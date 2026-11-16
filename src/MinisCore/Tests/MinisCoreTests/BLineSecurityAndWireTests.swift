import Foundation
import Testing
@testable import MinisCore

// B 线先行测试：只覆盖 TerminalGuard、Provider tools wire contract 和 MCP
// 纯逻辑边界。测试故意绑定阶段 0 冻结的显式接口，先于实现运行并保存失败证据。

private func bLineToolDefinition() -> AgentToolDefinition {
    AgentToolDefinition(
        name: "shell_execute",
        description: "Run one safe command",
        parameters: [
            "command": AgentToolParam(type: .string, description: "The command"),
            "timeout": AgentToolParam(type: .integer, description: "Timeout"),
        ],
        required: ["command"]
    )
}

private final class BLineMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data, [String: String]))?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [Data] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        if let body = request.httpBody {
            Self.bodies.append(body)
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            Self.bodies.append(data)
        }

        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, data, headers) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func reset() {
        handler = nil
        requests = []
        bodies = []
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BLineMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class BLineMCPTransport: MCPTransport, @unchecked Sendable {
    let response: @Sendable (MCPJSONRPCRequest) async throws -> MCPJSONRPCResponse

    init(response: @escaping @Sendable (MCPJSONRPCRequest) async throws -> MCPJSONRPCResponse) {
        self.response = response
    }

    func start() async throws {}
    func send(_ request: MCPJSONRPCRequest) async throws -> MCPJSONRPCResponse {
        try await response(request)
    }
    func notify(_ notification: MCPJSONRPCNotification) throws {}
    func stop() {}
}

private func bLineMCPResponse(for request: MCPJSONRPCRequest, tools: [MCPTool], output: String = "ok") -> MCPJSONRPCResponse {
    switch request.method {
    case "initialize":
        return MCPJSONRPCResponse(id: request.id, result: .object(["capabilities": .object([:])]))
    case "tools/list":
        return MCPJSONRPCResponse(id: request.id, result: .object([
            "tools": .array(tools.map { tool in
                var object: [String: MCPJSONValue] = ["name": .string(tool.name)]
                if let description = tool.description { object["description"] = .string(description) }
                if let schema = tool.inputSchema { object["inputSchema"] = schema }
                return .object(object)
            })
        ]))
    case "tools/call":
        return MCPJSONRPCResponse(id: request.id, result: .object([
            "content": .array([.object(["type": .string("text"), "text": .string(output)])])
        ]))
    default:
        return MCPJSONRPCResponse(id: request.id, error: MCPJSONRPCError(code: -32601, message: "not found"))
    }
}

@Suite(.serialized)
struct BLineTerminalGuardTests {
    @Test func safeQuotedOperatorsAreAllowed() {
        let result = TerminalGuard.inspect("printf '%s' 'a;b && c | d > file'")
        #expect(result.isAllowed)
        #expect(result.rejectionReason == nil)
    }

    @Test(arguments: [
        "echo one; echo two",
        "echo one && echo two",
        "echo one || echo two",
        "printf hi | cat",
        "echo hi > output.txt",
        "echo $(whoami)",
        "echo `whoami`",
        "env bash -c 'echo injected'",
        "env -u SECRET bash -c 'echo injected'",
        "env -S 'bash -c echo injected'",
        "env --split-string='bash -c echo injected'",
        "FOO=bar bash -c 'echo injected'",
        "nice -n 10 bash -c 'echo injected'",
        "sudo -u test-user bash -c 'echo injected'",
        "$SHELL -c 'echo injected'",
        "xargs rm",
    ])
    func unsafeShellSyntaxIsRejected(command: String) {
        let result = TerminalGuard.inspect(command)
        #expect(!result.isAllowed, "Unsafe syntax was accepted: \(command)")
        #expect(result.rejectionReason?.isEmpty == false)
    }

    @Test func malformedQuotesHaveDiagnostic() {
        let result = TerminalGuard.inspect("printf '%s",)
        #expect(!result.isAllowed)
        #expect(result.rejectionReason?.contains("quote") == true)
    }

    @Test func executorAppliesTerminalPolicyFailClosedBeforeSpawning() async throws {
        // Successor contract (lane 032 danger-syntax unification, D-TERMINAL-04).
        // This test used to pin "TerminalGuard syntax rejection throws before
        // any spawn" for EVERY rejected compound. That pre-classification
        // throw was superseded: `runShell` now mirrors the terminal's single
        // snapshot (`TerminalPolicy.decision`-parity mapping in
        // BuiltinToolExecutor.runShell), so a guard-rejected compound the
        // snapshot does NOT deny belongs to the confirmation class and is
        // gated by the structurally unskippable per-call `shell_execute`
        // approval in ApprovalGate (pinned by
        // TerminalDangerSyntaxParityTests.gateNeverAutoApprovesShellExecute
        // and S5AgentShellExecuteCompoundLockTests in the App target). What
        // must stay fail-closed at THIS layer, with zero execution and zero
        // side effects, is pinned below:
        //   1. `.denied` classification — including product hard-deny names
        //      nested inside rejected compound syntax — throws before any
        //      process spawn;
        //   2. well-formed `.unknown` executables still throw before spawn.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BLineTerminalGuard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executor = BuiltinToolExecutor(allowedRoot: root)

        // The verdicts below come from the SAME immutable snapshot the visible
        // terminal consumes; the expectations here are bound to that shared
        // classification, not to a test-local copy of it.
        let deniedCompound = "echo safe; sudo tee should-not-run"
        #expect(!TerminalGuard.inspect(deniedCompound).isAllowed,
                "fixture must keep the guard-rejected syntax shape")
        #expect(TerminalPolicySnapshot.default.classify(command: deniedCompound) == .denied,
                "hard-deny name nested in a compound must classify .denied for both consumers")

        await #expect(throws: ToolExecutorError.shellRejected("command denied by terminal policy")) {
            _ = try await executor.execute(
                name: "shell_execute",
                input: ["command": deniedCompound]
            )
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("should-not-run").path),
                "denied-class compound must produce zero side effects before any spawn")

        // Approved unknown executables reach the shell and return its exit status.
        #expect(TerminalPolicySnapshot.default.classify(command: "qqqnotacommand") == .unknown)
        let unknownInput: [String: Any] = ["command": "qqqnotacommand"]
        let unknownResult = try await withFreshShellApprovalForTest(input: unknownInput) {
            try await executor.execute(name: "shell_execute", input: unknownInput)
        }
        let unknownEnvelope = try #require(try JSONSerialization.jsonObject(with: Data(unknownResult.utf8)) as? [String: Any])
        #expect((unknownEnvelope["exit_code"] as? Int) == 127)
    }
}

