import AppKit
import SwiftUI
import Observation

/// Input scoped to our own window. External apps continue to use AX-gated system events.
@MainActor @Observable final class MacTVPointer {
    private(set) var location: CGPoint?
    private(set) var lastMoved = Date.distantPast
    @ObservationIgnored private weak var owner: NSWindow?
    func reset() { location = nil; owner = nil }
    func execute(_ body: [String: Any], window: NSWindow) -> (String, String) {
        guard window.attachedSheet == nil, let view = window.contentView else { return ("error", "Close the Mac dialog first") }
        if owner !== window { reset(); owner = window }
        var point = location ?? CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let kind = body["kind"] as? String
        if kind == "pointer", let dx = body["dx"] as? Double, let dy = body["dy"] as? Double,
           dx.isFinite, dy.isFinite, abs(dx) <= 500, abs(dy) <= 500 {
            point.x = min(view.bounds.maxX - 1, max(1, point.x + dx * 2))
            point.y = min(view.bounds.maxY - 1, max(1, point.y - dy * 2))
            location = point; lastMoved = .now
            if let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) { window.sendEvent(event) }
        } else if kind == "key", body["key"] as? String == "click" {
            location = point; lastMoved = .now
            // Send the normal click sequence only to MacTV's window; never post globally.
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) { NSApp.postEvent(event, atStart: false) }
            }
        } else if kind == "scroll", let delta = body["delta"] as? Double, delta.isFinite, abs(delta) <= 500 {
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(-delta * 2), wheel2: 0, wheel3: 0) else { return ("error", "Scroll unavailable") }
            let screenPoint = window.convertPoint(toScreen: point)
            event.location = CGPoint(x: screenPoint.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screenPoint.y)
            if let native = NSEvent(cgEvent: event) { view.hitTest(point)?.scrollWheel(with: native) }
            lastMoved = .now
        } else { return ("unsupported", "Invalid pointer input") }
        return ("dispatched", "MacTV touchpad input received")
    }
}

struct RemotePointerView: View {
    let pointer: MacTVPointer
    var body: some View {
        GeometryReader { geometry in
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                if let point = pointer.location, context.date.timeIntervalSince(pointer.lastMoved) < 4 {
                    Image(systemName: "cursorarrow").font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white).shadow(color: .black, radius: 2)
                        .position(x: point.x + 9, y: geometry.size.height - point.y + 12)
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
