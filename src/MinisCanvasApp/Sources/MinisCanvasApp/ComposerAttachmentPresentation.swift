import Foundation
import MinisCore

// MARK: - D-COMPOSER-04 附件状态视图模型（Composer 待发送 chip 的如实状态投影）
//
// 需求锚点：issues/三期初期合拢-App逐项功能验收清单-20260826.md
//   L193 `COMPOSER-04` 添加附件后显示文件名、类型和状态。
//   L197 `COMPOSER-08` 附件缺失、权限错误或处理失败时可见，不显示为成功。
//
// 事实来源约束（独审 D-COMPOSER-04 深核，P3-PROGRESS-AUDIT-20260909）：
// ChatStore.addAttachments 先落 pending 占位附件，后台读取完成后按固定 id
// 原位升级为 ready/failed。本投影优先消费既有 status/failureReason；
// ready 历史记录仍按 kind/data 保留原来的内容可用性判别，不新增状态事实源。

/// 待发送附件 chip 的可见状态（由 ChatAttachment 既有字段如实推导，不新增第二事实源）。
enum ComposerAttachmentChipStatus: String, Equatable, Sendable {
    /// 内容已读取成功（图片/音频字节或非截断文本已就绪）。
    case ready
    /// 文本类内容已注入，但达到 ChatStore.maxTextAttachmentChars 注入上限。
    case injectedAtCap
    case reading
    case readFailed
    /// ready 历史记录缺少已解析内容时，保留不冒充成功的形状兼容投影。
    case resolvingOrDegraded
    /// Local frames are ready; the selected model's image gate still decides
    /// whether any PNG part reaches the provider.
    case sampledVideoFrames
    case videoSampling
    case videoSamplingFailed
    /// 未知类型以及没有抽帧元数据的历史视频只保留文件引用。
    case referenceOnly

    var statusLabel: String {
        switch self {
        case .ready: return "就绪"
        case .injectedAtCap: return "已达注入上限"
        case .reading: return "读取中"
        case .readFailed: return "读取失败"
        case .resolvingOrDegraded: return "读取中或已降级为文件引用"
        case .sampledVideoFrames: return "静帧已就绪，发送取决于模型图片能力"
        case .videoSampling: return "视频抽帧中"
        case .videoSamplingFailed: return "视频抽帧失败，未发送画面"
        case .referenceOnly: return "文件引用"
        }
    }

    /// COMPOSER-08 的负向不变式：任何未成功状态都不得投影为成功文案。
    var claimsSuccess: Bool {
        self == .ready || self == .injectedAtCap || self == .sampledVideoFrames
    }
}

@MainActor
enum ComposerAttachmentPresentation {
    /// 从附件既有事实投影状态。只读，不改变发送门（发送语义不变）。
    static func status(for attachment: ChatAttachment) -> ComposerAttachmentChipStatus {
        if attachment.fileType == .video {
            switch attachment.status {
            case .pending: return .videoSampling
            case .failed: return .videoSamplingFailed
            case .ready:
                if attachment.videoFrames == nil { return .referenceOnly }
                return attachment.videoImageAttachments == nil
                    ? .videoSamplingFailed : .sampledVideoFrames
            }
        }
        switch attachment.status {
        case .pending: return .reading
        case .failed: return .readFailed
        case .ready: break
        }
        switch attachment.kind {
        case .image, .audio:
            // 升级成功后带 data；未解析占位符的 kind 恒为 .file（落入下方分支）。
            return attachment.data != nil ? .ready : .resolvingOrDegraded
        case .text:
            guard attachment.data != nil else { return .resolvingOrDegraded }
            // Exact cap length is not evidence of truncation. Use the actual
            // original character count captured before the producer caps text.
            if truncationNotice(for: attachment, sent: false) != nil { return .injectedAtCap }
            return .ready
        case .file:
            if attachment.fileType == .unknown {
                return .referenceOnly
            }
            return .resolvingOrDegraded
        }
    }

    /// String.count matches the producer's prefix cap; unknown historical
    /// totals stay unknown, with no guessed length from byte size or cap equality.
    nonisolated static func truncationNotice(for attachment: ChatAttachment, sent: Bool) -> String? {
        guard attachment.status == .ready, attachment.kind == .text,
              let original = attachment.originalTextCharacterCount, original > 0,
              let data = attachment.data, let text = String(data: data, encoding: .utf8),
              text.count < original else { return nil }
        let injected = text.count.formatted(.number.locale(Locale(identifier: "en_US_POSIX")))
        let total = original.formatted(.number.locale(Locale(identifier: "en_US_POSIX")))
        return "\(sent ? "已发送" : "将发送")前 \(injected) 字 / 共 \(total) 字，其余可让模型读取原文件"
    }

    /// 类型副标题（COMPOSER-04 的"类型"）：以分类事实源 FileType 为准，
    /// 不用 kind 反推——占位符的 kind 恒为 .file，会丢失类型信息。
    static func typeLabel(for attachment: ChatAttachment) -> String {
        switch attachment.fileType {
        case .text: return "文本"
        case .markdown: return "Markdown"
        case .json: return "JSON"
        case .image: return "图片"
        case .audio: return "音频"
        case .video: return "视频"
        case .unknown: return "未知类型"
        }
    }

    /// chip 的无障碍值：文件名、类型和状态一项不缺（COMPOSER-04），
    /// 未完成/失败态保持如实文案（COMPOSER-08）。
    @MainActor
    static func accessibilityValue(for attachment: ChatAttachment) -> String {
        let status = status(for: attachment)
        var parts = [attachment.fileName, typeLabel(for: attachment), status.statusLabel]
        if let size = attachment.size {
            parts[1] += " · \(ChatStore.formatByteCount(size))"
        }
        if let notice = truncationNotice(for: attachment, sent: false) { parts.append(notice) }
        if attachment.status == .failed,
           let reason = MinisCore.ConversationEventRedactor.redactField(attachment.failureReason) {
            parts.append(reason)
        }
        if status == .sampledVideoFrames, let frames = attachment.videoFrames {
            parts.append(frames.map { ChatAttachment.videoTimecode($0.timecodeSeconds) }
                .joined(separator: "、"))
        }
        return parts.joined(separator: "，")
    }

    /// Project the same model-bound readiness fact used by the send gate.
    /// Missing IDs are stale projections and must not look supported.
    static func mediaReadinessText(
        for attachment: ChatAttachment,
        in snapshot: ComposerMediaReadinessSnapshot
    ) -> String {
        snapshot.attachment(id: attachment.id)?.reason ?? "附件或模型已变化，请重新选择模型；仍无法发送时请移除附件后重试。"
    }

    /// 状态行文案：当前模型无法接收该附件时不写“就绪”。
    static func statusLabel(
        for attachment: ChatAttachment,
        in snapshot: ComposerMediaReadinessSnapshot
    ) -> String {
        if snapshot.attachment(id: attachment.id)?.blocksSend == true { return "不可发送" }
        return truncationNotice(for: attachment, sent: false) ?? status(for: attachment).statusLabel
    }

    static func accessibilityValue(
        for attachment: ChatAttachment,
        mediaReadiness snapshot: ComposerMediaReadinessSnapshot
    ) -> String {
        "\(accessibilityValue(for: attachment))，\(mediaReadinessText(for: attachment, in: snapshot))"
    }
}
