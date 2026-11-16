import Foundation
import Testing
@testable import MinisCore

// P3-P1-05 web_search 诚实失败契约（lane QODER-DEV-W5-WEBSEARCH-HONEST-085）。
// 未接入真实后端的能力必须：
// 1) 不出现在默认能力广播中（GoalEnvelope.allowedCapabilities 与 composer
//    能力面都由 defaultRegisteredToolNames() 派生）；
// 2) 一旦被调用即产生类型化错误（error-class），在 AgentLoop 中被记录为
//    is_error:true 的 tool_result，而不是返回会被当作成功的占位文本。
struct WebSearchHonestFailureTests {

    private func makeRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WebSearchHonestFailureTests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func defaultWhitelistDoesNotAdvertiseUnwiredWebSearch() throws {
        let names = BuiltinToolExecutor.defaultRegisteredToolNames()
        #expect(
            !names.contains("web_search"),
            "未接入的能力不得进入默认能力广播（policy Goal / composer 由该集合派生）"
        )
        // 真实内置能力不受影响（与本文件新增断言之外的既有白名单语义一致）。
        for implemented in [
            "shell_execute", "file_read", "file_write", "file_edit",
            "browser", "browser_use", "speech", "session_read",
        ] {
            #expect(names.contains(implemented), "默认白名单应包含已实现工具 \(implemented)")
        }
    }

    @Test func defaultExecutorRejectsWebSearchCallAsUnknownTool() async throws {
        let root = try makeRoot("reject")
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = BuiltinToolExecutor(allowedRoot: root)
        await #expect(throws: ToolExecutorError.unknownTool("web_search")) {
            _ = try await executor.execute(name: "web_search", input: ["query": "swift"])
        }
    }

    @Test func explicitlyRegisteredWebSearchFailsWithTypedException() async throws {
        // 兼容显式注册该名称的消费方：dispatch 必须走既有类型化失败路径
        // toolNotConfigured（与 session_read/browser/speech 未配置时同源），
        // 绝不返回 is_error:false 的说明文本。
        let root = try makeRoot("registered")
        defer { try? FileManager.default.removeItem(at: root) }
        var names = BuiltinToolExecutor.defaultRegisteredToolNames()
        names.insert("web_search")
        let executor = BuiltinToolExecutor(allowedRoot: root, registeredToolNames: names)
        await #expect(throws: ToolExecutorError.toolNotConfigured("web_search")) {
            _ = try await executor.execute(name: "web_search", input: ["query": "swift"])
        }
    }
}
