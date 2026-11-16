import AppKit
import Foundation
import MinisCore
import Observation
import SwiftUI
import Testing
@testable import MinisCanvasApp

/// Run only through the existing 339 NSApplication.run entry with an exclusive
/// UI lease and formal synthetic profile. No state/proxy substitute is used:
/// the production transcript owns its state, button, TextKit and outer scroll.
@Suite("D-CHAT-14 actual new-message button consumer", .serialized)
@MainActor
struct TranscriptNewMessage434NativeConsumerTests {
    @Test("three new messages retain history until the native button is pressed",
          arguments: [false, true])
    func actualButtonCountsAndReachesLatestMessage(atomicAppend: Bool) async throws {
        let fixture = Transcript434Fixture(tag: "A")
        let host = try Transcript434Host(fixture)
        defer { host.close() }
        try await host.settle()
        let text = try host.text(containing: "434-A-history-5-start")
        let scroll = try host.outerScroll(containing: text)
        text.setSelectedRange(NSRange(location: 3, length: 7))
        try host.readHistory(marker: "434-A-history-5-start", text: text, scroll: scroll)
        try await host.settle()
        let readingOrigin = scroll.contentView.bounds.origin
        let originalHistory = NSAttributedString(attributedString: text.attributedString())
        try host.expectVisible(marker: "434-A-history-5-start", text: text)
        let noUnreadButton1 = NativeConsumerOwnedAX.hasNoIdentifier(
            in: host.window, prefix: Transcript434Host.buttonID) == true
        try #require(noUnreadButton1)
        #expect(noUnreadButton1)

        let additions = (1...3).map { ChatMessageUI(role: .assistant, content: "434-A-new-\($0)") }
        if atomicAppend {
            // UI observation may coalesce multiple message writes into one
            // render. Count messages, rather than onChange deliveries.
            fixture.messages.append(contentsOf: additions)
            try await host.settle()
        } else {
            for (index, message) in additions.enumerated() {
                fixture.messages.append(message)
                try await host.settle()
                _ = try host.button(count: index + 1)
                #expect(scroll.contentView.bounds.origin == readingOrigin)
            }
        }
        let button = try host.button(count: 3)
        #expect(scroll.contentView.bounds.origin == readingOrigin)
        try host.expectVisible(marker: "434-A-history-5-start", text: text)
        #expect(text.attributedString().attributedSubstring(from: NSRange(
            location: 0, length: originalHistory.length)).isEqual(to: originalHistory))
        #expect(text.selectedRange() == NSRange(location: 3, length: 7))
        let latest = try #require(additions.last)
        #expect(fixture.messages.last?.id == latest.id)
        #expect(!host.isVisible(marker: latest.content, text: text))

        #expect(NativeConsumerOwnedAX.press(button), "press the actual production AX button")
        try await host.settle()
        try host.expectVisible(marker: latest.content, text: text, messageID: latest.id)
        #expect(scroll.contentView.bounds.origin != readingOrigin)
        let noUnreadButton2 = NativeConsumerOwnedAX.hasNoIdentifier(
            in: host.window, prefix: Transcript434Host.buttonID) == true
        try #require(noUnreadButton2)
        #expect(noUnreadButton2)
        #expect(text.selectedRange() == NSRange(location: 3, length: 7))

        let fourth = ChatMessageUI(role: .assistant, content: "434-A-new-4-followed")
        fixture.messages.append(fourth)
        try await host.settle()
        try host.expectVisible(marker: fourth.content, text: text, messageID: fourth.id)
        let noUnreadButton3 = NativeConsumerOwnedAX.hasNoIdentifier(
            in: host.window, prefix: Transcript434Host.buttonID) == true
        try #require(noUnreadButton3)
        #expect(noUnreadButton3)
    }

    @Test("actual tool toggle preserves ordinary JSON, source objects and viewer isolation")
    func actualToolOutputToggleRemainsMessageAndViewerScoped() async throws {
        let fixture = Transcript434Fixture(tag: "output419")
        let body = "{\"owned419\":\"ordinary JSON body\"}"
        let first = ChatMessageUI(role: .tool, content: body)
        let second = ChatMessageUI(role: .tool, content: body)
        let original = [ChatMessageUI(role: .user, content: body),
                        ChatMessageUI(role: .assistant, content: body), first, second]
        fixture.messages = original
        let viewer = fixture.sessionID
        let redactor = ChatTranscriptRedactor(secretValues: [])
        let export = SessionMarkdownExport.markdown(title: "owned419", messages: original, redactor: redactor)
        let plain = ChatTranscriptFormatter.plainText(original, redactor: redactor)
        let host = try Transcript434Host(fixture)
        defer { host.close() }
        try await host.settle()
        let text = try host.text(containing: "owned419")
        #expect(text.string.components(separatedBy: "owned419").count - 1 == 2)
        #expect(text.string.components(separatedBy: "工具输出已折叠").count - 1 == 2)
        let toggleID = "chat.tool-output.\(first.id.uuidString).toggle"
        let toggle = try #require(NativeConsumerOwnedAX.find(in: host.window, identifier: toggleID))
        #expect(NativeConsumerOwnedAX.press(toggle))
        try await host.settle()
        #expect(text.string.components(separatedBy: "owned419").count - 1 == 3)
        #expect(text.string.components(separatedBy: "工具输出已折叠").count - 1 == 1)
        let collapse = try #require(NativeConsumerOwnedAX.find(in: host.window, identifier: toggleID))
        #expect(NativeConsumerOwnedAX.press(collapse))
        try await host.settle()
        #expect(text.string.components(separatedBy: "owned419").count - 1 == 2)
        let reopen = try #require(NativeConsumerOwnedAX.find(in: host.window, identifier: toggleID))
        #expect(NativeConsumerOwnedAX.press(reopen))
        try await host.settle()
        #expect(text.string.components(separatedBy: "owned419").count - 1 == 3)
        // Same message IDs in another viewer must not inherit expansion state.
        fixture.sessionID = UUID()
        try await host.settle()
        let otherText = try host.text(containing: "owned419")
        #expect(otherText.string.components(separatedBy: "owned419").count - 1 == 2)
        #expect(otherText.string.components(separatedBy: "工具输出已折叠").count - 1 == 2)
        fixture.sessionID = viewer
        try await host.settle()
        #expect(try host.text(containing: "owned419").string.components(separatedBy: "owned419").count - 1 == 2)
        #expect(fixture.messages == original)
        #expect(ChatTranscriptFormatter.plainText(fixture.messages, redactor: redactor) == plain)
        #expect(SessionMarkdownExport.markdown(title: "owned419", messages: fixture.messages, redactor: redactor) == export)
    }

    @Test("session replacement clears old unread count and the button reaches only current history")
    func actualSessionSwitchDoesNotCarryUnreadOrOldDestination() async throws {
        let fixture = Transcript434Fixture(tag: "old")
        let host = try Transcript434Host(fixture)
        defer { host.close() }
        try await host.settle()
        let oldText = try host.text(containing: "434-old-history-5-start")
        let oldScroll = try host.outerScroll(containing: oldText)
        try host.readHistory(marker: "434-old-history-5-start", text: oldText, scroll: oldScroll)
        try await host.settle()
        for index in 1...2 {
            fixture.messages.append(ChatMessageUI(role: .assistant, content: "434-old-new-\(index)"))
            try await host.settle()
        }
        _ = try host.button(count: 2)

        let next = Transcript434Fixture(tag: "current")
        fixture.sessionID = next.sessionID
        fixture.messages = next.messages
        try await host.settle()
        let text = try host.text(containing: "434-current-history-5-start")
        #expect(!text.string.contains("434-old-"))
        let noUnreadButton4 = NativeConsumerOwnedAX.hasNoIdentifier(
            in: host.window, prefix: Transcript434Host.buttonID) == true
        try #require(noUnreadButton4)
        #expect(noUnreadButton4)
        let initialLatest = try #require(fixture.messages.last)
        try host.expectVisible(marker: "434-current-history-11-end", text: text,
                               messageID: initialLatest.id)
        let scroll = try host.outerScroll(containing: text)
        try host.readHistory(marker: "434-current-history-5-start", text: text, scroll: scroll)
        try await host.settle()
        let readingOrigin = scroll.contentView.bounds.origin
        let latest = ChatMessageUI(role: .assistant, content: "434-current-new-1")
        fixture.messages.append(latest)
        try await host.settle()
        let button = try host.button(count: 1)
        #expect(scroll.contentView.bounds.origin == readingOrigin)
        try host.expectVisible(marker: "434-current-history-5-start", text: text)
        #expect(NativeConsumerOwnedAX.press(button))
        try await host.settle()
        #expect(fixture.sessionID == next.sessionID && fixture.messages.last?.id == latest.id)
        try host.expectVisible(marker: latest.content, text: text, messageID: latest.id)
        #expect(!text.string.contains("434-old-"))
        let noUnreadButton5 = NativeConsumerOwnedAX.hasNoIdentifier(
            in: host.window, prefix: Transcript434Host.buttonID) == true
        try #require(noUnreadButton5)
        #expect(noUnreadButton5)
    }
}

