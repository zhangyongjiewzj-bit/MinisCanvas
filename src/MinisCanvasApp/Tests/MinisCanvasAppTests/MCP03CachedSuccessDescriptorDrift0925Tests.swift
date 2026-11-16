import Foundation
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

// This extension uses the original MCP3098 Process/Pipe fixture and its
// Composer turn IDs. It adds the state that the earlier held-call negative
// cases did not have: one successful call through this same executor first.
extension MCP03ActualStdioProvider3098Tests {
    private func cachedExecutor(
        _ f: Fixture
    ) -> (AgentLoopChatEngine, BuiltinToolExecutor, PolicyEnforcedToolExecutor) {
        let builtin = BuiltinToolExecutor(allowedRoot: f.root, mcpBridge: f.registry)
        let created = Date()
        // Preserve the old static-goal route that exposed the bypass.
        let goal = GoalEnvelope(scopeID: "test:mcp3098-cached",
            allowedCapabilities: builtin.registeredToolNames.union([f.fullName]),
            fileRoots: [f.root.path], budget: 10,
            deadline: created.addingTimeInterval(60), concurrencyLimit: 1,
            autonomyLevel: .l1, createdAt: created)
        let lease = AutonomyLease(goalID: goal.goalID, scopeID: goal.scopeID,
            issuedAt: created, expiresAt: goal.deadline)
        let executor = PolicyEnforcedToolExecutor(base: builtin, goal: goal,
            lease: lease, capabilityResolver: builtin)
        let facts = ComposerPolicyFactSource(knownCapabilities: [],
            grantedCapabilities: [], allowedWriteRoots: [f.root.path],
            workspaceID: "mcp3098-\(f.root.lastPathComponent)",
            revision: "mcp3098-policy", grantEpoch: "mcp3098-grant",
            leaseID: "mcp3098-lease-\(f.root.lastPathComponent)",
            expiresAt: created.addingTimeInterval(60), autonomyCeiling: .l1)
        let engine = AgentLoopChatEngine(toolExecutor: executor, maxIterations: 3,
            approvalDelegate: ProductionApprovalDelegate(), mcpBridge: f.registry,
            toolExecutionFactLedger: f.ledger, composerPolicyFacts: facts)
        return (engine, builtin, executor)
    }

    private func runHeldComposerTurn(
        _ f: Fixture, engine: AgentLoopChatEngine, provider: MCP3098HeldModel,
        conversationID: String, turnID: Int
    ) async throws {
        let user = ChatMessageUI(role: .user, content: "owned synthetic MCP request")
        let turn = AgentTurnIdentity(sessionID: conversationID, turnID: turnID,
            messageID: user.id.uuidString)
        let attemptID = UUID().uuidString
        let inputDigest = ComposerToolInput(values: [
            "content": .string(user.content), "attachments": .array([])
        ]).digest
        let snapshot = ComposerSubmissionSnapshot(mode: .manual,
            approvalScope: .request, effort: .standard, sessionID: conversationID,
            turnID: turnID, taskID: "chat:\(conversationID):\(turnID):\(attemptID)",
            attemptID: attemptID, messageID: turn.messageID, inputDigest: inputDigest,
            workspaceID: "mcp3098-\(f.root.lastPathComponent)", createdAt: Date(),
            policyRevision: "mcp3098-policy", grantEpoch: "mcp3098-grant",
            autonomyCeiling: .l1)
        let identity = AgentExecutionIdentity(turn: turn,
            operationID: "chat:\(conversationID):\(turnID):\(turn.messageID)",
            attempt: 1)
        let runtime = ChatTurnRuntimeSnapshot(turn: turn, skillInjector: nil,
            skillsDisabled: true, mcpBridge: try f.registry.snapshotForTurn())
        let stream = try await engine.streamReply(provider: provider, history: [user],
            systemPrompt: "owned synthetic fixture", maxTokens: 128,
            conversationID: conversationID, authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil, turnID: turnID,
            composerSnapshot: snapshot, executionIdentity: identity,
            turnRuntimeSnapshot: runtime)
        for try await _ in stream { }
    }

