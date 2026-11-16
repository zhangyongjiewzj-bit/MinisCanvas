import AppKit
import CoreGraphics
import Foundation
import Testing
import MinisCore
import QuartzCore
@testable import MinisCanvasApp

/// D-CHAT-15 already has L3 source evidence. This fills its native-consumer
/// proof gap, using the unchanged 339 entry and 434's existing owned host.
/// Synthetic NSEvent -> actual NSScrollView.scrollWheel is recorded separately
/// from a human's manual wheel/trackpad action in an isolated product package.
@Suite("D-CHAT-15 actual history viewport during streaming", .serialized)
@MainActor
struct TranscriptHistory435NativeConsumerTests {
    @Test("same-session placeholder and nonempty streaming deltas keep the native viewport at the tail")
    func nativeFollowingSamplesEveryStreamPhase() async throws {
        let fixture = Transcript434Fixture(tag: "909")
        let host = try Transcript434Host(fixture)
        defer { host.close() }
        try await host.settle()
        let text = try host.text(containing: "434-909-history-11-end")
        let scroll = try host.outerScroll(containing: text)
        _ = try sampleFollowingPhase("history-bottom", marker: "434-909-history-11-end",
                                     text: text, scroll: scroll, host: host)

        fixture.messages.append(ChatMessageUI(role: .user, content: "909-user-request"))
        try await host.settle()
        _ = try sampleFollowingPhase("user", marker: "909-user-request",
                                     text: text, scroll: scroll, host: host)

        let streaming = ChatMessageUI(role: .assistant, content: "", isStreaming: true)
        fixture.messages.append(streaming)
        let streamIndex = fixture.messages.count - 1
        try await host.settle()
        let placeholderLength = try sampleFollowingPhase(
            "placeholder", marker: "909-user-request", text: text, scroll: scroll, host: host)
        #expect(fixture.messages[streamIndex].isStreaming)
        #expect(fixture.messages[streamIndex].content.isEmpty)

        fixture.messages[streamIndex].content = "909-stream-start\n909-first-token"
        try await host.settle()
        var priorLength = try sampleFollowingPhase(
            "first-nonempty", marker: "909-first-token", text: text, scroll: scroll, host: host)
        #expect(priorLength > placeholderLength)

        for index in 1...3 {
            fixture.messages[streamIndex].content = "909-stream-start\n"
                + String(repeating: "bounded native streaming line\n", count: index * 24)
                + "909-middle-\(index)"
            try await host.settle()
            let length = try sampleFollowingPhase(
                "middle-\(index)", marker: "909-middle-\(index)",
                text: text, scroll: scroll, host: host)
            #expect(length > priorLength, "each sampled phase must contain real nonempty growth")
            priorLength = length
        }

        fixture.messages[streamIndex].isStreaming = false
        try await host.settle()
        _ = try sampleFollowingPhase("terminal", marker: "909-middle-3",
                                     text: text, scroll: scroll, host: host)
        #expect(!fixture.messages[streamIndex].isStreaming)
        #expect(NativeConsumerOwnedAX.hasNoIdentifier(
            in: host.window, prefix: Transcript434Host.buttonID) == true)
    }

    private func sampleFollowingPhase(
        _ phase: String, marker: String, text: NSTextView,
        scroll: NSScrollView, host: Transcript434Host
    ) throws -> Int {
        let document = try #require(scroll.documentView)
        let clip = scroll.contentView.bounds
        let gap = document.bounds.maxY - clip.maxY
        let length = text.attributedString().length
        print("TRANSCRIPT909 phase=\(phase) clip=\(clip) document=\(document.bounds) "
            + "visible=\(text.visibleRect) gap=\(gap) chars=\(length) "
            + "diagnostics=\(ChatTranscriptScrollDiagnostics.enabled)")
        ChatTranscriptScrollDiagnostics.record("consumer-909-\(phase)",
            "clip=\(clip) document=\(document.bounds) visible=\(text.visibleRect)")
        #expect(gap <= 24, "the real outer clip must follow the latest content at every phase")
        #expect(!host.isVisible(marker: "434-909-history-0-start", text: text))
        try host.expectVisible(marker: marker, text: text)
        return length
    }

    @Test("native upward wheel protects history through stream growth and stop until downward wheel")
    func nativeHistoryReadingSurvivesStreamAndStopUntilExplicitReturn() async throws {
        let fixture = Transcript434Fixture(tag: "435")
        fixture.messages[0].content = "# Historical heading\n\n435-history-target\n\n"
            + "Keep **bold**, `inline code`, and 中文 typography unchanged.\n435-history-first-end"
        let streaming = ChatMessageUI(role: .assistant, content: "435-stream-head\n435-first-piece", isStreaming: true)
        fixture.messages.append(streaming)
        let streamIndex = fixture.messages.count - 1
        let host = try Transcript434Host(fixture)
        defer { host.close() }
        try await host.settle()
        let text = try host.text(containing: "435-history-target")
        let scroll = try host.outerScroll(containing: text)
        try host.expectVisible(marker: "435-first-piece", text: text, messageID: streaming.id)
        let followedOrigin = scroll.contentView.bounds.origin

        try sendWheel(pixels: 20_000, to: scroll, host: host)
        try await host.settle()
        try #require(scroll.contentView.bounds.origin != followedOrigin,
                     "synthetic native wheel must actually move the owned outer clip; no programmatic fallback")
        try host.expectVisible(marker: "435-history-target", text: text, messageID: fixture.messages[0].id)
        #expect(!host.isVisible(marker: "435-first-piece", text: text))
        let source = text.string as NSString
        let historyEnd = source.range(of: "434-435-history-11-end")
        try #require(historyEnd.location != NSNotFound)
        let prefixRange = NSRange(location: 0, length: NSMaxRange(historyEnd))
        let history = NSAttributedString(attributedString:
            text.attributedString().attributedSubstring(from: prefixRange))
        let selection = source.range(of: "435-history-target")
        try #require(selection.location != NSNotFound)
        text.setSelectedRange(selection)
        try await host.settle()
        let readingClip = scroll.contentView.bounds
        let readingVisible = text.visibleRect
        let historicalGlyph = try host.glyphRect(marker: "435-history-target", text: text)
        print("TRANSCRIPT435 phase=upward-native-wheel clip=\(readingClip) visible=\(readingVisible) selection=\(selection)")

        for index in 1...6 {
            // The real mounted view observes mutations of the existing tail
            // message; no ScrollState.apply or fake scroll proxy is invoked.
            fixture.messages[streamIndex].content = "435-stream-head\n"
                + String(repeating: "streamed **bounded** line\n", count: index * 10)
                + "435-stream-piece-\(index)"
            try await host.settle()
            #expect(fixture.messages[streamIndex].id == streaming.id)
            #expect(fixture.messages[streamIndex].isStreaming)
            #expect(scroll.contentView.bounds == readingClip)
            #expect(text.visibleRect == readingVisible)
            #expect(text.selectedRange() == selection)
            #expect(text.attributedString().attributedSubstring(from: prefixRange).isEqual(to: history))
            let currentGlyph = try host.glyphRect(marker: "435-history-target", text: text)
            #expect(currentGlyph == historicalGlyph)
            try host.expectVisible(marker: "435-history-target", text: text, messageID: fixture.messages[0].id)
            #expect(!host.isVisible(marker: "435-stream-piece-\(index)", text: text))
            let noUnread = NativeConsumerOwnedAX.hasNoIdentifier(
                in: host.window, prefix: Transcript434Host.buttonID) == true
            try #require(noUnread)
            #expect(noUnread, "tail deltas are not newly appended assistant messages")
            print("TRANSCRIPT435 phase=stream-delta-\(index) tailID=\(streaming.id) clip=\(scroll.contentView.bounds) visible=\(text.visibleRect)")
        }

        // Observe the transcript's real terminal-refresh branch. This fixture
        // stops the streaming projection, not a provider or ChatStore task.
        fixture.messages[streamIndex].isStreaming = false
        try await host.settle()
        #expect(!fixture.messages[streamIndex].isStreaming)
        #expect(scroll.contentView.bounds == readingClip)
        #expect(text.visibleRect == readingVisible)
        #expect(text.selectedRange() == selection)
        #expect(text.attributedString().attributedSubstring(from: prefixRange).isEqual(to: history))
        let stoppedGlyph = try host.glyphRect(marker: "435-history-target", text: text)
        #expect(stoppedGlyph == historicalGlyph)
        try host.expectVisible(marker: "435-history-target", text: text)
        #expect(!host.isVisible(marker: "435-stream-piece-6", text: text))
        print("TRANSCRIPT435 phase=stopped-projection clip=\(scroll.contentView.bounds) selection=\(text.selectedRange())")

        try sendWheel(pixels: -20_000, to: scroll, host: host)
        try await host.settle()
        try #require(scroll.contentView.bounds != readingClip,
                     "explicit native downward wheel must actually return to the tail")
        try host.expectVisible(marker: "435-stream-piece-6", text: text, messageID: streaming.id)
        #expect(text.selectedRange() == selection)
        let returnedClip = scroll.contentView.bounds
        let next = ChatMessageUI(role: .assistant, content: "435-next-first", isStreaming: true)
        fixture.messages.append(next)
        try await host.settle()
        try host.expectVisible(marker: next.content, text: text, messageID: next.id)
        fixture.messages[fixture.messages.count - 1].content = "435-next-first\n"
            + String(repeating: "following growth line\n", count: 80) + "435-next-last"
        try await host.settle()
        #expect(fixture.messages.last?.id == next.id)
        #expect(scroll.contentView.bounds.origin != returnedClip.origin,
                "following must consume substantial tail growth after the explicit return")
        try host.expectVisible(marker: "435-next-last", text: text, messageID: next.id)
        #expect(text.selectedRange() == selection)
        #expect(text.attributedString().attributedSubstring(from: prefixRange).isEqual(to: history))
        let noUnreadAfterReturn = NativeConsumerOwnedAX.hasNoIdentifier(
            in: host.window, prefix: Transcript434Host.buttonID) == true
        try #require(noUnreadAfterReturn)
        #expect(noUnreadAfterReturn)
        print("TRANSCRIPT435 phase=following-after-native-return nextID=\(next.id) clip=\(scroll.contentView.bounds)")
    }

    private func sendWheel(pixels: Int32, to scroll: NSScrollView, host: Transcript434Host) throws {
        let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                        wheelCount: 1, wheel1: pixels, wheel2: 0, wheel3: 0))
        let native = try #require(NSEvent(cgEvent: event))
        #expect(native.type == .scrollWheel)
        try #require(native.scrollingDeltaY != 0)
        try #require(scroll.window === host.window,
                     "the event may target only the transcript's existing owned native consumer")
        print("TRANSCRIPT435 wheelRoute=synthetic-NSEvent-to-owned-NSScrollView.scrollWheel deltaY=\(native.scrollingDeltaY) before=\(scroll.contentView.bounds)")
        scroll.scrollWheel(with: native)
    }
}

