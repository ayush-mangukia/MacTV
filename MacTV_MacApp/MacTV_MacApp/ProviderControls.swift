import AppKit
import ApplicationServices

/// Bounded public Accessibility queries, scoped to the selected provider process.
@MainActor enum ProviderControls {
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    static func labels(_ element: AXUIElement) -> [String] {
        [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, "AXPlaceholderValue"].compactMap { attribute(element, $0) as? String }.map { $0.lowercased() }
    }
    /// Chromium exposes the complete web tree when an AX client requests enhanced UI.
    /// Visit depth first and act immediately, rather than spending the budget flattening
    /// thousands of recommendations before looking for the player's button.
    static func visit(_ app: NSRunningApplication, allWindows: Bool = false, match: (AXUIElement) -> Bool) -> Bool {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.08)
        if app.bundleIdentifier == "com.google.Chrome" {
            AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
        var stack: [AXUIElement]
        if allWindows { stack = (attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []).reversed() }
        else if let focused = attribute(root, kAXFocusedWindowAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() {
            stack = [unsafeBitCast(focused, to: AXUIElement.self)]
        } else { return false }
        if app.bundleIdentifier == "com.google.Chrome" {
            for window in stack { AXUIElementSetAttributeValue(window, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
        }
        let deadline = Date().addingTimeInterval(2.5)
        var visited = 0, success = false
        while let node = stack.popLast(), visited < 4000, Date() < deadline {
            visited += 1
            AXUIElementSetMessagingTimeout(node, 0.08)
            if match(node) { success = true; if !allWindows { return true } }
            if let children = attribute(node, kAXChildrenAttribute) as? [AXUIElement] {
                stack.append(contentsOf: children.prefix(1000).reversed())
            }
        }
        return success
    }
    static func isMediaButton(_ labels: [String], action: String) -> Bool {
        labels.contains { raw in
            let label = raw.lowercased()
            switch action {
            case "refresh": return ["reload", "reload this page", "refresh", "refresh page"].contains(label)
            case "unmute_stream": return ["unmute", "unmute stream", "unmute video", "click to unmute", "tap to unmute", "enable sound", "turn sound on"].contains(label) || label.hasPrefix("unmute (") || label.hasPrefix("unmute keyboard shortcut ")
            case "pause": return label == "pause" || label.hasPrefix("pause (") || label == "pause playback" || label == "pause video" || label.hasPrefix("pause keyboard shortcut ")
            case "play_pause": return isMediaButton([label], action: "pause") || label == "play" || label.hasPrefix("play (") || label == "play playback" || label == "play video" || label.hasPrefix("play keyboard shortcut ")
            case "fullscreen": return label == "full screen" || label.hasPrefix("full screen (") || label.hasPrefix("exit full screen") || label == "fullscreen" || label.hasPrefix("full screen keyboard shortcut ")
            case "subtitles": return label.hasPrefix("subtitles/closed captions") || label == "subtitles" || label.hasPrefix("closed captions (")
            default: return false
            }
        }
    }
    @discardableResult static func press(_ action: String, target: NSRunningApplication, allWindows: Bool = false) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        return visit(target, allWindows: allWindows) { node in
            let role = attribute(node, kAXRoleAttribute) as? String ?? ""
            guard (role == kAXButtonRole || (action == "unmute_stream" && role == "AXLink")),
                  isMediaButton(labels(node), action: action) else { return false }
            return AXUIElementPerformAction(node, kAXPressAction as CFString) == .success
        }
    }
    static func editingText(_ target: NSRunningApplication) -> Bool {
        let root = AXUIElementCreateApplication(target.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.08)
        guard let focused = attribute(root, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let element = unsafeBitCast(focused, to: AXUIElement.self)
        let role = attribute(element, kAXRoleAttribute) as? String ?? ""
        return [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"].contains(role) || attribute(element, "AXEditable") as? Bool == true
    }
    static func focusSearch(_ target: NSRunningApplication) -> Bool {
        visit(target) { node in
            let role = attribute(node, kAXRoleAttribute) as? String ?? ""
            guard [kAXTextFieldRole, "AXSearchField", kAXComboBoxRole].contains(role),
                  labels(node).contains(where: { $0.contains("search") || $0.contains("what do you want to play") }) else { return false }
            return AXUIElementSetAttributeValue(node, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
        }
    }
}

/// Never toggles playback: pause only. No user text or remote arguments enter AppleScript.
nonisolated enum OtherAudio {
    private static let queue = DispatchQueue(label: "MacTV.PauseOtherAudio")
    @MainActor static func pause(completion: @escaping @MainActor @Sendable (String?) -> Void) {
        let running = NSWorkspace.shared.runningApplications
        let browsers = running.filter { ["com.google.Chrome", "com.apple.Safari", "com.amazon.aiv.AIVApp"].contains($0.bundleIdentifier ?? "") }
        for app in browsers { ProviderControls.press("pause", target: app, allWindows: true) }
        let ids = running.compactMap(\.bundleIdentifier).filter { ["com.spotify.client", "com.apple.Music", "org.videolan.vlc"].contains($0) }
        queue.async {
            var failures: [String] = []
            for id in Set(ids) {
                let operation = id == "org.videolan.vlc" ? "if playing then pause" : "if player state is playing then pause"
                let source = "with timeout of 3 seconds\ntell application id \"\(id)\"\n\(operation)\nend tell\nend timeout"
                var error: NSDictionary?
                NSAppleScript(source: source)?.executeAndReturnError(&error)
                if error != nil { failures.append(id == "com.spotify.client" ? "Spotify" : (id == "com.apple.Music" ? "Music" : "VLC")) }
            }
            let notice = failures.isEmpty ? nil : "Could not pause \(failures.sorted().joined(separator: ", ")). Allow MacTV in Privacy & Security → Automation, or pause it manually."
            DispatchQueue.main.async { completion(notice) }
        }
    }
}
