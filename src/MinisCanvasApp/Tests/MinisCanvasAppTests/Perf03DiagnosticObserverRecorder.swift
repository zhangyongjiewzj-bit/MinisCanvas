import Foundation
@testable import MinisCanvasApp

/// The lock protects the only mutable state; the synchronous callback may run
/// on any executor, so the recorder's Sendable conformance does not rely on MainActor.
final class Perf03DiagnosticObserverRecorder: @unchecked Sendable {
    typealias Event = TranscriptOperationDiagnostics.OperationEvent
    private let lock = NSLock()
    private var recorded: [Event] = []

    func append(_ event: Event) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(event)
    }
    func snapshot() -> [Event] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
    static func records(_ events: [Event]) -> [[String: String]] {
        events.enumerated().map { index, event in
            var row = ["ordinal": String(index), "scope": event.scope.id,
                       "revision": String(event.scope.revision)]
            switch event.operation {
            case let .parse(kind): row["operation"] = "parse"; row["parser"] = kind
            case let .redact(mode): row["operation"] = "redact"; row["mode"] = mode
            case let .layout(host, mode, start, length, documentLength):
                row["operation"] = "layout"; row["host"] = host; row["mode"] = mode
                row["startUTF16"] = String(start); row["lengthUTF16"] = String(length)
                row["documentUTF16"] = String(documentLength)
            }
            return row
        }
    }
}
