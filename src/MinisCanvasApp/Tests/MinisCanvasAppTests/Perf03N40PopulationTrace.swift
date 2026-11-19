import AppKit
import CryptoKit
import Foundation
import Testing
@testable import MinisCanvasApp

/// Tests-only context; both scopes use the explicit async overload.
enum Perf03N40PopulationContext {
    @TaskLocal static var trace: Perf03N40PopulationTrace?
}

/// Test-owned boundary recorder. It never emits production operation events.
/// Main replay has no anchor call; the optional fresh replay is supplemental.
@MainActor
final class Perf03N40PopulationTrace {
    let recorder: Perf03DiagnosticObserverRecorder?
    let anchorSupplement: Bool
    private var rows: [[String: Any]] = []
    private var cursor = 0
    private var excluded: [[String: String]] = []
    private var originalHistoryLength = 0
    private(set) var artifactURL: URL?

    init(recorder: Perf03DiagnosticObserverRecorder? = nil, anchorSupplement: Bool = false) {
        self.recorder = recorder
        self.anchorSupplement = anchorSupplement
    }
    var eventCount: Int { recorder?.snapshot().count ?? 0 }
    var counterOn: Bool { recorder != nil }
    var populationIdentity: [String] {
        rows.map { ($0["logicalSampleKey"] as? String ?? "MISSING") + "|" + ($0["inputContentSHA256"] as? String ?? "MISSING") }
    }
    var populationSHA256: String { digest(Data(populationIdentity.joined(separator: "\n").utf8)) }
    private func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    private func counts(_ events: [[String: String]]) -> [String: Int] {
        ["parse": events.filter { $0["operation"] == "parse" }.count,
         "assessment-inline": events.filter { $0["parser"] == "assessment-inline" }.count,
         "redact": events.filter { $0["operation"] == "redact" }.count,
         "explicit-layout": events.filter { $0["operation"] == "layout" }.count]
    }
    private func records(_ events: [Perf03DiagnosticObserverRecorder.Event], offset: Int) -> [[String: String]] {
        Perf03DiagnosticObserverRecorder.records(events).enumerated().map { index, row in
            var value = row
            value["globalOrdinal"] = String(offset + index)
            return value
        }
    }

    /// The untouched original driver completes initial render/make/size before
    /// its first draft step. Draft mutation changes ChatStore text only; it
    /// never mutates the transcript input. Capture that real initial interval.
    func beforeOriginalSample(
        phase: String, index: Int, scale: Int, messages: [ChatMessageUI],
        session: UUID, cache: ChatTranscriptDocumentCache
    ) throws {
        guard rows.isEmpty else { return }
        try #require(phase == "draft" && index == 0)
        try record(phase: "initial-history", index: 0, sampleID: "initial-" + UUID().uuidString,
            scale: scale, messages: messages, session: session, cache: cache,
            revisionBefore: nil, primaryEventStart: 0)
    }

