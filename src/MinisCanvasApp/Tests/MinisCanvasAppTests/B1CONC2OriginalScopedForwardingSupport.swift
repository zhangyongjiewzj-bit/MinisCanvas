import Foundation
@testable import MinisCore

final class ScopedForwardingExecutor: ToolCatalogValidatingExecutor,
    BuiltinOwnerBoundToolExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var currentBase: BuiltinToolExecutor
    private var _invokedNames: [String] = []

    init(base: BuiltinToolExecutor) { currentBase = base }

    func rebind(to base: BuiltinToolExecutor) {
        lock.lock()
        currentBase = base
        lock.unlock()
    }

    private var base: BuiltinToolExecutor {
        lock.lock()
        defer { lock.unlock() }
        return currentBase
    }

    var currentBuiltinOwner: BuiltinToolExecutor? { base.currentBuiltinOwner }

    func executeBoundToBuiltinOwner(
        _ owner: BuiltinToolExecutor, name: String, input: [String: Any]
    ) async throws -> String {
        let captured = lock.withLock { () -> BuiltinToolExecutor? in
            guard currentBase === owner else { return nil }
            _invokedNames.append(name)
            return currentBase
        }
        guard let captured else { throw ToolExecutorError.resourceScopeInvalid }
        return try await captured.executeBoundToBuiltinOwner(owner, name: name, input: input)
    }

    var invokedNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _invokedNames
    }

    func validateToolCatalog(_ tools: [AgentToolDefinition]) throws {
        try base.validateToolCatalog(tools)
    }

    func execute(name: String, input: [String: Any]) async throws -> String {
        record(name)
        return try await base.execute(name: name, input: input)
    }

    private func record(_ name: String) {
        lock.lock()
        _invokedNames.append(name)
        lock.unlock()
    }
}
