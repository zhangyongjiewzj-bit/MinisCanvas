import Foundation

// MARK: - 自定义斜杠命令（对齐 Claude Code）

/// 一条由 Markdown 文件定义的斜杠命令：文件正文是提示词模板，执行时展开成一条用户消息发送。
///
/// 来源：
/// - 项目：`<项目根>/.claude/commands/**/*.md`
/// - 用户：`~/.claude/commands/**/*.md`
/// - 内置提示词：/init 这类自带固定提示词的命令
///
/// 子目录形成命名空间：`.claude/commands/git/commit.md` 的命令名是 `git:commit`。
public struct CustomSlashCommand: Sendable, Equatable, Identifiable {
    public enum Source: String, Sendable, Equatable {
        case builtinPrompt
        case project
        case user
        /// MCP 服务器提供的提示词（/mcp__服务器__提示词），选中后调用 prompts/get 展开。
        case mcp

        public var displayName: String {
            switch self {
            case .builtinPrompt: "内置"
            case .project: "项目"
            case .user: "用户"
            case .mcp: "MCP"
            }
        }
    }

    /// 命令名（不含 "/"），命名空间用 ":" 连接。
    public let name: String
    public let description: String
    /// frontmatter 的 argument-hint，斜杠菜单里显示在命令名后面，例如 "[文件名]"。
    public let argumentHint: String?
    public let source: Source
    /// 去掉 frontmatter 之后的正文。
    public let template: String
    /// 定义文件的绝对路径；内置提示词为 nil。
    public let filePath: String?

    public var id: String { name.lowercased() }

    public init(
        name: String, description: String, argumentHint: String? = nil,
        source: Source, template: String, filePath: String? = nil
    ) {
        self.name = name
        self.description = description
        self.argumentHint = argumentHint
        self.source = source
        self.template = template
        self.filePath = filePath
    }

    /// 把用户输入的参数展开进模板，得到要发送的用户消息。
    ///
    /// - `$ARGUMENTS` 换成参数全文；
    /// - `$1`、`$2`…… 换成按空白切分的第 N 个参数（支持引号），缺失时为空；
    /// - 模板里没有 `$ARGUMENTS` 而用户给了参数时，在末尾追加 `ARGUMENTS: <参数>`（与 Claude Code 一致）。
    /// 替换是单遍的：参数文字里即使含有 `$1`、`$ARGUMENTS` 也不会被再次替换。
    public func expand(arguments rawArguments: String) -> String {
        let arguments = rawArguments.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = Self.splitArguments(arguments)
        var output = ""
        var usedAllArguments = false
        let chars = Array(template)
        var index = 0
        let marker = Array("$ARGUMENTS")
        while index < chars.count {
            let char = chars[index]
            guard char == "$" else {
                output.append(char)
                index += 1
                continue
            }
            if chars.count - index >= marker.count, Array(chars[index..<index + marker.count]) == marker {
                output += arguments
                usedAllArguments = true
                index += marker.count
                continue
            }
            var end = index + 1
            while end < chars.count, chars[end].isASCII, chars[end].isNumber { end += 1 }
            if end > index + 1, let position = Int(String(chars[index + 1..<end])), position >= 1 {
                if position <= words.count { output += words[position - 1] }
                index = end
                continue
            }
            output.append(char)
            index += 1
        }
        // 模板用了 $1 之类的位置参数时，参数已被消费，不再追加。
        if !usedAllArguments, !arguments.isEmpty, !Self.usesPositionalArguments(template) {
            output += (output.hasSuffix("\n") || output.isEmpty ? "" : "\n\n") + "ARGUMENTS: " + arguments
        }
        return output
    }

    /// 命令会用到参数：写了 argument-hint，或模板含 $ARGUMENTS / $1 这类占位符。
    public var acceptsArguments: Bool {
        argumentHint != nil || template.contains("$ARGUMENTS") || Self.usesPositionalArguments(template)
    }

    private static func usesPositionalArguments(_ template: String) -> Bool {
        let chars = Array(template)
        for (offset, char) in chars.enumerated() where char == "$" {
            if offset + 1 < chars.count, chars[offset + 1].isASCII, chars[offset + 1].isNumber,
               chars[offset + 1] != "0" { return true }
        }
        return false
    }

    /// 按空白切分，双引号或单引号内的空白保留，引号本身去掉。
    static func splitArguments(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var hasCurrent = false
        var quote: Character?
        for char in text {
            if let open = quote {
                if char == open { quote = nil } else { current.append(char) }
            } else if char == "\"" || char == "'" {
                quote = char
                hasCurrent = true
            } else if char.isWhitespace {
                if hasCurrent { words.append(current) }
                current = ""
                hasCurrent = false
            } else {
                current.append(char)
                hasCurrent = true
            }
        }
        if hasCurrent { words.append(current) }
        return words
    }
}

