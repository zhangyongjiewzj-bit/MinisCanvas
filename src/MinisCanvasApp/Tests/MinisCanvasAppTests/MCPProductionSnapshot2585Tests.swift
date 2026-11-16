import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private final class MCPProductionSnapshotGate2585: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var mainThread = false
    private var expired = false
    private var visits = 0

    var didEnter: Bool { lock.withLock { visits > 0 } }
    var ranOnMain: Bool { lock.withLock { mainThread } }
    var timedOut: Bool { lock.withLock { expired } }

    func pause() {
        lock.withLock {
            mainThread = Thread.isMainThread
            visits += 1
        }
        entered.signal()
        let didExpire = release.wait(timeout: .now() + .milliseconds(600)) == .timedOut
        lock.withLock { expired = didExpire }
    }
}

/// Delegates to the real registry and manager. The gate identifies the
/// executor that crosses the production turn-snapshot boundary.
private final class MCPProductionSnapshotProbe2585:
    MCPToolBridgeTurnSnapshotting, MCPToolBridgeTurnPreparing,
    MCPToolBridgeRuntimeFencing, @unchecked Sendable {
    let registry: MCPToolRegistry
    let gate: MCPProductionSnapshotGate2585
    let failPreparation: Bool

    init(registry: MCPToolRegistry, gate: MCPProductionSnapshotGate2585,
         failPreparation: Bool = false) {
        self.registry = registry
        self.gate = gate
        self.failPreparation = failPreparation
    }

    var runtimeIdentity: MCPToolBridgeRuntimeIdentity? { registry.runtimeIdentity }
    func accepts(_ identity: MCPToolBridgeRuntimeIdentity) -> Bool { registry.accepts(identity) }
    func snapshotForTurn() throws -> any MCPToolBridge {
        gate.pause()
        return try registry.snapshotForTurn()
    }
    func captureTurnSnapshotPreparation() -> @Sendable () throws -> any MCPToolBridge {
        let preparation = registry.captureTurnSnapshotPreparation()
        return { [gate, failPreparation] in
            gate.pause()
            if failPreparation { throw MCPToolBridgeSnapshotError.unsupportedBase }
            return try preparation()
        }
    }
    func mcpBoundTools() async throws -> [MCPBoundTool] { try await registry.mcpBoundTools() }
    func callMCPTool(fullName: String, arguments: [String: Any]?) async throws -> String {
        try await registry.callMCPTool(fullName: fullName, arguments: arguments)
    }
}