@Observable @MainActor
final class Transcript434Fixture {
    let liveChat: ChatStore?
    var sessionID = UUID()
    var messages: [ChatMessageUI]

    init(tag: String, liveChat: ChatStore? = nil) {
        self.liveChat = liveChat
        messages = (0..<12).map { index in
            ChatMessageUI(role: .assistant, content: "434-\(tag)-history-\(index)-start\n"
                + String(repeating: "bounded synthetic history line\n", count: 8)
                + "434-\(tag)-history-\(index)-end")
        }
    }
}

struct Transcript434Root: View {
    let fixture: Transcript434Fixture
    let transcriptEnvStore: EnvVarStore
    var body: some View {
        if let chat = fixture.liveChat {
            ChatTranscriptView(sessionID: chat.activeSessionID, messages: chat.messages,
                               transcriptEnvStore: transcriptEnvStore)
                .id(ChatTranscriptSessionBoundary.viewIdentity(for: chat.activeSessionID))
        } else {
            ChatTranscriptView(sessionID: fixture.sessionID, messages: fixture.messages,
                               transcriptEnvStore: transcriptEnvStore)
        }
    }
}

@MainActor
final class Transcript434Host {
    static let buttonID = "chat.transcript.newMessages"
    let window: NSWindow
    let controller: NSHostingController<Transcript434Root>

