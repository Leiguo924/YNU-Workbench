import EventKit
import Foundation

@MainActor
enum ReminderExport {
    static func export(_ tasks: [TodoItem]) async throws -> Int {
        let store = EKEventStore()
        let granted: Bool
        if #available(macOS 14, *) {
            granted = try await store.requestFullAccessToReminders()
        } else {
            granted = try await store.requestAccess(to: .reminder)
        }
        guard granted else { throw ExportError.noPermission }
        guard let list = store.defaultCalendarForNewReminders(), list.allowsContentModifications else {
            throw ExportError.noList
        }

        let key = "exportedAppleReminderIDs"
        let defaults = UserDefaults.standard
        var existing = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        let pending = tasks.filter { task in
            guard !task.done else { return false }
            guard let identifier = existing[task.id.uuidString] else { return true }
            return store.calendarItem(withIdentifier: identifier) == nil
        }
        guard !pending.isEmpty else { return 0 }
        var saved: [(UUID, EKReminder)] = []
        do {
            for task in pending {
                let reminder = EKReminder(eventStore: store)
                reminder.calendar = list
                reminder.title = task.title
                if let date = task.due {
                    let fields: Set<Calendar.Component> = task.hasTime == true
                        ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
                    reminder.dueDateComponents = Calendar.current.dateComponents(fields, from: date)
                }
                try store.save(reminder, commit: false)
                saved.append((task.id, reminder))
            }
            try store.commit()
        } catch {
            store.reset()
            throw error
        }
        for (id, reminder) in saved {
            existing[id.uuidString] = reminder.calendarItemIdentifier
        }
        defaults.set(existing, forKey: key)
        return saved.count
    }

    private enum ExportError: LocalizedError {
        case noPermission, noList
        var errorDescription: String? {
            switch self {
            case .noPermission: return "请在系统设置的「隐私与安全性 → 提醒事项」中允许访问。"
            case .noList: return "提醒事项里没有可写入的默认列表。"
            }
        }
    }
}
