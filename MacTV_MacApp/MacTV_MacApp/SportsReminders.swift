import Foundation
import Observation
import UserNotifications

/// Reminders live entirely inside MacTV. No system-notification service or background
/// delivery is used. A changed start time produces a fresh reminder identity.
@MainActor @Observable final class SportsReminders {
    var enabled = true
    var notice: String?
    private(set) var scheduledCount = 0
    private(set) var events: [SportsEvent] = []
    private var lead = 15
    private var dismissed: Set<String> = []
    static func eligible(_ events: [SportsEvent], lead: Int, now: Date = .now) -> [SportsEvent] {
        Array(events.filter { $0.scheduled && $0.start > now && $0.start < now.addingTimeInterval(14 * 86400) }.sorted { $0.start < $1.start }.prefix(40))
    }
    private func identity(_ event: SportsEvent) -> String { "\(event.id):\(event.start.timeIntervalSince1970)" }
    func replace(_ values: [SportsEvent], lead: Int) async {
        self.lead = lead
        events = enabled ? Self.eligible(values, lead: lead) : []
        scheduledCount = events.count
        dismissed.formIntersection(Set(events.map(identity)))
    }
    func due(now: Date = .now) -> [SportsEvent] {
        guard enabled else { return [] }
        return Array(events.filter { $0.scheduled && $0.start > now && $0.start <= now.addingTimeInterval(Double(lead) * 60) && !dismissed.contains(identity($0)) }.prefix(2))
    }
    func dismiss(_ event: SportsEvent) { dismissed.insert(identity(event)) }
}

/// Removal-only migration for the earlier notification-based development build.
/// Never requests permission, schedules notifications, or touches another feature.
@MainActor enum LegacySportsNotificationCleanup {
    static func clear() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers:
            pending.map(\.identifier).filter { $0.hasPrefix("mactv.sports.") })
        let delivered = await center.deliveredNotifications()
        center.removeDeliveredNotifications(withIdentifiers:
            delivered.map { $0.request.identifier }.filter { $0.hasPrefix("mactv.sports.") })
    }
}
