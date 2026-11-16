import Foundation
import OSLog
import Testing
@testable import MinisCanvasApp

/// Reads only this test process and the content-free production category.
/// No global localStore(), xctrace attach, logging configuration or permission changes.
@MainActor
final class Perf03CurrentProcessSignpostCollector {
    struct Event: Codable {
        let timestampUnix: Double
        let processIdentifier: Int32
        let name: String
        let identifier: UInt64
        let fields: [String: String]
    }
    struct Step: Codable {
        let id: String
        let phase: String
        let scope: String
        let revisionBefore: UInt64
        let revisionAfter: UInt64
        let formattedMessagesOracle: Int
    }
    struct Counts: Codable {
        let step: Step
        let parseCalls: Int
        let redactCalls: Int
        let explicitTextKitLayoutRequests: Int
        let parseByKind: [String: Int]
        let redactByMode: [String: Int]
        let layoutByHostAndMode: [String: Int]
        let events: [Event]
    }
    enum ObservationError: Error {
        case notObserved(String)
    }
    private let started = Date()
    private let calibrationID = "CAL-" + UUID().uuidString
    private let boundaryName = "PERF03CountBoundary"
    private let productionNames: Set<String> = [
        "TranscriptParseCall", "TranscriptRedactCall", "TranscriptTextKitLayoutRequest"
    ]
    private let fieldNames: Set<String> = [
        "scope", "revision", "parser", "mode", "host", "startUTF16", "lengthUTF16",
        "documentUTF16", "step", "kind"
    ]

    func begin(_ id: String) {
        TranscriptPerformanceSignposts.signposter.emitEvent(
            "PERF03CountBoundary", "step=\(id, privacy: .public) kind=begin"
        )
    }
    func end(_ id: String) {
        TranscriptPerformanceSignposts.signposter.emitEvent(
            "PERF03CountBoundary", "step=\(id, privacy: .public) kind=end"
        )
    }

    /// Artificial calibration is labelled and excluded from workload counts.
    /// It checks all three producer event formats, not merely test markers.
    func calibrate() async throws -> [Event] {
        guard TranscriptOperationDiagnostics.enabled else {
            throw ObservationError.notObserved("diagnostic environment was not enabled before startup")
        }
        guard TranscriptPerformanceSignposts.signposter.isEnabled else {
            throw ObservationError.notObserved("production signposter disabled")
        }
        let scope = TranscriptOperationDiagnostics.Scope(id: calibrationID, revision: 0)
        begin(calibrationID)
        TranscriptOperationDiagnostics.$scope.withValue(scope) {
            TranscriptOperationDiagnostics.parserCall(kind: "collectorCalibration")
            TranscriptOperationDiagnostics.redactorCall(mode: "collectorCalibration")
        }
        TranscriptOperationDiagnostics.layoutRequest(scope: scope, host: "collectorCalibration",
            mode: "collectorCalibration", start: 0, length: 1, documentLength: 1)
        end(calibrationID)
        let events = try await settledEvents(requiredSteps: [calibrationID])
        let artificial = events.filter { $0.fields["scope"] == calibrationID }
        guard productionNames.allSatisfy({ name in artificial.filter { $0.name == name }.count == 1 }) else {
            throw ObservationError.notObserved("three producer-format calibration events not visible exactly once")
        }
        return artificial
    }

    private func fields(_ message: String) throws -> [String: String] {
        let expression = try NSRegularExpression(pattern: "\\b([A-Za-z][A-Za-z0-9]*)=([A-Za-z0-9-]+)")
        let text = message as NSString
        var fields: [String: String] = [:]
        for match in expression.matches(in: message, range: NSRange(location: 0, length: text.length)) {
            let key = text.substring(with: match.range(at: 1))
            if fieldNames.contains(key) { fields[key] = text.substring(with: match.range(at: 2)) }
        }
        return fields
    }

