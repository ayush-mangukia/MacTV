package com.example.mactv_androidapp

import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity

/** Debug-only host for synthetic Compose layouts, including while the phone is locked.
 * Contains no connection or user data. This does not unlock or dismiss secure keyguard.
 */
class LayoutTestActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        setShowWhenLocked(true)
        setTurnScreenOn(true)
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }
}
