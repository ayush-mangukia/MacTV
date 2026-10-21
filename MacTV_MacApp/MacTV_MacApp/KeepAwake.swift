import AppKit
import IOKit.pwr_mgt

/// Lifetime-scoped power assertions. Never changes login, password or power preferences.
@MainActor final class KeepAwake {
    private(set) var active = false
    private var display: IOPMAssertionID = 0
    private var activity: IOPMAssertionID = 0
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var suspended = false
    func setEnabled(_ enabled: Bool) {
        guard enabled != active else { return }
        if !enabled { stop(); return }
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), "MacTV is open" as CFString, &display)
        guard result == kIOReturnSuccess else { return }
        active = true
        let center = NSWorkspace.shared.notificationCenter
        observers = [center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspended = true }
        }, center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspended = false }
        }]
        // Keep the screen saver idle timer in step with an ongoing TV session. An explicitly
        // sleeping display is left alone; a manual lock remains password protected.
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.active, !self.suspended else { return }
                _ = IOPMAssertionDeclareUserActivity("MacTV viewing session" as CFString, kIOPMUserActiveLocal, &self.activity)
            }
        }
    }
    func stop() {
        timer?.invalidate(); timer = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }; observers = []
        if display != 0 { IOPMAssertionRelease(display); display = 0 }
        if activity != 0 { IOPMAssertionRelease(activity); activity = 0 }
        active = false; suspended = false
    }
}
