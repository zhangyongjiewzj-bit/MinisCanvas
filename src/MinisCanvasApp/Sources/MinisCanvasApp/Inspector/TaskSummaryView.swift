import SwiftUI
import MinisCore

/// Read-only task and child projection for the chat inspector.
/// Lifecycle facts remain owned by AgentTaskStore and Task Center.
struct TaskSummaryView: View {
    let currentTaskID: String?
    var viewerSessionID: String? = nil
    let taskSnapshots: [AgentTaskSnapshot]
    let receiptRows: [TaskCenterReceiptRow]
    /// Producer-side seam for child-transcript reachability (H3): this view
    /// only exposes the child row as an operable element carrying the public
    /// `TaskCenterChildSessionNavigation` identity already defined at head.
    /// The jump consumer is a separate lane and injects the handler here;
    /// until then the affordance stays exposed and the press is inert.
    /// Defaulted so the existing value-only call site compiles unchanged.
    var onOpenChildSession: ((TaskCenterChildSessionNavigation) -> Void)? = nil

    @Environment(\.themeTokens) private var theme
    @Environment(\.typographyTokens) private var typography

    private var currentTask: AgentTaskSnapshot? {
        guard let currentTaskID else { return nil }
        return taskSnapshots.first { $0.taskID == currentTaskID }
    }

    private var currentReceipt: TaskCenterReceiptRow? {
        guard let currentTaskID else { return nil }
        return receiptRows.first { $0.taskID == currentTaskID }
    }

    private var childProjection: TaskSummaryChildProjection {
        TaskSummaryChildProjection(currentTaskID: currentTaskID, receiptRows: receiptRows,
            viewerSessionID: viewerSessionID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            currentTaskSection
            childSection
        }
    }

