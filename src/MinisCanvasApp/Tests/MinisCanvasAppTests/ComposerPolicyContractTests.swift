import AppKit
import CoreFoundation
import Foundation
import SwiftUI
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Composer App policy contracts")
@MainActor
struct ComposerPolicyContractTests {
    @Test("Native choice requires a real current item action and non-cancelled menu return")
    func nativeChoiceCommitContract() throws {
        let fixture = try PolicyMenuOwnerContractFixture()
        defer { fixture.close() }
        let baseButton = try fixture.button("Composer 任务模式")
        let button = try #require(baseButton as? ComposerPolicyIdentityButton)
        let menu = try #require(button.menu as? ComposerPolicyChoiceMenu)
        let original = fixture.chat.composerPolicySelection
        let item = menu.items[1]
        menu.captureNativeChoice(item)
        #expect(menu.chosenItem == nil)
        #expect(!button.performOwnedChoice { _, _ in true })
        #expect(fixture.chat.composerPolicySelection == original)
        #expect(!button.performOwnedChoice { choice, _ in
            choice.captureNativeChoice(item)
            return false
        })
        #expect(fixture.chat.composerPolicySelection == original)
        let foreign = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
        #expect(!button.performOwnedChoice { choice, _ in
            choice.captureNativeChoice(foreign)
            return true
        })
        #expect(fixture.chat.composerPolicySelection == original)
        item.isEnabled = false
        #expect(!button.performOwnedChoice { choice, _ in choice.captureNativeChoice(item); return true })
        item.isEnabled = true
        #expect(fixture.chat.composerPolicySelection == original)
        let oldID = item.accessibilityIdentifier()
        item.setAccessibilityIdentifier("foreign")
        #expect(!button.performOwnedChoice { choice, _ in choice.captureNativeChoice(item); return true })
        item.setAccessibilityIdentifier(oldID)
        #expect(fixture.chat.composerPolicySelection == original)
        var nestedAccepted = true
        let outerAccepted = button.performOwnedChoice { choice, _ in
            nestedAccepted = button.performOwnedChoice { _, _ in true }
            return false
        }
        #expect(!nestedAccepted)
        #expect(!outerAccepted)
        #expect(fixture.chat.composerPolicySelection == original)
        #expect(!button.performOwnedChoice { choice, _ in
            choice.setAccessibilityParent(NSObject())
            choice.captureNativeChoice(item)
            return true
        })
        menu.setAccessibilityParent(button)
        #expect(fixture.chat.composerPolicySelection == original)
        #expect(button.performOwnedChoice { choice, _ in choice.captureNativeChoice(item); return true })
        #expect(fixture.chat.composerPolicySelection.mode == ComposerTaskMode.allCases[1])
        #expect(fixture.chat.composerPolicySelection.approvalScope == original.approvalScope)
        #expect(fixture.chat.composerPolicySelection.effort == original.effort)
        #expect(button.committedSelectionIndex == nil)
        #expect(menu.chosenItem == nil)
    }

    @Test("Native AppKit choice commits once and survives reopening", arguments: PolicyMenuNativeOpen.allCases)
    func nativeAppKitChoicePersists(route: PolicyMenuNativeOpen) throws {
        let fixture = try PolicyMenuOwnerContractFixture()
        defer { fixture.close() }
        let button = try #require(fixture.button("Composer 工作量") as? ComposerPolicyIdentityButton)
        let menu = try #require(button.menu as? ComposerPolicyChoiceMenu)
        let original = fixture.chat.composerPolicySelection
        let forwarding = try PolicyMenuActionCounter(button: button)
        button.target = forwarding
        button.action = #selector(PolicyMenuActionCounter.forward(_:))

        // Actual AppKit tracking and key events choose the next item. No
        // selectItem or fake captureNativeChoice is a positive action witness.
        let driver = PolicyMenuNativeKeyboardDriver(button: button, keyCodes: [125, 36])
        defer { driver.close() }
        #expect(driver.run(open: route))
        #expect(driver.beganTracking)
        #expect(driver.actionCount == 1)
        #expect(fixture.chat.composerPolicySelection.effort == .high)
        #expect(fixture.chat.composerPolicySelection.mode == original.mode)
        #expect(fixture.chat.composerPolicySelection.approvalScope == original.approvalScope)
        #expect(forwarding.calls == 1)
        #expect(button.committedSelectionIndex == nil)
        #expect(menu.chosenItem == nil)
        driver.close()

        // A duplicate/late action after the menu lifetime is closed must not
        // even forward to the production binding owner a second time.
        button.commitSelectedPolicyItem(menu.items[2])
        #expect(forwarding.calls == 1)
        let cancelled = PolicyMenuNativeKeyboardDriver(button: button, keyCodes: [53])
        defer { cancelled.close() }
        #expect(cancelled.run(open: route))
        #expect(cancelled.actionCount == 0)
        #expect(fixture.chat.composerPolicySelection.effort == .high)
        #expect(forwarding.calls == 1)
    }

    @Test("Returning from native open cannot authorize a setter, cancellation or late action")
    func nativeChoiceCancellationClosesActionLease() throws {
        let fixture = try PolicyMenuOwnerContractFixture()
        defer { fixture.close() }
        let button = try #require(fixture.button("Composer 工作量") as? ComposerPolicyIdentityButton)
        let menu = try #require(button.menu as? ComposerPolicyChoiceMenu)
        let original = fixture.chat.composerPolicySelection
        // AX can return false before AppKit starts its asynchronous tracking.
        #expect(button.performNativeOwnedChoice { _ in false })
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        // A setter alone is never a user choice, even while that menu is open.
        button.selectItem(at: 2)
        #expect(!button.captureNativeSelectionAction())
        #expect(fixture.chat.composerPolicySelection == original)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        button.commitSelectedPolicyItem(menu.items[2])
        #expect(fixture.chat.composerPolicySelection == original)
        _ = CFRunLoopRunInMode(.defaultMode, 0.02, false)
        // A fully dispatched AppKit action is still late after cancellation.
        menu.performActionForItem(at: 2)
        #expect(fixture.chat.composerPolicySelection == original)
        #expect(button.committedSelectionIndex == nil)
        #expect(menu.chosenItem == nil)
        // No begin/no action also expires at the first closing turn.
        #expect(button.performNativeOwnedChoice { _ in false })
        _ = CFRunLoopRunInMode(.defaultMode, 0.02, false)
        menu.performActionForItem(at: 2)
        #expect(fixture.chat.composerPolicySelection == original)
        #expect(button.committedSelectionIndex == nil)
        #expect(menu.chosenItem == nil)
    }

    @Test("Native action rejects changed generation, menu, item or owner window",
          arguments: PolicyMenuNativeInvalidation.allCases)
    func nativeChoiceRejectsChangedWitness(change: PolicyMenuNativeInvalidation) throws {
        let fixture = try PolicyMenuOwnerContractFixture()
        defer { fixture.close() }
        let button = try #require(fixture.button("Composer 工作量") as? ComposerPolicyIdentityButton)
        let menu = try #require(button.menu as? ComposerPolicyChoiceMenu)
        let original = fixture.chat.composerPolicySelection
        #expect(button.performNativeOwnedChoice { choice in
            NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: choice)
            return true
        })
        button.selectItem(at: 2) // A post-selection fixture, never a success witness.
        var foreign: NSWindow?
        defer { foreign?.close() }
        switch change {
        case .generation:
            let titles = menu.items.map(\.title)
            button.removeAllItems(); button.addItems(withTitles: titles)
            button.bindIdentity(titles: titles)
        case .menu:
            button.menu = ComposerPolicyChoiceMenu(title: "foreign")
        case .items:
            menu.removeItem(at: 0)
        case .window:
            foreign = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                styleMask: [.titled], backing: .buffered, defer: false)
            foreign?.isReleasedWhenClosed = false
            foreign?.orderFront(nil)
            button.removeFromSuperview()
            foreign?.contentView?.addSubview(button)
        }
        menu.performActionForItem(at: min(2, menu.items.count - 1))
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        _ = CFRunLoopRunInMode(.defaultMode, 0.02, false)
        #expect(fixture.chat.composerPolicySelection == original)
        #expect(button.committedSelectionIndex == nil)
        #expect(menu.chosenItem == nil)
    }

    @Test("Production menu identities are stable, instance-unique and reject stale menus")
    func productionMenuIdentityContract() throws {
        let a = ComposerPolicyIdentityButton(frame: .zero, pullsDown: false)
        let b = ComposerPolicyIdentityButton(frame: .zero, pullsDown: false)
        for button in [a, b] { button.addItems(withTitles: ["one", "two"]); button.bindIdentity(titles: ["one", "two"]) }
        let menu = try #require(a.menu)
        let first = try #require(a.identityRequest(menu: menu, query: "two"))
        a.bindIdentity(titles: ["one", "two"])
        let same = try #require(a.identityRequest(menu: menu, query: "two"))
        #expect(NSDictionary(dictionary: first).isEqual(to: same))
        let otherMenu = try #require(b.menu)
        let other = try #require(b.identityRequest(menu: otherMenu, query: "two"))
        #expect(first["popup_id"] as? String != other["popup_id"] as? String)
        menu.items[1].setAccessibilityIdentifier("forged")
        #expect(a.identityRequest(menu: menu, query: "two") == nil)
        #expect(a.identityFailure == "PRODUCER_IDENTIFIER_STALE")
        a.bindIdentity(titles: ["one", "two"])
        a.removeAllItems(); a.addItems(withTitles: ["one", "two"]); a.bindIdentity(titles: ["one", "two"])
        let rebuiltMenu = try #require(a.menu)
        let changed = try #require(a.identityRequest(menu: rebuiltMenu, query: "two"))
        #expect(changed["generation"] as? Int != first["generation"] as? Int)
        #expect(changed["target_id"] as? String != first["target_id"] as? String)
        a.removeAllItems(); a.addItems(withTitles: ["duplicate", "duplicate"]); a.bindIdentity(titles: ["duplicate", "duplicate"])
        #expect(a.identityRequest(menu: try #require(a.menu), query: "duplicate") == nil)
        #expect(a.identityFailure == "PRODUCER_IDENTITY_INVALID")
    }

    @Test("Real production policy buttons preserve owner and only their bound field through action and restore")
    func productionMenuOwnerActionAndRestore() throws {
        let fixture = try PolicyMenuOwnerContractFixture()
        defer { fixture.close() }
        let original = fixture.chat.composerPolicySelection
        let session = fixture.chat.activeSessionID
        let draft = fixture.chat.draftText
        let messages = fixture.chat.messages.map(\.id)
        #expect(fixture.buttons("Composer 审批范围").isEmpty)
        for (label, index) in [("Composer 任务模式", 1), ("Composer 工作量", 2)] {
            let button = try fixture.button(label)
            let menu = try #require(button.menu)
            let selected = button.indexOfSelectedItem
            #expect(fixture.failure(button, menu) == nil)
            let producer = try #require(button as? ComposerPolicyIdentityButton)
            #expect(producer.performOwnedChoice { choice, _ in
                choice.captureNativeChoice(choice.items[index]); return true
            })
            var expected = original
            switch label {
            case "Composer 任务模式": expected.mode = ComposerTaskMode.allCases[index]
            default: expected.effort = ComposerEffort.allCases[index]
            }
            #expect(fixture.chat.composerPolicySelection == expected)
            #expect(fixture.failure(button, menu) == nil)
            #expect(button.menu === menu)
            #expect(fixture.chat.activeSessionID == session)
            #expect(fixture.chat.draftText == draft)
            #expect(fixture.chat.messages.map(\.id) == messages)
            #expect(producer.performOwnedChoice { choice, _ in
                choice.captureNativeChoice(choice.items[selected]); return true
            })
            #expect(fixture.chat.composerPolicySelection == original)
            #expect(fixture.failure(button, menu) == nil)
        }
    }

    @Test("Original action admission rejects a production button moved to a foreign window")
    func productionMenuForeignWindowRejected() throws {
        let fixture = try PolicyMenuOwnerContractFixture()
        defer { fixture.close() }
        let button = try fixture.button("Composer 任务模式")
        let menu = try #require(button.menu)
        let foreign = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 310, height: 260),
                               styleMask: [.titled], backing: .buffered, defer: false)
        foreign.isReleasedWhenClosed = false
        defer { foreign.close() }
        button.removeFromSuperview()
        try #require(foreign.contentView).addSubview(button)
        #expect(fixture.failure(button, menu) == "BUTTON_WINDOW_MISMATCH")
        fixture.expectRejected(button, menu)
    }

    @Test("Original action admission rejects a replaced production menu")
    func productionMenuReplacementRejected() throws {
        let fixture = try PolicyMenuOwnerContractFixture()
        defer { fixture.close() }
        let button = try fixture.button("Composer 任务模式")
        let originalMenu = try #require(button.menu)
        button.menu = NSMenu(title: "foreign")
        #expect(fixture.failure(button, originalMenu) == "BUTTON_MENU_MISMATCH")
        fixture.expectRejected(button, originalMenu)
    }

    @Test("Original action admission rejects stale generation despite a valid production owner")
    func productionMenuStaleGenerationRejected() throws {
        let fixture = try PolicyMenuOwnerContractFixture()
        defer { fixture.close() }
        let button = try fixture.button("Composer 任务模式")
        let menu = try #require(button.menu)
        #expect(fixture.failure(button, menu) == nil)
        fixture.expectRejected(button, menu, currentGeneration: false)
    }

    @Test("Original action admission rejects a closed production window")
    func productionMenuClosedWindowRejected() throws {
        let fixture = try PolicyMenuOwnerContractFixture()
        defer { fixture.close() }
        let button = try fixture.button("Composer 任务模式")
        let menu = try #require(button.menu)
        fixture.window.close()
        #expect(fixture.failure(button, menu) != nil)
        fixture.expectRejected(button, menu)
    }

    @Test("ChatStore owns one shared five-mode/four-scope selection")
    func chatStoreOwnsSharedSelection() {
        let chat = ChatStore()
        #expect(ComposerPolicyPresentation.modeLabels.map(\.0) == ComposerTaskMode.allCases)
        #expect(ComposerPolicyPresentation.scopeLabels.map(\.0) == ComposerApprovalScope.allCases)

        chat.composerPolicySelection.mode = .plan
        chat.composerPolicySelection.approvalScope = .workspace
        #expect(chat.composerPolicySelection.mode == .plan)
        #expect(chat.composerPolicySelection.approvalScope == .workspace)
    }

    @Test("Composer policy defaults persist and notify the production consumer")
    func settingsPersistAndCallback() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComposerPolicySettings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: directory),
            envStore: EnvVarStore(directory: directory),
            memoryStore: MemoryStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            logManager: LogManager(directory: directory, ringCapacity: 20)
        )
        var callbackValue: ComposerPolicySettings?
        center.onComposerPolicyChanged = { callbackValue = $0 }
        let policy = ComposerPolicySettings(
            mode: .bypassPermission,
            approvalScope: .workspace,
            effort: .high,
            bypassModeConfirmed: true
        )

        center.composerPolicy = policy

        #expect(center.settingsStore.settings.agent.composerPolicy == policy)
        #expect(callbackValue == policy)
        let reloaded = SettingsStore(directory: directory)
        #expect(reloaded.settings.agent.composerPolicy == policy)

        center.resetToDefaults()
        #expect(center.composerPolicy == .default)
        #expect(callbackValue == .default)
    }

    @Test func projectTaskFreezesSavedComposerPolicyAtStart() async throws {
        let instruction = "project Composer policy test"
        let fixture = try ScheduledTargetFixture(command: instruction, projectChildTarget: true)
        defer { fixture.cleanup() }
        fixture.chat.restoreSpeedTier(.fast)
        let engine = SnapshotCapturingChatEngine()
        fixture.chat.agentEngine = engine
        fixture.chat.restoreComposerPolicy(.init(mode: .plan, approvalScope: .turn, effort: .high))
        fixture.chat.composerPolicySelection = .init(
            mode: .auto, approvalScope: .session, effort: .low, bypassModeConfirmed: false
        )

        let taskStore = AgentTaskStore()
        let taskID = "project-composer-policy-task"
        let runID = "project-composer-policy-run"
        _ = try taskStore.enqueue(taskID: taskID, parentID: "project-composer-policy-parent",
            providerID: nil, modelID: nil)
        _ = try taskStore.startRun(taskID: taskID, runID: runID)
        let started = fixture.chat.startProjectTask(
            targetID: fixture.targetID.uuidString, projectID: fixture.projectID,
            instruction: instruction, runID: runID, taskStore: taskStore,
            authorization: { true }, onFinished: {}
        )
        try #require(started)
        let task = try #require(fixture.chat.turnTaskForTests(sessionID: fixture.targetID))
        fixture.chat.restoreComposerPolicy(.default)
        fixture.chat.composerPolicySelection = .init(
            mode: .bypassPermission, approvalScope: .workspace, effort: .low, bypassModeConfirmed: true
        )
        await task.value

        let snapshot = try #require(engine.snapshots.first)
        #expect(snapshot.mode == .plan)
        #expect(snapshot.approvalScope == .request)
        #expect(snapshot.effort == .high)
        #expect(!snapshot.bypassModeConfirmed)
        #expect(snapshot.sessionID == fixture.targetID.uuidString)
        #expect(snapshot.taskID == taskID)
        #expect(fixture.chat.activeSessionID == fixture.activeID)
        #expect(fixture.chat.draftText == "untouched active draft")
    }

    @Test("Changing Composer settings only affects the next immutable submission")
    func settingsChangeDoesNotMutateFrozenSnapshot() throws {
        let chat = ChatStore()
        chat.configureComposerPolicy(
            ComposerPolicyFactSource(
                knownCapabilities: ["canvas_mutation"],
                grantedCapabilities: ["canvas_mutation"],
                allowedWriteRoots: [],
                workspaceID: chat.composerWorkspaceID,
                revision: "settings-revision",
                grantEpoch: "settings-epoch",
                leaseID: "settings-lease",
                expiresAt: Date().addingTimeInterval(60)
            )
        )
        let first = ComposerPolicySelection(
            mode: .autoEdit,
            approvalScope: .turn,
            effort: .low,
            bypassModeConfirmed: false
        )
        let second = ComposerPolicySelection(
            mode: .plan,
            approvalScope: .workspace,
            effort: .high,
            bypassModeConfirmed: false
        )
        var callbackValue: ComposerPolicySelection?
        chat.onComposerPolicyChanged = { callbackValue = $0 }
        chat.composerPolicySelection = first
        var captured: [ComposerSubmissionSnapshot] = []
        chat.onSendCommand = { _, snapshot in
            captured.append(snapshot)
            return true
        }
        chat.draftText = "第一回合"
        chat.submitComposer()
        chat.composerPolicySelection = second
        chat.draftText = "第二回合"
        chat.submitComposer()

        #expect(callbackValue == second)
        #expect(captured.map(\.mode) == [.autoEdit, .plan])
        #expect(captured.map(\.approvalScope) == [.turn, .workspace])
        #expect(captured.map(\.effort) == [.low, .high])
    }

    @Test("Global and sidebar entries consume the same controls and all options")
    func bothComposerEntriesExposeSharedControls() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let global = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/MinisCanvasApp/GlobalComposerView.swift"
            ),
            encoding: .utf8
        )
        let sidebar = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/MinisCanvasApp/ChatSidebarView.swift"
            ),
            encoding: .utf8
        )
        #expect(global.contains("ComposerPolicyControls(chat: chat, modeShortcutBinding:"))
        #expect(sidebar.contains("ComposerPolicyControls(chat: chat, modeShortcutBinding:"))
        #expect(global.contains("ComposerPolicyControls"))
        #expect(sidebar.contains("ComposerPolicyControls"))
    }

    @Test("Settings UI exposes the persisted policy and bypass risk")
    func settingsUIExposesComposerPolicy() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settings = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/MinisCanvasApp/SettingsView.swift"
            ),
            encoding: .utf8
        )
        #expect(settings.contains("Section(\"新对话默认权限\")"))
        #expect(settings.contains("center.composerPolicy.mode"))
        #expect(!settings.contains("center.composerPolicy.approvalScope"))
        #expect(settings.contains("center.composerPolicy.effort"))
        #expect(settings.contains("本次选择只确认一次"))
        #expect(settings.contains("center.composerPolicy.protectCredentialPaths"))
        #expect(settings.contains("Policy05BypassSettingsConfirmation.setConfirmed(true, in: center)"))
    }

    @Test("production snapshot contains the immutable identity required by the gate")
    func snapshotCarriesProductionIdentity() throws {
        let chat = ChatStore()
        let facts = ComposerPolicyFactSource(
            knownCapabilities: ["canvas_mutation"],
            grantedCapabilities: ["canvas_mutation"],
            allowedWriteRoots: ["/tmp/composer-contract"],
            workspaceID: "workspace-contract",
            revision: "composer-revision-1",
            grantEpoch: "grant-epoch-1",
            leaseID: "composer-contract-lease",
            expiresAt: Date().addingTimeInterval(60)
        )
        chat.configureComposerPolicy(facts)
        chat.composerPolicySelection = ComposerPolicySelection(
            mode: .autoEdit,
            approvalScope: .turn,
            effort: .high,
            bypassModeConfirmed: false
        )
        var captured: ComposerSubmissionSnapshot?
        chat.onSendCommand = { _, snapshot in
            captured = snapshot
            return true
        }
        chat.draftText = "建节点 llm"
        chat.sendDraft()

        let snapshot = try #require(captured)
        #expect(snapshot.mode == .autoEdit)
        #expect(snapshot.approvalScope == .turn)
        #expect(snapshot.effort == .high)
        #expect(!snapshot.sessionID.isEmpty)
        #expect(snapshot.turnID == 0)
        #expect(!snapshot.taskID.isEmpty)
        #expect(!snapshot.messageID.isEmpty)
        #expect(!snapshot.workspaceID.isEmpty)
        #expect(snapshot.policyRevision == "composer-revision-1")
        #expect(snapshot.grantEpoch == "grant-epoch-1")
    }

    @Test("bypass acknowledgement is frozen at the Composer submission boundary")
    func bypassAcknowledgementIsFrozen() throws {
        let chat = ChatStore()
        chat.configureComposerPolicy(
            ComposerPolicyFactSource(
                knownCapabilities: ["canvas_mutation"],
                grantedCapabilities: ["canvas_mutation"],
                allowedWriteRoots: [],
                workspaceID: chat.composerWorkspaceID,
                revision: "bypass-revision",
                grantEpoch: "bypass-epoch",
                leaseID: "bypass-lease",
                expiresAt: Date().addingTimeInterval(60)
            )
        )
        chat.composerPolicySelection = ComposerPolicySelection(
            mode: .bypassPermission,
            approvalScope: .request,
            effort: .standard,
            bypassModeConfirmed: false
        )
        var captured: ComposerSubmissionSnapshot?
        chat.onSendCommand = { _, snapshot in
            captured = snapshot
            return true
        }

        chat.draftText = "建节点 未确认"
        chat.submitComposer()

        let snapshot = try #require(captured)
        #expect(snapshot.mode == .bypassPermission)
        #expect(!snapshot.bypassModeConfirmed)
        #expect(snapshot.policyRevision == "bypass-revision")
        #expect(snapshot.grantEpoch == "bypass-epoch")
    }

    @Test("legacy engine overload is fail-closed when a required snapshot is requested")
    func legacyEngineCannotDropSnapshot() async throws {
        let engine = SnapshotRejectingChatEngine()
        await #expect(throws: ComposerEngineError.missingPolicyFacts) {
            _ = try await engine.streamReply(
                provider: MockProvider.shared,
                history: [],
                systemPrompt: "",
                maxTokens: 64,
                conversationID: "session",
                authorizedSessionReadSessionID: nil,
                authorizedSessionReadScope: nil,
                turnID: 1,
                composerSnapshot: ComposerSubmissionSnapshot(
                    mode: .manual,
                    approvalScope: .request,
                    effort: .standard,
                    sessionID: "session",
                    turnID: 1,
                    taskID: "task",
                    messageID: "message",
                    workspaceID: "workspace",
                    createdAt: Date(),
                    policyRevision: "revision"
                )
            )
        }
    }

    @Test("fallback consumer requires matching production facts before streaming")
    func fallbackConsumerRequiresMatchingFacts() async throws {
        let snapshot = ComposerSubmissionSnapshot(
            mode: .auto,
            approvalScope: .request,
            effort: .standard,
            sessionID: "session-fallback",
            turnID: 1,
            taskID: "task-fallback",
            messageID: "message-fallback",
            workspaceID: "workspace-fallback",
            createdAt: Date(),
            policyRevision: "facts-fallback",
            grantEpoch: "epoch-fallback"
        )
        let engine = FallbackChatEngine(
            composerPolicyFacts: ComposerPolicyFactSource(
                knownCapabilities: [],
                grantedCapabilities: [],
                allowedWriteRoots: [],
                workspaceID: "workspace-other",
                revision: "facts-fallback",
                grantEpoch: "epoch-fallback",
                leaseID: "fallback-other-lease",
                expiresAt: Date().addingTimeInterval(60)
            )
        )

        await #expect(throws: ComposerEngineError.missingPolicyFacts) {
            _ = try await engine.streamReply(
                provider: MockProvider.shared,
                history: [ChatMessageUI(role: .user, content: "拒绝")],
                systemPrompt: "",
                maxTokens: 64,
                conversationID: snapshot.sessionID,
                authorizedSessionReadSessionID: nil,
                authorizedSessionReadScope: nil,
                turnID: snapshot.turnID,
                composerSnapshot: snapshot
            )
        }
    }

    @Test("fallback consumer forwards a verified snapshot to the provider")
    func fallbackConsumerStreamsWithVerifiedFacts() async throws {
        let facts = ComposerPolicyFactSource(
            knownCapabilities: [],
            grantedCapabilities: [],
            allowedWriteRoots: [],
            workspaceID: "workspace-fallback",
            revision: "facts-fallback",
            grantEpoch: "epoch-fallback",
            leaseID: "fallback-lease",
            expiresAt: Date().addingTimeInterval(60)
        )
        let snapshot = ComposerSubmissionSnapshot(
            mode: .auto,
            approvalScope: .request,
            effort: .standard,
            sessionID: "session-fallback",
            turnID: 1,
            taskID: "task-fallback",
            messageID: "message-fallback",
            workspaceID: facts.workspaceID,
            createdAt: Date(),
            policyRevision: facts.revision,
            grantEpoch: facts.grantEpoch
        )
        let stream = try await FallbackChatEngine(
            composerPolicyFacts: facts
        ).streamReply(
            provider: MockProvider.shared,
            history: [ChatMessageUI(role: .user, content: "回退快照")],
            systemPrompt: "",
            maxTokens: 64,
            conversationID: snapshot.sessionID,
            authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil,
            turnID: snapshot.turnID,
            composerSnapshot: snapshot
        )

        var text = ""
        for try await event in stream {
            if case .textDelta(let value) = event {
                text += value
            }
        }
        #expect(text.contains("收到：回退快照"))
    }

    @Test("fallback consumer rejects an invalid execution identity")
    func fallbackConsumerRejectsInvalidExecutionIdentity() async throws {
        let facts = ComposerPolicyFactSource(
            knownCapabilities: [],
            grantedCapabilities: [],
            allowedWriteRoots: [],
            workspaceID: "workspace-fallback-identity",
            revision: "facts-fallback-identity",
            grantEpoch: "epoch-fallback-identity",
            leaseID: "fallback-identity-lease",
            expiresAt: Date().addingTimeInterval(60)
        )
        let snapshot = ComposerSubmissionSnapshot(
            mode: .auto,
            approvalScope: .request,
            effort: .standard,
            sessionID: "session-fallback-identity",
            turnID: 1,
            taskID: "task-fallback-identity",
            messageID: "message-fallback-identity",
            workspaceID: facts.workspaceID,
            createdAt: Date(),
            policyRevision: facts.revision,
            grantEpoch: facts.grantEpoch
        )
        let invalidIdentity = AgentExecutionIdentity(
            turn: AgentTurnIdentity(
                sessionID: snapshot.sessionID,
                turnID: snapshot.turnID,
                messageID: ""
            ),
            operationID: "fallback-invalid-identity"
        )

        await #expect(throws: ChatTurnRuntimeSnapshotError.invalidExecutionIdentity) {
            _ = try await FallbackChatEngine(
                composerPolicyFacts: facts
            ).streamReply(
                provider: MockProvider.shared,
                history: [ChatMessageUI(role: .user, content: "身份拒绝")],
                systemPrompt: "",
                maxTokens: 64,
                conversationID: snapshot.sessionID,
                authorizedSessionReadSessionID: nil,
                authorizedSessionReadScope: nil,
                turnID: snapshot.turnID,
                composerSnapshot: snapshot,
                executionIdentity: invalidIdentity
            )
        }
    }

    @Test("fallback consumer accepts the exact Composer execution identity")
    func fallbackConsumerAcceptsValidExecutionIdentity() async throws {
        let facts = ComposerPolicyFactSource(
            knownCapabilities: [],
            grantedCapabilities: [],
            allowedWriteRoots: [],
            workspaceID: "workspace-fallback-valid-identity",
            revision: "facts-fallback-valid-identity",
            grantEpoch: "epoch-fallback-valid-identity",
            leaseID: "fallback-valid-identity-lease",
            expiresAt: Date().addingTimeInterval(60)
        )
        let snapshot = ComposerSubmissionSnapshot(
            mode: .auto,
            approvalScope: .request,
            effort: .standard,
            sessionID: "session-fallback-valid-identity",
            turnID: 2,
            taskID: "task-fallback-valid-identity",
            messageID: "user-message-fallback-valid-identity",
            workspaceID: facts.workspaceID,
            createdAt: Date(),
            policyRevision: facts.revision,
            grantEpoch: facts.grantEpoch
        )
        let identity = AgentExecutionIdentity(
            turn: AgentTurnIdentity(
                sessionID: snapshot.sessionID,
                turnID: snapshot.turnID,
                messageID: snapshot.messageID
            ),
            operationID: "fallback-valid-identity"
        )
        let stream = try await FallbackChatEngine(
            composerPolicyFacts: facts
        ).streamReply(
            provider: MockProvider.shared,
            history: [ChatMessageUI(role: .user, content: "身份通过")],
            systemPrompt: "",
            maxTokens: 64,
            conversationID: snapshot.sessionID,
            authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil,
            turnID: snapshot.turnID,
            composerSnapshot: snapshot,
            executionIdentity: identity
        )

        var text = ""
        for try await event in stream {
            if case .textDelta(let value) = event {
                text += value
            }
        }
        #expect(text.contains("收到：身份通过"))
    }

    @Test("Bridge production facts keep the same workspace across new sessions")
    func productionFactsSurviveNewSession() throws {
        let bridge = BridgeStore()
        bridge.attachProductionServices()
        let firstWorkspace = bridge.chat.composerWorkspaceID
        let firstFacts = bridge.chat.composerPolicyFacts

        bridge.chat.newSession()

        #expect(bridge.chat.composerWorkspaceID == firstWorkspace)
        #expect(bridge.chat.composerPolicyFacts.workspaceID == firstFacts.workspaceID)
        #expect(bridge.chat.composerPolicyFacts.revision == firstFacts.revision)
        #expect(bridge.chat.composerPolicyFacts.grantEpoch == firstFacts.grantEpoch)
    }

    @Test("retry creates a fresh snapshot with content and attachment metadata")
    func retryRebuildsComposerSnapshot() async throws {
        let chat = ChatStore()
        let sessionID = try #require(chat.activeSessionID)
        let engine = SnapshotCapturingChatEngine()
        chat.agentEngine = engine
        let workspaceID = chat.composerWorkspaceID
        chat.configureComposerPolicy(
            ComposerPolicyFactSource(
                knownCapabilities: ["file_read", "file_write"],
                grantedCapabilities: ["file_read", "file_write"],
                allowedWriteRoots: ["/tmp/composer-contract"],
                workspaceID: workspaceID,
                revision: "retry-revision",
                grantEpoch: "retry-epoch",
                leaseID: "retry-lease",
                expiresAt: Date().addingTimeInterval(60)
            )
        )
        chat.composerPolicySelection = ComposerPolicySelection(
            mode: .auto,
            approvalScope: .session,
            effort: .high,
            bypassModeConfirmed: false
        )
        let imageData = try ComposerMediaFixtures589.png()
        #expect(MediaPayloadValidation.failure(data: imageData, mimeType: "image/png") == nil)
        #expect(MediaPayloadValidation.failure(data: Data([1, 2, 3, 4]), mimeType: "image/png") == .unsupportedImageFormat)
        print("MEDIA644_RETRY pngBytes=\(imageData.count) originalInvalidPNGRejected=true")
        let attachment = ChatAttachment(
            id: UUID(),
            kind: .image,
            fileName: "reference.png",
            fileType: .image,
            mimeType: "image/png",
            size: Int64(imageData.count),
            data: imageData,
            fileURL: "/tmp/reference.png"
        )
        let content = ChatStore.composeUserContent(
            text: "保留完整正文",
            attachments: [attachment]
        )
        chat.appendUser(content, attachments: [attachment])
        let originalMessage = try #require(chat.messages.last)
        chat.markExecutionRunning(
            sessionID: sessionID,
            turnID: 17,
            taskID: "failed-task",
            updatedAt: Date(timeIntervalSince1970: 17)
        )
        chat.markExecutionFailed(
            sessionID: sessionID,
            reason: "provider failure",
            updatedAt: Date(timeIntervalSince1970: 18)
        )
        let identity = try #require(chat.sessionList.first?.retryIdentity)

        #expect(chat.retryFailedSession(identity))
        for _ in 0..<50 where engine.snapshots.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        let snapshot = try #require(engine.snapshots.first)
        #expect(snapshot.mode == .auto)
        #expect(snapshot.approvalScope == .session)
        #expect(snapshot.effort == .high)
        #expect(snapshot.messageID != originalMessage.id.uuidString)
        #expect(!snapshot.attemptID.isEmpty)
        #expect(snapshot.turnID == 0)
        #expect(snapshot.taskID != "failed-task")
        #expect(snapshot.policyRevision == "retry-revision")
        #expect(snapshot.grantEpoch == "retry-epoch")

        let attachmentValue = ComposerInputValue.object([
            "id": .string(attachment.id.uuidString),
            "kind": .string(attachment.kind.rawValue),
            "fileName": .string(attachment.fileName),
            "fileType": .string(attachment.fileType.rawValue),
            "mimeType": .string("image/png"),
            "size": .integer(Int64(imageData.count)),
            "dataByteCount": .integer(Int64(imageData.count)),
            "fileURL": .string("/tmp/reference.png")
        ])
        let expectedDigest = ComposerToolInput(values: [
            "content": .string(content),
            "attachments": .array([attachmentValue])
        ]).digest
        #expect(snapshot.inputDigest == expectedDigest)

        let changedMetadataDigest = ComposerToolInput(values: [
            "content": .string(content),
            "attachments": .array([
                .object([
                    "id": .string(attachment.id.uuidString),
                    "kind": .string(attachment.kind.rawValue),
                    "fileName": .string("changed.png"),
                    "fileType": .string(attachment.fileType.rawValue),
                    "mimeType": .string("image/png"),
                    "size": .integer(Int64(imageData.count)),
                    "dataByteCount": .integer(Int64(imageData.count)),
                    "fileURL": .string("/tmp/reference.png")
                ])
            ])
        ]).digest
        #expect(snapshot.inputDigest != changedMetadataDigest)
        chat.stopStreaming()
    }

    @Test("unconfigured production Canvas command is fail-closed with zero mutation")
    func unconfiguredCanvasCommandDoesNotMutate() throws {
        let bridge = BridgeStore()
        let before = bridge.canvas.graph.nodes.count
        let snapshot = ComposerSubmissionSnapshot(
            mode: .auto,
            approvalScope: .request,
            effort: .standard,
            sessionID: bridge.chat.activeSessionID?.uuidString ?? "session",
            turnID: 0,
            taskID: "task",
            attemptID: "attempt",
            messageID: "message",
            workspaceID: bridge.chat.composerWorkspaceID,
            createdAt: Date(),
            policyRevision: "missing-policy"
        )

        let handled = bridge.chat.onSendCommand?("建节点 文本", snapshot) ?? false

        #expect(!handled)
        #expect(bridge.canvas.graph.nodes.count == before)
    }

    @Test("configured Canvas bypass stays at zero dispatch for Plan and denial")
    func configuredCanvasNegativePathsHaveZeroDispatch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComposerCanvasNegative-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bridge = BridgeStore()
        bridge.attachProductionServices(
            fileAccessAllowedRoot: root,
            sessionDirectory: root,
            approvalDelegateOverride: DenyingComposerApprovalDelegate()
        )
        let before = bridge.canvas.graph.nodes.count

        bridge.chat.composerPolicySelection = ComposerPolicySelection(
            mode: .manual,
            approvalScope: .request,
            effort: .standard,
            bypassModeConfirmed: false
        )
        bridge.chat.draftText = "建节点 文本"
        bridge.chat.sendDraft()
        try await Task.sleep(for: .milliseconds(80))
        #expect(bridge.composerCanvasDispatchCount == 0)
        #expect(bridge.canvas.graph.nodes.count == before)

        bridge.chat.composerPolicySelection = ComposerPolicySelection(
            mode: .plan,
            approvalScope: .workspace,
            effort: .standard,
            bypassModeConfirmed: false
        )
        bridge.chat.draftText = "建节点 文本"
        bridge.chat.sendDraft()
        try await Task.sleep(for: .milliseconds(80))
        #expect(bridge.composerCanvasDispatchCount == 0)
        #expect(bridge.canvas.graph.nodes.count == before)
    }
}

