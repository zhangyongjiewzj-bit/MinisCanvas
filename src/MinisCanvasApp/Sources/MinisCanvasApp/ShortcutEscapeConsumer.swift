import SwiftUI

/// A configured Escape only reaches an already mounted dismissal outlet.
/// No event monitor, new command, approval grant, or execution path is installed.
@MainActor
extension ShortcutStore {
    @discardableResult
    func dispatchEscape(
        binding: ShortcutBinding,
        closePopover: () -> Bool = { false },
        closeSheet: () -> Bool = { false },
        denyPending: () -> Bool = { false }
    ) -> Bool {
        let current = self.binding(for: .escape)
        guard !current.isEmpty, binding == current else { return false }
        // The existing in-window floating menu is above even an inline
        // pending card. Preserve that priority regardless of which local
        // shortcut button receives the event.
        if FloatingMenuHost.shared.isPresented {
            FloatingMenuHost.shared.dismiss()
            return true
        }
        // Consume just the frontmost available outlet; never dismiss a second
        // surface or reject a pending request while a nearer surface consumes it.
        return closePopover() || closeSheet() || denyPending()
    }
}

@MainActor
extension BridgeStore {
    func commandPaletteEscapeAction() -> () -> Bool {
        { [weak self] in
            guard let self, self.isCommandPalettePresented else { return false }
            self.isCommandPalettePresented = false
            return true
        }
    }
}

@MainActor
extension FloatingMenuHost {
    func escapeDismissalAction() -> () -> Bool {
        { [weak self] in
            guard let self, self.isPresented else { return false }
            self.dismiss()
            return true
        }
    }
}

@MainActor
extension ComposerCommandAdjudicationCenter {
    func escapeDenialAction(
        requestID: UUID, sessionID: String, chat: ChatStore
    ) -> () -> Bool {
        { [weak self, weak chat] in
            guard let self, let chat,
                  chat.activeSessionID?.uuidString == sessionID,
                  self.pendingAdjudication?.id == requestID,
                  self.pendingAdjudication?.sessionID == sessionID else { return false }
            self.denyCurrentAdjudication()
            return true
        }
    }
}

private struct ShortcutEscapeModifier: ViewModifier {
    @Environment(ShortcutStore.self) private var store: ShortcutStore?
    let closePopover: () -> Bool
    let closeSheet: () -> Bool
    let denyPending: () -> Bool

    func body(content: Content) -> some View {
        content.background {
            if let store {
                let binding = store.binding(for: .escape)
                if !binding.isEmpty {
                    Button("") {
                        store.dispatchEscape(
                            binding: binding, closePopover: closePopover,
                            closeSheet: closeSheet,
                            denyPending: denyPending
                        )
                    }
                    .shortcutKey(binding)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
                }
            }
        }
    }
}

extension View {
    func escapeShortcut(
        closePopover: @escaping () -> Bool = { false },
        closeSheet: @escaping () -> Bool = { false },
        denyPending: @escaping () -> Bool = { false }
    ) -> some View {
        modifier(ShortcutEscapeModifier(
            closePopover: closePopover, closeSheet: closeSheet, denyPending: denyPending
        ))
    }
}
