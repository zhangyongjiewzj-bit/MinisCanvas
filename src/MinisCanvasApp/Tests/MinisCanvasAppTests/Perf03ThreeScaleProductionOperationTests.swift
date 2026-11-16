import AppKit
import CryptoKit
import Darwin
import Foundation
import os
import SwiftUI
import Testing
@testable import MinisCanvasApp

/// Bounded, synthetic workload for the existing production document cache and
/// its native consumer. This does not substitute a formatter/redactor/layout
/// implementation. Existing production signposts are collected externally;
/// lastFormattedMessageCount and native coordinator state are separate work
/// oracles, never relabelled as exact parser/redactor/layout call counts.
@Suite("D-PERF-03 three-scale production operation sampling", .serialized)
@MainActor
struct Perf03ThreeScaleProductionOperationTests {
    private static let samplesPerOperation = 40
    private static let sourceEquivalentBase = "f3ba67fbb425f00235836ca377aadb1f0012acb5"

    private struct Sample: Codable {
        let id: String
        let phase: String
        let index: Int
        let inputUTF16: Int
        let documentUTF16: Int
        let formattedMessages: Int
        let revisionBefore: UInt64
        let revisionAfter: UInt64
        let scope: String?
        let patchStart: Int?
        let patchUTF16: Int?
        let nativePendingTailStart: Int?
        let renderMilliseconds: Double
        let applyMilliseconds: Double
        let layoutMilliseconds: Double
        let totalMilliseconds: Double
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let value = duration.components
        return Double(value.seconds) * 1_000 + Double(value.attoseconds) / 1e15
    }

    /// Nearest rank: N=40 gives P95=sorted[37], distinct from sorted[39]/max.
    private func percentile(_ values: [Double], fraction: Double) -> Double {
        let sorted = values.sorted()
        precondition(sorted.count >= Self.samplesPerOperation)
        return sorted[max(0, Int(ceil(fraction * Double(sorted.count))) - 1)]
    }

    private func load() -> [String: String] {
        var averages = [Double](repeating: 0, count: 3)
        let obtained = getloadavg(&averages, 3)
        let info = ProcessInfo.processInfo
        return ["timestampUnix": String(Date().timeIntervalSince1970),
                "pid": String(info.processIdentifier),
                "cpuCount": String(info.processorCount),
                "activeCPUCount": String(info.activeProcessorCount),
                "thermalState": String(info.thermalState.rawValue),
                "loadAvg1m5m15m": obtained == 3 ? averages.map { String($0) }.joined(separator: ",") : "UNKNOWN",
                "probeConcurrency": "1", "streams": "1",
                "scope": "in-process synthetic cache/native-consumer; no App window"]
    }

    /// Observe native state without creating/activating NSApplication or a window.
    private func nativeAppState() -> [String: String] {
        ["exists": String(NSApp != nil),
         "running": String(NSApp?.isRunning ?? false),
         "active": String(NSApp?.isActive ?? false),
         "windows": String(NSApp?.windows.count ?? 0),
         "visibleWindows": String(NSApp?.windows.filter(\.isVisible).count ?? 0)]
    }

    private func history(utf16Count: Int, secret: String) -> [ChatMessageUI] {
        let messageCount = 100
        let perMessage = utf16Count / messageCount
        precondition(utf16Count % messageCount == 0)
        return (0..<messageCount).map { index in
            let heading = "# 合成历史 \(index)\n\n**正文** \(secret)\n\n- 有界列表\n\n"
            precondition(heading.utf16.count < perMessage)
            let content = heading + String(repeating: "史", count: perMessage - heading.utf16.count)
            return ChatMessageUI(role: index.isMultiple(of: 2) ? .user : .assistant, content: content)
        }
    }