private struct DenyingComposerApprovalDelegate: ApprovalDelegate {
    func requestApproval(_: ApprovalRequest) async -> ApprovalDecision {
        .deny
    }
}

private struct SnapshotRejectingChatEngine: ChatAgentEngine {
    var isAvailable: Bool { true }

    func streamReply(
        provider: any LLMProvider,
        history: [ChatMessageUI],
        systemPrompt: String,
        maxTokens: Int
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        throw ComposerEngineError.missingRequiredSnapshot
    }

    func streamReply(
        provider: any LLMProvider,
        history: [ChatMessageUI],
        systemPrompt: String,
        maxTokens: Int,
        conversationID: String?,
        authorizedSessionReadSessionID: String?,
        authorizedSessionReadScope: SessionReadScope?,
        turnID: Int?,
        composerSnapshot: ComposerSubmissionSnapshot
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        throw ComposerEngineError.missingPolicyFacts
    }

    func interrupt() {}

    func compactContext(
        provider: any LLMProvider,
        history: [ChatMessageUI],
        systemPrompt: String,
        keepRecent: Int
    ) async -> CompactionResult {
        CompactionResult(
            messages: history.map { message in
                LLMMessage(
                    role: message.role == .user ? .user : .assistant,
                    content: message.content,
                    images: message.llmImages,
                    audios: message.llmAudios
                )
            },
            summary: nil,
            compactedCount: 0
        )
    }
}

