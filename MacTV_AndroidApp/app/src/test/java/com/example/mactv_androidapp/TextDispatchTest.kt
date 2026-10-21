package com.example.mactv_androidapp

import com.example.mactv_androidapp.command.*
import com.example.mactv_androidapp.ui.*
import org.junit.Assert.*
import org.junit.Test

class TextDispatchTest {
    private val typing = RemoteUiState(mode = InputMode.KEYBOARD, keyboardText = "my song")
    private val command = RemoteCommand.EnterText("my song")
    @Test fun acknowledgedTextReturnsToButtonsAndClearsDraft() {
        val result = typing.afterTextDispatch(command, DispatchResult.Delivered)
        assertEquals(InputMode.BUTTONS, result.mode)
        assertEquals("", result.keyboardText)
    }
    @Test fun failurePreservesDraftAndKeyboard() {
        assertEquals(typing, typing.afterTextDispatch(command, DispatchResult.Failed("unavailable")))
        assertEquals(typing, typing.afterTextDispatch(command, DispatchResult.Disconnected))
    }
    @Test fun acknowledgementDoesNotOverrideNewTextOrModeChoice() {
        val changed = typing.copy(keyboardText = "another song")
        assertEquals(changed, changed.afterTextDispatch(command, DispatchResult.Delivered))
        val touchpad = typing.copy(mode = InputMode.TOUCHPAD)
        assertEquals(touchpad, touchpad.afterTextDispatch(command, DispatchResult.Delivered))
    }
}
