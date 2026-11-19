import Foundation
import Testing
@testable import MinisCore

// P1-1 工具白名单强制：Agent 调用工具时必须校验 call.name ∈ 已注册工具集。
// 未注册/伪造工具名在 dispatch 前即被拒绝，抛 ToolExecutorError.unknownTool。
struct ToolWhitelistTests {

    private func makeExecutor() -> BuiltinToolExecutor {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToolWhitelistTests-\\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return BuiltinToolExecutor(allowedRoot: root)
    }

    // MARK: - 未知工具拒绝

    @Test func unknownToolRejected() async throws {
        let executor = makeExecutor()
        await #expect(throws: ToolExecutorError.unknownTool("rm -rf /")) {
            _ = try await executor.execute(name: "rm -rf /", input: [:])
        }
    }

    @Test func unregisteredBuiltinToolRejected() async throws {
        // 即使名字与内置工具前缀相似，只要不在白名单即拒绝。
        let executor = makeExecutor()
        await #expect(throws: ToolExecutorError.unknownTool("file_read_extra")) {
            _ = try await executor.execute(name: "file_read_extra", input: ["path": "/tmp"])
        }
    }

    @Test func unregisteredMCPToolRejected() async throws {
        // mcp_* 前缀命中也不会被放行 —— 必须显式注册。
        let executor = makeExecutor()
        await #expect(throws: ToolExecutorError.unknownTool("mcp_server_tool")) {
            _ = try await executor.execute(name: "mcp_server_tool", input: [:])
        }
    }

    // MARK: - 已注册工具放行

    @Test func knownBuiltinToolAccepted() async throws {
        let executor = makeExecutor()
        let target = executor.allowedRoot.appendingPathComponent("whitelist.txt")
        let out = try await executor.execute(name: "file_write", input: ["path": target.path, "content": "ok"])
        #expect(out.contains("whitelist.txt"))
    }

    @Test func defaultWhitelistContainsAllBuiltins() {
        let names = BuiltinToolExecutor.defaultRegisteredToolNames()
        // P3-P1-05 重钉：web_search 已从预期内置清单中移除 —— 它未接入任何
        // 后端，不得出现在默认能力广播（GoalEnvelope/composer 由该集合派生）。
        // 其余已实现能力必须保留，新增的负向断言把「未宣告」钉为契约。
        for expected in ["shell_execute", "file_read", "file_write", "file_edit", "browser", "browser_use", "speech", "session_read"] {
            #expect(names.contains(expected), "默认白名单应包含 \\(expected)")
        }
        #expect(!names.contains("web_search"), "未接入能力不得进入默认白名单（P3-P1-05 诚实失败契约）")
    }

    @Test func defaultCatalogDoesNotAdvertiseWebFetch() {
        #expect(!AgentToolCatalog.makeTools().contains { $0.name == "web_fetch" })
    }

    @Test func backgroundShellCatalogDeclaresTaskParameters() throws {
        let tools = AgentToolCatalog.makeTools()
        let output = try #require(tools.first { $0.name == "shell_output" })
        let stop = try #require(tools.first { $0.name == "shell_stop" })
        #expect(output.parameters.mapValues(\.type) == ["task_id": .string, "offset": .integer])
        #expect(output.required == ["task_id"])
        #expect(stop.parameters.mapValues(\.type) == ["task_id": .string])
        #expect(stop.required == ["task_id"])
    }

    @Test func fileReadCatalogDeclaresOptionalPDFPagination() throws {
        let fileRead = try #require(AgentToolCatalog.makeTools().first { $0.name == "file_read" })
        #expect(fileRead.parameters.mapValues(\.type) == [
            "tool_title": .string, "path": .string, "offset": .integer, "lines": .integer,
            "direction": .string, "max_length": .integer, "page_start": .integer, "page_count": .integer,
            "as_images": .boolean
        ])
        #expect(fileRead.propertyOrdering == [
            "tool_title", "path", "offset", "lines", "direction", "max_length", "page_start", "page_count", "as_images"
        ])
        #expect(fileRead.required == ["tool_title", "path"])
    }

    @Test func browserCatalogIsReadOnlyWithoutExplicitGrant() throws {
        let browser = try #require(AgentToolCatalog.makeTools().first { $0.name == BrowserTool.toolName })
        #expect(browser.parameters["action"]?.enumValues == ["navigate", "read", "back", "screenshot"])
        #expect(!BrowserCapabilityGrant.readOnly.allows(action: "click"))
        #expect(!BrowserCapabilityGrant.readOnly.allows(action: "page_requested_write"))
    }

    @Test func browserWriteCatalogRequiresCapabilityAndApproval() throws {
        let missingApproval = BrowserCapabilityGrant(capability: BrowserCapabilityGrant.writeCapability)
        #expect(!missingApproval.permitsWriteActions)
        #expect(!missingApproval.allows(action: "type"))

        let grant = BrowserCapabilityGrant(
            capability: BrowserCapabilityGrant.writeCapability,
            approvalReceipt: "approval-1"
        )
        let browser = try #require(AgentToolCatalog.makeTools(browserGrant: grant, browserWriteActionsVisible: true).first { $0.name == BrowserTool.toolName })
        #expect(grant.permitsWriteActions)
        #expect(grant.allows(action: "click"))
        #expect(grant.allows(action: "type"))
        #expect(browser.parameters["action"]?.enumValues?.contains("click") == true)
        #expect(browser.parameters["action"]?.enumValues?.contains("type") == true)
        #expect(!grant.allows(action: "unknown"))
    }

    @Test func sessionReadWithoutManagerIsNotConfigured() async throws {
        let executor = makeExecutor()

        await #expect(throws: ToolExecutorError.toolNotConfigured("session_read")) {
            _ = try await executor.execute(
                name: "session_read",
                input: ["session_id": "session", "scope": "metadata"]
            )
        }
    }

    @Test func sessionReadUsesInjectedManager() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let manager = SessionManager(store: store, badgeStore: SessionBadgeStore(directory: directory))
        try store.updateSession(ChatSession(id: "readable", title: "可读", modelID: "gpt-5"))

        let executor = BuiltinToolExecutor(allowedRoot: directory, sessionManager: manager)
        let now = Date()
        let authorization = CrossSessionReadAuthorization.issue(
            currentConversationID: "readable",
            authorizedSessionID: "readable",
            turnID: 1,
            issuedAt: now,
            lifetime: 60
        )
        let output = try await executor.executeSessionRead(
            input: ["session_id": "readable", "scope": "metadata"],
            authorization: authorization,
            context: SessionReadExecutionContext(
                currentConversationID: "readable",
                turnID: 1
            ),
            now: now
        )

        #expect(output.contains("gpt-5"))
        #expect(output.contains("可读"))
    }

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToolWhitelistSessionRead-\\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - 注册工具后放行

    @Test func mcpToolRegisteredThenAccepted() async throws {
        let executor = makeExecutor()
        executor.registerToolNames(["mcp_server_tool"])
        #expect(executor.registeredToolNames.contains("mcp_server_tool"))
        // 不接真实 bridge，注册后走到 dispatch —— 会因未配置 bridge 抛
        // toolNotConfigured 而非 unknownTool，证明名字已过白名单闸门。
        await #expect(throws: ToolExecutorError.toolNotConfigured("mcp_server_tool")) {
            _ = try await executor.execute(name: "mcp_server_tool", input: [:])
        }
    }

    @Test func customWhitelistOverride() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToolWhitelistCustom-\\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // 显式传入白名单：只允许 file_read —— 内置 shell 应被拒绝。
        let executor = BuiltinToolExecutor(
            allowedRoot: root,
            registeredToolNames: ["file_read"]
        )
        await #expect(throws: ToolExecutorError.unknownTool("shell_execute")) {
            _ = try await executor.execute(name: "shell_execute", input: ["command": "echo hi"])
        }
    }
}