private final class SnapshotCapturingChatEngine: ChatAgentEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var capturedSnapshots: [ComposerSubmissionSnapshot] = []

    var snapshots: [ComposerSubmissionSnapshot] {
        lock.withLock { capturedSnapshots }
    }

    var isAvailable: Bool { true }

    func streamReply(
        provider: any LLMProvider,
        history: [ChatMessageUI],
        systemPrompt: String,
        maxTokens: Int
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        makeDoneStream()
    }

    func streamReply(
        provider: any LLMProvider,
        history: [ChatMessageUI],
        systemPrompt: String,
        maxTokens: Int,
        conversationID: String?,
        authorizedSessionReadSessionID: String?,
        authorizedSessionReadScope: SessionReadScope?,
        turnID: Int?,
        composerSnapshot: ComposerSubmissionSnapshot
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        lock.withLock {
            capturedSnapshots.append(composerSnapshot)
        }
        return makeDoneStream()
    }

    func streamReply(
        provider: any LLMProvider,
        history: [ChatMessageUI],
        systemPrompt: String,
        maxTokens: Int,
        conversationID: String?,
        authorizedSessionReadSessionID: String?,
        authorizedSessionReadScope: SessionReadScope?,
        turnID: Int?,
        composerSnapshot: ComposerSubmissionSnapshot,
        executionIdentity: AgentExecutionIdentity
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        guard executionIdentity.isValid,
              executionIdentity.turn.sessionID == composerSnapshot.sessionID,
              executionIdentity.turn.turnID == composerSnapshot.turnID,
              executionIdentity.turn.messageID == composerSnapshot.messageID,
              conversationID == nil || conversationID == executionIdentity.turn.sessionID,
              turnID == nil || turnID == executionIdentity.turn.turnID
        else {
            throw ChatTurnRuntimeSnapshotError.invalidExecutionIdentity
        }
        lock.withLock {
            capturedSnapshots.append(composerSnapshot)
        }
        return makeDoneStream()
    }

    func interrupt() {}

    func compactContext(
        provider: any LLMProvider,
        history: [ChatMessageUI],
        systemPrompt: String,
        keepRecent: Int
    ) async -> CompactionResult {
        CompactionResult(messages: [], summary: nil, compactedCount: 0)
    }

    private func makeDoneStream() -> AsyncThrowingStream<AgentStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.done(stopReason: .endTurn))
            continuation.finish()
        }
    }
}

