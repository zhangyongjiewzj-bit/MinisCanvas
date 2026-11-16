import Foundation
import Darwin
import CryptoKit

/// File metadata is observed without reading the target body or expanding the
/// executor's existing read permissions. ctime is included so same-length
/// writes and restored mtimes still invalidate the user's earlier decision.
public struct ApprovalFileVersion: Sendable, Equatable {
    public let path: String
    public let canonicalPath: String
    private let metadata: [Int64]

    public static func capture(path: String) throws -> Self {
        guard path.hasPrefix("/"), !path.contains("\0") else {
            throw ApprovalError.denied(reason: "文件路径无效，请重新发起审批")
        }
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        var info = stat()
        if Darwin.lstat(canonical, &info) != 0 {
            guard errno == ENOENT else {
                throw ApprovalError.denied(reason: "无法检查文件状态，请重新发起审批")
            }
            // Include the existing ancestor identity. Replacing a missing
            // target's parent/symlink while the prompt is open also invalidates it.
            var ancestor = URL(fileURLWithPath: canonical).deletingLastPathComponent()
            while Darwin.lstat(ancestor.path, &info) != 0 {
                guard errno == ENOENT, ancestor.path != "/" else {
                    throw ApprovalError.denied(reason: "无法检查文件目录，请重新发起审批")
                }
                ancestor.deleteLastPathComponent()
            }
            return Self(path: path, canonicalPath: canonical, metadata: [-1, Int64(info.st_dev), Int64(info.st_ino)])
        }
        return Self(path: path, canonicalPath: canonical, metadata: [
            Int64(info.st_dev), Int64(info.st_ino), Int64(info.st_mode), Int64(info.st_size),
            Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec),
            Int64(info.st_ctimespec.tv_sec), Int64(info.st_ctimespec.tv_nsec)
        ])
    }

    func matches(_ info: stat) -> Bool {
        metadata == [Int64(info.st_dev), Int64(info.st_ino), Int64(info.st_mode), Int64(info.st_size),
            Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec),
            Int64(info.st_ctimespec.tv_sec), Int64(info.st_ctimespec.tv_nsec)]
    }

    public var versionDigest: String {
        let data = Data((path + "\0" + canonicalPath + "\0" + metadata.map(String.init).joined(separator: ",")).utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func validateCurrent() throws {
        guard try Self.capture(path: path) == self else {
            throw ApprovalFileChangedError()
        }
    }
}

public struct ApprovalFilePreview: Sendable, Equatable {
    public static let maximumCharacters = 4096
    public let version: ApprovalFileVersion?
    public let text: String
    public let isSensitive: Bool
    public let available: Bool
    var deletionContentDigest: String? = nil
    public internal(set) var expandedText: String? = nil
    var parameterOnly: Bool = false

    static func bounded(_ text: String, lines: Int? = nil, bytes: Int) -> String {
        let lineBounded = lines.map { text.split(separator: "\n", omittingEmptySubsequences: false).prefix($0).joined(separator: "\n") } ?? text
        if lineBounded == text && text.utf8.count <= bytes { return text }
        let marker = "\n…[预览已截断]"
        let body = lines.map { text.split(separator: "\n", omittingEmptySubsequences: false).prefix(max(0, $0 - 1)).joined(separator: "\n") } ?? text
        var prefix = Data(body.utf8.prefix(max(0, bytes - marker.utf8.count)))
        while String(data: prefix, encoding: .utf8) == nil && !prefix.isEmpty { prefix.removeLast() }
        return (String(data: prefix, encoding: .utf8) ?? "") + marker
    }

    private static func redactedLines(_ content: String) -> String {
        let safe = ContentSecretRedactor.redact(content)
        // The shared masker preserves Character count. Restore only line breaks
        // hidden inside a multiline credential so diff line numbers stay true.
        guard safe.count == content.count else { return safe }
        return String(zip(content, safe).map { original, redacted in original.isNewline ? original : redacted })
    }

    static func lineCount(_ content: String) -> Int {
        if content.isEmpty { return 0 }
        let count = content.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
        return count - (content.last?.isNewline == true ? 1 : 0)
    }

    static func write(version: ApprovalFileVersion, content: String, exists: Bool,
        oldLines: Int?, append: Bool, digest: String?, oldUnreadable: Bool = false) -> Self {
        let proposed = lineCount(content)
        let delta: String
        if let oldLines {
            delta = append ? "旧文件 \(oldLines) 行；追加内容 \(proposed) 行" : "行数：\(oldLines) → \(proposed)（差 \(proposed - oldLines)）"
        } else { delta = oldUnreadable ? "旧内容不可读；旧行数差/旧全文摘要不可用"
            : (exists ? "旧文件不是UTF8文本，无法计算行数差" : "新建文件：\(proposed) 行") }
        let heading = ContentSecretRedactor.redact("路径：\(version.path)\n拟写入大小：\(content.utf8.count) bytes\n" + (exists ? (append ? "将追加" : "将覆盖") : "将新建") + "\n" + delta + "\n")
        return Self(version: version, text: heading + writePreview(content, budget: max(64, maximumCharacters - heading.count)), isSensitive: false,
            available: true, deletionContentDigest: digest)
    }

    static func edit(version: ApprovalFileVersion, old: String, new: String, digest: String) -> Self {
        // Redact the complete source texts before rendering or clipping hunks.
        let hunks = TextDiff.diff(old: redactedLines(old), new: redactedLines(new))
        let safe = ContentSecretRedactor.redact("路径：\(version.path)\n")
            + DiffRenderer.renderUnifiedWithHeaders(hunks)
        let initial = bounded(safe, lines: 80, bytes: 8 * 1024)
        let expanded = bounded(safe, bytes: 64 * 1024)
        return Self(version: version, text: initial, isSensitive: false, available: true,
            deletionContentDigest: digest, expandedText: expanded == initial ? nil : expanded)
    }

    func validateMutation(data: Data?) throws {
        try validateCurrent()
        if let deletionContentDigest {
            guard let data, deletionContentDigest == Self.digest(data) else { throw ApprovalFileChangedError() }
        }
    }


    static func deletion(version: ApprovalFileVersion, data: Data, content: String) -> Self {
        let safe = redactedLines(content).split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).prefix(3).joined(separator: "\n")
        let body = String(safe.prefix(maximumCharacters)) + (safe.count > maximumCharacters ? "\n…[预览已截断]" : "")
        return Self(version: version, text: ContentSecretRedactor.redact("路径：\(version.path)\n大小：\(data.count) bytes\n前三行：\n") + body,
            isSensitive: false, available: true, deletionContentDigest: digest(data))
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func validateDeletion(data: Data, info: stat) throws {
        try validateCurrent()
        guard version?.matches(info) == true else { throw ApprovalFileChangedError() }
        if let deletionContentDigest, deletionContentDigest != Self.digest(data) { throw ApprovalFileChangedError() }
    }

    public static func capture(tool: String, input: [String: Any]) -> Self? {
        if tool == "shell_execute" {
            let safe = ContentSecretRedactor.redact("工作目录：" + (input["cwd"] as? String ?? "（沿用当前目录）")
                + "\n命令：\n" + (input["command"] as? String ?? ""))
            let initial = bounded(safe, lines: 20, bytes: 4 * 1024)
            let expanded = bounded(safe, bytes: 4 * 1024)
            return Self(version: nil, text: initial, isSensitive: false, available: true,
                expandedText: expanded == initial ? nil : expanded, parameterOnly: true)
        }
        guard ["file_write", "file_edit", "file_delete"].contains(tool) else { return nil }
        guard let path = input["path"] as? String,
              let version = try? ApprovalFileVersion.capture(path: path) else {
            return Self(version: nil, text: "无法检查文件，批准无效；请修正路径后重试", isSensitive: true, available: false)
        }
        let sensitive = SensitiveFilePolicy.contains(path) || SensitiveFilePolicy.contains(version.canonicalPath)
        if sensitive {
            return Self(version: version, text: "敏感文件：内容已隐藏", isSensitive: true, available: true)
        }
        let raw: String
        switch tool {
        case "file_write":
            let content = input["content"] as? String ?? ""
            let heading = ContentSecretRedactor.redact("路径：\(path)\n拟写入大小：\(content.utf8.count) bytes\n")
            let text = heading + writePreview(content, budget: max(64, maximumCharacters - heading.count))
            return Self(version: version, text: text, isSensitive: false, available: true)
        case "file_edit": raw = "拟替换片段：\n" + (input["old_string"] as? String ?? "") + "\n替换为：\n" + (input["new_string"] as? String ?? "")
        default: raw = "拟删除此文件；不会在预览中读取文件正文"
        }
        // Redact before clipping: clipping first could hide the beginning/end
        // of a credential marker and expose a fragment of its value.
        let safe = ContentSecretRedactor.redact(raw)
        let bounded = String(safe.prefix(maximumCharacters))
        return Self(version: version, text: bounded + (safe.count > maximumCharacters ? "\n…[预览已截断]" : ""), isSensitive: false, available: true)
    }

    private static func writePreview(_ content: String, budget: Int = 4096) -> String {
        let heading = "拟写入内容：\n"
        let safe = redactedLines(content)
        let hasTerminator = safe.last?.isNewline == true
        let body = hasTerminator ? safe.dropLast() : safe[...]
        let lines = body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let omitted = "\n…[预览已截断]\n"
        let bodyBudget = budget - heading.count - omitted.count
        if lines.count <= 16 {
            guard heading.count + safe.count > budget else { return heading + safe }
            let firstBudget = bodyBudget / 2
            return heading + String(safe.prefix(firstBudget)) + omitted + String(safe.suffix(bodyBudget - firstBudget))
        }

        let first = lines.prefix(12).joined(separator: "\n")
        let last = lines.suffix(4).joined(separator: "\n") + (hasTerminator ? "\n" : "")
        let lastBudget = min(last.count, max(bodyBudget / 2, bodyBudget - first.count))
        let firstBudget = bodyBudget - lastBudget
        return heading + String(first.prefix(firstBudget)) + omitted + String(last.suffix(lastBudget))
    }

    public func validateCurrent() throws {
        if parameterOnly && available { return }
        guard available, let version else {
            throw ApprovalError.denied(reason: "文件预览不可用，请修正路径后重新审批")
        }
        try version.validateCurrent()
    }
}

/// Carries the already-presented preview across the existing execution chain.
/// It grants no authority: the executor still validates policy and roots.
public enum ApprovalFilePreviewContext {
    @TaskLocal public static var current: ApprovalFilePreview?
}

/// An old consent cannot dispatch an effect. The owning authorization path may
/// request one fresh preview of the same action; this error grants nothing.
public struct ApprovalFileChangedError: Error, Sendable, Equatable, LocalizedError {
    public init() {}
    public var errorDescription: String? { "审批后文件已变化，请重新预览并审批" }
}
