package com.nativOS.launcher

import android.graphics.Bitmap
import android.graphics.Rect
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.PixelCopy
import android.view.SurfaceView
import android.view.View

/**
 * Detects the current blank black Phosh home visually, without root commands or
 * guessing from taps. Copies only a small in-memory image of our own surface;
 * nothing is saved or transmitted. This is not a semantic Wayland focus API:
 * an entirely black fullscreen app can look identical to the blank home.
 */
internal class BlackHomeObserver(
    private val surface: SurfaceView,
    private val dock: View,
    private val handleCover: View,
    private val homeStatusBar: View,
    private var contentHeight: Int,
    private val isDesktopVisible: () -> Boolean
) {
    private val handler = Handler(Looper.getMainLooper())
    private var running = false
    private var pending = false
    private var blackFrames = 0
    private var suppressedUntil = 0L
    private val tick = Runnable { sample() }

    fun start() {
        if (running) return
        running = true
        handler.post(tick)
    }

    fun stop() {
        running = false
        handler.removeCallbacks(tick)
        showDock(false)
    }

    fun suppressTemporarily() {
        suppressedUntil = SystemClock.elapsedRealtime() + 1200
        blackFrames = 0
        showDock(false)
    }

    fun updateContentHeight(height: Int) {
        contentHeight = height
        suppressTemporarily()
    }

    /** One state update controls both surfaces; never leave a stale cover. */
    private fun showDock(visible: Boolean) {
        val visibility = if (visible) View.VISIBLE else View.GONE
        handleCover.visibility = visibility
        dock.visibility = visibility
        homeStatusBar.visibility = visibility
        if (visible) {
            handleCover.bringToFront()
            dock.bringToFront()
            homeStatusBar.bringToFront()
        }
    }

    private fun schedule() {
        if (running) handler.postDelayed(tick, 500)
    }

    private fun sample() {
        if (!running || pending) return
        if (!isDesktopVisible() || !surface.holder.surface.isValid ||
            SystemClock.elapsedRealtime() < suppressedUntil) {
            blackFrames = 0
            showDock(false)
            schedule()
            return
        }
        // Exclude Phosh's top clock/status panel and bottom gesture handle.
        // The Android three-dot control and dock are separate views and do not
        // appear in a PixelCopy of the Linux surface.
        val density = surface.resources.displayMetrics.density
        // The nested output can initially be shorter than the Android surface
        // while transient system bars disappear. Its handle must still remain
        // outside the sample rather than being mistaken for home content.
        val crop = Rect(0, (32 * density).toInt(), surface.width,
            minOf(surface.height, contentHeight) - (24 * density).toInt())
        if (crop.width() <= 0 || crop.height() <= 0) {
            blackFrames = 0
            showDock(false)
            schedule()
            return
        }
        val bitmap = Bitmap.createBitmap(96, 192, Bitmap.Config.ARGB_8888)
        pending = true
        try {
            PixelCopy.request(surface, crop, bitmap, { result ->
                pending = false
                if (running) {
                    val pixels = IntArray(bitmap.width * bitmap.height)
                    if (result == PixelCopy.SUCCESS) bitmap.getPixels(
                        pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
                    val blank = result == PixelCopy.SUCCESS && pixels.all {
                        ((it shr 16) and 255) <= 8 && ((it shr 8) and 255) <= 8 && (it and 255) <= 8
                    }
                    blackFrames = if (blank) blackFrames + 1 else 0
                    showDock(blackFrames >= 2 && isDesktopVisible() &&
                        SystemClock.elapsedRealtime() >= suppressedUntil)
                    schedule()
                }
                bitmap.recycle()
            }, handler)
        } catch (_: IllegalArgumentException) {
            pending = false
            bitmap.recycle()
            blackFrames = 0
            showDock(false)
            schedule()
        }
    }
}
