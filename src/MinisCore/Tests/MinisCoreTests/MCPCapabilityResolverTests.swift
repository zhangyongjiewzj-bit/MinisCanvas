import Foundation
import Testing
@testable import MinisCore

private final class MutableMCPCapabilityBridge: MCPToolBridge, @unchecked Sendable {
    private let lock = NSLock()
    private var tools: [MCPBoundTool]

    init(tools: [MCPBoundTool]) {
        self.tools = tools
    }

    func mcpBoundTools() async throws -> [MCPBoundTool] {
        lock.withLock { tools }
    }

    func callMCPTool(fullName: String, arguments: [String: Any]?) async throws -> String {
        "unused"
    }

    func replaceTools(_ tools: [MCPBoundTool]) {
        lock.withLock { self.tools = tools }
    }
}

@Suite("MCP capability resolver descriptor revalidation")
struct MCPCapabilityResolverTests {
    @Test
    func registeredMCPNameCannotBypassCurrentBridgeCatalog() async throws {
        let fullName = MCPBoundTool.makeFullName(serverID: "settings", toolName: "greet")
        let tool = MCPBoundTool(
            fullName: fullName,
            serverID: "settings",
            tool: MCPTool(name: "greet")
        )
        let bridge = MutableMCPCapabilityBridge(tools: [tool])
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-capability-resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let executor = BuiltinToolExecutor(allowedRoot: root, mcpBridge: bridge)
        executor.registerToolNames([fullName])
        #expect(try await executor.resolvesCapability(fullName))

        // The dispatch cache still contains the old name, but the current
        // descriptor/name resolver no longer advertises it.
        bridge.replaceTools([])
        #expect(try await executor.resolvesCapability(fullName) == false)

        // A long-lived policy goal may also retain that stale name. The
        // original request capability gate must still consult the resolver.
        let now = Date()
        let goal = GoalEnvelope(
            scopeID: "mcp-capability-resolver",
            allowedCapabilities: [fullName],
            fileRoots: [root.path],
            budget: 2,
            deadline: now.addingTimeInterval(60),
            autonomyLevel: .l1,
            createdAt: now
        )
        let lease = AutonomyLease(
            goalID: goal.goalID,
            scopeID: goal.scopeID,
            issuedAt: now,
            expiresAt: goal.deadline
        )
        let policy = PolicyEnforcedToolExecutor(
            base: executor,
            goal: goal,
            lease: lease,
            capabilityResolver: executor
        )
        await #expect(throws: PolicyEnforcedToolExecutorError.policyViolation(.capabilityNotAllowed)) {
            _ = try await policy.execute(name: fullName, input: [:])
        }
        #expect(policy.acceptedExecutionCount == 0)
        #expect(policy.deniedExecutionCount == 1)
    }
}