    private func read() throws -> [Event] {
        // A store is a fixed snapshot; create a new snapshot after each wait.
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let entries = try store.getEntries(at: store.position(date: started), matching:
            NSPredicate(format: "subsystem == %@ AND category == %@",
                "com.miniscanvas.MinisCanvas", "TranscriptPerformance"))
        var events: [Event] = []
        for entry in entries {
            guard let signpost = entry as? OSLogEntrySignpost,
                  signpost.processIdentifier == ProcessInfo.processInfo.processIdentifier,
                  signpost.signpostType == .event,
                  productionNames.contains(signpost.signpostName) || signpost.signpostName == boundaryName
            else { continue }
            guard events.count < 10_000 else {
                throw ObservationError.notObserved("bounded observer capacity exceeded; no partial counts")
            }
            events.append(Event(timestampUnix: signpost.date.timeIntervalSince1970,
                processIdentifier: signpost.processIdentifier, name: signpost.signpostName,
                identifier: signpost.signpostIdentifier, fields: try fields(signpost.composedMessage)))
        }
        return events
    }

    private func settledEvents(requiredSteps: [String]) async throws -> [Event] {
        // Bounded flush observation, not a workload rerun. No permission fallback.
        for _ in 0..<3 {
            try await Task.sleep(for: .milliseconds(250))
            let events = try read()
            if requiredSteps.allSatisfy({ id in
                let markers = events.filter { $0.name == boundaryName && $0.fields["step"] == id }
                return markers.count == 2 && markers.filter { $0.fields["kind"] == "begin" }.count == 1
                    && markers.filter { $0.fields["kind"] == "end" }.count == 1
            }) { return events }
        }
        throw ObservationError.notObserved("own-process signpost boundaries missing; absence is not zero calls")
    }

    func collect(steps: [Step]) async throws -> (counts: [Counts], raw: [Event]) {
        let events = try await settledEvents(requiredSteps: [calibrationID] + steps.map(\.id))
        let calibration = events.filter { $0.fields["scope"] == calibrationID }
        guard productionNames.allSatisfy({ name in calibration.filter { $0.name == name }.count == 1 }) else {
            throw ObservationError.notObserved("calibration expired or incomplete in final snapshot")
        }
        var counts: [Counts] = []
        for step in steps {
            let start = try #require(events.firstIndex { $0.name == boundaryName && $0.fields["step"] == step.id && $0.fields["kind"] == "begin" })
            let end = try #require(events.firstIndex { $0.name == boundaryName && $0.fields["step"] == step.id && $0.fields["kind"] == "end" })
            guard start < end else { throw ObservationError.notObserved("unordered step boundaries") }
            let observed = Array(events[(start + 1)..<end]).filter { productionNames.contains($0.name) }
            guard observed.allSatisfy({ $0.fields["scope"] == step.scope
                && $0.fields["revision"] == String(step.revisionAfter) }) else {
                throw ObservationError.notObserved("cross-step or missing opaque production scope")
            }
            func histogram(_ name: String, dimensions: [String]) -> [String: Int] {
                var result: [String: Int] = [:]
                for event in observed where event.name == name {
                    let key = dimensions.map { event.fields[$0] ?? "UNKNOWN" }.joined(separator: "/")
                    result[key, default: 0] += 1
                }
                return result
            }
            counts.append(Counts(step: step,
                parseCalls: observed.filter { $0.name == "TranscriptParseCall" }.count,
                redactCalls: observed.filter { $0.name == "TranscriptRedactCall" }.count,
                explicitTextKitLayoutRequests: observed.filter { $0.name == "TranscriptTextKitLayoutRequest" }.count,
                parseByKind: histogram("TranscriptParseCall", dimensions: ["parser"]),
                redactByMode: histogram("TranscriptRedactCall", dimensions: ["mode"]),
                layoutByHostAndMode: histogram("TranscriptTextKitLayoutRequest", dimensions: ["host", "mode"]),
                events: observed))
        }
        // Real production positive controls must be visible for every event type.
        let controls = counts.filter { ["initial-history", "historical-edit-control"].contains($0.step.phase) }
        guard controls.count == 2,
            controls.allSatisfy({ $0.parseCalls > 0 && $0.redactCalls > 0 && $0.explicitTextKitLayoutRequests > 0 }) else {
            throw ObservationError.notObserved("real producer positive control missing; no zero inference")
        }
        return (counts, events)
    }
}
