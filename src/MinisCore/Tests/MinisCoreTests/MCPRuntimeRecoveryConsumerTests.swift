import Foundation
import Testing
@testable import MinisCore

private actor MCPRecoveryLatch {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var signaled = false

    func wait() async {
        if signaled { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        signaled = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

private final class MCPRecoveryRebindBridge: MCPToolBridge, MCPToolBridgeInvocationFencing, MCPToolBridgeRuntimeFencing, @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    let entered = MCPRecoveryLatch()
    let release = MCPRecoveryLatch()

    var runtimeIdentity: MCPToolBridgeRuntimeIdentity? {
        withLock { MCPToolBridgeRuntimeIdentity(ownerID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, generation: generation) }
    }

    func accepts(_ identity: MCPToolBridgeRuntimeIdentity) -> Bool {
        withLock { identity.ownerID.uuidString == "00000000-0000-0000-0000-000000000001" && identity.generation == generation }
    }

    func retire() {
        withLock { generation &+= 1 }
    }

    func mcpBoundTools() async throws -> [MCPBoundTool] { [] }

    func callMCPTool(fullName: String, arguments: [String: Any]?) async throws -> String {
        try await callMCPTool(fullName: fullName, arguments: arguments, invocation: MCPToolInvocationIdentity(correlationID: "legacy", attemptID: UUID().uuidString))
    }

    func callMCPTool(fullName: String, arguments: [String: Any]?, invocation: MCPToolInvocationIdentity) async throws -> String {
        await entered.signal()
        await release.wait()
        return "late result"
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Direct consumer contracts for MCP runtime recovery.  These are source-only
/// in the current L10 window; execution remains UNVERIFIED/FIELD_PENDING.
struct MCPRuntimeRecoveryConsumerTests {

    @Test func rebindRejectsLateBridgeProjection() async {
        let bridge = MCPRecoveryRebindBridge()
        let runtime = bridge.runtimeIdentity!
        let invocation = MCPToolInvocationIdentity(correlationID: "rebind", attemptID: "attempt-1")
        let pending = Task {
            await bridge.callMCPToolProjection(
                fullName: "mcp_demo_tool",
                arguments: nil,
                identity: invocation
            )
        }

        await bridge.entered.wait()
        bridge.retire()
        await bridge.release.signal()
        let projection = await pending.value

        #expect(!bridge.accepts(runtime))
        #expect(projection.identity == invocation)
        #expect(projection.response.disposition == .invocationRejected)
    }

    @Test func cancelledProjectionRejectsLateFinalChunk() async {
        let bridge = MCPRecoveryRebindBridge()
        let invocation = MCPToolInvocationIdentity(correlationID: "cancel-final", attemptID: "attempt-1")
        let pending = Task {
            await bridge.callMCPToolProjection(
                fullName: "mcp_demo_tool",
                arguments: nil,
                identity: invocation
            )
        }

        await bridge.entered.wait()
        pending.cancel()
        await bridge.release.signal()
        let projection = await pending.value

        #expect(projection.identity == invocation)
        #expect(projection.response.disposition == .invocationRejected)
    }

    @Test func streamedOutputIsBoundedWithoutJoiningAnUnboundedPayload() {
        let output = MCPOutputLimiter.limit(
            [String(repeating: "a", count: 10_000), String(repeating: "b", count: 10_000)],
            to: 64
        )

        #expect(output.count <= 64)
        #expect(output.contains(MCPOutputLimiter.truncationMarker))
    }

    @Test func stopRetiresOwnerAndReopenGetsAnewGenerationFence() async throws {
        let transport = MCPStdioTransport(command: "/bin/cat", args: [], env: [:], timeoutSeconds: 1)

        try await transport.start()
        let first = transport.runtimeSnapshot()
        #expect(first.state == .running)
        #expect(first.ownerID != nil)
        let firstIdentity = try #require(first.runtimeIdentity)
        #expect(transport.accepts(firstIdentity))
        #expect(transport.isReady)

        transport.stop()
        let retired = transport.runtimeSnapshot()
        #expect(retired.state == .stopped)
        #expect(retired.ownerID == nil)
        #expect(retired.runtimeIdentity == nil)
        #expect(!transport.accepts(firstIdentity))
        #expect(!transport.isReady)

        try await transport.start()
        let reopened = transport.runtimeSnapshot()
        #expect(reopened.state == .running)
        #expect(reopened.generation > first.generation)
        #expect(reopened.ownerID != first.ownerID)
        let reopenedIdentity = try #require(reopened.runtimeIdentity)
        #expect(!transport.accepts(firstIdentity), "late output from retired owner must be rejected")
        #expect(transport.accepts(reopenedIdentity))

        let rolledBack = transport.rollbackRuntime()
        #expect(rolledBack.state == .stopped)
        #expect(rolledBack.runtimeIdentity == nil)
        #expect(!transport.accepts(reopenedIdentity), "rollback must retire the active owner")
    }

    @Test func clientRollbackLeavesFailedRecoveryDisconnected() async {
        let server = MCPServer(id: "missing", name: "Missing", type: .stdio, command: nil)
        let client = MCPClient(server: server)

        do {
            try await client.recover()
            Issue.record("expected recovery of invalid stdio configuration to fail closed")
        } catch {
            #expect(client.connectionState == .failed("Invalid MCP server config: no command configured for stdio server"))
        }

        client.rollback()
        #expect(client.connectionState == .disconnected)
        #expect(!client.isConnected)
    }

    @Test func failedConnectPublishesUserUnderstandableTerminalState() async {
        let server = MCPServer(id: "missing", name: "Missing", type: .stdio, command: nil)
        let client = MCPClient(server: server)

        do {
            try await client.connect()
            Issue.record("expected invalid stdio configuration to fail closed")
        } catch {
            #expect(client.connectionState == .failed("Invalid MCP server config: no command configured for stdio server"))
            #expect(!client.isConnected)
        }
    }
}
