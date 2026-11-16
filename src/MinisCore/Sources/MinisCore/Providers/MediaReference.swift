import Foundation

// MARK: - MediaReference（媒体引用链 · P1-13）

/// 参考图/参考媒体的三种来源形态。
///
/// 生视频（可灵 Kling / 即梦 Jimeng）等云端 API 的 `image_url` / `first_frame.url`
/// 必须是一个**云端可访问**的 URL。而画布上游生图节点产出后，参考图在内存/界面上
/// 常常是**本地文件路径**（如 `/tmp/xxx.png` 或 App 沙盒内路径）。若把本地路径直接
/// 塞进云端请求体，云端服务器无法访问该文件 → 生图→生视频主链路断裂（P1-13）。
///
/// 本类型把一条参考媒体字符串显式区分为三种形态，供链路在提交云端前统一把关：
/// - `.local(path:)`   —— 本地文件路径，云端**不可**访问；提交前必须上传托管或阻断。
/// - `.remote(url:)`   —— 已经是可远程访问的 URL（http/https），可直接用于云端。
/// - `.managed(url:)`  —— 已上传到托管服务的 URL（云端可访问），可直接用于云端。
public enum MediaReference: Sendable, Equatable {
    case local(path: String)
    case remote(url: String)
    case managed(url: String)

    /// 该引用是否可直接用于云端 API（`true` = 云端可访问）。
    public var isCloudAccessible: Bool {
        switch self {
        case .local: return false
        case .remote, .managed: return true
        }
    }

    /// 云端可访问的 URL（本地路径返回 nil）。
    public var cloudAccessibleURL: String? {
        switch self {
        case .local: return nil
        case .remote(let url), .managed(let url): return url
        }
    }
}

// MARK: - 分类

/// 把一条参考媒体字符串归类为 MediaReference。
///
/// 判定规则：以 `scheme://host` 形式（http/https/其他 scheme）且 host 非空 →
/// 视为 `.remote`；其余一律视为 `.local`（本地磁盘路径）。`data:` URI 与
/// `file://` 本地文件 URI 也统一归为 `.local`（云端不可用）。
public enum MediaReferenceResolver {
    public static func classify(_ raw: String) -> MediaReference {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .local(path: trimmed) }

        // 本地文件 URI（file:///...）→ 本地路径
        if trimmed.lowercased().hasPrefix("file://") {
            return .local(path: trimmed)
        }
        // data: URI → 云端不可用，归本地（需先转存上传）
        if trimmed.lowercased().hasPrefix("data:") {
            return .local(path: trimmed)
        }
        if let url = URL(string: trimmed), url.scheme != nil, url.host != nil {
            return .remote(url: trimmed)
        }
        return .local(path: trimmed)
    }
}

// MARK: - 托管上传

/// 把本地参考图上传到云端托管并返回可访问 URL 的能力。
///
/// 接入方（如未来接入 OSS / 图床 / 厂商临时素材上传接口）实现 `upload(localPath:)`，
/// 返回托管后的 URL；无法托管时返回 nil（由调用方决定阻断）。
public protocol MediaReferenceHosting: Sendable {
    /// 上传本地文件，返回云端可访问 URL。
    /// - Returns: 托管后的 URL；`nil` 表示当前环境不支持托管上传。
    func upload(localPath: String) async throws -> String?
}

// MARK: - 错误

/// 媒体引用链校验失败的错误。
public enum MediaReferenceError: Error, Equatable, LocalizedError {
    /// 参考图是本地路径，云端 API 无法访问，且当前没有可用的托管上传能力。
    case localNotAccessible(path: String)

    public var errorDescription: String? {
        switch self {
        case .localNotAccessible(let path):
            return "生视频参考图是本地路径，云端 API 无法访问：\(path)。请先将该图片上传到云端托管（获得可访问 URL）后再发起生视频。"
        }
    }
}

// MARK: - 提交前把关

/// 生视频提交前的媒体引用把关：把参考图字符串解析为云端可访问 URL。
///
/// - 远程/托管 URL → 原样返回。
/// - 本地路径 → 若已注入 `hoster`，尝试上传并返回托管 URL；否则阻塞并抛出
///   `MediaReferenceError.localNotAccessible`（友好提示用户先上传）。
///
/// 该关卡由 KlingProvider / JimengProvider 在 `submitVideo` 组装请求体前调用，
/// 保证进入云端 body 的 `image_url` / `first_frame.url` 一定是云端可访问的 URL，
/// 从而修复「生图本地路径 → 生视频云端 API」的断裂链路（P1-13）。
public enum MediaReferenceGate {
    /// 把可选参考图字符串解析为云端可访问 URL（`nil` 输入 → `nil`，不理会）。
    public static func resolveForCloud(
        _ raw: String?,
        hoster: (any MediaReferenceHosting)? = nil
    ) async throws -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        switch MediaReferenceResolver.classify(raw) {
        case .remote(let url), .managed(let url):
            return url
        case .local(let path):
            if let hoster {
                if let managed = try await hoster.upload(localPath: path) {
                    return managed
                }
            }
            throw MediaReferenceError.localNotAccessible(path: path)
        }
    }
}