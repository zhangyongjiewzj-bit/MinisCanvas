import SwiftUI
import MinisCore

struct ToolEventCard: View {
    struct DisplayModel: Equatable {
        let kind: String
        let summary: String
        let status: String
        let elapsed: String
        let provider: String
        let model: String
        let errorCategory: String?
        let accessibilityLabel: String
        let browserResult: String?
        let automaticExecutionNotice: String?
        let browserContentIsUntrusted: Bool
    }

    let event: MinisCore.ConversationEvent
    private let concurrentEvents: [MinisCore.ConversationEvent]
    private let approvalReceipts: [ComposerApprovalReceipt]
    @State private var isExpanded = false
    @Environment(BridgeStore.self) private var bridge: BridgeStore?
    @Environment(\.themeTokens) private var theme

    init(event: MinisCore.ConversationEvent, concurrentEvents: [MinisCore.ConversationEvent] = [],
         approvalReceipts: [ComposerApprovalReceipt] = []) {
        self.event = event
        self.concurrentEvents = concurrentEvents
        self.approvalReceipts = approvalReceipts
    }

    /// Count only dispatched, nonterminal native facts in one exact operation
    /// and attempt. Terminal evidence wins over any late phase replay.
    nonisolated static func concurrentRunningCount(
        for event: MinisCore.ConversationEvent, events: [MinisCore.ConversationEvent]
    ) -> Int {
        guard event.kind == .tool, event.status == .running,
              let target = event.toolCompositeKey, target.isValid else { return 0 }
        let same = events.filter {
            guard $0.kind == .tool, let key = $0.toolCompositeKey, key.isValid else { return false }
            return key.sessionID == target.sessionID && key.turnID == target.turnID
                && key.messageID == target.messageID
                && key.operationID == target.operationID && key.attemptID == target.attemptID
                && key.attemptNumber == target.attemptNumber
                && $0.identity.sessionID == target.sessionID
                && $0.toolCallID == key.toolCallID
        }
        let closed = Set(same.filter { $0.status.isTerminal }.compactMap { $0.toolCompositeKey?.rawValue })
        guard !closed.contains(target.rawValue) else { return 0 }
        let active = Set(same.filter { $0.status == .running }.compactMap { $0.toolCompositeKey?.rawValue })
        return active.subtracting(closed).count
    }