/// Contract coverage for the actual AppKit producer; never substitutes for AX menu acceptance.
@MainActor
private final class PolicyMenuOwnerContractFixture {
    let chat: ChatStore
    let window: NSWindow
    let host: NSHostingView<ComposerPolicyControls>
    let controller = NSViewController()
    let caseID = "policy-owner-contract"

    init() throws {
        _ = NSApplication.shared
        let actualChat = ChatStore()
        actualChat.configureComposerPolicy(ComposerPolicyFactSource(
            knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: actualChat.composerWorkspaceID, revision: "policy-owner-contract-v1",
            grantEpoch: "policy-owner-contract-epoch", leaseID: "policy-owner-contract-lease",
            expiresAt: Date().addingTimeInterval(60), autonomyCeiling: .l2))
        chat = actualChat
        host = NSHostingView(rootView: ComposerPolicyControls(chat: actualChat))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 260),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        controller.view = host
        window.contentViewController = controller
        window.setAccessibilityIdentifier("uf03-owned-" + caseID)
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        do { _ = try button("Composer 任务模式") }
        catch { window.close(); throw error }
    }

    func buttons(_ label: String) -> [NSPopUpButton] {
        func buttons(_ view: NSView) -> [NSPopUpButton] {
            (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap(buttons)
        }
        return buttons(host).filter { $0.accessibilityLabel() == label }
    }

    func button(_ label: String) throws -> NSPopUpButton {
        let matches = buttons(label)
        #expect(matches.count == 1)
        return try #require(matches.count == 1 ? matches.first : nil)
    }

    func failure(_ button: NSPopUpButton, _ menu: NSMenu) -> String? {
        UF03OwnedPolicyMenuOwnership.failure(host: host, window: window, button: button,
                                            menu: menu, caseID: caseID)
    }

    func expectRejected(_ button: NSPopUpButton, _ menu: NSMenu, currentGeneration: Bool = true) {
        let before = chat.composerPolicySelection
        let draft = chat.draftText
        let messages = chat.messages.map(\.id)
        let session = chat.activeSessionID
        var deliveries = 0
        let turn = UF03OwnedMenuActionTurn(owner: controller, menu: menu,
            deadline: ProcessInfo.processInfo.systemUptime + 0.5,
            isCurrentGeneration: { currentGeneration },
            ownsTarget: { self.failure(button, menu) == nil },
            startAction: { completion in deliveries += 1; completion(true); return true },
            cleanup: { menu.cancelTracking() })
        defer { turn.invalidate() }
        #expect(!turn.arm())
        #expect(deliveries == 0)
        #expect(turn.actionCount == 0)
        #expect(chat.composerPolicySelection == before)
        #expect(chat.draftText == draft)
        #expect(chat.messages.map(\.id) == messages)
        #expect(chat.activeSessionID == session)
    }

    func close() { window.close() }
}

