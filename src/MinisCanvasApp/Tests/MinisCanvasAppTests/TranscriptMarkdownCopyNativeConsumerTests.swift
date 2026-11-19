import AppKit
import Foundation
import SwiftUI
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Main transcript Markdown copy native consumer", .serialized)
@MainActor
struct TranscriptMarkdownCopyNativeConsumerTests {
    @Test func actualToolbarCopiesRedactedMarkdownAndRejectsAStaleSession() async throws {
        try #require(NSApplication.shared.isRunning, "requires the existing native App test host")
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "transcript-markdown-copy",
            processEnvironment: [:], processArguments: ["TranscriptMarkdownCopyNativeConsumerTests.xctest"],
            canvasRuntimeState: .disabled)
        defer { try? profile.cleanupDisposableRoots() }
        let env = profile.makeEnvironmentStore(keychain: profile.makeKeychainStore())
        let secret = "G22_OWNED_MARKDOWN_SECRET_891"
        #expect(env.setEnvVar(name: "G22_COPY_SECRET", value: secret, isSecret: true))
        let raw = "# 合成回答\n\n**原始 Markdown** ⚠️ " + secret
            + "\n\n```swift\nlet sample = 1\n```\n"
        let message = ChatMessageUI(role: .assistant, content: raw)
        let sessionID = UUID()
        var currentSessionID = sessionID
        let board = NSPasteboard(name: .init("g22-markdown-copy-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        board.setString("owned-before-copy", forType: .string)
        let view = ChatTranscriptView(sessionID: sessionID, messages: [message], transcriptEnvStore: env,
            currentSessionID: { currentSessionID }, markdownCopyPasteboard: board)
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = []
        let lease = NativeTestHostLifecycle.begin("TranscriptMarkdownCopy")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 500),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        NativeTestHostLifecycle.bind(lease, to: window)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 760, height: 500))
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
            NativeTestHostLifecycle.end(window)
        }
        let consumer = SettingsNativeInteractionConsumerTests()
        let menuID = "chat.transcript.copy.\(message.id.uuidString)"
        for stale in [true, false] {
            var menu: AnyObject?
            for _ in 0..<100 {
                menu = NativeConsumerOwnedAX.find(in: window, identifier: menuID)
                if menu != nil { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(menu != nil, "The original independent Copy menu must remain present")
            // 「复制为 Markdown」是“复制”菜单里的一项。SwiftUI 在点开时才生成这个 NSMenu，并进入
            // 不服务主队列的跟踪循环，宿主里没法可靠地自动选中菜单项（会挂住进程），所以菜单本身只核
            // 存在（上面的原生 AX），这一项执行的是菜单项绑定的同一个动作。
            currentSessionID = stale ? UUID() : sessionID
            view.copyMessage(message.id, pasteboard: board)
            consumer.pumpSettingsRunLoop()
            if stale {
                #expect(board.string(forType: .string) == "owned-before-copy")
            } else {
                let copied = try #require(board.string(forType: .string))
                #expect(copied.hasPrefix("# 合成回答\n\n**原始 Markdown** ⚠️ "))
                #expect(copied.contains("```swift\nlet sample = 1\n```"))
                #expect(!copied.contains(secret))
            }
            currentSessionID = sessionID
        }
        #expect(message.content == raw)
        #expect(message.asLLMMessage().content == raw)
    }
}
