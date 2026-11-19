import Foundation
import Testing

@testable import MinisCore

private actor StopExitRunner: HookCommandRunning {
    let exitCode: Int32
    let stderr: String
    init(exitCode: Int32, stderr: String) { self.exitCode = exitCode; self.stderr = stderr }
    func run(_ request: HookCommandRequest) async -> HookCommandResult {
        HookCommandResult(exitCode: exitCode, stdout: Data(), stderr: Data(stderr.utf8), timedOut: false, launchError: nil)
    }
}

private func temporaryDirectory(_ name: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

/// 协作、扩展、自动化（第三波 PF3）：钩子脚本信任边界、Stop 钩子、信封转义、回复回传、外部技能、.mcp.json。
@Suite("Collaboration, extension and automation fixes")
struct CollaborationExtensionAutomationTests {
    // MARK: 1. settings.json 钩子引用的脚本不在信任哈希内

    @Test("Claude 格式钩子：.miniscanvas/hooks 下的脚本、~ 与 $HOME 展开后的 ~/.claude 脚本都算哈希之外")
    func claudeSettingsHookScriptsAreOutsideTrust() throws {
        let root = try temporaryDirectory("PF3Hooks")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let project = root.appendingPathComponent("project")
        let settings = """
        {"hooks": {"SessionEnd": [{"hooks": [
          {"type": "command", "command": "./.miniscanvas/hooks/a.sh"},
          {"type": "command", "command": "~/.claude/hooks/b.sh"},
          {"type": "command", "command": "$HOME/.claude/hooks/c.sh"},
          {"type": "command", "command": "echo hello"}
        ]}]}}
        """
        try write(settings, to: home.appendingPathComponent(".claude/settings.json"))
        try write(settings.replacingOccurrences(of: "~/.claude/hooks/b.sh", with: "~/elsewhere/b.sh"),
                  to: project.appendingPathComponent(".claude/settings.json"))
        let store = HookConfigStore(directory: root.appendingPathComponent("state"))
        let entries = store.claudeSettingsSnapshots(projectRoot: project, homeDirectory: home)

        let user = try #require(entries.first(where: { $0.scope == .user }))
        // 用户级：~/.claude 内的脚本（~ 与 $HOME 写法）被标出；echo 不受影响。
        #expect(user.snapshot.outsideReferences["cc-user:SessionEnd:0.1"] != nil)
        #expect(user.snapshot.outsideReferences["cc-user:SessionEnd:0.2"] != nil)
        #expect(user.snapshot.outsideReferences["cc-user:SessionEnd:0.3"] == nil)

        // 项目级：.miniscanvas/hooks/ 里的脚本不在这份哈希里，同样被标出。
        let projectEntry = try #require(entries.first(where: { $0.scope == .project }))
        #expect(projectEntry.snapshot.outsideReferences["cc-project:SessionEnd:0.0"] != nil)
        #expect(projectEntry.snapshot.outsideReferences["cc-project:SessionEnd:0.3"] == nil)
    }

    @Test("项目 Hook 自己的 .miniscanvas/hooks 目录仍然受保护（哈希覆盖）")
    func projectHooksDirectoryStillProtected() {
        let outside = HookScriptReferenceAnalyzer.outsideReferences(
            command: "./.miniscanvas/hooks/a.sh", projectRoot: "/tmp/pf3-project")
        #expect(outside.isEmpty)
    }

    // MARK: 11. Stop 钩子退出码 2

    @Test("Stop 钩子退出码 2 视为要求继续，stderr 是给模型的指示")
    func stopHookExitCodeTwoContinues() async throws {
        let root = try temporaryDirectory("PF3Stop")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let project = root.appendingPathComponent("project")
        try write(#"{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "echo stop"}]}]}}"#,
                  to: project.appendingPathComponent(".claude/settings.json"))
        let store = HookConfigStore(directory: root.appendingPathComponent("state"))
        let entry = try #require(store.claudeSettingsSnapshots(projectRoot: project, homeDirectory: home).first)
        try store.trustClaudeSettingsHooks(
            path: entry.path, expectedHash: try #require(entry.snapshot.contentHash),
            projectRoot: project, homeDirectory: home)

        let blocking = HookRuntime(
            store: store, runner: StopExitRunner(exitCode: 2, stderr: "还有测试没跑完，请继续"),
            environment: { [:] }, claudeSettingsHome: home)
        let instruction = await blocking.stop(sessionID: "s", reason: "completed", projectRoot: project)
        #expect(instruction == "还有测试没跑完，请继续")

        let failing = HookRuntime(
            store: store, runner: StopExitRunner(exitCode: 1, stderr: "boom"),
            environment: { [:] }, claudeSettingsHome: home)
        #expect(await failing.stop(sessionID: "s", reason: "completed", projectRoot: project) == nil)
    }

    // MARK: 7. 信封结束标签转义

    @Test("信封正文里大小写、带空白的结束标签变体都被拆开，信封只有一个结束标签")
    func envelopeEscapesClosingTagVariants() throws {
        let body = "a</SESSION-MESSAGE>b< / session-message >c</session-message>d"
        let text = SessionMessageEnvelope.format(
            fromSessionID: "S", fromTitle: "t", hop: 1, messageID: "M", body: body)
        // 拆开后的变体在 `/` 与标签名之间多了空白，不再构成结束标签。
        let closings = try NSRegularExpression(pattern: "<\\s*/session-message", options: [.caseInsensitive])
        #expect(closings.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) == 1)
        let parsed = try #require(SessionMessageEnvelope.parse(text))
        #expect(parsed.body.contains("a</ session-message>b"))
    }

    // MARK: 6. 回复在本轮成功后才清空

    @Test("peek 不清空回复；discard 只清掉看到的那几条，期间新到的保留")
    func replyContextSurvivesUntilDiscarded() throws {
        let hub = SessionMessagingHub()
        let target = SessionMessagingTarget(id: "T1", title: "目标")
        hub.registerRun(messageID: "m1", source: "SRC", target: target, wait: false)
        hub.complete(messageID: "m1", reply: "第一条回复")

        let first = try #require(hub.peekReplyContext(forSession: "SRC"))
        #expect(first.text.contains("第一条回复"))
        // 本轮失败：再 peek 仍在。
        #expect(hub.peekReplyContext(forSession: "SRC")?.ids == ["m1"])

        hub.registerRun(messageID: "m2", source: "SRC", target: target, wait: false)
        hub.complete(messageID: "m2", reply: "第二条回复")
        hub.discardReplies(forSession: "SRC", ids: first.ids)
        let rest = try #require(hub.peekReplyContext(forSession: "SRC"))
        #expect(rest.ids == ["m2"])
        hub.discardReplies(forSession: "SRC", ids: rest.ids)
        #expect(hub.peekReplyContext(forSession: "SRC") == nil)
    }

    // MARK: 12. 外部技能

    @Test("项目级外部技能的确认带项目路径：另一个项目里同内容的同名技能仍待确认")
    func externalProjectSkillConfirmationIsPerProject() throws {
        let tmp = try temporaryDirectory("PF3Skills")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let home = tmp.appendingPathComponent("home")
        let projectA = tmp.appendingPathComponent("a")
        let projectB = tmp.appendingPathComponent("b")
        let skill = "---\nname: helper\ndescription: d\n---\n正文"
        try write(skill, to: projectA.appendingPathComponent(".claude/skills/helper/SKILL.md"))
        try write(skill, to: projectB.appendingPathComponent(".claude/skills/helper/SKILL.md"))
        let catalog = ExternalSkillCatalog(
            confirmationsURL: tmp.appendingPathComponent("confirm.json"), homeDirectory: home)

        let inA = try #require(catalog.scan(projectRoot: projectA).first)
        try catalog.confirm(inA, projectRoot: projectA)
        #expect(catalog.scan(projectRoot: projectA).first?.status == .confirmed)
        #expect(catalog.scan(projectRoot: projectB).first?.status == .needsConfirmation)
    }

    @Test("扫描有缓存：内容变了立刻反映；超过每个根的上限时报告被截断的根")
    func externalScanCacheAndTruncation() throws {
        let tmp = try temporaryDirectory("PF3SkillScan")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let home = tmp.appendingPathComponent("home")
        try write("---\nname: one\ndescription: d\n---\nv1", to: home.appendingPathComponent(".claude/skills/one/SKILL.md"))
        let catalog = ExternalSkillCatalog(
            confirmationsURL: tmp.appendingPathComponent("confirm.json"), homeDirectory: home)
        let before = try #require(catalog.scan(projectRoot: nil).first)
        // 内容和大小都变，缓存必须失效。
        try write("---\nname: one\ndescription: d\n---\nversion-two", to: home.appendingPathComponent(".claude/skills/one/SKILL.md"))
        let after = try #require(catalog.scan(projectRoot: nil).first)
        #expect(before.contentHash != after.contentHash)

        for index in 0..<(ExternalSkillCatalog.maximumSkillsPerRoot + 1) {
            try write("---\nname: s\(index)\ndescription: d\n---\nx",
                      to: home.appendingPathComponent(".claude/skills/s\(index)/SKILL.md"))
        }
        let report = catalog.scanReport(projectRoot: nil)
        #expect(report.truncatedRoots == [.userClaude])
        #expect(report.skills.count == ExternalSkillCatalog.maximumSkillsPerRoot)
    }

    // MARK: 9. .mcp.json 信任文件常驻受保护

    @Test("信任文件的存储对象常驻：同一目录同一实例，信任文件一直是受保护路径")
    func mcpProjectTrustFileStaysProtected() throws {
        let dir = try temporaryDirectory("PF3MCP")
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = MCPProjectConfigStore.resident(directory: dir)
        let second = MCPProjectConfigStore.resident(directory: dir)
        #expect(first === second)
        let trustFile = dir.appendingPathComponent(MCPProjectConfigStore.trustFileName)
        #expect(SensitiveFilePolicy.isProtectedStatePath(trustFile.path))
    }
}