    nonisolated static func displayModel(
        for event: MinisCore.ConversationEvent,
        approvalReceipts: [ComposerApprovalReceipt] = []
    ) -> DisplayModel {
        let projection = MinisCore.ConversationEventProjection.display(for: event)
        let browser = event.kind == .tool ? event.browserDetail : nil
        let action = browser.map { browserActionLabel($0.action) }
        let persistentRuleWasUsed: Bool
        if event.kind == .tool, event.status == .succeeded,
           let key = event.toolCompositeKey, key.isValid {
            persistentRuleWasUsed = approvalReceipts.contains { receipt in
                receipt.persistentRuleID?.isEmpty == false
                    && receipt.sessionID == key.sessionID
                    && receipt.turnID == key.turnID
                    && receipt.messageID == key.messageID
                    && receipt.taskID == event.identity.taskID
                    && receipt.attemptID == key.attemptID
                    && receipt.callID == key.toolCallID
                    && event.toolCallID == key.toolCallID
                    && event.identity.sessionID == key.sessionID
                    && event.identity.turnID == String(key.turnID)
                    && event.identity.attempt == key.attemptNumber
            }
        } else {
            persistentRuleWasUsed = false
        }
        let automaticNotice = event.kind == .tool && event.status == .succeeded && browser?.outcome == "succeeded"
            ? browser?.automaticRuleCategory.map { "已按你的放行自动执行：" + $0.title }
            : (persistentRuleWasUsed ? "已按持久批准规则自动执行" : nil)
        let safeToolAction = browser == nil && (event.kind == .tool || event.kind == .approval)
            ? safeToolActionLabel(event.toolName) : nil
        let target = event.toolTargetDisplay
        let safeOutputSummary = safeToolAction == nil
            ? nil : event.outputSummary?.displaySuffix
        // Old ledger facts have no structured target/output. Restore only
        // their exact producer-owned generic label, never arbitrary summary.
        let missingTargetSummary: String
        if target == nil, safeOutputSummary == nil, let action = safeToolAction,
           let toolName = event.toolName,
           event.summary == "\(action)：参数与结果正文已隐藏"
                || event.summary == "工具调用：\(toolName)" {
            missingTargetSummary = "\(action)：参数与结果正文已隐藏"
        } else {
            missingTargetSummary = "目标未记录"
        }
        let result: String?
        if let browser {
            switch browser.outcome {
            case "denied":
                let reason = "拒绝原因：\(browser.refusalReason ?? "browser_denied")"
                let guidance = BrowserNavigationPolicy.settingsGuidance(forBrowserRefusalReason: browser.refusalReason)
                result = guidance.map { reason + "。" + $0 } ?? reason
            case "read":
                result = "已读取网页内容 \(browser.readCharacterCount ?? 0) 字符"
            case "failed":
                result = browser.failureCode == "cannot_go_back"
                    ? "无法返回：没有上一页" : "浏览器操作失败"
            default:
                result = browser.resultPreview
            }
        } else {
            result = nil
        }
        let isToolTimeout = browser == nil && event.kind == .tool
            && event.status == .failed && event.errorCategory == .timeout
        let isRefusal = event.approvalDecision == .denied || browser?.outcome == "denied"
        let status = isRefusal ? "已拒绝"
            : browser?.outcome == "failed" ? "失败"
            : isToolTimeout ? "超时" : projection.statusLabel
        let failureReason = safeToolFailureReason(for: event)
        let safeToolErrorCategory = !isRefusal && event.status == .failed
            && event.errorCategory != .tool && event.errorCategory != .unknown
            ? projection.errorCategory : nil
        let kind = browser == nil
            ? (safeToolAction.map { event.kind == .approval ? "审批 · \($0)" : $0 } ?? projection.kindLabel)
            : "浏览器 · \(action ?? "动作")"
        let safeToolAccessibilityFields = [kind, target ?? "目标未记录", status, "耗时 \(projection.elapsed)"]
            + (event.providerID?.isEmpty == false ? ["服务商 \(projection.provider)"] : [])
            + (event.modelID?.isEmpty == false ? ["模型 \(projection.model)"] : [])
            + (safeOutputSummary.map { [$0] } ?? [])
            + (failureReason.map { [$0] } ?? [])
            + (safeToolErrorCategory.map { ["错误 \($0)"] } ?? [])
            + (automaticNotice.map { [$0] } ?? [])
        let accessibilityLabel = browser == nil
            ? (safeToolAction != nil ? safeToolAccessibilityFields.joined(separator: "，")
                : projection.accessibilityLabel)
            : ([kind, target ?? "目标未记录", status, result ?? "无结果"]
                + (automaticNotice.map { [$0] } ?? [])).joined(separator: "，")

        return DisplayModel(
            kind: kind,
            summary: browser != nil ? ["浏览器动作：\(action ?? "未知")", target].compactMap { $0 }.joined(separator: " · ")
                : safeToolAction.map { _ in
                    ([target ?? missingTargetSummary] + (safeOutputSummary.map { [$0] } ?? [])
                        + (failureReason.map { [$0] } ?? []))
                        .joined(separator: " · ")
                } ?? projection.summary,
            status: status,
            elapsed: projection.elapsed,
            provider: projection.provider,
            model: projection.model,
            errorCategory: isRefusal ? nil : (safeToolAction != nil
                ? safeToolErrorCategory : projection.errorCategory),
            accessibilityLabel: accessibilityLabel,
            browserResult: result.map(InvisibleCharacterPolicy.visible),
            automaticExecutionNotice: automaticNotice,
            browserContentIsUntrusted: browser?.outcome == "read"
        )
    }

