package com.example.mactv_androidapp

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.drawable.AdaptiveIconDrawable
import android.graphics.drawable.ColorDrawable
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import org.junit.Assert.*
import org.junit.Test

class LauncherIconTest {
    @Test fun themedMonogramKeepsNegativeSpaceAndRendersOnBlue() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val icon = context.getDrawable(R.mipmap.ic_launcher) as AdaptiveIconDrawable
        val mono = requireNotNull(icon.monochrome)
        val mask = Bitmap.createBitmap(108, 108, Bitmap.Config.ARGB_8888)
        mono.setBounds(0, 0, 108, 108); mono.draw(Canvas(mask))
        assertEquals("The M opening must stay transparent under themed tint", 0, Color.alpha(mask.getPixel(45, 70)))
        assertTrue("M stem missing", Color.alpha(mask.getPixel(35, 54)) > 200)
        assertTrue("Play symbol missing", Color.alpha(mask.getPixel(74, 54)) > 200)
        for (themed in listOf(false, true)) {
            val bitmap = Bitmap.createBitmap(432,432,Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            if (themed) {
                mono.setTint(Color.BLACK)
                val themedIcon = AdaptiveIconDrawable(ColorDrawable(Color.rgb(46,126,212)), mono)
                themedIcon.setBounds(0,0,432,432); themedIcon.draw(canvas)
            } else { icon.setBounds(0,0,432,432); icon.draw(canvas) }
            File(context.getExternalFilesDir(null), if (themed) "launcher-icon-themed.png" else "launcher-icon-color.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG,100,it) }
        }
    }
}