extension CustomSlashCommand {
    public static let maximumInlineFileBytes = 64 * 1024
    public static let maximumInlineFiles = 5

    /// 对齐 Claude Code 的命令写法，展开成要发送的用户消息：
    /// - ``!`命令` `` 不在命令展开时执行，而是写成"请先运行：`命令`"交给模型，走正常审批；
    /// - `@文件` 只在文件位于授权根内、不是敏感文件、是不超过 64KB 的文本时，把内容附在消息末尾；
    ///   其余的 @ 原样保留，不报错；
    /// - frontmatter 里的 model、allowed-tools 等字段被忽略，不报错。
    /// 内置提示词命令不做这两种展开。
    public func expandForSending(arguments: String, projectRoot: URL?, allowedRoots: [String]) -> String {
        let base = expand(arguments: arguments)
        guard source != .builtinPrompt else { return base }
        let withShell = Self.rewriteShellDirectives(base)
        return Self.inlineFiles(in: withShell, projectRoot: projectRoot, allowedRoots: allowedRoots)
    }

    static func rewriteShellDirectives(_ text: String) -> String {
        guard text.contains("!`"),
              let expression = try? NSRegularExpression(pattern: "!`([^`\\n]+)`") else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return expression.stringByReplacingMatches(
            in: text, range: range, withTemplate: "（请先运行：`$1`）")
    }

    static func inlineFiles(in text: String, projectRoot: URL?, allowedRoots: [String]) -> String {
        guard text.contains("@"),
              let expression = try? NSRegularExpression(pattern: "(^|[\\s(（])@([^\\s`'\",;)）]+)") else { return text }
        let nsText = text as NSString
        var attachments: [(name: String, content: String)] = []
        var seen = Set<String>()
        for match in expression.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            guard attachments.count < maximumInlineFiles else { break }
            var raw = nsText.substring(with: match.range(at: 2))
            while raw.hasSuffix(".") || raw.hasSuffix("。") { raw.removeLast() }
            guard !raw.isEmpty, seen.insert(raw).inserted,
                  let content = readInlineFile(raw, projectRoot: projectRoot, allowedRoots: allowedRoots)
            else { continue }
            attachments.append((raw, content))
        }
        guard !attachments.isEmpty else { return text }
        var output = text + "\n"
        for attachment in attachments {
            output += "\n文件 \(attachment.name) 的内容：\n```\n\(attachment.content)\n```\n"
        }
        return output
    }

    private static func readInlineFile(_ raw: String, projectRoot: URL?, allowedRoots: [String]) -> String? {
        var path = raw
        if path.hasPrefix("~/") {
            path = FileManager.default.homeDirectoryForCurrentUser.path + String(path.dropFirst(1))
        } else if !path.hasPrefix("/") {
            guard let projectRoot else { return nil }
            path = projectRoot.appendingPathComponent(path).path
        }
        guard let real = PolicyRuntimePathBoundary.canonicalPath(path),
              PolicyRuntimePathBoundary.isWithinRoots(path: real, roots: allowedRoots),
              !SensitiveFilePolicy.contains(real), !SensitiveFilePolicy.contains(path),
              !SensitiveFilePolicy.isCredentialPath(real) else { return nil }
        guard let values = try? URL(fileURLWithPath: real).resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= maximumInlineFileBytes,
              let data = try? Data(contentsOf: URL(fileURLWithPath: real)), !data.contains(0),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return ContentSecretRedactor.redact(text)
    }
}

/// 加载自定义斜杠命令。
public enum CustomSlashCommandLoader {
    public static let maximumCommands = 200
    public static let maximumFileBytes = 256 * 1024
    public static let maximumDepth = 4

    /// /init 的固定提示词：让模型分析当前项目，创建或更新项目根的 CLAUDE.md。
    public static let initPrompt = """
    请分析当前项目，在项目根目录创建 CLAUDE.md；如果已经有，就在保留有价值内容的基础上更新它。\
    CLAUDE.md 是给后续接手这个项目的 AI 编程助手看的工作说明，请先阅读项目里真实存在的文件\
    （README、构建配置、目录结构、关键源码、已有的 .cursorrules 或 .github/copilot-instructions.md 等）再动笔，\
    不要编造不存在的命令、目录或约定。内容包括：

    1. 项目概述：这个项目是做什么的，主要技术栈和运行环境。
    2. 构建、运行与测试命令：从构建配置和脚本里确认过的命令，包括如何只跑单个测试。
    3. 代码结构：需要读多个文件才能理解的整体架构、主要模块及其关系，不要罗列每个文件。
    4. 约定：命名、代码风格、提交与分支、不能碰的目录或文件，以及容易踩的坑。

    写得简洁、具体、可直接执行；不要写“写好测试”“提供有用的错误信息”这类通用建议。
    """

