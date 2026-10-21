package com.example.mactv_androidapp

import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.test.platform.app.InstrumentationRegistry
import android.graphics.Bitmap
import java.io.File
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.activity.ComponentActivity
import android.view.WindowManager
import org.junit.Before
import com.example.mactv_androidapp.command.*
import com.example.mactv_androidapp.connection.*
import com.example.mactv_androidapp.ui.*
import com.example.mactv_androidapp.ui.theme.MacTV_AndroidAppTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

/** Real Compose controls, with context injected; never dispatches desktop input. */
class ContextControlsTest {
    @get:Rule val compose = createAndroidComposeRule<LayoutTestActivity>()
    @Before fun prepareTestWindow() {
        compose.runOnUiThread {
            compose.activity.setShowWhenLocked(true)
            compose.activity.setTurnScreenOn(true)
            compose.activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }
    @Test fun switchingAppsReplacesActionsAndSubtitleButtonSendsTheRightCommand() {
        val context = mutableStateOf(AppContext("spotify", "Spotify", setOf("app_search")))
        val sent = mutableListOf<RemoteCommand>()
        compose.setContent {
            MacTV_AndroidAppTheme {
                RemoteAppContent(RemoteUiState(appContext = context.value), send = { sent.add(it) })
            }
        }
        compose.onNodeWithText("Search Spotify").performScrollTo().assertIsDisplayed().performClick()
        compose.runOnIdle { assertEquals(RemoteCommand.Press(RemoteKey.APP_SEARCH), sent.last()) }
        compose.runOnIdle { context.value = AppContext("player", "Test movie", setOf("subtitles", "restart"), subtitle = "English") }
        compose.onNodeWithText("Search Spotify").assertDoesNotExist()
        compose.onNodeWithText("Subtitles", useUnmergedTree = true).performScrollTo().assertIsDisplayed().performClick()
        compose.runOnIdle { assertEquals(RemoteCommand.Press(RemoteKey.SUBTITLES), sent.last()) }
        compose.onNodeWithText("Start over").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("Subtitles: English").assertExists()
        snapshot("remote-player")
    }
    @Test fun keyboardEraseActionsAndLayout() {
        val sent = mutableListOf<RemoteCommand>()
        val draft = mutableStateOf("Test draft")
        compose.setContent {
            MacTV_AndroidAppTheme {
                RemoteAppContent(RemoteUiState(mode = InputMode.KEYBOARD, keyboardText = draft.value),
                    send = { sent.add(it) }, updateText = { draft.value = it })
            }
        }
        compose.onNodeWithText("Backspace").performScrollTo().performClick()
        compose.runOnIdle { assertEquals(RemoteCommand.Press(RemoteKey.BACKSPACE), sent.last()) }
        compose.onNodeWithText("Erase Mac field").performScrollTo().performClick()
        compose.runOnIdle { assertEquals(RemoteCommand.Press(RemoteKey.ERASE_FIELD), sent.last()); assertEquals("", draft.value) }
        compose.onNodeWithText("Buttons").assertIsDisplayed()
        compose.onNodeWithText("Touchpad").assertIsDisplayed()
        compose.onNode(hasText("Keyboard") and hasClickAction()).assertIsDisplayed()
        snapshot("remote-keyboard")
    }
    @Test fun sportsLaunchersSendCommandsAndKeepModeTabsVisible() {
        val sent = mutableListOf<RemoteCommand>()
        compose.setContent {
            MacTV_AndroidAppTheme {
                RemoteAppContent(RemoteUiState(appContext = AppContext("f1", "F1 TV", setOf("fullscreen"))), send = { sent.add(it) })
            }
        }
        compose.onNodeWithContentDescription("Launch F1 TV").performScrollTo().assertIsDisplayed().performClick()
        compose.runOnIdle { assertEquals(RemoteCommand.Launch(LaunchApp.F1), sent.last()) }
        compose.onNodeWithContentDescription("Launch Football").performScrollTo().assertIsDisplayed().performClick()
        compose.runOnIdle { assertEquals(RemoteCommand.Launch(LaunchApp.FOOTBALL), sent.last()) }
        compose.onNodeWithText("Buttons").assertIsDisplayed()
        compose.onNodeWithContentDescription("Back 10 seconds").assertDoesNotExist()
        snapshot("remote-sports")
    }
    @Test fun footballRecoveryButtonsSendDistinctCommands() {
        val sent = mutableListOf<RemoteCommand>()
        compose.setContent {
            MacTV_AndroidAppTheme {
                RemoteAppContent(RemoteUiState(appContext = AppContext("football", "Football", setOf("unmute_stream", "refresh", "fullscreen", "close_tab"))), send = { sent.add(it) })
            }
        }
        compose.onNodeWithText("Unmute stream").performScrollTo().performClick()
        compose.runOnIdle { assertEquals(RemoteCommand.Press(RemoteKey.UNMUTE_STREAM), sent.last()) }
        compose.onNodeWithText("Refresh page").performScrollTo().performClick()
        compose.runOnIdle { assertEquals(RemoteCommand.Press(RemoteKey.REFRESH), sent.last()) }
        compose.onNodeWithText("Fullscreen").performScrollTo().performClick()
        compose.runOnIdle { assertEquals(RemoteCommand.Press(RemoteKey.FULLSCREEN), sent.last()) }
        compose.onNodeWithText("Close current tab").performScrollTo().assertIsDisplayed().performClick()
        compose.runOnIdle { assertEquals(RemoteCommand.Press(RemoteKey.CLOSE_TAB), sent.last()) }
        snapshot("remote-football")
    }
    @Test fun remotePrioritisesPlaybackAndInputWhileConnectionStaysInDevices() {
        val state = mutableStateOf(RemoteUiState(
            connection = ConnectionState.Connected(MacDevice("test", "Test Mac", "ws://127.0.0.1:8765/")),
            appContext = AppContext("football", "Football", setOf("unmute_stream", "refresh", "fullscreen", "close_tab"))))
        compose.setContent { MacTV_AndroidAppTheme { RemoteAppContent(state.value) } }
        compose.onNodeWithText("Connected · authenticated").assertDoesNotExist()
        val playback = compose.onNodeWithContentDescription("Play or pause").assertIsDisplayed().fetchSemanticsNode().boundsInRoot
        val input = compose.onNodeWithContentDescription("Up").assertIsDisplayed().fetchSemanticsNode().boundsInRoot
        assertTrue("Playback must appear above directional input", playback.bottom < input.top)
        compose.onNodeWithText("Close current tab").performScrollTo().assertIsDisplayed()
        compose.onNodeWithContentDescription("Play or pause").assertIsDisplayed()
        compose.onNodeWithText("Buttons").assertIsDisplayed()
        snapshot("remote-football")
        compose.runOnIdle { state.value = state.value.copy(mode = InputMode.TOUCHPAD) }
        compose.onNodeWithContentDescription("Play or pause").assertIsDisplayed()
        compose.onNodeWithText("Room to move.").performScrollTo().assertIsDisplayed()
        snapshot("remote-touchpad")
        compose.runOnIdle { state.value = state.value.copy(destination = Destination.DEVICES) }
        compose.onNodeWithText("Connected · authenticated").assertIsDisplayed()
    }

    @Test fun appReturnActionUsesTheAppNameAndSendsActivation() {
        val context = mutableStateOf(AppContext("spotify", "Spotify", setOf("app_search"), foreground = false))
        val sent = mutableListOf<RemoteCommand>()
        compose.setContent { MacTV_AndroidAppTheme { RemoteAppContent(RemoteUiState(appContext = context.value), send = { sent.add(it) }) } }
        compose.onNodeWithText("Open Spotify").performScrollTo().assertIsDisplayed().performClick()
        compose.runOnIdle { assertEquals(RemoteCommand.Press(RemoteKey.ACTIVATE_APP), sent.last()) }
        compose.runOnIdle { context.value = AppContext("youtube", "YouTube", setOf("fullscreen"), foreground = false) }
        compose.onNodeWithText("Open YouTube").performScrollTo().assertIsDisplayed()
        snapshot("remote-return")
    }

    private fun snapshot(name: String) {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val file = File(context.getExternalFilesDir(null), "$name.png")
        file.outputStream().use { compose.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it) }
    }

}
