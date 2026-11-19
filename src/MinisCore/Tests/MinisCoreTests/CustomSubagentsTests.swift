import Foundation
import Testing

@testable import MinisCore

@Suite("自定义子智能体（.claude/agents）")
struct CustomSubagentsTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CustomSubagentsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test("读取 frontmatter，Claude Code 工具名换成本 App 工具名，项目覆盖用户")
    func loadsAndMapsTools() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let project = root.appendingPathComponent("project")
        try write("---\nname: reviewer\ndescription: 用户版\n---\n用户角色", home
            .appendingPathComponent(".claude/agents/reviewer.md"))
        try write("---\nname: reviewer\ndescription: 审查\ntools: Read, Grep, Glob\nmodel: sonnet\n---\n只审查，不改文件",
                  project.appendingPathComponent(".claude/agents/reviewer.md"))
        let agents = CustomSubagentLoader.load(projectRoot: project, homeDirectory: home)
        let reviewer = try #require(agents.first)
        #expect(agents.count == 1)
        #expect(reviewer.source == .project)
        #expect(reviewer.toolNames == ["file_read", "file_grep", "file_glob"])
        #expect(reviewer.prompt == "只审查，不改文件")
    }

    @Test("tools 键留空等于省略（继承全部）；写了值却一个都对不上才是没有工具")
    func emptyToolsKeyInheritsAll() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let project = root.appendingPathComponent("project")
        try write("---\nname: blank\ndescription: d\ntools:\n---\n正文",
                  project.appendingPathComponent(".claude/agents/blank.md"))
        try write("---\nname: bogus\ndescription: d\ntools: Nonexistent\n---\n正文",
                  project.appendingPathComponent(".claude/agents/bogus.md"))
        let agents = CustomSubagentLoader.load(projectRoot: project, homeDirectory: home)
        #expect(try #require(agents.first { $0.name == "blank" }).toolNames == nil)
        let bogus = try #require(agents.first { $0.name == "bogus" })
        #expect(bogus.toolNames == [])
        #expect(bogus.unmappedTools == ["Nonexistent"])
    }

    @Test("改写成内置子任务：工具只能收窄，找不到名字时拒绝")
    func rewriteNarrowsTools() throws {
        let definition = CustomSubagentDefinition(
            name: "reviewer", description: "", toolNames: ["file_read", "file_grep"],
            prompt: "只读审查", source: .project, filePath: "/x/reviewer.md")
        let input: [String: Any] = [
            "input_version": 1,
            "tasks": [[
                "id": "a", "title": "审", "instructions": "看看 a.swift",
                "agent": "custom:Reviewer", "allowed_tool_names": ["file_read", "file_write"],
            ]],
        ]
        let output = try CustomSubagentRewriter.rewrite(input, definitions: [definition])
        let task = try #require((output["tasks"] as? [[String: Any]])?.first)
        #expect(task["agent"] as? String == "builtin")
        #expect(task["allowed_tool_names"] as? [String] == ["file_read"])
        #expect((task["instructions"] as? String)?.contains("只读审查") == true)
        #expect(output["input_version"] as? Int == 2)

        var missing = input
        missing["tasks"] = [["id": "a", "title": "t", "instructions": "i", "agent": "custom:none"]]
        #expect(throws: ToolExecutorError.self) {
            _ = try CustomSubagentRewriter.rewrite(missing, definitions: [definition])
        }
    }

    @Test("F-6：工具说明列出可用自定义子智能体；格式错误和 tools 全错时派发给出明确提示")
    func directoryAndClearErrors() throws {
        let good = CustomSubagentDefinition(
            name: "reviewer", description: "只读审查代码", toolNames: ["file_read"],
            prompt: "p", source: .user, filePath: "/x/reviewer.md")
        let badTools = CustomSubagentDefinition(
            name: "bogus", description: "d", toolNames: [], prompt: "p", source: .user,
            filePath: "/x/bogus.md", unmappedTools: ["Nonexistent"])
        let unclosed = CustomSubagentDefinition(
            name: "broken", description: "d", toolNames: nil, prompt: "p", source: .user,
            filePath: "/x/broken.md", formatProblem: "开头有 --- 但没有结尾的 ---")

        let text = OrchestrationToolExecutor.makeDefinition(customSubagents: [good, badTools, unclosed]).description
        #expect(text.contains("custom:reviewer：只读审查代码"))
        #expect(!text.contains("custom:broken"))
        #expect(!OrchestrationToolExecutor.makeDefinition().description.contains("custom:reviewer"))

        func input(_ name: String) -> [String: Any] {
            ["input_version": 1, "tasks": [["id": "a", "title": "t", "instructions": "i", "agent": "custom:\(name)"]]]
        }
        for (definition, needle) in [(badTools, "Nonexistent"), (unclosed, "没有结尾的 ---")] {
            do {
                _ = try CustomSubagentRewriter.rewrite(input(definition.name), definitions: [definition])
                Issue.record("应当拒绝 \(definition.name)")
            } catch let ToolExecutorError.invalidParameter(message) {
                #expect(message.contains(needle))
            }
        }
    }

    @Test("F-6：开头 --- 没有闭合的文件被标出格式问题")
    func unclosedFrontmatterIsFlagged() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        try write("---\nname: broken\ndescription: d\n正文没有闭合", home.appendingPathComponent(".claude/agents/broken.md"))
        let agents = CustomSubagentLoader.load(projectRoot: nil, homeDirectory: home)
        #expect(try #require(agents.first).formatProblem != nil)
    }

    @Test("项目子智能体：首次与内容变化后未确认，派发被拒绝；确认后可用；用户级不需要确认")
    func projectSubagentNeedsContentConfirmation() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let project = root.appendingPathComponent("project")
        let file = project.appendingPathComponent(".claude/agents/helper.md")
        try write("---\nname: helper\ndescription: d\n---\n角色一", file)
        try write("---\nname: mine\ndescription: d\n---\n我自己的", home.appendingPathComponent(".claude/agents/mine.md"))
        let store = CustomSubagentConfirmationStore(url: root.appendingPathComponent("confirm.json"))
        func task(_ name: String) -> [String: Any] {
            ["input_version": 1, "tasks": [["id": "a", "title": "t", "instructions": "i", "agent": "custom:\(name)"]]]
        }

        var agents = CustomSubagentLoader.load(projectRoot: project, homeDirectory: home, confirmations: store)
        let helper = try #require(agents.first { $0.name == "helper" })
        #expect(helper.confirmation == .needsConfirmation)
        #expect(try #require(agents.first { $0.name == "mine" }).confirmation == .confirmed)
        #expect(throws: ToolExecutorError.self) {
            _ = try CustomSubagentRewriter.rewrite(task("helper"), definitions: agents)
        }

        try store.confirm(helper)
        agents = CustomSubagentLoader.load(projectRoot: project, homeDirectory: home, confirmations: store)
        #expect(agents.first { $0.name == "helper" }?.confirmation == .confirmed)
        _ = try CustomSubagentRewriter.rewrite(task("helper"), definitions: agents)

        try write("---\nname: helper\ndescription: d\n---\n角色二（被改过）", file)
        agents = CustomSubagentLoader.load(projectRoot: project, homeDirectory: home, confirmations: store)
        #expect(agents.first { $0.name == "helper" }?.confirmation == .changedSinceConfirmation)
        #expect(throws: ToolExecutorError.self) {
            _ = try CustomSubagentRewriter.rewrite(task("helper"), definitions: agents)
        }
    }
}

@Suite("浏览器会话不可用的提示")
struct BrowserSessionUnavailableMessageTests {
    @Test("F-8：会话已不在前台时的报错说浏览器，不再说授权目录")
    func messageMentionsBrowserNotAuthorizedDirectory() {
        let message = ToolExecutorError.browserSessionUnavailable.localizedDescription
        #expect(message.contains("浏览器"))
        #expect(!message.contains("授权目录"))
        #expect(ToolExecutorError.browserSessionUnavailable.displayDescription == message)
    }
}
