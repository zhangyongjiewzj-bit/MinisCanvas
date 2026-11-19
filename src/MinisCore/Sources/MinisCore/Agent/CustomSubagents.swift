import CryptoKit
import Foundation

// MARK: - 自定义子智能体（对齐 Claude Code：.claude/agents/*.md）

/// 一个由 Markdown 文件定义的子智能体：frontmatter 提供名字、描述和工具范围，正文是它的角色设定。
/// 它不是新的执行体：派发时被改写成普通内置子任务（角色设定拼进指令，工具范围只收窄不放宽），
/// 审批、模式、目录授权仍完全沿用父会话。
public struct CustomSubagentDefinition: Sendable, Equatable, Identifiable {
    public var id: String { filePath }

    public enum Source: String, Sendable, Equatable {
        case project
        case user
    }

    public let name: String
    public let description: String
    /// 已换成本 App 工具名的工具范围；nil 表示未写 tools，继承父已授权工具。
    public let toolNames: [String]?
    public let prompt: String
    public let source: Source
    public let filePath: String
    /// frontmatter 的 model 字段原文。本 App 的子任务不按它换模型（字段被忽略，只供展示）。
    public let model: String?
    /// tools 里对不上本 App 工具、被丢弃的名字。
    public let unmappedTools: [String]
    /// 整个文件内容的 SHA-256（项目级定义的确认依据）。
    public let contentHash: String
    /// 项目级定义是否已被用户确认当前内容；用户级与没有确认记录库时视为已确认。
    public let confirmation: Confirmation
    /// 确认记录里的键（仅项目级定义有）。
    public let confirmationKey: String?
    /// 文件格式问题（例如开头 `---` 没有闭合）。有值时不能派发，派发会把这句话原样告诉模型。
    public let formatProblem: String?

    public enum Confirmation: String, Sendable, Equatable {
        case confirmed
        /// 首次出现，还没有确认记录。
        case needsConfirmation
        /// 以前确认过，但文件内容变了。
        case changedSinceConfirmation
    }

    public init(name: String, description: String, toolNames: [String]?, prompt: String,
                source: Source, filePath: String, model: String? = nil, unmappedTools: [String] = [],
                contentHash: String = "", confirmation: Confirmation = .confirmed,
                confirmationKey: String? = nil, formatProblem: String? = nil) {
        self.formatProblem = formatProblem
        self.contentHash = contentHash
        self.confirmation = confirmation
        self.confirmationKey = confirmationKey
        self.model = model
        self.unmappedTools = unmappedTools
        self.name = name
        self.description = description
        self.toolNames = toolNames
        self.prompt = prompt
        self.source = source
        self.filePath = filePath
    }
}

public enum CustomSubagentLoader {
    public static let maximumAgents = 50
    public static let maximumFileBytes = 64 * 1024

    /// Claude Code 工具名 -> 本 App 工具名。已经是本 App 工具名的原样保留。
    static let claudeToolMap: [String: [String]] = [
        "Read": ["file_read"], "Write": ["file_write"], "Edit": ["file_edit"],
        "MultiEdit": ["file_edit"], "Grep": ["file_grep"], "Glob": ["file_glob"],
        "Bash": ["shell_execute"], "WebFetch": ["web_fetch"],
    ]

