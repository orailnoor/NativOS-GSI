package com.nativOS.launcher

import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorFilter
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.drawable.Drawable

/** Density-independent dock artwork; no font glyphs or raster dependencies. */
internal class DockIcon(private val kind: Kind) : Drawable() {
    enum class Kind { APPS, BACK }
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)

    override fun draw(canvas: Canvas) {
        val save = canvas.save()
        canvas.translate(bounds.left.toFloat(), bounds.top.toFloat())
        canvas.scale(bounds.width() / 40f, bounds.height() / 40f)
        paint.style = Paint.Style.FILL
        paint.color = if (kind == Kind.APPS) Color.rgb(83, 135, 240) else Color.rgb(84, 95, 115)
        canvas.drawRoundRect(1f, 1f, 39f, 39f, 10f, 10f, paint)
        paint.color = Color.WHITE
        if (kind == Kind.APPS) {
            for (row in 0..2) for (column in 0..2) {
                val x = 9f + column * 8f
                val y = 9f + row * 8f
                canvas.drawRoundRect(x, y, x + 6f, y + 6f, 1.8f, 1.8f, paint)
            }
        } else {
            paint.style = Paint.Style.STROKE
            paint.strokeWidth = 3f
            paint.strokeCap = Paint.Cap.ROUND
            paint.strokeJoin = Paint.Join.ROUND
            canvas.drawLine(11f, 20f, 28f, 20f, paint)
            canvas.drawLine(11f, 20f, 19f, 12f, paint)
            canvas.drawLine(11f, 20f, 19f, 28f, paint)
        }
        canvas.restoreToCount(save)
    }

    override fun setAlpha(alpha: Int) { paint.alpha = alpha; invalidateSelf() }
    override fun setColorFilter(filter: ColorFilter?) { paint.colorFilter = filter; invalidateSelf() }
    @Deprecated("Drawable opacity")
    override fun getOpacity(): Int = PixelFormat.TRANSLUCENT
}
