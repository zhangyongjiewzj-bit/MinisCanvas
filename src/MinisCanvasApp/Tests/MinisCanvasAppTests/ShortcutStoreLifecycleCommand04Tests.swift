import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-COMMAND-04 快捷键持久生命周期")
@MainActor
struct ShortcutStoreLifecycleCommand04Tests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "command04-lifecycle-\(UUID().uuidString)")!
    }

    @Test func everyCatalogActionRebindClearConflictAndRestoreSurvivesReopen() {
        // N06 adds the approved Command-/ shortcut reference action to the original catalog.
        let actions: [ShortcutAction] = [
            .commandPalette, .mainPaneChat, .mainPaneCanvas, .toggleSessionSidebar,
            .toggleContextPanel, .sendMessage, .stopGeneration, .createPipeline,
            .openSettings, .openShortcutReference, .newSession, .compactContext,
            .runCanvas, .cancelCanvas, .toggleMiniMap, .focusComposer, .composerMode,
            .nextTask, .approveRequest, .rejectRequest, .escape, .inputHistorySearch
        ]
        #expect(ShortcutAction.allCases == actions)
        #expect(actions.count == 22)
        let uniqueKeys = Array("abcdefghijklmnopqrstuv")

        for (index, action) in actions.enumerated() {
            let defaults = makeDefaults()
            let binding = ShortcutBinding(
                key: String(uniqueKeys[index]),
                modifiers: ShortcutModifiers(command: true, control: true, option: true, shift: true)
            )
            let writer = ShortcutStore(defaults: defaults)

            #expect(writer.setBinding(binding, for: action) == nil)
            #expect(ShortcutStore(defaults: defaults).binding(for: action) == binding)

            let empty = ShortcutBinding(key: "", modifiers: .none)
            let requiresApprovalBinding = action == .approveRequest || action == .rejectRequest
            let expectedAfterClear = requiresApprovalBinding ? binding : empty
            let expectedClearConflict: ShortcutConflict? = requiresApprovalBinding ? .approvalSafety : nil
            #expect(writer.setBinding(empty, for: action) == expectedClearConflict)
            let cleared = ShortcutStore(defaults: defaults)
            #expect(cleared.binding(for: action) == expectedAfterClear)

            let occupiedAction: ShortcutAction = action == .newSession ? .mainPaneChat : .newSession
            let occupiedBinding = occupiedAction.defaultBinding
            #expect(cleared.setBinding(occupiedBinding, for: action) == .action(occupiedAction))
            #expect(cleared.setBinding(
                ShortcutBinding(key: "q", modifiers: ShortcutModifiers.command), for: action
            ) == .system)
            #expect(ShortcutStore(defaults: defaults).binding(for: action) == expectedAfterClear)

            #expect(cleared.reset(for: action) == nil)
            #expect(ShortcutStore(defaults: defaults).binding(for: action) == action.defaultBinding)
        }
    }

    @Test func resetAllPersistsAfterMixedRebindAndClear() {
        let defaults = makeDefaults()
        let writer = ShortcutStore(defaults: defaults)
        #expect(writer.setBinding(
            ShortcutBinding(key: "g", modifiers: ShortcutModifiers.command), for: .createPipeline
        ) == nil)
        #expect(writer.setBinding(
            ShortcutBinding(key: "", modifiers: .none), for: .newSession
        ) == nil)
        #expect(ShortcutStore(defaults: defaults).binding(for: .newSession).isEmpty)

        writer.resetAll()
        let reopened = ShortcutStore(defaults: defaults)
        for action in ShortcutAction.allCases {
            #expect(reopened.binding(for: action) == action.defaultBinding)
        }
    }

    @Test func defaultsNeverClaimSystemReservedBindings() {
        for action in ShortcutAction.allCases {
            #expect(!ShortcutStore.systemReserved.contains(action.defaultBinding))
        }
        #expect(ShortcutAction.commandPalette.defaultBinding == ShortcutBinding(
            key: "k", modifiers: ShortcutModifiers.command
        ))
    }

    @Test func catalogExposesNextTaskAndScopedEscape() {
        #expect(ShortcutAction.nextTask.defaultBinding == ShortcutBinding(
            key: "j", modifiers: ShortcutModifiers.command
        ))
        #expect(ShortcutAction.nextTask.unavailableReason == nil)
        #expect(ShortcutAction.escape.defaultBinding.isEmpty)
        #expect(ShortcutAction.escape.unavailableReason == nil)
        #expect(ShortcutAction.focusComposer.unavailableReason == nil)
    }

    @Test func paletteApprovalMetadataCannotBypassRenderedCard() async throws {
        let defaults = makeDefaults()
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults),
            preferencesDefaults: defaults
        )
        for id in ["ui.agent.approve", "ui.agent.reject"] {
            let command = try #require(bridge.commandRegistry.command(id: id))
            #expect(command.currentAvailability == .disabled(reason: "请在当前工具审批弹窗操作"))
            do {
                _ = try await bridge.commandRegistry.execute(id: id)
                Issue.record("Approval metadata executed without a rendered card: \(id)")
            } catch let error as CommandExecutionError {
                #expect(error == .disabled(commandID: id, reason: "请在当前工具审批弹窗操作"))
            }
        }
    }

    @Test func renderedApprovalActionsKeepTheOriginalTwoStepWaiter() async throws {
        let center = ApprovalPromptCenter(expirationInterval: 60)
        let request = ApprovalRequest(
            id: "command04-synthetic", toolName: "synthetic_tool",
            inputSummary: "FAKE input", riskLevel: .high,
            requiresApproval: true, requiresSecondConfirmation: true
        )
        let decisionTask = Task { await center.present(request) }
        defer { decisionTask.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while center.pendingRequest == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        guard center.pendingRequest != nil else {
            Issue.record("Synthetic approval card was not presented")
            decisionTask.cancel()
            return
        }

        try await Task.sleep(for: .milliseconds(500))
        try #require(center.pendingRequest == request && !center.awaitingConfirmation)
        let firstStep = center.actionsForPresentedRequest()
        firstStep.approve()
        #expect(center.awaitingConfirmation)
        #expect(center.pendingRequest != nil)
        let secondStep = center.actionsForPresentedRequest()
        try await Task.sleep(for: .milliseconds(500))
        try #require(center.pendingRequest == request && center.awaitingConfirmation)
        secondStep.approve()
        let decision = await decisionTask.value
        #expect(decision.approved)
        #expect(decision.confirmed)
    }
}
