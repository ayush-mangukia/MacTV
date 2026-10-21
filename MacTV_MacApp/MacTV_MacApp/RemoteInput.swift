import AppKit
import ApplicationServices

@MainActor
enum RemoteInput {
    static var permitted: Bool { CGPreflightPostEventAccess() }
    static var diagnostic: String { "Input permission: event posting=\(CGPreflightPostEventAccess()), app access=\(AXIsProcessTrusted())" }
    static var permissionName: String {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? "Device Control and Data Access" : "Accessibility"
    }
    static var permissionMessage: String { "Enable MacTV in System Settings → Privacy & Security → \(permissionName). Then return to the streaming app." }
    static func requestPermission() {
        _ = CGRequestPostEventAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
    private static func sendKey(_ code: CGKeyCode, flags: CGEventFlags = []) {
        for down in [true, false] { let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down); event?.flags = flags; event?.post(tap: .cghidEventTap) }
    }
    static func primaryClick(at point: CGPoint) -> [CGEvent] {
        [CGEventType.leftMouseDown, .leftMouseUp].compactMap { type in
            guard let event = CGEvent(mouseEventSource: CGEventSource(stateID: .privateState), mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return nil }
            event.flags = []
            event.setIntegerValueField(.mouseEventButtonNumber, value: 0)
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            return event
        }
    }
    static func canCloseTab(service: Service?, bundleID: String?) -> Bool {
        service == .football && bundleID == "com.google.Chrome"
    }
    static func execute(_ body: [String: Any], target: NSRunningApplication?, service: Service? = nil) -> (String, String) {
        guard permitted else { return ("permission_required", permissionMessage) }
        let kind = body["kind"] as? String
        // AX actions address a specific provider element. Unlike keyboard events they
        // are safe while another app or a search field has focus.
        if kind == "key", let key = body["key"] as? String, let target {
            if key == "unmute_stream", service == .football {
                return ProviderControls.press("unmute_stream", target: target)
                    ? ("dispatched", "Stream unmute button pressed")
                    : ("error", "No Unmute button is visible. The stream may already have sound; use the touchpad to inspect its player.")
            }
            if key == "refresh", service == .football, ProviderControls.press("refresh", target: target) {
                return ("dispatched", "Football page refreshed")
            }
            if key == "play_pause", [.youtube, .netflix, .prime, .f1, .football].contains(service) {
                return ProviderControls.press("play_pause", target: target)
                    ? ("dispatched", "Player button pressed")
                    : ("error", "Player control unavailable. Open a video and reveal its controls with the touchpad.")
            }
            if ["fullscreen", "subtitles"].contains(key), [.youtube, .f1, .football].contains(service), ProviderControls.press(key, target: target) {
                return ("dispatched", "Player button pressed")
            }
        }
        // Never send keyboard or pointer input to an unrelated frontmost application.
        if let target, NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
            return ("error", "Your streaming app must be in front. Tap Return to app, or Home to return to MacTV.")
        }
        if kind == "text", let text = body["text"] as? String, text.count <= 2000 {
            // CGEvent Unicode handles user text without shell, AppleScript, or clipboard access.
            for character in text {
                let chunk = Array(String(character).utf16)
                guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                      let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { return ("error", "Input event unavailable") }
                chunk.withUnsafeBufferPointer { down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress!) }
                down.flags = []; up.flags = []; down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
            }
        } else if kind == "pointer", let dx = body["dx"] as? Double, let dy = body["dy"] as? Double,
                  dx.isFinite, dy.isFinite, abs(dx) <= 500, abs(dy) <= 500 {
            guard let current = CGEvent(source: nil)?.location else { return ("error", "Pointer unavailable") }
            let screens = NSScreen.screens.map(\.frame)
            let minX = screens.map(\.minX).min() ?? 0, maxX = screens.map(\.maxX).max() ?? 1920
            let mainHeight = NSScreen.screens.first?.frame.height ?? 1080
            let minY = mainHeight - (screens.map(\.maxY).max() ?? mainHeight)
            let maxY = mainHeight - (screens.map(\.minY).min() ?? 0)
            let point = CGPoint(x: min(maxX - 1, max(minX, current.x + dx * 2)), y: min(maxY - 1, max(minY, current.y + dy * 2)))
            guard let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else { return ("error", "Pointer event unavailable") }
            event.setIntegerValueField(.mouseEventDeltaX, value: Int64(point.x - current.x))
            event.setIntegerValueField(.mouseEventDeltaY, value: Int64(point.y - current.y))
            event.flags = []; event.post(tap: .cghidEventTap)
        } else if kind == "scroll", let delta = body["delta"] as? Double, delta.isFinite, abs(delta) <= 500 {
            let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(-delta), wheel2: 0, wheel3: 0)
            event?.flags = []; event?.post(tap: .cghidEventTap)
        } else if kind == "key", let key = body["key"] as? String {
            if key == "close_tab" {
                guard canCloseTab(service: service, bundleID: target?.bundleIdentifier) else { return ("unsupported", "Close tab is available only for Football in Chrome") }
                sendKey(13, flags: .maskCommand) // Chrome's Close current tab (Cmd-W).
            }
            else if key == "refresh", service == .football { sendKey(15, flags: .maskCommand) }
            else if key == "click" {
                guard let point = CGEvent(source: nil)?.location else { return ("error", "Pointer unavailable") }
                for event in primaryClick(at: point) { event.post(tap: .cghidEventTap) }
            } else if key == "backspace" || key == "erase_field" {
                guard let target, ProviderControls.editingText(target) else { return ("error", "Focus a text field on the Mac first") }
                if key == "erase_field" { sendKey(0, flags: .maskCommand) }
                sendKey(51)
            } else if service == .youtube, let target, ["fullscreen", "subtitles", "seek_back", "seek_forward", "previous", "next"].contains(key), ProviderControls.editingText(target) {
                return ("error", "Finish editing or select the video with the touchpad first")
            } else if service == .youtube, let code: CGKeyCode = ["fullscreen": 3, "seek_back": 38, "seek_forward": 37, "previous": 38, "next": 37][key] {
                sendKey(code)
            } else if service == .netflix, key == "fullscreen" {
                sendKey(3)
            } else if key == "fullscreen" {
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: nil, virtualKey: 3, keyDown: down)
                    event?.flags = [.maskCommand, .maskControl]
                    event?.post(tap: .cghidEventTap)
                }
            } else if key == "back", ["com.apple.Safari", "com.google.Chrome"].contains(target?.bundleIdentifier ?? "") {
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: nil, virtualKey: 33, keyDown: down)
                    event?.flags = .maskCommand
                    event?.post(tap: .cghidEventTap)
                }
            } else if let code: CGKeyCode = ["up": 126, "down": 125, "left": 123, "right": 124, "ok": 36, "back": 53][key] {
                sendKey(code)
            } else if key == "app_search", service == .spotify, let target {
                if !ProviderControls.focusSearch(target) {
                    guard target.bundleIdentifier == "com.spotify.client" else { return ("error", "Select Spotify’s search field with the touchpad") }
                    sendKey(40, flags: .maskCommand) // Spotify Quick Search (Cmd-K), which focuses typing.
                }
            } else if key == "subtitles", ["com.google.Chrome", "com.apple.Safari"].contains(target?.bundleIdentifier ?? "") {
                sendKey(8) // YouTube's C shortcut; offered only by the YouTube context.
            } else if key == "seek_back" || key == "seek_forward" {
                sendKey(key == "seek_back" ? 123 : 124)
            } else if let media = ["play_pause": 16, "previous": 18, "next": 17, "volume_up": 0, "volume_down": 1, "mute": 7][key] {
                for down in [true, false] {
                    let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
                    NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                                       windowNumber: 0, context: nil, subtype: 8,
                                       data1: (media << 16) | (down ? 0xa00 : 0xb00), data2: -1)?.cgEvent?.post(tap: .cghidEventTap)
                }
            } else { return ("unsupported", "This key is not supported by the active app") }
        } else { return ("unsupported", "Invalid or unsupported input") }
        return ("dispatched", "Input dispatched; the streaming app controls its response")
    }
}
