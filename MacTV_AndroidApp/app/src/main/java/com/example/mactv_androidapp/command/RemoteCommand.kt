package com.example.mactv_androidapp.command

/** Transport-independent intent, encoded by RemoteWire v1. */
sealed interface RemoteCommand {
    data class Press(val key: RemoteKey) : RemoteCommand
    data class MovePointer(val dx: Float, val dy: Float) : RemoteCommand
    data class Scroll(val delta: Float) : RemoteCommand
    data class EnterText(val text: String) : RemoteCommand
    data class Launch(val app: LaunchApp) : RemoteCommand
}

enum class RemoteKey {
    UP, DOWN, LEFT, RIGHT, OK, HOME, BACK, PLAY_PAUSE, PREVIOUS, NEXT,
    VOLUME_UP, VOLUME_DOWN, MUTE, CLICK, FULLSCREEN, CONTROLS, INPUT_SETTINGS, ACTIVATE_APP, SUBTITLES, RESTART, SEEK_BACK, SEEK_FORWARD, APP_SEARCH, BACKSPACE, ERASE_FIELD, REFRESH, UNMUTE_STREAM, CLOSE_TAB
}

enum class LaunchApp(val title: String, val mark: String) {
    NETFLIX("Netflix", "N"), SPOTIFY("Spotify", "Spotify"),
    YOUTUBE("YouTube", "▶"), PRIME_VIDEO("Prime Video", "prime"), MOVIES("Movies", "Movies"), F1("F1 TV", "F1"), FOOTBALL("Football", "Football")
}

sealed interface DispatchResult {
    data object RecordedLocally : DispatchResult
    data object Disconnected : DispatchResult
    data object Delivered : DispatchResult
    data class Failed(val reason: String) : DispatchResult
}

fun interface CommandDispatcher {
    suspend fun dispatch(command: RemoteCommand): DispatchResult
}

/** Bounded, in-memory test recorder. Never reports delivery or retains text input. */
class MockCommandDispatcher : CommandDispatcher {
    private val commands = ArrayDeque<RemoteCommand>()
    val recordedCommands: List<RemoteCommand> get() = commands.toList()

    override suspend fun dispatch(command: RemoteCommand): DispatchResult {
        if (commands.size == 64) commands.removeFirst()
        commands.addLast(if (command is RemoteCommand.EnterText) RemoteCommand.EnterText("[redacted]") else command)
        return DispatchResult.RecordedLocally
    }
}