@MainActor
private final class PolicyItemActionReceiver: NSObject {
    var indices: [Int] = []
    @objc func accept(_ sender: NSPopUpButton) { indices.append(sender.indexOfSelectedItem) }
}

// A native lifecycle probe: AppKit itself opens/tracks the menu and dispatches
// posted keyboard events. These tests require the single UI resource.
enum PolicyMenuNativeOpen: CaseIterable, Sendable { case accessibility, mouse, keyboard }
enum PolicyMenuNativeInvalidation: CaseIterable, Sendable { case generation, menu, items, window }

@MainActor
private final class PolicyMenuActionCounter: NSObject {
    private let target: AnyObject
    private let action: Selector
    private(set) var calls = 0
    init(button: NSPopUpButton) throws {
        target = try #require(button.target)
        action = try #require(button.action)
    }
    @objc func forward(_ sender: NSPopUpButton) {
        calls += 1
        _ = sender.sendAction(action, to: target)
    }
}

@MainActor
private final class PolicyMenuNativeKeyboardDriver: NSObject {
    let button: ComposerPolicyIdentityButton
    let keyCodes: [UInt16]
    private var inputObserver: CFRunLoopObserver?
    private var deadlineTimer: Timer?
    private var endedTracking = false
    private var expired = false
    private(set) var beganTracking = false
    private(set) var actionCount = 0

