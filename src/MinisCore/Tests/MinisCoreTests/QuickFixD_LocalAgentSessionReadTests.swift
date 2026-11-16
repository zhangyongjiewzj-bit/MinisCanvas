import Foundation
import Testing
@testable import MinisCore

/// 快档 D（用户 11/12）：读取本机 Codex / Claude Code 会话不需要挂载文件夹。
/// 约定的新符号（RED 阶段尚不存在，编译失败即 RED）：
///  - `PrivacySettings.allowLocalAgentSessionRead: Bool`，默认 true，旧 JSON 缺字段解码为 true。
///  - `BuiltinToolExecutor.init(... localAgentSessionHome: URL?, allowsLocalAgentSessionRead: Bool ...)`：
///    home 可注入（生产为真实 home）；开关对应上面的设置字段。
/// 夹具全部在临时目录内，不触碰真实 ~/.codex、~/.claude。
@Suite("QuickFixD local agent session read without mounting")
struct QuickFixD_LocalAgentSessionReadTests {
    private let optInHint = "允许读取本机 Codex / Claude Code 会话"

    private func makeExecutor(home: ExtFixture.Home, workspace: URL, allow: Bool,
                              mounted: [URL] = []) -> BuiltinToolExecutor {
        BuiltinToolExecutor(
            allowedRoot: workspace, deniedRoots: [],
            additionalAllowedRoots: mounted,
            localAgentSessionHome: home.url,
            allowsLocalAgentSessionRead: allow)
    }

