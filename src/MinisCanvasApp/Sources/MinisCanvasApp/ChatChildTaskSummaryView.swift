import SwiftUI
import MinisCore

/// Mounted observations only; every action retains the canonical receipt row.
@MainActor
struct ChatChildTaskSummaryView: View {
    var onOpen: ((TaskCenterChildSessionNavigation) -> Void)? = nil
    var onStop: ((TaskCenterReceiptRow) throws -> Void)? = nil
    let readProjection: () -> TaskSummaryChildProjection
    @Environment(\.typographyTokens) private var typography
    @Environment(\.themeTokens) private var theme
    @FocusState private var focusedRowID: String?
    @State private var actionError: String?

    var body: some View {
        // 外层读一次投影：读取里的观察信号（toolLifecyclePresentationRevision）变化时重算；
        // 没有进行中/状态待更新的子任务时时钟暂停，空闲不再每 0.5 秒重算。
        let current = readProjection()
        let needsClock = current.rows.contains { $0.cancelAvailable || $0.isStale }
        TimelineView(.animation(minimumInterval: 0.5, paused: !needsClock)) { _ in
            let projection = needsClock ? readProjection() : current
            if !projection.rows.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(projection.summaryTitle)
                        .font(typography?.headline ?? .headline)
                        .accessibilityIdentifier("chat-child-summary-counts")
                    ForEach(projection.rows) { row in
                        taskRow(row, projection: projection)
                    }
                    if let actionError {
                        Text(actionError).font(typography?.caption ?? .caption)
                            .foregroundStyle(theme?.statusWarning ?? .orange)
                    }
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("chat-child-summary")
            }
        }
    }

    private func taskRow(_ row: TaskCenterReceiptRow, projection: TaskSummaryChildProjection) -> some View {
        rowContent(row, projection: projection)
            .padding(10)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .contain)
            .focusedValue(\.chatStopAction, projection.allowsCurrentTaskNavigation(row) ? focusedStopAction(for: row) : nil)
            .onKeyPress(.return) {
                projection.allowsCurrentTaskNavigation(row) ? handleOpenKey(row: row) : .ignored
            }
            .onKeyPress(.upArrow) { handleFocusKey(-1, rows: projection.rows) }
            .onKeyPress(.downArrow) { handleFocusKey(1, rows: projection.rows) }
            .onKeyPress(KeyEquivalent("."), phases: [.down, .repeat]) { key in
                projection.allowsCurrentTaskNavigation(row) ? handleStopKey(key, row: row) : .ignored
            }
    }

    private func rowContent(_ row: TaskCenterReceiptRow, projection: TaskSummaryChildProjection) -> some View {
        HStack(spacing: 8) {
            Button {
                if let navigation = row.childNavigation { onOpen?(navigation) }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Self.rowTitle(row, projection: projection))
                        .font(typography?.contextBody ?? .body)
                    Text("来源：当前会话 · \(row.durationTitle())")
                        .font(typography?.caption ?? .caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(row.childNavigation == nil || onOpen == nil || !projection.allowsCurrentTaskNavigation(row))
            .help(projection.allowsCurrentTaskNavigation(row)
                ? "查看子任务" : "历史子任务可在任务中心查看")
            .focused($focusedRowID, equals: row.stableID)
            .accessibilityLabel("查看子任务，\(Self.rowTitle(row, projection: projection))")
            .accessibilityIdentifier("chat-child-summary-\(row.stableID)")
            if projection.allowsCurrentTaskNavigation(row), row.cancelAvailable, let onStop {
                Button("停止") {
                    do { try onStop(row); actionError = nil }
                    catch { actionError = "任务状态已变化，请在任务中心重试。" }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("停止子任务 \(Self.title(row))")
                .accessibilityIdentifier("chat-child-stop-\(row.stableID)")
            }
        }
    }

    private func focusedStopAction(for row: TaskCenterReceiptRow) -> (@MainActor @Sendable () -> Void)? {
        guard row.cancelAvailable, onStop != nil else { return nil }
        return {
            do { try onStop?(row); actionError = nil }
            catch { actionError = "任务状态已变化，请在任务中心重试。" }
        }
    }

    private func handleOpenKey(row: TaskCenterReceiptRow) -> KeyPress.Result {
        guard focusedRowID == row.stableID,
              let navigation = row.childNavigation,
              let onOpen else { return .ignored }
        onOpen(navigation)
        return .handled
    }

    private func handleFocusKey(_ delta: Int, rows: [TaskCenterReceiptRow]) -> KeyPress.Result {
        moveFocus(delta, rows: rows)
        return .handled
    }

    private func handleStopKey(_ key: KeyPress, row: TaskCenterReceiptRow) -> KeyPress.Result {
        guard key.modifiers == EventModifiers.command,
              focusedRowID == row.stableID,
              row.cancelAvailable,
              let onStop else { return .ignored }
        do { try onStop(row); actionError = nil }
        catch { actionError = "任务状态已变化，请在任务中心重试。" }
        return .handled
    }

    private func moveFocus(_ delta: Int, rows: [TaskCenterReceiptRow]) {
        guard !rows.isEmpty else { return }
        let index = rows.firstIndex { $0.stableID == focusedRowID } ?? 0
        focusedRowID = rows[min(max(index + delta, 0), rows.count - 1)].stableID
    }

    static func title(_ row: TaskCenterReceiptRow) -> String {
        TaskCenterRowLabelFormatter.title(row.userTitle, taskID: row.taskID)
    }

    static func rowTitle(_ row: TaskCenterReceiptRow,
                         projection: TaskSummaryChildProjection) -> String {
        let status = row.isStale ? "\(row.statusTitle) · 状态待更新" : row.statusTitle
        let activity = row.childToolActivityTitle.map { " · " + $0 } ?? ""
        return "\(title(row)) · \(status) · 最近：\(row.currentStepTitle) · \(row.resultSummaryTitle)" + activity
    }
}
