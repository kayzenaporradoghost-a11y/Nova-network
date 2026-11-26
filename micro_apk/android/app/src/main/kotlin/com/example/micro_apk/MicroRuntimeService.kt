package com.example.micro_apk

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import java.io.File

class MicroRuntimeService : Service() {
    companion object {
        const val ACTION_START = "micro.runtime.START"
        const val ACTION_STOP = "micro.runtime.STOP"
        const val ACTION_AGENT_START = "micro.runtime.AGENT_START"
        const val ACTION_AGENT_STOP = "micro.runtime.AGENT_STOP"
        const val EXTRA_PREFIX = "prefix"
        private const val CHANNEL_ID = "micro_ollama"
        private const val NOTIFICATION_ID = 4102
    }
    private var process: Process? = null
    private var agentKeepAlive = false

    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(CHANNEL_ID, "Serviço em segundo plano", NotificationManager.IMPORTANCE_LOW)
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                process?.destroy()
                process = null
                agentKeepAlive = false
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_AGENT_START -> {
                agentKeepAlive = true
                startForeground(NOTIFICATION_ID, notification("NETWORK está executando sua tarefa"))
            }
            ACTION_AGENT_STOP -> {
                agentKeepAlive = false
                if (process == null) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                    return START_NOT_STICKY
                }
            }
            ACTION_START -> {
                startForeground(NOTIFICATION_ID, notification("NETWORK · runtime local ativo"))
                val prefix = intent.getStringExtra(EXTRA_PREFIX) ?: return START_NOT_STICKY
                startOllama(prefix)
            }
        }
        return START_STICKY
    }

    private fun notification(message: String): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) Notification.Builder(this, CHANNEL_ID) else Notification.Builder(this)
        return builder.setContentTitle("NETWORK").setContentText(message).setSmallIcon(android.R.drawable.stat_sys_download_done).setOngoing(true).build()
    }

    private fun startOllama(prefix: String) {
        process?.destroy()
        val root = File(prefix)
        val binary = File(root, "bin/ollama")
        if (!binary.exists()) { stopSelf(); return }
        binary.setExecutable(true)
        File(root, "lib/ollama/llama-server").setExecutable(true)
        val log = File(filesDir, "ollama-runtime.log")
        val env = mapOf(
            "HOME" to filesDir.absolutePath,
            "PREFIX" to root.absolutePath,
            "OLLAMA_MODELS" to File(filesDir, "models").absolutePath,
            "OLLAMA_HOST" to "127.0.0.1:11434",
            // Flag solicitada para o processo de inferência local.
            "DESABLITERATE" to "1",
            "LD_LIBRARY_PATH" to "/system/lib64:${File(root, "lib").absolutePath}:${File(root, "lib/ollama").absolutePath}",
            "OLLAMA_LIBRARY_PATH" to File(root, "lib/ollama").absolutePath,
            "PATH" to "${File(root, "bin").absolutePath}:/system/bin:/system/xbin"
        )
        try {
            val builder = ProcessBuilder(binary.absolutePath, "serve").directory(root).redirectErrorStream(true).redirectOutput(log)
            builder.environment().putAll(env)
            process = builder.start()
        } catch (_: Exception) { stopSelf() }
    }

    override fun onDestroy() { process?.destroy(); process = null; super.onDestroy() }
    override fun onBind(intent: Intent?): IBinder? = null
}