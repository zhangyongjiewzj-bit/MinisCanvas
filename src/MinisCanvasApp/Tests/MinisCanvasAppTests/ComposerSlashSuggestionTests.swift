import Testing
import Foundation
import AppKit
import MinisCore
@testable import MinisCanvasApp

@Suite("Composer slash suggestions")
@MainActor
struct ComposerSlashSuggestionTests {
    @Test func slashPrefixUsesCanonicalCommandCompletion() {
        let registry = CommandRegistry()
        registry.registerComposerCommands()

        // W4-036 (D-COMPOSER-17): the menu covers the full slash vocabulary in
        // stable order; unrouted rows render as 阻断 and can never dispatch.
        // D-COMMAND-02 (DEV-284): that order is the registry's own declaration
        // order, so the expectation is read from `CommandRegistry` instead of an
        // App-side literal list — a registry that grows keeps this test meaningful.
        #expect(GlobalComposer.slashSuggestions(for: "/", registry: registry)
            .map(\.id) == SlashRegistryExpectations.canonicalComposerIDs()
                + registry.allCommands().map(\.id).filter {
                    !CommandRegistry.composerCommandIDs.contains($0)
                })
        #expect(GlobalComposer.slashSuggestions(for: "/co", registry: registry)
            .map(\.id) == ["commands", "copy", "compact", "context", "usage"])
        #expect(GlobalComposer.slashSuggestions(for: "compact", registry: registry).isEmpty)
    }

    @Test func compactSelectionUsesCanonicalDraftAndLandedSendBoundary() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/MinisCanvasApp/GlobalComposerView.swift"
            ),
            encoding: .utf8
        )
        #expect(source.contains("GlobalComposer.acceptedSlashDraft("))
        #expect(source.contains("send()"))
        #expect(source.contains("ComposerSlashCommandMenu.entries("))
        #expect(source.contains("chat.submitComposer()"))
    }

    @Test func completionPathDoesNotCreateAnotherRegistryOrMutateTranscript() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/MinisCanvasApp/GlobalComposerView.swift"
            ),
            encoding: .utf8
        )
        #expect(!source.contains("CommandRegistry("))
        #expect(!source.contains("appendUser"))
        #expect(!source.contains("streamReply"))
    }

    @Test func nativeTextViewDownThenReturnUsesRegistryAndRealComposerBoundary() {
        let registry = CommandRegistry.shared
        registry.registerComposerCommands()
        let chat = ChatStore()
        chat.draftText = "/co"
        chat.onComposerCommandPolicy = { _, _ in .pending }

        let field = ScrollableComposerTextView(
            text: .constant(chat.draftText),
            font: .systemFont(ofSize: 13),
            onSend: {}
        )
        let coordinator = ScrollableComposerTextView.Coordinator(field)
        let textView = ComposerPasteAwareTextView(frame: .zero)
        textView.string = "/co"

        let suggestions = GlobalComposer.slashSuggestions(for: chat.draftText, registry: registry)
        var completion = CommandCompletionState(suggestions: suggestions, selectedIndex: 0)
        coordinator.onCommandKey = { key in
            switch key {
            case .down:
                _ = completion.handle(.down)
                return true
            case .returnKey(false):
                guard let command = completion.selected else { return false }
                chat.draftText = "/\(command.id)"
                chat.submitComposer()
                return true
            default:
                return false
            }
        }

        // Canonical /co declaration order includes copy, context and cost's
        // usage alias. Keep multi-row native navigation to compact at index 2.
        let expectedIDs = ["commands", "copy", "compact", "context", "usage"]
        #expect(suggestions.map(\.id) == expectedIDs)
        #expect(completion.selected?.id == expectedIDs[0])
        for expectedID in expectedIDs[1...2] {
            #expect(
                coordinator.textView(
                    textView,
                    doCommandBy: NSSelectorFromString("moveDown:")
                )
            )
            #expect(completion.selected?.id == expectedID)
        }
        #expect(
            coordinator.textView(
                textView,
                doCommandBy: NSSelectorFromString("insertNewline:")
            )
        )
        #expect(chat.pendingComposerCommand?.commandID == "compact")
        #expect(chat.messages.allSatisfy { !$0.content.contains("/compact") })
    }

    @Test func nativeTabCompletesWithoutDispatchAndEscapePreservesDraft() {
        let registry = CommandRegistry.shared
        registry.registerComposerCommands()
        let chat = ChatStore()
        chat.draftText = "/co"
        let field = ScrollableComposerTextView(
            text: .constant(chat.draftText),
            font: .systemFont(ofSize: 13),
            onSend: {}
        )
        let coordinator = ScrollableComposerTextView.Coordinator(field)
        let textView = ComposerPasteAwareTextView(frame: .zero)
        textView.string = "/co"
        let suggestions = GlobalComposer.slashSuggestions(for: chat.draftText, registry: registry)
        var completion = CommandCompletionState(suggestions: suggestions, selectedIndex: 0)
        coordinator.onCommandKey = { key in
            switch key {
            case .tab:
                guard case .accept(let commandID) = completion.handle(.tab) else { return false }
                chat.draftText = "/\(commandID)"
                return true
            case .escape:
                _ = completion.handle(.escape)
                return true
            default:
                return false
            }
        }

        #expect(
            coordinator.textView(
                textView,
                doCommandBy: NSSelectorFromString("insertTab:")
            )
        )
        // "/co" now filters the Phase 3 vocabulary to [commands, compact];
        // index 0 completion writes "/commands" without dispatching.
        #expect(chat.draftText == "/commands")
        #expect(chat.pendingComposerCommand == nil)

        chat.draftText = "/co"
        textView.string = "/co"
        #expect(
            coordinator.textView(
                textView,
                doCommandBy: NSSelectorFromString("cancelOperation:")
            )
        )
        #expect(chat.draftText == "/co")
    }

    @Test func nativeSelectorsCoverFocusAndImeBoundaries() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "Sources/MinisCanvasApp/ScrollableComposerTextView.swift"
                ),
            encoding: .utf8
        )
        #expect(ComposerNativeKeyRouting.key(
            for: NSSelectorFromString("moveUp:"),
            modifierFlags: []
        ) == .up)
        #expect(ComposerNativeKeyRouting.key(
            for: NSSelectorFromString("insertTab:"),
            modifierFlags: []
        ) == .tab)
        #expect(ComposerNativeKeyRouting.key(
            for: NSSelectorFromString("insertTab:"),
            modifierFlags: [.shift]
        ) == .shiftTab)
        #expect(ComposerNativeKeyRouting.key(
            for: NSSelectorFromString("insertBacktab:"),
            modifierFlags: []
        ) == .shiftTab)
        #expect(source.contains("hasMarkedText()"))
        #expect(source.contains("selectKeyView(following: textView)"))
        #expect(source.contains("selectKeyView(preceding: textView)"))
    }
    @Test func nativeFocusTraversalAndMarkedTextUseTheActualAppKitBoundary() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 180),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = NSView(frame: window.contentView!.bounds)
        let textView = ComposerPasteAwareTextView(frame: NSRect(x: 0, y: 0, width: 180, height: 100))
        let other = NSTextView(frame: NSRect(x: 200, y: 0, width: 180, height: 100))
        container.addSubview(textView)
        container.addSubview(other)
        window.contentView = container
        textView.nextKeyView = other
        other.nextKeyView = textView
        var sent = 0
        var received: [ComposerNativeKey] = []
        let field = ScrollableComposerTextView(text: .constant("draft"), font: .systemFont(ofSize: 13), onSend: { sent += 1 })
        let coordinator = ScrollableComposerTextView.Coordinator(field)
        coordinator.onCommandKey = { received.append($0); return false }
        #expect(window.makeFirstResponder(textView))
        #expect(coordinator.textView(textView, doCommandBy: NSSelectorFromString("insertTab:")))
        #expect(window.firstResponder === other)
        #expect(window.makeFirstResponder(textView))
        #expect(coordinator.textView(textView, doCommandBy: NSSelectorFromString("insertBacktab:")))
        #expect(window.firstResponder === other)
        #expect(window.makeFirstResponder(textView))
        received.removeAll()
        textView.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(textView.hasMarkedText())
        for selector in ["moveDown:", "insertNewline:", "insertTab:", "cancelOperation:"] {
            #expect(!coordinator.textView(textView, doCommandBy: NSSelectorFromString(selector)))
        }
        #expect(received.isEmpty)
        #expect(sent == 0)
        #expect(window.firstResponder === textView)
        textView.unmarkText()
        #expect(!textView.hasMarkedText())
        #expect(coordinator.textView(textView, doCommandBy: NSSelectorFromString("insertNewline:")))
        #expect(sent == 1)
    }

}
