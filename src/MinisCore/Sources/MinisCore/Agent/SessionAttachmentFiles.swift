import Foundation

/// `session_send` / `external_session_send` 的文件附件。路径必须落在读取授权根内
/// （由调用方的 `authorize` 检查）、不是敏感文件或凭据、是普通文件。
/// 本 App 内的会话：把文本文件内容（脱敏、限长）附在消息后面；外部会话：消息里只带文件路径，
/// 由对方智能体在它自己的权限下读取，并完整显示在确认卡上。
public enum SessionAttachmentFiles {
    static let maximumFiles = 3
    static let maximumInlineBytes = 64 * 1024

    /// 工具参数 `files` 的 JSON Schema：字符串数组（最多 3 项由工具自己检查）。
    static let arraySchema: MCPJSONValue = .object([
        "type": .string("array"),
        "items": .object(["type": .string("string")]),
    ])

    public struct Resolved: Sendable, Equatable {
        public let path: String
        public let name: String
        public let size: Int
    }

    /// `input["files"]`：最多 3 个绝对路径；没有则为空。
    static func requestedPaths(_ input: [String: Any]) throws -> [String] {
        guard let raw = input["files"], !(raw is NSNull) else { return [] }
        guard let list = raw as? [Any] else { throw ToolExecutorError.invalidParameter("files") }
        guard list.count <= maximumFiles else { throw ToolExecutorError.invalidParameter("files_too_many") }
        var paths: [String] = []
        for item in list {
            guard let path = item as? String, path.hasPrefix("/"), !path.contains("\0"),
                  path.rangeOfCharacter(from: .controlCharacters) == nil else {
                throw ToolExecutorError.invalidParameter("files")
            }
            if !paths.contains(path) { paths.append(path) }
        }
        return paths
    }

    /// `authorize` 返回通过授权根检查的规范路径（越权时抛错）。
    static func resolve(paths: [String], authorize: (String) throws -> URL) throws -> [Resolved] {
        try paths.map { path in
            let real = try authorize(path).path
            guard !SensitiveFilePolicy.contains(real), !SensitiveFilePolicy.contains(path),
                  !SensitiveFilePolicy.isCredentialPath(real) else {
                throw ToolExecutorError.permissionDenied(path)
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: real, isDirectory: &isDirectory), !isDirectory.boolValue,
                  let size = (try? FileManager.default.attributesOfItem(atPath: real))?[.size] as? Int else {
                throw ToolExecutorError.invalidParameter("files")
            }
            return Resolved(path: real, name: (real as NSString).lastPathComponent, size: size)
        }
    }

    /// 本 App 内会话：读文本内容，脱敏后附在消息后面。过大或不是文本的文件拒绝，不静默丢弃。
    static func inlineBlock(_ files: [Resolved], knownSecrets: [String]) throws -> String {
        var output = ""
        for file in files {
            guard file.size <= maximumInlineBytes,
                  let data = try? Data(contentsOf: URL(fileURLWithPath: file.path)), !data.contains(0),
                  let text = String(data: data, encoding: .utf8) else {
                throw ToolExecutorError.invalidParameter("files_not_small_text")
            }
            let safe = ContentSecretRedactor.redact(text, knownSecrets: knownSecrets)
            output += "\n\n附件 \(file.name)（\(file.path)）的内容：\n```\n\(safe)\n```"
        }
        return output
    }
}
