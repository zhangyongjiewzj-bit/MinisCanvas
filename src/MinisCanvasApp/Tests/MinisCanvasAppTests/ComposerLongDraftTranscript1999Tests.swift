import AppKit
import Foundation
import MinisCore
import SwiftUI
import Testing
@testable import MinisCanvasApp

@Suite("D-PERF-01/05 native draft to transcript consumer")
@MainActor
struct ComposerLongDraftTranscript1999Tests {
    @Test(arguments: [50_000, 100_000])
    func longDraftEditsRetainLargeTranscriptAndOnePersistenceTimer(historyLength: Int) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("perf1999-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try #require(UserDefaults(suiteName: "perf1999-\(UUID())"))
        let chat = ChatStore(preferencesDefaults: defaults,
                             logManager: LogManager(directory: root.appendingPathComponent("logs")))
        let drafts = DraftStore(directory: root.appendingPathComponent("drafts"))
        drafts.debounceInterval = .seconds(30)
        chat.attachDraftStore(drafts)
        let session = try #require(chat.activeSessionID)
        let history = ChatMessageUI(role: .assistant, content: String(repeating: "史", count: historyLength))
        #expect(chat.setMessages([history], forSession: session))
        let revision = try #require(chat.transcriptRevision(forSession: session))
        let cache = ChatTranscriptDocumentCache()
        let redactor = ChatTranscriptRedactor(secretValues: [])
        let initial = cache.render(sessionID: session, messages: chat.messages,
                                   baseSize: 13, redactor: redactor)
        #expect(cache.lastFormattedMessageCount == 1)
        let documentRevision = cache.update.revision
        let generation = cache.update.generation
        let initialLocations = initial.messageStartLocations
        let status = "。滚动位置：跟随最新消息"
        let initialAccessibilityValue = cache.accessibilityValue(status: status)
        #expect(cache.accessibilityValueBuildCount == 1)
        #expect(cache.fallbackRouteStatus {
            ChatTranscriptAXContract.fallbackRouteStatus(in: chat.messages)
        } == nil)
        #expect(cache.fallbackRouteCheckCount == 1)
        let draftKey = DraftStore.chatDraftKey(sessionID: session)
        var sessionWrites = 0
        chat.onSessionsChanged = { sessionWrites += 1 }

        // Exercise the mounted composer's production delegate and binding, not
        // a direct DraftStore call. This creates no window or App run loop.
        let delegate = ScrollableComposerTextView(
            text: Binding(get: { chat.draftText }, set: { chat.draftText = $0 }),
            font: .systemFont(ofSize: 13),
            onSend: { Issue.record("unsent draft must not send") }
        ).makeCoordinator()
        let editor = ComposerPasteAwareTextView(frame: .zero)
        let base = String(repeating: "ordinary long draft line\n", count: 400)
        editor.string = base
        for _ in 0..<12 {
            editor.string += "字"
            delegate.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
            #expect(chat.draftText == editor.string)
            let document = cache.render(sessionID: session, messages: chat.messages,
                                        baseSize: 13, redactor: redactor)
            #expect(cache.lastFormattedMessageCount == 0)
            #expect(cache.update.revision == documentRevision)
            #expect(cache.update.generation == generation)
            #expect(document.messageStartLocations == initialLocations)
            #expect(cache.accessibilityValue(status: status) == initialAccessibilityValue)
            #expect(cache.accessibilityValueBuildCount == 1)
            #expect(cache.fallbackRouteStatus {
                ChatTranscriptAXContract.fallbackRouteStatus(in: chat.messages)
            } == nil)
            #expect(cache.fallbackRouteCheckCount == 1)
        }
        #expect(chat.transcriptRevision(forSession: session) == revision)
        #expect(sessionWrites == 0)
        #expect(drafts.latestPayload(for: draftKey) == nil)
        #expect(chat.longDraftTimerCreationCount == 1)
        #expect(chat.longDraftEncodingCount == 0)

        // A real transcript mutation is the positive control: only its new
        // message should format; the unchanged historical body stays cached.
        chat.appendAssistant("new answer " + ChatStore.fallbackRouteProjectionPrefix)
        _ = cache.render(sessionID: session, messages: chat.messages,
                         baseSize: 13, redactor: redactor)
        #expect(sessionWrites == 1)
        #expect(cache.lastFormattedMessageCount == 1)
        #expect(cache.update.generation == generation)
        #expect(cache.document.messageStartLocations.first == initialLocations.first)
        #expect(cache.accessibilityValue(status: status).contains("new answer"))
        #expect(cache.accessibilityValueBuildCount == 2)
        #expect(cache.fallbackRouteStatus {
            ChatTranscriptAXContract.fallbackRouteStatus(in: chat.messages)
        } == "回退路由状态已显示")
        #expect(cache.fallbackRouteCheckCount == 2)
        #expect(cache.accessibilityValue(status: "。滚动位置：正在阅读历史").contains("正在阅读历史"))
        #expect(cache.accessibilityValueBuildCount == 3)
        #expect(chat.flushPendingDraftForTermination())
        #expect(drafts.load(key: draftKey) == Data(editor.string.utf8))
        #expect(chat.longDraftEncodingCount == 1)
    }
}