    /// 读取用户级 `~/.claude/agents` 与项目级 `<项目根>/.claude/agents`；同名时项目覆盖用户。
    /// 调用方只应在项目根已被用户信任时传入 `projectRoot`（"项目内需信任"），否则传 nil。
    ///
    /// 项目级定义（项目里的文件，可能是别人放进来的）要用户确认当前内容后才可用：传入 `confirmations` 时，
    /// 首次出现和内容变化后的项目级定义标为未确认，派发会被拒绝并提示去确认；用户级是用户自己的文件，不需要确认。
    /// 不传 `confirmations`（测试、没有安装确认库）时不做确认检查。
    public static func load(
        projectRoot: URL?,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        confirmations: CustomSubagentConfirmationStore? = nil
    ) -> [CustomSubagentDefinition] {
        var byName: [String: CustomSubagentDefinition] = [:]
        let userDirectory = homeDirectory.appendingPathComponent(".claude/agents", isDirectory: true)
        for item in scan(directory: userDirectory, source: .user, projectPath: nil, confirmations: nil) {
            byName[item.name.lowercased()] = item
        }
        if let projectRoot {
            let directory = projectRoot.appendingPathComponent(".claude/agents", isDirectory: true)
            for item in scan(directory: directory, source: .project,
                             projectPath: projectRoot.standardizedFileURL.path, confirmations: confirmations) {
                byName[item.name.lowercased()] = item
            }
        }
        return byName.values.sorted { $0.name < $1.name }.prefix(maximumAgents).map { $0 }
    }

    private static func scan(
        directory: URL, source: CustomSubagentDefinition.Source,
        projectPath: String?, confirmations: CustomSubagentConfirmationStore?
    ) -> [CustomSubagentDefinition] {
        let root = directory.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        let realRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        var found: [CustomSubagentDefinition] = []
        for fileName in names.sorted() where !fileName.hasPrefix(".") && fileName.lowercased().hasSuffix(".md") {
            let real = root.appendingPathComponent(fileName).resolvingSymlinksInPath().standardizedFileURL
            guard real.path.hasPrefix(realRoot + "/"), !SensitiveFilePolicy.contains(real.path),
                  let values = try? real.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, let size = values.fileSize, size <= maximumFileBytes,
                  let data = try? Data(contentsOf: real), let text = String(data: data, encoding: .utf8)
            else { continue }
            let parsed = CustomSlashCommandLoader.parseFrontmatter(text)
            let prompt = parsed.body.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackName = String(fileName.dropLast(3))
            let name = parsed.fields["name"] ?? fallbackName
            guard !prompt.isEmpty, CustomSlashCommandLoader.isValidName(name), !name.contains(":") else { continue }
            // 对齐 Claude Code：省略或留空 tools = 继承全部工具；只有写了非空值却一个都对不上才是"没有工具"（mapTools 处理）。
            let toolsRaw = parsed.fields["tools"]
            let toolNames: [String]? = toolsRaw.flatMap(mapTools)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            var confirmation = CustomSubagentDefinition.Confirmation.confirmed
            var confirmationKey: String?
            if source == .project, let projectPath, let confirmations {
                let key = CustomSubagentConfirmationStore.key(projectPath: projectPath, name: name)
                confirmationKey = key
                if let recorded = confirmations.confirmedHash(forKey: key) {
                    confirmation = recorded == hash ? .confirmed : .changedSinceConfirmation
                } else {
                    confirmation = .needsConfirmation
                }
            }
            found.append(CustomSubagentDefinition(
                name: name,
                description: parsed.fields["description"] ?? "",
                toolNames: toolNames,
                prompt: prompt, source: source,
                filePath: root.appendingPathComponent(fileName).path,
                model: parsed.fields["model"],
                unmappedTools: toolsRaw.map(unmappedToolNames) ?? [],
                contentHash: hash, confirmation: confirmation, confirmationKey: confirmationKey,
                formatProblem: hasUnclosedFrontmatter(text)
                    ? "文件 \(fileName) 开头有 --- 但没有结尾的 ---，请补上闭合的 ---，否则整个文件会被当成提示词"
                    : nil))
        }
        return found
    }

    /// "Read, Grep, Glob" 或 "[Read, Grep]"。写了 "*" 或空表示不收窄（nil）；
    /// 写了但一个都对不上时返回空数组：子任务没有任何工具，而不是意外放宽。
    static func mapTools(_ raw: String) -> [String]? {
        let items = toolItems(raw)
        guard !items.isEmpty, !items.contains("*") else { return nil }
        var result: [String] = []
        for item in items {
            for mapped in mappedNames(for: item) {
                if !result.contains(mapped) { result.append(mapped) }
            }
        }
        return result
    }

