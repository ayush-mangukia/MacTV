package com.example.mactv_androidapp

import androidx.test.platform.app.InstrumentationRegistry
import com.example.mactv_androidapp.command.*
import com.example.mactv_androidapp.connection.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Manual opt-in only: toggles the current video on the already-paired Mac once.
 * Run with -e livePlayback true -e expectedApp youtube after preparing a test video.
 * Uses the app's normal private credential store; never exports credentials or repairs pairing.
 */
class LivePlaybackTest {
    @Test fun togglePreparedVideoUsingExistingPairing() = runBlocking {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue("Requires explicit livePlayback opt-in", args.getString("livePlayback") == "true")
        val expected = args.getString("expectedApp")
        require(expected in setOf("youtube", "netflix", "prime"))
        val connection = MacConnection(InstrumentationRegistry.getInstrumentation().targetContext)
        try {
            connection.resume()
            withTimeout(12000) { connection.state.first { it is ConnectionState.Connected } }
            val context = withTimeout(5000) { connection.context.first { it != null } }!!
            assertEquals("Prepare the expected provider before this test", expected, context.app)
            assertEquals(DispatchResult.Delivered, connection.dispatch(RemoteCommand.Press(RemoteKey.PLAY_PAUSE)))
        } finally { connection.close() }
    }
}
