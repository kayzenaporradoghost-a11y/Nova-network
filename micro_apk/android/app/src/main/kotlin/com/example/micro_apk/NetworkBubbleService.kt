package com.example.micro_apk

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Build
import android.os.IBinder
import android.animation.ValueAnimator
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.view.animation.LinearInterpolator
import android.widget.TextView

class NetworkBubbleService : Service() {
    companion object {
        const val ACTION_VOICE_TOGGLE = "com.example.micro_apk.NETWORK_VOICE_TOGGLE"
        const val ACTION_BUBBLE_STATE = "com.example.micro_apk.NETWORK_BUBBLE_STATE"
        private const val CHANNEL_ID = "network_floating_assistant"
        private const val NOTIFICATION_ID = 7410
    }

    private var windowManager: WindowManager? = null
    private var bubble: TextView? = null
    private var pulse: ValueAnimator? = null
    private var tone: ToneGenerator? = null
    private var listening = false
    private var working = false
    private var speaking = false

    private val stateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.getStringExtra("state")) {
                "listening" -> { listening = true; working = false; speaking = false; animateState() }
                "working" -> { listening = false; working = true; speaking = false; animateState() }
                "speaking" -> { listening = false; working = false; speaking = true; animateState() }
                "idle" -> { listening = false; working = false; speaking = false; animateState() }
                "done" -> { listening = false; working = false; speaking = false; animateState() }
                "error" -> { listening = false; working = false; speaking = false; animateState() }
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification())
        val stateFilter = IntentFilter(ACTION_BUBBLE_STATE)
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(stateReceiver, stateFilter, Context.RECEIVER_NOT_EXPORTED)
        else registerReceiver(stateReceiver, stateFilter)
        showBubble()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (bubble == null) showBubble()
        return START_STICKY
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(CHANNEL_ID, "NETWORK flutuante", NotificationManager.IMPORTANCE_LOW)
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) Notification.Builder(this, CHANNEL_ID) else Notification.Builder(this)
        return builder.setContentTitle("NETWORK pronto para ouvir")
            .setContentText("Toque na bolinha para falar com a IA. Não abre a tela do aplicativo.")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setOngoing(true)
            .build()
    }

    private fun showBubble() {
        if (Build.VERSION.SDK_INT >= 23 && !android.provider.Settings.canDrawOverlays(this)) {
            stopSelf()
            return
        }
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
        val view = TextView(this).apply {
            text = "N"
            textSize = 21f
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
            typeface = android.graphics.Typeface.DEFAULT_BOLD
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(Color.BLACK)
                setStroke(3, Color.WHITE)
            }
            elevation = 14f
            contentDescription = "Toque para falar com NETWORK"
        }
        val overlayType = if (Build.VERSION.SDK_INT >= 26) WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY else WindowManager.LayoutParams.TYPE_PHONE
        val layout = WindowManager.LayoutParams(
            dp(58), dp(58), overlayType,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = dp(14)
            y = dp(260)
        }
        var downX = 0f
        var downY = 0f
        var startX = 0
        var startY = 0
        var moved = false
        view.setOnTouchListener { _, event ->
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    downX = event.rawX; downY = event.rawY
                    startX = layout.x; startY = layout.y; moved = false
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = (event.rawX - downX).toInt()
                    val dy = (event.rawY - downY).toInt()
                    if (kotlin.math.abs(dx) > dp(5) || kotlin.math.abs(dy) > dp(5)) moved = true
                    if (moved) {
                        layout.x = (startX + dx).coerceAtLeast(0)
                        layout.y = (startY + dy).coerceAtLeast(0)
                        windowManager?.updateViewLayout(view, layout)
                    }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    if (!moved) {
                        sendBroadcast(Intent(ACTION_VOICE_TOGGLE).setPackage(packageName).putExtra("event", "toggle"))
                        playTone(if (listening) ToneGenerator.TONE_PROP_ACK else ToneGenerator.TONE_PROP_PROMPT, 100)
                    }
                    true
                }
                else -> true
            }
        }
        try {
            windowManager?.addView(view, layout)
            bubble = view
            animateState()
        } catch (_: Exception) { stopSelf() }
    }

    private fun animateState() {
        val view = bubble ?: return
        pulse?.cancel()
        (view.background as? GradientDrawable)?.setColor(Color.BLACK)
        (view.background as? GradientDrawable)?.setStroke(3, Color.WHITE)
        if (listening || working || speaking) {
            pulse = ValueAnimator.ofFloat(1f, if (listening) 1.20f else 1.10f).apply {
                duration = if (listening) 520 else if (speaking) 680 else 850
                repeatMode = ValueAnimator.REVERSE
                repeatCount = ValueAnimator.INFINITE
                interpolator = LinearInterpolator()
                addUpdateListener {
                    val scale = it.animatedValue as Float
                    view.scaleX = scale
                    view.scaleY = scale
                }
                start()
            }
        } else {
            view.scaleX = 1f; view.scaleY = 1f
        }
        view.contentDescription = when {
            listening -> "NETWORK está ouvindo. Toque para parar."
            working -> "NETWORK está processando seu comando."
            speaking -> "NETWORK está respondendo por voz."
            else -> "Toque para falar com NETWORK."
        }
    }

    private fun playTone(toneType: Int, duration: Int) {
        try {
            if (tone == null) tone = ToneGenerator(AudioManager.STREAM_NOTIFICATION, 75)
            tone?.startTone(toneType, duration)
        } catch (_: Exception) {}
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    override fun onDestroy() {
        pulse?.cancel()
        try { unregisterReceiver(stateReceiver) } catch (_: Exception) {}
        try { bubble?.let { windowManager?.removeView(it) } } catch (_: Exception) {}
        tone?.release()
        bubble = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