@Suite(.serialized)
struct BLineProviderCapabilityTests {
    @Test func providersDeclareUnifiedCapabilities() {
        let openAI = OpenAICompatibleProvider(apiKey: "unit-test-key")
        let anthropic = AnthropicProvider(apiKey: "unit-test-key")
        let checkpointDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bline-capabilities-" + UUID().uuidString, isDirectory: true)
        let responses = OpenAIResponsesProvider(
            apiKey: "unit-test-key",
            model: .gpt4oMini,
            customBaseURL: nil,
            appendV1Suffix: true,
            session: nil,
            providerName: "OpenAI Responses",
            attemptCheckpointDirectory: checkpointDirectory
        )

        #expect(openAI.capabilities.contains(.streaming))
        #expect(openAI.capabilities.contains(.tools))
        #expect(anthropic.capabilities.contains(.streaming))
        #expect(anthropic.capabilities.contains(.tools))
        #expect(responses.capabilities.contains(.streaming))
        #expect(responses.capabilities.contains(.tools))
        #expect(ProviderCapability.allCases == [.streaming, .tools, .vision, .audio, .image, .video])
    }

    @Test func defaultToolsPathFailsExplicitlyWhenUnsupported() async throws {
        let provider = BLineUnsupportedProvider()
        do {
            _ = try await provider.sendMessage(
                messages: [LLMMessage(role: .user, content: "hello")],
                systemPrompt: nil,
                tools: [bLineToolDefinition()],
                maxTokens: 32,
                temperature: nil
            )
            Issue.record("unsupported tools request unexpectedly succeeded")
        } catch let error as LLMError {
            guard case .unsupportedCapability(.tools) = error else {
                Issue.record("unexpected provider error: \(error.localizedDescription)")
                return
            }
        }
    }

