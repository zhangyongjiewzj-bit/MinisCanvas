import Foundation
import MinisCore

/// One orchestration round: metadata is credential-free; only selected providers
/// enter this cache, shared by capability checks and the actual dispatch.
final class ChildModelProviderCache: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [String: Task<LLMProviderBox, Error>] = [:]
    private var providers: [String: LLMProviderBox] = [:]

    func provider(for id: String) -> LLMProviderBox? { lock.withLock { providers[id] } }
    func store(_ provider: LLMProviderBox, for id: String) { lock.withLock { providers[id] = provider } }

    func prepare(id: String, construct: @escaping @Sendable () async throws -> LLMProviderBox) async throws {
        try Task.checkCancellation()
        let task = lock.withLock {
            if let existing = tasks[id] { return existing }
            let task = Task { try await construct() }
            tasks[id] = task
            return task
        }
        let provider = try await task.value
        try Task.checkCancellation()
        store(provider, for: id)
    }
}

struct ChildModelRuntimeBinding: Sendable {
    let policy: ChildModelBindingPolicy
    var parentBinding: ParentContextSnapshotV1? = nil
    let cache = ChildModelProviderCache()
    let construct: @Sendable (String) async throws -> LLMProviderBox

    private func match(_ task: SubAgentTask) throws -> ReadyChildModel {
        guard let match = policy.readyModels.first(where: {
            $0.binding.providerID == task.providerID && $0.binding.modelID == task.modelID
                && $0.binding.configurationFingerprint == task.configurationFingerprint
        }) else { throw ChildModelBindingError.notReady(task.modelID ?? "<missing>") }
        return match
    }

    func prepare(_ task: SubAgentTask, inherited: any LLMProvider) async throws {
        let selected = try match(task)
        // A thinking-only change consumes the already admitted parent provider.
        if let parentBinding, task.providerID == parentBinding.providerID,
           task.modelID == parentBinding.modelID, task.configurationFingerprint == parentBinding.configurationFingerprint,
           task.providerID == inherited.name, task.modelID == inherited.model.id {
            cache.store(LLMProviderBox(value: inherited), for: selected.stableID)
            return
        }
        try await cache.prepare(id: selected.stableID) {
            let provider = try await construct(selected.stableID)
            guard provider.value.name == selected.binding.providerID,
                  provider.value.model.id == selected.binding.modelID,
                  providerRuntimeConfigurationFingerprint(provider.value) == selected.binding.configurationFingerprint else {
                throw ChildModelBindingError.notReady(selected.stableID)
            }
            return provider
        }
    }

    func resolve(_ task: SubAgentTask, inherited: any LLMProvider) throws -> any LLMProvider {
        let selected = try match(task)
        guard let provider = cache.provider(for: selected.stableID)?.value else {
            throw ChildModelBindingError.notReady(selected.stableID)
        }
        let inheritedBinding = parentBinding.map {
            $0.providerID == task.providerID && $0.modelID == task.modelID
                && $0.configurationFingerprint == task.configurationFingerprint
        } ?? false
        guard inheritedBinding || providerRuntimeConfigurationFingerprint(provider) == task.configurationFingerprint else {
            throw ChildModelBindingError.notReady(selected.stableID)
        }
        return provider
    }
}
