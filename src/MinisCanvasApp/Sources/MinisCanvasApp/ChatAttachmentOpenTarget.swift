import Foundation
import AppKit

/// 聊天附件的可打开目标解析边界。
///
/// 会话持久化只保存原始路径和可选的附件数据。路径失效时，优先用已持久化的数据
/// 物化为临时文件，保证会话迁移或原文件被移动后仍然有明确的打开结果；两者都没有时
/// 返回显式错误，调用方必须给用户反馈，不能静默 no-op。
enum ChatAttachmentOpenError: Error, Equatable, LocalizedError {
    case unavailable
    case materializationFailed
    case permissionDenied
    case noApplication
    case externalOpenFailed

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "附件的原文件已不存在，且没有可恢复的数据。"
        case .materializationFailed:
            return "附件数据无法恢复为可打开的文件。"
        case .permissionDenied:
            return "没有权限读取此附件，无法交给系统打开。"
        case .noApplication:
            return "系统没有找到可以打开此附件的应用。"
        case .externalOpenFailed:
            return "系统打开此附件失败，请稍后重试或检查文件权限。"
        }
    }
}

/// User-facing source state used by both the transcript chip and the preview
/// route. It deliberately exposes no path or attachment bytes.
enum ChatAttachmentSourceState: Equatable, Sendable {
    case sourceAvailable
    case missingSourceMaterializable
    case unavailable

    var isOpenable: Bool {
        self != .unavailable
    }

    var statusText: String {
        switch self {
        case .sourceAvailable:
            return "原文件可用"
        case .missingSourceMaterializable:
            return "原文件缺失，将从已保存数据恢复"
        case .unavailable:
            return "原文件缺失且没有可恢复数据"
        }
    }
}

struct ChatAttachmentOpenTarget {
    let fileManager: FileManager
    let temporaryDirectory: URL

    init(
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory
    }

    /// 只检查是否存在可打开来源，不产生文件副作用，供 UI 决定 disabled 状态。
    static func canOpen(_ attachment: ChatAttachment, fileManager: FileManager = .default) -> Bool {
        sourceState(for: attachment, fileManager: fileManager).isOpenable
    }

    /// Read-only state projection for UI and recovery actions. A missing
    /// source with persisted bytes is recoverable but is not reported as
    /// sourceAvailable until `resolve` materializes it.
    static func sourceState(
        for attachment: ChatAttachment,
        fileManager: FileManager = .default
    ) -> ChatAttachmentSourceState {
        if let rawPath = attachment.fileURL,
           let url = sourceURL(from: rawPath),
           isRegularFile(url, fileManager: fileManager) {
            return .sourceAvailable
        }
        return attachment.data == nil ? .unavailable : .missingSourceMaterializable
    }

    /// 解析已有文件，或将持久化 data 物化为临时文件。
    func resolve(_ attachment: ChatAttachment) throws -> URL {
        if let rawPath = attachment.fileURL,
           let url = Self.sourceURL(from: rawPath),
           Self.isRegularFile(url, fileManager: fileManager) {
            return url
        }

        guard let data = attachment.data else {
            throw ChatAttachmentOpenError.unavailable
        }

        let directory = temporaryDirectory
            .appendingPathComponent("MinisCanvas", isDirectory: true)
            .appendingPathComponent("ChatAttachments", isDirectory: true)
            .appendingPathComponent(attachment.id.uuidString, isDirectory: true)
        let fileName = Self.safeFileName(attachment.fileName, fallback: attachment.id.uuidString)
        let destination = directory.appendingPathComponent(fileName, isDirectory: false)

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
            return destination
        } catch {
            throw ChatAttachmentOpenError.materializationFailed
        }
    }

    /// 路径格式契约 seam：保留 file://、~ 和普通绝对路径的统一解析。
    static func sourceURL(from rawPath: String) -> URL? {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        if path.hasPrefix("file://"), let url = URL(string: path), url.isFileURL {
            return url.standardizedFileURL
        }
        let expandedPath = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expandedPath).standardizedFileURL
    }

    private static func isRegularFile(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        return !isDirectory.boolValue
    }

    private static func safeFileName(_ fileName: String, fallback: String) -> String {
        let lastPathComponent = (fileName as NSString).lastPathComponent
        let trimmed = lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "." || trimmed == ".." ? fallback : trimmed
    }
}

/// 文件/图片离开客户端后的系统打开边界。
///
/// 系统能力通过两个闭包注入：测试可以确定性验证路由和失败语义，生产默认使用
/// NSWorkspace。解析、权限检查、打开器发现和最终打开动作分层，避免按钮点击后静默 no-op。
struct ChatAttachmentExternalOpener {
    typealias ApplicationResolver = (URL) -> URL?
    typealias OpenAction = (URL) -> Bool
    typealias ReadabilityCheck = (URL) -> Bool

    private let target: ChatAttachmentOpenTarget
    private let isReadable: ReadabilityCheck
    private let applicationResolver: ApplicationResolver
    private let openAction: OpenAction

    init(
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        isReadable: ReadabilityCheck? = nil,
        applicationResolver: ApplicationResolver? = nil,
        openAction: OpenAction? = nil
    ) {
        let target = ChatAttachmentOpenTarget(
            fileManager: fileManager,
            temporaryDirectory: temporaryDirectory
        )
        self.target = target
        self.isReadable = isReadable ?? { url in
            fileManager.isReadableFile(atPath: url.path)
        }
        self.applicationResolver = applicationResolver ?? { url in
            NSWorkspace.shared.urlForApplication(toOpen: url)
        }
        self.openAction = openAction ?? { url in
            NSWorkspace.shared.open(url)
        }
    }

    /// 解析附件、检查读取权限、发现系统打开器并执行外部打开动作。
    /// 返回最终交给系统的 URL，便于调用方记录和测试恢复数据物化结果。
    @discardableResult
    func open(_ attachment: ChatAttachment) throws -> URL {
        let url = try target.resolve(attachment)
        return try open(url: url)
    }

    /// 已由客户端文件树解析出的文件 URL 的外部打开入口。
    @discardableResult
    func open(url: URL) throws -> URL {
        guard isReadable(url) else {
            throw ChatAttachmentOpenError.permissionDenied
        }
        guard applicationResolver(url) != nil else {
            throw ChatAttachmentOpenError.noApplication
        }
        guard openAction(url) else {
            throw ChatAttachmentOpenError.externalOpenFailed
        }
        return url
    }
}
