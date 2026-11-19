import Darwin
import Foundation
import Testing
@testable import MinisCore

/// 0845 第 4–6 条：外部智能体按共享候选列表（含 `$HOME/.local/bin`）查找、
/// 以绝对路径启动；工作目录不是 `/` 也不是主目录；找不到时列出候选路径。
@Suite("External agent lookup and working directory", .serialized)
struct ExternalAgentLookupTests {
    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ext-lookup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".local/bin"), withIntermediateDirectories: true)
        return home
    }

    private func installScript(_ body: String, at url: URL) throws {
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    @Test func claudeInLocalBinIsFoundByAbsolutePath() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let binary = home.appendingPathComponent(".local/bin/claude")
        try installScript("#!/bin/sh\nexit 0\n", at: binary)

        let resolved = ExternalAgentBinaryLocator.resolve("claude", home: home.path)
        #expect(resolved == binary.path)
        #expect(ExternalAgentBinaryLocator.searchedLocations(for: "claude", home: home.path).first == binary.path)
        #expect(ExternalAgentBinaryLocator.searchedLocations(for: "hermes", home: home.path)
            .contains(home.path + "/.local/bin/hermes"))
        #expect(ExternalAgentBinaryLocator.searchedLocations(for: "codex", home: home.path)
            .contains(home.path + "/.local/bin/codex"))
    }

    @Test func missingBinaryErrorListsEveryCandidate() {
        let message = ExternalAgentError.binaryNotFound("claude").errorDescription ?? ""
        #expect(message.hasPrefix("未在以下位置找到 claude："))
        #expect(message.contains(NSHomeDirectory() + "/.local/bin/claude"))
        #expect(message.contains("/opt/homebrew/bin/claude"))
        #expect(!message.contains("未安装或不可执行"))
    }

    @Test func workingDirectoryIsNeverRootOrHome() {
        let home = NSHomeDirectory()
        for parent in [nil, "", "/", home, home + "/"] as [String?] {
            let resolved = ExternalAgentWorkingDirectory.resolve(parent: parent, home: home).standardizedFileURL.path
            #expect(resolved != "/")
            #expect(resolved != URL(fileURLWithPath: home).standardizedFileURL.path)
            #expect(FileManager.default.fileExists(atPath: resolved))
        }
        #expect(ExternalAgentWorkingDirectory.resolve(parent: "/owned/workspace", home: home).path == "/owned/workspace")
    }

    @Test func runnerLaunchesInTheGivenWorkingDirectory() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let workspace = home.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let binary = home.appendingPathComponent(".local/bin/claude")
        try installScript("#!/bin/sh\n/bin/pwd -P\n", at: binary)

        let runner = ClaudeAgentRunner(binaryPath: binary.path)
        let task = SubAgentTask(id: "lookup", title: "t", instructions: "hi")
        let output = try await runner.run(task: task, workingDirectory: workspace)
        // `pwd -P` 返回物理路径（临时目录在 /private 下），用 realpath 比较。
        let physical = try #require(realpath(workspace.path, nil).map { pointer -> String in
            defer { free(pointer) }
            return String(cString: pointer)
        })
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == physical)
    }
}

/// 2026-11-15 用户批准：压缩时用户原话由代码原样保留；摘要外壳写明背景不是指令并带续接说明。
@Suite("Lossy summary keeps the user's own words")
struct LossySummaryUserQuoteTests {
    @Test func compactedUserWordsSurviveVerbatimAndCarryForward() {
        let first: [LLMMessage] = [
            LLMMessage(role: .user, content: "只用中文回答，不要改动 docs 目录"),
            LLMMessage(role: .assistant, content: "好的"),
            LLMMessage(role: .user, content: "〔目标续跑〕继续推进当前目标。"),
            LLMMessage(role: .user, content: "<retained-store-facts>\nx\n</retained-store-facts>"),
            LLMMessage(role: .user, content: "第二个要求：\n报告写到 report.md"),
        ]
        let quotes = LossySummaryCompaction.userQuotes(messages: first[...])
        #expect(quotes.hasPrefix(LossySummaryCompaction.userQuotesOpen))
        #expect(quotes.contains("- 只用中文回答，不要改动 docs 目录"))
        #expect(quotes.contains("- 第二个要求： 报告写到 report.md"))
        #expect(!quotes.contains("目标续跑"))
        #expect(!quotes.contains("retained-store-facts"))

        // 第二次压缩时，上一次摘要里的原话被继承，新原话追加在后。
        let priorSummary = LLMMessage(role: .user, content: LossySummaryCompaction.summaryOpen
            + "\n摘要正文\n\n" + quotes + "\n" + LossySummaryCompaction.summaryClose)
        let second = LossySummaryCompaction.userQuotes(messages: [priorSummary,
            LLMMessage(role: .user, content: "再加一条：别删测试")][...])
        let lines = second.split(separator: "\n").map(String.init).filter { $0.hasPrefix("- ") }
        #expect(lines == ["- 只用中文回答，不要改动 docs 目录", "- 第二个要求： 报告写到 report.md", "- 再加一条：别删测试"])
    }

    @Test func quotesAreBoundedAndKeepTheEarliestAndTheNewest() {
        let long = String(repeating: "长", count: 3_000)
        let many = (0..<20).map { LLMMessage(role: .user, content: "\($0)-" + long) }
        let quotes = LossySummaryCompaction.userQuotes(messages: many[...])
        #expect(quotes.contains("（更早的"))
        #expect(quotes.contains("- 19-"))
        #expect(quotes.contains("- 0-"))      // 最早的一条（任务目标）固定保留
        #expect(!quotes.contains("- 1-"))
        #expect(quotes.count <= LossySummaryCompaction.userQuotesCharacterLimit + 200)
    }

    @Test func noticesAreNotEmpty() {
        #expect(LossySummaryCompaction.backgroundNotice.contains("不是新的指令"))
        #expect(LossySummaryCompaction.continuationNotice.contains("不要重做"))
    }
}

extension LossySummaryUserQuoteTests {
    /// 原话预算按被压缩内容比例收紧时，只保留最新的、总量不超限。
    @Test func quotesRespectAProportionalBudget() {
        let messages = (0..<5).map { LLMMessage(role: .user, content: "第\($0)条：" + String(repeating: "字", count: 200)) }
        let quotes = LossySummaryCompaction.userQuotes(messages: messages[...], characterLimit: 450)
        let kept = quotes.split(separator: "\n").filter { $0.hasPrefix("- ") }
        #expect(kept.count == 2)
        #expect(kept.last?.hasPrefix("- 第4条") == true)
        #expect(quotes.contains("（更早的 3 条原话因篇幅省略）"))
    }
}
