import AppKit
import Foundation
import MinisCore
import SwiftUI
import Testing
@testable import MinisCanvasApp

/// Test-local instrumentation of the synchronous production delegate. It
/// forwards actual NSTextView callbacks to the unmodified Coordinator; it
/// does not replace the draft setter, poll MainActor or schedule a Task.
/// This interval covers synchronous binding/credential processing and the
/// persistence enqueue call. A short draft's async Task/disk write and a long
/// draft's later timer/encoding/disk write are outside this interval. It is
/// wall duration on MainActor, not CPU time or event-to-presented-frame latency.
@MainActor
private final class ComposerDelegateLatency2879Collector: NSObject, NSTextViewDelegate {
    let consumer: ScrollableComposerTextView.Coordinator
    private(set) var nanoseconds: [Int64] = []
    private(set) var wrongObjectCallbacks = 0
    weak var expectedEditor: NSTextView?

    init(consumer: ScrollableComposerTextView.Coordinator, capacity: Int) {
        self.consumer = consumer
        nanoseconds.reserveCapacity(capacity)
    }

    func textDidChange(_ notification: Notification) {
        guard notification.object as? NSTextView === expectedEditor else {
            wrongObjectCallbacks += 1
            return
        }
        let clock = ContinuousClock()
        let start = clock.now
        consumer.textDidChange(notification)
        // Collection/printing is outside the measured production consumer.
        nanoseconds.append(Self.nanoseconds(start.duration(to: clock.now)))
    }

    static func nanoseconds(_ duration: Duration) -> Int64 {
        let parts = duration.components
        return parts.seconds * 1_000_000_000 + parts.attoseconds / 1_000_000_000
    }

    static func p95(_ samples: [Int64]) -> Int64? {
        guard !samples.isEmpty else { return nil }
        let ordered = samples.sorted()
        // Nearest rank; do not drop the tail or average away slow edits.
        return ordered[(ordered.count * 95 + 99) / 100 - 1]
    }

    static func withinFrame(_ nanoseconds: Int64, hz: Int64) -> Bool {
        nanoseconds >= 0 && hz > 0 && nanoseconds <= 1_000_000_000 / hz
    }
}