    private struct CorpusRow: Decodable {
        let index: Int
        let role: String
        let content: String
    }
    private struct DeltaRow: Decodable {
        let step: Int
        let append: String
        let append_utf16_units: Int
        let cumulative_tail_utf16_units: Int
    }
    private struct ApprovedCorpus {
        let messages: [ChatMessageUI]
        let deltaCharacters: [String]
        let provenance: [String: String]
    }
    private static let approvedCorpusRoot = URL(fileURLWithPath:
        (ProcessInfo.processInfo.environment["MINISCANVAS_PERF03_CORPUS_DIR"] ?? "/Users/me/perf03-corpus"),
        isDirectory: true)
    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func approvedBytes(_ name: String, sha256: String) throws -> Data {
        let url = Self.approvedCorpusRoot.appendingPathComponent(name)
        let facts = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        try #require(facts.isRegularFile == true && facts.isSymbolicLink != true)
        try #require((facts.fileSize ?? 300_001) <= 300_000)
        let bytes = try Data(contentsOf: url)
        try #require(digest(bytes) == sha256, "only approved original synthetic corpus bytes may be decoded")
        return bytes
    }
    private func approvedCorpus(scale: Int, secret: String) throws -> ApprovedCorpus {
        let manifestSHA = "51f9dad84639ecaffb85f165927fd787e1a40ff0813f1994c1f6b62fc27b3a43"
        let manifestBytes = try approvedBytes("CORPUS_MANIFEST.json", sha256: manifestSHA)
        let manifest = try #require(JSONSerialization.jsonObject(with: manifestBytes) as? [String: Any])
        try #require(manifest["source_fixture"] as? String == "SessionPackageFieldFixture.preparePerformance")
        try #require(manifest["source_head"] as? String == "2aa229e97057d63712d126193569034e523803b5")
        let deltaSHA = "dfe9a7fbcc8e32a19c13e3c7bff8441979c6b8eb0852c3f9cb8c5521a55cad76"
        let deltaBytes = try approvedBytes("production_consumer_20_stream_deltas.jsonl", sha256: deltaSHA)
        let deltas = try String(decoding: deltaBytes, as: UTF8.self).split(separator: "\n").map {
            try JSONDecoder().decode(DeltaRow.self, from: Data($0.utf8))
        }
        try #require(deltas.count == 20)
        for (offset, row) in deltas.enumerated() {
            try #require(row.step == offset + 1 && row.append == "增"
                && row.append_utf16_units == 1 && row.cumulative_tail_utf16_units == offset + 1)
        }
        if scale == 150_000 {
            return ApprovedCorpus(messages: history(utf16Count: scale, secret: secret),
                deltaCharacters: deltas.map(\.append),
                provenance: ["kind": "SUPPLEMENTAL_150K_SYNTHETIC_NOT_0740",
                    "historySource": "test history(utf16Count:secret:)",
                    "manifestPath": Self.approvedCorpusRoot.appendingPathComponent("CORPUS_MANIFEST.json").path,
                    "manifestSHA256": manifestSHA, "deltaSHA256": deltaSHA,
                    "modelTokens": "NOT_MEASURED; character deltas repeated twice for N40"])
        }
        try #require(scale == 50_000 || scale == 100_000)
        let name = "perf07_session_\(scale)_messages.jsonl"
        let sha = scale == 50_000
            ? "e3ceeee8ea99d19ec49d165569da182badc994e22e5b9e1d9cc980f8b50c1476"
            : "6cb5627dac1a06305025702166dfc94258fff2549893e55b04b0cd7d65c1f9a6"
        let files = try #require(manifest["files"] as? [[String: Any]])
        try #require(files.contains { $0["path"] as? String == name && $0["sha256"] as? String == sha })
        let bytes = try approvedBytes(name, sha256: sha)
        let rows = try String(decoding: bytes, as: UTF8.self).split(separator: "\n").map {
            try JSONDecoder().decode(CorpusRow.self, from: Data($0.utf8))
        }
        try #require(rows.count == 20)
        for (offset, row) in rows.enumerated() {
            let index = offset + 1
            let prefix = "PERF07 synthetic \(scale) UTF16 message \(index): "
            try #require(row.index == index && row.role == (index.isMultiple(of: 2) ? "assistant" : "user"))
            try #require(row.content == prefix + String(repeating: "文", count: scale / 20 - prefix.utf16.count))
        }
        return ApprovedCorpus(messages: rows.map {
            ChatMessageUI(role: $0.role == "assistant" ? .assistant : .user, content: $0.content)
        }, deltaCharacters: deltas.map(\.append),
            provenance: ["kind": "ORIGINAL_0740_FIELD_CONTENT_SPEC",
                "historyPath": Self.approvedCorpusRoot.appendingPathComponent(name).path,
                "historySHA256": sha, "manifestSHA256": manifestSHA,
                "producerFixture": "SessionPackageFieldFixture.preparePerformance",
                "producerFixtureSHA256": "239d7e2617bf6997dd7ddc281ef6e7c12fa005231aea09bffa37c6cf2327785b",
                "deltaSHA256": deltaSHA,
                "modelTokens": "NOT_MEASURED; 20 original character deltas repeated twice for N40"])
    }

    /// Diagnostics preserve all attributes. No font/style normalization or
    /// ignored keys enter the equality oracle; only the stages are aligned.
    private func attributeDifference(_ left: NSAttributedString, _ right: NSAttributedString) -> [String: String] {
        var changed: Set<String> = []
        var firstRange = "none"
        let length = min(left.length, right.length)
        var offset = 0
        while offset < length {
            var aRange = NSRange(), bRange = NSRange()
            let a = left.attributes(at: offset, effectiveRange: &aRange)
            let b = right.attributes(at: offset, effectiveRange: &bRange)
            for key in Set(a.keys).union(b.keys) {
                let equal: Bool
                if a[key] == nil && b[key] == nil { equal = true }
                else if let value = a[key] as? NSObject { equal = value.isEqual(b[key]) }
                else { equal = false }
                if !equal {
                    changed.insert(key.rawValue)
                    if firstRange == "none" { firstRange = "\(offset):\(min(NSMaxRange(aRange), NSMaxRange(bRange)))" }
                }
            }
            offset = min(NSMaxRange(aRange), NSMaxRange(bRange))
        }
        return ["textEqual": String(left.string == right.string),
                "attributedEqual": String(left.isEqual(to: right)),
                "leftUTF16": String(left.length), "rightUTF16": String(right.length),
                "changedAttributes": changed.sorted().joined(separator: ","), "firstChangedRangeUTF16": firstRange]
    }

    private func observe(
        phase: String, index: Int, scale: Int,
        cache: ChatTranscriptDocumentCache, session: UUID,
        messages: [ChatMessageUI], redactor: ChatTranscriptRedactor,
        host: NSScrollView, coordinator: ReadOnlyAttributedTextView.Coordinator,
        proposal: ProposedViewSize
    ) throws -> Sample {
        let population = Perf03N40PopulationContext.trace
        try population?.beforeOriginalSample(phase: phase, index: index, scale: scale,
            messages: messages, session: session, cache: cache)
        let primaryEventStart = population?.eventCount ?? 0
        let sampleID = UUID().uuidString
        let oldRevision = cache.update.revision
        let oldNativeRevision = coordinator.appliedTranscriptRevision
        TranscriptPerformanceSignposts.signposter.emitEvent(
            "PERF03ProbeStepBegin",
            "sample=\(sampleID, privacy: .public) scaleUTF16=\(scale, privacy: .public) phase=\(phase, privacy: .public) index=\(index, privacy: .public)"
        )
        let started = ContinuousClock.now
        let document = cache.render(sessionID: session, messages: messages, baseSize: 13, redactor: redactor)
        let afterRender = ContinuousClock.now
        let patch = cache.update.patch(forAppliedRevision: oldNativeRevision)
        let view = ReadOnlyAttributedTextView(transcriptDocument: document, update: cache.update)
        view.updateNSView(host, coordinator: coordinator)
        let pendingTail = coordinator.pendingTailStart
        let afterApply = ContinuousClock.now
        let size = view.sizeThatFits(proposal, nsView: host, coordinator: coordinator)
        let afterLayout = ContinuousClock.now
        try #require(size != nil && size!.height > 0)
        #expect(coordinator.appliedTranscriptRevision == cache.update.revision)
        #expect(coordinator.pendingTailStart == nil)
        let sample = Sample(id: sampleID, phase: phase, index: index, inputUTF16: scale,
            documentUTF16: document.attributedString.length,
            formattedMessages: cache.lastFormattedMessageCount,
            revisionBefore: oldRevision, revisionAfter: cache.update.revision,
            scope: cache.update.diagnosticScope?.id,
            patchStart: patch?.start, patchUTF16: patch?.value.length,
            nativePendingTailStart: pendingTail,
            renderMilliseconds: milliseconds(started.duration(to: afterRender)),
            applyMilliseconds: milliseconds(afterRender.duration(to: afterApply)),
            layoutMilliseconds: milliseconds(afterApply.duration(to: afterLayout)),
            totalMilliseconds: milliseconds(started.duration(to: afterLayout)))
        TranscriptPerformanceSignposts.signposter.emitEvent(
            "PERF03ProbeStepEnd",
            "sample=\(sampleID, privacy: .public) scaleUTF16=\(scale, privacy: .public) phase=\(phase, privacy: .public) index=\(index, privacy: .public)"
        )
        try population?.record(phase: phase, index: index, sampleID: sampleID, scale: scale,
            messages: messages, session: session, cache: cache,
            revisionBefore: oldRevision, primaryEventStart: primaryEventStart)
        print("PERF03_RAW_SAMPLE \(String(decoding: try JSONEncoder().encode(sample), as: UTF8.self))")
        return sample
    }

    /// First selector only proves observer visibility; all events are artificial.
    /// If this fails, stop before the three workload cases rather than repeating failures.
    @Test
    func currentProcessCollectorCalibrationIsVisible() async throws {
        let formal = try #require(ProcessInfo.processInfo.environment["MINISCANVAS_TEST_DIRECTORY"])
        let file = URL(fileURLWithPath: formal, isDirectory: true)
            .appendingPathComponent("perf03-count-observer-preflight-\(UUID().uuidString).json")
        do {
            let events = try await Perf03CurrentProcessSignpostCollector().calibrate()
            let record: [String: Any] = ["status": "CALIBRATION_ONLY_NOT_PRODUCTION_COUNTS",
                "observer": "OSLogStore.currentProcessIdentifier", "artificialEventCount": events.count,
                "productionCounts": "NOT_RUN", "permissionChanged": false]
            try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: file)
            print("PERF03_COUNT_OBSERVER_PREFLIGHT artifact=\(file.path) status=CALIBRATION_ONLY_NOT_PRODUCTION_COUNTS")
        } catch {
            let record: [String: Any] = ["status": "NOT_OBSERVED", "reason": String(describing: error),
                "productionCounts": NSNull(), "permissionChanged": false]
            try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: file)
            print("PERF03_COUNT_OBSERVER_PREFLIGHT artifact=\(file.path) status=NOT_OBSERVED; stop before workload")
            throw error
        }
    }

    /// Counts-only replay. Existing N40/P95 evidence is not rerun or replaced.
    /// One real production invocation per phase; loop cardinality is never a call count.
    @Test(arguments: [50_000, 100_000, 150_000])
    func currentProcessSignpostsCountProductionOperations(scale: Int) async throws {
        let formal = try #require(ProcessInfo.processInfo.environment["MINISCANVAS_TEST_DIRECTORY"])
        let root = URL(fileURLWithPath: formal, isDirectory: true)
            .appendingPathComponent("perf03-counts-\(scale)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let collector = Perf03CurrentProcessSignpostCollector()
        let nativeBefore = nativeAppState()
        do {
            let artificialCalibration = try await collector.calibrate()
            let corpus = try approvedCorpus(scale: scale, secret: "owned-PERF03-count-secret")
            var messages = corpus.messages
            let originalMessageIDs = messages.map(\.id)
            let cache = ChatTranscriptDocumentCache()
            let session = UUID()
            let redactor = ChatTranscriptRedactor(secretValues: ["owned-PERF03-count-secret"])
            let coordinator = ReadOnlyAttributedTextView.Coordinator()
            let proposal = ProposedViewSize(width: 600, height: nil)
            var host: NSScrollView?
            defer {
                if let host { ReadOnlyAttributedTextView.dismantleNSView(host, coordinator: coordinator) }
            }
            var steps: [Perf03CurrentProcessSignpostCollector.Step] = []
            @MainActor func perform(_ phase: String, mutation: () -> Void) throws {
                let id = UUID().uuidString
                let before = cache.update.revision
                collector.begin(id)
                mutation()
                let document = cache.render(sessionID: session, messages: messages,
                    baseSize: 13, redactor: redactor)
                let view = ReadOnlyAttributedTextView(transcriptDocument: document, update: cache.update)
                if host == nil { host = view.makeNSView(coordinator: coordinator) }
                else { view.updateNSView(try #require(host), coordinator: coordinator) }
                let measuredHost = try #require(host)
                let candidateSize = view.sizeThatFits(proposal, nsView: measuredHost, coordinator: coordinator)
                let size = try #require(candidateSize)
                collector.end(id)
                try #require(size.height > 0)
                #expect(coordinator.appliedTranscriptRevision == cache.update.revision)
                steps.append(.init(id: id, phase: phase,
                    scope: try #require(cache.update.diagnosticScope?.id),
                    revisionBefore: before, revisionAfter: cache.update.revision,
                    formattedMessagesOracle: cache.lastFormattedMessageCount))
            }
            try perform("initial-history") {}
            #expect(cache.lastFormattedMessageCount == messages.count)
            let chat = ChatStore() // no persistence, App window or Provider attachment
            try perform("draft") { chat.draftText += "输" }
            #expect(cache.lastFormattedMessageCount == 0)
            try perform("new-message") {
                messages.append(ChatMessageUI(role: .user, content: "合成新消息 owned-PERF03-count-secret"))
                messages.append(ChatMessageUI(role: .assistant, content: "合成新回复"))
            }
            #expect(cache.lastFormattedMessageCount == 2)
            try perform("stream-setup") {
                messages.append(ChatMessageUI(role: .assistant, content: "", isStreaming: true))
            }
            try perform("stream-character") {
                messages[messages.count - 1].content += corpus.deltaCharacters[0]
            }
            #expect(cache.lastFormattedMessageCount == 1)
            #expect(Array(messages.prefix(originalMessageIDs.count).map(\.id)) == originalMessageIDs)
            try perform("historical-edit-control") {
                messages[0].content += " changed-history-count-control"
            }
            #expect(cache.lastFormattedMessageCount == messages.count)
            let captured = try await collector.collect(steps: steps)
            let nativeAfter = nativeAppState()
            #expect(nativeBefore["visibleWindows"] == nativeAfter["visibleWindows"])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(captured.raw).write(to: root.appendingPathComponent("raw-own-process-signposts.json"))
            try encoder.encode(captured.counts).write(to: root.appendingPathComponent("production-event-counts.json"))
            try encoder.encode(artificialCalibration).write(to: root.appendingPathComponent("excluded-artificial-calibration.json"))
            let artifact: [String: Any] = [
                "requirement": "D-PERF-03", "status": "CALIBRATED_PRODUCTION_EVENT_ROWS_OBSERVED",
                "sourceEquivalentBase": Self.sourceEquivalentBase, "scaleUTF16": scale,
                "historyMessageCount": corpus.messages.count, "corpus": corpus.provenance,
                "processIdentifier": ProcessInfo.processInfo.processIdentifier,
                "observer": "OSLogStore.currentProcessIdentifier; OSLogEntrySignpost.event",
                "productionEvents": ["TranscriptParseCall", "TranscriptRedactCall", "TranscriptTextKitLayoutRequest"],
                "boundaryAndScope": "exclusive begin/end native-entry order AND matching production opaque scope",
                "workloadInvocationsPerPhase": 1, "workloadInvocationsAreProductionCallCounts": false,
                "artificialCalibrationExcluded": true, "explicitLayoutRequestDefinition": "instrumented ensureLayout call sites only",
                "untrackedTextKitInternalCallbacks": "NOT_OBSERVED",
                "anchorGeometryLayout": "NOT_INVOKED_BY_THIS_COMPONENT_REPLAY; no zero inference",
                "observerLosslessness": "NOT_GUARANTEED_BY_OSLogStore; calibrated named event rows, raw retained",
                "latencyAndP95": "NOT_RESAMPLED; existing accepted N40 evidence remains separate",
                "modelTokens": "NOT_MEASURED; one approved character delta",
                "beforeNativeApp": nativeBefore, "afterNativeApp": nativeAfter,
                "actualUIKeyboardProviderOrPresentedFrame": "NOT_OBSERVED"
            ]
            try JSONSerialization.data(withJSONObject: artifact, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("summary.json"))
            print("PERF03_COUNTS_ARTIFACT root=\(root.path) status=CALIBRATED_PRODUCTION_EVENT_ROWS_OBSERVED scaleUTF16=\(scale) phases=6 invocationsPerPhase=1 P95=NOT_RESAMPLED")
        } catch {
            let artifact: [String: Any] = ["requirement": "D-PERF-03", "status": "NOT_OBSERVED",
                "scaleUTF16": scale, "reason": String(describing: error),
                "parseCalls": NSNull(), "redactCalls": NSNull(), "layoutCalls": NSNull(),
                "systemPermissionChanged": false, "sourceChanged": false,
                "latencyAndP95": "NOT_RESAMPLED"]
            try JSONSerialization.data(withJSONObject: artifact, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("NOT_OBSERVED.json"))
            print("PERF03_COUNTS_NOT_OBSERVED root=\(root.path) scaleUTF16=\(scale); no zero inference")
            throw error // missing observation cannot become a framework PASS
        }
    }

    @Test(arguments: [50_000, 100_000, 150_000])
    func draftAppendAndStreamingTokenRetainHistory(scale: Int) throws {
        try #require(TranscriptOperationDiagnostics.enabled,
            "runner must set MINISCANVAS_TRANSCRIPT_OPERATION_DIAGNOSTICS=1 before process start; exact call counts need external production-signpost capture")
        let formal = try #require(ProcessInfo.processInfo.environment["MINISCANVAS_TEST_DIRECTORY"])
        let root = URL(fileURLWithPath: formal, isDirectory: true)
            .appendingPathComponent("perf03-\(scale)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let beforeLoad = load()
        let beforeNativeApp = nativeAppState()
        let secret = "owned-PERF03-secret"
        let corpus = try approvedCorpus(scale: scale, secret: secret)
        var messages = corpus.messages
        let originalMessageIDs = messages.map(\.id)
        let originalMessageCount = messages.count
        #expect(originalMessageCount == (scale == 150_000 ? 100 : 20))
        #expect(messages.reduce(0) { $0 + $1.content.utf16.count } == scale)
        let cache = ChatTranscriptDocumentCache()
        let session = UUID()
        let redactor = ChatTranscriptRedactor(secretValues: [secret])
        let initial = cache.render(sessionID: session, messages: messages, baseSize: 13, redactor: redactor)
        #expect(cache.lastFormattedMessageCount == originalMessageCount)
        // Formatter-stage full history is compared only with formatter-stage history.
        let frozenFormatterHistory = NSAttributedString(attributedString: initial.attributedString)
        let historyBoundary = initial.attributedString.length
        // The terminal initial message can acquire a new paragraph boundary
        // when the first append arrives. Freeze native CLOSED fragments by ID;
        // the entire initial history remains protected by the formatter oracle.
        let closedHistoryBoundary = initial.messageStartLocations[originalMessageCount - 1]
        let closedHistoryMessageIDs = Array(originalMessageIDs.dropLast())
        let generation = cache.update.generation
        let coordinator = ReadOnlyAttributedTextView.Coordinator()
        let firstView = ReadOnlyAttributedTextView(transcriptDocument: initial, update: cache.update)
        let host = firstView.makeNSView(coordinator: coordinator)
        defer { ReadOnlyAttributedTextView.dismantleNSView(host, coordinator: coordinator) }
        let text = try #require(host.documentView as? NSTextView)
        let proposal = ProposedViewSize(width: 600, height: nil)
        _ = try #require(firstView.sizeThatFits(proposal, nsView: host, coordinator: coordinator))
        let width = coordinator.cachedWidth
        let closedRange = NSRange(location: 0, length: closedHistoryBoundary)
        let frozenNativeHistory = NSAttributedString(attributedString:
            text.attributedString().attributedSubstring(from: closedRange))
        let initialStageDifference = attributeDifference(
            frozenFormatterHistory.attributedSubstring(from: closedRange), frozenNativeHistory)
        var historyChecks: [[String: String]] = []
        @MainActor func checkFrozenHistory(_ phase: String) throws {
            #expect(Array(messages.prefix(originalMessageCount).map(\.id)) == originalMessageIDs)
            #expect(cache.document.messageStartLocations[originalMessageCount - 1] == closedHistoryBoundary)
            let formatterPrefix = cache.document.attributedString.attributedSubstring(
                from: NSRange(location: 0, length: historyBoundary))
            let nativePrefix = text.attributedString().attributedSubstring(from: closedRange)
            let formatterDifference = attributeDifference(formatterPrefix, frozenFormatterHistory)
            let nativeDifference = attributeDifference(nativePrefix, frozenNativeHistory)
            let formatterUnchanged = formatterPrefix.isEqual(to: frozenFormatterHistory)
            let nativeUnchanged = nativePrefix.isEqual(to: frozenNativeHistory)
            #expect(formatterUnchanged, "formatter history changed: \(formatterDifference)")
            #expect(nativeUnchanged, "post-layout closed native history changed: \(nativeDifference)")
            let record = ["phase": phase, "scale": String(scale),
                "formatter": String(describing: formatterDifference),
                "native": String(describing: nativeDifference),
                "nativeClosedBoundaryUTF16": String(closedHistoryBoundary)]
            historyChecks.append(record)
            print("PERF03_HISTORY_ORACLE \(String(decoding: try JSONEncoder().encode(record), as: UTF8.self))")
        }
        let chat = ChatStore() // no persistence or provider is attached
        var samples: [Sample] = []

        for index in 0..<Self.samplesPerOperation {
            chat.draftText += "输"
            let sample = try observe(phase: "draft", index: index, scale: scale, cache: cache,
                session: session, messages: messages, redactor: redactor, host: host,
                coordinator: coordinator, proposal: proposal)
            #expect(sample.formattedMessages == 0)
            #expect(sample.revisionBefore == sample.revisionAfter)
            #expect(sample.nativePendingTailStart == nil)
            #expect(coordinator.cachedWidth == width)
            samples.append(sample)
        }
        #expect(chat.draftText == String(repeating: "输", count: Self.samplesPerOperation))
        try checkFrozenHistory("after-draft")

        for index in 0..<Self.samplesPerOperation {
            let oldLength = cache.document.attributedString.length
            messages.append(ChatMessageUI(role: .user, content: "合成新消息 \(index) \(secret)"))
            messages.append(ChatMessageUI(role: .assistant, content: "合成新回复 \(index)", isStreaming: false))
            let sample = try observe(phase: "new-message", index: index, scale: scale, cache: cache,
                session: session, messages: messages, redactor: redactor, host: host,
                coordinator: coordinator, proposal: proposal)
            #expect(sample.formattedMessages == 2, "a full-history rebuild would format at least \(originalMessageCount) messages")
            #expect(sample.patchStart == oldLength)
            #expect(sample.nativePendingTailStart == oldLength)
            #expect(sample.patchUTF16 != nil && sample.patchUTF16! < historyBoundary)
            #expect(cache.update.generation == generation)
            samples.append(sample)
        }

        try checkFrozenHistory("after-new-message")
        let activeTail = ChatMessageUI(role: .assistant, content: "", isStreaming: true)
        let activeTailID = activeTail.id
        messages.append(activeTail)
        let streamSetup = try observe(phase: "stream-setup", index: 0, scale: scale,
            cache: cache, session: session, messages: messages, redactor: redactor,
            host: host, coordinator: coordinator, proposal: proposal)
        #expect(streamSetup.formattedMessages == 1)
        #expect(messages.filter(\.isStreaming).count == 1)
        for index in 0..<Self.samplesPerOperation {
            let tailIndex = messages.count - 1
            messages[tailIndex].content += corpus.deltaCharacters[index % corpus.deltaCharacters.count]
            let sample = try observe(phase: "stream-token", index: index, scale: scale, cache: cache,
                session: session, messages: messages, redactor: redactor, host: host,
                coordinator: coordinator, proposal: proposal)
            #expect(sample.formattedMessages == 1, "a token may format only the active assistant message")
            #expect(sample.patchStart != nil && sample.patchStart! >= historyBoundary)
            #expect(sample.nativePendingTailStart == sample.patchStart)
            #expect(sample.patchUTF16 != nil && sample.patchUTF16! < historyBoundary)
            #expect(coordinator.cachedWidth == width)
            #expect(cache.update.generation == generation)
            samples.append(sample)
        }
        try checkFrozenHistory("after-stream")
        #expect(messages.last?.id == activeTailID)
        let activeStart = try #require(cache.document.messageStartLocations.last)
        let activeSource = cache.document.attributedString.attributedSubstring(from:
            NSRange(location: activeStart, length: cache.document.attributedString.length - activeStart))
        let activeBlock = try #require((activeSource.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
            as? NSParagraphStyle)?.textBlocks.first)
        let expectedActive = ChatTranscriptFormatter.formattedMessage(try #require(messages.last),
            baseSize: 13, redactor: redactor, block: activeBlock)
        let activeFormatterCorrect = activeSource.isEqual(to: expectedActive)
        #expect(activeFormatterCorrect, "active tail formatter differs: \(attributeDifference(activeSource, expectedActive))")
        #expect((text.string as NSString).substring(from: activeStart) == expectedActive.string)
        #expect(text.string == cache.document.attributedString.string)
        #expect(!text.string.contains(secret) && !cache.accessibilityText.contains(secret))

        // Positive control goes through the SAME production method. It must
        // actually invalidate all history, making this oracle discriminating.
        messages[0].content += " changed-history-control"
        let control = try observe(phase: "historical-edit-control", index: 0, scale: scale,
            cache: cache, session: session, messages: messages, redactor: redactor,
            host: host, coordinator: coordinator, proposal: proposal)
        #expect(control.formattedMessages == messages.count)
        #expect(cache.update.generation == generation + 1)
        #expect(control.patchStart == nil && control.nativePendingTailStart == nil)
        let editedPrefix = cache.document.attributedString.attributedSubstring(from:
            NSRange(location: 0, length: historyBoundary))
        let editedNativePrefix = text.attributedString().attributedSubstring(from: closedRange)
        let controlFormatterDifference = attributeDifference(editedPrefix, frozenFormatterHistory)
        let controlNativeDifference = attributeDifference(editedNativePrefix, frozenNativeHistory)
        #expect(!editedPrefix.isEqual(to: frozenFormatterHistory), "the same frozen-history oracle must detect a real historical edit")
        #expect(!editedNativePrefix.isEqual(to: frozenNativeHistory), "post-layout native oracle must detect the real historical edit")

        let raw = try JSONEncoder().encode(samples)
        try raw.write(to: root.appendingPathComponent("raw-samples.json"), options: .atomic)
        var summaries: [String: [String: Double]] = [:]
        for phase in ["draft", "new-message", "stream-token"] {
            let group = samples.filter { $0.phase == phase }
            #expect(group.count == Self.samplesPerOperation)
            var metrics: [String: Double] = [:]
            for (stage, values) in [("render", group.map(\.renderMilliseconds)),
                                    ("nativeApply", group.map(\.applyMilliseconds)),
                                    ("layout", group.map(\.layoutMilliseconds)),
                                    ("total", group.map(\.totalMilliseconds))] {
                metrics[stage + "P50Ms"] = percentile(values, fraction: 0.50)
                metrics[stage + "P95Ms"] = percentile(values, fraction: 0.95)
                metrics[stage + "MaxMs"] = values.max()
            }
            summaries[phase] = metrics
        }
        let afterNativeApp = nativeAppState()
        #expect(afterNativeApp["visibleWindows"] == beforeNativeApp["visibleWindows"],
                "the component probe must not open an App window")
        let artifact: [String: Any] = [
            "requirement": "D-PERF-03", "status": "NATIVE_COMPONENT_PARTIAL_REQUIRES_SIGNPOST_CAPTURE",
            "sourceEquivalentBase": Self.sourceEquivalentBase,
            "historyBodyUTF16": scale, "historyMessages": originalMessageCount,
            "corpus": corpus.provenance,
            "originalMessageIDs": originalMessageIDs.map(\.uuidString),
            "closedHistoryMessageIDs": closedHistoryMessageIDs.map(\.uuidString),
            "formatterFullHistoryBoundaryUTF16": historyBoundary,
            "nativeClosedHistoryBoundaryUTF16": closedHistoryBoundary,
            "initialFormatterVsNativeStageDifference": initialStageDifference,
            "historyOracleChecks": historyChecks,
            "positiveControlFormatterDifference": controlFormatterDifference,
            "positiveControlNativeDifference": controlNativeDifference,
            "activeTailMessageID": activeTailID.uuidString,
            "samplesPerOperation": Self.samplesPerOperation,
            "quantileMethod": "nearest-rank ceil(0.95*N)-1; N=40 index=37; max index=39",
            "summaries": summaries, "beforeLoad": beforeLoad, "afterLoad": load(),
            "beforeNativeApp": beforeNativeApp, "afterNativeApp": afterNativeApp,
            "productionSignpostEnabled": TranscriptPerformanceSignposts.signposter.isEnabled,
            "exactParseRedactLayoutCounts": "EXTERNAL_CAPTURE_REQUIRED_NOT_INFERRED",
            "actualUIKeyboardOrProviderStream": "NOT_OBSERVED",
            "framePacing": "NOT_OBSERVED", "latencySLA": "NO_CONTRACT_THRESHOLD_GIVEN",
            "streamSetup": try JSONSerialization.jsonObject(with: JSONEncoder().encode(streamSetup)),
            "positiveControl": try JSONSerialization.jsonObject(with: JSONEncoder().encode(control))]
        try JSONSerialization.data(withJSONObject: artifact, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("summary.json"), options: .atomic)
        print("PERF03_ARTIFACT root=\(root.path) samples=\(samples.count) sizesUnit=history-body-utf16 exactCounts=EXTERNAL_CAPTURE_REQUIRED actualUI=NOT_OBSERVED")
    }

    /// The original N40 method above is the only driver and is byte-preserved.
    /// Counter-ON original timing artifacts remain raw controls, never OFF P95.
    private func replayOriginalN40Population(
        scale: Int, counterOn: Bool, anchorSupplement: Bool = false
    ) async throws -> Perf03N40PopulationTrace {
        try #require(TranscriptOperationDiagnostics.enabled)
        #expect(TranscriptOperationDiagnostics.observer == nil)
        #expect(Perf03N40PopulationContext.trace == nil)
        let recorder = counterOn ? Perf03DiagnosticObserverRecorder() : nil
        let trace = Perf03N40PopulationTrace(recorder: recorder, anchorSupplement: anchorSupplement)
        let callback: (@Sendable (TranscriptOperationDiagnostics.OperationEvent) -> Void)?
        if let recorder { callback = { recorder.append($0) } }
        else { callback = nil }
        try await TranscriptOperationDiagnostics.$observer.withValue(callback) { @MainActor () async throws -> Void in
            try await Perf03N40PopulationContext.$trace.withValue(trace) { @MainActor () async throws -> Void in
                try draftAppendAndStreamingTokenRetainHistory(scale: scale)
            }
        }
        #expect(TranscriptOperationDiagnostics.observer == nil)
        #expect(Perf03N40PopulationContext.trace == nil)
        let formal = try #require(ProcessInfo.processInfo.environment["MINISCANVAS_TEST_DIRECTORY"])
        let mode = anchorSupplement ? "anchor-supplement" : (counterOn ? "counter-on" : "counter-off")
        let root = URL(fileURLWithPath: formal, isDirectory: true)
            .appendingPathComponent("perf03-exact-n40-\(mode)-\(scale)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let corpus = try approvedCorpus(scale: scale, secret: "owned-PERF03-secret")
        try trace.write(to: root, scale: scale, corpus: corpus.provenance)
        return trace
    }

    /// OFF retains the original timing body and adds identity metadata after its timer.
    /// Replay this selector at least three times per scale in distinct real runs.
    @Test(arguments: [50_000, 100_000, 150_000])
    func sameN40PopulationCounterOffP95(scale: Int) async throws {
        _ = try await replayOriginalN40Population(scale: scale, counterOn: false)
    }

    /// ON uses precisely that driver, not 40 times a one-operation proxy.
    /// A fresh second complete replay carries the independent anchor supplement.
    @Test(arguments: [50_000, 100_000, 150_000])
    func sameN40PopulationCountsRealProducers(scale: Int) async throws {
        let primary = try await replayOriginalN40Population(scale: scale, counterOn: true)
        let anchorSupplement = try await replayOriginalN40Population(
            scale: scale, counterOn: true, anchorSupplement: true)
        let populationMatches = primary.populationIdentity == anchorSupplement.populationIdentity
        #expect(populationMatches, "fresh anchor carrier must preserve the exact content population")
        let primaryFile = try #require(primary.artifactURL)
        let anchorFile = try #require(anchorSupplement.artifactURL)
        let pair: [String: Any] = ["scaleUTF16": scale, "primaryArtifact": primaryFile.path,
            "anchorSupplementArtifact": anchorFile.path, "contentPopulationMatches": populationMatches,
            "primaryPopulationSHA256": primary.populationSHA256,
            "anchorCarrierPopulationSHA256": anchorSupplement.populationSHA256,
            "P95": "FORBIDDEN_COUNTER_ON_OVERHEAD",
            "originalTimingArtifactLink": "match every actual sampleID to the original PERF03_RAW_SAMPLE and raw-samples.json; no pathname inference",
            "UUIDs": "original random initialization; actual IDs differ and are recorded"]
        try JSONSerialization.data(withJSONObject: pair, options: [.prettyPrinted, .sortedKeys])
            .write(to: primaryFile.deletingLastPathComponent().appendingPathComponent("n40-replay-pair.json"))
    }

    /// Small real producer chain for the diagnostic-off / nil-observer negatives.
    private func tinyDiagnosticProducerChain() throws {
        let cache = ChatTranscriptDocumentCache()
        let document = cache.render(sessionID: UUID(),
            messages: [ChatMessageUI(role: .user, content: "**合成观察对照**")],
            baseSize: 13, redactor: ChatTranscriptRedactor(secretValues: []))
        let coordinator = ReadOnlyAttributedTextView.Coordinator()
        let view = ReadOnlyAttributedTextView(transcriptDocument: document, update: cache.update)
        let host = view.makeNSView(coordinator: coordinator)
        defer { ReadOnlyAttributedTextView.dismantleNSView(host, coordinator: coordinator) }
        let candidate = view.sizeThatFits(ProposedViewSize(width: 600, height: nil), nsView: host, coordinator: coordinator)
        let size = try #require(candidate)
        #expect(size.height > 0)
        #expect(cache.messageOffsets(contentWidth: 600).count == 1)
    }

    @Test
    func unmarkedInlineOffsetsAvoidLayoutWhileMarkerRevisionsRetainGeometry() async throws {
        try #require(TranscriptOperationDiagnostics.enabled)
        let session = UUID()
        let cache = ChatTranscriptDocumentCache()
        var message = ChatMessageUI(role: .assistant, content: "前文合成正文。后文保持可选。")
        let following = ChatMessageUI(role: .user, content: "下一条合成消息")
        let redactor = ChatTranscriptRedactor(secretValues: [])
        let markerID = message.id.uuidString + ":7"
        let noMarker = Perf03DiagnosticObserverRecorder()
        await TranscriptOperationDiagnostics.$observer.withValue({ noMarker.append($0) }) { @MainActor () async -> Void in
            _ = cache.render(sessionID: session, messages: [message, following], baseSize: 13, redactor: redactor)
            #expect(cache.inlineToolMarkerIDs().isEmpty)
            #expect(cache.inlineToolOffsets(contentWidth: 360).isEmpty)
        }
        let noMarkerAnchorLayouts = Perf03DiagnosticObserverRecorder.records(noMarker.snapshot()).filter {
            $0["operation"] == "layout" && $0["host"] == "anchor"
        }.count
        #expect(noMarkerAnchorLayouts == 0)
        let marked = Perf03DiagnosticObserverRecorder()
        var firstOffsets: [String: CGFloat] = [:]
        var firstMessageOffsets: [CGFloat] = []
        await TranscriptOperationDiagnostics.$observer.withValue({ marked.append($0) }) { @MainActor () async -> Void in
            _ = cache.render(sessionID: session, messages: [message, following], baseSize: 13, redactor: redactor,
                inlineTools: [message.id: [ChatInlineToolGap(id: markerID, sourceUTF16Offset: 7, height: 30)]])
            #expect(cache.inlineToolMarkerIDs() == [markerID])
            firstOffsets = cache.inlineToolOffsets(contentWidth: 360)
            let count = marked.snapshot().count
            #expect(cache.inlineToolOffsets(contentWidth: 360) == firstOffsets)
            #expect(marked.snapshot().count == count)
            firstMessageOffsets = cache.messageOffsets(contentWidth: 360)
        }
        #expect(Perf03DiagnosticObserverRecorder.records(marked.snapshot()).contains {
            $0["operation"] == "layout" && $0["host"] == "anchor"
        })
        let firstY = try #require(firstOffsets[markerID])
        try #require(firstMessageOffsets.count == 2)
        #expect(firstY.isFinite && firstY >= firstMessageOffsets[0] && firstY < firstMessageOffsets[1])
        let removed = Perf03DiagnosticObserverRecorder()
        await TranscriptOperationDiagnostics.$observer.withValue({ removed.append($0) }) { @MainActor () async -> Void in
            message.content += "流式追加正文。"
            _ = cache.render(sessionID: session, messages: [message, following], baseSize: 13, redactor: redactor)
            #expect(cache.inlineToolMarkerIDs().isEmpty)
            #expect(cache.inlineToolOffsets(contentWidth: 360).isEmpty)
        }
        let removedMarkerAnchorLayouts = Perf03DiagnosticObserverRecorder.records(removed.snapshot()).filter {
            $0["operation"] == "layout" && $0["host"] == "anchor"
        }.count
        #expect(removedMarkerAnchorLayouts == 0)
        _ = cache.render(sessionID: session, messages: [message, following], baseSize: 13, redactor: redactor,
            inlineTools: [message.id: [ChatInlineToolGap(id: markerID, sourceUTF16Offset: 7, height: 90)]])
        let restored = cache.inlineToolOffsets(contentWidth: 360)
        #expect(restored.keys.sorted() == [markerID])
        #expect(restored[markerID] == firstY)
        let expandedPositions = cache.messageOffsets(contentWidth: 360)
        try #require(expandedPositions.count == 2)
        #expect(expandedPositions[1] > firstMessageOffsets[1])
    }

    @Test
    func diagnosticFlagOffDoesNotObserveRealProducers() async throws {
        // B0003: the original OFF assertions below run once in the isolated worker.
        if ProcessInfo.processInfo.environment["MINISCANVAS_PERF03_OFF_WORKER"] != "1",
           TranscriptOperationDiagnostics.enabled {
            try await Perf03OffIsolatedWorker.run()
            return
        }
        try #require(!TranscriptOperationDiagnostics.enabled,
            "run this selector in a fresh v42 process WITHOUT the diagnostic flag")
        #expect(TranscriptOperationDiagnostics.observer == nil)
        let recorder = Perf03DiagnosticObserverRecorder()
        try await TranscriptOperationDiagnostics.$observer.withValue({ recorder.append($0) }) { @MainActor () async throws -> Void in
            try tinyDiagnosticProducerChain()
        }
        #expect(recorder.snapshot().isEmpty)
        #expect(TranscriptOperationDiagnostics.observer == nil)
    }

    @Test
    func nilObserverDoesNotRetainDiagnosticEvents() async throws {
        try #require(TranscriptOperationDiagnostics.enabled)
        #expect(TranscriptOperationDiagnostics.observer == nil)
        let recorder = Perf03DiagnosticObserverRecorder()
        try await TranscriptOperationDiagnostics.$observer.withValue({ recorder.append($0) }) { @MainActor () async throws -> Void in
            try await TranscriptOperationDiagnostics.$observer.withValue(nil) { @MainActor () async throws -> Void in
                try tinyDiagnosticProducerChain()
            }
        }
        #expect(recorder.snapshot().isEmpty)
        #expect(TranscriptOperationDiagnostics.observer == nil)
    }

    @MainActor private final class ObserverMainActorState {
        let cache = ChatTranscriptDocumentCache()
        let coordinator = ReadOnlyAttributedTextView.Coordinator()
    }

    /// New Source candidate: one synchronous capture per actual operation, no P95 replay.
    @Test(arguments: [50_000, 100_000, 150_000])
    func scopedObserverCountsRealProducersAndPreservesHistory(scale: Int) async throws {
        try #require(TranscriptOperationDiagnostics.enabled)
        #expect(TranscriptOperationDiagnostics.observer == nil)
        let formal = try #require(ProcessInfo.processInfo.environment["MINISCANVAS_TEST_DIRECTORY"])
        let root = URL(fileURLWithPath: formal, isDirectory: true)
            .appendingPathComponent("perf03-observer-\(scale)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let corpus = try approvedCorpus(scale: scale, secret: "owned-observer-fixture")
        var messages = corpus.messages
        let originalIDs = messages.map(\.id)
        let state = ObserverMainActorState()
        let session = UUID()
        let redactor = ChatTranscriptRedactor(secretValues: ["owned-observer-fixture"])
        let proposal = ProposedViewSize(width: 600, height: nil)
        var host: NSScrollView?
        defer {
            if let host { ReadOnlyAttributedTextView.dismantleNSView(host, coordinator: state.coordinator) }
        }
        let nativeBefore = nativeAppState()
        var phases: [[String: Any]] = []
        let capture: @MainActor (String, @MainActor () -> Void) async throws -> [[String: String]] = { phase, mutation in
            let recorder = Perf03DiagnosticObserverRecorder()
            let before = state.cache.update.revision
            try await TranscriptOperationDiagnostics.$observer.withValue({ recorder.append($0) }) { @MainActor () async throws -> Void in
                mutation()
                let document = state.cache.render(sessionID: session, messages: messages,
                    baseSize: 13, redactor: redactor)
                let view = ReadOnlyAttributedTextView(transcriptDocument: document, update: state.cache.update)
                if let existingHost = host { view.updateNSView(existingHost, coordinator: state.coordinator) }
                else { host = view.makeNSView(coordinator: state.coordinator) }
                // Separate macro expressions: nested #require caused the prior actual typecheck RED.
                let measuredHost = try #require(host)
                let candidate = view.sizeThatFits(proposal, nsView: measuredHost, coordinator: state.coordinator)
                let size = try #require(candidate)
                #expect(size.height > 0)
                let offsets = state.cache.messageOffsets(contentWidth: 600)
                #expect(offsets.count == messages.count)
            }
            let scope = try #require(state.cache.update.diagnosticScope)
            let events = recorder.snapshot()
            #expect(events.allSatisfy { $0.scope.id == scope.id && $0.scope.revision == state.cache.update.revision })
            #expect(TranscriptOperationDiagnostics.observer == nil)
            let records = Perf03DiagnosticObserverRecorder.records(events).map { record in
                var tagged = record
                tagged["workloadStage"] = record["operation"] == "layout" && record["host"] == "anchor"
                    ? "anchor-supplement" : "primary-native"
                return tagged
            }
            let counts = Dictionary(grouping: records, by: { $0["operation"] ?? "UNKNOWN" }).mapValues(\.count)
            let primaryEvents = records.filter { $0["workloadStage"] == "primary-native" }
            let anchorEvents = records.filter { $0["workloadStage"] == "anchor-supplement" }
            let row: [String: Any] = ["phase": phase, "scope": scope.id,
                "revisionBefore": before, "revisionAfter": state.cache.update.revision,
                "formattedMessagesOracleNotCalls": state.cache.lastFormattedMessageCount,
                "parseCalls": counts["parse", default: 0], "redactCalls": counts["redact", default: 0],
                "explicitLayoutRequests": primaryEvents.filter { $0["operation"] == "layout" }.count,
                "combinedExplicitLayoutRequests": counts["layout", default: 0],
                "anchorSupplementalLayoutRequests": anchorEvents.count,
                "primaryStageEvents": primaryEvents, "anchorSupplementalEvents": anchorEvents, "events": records,
                "productionOperationInvocations": 1, "manualMarkersOrSyntheticCallEvents": 0]
            phases.append(row)
            print("PERF03_OBSERVER_PHASE \(String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))")
            return records
        }
        let initialCalls = try await capture("initial-history") {}
        // Real initial producer positivity, not calibration methods invoked by Tests.
        #expect(["parse", "redact", "layout"].allSatisfy { operation in initialCalls.contains { $0["operation"] == operation } })
        #expect(initialCalls.contains { $0["operation"] == "parse" && $0["parser"] == "assessment-inline" },
            "actual assessment AttributedString(markdown:) calls must be observed")
        let initialAnchorCalls = initialCalls.filter { $0["operation"] == "layout" && $0["host"] == "anchor" }
        #expect(!initialAnchorCalls.isEmpty)
        #expect(initialAnchorCalls.allSatisfy { $0["mode"] == "suffix" && $0["lengthUTF16"] == "1" })
        let historyLength = state.cache.document.attributedString.length
        let closedBoundary = state.cache.document.messageStartLocations[messages.count - 1]
        let fullHistoryRange = NSRange(location: 0, length: historyLength)
        let closedHistoryRange = NSRange(location: 0, length: closedBoundary)
        let frozenFormatter = NSAttributedString(attributedString: state.cache.document.attributedString)
        let measuredHost = try #require(host)
        let text = try #require(measuredHost.documentView as? NSTextView)
        let frozenNative = NSAttributedString(attributedString: text.attributedString().attributedSubstring(from: closedHistoryRange))
        let generation = state.cache.update.generation
        @MainActor func unchangedHistory() {
            #expect(Array(messages.prefix(originalIDs.count).map(\.id)) == originalIDs)
            let formatterPrefix = state.cache.document.attributedString.attributedSubstring(from: fullHistoryRange)
            let nativePrefix = text.attributedString().attributedSubstring(from: closedHistoryRange)
            let formatterUnchanged = formatterPrefix.isEqual(to: frozenFormatter)
            let nativeUnchanged = nativePrefix.isEqual(to: frozenNative)
            let formatterDifference = attributeDifference(formatterPrefix, frozenFormatter)
            let nativeDifference = attributeDifference(nativePrefix, frozenNative)
            #expect(formatterUnchanged, "formatter history changed: \(formatterDifference)")
            #expect(nativeUnchanged, "post-layout closed history changed: \(nativeDifference)")
            #expect(state.cache.update.generation == generation)
        }
        let chat = ChatStore() // no persistence or Provider
        let draft = try await capture("draft") { chat.draftText += "输" }
        #expect(draft.isEmpty, "same history/width refresh must invoke no instrumented producer")
        #expect(state.cache.lastFormattedMessageCount == 0)
        unchangedHistory()
        let appended = try await capture("new-message") {
            messages.append(ChatMessageUI(role: .user, content: "合成新消息"))
            messages.append(ChatMessageUI(role: .assistant, content: "合成新回复"))
        }
        #expect(state.cache.lastFormattedMessageCount == 2)
        #expect(["parse", "redact", "layout"].allSatisfy { operation in appended.contains { $0["operation"] == operation } })
        #expect(appended.filter { $0["parser"] == "assessment-inline" }.count == 2,
            "the two real one-paragraph new messages each perform one assessment parse")
        #expect(appended.filter { $0["operation"] == "parse" }.count < initialCalls.filter { $0["operation"] == "parse" }.count)
        #expect(appended.filter { $0["operation"] == "redact" }.count < initialCalls.filter { $0["operation"] == "redact" }.count)
        #expect(appended.filter { $0["operation"] == "layout" }.allSatisfy { (Int($0["startUTF16"] ?? "-1") ?? -1) >= historyLength })
        unchangedHistory()
        let setup = try await capture("stream-setup") { messages.append(ChatMessageUI(role: .assistant, content: "", isStreaming: true)) }
        #expect(!setup.contains { $0["parser"] == "assessment-inline" },
            "empty streaming placeholder does not call Markdown assessment")
        let tailID = try #require(messages.last?.id)
        let stream = try await capture("stream-character") { messages[messages.count - 1].content += corpus.deltaCharacters[0] }
        #expect(state.cache.lastFormattedMessageCount == 1)
        #expect(["parse", "redact", "layout"].allSatisfy { operation in stream.contains { $0["operation"] == operation } })
        #expect(stream.filter { $0["parser"] == "assessment-inline" }.count == 1,
            "the one-character real tail performs one assessment parse")
        #expect(stream.filter { $0["operation"] == "parse" }.count < initialCalls.filter { $0["operation"] == "parse" }.count)
        #expect(stream.filter { $0["operation"] == "redact" }.count < initialCalls.filter { $0["operation"] == "redact" }.count)
        #expect(stream.filter { $0["operation"] == "layout" }.allSatisfy { (Int($0["startUTF16"] ?? "-1") ?? -1) >= historyLength })
        unchangedHistory()
        #expect(messages.last?.id == tailID)
        #expect(text.string == state.cache.document.attributedString.string)
        let tailStart = try #require(state.cache.document.messageStartLocations.last)
        let activeSource = state.cache.document.attributedString.attributedSubstring(from: NSRange(location: tailStart, length: state.cache.document.attributedString.length - tailStart))
        let paragraph = try #require(activeSource.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        let block = try #require(paragraph.textBlocks.first)
        let tail = try #require(messages.last)
        let expectedTail = ChatTranscriptFormatter.formattedMessage(tail, baseSize: 13, redactor: redactor, block: block)
        #expect(activeSource.isEqual(to: expectedTail))
        let control = try await capture("historical-edit-control") { messages[0].content += " changed-history-control" }
        #expect(state.cache.lastFormattedMessageCount == messages.count)
        #expect(state.cache.update.generation == generation + 1)
        #expect(["parse", "redact", "layout"].allSatisfy { operation in control.contains { $0["operation"] == operation } })
        #expect(control.filter { $0["parser"] == "assessment-inline" }.count > appended.filter { $0["parser"] == "assessment-inline" }.count,
            "the actual historical-edit rebuild is an assessment-positive control")
        #expect(control.contains { $0["operation"] == "layout" && $0["startUTF16"] == "0" })
        #expect(!state.cache.document.attributedString.attributedSubstring(from: fullHistoryRange).isEqual(to: frozenFormatter))
        #expect(!text.attributedString().attributedSubstring(from: closedHistoryRange).isEqual(to: frozenNative))
        let nativeAfter = nativeAppState()
        #expect(nativeBefore["visibleWindows"] == nativeAfter["visibleWindows"])
        var observerCorpus = corpus.provenance
        observerCorpus["modelTokens"] = "NOT_MEASURED; counts replay uses one approved character delta, not N40"
        let artifact: [String: Any] = ["requirement": "D-PERF-03", "status": "SYNCHRONOUS_PRODUCER_COUNTER_OBSERVED",
            "scaleUTF16": scale, "corpus": observerCorpus, "phases": phases,
            "producerBoundary": "existing parser/redactor/explicit ensureLayout call-site diagnostics",
            "parseCoverage": "block parse, assessment-inline parse and render-inline parse API attempts; not parser internals",
            "primaryStage": "cache.render -> native make/update -> sizeThatFits; same primitives as N40 observe",
            "anchorGeometryConsumer": "actual ChatTranscriptDocumentCache.messageOffsets; same method used by ChatSidebarView:2322",
            "anchorWorkloadBoundary": "SEPARATE_SUPPLEMENT; no anchor cost in N40 primary P95",
            "workloadIdentity": "one pair and one delta vs N40 cumulative 40 updates; same primitive stage, not same sample or total-call population",
            "losslessWithinScopedSynchronousObserver": true, "callbackStorageOwner": "Tests recorder only",
            "TextKitInternalAutomaticCallbacks": "NOT_OBSERVED", "P95": "NOT_MEASURED_BY_COUNTS; separate same-binary N40 replay required after Source change",
            "originalHistoryMessageIDs": originalIDs.map(\.uuidString), "nativeClosedHistoryBoundaryUTF16": closedBoundary,
            "beforeNativeApp": nativeBefore, "afterNativeApp": nativeAfter,
            "actualUIKeyboardProviderOrPresentedFrame": "NOT_OBSERVED"]
        try JSONSerialization.data(withJSONObject: artifact, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("producer-counts.json"))
        print("PERF03_OBSERVER_ARTIFACT root=\(root.path) scaleUTF16=\(scale) phases=6 P95=NOT_RESAMPLED")
    }

}