// TASK1008: existing 434 host + real ChatStore stream consumer. Display-link
// callbacks only read native geometry; they never force layout or scroll.
extension TranscriptHistory435NativeConsumerTests {
    @Test("real stream consumer retains a nonblank following viewport on every native frame")
    func liveStreamFollowingHasNoTopJumpAcrossNativeFrames1008() async throws {
        let (chat, engine, fixture, host) = try makeLiveTranscript1008(tag: "follow")
        defer { engine.continuation.finish(); chat.stopAllStreamingForSafety(); host.close() }
        try await host.settle()
        let session = try #require(chat.activeSessionID)
        let text = try host.text(containing: "434-1008-follow-history-0-start")
        let scroll = try host.outerScroll(containing: text)
        let sampler = try NativeTranscriptFrameSampler1008(host: host, chat: chat)
        defer { sampler.stop() }
        try sampler.begin("send-placeholder-first-tail", session: session, text: text, scroll: scroll,
                          topMarker: fixture.messages[0].content.components(separatedBy: "\n")[0])
        chat.draftText = "1008 ordinary live stream"
        chat.sendDraft()
        try await requireLiveProducer1008(engine)
        let turn = try #require(chat.turnTaskForTests(sessionID: session))
        try await sampler.waitForFrames(sampler.phaseFrameCount + 3)
        let assistantID = try #require(chat.messages.last?.id)
        #expect(chat.messages.last?.isStreaming == true)
        #expect(chat.messages.last?.content.isEmpty == true)
        // TASK1026: same unfinished turn, host, read primitive and display link.
        // This hold emits no delta; it does not relax any original coverage check.
        sampler.markProbeStage(.hold)
        try await sampler.waitForFrames(sampler.phaseFrameCount + 12)
        #expect(chat.messages.last?.id == assistantID)
        #expect(chat.messages.last?.isStreaming == true)
        #expect(chat.messages.last?.content.isEmpty == true)
        sampler.markProbeStage(.growth)
        let chunks = (0..<12).map { index in
            "1008-live-piece-\(index)\n" + String(repeating: "native continuous bounded line\n", count: 3)
        }
        for (chunkIndex, chunk) in chunks.enumerated() {
            sampler.recordProbePoint(.yieldEnter, chunkIndex: chunkIndex)
            engine.continuation.yield(.textDelta(chunk))
            sampler.recordProbePoint(.yieldReturn, chunkIndex: chunkIndex)
            try await sampler.waitForFrames(sampler.phaseFrameCount + 3)
            #expect(chat.messages.last?.id == assistantID)
            #expect(chat.messages.last?.isStreaming == true)
        }
        sampler.markProbeStage(.terminal)
        engine.continuation.finish()
        sampler.recordProbePoint(.turnWaitEnter)
        await turn.value
        sampler.recordProbePoint(.turnWaitReturn)
        try await sampler.waitForFrames(sampler.phaseFrameCount + 3)
        try sampler.requireCoverageAndNonblank()
        #expect(sampler.phaseFrames.allSatisfy { !$0.topVisible })
        #expect(sampler.longestOffTailRun <= 1,
                "following may settle within one native frame, never accumulate a multi-frame off-tail viewport")
        #expect(Set(sampler.phaseFrames.map(\.characters)).count > 3,
                "frame evidence must span actual native storage growth, not a final-text-only sample")
        #expect(chat.messages.last?.content == chunks.joined())
        #expect(chat.messages.last?.isStreaming == false)
        try host.expectVisible(marker: "1008-live-piece-11", text: text)
    }

    @Test("native upward wheel remains on history during actual streamed chunks")
    func liveStreamHistoryIsNotPulledBackOnNativeFrames1008() async throws {
        let (chat, engine, fixture, host) = try makeLiveTranscript1008(tag: "read")
        defer { engine.continuation.finish(); chat.stopAllStreamingForSafety(); host.close() }
        chat.draftText = "1008 read history while producing"
        chat.sendDraft()
        try await requireLiveProducer1008(engine)
        let session = try #require(chat.activeSessionID)
        let turn = try #require(chat.turnTaskForTests(sessionID: session))
        engine.continuation.yield(.textDelta("1008-live-read-first\n"))
        try await host.settle()
        let text = try host.text(containing: "434-1008-read-history-0-start")
        let scroll = try host.outerScroll(containing: text)
        let followed = scroll.contentView.bounds
        try sendWheel(pixels: 20_000, to: scroll, host: host)
        try await host.settle()
        try #require(scroll.contentView.bounds != followed, "the original native wheel must actually move")
        let readingClip = scroll.contentView.bounds
        let sampler = try NativeTranscriptFrameSampler1008(host: host, chat: chat)
        defer { sampler.stop() }
        try sampler.begin("user-history-during-real-stream", session: session, text: text, scroll: scroll,
                          topMarker: fixture.messages[0].content.components(separatedBy: "\n")[0])
        let chunks = (0..<12).map { index in
            "1008-live-read-\(index)\n" + String(repeating: "new output does not own reading intent\n", count: 3)
        }
        for chunk in chunks {
            engine.continuation.yield(.textDelta(chunk))
            try await sampler.waitForFrames(sampler.phaseFrameCount + 3)
        }
        engine.continuation.finish()
        await turn.value
        try await sampler.waitForFrames(sampler.phaseFrameCount + 3)
        try sampler.requireCoverageAndNonblank()
        #expect(sampler.phaseFrames.allSatisfy { $0.clip == readingClip && $0.topVisible })
        #expect(Set(sampler.phaseFrames.map(\.characters)).count > 3)
        #expect(chat.messages.last?.content == "1008-live-read-first\n" + chunks.joined())
        #expect(chat.messages.last?.isStreaming == false)
    }

    @Test("old session's actual late chunks cannot write the new native viewport")
    func liveOldSessionDeltaCannotMoveCurrentNativeViewport1008() async throws {
        let (chat, oldEngine, _, host) = try makeLiveTranscript1008(tag: "A")
        let newEngine = ControlledFrameStreamEngine()
        defer {
            oldEngine.continuation.finish(); newEngine.continuation.finish()
            chat.stopAllStreamingForSafety(); host.close()
        }
        chat.draftText = "1008 A starts"
        chat.sendDraft()
        try await requireLiveProducer1008(oldEngine)
        let oldSession = try #require(chat.activeSessionID)
        let oldTurn = try #require(chat.turnTaskForTests(sessionID: oldSession))
        oldEngine.continuation.yield(.textDelta("1008-A-first\n"))
        try await host.settle()
        chat.newSession()
        let newSession = try #require(chat.activeSessionID)
        #expect(newSession != oldSession)
        let newHistory = Transcript434Fixture(tag: "1008-B")
        // Seed history once, before streaming. Every later output mutation is
        // exclusively the real consumeAgentStream/coalescer/writeback path.
        chat.messages = newHistory.messages
        chat.agentEngine = newEngine
        chat.draftText = "1008 B starts"
        chat.sendDraft()
        try await requireLiveProducer1008(newEngine)
        let newTurn = try #require(chat.turnTaskForTests(sessionID: newSession))
        newEngine.continuation.yield(.textDelta("1008-B-first\n"))
        try await host.settle()
        let text = try host.text(containing: "434-1008-B-history-0-start")
        let scroll = try host.outerScroll(containing: text)
        let newClip = scroll.contentView.bounds
        let newMessages = chat.messages
        let sampler = try NativeTranscriptFrameSampler1008(host: host, chat: chat)
        defer { sampler.stop() }
        try sampler.begin("B-visible-A-late-real-stream", session: newSession, text: text, scroll: scroll,
                          topMarker: newHistory.messages[0].content.components(separatedBy: "\n")[0])
        let lateChunks = (0..<12).map { "1008-A-late-\($0)\n" }
        for chunk in lateChunks {
            oldEngine.continuation.yield(.textDelta(chunk))
            try await sampler.waitForFrames(sampler.phaseFrameCount + 3)
        }
        oldEngine.continuation.finish()
        await oldTurn.value
        try await sampler.waitForFrames(sampler.phaseFrameCount + 3)
        try sampler.requireCoverageAndNonblank()
        #expect(sampler.phaseFrames.allSatisfy { $0.clip == newClip && !$0.oldSessionTextPresent })
        #expect(chat.messages == newMessages)
        let oldMessages = try #require(chat.sessions.first(where: { $0.id == oldSession })?.messages)
        #expect(oldMessages.last?.content == "1008-A-first\n" + lateChunks.joined(),
                "the old producer must actually consume every late chunk in its own session")
        #expect(oldMessages.last?.isStreaming == false)
        newEngine.continuation.finish()
        await newTurn.value
    }

    private func makeLiveTranscript1008(tag: String) throws
        -> (ChatStore, ControlledFrameStreamEngine, Transcript434Fixture, Transcript434Host) {
        let chat = ChatStore()
        chat.newSession()
        let fixture = Transcript434Fixture(tag: "1008-\(tag)", liveChat: chat)
        chat.messages = fixture.messages
        let engine = ControlledFrameStreamEngine()
        chat.agentEngine = engine
        let host = try Transcript434Host(fixture)
        return (chat, engine, fixture, host)
    }

    private func requireLiveProducer1008(_ engine: ControlledFrameStreamEngine) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while engine.executionIdentity == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        _ = try #require(engine.executionIdentity, "actual sendDraft must enter the existing controlled stream engine")
        _ = try #require(engine.composerSnapshot, "the original turn identity must be supplied by ChatStore")
    }
}

