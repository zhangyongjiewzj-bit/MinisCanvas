import os

/// 流畅度基线埋点（J 组）：只负责让 Instruments 的 os_signpost 泳道看到固定名称的区间。
/// 子系统与既有转录/输入框埋点一致，类别固定为 "Perf"。区间名是固定字面量，
/// 不携带消息正文、会话 ID 或凭据。不改变任何业务行为。
///
/// 用法（两行以内，begin 之后用 defer 收尾）：
///
///     let perf = PerformanceSignposts.begin(.persistSessions); defer { perf.end() }
enum PerformanceSignposts {
    static let signposter = OSSignposter(
        subsystem: "com.miniscanvas.MinisCanvas", category: "Perf"
    )

    /// 固定区间名。新增区间只加 case 与 `label`。
    enum Interval {
        /// ChatStore.persistSessions：回合结束/改名/归档等触发的全量会话保存。
        case persistSessions
        /// ChatStore.updateMessageContent：流式片段写回（含整条正文脱敏）。
        case streamDeltaWriteback
        /// ChatCredentialBroker.projectStream 内的整段脱敏（StreamDeltaWriteback 的子区间）。
        case streamRedaction
        /// ChatTranscriptFormatter.formattedMessage：单条消息格式化（含 Markdown 构建）。
        case transcriptFormatMessage
        /// MarkdownAttributedTextBuilder 的解析 + 属性字符串构建。
        case transcriptMarkdownBuild
        /// ChatTranscriptView.transcriptDocumentForDisplay：展示投影 + 文档缓存 render。
        case transcriptDocumentForDisplay
        /// 侧栏 chat.sessionGroups 计算（排序、过滤、分组）。
        case sidebarSessionGroups
        /// ChatStore.searchMessageResults：一次全会话搜索。
        case sessionSearch
        /// ChatStore.setDraftText：输入框一次按键提交到草稿的处理。
        case composerDraftCommit
        /// ChatStore.applySwitchSession：切换会话的同步部分（不含随后的转录重建）。
        case sessionSwitch
        /// 展开/收起工具输出点击处理（不含随后由 SwiftUI 触发的转录重建，
        /// 重建部分见 transcriptDocumentForDisplay / TranscriptRender）。
        case toolOutputToggle

        var label: StaticString {
            switch self {
            case .persistSessions: return "PersistSessions"
            case .streamDeltaWriteback: return "StreamDeltaWriteback"
            case .streamRedaction: return "StreamRedaction"
            case .transcriptFormatMessage: return "TranscriptFormatMessage"
            case .transcriptMarkdownBuild: return "TranscriptMarkdownBuild"
            case .transcriptDocumentForDisplay: return "TranscriptDocumentForDisplay"
            case .sidebarSessionGroups: return "SidebarSessionGroups"
            case .sessionSearch: return "SessionSearch"
            case .composerDraftCommit: return "ComposerDraftCommit"
            case .sessionSwitch: return "SessionSwitch"
            case .toolOutputToggle: return "ToolOutputToggle"
            }
        }
    }

    /// 一个进行中的区间；`end()` 必须恰好调用一次（用 defer）。
    struct Token {
        fileprivate let interval: Interval
        fileprivate let state: OSSignpostIntervalState

        func end() {
            PerformanceSignposts.signposter.endInterval(interval.label, state)
        }
    }

    static func begin(_ interval: Interval) -> Token {
        Token(interval: interval, state: signposter.beginInterval(interval.label))
    }
}