// B0003 Tests-only transport. No additional test method or production switch.
@MainActor
private enum Perf03OffIsolatedWorker {
    private struct Failure: Error { let reason: String }

    static func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        let arguments = CommandLine.arguments
        func argument(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard let bundle = argument("--test-bundle-path") ?? environment["MINISCANVAS_PERF03_TEST_BUNDLE_PATH"],
              let formalRoot = environment["MINISCANVAS_TEST_DIRECTORY"] else {
            throw Failure(reason: "OFF worker requires the actual same-DSO path and isolated formal root")
        }
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: formalRoot, isDirectory: true)
            .appendingPathComponent("perf03-off-" + UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false,
                                       attributes: [.posixPermissions: 0o700])
        let helper = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Perf03OffWorkerSupport.py")
        // The compiled test bundle is supplied by the current SDK/native entry.
        // The same-DSO path and the original OFF selector cross into a fresh
        // process; no archived source matcher or executable hash pins are used.
        let request: [String: String] = ["bundle": bundle, "root": root.path]
        let requestURL = root.appendingPathComponent("request.json")
        try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]).write(to: requestURL, options: .withoutOverwriting)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: requestURL.path)
        let output = root.appendingPathComponent("python.stdout.raw")
        let errors = root.appendingPathComponent("python.stderr.raw")
        guard fileManager.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              fileManager.createFile(atPath: errors.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw Failure(reason: "B0003 unique parent output files required")
        }
        let stdout = try FileHandle(forWritingTo: output)
        let stderr = try FileHandle(forWritingTo: errors)
        defer { try? stdout.close(); try? stderr.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-B", helper.path, "--request", requestURL.path]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8", "HOME": root.path, "TMPDIR": root.path,
            "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { actual in continuation.resume(returning: actual.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        // Keep the real child exit and raw output; no legacy custody receipt
        // is needed to accept the ordinary Swift Testing result.
        try stdout.close()
        try stderr.close()
        guard status == 0,
              let result = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("result.json"))) as? [String: Any],
              result["passed"] as? Bool == true else {
            throw Failure(reason: "B0003 isolated OFF worker failed; retain separate evidence at " + root.path)
        }
    }
}