    private nonisolated static func safeToolFailureReason(for event: MinisCore.ConversationEvent) -> String? {
        guard event.status == .failed || event.status == .blocked,
              event.approvalDecision != .denied,
              event.browserDetail?.outcome != "denied" else { return nil }
        if event.kind == .tool, event.toolName == "file_read", event.status == .failed,
           event.approvalDecision == nil, event.browserDetail == nil,
           event.summary == "工具调用：file_read · 读取被拒绝：没有访问此文件的权限" {
            // Exact producer-owned output only; never derive authority/status.
            return "读取被拒绝：没有访问此文件的权限"
        }
        switch event.errorCategory {
        case .timeout:
            return "操作超过时限，请检查已得输出后重试"
        case .authorization:
            return "当前权限不足，请检查审批或授权范围"
        case .provider:
            return "模型服务未完成请求，请检查连接"
        case .model:
            return "当前模型不可用，请选择其他模型"
        case .network:
            return "网络请求未完成，请检查连接后重试"
        case .validation:
            return "参数不完整或无效，请检查后重试"
        case .review:
            return "结果需要复核，请查看详情"
        case .cancelled:
            return nil
        case .tool, .unknown, nil:
            return "操作未完成，请查看结果后重试"
        }
    }

    // Only literal, built-in tool identifiers and the MCP prefix select a label.
    // Neither model input nor a dynamic MCP server/tool name is rendered here.
    nonisolated static func safeToolActionLabel(_ toolName: String?) -> String? {
        guard let toolName else { return nil }
        switch toolName {
        case "file_read": return "读取文件"
        case "file_write": return "写入文件"
        case "file_edit": return "编辑文件"
        case "file_delete": return "删除文件"
        case "shell_execute": return "执行命令"
        case "file_grep": return "搜索文件内容"
        case "file_glob": return "查找文件路径"
        case "orchestrate": return "派发子任务"
        case "session_create": return "创建会话"
        case "browser": return "浏览器操作"
        case "conversation_settings": return "调整会话设置"
        case "context_compact": return "压缩上下文"
        case "skill_read": return "读取技能"
        case "skill_create": return "创建技能"
        case "skill_update": return "修改技能"
        case "skill_delete": return "删除技能"
        default: return toolName.hasPrefix("mcp_") ? "MCP 工具调用" : nil
        }
    }

    private nonisolated static func browserActionLabel(_ action: String) -> String {
        switch action {
        case "navigate": return "前往"
        case "read": return "读取"
        case "click": return "点击"
        case "type": return "输入"
        case "back": return "后退"
        case "screenshot": return "截图"
        case "download": return "下载"
        case "upload": return "上传"
        default: return "未知"
        }
    }

