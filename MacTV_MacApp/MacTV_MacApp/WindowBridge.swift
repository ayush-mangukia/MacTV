import AppKit
import SwiftUI

/// Keeps AppKit window lifecycle and local keyboard input outside the SwiftUI views.
struct WindowBridge: NSViewRepresentable {
    let model: MacTVModel

    func makeNSView(context: Context) -> WindowObserverView {
        let view = WindowObserverView()
        view.model = model
        return view
    }

    func updateNSView(_ nsView: WindowObserverView, context: Context) {}

    static func dismantleNSView(_ nsView: WindowObserverView, coordinator: ()) {
        nsView.stopMonitoring()
    }
}

final class WindowObserverView: NSView {
    weak var model: MacTVModel?
    private var monitor: Any?
    private var mouseMonitor: Any?
    private var closeObserver: NSObjectProtocol?
    private var configured = false
    private var terminationObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" else { return }
        guard let window, let model else { stopMonitoring(); return }
        model.window = window
        model.awake.setEnabled(model.keepAwake)
        if terminationObserver == nil {
            terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak model] _ in
                MainActor.assumeIsolated { model?.stopMovie(); model?.awake.stop() }
            }
        }
        if closeObserver == nil {
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak model] _ in
                Task { @MainActor [weak model] in model?.stopMovie(); model?.awake.stop() }
            }
        }
        window.acceptsMouseMovedEvents = true
        if mouseMonitor == nil {
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .scrollWheel]) { [weak self] event in
                if event.window === self?.window { self?.model?.moviePlayer?.revealControls() }
                return event
            }
        }
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let model = self.model,
                      event.window === self.window, self.window?.isKeyWindow == true,
                      self.window?.attachedSheet == nil,
                      !event.modifierFlags.contains(.command),
                      !event.modifierFlags.contains(.option),
                      !event.modifierFlags.contains(.control) else { return event }
                // Let native URL editing receive arrows and Return; Escape remains MacTV Back.
                if (model.browser?.editingAddress == true || model.browser?.editingWebField == true || model.movieSearchEditing) && event.keyCode != 53 { return event }
                let command: RemoteCommand
                switch event.keyCode {
                case 123: command = .left
                case 124: command = .right
                case 125: command = .down
                case 126: command = .up
                case 36, 76: command = .ok
                case 53: command = .back
                case 115: command = .home
                case 49 where model.browser != nil || model.moviePlayer != nil: command = .playPause
                default: return event
                }
                if event.isARepeat && (command == .ok || command == .back || command == .home) { return nil }
                model.handle(command)
                return nil
            }
        }
        guard !configured else { return }
        configured = true
        window.title = "MacTV"
        window.collectionBehavior.insert(.fullScreenPrimary)
        // Wait until SwiftUI has attached and presented the window.
        Task { @MainActor [weak window, weak model] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let window, let model, window.isVisible,
                  model.startsFullscreen, !window.styleMask.contains(.fullScreen) else { return }
            window.toggleFullScreen(nil)
        }
    }

    func stopMonitoring() {
        model?.awake.stop()
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }; terminationObserver = nil
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }; mouseMonitor = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
