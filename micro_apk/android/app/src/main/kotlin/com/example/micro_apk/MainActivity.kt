package com.example.micro_apk

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.app.AppOpsManager
import java.text.Normalizer
import java.util.Locale
import android.content.Intent
import android.app.PendingIntent
import android.app.Activity
import android.media.projection.MediaProjectionManager
import android.os.ResultReceiver
import android.os.Bundle
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.net.Uri
import android.content.ComponentName
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val channel = "micro/runtime"
    @Volatile private var cachedInstalledApps: List<Map<String, Any>>? = null
    @Volatile private var installedAppsCacheAtMs = 0L
    private var voiceEventSink: EventChannel.EventSink? = null
    private var screenCaptureResult: MethodChannel.Result? = null
    private val screenCaptureHandler = Handler(Looper.getMainLooper())
    private var screenCaptureTimeout: Runnable? = null
    private var voiceReceiverRegistered = false
    private var termuxReceiverRegistered = false
    private val termuxCallbacks = ConcurrentHashMap<String, MethodChannel.Result>()
    private val termuxResultReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val id = intent?.getStringExtra("request_id") ?: return
            val callback = termuxCallbacks.remove(id) ?: return
            val rawOutput = intent.getStringExtra("stdout") ?: ""
            val exitMarker = Regex("(?m)^__NETWORK_EXIT_CODE_${Regex.escape(id)}=(-?\\d+)\\s*$")
            val exitMatch = exitMarker.find(rawOutput)
            val output = if (exitMatch != null) {
                rawOutput.removeRange(exitMatch.range).trimEnd()
            } else {
                rawOutput
            }
            val exitCode = exitMatch?.groupValues?.getOrNull(1)?.toIntOrNull()
                ?: intent.getIntExtra("exitCode", -1)
            callback.success(mapOf(
                "request_id" to id,
                "stdout" to output,
                "stderr" to (intent.getStringExtra("stderr") ?: ""),
                "exit_code" to exitCode
            ))
        }
    }
    private val voiceCommandReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            voiceEventSink?.success(intent?.getStringExtra("event") ?: "toggle")
        }
    }

    private fun normalizedAppName(value: String): String {
        return Normalizer.normalize(value.trim(), Normalizer.Form.NFD)
            .replace(Regex("\\p{Mn}+"), "")
            .lowercase(Locale.ROOT)
            .replace(Regex("[^a-z0-9]+"), "")
    }

    private fun installedAppsInventory(): List<Map<String, Any>> {
        val now = android.os.SystemClock.elapsedRealtime()
        cachedInstalledApps?.let { cached ->
            if (now - installedAppsCacheAtMs < 30_000L) return cached
        }
        val launcherPackages = packageManager.queryIntentActivities(
            Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER), 0
        ).map { it.activityInfo.packageName }.toSet()
        val inventory = packageManager.getInstalledPackages(0)
            .mapNotNull { pkg ->
                val appInfo = pkg.applicationInfo ?: return@mapNotNull null
                val packageId = pkg.packageName
                val label = try { appInfo.loadLabel(packageManager).toString() } catch (_: Exception) { packageId }
                mapOf(
                    "name" to label,
                    "package" to packageId,
                    "system" to ((appInfo.flags and android.content.pm.ApplicationInfo.FLAG_SYSTEM) != 0),
                    "enabled" to appInfo.enabled,
                    "launchable" to launcherPackages.contains(packageId)
                )
            }
            .sortedWith(compareBy<Map<String, Any>> { (it["name"] as String).lowercase(Locale.ROOT) }.thenBy { it["package"] as String })
        cachedInstalledApps = inventory
        installedAppsCacheAtMs = now
        return inventory
    }

    private fun resolveAppByName(appQuery: String): Map<String, Any?> {
        if (appQuery.isBlank() || appQuery.length > 200) return mapOf("success" to false, "error" to "Nome ou pacote inválido.")
        val apps = installedAppsInventory().filter { it["launchable"] == true }
        val exactPackage = apps.firstOrNull { (it["package"] as String).equals(appQuery, true) }
        val queryNormalized = normalizedAppName(appQuery)
        if (queryNormalized.isEmpty() && exactPackage == null) return mapOf("success" to false, "error" to "Nome inválido.")
        val exactLabel = apps.filter { normalizedAppName(it["name"] as String) == queryNormalized }
        val partial = if (exactLabel.isEmpty()) apps.filter {
            val label = normalizedAppName(it["name"] as String)
            label.contains(queryNormalized) || queryNormalized.contains(label)
        } else emptyList()
        val matches = when {
            exactPackage != null -> listOf(exactPackage)
            exactLabel.size == 1 -> exactLabel
            exactLabel.size > 1 -> exactLabel
            partial.size == 1 -> partial
            else -> partial
        }
        if (matches.size != 1) {
            return mapOf(
                "success" to false,
                "error" to if (matches.isEmpty()) "Nenhum aplicativo inicializável corresponde a '$appQuery'." else "Nome ambíguo; não abri nenhum aplicativo.",
                "candidates" to matches.take(12).map { mapOf("name" to it["name"], "package" to it["package"]) }
            )
        }
        val chosen = matches.single()
        val packageId = chosen["package"] as String
        if (packageManager.getLaunchIntentForPackage(packageId) == null) {
            return mapOf("success" to false, "error" to "O app foi listado, mas não tem atividade de abertura.", "name" to chosen["name"], "package" to packageId)
        }
        return mapOf("success" to true, "name" to chosen["name"], "package" to packageId)
    }

    private fun androidSensitivitySnapshot(): Map<String, Any?> {
        val packageInfo = packageManager.getPackageInfo(packageName, PackageManager.GET_PERMISSIONS)
        val declaredPermissions = packageInfo.requestedPermissions?.toList() ?: emptyList()
        fun permissionState(permission: String, declared: Boolean): Map<String, Any?> {
            val special = when (permission) {
                Manifest.permission.SYSTEM_ALERT_WINDOW -> "overlay"
                else -> null
            }
            val applicable = when (permission) {
                Manifest.permission.READ_EXTERNAL_STORAGE -> Build.VERSION.SDK_INT <= 32
                Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO -> Build.VERSION.SDK_INT >= 33
                Manifest.permission.POST_NOTIFICATIONS -> Build.VERSION.SDK_INT >= 33
                else -> true
            }
            val granted = when (special) {
                "overlay" -> Build.VERSION.SDK_INT < 23 || Settings.canDrawOverlays(this)
                else -> if (Build.VERSION.SDK_INT >= 23) checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
                    else packageManager.checkPermission(permission, packageName) == PackageManager.PERMISSION_GRANTED
            }
            val state = when {
                !applicable -> "not_applicable_on_this_android"
                !declared -> "not_requested"
                special != null -> if (granted) "special_access_granted" else "special_access_missing"
                granted -> "granted"
                else -> "denied_or_not_granted"
            }
            return mapOf("permission" to permission, "declared" to declared, "granted" to granted,
                "specialAccess" to special, "applicable" to applicable, "state" to state)
        }
        val permissions = (declaredPermissions.map { permissionState(it, true) } + listOf(
            Manifest.permission.RECORD_AUDIO, Manifest.permission.CAMERA,
            Manifest.permission.READ_CONTACTS, Manifest.permission.READ_MEDIA_IMAGES,
            Manifest.permission.READ_MEDIA_VIDEO, Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED,
            Manifest.permission.READ_EXTERNAL_STORAGE, Manifest.permission.POST_NOTIFICATIONS,
            Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION
        ).filterNot { declaredPermissions.contains(it) }.map { permissionState(it, false) })
        val enabledAccessibility = Settings.Secure.getString(contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: ""
        val accessibilityComponent = ComponentName(this, NetworkAccessibilityService::class.java).flattenToString()
        val accessibilityEnabled = enabledAccessibility.split(':').any { it.equals(accessibilityComponent, true) }
        val overlayGranted = Build.VERSION.SDK_INT < 23 || Settings.canDrawOverlays(this)
        val usageAccess = try {
            val appOps = getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
            val mode = appOps.checkOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, android.os.Process.myUid(), packageName)
            mode == AppOpsManager.MODE_ALLOWED
        } catch (_: Exception) { false }
        val batteryOptimizationsIgnored = if (Build.VERSION.SDK_INT >= 23) {
            (getSystemService(Context.POWER_SERVICE) as android.os.PowerManager).isIgnoringBatteryOptimizations(packageName)
        } else true
        return mapOf(
            "androidVersion" to Build.VERSION.RELEASE, "apiLevel" to Build.VERSION.SDK_INT,
            "manufacturer" to Build.MANUFACTURER, "model" to Build.MODEL,
            "permissions" to permissions,
            "specialAccess" to mapOf("accessibility" to accessibilityEnabled, "accessibilityServiceConnected" to NetworkAccessibilityService.isConnected(), "overlay" to overlayGranted,
                "usageAccess" to usageAccess, "batteryOptimizationExemption" to batteryOptimizationsIgnored,
                "screenCapture" to "consent_required_each_session; no persistent permission"),
            "capabilities" to mapOf("appInventory" to "QUERY_ALL_PACKAGES; installed package metadata only, no app private data",
                "screenUnderstanding" to "Accessibility snapshots and OCR via user-approved MediaProjection",
                "privacyLimitations" to "Protected content, secure windows, private app databases and denied permissions are not accessible")
        )
    }

    override fun onDestroy() {
        if (voiceReceiverRegistered) {
            try { unregisterReceiver(voiceCommandReceiver) } catch (_: Exception) {}
            voiceReceiverRegistered = false
        }
        if (termuxReceiverRegistered) {
            try { unregisterReceiver(termuxResultReceiver) } catch (_: Exception) {}
            termuxReceiverRegistered = false
        }
        termuxCallbacks.values.forEach { it.error("ACTIVITY_CLOSED", "NETWORK foi encerrado antes do retorno do Termux.", null) }
        termuxCallbacks.clear()
        screenCaptureTimeout?.let { screenCaptureHandler.removeCallbacks(it) }
        screenCaptureTimeout = null
        screenCaptureResult?.error("ACTIVITY_CLOSED", "NETWORK foi encerrado durante a captura de tela.", null)
        screenCaptureResult = null
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "micro/screen_events").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    NetworkAccessibilityService.setScreenEventSink(events)
                }
                override fun onCancel(arguments: Any?) {
                    NetworkAccessibilityService.setScreenEventSink(null)
                }
            }
        )
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "micro/voice_events").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { voiceEventSink = events }
                override fun onCancel(arguments: Any?) { voiceEventSink = null }
            }
        )
        if (!voiceReceiverRegistered) {
            val filter = IntentFilter(NetworkBubbleService.ACTION_VOICE_TOGGLE)
            if (Build.VERSION.SDK_INT >= 33) registerReceiver(voiceCommandReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
            else registerReceiver(voiceCommandReceiver, filter)
            voiceReceiverRegistered = true
        }
        if (!termuxReceiverRegistered) {
            val filter = IntentFilter("$packageName.TERMUX_RESULT")
            if (Build.VERSION.SDK_INT >= 33) registerReceiver(termuxResultReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
            else registerReceiver(termuxResultReceiver, filter)
            termuxReceiverRegistered = true
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel).setMethodCallHandler { call, result ->
            when (call.method) {
                "agent_keep_alive_start" -> {
                    val serviceIntent = Intent(this, MicroRuntimeService::class.java).setAction(MicroRuntimeService.ACTION_AGENT_START)
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(serviceIntent) else startService(serviceIntent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("AGENT_SERVICE", "Não foi possível manter a tarefa ativa em segundo plano: ${e.message}", null)
                    }
                }
                "agent_keep_alive_stop" -> {
                    try {
                        startService(Intent(this, MicroRuntimeService::class.java).setAction(MicroRuntimeService.ACTION_AGENT_STOP))
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("AGENT_SERVICE", e.message, null)
                    }
                }
                "phone_android_sensitivity" -> result.success(androidSensitivitySnapshot())
                "phone_list_apps" -> result.success(installedAppsInventory())
                "open_app_resolved" -> {
                    val resolved = resolveAppByName(call.argument<String>("app")?.trim().orEmpty())
                    val packageId = resolved["package"]?.toString().orEmpty()
                    if (resolved["success"] != true || packageId.isBlank()) {
                        result.success(resolved)
                    } else {
                        // Do not report success merely because startActivity was dispatched.
                        // Wait until Accessibility sees the requested app's real window.
                        NetworkAccessibilityService.openAppAndRead(packageId) { screen ->
                            val opened = screen.startsWith("APP_ABERTO_TELA_DETECTADA") ||
                                screen.startsWith("APP_JA_ATIVO")
                            result.success(mapOf(
                                "success" to opened,
                                "dispatched" to true,
                                "name" to resolved["name"],
                                "package" to packageId,
                                "screen" to screen,
                                "error" to if (opened) null else screen
                            ))
                        }
                    }
                }
                "launch_app" -> {
                    val packageName = call.argument<String>("package")?.trim().orEmpty()
                    if (packageName.isBlank() || packageName.length > 200) {
                        result.error("APP_PACKAGE", "Identificador de aplicativo inválido.", null)
                    } else {
                        val launch = packageManager.getLaunchIntentForPackage(packageName)
                        if (launch == null) result.success(false)
                        else {
                            launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            try { startActivity(launch); result.success(true) }
                            catch (e: Exception) { result.error("APP_LAUNCH", e.message, null) }
                        }
                    }
                }
                "hasOverlayPermission" -> result.success(Build.VERSION.SDK_INT < 23 || Settings.canDrawOverlays(this))
                "requestOverlayPermission" -> {
                    if (Build.VERSION.SDK_INT >= 23 && !Settings.canDrawOverlays(this)) {
                        startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName")))
                    }
                    result.success(true)
                }
                "isAccessibilityEnabled" -> {
                    val enabled = Settings.Secure.getString(contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: ""
                    val component = ComponentName(this, NetworkAccessibilityService::class.java).flattenToString()
                    result.success(enabled.split(':').any { it.equals(component, true) })
                }
                "openAccessibilitySettings" -> {
                    startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                    result.success(true)
                }
                "setBubbleState" -> {
                    val state = call.argument<String>("state") ?: "idle"
                    sendBroadcast(Intent(NetworkBubbleService.ACTION_BUBBLE_STATE).setPackage(packageName).putExtra("state", state))
                    result.success(true)
                }
                "startFloatingBubble" -> {
                    if (Build.VERSION.SDK_INT >= 23 && checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                        requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), 4105)
                        result.error("MICROPHONE_PERMISSION_REQUIRED", "Autorize o microfone e toque novamente em Assistente flutuante.", null)
                    } else if (Build.VERSION.SDK_INT >= 23 && !Settings.canDrawOverlays(this)) {
                        result.error("OVERLAY_PERMISSION", "Permissão de sobreposição não concedida.", null)
                    } else {
                        val serviceIntent = Intent(this, NetworkBubbleService::class.java)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(serviceIntent) else startService(serviceIntent)
                        result.success(true)
                    }
                }
                "stopFloatingBubble" -> {
                    stopService(Intent(this, NetworkBubbleService::class.java))
                    result.success(true)
                }
                "phone_screen_ocr_capture" -> {
                    if (screenCaptureResult != null) {
                        result.error("CAPTURE_BUSY", "Já existe uma captura de tela em andamento.", null)
                    } else {
                        val manager = getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
                        screenCaptureResult = result
                        screenCaptureTimeout = Runnable {
                            screenCaptureResult?.error("CAPTURE_TIMEOUT", "O Android não concluiu a autorização/captura em 15 segundos. Tente novamente.", null)
                            screenCaptureResult = null
                            screenCaptureTimeout = null
                            stopService(Intent(this, ScreenOcrCaptureService::class.java))
                        }
                        screenCaptureHandler.postDelayed(screenCaptureTimeout!!, 15000)
                        try {
                            startActivityForResult(manager.createScreenCaptureIntent(), 4199)
                        } catch (e: Exception) {
                            screenCaptureTimeout?.let { screenCaptureHandler.removeCallbacks(it) }
                            screenCaptureTimeout = null
                            screenCaptureResult = null
                            result.error("CAPTURE_PERMISSION", "Não foi possível solicitar permissão de captura: ${e.message}", null)
                        }
                    }
                }
                "local_shell_exec" -> {
                    val command = call.argument<String>("command")?.trim().orEmpty()
                    val workdir = call.argument<String>("workdir")?.trim().orEmpty()
                    if (command.isEmpty() || command.length > 8000 || command.contains('\u0000')) {
                        result.error("LOCAL_SHELL_ARGUMENT", "Comando vazio, inválido ou acima de 8000 caracteres.", null)
                        return@setMethodCallHandler
                    }
                    val requestId = UUID.randomUUID().toString()
                    // Termux background callbacks reliably return stdout. Wrap the
                    // command in a subshell and append a request-specific exit marker
                    // so NETWORK can still verify the real command exit code.
                    val quotedCommand = "'" + command.replace("'", "'\"'\"'") + "'"
                    val wrappedCommand = "bash -lc $quotedCommand 2>&1\n__network_exit_code=\$?\nprintf '\n__NETWORK_EXIT_CODE_${requestId}=%s\n' \"\$__network_exit_code\""
                    val callbackIntent = Intent("$packageName.TERMUX_RESULT").setPackage(packageName)
                        .putExtra("request_id", requestId)
                    val pendingFlags = PendingIntent.FLAG_UPDATE_CURRENT or
                        (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
                    val callback = PendingIntent.getBroadcast(this, requestId.hashCode(), callbackIntent, pendingFlags)
                    val run = Intent("com.termux.RUN_COMMAND").setClassName(
                        "com.termux", "com.termux.app.RunCommandService"
                    ).putExtra("com.termux.RUN_COMMAND_PATH", "/data/data/com.termux/files/usr/bin/bash")
                        .putStringArrayListExtra("com.termux.RUN_COMMAND_ARGUMENTS", arrayListOf("-lc", wrappedCommand))
                        .putExtra("com.termux.RUN_COMMAND_WORKDIR",
                            if (workdir.isEmpty()) "/data/data/com.termux/files/home" else workdir)
                        .putExtra("com.termux.RUN_COMMAND_BACKGROUND", true)
                        .putExtra("com.termux.RUN_COMMAND_PENDING_INTENT", callback)
                    try {
                        termuxCallbacks[requestId] = result
                        startService(run)
                    } catch (e: Exception) {
                        termuxCallbacks.remove(requestId)
                        result.error("LOCAL_SHELL_UNAVAILABLE",
                            "Não foi possível iniciar o Termux. Confira se está instalado (versão 0.109+), se NETWORK tem a permissão “Executar comandos no Termux” e se allow-external-apps=true está configurado no Termux: ${e.message}", null)
                    }
                }
                "phone_open_app_and_read" -> {
                    val packageName = call.argument<String>("package")?.trim().orEmpty()
                    NetworkAccessibilityService.openAppAndRead(packageName) { screen ->
                        result.success(screen)
                    }
                }
                "phone_browser_search" -> {
                    val query = call.argument<String>("query")?.trim().orEmpty()
                    NetworkAccessibilityService.browserSearch(query) { screen ->
                        result.success(screen)
                    }
                }
                "phone_cancel_pending" -> {
                    result.success(NetworkAccessibilityService.cancelPendingActions())
                }
                "phone_wait_for_text" -> {
                    val args = call.arguments as? Map<*, *> ?: emptyMap<String, Any?>()
                    val query = args["text"]?.toString().orEmpty()
                    try {
                        NetworkAccessibilityService.waitForTextVisible(query, { accepted ->
                            result.success(accepted)
                        }, (args["timeoutMs"] as? Number)?.toLong() ?: 0L)
                    } catch (e: Exception) {
                        result.error("PHONE_ACTION", e.message ?: "Falha ao aguardar elemento.", null)
                    }
                }
                "phone_focus_input" -> {
                    val args = call.arguments as? Map<*, *> ?: emptyMap<String, Any?>()
                    try {
                        NetworkAccessibilityService.waitForInputFocus({ accepted ->
                            result.success(accepted)
                        }, (args["timeoutMs"] as? Number)?.toLong() ?: 0L)
                    } catch (e: Exception) {
                        result.error("PHONE_ACTION", e.message ?: "Falha ao focar campo.", null)
                    }
                }
                "phone_tap_text" -> {
                    val args = call.arguments as? Map<*, *> ?: emptyMap<String, Any?>()
                    val query = args["text"]?.toString().orEmpty()
                    try {
                        NetworkAccessibilityService.waitForText(query, { accepted ->
                            result.success(accepted)
                        }, (args["timeoutMs"] as? Number)?.toLong() ?: 0L)
                    } catch (e: Exception) {
                        result.error("PHONE_ACTION", e.message ?: "Falha ao localizar elemento.", null)
                    }
                }
                "phone_screen_read", "phone_tap", "phone_scroll", "phone_long_press", "phone_swipe", "phone_type_text", "phone_press_back", "phone_open_app", "phone_open_app_window", "phone_window_capabilities", "phone_window_list", "phone_window_read", "phone_window_tap_text", "phone_window_type_text", "phone_window_scroll" -> {
                    @Suppress("UNCHECKED_CAST")
                    val args = call.arguments as? Map<String, Any?> ?: emptyMap()
                    try {
                        result.success(NetworkAccessibilityService.execute(call.method, args))
                    } catch (e: Exception) {
                        result.error("PHONE_ACTION", e.message ?: "Falha na ação de acessibilidade.", null)
                    }
                }
                "isArm64" -> result.success(Build.SUPPORTED_ABIS.any { it == "arm64-v8a" })
                "installBundled" -> {
                    val prefix = call.argument<String>("prefix")
                    if (prefix.isNullOrBlank()) {
                        result.error("ARGUMENT", "Destino ausente", null)
                        return@setMethodCallHandler
                    }
                    // A cópia do modelo tem cerca de 9 GB: nunca executar na thread da interface.
                    Thread {
                        try {
                            val root = File(prefix)
                            val binary = File(root, "bin/ollama")
                            val modelManifests = File(filesDir, "models/manifests")
                            val marker = File(filesDir, "bundle-installed.marker")
                            if (!marker.exists() || !binary.exists() || !modelManifests.exists()) {
                                marker.delete()
                                copyAssetTree("flutter_assets/assets/bundle/runtime", root)
                                copyAssetTree("flutter_assets/assets/bundle/models", File(filesDir, "models"))
                                if (!binary.exists() || !modelManifests.exists()) {
                                    throw IllegalStateException("Runtime ou manifestos do modelo não foram copiados")
                                }
                                marker.writeText("CODEX bundle v1")
                            }
                            Handler(Looper.getMainLooper()).post { result.success(true) }
                        } catch (e: Exception) {
                            Handler(Looper.getMainLooper()).post {
                                result.error("BUNDLE_INSTALL", e.message, null)
                            }
                        }
                    }.start()
                }
                "startAgentKeepAlive" -> {
                    val intent = Intent(this, MicroRuntimeService::class.java).apply {
                        action = MicroRuntimeService.ACTION_AGENT_START
                    }
                    if (Build.VERSION.SDK_INT >= 33 &&
                        checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 4104)
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent) else startService(intent)
                    result.success(true)
                }
                "stopAgentKeepAlive" -> {
                    val intent = Intent(this, MicroRuntimeService::class.java).apply {
                        action = MicroRuntimeService.ACTION_AGENT_STOP
                    }
                    startService(intent)
                    result.success(true)
                }
                "startOllama" -> {
                    val prefix = call.argument<String>("prefix")
                    if (prefix.isNullOrBlank()) {
                        result.error("ARGUMENT", "Prefix ausente", null)
                        return@setMethodCallHandler
                    }
                    val intent = Intent(this, MicroRuntimeService::class.java).apply {
                        action = MicroRuntimeService.ACTION_START
                        putExtra(MicroRuntimeService.EXTRA_PREFIX, prefix)
                    }
                    if (Build.VERSION.SDK_INT >= 33 &&
                        checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 4103)
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent) else startService(intent)
                    result.success(true)
                }
                "stopOllama" -> {
                    val intent = Intent(this, MicroRuntimeService::class.java).apply {
                        action = MicroRuntimeService.ACTION_STOP
                    }
                    startService(intent)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    @Deprecated("Deprecated in Android API; retained for Android 10 compatibility")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 4199) return
        val callback = screenCaptureResult ?: return
        if (resultCode != Activity.RESULT_OK || data == null) {
            screenCaptureTimeout?.let { screenCaptureHandler.removeCallbacks(it) }
            screenCaptureTimeout = null
            screenCaptureResult = null
            callback.error("CAPTURE_DENIED", "Permissão de captura de tela negada.", null)
            return
        }
        try {
            val receiver = object : ResultReceiver(Handler(Looper.getMainLooper())) {
                override fun onReceiveResult(resultCode: Int, resultData: Bundle?) {
                    val callback = screenCaptureResult
                    screenCaptureTimeout?.let { screenCaptureHandler.removeCallbacks(it) }
                    screenCaptureTimeout = null
                    screenCaptureResult = null
                    if (callback == null) return
                    if (resultCode == Activity.RESULT_OK) {
                        val path = resultData?.getString("path")
                        if (path.isNullOrBlank()) callback.error("CAPTURE_FAILED", "O serviço OCR não retornou a imagem.", null)
                        else callback.success(path)
                    } else {
                        callback.error("CAPTURE_FAILED", resultData?.getString("error") ?: "Falha ao capturar a tela.", null)
                    }
                }
            }
            val service = Intent(this, ScreenOcrCaptureService::class.java)
                .putExtra(ScreenOcrCaptureService.EXTRA_RESULT_CODE, resultCode)
                .putExtra(ScreenOcrCaptureService.EXTRA_DATA, data)
                .putExtra(ScreenOcrCaptureService.EXTRA_RECEIVER, receiver)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(service) else startService(service)
        } catch (e: Exception) {
            screenCaptureTimeout?.let { screenCaptureHandler.removeCallbacks(it) }
            screenCaptureTimeout = null
            screenCaptureResult = null
            callback.error("CAPTURE_FAILED", e.message ?: "Falha ao iniciar o serviço OCR.", null)
        }
    }

    private fun copyAssetTree(assetPath: String, destination: File) {
        destination.mkdirs()
        val children = assets.list(assetPath) ?: emptyArray()
        if (children.isEmpty()) {
            assets.open(assetPath).use { input ->
                destination.outputStream().use { output -> input.copyTo(output, 1024 * 1024) }
            }
            destination.setExecutable(true, false)
            return
        }
        for (child in children) {
            copyAssetTree("$assetPath/$child", File(destination, child))
        }
    }
}