    @Test func openAICompatibleSendsAndParsesNativeTools() async throws {
        defer { BLineMockURLProtocol.reset() }
        BLineMockURLProtocol.handler = { _ in
            let body: [String: Any] = [
                "choices": [[
                    "finish_reason": "tool_calls",
                    "message": [
                        "content": NSNull(),
                        "tool_calls": [[
                            "id": "call_openai_1",
                            "type": "function",
                            "function": ["name": "shell_execute", "arguments": "{\"command\":\"printf hi\"}"]
                        ]]
                    ]
                ]]
            ]
            return BLineMockURLProtocol.json(body)
        }
        let provider = OpenAICompatibleProvider(
            apiKey: "unit-test-key",
            customBaseURL: "https://mock.test",
            session: BLineMockURLProtocol.session()
        )
        let response = try await provider.sendMessage(
            messages: [LLMMessage(role: .user, content: "run")],
            systemPrompt: nil,
            tools: [bLineToolDefinition()],
            maxTokens: 64,
            temperature: nil
        )
        let body = try #require(BLineMockURLProtocol.bodies.first)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect((tools.first?["type"] as? String) == "function")
        #expect(((tools.first?["function"] as? [String: Any])?["name"] as? String) == "shell_execute")
        #expect(response.toolCalls.map(\.name) == ["shell_execute"])
        #expect(response.toolCalls.first?.rawArguments == "{\"command\":\"printf hi\"}")
    }

    @Test func anthropicSendsAndParsesNativeTools() async throws {
        defer { BLineMockURLProtocol.reset() }
        BLineMockURLProtocol.handler = { _ in
            BLineMockURLProtocol.json([
                "stop_reason": "tool_use",
                "content": [[
                    "type": "tool_use",
                    "id": "tool_anthropic_1",
                    "name": "shell_execute",
                    "input": ["command": "printf hi"]
                ]]
            ])
        }
        let provider = AnthropicProvider(
            apiKey: "unit-test-key",
            basePath: "https://mock.test",
            session: BLineMockURLProtocol.session()
        )
        let response = try await provider.sendMessage(
            messages: [LLMMessage(role: .user, content: "run")],
            systemPrompt: nil,
            tools: [bLineToolDefinition()],
            maxTokens: 64,
            temperature: nil
        )
        let body = try #require(BLineMockURLProtocol.bodies.first)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect((tools.first?["name"] as? String) == "shell_execute")
        #expect((tools.first?["input_schema"] as? [String: Any])?["type"] as? String == "object")
        #expect(response.toolCalls.map { $0.id } == ["tool_anthropic_1"])
        let firstArguments = try #require(response.toolCalls.first?.arguments)
        #expect(firstArguments["command"] as? String == "printf hi")
    }