    init(button: ComposerPolicyIdentityButton, keyCodes: [UInt16]) {
        self.button = button; self.keyCodes = keyCodes
    }

    func run(open route: PolicyMenuNativeOpen) -> Bool {
        guard let menu = button.menu, let window = button.window else { return false }
        window.makeKeyAndOrderFront(nil)
        for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification,
                     NSMenu.didSendActionNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(menuNotification(_:)),
                name: name, object: menu)
        }
        let timer = Timer(timeInterval: 2, target: self, selector: #selector(deadline(_:)),
            userInfo: nil, repeats: false)
        deadlineTimer = timer
        RunLoop.main.add(timer, forMode: .default)
        RunLoop.main.add(timer, forMode: .eventTracking)
        switch route {
        case .accessibility:
            guard button.accessibilityPerformPress() else { return false }
        case .keyboard:
            guard let event = keyEvent(code: 49, type: .keyDown) else { return false }
            button.keyDown(with: event)
        case .mouse:
            let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            guard let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                clickCount: 1, pressure: 1) else { return false }
            button.mouseDown(with: event)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !endedTracking && !expired && ProcessInfo.processInfo.systemUptime < deadline {
            _ = CFRunLoopRunInMode(.defaultMode, 0.02, false)
        }
        // Service the menu's closing turn, including a final native item action.
        _ = CFRunLoopRunInMode(.defaultMode, 0.02, false)
        return beganTracking && endedTracking && !expired
    }

    @objc private func menuNotification(_ notification: Notification) {
        switch notification.name {
        case NSMenu.didBeginTrackingNotification:
            guard !beganTracking else { return }
            beganTracking = true
            let observer = composerPolicyTurnBoundaryObserver { [weak self] in
                guard let self else { return }
                self.inputObserver = nil
                for code in self.keyCodes {
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        if let event = self.keyEvent(code: code, type: type) {
                            NSApplication.shared.postEvent(event, atStart: false)
                        }
                    }
                }
            }
            inputObserver = observer
            if let observer {
                CFRunLoopAddObserver(CFRunLoopGetMain(), observer,
                    CFRunLoopMode(rawValue: RunLoop.Mode.eventTracking.rawValue as CFString))
            }
        case NSMenu.didEndTrackingNotification: endedTracking = true
        case NSMenu.didSendActionNotification: actionCount += 1
        default: break
        }
    }

    private func keyEvent(code: UInt16, type: NSEvent.EventType) -> NSEvent? {
        guard let window = button.window else { return nil }
        let characters: String
        switch code {
        case 125: characters = "\u{F701}"
        case 36: characters = "\r"
        case 53: characters = "\u{1B}"
        default: characters = " "
        }
        return NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code)
    }

    @objc private func deadline(_ timer: Timer) {
        expired = true
        button.menu?.cancelTracking()
    }

    func close() {
        NotificationCenter.default.removeObserver(self)
        if let observer = inputObserver { CFRunLoopObserverInvalidate(observer) }
        inputObserver = nil
        deadlineTimer?.invalidate(); deadlineTimer = nil
    }
}
