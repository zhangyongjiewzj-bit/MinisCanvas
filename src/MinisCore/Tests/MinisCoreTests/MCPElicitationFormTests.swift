import XCTest
@testable import MinisCore

final class MCPElicitationFormTests: XCTestCase {
    private func form(_ properties: [String: MCPJSONValue], required: [String] = []) throws -> MCPElicitationForm {
        try MCPElicitationForm(params: .object([
            "message": .string("请核对输入"),
            "requestedSchema": .object(["type": .string("object"), "properties": .object(properties),
                "required": .array(required.map(MCPJSONValue.string))])
        ]))
    }

    func testRealLoopUsesItsReceiptForFencedMCPAndSettlesTypedUserCancelOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("N13-cancel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts.json"))
        let bridge = N13ReceiptBridge()
        let executor = BuiltinToolExecutor(allowedRoot: root, mcpBridge: bridge)
        let provider = N13CancelProvider()
        let execution = AgentExecutionIdentity(turn: AgentTurnIdentity(sessionID: "n13-session", turnID: 1,
            messageID: "n13-message"), operationID: "n13-operation", attempt: 1)
        let gate = ApprovalGate(policyByTool: [N13ReceiptBridge.toolName: .autoApprove])
        do {
            _ = try await AgentLoop(maxIterations: 2, approvalGate: gate, toolExecutionFactLedger: ledger).run(
                messages: [LLMMessage(role: .user, content: "synthetic")], systemPrompt: nil,
                provider: provider, toolExecutor: executor,
                tools: [AgentToolDefinition(name: N13ReceiptBridge.toolName, description: "synthetic", parameters: [:], required: [])],
                executionIdentity: execution)
            XCTFail("User cancellation must terminate instead of continuing the model")
        } catch is MCPElicitationUserCancelled {
            // This precise error has a different origin from transport/schema failures.
        }
        let receipt = try XCTUnwrap(bridge.receipt)
        XCTAssertEqual(bridge.invocation, MCPToolInvocationIdentity(correlationID: receipt.receiptID, attemptID: receipt.attemptID))
        XCTAssertEqual(receipt.executionIdentity, execution)
        XCTAssertEqual(ledger.facts.count, 1)
        XCTAssertEqual(ledger.facts.first?.status, .cancelled)
        XCTAssertTrue(ledger.pendingReceipts.isEmpty)
        XCTAssertEqual(provider.requestCount, 1)
    }

    func testLegacyMCPDispatchWithoutAReceiptCannotInheritAnInteractiveHandler() async throws {
        let bridge = N13ReceiptBridge()
        let executor = BuiltinToolExecutor(allowedRoot: FileManager.default.temporaryDirectory, mcpBridge: bridge)
        let output = try await ToolExecutionReceiptContext.$current.withValue(nil) {
            try await MCPElicitationTaskContext.$handler.withValue({ _, _ in
                XCTFail("A legacy invocation must not open an elicitation")
                return MCPElicitationResult(action: .decline)
            }) {
                try await executor.execute(name: N13ReceiptBridge.toolName, input: [:])
            }
        }
        XCTAssertEqual(output, "legacy noninteractive result")
        XCTAssertEqual(bridge.legacyHadHandler, false)
        XCTAssertNil(bridge.invocation)
    }

    func testAcceptPreservesPrimitiveTypesAndOmitsUnansweredOptionalField() throws {
        let request = try form([
            "name": .object(["type": .string("string"), "minLength": .number(2)]),
            "count": .object(["type": .string("integer"), "minimum": .number(1)]),
            "confirm": .object(["type": .string("boolean")]),
            "optional": .object(["type": .string("string")])
        ], required: ["name", "count", "confirm"])
        let result = try request.response(texts: ["name": "张三", "count": "2", "confirm": "false"])
        XCTAssertEqual(result.action, .accept)
        XCTAssertEqual(result.content, ["name": .string("张三"), "count": .number(2), "confirm": .bool(false)])
        XCTAssertNoThrow(try request.validate(result))
        XCTAssertThrowsError(try request.response(texts: ["name": "张", "count": "2.5", "confirm": "false"]))
    }

    func testUnsupportedSchemaAndOversizedInputAreRejectedInsteadOfChanged() throws {
        XCTAssertThrowsError(try form(["name": .object(["type": .string("string"), "pattern": .string("[a-z]+")])]))
        XCTAssertThrowsError(try form(["items": .object(["type": .string("array")])]))
        let request = try form(["name": .object(["type": .string("string")])])
        XCTAssertThrowsError(try request.response(texts: ["name": String(repeating: "x", count: 4_001)]))
        XCTAssertThrowsError(try request.validate(MCPElicitationResult(action: .accept, content: ["name": .number(1)])))
        XCTAssertEqual(MCPElicitationResult(action: .decline).json, .object(["action": .string("decline")]))
        XCTAssertEqual(MCPElicitationResult(action: .cancel).json, .object(["action": .string("cancel")]))
    }

    func testOnlyExactBooleanServerMetadataRequiresHumanInteraction() throws {
        let boolean = MCPTool(name: "ordinary", _meta: .object(["anthropic/requiresUserInteraction": .bool(true)]))
        let string = MCPTool(name: "requiresUserInteraction", _meta: .object(["anthropic/requiresUserInteraction": .string("true")]))
        XCTAssertTrue(boolean.requiresUserInteraction)
        XCTAssertFalse(string.requiresUserInteraction)
        XCTAssertFalse(MCPTool(name: "requiresUserInteraction").requiresUserInteraction)
        let decoded = try JSONDecoder().decode(MCPTool.self, from: JSONEncoder().encode(boolean))
        XCTAssertTrue(decoded.requiresUserInteraction)
        XCTAssertNotEqual(MCPDiscoverySnapshot.schemaDigest(for: [boolean]), MCPDiscoverySnapshot.schemaDigest(for: [MCPTool(name: "ordinary")]))
    }
}