    private var currentTaskSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let currentReceipt {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor(currentReceipt.lifecycleState))
                        .frame(width: 7, height: 7)
                    Text(currentReceipt.statusTitle)
                        .font((typography?.contextBody ?? .system(size: 10)).weight(.medium))
                    if currentReceipt.isStale {
                        Text("陈旧观测")
                            .font(typography?.caption ?? .system(size: 10))
                            .foregroundStyle(theme?.aj38.danger.swiftUIColor ?? .red)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("当前任务，状态：\(currentReceipt.statusTitle)")

                DisclosureGroup("内部 identity") {
                    InspectorValueRow("Task", currentReceipt.taskID)
                    InspectorValueRow("Parent", currentReceipt.parentID)
                    InspectorValueRow("Run", currentReceipt.runID ?? "未创建")
                    InspectorValueRow("Attempt", currentReceipt.attemptID ?? "未创建")
                    InspectorValueRow("Receipt", currentReceipt.receiptID)
                }
                .font(typography?.caption ?? .system(size: 10))
            } else if let currentTask {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor(currentTask.status))
                        .frame(width: 7, height: 7)
                    Text(statusTitle(currentTask.status))
                        .font((typography?.contextBody ?? .system(size: 10)).weight(.medium))
                    Spacer(minLength: 0)
                }
                DisclosureGroup("内部 identity") {
                    InspectorValueRow("Task", currentTask.taskID)
                    InspectorValueRow("Parent", currentTask.parentID)
                }
                .font(typography?.caption ?? .system(size: 10))
            } else if taskSnapshots.isEmpty {
                InspectorEmptyState(text: "当前会话暂无任务事实")
            } else {
                InspectorEmptyState(text: "当前任务尚未产生可读回执")
            }

            if !taskSnapshots.isEmpty {
                Text("当前会话 \(taskSnapshots.count) 个任务投影")
                    .font(typography?.caption ?? .system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var childSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("子智能体")
                .font((typography?.caption ?? .system(size: 10)).weight(.semibold))
                .foregroundStyle(.secondary)
            if childProjection.rows.isEmpty {
                InspectorEmptyState(text: "暂无子任务投影")
            } else {
                Text(childProjection.summaryTitle)
                    .font(typography?.caption ?? .system(size: 10))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("child-agent-counts")
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(childProjection.rows) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(statusColor(row.lifecycleState))
                                    .frame(width: 6, height: 6)
                                Text(row.isStale ? "\(row.statusTitle) · 陈旧观测" : row.statusTitle)
                                    .font(typography?.contextBody ?? .system(size: 10))
                                Spacer(minLength: 0)
                            }
                            Text("步骤：\(row.currentStepTitle) · \(childProjection.progressTitle(for: row))")
                                .font(typography?.caption ?? .system(size: 10))
                                .foregroundStyle(.secondary)
                            DisclosureGroup("子任务详情") {
                                InspectorValueRow("Task", row.taskID)
                                InspectorValueRow("Parent", row.parentID)
                                InspectorValueRow("Run", row.runID ?? "未创建")
                                InspectorValueRow("Attempt", row.attemptID ?? "未创建")
                                InspectorValueRow("结果", row.resultSummaryTitle)
                                if let childSessionID = row.childSessionID {
                                    Button {
                                        if childProjection.allowsCurrentTaskNavigation(row),
                                           let navigation = row.childNavigation {
                                            onOpenChildSession?(navigation)
                                        }
                                    } label: {
                                        InspectorValueRow("子会话", childSessionID)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(!childProjection.allowsCurrentTaskNavigation(row) || onOpenChildSession == nil)
                                    .help(childProjection.allowsCurrentTaskNavigation(row)
                                        ? "查看子会话" : "历史子任务可在任务中心查看")
                                    // Single-element AX recipe converged by the
                                    // 161/190 gate: combine first, then declare
                                    // traits/label/default action/identifier on
                                    // the projected element (declared ≠ exposed).
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityLabel(
                                        row.childNavigation?.accessibilityLabel
                                            ?? "打开子会话 \(childSessionID)"
                                    )
                                    .accessibilityValue("打开并保留父任务位置")
                                    .accessibilityAction {
                                        if childProjection.allowsCurrentTaskNavigation(row),
                                           let navigation = row.childNavigation {
                                            onOpenChildSession?(navigation)
                                        }
                                    }
                                    .accessibilityIdentifier("task-summary-child-session-\(childSessionID)")
                                }
                                if let failureReason = row.failureReason {
                                    InspectorValueRow("原因", failureReason, tint: theme?.aj38.danger.swiftUIColor ?? .red)
                                }
                            }
                            .font(typography?.caption ?? .system(size: 10))
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    private func statusTitle(_ status: AgentTaskStatus) -> String {
        switch status {
        case .queued: return "排队"
        case .running: return "运行中"
        case .succeeded: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }

    private func statusColor(_ status: AgentTaskStatus) -> Color {
        switch status {
        case .queued: return theme?.statusInfo ?? AppStatusColor.info
        case .running: return theme?.statusWarning ?? AppStatusColor.warning
        case .succeeded: return theme?.statusSuccess ?? .green
        case .failed: return theme?.aj38.danger.swiftUIColor ?? .red
        case .cancelled: return .secondary
        }
    }

    private func statusColor(_ status: TaskCenterReceiptState) -> Color {
        switch status {
        case .queued, .inputRequired: return theme?.statusInfo ?? AppStatusColor.info
        case .running, .approvalRequired, .retrying: return theme?.statusWarning ?? AppStatusColor.warning
        case .completed: return theme?.statusSuccess ?? .green
        case .failed: return theme?.aj38.danger.swiftUIColor ?? .red
        case .cancelled: return .secondary
        }
    }
}

/// A value-only summary of the already scoped Task Center receipt rows.
/// Unknown or stale event progress never becomes a fabricated percentage.
struct TaskSummaryChildProjection {
    let rows: [TaskCenterReceiptRow]
    private let currentTaskID: String?

    init(currentTaskID: String?, receiptRows: [TaskCenterReceiptRow], viewerSessionID: String? = nil) {
        self.currentTaskID = currentTaskID
        guard let currentTaskID else {
            // Only a validated canonical locator proves historical ownership.
            // Absence of a current run is not evidence that its children vanished.
            rows = receiptRows.filter { row in
                guard let viewerSessionID, let navigation = row.childNavigation else { return false }
                return navigation.locator != nil && navigation.parentSessionID == viewerSessionID
            }
            return
        }
        rows = receiptRows.filter {
            $0.parentID == currentTaskID && $0.taskID != currentTaskID
        }
    }

    func allowsCurrentTaskNavigation(_ row: TaskCenterReceiptRow) -> Bool {
        guard let currentTaskID else { return false }
        return row.parentID == currentTaskID && row.taskID != currentTaskID
    }

    private var currentRows: [TaskCenterReceiptRow] { rows.filter { !$0.isStale } }
    var runningCount: Int { currentRows.filter { $0.lifecycleState == .running }.count }
    var approvalCount: Int { currentRows.filter { $0.lifecycleState == .approvalRequired }.count }
    var failedCount: Int { currentRows.filter { $0.lifecycleState == .failed }.count }
    var completedCount: Int { currentRows.filter { $0.lifecycleState == .completed }.count }
    var staleCount: Int { rows.count - currentRows.count }
    var otherCount: Int {
        currentRows.count - runningCount - approvalCount - failedCount - completedCount
    }

    var summaryTitle: String {
        var parts = [
            "子智能体 \(rows.count) 个",
            "运行 \(runningCount)",
            "待审批 \(approvalCount)",
            "失败 \(failedCount)",
            "完成 \(completedCount)"
        ]
        if otherCount > 0 { parts.append("其他状态 \(otherCount)") }
        if staleCount > 0 { parts.append("观测待核 \(staleCount)") }
        return parts.joined(separator: " · ")
    }

    func progressTitle(for row: TaskCenterReceiptRow) -> String {
        guard !row.isStale, let eventProgressTitle = row.eventProgressTitle else {
            return "进度未知"
        }
        return "进度：\(eventProgressTitle)"
    }
}