@Suite("D-PERF-01 production input latency collector (not UI acceptance)")
@MainActor
struct ComposerInputLatency2879Tests {
    @Test("P95 uses the real tail and original 60/120 Hz frame budgets")
    func percentileDoesNotHideSlowTail() {
        typealias Collector = ComposerDelegateLatency2879Collector
        #expect(Collector.p95([]) == nil)
        #expect(Collector.p95(Array(repeating: 100, count: 94)
            + Array(repeating: 20_000_000, count: 6)) == 20_000_000)
        #expect(!Collector.withinFrame(20_000_000, hz: 60))
        #expect(!Collector.withinFrame(9_000_000, hz: 120))
        #expect(Collector.withinFrame(8_000_000, hz: 120))
        #expect(!Collector.withinFrame(-1, hz: 60))
    }

    @Test("Committed native insert callbacks sample production binding and detect lost edits")
    func committedNativeInputSamplesProductionDelegate() throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("perf2879-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let defaults = try #require(UserDefaults(suiteName: "perf2879-\(UUID())"))
        let chat = ChatStore(preferencesDefaults: defaults,
                             logManager: LogManager(directory: root.appendingPathComponent("logs")))
        let drafts = DraftStore(directory: root.appendingPathComponent("drafts"))
        drafts.debounceInterval = .seconds(30)
        chat.attachDraftStore(drafts)
        let session = try #require(chat.activeSessionID)
        chat.appendAssistant("unchanged synthetic transcript")
        let history = chat.messages
        let revision = chat.transcriptRevision(forSession: session)
        var sessionNotifications = 0
        chat.onSessionsChanged = { sessionNotifications += 1 }
        let coordinator = ScrollableComposerTextView(
            text: Binding(get: { chat.draftText }, set: { chat.draftText = $0 }),
            font: .systemFont(ofSize: 13), onSend: { Issue.record("collector must not send") }
        ).makeCoordinator()
        let input = ComposerPasteAwareTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 80))
        input.isRichText = false
        input.allowsUndo = true
        input.font = .systemFont(ofSize: 13)
        let keyCount = 240
        let collector = ComposerDelegateLatency2879Collector(consumer: coordinator, capacity: keyCount)
        collector.expectedEditor = input
        input.delegate = collector
        defer { input.delegate = nil }
        let clock = ContinuousClock()
        var nativeNanoseconds: [Int64] = []
        nativeNanoseconds.reserveCapacity(keyCount)
        var expected = ""
        var lostEdits = 0
        // Mixed ASCII/CJK/combining/surrogate-pair input also makes lost-text
        // checks independent of UTF-16 length. IME marked text is not claimed.
        let keys = ["a", "中", "e\u{301}", "🙂"]
        for index in 0..<keyCount {
            let key = keys[index % keys.count]
            let before = collector.nanoseconds.count
            let start = clock.now
            // This is committed NSTextInputClient insertion. It bypasses
            // NSEvent.keyDown, keyboard-layout interpretation and IME marked
            // text; it must not be labelled a physical keyboard measurement.
            // Actual AppKit insertion must notify the delegate. Do not call
            // textDidChange manually: missing callbacks are a real failure.
            input.insertText(key, replacementRange: input.selectedRange())
            nativeNanoseconds.append(ComposerDelegateLatency2879Collector.nanoseconds(
                start.duration(to: clock.now)))
            expected += key
            if chat.draftText != expected || input.string != expected { lostEdits += 1 }
            #expect(collector.nanoseconds.count == before + 1)
            #expect(chat.draftText == expected)
            #expect(input.string == expected)
        }
        #expect(collector.wrongObjectCallbacks == 0)
        #expect(collector.nanoseconds.count == keyCount)
        #expect(chat.messages == history && chat.transcriptRevision(forSession: session) == revision)
        #expect(sessionNotifications == 0)
        #expect(chat.longDraftTimerCreationCount == 0 && chat.longDraftEncodingCount == 0)
        #expect(chat.flushPendingDraftForTermination())
        drafts.flushAll()
        let reopened = DraftStore(directory: root.appendingPathComponent("drafts"))
        #expect(reopened.load(key: DraftStore.chatDraftKey(sessionID: session)) == Data(expected.utf8))

        // Raw per-edit observations enable independent recomputation. No
        // unmeasured result becomes an assertion or a fabricated acceptance.
        for (index, pair) in zip(collector.nanoseconds, nativeNanoseconds).enumerated() {
            print("PERF2879_SAMPLE index=\(index) delegate_ns=\(pair.0) native_insert_ns=\(pair.1)")
        }
        let delegateP95 = try #require(ComposerDelegateLatency2879Collector.p95(collector.nanoseconds))
        let nativeP95 = try #require(ComposerDelegateLatency2879Collector.p95(nativeNanoseconds))
        for hz: Int64 in [60, 120] {
            print("PERF2879_DIAGNOSTIC samples=\(keyCount) budget_hz=\(hz) "
                + "budget_ns=\(1_000_000_000 / hz) delegate_p95_ns=\(delegateP95) "
                + "native_insert_p95_ns=\(nativeP95) "
                + "delegate_within_budget=\(ComposerDelegateLatency2879Collector.withinFrame(delegateP95, hz: hz)) "
                + "native_within_budget=\(ComposerDelegateLatency2879Collector.withinFrame(nativeP95, hz: hz)) "
                + "lost_edits=\(lostEdits) input=COMMITTED_INSERT_TEXT keyboard=NOT_MEASURED "
                + "sync_persistence_enqueue=INCLUDED async_persistence=NOT_TIMED "
                + "cadence=UNPACED window=NONE render=NOT_MEASURED "
                + "CPU=NOT_MEASURED alloc=NOT_MEASURED SwiftTask_total=NOT_MEASURED UI_acceptance=NOT_PROVEN")
        }
    }

    @Test("Long committed input preserves queued payload and transcript cache until flush",
          arguments: [50_000, 100_000])
    func longNativeCallbacksDoNotEnqueuePerKeyPayloadOrInvalidateTranscript(bytes: Int) throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("perf2899-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let defaults = try #require(UserDefaults(suiteName: "perf2899-\(UUID())"))
        let chat = ChatStore(preferencesDefaults: defaults,
                             logManager: LogManager(directory: root.appendingPathComponent("logs")))
        let drafts = DraftStore(directory: root.appendingPathComponent("drafts"))
        drafts.debounceInterval = .seconds(30)
        chat.attachDraftStore(drafts)
        let session = try #require(chat.activeSessionID)
        let draftKey = DraftStore.chatDraftKey(sessionID: session)
        chat.appendAssistant(String(repeating: "史", count: 50_000))
        let history = chat.messages
        #expect(history.count == 2) // Built-in welcome plus this fixture row.
        let revision = chat.transcriptRevision(forSession: session)
        let cache = ChatTranscriptDocumentCache()
        let redactor = ChatTranscriptRedactor(secretValues: [])
        let document = cache.render(sessionID: session, messages: history, baseSize: 13, redactor: redactor)
        let documentRevision = cache.update.revision
        let generation = cache.update.generation
        let locations = document.messageStartLocations
        let status = "。滚动位置：跟随最新消息"
        let accessibility = cache.accessibilityValue(status: status)
        #expect(cache.lastFormattedMessageCount == history.count)
        #expect(cache.accessibilityValueBuildCount == 1)
        var sessionNotifications = 0
        chat.onSessionsChanged = { sessionNotifications += 1 }

        // Diagnostic only: bracket the actual ChatStore binding setter inside
        // the already measured production Coordinator callback. The extra
        // clock reads change absolute timings, so this cannot be compared as
        // a regression baseline against the uninstrumented R15 run.
        var setterNanoseconds: [Int64] = []
        setterNanoseconds.reserveCapacity(34)
        let coordinator = ScrollableComposerTextView(
            text: Binding(get: { chat.draftText }, set: { value in
                let start = ContinuousClock().now
                chat.draftText = value
                setterNanoseconds.append(ComposerDelegateLatency2879Collector.nanoseconds(
                    start.duration(to: ContinuousClock().now)))
            }),
            font: .systemFont(ofSize: 13), onSend: { Issue.record("unsent draft must not send") }
        ).makeCoordinator()
        let input = ComposerPasteAwareTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 80))
        input.isRichText = false
        input.font = .systemFont(ofSize: 13)
        let collector = ComposerDelegateLatency2879Collector(consumer: coordinator, capacity: 34)
        collector.expectedEditor = input
        input.delegate = collector
        defer { input.delegate = nil }

        // Positive control for the real persistence queue: short input must
        // enter DraftStore immediately. Later long edits must not replace this
        // queued Data with a whole-draft payload before the flush boundary.
        input.insertText("s", replacementRange: input.selectedRange())
        let queuedShortPayload = try #require(drafts.latestPayload(for: draftKey))
        #expect(queuedShortPayload == Data("s".utf8))
        #expect(collector.nanoseconds.count == 1)
        input.setSelectedRange(NSRange(location: 0, length: (input.string as NSString).length))
        let longStart = String(repeating: "a", count: bytes)
        input.insertText(longStart, replacementRange: input.selectedRange())
        #expect(chat.draftText == longStart)
        #expect(collector.nanoseconds.count == 2)
        #expect(chat.longDraftTimerCreationCount == 1)
        #expect(chat.longDraftEncodingCount == 0)
        #expect(drafts.latestPayload(for: draftKey) == queuedShortPayload)

        let clock = ContinuousClock()
        var nativeSamples: [Int64] = []
        nativeSamples.reserveCapacity(32)
        var expected = longStart
        var queuedPayloadUpdates = 0
        var transcriptReformats = 0
        var lostEdits = 0
        let committedKeys = ["z", "中", "e\u{301}", "🙂"]
        for index in 0..<32 {
            let key = committedKeys[index % committedKeys.count]
            let callbacks = collector.nanoseconds.count
            let start = clock.now
            input.insertText(key, replacementRange: input.selectedRange())
            nativeSamples.append(ComposerDelegateLatency2879Collector.nanoseconds(
                start.duration(to: clock.now)))
            expected += key
            if chat.draftText != expected || input.string != expected { lostEdits += 1 }
            if drafts.latestPayload(for: draftKey) != queuedShortPayload { queuedPayloadUpdates += 1 }
            #expect(collector.nanoseconds.count == callbacks + 1)
            #expect(input.string == expected && chat.draftText == expected)
            #expect(drafts.latestPayload(for: draftKey) == queuedShortPayload)
            #expect(chat.longDraftTimerCreationCount == 1 && chat.longDraftEncodingCount == 0)
            #expect(chat.messages == history && chat.transcriptRevision(forSession: session) == revision)
            #expect(sessionNotifications == 0)
            let current = cache.render(sessionID: session, messages: chat.messages,
                                       baseSize: 13, redactor: redactor)
            transcriptReformats += cache.lastFormattedMessageCount
            #expect(cache.lastFormattedMessageCount == 0)
            #expect(cache.update.revision == documentRevision && cache.update.generation == generation)
            #expect(current.messageStartLocations == locations)
            #expect(cache.accessibilityValue(status: status) == accessibility)
            #expect(cache.accessibilityValueBuildCount == 1)
        }
        #expect(collector.wrongObjectCallbacks == 0 && collector.nanoseconds.count == 34)
        #expect(setterNanoseconds.count == collector.nanoseconds.count)

        // Positive control for invalidation: a real transcript append must
        // update the same cache that remained unchanged during native input.
        chat.appendAssistant("after native edits")
        let prefixPreserved = Array(chat.messages.prefix(history.count)) == history
        print("PERF2899_APPEND_DIAGNOSTIC bytes=\(bytes) prefix_preserved=\(prefixPreserved) "
            + "old_count=\(history.count) new_count=\(chat.messages.count)")
        _ = cache.render(sessionID: session, messages: chat.messages, baseSize: 13, redactor: redactor)
        #expect(cache.lastFormattedMessageCount == 1)
        #expect(cache.update.revision != documentRevision)
        #expect(sessionNotifications == 1)
        #expect(cache.accessibilityValue(status: status).contains("after native edits"))
        #expect(cache.accessibilityValueBuildCount == 2)

        // A separate observation covers synchronous encoding and actual disk
        // persistence at clean exit. It is not added to per-key P95 samples.
        let encodesBeforeFlush = chat.longDraftEncodingCount
        let timersBeforeFlush = chat.longDraftTimerCreationCount
        let flushStart = clock.now
        let flushed = chat.flushPendingDraftForTermination()
        let flushNS = ComposerDelegateLatency2879Collector.nanoseconds(flushStart.duration(to: clock.now))
        #expect(flushed)
        #expect(chat.longDraftEncodingCount == 1)
        #expect(drafts.latestPayload(for: draftKey) == Data(expected.utf8))
        let reopened = DraftStore(directory: root.appendingPathComponent("drafts"))
        #expect(reopened.load(key: draftKey) == Data(expected.utf8))

        // Exclude the initial short insertion and replacement with the long
        // text. Only the 32 actual committed edits form the per-key sample set.
        let delegateSamples = Array(collector.nanoseconds.dropFirst(2))
        let setterSamples = Array(setterNanoseconds.dropFirst(2))
        for (index, sample) in zip(zip(delegateSamples, setterSamples), nativeSamples).enumerated() {
            print("PERF2899_SAMPLE bytes=\(bytes) index=\(index) delegate_ns=\(sample.0.0) native_insert_ns=\(sample.1)")
            print("PERF3089_SEGMENT_SAMPLE bytes=\(bytes) index=\(index) "
                + "delegate_ns=\(sample.0.0) setter_ns=\(sample.0.1) native_insert_ns=\(sample.1)")
        }
        let setterP95 = try #require(ComposerDelegateLatency2879Collector.p95(setterSamples))
        print("PERF3089_SEGMENT_DIAGNOSTIC bytes=\(bytes) samples=32 "
            + "setter_p95_ns=\(setterP95) instrumented=true window=NONE "
            + "keyboard=NOT_MEASURED render=NOT_MEASURED UI_acceptance=NOT_PROVEN")
        print("PERF2899_DIAGNOSTIC bytes=\(bytes) samples=32 "
            + "delegate_p95_ns=\(try #require(ComposerDelegateLatency2879Collector.p95(delegateSamples))) "
            + "native_insert_p95_ns=\(try #require(ComposerDelegateLatency2879Collector.p95(nativeSamples))) "
            + "quit_flush_ns=\(flushNS) flush_succeeded=\(flushed) timer=\(timersBeforeFlush) "
            + "encode_before_flush=\(encodesBeforeFlush) encode_after_flush=\(chat.longDraftEncodingCount) "
            + "input=COMMITTED_INSERT_TEXT keyboard=NOT_MEASURED window=NONE "
            + "lost_edits=\(lostEdits) queued_payload_updates_during_long_edits=\(queuedPayloadUpdates) "
            + "transcript_reformats_during_edits=\(transcriptReformats) "
            + "CPU=NOT_MEASURED alloc=NOT_MEASURED SwiftTask_total=NOT_MEASURED "
            + "full_text_copy=NOT_MEASURED UI_acceptance=NOT_PROVEN")
    }

}
