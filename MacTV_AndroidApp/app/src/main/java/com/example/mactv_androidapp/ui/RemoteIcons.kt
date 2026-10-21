package com.example.mactv_androidapp.ui

import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.PathBuilder
import androidx.compose.ui.graphics.vector.path
import androidx.compose.ui.unit.dp

enum class Glyph { REMOTE, DEVICES, SETTINGS, UP, DOWN, LEFT, RIGHT, HOME, BACK,
    PLAY, PREVIOUS, NEXT, PLUS, MINUS, MUTE, TOUCH, KEYBOARD, QR, LINK, CHECK, SEND }

private fun vector(name: String, block: PathBuilder.() -> Unit) =
    ImageVector.Builder(name, 24.dp, 24.dp, 24f, 24f).apply {
        path(fill = null, stroke = SolidColor(Color.White), strokeLineWidth = 1.7f,
            strokeLineCap = StrokeCap.Round, strokeLineJoin = StrokeJoin.Round, pathBuilder = block)
    }.build()

private val vectors = Glyph.entries.associateWith { glyph ->
    vector(glyph.name) {
        when (glyph) {
            Glyph.UP -> { moveTo(7f,14f); lineTo(12f,9f); lineTo(17f,14f) }
            Glyph.DOWN -> { moveTo(7f,10f); lineTo(12f,15f); lineTo(17f,10f) }
            Glyph.LEFT -> { moveTo(14f,7f); lineTo(9f,12f); lineTo(14f,17f) }
            Glyph.RIGHT -> { moveTo(10f,7f); lineTo(15f,12f); lineTo(10f,17f) }
            Glyph.HOME -> { moveTo(3f,11f); lineTo(12f,3f); lineTo(21f,11f)
                moveTo(5f,10f); lineTo(5f,21f); lineTo(10f,21f); lineTo(10f,15f)
                lineTo(14f,15f); lineTo(14f,21f); lineTo(19f,21f); lineTo(19f,10f) }
            Glyph.BACK -> { moveTo(9f,5f); lineTo(3f,11f); lineTo(9f,17f)
                moveTo(3f,11f); lineTo(15f,11f); curveTo(22f,11f,22f,20f,15f,20f) }
            Glyph.PLAY -> { moveTo(5f,5f); lineTo(5f,19f); lineTo(14f,12f); close()
                moveTo(18f,6f); lineTo(18f,18f); moveTo(22f,6f); lineTo(22f,18f) }
            Glyph.PREVIOUS -> { moveTo(6f,5f); lineTo(6f,19f); moveTo(19f,5f)
                lineTo(9f,12f); lineTo(19f,19f); close() }
            Glyph.NEXT -> { moveTo(18f,5f); lineTo(18f,19f); moveTo(5f,5f)
                lineTo(15f,12f); lineTo(5f,19f); close() }
            Glyph.PLUS -> { moveTo(5f,12f); lineTo(19f,12f); moveTo(12f,5f); lineTo(12f,19f) }
            Glyph.MINUS -> { moveTo(5f,12f); lineTo(19f,12f) }
            Glyph.MUTE -> { moveTo(11f,4f); lineTo(6f,9f); lineTo(3f,9f); lineTo(3f,15f)
                lineTo(6f,15f); lineTo(11f,20f); close()
                moveTo(16f,9f); lineTo(22f,15f); moveTo(22f,9f); lineTo(16f,15f) }
            Glyph.DEVICES -> { moveTo(3f,4f); lineTo(21f,4f); lineTo(21f,17f)
                lineTo(3f,17f); close(); moveTo(8f,21f); lineTo(16f,21f)
                moveTo(12f,17f); lineTo(12f,21f) }
            Glyph.REMOTE -> { moveTo(8f,2f); lineTo(16f,2f); quadTo(19f,2f,19f,5f)
                lineTo(19f,19f); quadTo(19f,22f,16f,22f); lineTo(8f,22f)
                quadTo(5f,22f,5f,19f); lineTo(5f,5f); quadTo(5f,2f,8f,2f)
                moveTo(9f,8f); lineTo(15f,8f); moveTo(12f,5f); lineTo(12f,11f)
                moveTo(9f,16f); lineTo(10f,16f); moveTo(14f,16f); lineTo(15f,16f) }
            Glyph.SETTINGS -> { moveTo(4f,7f); lineTo(20f,7f); moveTo(4f,17f); lineTo(20f,17f)
                moveTo(9f,4f); lineTo(9f,10f); moveTo(15f,14f); lineTo(15f,20f) }
            Glyph.TOUCH -> { moveTo(8f,12f); lineTo(8f,5f); curveTo(8f,2f,12f,2f,12f,5f)
                lineTo(12f,11f); curveTo(20f,9f,21f,13f,19f,18f)
                lineTo(17f,22f); lineTo(10f,22f); lineTo(4f,15f); quadTo(2f,11f,5f,12f); lineTo(8f,15f) }
            Glyph.KEYBOARD -> { moveTo(2f,5f); lineTo(22f,5f); lineTo(22f,19f); lineTo(2f,19f); close()
                moveTo(6f,9f); lineTo(6.1f,9f); moveTo(10f,9f); lineTo(10.1f,9f)
                moveTo(14f,9f); lineTo(14.1f,9f); moveTo(18f,9f); lineTo(18.1f,9f)
                moveTo(6f,13f); lineTo(6.1f,13f); moveTo(10f,13f); lineTo(18f,13f)
                moveTo(7f,16f); lineTo(17f,16f) }
            Glyph.QR -> { moveTo(3f,3f); lineTo(9f,3f); lineTo(9f,9f); lineTo(3f,9f); close()
                moveTo(15f,3f); lineTo(21f,3f); lineTo(21f,9f); lineTo(15f,9f); close()
                moveTo(3f,15f); lineTo(9f,15f); lineTo(9f,21f); lineTo(3f,21f); close()
                moveTo(15f,15f); lineTo(18f,15f); lineTo(18f,18f); lineTo(21f,18f); lineTo(21f,21f)
                moveTo(15f,19f); lineTo(15f,21f) }
            Glyph.LINK -> { moveTo(9f,8f); lineTo(12f,5f); curveTo(18f,-1f,25f,6f,19f,12f)
                lineTo(16f,15f); moveTo(15f,16f); lineTo(12f,19f); curveTo(6f,25f,-1f,18f,5f,12f)
                lineTo(8f,9f); moveTo(8f,16f); lineTo(16f,8f) }
            Glyph.CHECK -> { moveTo(5f,12f); lineTo(10f,17f); lineTo(20f,7f) }
            Glyph.SEND -> { moveTo(3f,3f); lineTo(22f,12f); lineTo(3f,21f); lineTo(6f,12f); close()
                moveTo(6f,12f); lineTo(22f,12f) }
        }
    }
}

@Composable
fun RemoteIcon(glyph: Glyph, modifier: Modifier = Modifier, tint: Color = Color.Unspecified) {
    Icon(vectors.getValue(glyph), contentDescription = null, modifier = modifier, tint = tint)
}
