import Foundation
import Testing

@testable import MinisCore

private actor RecordingHookRunner: HookCommandRunning {
    private(set) var commands: [String] = []
    private(set) var timeouts: [TimeInterval] = []
    private(set) var events: [String] = []
    func run(_ request: HookCommandRequest) async -> HookCommandResult {
        commands.append(request.command)
        timeouts.append(request.timeout)
        if let object = try? JSONSerialization.jsonObject(with: request.stdin) as? [String: Any],
           let event = object["hook_event_name"] as? String {
            events.append(event)
        }
        return HookCommandResult(exitCode: 0, stdout: Data(), stderr: Data(), timedOut: false, launchError: nil)
    }
}

private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ClaudeSettingsHooksTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func writeFile(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

@Suite("钩子与 Claude Code 通用", .serialized)
struct ClaudeSettingsHooksTests {
    @Test("matcher 是正则，旧的 a|b 写法照常工作，CC 工具名 Bash 能匹配本 App 的 shell_execute")
    func matcherIsRegularExpression() {
        func hook(_ matcher: String?) -> HookDefinition {
            HookDefinition(id: "h", event: .preToolUse, matcher: matcher, command: "true")
        }
        #expect(hook("file_write | file_edit").matches(toolName: "file_edit"))
        #expect(hook("file_.*").matches(toolName: "file_grep"))
        #expect(!hook("file_.*").matches(toolName: "shell_execute"))
        #expect(!hook("file").matches(toolName: "file_write"))   // 整名匹配，不是子串
        #expect(hook("Edit|Write").matches(toolName: "file_write"))
        #expect(hook("Bash").matches(toolName: "shell_execute"))
        #expect(!hook("(").matches(toolName: "file_read"))         // 非法正则什么都不匹配
        #expect(hook("*").matches(toolName: "anything") && hook(nil).matches(toolName: nil))
    }

    @Test("默认超时 60 秒；新事件可以编解码")
    func defaultTimeoutAndNewEvents() throws {
        #expect(HookDefinition(event: .stop, command: "true").effectiveTimeout == 60)
        for name in ["Notification", "SubagentStop", "PreCompact", "SessionEnd"] {
            #expect(HookEvent(rawValue: name) != nil)
        }
        let data = Data(#"{"id":"a","event":"PreCompact","command":"true"}"#.utf8)
        #expect(try JSONDecoder().decode(HookDefinition.self, from: data).event == .preCompact)
    }

    @Test("引用 .claude/hooks/ 以外脚本的钩子即使信任了也不执行")
    func scriptOutsideHooksDirectoryNeverRuns() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let project = root.appendingPathComponent("project")
        try writeFile(
            #"{"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "./tools/hook.sh"}]}]}}"#,
            to: project.appendingPathComponent(".claude/settings.json"))
        try writeFile("#!/bin/sh\n", to: project.appendingPathComponent("tools/hook.sh"))
        let store = HookConfigStore(directory: root.appendingPathComponent("state"))
        let runner = RecordingHookRunner()
        let runtime = HookRuntime(store: store, runner: runner, environment: { [:] }, claudeSettingsHome: home)
        let entry = try #require(store.claudeSettingsSnapshots(projectRoot: project, homeDirectory: home).first)
        #expect(entry.snapshot.outsideReferences.values.first == ["tools/hook.sh"])
        try store.trustClaudeSettingsHooks(
            path: entry.path, expectedHash: try #require(entry.snapshot.contentHash),
            projectRoot: project, homeDirectory: home)
        await runtime.fire(.sessionStart, sessionID: "s", projectRoot: project)
        #expect(await runner.commands.isEmpty)
    }

    @Test("settings.json 的钩子只有在用户信任后才执行；改了命令要重新信任；.claude/hooks/ 内脚本入哈希、脚本改了要重新信任")
    func claudeSettingsHooksNeedTrust() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let project = root.appendingPathComponent("project")
        func settings(_ command: String) -> String {
            """
            {"permissions": {"allow": []},
             "hooks": {
               "SessionEnd": [{"hooks": [{"type": "command", "command": "\(command)", "timeout": 5}]}],
               "Notification": [{"hooks": [{"type": "prompt", "prompt": "ignored"}]}],
               "SessionStart": [{"hooks": [{"type": "command", "command": "./.claude/hooks/local.sh"}]}]
             }}
            """
        }
        try writeFile(settings("echo first"), to: project.appendingPathComponent(".claude/settings.json"))
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent(".claude/hooks"), withIntermediateDirectories: true)
        try writeFile("#!/bin/sh\n", to: project.appendingPathComponent(".claude/hooks/local.sh"))
        let store = HookConfigStore(directory: root.appendingPathComponent("state"))
        let runner = RecordingHookRunner()
        let runtime = HookRuntime(store: store, runner: runner, environment: { [:] }, claudeSettingsHome: home)

        // 未信任：不执行。
        await runtime.fire(.sessionEnd, sessionID: "s", projectRoot: project)
        #expect(await runner.commands.isEmpty)

        let entry = try #require(store.claudeSettingsSnapshots(projectRoot: project, homeDirectory: home).first)
        #expect(entry.scope == .project)
        #expect(entry.snapshot.hooks.count == 2)          // prompt 类型被跳过
        #expect(entry.snapshot.trust == .untrusted(changedSinceTrust: false))
        let hash = try #require(entry.snapshot.contentHash)
        try store.trustClaudeSettingsHooks(path: entry.path, expectedHash: hash,
                                           projectRoot: project, homeDirectory: home)

        await runtime.fire(.sessionEnd, sessionID: "s", projectRoot: project)
        #expect(await runner.commands == ["echo first"])
        #expect(await runner.timeouts == [5])
        // 引用项目内普通脚本的钩子：脚本已并入信任哈希，信任后执行；脚本一改就要重新信任。
        await runtime.fire(.sessionStart, sessionID: "s", projectRoot: project)
        #expect(await runner.commands == ["echo first", "./.claude/hooks/local.sh"])
        try writeFile("#!/bin/sh\necho changed\n", to: project.appendingPathComponent(".claude/hooks/local.sh"))
        await runtime.fire(.sessionStart, sessionID: "s", projectRoot: project)
        #expect(await runner.commands == ["echo first", "./.claude/hooks/local.sh"])
        let afterScriptEdit = try #require(store.claudeSettingsSnapshots(projectRoot: project, homeDirectory: home).first)
        #expect(afterScriptEdit.snapshot.trust == .untrusted(changedSinceTrust: true))
        #expect(afterScriptEdit.snapshot.protectedScriptFiles == [".claude/hooks/local.sh"])
        try writeFile("#!/bin/sh\n", to: project.appendingPathComponent(".claude/hooks/local.sh"))

        // 改了命令：信任失效。
        try writeFile(settings("echo second"), to: project.appendingPathComponent(".claude/settings.json"))
        await runtime.fire(.sessionEnd, sessionID: "s", projectRoot: project)
        // 命令改后不再执行：记录里仍只有此前那两次（echo first 与项目内脚本钩子）。
        #expect(await runner.commands == ["echo first", "./.claude/hooks/local.sh"])
        let changed = try #require(store.claudeSettingsSnapshots(projectRoot: project, homeDirectory: home).first)
        #expect(changed.snapshot.trust == .untrusted(changedSinceTrust: true))
    }
}
