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
    }

    var isEditing: Bool { original != nil }

    private var hasValidIdentity: Bool {
        !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (original == nil || id == original?.id)
    }

    var isValid: Bool {
        guard hasValidIdentity else { return false }
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
            for pair in envText.split(separator: ",") {
                let fields = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard fields.count == 2, !fields[0].isEmpty else { return nil }
                result.env[fields[0]] = fields[1]
            }
        }
        if type == .http {
            var headers: [String: String] = [:]
            var names = Set<String>()
            for row in headerRows {
                let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, names.insert(name.lowercased()).inserted,
                      name.utf8.allSatisfy({ byte in
                          (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                          || "!#$%&'*+-.^_`|~".utf8.contains(byte)
                      }), !["host", "content-length", "content-type", "accept", "mcp-session-id"].contains(name.lowercased())
                else { return nil }
                let value: String
                if row.value.isEmpty, row.originalName == name,
                   let retained = original?.headers[name] { value = retained }
                else { value = row.value }
                guard !value.isEmpty, !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return nil }
                headers[name] = value
            }
            result.headers = headers
        }
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