    @Test func responsesSendsAndParsesFunctionCallItems() async throws {
        defer { BLineMockURLProtocol.reset() }
        let checkpointDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bline-responses-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: checkpointDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: checkpointDirectory) }
        BLineMockURLProtocol.handler = { _ in
            BLineMockURLProtocol.json([
                "status": "completed",
                "output": [[
                    "type": "function_call",
                    "call_id": "call_responses_1",
                    "name": "shell_execute",
                    "arguments": "{\"command\":\"printf hi\"}"
                ]]
            ])
        }
        let provider = OpenAIResponsesProvider(
            apiKey: "unit-test-key",
            model: .gpt4oMini,
            customBaseURL: "https://mock.test",
            appendV1Suffix: true,
            session: BLineMockURLProtocol.session(),
            providerName: "OpenAI Responses",
            attemptCheckpointDirectory: checkpointDirectory
        )
        let response: LLMResponse
        do {
            response = try await provider.sendMessage(
                messages: [LLMMessage(role: .user, content: "run")],
                systemPrompt: nil,
                tools: [bLineToolDefinition()],
                maxTokens: 64,
                temperature: nil
            )
        } catch {
            Issue.record("Responses stage: \(provider.persistAttemptReceiptDiagnosticStage()); write stage: \(provider.durableAttemptWriteDiagnosticStage()); mock requests: \(BLineMockURLProtocol.requests.count)")
            throw error
        }
        let body = try #require(BLineMockURLProtocol.bodies.first)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect((tools.first?["type"] as? String) == "function")
        #expect((tools.first?["name"] as? String) == "shell_execute")
        #expect(response.toolCalls.map(\.id) == ["call_responses_1"])
        #expect(response.toolCalls.first?.name == "shell_execute")
    }

    @Test func responsesRejectsIdentityFreeFunctionCallWithoutProjection() async throws {
        defer { BLineMockURLProtocol.reset() }
        let checkpointDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bline-responses-invalid-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: checkpointDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: checkpointDirectory) }
        BLineMockURLProtocol.handler = { _ in
            BLineMockURLProtocol.json([
                "id": "resp_invalid_call",
                "status": "completed",
                "output": [
                    ["type": "function_call", "name": "shell_execute", "arguments": "{}"],
                    ["type": "message", "content": [["type": "output_text", "text": "must not project"]]]
                ]
            ])
        }
        let provider = OpenAIResponsesProvider(
            apiKey: "unit-test-key",
            model: .gpt4oMini,
            customBaseURL: "https://mock.test",
            appendV1Suffix: true,
            session: BLineMockURLProtocol.session(),
            providerName: "OpenAI Responses",
            attemptCheckpointDirectory: checkpointDirectory
        )
        do {
            _ = try await provider.sendMessage(
                messages: [LLMMessage(role: .user, content: "run")],
                systemPrompt: nil,
                tools: [bLineToolDefinition()],
                maxTokens: 64,
                temperature: nil
            )
            Issue.record("identity-free function call was projected")
        } catch let error as LLMError {
            guard case .decodingError = error else {
                Issue.record("unexpected failure category: \(error)")
                return
            }
        }
        #expect(BLineMockURLProtocol.requests.count == 1)
    }
}

private final class BLineUnsupportedProvider: LLMProvider, @unchecked Sendable {
    let name = "Unsupported"
    var model: LLMModel = .gpt4oMini
    var capabilities: Set<ProviderCapability> { [.streaming] }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        LLMResponse(text: "plain", stopReason: "stop", usage: nil)
    }

    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private final class BLineForwardingProvider: LLMProvider, @unchecked Sendable {
    let name = "Forwarding"
    var model: LLMModel = .gpt4oMini
    let capabilities: Set<ProviderCapability> = [.streaming, .tools]
    private(set) var receivedToolNames: [String] = []

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        LLMResponse(text: "plain", stopReason: "stop", usage: nil)
    }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
        maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        receivedToolNames = tools.map(\.name)
        return LLMResponse(
            text: "tool response",
            stopReason: "tool_calls",
            usage: nil,
            toolCalls: [LLMToolCall(
                id: "forwarded-call", name: tools[0].name,
                rawArguments: "{\"command\":\"printf hi\"}",
                arguments: ["command": "printf hi"]
            )]
        )
    }

    func streamMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@Suite(.serialized)
struct BLineProviderDecoratorTests {
    @Test func retryDecoratorForwardsCapabilitiesAndNativeTools() async throws {
        let base = BLineForwardingProvider()
        let retrying = RetryingLLMProvider(
            base: base,
            policy: LLMRetryPolicy(maxRetries: 0, sleeper: { _ in })
        )

        #expect(retrying.capabilities == base.capabilities)
        let response = try await retrying.sendMessage(
            messages: [LLMMessage(role: .user, content: "run")],
            systemPrompt: nil,
            tools: [bLineToolDefinition()],
            maxTokens: 32,
            temperature: nil
        )
        #expect(base.receivedToolNames == ["shell_execute"])
        #expect(response.toolCalls.map(\.id) == ["forwarded-call"])
    }
}

@Suite(.serialized)
struct BLineMCPBoundaryTests {
    private func makeTool(name: String = "greet", outputSchema: Bool = true) -> MCPTool {
        MCPTool(
            name: name,
            description: "Greet a user",
            inputSchema: outputSchema ? .object([
                "type": .string("object"),
                "properties": .object([
                    "name": .object(["type": .string("string"), "description": .string("Name")]),
                    "count": .object(["type": .string("integer")]),
                ]),
                "required": .array([.string("name")]),
            ]) : nil
        )
    }

