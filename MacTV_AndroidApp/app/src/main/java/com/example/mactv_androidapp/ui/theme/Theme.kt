package com.example.mactv_androidapp.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

val Amber = Color(0xFFEBC18A)
val Ink = Color(0xFF101113)
val Panel = Color(0xFF1B1D20)
val Muted = Color(0xFF94979F)
val Outline = Color(0xFF303237)

private val RemoteColors = darkColorScheme(
    primary = Amber, onPrimary = Ink,
    secondary = Color(0xFFD9DFE8),
    background = Ink, onBackground = Color(0xFFF4F2EF),
    surface = Panel, onSurface = Color(0xFFF4F2EF),
    surfaceVariant = Color(0xFF25272B), onSurfaceVariant = Muted,
    outline = Outline
)

@Composable
fun MacTV_AndroidAppTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = RemoteColors, typography = Typography, content = content)
}