    private func makeWorkspace() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qfd-workspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("开关开且未挂载：external_session_read 列出并读取 Codex 与 Claude Code 会话")
    func readsDefaultDirectoriesWithoutMount() async throws {
        let home = try ExtFixture.Home(); defer { home.remove() }
        let workspace = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: workspace) }
        let codexID = UUID().uuidString.lowercased()
        let claudeID = UUID().uuidString.lowercased()
        try ExtFixture.writeCodex(home, id: codexID, lines: [
            try ExtFixture.codexMeta(id: codexID), try ExtFixture.codexUser("codex-hello-qfd")])
        try ExtFixture.writeClaude(home, id: claudeID, lines: [
            try ExtFixture.claudeUser(session: claudeID, "claude-hello-qfd")])
        let executor = makeExecutor(home: home, workspace: workspace, allow: true)

        let listing = try await executor.execute(name: ExternalSessionToolNames.read, input: [:])
        #expect(listing.contains(codexID))
        #expect(listing.contains(claudeID))

        let codexPage = try await executor.execute(name: ExternalSessionToolNames.read,
            input: ["source": "codex", "session": codexID])
        #expect(codexPage.contains("codex-hello-qfd"))
        let claudePage = try await executor.execute(name: ExternalSessionToolNames.read,
            input: ["source": "claude_code", "session": claudeID])
        #expect(claudePage.contains("claude-hello-qfd"))
    }

    @Test("开关关且未挂载：仍报 no_authorized_root，文案指向设置里的开关")
    func disabledFallsBackToMountWithSettingsHint() async throws {
        let home = try ExtFixture.Home(); defer { home.remove() }
        let workspace = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: workspace) }
        let id = UUID().uuidString.lowercased()
        try ExtFixture.writeCodex(home, id: id, lines: [
            try ExtFixture.codexMeta(id: id), try ExtFixture.codexUser("hidden")])
        let executor = makeExecutor(home: home, workspace: workspace, allow: false)

        do {
            _ = try await executor.execute(name: ExternalSessionToolNames.read, input: [:])
            Issue.record("开关关闭且未挂载时不应读取成功")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            #expect(message.contains("no_authorized_root"))
            #expect(message.contains("设置→隐私"))
            #expect(message.contains(optInHint))
        }
    }

    @Test("开关关但已挂载会话目录：照旧可读（现状行为）")
    func disabledStillReadsMountedRoot() async throws {
        let home = try ExtFixture.Home(); defer { home.remove() }
        let workspace = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: workspace) }
        let id = UUID().uuidString.lowercased()
        try ExtFixture.writeCodex(home, id: id, lines: [
            try ExtFixture.codexMeta(id: id), try ExtFixture.codexUser("mounted-visible")])
        let executor = makeExecutor(home: home, workspace: workspace, allow: false, mounted: [home.codexRoot])
        let page = try await executor.execute(name: ExternalSessionToolNames.read,
            input: ["source": "codex", "session": id])
        #expect(page.contains("mounted-visible"))
    }

    @Test("默认会话目录不因此成为文件工具可访问目录")
    func fileToolsCannotReadDefaultSessionDirectories() async throws {
        let home = try ExtFixture.Home(); defer { home.remove() }
        let workspace = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: workspace) }
        let id = UUID().uuidString.lowercased()
        let file = try ExtFixture.writeCodex(home, id: id, lines: [
            try ExtFixture.codexMeta(id: id), try ExtFixture.codexUser("file-tool-must-not-see")])
        let executor = makeExecutor(home: home, workspace: workspace, allow: true)

        // 先证明外部会话工具确实能读到（否则下面的拒绝没有意义）。
        let page = try await executor.execute(name: ExternalSessionToolNames.read,
            input: ["source": "codex", "session": id])
        #expect(page.contains("file-tool-must-not-see"))

        for (tool, input) in [
            ("file_read", ["path": file.path]),
            ("file_write", ["path": file.deletingLastPathComponent().appendingPathComponent("x.txt").path,
                            "content": "x"]),
            ("file_glob", ["pattern": "*.jsonl", "path": home.codexRoot.path]),
            ("file_grep", ["pattern": "file-tool", "path": home.codexRoot.path])
        ] as [(String, [String: Any])] {
            do {
                let output = try await executor.execute(name: tool, input: input)
                Issue.record("\(tool) 不应能访问默认会话目录，实际返回：\(output.prefix(80))")
            } catch {
                // 期望被拒绝
            }
        }
    }

    @Test("external_session_send 无需挂载即可定位会话（确认卡可生成）")
    func sendLocatesSessionWithoutMount() async throws {
        let home = try ExtFixture.Home(); defer { home.remove() }
        let workspace = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: workspace) }
        let id = UUID().uuidString.lowercased()
        try ExtFixture.writeCodex(home, id: id, lines: [
            try ExtFixture.codexMeta(id: id, cwd: workspace.path), try ExtFixture.codexUser("target")])
        let executor = makeExecutor(home: home, workspace: workspace, allow: true)
        let summary = try await executor.externalSessionApprovalSummary(
            input: ["source": "codex", "session": id, "message": "please fix"])
        #expect(summary.contains(id))
    }

    @Test("send 在开关关且未挂载时无法定位会话")
    func sendRequiresMountWhenDisabled() async throws {
        let home = try ExtFixture.Home(); defer { home.remove() }
        let workspace = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: workspace) }
        let id = UUID().uuidString.lowercased()
        try ExtFixture.writeCodex(home, id: id, lines: [
            try ExtFixture.codexMeta(id: id), try ExtFixture.codexUser("target")])
        let executor = makeExecutor(home: home, workspace: workspace, allow: false)
        await #expect(throws: (any Error).self) {
            _ = try await executor.externalSessionApprovalSummary(
                input: ["source": "codex", "session": id, "message": "please fix"])
        }
    }

    @Test("send 审批策略不变：任何全局策略下仍逐次确认")
    func sendStaysAlwaysAsk() {
        for policy in [ApprovalPolicy.alwaysAsk, .riskOnlyAsk, .autoApprove] {
            #expect(ApprovalGate.policyOverrides(for: policy)[ExternalSessionToolNames.send] == .alwaysAsk)
        }
    }

    @Test("设置字段：默认开；旧 JSON 缺字段解码为开；显式关闭可往返")
    func settingsFieldDefaultsAndCompat() throws {
        #expect(PrivacySettings.default.allowLocalAgentSessionRead == true)
        let legacy = Data(#"{"redactEnvValues":true,"logLevel":"info","collectAnalytics":false,"mountedFolderPaths":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(PrivacySettings.self, from: legacy)
        #expect(decoded.allowLocalAgentSessionRead == true)

        var off = PrivacySettings.default
        off.allowLocalAgentSessionRead = false
        let roundTrip = try JSONDecoder().decode(PrivacySettings.self, from: JSONEncoder().encode(off))
        #expect(roundTrip.allowLocalAgentSessionRead == false)
    }

    @Test("工具说明不再要求必须挂载，改为默认可读并可在设置关闭")
    func toolDescriptionsNoLongerRequireMount() {
        let read = ExternalSessionReadTool.definition().description
        let send = ExternalSessionSendTool.definition().description
        #expect(!read.contains("available only after the user mounts"))
        #expect(!send.contains("mounted in settings"))
        #expect(read.contains(".codex/sessions") && read.contains(".claude/projects"))
        #expect(read.contains("Settings"))
        #expect(send.contains("Settings"))
    }
}
