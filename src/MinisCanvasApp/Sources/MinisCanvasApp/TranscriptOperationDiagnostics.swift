import Foundation
import os

/// Opt-in D-PERF-03/04 call-site observations. A scope is generated for one
/// document render and carried by its update to the native text consumer.
/// Signposts contain only opaque identity, revision and UTF-16 lengths/ranges.
enum TranscriptOperationDiagnostics {
    struct Scope: Sendable {
        let id: String
        let revision: UInt64
    }

    @TaskLocal static var scope: Scope?

    /// Synchronous, opt-in observation of these exact producer call sites.
    /// No observer or retained event storage exists in the default path.
    struct OperationEvent: Sendable {
        enum Operation: Sendable {
            case parse(kind: String)
            case redact(mode: String)
            case layout(host: String, mode: String, start: Int, length: Int, documentLength: Int)
        }
        let scope: Scope
        let operation: Operation
    }
    @TaskLocal static var observer: (@Sendable (OperationEvent) -> Void)?

    private static func observe(scope: Scope, operation: @autoclosure () -> OperationEvent.Operation) {
        guard enabled, let observer else { return }
        observer(OperationEvent(scope: scope, operation: operation()))
    }

    #if DEBUG
    static let enabled = ProcessInfo.processInfo.environment[
        "MINISCANVAS_TRANSCRIPT_OPERATION_DIAGNOSTICS"
    ] == "1"
    #else
    static let enabled = false
    #endif

    static func nextScope(revision: UInt64) -> Scope? {
        enabled ? Scope(id: UUID().uuidString, revision: revision) : nil
    }

    static func parserCall(kind: String, observerOnly: Bool = false) {
        guard let scope else { return }
        if observerOnly {
            guard enabled, observer != nil else { return }
        }
        observe(scope: scope, operation: .parse(kind: kind))
        TranscriptPerformanceSignposts.signposter.emitEvent(
            "TranscriptParseCall",
            "scope=\(scope.id, privacy: .public) revision=\(scope.revision, privacy: .public) parser=\(kind, privacy: .public)"
        )
    }

    static func redactorCall(mode: String) {
        guard let scope else { return }
        observe(scope: scope, operation: .redact(mode: mode))
        TranscriptPerformanceSignposts.signposter.emitEvent(
            "TranscriptRedactCall",
            "scope=\(scope.id, privacy: .public) revision=\(scope.revision, privacy: .public) mode=\(mode, privacy: .public)"
        )
    }

    static func textStorageEdit(
        scope: Scope?, host: String, mode: String, start: Int, removed: Int,
        inserted: Int, oldLength: Int
    ) {
        guard let scope else { return }
        let newLength = oldLength - removed + inserted
        TranscriptPerformanceSignposts.signposter.emitEvent(
            "TranscriptTextStorageEdit",
            "scope=\(scope.id, privacy: .public) revision=\(scope.revision, privacy: .public) host=\(host, privacy: .public) mode=\(mode, privacy: .public) startUTF16=\(start, privacy: .public) removedUTF16=\(removed, privacy: .public) insertedUTF16=\(inserted, privacy: .public) oldUTF16=\(oldLength, privacy: .public) newUTF16=\(newLength, privacy: .public)"
        )
    }

    static func layoutRequest(
        scope: Scope?, host: String, mode: String, start: Int, length: Int,
        documentLength: Int
    ) {
        guard let scope else { return }
        observe(scope: scope, operation: .layout(host: host, mode: mode, start: start,
            length: length, documentLength: documentLength))
        TranscriptPerformanceSignposts.signposter.emitEvent(
            "TranscriptTextKitLayoutRequest",
            "scope=\(scope.id, privacy: .public) revision=\(scope.revision, privacy: .public) host=\(host, privacy: .public) mode=\(mode, privacy: .public) startUTF16=\(start, privacy: .public) lengthUTF16=\(length, privacy: .public) documentUTF16=\(documentLength, privacy: .public)"
        )
    }
}
