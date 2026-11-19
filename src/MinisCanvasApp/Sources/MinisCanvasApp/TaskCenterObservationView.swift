import Foundation
import SwiftUI
import MinisCore

/// Selection follows the Task Center's canonical presentation order. It never
/// creates or changes a task, and a stale selection starts from the current head.
enum TaskCenterNextTaskSelection {
    static func nextID(in rows: [TaskCenterReceiptRow], after selectedID: String?) -> String? {
        guard !rows.isEmpty else { return nil }
        guard let selectedID,
              let index = rows.firstIndex(where: { $0.stableID == selectedID }) else {
            return rows[0].stableID
        }
        return rows[(index + 1) % rows.count].stableID
    }
}

/// Compact labels use existing metadata; filtering continues to use source IDs.
enum TaskCenterRowLabelFormatter {
    static func title(_ userTitle: String?, taskID: String) -> String {
        guard let title = userTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty, title != taskID, UUID(uuidString: title) == nil
        else { return "未命名任务" }
        return title
    }

    static func sourceLabels(ids: [String], knownTitles: [String: String]) -> [String: String] {
        let sortedIDs = Array(Set(ids)).sorted()
        let names = sortedIDs.map { id -> String? in
            guard let title = knownTitles[id]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty, title != id, UUID(uuidString: title) == nil
            else { return nil }
            return title
        }
        return Dictionary(uniqueKeysWithValues: sortedIDs.enumerated().map { index, id in
            let fallback = "来源会话 \(index + 1)"
            guard let name = names[index] else { return (id, fallback) }
            return (id, names.filter { $0 == name }.count == 1 ? name : "\(name)（\(fallback)）")
        })
    }

    static func blockedAccessibilityLabel(title: String, state: TaskCenterReceiptState) -> String {
        "任务 " + title + "，" + state.title + "，需要处理"
    }

    static func observationAccessibilityLabel(title: String, state: TaskCenterObservationState) -> String {
        "任务 " + title + "，观测状态 " + state.title
    }

    static func controlAccessibilityLabel(title: String, action: TaskCenterControlAction) -> String {
        action.title + "任务 " + title
    }

    static func source(_ sourceID: String?, labels: [String: String]) -> String {
        guard let sourceID else { return "来源未知" }
        return labels[sourceID] ?? "来源会话不可用"
    }

    static func accessibilityLabel(
        title: String, source: String, status: String, step: String,
        progress: String, duration: String, result: String, recovery: String? = nil
    ) -> String {
        var parts = [
            "任务 \(title)", "状态 \(status)", "来源会话 \(source)",
            "当前步骤 \(step)", "进度 \(progress)", "耗时 \(duration)", "结果 \(result)"
        ]
        if let recovery { parts.append(recovery) }
        return parts.joined(separator: "，")
    }

    static func recoveryAccessibilitySummary(for row: TaskCenterReceiptRow?) -> String? {
        row?.recoveryState == .needsUserReview ? "恢复：需要人工复核" : nil
    }
}

/// Task-center surface backed by the canonical AgentTaskStore projection.
/// Observation remains read-only; controls enter only through the Bridge consumer.
struct TaskCenterObservationView: View {
    @Environment(\.themeTokens) private var theme
    @State private var ledgerSignature: [UInt64] = []
    @State private var confirmsStopAllBackground = false
    let bridge: BridgeStore
    let initialChildNavigation: TaskCenterChildSessionNavigation?
    let initialTaskStableID: String?
    let isSidebar: Bool
    let onClose: (@MainActor @Sendable () -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.typographyTokens) private var typography
    @State private var showsResidualWorktrees = false
    @FocusState private var panelFocused: Bool
    @State private var controlError: TaskCenterControlConsumerError?
    @State private var selectedFilterStatus: TaskCenterFilterStatus?
    @State private var selectedSourceSessionID: String?
    @State private var showArchivedHistory = false
    @State private var showRecentHistory = false
    @State private var showSystemActivity = false
    @State private var showsInitialChildSession = false
    @State private var didProcessInitialChildNavigation = false
    @State private var selectedTaskStableID: String?

    init(
        bridge: BridgeStore,
        initialChildNavigation: TaskCenterChildSessionNavigation? = nil,
        initialTaskStableID: String? = nil,
        isSidebar: Bool = false,
        onClose: (@MainActor @Sendable () -> Void)? = nil
    ) {
        self.bridge = bridge
        self.initialChildNavigation = initialChildNavigation
        self.initialTaskStableID = initialTaskStableID
        self.isSidebar = isSidebar
        self.onClose = onClose
    }

    private func selectNotificationTask(_ stableID: String) {
        guard let row = bridge.taskCenterControlConsumer.receiptRows().first(where: { $0.stableID == stableID }) else {
            selectedTaskStableID = nil
            return
        }
        // Completed targets may be older than the default recent-history cap.
        // Use the existing status/source filter so the exact row is visible.
        selectedSourceSessionID = row.sourceSessionID
        selectedFilterStatus = row.lifecycleState == .completed ? .completed
            : row.lifecycleState == .failed ? .failed : nil
        showArchivedHistory = false
        showRecentHistory = true
        selectedTaskStableID = stableID
    }

    private var nextTaskCommand: PaletteCommand? {
        AppCommandMenuBuilder.command(
            id: "ui.taskcenter.next", registry: bridge.commandRegistry,
            display: bridge.paletteDisplay
        )
    }

    private func consumeNextTaskCommands(from previous: UInt64, to currentCount: UInt64) {
        guard currentCount > previous else { return }
        selectedFilterStatus = nil
        selectedSourceSessionID = nil
        showArchivedHistory = false
        let current = bridge.taskCenterControlConsumer.homeReceiptSections(
            TaskCenterReceiptFilter()
        ).current
        for _ in previous..<currentCount {
            selectedTaskStableID = TaskCenterNextTaskSelection.nextID(
                in: current, after: selectedTaskStableID
            )
        }
    }


    /// Focused field instrumentation seam for NSHosting/AppKit measurement.
    @MainActor
    internal func typographyInstrumentationView() -> AnyView {
        AnyView(self)
    }

