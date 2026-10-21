package com.example.mactv_androidapp

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.lifecycle.ViewModelProvider
import com.example.mactv_androidapp.ui.MacTVRemoteApp
import com.example.mactv_androidapp.ui.theme.MacTV_AndroidAppTheme

class MainActivity : ComponentActivity() {
    private val remote by lazy { ViewModelProvider(this)[com.example.mactv_androidapp.ui.RemoteViewModel::class.java] }
    override fun onStart() { super.onStart(); remote.resume() }
    override fun onStop() { remote.suspendConnection(); super.onStop() }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT)
        )
        window.isNavigationBarContrastEnforced = false
        setContent {
            MacTV_AndroidAppTheme { MacTVRemoteApp(remote) }
        }
    }
}
