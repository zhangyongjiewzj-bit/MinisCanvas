import Foundation

/// 从 JSON 文本导入 MCP 服务器配置（Claude Code / Claude Desktop 通用写法）。
///
/// 支持：
/// - `{"mcpServers": {"名字": {...}}}`（也接受 `servers` 作为外层键）
/// - 只有 `{"名字": {...}}` 的内层对象，或缺少外层花括号的 `"名字": {...}` 片段
/// - 单个服务器对象 `{"command": "npx", "args": [...]}` / `{"type": "http", "url": "..."}`
///
/// 导入只产生待添加的服务器配置；是否授权由用户之后逐个决定（与手动添加一致）。
public struct MCPServerImportPreview: Equatable, Sendable {
    public struct Entry: Equatable, Sendable, Identifiable {
        public var id: String { sourceName }
        /// JSON 里的名字（键）。
        public let sourceName: String
        /// 可以导入时的服务器配置；不能导入时为 nil。
        public let server: MCPServer?
        /// 给用户看的一行摘要（不含密钥值）。
        public let summary: String
        /// 提示或不能导入的原因（中文，含下一步）。
        public let note: String?
    }

    public var entries: [Entry]
    /// 整段文本无法解析时的原因。
    public var parseError: String?

    public var importableServers: [MCPServer] { entries.compactMap(\.server) }
}

public enum MCPServerJSONImport {
    /// - Parameters:
    ///   - updatableIDs: 已存在、且来自同一份项目 .mcp.json 的服务器 id；这些重名不跳过，
    ///     而是作为“更新”导入。用户自己添加的同名服务器不在其中，仍然跳过。
    ///   - projectRoot: 项目 .mcp.json 的项目根。给了才展开变量并把本地服务器的工作目录设为项目根。
    public static func preview(_ text: String, existingIDs: Set<String>,
                               updatableIDs: Set<String> = [], projectRoot: String? = nil) -> MCPServerImportPreview {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return MCPServerImportPreview(entries: [], parseError: nil) }
        guard let root = parseJSONObject(trimmed) ?? parseJSONObject("{" + trimmed + "}") else {
            return MCPServerImportPreview(entries: [], parseError: "不是有效的 JSON，请粘贴完整的配置，例如 {\"mcpServers\": {…}}。")
        }

        var table: [(String, [String: Any])] = []
        if let wrapped = (root["mcpServers"] ?? root["servers"]) as? [String: Any] {
            table = wrapped.keys.sorted().compactMap { key -> (String, [String: Any])? in
                guard let config = wrapped[key] as? [String: Any] else { return nil }
                return (key, config)
            }
        } else if root["command"] != nil || root["url"] != nil {
            table = [(suggestedName(for: root), root)]
        } else {
            table = root.keys.sorted().compactMap { key -> (String, [String: Any])? in
                guard let config = root[key] as? [String: Any],
                      config["command"] != nil || config["url"] != nil else { return nil }
                return (key, config)
            }
        }
        guard !table.isEmpty else {
            return MCPServerImportPreview(entries: [], parseError: "没有找到服务器配置。需要包含 mcpServers，或带 command / url 的服务器对象。")
        }