    init(_ fixture: Transcript434Fixture) throws {
        try #require(NSApplication.shared.isRunning, "requires the unchanged 339 native entry")
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer(),
                                  "default redactor and shared owners must use the formal synthetic profile")
        // The live ChatStore's omitted defaults resolve this same formal profile.
        // Both mounted branches use this formal-profile-scoped store, never a redactor snapshot.
        let transcriptEnvStore = EnvVarStore(
            directory: profile.providerConfigurationDirectory,
            keychain: KeychainStore(backing: InMemoryKeychainBacking()),
            privacyStore: EnvVarPrivacyStore(defaults: profile.makeUserDefaults()))
        let lease = NativeTestHostLifecycle.begin("TranscriptNewMessage434")
        controller = NSHostingController(rootView: Transcript434Root(
            fixture: fixture, transcriptEnvStore: transcriptEnvStore))
        controller.sizingOptions = []
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.setAccessibilityIdentifier("Transcript434-" + UUID().uuidString)
        NativeTestHostLifecycle.bind(lease, to: window)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        let contentSize = NSSize(width: 640, height: 420)
        window.setContentSize(contentSize)
        controller.view.frame = NSRect(origin: .zero, size: contentSize)
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func close() {
        window.orderOut(nil)
        window.contentViewController = nil
        window.close()
        NativeTestHostLifecycle.end(window)
    }