/// In-memory bridge only: no process, MCP connection, server or credential access.
private final class N13ReceiptBridge: MCPToolBridgeInvocationFencing, @unchecked Sendable {
    static let toolName = "mcp_synthetic_question"
    private let lock = NSLock()
    private var savedReceipt: ToolExecutionReceipt?
    private var savedInvocation: MCPToolInvocationIdentity?
    private var savedLegacyHadHandler: Bool?
    var receipt: ToolExecutionReceipt? { lock.withLock { savedReceipt } }
    var invocation: MCPToolInvocationIdentity? { lock.withLock { savedInvocation } }
    var legacyHadHandler: Bool? { lock.withLock { savedLegacyHadHandler } }
    func mcpBoundTools() async throws -> [MCPBoundTool] {
        [MCPBoundTool(fullName: Self.toolName, serverID: "synthetic", tool: MCPTool(name: "question"))]
    }
    func callMCPTool(fullName: String, arguments: [String: Any]?) async throws -> String {
        lock.withLock { savedLegacyHadHandler = MCPElicitationTaskContext.handler != nil }
        return "legacy noninteractive result"
    }
    func callMCPTool(fullName: String, arguments: [String: Any]?, invocation: MCPToolInvocationIdentity) async throws -> String {
        lock.withLock {
            savedReceipt = ToolExecutionReceiptContext.current
            savedInvocation = invocation
        }
        throw MCPElicitationUserCancelled()
    }
}
private final class N13CancelProvider: LLMProvider, @unchecked Sendable {
    let name = "n13-offline"
    var model = LLMModel(id: "synthetic", displayName: "synthetic", provider: "n13-offline")
    let capabilities: Set<ProviderCapability> = [.tools]
    private let lock = NSLock()
    private var count = 0
    var requestCount: Int { lock.withLock { count } }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        lock.withLock { count += 1 }
        return LLMResponse(text: "{\"tool_calls\":[{\"id\":\"elicitation-tool\",\"name\":\"mcp_synthetic_question\",\"input\":{}}]}",
            stopReason: "tool_use", usage: nil)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition], maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt, maxTokens: maxTokens, temperature: temperature)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// Source-only regression coverage for the real stdio pending table. These
/// fixtures are not started by the code-only lane; the unified test lane runs
/// them later under its owned MINISCANVAS_TEST_DIRECTORY.
final class MCPElicitationStdioPendingTests: XCTestCase, @unchecked Sendable {
    private final class HandlerCount: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        func read() -> Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func client(scriptBody: String) throws -> (MCPClient, MCPStdioTransport) {
        let formal = try XCTUnwrap(ProcessInfo.processInfo.environment["MINISCANVAS_TEST_DIRECTORY"])
        let directory = URL(fileURLWithPath: formal, isDirectory: true)
            .appendingPathComponent("N13-stdio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let script = directory.appendingPathComponent("peer.py")
        try scriptBody.write(to: script, atomically: true, encoding: .utf8)
        let server = MCPServer(id: "n13-local", name: "N13 test peer", command: "/usr/bin/python3",
            args: ["-B", script.path], timeoutSeconds: 5)
        let transport = MCPStdioTransport(command: "/usr/bin/python3", args: ["-B", script.path], env: [:], timeoutSeconds: 5)
        return (MCPClient(server: server, transport: transport), transport)
    }