@MainActor
private final class NativeTranscriptFrameSampler1008: NSObject {
    enum ProbeStage: String, Codable { case original, hold, growth, terminal }
    enum ProbePointKind: String, Codable { case stage, yieldEnter, yieldReturn, waitEnter, waitReturn, turnWaitEnter, turnWaitReturn }
    struct ProbePoint: Codable {
        let kind: ProbePointKind
        let stage: ProbeStage
        let wallTimestamp: Double
        let actualFrameCount: Int
        let expectedFrameCount: Int?
        let chunkIndex: Int?
    }
    struct Frame: Codable {
        let probeStage: ProbeStage
        let callbackEntry: Double
        var callbackExit: Double
        var callbackDuration: Double
        let displayLinkDuration: Double
        let charactersReadEntry: Double
        let charactersReadExit: Double
        let containsReadEntry: Double
        let containsReadExit: Double
        let phase: String
        let timestamp: Double
        let targetTimestamp: Double
        let sessionMatches: Bool
        let nativeTextAttached: Bool
        let clip: CGRect
        let visible: CGRect
        let gap: CGFloat
        let characters: Int
        let topVisible: Bool
        let oldSessionTextPresent: Bool
        let streaming: Bool
    }
    private let host: Transcript434Host
    private let chat: ChatStore
    private let proofURL: URL
    private let expectedFramePeriod: Double
    private var link: CADisplayLink?
    private var text: NSTextView?
    private var scroll: NSScrollView?
    private var topGlyph = CGRect.zero
    private var expectedSession: UUID?
    private var phase = ""
    private var probeStage: ProbeStage = .original
    private var probePoints: [ProbePoint] = []
    private(set) var phaseFrames: [Frame] = []
    var phaseFrameCount: Int { phaseFrames.count }
    var longestOffTailRun: Int {
        var longest = 0, current = 0
        for frame in phaseFrames {
            current = frame.gap > 24 ? current + 1 : 0
            longest = max(longest, current)
        }
        return longest
    }