    func settle() async throws {
        for _ in 0..<30 {
            window.layoutIfNeeded()
            controller.view.layoutSubtreeIfNeeded()
            controller.view.display()
            try await Task.sleep(for: .milliseconds(10))
        }
        let content = try #require(window.contentView)
        #expect(content.bounds.size == NSSize(width: 640, height: 420))
        #expect(controller.view.frame.size == content.bounds.size)
        NativeTestHostLifecycle.observe(window, phase: "transcript434-sampled")
    }

    func text(containing marker: String) throws -> NSTextView {
        var matches: [NSTextView] = []
        func visit(_ view: NSView) {
            if let text = view as? NSTextView, !text.isEditable, text.string.contains(marker) {
                matches.append(text)
            }
            view.subviews.forEach(visit)
        }
        visit(controller.view)
        #expect(matches.count == 1, "only the mounted production transcript may supply glyph evidence")
        return try #require(matches.count == 1 ? matches.first : nil)
    }

    func outerScroll(containing text: NSTextView) throws -> NSScrollView {
        var ancestor = text.superview
        while let view = ancestor {
            if let scroll = view as? NSScrollView, let document = scroll.documentView,
               document.bounds.height > scroll.contentView.bounds.height + 100 {
                return scroll
            }
            ancestor = view.superview
        }
        return try #require(nil as NSScrollView?, "must observe the real outer transcript clip")
    }

    func glyphRect(marker: String, text: NSTextView) throws -> NSRect {
        let source = text.string as NSString
        let range = source.range(of: marker)
        try #require(range.location != NSNotFound && range.length > 0, "missing destination cannot supply a glyph range")
        #expect(source.range(of: marker, options: [], range: NSRange(
            location: NSMaxRange(range), length: source.length - NSMaxRange(range))).location == NSNotFound)
        let manager = try #require(text.layoutManager)
        let container = try #require(text.textContainer)
        manager.ensureLayout(for: container)
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        #expect(glyphs.length > 0)
        return manager.boundingRect(forGlyphRange: glyphs, in: container)
            .offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
    }

    func readHistory(marker: String, text: NSTextView, scroll: NSScrollView) throws {
        let document = try #require(scroll.documentView)
        let rect = text.convert(try glyphRect(marker: marker, text: text), to: document)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: rect.minY))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func isVisible(marker: String, text: NSTextView) -> Bool {
        guard let rect = try? glyphRect(marker: marker, text: text) else { return false }
        return !rect.isEmpty && !text.visibleRect.isEmpty && text.visibleRect.intersects(rect)
    }

    func expectVisible(marker: String, text: NSTextView, messageID: UUID? = nil) throws {
        let rect = try glyphRect(marker: marker, text: text)
        print("TRANSCRIPT434 destination=\(messageID?.uuidString ?? "history") marker=\(marker.debugDescription) glyph=\(rect) actualVisible=\(text.visibleRect)")
        #expect(!rect.isEmpty && !text.visibleRect.isEmpty)
        #expect(text.visibleRect.intersects(rect), "the specific destination's real glyph must be inside ancestor clips")
    }

    func button(count: Int) throws -> AnyObject {
        let button = try #require(NativeConsumerOwnedAX.find(in: window, identifier: Self.buttonID))
        #expect(NativeConsumerOwnedAX.role(button) == .button)
        #expect(NativeConsumerOwnedAX.enabled(button) == true)
        #expect(NativeConsumerOwnedAX.label(button) == "有 \(count) 条新消息")
        let frame = try #require(NativeConsumerOwnedAX.frame(button))
        #expect(!frame.isEmpty)
        print("TRANSCRIPT434 buttonExpectedCount=\(count) actualLabel=\(NativeConsumerOwnedAX.label(button) ?? "unreadable") nativeFrame=\(frame) owner=\(window.accessibilityIdentifier())")
        return button
    }
}