        let takenIDs = existingIDs.subtracting(updatableIDs)
        var usedIDs = takenIDs
        var entries: [MCPServerImportPreview.Entry] = []
        for (name, config) in table {
            entries.append(makeEntry(name: name, config: config, existingIDs: takenIDs,
                                     updatableIDs: updatableIDs.intersection(existingIDs),
                                     projectRoot: projectRoot, usedIDs: &usedIDs))
        }
        return MCPServerImportPreview(entries: entries, parseError: nil)
    }

    // MARK: - 单个服务器

    private static func makeEntry(name: String, config rawConfig: [String: Any], existingIDs: Set<String>,
                                  updatableIDs: Set<String>, projectRoot: String?,
                                  usedIDs: inout Set<String>) -> MCPServerImportPreview.Entry {
        var unresolved: [String] = []
        let config: [String: Any]
        if let projectRoot {
            config = expandingVariables(in: rawConfig, projectRoot: projectRoot, unresolved: &unresolved) as? [String: Any] ?? rawConfig
        } else {
            config = rawConfig
        }
        func finish(_ entry: MCPServerImportPreview.Entry) -> MCPServerImportPreview.Entry {
            var notes: [String] = []
            if let note = entry.note { notes.append(note) }
            if updatableIDs.contains(entry.server?.id ?? "") { notes.append("更新已有服务器") }
            let names = Set(unresolved).sorted()
            if !names.isEmpty, entry.server != nil {
                notes.append("含需要你填写的变量：" + names.joined(separator: "、")
                    + "（不会读取本机环境变量，批准后请在服务器设置里填写实际值）")
            }
            return .init(sourceName: entry.sourceName, server: entry.server, summary: entry.summary,
                         note: notes.isEmpty ? nil : notes.joined(separator: "；"))
        }
        return finish(makeRawEntry(name: name, config: config, existingIDs: existingIDs,
                                   projectRoot: projectRoot, usedIDs: &usedIDs))
    }

    /// 只展开 `${CLAUDE_PROJECT_DIR}`、`${HOME}` 和 `${变量:-默认值}` 的默认值；其它 `${变量}`
    /// 原样保留并记下名字。不读进程环境，避免恶意 .mcp.json 用 `${密钥}` 把密钥发给外部服务。
    static func expandingVariables(in value: Any, projectRoot: String, unresolved: inout [String]) -> Any {
        switch value {
        case let text as String:
            return expandVariables(in: text, projectRoot: projectRoot, unresolved: &unresolved)
        case let list as [Any]:
            return list.map { expandingVariables(in: $0, projectRoot: projectRoot, unresolved: &unresolved) }
        case let object as [String: Any]:
            return object.mapValues { expandingVariables(in: $0, projectRoot: projectRoot, unresolved: &unresolved) }
        default:
            return value
        }
    }

    static func expandVariables(in text: String, projectRoot: String, unresolved: inout [String]) -> String {
        guard text.contains("${") else { return text }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index...].hasPrefix("${"), let close = text[index...].firstIndex(of: "}") {
                let inner = String(text[text.index(index, offsetBy: 2)..<close])
                let name: String
                var fallback: String?
                if let range = inner.range(of: ":-") {
                    name = String(inner[..<range.lowerBound])
                    fallback = String(inner[range.upperBound...])
                } else {
                    name = inner
                }
                if name == "CLAUDE_PROJECT_DIR" {
                    result += projectRoot
                } else if name == "HOME" {
                    result += NSHomeDirectory()
                } else if let fallback {
                    result += fallback
                } else {
                    result += "${" + inner + "}"
                    unresolved.append(name)
                }
                index = text.index(after: close)
            } else {
                result.append(text[index])
                index = text.index(after: index)
            }
        }
        return result
    }

    private static func makeRawEntry(name: String, config: [String: Any], existingIDs: Set<String>,
                                     projectRoot: String?,
                                     usedIDs: inout Set<String>) -> MCPServerImportPreview.Entry {
        func failed(_ note: String) -> MCPServerImportPreview.Entry {
            .init(sourceName: name, server: nil, summary: "", note: note)
        }
        let typeText = (config["type"] as? String)?.lowercased()
        let command = (config["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlText = (config["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isRemote: Bool
        switch typeText {
        case "stdio"?: isRemote = false
        case "http"?, "sse"?, "streamable-http"?, "streamable_http"?, "streamablehttp"?: isRemote = true
        case nil: isRemote = (command ?? "").isEmpty && !(urlText ?? "").isEmpty
        default: return failed("不认识的类型「\(typeText ?? "")」。请使用 stdio、http 或 sse。")
        }

        let baseID = sanitizedID(name)
        var id = baseID
        if existingIDs.contains(id) {
            return failed("已存在标识为「\(id)」的服务器，已跳过。请先改名或删除旧的，再重新导入。")
        }
        var suffix = 2
        while usedIDs.contains(id) { id = "\(baseID)-\(suffix)"; suffix += 1 }
        usedIDs.insert(id)

        var notes: [String] = []
        if id != name { notes.append("标识改为「\(id)」") }

        var server = MCPServer(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? id : name)
        if (config["disabled"] as? Bool) == true || (config["enabled"] as? Bool) == false { server.enabled = false }
        if isRemote {
            guard let urlText, let url = URL(string: urlText), let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme), url.host != nil else {
                return failed("缺少有效的 url（需以 http:// 或 https:// 开头）。")
            }
            server.type = .http
            server.url = urlText
            if let headers = config["headers"] as? [String: Any] {
                for (key, value) in headers { server.headers[key] = stringValue(value) }
            }
            let headerNote = server.headers.isEmpty ? "" : " · 请求头 \(server.headers.count) 项"
            return .init(sourceName: name, server: server, summary: "http · \(urlText)\(headerNote)",
                         note: notes.isEmpty ? nil : notes.joined(separator: "；"))
        }
        guard let command, !command.isEmpty else {
            return failed("缺少 command（本地服务器）或 url（远程服务器）。")
        }
        server.type = .stdio
        server.command = command
        server.workingDirectory = projectRoot
        if let rawArgs = config["args"] {
            guard let list = rawArgs as? [Any] else { return failed("args 需要是字符串数组。") }
            server.args = list.map(stringValue)
        }
        if let env = config["env"] as? [String: Any] {
            for (key, value) in env { server.env[key] = stringValue(value) }
        }
        let envNote = server.env.isEmpty ? "" : " · 环境变量 \(server.env.count) 项"
        let line = ([command] + server.args).joined(separator: " ")
        return .init(sourceName: name, server: server, summary: "stdio · \(line)\(envNote)",
                     note: notes.isEmpty ? nil : notes.joined(separator: "；"))
    }

    // MARK: - 辅助

    private static func parseJSONObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return value as? [String: Any]
    }

    private static func stringValue(_ value: Any) -> String {
        switch value {
        case let text as String: return text
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        default: return "\(value)"
        }
    }

    /// 标识只保留 ASCII 字母、数字、下划线和连字符（它会出现在工具名里）。
    static func sanitizedID(_ name: String) -> String {
        let mapped = String(name.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.map { scalar -> Character in
            let v = scalar.value
            let ok = (48...57).contains(v) || (65...90).contains(v) || (97...122).contains(v) || v == 95 || v == 45
            return ok ? Character(scalar) : "-"
        })
        let cleaned = mapped.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return cleaned.isEmpty ? "server" : cleaned
    }

    private static func suggestedName(for config: [String: Any]) -> String {
        if let name = (config["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if let urlText = config["url"] as? String, let host = URL(string: urlText)?.host, !host.isEmpty {
            return host
        }
        if let args = config["args"] as? [Any],
           let package = args.compactMap({ $0 as? String }).first(where: { !$0.hasPrefix("-") }) {
            return String(package.split(separator: "/").last ?? Substring(package))
        }
        if let command = config["command"] as? String, !command.isEmpty {
            return URL(fileURLWithPath: command).lastPathComponent
        }
        return "server"
    }
}
