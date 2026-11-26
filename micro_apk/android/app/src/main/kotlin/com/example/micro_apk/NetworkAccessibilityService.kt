package com.example.micro_apk

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Intent
import android.app.ActivityOptions
import android.net.Uri
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import android.graphics.Path
import android.graphics.Rect
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import io.flutter.plugin.common.EventChannel

class NetworkAccessibilityService : AccessibilityService() {
    companion object {
        @Volatile private var active: NetworkAccessibilityService? = null
        fun isConnected(): Boolean = active != null
        @Volatile private var screenEventSink: EventChannel.EventSink? = null
        fun setScreenEventSink(sink: EventChannel.EventSink?) {
            screenEventSink = sink
            if (sink != null) active?.publishCurrentScreenState()
        }

        fun execute(action: String, args: Map<String, Any?>): Any {
            val service = active ?: throw IllegalStateException("Ative NETWORK - Controle do celular nas configurações de Acessibilidade.")
            return service.perform(action, args)
        }

        fun openAppAndRead(packageName: String, callback: (String) -> Unit) {
            val service = active ?: run { callback("ERRO: Acessibilidade do NETWORK não está ativa."); return }
            service.openAppAndReadWindow(packageName, callback)
        }

        fun browserSearch(query: String, callback: (String) -> Unit) {
            val service = active ?: run { callback("ERRO: Acessibilidade do NETWORK não está ativa."); return }
            service.openBrowserSearch(query, callback)
        }

        fun waitForText(query: String, callback: (Boolean) -> Unit, timeoutMs: Long = 3000L) {
            val service = active ?: throw IllegalStateException("Ative NETWORK - Controle do celular nas configurações de Acessibilidade.")
            service.waitForVisibleText(query, true, callback, timeoutMs)
        }

        fun waitForTextVisible(query: String, callback: (Boolean) -> Unit, timeoutMs: Long = 20000L) {
            val service = active ?: throw IllegalStateException("Ative NETWORK - Controle do celular nas configurações de Acessibilidade.")
            service.waitForVisibleText(query, false, callback, timeoutMs)
        }

        fun waitForInputFocus(callback: (Boolean) -> Unit, timeoutMs: Long = 3000L) {
            val service = active ?: throw IllegalStateException("Ative NETWORK - Controle do celular nas configurações de Acessibilidade.")
            service.waitForEditableFocus(callback, timeoutMs)
        }

        fun cancelPendingActions(): Boolean {
            return active?.cancelPendingActions() ?: false
        }
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        active = this
        if (screenEventSink != null) publishCurrentScreenState()
    }

    private data class PendingTextTap(
        val query: String,
        val callback: (Boolean) -> Unit,
        val timeout: Runnable,
        val tap: Boolean
    )