    @Test func mcpSchemaMapsToAgentToolDefinition() throws {
        let definition = try #require(try makeTool().makeAgentToolDefinition())
        #expect(definition.name == "greet")
        #expect(definition.description == "Greet a user")
        #expect(definition.required == ["name"])
        #expect(definition.parameters["name"]?.type == .string)
        #expect(definition.parameters["count"]?.type == .integer)
    }

    @Test func mcpClientCapsOutputWithoutLeakingUnboundedPayload() async throws {
        let longText = String(repeating: "x", count: 200)
        let transport = BLineMCPTransport { request in
            bLineMCPResponse(for: request, tools: [], output: longText)
        }
        let client = MCPClient(
            server: MCPServer(id: "bounded", name: "Bounded", type: .http, url: "http://mock"),
            transport: transport,
            maxOutputCharacters: 32
        )
        let output = try await client.callTool(name: "greet", arguments: nil)
        #expect(output.count <= 32)
        #expect(output.contains("truncated"))
    }

    @Test func registryRemovesToolsAndClientsWhenServerGoesOffline() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BLineMCP-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manager = MCPServerManager(fileURL: directory.appendingPathComponent("mcps.json"))
        let online = MCPServer(id: "online", name: "Online", type: .http, url: "http://mock")
        try manager.addServer(online)
        try manager.authorizeServer(id: online.id)
        try manager.authorizeTool(serverID: online.id, toolName: "greet")
        let tool = makeTool()
        let registry = MCPToolRegistry(manager: manager, clientFactory: { server in
            MCPClient(server: server, transport: BLineMCPTransport { request in
                bLineMCPResponse(for: request, tools: [tool], output: "ok")
            })
        }, authorization: .allowing(["mcp_online_greet"]))

        #expect((try await registry.mcpBoundTools()).map(\.fullName) == ["mcp_online_greet"])
        _ = try #require(try manager.enableServer(id: "online", enabled: false))
        try await registry.refreshTools()
        let toolsAfterDisable = try await registry.mcpBoundTools()
        #expect(toolsAfterDisable.isEmpty)
        await #expect(throws: MCPClientError.toolNotFound("mcp_online_greet")) {
            _ = try await registry.callMCPTool(fullName: "mcp_online_greet", arguments: nil)
        }
    }

    @Test func registryPropagatesCancellationInsteadOfDowngradingToEmpty() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BLineMCPCancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manager = MCPServerManager(fileURL: directory.appendingPathComponent("mcps.json"))
        let cancel = MCPServer(id: "cancel", name: "Cancel", type: .http, url: "http://mock")
        try manager.addServer(cancel)
        try manager.authorizeServer(id: cancel.id)
        let registry = MCPToolRegistry(manager: manager) { server in
            MCPClient(server: server, transport: BLineMCPTransport { _ in throw CancellationError() })
        }

        await #expect(throws: CancellationError.self) {
            _ = try await registry.mcpBoundTools()
        }
    }

    @Test func forgedToolNameIsRejectedAfterDiscovery() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BLineMCPForge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manager = MCPServerManager(fileURL: directory.appendingPathComponent("mcps.json"))
        let server = MCPServer(id: "server", name: "Server", type: .http, url: "http://mock")
        try manager.addServer(server)
        try manager.authorizeServer(id: server.id)
        try manager.authorizeTool(serverID: server.id, toolName: "greet")
        let registry = MCPToolRegistry(manager: manager) { server in
            MCPClient(server: server, transport: BLineMCPTransport { request in
                bLineMCPResponse(for: request, tools: [makeTool()], output: "ok")
            })
        }
        _ = try await registry.mcpBoundTools()

        await #expect(throws: MCPClientError.toolNotFound("mcp_server_greet_forged")) {
            _ = try await registry.callMCPTool(fullName: "mcp_server_greet_forged", arguments: nil)
        }
    }
}

private extension BLineMockURLProtocol {
    static func json(_ object: [String: Any], status: Int = 200) -> (Int, Data, [String: String]) {
        (status, try! JSONSerialization.data(withJSONObject: object), ["Content-Type": "application/json"])
    }
}