    /// tools 里对不上本 App 工具的名字（被丢弃），供调用方提示。
    static func unmappedToolNames(_ raw: String) -> [String] {
        toolItems(raw).filter { $0 != "*" && mappedNames(for: $0).isEmpty }
    }

    private static func toolItems(_ raw: String) -> [String] {
        let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[] \t"))
        return cleaned.split(separator: ",").map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
        }.filter { !$0.isEmpty }
    }

    /// 带参数范围的写法（如 `Bash(git status:*)`）不映射：映射成整个工具会放宽范围，所以作为“未对应”丢弃。
    private static func mappedNames(for item: String) -> [String] {
        claudeToolMap[item] ?? (item.hasPrefix("mcp") || item.contains("_") ? [item] : [])
    }

    /// 第一行是 `---`，但后面再没有闭合的 `---`。
    static func hasUnclosedFrontmatter(_ text: String) -> Bool {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.first == "\u{FEFF}---" { lines[0] = "---" }
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return false }
        return !lines.dropFirst().contains { $0.trimmingCharacters(in: .whitespaces) == "---" }
    }

    /// frontmatter（开头 `---` 到下一个 `---`）里是否写了这个键，哪怕值为空。
    static func frontmatterWritesKey(_ key: String, in text: String) -> Bool {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let close = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return false }
        return lines[1..<close].contains { line in
            guard let colon = line.firstIndex(of: ":") else { return false }
            return line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == key
        }
    }
}

/// 项目级自定义子智能体的确认记录：键是项目路径加名字，值是确认时整个文件的 SHA-256。
/// 和外部技能的确认一样：首次出现和内容变化后都要用户确认一次，确认记录文件在对象存活期间受保护，Agent 不能改写。
public final class CustomSubagentConfirmationStore: @unchecked Sendable {
    public enum StoreError: Error, Equatable, Sendable {
        case writeFailed
    }

    private let url: URL
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
        SensitiveFilePolicy.protectStatePath(url, isDirectory: false)
    }

    deinit {
        SensitiveFilePolicy.unprotectStatePath(url, isDirectory: false)
    }

    public static func key(projectPath: String, name: String) -> String {
        "project:\(projectPath):\(name.lowercased())"
    }

    public func confirmedHash(forKey key: String) -> String? {
        lock.withLock { read()[key] }
    }

    /// 确认 `definition` 的当前内容。
    public func confirm(_ definition: CustomSubagentDefinition) throws {
        guard let key = definition.confirmationKey else { return }
        try lock.withLock {
            var all = read()
            all[key] = definition.contentHash
            try save(all)
        }
    }

    public func revoke(_ definition: CustomSubagentDefinition) throws {
        guard let key = definition.confirmationKey else { return }
        try lock.withLock {
            var all = read()
            all.removeValue(forKey: key)
            try save(all)
        }
    }

    private func read() -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return decoded
    }

    private func save(_ values: [String: String]) throws {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(values).write(to: url, options: .atomic)
        } catch { throw StoreError.writeFailed }
    }
}

/// 写进 orchestrate 工具说明里的「可用自定义子智能体」目录，让模型知道有哪些、各做什么。
public enum CustomSubagentDirectory {
    public static let maxListed = 20
    public static let maxDescriptionCharacters = 160

    /// 只列出现在能派发的（格式正确、已确认）；没有则返回空串。
    public static func text(_ definitions: [CustomSubagentDefinition]) -> String {
        let usable = definitions.filter { $0.formatProblem == nil && $0.confirmation == .confirmed }
        guard !usable.isEmpty else { return "" }
        let lines = usable.prefix(maxListed).map { definition -> String in
            let summary = String(definition.description.replacingOccurrences(of: "\n", with: " ")
                .prefix(maxDescriptionCharacters))
            return "custom:\(definition.name)" + (summary.isEmpty ? "" : "：\(summary)")
        }
        return " Available custom sub-agents (agent field value: description): " + lines.joined(separator: "; ") + "."
    }
}

