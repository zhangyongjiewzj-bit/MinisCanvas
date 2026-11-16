import Foundation

/// Fixed, payload-free user copy. The associated session identifiers and
/// details are never shown; the retry envelope and the App projection both read
/// this description so every session kind shows the same text.
extension SessionStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .sessionNotFound:
            return "会话记录不存在或已被移除，本次请求未完成。"
        case .sessionAlreadyExists:
            return "会话记录已存在，本次请求未完成。"
        case .sessionSnapshotConflict:
            return "会话记录在处理期间发生了变化，本次请求未完成；原消息已保留，请重试。"
        case .sessionTargetMismatch:
            return "会话目标与当前记录不一致，本次请求未完成。"
        case .sessionCommitUncertain:
            return "会话记录的写入结果无法确认，本次请求已停止；请先核对会话内容后再重试。"
        case .invalidSessionLineage, .sessionLineageCycle:
            return "会话的来源关系无效，本次请求未完成。"
        case .compactionCheckpointConflict, .invalidCompactionCheckpoint,
             .compactionCheckpointRecoveryRequired, .compactionCheckpointSessionMismatch,
             .compactionCheckpointLineageMismatch, .compactionCheckpointRevisionMismatch,
             .compactionCheckpointBoundaryMismatch:
            return "上下文压缩记录校验未通过，本次未向模型发送请求；原消息已保留，可以在新会话继续。"
        case .compactionRefused:
            return "上下文压缩被拒绝，本次未向模型发送请求；原消息已保留，可以在新会话继续。"
        }
    }
}
