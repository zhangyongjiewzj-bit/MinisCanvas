import Foundation
import MinisCore

/// The Settings form edits one canonical server. Existing environment/header
/// values never become form text; an untouched field remains in the record.
struct MCPHeaderEditRow: Identifiable {
    let id = UUID()
    var name: String
    /// Replacement input only; stored values never prefill a field.
    var value = ""
    var originalName: String?
}

struct MCPServerEditDraft {
    private let original: MCPServer?
    var id: String
    var name: String
    var type: MCPTransportType
    var command: String
    var argsText: String
    var url: String
    var enabled: Bool
    var envText = ""
    var headerRows: [MCPHeaderEditRow]
    /// 工具调用超时（秒）；留空使用默认值（10 分钟）。
    var callTimeoutText: String

    init(existing: MCPServer? = nil) {
        original = existing
        id = existing?.id ?? ""
        name = existing?.name ?? ""
        type = existing?.type ?? .stdio
        command = existing?.command ?? ""
        argsText = existing?.args.joined(separator: " ") ?? ""
        url = existing?.url ?? ""
        enabled = existing?.enabled ?? true
        headerRows = (existing?.headers.keys.sorted() ?? []).map {
            MCPHeaderEditRow(name: $0, originalName: $0)
        }
        callTimeoutText = existing?.callTimeoutSeconds.map(String.init) ?? ""
    }

    var isEditing: Bool { original != nil }

    private var hasValidIdentity: Bool {
        !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (original == nil || id == original?.id)
    }

