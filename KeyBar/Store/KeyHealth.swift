import Foundation
import UserNotifications

/// Keys that need attention: expiring soon, or not used in months
enum KeyHealth {
    /// A reminder this many days before a key expires
    static let soonDays = 14
    /// Keys unused this long are offered for archiving
    static let unusedDays = 90

    /// Active keys added at least `unusedDays` ago and not used since then
    static func unused(_ records: [SecretRecord], now: Date = Date()) -> [SecretRecord] {
        let cutoff = now.addingTimeInterval(-Double(unusedDays) * 86_400)
        return records.filter { !$0.isArchived && $0.createdAt < cutoff && ($0.lastUsedAt ?? $0.createdAt) < cutoff }
    }

    static func expiryText(_ record: SecretRecord, now: Date = Date()) -> String? {
        guard let days = record.daysUntilExpiry(from: now) else { return nil }
        switch days {
        case ..<0: return "Expired"
        case 0: return "Expires today"
        case 1: return "Expires tomorrow"
        default: return days <= soonDays ? "Expires in \(days) days" : nil
        }
    }
}

/// Notifications before keys expire: one when it's `KeyHealth.soonDays`
/// away, one on the day. Each is sent once per key and expiry date.
@MainActor
final class ExpiryReminders {
    private let store: SecretStore
    private let settings: AppSettings
    private static let sentKey = "expiryRemindersSent"

    init(store: SecretStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
    }

    /// Asks macOS to allow notifications, the first time a key gets a date
    static func askPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func check(now: Date = Date()) {
        guard settings.expiryReminders else { return }
        var sent = Set(UserDefaults.standard.stringArray(forKey: Self.sentKey) ?? [])
        var live = Set<String>()
        for record in store.active {
            guard let expiresAt = record.expiresAt, let days = record.daysUntilExpiry(from: now) else { continue }
            let stage = days <= 0 ? "due" : days <= KeyHealth.soonDays ? "soon" : nil
            guard let stage else { continue }
            let id = "\(record.name)|\(Int(expiresAt.timeIntervalSince1970))|\(stage)"
            live.insert(id)
            guard !sent.contains(id) else { continue }
            sent.insert(id)
            post(record, days: days, id: id)
        }
        // Forget reminders for keys and dates that are gone
        UserDefaults.standard.set(Array(sent.intersection(live)), forKey: Self.sentKey)
    }

    private func post(_ record: SecretRecord, days: Int, id: String) {
        let content = UNMutableNotificationContent()
        content.title = days < 0 ? "\(record.name) has expired" : days == 0 ? "\(record.name) expires today" : "\(record.name) expires in \(days) days"
        var body = "Make a new one, then replace it in KeyBar."
        if !record.sentTo.isEmpty {
            body += " KeyBar can then send it again to \(record.sentTo.count == 1 ? record.sentTo[0].label : "the \(record.sentTo.count) places it went")."
        }
        content.body = body
        content.userInfo = ["key": record.name]
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
