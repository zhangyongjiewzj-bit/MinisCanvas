import SwiftUI
import Testing
@testable import MinisCanvasApp

@MainActor
@Suite("Task Center production filter icons")
struct TaskCenterFilterIcon2305Tests {
    @Test func statusSelectionUsesFilteringSemanticsAndExistingActiveTokens() {
        let all = TaskCenterFilterIconProjection.status(nil)
        #expect(all.icon == .filter)
        if case .normal = all.state {} else { Issue.record("all statuses must not look selected") }
        for selection in TaskCenterFilterStatus.allCases {
            let selected = TaskCenterFilterIconProjection.status(selection)
            #expect(selected.icon == .filter)
            if case .active = selected.state {} else { Issue.record("selected status must use active") }
            #expect(MinisIconView.renderSource(for: selected.icon) == .keyline)
            #expect(MinisIconTokens.primaryColor(for: selected.state) == MinisIconTokens.keylineOrangeA7A)
            #expect(MinisIconTokens.secondaryColor(for: selected.state) == MinisIconTokens.keylineOrangeA7A.opacity(0.26))
        }
        #expect(TaskCenterFilterIconProjection.status(nil).icon == all.icon)
    }

    @Test func sourceIsAConversationFilterAndClearingReturnsNeutral() {
        let selected = TaskCenterFilterIconProjection.sourceSession("synthetic-session-2305")
        #expect(selected.icon == .messages)
        #expect(selected.icon != .user)
        if case .active = selected.state {} else { Issue.record("selected source must use active") }
        #expect(MinisIconView.renderSource(for: selected.icon) == .keyline)
        #expect(MinisIconTokens.primaryColor(for: selected.state) == MinisIconTokens.keylineOrangeA7A)
        let cleared = TaskCenterFilterIconProjection.sourceSession(nil)
        #expect(cleared.icon == selected.icon)
        if case .normal = cleared.state {} else { Issue.record("cleared source must be neutral") }
        #expect(MinisIconTokens.primaryColor(for: cleared.state) == MinisIconTokens.neutralPrimary)
    }
}
