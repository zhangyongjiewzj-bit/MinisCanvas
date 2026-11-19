import Foundation
import Testing

@testable import MinisCore

private func makeCommandsRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CustomSlashCommandsTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func write(_ text: String, to root: URL, _ relative: String) throws {
    let url = root.appendingPathComponent(relative)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

@Suite("自定义斜杠命令（对齐 Claude Code）")
struct CustomSlashCommandsTests {
    @Test("子目录形成命名空间，frontmatter 提供描述和参数提示，项目覆盖用户，内置名不能被文件占用")
    func loadsNamespacedCommandsWithPrecedence() throws {
        let root = try makeCommandsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let project = root.appendingPathComponent("project")
        try write("用户版本 $ARGUMENTS", to: home, ".claude/commands/lint.md")
        try write("---\ndescription: \"提交代码\"\nargument-hint: [说明]\n---\n提交：$ARGUMENTS\n",
                  to: project, ".claude/commands/git/commit.md")
        try write("项目版本 $ARGUMENTS", to: project, ".claude/commands/lint.md")
        try write("占用 commit 与 review", to: project, ".claude/commands/review.md")
        try write("占用 commit", to: project, ".claude/commands/commit.md")
        try write("占用内置名", to: project, ".claude/commands/help.md")
        try write("占用 init", to: project, ".claude/commands/init.md")
        try write("隐藏", to: project, ".claude/commands/.hidden.md")

        let commands = CustomSlashCommandLoader.load(projectRoot: project, homeDirectory: home)
        let names = commands.map(\.name)
        // 内置提示词命令：init、commit、review（文件里同名的被忽略）。
        #expect(names == ["init", "commit", "review", "git:commit", "lint"])

        let commit = try #require(CustomSlashCommandLoader.command(named: "GIT:commit", in: commands))
        #expect(commit.description == "提交代码")
        #expect(commit.argumentHint == "[说明]")
        #expect(commit.source == .project)
        #expect(commit.template == "提交：$ARGUMENTS")
        let lint = try #require(CustomSlashCommandLoader.command(named: "lint", in: commands))
        #expect(lint.source == .project && lint.template == "项目版本 $ARGUMENTS")
        #expect(CustomSlashCommandLoader.command(named: "review", in: commands)?.source == .builtinPrompt)
        #expect(CustomSlashCommandLoader.command(named: "commit", in: commands)?.source == .builtinPrompt)
        // 内置 /init 的固定提示词优先，文件里的 init.md 被忽略。
        let initCommand = try #require(CustomSlashCommandLoader.command(named: "init", in: commands))
        #expect(initCommand.source == .builtinPrompt)
        #expect(initCommand.template.contains("CLAUDE.md"))
    }

    @Test("$ARGUMENTS 与 $1 $2 展开；参数里的占位符不会被二次替换；没有占位符时追加 ARGUMENTS")
    func expandsArguments() {
        let positional = CustomSlashCommand(
            name: "p", description: "", source: .project, template: "先 $2 再 $1，缺 $3 完，全部 $ARGUMENTS")
        #expect(positional.expand(arguments: "\"a b\" c")
            == "先 c 再 a b，缺  完，全部 \"a b\" c")

        let literal = CustomSlashCommand(name: "l", description: "", source: .user, template: "echo $ARGUMENTS")
        #expect(literal.expand(arguments: "$1 $ARGUMENTS") == "echo $1 $ARGUMENTS")

        let plain = CustomSlashCommand(name: "n", description: "", source: .user, template: "总结一下")
        #expect(plain.expand(arguments: "") == "总结一下")
        #expect(plain.expand(arguments: "第三章") == "总结一下\n\nARGUMENTS: 第三章")
    }

    @Test("!命令 展开成“请先运行”，@文件 只读授权根内的普通文本，敏感文件不读")
    func expandsShellDirectivesAndFiles() throws {
        let root = try makeCommandsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        try write("你好世界", to: project, "notes.txt")
        try write("API_KEY=abc", to: project, ".env")
        let real = project.resolvingSymlinksInPath()
        let command = CustomSlashCommand(
            name: "r", description: "", source: .project,
            template: "状态 !`git status` 看 @notes.txt 和 @.env 以及 @/etc/hosts")
        let text = command.expandForSending(arguments: "", projectRoot: real, allowedRoots: [real.path])
        #expect(text.contains("请先运行：`git status`"))
        #expect(text.contains("你好世界"))
        #expect(!text.contains("API_KEY=abc"))
        #expect(!text.contains("localhost"))
    }

    @Test("命令文件是指向目录外的符号链接时不加载")
    func symlinkedCommandOutsideDirectoryIsIgnored() throws {
        let root = try makeCommandsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        try write("外部内容", to: root, "outside/secret.md")
        try write("正常", to: project, ".claude/commands/ok.md")
        let commandsDir = project.appendingPathComponent(".claude/commands")
        try FileManager.default.createSymbolicLink(
            at: commandsDir.appendingPathComponent("leak.md"),
            withDestinationURL: root.appendingPathComponent("outside/secret.md"))
        let names = CustomSlashCommandLoader.load(
            projectRoot: project, homeDirectory: root.appendingPathComponent("nohome")).map(\.name)
        #expect(names.contains("ok"))
        #expect(!names.contains("leak"))
    }

    @Test("/init 的固定提示词要求写 CLAUDE.md 的四项内容")
    func initPromptCoversRequiredSections() throws {
        let command = try #require(CustomSlashCommandLoader.builtinPromptCommands.first { $0.name == "init" })
        for keyword in ["CLAUDE.md", "项目概述", "构建", "测试", "代码结构", "约定"] {
            #expect(command.template.contains(keyword), "提示词缺少：\(keyword)")
        }
    }
}