    var body: some View {
        let dismissAction = dismiss
        let closePresentation: @MainActor @Sendable () -> Void = { [onClose, dismissAction] in
            if let onClose { onClose() } else { dismissAction() }
        }
        let residualWorktreesPresentation = $showsResidualWorktrees
        let canEnterPanel = initialChildNavigation == nil
        return NavigationStack {
            // 不再用计时器包住整个界面：只在账本数据变化时重算（见下面的 .task），
            // 随时间走的文案（后台命令用时）由 BackgroundCommandsSection 自带时钟。
            Group {
                let _ = ledgerSignature
                let observation = bridge.taskCenterObservation
                let goalProjection = bridge.taskCenterGoalProjection(now: .now)
                let consumer = bridge.taskCenterControlConsumer
                let allReceiptRows = bridge.taskCenterControlConsumer.receiptRowsReusingVersion(includeArchived: true)
                let filter = TaskCenterReceiptFilter(
                    status: selectedFilterStatus,
                    sourceSessionID: selectedSourceSessionID,
                    includeArchived: showArchivedHistory
                )
                let receiptRows = consumer.filteredReceiptRows(filter, now: .now)
                let homeSections = consumer.homeReceiptSections(filter, now: .now)
                let archivedReceiptRows = receiptRows.filter(\.isArchived)
                let sourceSessionIDs = Array(
                    Set(allReceiptRows.compactMap(\.sourceSessionID))
                ).sorted()
                let knownSessionTitles = Dictionary(
                    bridge.chat.sessions.map { ($0.id.uuidString, $0.title) },
                    uniquingKeysWith: { first, _ in first }
                )
                let sourceLabels = TaskCenterRowLabelFormatter.sourceLabels(
                    ids: sourceSessionIDs,
                    knownTitles: knownSessionTitles
                )
                ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        summary(consumer.userTaskObservation())
                        let backgroundCount = consumer.backgroundChildCount()
                        if backgroundCount > 0 {
                            Button("停止全部后台子任务", role: .destructive) {
                                confirmsStopAllBackground = true
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("task-center-stop-all-background")
                            .confirmationDialog("停止全部后台子任务？", isPresented: $confirmsStopAllBackground,
                                                titleVisibility: .visible) {
                                Button("停止全部", role: .destructive) {
                                    Task { await consumer.stopAllBackgroundChildren() }
                                }
                                Button("取消", role: .cancel) {}
                            } message: {
                                Text("会中断所有仍在后台运行的子任务；已经完成的结果不受影响。")
                            }
                        }
                        BackgroundCommandsSection(registry: .shared, sessionTitles: knownSessionTitles)
                        if bridge.approvalCenter.pendingExecutionOrigin.isUnattended,
                           bridge.approvalCenter.pendingRequest != nil {
                            Label {
                                Text("无人值守任务已挂起，等待审批")
                            } icon: {
                                MinisIconView(.pause, size: 12)
                            }
                            .accessibilityLabel("无人值守任务已挂起，等待审批")
                            .accessibilityIdentifier("task-center-unattended-approval")
                            Text("可在设置 › 常规 › 通知中开启审批通知。")
                                .font(typography?.caption ?? .caption)
                                .foregroundStyle(.secondary)
                        }
                        let queuedApprovals = bridge.approvalCenter.approvalQueue.queuedRequests
                        if !queuedApprovals.isEmpty {
                            DisclosureGroup("排队待审批（\(queuedApprovals.count)）") {
                                Text("先处理当前审批；后续请求按顺序显示。")
                                    .font(typography?.caption ?? .caption)
                                    .foregroundStyle(.secondary)
                                ForEach(queuedApprovals, id: \.id) { request in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(request.toolName)
                                        Text(request.inputSummary)
                                            .font(typography?.caption ?? .caption)
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                            .accessibilityIdentifier("task-center-queued-approvals")
                        }
                        if let controlError {
                            Text(controlError.userMessage)
                                .font(typography?.caption ?? .caption)
                                .modifier(ReadableStatusForeground(status: .danger))
                                .accessibilityIdentifier("task-center-control-error")
                        }
                        filterBar(sourceSessionIDs: sourceSessionIDs, sourceLabels: sourceLabels)
                        if selectedFilterStatus != nil || selectedSourceSessionID != nil || showArchivedHistory {
                            taskList(observation, goalProjection: goalProjection,
                                     receiptRows: receiptRows.filter { !$0.isArchived }, sourceLabels: sourceLabels)
                        } else {
                            taskList(observation, goalProjection: goalProjection,
                                     receiptRows: homeSections.current, sourceLabels: sourceLabels)
                            if !homeSections.recentHistory.isEmpty {
                                Button { [history = $showRecentHistory] in
                                    history.wrappedValue.toggle()
                                } label: {
                                    Text("最近历史（\(homeSections.recentHistory.count) 条，最多 \(TaskCenterControlConsumer.defaultRecentHistoryLimit) 条）")
                                }
                                .accessibilityValue(showRecentHistory ? "已展开" : "已折叠")
                                .accessibilityIdentifier("tasks-history-toggle")
                                if showRecentHistory {
                                    taskList(observation, goalProjection: goalProjection,
                                             receiptRows: homeSections.recentHistory, sourceLabels: sourceLabels)
                                        .accessibilityIdentifier("tasks-history")
                                }
                            }
                        }
                        if showArchivedHistory {
                            archivedTaskList(rows: archivedReceiptRows, sourceLabels: sourceLabels)
                        }
                        DisclosureGroup("高级与授权") {
                            childConcurrencySummary(selection: bridge.childConcurrencySelection)
                            goalSummary(goalProjection)
                            if let externalSession = consumer.externalSessionRuntime {
                                externalSessionSummary(externalSession)
                            }
                            ExternalSessionAuthorizationLedgerView()
                        }
                        .accessibilityIdentifier("tasks-advanced-authorization")
                        Toggle("高级系统活动", isOn: $showSystemActivity)
                            .toggleStyle(.checkbox)
                            .accessibilityIdentifier("tasks-diagnostics-toggle")
                        if showSystemActivity {
                            let counts = consumer.sessionActionDiagnosticObservation().counts
                            let activityText = "会话控制：\(counts.total) · 排队 \(counts.queued) · 运行中 \(counts.running) · 已完成 \(counts.succeeded) · 失败 \(counts.failed) · 已取消 \(counts.cancelled)"
                            Text(activityText)
                                .font(typography?.caption ?? .caption)
                                .accessibilityLabel(activityText)
                                .accessibilityIdentifier("tasks-session-activity")
                        }
                    }
                    .padding(20)
                }
                .frame(minWidth: isSidebar ? 320 : 520, minHeight: 420)
                .accessibilityIdentifier("task-center-observation")
                .onAppear {
                    if let initialTaskStableID { selectNotificationTask(initialTaskStableID) }
                }
                .onChange(of: bridge.taskCenterOpenIntent?.id) { _, _ in
                    if let id = bridge.taskCenterOpenIntent?.initialTaskStableID { selectNotificationTask(id) }
                }
                .onChange(of: selectedTaskStableID) { _, selectedID in
                    guard let selectedID else { return }
                    scrollProxy.scrollTo(selectedID, anchor: .top)
                }
                .background {
                    Button("") { [weak bridge] in
                        bridge?.runCommand(id: "ui.taskcenter.next")
                    }
                    .shortcutKey(bridge.shortcutStore.binding(for: .nextTask))
                    .disabled(nextTaskCommand?.isEnabled != true)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
                }
                }
            }
            .task {
                // 每 0.5 秒只比一次廉价签名（账本版本 + 后台子任务数 + 10 秒时间段）；变了才改状态、触发重算。
                while !Task.isCancelled {
                    let current = bridge.taskCenterControlConsumer.observationSignature(now: .now)
                    if current != ledgerSignature { ledgerSignature = current }
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            .navigationTitle("任务中心")
            .sheet(isPresented: $showsResidualWorktrees) {
                P03CleanupAppView(controller: bridge.p03CleanupAppController,
                                  approvalCenter: bridge.approvalCenter, shortcutStore: bridge.shortcutStore)
            }
            .onChange(of: showsResidualWorktrees) { _, shown in
                bridge.p03CleanupAppController.isPanelPresented = shown
            }
            .toolbar {
                ToolbarItem {
                    Button("残留子任务隔离工作树") { [residualWorktreesPresentation, weak bridge] in
                        // Set before the sheet exists so the outer approval sheet
                        // never competes with the panel for even one frame.
                        // Weak: AppKit keeps toolbar items alive after the window closes.
                        bridge?.p03CleanupAppController.isPanelPresented = true
                        residualWorktreesPresentation.wrappedValue = true
                    }
                        .accessibilityIdentifier("task-center.residual-worktrees")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button { [closePresentation] in
                        closePresentation()
                    } label: {
                        MinisIconView(
                            .close,
                            size: 16,
                            accessibilityLabel: "关闭任务中心"
                        )
                    }
                    .help("关闭任务中心")
                    .keyboardShortcut("w", modifiers: .command)
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("关闭任务中心")
                    .accessibilityValue("返回当前窗口")
                    .accessibilityAction { [closePresentation] in closePresentation() }
                    .accessibilityIdentifier("task-center-close")
                }
            }
            .navigationDestination(isPresented: $showsInitialChildSession) {
                if let initialChildNavigation {
                    TaskCenterChildSessionView(
                        navigation: initialChildNavigation,
                        consumer: bridge.taskCenterControlConsumer
                    )
                }
            }
            .onAppear {
                guard !didProcessInitialChildNavigation else { return }
                didProcessInitialChildNavigation = true
                guard let initialChildNavigation,
                      bridge.taskCenterControlConsumer.childTranscript(
                          navigation: initialChildNavigation
                      ) != nil else { return }
                showsInitialChildSession = true
            }
        }
        .focusable()
        .focused($panelFocused)
        .background {
            if isSidebar {
                WindowAccessor(
                    purpose: .passiveWindowAccess,
                    canReceiveUnclaimedCancel: { [weak bridge, canEnterPanel] window in
                        guard canEnterPanel, let bridge else { return false }
                        return window.isKeyWindow && window.attachedSheet == nil
                            && !bridge.approvalCenter.isPromptPresented
                            && !bridge.isCommandPalettePresented
                            && !FloatingMenuHost.shared.isPresented
                    },
                    onUnclaimedCancel: closePresentation
                )
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            }
        }
        .onChange(of: bridge.taskCenterNextCommandCount) { previous, currentCount in
            consumeNextTaskCommands(from: previous, to: currentCount)
        }
        .onExitCommand { [closePresentation] in
            if let input = NSApp.keyWindow?.firstResponder as? ComposerPasteAwareTextView,
               input.cancelMarkedCompositionForEscape() { return }
            closePresentation()
        }
        .escapeShortcut(closeSheet: { [closePresentation] in
            if let input = NSApp.keyWindow?.firstResponder as? ComposerPasteAwareTextView,
               input.cancelMarkedCompositionForEscape() { return true }
            closePresentation()
            return true
        })
        .font(typography?.body ?? .body)
    }

    private func summary(_ observation: TaskCenterObservationSnapshot) -> some View {
        let counts = observation.counts
        return AdaptiveControlRowLayout(spacing: 14) {
            TaskCenterMetric(title: "全部", value: counts.total, tint: .secondary)
            TaskCenterMetric(title: "排队", value: counts.queued, tint: theme?.statusInfo ?? AppStatusColor.info)
            TaskCenterMetric(title: "运行中", value: counts.running, tint: theme?.statusWarning ?? AppStatusColor.warning)
            TaskCenterMetric(title: "已完成", value: counts.succeeded, tint: theme?.statusSuccess ?? AppStatusColor.success)
            TaskCenterMetric(title: "失败", value: counts.failed, tint: theme?.statusDanger ?? AppStatusColor.danger)
            TaskCenterMetric(title: "已取消", value: counts.cancelled, tint: .secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task-center-summary")
    }

    /// P3-CHILD-40 / D-CHILDB「并列展示selected/recommended/effective/actual/
    /// queued与原因」renderer half. The five quantities and their per-stage
    /// reasons come from the ONE value object sealed by lane 178
    /// (`ChildConcurrencySelection.sideBySideProjection` / `sideBySideSummary`);
    /// this row never re-derives a value and never fabricates a cause. While the
    /// reporter (BridgeStore, owned by another lane's serial queue) has not fed a
    /// `RuntimeReport`, the actual/queued stages render 未上报 — deliberately not
    /// the task-ledger tally, which stays visible in `summary(observation)`
    /// above and is a different quantity (see lane 178 receipt spec_block Q1).
    private func childConcurrencySummary(
        selection: ChildConcurrencySelection
    ) -> some View {
        let rows = selection.sideBySideProjection
        return Self.childConcurrencyRowLayout {
            Label {
                Text("子 Agent 并发")
            } icon: {
                MinisIconView(.branch, size: 14, accessibilityLabel: "子 Agent 并发")
            }
            ForEach(rows, id: \.stage) { row in
                Text(row.displayText)
                    .foregroundStyle(row.deviations.isEmpty ? Color.secondary : (theme?.statusWarning ?? AppStatusColor.warning))
                    .accessibilityIdentifier("task-center-child-concurrency-\(row.stage.rawValue)")
            }
            Text(Self.childConcurrencyCeilingText)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .font(typography?.caption ?? .caption)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("task-center-child-concurrency")
        .accessibilityLabel(Self.childConcurrencyAccessibilityLabel(selection: selection))
    }

    /// The five-stage row shares the same allocated-width policy as the task
    /// controls, context tabs, terminal confirmation and browser toolbar.
    static var childConcurrencyRowLayout: AdaptiveControlRowLayout {
        AdaptiveControlRowLayout(spacing: 12)
    }

    /// The hard-ceiling chip kept from the pre-D-CHILDB row. Lane 178 receipt
    /// spec_block ambiguity_4 leaves whether it stays part of the row open to C0;
    /// this renderer keeps it byte-identical rather than deleting it on its own.
    static var childConcurrencyCeilingText: String {
        "硬上限 \(ChildConcurrencySelection.hardMaximum)"
    }

    /// The row's visible chip texts in canonical order: the five stage rows
    /// (each already composed as `标题 值（原因；原因）` by the value object)
    /// followed by the ceiling chip. Single source for visual and AX surfaces so
    /// neither can drift from the other.
    static func childConcurrencyRowTexts(selection: ChildConcurrencySelection) -> [String] {
        selection.sideBySideProjection.map(\.displayText) + [childConcurrencyCeilingText]
    }

    /// Full combined-AX label for the row: the same five stages plus the ceiling,
    /// taken verbatim from `sideBySideSummary` per lane 178's sealed delta.
    static func childConcurrencyAccessibilityLabel(selection: ChildConcurrencySelection) -> String {
        "子 Agent 并发，\(selection.sideBySideSummary)，\(childConcurrencyCeilingText)"
    }

    private func goalSummary(_ projection: GoalTaskCenterProjection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label {
                    Text("任务授权")
                        .accessibilityIdentifier("typography.task.goal-headline")
                } icon: {
                    MinisIconView(.target, size: 16, accessibilityLabel: "任务授权")
                }
                .font(typography?.headline ?? .headline)
                Spacer()
                Text(bridge.taskCenterControlConsumer.isAvailable ? "生产控制已接入" : "只读投影")
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
            }

            if projection.goals.isEmpty {
                Text(
                    bridge.taskCenterControlConsumer.isAvailable
                        ? "当前没有绑定任务授权的任务（这里不是会话目标）"
                        : "任务授权功能未接入，控制动作保持关闭"
                )
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(projection.goals, id: \.goalID) { goal in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(goal.scopeID)
                            .font(typography?.monospaced ?? .system(.body, design: .monospaced))
                            .lineLimit(1)
                        Spacer()
                        Text("\(goal.budget) · \(leaseTitle(goal.leaseState))")
                            .font(typography?.caption ?? .caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(leaseAccessibilityLabel(goal.leaseState))
                            .accessibilityIdentifier(
                                "task-center-lease-state-\(goal.goalID.uuidString)"
                            )
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("task-center-goal-\(goal.goalID.uuidString)")
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task-center-goal-summary")
    }

    private func externalSessionSummary(
        _ projection: TaskCenterExternalSessionProjection
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("外部会话")
            } icon: {
                MinisIconView(.branch, size: 16, accessibilityLabel: "外部会话")
            }
            Text(projection.snapshot.userMessage)
                .font(typography?.caption ?? .caption)
                .foregroundStyle(
                    projection.snapshot.state == .connected
                        ? Color.secondary
                        : (theme?.statusWarning ?? AppStatusColor.warning)
                )
            if let backlink = projection.snapshot.lastOutputBacklink {
                Text("最近输出回链：\(backlink.threadID.rawValue) · 第 \(backlink.sequence) 条")
                    .font(typography?.caption2 ?? .caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Text(
                projection.snapshot.recoveryActions.isEmpty
                    ? "恢复动作：无"
                    : "恢复动作：" + projection.snapshot.recoveryActions.map(\.title).joined(separator: "、")
            )
                .font(typography?.caption2 ?? .caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(projection.accessibilityLabel)
        .accessibilityIdentifier("task-center-external-session-recovery")
    }

    private func filterBar(sourceSessionIDs: [String], sourceLabels: [String: String]) -> some View {
        AdaptiveControlRowLayout(spacing: 10) {
            Menu {
                Button("全部") { [selection = $selectedFilterStatus] in selection.wrappedValue = nil }
                ForEach(TaskCenterFilterStatus.allCases, id: \.rawValue) { status in
                    Button(status.title) { [selection = $selectedFilterStatus, status] in selection.wrappedValue = status }
                }
            } label: {
                let icon = TaskCenterFilterIconProjection.status(selectedFilterStatus)
                Label {
                    Text("状态：\(selectedFilterStatus?.title ?? "全部")")
                } icon: {
                    MinisIconView(icon.icon, state: icon.state, size: 12)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityIdentifier("task-center-filter-status")

            Menu {
                Button("全部来源") { [selection = $selectedSourceSessionID] in selection.wrappedValue = nil }
                ForEach(sourceSessionIDs, id: \.self) { sourceSessionID in
                    Button(TaskCenterRowLabelFormatter.source(sourceSessionID, labels: sourceLabels)) { [selection = $selectedSourceSessionID, sourceSessionID] in
                        selection.wrappedValue = sourceSessionID
                    }
                }
            } label: {
                let icon = TaskCenterFilterIconProjection.sourceSession(selectedSourceSessionID)
                Label {
                    Text("来源：\(selectedSourceSessionID.map { TaskCenterRowLabelFormatter.source($0, labels: sourceLabels) } ?? "全部")")
                } icon: {
                    MinisIconView(icon.icon, state: icon.state, size: 12)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityIdentifier("task-center-filter-source")

            Toggle("显示已归档", isOn: $showArchivedHistory)
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("task-center-filter-archived")

            Spacer(minLength: 0)
        }
        .font(typography?.caption ?? .caption)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task-center-filters")
    }

    @ViewBuilder
    private func archivedTaskList(rows: [TaskCenterReceiptRow], sourceLabels: [String: String]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("已归档记录")
                    .font(typography?.headline ?? .headline)
                ForEach(rows) { row in
                    let title = TaskCenterRowLabelFormatter.title(bridge.taskCenterControlConsumer.humanDisplayTitle(for: row), taskID: row.taskID)
                    let source = TaskCenterRowLabelFormatter.source(row.sourceSessionID, labels: sourceLabels)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title)
                                .font(typography?.monospaced ?? .system(.body, design: .monospaced))
                                .lineLimit(1)
                            Text("\(row.statusTitle) · 来源：\(source)")
                                .font(typography?.caption2 ?? .caption2)
                                .foregroundStyle(.secondary)
                            // Archive hides the task from current work; it does
                            // not require changing that state to inspect its
                            // still-authorized source or settled result.
                            AdaptiveControlRowLayout(spacing: 6) {
                                if let child = row.childNavigation {
                                    NavigationLink("打开子会话") {
                                        TaskCenterChildSessionView(
                                            navigation: child,
                                            consumer: bridge.taskCenterControlConsumer
                                        )
                                    }
                                    .accessibilityIdentifier("archived-child-link-\(row.stableID)")
                                }
                                if let source = bridge.taskCenterControlConsumer.sourceSessionNavigation(for: row) {
                                    NavigationLink("打开来源会话") {
                                        TaskCenterSourceSessionView(
                                            navigation: source,
                                            consumer: bridge.taskCenterControlConsumer
                                        )
                                    }
                                    .accessibilityIdentifier("archived-source-link-\(row.stableID)")
                                }
                                if let result = bridge.taskCenterControlConsumer.resultNavigation(for: row) {
                                    NavigationLink("查看运行结果") {
                                        TaskCenterResultDetailView(
                                            navigation: result,
                                            consumer: bridge.taskCenterControlConsumer
                                        )
                                    }
                                    .accessibilityIdentifier("archived-result-link-\(row.stableID)")
                                }
                                ForEach(bridge.taskCenterControlConsumer.fileArtifactNavigations(for: row)
                                    .filter { bridge.taskCenterControlConsumer.fileArtifactPresentationAuthorized(navigation: $0) }) { file in
                                    NavigationLink("查看文件 · \(file.displayName)") {
                                        TaskCenterFileArtifactView(
                                            navigation: file,
                                            consumer: bridge.taskCenterControlConsumer
                                        )
                                    }
                                    .accessibilityIdentifier("archived-file-link-\(file.id)")
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        Spacer(minLength: 8)
                        Button { [weak bridge, errors = $controlError, taskID = row.taskID, parentID = row.parentID] in
                            guard let bridge else { errors.wrappedValue = .unavailable; return }
                            let request = TaskCenterArchiveRequest(
                                taskID: taskID,
                                parentID: parentID,
                                actorID: "task-center-ui",
                                idempotencyKey: "task-center-restore-ui:\(UUID().uuidString)",
                                action: .restore
                            )
                            do {
                                _ = try bridge.taskCenterControlConsumer.applyArchive(request)
                                errors.wrappedValue = nil
                            } catch let error as TaskCenterControlConsumerError {
                                errors.wrappedValue = error
                            } catch {
                                errors.wrappedValue = .archive(.archiveStateConflict)
                            }
                        } label: {
                            Label {
                                Text("恢复记录")
                            } icon: {
                                MinisIconView(.retry, size: 14)
                                    .accessibilityHidden(true)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel("恢复已归档任务 \(title)")
                        .accessibilityIdentifier("task-center-archive-restore-\(row.taskID)")
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(TaskCenterRowLabelFormatter.accessibilityLabel(
                        title: title, source: source, status: row.statusTitle,
                        step: row.currentStepTitle, progress: row.eventProgressTitle ?? "未记录",
                        duration: row.durationTitle(), result: row.resultSummaryTitle,
                        recovery: TaskCenterRowLabelFormatter.recoveryAccessibilitySummary(for: row)
                    ))
                    .accessibilityIdentifier("task-center-archived-row-\(row.stableID)")
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("task-center-archived-list")
        }
    }

    @ViewBuilder
    private func taskList(
        _ observation: TaskCenterObservationSnapshot,
        goalProjection: GoalTaskCenterProjection,
        receiptRows: [TaskCenterReceiptRow],
        sourceLabels: [String: String]
    ) -> some View {
        let visibleFacts = receiptRows.compactMap { row in
            goalProjection.tasks.first { fact in
                row.taskID == fact.taskID && row.parentID == fact.parentID
            }
        }.enumerated().sorted { left, right in
            func priority(_ fact: GoalTaskCenterTaskFact) -> Int {
                if receiptRows.first(where: { $0.taskID == fact.taskID && $0.parentID == fact.parentID })?.lifecycleState == .approvalRequired { return 0 }
                return fact.status == .running ? 1 : fact.status == .queued ? 2 : 3
            }
            let lhs = priority(left.element), rhs = priority(right.element)
            return lhs == rhs ? left.offset < right.offset : lhs < rhs
        }.map(\.element)
        if receiptRows.isEmpty || visibleFacts.isEmpty {
            ContentUnavailableView {
                Label {
                    Text("暂无任务")
                } icon: {
                    MinisIconView(.task, size: 32, accessibilityLabel: "任务")
                }
            } description: {
                Text("任务运行后会显示在这里")
            }
            .frame(maxWidth: .infinity, minHeight: 220)
            .accessibilityIdentifier("task-center-empty")
        } else {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(visibleFacts, id: \.taskCenterStableID) { fact in
                    TaskCenterRow(
                        fact: fact,
                        receipt: receiptRows.first {
                            $0.taskID == fact.taskID && $0.parentID == fact.parentID
                        },
                        sourceDisplayTitle: TaskCenterRowLabelFormatter.source(
                            receiptRows.first { $0.taskID == fact.taskID && $0.parentID == fact.parentID }?.sourceSessionID,
                            labels: sourceLabels
                        ),
                        childTranscriptConsumer: bridge.taskCenterControlConsumer,
                        approvalCenter: bridge.approvalCenter,
                        controlsEnabled: bridge.taskCenterControlConsumer.isAvailable
                            && fact.isGoalBound,
                        isSelected: selectedTaskStableID == fact.taskCenterStableID,
                        onSelect: { [selection = $selectedTaskStableID, stableID = fact.taskCenterStableID] in
                            selection.wrappedValue = stableID
                        },
                        onArchive: { [weak bridge, errors = $controlError, taskID = fact.taskID, parentID = fact.parentID] in
                            guard let bridge else { errors.wrappedValue = .unavailable; return }
                            let request = TaskCenterArchiveRequest(
                                taskID: taskID,
                                parentID: parentID,
                                actorID: "task-center-ui",
                                idempotencyKey: "task-center-archive-ui:\(UUID().uuidString)",
                                action: .archive
                            )
                            do {
                                _ = try bridge.taskCenterControlConsumer.applyArchive(request)
                                errors.wrappedValue = nil
                            } catch let error as TaskCenterControlConsumerError {
                                errors.wrappedValue = error
                            } catch {
                                errors.wrappedValue = .archive(.archiveStateConflict)
                            }
                        }
                    ) { [weak bridge, errors = $controlError, fact] action in
                        guard let bridge else { errors.wrappedValue = .unavailable; return }
                        let request = TaskCenterControlRequest(
                            taskID: fact.taskID,
                            parentID: fact.parentID,
                            revision: fact.revision,
                            scopeID: fact.scopeID ?? "",
                            actorID: "task-center-ui",
                            idempotencyKey: "task-center-ui:\(UUID().uuidString)",
                            action: action,
                            runID: bridge.taskCenterControlRunID(
                                taskID: fact.taskID,
                                parentID: fact.parentID
                            )
                        )
                        if action == .retry {
                            Task { @MainActor [bridge, errors] in
                                do {
                                    _ = try await bridge.executeTaskCenterRetryFromUserEvent(request)
                                    errors.wrappedValue = nil
                                } catch let error as TaskCenterControlConsumerError {
                                    errors.wrappedValue = error
                                } catch {
                                    errors.wrappedValue = .unavailable
                                }
                            }
                        } else {
                            do {
                                _ = try bridge.executeTaskCenterControl(request)
                                errors.wrappedValue = nil
                            } catch let error as TaskCenterControlConsumerError {
                                errors.wrappedValue = error
                            } catch {
                                errors.wrappedValue = .unavailable
                            }
                        }
                    }
                    .id(fact.taskCenterStableID)
                }
            }
            .accessibilityIdentifier("task-center-list")
        }
    }

    private func leaseTitle(_ state: GoalTaskCenterLeaseState) -> String {
        switch state {
        case .active: return "授权有效"
        case .expired: return "授权过期"
        case .revoked: return "授权撤销"
        case .invalid: return "授权无效"
        }
    }

    private func leaseAccessibilityLabel(_ state: GoalTaskCenterLeaseState) -> String {
        "任务" + leaseTitle(state)
    }
}

private extension GoalTaskCenterLeaseState {
    var accessibilityLabel: String {
        switch self {
        case .active: return "任务授权有效"
        case .expired: return "任务授权过期"
        case .revoked: return "任务授权撤销"
        case .invalid: return "任务授权无效"
        }
    }
}

private struct TaskCenterMetric: View {
    let title: String
    let value: Int
    let tint: Color
    @Environment(\.typographyTokens) private var typography

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(typography?.caption ?? .caption)
                .foregroundStyle(.secondary)
            Text(value, format: .number)
                .font(typography?.metric ?? .system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
        }
        .frame(minWidth: 56, alignment: .leading)
    }
}

private struct TaskCenterBlockedStateRow: View {
    let lifecycleState: TaskCenterReceiptState
    let taskID: String
    let displayTitle: String
    @Environment(\.typographyTokens) private var typography

    var body: some View {
        Group {
            if lifecycleState == .approvalRequired {
                Label {
                    Text(lifecycleState.title)
                } icon: {
                    MinisIconView(.handOpen, state: .active, size: 12)
                }
            } else {
                Label {
                    Text(lifecycleState.title)
                } icon: {
                    MinisIconView(.help, state: .active, size: 12)
                }
            }
        }
            .font(typography?.caption2 ?? .caption2)
            .modifier(ReadableStatusForeground(status: .warning))
            .accessibilityLabel(
                TaskCenterRowLabelFormatter.blockedAccessibilityLabel(title: displayTitle, state: lifecycleState)
            )
            .accessibilityIdentifier(
                "task-center-blocked-state-" + lifecycleState.rawValue + "-" + taskID
            )
    }

}

private struct TaskCenterObservationStateRow: View {
    let observationState: TaskCenterObservationState
    let isStale: Bool
    let taskID: String
    let displayTitle: String
    @Environment(\.themeTokens) private var theme
    @Environment(\.typographyTokens) private var typography

    var body: some View {
        Group {
            if isStale {
                Label(title, systemImage: systemImage)
            } else {
                Label {
                    Text(title)
                } icon: {
                    MinisIconView(.target, size: 12)
                }
            }
        }
            .font(typography?.caption2 ?? .caption2)
            .foregroundStyle(
                isStale
                    ? AnyShapeStyle(theme?.statusWarning ?? AppStatusColor.warning)
                    : AnyShapeStyle(HierarchicalShapeStyle.tertiary)
            )
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var title: String {
        "观测：" + observationState.title
    }

    private var systemImage: String {
        isStale ? "clock.badge.exclamationmark" : "scope"
    }

    private var accessibilityLabel: String {
        TaskCenterRowLabelFormatter.observationAccessibilityLabel(title: displayTitle, state: observationState)
    }

    private var accessibilityIdentifier: String {
        "task-center-observation-" + observationState.rawValue + "-" + taskID
    }
}

/// Presentation only: recovery is not a terminal task status. The receipt
/// already carries the canonical title and action availability from the store.
enum TaskCenterRecoveryRowText {
    static func visibleTitle(for row: TaskCenterReceiptRow) -> String? {
        guard row.recoveryState == .needsUserReview else { return nil }
        if row.needsChildTerminalReview {
            return "恢复：子任务 \(row.taskID) · 父任务 \(row.parentID) · 运行 \(row.runID ?? "未记录") 的真实终态未记录，需人工复核"
        }
        return "恢复：" + row.recoveryState.title
    }
}

/// Filter labels consume the same catalog semantics as status filtering and
/// source-session navigation. A selected filter uses the existing orange active
/// state; it never changes the filter value or the menu's action.
struct TaskCenterFilterIconProjection {
    let icon: MinisIcon
    let state: MinisIconState

    static func status(_ selection: TaskCenterFilterStatus?) -> Self {
        Self(icon: .filter, state: selection == nil ? .normal : .active)
    }

    static func sourceSession(_ selection: String?) -> Self {
        Self(icon: .messages, state: selection == nil ? .normal : .active)
    }
}

/// Uses the existing receipt/fact precedence; only glyphs with an exact
/// catalog meaning use Keyline. Other lifecycle symbols keep their SF shape.
struct TaskCenterRowIconProjection {
    let systemName: String
    let semantic: (icon: MinisIcon, state: MinisIconState)?

    static func make(
        isStale: Bool,
        lifecycleState: TaskCenterReceiptState?,
        taskStatus: AgentTaskStatus
    ) -> Self {
        let name: String
        if isStale {
            name = "clock.badge.exclamationmark"
        } else {
            switch lifecycleState {
            case .some(.retrying): name = "arrow.clockwise.circle"
            case .some(.completed): name = "checkmark.circle"
            case .some(.failed): name = "exclamationmark.triangle"
            case .some(.cancelled): name = "xmark.circle"
            case .some(.running): name = "arrow.triangle.2.circlepath"
            case .some(.approvalRequired): name = "hand.raised.circle"
            case .some(.inputRequired): name = "questionmark.circle"
            case .some(.queued), .none:
                switch taskStatus {
                case .queued: name = "clock"
                case .running: name = "arrow.triangle.2.circlepath"
                case .succeeded: name = "checkmark.circle"
                case .failed: name = "exclamationmark.triangle"
                case .cancelled: name = "xmark.circle"
                }
            }
        }

        let semantic: (icon: MinisIcon, state: MinisIconState)?
        switch name {
        case "checkmark.circle": semantic = (.success, .success)
        case "exclamationmark.triangle": semantic = (.warning, .danger)
        case "xmark.circle": semantic = (.cancel, .disabled)
        case "questionmark.circle": semantic = (.help, .active)
        case "hand.raised.circle": semantic = (.handOpen, .active)
        case "arrow.clockwise.circle": semantic = (.retry, .active)
        case "arrow.triangle.2.circlepath": semantic = (.spinner, .active)
        case "clock": semantic = (.schedule, .normal)
        default: semantic = nil
        }
        return Self(systemName: name, semantic: semantic)
    }
}

private struct TaskCenterRow: View {
    @Environment(\.themeTokens) private var theme
    let fact: GoalTaskCenterTaskFact
    let receipt: TaskCenterReceiptRow?
    let sourceDisplayTitle: String
    let childTranscriptConsumer: TaskCenterControlConsumer
    let approvalCenter: ApprovalPromptCenter
    let controlsEnabled: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    let onArchive: (() -> Void)?
    let onControl: (TaskCenterControlAction) -> Void
    @Environment(BridgeStore.self) private var bridge: BridgeStore?
    @Environment(\.typographyTokens) private var typography
    @State private var showsInternalDetails = false

    private var liveReviewReason: String? {
        guard let bridge, bridge.approvalCenter === approvalCenter,
              let request = approvalCenter.pendingRequest,
              let sessionID = request.sessionID.flatMap(UUID.init(uuidString:)),
              receipt.flatMap({ childTranscriptConsumer.approvalNavigation(for: $0, pendingRequest: request) }) != nil
        else { return nil }
        return bridge.chat.sessionRuntimeReviewReason(for: sessionID, approvalCenter: approvalCenter)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let semantic = iconProjection.semantic {
                Group {
                    if semantic.icon == .spinner {
                        ProgressView().controlSize(.small).frame(width: 18, height: 18)
                    } else {
                        MinisIconView(semantic.icon, state: semantic.state, size: 18)
                    }
                }
                .accessibilityHidden(true)
            } else {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                    .frame(width: 18)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(humanDisplayTitle)
                        .font(typography?.monospaced ?? .system(.body, design: .monospaced))
                        .lineLimit(1)
                        .accessibilityIdentifier("task-center-row-title-\(fact.taskCenterStableID)")
                    Button(isSelected ? "当前任务" : "设为当前") { [onSelect] in
                        onSelect()
                    }
                    .buttonStyle(.borderless)
                    .disabled(isSelected)
                    .accessibilityIdentifier("task-center-select-\(fact.taskCenterStableID)")
                }
                Text("状态：\(statusTitle) · 来源：\(sourceDisplayTitle)")
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("task-center-source-\(receipt?.stableID ?? fact.taskCenterStableID)")
                if let receipt,
                   let recoveryTitle = TaskCenterRecoveryRowText.visibleTitle(for: receipt) {
                    HStack(spacing: 4) {
                        MinisIconView(.warning, size: 12)
                            .accessibilityHidden(true)
                        Text(recoveryTitle)
                    }
                        .font(typography?.caption2 ?? .caption2)
                        .modifier(ReadableStatusForeground(status: .warning))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(recoveryTitle)
                        .accessibilityIdentifier("recovery-state-\(receipt.stableID)")
                }
                Text("\(statusTitle) · \(receipt?.durationTitle() ?? "未记录时长") · 最近：\(receipt?.currentStepTitle ?? "等待开始")")
                    .font(typography?.caption2 ?? .caption2)
                    .foregroundStyle(.secondary)

                if let lifecycleState = receipt?.lifecycleState,
                   lifecycleState == .approvalRequired || lifecycleState == .inputRequired {
                    TaskCenterBlockedStateRow(
                        lifecycleState: lifecycleState,
                        taskID: fact.taskID,
                        displayTitle: humanDisplayTitle
                    )
                }

                if let receipt {
                    TaskCenterObservationStateRow(
                        observationState: receipt.observationState,
                        isStale: receipt.isStale,
                        taskID: fact.taskID,
                        displayTitle: humanDisplayTitle
                    )
                }

                if let childNavigation = receipt?.childNavigation {
                    NavigationLink {
                        TaskCenterChildSessionView(
                            navigation: childNavigation,
                            consumer: childTranscriptConsumer
                        )
                    } label: {
                        Label("打开子会话", systemImage: "arrow.turn.down.right")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("打开子会话并保留父会话返回位置")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("打开子会话并保留父任务位置")
                    .accessibilityValue("打开并保留父任务位置")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier(
                        "task-center-child-session-\(childNavigation.childSessionID)"
                    )
                }

                if let receipt,
                   let approvalNavigation = childTranscriptConsumer.approvalNavigation(
                       for: receipt,
                       pendingRequest: approvalCenter.pendingRequest
                   ) {
                    NavigationLink {
                        TaskCenterApprovalDetailView(
                            navigation: approvalNavigation,
                            consumer: childTranscriptConsumer,
                            approvalCenter: approvalCenter
                        )
                    } label: {
                        HStack(spacing: 4) {
                            Label("查看待审批", systemImage: "hand.raised")
                            if liveReviewReason != nil { Text("需复核") }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(liveReviewReason ?? "只读查看当前待审批请求，返回任务中心")
                    .accessibilityLabel(liveReviewReason.map { "需复核：" + $0 } ?? "查看待审批请求，返回任务中心")
                    .accessibilityIdentifier("approval-detail-link-\(fact.taskCenterStableID)")

                    if approvalCenter.canResumeTaskCenterPresentation(approvalNavigation) {
                        Button("继续审批") {
                            // Revalidate the original canonical mapping; this
                            // row only requests navigation, never a decision.
                            guard childTranscriptConsumer.pendingApproval(
                                navigation: approvalNavigation,
                                pendingRequest: approvalCenter.pendingRequest
                            ) != nil else { return }
                            approvalCenter.requestTaskCenterResume(
                                approvalNavigation, consumer: childTranscriptConsumer
                            )
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("返回同一审批请求；不会批准或拒绝")
                        .accessibilityIdentifier("approval-resume-link-\(fact.taskCenterStableID)")
                    }
                }

                if let receipt,
                   let sourceNavigation = childTranscriptConsumer.sourceSessionNavigation(
                       for: receipt
                   ) {
                    NavigationLink {
                        TaskCenterSourceSessionView(
                            navigation: sourceNavigation,
                            consumer: childTranscriptConsumer
                        )
                    } label: {
                        Label {
                            Text("打开来源会话")
                        } icon: {
                            MinisIconView(.messages, size: 14)
                                .accessibilityHidden(true)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("只读查看来源会话，返回任务中心")
                    .accessibilityLabel("打开来源会话，返回任务中心")
                    .accessibilityValue("打开并保留原任务位置")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("source-session-link-\(fact.taskCenterStableID)")
                }

                if let receipt,
                   let resultNavigation = childTranscriptConsumer.resultNavigation(
                       for: receipt
                   ) {
                    NavigationLink {
                        TaskCenterResultDetailView(
                            navigation: resultNavigation,
                            consumer: childTranscriptConsumer
                        )
                    } label: {
                        Label {
                            Text("查看运行结果")
                        } icon: {
                            MinisIconView(.documentSearch, size: 14)
                                .accessibilityHidden(true)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("只读查看本次运行的结果，返回任务中心")
                    .accessibilityLabel("查看运行结果，返回任务中心")
                    .accessibilityValue("打开并保留原任务位置")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("result-detail-link-\(fact.taskCenterStableID)")
                }

                if let receipt {
                    ForEach(childTranscriptConsumer.fileArtifactNavigations(for: receipt).filter { childTranscriptConsumer.fileArtifactPresentationAuthorized(navigation: $0) }) { file in
                        NavigationLink {
                            TaskCenterFileArtifactView(navigation: file, consumer: childTranscriptConsumer)
                        } label: {
                            Text("查看文件 · \(file.displayName)")
                        }
                        .accessibilityLabel("查看此任务生成的文件")
                        .accessibilityIdentifier("task-file-link-\(file.id)")
                    }
                }

                if let failureReason = receipt?.failureReasonDisplayTitle {
                    Text("失败原因：\(failureReason)")
                        .font(typography?.caption2 ?? .caption2)
                        .modifier(ReadableStatusForeground(status: .danger))
                        .lineLimit(2)
                        .accessibilityIdentifier("task-center-failure-\(fact.taskID)")
                }

                if let providerID = fact.providerID {
                    Text([providerID, fact.modelID].compactMap { $0 }.joined(separator: " · "))
                        .font(typography?.caption2 ?? .caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                DisclosureGroup("展开详情", isExpanded: $showsInternalDetails) {
                    VStack(alignment: .leading, spacing: 3) {
                if fact.isGoalBound && fact.scopeID != nil {
                    Text("任务授权 · \(leaseTitle)")
                        .font(typography?.caption2 ?? .caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .accessibilityLabel(fact.leaseState.accessibilityLabel)
                        .accessibilityIdentifier(
                            "task-center-lease-state-\(fact.goalID?.uuidString ?? fact.taskCenterStableID)"
                        )
                } else {
                    Text("未绑定任务授权 · 只读")
                        .font(typography?.caption2 ?? .caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                        VStack(alignment: .leading, spacing: 3) {
                            Text("子能力摘要（具体操作仍受审批/安全策略约束）")
                            Text("父任务授权仅表示父级目标与上限，不等于子任务全部有效权限")
                            if let granted = fact.childGrantedCapabilities,
                               let intersection = fact.childCapabilityIntersection {
                                Text("已冻结能力：\(childCapabilityNames(granted))")
                                Text("父级能力上限：\(childCapabilityNames(intersection.parentCapabilities))")
                                Text("子任务请求：\(childCapabilityNames(intersection.requestedCapabilities))")
                                Text("能力目录：\(childCapabilityNames(intersection.catalogCapabilities))")
                                Text("派发策略上限：\(childCapabilityNames(intersection.policyCapabilities))")
                                if let directory = fact.childWorkingDirectory {
                                    Text("派发时工作目录：\(ProductRedactionPolicy.redact(directory, maxLength: 512))")
                                }
                            } else {
                                Text("子能力：未知（未记录子能力边界）")
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("task-center-child-capabilities-\(fact.taskID)")

                        Text("进度：\(receipt?.eventProgressTitle ?? "未记录")")
                        Text("任务 ID：\(fact.taskID)")
                        Text("父会话 ID：\(fact.parentID)")
                        // Only the canonical redacted category is safe to show verbatim.
                        // Unknown legacy failure text may contain credentials and stays hidden.
                        if receipt?.failureReason == "execution-failed" {
                            Text("失败原因：执行失败")
                                .accessibilityIdentifier("task-center-failure-code-\(fact.taskID)")
                        }
                        if let scopeID = fact.scopeID {
                            Text("授权范围：\(scopeID)")
                        }
                        Text(receiptSummary)
                            .accessibilityIdentifier("task-center-receipt-details-\(receipt?.stableID ?? fact.taskCenterStableID)")
                        if let succeededBacklink = receipt?.succeededBacklink {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("成功回执回链：运行 \(succeededBacklink.runID) · 第 \(succeededBacklink.attemptID) 次尝试 · 终态第 \(succeededBacklink.terminalEventSequence) 条")
                                    .lineLimit(1)
                                if let outputDigest = succeededBacklink.outputDigest {
                                    Text("输出摘要：\(outputDigest)")
                                        .lineLimit(1)
                                }
                            }
                            .font(typography?.caption2 ?? .caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(succeededBacklink.accessibilityLabel)
                            .accessibilityIdentifier(
                                "task-center-succeeded-backlink-\(succeededBacklink.taskID)"
                            )
                        }

                        if let artifactSummary = receipt?.artifactSummary {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("产物：\(artifactSummary.title)")
                                if let outputDigest = artifactSummary.outputDigest {
                                    Text("摘要：\(outputDigest)")
                                        .lineLimit(1)
                                }
                            }
                            .font(typography?.caption2 ?? .caption2)
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(artifactAccessibilityLabel(artifactSummary))
                            .accessibilityIdentifier(
                                "task-center-artifact-summary-\(receipt?.stableID ?? fact.taskCenterStableID)"
                            )
                        }
                        Text("版本号：\(fact.revision)")
                    }
                    .font(typography?.caption2 ?? .caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(receipt?.accessibilityLabel ?? "任务 \(fact.taskID) 的内部详情")
                }
                .accessibilityIdentifier("task-center-expanded-details-\(fact.taskCenterStableID)")
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 8) {
                if fact.routeReceiptID != nil {
                    MinisIconView(
                        .branch,
                        state: .active,
                        size: 16,
                        accessibilityLabel: "已有路由回执"
                    )
                        .help("已有路由回执")
                        .accessibilityHidden(true)
                }

                if controlsEnabled {
                    HStack(spacing: 6) {
                        ForEach(controlActions, id: \.rawValue) { action in
                            Button { [onControl, action] in
                                onControl(action)
                            } label: {
                                Label {
                                    Text(action.title)
                                } icon: {
                                    MinisIconView(action.keylineIcon, size: 12)
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help(action.title)
                            .accessibilityElement(children: .ignore)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityLabel(actionAccessibilityLabel(action))
                            .accessibilityValue("可用")
                            .accessibilityAction { [onControl, action] in onControl(action) }
                            .accessibilityIdentifier(
                                "task-center-control-\(action.rawValue)-\(fact.taskID)"
                            )
                        }
                    }
                }

                if receipt?.archiveAvailable == true {
                    Button { [onArchive] in
                        onArchive?()
                    } label: {
                        Label {
                            Text("归档记录")
                        } icon: {
                            MinisIconView(.archive, size: 14)
                                .accessibilityHidden(true)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("归档已完成记录")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("归档已完成任务 \(humanDisplayTitle)")
                    .accessibilityValue("可用")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("task-center-archive-\(fact.taskID)")
                }
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        // Keep the row summary and its pause/resume/stop/retry controls as
        // separate VoiceOver children so every visible action is reachable.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(TaskCenterRowLabelFormatter.accessibilityLabel(
            title: humanDisplayTitle,
            source: sourceDisplayTitle, status: statusTitle,
            step: receipt?.currentStepTitle ?? statusTitle,
            progress: receipt?.eventProgressTitle ?? "未记录",
            duration: receipt?.durationTitle() ?? "未记录",
            result: receipt?.resultSummaryTitle ?? "尚无结果",
            recovery: TaskCenterRowLabelFormatter.recoveryAccessibilitySummary(for: receipt)
        ))
        .accessibilityIdentifier("task-center-row-\(fact.taskCenterStableID)")
    }

    private var humanDisplayTitle: String {
        TaskCenterRowLabelFormatter.title(
            receipt.flatMap { childTranscriptConsumer.humanDisplayTitle(for: $0) },
            taskID: fact.taskID
        )
    }

    private var statusTitle: String {
        if let receipt {
            return receipt.statusTitle
        }
        switch fact.status {
        case .queued: return "排队"
        case .running: return "运行中"
        case .succeeded: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }

    private var iconProjection: TaskCenterRowIconProjection {
        TaskCenterRowIconProjection.make(
            isStale: receipt?.isStale == true,
            lifecycleState: receipt?.lifecycleState,
            taskStatus: fact.status
        )
    }

    private var statusIcon: String { iconProjection.systemName }

    private func artifactAccessibilityLabel(_ summary: TaskCenterArtifactSummary) -> String {
        var label = "任务产物，" + summary.title
        if let outputDigest = summary.outputDigest {
            label += "，摘要 " + outputDigest
        }
        return label
    }

    private var statusColor: Color {
        let warning = theme?.statusWarning ?? AppStatusColor.warning
        let success = theme?.statusSuccess ?? AppStatusColor.success
        let danger = theme?.statusDanger ?? AppStatusColor.danger
        if receipt?.isStale == true {
            return warning
        }
        switch receipt?.lifecycleState {
        case .some(.retrying): return warning
        case .some(.completed): return success
        case .some(.failed): return danger
        case .some(.cancelled): return .secondary
        case .some(.running): return warning
        case .some(.approvalRequired), .some(.inputRequired): return warning
        case .some(.queued), .none: break
        }
        switch fact.status {
        case .queued: return theme?.statusInfo ?? AppStatusColor.info
        case .running: return warning
        case .succeeded: return success
        case .failed: return danger
        case .cancelled: return .secondary
        }
    }

    private func childCapabilityNames(_ capabilities: Set<ProviderCapability>) -> String {
        let names = capabilities.sorted { $0.rawValue < $1.rawValue }.map { capability in
            switch capability {
            case .streaming: return "流式回复"
            case .tools: return "工具调用"
            case .vision: return "图像理解"
            case .audio: return "音频"
            case .image: return "图像"
            case .video: return "视频"
            }
        }
        return names.isEmpty ? "无" : names.joined(separator: "、")
    }

    private var leaseTitle: String {
        switch fact.leaseState {
        case .active: return "授权有效"
        case .expired: return "授权过期"
        case .revoked: return "授权撤销"
        case .invalid: return "授权无效"
        }
    }

    private var controlActions: [TaskCenterControlAction] {
        switch fact.status {
        case .queued, .running:
            guard receipt?.cancelAvailable == true else { return [] }
            if fact.controlState == .paused {
                return [.resume, fact.status == .queued ? .cancel : .stop]
            }
            return [.pause, fact.status == .queued ? .cancel : .stop]
        case .failed, .cancelled:
            return receipt?.retryAvailable == true ? [.retry] : []
        case .succeeded:
            return []
        }
    }

    private var receiptSummary: String {
        guard let receipt else { return "任务回执未生成" }
        let run = receipt.runID ?? "未创建"
        let attempt = receipt.attemptID ?? "未创建"
        let availableActions = [
            receipt.retryAvailable ? "可重试" : nil,
            receipt.cancelAvailable ? "可取消" : nil
        ].compactMap { $0 }
        let actionSummary = availableActions.isEmpty
            ? "操作 无"
            : "操作 \(availableActions.joined(separator: "、"))"
        return [
            "回执 \(receipt.receiptID)",
            "会话 \(receipt.sessionID)",
            "任务 \(receipt.statusTitle)",
            "运行 \(run)（\(receipt.runState.title)）",
            "尝试 \(attempt)（\(receipt.attemptState.title)）",
            "效果 \(receipt.effectID)（\(receipt.effectState.title)）",
            actionSummary
        ].joined(separator: " · ")
    }

    private func actionAccessibilityLabel(_ action: TaskCenterControlAction) -> String {
        let title = humanDisplayTitle
        return TaskCenterRowLabelFormatter.controlAccessibilityLabel(title: title, action: action)
    }
}

private struct TaskCenterChildSessionView: View {
    let navigation: TaskCenterChildSessionNavigation
    let consumer: TaskCenterControlConsumer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.typographyTokens) private var typography

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("子会话", systemImage: "arrow.turn.down.right")
                .font(typography?.headline ?? .headline)
            Text("任务：\(navigation.taskID)")
            Text("子会话：\(navigation.childSessionID)")
                .font(typography?.monospaced ?? .system(.body, design: .monospaced))
                .textSelection(.enabled)
            Text("父会话：\(navigation.parentSessionID)")
                .font(typography?.caption ?? .caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let transcript = consumer.childTranscript(navigation: navigation)
                if let transcript {
                    VStack(alignment: .leading, spacing: 8) {
                        if transcript.truncated {
                            Text("仅显示最近 100 条安全记录")
                                .font(typography?.caption ?? .caption)
                                .foregroundStyle(.secondary)
                        }
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                ForEach(transcript.messages) { message in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(message.roleTitle)
                                            .font(typography?.caption ?? .caption)
                                            .foregroundStyle(.secondary)
                                        Text(message.content)
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                        }
                        if consumer.canMoveChildToBackground(navigation: navigation) {
                            Button("转入后台") {
                                Task { _ = await consumer.moveChildToBackground(navigation: navigation) }
                            }
                            .buttonStyle(.bordered)
                            .help("转入后台运行，当前对话可以继续")
                            .accessibilityLabel("把子任务转入后台运行")
                            .accessibilityIdentifier("task-center-background-move-\(navigation.taskID)")
                        }
                        TaskCenterChildInstructionComposer(navigation: navigation, consumer: consumer)
                            .id(navigation.locator)
                    }
                } else {
                    Text("子会话记录已失效或不可读取；返回任务中心查看当前任务。")
                        .font(typography?.caption ?? .caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(20)
        .navigationTitle("子会话")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("返回") { dismiss() }
                    .accessibilityLabel("返回任务中心")
                    .accessibilityIdentifier("task-center-child-session-return")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task-center-child-session-view-\(navigation.childSessionID)")
    }
}

private struct TaskCenterChildInstructionComposer: View {
    let navigation: TaskCenterChildSessionNavigation
    let consumer: TaskCenterControlConsumer
    @Environment(\.typographyTokens) private var typography
    @State private var draft = ""
    @State private var feedback: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("补充指令", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
                .accessibilityIdentifier("task-center-child-instruction-input")
            Button("发送补充指令", action: submit)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("task-center-child-instruction-send")
            if let feedback {
                Text(feedback)
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("task-center-child-instruction-feedback")
            }
        }
    }

    private func submit() {
        do {
            try consumer.appendChildInstruction(navigation: navigation, text: draft)
            draft = ""
            feedback = "已排队 · 将在下一步送达"
        } catch ChildInstructionMailboxError.invalidText {
            feedback = "指令为空或太长。请修改后再发送。"
        } catch ChildInstructionMailboxError.full {
            feedback = "待发送队列已满。请等子任务处理后再试。"
        } catch ChildInstructionMailboxError.staleAttempt {
            feedback = "子任务已停止、已结束或此页面已失效。未发送指令，任务不会自动恢复。"
        } catch {
            feedback = "无法确认子任务的当前来源。未发送指令。"
        }
    }
}

private struct TaskCenterApprovalDetailView: View {
    let navigation: TaskCenterApprovalNavigation
    let consumer: TaskCenterControlConsumer
    let approvalCenter: ApprovalPromptCenter
    @Environment(BridgeStore.self) private var bridge: BridgeStore?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.typographyTokens) private var typography

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("待审批请求", systemImage: "hand.raised")
                .font(typography?.headline ?? .headline)
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                // Re-read the live prompt and canonical task identity on every
                // refresh. Replaced, expired, or retried requests show no details.
                if let request = consumer.pendingApproval(
                    navigation: navigation,
                    pendingRequest: approvalCenter.pendingRequest
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let bridge, bridge.approvalCenter === approvalCenter,
                           let sessionID = request.sessionID.flatMap(UUID.init(uuidString:)),
                           let reason = bridge.chat.sessionRuntimeReviewReason(for: sessionID, approvalCenter: approvalCenter) {
                            Text("需复核：" + reason)
                                .accessibilityIdentifier("task-center-approval-needs-review")
                        }
                        Text("工具：\(request.toolName)")
                        Text("输入摘要（已脱敏）：\(request.inputSummary)")
                            .textSelection(.enabled)
                        Text("此页仅供查看。审批操作请使用当前审批提示。")
                            .font(typography?.caption ?? .caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("待审批请求已失效或不可读取；返回任务中心查看当前任务。")
                        .font(typography?.caption ?? .caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(20)
        .navigationTitle("待审批")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("返回") { dismiss() }
                    .accessibilityLabel("返回任务中心")
                    .accessibilityIdentifier("approval-detail-return")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("approval-detail-view")
    }
}

private struct TaskCenterSourceSessionView: View {
    let navigation: TaskCenterSourceSessionNavigation
    let consumer: TaskCenterControlConsumer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.typographyTokens) private var typography

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("来源会话")
            } icon: {
                MinisIconView(.messages, size: 18)
                    .accessibilityHidden(true)
            }
                .font(typography?.headline ?? .headline)
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                // Recheck identity on every read. Retry or source changes
                // must stop displaying the transcript opened earlier.
                if let transcript = consumer.sourceTranscript(navigation: navigation) {
                    VStack(alignment: .leading, spacing: 8) {
                        if transcript.truncated {
                            Text("仅显示最近 100 条安全记录")
                                .font(typography?.caption ?? .caption)
                                .foregroundStyle(.secondary)
                        }
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                ForEach(transcript.messages) { message in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(message.roleTitle)
                                            .font(typography?.caption ?? .caption)
                                            .foregroundStyle(.secondary)
                                        Text(message.content)
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    Text("来源会话已失效或不可读取；返回任务中心查看当前任务。")
                        .font(typography?.caption ?? .caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(20)
        .navigationTitle("来源会话")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("返回") { dismiss() }
                    .accessibilityLabel("返回任务中心")
                    .accessibilityIdentifier("source-session-return")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("source-session-view")
    }
}

private struct TaskCenterResultDetailView: View {
    let navigation: TaskCenterResultNavigation
    let consumer: TaskCenterControlConsumer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.typographyTokens) private var typography

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("运行结果")
            } icon: {
                MinisIconView(.documentSearch, size: 18)
                    .accessibilityHidden(true)
            }
                .font(typography?.headline ?? .headline)
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                // Keep the view bound to the canonical run and attempt.
                // A retry must not leave its earlier result visible.
                if let detail = consumer.resultDetail(navigation: navigation) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("状态：\(detail.statusTitle)")
                        Text(detail.durationSeconds.map { "耗时：\(String(format: "%.2f", $0)) 秒" } ?? "耗时：未知")
                        Text(detail.settledToolCalls.map { "已结算工具调用：\($0) 次（含失败与取消）" } ?? "已结算工具调用：未知")
                        if let usage = detail.tokenUsage {
                            Text("Provider 已报告 tokens：输入 \(usage.totalInputTokens ?? usage.inputTokens)，输出 \(usage.outputTokens)；\(usage.reportedCallCount) 次报告")
                        } else { Text("Provider 已报告 tokens：未知") }
                        Text(detail.artifactsComplete ? "产物：\(detail.files.count) 项" : "产物：未知或部分不可访问")
                        ForEach(detail.files.filter { consumer.fileArtifactPresentationAuthorized(navigation: $0) }) { file in
                            NavigationLink("查看文件 · \(file.displayName)") {
                                TaskCenterFileArtifactView(navigation: file, consumer: consumer)
                            }
                        }
                        Text("本页显示本次运行的安全结果摘要；完整答复可从子任务会话查看。")
                            .font(typography?.caption ?? .caption)
                            .foregroundStyle(.secondary)
                        if let output = detail.displayOutput {
                            ScrollView {
                                Text(output)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                        } else {
                            Text("此回执没有可展示的结果正文。")
                                .foregroundStyle(.secondary)
                        }
                        if detail.evidenceCount > 0 {
                            Text("附带 \(detail.evidenceCount) 条证据引用。")
                                .font(typography?.caption ?? .caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("产物结果已失效或不可读取；返回任务中心查看当前任务。")
                        .font(typography?.caption ?? .caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(20)
        .navigationTitle("运行结果")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("返回") { dismiss() }
                    .accessibilityLabel("返回任务中心")
                    .accessibilityIdentifier("result-detail-return")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("result-detail-view")
    }
}

private struct TaskCenterFileArtifactView: View {
    let navigation: TaskCenterFileArtifactNavigation
    let consumer: TaskCenterControlConsumer
    @Environment(\.dismiss) private var dismiss
    @State private var preview: FilePreview?
    @State private var feedback: String?
    @State private var previewTarget: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(navigation.displayName).font(.headline)
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let admitted = consumer.fileArtifactPresentationAuthorized(navigation: navigation, target: previewTarget)
                VStack(alignment: .leading, spacing: 12) {
                if admitted {
                    if let preview {
                        if let error = preview.error { Text(error).foregroundStyle(.secondary) }
                        else {
                            ScrollView { FilePreviewContents(preview: preview, imageCacheKey: "") }
                        }
                    } else {
                        ProgressView("正在核验文件…")
                    }
                    HStack {
                        Button("系统打开") { perform(.systemOpen) }
                        Button("在 Finder 中显示") { perform(.finderReveal) }
                    }
                    .buttonStyle(.bordered)
                    if let feedback { Text(feedback).foregroundStyle(.secondary) }
                } else {
                    Text("此文件结果已失效或无法核验，请返回任务中心。")
                        .foregroundStyle(.secondary)
                }
                }
                .onChange(of: admitted) { _, allowed in
                    if !allowed { preview = nil }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .navigationTitle("任务文件")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("返回") { dismiss() }
                    .accessibilityLabel("返回任务中心")
                    .accessibilityIdentifier("task-file-return")
            }
        }
        .task(id: navigation.id) {
            preview = nil; previewTarget = nil
            guard consumer.fileArtifactPresentationAuthorized(navigation: navigation),
                  let access = consumer.fileArtifactAccess(navigation: navigation) else { return }
            let loaded = await Task.detached(priority: .userInitiated) {
                let target: URL
                switch AgentFileOutputTargetResolver.resolve(
                    path: access.record.path, workspaceRoot: access.workspaceRoot,
                    probe: AgentFileOutputTargetResolver.fileSystemProbe
                ) {
                case .failure(let failure):
                    return (nil as URL?, FilePreview(kind: .other, text: nil, imageData: nil, videoURL: nil,
                                       sizeText: "", error: failure.message))
                case .success(let url): target = url
                }
                return (Optional(target), FilePreview.loadAgentOutput(
                    url: target,
                    workspaceRoot: URL(fileURLWithPath: navigation.binding.workingDirectory, isDirectory: true),
                    expectedSHA256: navigation.outputSHA256,
                    validateBinding: { consumer.fileArtifactAccess(navigation: navigation) == access },
                    authorizeTarget: { consumer.fileArtifactTargetAuthorized(navigation: navigation, target: $0) }
                ))
            }.value
            guard !Task.isCancelled,
                  consumer.fileArtifactAccess(navigation: navigation) == access,
                  consumer.fileArtifactPresentationAuthorized(navigation: navigation, target: loaded.0) else { return }
            previewTarget = loaded.0
            preview = loaded.1
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task-file-view")
    }

    private func perform(_ intent: AgentFileOutputIntent) {
        Task {
            let result = await AgentFileOutputActionConsumer.performTaskArtifactInApp(
                navigation: navigation, consumer: consumer, intent: intent
            )
            guard !Task.isCancelled else { return }
            feedback = result.message
        }
    }
}

private extension GoalTaskCenterTaskFact {
    /// Length-prefixed composite identity avoids delimiter collisions while staying
    /// stable across projection refreshes and safe for accessibility locators.
    var taskCenterStableID: String {
        let key = "\(parentID.count):\(parentID)\(taskID.count):\(taskID)"
        return Data(key.utf8).base64EncodedString()
    }
}