    private val mainHandler = Handler(Looper.getMainLooper())
    private var screenEventPending: Runnable? = null
    private var lastScreenSnapshot = ""
    private var screenEventSequence = 0L
    private data class PendingWindowRead(val packageName: String, val callback: (String) -> Unit, val timeout: Runnable, val requireContentChange: Boolean)
    @Volatile private var pendingWindowRead: PendingWindowRead? = null
    @Volatile private var pendingTextTap: PendingTextTap? = null
    private data class PendingInputFocus(val callback: (Boolean) -> Unit, val timeout: Runnable)
    @Volatile private var pendingInputFocus: PendingInputFocus? = null

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return
        if (event.eventType == AccessibilityEvent.TYPE_WINDOWS_CHANGED ||
            event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED ||
            event.eventType == AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED ||
            event.eventType == AccessibilityEvent.TYPE_VIEW_SCROLLED ||
            event.eventType == AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED ||
            event.eventType == AccessibilityEvent.TYPE_VIEW_CLICKED ||
            event.eventType == AccessibilityEvent.TYPE_VIEW_SELECTED ||
            event.eventType == AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED ||
            event.eventType == AccessibilityEvent.TYPE_NOTIFICATION_STATE_CHANGED ||
            event.eventType == AccessibilityEvent.TYPE_ANNOUNCEMENT) {
            scheduleScreenStateEvent(event.eventType, event.eventTime, event.packageName?.toString())
        }
        if (pendingWindowRead != null) resolvePendingWindowRead(event)
        if (pendingInputFocus != null) resolvePendingInputFocus()
        if (pendingTextTap == null) return
        if (event.eventType == AccessibilityEvent.TYPE_WINDOWS_CHANGED ||
            event.eventType == AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED ||
            event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED ||
            event.eventType == AccessibilityEvent.TYPE_VIEW_SCROLLED ||
            event.eventType == AccessibilityEvent.TYPE_VIEW_FOCUSED ||
            event.eventType == AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED ||
            event.eventType == AccessibilityEvent.TYPE_VIEW_CLICKED ||
            event.eventType == AccessibilityEvent.TYPE_VIEW_SELECTED ||
            event.eventType == AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED) {
            resolvePendingTextTap()
        }
    }

    private fun openAppAndReadWindow(packageName: String, callback: (String) -> Unit) {
        if (packageName.isBlank() || packageName.length > 200) { callback("ERRO: pacote inválido."); return }
        val currentPackage = rootInActiveWindow?.packageName?.toString()
        if (currentPackage == packageName) { callback("APP_JA_ATIVO\\n${readScreen()}"); return }
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        if (launch == null) { callback("ERRO: aplicativo não instalado ou sem atividade inicializável: $packageName"); return }
        // Register the expected package BEFORE launching, otherwise a fast window event
        // can arrive before the pending read exists and the agent will inspect the old app.
        waitForPackageWindow(packageName, callback)
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            startActivity(launch)
        } catch (error: Exception) {
            cancelPendingWindowRead("ERRO AO ABRIR APLICATIVO: ${error.message}")
        }
    }
    private fun openBrowserSearch(query: String, callback: (String) -> Unit) {
        val value = query.trim()
        if (value.isEmpty() || value.length > 1000) { callback("ERRO: pesquisa vazia ou muito longa."); return }
        val uri = Uri.parse("https://www.google.com/search?q=${Uri.encode(value)}")
        val intent = Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val target = intent.resolveActivity(packageManager)?.packageName
        if (target.isNullOrBlank()) { callback("ERRO: nenhum navegador disponível para abrir a pesquisa."); return }
        try {
            startActivity(intent)
            callback("PESQUISA_DISPARADA: navegador acionado. Continue pela tela assim que os elementos necessários surgirem nos eventos de Acessibilidade.")
        } catch (error: Exception) {
            cancelPendingWindowRead("ERRO AO ABRIR PESQUISA NO NAVEGADOR: ${error.message}")
        }
    }

    private fun waitForPackageWindow(packageName: String, callback: (String) -> Unit, requireContentChange: Boolean = false) {
        if (pendingWindowRead != null) { callback("ERRO: já existe uma abertura de aplicativo aguardando a tela."); return }
        lateinit var timeout: Runnable
        timeout = Runnable {
            val pending = pendingWindowRead
            if (pending != null && pending.callback === callback) {
                pendingWindowRead = null
                pending.callback("APP_NAO_DISPONIBILIZOU_JANELA: o Android não enviou uma janela acessível para o aplicativo dentro do prazo de segurança.\n${readScreen()}")
            }
        }
        pendingWindowRead = PendingWindowRead(packageName, callback, timeout, requireContentChange)
        mainHandler.postDelayed(timeout, 15000L)
    }

    private fun resolvePendingWindowRead(event: AccessibilityEvent? = null): Boolean {
        val pending = pendingWindowRead ?: return false
        if (pending.requireContentChange && event?.eventType != AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED) return false
        val root = rootInActiveWindow ?: return false
        if (root.packageName?.toString() != pending.packageName) return false
        pendingWindowRead = null
        mainHandler.removeCallbacks(pending.timeout)
        pending.callback("APP_ABERTO_TELA_DETECTADA\n${readScreen()}")
        return true
    }

    private fun cancelPendingWindowRead(message: String) {
        val pending = pendingWindowRead ?: return
        pendingWindowRead = null
        mainHandler.removeCallbacks(pending.timeout)
        pending.callback(message)
    }

    private fun waitForVisibleText(query: String, tap: Boolean, callback: (Boolean) -> Unit, timeoutMs: Long = 20000L) {
        // Never allow zero/negative timeouts to create an immortal pending action.
        val boundedTimeoutMs = timeoutMs.coerceIn(250L, 8000L)
        val target = query.trim()
        if (target.isEmpty() || target.length > 300 || pendingTextTap != null) {
            callback(false)
            return
        }
        val timeout = Runnable {
            val pending = pendingTextTap
            if (pending != null && pending.callback === callback) {
                pendingTextTap = null
                pending.callback(false)
            }
        }
        pendingTextTap = PendingTextTap(target, callback, timeout, tap)
        if (!resolvePendingTextTap()) mainHandler.postDelayed(timeout, boundedTimeoutMs)
    }

    private fun cancelPendingActions(): Boolean {
        var cancelled = false
        if (pendingWindowRead != null) {
            cancelPendingWindowRead("EXECUÇÃO INTERROMPIDA PELO USUÁRIO")
            cancelled = true
        }
        val pending = pendingTextTap
        if (pending != null) {
            pendingTextTap = null
            mainHandler.removeCallbacks(pending.timeout)
            pending.callback(false)
            cancelled = true
        }
        val focus = pendingInputFocus
        if (focus != null) {
            pendingInputFocus = null
            mainHandler.removeCallbacks(focus.timeout)
            focus.callback(false)
            cancelled = true
        }
        return cancelled
    }


    private fun waitForEditableFocus(callback: (Boolean) -> Unit, timeoutMs: Long = 3000L) {
        val boundedTimeoutMs = timeoutMs.coerceIn(250L, 5000L)
        if (pendingInputFocus != null) { callback(false); return }
        if (hasFocusedEditable()) { callback(true); return }
        focusInput()
        if (hasFocusedEditable()) { callback(true); return }
        lateinit var timeout: Runnable
        timeout = Runnable {
            val pending = pendingInputFocus
            if (pending != null && pending.callback === callback) {
                pendingInputFocus = null
                pending.callback(false)
            }
        }
        pendingInputFocus = PendingInputFocus(callback, timeout)
        mainHandler.postDelayed(timeout, boundedTimeoutMs)
    }

    private fun resolvePendingInputFocus(): Boolean {
        val pending = pendingInputFocus ?: return false
        if (!hasFocusedEditable()) {
            focusInput()
            if (!hasFocusedEditable()) return false
        }
        pendingInputFocus = null
        mainHandler.removeCallbacks(pending.timeout)
        pending.callback(true)
        return true
    }

    private fun hasFocusedEditable(): Boolean {
        val root = rootInActiveWindow ?: return false
        return root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)?.isEditable == true
    }

    private fun hasVisibleTextInRoot(root: AccessibilityNodeInfo, query: String): Boolean {
        val targets = query.split('|').map { it.trim() }.filter { it.isNotEmpty() }
        fun find(node: AccessibilityNodeInfo, depth: Int): Boolean {
            if (depth > 24) return false
            val label = listOf(node.text?.toString(), node.contentDescription?.toString())
                .filterNotNull().joinToString(" ").trim()
            if (node.isVisibleToUser && targets.any { label.contains(it, ignoreCase = true) }) return true
            for (i in 0 until node.childCount) {
                val child = node.getChild(i) ?: continue
                if (find(child, depth + 1)) return true
            }
            return false
        }
        return find(root, 0)
    }

    private fun resolvePendingTextTap(): Boolean {
        val pending = pendingTextTap ?: return false
        val root = rootInActiveWindow ?: return false
        val matched = if (pending.tap) tapTextInRoot(root, pending.query) else hasVisibleTextInRoot(root, pending.query)
        if (matched) {
            pendingTextTap = null
            mainHandler.removeCallbacks(pending.timeout)
            pending.callback(true)
        }
        return matched
    }

    override fun onInterrupt() {
        cancelPendingWindowRead("ERRO: serviço de Acessibilidade foi interrompido.")
        val pending = pendingTextTap
        pendingTextTap = null
        if (pending != null) {
            mainHandler.removeCallbacks(pending.timeout)
            pending.callback(false)
        }
        val focus = pendingInputFocus
        pendingInputFocus = null
        if (focus != null) {
            mainHandler.removeCallbacks(focus.timeout)
            focus.callback(false)
        }
    }

    override fun onDestroy() {
        cancelPendingWindowRead("ERRO: serviço de Acessibilidade foi encerrado.")
        val pending = pendingTextTap
        pendingTextTap = null
        if (pending != null) {
            mainHandler.removeCallbacks(pending.timeout)
            pending.callback(false)
        }
        val focus = pendingInputFocus
        pendingInputFocus = null
        if (focus != null) {
            mainHandler.removeCallbacks(focus.timeout)
            focus.callback(false)
        }
        if (active === this) active = null
        super.onDestroy()
    }

    private fun number(args: Map<String, Any?>, key: String, fallback: Float = 0f): Float =
        (args[key] as? Number)?.toFloat() ?: fallback

    private fun gesture(x1: Float, y1: Float, x2: Float, y2: Float, duration: Long): Boolean {
        val path = Path().apply {
            moveTo(x1, y1)
            lineTo(if (x1 == x2 && y1 == y2) x2 + 0.1f else x2,
                if (x1 == x2 && y1 == y2) y2 + 0.1f else y2)
        }
        val stroke = GestureDescription.StrokeDescription(path, 0, duration.coerceIn(100, 3000))
        return dispatchGesture(GestureDescription.Builder().addStroke(stroke).build(), null, null)
    }

    private fun perform(action: String, args: Map<String, Any?>): Any {
        return when (action) {
            "phone_screen_read" -> readScreen()
            "phone_list_apps" -> listApps()
            "phone_tap" -> gesture(number(args, "x"), number(args, "y"), number(args, "x"), number(args, "y"), 90)
            "phone_tap_text" -> tapText(args["text"]?.toString() ?: "")
            "phone_scroll" -> scroll(args["direction"]?.toString() ?: "down")
            "phone_long_press" -> {
                val x = number(args, "x")
                val y = number(args, "y")
                gesture(x, y, x, y, (args["duration"] as? Number)?.toLong() ?: 900L)
            }
            "phone_swipe" -> gesture(
                number(args, "x1"), number(args, "y1"),
                number(args, "x2"), number(args, "y2"),
                (args["duration"] as? Number)?.toLong() ?: 350L
            )
            "phone_focus_input" -> focusInput()
            "phone_type_text" -> typeText(args["text"]?.toString() ?: "")
            "phone_press_back" -> performGlobalAction(GLOBAL_ACTION_BACK)
            "phone_open_app" -> openApp(args["package"]?.toString() ?: "")
            "phone_open_app_window" -> openAppWindow(args["package"]?.toString() ?: "")
            "phone_window_capabilities" -> windowCapabilities()
            "phone_window_list" -> listAppWindows()
            "phone_window_read" -> readAppWindow(args["package"]?.toString() ?: "", (args["window_id"] as? Number)?.toInt())
            "phone_window_tap_text" -> tapAppWindowText(args["package"]?.toString() ?: "", args["text"]?.toString() ?: "", (args["window_id"] as? Number)?.toInt())
            "phone_window_type_text" -> typeAppWindowText(args["package"]?.toString() ?: "", args["text"]?.toString() ?: "", (args["window_id"] as? Number)?.toInt())
            "phone_window_scroll" -> scrollAppWindow(args["package"]?.toString() ?: "", args["direction"]?.toString() ?: "down", (args["window_id"] as? Number)?.toInt())
            else -> throw IllegalArgumentException("Ação de celular desconhecida: $action")
        }
    }

    private fun listApps(): String {
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val apps = packageManager.queryIntentActivities(intent, 0)
            .map { it.activityInfo.applicationInfo to it.activityInfo.packageName }
            .distinctBy { it.second }
            .sortedBy { it.first.loadLabel(packageManager).toString().lowercase() }
        return apps.take(250).joinToString("\n") { (info, packageName) ->
            "${info.loadLabel(packageManager)} | $packageName"
        }.ifEmpty { "Nenhum aplicativo inicializável foi encontrado." }
    }

    private fun publishCurrentScreenState() {
        mainHandler.post {
            // A new Flutter listener needs the current screen even if it has not changed.
            lastScreenSnapshot = ""
            scheduleScreenStateEvent(AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED)
        }
    }

    private fun scheduleScreenStateEvent(eventType: Int, sourceEventTime: Long = 0L, sourcePackage: String? = null) {
        if (screenEventSink == null) return
        screenEventPending?.let { mainHandler.removeCallbacks(it) }
        val task = Runnable {
            screenEventPending = null
            val snapshotStartedAt = SystemClock.elapsedRealtimeNanos()
            val root = rootInActiveWindow ?: return@Runnable
            val snapshot = readScreen()
            val windowSnapshot = appWindowSummaries()
            val combinedSnapshot = "EVENT_TYPE:$eventType SOURCE:$sourcePackage\n" + snapshot + "\nWINDOWS:" + windowSnapshot.toString()
            if (combinedSnapshot == lastScreenSnapshot) return@Runnable
            lastScreenSnapshot = combinedSnapshot
            screenEventSequence += 1
            screenEventSink?.success(mapOf(
                "sequence" to screenEventSequence,
                "event_type" to eventType,
                "event_source_package" to (sourcePackage ?: ""),
                "eventAgeMs" to if (sourceEventTime > 0L) (SystemClock.uptimeMillis() - sourceEventTime).coerceAtLeast(0L) else 0L,
                "snapshotBuildMs" to ((SystemClock.elapsedRealtimeNanos() - snapshotStartedAt).coerceAtLeast(0L) / 1_000_000.0),
                "package" to (root.packageName?.toString() ?: ""),
                "screen" to snapshot,
                "windows" to windowSnapshot
            ))
        }
        screenEventPending = task
        // Coalesce events already queued on the main thread, but do not add a fixed 16ms wait.
        // The first useful accessibility snapshot is forwarded on the next main-loop turn.
        mainHandler.post(task)
    }

    private fun readScreen(): String {
        val root = rootInActiveWindow ?: return "A janela atual não disponibilizou elementos para acessibilidade."
        val output = StringBuilder()
        output.append("APP: ").append(root.packageName ?: "desconhecido").append('\n')
        var count = 0
        fun walk(node: AccessibilityNodeInfo, depth: Int) {
            if (count >= 120 || depth > 18) return
            val text = node.text?.toString()?.trim().orEmpty()
            val description = node.contentDescription?.toString()?.trim().orEmpty()
            val bounds = Rect()
            node.getBoundsInScreen(bounds)
            if ((text.isNotEmpty() || description.isNotEmpty() || node.isClickable || node.isEditable || node.isScrollable) && !bounds.isEmpty) {
                output.append("ELEMENTO ").append(count + 1)
                    .append(" texto=").append(text.take(240))
                    .append(" descrição=").append(description.take(160))
                    .append(" classe=").append(node.className ?: "")
                    .append(" bounds=").append(bounds.left).append(',').append(bounds.top)
                    .append(',').append(bounds.right).append(',').append(bounds.bottom)
                     .append(" clicável=").append(node.isClickable)
                    .append(" rolável=").append(node.isScrollable)
                    .append(" editável=").append(node.isEditable)
                    .append('\n')
                count++
            }
            for (i in 0 until node.childCount) {
                val child = node.getChild(i) ?: continue
                walk(child, depth + 1)
            }
        }
        walk(root, 0)
        if (count == 0) output.append("Nenhum texto/elemento acessível exposto pelo app atual.")
        return output.toString().take(16000)
    }

    private fun scroll(direction: String): Boolean {
        val forward = when (direction.lowercase()) {
            "down", "forward" -> true
            "up", "backward" -> false
            else -> throw IllegalArgumentException("Direção de rolagem deve ser up ou down.")
        }
        val root = rootInActiveWindow ?: return false
        val candidates = mutableListOf<Pair<AccessibilityNodeInfo, Rect>>()
        fun collect(node: AccessibilityNodeInfo, depth: Int) {
            if (depth > 24) return
            if (node.isScrollable) {
                val bounds = Rect()
                node.getBoundsInScreen(bounds)
                if (!bounds.isEmpty) candidates += node to bounds
            }
            for (i in 0 until node.childCount) {
                val child = node.getChild(i) ?: continue
                collect(child, depth + 1)
            }
        }
        collect(root, 0)
        // Prefere o contêiner rolável mais específico (ex.: lista interna em vez da página inteira).
        for ((node, bounds) in candidates.sortedBy { it.second.width() * it.second.height() }) {
            val action = if (forward) AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
                else AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD
            if (node.performAction(action)) return true
        }
        val bounds = candidates.firstOrNull()?.second ?: Rect().also { root.getBoundsInScreen(it) }
        if (bounds.isEmpty) return false
        val x = bounds.exactCenterX()
        val startY = if (forward) bounds.bottom - bounds.height() * 0.2f else bounds.top + bounds.height() * 0.2f
        val endY = if (forward) bounds.top + bounds.height() * 0.2f else bounds.bottom - bounds.height() * 0.2f
        return gesture(x, startY, x, endY, 420)
    }

    private fun tapText(query: String): Boolean {
        val target = query.trim()
        if (target.isEmpty() || target.length > 300) {
            throw IllegalArgumentException("Texto-alvo vazio ou acima de 300 caracteres.")
        }
        val root = rootInActiveWindow ?: return false
        return tapTextInRoot(root, target)
    }

    private fun tapTextInRoot(root: AccessibilityNodeInfo, target: String, allowScreenGesture: Boolean = true): Boolean {
        val targets = target.split('|').map { it.trim() }.filter { it.isNotEmpty() }
        if (targets.isEmpty()) return false

        data class TapCandidate(
            val matchNode: AccessibilityNodeInfo,
            val actionNode: AccessibilityNodeInfo?,
            val exact: Boolean,
            val confidence: Int
        )

        fun nearestClickable(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
            var current: AccessibilityNodeInfo? = node
            var depth = 0
            while (current != null && depth++ <= 24) {
                if (current.isVisibleToUser && current.isEnabled && current.isClickable) return current
                current = current.parent
            }
            return null
        }

        fun identity(node: AccessibilityNodeInfo): String {
            val bounds = Rect()
            node.getBoundsInScreen(bounds)
            return listOf(
                node.windowId.toString(),
                node.viewIdResourceName.orEmpty(),
                node.className?.toString().orEmpty(),
                bounds.flattenToString()
            ).joinToString("|")
        }

        // Several accessibility nodes can expose the same label for one button.
        // Collapse them by their actual clickable ancestor before deciding ambiguity.
        val candidatesByAction = linkedMapOf<String, TapCandidate>()
        fun collect(node: AccessibilityNodeInfo, depth: Int) {
            if (depth > 24) return
            val label = listOf(node.text?.toString(), node.contentDescription?.toString())
                .filterNotNull().joinToString(" ").trim()
            if (node.isVisibleToUser && node.isEnabled && label.isNotEmpty()) {
                val exact = targets.any { label.equals(it, ignoreCase = true) }
                val partial = !exact && targets.any { label.contains(it, ignoreCase = true) }
                if (exact || partial) {
                    val actionNode = nearestClickable(node)
                    val identityNode = actionNode ?: node
                    val confidence = (if (exact) 100 else 70) +
                        (if (actionNode != null) 15 else 0) +
                        (if (!node.viewIdResourceName.isNullOrBlank()) 5 else 0) + 5
                    val key = identity(identityNode)
                    val candidate = TapCandidate(node, actionNode, exact, confidence)
                    val previous = candidatesByAction[key]
                    if (previous == null || candidate.confidence > previous.confidence) {
                        candidatesByAction[key] = candidate
                    }
                }
            }
            for (i in 0 until node.childCount) {
                val child = node.getChild(i) ?: continue
                collect(child, depth + 1)
            }
        }

        collect(root, 0)
        val exactMatches = candidatesByAction.values.filter { it.exact }
        val matches = if (exactMatches.isNotEmpty()) exactMatches else candidatesByAction.values.toList()
        // Never guess between distinct controls with the same visible label.
        if (matches.size != 1) return false

        val selected = matches.single()
        if (selected.confidence < 85) return false
        if (selected.actionNode != null) {
            val actionNode = selected.actionNode
            if (actionNode.windowId != root.windowId ||
                !actionNode.refresh() ||
                !actionNode.isVisibleToUser ||
                !actionNode.isEnabled ||
                !actionNode.isClickable) return false
            if (actionNode.performAction(AccessibilityNodeInfo.ACTION_CLICK)) return true
            // A failed semantic click must not fall through to a coordinate guess
            // when the label was only a partial match.
            if (!selected.exact || !allowScreenGesture) return false
        } else if (!allowScreenGesture || !selected.exact) {
            return false
        }

        val matchNode = selected.matchNode
        if (matchNode.windowId != root.windowId ||
            !matchNode.refresh() ||
            !matchNode.isVisibleToUser ||
            !matchNode.isEnabled) return false
        val bounds = Rect()
        matchNode.getBoundsInScreen(bounds)
        if (bounds.isEmpty) return false
        return gesture(bounds.exactCenterX(), bounds.exactCenterY(),
            bounds.exactCenterX(), bounds.exactCenterY(), 90)
    }

    private fun focusInput(): Boolean {
        val root = rootInActiveWindow ?: return false
        fun currentFocusedEditable(): AccessibilityNodeInfo? {
            val currentRoot = rootInActiveWindow ?: return null
            if (currentRoot.packageName != root.packageName) return null
            return currentRoot.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
                ?.takeIf { it.isEditable && it.isVisibleToUser && it.isEnabled }
        }
        if (currentFocusedEditable() != null) return true

        val candidates = mutableListOf<Pair<AccessibilityNodeInfo, Rect>>()
        fun collect(node: AccessibilityNodeInfo, depth: Int) {
            if (depth > 24) return
            if (node.isVisibleToUser && node.isEnabled && node.isEditable) {
                val bounds = Rect()
                node.getBoundsInScreen(bounds)
                if (!bounds.isEmpty) candidates += node to bounds
            }
            for (i in 0 until node.childCount) {
                val child = node.getChild(i) ?: continue
                collect(child, depth + 1)
            }
        }
        collect(root, 0)
        for ((node, _) in candidates.sortedByDescending { it.second.bottom }) {
            node.performAction(AccessibilityNodeInfo.ACTION_CLICK)
            node.performAction(AccessibilityNodeInfo.ACTION_FOCUS)
            if (currentFocusedEditable() != null) return true
        }
        // A ação de clique pode abrir o teclado e gerar um evento depois.
        // Nunca declare foco só porque ACTION_CLICK/ACTION_FOCUS retornou true.
        return currentFocusedEditable() != null
    }

    private fun typeText(text: String): Boolean {
        if (text.length > 5000) throw IllegalArgumentException("Texto excede 5000 caracteres.")
        val root = rootInActiveWindow
            ?: throw IllegalStateException("Não há janela ativa. O texto não foi digitado.")
        val focused = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
            ?: throw IllegalStateException("Nenhum campo de entrada está realmente focado. O texto não foi digitado.")
        if (!focused.isEditable || !focused.isVisibleToUser || !focused.isEnabled) {
            throw IllegalStateException("O elemento focado não é um campo editável visível. O texto não foi digitado.")
        }
        val focusedPackage = focused.packageName?.toString()
        val rootPackage = root.packageName?.toString()
        if (focusedPackage != null && rootPackage != null && focusedPackage != rootPackage) {
            throw IllegalStateException("O campo focado pertence a outro aplicativo. O texto não foi digitado.")
        }
        val bundle = Bundle().apply { putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text) }
        val accepted = focused.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, bundle)
        if (!accepted) throw IllegalStateException("O Android recusou a inserção no campo focado. O texto não foi digitado.")
        return true
    }


    // Operações por janela usam nós da AccessibilityWindowInfo, sem gestos globais.
    private fun appWindowRoot(packageName: String, windowId: Int? = null): AccessibilityNodeInfo? {
        if (packageName.isBlank()) return null
        val candidates = try { windows } catch (_: Exception) { emptyList() }
        val display = resources.displayMetrics
        val matches = candidates.mapNotNull { window ->
            if (window.type != AccessibilityWindowInfo.TYPE_APPLICATION) return@mapNotNull null
            if (windowId != null && window.id != windowId) return@mapNotNull null
            val root = try { window.root } catch (_: Exception) { null } ?: return@mapNotNull null
            if (root.packageName?.toString() != packageName) return@mapNotNull null
            val bounds = Rect()
            try { window.getBoundsInScreen(bounds) } catch (_: Exception) {}
            if (bounds.isEmpty) return@mapNotNull null
            val coversScreen = bounds.width() >= display.widthPixels * 0.96f &&
                bounds.height() >= display.heightPixels * 0.96f
            if (coversScreen) return@mapNotNull null
            root
        }
        // Sem ID, só aceita uma janela correspondente. Nunca adivinha entre instâncias.
        return matches.singleOrNull()
    }

    private fun appWindowSummaries(): List<Map<String, Any?>> {
        val result = mutableListOf<Map<String, Any?>>()
        val seen = mutableSetOf<String>()
        val candidates = try { windows } catch (_: Exception) { emptyList() }
        for (window in candidates) {
            if (window.type != AccessibilityWindowInfo.TYPE_APPLICATION) continue
            val root = try { window.root } catch (_: Exception) { null } ?: continue
            val packageName = root.packageName?.toString() ?: continue
            val bounds = Rect()
            try { window.getBoundsInScreen(bounds) } catch (_: Exception) {}
            val key = packageName + ":" + window.id
            if (!seen.add(key)) continue
            result += mapOf(
                "package" to packageName,
                "window_id" to window.id,
                "title" to (try { window.title?.toString() } catch (_: Exception) { null }),
                "focused" to window.isFocused,
                "active" to window.isActive,
                "bounds" to mapOf("left" to bounds.left, "top" to bounds.top, "right" to bounds.right, "bottom" to bounds.bottom)
            )
        }
        return result
    }

    private fun listAppWindows(): String {
        val found = appWindowSummaries()
        if (found.isEmpty()) return "Nenhuma janela de aplicativo está acessível no momento."
        return found.joinToString("\n") { item ->
            "APP=" + item["package"] + " janela=" + item["window_id"] + " focada=" + item["focused"] + " ativa=" + item["active"] + " limites=" + item["bounds"]
        }
    }

    private fun readAppWindow(packageName: String, windowId: Int? = null): String {
        val root = appWindowRoot(packageName, windowId)
            ?: return "JANELA_NAO_ENCONTRADA: " + packageName + " não está disponível como janela de aplicativo acessível."
        val output = StringBuilder("APP: " + packageName + "\nJANELA: independente\n")
        var count = 0
        fun walk(node: AccessibilityNodeInfo, depth: Int) {
            if (count >= 160 || depth > 22) return
            val text = node.text?.toString()?.trim().orEmpty()
            val description = node.contentDescription?.toString()?.trim().orEmpty()
            val bounds = Rect()
            node.getBoundsInScreen(bounds)
            if ((text.isNotEmpty() || description.isNotEmpty() || node.isClickable || node.isEditable || node.isScrollable) && !bounds.isEmpty) {
                output.append("ELEMENTO ").append(count + 1)
                    .append(" texto=").append(text.take(240))
                    .append(" descrição=").append(description.take(160))
                    .append(" classe=").append(node.className ?: "")
                    .append(" bounds=").append(bounds.left).append(',').append(bounds.top)
                    .append(',').append(bounds.right).append(',').append(bounds.bottom)
                    .append(" clicável=").append(node.isClickable)
                    .append(" rolável=").append(node.isScrollable)
                    .append(" editável=").append(node.isEditable).append('\n')
                count++
            }
            for (i in 0 until node.childCount) {
                val child = node.getChild(i) ?: continue
                walk(child, depth + 1)
            }
        }
        walk(root, 0)
        if (count == 0) output.append("O aplicativo não expôs elementos acessíveis nesta janela.")
        return output.toString().take(20000)
    }

    private fun tapAppWindowText(packageName: String, text: String, windowId: Int? = null): Boolean {
        val root = appWindowRoot(packageName, windowId)
            ?: throw IllegalStateException("Janela independente não encontrada para " + packageName + ".")
        val target = text.trim()
        if (target.isEmpty() || target.length > 300) throw IllegalArgumentException("Texto-alvo inválido.")
        return tapTextInRoot(root, target, allowScreenGesture = false)
    }

    private fun typeAppWindowText(packageName: String, text: String, windowId: Int? = null): Boolean {
        if (text.length > 5000) throw IllegalArgumentException("Texto excede 5000 caracteres.")
        val root = appWindowRoot(packageName, windowId)
            ?: throw IllegalStateException("Janela independente não encontrada para " + packageName + ".")
        val targets = mutableListOf<AccessibilityNodeInfo>()
        fun collect(node: AccessibilityNodeInfo, depth: Int) {
            if (depth > 24) return
            if (node.isVisibleToUser && node.isEnabled && node.isEditable) targets += node
            for (i in 0 until node.childCount) {
                val child = node.getChild(i) ?: continue
                collect(child, depth + 1)
            }
        }
        collect(root, 0)
        val focused = try { root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) } catch (_: Exception) { null }
        val target = focused?.takeIf { it.isEditable } ?: targets.singleOrNull()
            ?: throw IllegalStateException("A janela " + packageName + " não tem um único campo editável identificável.")
        val bundle = Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
        }
        if (!target.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, bundle)) {
            throw IllegalStateException("O aplicativo recusou ACTION_SET_TEXT na janela " + packageName + ".")
        }
        return true
    }

    private fun scrollAppWindow(packageName: String, direction: String, windowId: Int? = null): Boolean {
        val forward = when (direction.lowercase()) {
            "down", "forward" -> true
            "up", "backward" -> false
            else -> throw IllegalArgumentException("Direção deve ser up ou down.")
        }
        val root = appWindowRoot(packageName, windowId)
            ?: throw IllegalStateException("Janela independente não encontrada para " + packageName + ".")
        val candidates = mutableListOf<Pair<AccessibilityNodeInfo, Rect>>()
        fun collect(node: AccessibilityNodeInfo, depth: Int) {
            if (depth > 24) return
            if (node.isVisibleToUser && node.isScrollable) {
                val bounds = Rect()
                node.getBoundsInScreen(bounds)
                if (!bounds.isEmpty) candidates += node to bounds
            }
            for (i in 0 until node.childCount) {
                val child = node.getChild(i) ?: continue
                collect(child, depth + 1)
            }
        }
        collect(root, 0)
        val action = if (forward) AccessibilityNodeInfo.ACTION_SCROLL_FORWARD else AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD
        for ((node, _) in candidates.sortedBy { it.second.width() * it.second.height() }) {
            if (node.performAction(action)) return true
        }
        return false
    }

    private fun windowCapabilities(): String {
        val freeform = packageManager.hasSystemFeature("android.software.freeform_window_management")
        val freeformEnabled = Settings.Global.getInt(contentResolver, "enable_freeform_support", 0) == 1
        val lowRam = getSystemService(android.app.ActivityManager::class.java)?.isLowRamDevice == true
        val overlay = Build.VERSION.SDK_INT < 23 || Settings.canDrawOverlays(this)
        val display = resources.displayMetrics
        val openWindows = appWindowSummaries()
        val api = Build.VERSION.SDK_INT
        val samsung = Build.MANUFACTURER.equals("samsung", ignoreCase = true)
        val activeWindowAutomation = true // AccessibilityService + window tree/gestures are available on API 29.
        val backgroundVirtualDisplay = api >= Build.VERSION_CODES.S
        val strategy = when {
            samsung && api == Build.VERSION_CODES.Q -> "ANDROID_10_SAMSUNG: AccessibilityService controls the active app; independent popup must be requested through One UI Recent Apps and verified in windows. If popup controls are not accessible, continue in the active app window."
            api == Build.VERSION_CODES.Q -> "ANDROID_10: control the active app with AccessibilityService; independent windows depend on OEM freeform/multi-window support."
            else -> "Use AccessibilityService and verified OEM multi-window/freeform support."
        }
        return "Android API=$api; samsung=$samsung; active_window_accessibility=$activeWindowAutomation; background_virtual_display=$backgroundVirtualDisplay; strategy=$strategy; freeform=$freeform; freeform_enabled=$freeformEnabled; low_ram=$lowRam; overlay_permission=$overlay; split_screen_candidate=${api >= Build.VERSION_CODES.N && !lowRam}; display=${display.widthPixels}x${display.heightPixels}; accessible_app_windows=${openWindows.size}; packages=${openWindows.mapNotNull { it["package"] }.distinct().joinToString(",")}. O fabricante e o sistema definem quantas janelas independentes são aceitas."
    }

    private fun isAlreadyInMultiWindowLayout(): Boolean {
        val display = resources.displayMetrics
        val appWindows = try { windows.filter { it.type == AccessibilityWindowInfo.TYPE_APPLICATION } } catch (_: Exception) { emptyList() }
        if (appWindows.size >= 2) return true
        return appWindows.any { window ->
            val bounds = Rect()
            try { window.getBoundsInScreen(bounds) } catch (_: Exception) {}
            !bounds.isEmpty && (bounds.width() < display.widthPixels * 0.96f ||
                bounds.height() < display.heightPixels * 0.96f)
        }
    }

    private fun openAppWindow(packageName: String): String {
        if (packageName.isBlank() || packageName.length > 200) {
            throw IllegalArgumentException("Pacote inválido.")
        }
        val launch = packageManager.getLaunchIntentForPackage(packageName)
            ?: return "ERRO: aplicativo não instalado ou sem atividade inicializável: $packageName"
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            // One UI exposes pop-up view through the app card's Recentes menu.
            // launchBounds/freeform flags do not reliably invoke Samsung's native pop-up UI.
            if (Build.MANUFACTURER.equals("samsung", ignoreCase = true)) {
                startActivity(launch)
                mainHandler.postDelayed({
                    if (active === this) performGlobalAction(GLOBAL_ACTION_RECENTS)
                }, 450L)
                return "SAMSUNG_RECENTS_ABERTO: o aplicativo $packageName foi iniciado e a tela Recentes será aberta. Leia a tela com phone_screen_read, localize o cartão/ícone desse aplicativo, toque no ícone para abrir o menu e selecione 'Abrir na exibição pop-up' (também pode aparecer como 'Abrir em exibição pop-up' ou 'Abrir em pop-up'). Depois leia novamente a tela e confirme a janela com phone_window_list. Não use toques por coordenadas."
            }
            launch.addFlags(Intent.FLAG_ACTIVITY_MULTIPLE_TASK)
            val options = ActivityOptions.makeBasic()
            val metrics = resources.displayMetrics
            val width = metrics.widthPixels
            val height = metrics.heightPixels
            val freeform = packageManager.hasSystemFeature("android.software.freeform_window_management")
            val freeformEnabled = Settings.Global.getInt(contentResolver, "enable_freeform_support", 0) == 1
            val existingMultiWindow = Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && isAlreadyInMultiWindowLayout()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && freeform && (freeformEnabled || existingMultiWindow)) {
                val windowWidth = (width * 0.78f).toInt().coerceAtLeast(320)
                val windowHeight = (height * 0.62f).toInt().coerceAtLeast(420)
                val left = ((width - windowWidth) / 2).coerceAtLeast(0)
                val top = (height * 0.12f).toInt().coerceAtLeast(0)
                options.launchBounds = Rect(left, top, left + windowWidth, top + windowHeight)
                startActivity(launch, options.toBundle())
                "PEDIDO_JANELA_LIVRE_ENVIADO: $packageName. Confirme a criação real com phone_window_list."
            } else if (existingMultiWindow) {
                launch.addFlags(Intent.FLAG_ACTIVITY_LAUNCH_ADJACENT)
                startActivity(launch, options.toBundle())
                "PEDIDO_JANELA_ADJACENTE_ENVIADO: $packageName. Confirme a janela independente com phone_window_list."
            } else {
                "JANELA_FLUTUANTE_NAO_CONFIRMADA: este Android não expôs um mecanismo de janela independente. Nenhuma falsa confirmação foi emitida."
            }
        } catch (error: Exception) {
            throw IllegalStateException("Não foi possível solicitar uma janela para " + packageName + ": " + error.message)
        }
    }

    private fun normalizeAppLabel(value: String): String {
        return java.text.Normalizer.normalize(value.trim(), java.text.Normalizer.Form.NFD)
            .replace(Regex("\\p{Mn}+"), "").lowercase(java.util.Locale.ROOT)
            .replace(Regex("[^a-z0-9]+"), "")
    }

    private fun openApp(packageNameOrLabel: String): String {
        if (packageNameOrLabel.isBlank() || packageNameOrLabel.length > 200) throw IllegalArgumentException("Nome/pacote inválido.")
        val launchers = packageManager.queryIntentActivities(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER), 0)
            .map { it.activityInfo.applicationInfo to it.activityInfo.packageName }.distinctBy { it.second }
        val byPackage = launchers.firstOrNull { it.second.equals(packageNameOrLabel.trim(), true) }
        val query = normalizeAppLabel(packageNameOrLabel)
        val exact = launchers.filter { normalizeAppLabel(it.first.loadLabel(packageManager).toString()) == query }
        val fuzzy = if (exact.isEmpty()) launchers.filter {
            val label = normalizeAppLabel(it.first.loadLabel(packageManager).toString())
            label.contains(query) || query.contains(label)
        } else emptyList()
        val chosen = when {
            byPackage != null -> byPackage
            exact.size == 1 -> exact.single()
            exact.size > 1 -> throw IllegalStateException("Nome de aplicativo ambíguo; candidatos: " + exact.joinToString { it.first.loadLabel(packageManager).toString() + " (" + it.second + ")" })
            fuzzy.size == 1 -> fuzzy.single()
            fuzzy.isNotEmpty() -> throw IllegalStateException("Nome de aplicativo ambíguo; candidatos: " + fuzzy.joinToString { it.first.loadLabel(packageManager).toString() + " (" + it.second + ")" })
            else -> throw IllegalStateException("Não encontrei aplicativo instalado/inicializável com nome ou pacote: $packageNameOrLabel")
        }
        val label = chosen.first.loadLabel(packageManager).toString()
        val packageId = chosen.second
        val launch = packageManager.getLaunchIntentForPackage(packageId)
            ?: throw IllegalStateException("O app $label ($packageId) não tem intent de lançamento.")
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(launch)
        return "APP_OPEN_DISPATCHED: nome=$label pacote=$packageId; confirme pela leitura da tela."
    }
}