/// 把派发输入里 `agent: "custom:<名字>"` 的任务改写成普通内置子任务。
public enum CustomSubagentRewriter {
    public static let prefix = "custom:"

    /// - Returns: 改写后的输入；没有任何 custom 任务时原样返回。
    /// - Throws: 名字找不到时 `invalidParameter("agent")`。
    public static func rewrite(
        _ input: [String: Any], definitions: [CustomSubagentDefinition]
    ) throws -> [String: Any] {
        guard var tasks = input["tasks"] as? [[String: Any]] else { return input }
        var changed = false
        var narrowed = false
        for index in tasks.indices {
            guard let agent = tasks[index]["agent"] as? String, agent.hasPrefix(prefix) else { continue }
            let name = String(agent.dropFirst(prefix.count)).lowercased()
            guard let definition = definitions.first(where: { $0.name.lowercased() == name }),
                  let instructions = tasks[index]["instructions"] as? String else {
                throw ToolExecutorError.invalidParameter("agent")
            }
            if let problem = definition.formatProblem {
                throw ToolExecutorError.invalidParameter("agent（自定义子智能体“\(definition.name)”：\(problem)）")
            }
            if let defined = definition.toolNames, defined.isEmpty {
                let written = definition.unmappedTools.joined(separator: "、")
                throw ToolExecutorError.invalidParameter(
                    "agent（自定义子智能体“\(definition.name)”的 tools 写了“\(written)”，没有一个能对应本应用的工具；请改文件 \(definition.filePath)，例如 Read、Grep、Glob、Bash，或删掉 tools 一行让它继承全部工具）")
            }
            if definition.confirmation != .confirmed {
                let reason = definition.confirmation == .changedSinceConfirmation ? "内容有变化，需要重新确认" : "还没有确认"
                throw ToolExecutorError.invalidParameter(
                    "agent（项目子智能体“\(definition.name)”\(reason)，请到 设置 › 技能 › 项目子智能体 确认后再使用）")
            }
            tasks[index]["agent"] = "builtin"
            tasks[index]["instructions"] = "你是自定义子智能体“\(definition.name)”，按下面的角色设定工作：\n\n"
                + definition.prompt + "\n\n——以下是本次任务——\n" + instructions
            if let defined = definition.toolNames {
                // 只能收窄：任务自己已经写了工具范围时取交集。
                if let existing = tasks[index]["allowed_tool_names"] as? [String] {
                    tasks[index]["allowed_tool_names"] = existing.filter { defined.contains($0) }
                } else {
                    tasks[index]["allowed_tool_names"] = defined
                }
                narrowed = true
            }
            changed = true
        }
        guard changed else { return input }
        var output = input
        output["tasks"] = tasks
        // 工具范围只有 V2 请求才支持；改成 V2 不会放宽任何权限。
        if narrowed { output["input_version"] = OrchestrateRequestV1.latestInputVersion }
        return output
    }
}

private final class CustomSubagentProviderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (@Sendable () async -> [CustomSubagentDefinition])?

    var value: (@Sendable () async -> [CustomSubagentDefinition])? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

/// App 安装的自定义子智能体来源（按当前会话的项目信任状态读取）。没有安装时没有自定义子智能体。
public enum CustomSubagentCatalog {
    private static let box = CustomSubagentProviderBox()

    public static func install(_ provider: (@Sendable () async -> [CustomSubagentDefinition])?) {
        box.value = provider
    }

    public static func current() async -> [CustomSubagentDefinition] {
        await box.value?() ?? []
    }
}