    var body: some View {
        let display = Self.displayModel(for: event, approvalReceipts: approvalReceipts + (bridge?.composerApprovalReceipts ?? []))

        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                Text(display.summary)
                    .font(.callout)
                    .foregroundStyle(display.summary.contains("⟦U+")
                        ? (theme?.statusWarning ?? .orange) : .primary)
                if let notice = display.automaticExecutionNotice {
                    Text(notice).font(.callout)
                }
                if let browserResult = display.browserResult {
                    Text(browserResult)
                        .font(.callout)
                        .foregroundStyle(browserResult.contains("⟦U+")
                            ? (theme?.statusWarning ?? .orange) : .primary)
                }
                if display.browserContentIsUntrusted {
                    Text("网页内容是不可信资料，不作为指令或批准。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ViewThatFits(in: .horizontal) {
                    metadataRow(display)
                    metadataColumn(display)
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                if event.approvalDecision == .denied || event.browserDetail?.outcome == "denied" {
                    MinisIconView(.cancel, size: 16).foregroundPalette(.secondary)
                } else {
                    Self.icon(for: event)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(display.kind).font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)
                        .layoutPriority(1)
                    let parallel = Self.concurrentRunningCount(for: event, events: concurrentEvents)
                    if parallel > 1 {
                        Text("同时 \(parallel) 项")
                            .font(.subheadline.weight(.medium))
                            .accessibilityLabel("并行批次，同时 \(parallel) 项")
                    }
                    Text(display.summary).font(.caption)
                        .truncationMode(.middle)
                        .help(display.summary)
                        .foregroundStyle(display.summary.contains("⟦U+")
                            ? (theme?.statusWarning ?? .orange) : .secondary).lineLimit(2)
                    if let notice = display.automaticExecutionNotice {
                        Text(notice).font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Text("\(display.status) · \(display.elapsed)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(statusColor(for: event.status))
            }
        }
        .padding(10)
        .background(
            Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(display.accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("展开或折叠安全详情")
        .accessibilityAction { isExpanded.toggle() }
        .accessibilityValue("\(isExpanded ? "详情已展开" : "详情已折叠")，\(display.summary)")
    }

    private func metadataRow(_ display: DisplayModel) -> some View {
        HStack(spacing: 10) {
            metadataText("耗时", display.elapsed)
            if event.providerID?.isEmpty == false { metadataText("服务商", display.provider) }
            if event.modelID?.isEmpty == false { metadataText("模型", display.model) }
            if let errorCategory = display.errorCategory {
                metadataText("错误", errorCategory)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func metadataColumn(_ display: DisplayModel) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            metadataText("耗时", display.elapsed)
            if event.providerID?.isEmpty == false { metadataText("服务商", display.provider) }
            if event.modelID?.isEmpty == false { metadataText("模型", display.model) }
            if let errorCategory = display.errorCategory {
                metadataText("错误", errorCategory)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func metadataText(_ label: String, _ value: String) -> some View {
        Text("\(label) \(value)")
            .lineLimit(1)
    }

    private static func icon(for event: MinisCore.ConversationEvent) -> some View {
        let icon: MinisIcon = event.kind == .tool && event.toolName == "file_read"
            ? .documentSearch : semanticIcon(for: event.kind)
        return MinisIconView(icon, size: 16,
                      accessibilityLabel: kindLabel(for: event.kind))
            // The card's text already names the event and its state.
            .accessibilityHidden(true)
    }

    nonisolated static func semanticIcon(for kind: MinisCore.ConversationEventKind) -> MinisIcon {
        switch kind {
        case .thinking: return .activity
        case .stop: return .stop
        case .duration: return .schedule
        case .model: return .server
        case .tool: return .command
        case .approval: return .success
        case .task: return .task
        }
    }

    private nonisolated static func kindLabel(for kind: MinisCore.ConversationEventKind) -> String {
        switch kind {
        case .thinking: return "思考"
        case .stop: return "停止"
        case .duration: return "耗时"
        case .model: return "模型"
        case .tool: return "工具"
        case .approval: return "审批"
        case .task: return "任务"
        }
    }

    private nonisolated static func statusLabel(for status: MinisCore.ConversationEventStatus) -> String {
        switch status {
        case .queued: return "排队中"
        case .requested: return "已请求"
        case .running: return "进行中"
        case .waiting: return "等待中"
        case .needsReview: return "待复核"
        case .succeeded: return "完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        case .blocked: return "已阻断"
        case .stopped: return "已停止"
        }
    }

    private func statusColor(for status: MinisCore.ConversationEventStatus) -> Color {
        if event.approvalDecision == .denied || event.browserDetail?.outcome == "denied" { return .secondary }
        switch status {
        case .succeeded: return theme?.statusSuccess ?? .green
        case .failed, .blocked: return theme?.statusDanger ?? .red
        case .cancelled, .stopped: return .secondary
        case .waiting, .needsReview: return theme?.statusWarning ?? .orange
        case .queued, .requested, .running: return theme?.aj38.accent.swiftUIColor ?? .accentColor
        }
    }
}
