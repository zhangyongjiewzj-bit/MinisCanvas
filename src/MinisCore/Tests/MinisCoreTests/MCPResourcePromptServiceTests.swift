import Foundation
import Testing
@testable import MinisCore

@Suite struct MCPResourcePromptServiceTests {
    private let prompt = MCPPromptInfo(
        name: "review code",
        description: "审查代码",
        arguments: [
            MCPPromptArgument(name: "file", required: true),
            MCPPromptArgument(name: "focus", required: false),
        ]
    )

    @Test func slashNameIsServerScopedAndSanitized() {
        let item = MCPPromptItem(serverID: "my.server", serverName: "我的服务器", info: prompt)
        #expect(item.slashName == "mcp__my_server__review_code")
        #expect(item.argumentHint == "<file> [focus]")
    }

    @Test func nonASCIIPromptNamesOfSameLengthGetDistinctStableSlashNames() {
        let a = MCPPromptItem(serverID: "srv", serverName: "服务", info: MCPPromptInfo(name: "代码审查", description: nil, arguments: []))
        let b = MCPPromptItem(serverID: "srv", serverName: "服务", info: MCPPromptInfo(name: "文档润色", description: nil, arguments: []))
        #expect(a.slashName != b.slashName)
        #expect(a.slashName == MCPPromptItem(serverID: "srv", serverName: "服务", info: a.info).slashName)
        #expect(a.slashName.hasPrefix("mcp__srv____"))
        #expect(a.slashName.allSatisfy { $0.isASCII })
    }

    @Test func promptArgumentsAcceptPositionalAndNamedValues() throws {
        let positional = try MCPResourcePromptService.promptArguments(for: prompt, argumentText: "a.swift 性能 和 安全")
        #expect(positional == ["file": "a.swift", "focus": "性能 和 安全"])
        let named = try MCPResourcePromptService.promptArguments(for: prompt, argumentText: "focus=速度 b.swift")
        #expect(named == ["file": "b.swift", "focus": "速度"])
    }

    @Test func missingRequiredArgumentIsRejectedWithItsName() {
        #expect(throws: MCPResourcePromptError.missingArgument("file")) {
            _ = try MCPResourcePromptService.promptArguments(for: prompt, argumentText: "")
        }
    }

    private struct ListFailureTransport: MCPTransport {
        let failing: Bool
        func start() async throws {}
        func notify(_ notification: MCPJSONRPCNotification) throws {}
        func stop() {}
        func send(_ request: MCPJSONRPCRequest) async throws -> MCPJSONRPCResponse {
            switch request.method {
            case "initialize":
                return MCPJSONRPCResponse(id: request.id, result: .object([
                    "protocolVersion": .string("2025-11-25"),
                    "capabilities": .object(["resources": .object([:]), "prompts": .object([:])])
                ]))
            case "resources/list":
                if failing { return MCPJSONRPCResponse(id: request.id, error: MCPJSONRPCError(code: -32000, message: "down")) }
                return MCPJSONRPCResponse(id: request.id, result: .object(["resources": .array([])]))
            case "prompts/list":
                if failing { return MCPJSONRPCResponse(id: request.id, error: MCPJSONRPCError(code: -32000, message: "down")) }
                return MCPJSONRPCResponse(id: request.id, result: .object(["prompts": .array([])]))
            default:
                return MCPJSONRPCResponse(id: request.id, error: MCPJSONRPCError(code: -32601, message: "no"))
            }
        }
    }

    private func authorizedService(failing: Bool) throws -> MCPResourcePromptService {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MCPListFail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manager = MCPServerManager(fileURL: directory.appendingPathComponent("mcps.json"))
        let server = MCPServer(id: "srv", name: "示例服务器", type: .http, url: "http://127.0.0.1:1")
        try manager.addServer(server)
        try manager.authorizeServer(id: server.id)
        return MCPResourcePromptService(manager: manager, clientFactory: {
            MCPClient(server: $0, transport: ListFailureTransport(failing: failing))
        })
    }

    @Test func listFailureIsReportedSeparatelyFromAnEmptyList() async throws {
        let failing = try authorizedService(failing: true)
        let failedResources = await failing.resourcesReport(matching: "")
        #expect(failedResources.items.isEmpty)
        #expect(failedResources.failedServers == ["示例服务器"])
        let failedPrompts = await failing.promptsReport()
        #expect(failedPrompts.failedServers == ["示例服务器"])

        let healthy = try authorizedService(failing: false)
        let emptyResources = await healthy.resourcesReport(matching: "")
        #expect(emptyResources.items.isEmpty)
        #expect(emptyResources.failedServers.isEmpty)
        let emptyPrompts = await healthy.promptsReport()
        #expect(emptyPrompts.failedServers.isEmpty)
    }

    @Test func boundedContentIsRedactedAndTruncated() {
        let long = String(repeating: "a", count: 100)
        let result = MCPResourcePromptService.bounded(long, limit: 10)
        #expect(result.hasPrefix("aaaaaaaaaa"))
        #expect(result.contains("已截断"))
    }
}