    /// Called after the original measured render/apply/layout sequence ends.
    /// Hashing/JSON and supplemental anchor work never enter its timer interval.
    func record(
        phase: String, index: Int, sampleID: String, scale: Int,
        messages: [ChatMessageUI], session: UUID, cache: ChatTranscriptDocumentCache,
        revisionBefore: UInt64?, primaryEventStart: Int
    ) throws {
        let all = recorder?.snapshot() ?? []
        try #require(primaryEventStart >= cursor && primaryEventStart <= all.count)
        if primaryEventStart > cursor {
            excluded += records(Array(all[cursor..<primaryEventStart]), offset: cursor)
        }
        let events = Array(all[primaryEventStart..<all.count])
        let scope = try #require(cache.update.diagnosticScope)
        let scopeMatches = events.allSatisfy {
            $0.scope.id == scope.id && $0.scope.revision == cache.update.revision
        }
        #expect(scopeMatches, "every callback must belong to the actual current render/update scope")
        let primary = records(events, offset: primaryEventStart)
        // Stable population identity excludes runtime UUIDs/timestamps only;
        // actual IDs are retained separately, never claimed byte-identical.
        let content = messages.enumerated().map { index, message -> [String: Any] in
            ["logicalMessageIndex": index, "role": String(describing: message.role),
             "content": message.content, "isStreaming": message.isStreaming]
        }
        let contentBytes = try JSONSerialization.data(withJSONObject: content, options: [.sortedKeys])
        let inputHash = digest(contentBytes)
        let ids = messages.map { $0.id.uuidString }
        let revisionBeforeRecord: Any = revisionBefore.map { NSNumber(value: $0) as Any } ?? NSNull()
        let instance = try JSONSerialization.data(withJSONObject:
            ["sessionID": session.uuidString, "messageIDs": ids, "contentSHA256": inputHash],
            options: [.sortedKeys])
        if phase == "initial-history" { originalHistoryLength = cache.document.attributedString.length }
        var row: [String: Any] = ["phase": phase, "index": index, "sampleID": sampleID,
            "logicalSampleKey": "N40-v1-\(scale)-\(phase)-\(index)",
            "inputContentSHA256": inputHash, "runtimeInstanceSHA256": digest(instance),
            "runtimeSessionID": session.uuidString, "runtimeMessageIDs": ids,
            "inputMessageCount": messages.count,
            "inputContentUTF16": messages.reduce(0) { $0 + $1.content.utf16.count },
            "historyBodyUTF16": scale, "scope": scope.id,
            "revisionBefore": revisionBeforeRecord, "revisionAfter": cache.update.revision,
            "initialRevisionBefore": "NOT_CAPTURED_BEFORE_UNCHANGED_ORIGINAL_INITIALIZATION",
            "formattedMessagesOracleNotCalls": cache.lastFormattedMessageCount,
            "primaryEvents": primary,
            "primaryCounts": recorder == nil ? NSNull() : counts(primary) as Any,
            "primaryObservation": recorder == nil ? "NOT_OBSERVED_NIL_CALLBACK" : "ACTUAL_SCOPED_CALLBACKS",
            "originalHistoryBoundaryUTF16": originalHistoryLength]
        if counterOn {
            let observed = counts(primary)
            if phase == "initial-history" {
                let producerCalibration = observed["assessment-inline", default: 0] > 0
                    && observed["redact", default: 0] > 0
                    && observed["explicit-layout", default: 0] > 0
                try #require(producerCalibration,
                    "NOT_OBSERVED: initial real assessment/redactor/native producer positivity is missing; absence is not zero")
            } else if phase == "draft" {
                #expect(primary.isEmpty, "the calibrated producer callback must observe no call for this real no-op step")
            } else if phase == "new-message" || phase == "stream-token" {
                let expectedAssessment = phase == "new-message" ? 2 : 1
                #expect(observed["assessment-inline", default: 0] == expectedAssessment)
                #expect(observed["redact", default: 0] > 0)
                let tailRequests = primary.filter { $0["operation"] == "layout" }
                let rangesAreTail = tailRequests.allSatisfy {
                    (Int($0["startUTF16"] ?? "-1") ?? -1) >= originalHistoryLength
                }
                #expect(!tailRequests.isEmpty && rangesAreTail)
            } else if phase == "historical-edit-control" {
                // 消息级与块级缓存之后，历史编辑只重新评估被改动的那一条，不再比追加两条新消息更多；
                // 仍须观察到真实的评估解析，且下面的整段重排保持。
                #expect(observed["assessment-inline", default: 0] >= 1)
                let explicitFull = primary.contains { $0["operation"] == "layout" && $0["startUTF16"] == "0" }
                #expect(explicitFull, "the same producer must detect a real full-history edit")
            }
        }
        cursor = all.count
        if anchorSupplement {
            let anchorStart = eventCount
            let offsets = cache.messageOffsets(contentWidth: 600)
            #expect(offsets.count == messages.count)
            let afterAnchor = recorder?.snapshot() ?? []
            let anchor = records(Array(afterAnchor[anchorStart..<afterAnchor.count]), offset: anchorStart)
            let anchorScopeMatches = afterAnchor[anchorStart..<afterAnchor.count].allSatisfy {
                $0.scope.id == scope.id && $0.scope.revision == cache.update.revision
            }
            let onlyAnchorRequests = anchor.allSatisfy { $0["operation"] == "layout" && $0["host"] == "anchor" }
            #expect(anchorScopeMatches && onlyAnchorRequests)
            row["anchorSupplementEvents"] = anchor
            row["anchorSupplementCounts"] = counts(anchor)
            cursor = afterAnchor.count
        }
        rows.append(row)
    }

    func write(to root: URL, scale: Int, corpus: [String: String]) throws {
        let all = recorder?.snapshot() ?? []
        if all.count > cursor { excluded += records(Array(all[cursor..<all.count]), offset: cursor) }
        var phaseCounts: [String: Any] = [:]
        for phase in ["initial-history", "draft", "new-message", "stream-setup", "stream-token", "historical-edit-control"] {
            let selected = rows.filter { $0["phase"] as? String == phase }
            let expectedSamples = ["draft", "new-message", "stream-token"].contains(phase) ? 40 : 1
            #expect(selected.count == expectedSamples)
            let events = selected.flatMap { $0["primaryEvents"] as? [[String: String]] ?? [] }
            let anchors = selected.flatMap { $0["anchorSupplementEvents"] as? [[String: String]] ?? [] }
            phaseCounts[phase] = ["actualSampleCount": selected.count,
                "countsDerivedFromActualCallbacks": counterOn ? counts(events) as Any : NSNull(),
                "anchorSupplementCounts": anchorSupplement ? counts(anchors) as Any : NSNull(),
                "sampleKeys": selected.compactMap { $0["logicalSampleKey"] as? String }]
        }
        #expect(rows.count == 123, "initial + 3x40 operations + stream setup + historical edit control")
        let ownedCount = rows.reduce(0) { sum, row in
            sum + (row["primaryEvents"] as? [[String: String]] ?? []).count
                + (row["anchorSupplementEvents"] as? [[String: String]] ?? []).count
        }
        #expect(ownedCount + excluded.count == all.count, "no captured event may be dropped or counted twice")
        let primary = rows.flatMap { $0["primaryEvents"] as? [[String: String]] ?? [] }
        let data: [String: Any] = ["requirement": "D-PERF-03", "scaleUTF16": scale,
            "driver": "original-draftAppendAndStreamingTokenRetainHistory-byte-preserved-v1", "counterOn": counterOn,
            "replay": anchorSupplement ? "FRESH_ANCHOR_SUPPLEMENT_NOT_PRIMARY_POPULATION" : "PRIMARY_EXACT_N40_DRIVER",
            "corpus": corpus, "samplesPerPrimaryOperation": 40,
            "populationVectorSHA256": populationSHA256,
            "initializationAndControls": "1 initial, 1 stream setup, 1 historical edit, outside 120 operation samples",
            "UUIDSeed": "ORIGINAL_UNSEEDED_RUNTIME_UUID_INITIALIZATION_PRESERVED; logical content population hash excludes UUID/timestamps",
            "P95Use": counterOn ? "FORBIDDEN_COUNTER_ON_OVERHEAD; original driver summary/raw timings are retained but are not valid OFF P95" : "OFF_PRIMARY_P95_ONLY",
            "anchorChangesCarrierWorkload": anchorSupplement,
            "anchorBoundary": "fresh independent complete driver replay; every anchor call follows its carrier sample; never added to OFF P95 or primary exact counter pass",
            "phaseCounts": phaseCounts, "steps": rows,
            "producerCalibration": counterOn ? "INITIAL_REAL_PRODUCER_POSITIVITY_REQUIRED" : "NOT_OBSERVED_NIL_CALLBACK",
            "primaryTotalCounts": counterOn ? counts(primary) as Any : NSNull(),
            "capturedCallbackCount": counterOn ? all.count as Any : NSNull(),
            "excludedOutsideStepEvents": excluded,
            "parseBoundary": "actual scoped block / assessment-inline / render-inline API attempts; events have scope, not per-message parse ranges",
            "layoutBoundary": "producer explicit native/anchor ensureLayout requests and ranges only",
            "zeroMeaning": "observed callback zero only; no inference of zero internal TextKit work",
            "TextKitInternalAutomaticCalls": "NOT_OBSERVED", "SwiftUIRefreshAndPresentedFrames": "NOT_OBSERVED",
            "actualKeyboardOrProviderTokens": "NOT_OBSERVED", "manualProducerEventEmissions": 0]
        let file = root.appendingPathComponent("n40-population-and-counts.json")
        try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
            .write(to: file, options: .atomic)
        artifactURL = file
        print("PERF03_N40_POPULATION artifact=\(file.path) counterOn=\(counterOn) anchorSupplement=\(anchorSupplement) callbackCount=\(all.count)")
    }
}