    /// /commit 的固定提示词：先看状态与差异，拟提交消息交用户确认，再提交（走命令审批）。
    public static let commitPrompt = """
    请帮我把当前工作区的改动提交到 git。步骤：

    1. 运行 `git status` 和 `git diff HEAD`（必要时加 `--stat`）看清改动；再运行 `git log -5 --oneline` 参考本仓库的提交消息风格。
    2. 只提交与本次任务相关的文件，不要提交看起来含密钥的文件（.env、密钥、凭据等）；发现这类文件先告诉我。
    3. 拟一条简洁、说明“为什么改”的提交消息，先发给我确认，不要直接提交。
    4. 我确认后，用 `git add <具体文件>` 暂存，再用 `git commit -m "<消息>"` 提交；多行消息写成多个 `-m "<段落>"`，或在双引号里直接换行，不要用 `$(cat <<EOF ...)` 这类命令替换。这些命令会走正常审批。
    5. 提交后运行 `git status` 确认结果，并如实汇报；不要推送，除非我另行要求。

    \(GitWorkflowPolicy.workflowInstructions)
    """

    /// /review 的固定提示词：只读审查当前改动，给出按严重程度排序的问题。
    public static let reviewPrompt = """
    请审查当前工作区的未提交改动（只读，不要修改任何文件）。步骤：

    1. 如果消息末尾带有 ARGUMENTS（PR 号或分支名）：PR 号用 `gh pr view <号>` 和 `gh pr diff <号>` 读取，分支名用 `git diff <分支>...HEAD` 读取，审查那部分改动；没有参数就运行 `git status` 和 `git diff HEAD` 看全部未提交改动。有新增的未跟踪文件，也用 file_read 读一遍。
    2. 逐个文件检查：逻辑错误与边界情况、错误处理、并发与资源释放、安全问题（密钥、注入、越权）、与周围代码风格是否一致、是否缺少对应测试。
    3. 按严重程度从高到低列出问题，每条写清：文件和行号、问题是什么、为什么是问题、建议怎么改。没有把握的写“不确定”，不要编造。
    4. 最后用两三句话总结整体质量和最需要先处理的事。没有发现问题就如实说没有。
    """

    /// 内置提示词命令。名字与文件命令重名时，内置的优先。
    public static var builtinPromptCommands: [CustomSlashCommand] {
        [
            CustomSlashCommand(
                name: "init",
                description: "分析当前项目，创建或更新项目根的 CLAUDE.md",
                source: .builtinPrompt,
                template: initPrompt
            ),
            CustomSlashCommand(
                name: "commit",
                description: "查看改动、拟提交消息并在确认后提交",
                source: .builtinPrompt,
                template: commitPrompt
            ),
            CustomSlashCommand(
                name: "review",
                description: "只读审查当前未提交的改动，或指定 PR 号、分支",
                argumentHint: "[PR 号或分支]",
                source: .builtinPrompt,
                template: reviewPrompt
            ),
        ]
    }

    /// 内置命令（含别名）的名字，文件命令不能占用。
    public static var defaultReservedNames: Set<String> {
        var names = Set<String>()
        for metadata in CommandRegistry.composerCommandMetadata {
            names.insert(metadata.id)
            for alias in metadata.aliases { names.insert(CommandDefinition.canonicalID(alias)) }
        }
        return names
    }

    /// 读取项目级与用户级命令，返回按名字排序的列表（内置提示词在前）。
    ///
    /// - 同名时项目覆盖用户；与 `reservedNames`（内置命令及别名，大小写不敏感）重名的文件命令被忽略；
    /// - 隐藏文件、非 .md 文件、过大的文件、超过深度或总数上限的部分被跳过；
    /// - `projectRoot` 为 nil 时只读用户级。
    public static func load(
        projectRoot: URL?,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        reservedNames: Set<String>? = nil
    ) -> [CustomSlashCommand] {
        let reserved = (reservedNames ?? defaultReservedNames).union(
            builtinPromptCommands.map { $0.id })
        var byID: [String: CustomSlashCommand] = [:]
        // 先放用户级，再让项目级覆盖。
        let userDirectory = homeDirectory.appendingPathComponent(".claude/commands", isDirectory: true)
        for command in scan(directory: userDirectory, source: .user) where !reserved.contains(command.id) {
            byID[command.id] = command
        }
        if let projectRoot {
            let projectDirectory = projectRoot.appendingPathComponent(".claude/commands", isDirectory: true)
            for command in scan(directory: projectDirectory, source: .project) where !reserved.contains(command.id) {
                byID[command.id] = command
            }
        }
        let files = byID.values.sorted { $0.id < $1.id }.prefix(maximumCommands)
        return builtinPromptCommands + files
    }

