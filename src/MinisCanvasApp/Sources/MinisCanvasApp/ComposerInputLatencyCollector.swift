/// Opaque, process-local IDs for pairing a native key dispatch with the
/// synchronous draft commit it caused. No text, key code, session identity, or
/// trace is retained. A callback without a synchronous key dispatch keeps a
/// nil key ID (paste, programmatic insertion, or deferred IME commit).
@MainActor
final class ComposerInputLatencyCollector {
    struct PhysicalKeyScope {
        let id: UInt64
        fileprivate let previousID: UInt64?
    }

    struct Commit {
        let eventID: UInt64
        let physicalKeyID: UInt64?
    }

    private static var nextID: UInt64 = 0
    private var activePhysicalKeyID: UInt64?

    private static func allocateID() -> UInt64 {
        nextID &+= 1
        if nextID == 0 { nextID = 1 }
        return nextID
    }

    func beginPhysicalKey() -> PhysicalKeyScope {
        let scope = PhysicalKeyScope(id: Self.allocateID(), previousID: activePhysicalKeyID)
        activePhysicalKeyID = scope.id
        return scope
    }

    func endPhysicalKey(_ scope: PhysicalKeyScope) {
        // Restore the outer dispatch if AppKit reenters keyDown synchronously.
        if activePhysicalKeyID == scope.id {
            activePhysicalKeyID = scope.previousID
        }
    }

    func nextCommit() -> Commit {
        Commit(eventID: Self.allocateID(), physicalKeyID: activePhysicalKeyID)
    }
}