    @Test(arguments: ["unchanged", "descriptor-argv", "tool-grant"])
    func actualCachedSuccessThenCanonicalDriftIsPredispatchDenied(
        _ scenario: String
    ) async throws {
        let f = try fixture("cached-\(scenario)")
        defer { f.registry.disconnectAll() }
        try #require(try await discover(f))
        let initial = try #require(f.manager.discoverySnapshot(serverID: f.server.id))
        let conversationID = "mcp3098-\(f.root.lastPathComponent)"
        let (engine, builtin, executor) = cachedExecutor(f)
        #expect(goalContainsMCP(executor, f.fullName))

        _ = try await providerTurn(f, stage: "cached-turn-1", callsTool: true,
            conversationID: conversationID, turnID: 1, sharedEngine: engine)
        #expect(builtin.registeredToolNames.contains(f.fullName),
            "The first successful dispatch must exercise the cached-name path")
        #expect(executor.acceptedExecutionCount == 1)
        #expect(executor.deniedExecutionCount == 0)
        let firstWire = try wire(f)
        #expect(firstWire.filter { $0["method"] as? String == "tools/list" }.count == 1)
        #expect(firstWire.filter { $0["method"] as? String == "tools/call" }.count == 1)
        let firstFact = try #require(f.ledger.facts.first)
        #expect(f.ledger.facts.count == 1 && firstFact.status == .succeeded)
        #expect(firstFact.compositeKey?.sessionID == conversationID)
        #expect(firstFact.compositeKey?.turnID == 1)

        let callID = "mcp3098-cached-\(scenario)-turn-2"
        let held = MCP3098HeldModel(requestedName: f.fullName, callID: callID)
        defer { held.release.signal() }
        let running = Task {
            try await runHeldComposerTurn(f, engine: engine, provider: held,
                conversationID: conversationID, turnID: 2)
        }
        for _ in 0..<100 where !held.entered.isReady {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(held.entered.isReady)
        #expect(held.offeredNames.first?.contains(f.fullName) == true)
        #expect(try wire(f).filter { $0["method"] as? String == "tools/call" }.count == 1)

        switch scenario {
        case "descriptor-argv":
            let changed = MCPServer(id: f.server.id, name: f.server.name,
                type: .stdio, command: "/bin/sh",
                args: [f.root.appendingPathComponent("server.sh").path, "--identity-drift"],
                env: ["MCP3098_ROOT": f.root.path], timeoutSeconds: 5)
            #expect(changed.descriptorFingerprint != f.server.descriptorFingerprint)
            try #require(f.center.addMCPServer(changed))
            #expect(!f.center.isMCPServerAuthorized(id: f.server.id))
            #expect(f.manager.discoverySnapshot(serverID: f.server.id) == nil)
            #expect(try await f.registry.mcpBoundTools().isEmpty)
        case "tool-grant":
            try #require(f.center.setMCPToolAuthorized(
                serverID: f.server.id, toolName: "greet", authorized: false))
            #expect(!f.center.isMCPToolAuthorized(
                serverID: f.server.id, toolName: "greet"))
            #expect(try await f.registry.mcpBoundTools().isEmpty)
        default:
            #expect(scenario == "unchanged")
            #expect(f.manager.discoverySnapshot(serverID: f.server.id) == initial)
            #expect(try await f.registry.mcpBoundTools().map(\.fullName) == [f.fullName])
        }
        // The old static goal and cached builtin name remain on purpose.
        #expect(goalContainsMCP(executor, f.fullName))
        #expect(builtin.registeredToolNames.contains(f.fullName))
        held.release.signal()
        try await running.value

        let finalWire = try wire(f)
        let callCount = finalWire.filter { $0["method"] as? String == "tools/call" }.count
        let reopened = try ToolExecutionFactLedger(
            persistenceURL: f.root.appendingPathComponent("facts.json"))
        #expect(reopened.facts == f.ledger.facts)
        #expect(reopened.pendingReceipts.isEmpty)
        if scenario == "unchanged" {
            #expect(callCount == 2)
            #expect(executor.acceptedExecutionCount == 2)
            #expect(executor.deniedExecutionCount == 0)
            let facts = f.ledger.facts
            #expect(facts.count == 2 && facts.allSatisfy { $0.status == .succeeded })
            #expect(facts.compactMap { $0.compositeKey?.turnID } == [1, 2])
            #expect(Set(facts.map(\.receiptID)).count == 2)
        } else {
            #expect(callCount == 1, "Second model call must not reach actual stdio")
            #expect(executor.acceptedExecutionCount == 1,
                "Canonical drift must be rejected before the base executor")
            #expect(executor.deniedExecutionCount == 1)
            #expect(executor.lastCapabilityDenialReceipt?.capabilityID == f.fullName)
            #expect(executor.lastCapabilityDenialReceipt?.reason == .capabilityNotAllowed)
            #expect(f.ledger.facts.count == 2)
            #expect(f.ledger.facts.first == firstFact)
            let second = try #require(f.ledger.facts.last)
            #expect(second.toolCallID == callID && second.status == .failed)
            #expect(second.compositeKey?.sessionID == conversationID)
            #expect(second.compositeKey?.turnID == 2)
        }
    }

    private func goalContainsMCP(
        _ executor: PolicyEnforcedToolExecutor, _ name: String
    ) -> Bool {
        executor.goal.allowedCapabilities.contains(name)
    }
}