    /// 按名字（不区分大小写）找命令。
    public static func command(named name: String, in commands: [CustomSlashCommand]) -> CustomSlashCommand? {
        let needle = CommandDefinition.canonicalID(name)
        return commands.first { $0.id == needle }
    }

    private static func scan(directory: URL, source: CustomSlashCommand.Source) -> [CustomSlashCommand] {
        let root = directory.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return [] }
        var found: [CustomSlashCommand] = []
        // 命令文件是符号链接时按真实路径检查：必须仍在命令目录内，且不是敏感文件，
        // 否则链接到 ~/.ssh 之类的文件会把内容当提示词发给模型。
        let realRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        var pending: [(url: URL, namespace: [String], depth: Int)] = [(root, [], 0)]
        while let item = pending.popLast() {
            guard item.depth <= maximumDepth,
                  let names = try? FileManager.default.contentsOfDirectory(atPath: item.url.path) else { continue }
            for name in names.sorted() where !name.hasPrefix(".") {
                let url = item.url.appendingPathComponent(name)
                let realURL = url.resolvingSymlinksInPath().standardizedFileURL
                guard let values = try? realURL.resourceValues(
                    forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]) else { continue }
                if values.isDirectory == true {
                    pending.append((url, item.namespace + [name], item.depth + 1))
                    continue
                }
                guard realURL.path.hasPrefix(realRoot + "/"),
                      !SensitiveFilePolicy.contains(realURL.path),
                      !SensitiveFilePolicy.isCredentialPath(realURL.path) else { continue }
                guard values.isRegularFile == true, name.lowercased().hasSuffix(".md"),
                      let size = values.fileSize, size <= maximumFileBytes,
                      let data = try? Data(contentsOf: realURL),
                      let text = String(data: data, encoding: .utf8) else { continue }
                let stem = String(name.dropLast(3))
                guard !stem.isEmpty else { continue }
                let commandName = (item.namespace + [stem]).joined(separator: ":")
                guard isValidName(commandName) else { continue }
                let parsed = parseFrontmatter(text)
                let body = parsed.body.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { continue }
                found.append(CustomSlashCommand(
                    name: commandName,
                    description: parsed.fields["description"] ?? firstLine(of: body),
                    argumentHint: parsed.fields["argument-hint"],
                    source: source,
                    template: body,
                    filePath: url.standardizedFileURL.path
                ))
            }
        }
        return found
    }

    /// 命令名只允许字母、数字、中文、`-`、`_`、`.` 和命名空间分隔符 ":"，不含空白与斜杠。
    static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64 else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || "-_.:".contains($0) }
    }

    private static func firstLine(of body: String) -> String {
        let line = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces))
        return trimmed.count > 80 ? String(trimmed.prefix(80)) + "…" : trimmed
    }

    /// 最小 frontmatter 解析：开头 `---` 到下一个 `---` 之间的 `key: value` 行。
    static func parseFrontmatter(_ text: String) -> (fields: [String: String], body: String) {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.first == "\u{FEFF}---" { lines[0] = "---" }
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let close = lines.dropFirst().firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "---"
              }) else { return ([:], text) }
        var fields: [String: String] = [:]
        let header = Array(lines[1..<close])
        var index = 0
        while index < header.count {
            let line = header[index]
            index += 1
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, let last = value.last,
               (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                value = String(value.dropFirst().dropLast())
            }
            // `key:` 后面跟 YAML 块列表（`- a`、`- b`）：合成逗号分隔的值，和行内写法一致。
            if value.isEmpty, !key.isEmpty, !key.hasPrefix("-") {
                var items: [String] = []
                while index < header.count {
                    let next = header[index].trimmingCharacters(in: .whitespaces)
                    guard next == "-" || next.hasPrefix("- ") else { break }
                    let item = next.dropFirst().trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
                    if !item.isEmpty { items.append(item) }
                    index += 1
                }
                value = items.joined(separator: ", ")
            }
            if !key.isEmpty, !value.isEmpty { fields[key] = value }
        }
        return (fields, lines[(close + 1)...].joined(separator: "\n"))
    }
}
