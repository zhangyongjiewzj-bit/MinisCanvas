import Foundation
import MinisCore

/// Conversation-editable app preferences: notification categories and keep-awake.
/// Both write the same controllers the Settings page edits. Launch-at-login is not
/// part of this surface.
@MainActor
extension SettingsCenter {
    /// nil when neither controller is installed; otherwise covers every value below.
    func conversationPreferencesRevision() -> String? {
        guard systemNotifications != nil || residentLifecycle != nil else { return nil }
        let lines = conversationPreferenceRows().map { "\($0.id)|\($0.value)" }
        return DeletionGate.fingerprint(Data(lines.sorted().joined(separator: "\n").utf8))
    }

    func conversationPreferenceRows() -> [(id: String, value: BL6SettingValue)] {
        var rows: [(id: String, value: BL6SettingValue)] = []
        if let systemNotifications {
            for category in SystemNotificationCategory.allCases {
                rows.append(("notifications.\(category.rawValue)", .toggle(systemNotifications.isEnabled(category))))
            }
        }
        if let residentLifecycle {
            rows.append(("resident.keep-awake", .toggle(residentLifecycle.keepAwakeDuringWork)))
        }
        return rows
    }

    func applyConversationPreference(
        key: String, value: BL6SettingValue
    ) -> Result<BL6SettingValue, BL6SettingsDispatchError> {
        guard case .toggle(let on) = value else {
            return .failure(.invalidIntent("preference value must be a toggle"))
        }
        if key == "resident.keep-awake", let residentLifecycle {
            let previous = residentLifecycle.keepAwakeDuringWork
            residentLifecycle.keepAwakeDuringWork = on
            return .success(.toggle(previous))
        }
        if key.hasPrefix("notifications."), let systemNotifications,
           let category = SystemNotificationCategory(rawValue: String(key.dropFirst("notifications.".count))) {
            let previous = systemNotifications.isEnabled(category)
            systemNotifications.setEnabled(category, on)
            return .success(.toggle(previous))
        }
        return .failure(.invalidIntent("unknown preference setting"))
    }
}