    func testConcurrentOrdinaryCallsCompleteAndAmbiguousAndLateFormsDecline() async throws {
        let (client, transport) = try client(scriptBody: #"""
        import sys, json
        def send(value):
            print(json.dumps(dict(jsonrpc="2.0", **value)), flush=True)
        def success(identity, text):
            send(dict(id=identity, result=dict(content=[dict(type="text", text=text)])))
        def form(identity):
            send(dict(id=identity, method="elicitation/create", params=dict(message="Which call?", requestedSchema=dict(type="object", properties={}))))
        first = second = release = None
        concurrent_declined = False
        for line in sys.stdin:
            message = json.loads(line)
            method = message.get("method")
            if method == "initialize":
                send(dict(id=message["id"], result=dict(protocolVersion="2025-11-25", capabilities=dict(tools=dict(listChanged=True)), serverInfo=dict(name="fixture", version="1"))))
            elif method == "tools/call":
                name = message["params"]["name"]
                if name == "first":
                    first = message["id"]
                    send(dict(method="notifications/tools/list_changed"))
                elif name == "second":
                    second = message["id"]
                    form("concurrent-form")
                elif name == "release":
                    release = message["id"]
                    form("late-second-form")
            elif message.get("id") == "concurrent-form":
                concurrent_declined = message.get("result", {}).get("action") == "decline"
                success(second, "second-ok" if concurrent_declined else "wrong-concurrent-routing")
            elif message.get("id") == "late-second-form":
                late_declined = message.get("result", {}).get("action") == "decline"
                success(first, "first-ok" if late_declined else "wrong-late-routing")
                success(release, "release-ok")
        """#)
        defer { client.disconnect() }
        let firstPending = expectation(description: "server has the first real pending tool")
        client.setToolsChangedHandler { firstPending.fulfill() }
        try await client.connect()
        let count = HandlerCount()
        let handler: @Sendable (MCPElicitationContext, MCPElicitationForm) async throws -> MCPElicitationResult = { _, _ in
            count.increment()
            return MCPElicitationResult(action: .decline)
        }
        let first = Task {
            try await MCPElicitationTaskContext.$handler.withValue(handler) {
                try await client.callTool(name: "first", arguments: nil,
                    invocation: MCPToolInvocationIdentity(correlationID: "real-first", attemptID: "attempt-1"))
            }
        }
        defer { first.cancel() }
        await fulfillment(of: [firstPending], timeout: 5)
        let second = try await MCPElicitationTaskContext.$handler.withValue(handler) {
            try await client.callTool(name: "second", arguments: nil,
                invocation: MCPToolInvocationIdentity(correlationID: "real-second", attemptID: "attempt-2"))
        }
        XCTAssertEqual(second, "second-ok")
        let owner = try XCTUnwrap(transport.runtimeSnapshot().ownerID)
        XCTAssertNil(transport.elicitationParentRequestID(ownerID: owner), "A late second-call form must stay unassociated after second completes")
        let release = try await client.callTool(name: "release", arguments: nil)
        XCTAssertEqual(release, "release-ok")
        let firstOutput = try await first.value
        XCTAssertEqual(firstOutput, "first-ok")
        XCTAssertEqual(count.read(), 0, "Neither form may reach the retained first-call handler")
    }

    func testUserCancellationWinsOverImmediateLateToolSuccessAndNextCallRemainsUsable() async throws {
        let (client, _) = try client(scriptBody: #"""
        import sys, json
        def send(value):
            print(json.dumps(dict(jsonrpc="2.0", **value)), flush=True)
        original = None
        cancelled = False
        for line in sys.stdin:
            message = json.loads(line)
            method = message.get("method")
            if method == "initialize":
                send(dict(id=message["id"], result=dict(protocolVersion="2025-11-25", capabilities={}, serverInfo=dict(name="fixture", version="1"))))
            elif method == "tools/call" and message["params"]["name"] == "cancel-me":
                original = message["id"]
                send(dict(id="cancel-form", method="elicitation/create", params=dict(message="Cancel this call", requestedSchema=dict(type="object", properties={}))))
            elif message.get("id") == "cancel-form":
                if message.get("result", {}).get("action") == "cancel":
                    send(dict(id=original, result=dict(content=[dict(type="text", text="late-success-must-not-win")])))
            elif method == "notifications/cancelled":
                cancelled = message["params"]["requestId"] == original
            elif method == "tools/call" and message["params"]["name"] == "after":
                send(dict(id=message["id"], result=dict(content=[dict(type="text", text="after-ok" if cancelled else "missing-parent-cancel")])))
        """#)
        defer { client.disconnect() }
        let count = HandlerCount()
        let handler: @Sendable (MCPElicitationContext, MCPElicitationForm) async throws -> MCPElicitationResult = { _, _ in
            count.increment()
            return MCPElicitationResult(action: .cancel)
        }
        try await client.connect()
        do {
            _ = try await MCPElicitationTaskContext.$handler.withValue(handler) {
                try await client.callTool(name: "cancel-me", arguments: nil,
                    invocation: MCPToolInvocationIdentity(correlationID: "cancel-owner", attemptID: "attempt-1"))
            }
            XCTFail("The original real pending call must end as typed user cancellation")
        } catch is MCPElicitationUserCancelled {
            // Typed terminal from the exact original continuation, not inferred
            // from an empty tool result, UI state, or a timer.
        }
        XCTAssertEqual(count.read(), 1)
        let next = try await client.callTool(name: "after", arguments: nil)
        XCTAssertEqual(next, "after-ok", "Late success cannot consume or contaminate the next real pending call")
    }
}
