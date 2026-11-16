import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-COMMAND-04 inline slash Escape production consumer")
@MainActor
struct Command04InlineSlashEscapeConsumerTests {
    private var key: ShortcutBinding {
        ShortcutBinding(key: "e", modifiers: ShortcutModifiers(command: true, control: true))
    }
    private func store() -> ShortcutStore {
        ShortcutStore(defaults: UserDefaults(suiteName: "command04-inline-escape-\(UUID().uuidString)")!)
    }
    private func rows(_ chat: ChatStore, dismissed: String?) -> [ComposerSlashMenuEntry] {
        GlobalComposer.slashMenuEntries(
            for: chat.draftText, dismissedContextKey: dismissed,
            contextKey: { "\(chat.activeSessionID?.uuidString ?? "none")\u{001F}\(chat.draftText)" },
            registry: { chat.registeredComposerCommandRegistry },
            sessionState: { .neutral }, canvasAvailable: { false }
        )
    }
    private func context(_ chat: ChatStore) -> String {
        "\(chat.activeSessionID?.uuidString ?? "none")\u{001F}\(chat.draftText)"
    }

    @Test func configuredShortcutDismissesCurrentProductionProjectionWithoutSubmitting() throws {
        let shortcuts = store()
        let bridge = BridgeStore(shortcutStore: shortcuts)
        let chat = bridge.chat
        chat.draftText = "/help"
        var selected: String? = "help"
        var dismissed: String?
        let before = rows(chat, dismissed: dismissed)
        #expect(before.map(\.id) == ["help"])
        #expect(shortcuts.setBinding(key, for: .escape) == nil)
        // Old inline menu supplied no outlet: a matching configured key alone
        // cannot consume its real registry-derived completion projection.
        #expect(!shortcuts.dispatchEscape(binding: key))
        #expect(rows(chat, dismissed: dismissed).map(\.id) == ["help"])
        #expect(shortcuts.dispatchEscape(binding: key, closePopover: {
            GlobalComposer.dismissSlashCompletion(
                entries: rows(chat, dismissed: dismissed), contextKey: context(chat),
                selectedCommandID: &selected, dismissedContextKey: &dismissed
            )
        }))
        #expect(selected == nil && dismissed == context(chat))
        #expect(rows(chat, dismissed: dismissed).isEmpty)
        #expect(chat.draftText == "/help")
        #expect(chat.pendingComposerCommand == nil && !chat.isActiveSessionStreaming)
        // Dismissal is scoped to this draft/session; it does not disable future
        // completions or change the canonical vocabulary.
        chat.draftText = "/model"
        #expect(rows(chat, dismissed: dismissed).map(\.id) == ["model"])
    }

    @Test func defaultClearAndRebindNeverInvokeInlineDismissal() {
        let shortcuts = store()
        let chat = BridgeStore(shortcutStore: shortcuts).chat
        chat.draftText = "/help"
        var selected: String? = "help"
        var dismissed: String?
        func attempt(_ binding: ShortcutBinding) -> Bool {
            shortcuts.dispatchEscape(binding: binding, closePopover: {
                GlobalComposer.dismissSlashCompletion(
                    entries: rows(chat, dismissed: dismissed), contextKey: context(chat),
                    selectedCommandID: &selected, dismissedContextKey: &dismissed
                )
            })
        }
        #expect(shortcuts.binding(for: .escape).isEmpty)
        #expect(!attempt(key))
        #expect(shortcuts.setBinding(key, for: .escape) == nil)
        #expect(shortcuts.setBinding(ShortcutBinding(key: "", modifiers: .none), for: .escape) == nil)
        #expect(!attempt(key))
        let replacement = ShortcutBinding(key: "g", modifiers: ShortcutModifiers(command: true, control: true))
        #expect(shortcuts.setBinding(replacement, for: .escape) == nil)
        #expect(!attempt(key))
        #expect(selected == "help" && dismissed == nil)
        #expect(rows(chat, dismissed: dismissed).map(\.id) == ["help"])
        #expect(attempt(replacement))
        #expect(rows(chat, dismissed: dismissed).isEmpty)
    }

    @Test func nativeEscapeUsesSameDismissalAndEmptyMenuCannotConsume() {
        let chat = ChatStore()
        chat.registeredComposerCommandRegistry.registerComposerCommands()
        chat.draftText = "/help"
        var selected: String? = "help"
        var dismissed: String?
        let entries = rows(chat, dismissed: dismissed)
        var completion = CommandCompletionState(suggestions: entries.map(\.completionCommand), selectedIndex: 0)
        guard case .dismiss = completion.handle(.escape) else {
            Issue.record("native Escape must reach the existing dismissal action")
            return
        }
        #expect(GlobalComposer.dismissSlashCompletion(
            entries: entries, contextKey: context(chat),
            selectedCommandID: &selected, dismissedContextKey: &dismissed
        ))
        #expect(rows(chat, dismissed: dismissed).isEmpty && selected == nil)
        let retainedContext = dismissed
        #expect(!GlobalComposer.dismissSlashCompletion(
            entries: rows(chat, dismissed: dismissed), contextKey: "different-context",
            selectedCommandID: &selected, dismissedContextKey: &dismissed
        ))
        #expect(dismissed == retainedContext && chat.draftText == "/help")
    }
}