@Suite("D-PERF-06 production MCP turn snapshot", .serialized)
@MainActor
struct MCPProductionSnapshot2585Tests {
    private func fixture(label: String, serverCount: Int,
                         failPreparation: Bool = false)
        async throws -> (manager: MCPServerManager, registry: MCPToolRegistry,
                         gate: MCPProductionSnapshotGate2585, bridge: BridgeStore) {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: label, processEnvironment: [:],
            processArguments: ["/tmp/MinisCanvasAppTests.xctest"],
            canvasRuntimeState: .disabled)
        let manager = MCPServerManager(
            fileURL: profile.mcpDirectory.appendingPathComponent("mcps.json"),
            keychain: profile.makeKeychainStore())
        // Real bounded manager inputs, created before the responsiveness gate.
        for index in 0..<serverCount {
            try manager.addServer(MCPServer(
                id: "snapshot-\(index)", name: "Snapshot \(index)",
                type: .http, enabled: false, url: "https://example.invalid/mcp/\(index)"))
        }
        let registry = MCPToolRegistry(manager: manager)
        let gate = MCPProductionSnapshotGate2585()
        let probe = MCPProductionSnapshotProbe2585(
            registry: registry, gate: gate, failPreparation: failPreparation)
        let bridge = BridgeStore(canvasRuntimeState: .disabled)
        await bridge.attachProductionServices(
            fileAccessAllowedRoot: profile.rootDirectory,
            fileAccessDeniedRoots: [], sessionDirectory: profile.sessionDirectory,
            mcpManager: manager, mcpBridgeOverride: probe,
            canvasRuntimeState: .disabled, externalRunners: [:],
            externalNetworkAllowed: false
        ).value
        return (manager, registry, gate, bridge)
    }

    private func turn(_ id: Int) -> AgentTurnIdentity {
        AgentTurnIdentity(sessionID: "mcp-2585", turnID: id,
                          messageID: "assistant-2585-\(id)")
    }

    @Test("large real MCP manager snapshot keeps the production turn factory responsive")
    func productionTurnSnapshotDoesNotBlockMainActor() async throws {
        let f = try await fixture(label: "MCP2585-main", serverCount: 256)
        let gate = f.gate
        DispatchQueue.global(qos: .userInitiated).async {
            guard gate.entered.wait(timeout: .now() + .seconds(5)) == .success else { return }
            Task { @MainActor in gate.release.signal() }
        }
        let factory = try #require(f.bridge.chat.turnRuntimeSnapshotFactory)
        let pending = factory(turn(1), MockProvider.shared)
        // The later configuration belongs to the next turn, even when the
        // worker has not yet validated the captured discovery cache.
        try f.manager.addServer(MCPServer(
            id: "later", name: "Later", type: .http, enabled: false,
            url: "https://example.invalid/mcp/later"))
        defer { f.gate.release.signal() }
        let prepared = try #require(await pending.preparedForExecution())
        let frozen = try #require(prepared.mcpBridge as? MCPToolRegistry)
        #expect(f.manager.listServers().count == 257)
        #expect(frozen.manager.listServers().count == 256)
        #expect(f.gate.didEnter)
        #expect(!f.gate.ranOnMain)
        #expect(!f.gate.timedOut)
    }

    @Test("runtime rebind while the snapshot worker waits rejects the old turn")
    func rebindRejectsPreparedSnapshot() async throws {
        let f = try await fixture(label: "MCP2585-rebind", serverCount: 1)
        let gate = f.gate
        let registry = f.registry
        let factory = try #require(f.bridge.chat.turnRuntimeSnapshotFactory)
        let pending = factory(turn(2), MockProvider.shared)
        let waiting = Task { await pending.preparedForExecution() }
        DispatchQueue.global(qos: .userInitiated).async {
            guard gate.entered.wait(timeout: .now() + .seconds(5)) == .success else { return }
            Task { @MainActor in
                registry.disconnectAll()
                gate.release.signal()
            }
        }
        defer { f.gate.release.signal() }
        let prepared = await waiting.value
        #expect(prepared == nil)
        #expect(f.gate.didEnter)
        #expect(!f.gate.ranOnMain)
        #expect(!f.gate.timedOut)
    }

    @Test("cancelled turn cannot adopt a late MCP snapshot")
    func cancellationRejectsPreparedSnapshot() async throws {
        let f = try await fixture(label: "MCP2585-cancel", serverCount: 1)
        let gate = f.gate
        let factory = try #require(f.bridge.chat.turnRuntimeSnapshotFactory)
        let pending = factory(turn(3), MockProvider.shared)
        let waiting = Task { await pending.preparedForExecution() }
        DispatchQueue.global(qos: .userInitiated).async {
            guard gate.entered.wait(timeout: .now() + .seconds(5)) == .success else { return }
            Task { @MainActor in
                waiting.cancel()
                gate.release.signal()
            }
        }
        defer { f.gate.release.signal() }
        let prepared = await waiting.value
        #expect(prepared == nil)
        #expect(f.gate.didEnter)
        #expect(!f.gate.ranOnMain)
        #expect(!f.gate.timedOut)
    }

    @Test("ordinary optional MCP snapshot failure keeps the chat turn available")
    func optionalSnapshotFailureOmitsMCP() async throws {
        let f = try await fixture(label: "MCP2585-optional", serverCount: 1,
                                  failPreparation: true)
        let gate = f.gate
        DispatchQueue.global(qos: .userInitiated).async {
            guard gate.entered.wait(timeout: .now() + .seconds(5)) == .success else { return }
            Task { @MainActor in gate.release.signal() }
        }
        let factory = try #require(f.bridge.chat.turnRuntimeSnapshotFactory)
        let pending = factory(turn(4), MockProvider.shared)
        defer { gate.release.signal() }
        let prepared = try #require(await pending.preparedForExecution())
        #expect(prepared.mcpBridge == nil)
        #expect(gate.didEnter)
        #expect(!gate.ranOnMain)
        #expect(!gate.timedOut)
    }
}