    var isValid: Bool {
        guard hasValidIdentity, problem == nil else { return false }
        return type == .stdio
            ? stdioLaunchFields?.command.isEmpty == false
            : !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var stdioLaunchFields: (command: String, args: [String])? {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let args: [String]
        if let original, argsText == original.args.joined(separator: " ") {
            args = original.args
        } else {
            guard let parsedArgs = Self.parseArguments(argsText) else { return nil }
            args = parsedArgs
        }
        if let originalCommand = original?.command, command == originalCommand {
            return (originalCommand, args)
        }
        // Prefer an existing executable at the full literal path. Otherwise
        // parse a command line and require its absolute executable to exist.
        if text.hasPrefix("/"), Self.isExecutableFile(text) { return (text, args) }
        guard let tokens = Self.parseArguments(text), let executable = tokens.first,
              !executable.isEmpty else { return nil }
        if text.hasPrefix("/"), tokens.count > 1,
           !Self.isExecutableFile(executable) { return nil }
        return (executable, Array(tokens.dropFirst()) + args)
    }

    private static func isExecutableFile(_ path: String) -> Bool {
        var directory = ObjCBool(false)
        let files = FileManager.default
        return files.fileExists(atPath: path, isDirectory: &directory)
            && !directory.boolValue && files.isExecutableFile(atPath: path)
    }

    private static func parseArguments(_ input: String) -> [String]? {
        var arguments: [String] = []
        var argument = ""
        var quote: Character?
        var escaped = false
        var started = false

        for character in input {
            if escaped {
                argument.append(character)
                escaped = false
            } else if character == "\\" && quote != "'" {
                escaped = true
                started = true
            } else if let quoteCharacter = quote {
                if character == quoteCharacter { quote = nil }
                else { argument.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
                started = true
            } else if character.isWhitespace {
                if started {
                    arguments.append(argument)
                    argument = ""
                    started = false
                }
            } else {
                argument.append(character)
                started = true
            }
        }
        guard !escaped, quote == nil else { return nil }
        if started { arguments.append(argument) }
        return arguments
    }

    // MARK: 环境变量与请求头

    /// 每行一个 KEY=VALUE（值里可以有逗号和等号）。兼容旧写法：只有一行、且逗号分隔的每一段都含 = 时按逗号拆。
    static func parseEnvironment(_ text: String) -> (pairs: [(String, String)]?, problem: String?) {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var entries = lines
        if lines.count == 1, lines[0].contains(",") {
            let segments = lines[0].split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if segments.allSatisfy({ $0.contains("=") }) { entries = segments }
        }
        var pairs: [(String, String)] = []
        for (index, entry) in entries.enumerated() {
            guard let equals = entry.firstIndex(of: "=") else {
                return (nil, "环境变量第 \(index + 1) 行不是 KEY=VALUE 格式：每行写一个，例如 API_KEY=xxx。")
            }
            let key = entry[..<equals].trimmingCharacters(in: .whitespaces)
            let value = entry[entry.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !key.contains(where: { $0.isWhitespace }) else {
                return (nil, "环境变量第 \(index + 1) 行的变量名为空或含空格。")
            }
            pairs.append((key, value))
        }
        return (pairs, nil)
    }

    static func parseCallTimeout(_ text: String) -> (value: Int??, problem: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return (.some(nil), nil) }
        guard let seconds = Int(trimmed), (1...86_400).contains(seconds) else {
            return (nil, "工具调用超时需要是 1 到 86400 之间的秒数，或留空使用默认的 10 分钟。")
        }
        return (.some(seconds), nil)
    }

    private func resolvedHeaders() -> (headers: [String: String]?, problem: String?) {
        var headers: [String: String] = [:]
        var names = Set<String>()
        for row in headerRows {
            let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
            // 完全空白的行直接忽略。
            if name.isEmpty, row.value.isEmpty { continue }
            guard !name.isEmpty else { return (nil, "有一行请求头只填了值，请补上名称或移除该行。") }
            guard name.utf8.allSatisfy({ byte in
                (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                    || "!#$%&'*+-.^_`|~".utf8.contains(byte)
            }) else { return (nil, "请求头名称「\(name)」含有不允许的字符，只能用字母、数字和 !#$%&'*+-.^_`|~。") }
            guard !["host", "content-length", "content-type", "accept", "mcp-session-id"].contains(name.lowercased()) else {
                return (nil, "请求头「\(name)」由程序自动设置，不能在这里填写。")
            }
            guard names.insert(name.lowercased()).inserted else { return (nil, "请求头「\(name)」重复了。") }
            let value: String
            if row.value.isEmpty, row.originalName == name, let retained = original?.headers[name] { value = retained }
            else { value = row.value }
            guard !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
                return (nil, "请求头「\(name)」的值含有换行或控制字符。")
            }
            headers[name] = value
        }
        return (headers, nil)
    }

    /// 当前草稿不能保存的具体原因（中文，含下一步）；可以保存时为 nil。
    var problem: String? {
        if type == .stdio {
            if let reason = Self.parseEnvironment(envText).problem { return reason }
        } else if let reason = resolvedHeaders().problem {
            return reason
        }
        return Self.parseCallTimeout(callTimeoutText).problem
    }

    func server() -> MCPServer? {
        guard hasValidIdentity else { return nil }
        let launch = type == .stdio ? stdioLaunchFields : nil
        if type == .stdio {
            guard let launch, !launch.command.isEmpty else { return nil }
        } else {
            guard !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        }
        var result = original ?? MCPServer(id: id.trimmingCharacters(in: .whitespacesAndNewlines), name: name)
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.type = type
        result.enabled = enabled
        result.command = type == .stdio ? launch?.command : nil
        result.args = type == .stdio ? launch?.args ?? [] : []
        result.url = type == .http ? url.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        if type == .stdio {
            guard let pairs = Self.parseEnvironment(envText).pairs else { return nil }
            for (key, value) in pairs { result.env[key] = value }
        }
        if type == .http {
            guard let headers = resolvedHeaders().headers else { return nil }
            result.headers = headers
        }
        guard let timeout = Self.parseCallTimeout(callTimeoutText).value else { return nil }
        result.callTimeoutSeconds = timeout
        return result
    }

    @MainActor
    @discardableResult
    func save(to center: SettingsCenter) -> Bool {
        guard let server = server() else { return false }
        let current = center.mcpManager.server(id: server.id)
        // An open edit cannot resurrect a deleted server or overwrite a later
        // change. A new form cannot silently replace an existing identity.
        guard original.map({ current == $0 }) ?? (current == nil) else { return false }
        return center.addMCPServer(server)
    }
}