    init(host: Transcript434Host, chat: ChatStore) throws {
        self.host = host
        self.chat = chat
        let screen = try #require(host.window.screen, "the owned window must be on an actual display")
        let displayHz = screen.maximumFramesPerSecond
        try #require(displayHz > 0, "unknown display cadence cannot be a one-frame proof")
        expectedFramePeriod = 1 / Double(displayHz)
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let proofRoot = profile.rootDirectory.appendingPathComponent("task1008-native-frames-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: proofRoot, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        proofURL = proofRoot.appendingPathComponent("native-frames.json")
        super.init()
        let actual = host.window.displayLink(target: self, selector: #selector(sample(_:)))
        link = actual
        let cadence = Float(displayHz)
        actual.preferredFrameRateRange = CAFrameRateRange(minimum: cadence, maximum: cadence, preferred: cadence)
        actual.add(to: .main, forMode: .common)
        print("TRANSCRIPT1008 proofRoot=\(proofRoot.path) actualNativeDisplayLink=true displayHz=\(displayHz)")
    }

    func begin(_ phase: String, session: UUID, text: NSTextView, scroll: NSScrollView,
               topMarker: String) throws {
        try #require(text.window === host.window && scroll.window === host.window)
        // Obtain the historical glyph once from the settled original host.
        // Per-frame callbacks never ensureLayout/display/layoutSubtree.
        topGlyph = try host.glyphRect(marker: topMarker, text: text)
        self.phase = phase
        expectedSession = session
        self.text = text
        self.scroll = scroll
        phaseFrames.removeAll(keepingCapacity: true)
    }

    func markProbeStage(_ stage: ProbeStage) {
        probeStage = stage
        recordProbePoint(.stage)
    }

    func recordProbePoint(_ kind: ProbePointKind, expectedFrameCount: Int? = nil, chunkIndex: Int? = nil) {
        probePoints.append(ProbePoint(
            kind: kind, stage: probeStage, wallTimestamp: CACurrentMediaTime(),
            actualFrameCount: phaseFrameCount, expectedFrameCount: expectedFrameCount, chunkIndex: chunkIndex
        ))
    }

    @objc private func sample(_ displayLink: CADisplayLink) {
        let callbackEntry = CACurrentMediaTime()
        guard let text, let scroll, let document = scroll.documentView, !phase.isEmpty else { return }
        // Keep the original primitive read expressions and their order. In
        // particular the two original text.string reads are not consolidated.
        let timestamp = displayLink.timestamp
        let targetTimestamp = displayLink.targetTimestamp
        let sessionMatches = chat.activeSessionID == expectedSession
        let nativeTextAttached = text.window === host.window
        let clip = scroll.contentView.bounds
        let visible = text.visibleRect
        let gap = document.bounds.maxY - scroll.contentView.bounds.maxY
        let charactersReadEntry = CACurrentMediaTime()
        let characters = text.string.utf16.count
        let charactersReadExit = CACurrentMediaTime()
        let topVisible = !text.visibleRect.isEmpty && text.visibleRect.intersects(topGlyph)
        let containsReadEntry = CACurrentMediaTime()
        let oldSessionTextPresent = text.string.contains("1008-A-late-")
        let containsReadExit = CACurrentMediaTime()
        let streaming = chat.messages.last?.isStreaming == true
        let frameIndex = phaseFrames.count
        phaseFrames.append(Frame(
            probeStage: probeStage, callbackEntry: callbackEntry, callbackExit: 0, callbackDuration: 0,
            displayLinkDuration: displayLink.duration,
            charactersReadEntry: charactersReadEntry, charactersReadExit: charactersReadExit,
            containsReadEntry: containsReadEntry, containsReadExit: containsReadExit,
            phase: phase, timestamp: timestamp, targetTimestamp: targetTimestamp,
            sessionMatches: sessionMatches, nativeTextAttached: nativeTextAttached,
            clip: clip, visible: visible, gap: gap, characters: characters,
            topVisible: topVisible, oldSessionTextPresent: oldSessionTextPresent, streaming: streaming
        ))
        // Includes the primitive reads and frame append. The final metadata
        // assignments/return are outside this measured interval, not hidden as zero cost.
        let callbackExit = CACurrentMediaTime()
        phaseFrames[frameIndex].callbackExit = callbackExit
        phaseFrames[frameIndex].callbackDuration = callbackExit - callbackEntry
    }

    func waitForFrames(_ count: Int) async throws {
        recordProbePoint(.waitEnter, expectedFrameCount: count)
        defer { recordProbePoint(.waitReturn, expectedFrameCount: count) }
        let deadline = ContinuousClock.now + .seconds(3)
        while phaseFrames.count < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        try #require(phaseFrames.count >= count,
                     "zero/missing native display-link callbacks cannot count as frame evidence")
    }

    func requireCoverageAndNonblank() throws {
        try persist()
        try #require(phaseFrames.count >= 3, "actual native frame samples must exist")
        #expect(phaseFrames.allSatisfy { $0.sessionMatches && $0.nativeTextAttached })
        #expect(phaseFrames.contains { $0.streaming }, "native samples must include an unfinished real turn")
        var consecutiveEmpty = 0
        var cadenceGapExceedances = 0
        var maximumAdjacentTimestampGap: Double = 0
        for (index, frame) in phaseFrames.enumerated() {
            let period = frame.targetTimestamp - frame.timestamp
            try #require(period > 0 && period.isFinite, "actual native frame period must be readable")
            try #require(period <= expectedFramePeriod * 1.5,
                         "a lower-rate callback cannot relax the display's original one-frame standard")
            if index > 0 {
                let previous = phaseFrames[index - 1]
                let previousPeriod = previous.targetTimestamp - previous.timestamp
                try #require(frame.timestamp > previous.timestamp)
                // CADisplayLink delivery is best effort. Keep its actual gap
                // as a metric; visible viewport assertions below remain binding.
                let adjacentTimestampGap = frame.timestamp - previous.timestamp
                maximumAdjacentTimestampGap = max(maximumAdjacentTimestampGap, adjacentTimestampGap)
                if adjacentTimestampGap > max(period, previousPeriod) * 1.5 {
                    cadenceGapExceedances += 1
                }
            }
            let empty = frame.characters == 0 || frame.visible.isEmpty || frame.clip.isEmpty
            consecutiveEmpty = empty ? consecutiveEmpty + 1 : 0
            #expect(consecutiveEmpty <= 1, "original D-PERF-02 allows no disappearance longer than one frame")
        }
        print("TRANSCRIPT1008 phase=\(phase) realFrames=\(phaseFrames.count) maxOffTailFrames=\(longestOffTailRun) cadenceGapExceedances=\(cadenceGapExceedances) maximumAdjacentTimestampGapMs=\(maximumAdjacentTimestampGap * 1_000)")
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(phaseFrames).write(to: proofURL, options: .atomic)
        try encoder.encode(probePoints).write(
            to: proofURL.deletingLastPathComponent().appendingPathComponent("native-timing-points.json"),
            options: .atomic
        )
        print("TRANSCRIPT1008 frames=\(phaseFrames.count) proof=\(proofURL.path)")
    }

    func stop() {
        link?.invalidate()
        link = nil
        // Keep partial evidence even when a require aborts a phase.
        do { try persist() } catch { print("TRANSCRIPT1008 proofWriteFailed=\(error)") }
    }
}
