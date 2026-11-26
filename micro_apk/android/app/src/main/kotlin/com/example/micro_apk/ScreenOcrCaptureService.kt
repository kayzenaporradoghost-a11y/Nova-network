package com.example.micro_apk

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.Image
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.ResultReceiver
import java.io.File

class ScreenOcrCaptureService : Service() {
    companion object {
        const val EXTRA_RESULT_CODE = "result_code"
        const val EXTRA_DATA = "result_data"
        const val EXTRA_RECEIVER = "result_receiver"
        private const val CHANNEL_ID = "network_screen_ocr"
        private const val NOTIFICATION_ID = 4199
    }

    private val handler = Handler(Looper.getMainLooper())
    private var projection: MediaProjection? = null
    private var display: VirtualDisplay? = null
    private var reader: ImageReader? = null
    private var receiver: ResultReceiver? = null
    private var startedAt = 0L
    private var finished = false

    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Leitura OCR da tela",
                NotificationManager.IMPORTANCE_LOW
            )
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        receiver = intent?.getParcelableExtra(EXTRA_RECEIVER)
        try {
            val resultCode = intent?.getIntExtra(EXTRA_RESULT_CODE, 0) ?: 0
            @Suppress("DEPRECATION")
            val data = intent?.getParcelableExtra<Intent>(EXTRA_DATA)
                ?: throw IllegalArgumentException("Dados de autorização de captura ausentes.")
            if (resultCode != Activity.RESULT_OK) throw SecurityException("Autorização de captura inválida.")

            val notification = notification()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }

            val manager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            projection = manager.getMediaProjection(resultCode, data)
                ?: throw IllegalStateException("O Android não disponibilizou a projeção de mídia.")

            projection?.registerCallback(object : MediaProjection.Callback() {
                override fun onStop() {
                    finishWithError("A autorização de captura foi encerrada pelo Android.")
                }
            }, handler)

            val metrics = resources.displayMetrics
            val width = metrics.widthPixels.coerceAtLeast(1)
            val height = metrics.heightPixels.coerceAtLeast(1)
            reader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 2)
            display = projection?.createVirtualDisplay(
                "NETWORK-screen-ocr",
                width,
                height,
                metrics.densityDpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                reader!!.surface,
                null,
                handler
            ) ?: throw IllegalStateException("Não foi possível criar a tela virtual para OCR.")

            startedAt = System.currentTimeMillis()
            handler.postDelayed(::captureFrame, 350)
        } catch (error: Exception) {
            finishWithError(error.message ?: "Falha ao iniciar a captura OCR.")
        }
        return START_NOT_STICKY
    }

    private fun captureFrame() {
        if (finished) return
        val image = try { reader?.acquireLatestImage() } catch (_: Exception) { null }
        if (image == null && System.currentTimeMillis() - startedAt < 2500) {
            handler.postDelayed(::captureFrame, 150)
            return
        }
        if (image == null) {
            finishWithError("O Android não entregou um quadro da tela.")
            return
        }
        try {
            val path = saveImage(image)
            receiver?.send(Activity.RESULT_OK, Bundle().apply { putString("path", path) })
            finish()
        } catch (error: Exception) {
            finishWithError(error.message ?: "Falha ao salvar a imagem para OCR.")
        } finally {
            image.close()
        }
    }

    private fun saveImage(image: Image): String {
        val plane = image.planes.firstOrNull()
            ?: throw IllegalStateException("O quadro da tela não contém pixels.")
        val pixelStride = plane.pixelStride
        val rowStride = plane.rowStride
        if (pixelStride <= 0 || rowStride <= 0) throw IllegalStateException("Formato de imagem inválido.")
        val width = image.width
        val height = image.height
        val paddedWidth = rowStride / pixelStride
        val bitmap = Bitmap.createBitmap(paddedWidth, height, Bitmap.Config.ARGB_8888)
        bitmap.copyPixelsFromBuffer(plane.buffer)
        val cropped = Bitmap.createBitmap(bitmap, 0, 0, width, height)
        val output = File(cacheDir, "network_screen_${System.currentTimeMillis()}.png")
        output.outputStream().use { stream ->
            if (!cropped.compress(Bitmap.CompressFormat.PNG, 100, stream)) {
                throw IllegalStateException("Falha ao codificar a imagem da tela.")
            }
        }
        if (cropped !== bitmap) cropped.recycle()
        bitmap.recycle()
        return output.absolutePath
    }

    private fun notification(): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("NETWORK")
            .setContentText("Lendo a tela para reconhecer texto")
            .setSmallIcon(android.R.drawable.ic_menu_view)
            .setOngoing(true)
            .build()
    }

    private fun finishWithError(message: String) {
        if (finished) return
        receiver?.send(Activity.RESULT_CANCELED, Bundle().apply { putString("error", message) })
        finish()
    }

    private fun finish() {
        if (finished) return
        finished = true
        handler.removeCallbacksAndMessages(null)
        try { display?.release() } catch (_: Exception) {}
        display = null
        try { reader?.close() } catch (_: Exception) {}
        reader = null
        try { projection?.stop() } catch (_: Exception) {}
        projection = null
        receiver = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) stopForeground(STOP_FOREGROUND_REMOVE)
        else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    override fun onDestroy() {
        if (!finished) finish()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
