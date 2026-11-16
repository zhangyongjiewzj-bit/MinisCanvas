import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-COMMAND-04 scoped Escape production consumers")
@MainActor
struct Command04EscapeProductionConsumerTests {
    private var key: ShortcutBinding {
        ShortcutBinding(key: "e", modifiers: ShortcutModifiers(command: true, control: true))
    }
    private func store() -> ShortcutStore {
        ShortcutStore(defaults: UserDefaults(suiteName: "command04-escape-\(UUID().uuidString)")!)
    }
    private func pendingPair() throws -> (ChatStore, ComposerCommandAdjudicationCenter) {
        let chat = ChatStore()
        let center = ComposerCommandAdjudicationCenter()
        chat.configureComposerPolicy(ComposerPolicyFactSource(
            knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: chat.composerWorkspaceID, revision: "escape-rev", grantEpoch: "escape-epoch",
            leaseID: "escape-lease", expiresAt: Date().addingTimeInterval(600), revoked: false
        ))
        chat.onComposerCommandPolicy = { request, snapshot in
            center.evaluate(request: request, snapshot: snapshot, facts: chat.composerPolicyFacts)
        }
        center.onPendingTerminalResolution = { resolution in
            chat.resolvePendingComposerCommand(requestID: resolution.id, disposition: .reject)
        }
        chat.draftText = "/compact"
        chat.submitComposer()
        _ = try #require(center.pendingAdjudication)
        let request = try #require(chat.pendingComposerCommand)
        #expect(request.commandID == "compact")
        return (chat, center)
    }

    @Test func configuredEscapeConsumesPopoverBeforeActualPaletteAndPending() throws {
        let shortcutStore = store()
        #expect(ShortcutAction.escape.unavailableReason == nil)
        #expect(shortcutStore.setBinding(key, for: .escape) == nil)
        let bridge = BridgeStore(shortcutStore: shortcutStore)
        bridge.isCommandPalettePresented = true
        let host = FloatingMenuHost.shared
        host.present([FloatingMenuItem(kind: .button(title: "合成菜单项", icon: nil, role: nil, help: nil, action: {}))], at: .zero)
        defer { host.dismiss() }
        let (chat, center) = try pendingPair()
        let pending = try #require(center.pendingAdjudication)
        let deny = center.escapeDenialAction(requestID: pending.id, sessionID: pending.sessionID, chat: chat)
        func dispatch() -> Bool {
            shortcutStore.dispatchEscape(binding: key,
                closePopover: host.escapeDismissalAction(),
                closeSheet: bridge.commandPaletteEscapeAction(),
                denyPending: deny
            )
        }
        #expect(dispatch())
        #expect(!host.isPresented && bridge.isCommandPalettePresented)
        #expect(center.pendingAdjudication?.id == pending.id)
        #expect(dispatch())
        #expect(!bridge.isCommandPalettePresented)
        #expect(center.pendingAdjudication?.id == pending.id)
        #expect(dispatch())
        #expect(center.pendingAdjudication == nil && chat.pendingComposerCommand == nil)
        #expect(center.lastResolution?.outcome == .deniedByUser)
        #expect(!dispatch())
    }

    @Test func pendingOutletStillClosesCurrentFloatingPopoverBeforeDenying() throws {
        let shortcutStore = store()
        #expect(shortcutStore.setBinding(key, for: .escape) == nil)
        let (chat, center) = try pendingPair()
        let pending = try #require(center.pendingAdjudication)
        let deny = center.escapeDenialAction(requestID: pending.id, sessionID: pending.sessionID, chat: chat)
        let host = FloatingMenuHost.shared
        host.present([FloatingMenuItem(kind: .button(title: "合成菜单项", icon: nil, role: nil, help: nil, action: {}))], at: .zero)
        defer { host.dismiss() }
        // The mounted pending card supplies only its existing rejection outlet.
        #expect(shortcutStore.dispatchEscape(binding: key, denyPending: deny))
        #expect(!host.isPresented)
        #expect(center.pendingAdjudication?.id == pending.id)
        #expect(chat.pendingComposerCommand?.id == pending.id)
        center.denyCurrentAdjudication()
    }

    @Test func clearingOrRebindingRejectsCapturedOldShortcutWithoutClosingPalette() {
        let shortcutStore = store()
        #expect(shortcutStore.setBinding(key, for: .escape) == nil)
        let bridge = BridgeStore(shortcutStore: shortcutStore)
        bridge.isCommandPalettePresented = true
        let close = bridge.commandPaletteEscapeAction()
        #expect(shortcutStore.setBinding(ShortcutBinding(key: "", modifiers: .none), for: .escape) == nil)
        #expect(!shortcutStore.dispatchEscape(binding: key, closeSheet: close))
        #expect(bridge.isCommandPalettePresented)
        let replacement = ShortcutBinding(key: "b", modifiers: ShortcutModifiers(command: true, control: true))
        #expect(shortcutStore.setBinding(replacement, for: .escape) == nil)
        #expect(!shortcutStore.dispatchEscape(binding: key, closeSheet: close))
        #expect(bridge.isCommandPalettePresented)
        #expect(shortcutStore.reset(for: .escape) == nil)
        #expect(shortcutStore.binding(for: .escape).isEmpty)
        #expect(!shortcutStore.dispatchEscape(binding: replacement, closeSheet: close))
    }

    @Test func escapeConflictDoesNotOverwriteEitherLiveBinding() {
        let shortcutStore = store()
        #expect(shortcutStore.setBinding(key, for: .escape) == nil)
        #expect(shortcutStore.setBinding(ShortcutAction.newSession.defaultBinding, for: .escape) == .action(.newSession))
        #expect(shortcutStore.binding(for: .escape) == key)
        #expect(shortcutStore.binding(for: .newSession) == ShortcutAction.newSession.defaultBinding)
        #expect(shortcutStore.setBinding(ShortcutBinding(key: "q", modifiers: ShortcutModifiers.command), for: .escape) == .system)
        #expect(shortcutStore.binding(for: .escape) == key)
    }

    @Test func capturedEscapeDenialCannotRejectReplacementPendingOrRunExecutor() throws {
        let shortcutStore = store()
        #expect(shortcutStore.setBinding(key, for: .escape) == nil)
        let (chat, center) = try pendingPair()
        var executed = 0
        center.openCanonicalSettings = { executed += 1 }
        center.replaySubmittedCommand = { _ in executed += 1 }
        let original = try #require(center.pendingAdjudication)
        let stale = center.escapeDenialAction(requestID: original.id, sessionID: original.sessionID, chat: chat)
        chat.draftText = "/compact"
        chat.submitComposer()
        let replacement = try #require(center.pendingAdjudication)
        #expect(replacement.id != original.id)
        #expect(!shortcutStore.dispatchEscape(binding: key, denyPending: stale))
        #expect(center.pendingAdjudication?.id == replacement.id)
        #expect(chat.pendingComposerCommand?.id == replacement.id)
        let current = center.escapeDenialAction(requestID: replacement.id, sessionID: replacement.sessionID, chat: chat)
        #expect(shortcutStore.dispatchEscape(binding: key, denyPending: current))
        #expect(center.lastResolution?.id == replacement.id)
        #expect(center.lastResolution?.outcome == .deniedByUser)
        #expect(chat.pendingComposerCommand == nil && executed == 0)
    }
}
