import Foundation
import Testing
@testable import MinisCore

private final class Line4FakeProvider: LLMProvider, @unchecked Sendable {
    let name = "Line4Fake"
    var model = LLMModel(id: "line4-fake-model", displayName: "Line4 Fake", provider: "Line4Fake")
    let capabilities: Set<ProviderCapability>
    private(set) var receivedToolNames: [String] = []

    init(capabilities: Set<ProviderCapability>) {
        self.capabilities = capabilities
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        LLMResponse(text: "fake response", stopReason: "stop", usage: nil)
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        guard capabilities.contains(.tools) else {
            throw LLMError.unsupportedCapability(.tools)
        }
        receivedToolNames = tools.map(\.name)
        return LLMResponse(text: "fake tool response", stopReason: "stop", usage: nil)
    }

    func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.started)
            continuation.yield(.text("fake stream"))
            continuation.yield(.finished(stopReason: "stop"))
            continuation.finish()
        }
    }
}

private struct Line4FakeMCPTransport: MCPTransport {
    let output: String

    func start() async throws {}

    func send(_ request: MCPJSONRPCRequest) async throws -> MCPJSONRPCResponse {
        switch request.method {
        case "initialize":
            return MCPJSONRPCResponse(id: request.id, result: .object(["capabilities": .object([:])]))
        case "tools/list":
            return MCPJSONRPCResponse(id: request.id, result: .object([
                "tools": .array([
                    .object([
                        "name": .string("echo"),
                        "description": .string("offline fake tool"),
                        "inputSchema": .object(["type": .string("object")]),
                    ])
                ])
            ]))
        case "tools/call":
            return MCPJSONRPCResponse(id: request.id, result: .object([
                "content": .array([.object(["type": .string("text"), "text": .string(output)])])
            ]))
        default:
            return MCPJSONRPCResponse(id: request.id, error: MCPJSONRPCError(code: -32601, message: "method not found"))
        }
    }

    func notify(_ notification: MCPJSONRPCNotification) throws {}
    func stop() {}
}

@Suite("Line4 Provider and MCP Contracts")
struct Line4ProviderMCPContractTests {

    @Test func manifestIsStableCredentialFreeAndRoundTrips() throws {
        let manifest = CapabilityManifest(
            providerID: "line4-fake",
            capabilities: [.tools, .streaming],
            maxOutputCharacters: 24
        )
        let encoded = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(CapabilityManifest.self, from: encoded)

        #expect(decoded == manifest)
        #expect(manifest.capabilities.map(\.rawValue) == ["streaming", "tools"])
        #expect(manifest.hash.count == 64)
        #expect(String(decoding: encoded, as: UTF8.self).contains("line4-fake"))
        #expect(!String(decoding: encoded, as: UTF8.self).contains("apiKey"))
    }

    @Test func manifestRejectsUnknownCapabilityAndTamperedHash() throws {
        let manifest = CapabilityManifest(providerID: "line4-fake", capabilities: [.tools])
        let data = try JSONEncoder().encode(manifest)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["capabilities"] = ["tools", "future_capability"]
        let unknownData = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(CapabilityManifest.self, from: unknownData)
        }

        object["capabilities"] = ["tools"]
        object["hash"] = String(repeating: "0", count: 64)
        let tamperedData = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: CapabilityManifestError.self) {
            _ = try JSONDecoder().decode(CapabilityManifest.self, from: tamperedData)
        }
    }

    @Test func providerSnapshotContainsOnlyPublicWireMetadata() throws {
        let provider = Line4FakeProvider(capabilities: [.streaming, .tools])
        let snapshot = CapabilityProviderSnapshot(providerID: "line4-fake", provider: provider, maxOutputCharacters: 48)
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(CapabilityProviderSnapshot.self, from: data)

        #expect(decoded == snapshot)
        #expect(snapshot.capabilityManifestHash.count == 64)
        #expect(snapshot.maxOutputCharacters == 48)
        #expect(!String(decoding: data, as: UTF8.self).contains("Authorization"))
        #expect(!String(decoding: data, as: UTF8.self).contains("apiKey"))
    }

    @Test func fakeProviderRejectsToolsWithoutCapabilityAndAcceptsDeclaredTools() async throws {
        let tool = AgentToolDefinition(name: "echo", description: "echo", parameters: [:], required: [])
        let unsupported = Line4FakeProvider(capabilities: [.streaming])
        do {
            _ = try await unsupported.sendMessage(messages: [], systemPrompt: nil, tools: [tool], maxTokens: 8, temperature: nil)
            Issue.record("a provider without tools capability unexpectedly accepted a tool request")
        } catch let error as LLMError {
            guard case .unsupportedCapability(.tools) = error else {
                Issue.record("unexpected provider error: \(error)")
                return
            }
        }

        let supported = Line4FakeProvider(capabilities: [.tools])
        _ = try await supported.sendMessage(messages: [], systemPrompt: nil, tools: [tool], maxTokens: 8, temperature: nil)
        #expect(supported.receivedToolNames == ["echo"])
    }

    @Test func mcpDeclarationDoesNotGrantExecutionPermission() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Line4MCP-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = MCPServerManager(fileURL: directory.appendingPathComponent("mcps.json"))
        let fake = MCPServer(id: "fake", name: "Fake", type: .http, url: "http://127.0.0.1:1")
        try manager.addServer(fake)
        try manager.authorizeServer(id: fake.id)
        try manager.authorizeTool(serverID: fake.id, toolName: "echo")

        let registry = MCPToolRegistry(manager: manager, clientFactory: { server in
            MCPClient(server: server, transport: Line4FakeMCPTransport(output: "offline output"))
        }, authorization: .denyAll)
        let declared = try await registry.mcpBoundTools()
        #expect(declared.map(\.fullName) == ["mcp_fake_echo"])

        do {
            _ = try await registry.callMCPTool(fullName: "mcp_fake_echo", arguments: nil)
            Issue.record("a discovered declaration unexpectedly granted execution permission")
        } catch MCPClientError.permissionDenied("mcp_fake_echo") {
            // Expected: declaration and permission are separate contracts.
        }
        registry.disconnectAll()
    }

    @Test func authorizedFakeMCPIsOfflineAndOutputLimited() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Line4MCP-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = MCPServerManager(fileURL: directory.appendingPathComponent("mcps.json"))
        let fake = MCPServer(id: "fake", name: "Fake", type: .http, url: "http://127.0.0.1:1")
        try manager.addServer(fake)
        try manager.authorizeServer(id: fake.id)
        try manager.authorizeTool(serverID: fake.id, toolName: "echo")

        let registry = MCPToolRegistry(manager: manager, clientFactory: { server in
            MCPClient(
                server: server,
                transport: Line4FakeMCPTransport(output: String(repeating: "x", count: 80)),
                maxOutputCharacters: 12
            )
        }, authorization: .allowing(["mcp_fake_echo"]))

        let output = try await registry.callMCPTool(fullName: "mcp_fake_echo", arguments: nil)
        #expect(output.count <= 12)
        #expect(output.contains("truncated"))
        registry.disconnectAll()
    }
}
