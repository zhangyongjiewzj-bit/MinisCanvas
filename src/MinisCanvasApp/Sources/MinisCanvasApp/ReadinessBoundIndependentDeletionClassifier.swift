import Foundation
import MinisCore

/// Separate provider construction, reached only after default-off eligibility
/// and the canonical durable checkpoint checks pass. No parent messages or
/// child output are accepted at this seam.
struct ReadinessBoundIndependentDeletionClassifier: IndependentDeletionClassifying {
    enum Failure: Error { case unavailable }
    private let construction: @MainActor @Sendable (ParentContextSnapshotV1) throws -> ChatStore.FrozenProviderConstruction
    init(construction: @escaping @MainActor @Sendable (ParentContextSnapshotV1) throws -> ChatStore.FrozenProviderConstruction) {
        self.construction = construction
    }
    func classify(_ input: ChildDeletionClassifierInput) async throws -> ChildDeletionModelVerdict {
        try Task.checkCancellation()
        guard let runtime = AgentExecutionContext.current,
              let expected = runtime.childToolRuntimeBinding?.boundary.identity.providerSnapshot ?? runtime.parentBinding,
              !expected.configurationFingerprint.isEmpty else { throw Failure.unavailable }
        let frozen = try await construction(expected)
        try Task.checkCancellation()
        // Transfer the fresh instance before any existential configuration cast.
        // All identity inspection then stays on its owning classifier actor.
        let independent = IndependentDeletionClassifier(provider: try frozen.makeProvider())
        guard await independent.matchesRuntime(expected) else { throw Failure.unavailable }
        return try await independent.classify(input)
    }
}
