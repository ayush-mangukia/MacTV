package com.example.mactv_androidapp

import com.example.mactv_androidapp.command.*
import com.example.mactv_androidapp.connection.ConnectionState
import com.example.mactv_androidapp.ui.RemoteUiState
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class RemoteCommandTest {
    @Test fun startupIsDisconnectedAndTestingIsOptIn() {
        val state = RemoteUiState()
        assertEquals(ConnectionState.Disconnected, state.connection)
        assertFalse(state.testMode)
        assertEquals(0, state.commandCount)
    }

    @Test fun mockRecordsCommandsInOrderWithoutClaimingDelivery() = runBlocking {
        val mock = MockCommandDispatcher()
        val commands = listOf(
            RemoteCommand.Press(RemoteKey.OK),
            RemoteCommand.MovePointer(12f, -4f),
            RemoteCommand.Scroll(8f),
            RemoteCommand.Launch(LaunchApp.YOUTUBE)
        )
        commands.forEach { assertEquals(DispatchResult.RecordedLocally, mock.dispatch(it)) }
        assertEquals(commands, mock.recordedCommands)
    }

    @Test fun typedContentIsNeverKeptInTheRecorder() = runBlocking {
        val mock = MockCommandDispatcher()
        mock.dispatch(RemoteCommand.EnterText("private search"))
        assertEquals(listOf(RemoteCommand.EnterText("[redacted]")), mock.recordedCommands)
    }

    @Test fun gestureBurstsKeepOnlyTheLatest64Commands() = runBlocking {
        val mock = MockCommandDispatcher()
        repeat(100) { mock.dispatch(RemoteCommand.Scroll(it.toFloat())) }
        assertEquals(64, mock.recordedCommands.size)
        assertEquals(RemoteCommand.Scroll(36f), mock.recordedCommands.first())
        assertEquals(RemoteCommand.Scroll(99f), mock.recordedCommands.last())
    }
}
