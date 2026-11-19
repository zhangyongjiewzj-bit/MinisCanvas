import SwiftUI
import MinisCore
import Observation

/// Presentation only: the store remains the sole confirmation/authorization gate.
enum SchedulerConfirmationFeedback {
    static let storageUnavailableAdvice = "定时任务存储写入失败。请检查磁盘空间后重新打开应用。"

    static func failureMessage(previewExpiresAt: Date, hasValidTarget: Bool,
                               storageUnavailable: Bool = false, now: Date = Date()) -> String {
        if storageUnavailable {
            return "确认失败：" + storageUnavailableAdvice
        }
        if previewExpiresAt <= now {
            return "确认失败：预览已过期。请重新预览后再授权。"
        }
        if !hasValidTarget {
            return "确认失败：目标会话、项目或来源轮次不完整。请补全目标后重新预览。"
        }
        return "确认失败：任务版本或授权条件已变化。请刷新后重新预览。"
    }
}

struct SchedulerTaskDeletionRequest: Equatable, Sendable {
    let taskID: UUID
    let taskVersion: Int
    let taskName: String
    let requestedAt: Date
    let expiresAt: Date
}

enum SchedulerTaskDeletionFailure: Equatable, Sendable {
    case existingPersistenceError
    case selectionChanged
    case expired
    case missingOrDeleted
    case taskChanged
    case persistenceFailed
}

enum SchedulerTaskDeletionResult: Equatable, Sendable {
    case deleted
    case rejected(SchedulerTaskDeletionFailure)
}

/// The visible revoke action consumes the exact task/authorization version
/// that was displayed. Editing or reauthorizing before the click fails closed.
@MainActor
enum SchedulerTaskAuthorizationRevocationConsumer {
    static func revoke(_ displayed: SchedulerTask, store: SchedulerTaskStore) -> Bool {
        guard let current = store.task(id: displayed.id), !current.isDeleted,
              current.version == displayed.version,
              current.authorizationVersion == displayed.authorizationVersion,
              current.isAuthorized, !current.authorizationRevoked else { return false }
        return store.revokeAuthorization(
            displayed.id,
            expectedVersion: displayed.version,
            expectedAuthorizationVersion: displayed.authorizationVersion
        )
    }
}

/// The settings surface uses this one consumer for both its visible and AX
/// actions. It snapshots an exact task version, revalidates it immediately
/// before the existing store boundary, and verifies the Void deletion result.
@MainActor
enum SchedulerTaskDeletionConsumer {
    static let confirmationTTL: TimeInterval = 60

    static func request(
        for task: SchedulerTask,
        now: Date = Date(),
        ttl: TimeInterval = confirmationTTL
    ) -> SchedulerTaskDeletionRequest? {
        guard !task.isDeleted, ttl > 0 else { return nil }
        return SchedulerTaskDeletionRequest(
            taskID: task.id,
            taskVersion: task.version,
            taskName: task.name,
            requestedAt: now,
            expiresAt: now.addingTimeInterval(ttl)
        )
    }

    static func confirm(
        _ request: SchedulerTaskDeletionRequest,
        selectedTaskID: UUID?,
        store: SchedulerTaskStore,
        now: Date = Date()
    ) -> SchedulerTaskDeletionResult {
        guard store.persistenceError == nil else {
            return .rejected(.existingPersistenceError)
        }
        guard selectedTaskID == request.taskID else {
            return .rejected(.selectionChanged)
        }
        guard request.expiresAt > now else {
            return .rejected(.expired)
        }
        guard let current = store.task(id: request.taskID), !current.isDeleted else {
            return .rejected(.missingOrDeleted)
        }
        guard current.version == request.taskVersion, current.name == request.taskName else {
            return .rejected(.taskChanged)
        }

        store.delete(id: request.taskID)

        guard store.persistenceError == nil,
              let tombstone = store.task(id: request.taskID),
              tombstone.isDeleted,
              tombstone.version == request.taskVersion + 1 else {
            return .rejected(.persistenceFailed)
        }
        return .deleted
    }
}

private struct SchedulerTaskDeletionFeedback: Equatable {
    let message: String
    let isError: Bool
}

/// Secret-free, typed facts shown at the control boundary before an
/// authorization/save decision. This keeps the UI projection tied to the
/// exact preview and occurrence versions that the Store/Runtime consume.
struct SchedulerControlProductionProjection: Equatable, Sendable {
    struct Trigger: Equatable, Sendable {
        let cronExpression: String
        let isValid: Bool
        let nextOccurrence: Date?
    }

    struct Credential: Equatable, Sendable {
        let providerID: String?
        let modelID: String?
        let credentialVersion: String?
        let status: SchedulerProviderPreflightStatus?
        let detail: String

        var isReadyForExecution: Bool {
            status.map { $0 == .ready } == true
        }
    }

    struct Source: Equatable, Sendable {
        let anchorVersion: Int?
        let anchorDigest: String?
        let policyRevision: String?

        var isBound: Bool {
            anchorVersion == 2
                && !(anchorDigest?.isEmpty ?? true)
                && !(policyRevision?.isEmpty ?? true)
        }

        var displayValue: String {
            let anchor = anchorVersion.map { "v\($0)" } ?? "未绑定"
            let digest = anchorDigest.map { String($0.prefix(12)) + "…" } ?? "无 digest"
            let policy = policyRevision ?? "无 policy"
            return "\(anchor) · \(digest) · \(policy)"
        }
    }

    struct Target: Equatable, Sendable {
        let sessionID: UUID?
        let projectID: String?
        let turnID: Int?
        let isValid: Bool
    }

    struct PinnedVersion: Equatable, Sendable {
        let taskVersion: Int
        let occurrenceVersions: [Int]
    }

    let taskID: UUID
    let isEnabled: Bool
    let trigger: Trigger
    let credential: Credential
    let source: Source
    let target: Target
    let pinnedVersion: PinnedVersion
    let authorizationState: SchedulerPreviewAuthorizationState

    var nextOccurrence: Date? { trigger.nextOccurrence }

    /// A control projection cannot produce a dispatch intent unless every
    /// durable identity/readiness fence is represented by the same preview.
    var canProduceDispatchIntent: Bool {
        isEnabled
            && trigger.isValid
            && trigger.nextOccurrence != nil
            && credential.isReadyForExecution
            && source.isBound
            && target.isValid
            && authorizationState == .authorized
    }

    init(preview: SchedulerTaskPreview, occurrences: [SchedulerOccurrence]) {
        taskID = preview.taskID
        isEnabled = preview.isEnabled
        trigger = Trigger(
            cronExpression: preview.cronExpression,
            isValid: CronValidator.validate(preview.cronExpression) == nil,
            nextOccurrence: preview.predictedTriggers.first
        )
        if let preflight = preview.providerPreflight {
            credential = Credential(
                providerID: preflight.providerID,
                modelID: preflight.modelID,
                credentialVersion: preflight.credentialVersion,
                status: preflight.status,
                detail: preflight.detail
            )
        } else {
            credential = Credential(
                providerID: nil,
                modelID: nil,
                credentialVersion: nil,
                status: nil,
                detail: "服务商、模型与凭据的可用性暂时无法确认"
            )
        }
        source = Source(
            anchorVersion: preview.sourceAnchorVersion,
            anchorDigest: preview.observedSourceAnchorDigest,
            policyRevision: preview.observedPolicyRevision
        )
        target = Target(
            sessionID: preview.targetSessionID,
            projectID: preview.targetProjectID,
            turnID: preview.targetTurnID,
            isValid: preview.hasValidTarget
        )
        pinnedVersion = PinnedVersion(
            taskVersion: preview.taskVersion,
            occurrenceVersions: Array(Set(
                occurrences.filter { $0.taskID == preview.taskID }.map(\.taskVersion)
            )).sorted()
        )
        authorizationState = preview.authorizationState
    }
}

/// Read-only projection shared by the visible preview action and its consumer tests.
@MainActor
enum SchedulerControlPreviewConsumer {
    static func makePreview(
        taskID: UUID,
        store: SchedulerTaskStore,
        runtime: SchedulerTaskRuntime?
    ) -> SchedulerTaskPreview? {
        guard var value = store.preview(taskID: taskID) else { return nil }
        value.observedPolicyRevision = runtime?.currentPolicyRevision()
        // Missing target facts must be visible in the read-only preview. The
        // existing confirmation and dispatch guards still reject them.
        if let sessionID = value.targetSessionID, let projectID = value.targetProjectID,
           let ordinal = value.targetTurnID {
            value.observedSourceAnchorDigest = runtime?.sourceAnchorDigest(sessionID: sessionID,
                projectID: projectID, ordinal: ordinal)
        }
        return value
    }
}

enum SchedulerControlTaskRevisionFence {
    static func matches(_ task: SchedulerTask?, expectedVersion: Int) -> Bool {
        guard let task, !task.isDeleted else { return false }
        return task.version == expectedVersion
    }
}

/// Full scheduler control surface. The parent settings view owns composition
/// and may inject the already running SchedulerTaskRuntime; this view never
/// creates a second runtime, timer, ledger or effect path.
struct SchedulerControlSettingsView: View {
    @Bindable var store: SchedulerTaskStore
    let runtime: SchedulerTaskRuntime?

    /// 两栏宽度契约：设置窗最窄内容区（431pt）内左栏可压缩、右栏保持可用最小宽度。
    enum ColumnLayout {
        static let taskListMinWidth: CGFloat = 160
        static let taskListIdealWidth: CGFloat = 350
        static let dividerWidth: CGFloat = 1
        static let detailMinWidth: CGFloat = 220
    }

    @Environment(\.themeTokens) private var theme
    @Environment(\.typographyTokens) private var typography
    @State private var selectedTaskID: UUID?
    @State private var preview: SchedulerTaskPreview?
    @State private var sourceAnchorConfirmed = false
    /// 授权主体默认取当前系统用户，不需要手输；仍可改。
    @State private var actorID = NSUserName().isEmpty ? "本机用户" : NSUserName()
    @State private var feedback: String?
    private struct EditorPresentation: Identifiable {
        let id = UUID()
        let task: SchedulerTask?
        var prefill: SchedulerTaskTargetPrefill?
    }
    @State private var editorPresentation: EditorPresentation?
    @State private var pendingDeletion: SchedulerTaskDeletionRequest?
    @State private var deletionFeedback: SchedulerTaskDeletionFeedback?
    /// Transient observations are keyed to the clicked occurrence, never the
    /// selected/current task. They do not replace any durable receipt.
    @State private var targetDeliveryObservations: [UUID: SchedulerTargetDeliveryObservation] = [:]
    @State private var rerunFeedback: String?

    init(store: SchedulerTaskStore, runtime: SchedulerTaskRuntime? = nil) {
        self.store = store
        self.runtime = runtime
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if store.persistenceError != nil {
                Text("定时任务存储不可用，原数据已保留；请处理存储错误后重新打开。")
                    .foregroundStyle(theme?.statusDangerText ?? .red)
                    .padding(.horizontal, 14)
                    .accessibilityIdentifier("scheduler.persistence-error")
            }
            Divider()
            GeometryReader { proxy in
                // 左栏宽度确定性计算：宽窗取理想宽度，窄窗让出空间给右栏最小宽度。
                let listWidth = min(
                    ColumnLayout.taskListIdealWidth,
                    max(
                        ColumnLayout.taskListMinWidth,
                        proxy.size.width - ColumnLayout.dividerWidth - ColumnLayout.detailMinWidth
                    )
                )
                HStack(spacing: 0) {
                    taskList
                        .frame(width: listWidth)
                    Divider()
                    detailPane
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .onChange(of: preview?.fingerprint) { _, _ in sourceAnchorConfirmed = false }
        .sheet(item: $editorPresentation) { presentation in
            SchedulerControlTaskEditor(store: store, task: presentation.task, prefill: presentation.prefill)
        }
        .onChange(of: SchedulerTaskPrefillInbox.shared.pending, initial: true) { _, pending in
            guard let pending else { return }
            SchedulerTaskPrefillInbox.shared.pending = nil
            editorPresentation = EditorPresentation(task: nil, prefill: pending)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("定时任务控制")
                    .font(typography?.headline ?? .headline)
                Text("仅在 MinisCanvas 运行时检查并触发任务；退出 App 后不会执行。")
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
                Text("预览只读；确认绑定版本、指纹、期限和显式授权")
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(store.allTasks().count) 个任务 · \(store.enabledTasks().count) 启用")
                .font(typography?.caption ?? .caption)
                .foregroundStyle(.secondary)
            Button {
                editorPresentation = EditorPresentation(task: nil)
            } label: {
                Label {
                    Text("新建任务")
                } icon: {
                    MinisIconView(.add, size: 14)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityIdentifier("scheduler.task.add")
        }
        .padding(14)
    }

    private var taskList: some View {
        VStack(spacing: 0) {
            if store.allTasks().isEmpty {
                ContentUnavailableView(
                    "暂无定时任务",
                    systemImage: "clock",
                    description: Text("新建任务后，先预览下一次触发，再用显式授权确认。")
                )
            } else {
                // 破坏性删除入口必须常驻物化：List 按表格 cell 节奏投影行，
                // 托管设置面里每任务的 `scheduler.task.delete.<uuid>` 原生可访问性
                // 入口因此到不了 AX 树（F16 验收行 SchedulerControlSettingsTests）。
                // 非懒加载 VStack 立即物化全部行，ScrollView 保留超长任务列表的
                // 滚动语义，不再依赖 List 的懒物化。
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(store.allTasks()) { task in
                            taskRow(task)
                                .padding(.horizontal, 10)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func taskRow(_ task: SchedulerTask) -> some View {
        let selected = selectedTaskID == task.id
        return VStack(alignment: .leading, spacing: 5) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(task.name.isEmpty ? "未命名任务" : task.name)
                        .font(typography?.body ?? .body)
                        .fontWeight(.medium)
                    Spacer()
                    Text(task.isAuthorized && task.sourceAnchorDigest != nil ? "已授权" : "待绑定授权")
                        .font(typography?.caption2 ?? .caption2)
                        .foregroundStyle(task.isAuthorized ? (theme?.statusSuccess ?? AppStatusColor.success) : Color.secondary)
                }
                Text(task.cronExpression)
                    .font(typography?.monospaced ?? .system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(task.command.isEmpty ? "（空命令）" : task.command)
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                if let error = runtime?.catchUpErrors[task.id] {
                    Text("补跑未安排：\(error)")
                        .font(typography?.caption ?? .caption)
                        .foregroundStyle(theme?.statusDangerText ?? .red)
                }
                HStack(spacing: 8) {
                    Toggle("启用", isOn: Binding(
                        get: { task.isEnabled },
                        set: { setEnabled(task, enabled: $0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    Button("预览") {
                        selectedTaskID = task.id
                        preview = makePreview(taskID: task.id)
                        feedback = preview == nil ? "无法生成预览：任务或 cron 已失效。" : nil
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("scheduler.preview.\(task.id.uuidString)")
                    if task.isAuthorized && !task.authorizationRevoked {
                        Button("撤销授权") { revokeAuthorization(task) }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("scheduler.authorization.revoke.\(task.id.uuidString)")
                    }
                    Button {
                        editorPresentation = EditorPresentation(task: task)
                    } label: {
                        MinisIconView(.edit, size: 14, accessibilityLabel: "编辑任务")
                    }
                    .buttonStyle(.borderless)
                    .help("编辑任务")
                    Button("删除", role: .destructive) {
                        beginDeletion(task)
                    }
                    .buttonStyle(.borderless)
                    .help("删除定时任务 \(task.name.isEmpty ? "未命名任务" : task.name)")
                    // F16 原生 AX 验收（scheduler-f16-baseline-028）曝光配方，FIXED2
                    // 全量复测后由 lane 190 收敛为单一变量：fixed2 raw :473 实测
                    // 命中的单一元素 role=.button、enabled=true 均通过，但
                    // kAXDescription/kAXTitle 均为 nil，且 :474/:520 按压返回
                    // .success 后 :476/:522 仍读不到任何确认区元素 ——
                    // `.accessibilityElement(children: .ignore)` 生成的新元素只承接
                    // 它之后声明的属性与动作（官方文档：children 的可访问性被忽略），
                    // lane 161 把 accessibilityLabel 与 Button 自带动作留在聚合之前，
                    // 于是宿主内实测到的是"有 role、无 label、按压空转"的聚合元素，
                    // pendingDeletion 永不置位，确认区（含 :446 confirm、:434 cancel、
                    // :453 container）从未进入 AX 树。这里把标签声明与对既有
                    // beginDeletion 生产入口的显式默认动作一并移到聚合之后，令被
                    // 投射的单一元素自带组合标签与真实按压语义；文案、样式、动作
                    // 目标、位置均未改变，不新增任何业务语义。
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("删除定时任务 \(task.name.isEmpty ? "未命名任务" : task.name)")
                    .accessibilityAction { beginDeletion(task) }
                    .accessibilityIdentifier("scheduler.task.delete.\(task.id.uuidString)")
                }
            }
            .padding(.vertical, 4)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .background(selected ? Color.accentColor.opacity(0.1) : Color.clear)
        .onTapGesture {
            selectedTaskID = task.id
            preview = nil
            feedback = nil
            deletionFeedback = nil
        }
        .accessibilityIdentifier("scheduler.task.\(task.id.uuidString)")
        .opacity(task.isEnabled ? 1 : 0.55)
    }

    @ViewBuilder
    private var detailPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let pendingDeletion {
                    deletionConfirmationSection(pendingDeletion)
                }
                if let deletionFeedback {
                    Text(deletionFeedback.message)
                        .font(typography?.caption ?? .caption)
                        .foregroundStyle(deletionFeedback.isError
                            ? (theme?.statusDanger ?? .red)
                            : (theme?.statusSuccess ?? .green))
                        // F16 原生 AX 验收（scheduler-f16-baseline-028 :526-:527）：
                        // 反馈文案已由 confirmDeletion 的 .rejected(.persistenceFailed)
                        // 分支写入 deletionFeedback 并真实渲染（R27 raw :526 的
                        // schedulerFindAX 命中本 identifier，证明状态与节点在场），
                        // 缺口只在曝光：未声明为单一可访问性元素的普通 Text 在本
                        // 托管宿主的两条探针通道下，identifier 落在附件节点上，而
                        // 该节点 kAXDescription/kAXTitle/本地 accessibilityLabel
                        // 全为 nil（同一失效类已由 :355-:373 删除入口、:442-:466
                        // 取消/确认按钮、:471-:473 确认区容器在本文件实测收敛）。
                        // 沿用同一配方：先聚合为单一元素，再在其之后声明标签与
                        // 标识符（聚合元素只承接其后声明的属性，见 :360-:363），
                        // 使被投射的单一元素自带可见反馈原文案；不新增隐藏元素、
                        // 不改文案、不加按钮 trait（本元素是静态反馈，非控件）。
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(deletionFeedback.message)
                        .accessibilityIdentifier("scheduler.delete.feedback")
                }
                if let preview {
                    previewSection(preview)
                    authorizationSection(preview)
                    occurrenceSection(taskID: preview.taskID)
                } else if pendingDeletion == nil && deletionFeedback == nil {
                    ContentUnavailableView(
                        "选择一个任务",
                        systemImage: "calendar.badge.clock",
                        description: Text("预览不会写入执行记录；确认前请核对版本、目标项目和授权范围。")
                    )
                }
            }
            .padding(16)
        }
        .frame(minWidth: ColumnLayout.detailMinWidth, maxWidth: .infinity)
    }

    private func deletionConfirmationSection(_ request: SchedulerTaskDeletionRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("确认删除定时任务")
                .font(typography?.headline ?? .headline)
            Text("“\(request.taskName.isEmpty ? "未命名任务" : request.taskName)” · v\(request.taskVersion)")
                .font(typography?.body ?? .body)
                .fontWeight(.medium)
            Text("任务将停用并保留删除标记；历史执行记录和待对账记录不会被清除。")
                .font(typography?.caption ?? .caption)
                .foregroundStyle(.secondary)
            HStack {
                Text("确认有效至 \(request.expiresAt.formatted(date: .omitted, time: .shortened))")
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") {
                    pendingDeletion = nil
                    deletionFeedback = nil
                }
                // F16 原生 AX 验收（scheduler-f16-baseline-028 :484-:488）：与删除
                // 入口同一失效类——未声明为单一元素的 plain Button 在本宿主两条
                // 通道下只会落在无 role 的附件节点上（R18C/设置族 hit=false 同形
                // 实测），且聚合元素必须自带标签与真实动作。动作仍调用与可见按钮
                // 完全相同的既有清理路径，不新增语义。
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("取消")
                .accessibilityAction {
                    pendingDeletion = nil
                    deletionFeedback = nil
                }
                .accessibilityIdentifier("scheduler.delete.cancel")
                Button("确认删除", role: .destructive) {
                    confirmDeletion(request)
                }
                // 同一收敛配方（lane 190，fixed2 raw :476/:522 根因）：标签与对既有
                // confirmDeletion 生产入口的显式默认动作一并移到聚合之后，被投射的
                // 单一元素才同时携带 :497 期望的组合标签与可真实到达 Store 删除边界
                // 的按压语义。控件未改名、未移动。
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("确认删除定时任务 \(request.taskName.isEmpty ? "未命名任务" : request.taskName)")
                .accessibilityAction { confirmDeletion(request) }
                .accessibilityIdentifier("scheduler.delete.confirm")
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("删除定时任务 \(request.taskName.isEmpty ? "未命名任务" : request.taskName)，版本 \(request.taskVersion)")
        .accessibilityIdentifier("scheduler.delete.confirmation")
    }

    private func previewSection(_ preview: SchedulerTaskPreview) -> some View {
        let projection = productionProjection(for: preview)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("只读预览")
                    .font(typography?.headline ?? .headline)
                Spacer()
                Button("重新预览") {
                    self.preview = makePreview(taskID: preview.taskID)
                    sourceAnchorConfirmed = false
                    feedback = nil
                }
                .accessibilityIdentifier("scheduler.preview.refresh")
            }
            keyValue("版本", "v\(preview.taskVersion)")
            keyValue("Cron", preview.cronExpression)
            keyValue("目标项目", preview.targetProjectID ?? "未绑定")
            keyValue("目标会话", preview.targetSessionID?.uuidString ?? "未绑定")
            keyValue("来源用户轮次（从 1 开始）", preview.targetTurnID.map(String.init) ?? "未绑定")
            if let providerPreflight = preview.providerPreflight {
                keyValue("选定服务商", providerPreflight.providerID ?? "未解析")
                keyValue("选定模型", providerPreflight.modelID ?? "未解析")
                keyValue("凭据与模型前置", providerPreflight.status.displayLabel)
                if !providerPreflight.isReadyForExecution {
                    Text(providerPreflight.detail)
                        .font(typography?.caption ?? .caption)
                        .foregroundStyle(theme?.statusDanger ?? .red)
                }
            } else {
                keyValue("凭据与模型前置", "未装配")
                Text("当前服务商和模型的前置条件无法复核，请刷新预览。")
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(theme?.statusDanger ?? .red)
            }
            Toggle("确认以此来源轮次授权；每次执行另建独立轮次", isOn: $sourceAnchorConfirmed)
            if preview.sourceAnchorVersion != 2 {
                Text("旧任务的轮次含义尚未确认，本次确认后才可按新版语义执行。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            keyValue("时区", preview.timeZoneIdentifier)
            keyValue("指纹", String(preview.fingerprint.prefix(16)) + "…")
            keyValue("授权状态", preview.authorizationState.rawValue)
            productionProjectionSection(projection)
            Text(preview.predictedTriggers.isEmpty ? "一年边界内没有预测触发点。" : "预测触发（只读）")
                .font(typography?.caption ?? .caption)
                .foregroundStyle(.secondary)
            ForEach(preview.predictedTriggers, id: \.self) { trigger in
                Text(trigger.formatted(date: .abbreviated, time: .shortened))
                    .font(typography?.monospaced ?? .system(.caption, design: .monospaced))
            }
        }
        .accessibilityIdentifier("scheduler.preview.panel")
    }

    private func authorizationSection(_ preview: SchedulerTaskPreview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("显式授权")
                .font(typography?.headline ?? .headline)
            TextField("授权主体（默认当前用户）", text: $actorID)
                .textFieldStyle(.roundedBorder)
            keyValue("授权项目", preview.targetProjectID ?? "未绑定")
            Text(preview.observedPolicyRevision == nil ? "当前策略不可用，请刷新后重试。" : "将使用当前有效策略授权")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("预览有效至 \(preview.expiresAt.formatted(date: .omitted, time: .shortened))")
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("确认授权") {
                    confirm(preview)
                }
                .disabled(actorID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || preview.observedPolicyRevision == nil || preview.observedSourceAnchorDigest == nil
                          || !sourceAnchorConfirmed || !preview.hasValidTarget
                          || preview.providerPreflight?.isReadyForExecution != true)
                .accessibilityIdentifier("scheduler.preview.confirm")
            }
            if !preview.hasValidTarget {
                Text("目标会话、项目和回合必须由用户显式绑定后才能授权。")
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(theme?.statusDanger ?? .red)
            }
            if let feedback {
                Text(feedback)
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(theme?.statusDanger ?? .red)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func occurrenceSection(taskID: UUID) -> some View {
        let rows = store.occurrences.filter { $0.taskID == taskID }.sorted { $0.createdAt > $1.createdAt }
        return VStack(alignment: .leading, spacing: 8) {
            Text("运行记录")
                .font(typography?.headline ?? .headline)
            if rows.isEmpty {
                Text("尚无触发记录。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows) { occurrence in
                    occurrenceRow(occurrence)
                }
            }
        }
        .accessibilityIdentifier("scheduler.occurrences")
    }

    private func occurrenceRow(_ occurrence: SchedulerOccurrence) -> some View {
        let canRetry = canRetryOccurrence(occurrence)
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(SchedulerSlashObservation.userFacingState(for: occurrence.state))
                    .fontWeight(.medium)
                if occurrence.isCatchUp {
                    Label {
                        Text("补跑")
                    } icon: {
                        MinisIconView(.retry, size: 12)
                    }
                    .font(typography?.caption ?? .caption)
                    .accessibilityLabel("补跑")
                }
                Spacer()
                Text("v\(occurrence.taskVersion) · \(occurrence.scheduledMinute.formatted(date: .abbreviated, time: .shortened))")
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
            }
            Text(occurrence.command.isEmpty ? "（旧记录没有保存命令内容）" : occurrence.command)
                .font(typography?.monospaced ?? .system(.caption, design: .monospaced))
                .lineLimit(2)
            keyValue("来源用户轮次", occurrence.targetTurnID.map(String.init) ?? "未绑定")
            if let execution = occurrence.executionTurnID { keyValue("本次执行轮次", String(execution)) }
            if let target = occurrence.targetSessionID,
               let destination = URL(string: ChatStore.sessionDeepLink(for: target)) {
                Link("打开目标会话", destination: destination)
            }
            if let receipt = occurrence.deliveryReceipt {
                Text("回执：\(SchedulerSlashObservation.userFacingDeliveryStatus(receipt.status)) · \(receipt.detail ?? "无附加说明")")
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
            }
            if let preflight = runtime?.providerPreflight(taskID: occurrence.taskID),
               !preflight.isReadyForExecution {
                Text("模型服务未就绪：\(preflight.detail)")
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(theme?.statusDanger ?? .red)
            }
            HStack(spacing: 8) {
                if occurrence.state == .failed || occurrence.state == .unknown
                    || occurrence.state == .unknownReconciled, let runtime {
                    Button("查询目标事实") {
                        targetDeliveryObservations[occurrence.id] = runtime.queryTargetDelivery(id: occurrence.id)
                    }
                    .accessibilityIdentifier("scheduler.occurrence.query-target-fact.\(occurrence.id.uuidString)")
                }
                if occurrence.state == .failed, let runtime {
                    Button("重新执行") {
                        if !runtime.rerunFailedOccurrence(id: occurrence.id) {
                            rerunFeedback = "没有重新执行：任务已停用或删除，或这一分钟已有记录。请稍后再试。"
                        }
                    }
                    .help("失败的定时任务不会自动重试；点这里按任务当前版本再执行一次")
                    .accessibilityIdentifier("scheduler.occurrence.rerun.\(occurrence.id.uuidString)")
                }
                if occurrence.state == .unknown, let runtime {
                    Button("先对账") {
                        _ = runtime.reconcileUnknownOccurrence(id: occurrence.id)
                    }
                }
                if occurrence.state == .unknownReconciled,
                   let proof = occurrence.reconciliationProof,
                   let runtime {
                    Button("显式重试") {
                        _ = runtime.retryReconciledOccurrence(
                            id: occurrence.id,
                            expectedControlRevision: occurrence.controlRevision,
                            proofToken: proof
                        )
                    }
                    .disabled(!canRetry)
                    .help(canRetry ? "使用当前任务版本显式重试" : "任务版本或服务商凭据已失效，不能再次执行")
                    Button("终止") {
                        _ = runtime.abortReconciledOccurrence(
                            id: occurrence.id,
                            expectedControlRevision: occurrence.controlRevision,
                            proofToken: proof
                        )
                    }
                }
                if !occurrence.state.isTerminal, let runtime {
                    Button("取消") {
                        cancel(occurrence, using: runtime)
                    }
                }
            }
            if let rerunFeedback, occurrence.state == .failed {
                Text(rerunFeedback)
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
            }
            if let observation = targetDeliveryObservations[occurrence.id] {
                Text("目标事实观测（仅查询）：\(targetDeliveryObservationText(observation))")
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("scheduler.occurrence.target-fact-observation.\(occurrence.id.uuidString)")
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("scheduler.occurrence.\(occurrence.id.uuidString)")
    }

    private func targetDeliveryObservationText(_ observation: SchedulerTargetDeliveryObservation) -> String {
        switch observation {
        case .unavailable:
            "目标查询不可用；原执行状态与回执保留。"
        case .noMatchingFact:
            "未查到匹配的投递事实，投递结果仍不确定；不能据此认定未发生执行或重新派发。"
        case .identityConflict:
            "目标事实与此记录身份不匹配，拒绝归并；原执行状态与回执保留。"
        case .deliveryObserved:
            "已观测到匹配的持久投递事实；本次仅查询，执行状态未改变。"
        case .deliveryConflictsWithFailure:
            "已观测到投递，与原失败报告冲突；执行仍为失败，未重试，不能据此认定任务成功。"
        }
    }

    private func productionProjection(for preview: SchedulerTaskPreview) -> SchedulerControlProductionProjection {
        SchedulerControlProductionProjection(
            preview: preview,
            occurrences: store.occurrences
        )
    }

    private func productionProjectionSection(_ projection: SchedulerControlProductionProjection) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("生产投影（保存前）")
                .font(.subheadline)
            keyValue("触发", projection.trigger.cronExpression)
            keyValue(
                "下一次触发",
                projection.nextOccurrence?.formatted(date: .abbreviated, time: .shortened) ?? "无下一次触发"
            )
            let provider = projection.credential.providerID ?? "未选服务商"
            let model = projection.credential.modelID ?? "未选模型"
            let credentialRevision = projection.credential.credentialVersion ?? "未装配"
            keyValue("凭据来源", "\(provider) / \(model) · \(credentialRevision)")
            keyValue("来源", projection.source.displayValue)
            keyValue("目标", projection.target.isValid
                ? "\(projection.target.projectID ?? "") / turn \(projection.target.turnID ?? 0)"
                : "未绑定或无效")
            keyValue("任务版本", "任务 v\(projection.pinnedVersion.taskVersion) · occurrence \(projection.pinnedVersion.occurrenceVersions.map(String.init).joined(separator: ", ").isEmpty ? "无" : projection.pinnedVersion.occurrenceVersions.map(String.init).joined(separator: ", "))")
            keyValue("授权状态", projection.authorizationState.rawValue)
            Text(projection.canProduceDispatchIntent
                ? "当前设置满足条件，可以执行。"
                : "当前设置不会触发执行：请修复触发、来源、目标、授权或凭据前置。")
                .font(typography?.caption ?? .caption)
                .foregroundStyle(projection.canProduceDispatchIntent
                    ? (theme?.statusSuccess ?? .green)
                    : (theme?.statusDanger ?? .red))
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("scheduler.production-projection")
    }

    private func setEnabled(_ task: SchedulerTask, enabled: Bool) {
        guard store.persistenceError == nil else {
            feedback = "启用状态未改变：" + SchedulerConfirmationFeedback.storageUnavailableAdvice
            return
        }
        guard SchedulerControlTaskRevisionFence.matches(store.task(id: task.id), expectedVersion: task.version) else {
            feedback = "启用状态未改变：任务已被修改。请刷新后重新预览。"
            return
        }
        guard store.setEnabled(task.id, enabled: enabled, expectedVersion: task.version,
                               expectedEnablementRevision: task.enablementRevision) else {
            feedback = store.persistenceError == nil
                ? "启用状态未改变：任务或控制版本已变化，请重新预览。"
                : "启用状态未改变：" + SchedulerConfirmationFeedback.storageUnavailableAdvice
            return
        }
        if selectedTaskID == task.id {
            preview = makePreview(taskID: task.id)
        }
    }

    private func revokeAuthorization(_ task: SchedulerTask) {
        guard SchedulerTaskAuthorizationRevocationConsumer.revoke(task, store: store) else {
            feedback = "授权未撤销：任务或授权版本已变化，请刷新后重试。"
            return
        }
        preview = makePreview(taskID: task.id)
        feedback = "已撤销任务授权；后续执行须重新明确授权。"
    }

    private func canRetryOccurrence(_ occurrence: SchedulerOccurrence) -> Bool {
        guard SchedulerControlTaskRevisionFence.matches(
            store.task(id: occurrence.taskID),
            expectedVersion: occurrence.taskVersion
        ), store.persistenceError == nil else { return false }
        return runtime?.providerPreflight(taskID: occurrence.taskID)?.isReadyForExecution == true
    }

    private func cancel(_ occurrence: SchedulerOccurrence, using runtime: SchedulerTaskRuntime) {
        guard store.persistenceError == nil else {
            feedback = "取消未执行：" + SchedulerConfirmationFeedback.storageUnavailableAdvice
            return
        }
        guard SchedulerControlTaskRevisionFence.matches(
                  store.task(id: occurrence.taskID),
                  expectedVersion: occurrence.taskVersion
              ) else {
            feedback = "取消未执行：任务已被修改。请刷新后重新预览。"
            return
        }
        guard runtime.cancelOccurrence(
            id: occurrence.id,
            expectedTaskVersion: occurrence.taskVersion,
            expectedControlRevision: occurrence.controlRevision,
            owner: occurrence.leaseOwner,
            token: occurrence.leaseToken
        ) else {
            feedback = "取消未执行：这次执行记录的版本或占用状态已变化，请重新加载。"
            return
        }
        if preview?.taskID == occurrence.taskID {
            preview = makePreview(taskID: occurrence.taskID)
        }
    }

    private func makePreview(taskID: UUID) -> SchedulerTaskPreview? {
        SchedulerControlPreviewConsumer.makePreview(taskID: taskID, store: store, runtime: runtime)
    }

    private func confirm(_ preview: SchedulerTaskPreview) {
        guard let sessionID = preview.targetSessionID, let projectID = preview.targetProjectID,
              let ordinal = preview.targetTurnID, let policyRevision = runtime?.currentPolicyRevision(),
              sourceAnchorConfirmed, store.confirmPreview(
            preview,
            actorID: actorID,
            scopeID: projectID,
            policyRevision: policyRevision,
            sourceAnchorConfirmed: sourceAnchorConfirmed,
            currentSourceAnchorDigest: runtime?.sourceAnchorDigest(sessionID: sessionID,
                projectID: projectID, ordinal: ordinal),
            currentPolicyRevision: policyRevision
        ) else {
            feedback = SchedulerConfirmationFeedback.failureMessage(
                previewExpiresAt: preview.expiresAt,
                hasValidTarget: preview.hasValidTarget,
                storageUnavailable: store.persistenceError != nil
            )
            return
        }
        feedback = "已按该预览版本授权；启用状态仍由单独开关控制。"
        self.preview = makePreview(taskID: preview.taskID)
    }

    private func beginDeletion(_ task: SchedulerTask) {
        selectedTaskID = task.id
        if preview?.taskID != task.id { preview = nil }
        feedback = nil
        deletionFeedback = nil
        pendingDeletion = SchedulerTaskDeletionConsumer.request(for: task)
    }

    private func confirmDeletion(_ request: SchedulerTaskDeletionRequest) {
        switch SchedulerTaskDeletionConsumer.confirm(
            request,
            selectedTaskID: selectedTaskID,
            store: store
        ) {
        case .deleted:
            pendingDeletion = nil
            if selectedTaskID == request.taskID {
                selectedTaskID = nil
                preview = nil
            }
            deletionFeedback = SchedulerTaskDeletionFeedback(
                message: "已删除定时任务“\(request.taskName.isEmpty ? "未命名任务" : request.taskName)”；历史执行记录已保留。",
                isError: false
            )
        case .rejected(let failure):
            deletionFeedback = SchedulerTaskDeletionFeedback(
                message: deletionFailureMessage(failure),
                isError: true
            )
        }
    }

    private func deletionFailureMessage(_ failure: SchedulerTaskDeletionFailure) -> String {
        switch failure {
        case .existingPersistenceError:
            return "无法删除：持久化存储当前不可用，请先处理存储错误。"
        case .selectionChanged:
            return "无法删除：当前选择已变化，请重新选择任务并确认。"
        case .expired:
            return "无法删除：本次确认已过期，请重新发起删除。"
        case .missingOrDeleted:
            return "无法删除：任务已不存在或已经删除。"
        case .taskChanged:
            return "无法删除：任务版本已变化，请核对最新内容后重新确认。"
        case .persistenceFailed:
            return "删除未完成：持久化失败，任务已保留，请处理存储错误后重试。"
        }
    }

    private func keyValue(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }
}

private struct SchedulerControlTaskEditor: View {
    @Bindable var store: SchedulerTaskStore
    let task: SchedulerTask?
    var prefill: SchedulerTaskTargetPrefill?
    @Environment(\.dismiss) private var dismiss
    private enum Field: Hashable { case name, cron, command, session, project, turn }
    @FocusState private var focusedField: Field?
    @State private var name = ""
    @State private var cron = ""
    @State private var command = ""
    @State private var isEnabled = false
    @State private var sessionID = ""
    @State private var projectID = ""
    @State private var turnID = ""
    @State private var error: String?
    @State private var opensNewSession = false
    @State private var preset: SchedulerCronPreset = .daily
    @State private var hour = 9
    @State private var minute = 0
    @State private var weekday = 1
    @State private var sessionOptions: [SchedulerSessionOption] = []
    @State private var selectedSessionID: UUID?

    private static let weekdayNames = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]

    private var schedulableOptions: [SchedulerSessionOption] { sessionOptions.filter(\.isSchedulable) }
    private var selectedOption: SchedulerSessionOption? {
        sessionOptions.first { $0.id == selectedSessionID }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(task == nil ? "新建定时任务" : "编辑定时任务")
                .accessibilityIdentifier("scheduler.editor.title")
                .font(.headline)
                .padding(14)
            Divider()
            Form {
                TextField("任务名称", text: $name)
                    .accessibilityIdentifier("scheduler.editor.name")
                    .focused($focusedField, equals: .name)
                Picker("执行频率", selection: $preset) {
                    ForEach(SchedulerCronPreset.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: preset) { _, _ in applyPreset() }
                if preset != .custom {
                    HStack {
                        if preset == .weekly {
                            Picker("星期", selection: $weekday) {
                                ForEach(0..<7, id: \.self) { Text(Self.weekdayNames[$0]).tag($0) }
                            }
                            .onChange(of: weekday) { _, _ in applyPreset() }
                        }
                        if preset != .hourly {
                            Picker("时", selection: $hour) {
                                ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                            }
                            .onChange(of: hour) { _, _ in applyPreset() }
                        }
                        Picker("分", selection: $minute) {
                            ForEach(0..<60, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                        }
                        .onChange(of: minute) { _, _ in applyPreset() }
                    }
                    Text("对应 cron：\(cron)（使用任务预览所示时区）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    TextField("Cron（分 时 日 月 周）", text: $cron)
                        .accessibilityIdentifier("scheduler.editor.cron")
                        .focused($focusedField, equals: .cron)
                    Text("例如：0 9 * * * 表示每天 09:00（使用任务预览所示时区）。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TextField("提示词或支持的斜杠命令", text: $command, axis: .vertical)
                    .accessibilityIdentifier("scheduler.editor.prompt")
                    .lineLimit(2...4)
                    .focused($focusedField, equals: .command)
                Text("提示词会发送到绑定的目标会话；支持 /compact、/memory.propose，以及你在 ~/.claude/commands 里写的自定义命令（保存时展开成完整提示词），不是终端命令。执行仍须通过任务授权与当前策略。失败的任务不会自动重试，可在触发记录里点“重新执行”。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("启用", isOn: $isEnabled)
                Toggle("每次运行开新会话", isOn: $opensNewSession)
                    .accessibilityIdentifier("scheduler.editor.new-session")
                Text("开启后，每次触发都会在目标会话所在的项目里新建一个会话（标题含任务名和时间）并在其中运行；目标会话本身不被改动。修改这个选项需要重新授权。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                targetSection
                if let error {
                    Text(error).modifier(ReadableStatusForeground(status: .danger))
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("取消") { dismiss() }
                    .accessibilityIdentifier("scheduler.editor.cancel")
                Spacer()
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(14)
        }
        .frame(width: 500, height: 560)
        .onAppear {
            Task { @MainActor in
                await Task.yield()
                focusedField = .name
            }
            sessionOptions = SchedulerTaskPrefillInbox.shared.sessionOptions()
            guard let task else {
                cron = SchedulerCronPreset.cron(.daily, hour: hour, minute: minute, weekday: weekday) ?? "0 9 * * *"
                if let prefill {
                    sessionID = prefill.sessionID.uuidString
                    projectID = prefill.projectID
                    turnID = String(prefill.turnID)
                    selectedSessionID = prefill.sessionID
                } else if let current = SchedulerTaskPrefillInbox.shared.currentSessionID(),
                          let option = schedulableOptions.first(where: { $0.id == current }) {
                    chooseSession(option)
                } else if let first = schedulableOptions.first {
                    chooseSession(first)
                }
                return
            }
            name = task.name
            cron = task.cronExpression
            if let parsed = SchedulerCronPreset.parse(task.cronExpression) {
                preset = parsed.preset
                hour = parsed.hour
                minute = parsed.minute
                weekday = parsed.weekday
            } else {
                preset = .custom
            }
            command = task.command
            isEnabled = task.isEnabled
            opensNewSession = task.opensNewSessionEachRun
            sessionID = task.targetSessionID?.uuidString ?? ""
            projectID = task.targetProjectID ?? ""
            turnID = task.targetTurnID.map(String.init) ?? ""
            selectedSessionID = task.targetSessionID
        }
    }

    @ViewBuilder private var targetSection: some View {
        Section("执行位置") {
            if sessionOptions.isEmpty {
                TextField("目标 Session UUID", text: $sessionID)
                    .focused($focusedField, equals: .session)
                TextField("目标 Project ID", text: $projectID)
                    .focused($focusedField, equals: .project)
                TextField("目标 Turn ID", text: $turnID)
                    .focused($focusedField, equals: .turn)
            } else {
                Picker("目标会话", selection: $selectedSessionID) {
                    Text("请选择会话").tag(UUID?.none)
                    if let id = selectedSessionID, !schedulableOptions.contains(where: { $0.id == id }) {
                        Text(selectedOption?.menuTitle ?? "原目标会话（已不在列表）").tag(Optional(id))
                    }
                    ForEach(schedulableOptions) { Text($0.menuTitle).tag(Optional($0.id)) }
                }
                .onChange(of: selectedSessionID) { _, newValue in
                    if let newValue, let option = sessionOptions.first(where: { $0.id == newValue }) { chooseSession(option) }
                }
                if let option = selectedOption, option.isSchedulable {
                    Text("所属项目：\(option.projectName ?? option.projectID ?? "")；回合号自动取该会话当前最新一轮（第 \(turnID.isEmpty ? String(option.userTurnCount) : turnID) 轮）。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                let blocked = sessionOptions.count - schedulableOptions.count
                if blocked > 0 {
                    Text("另有 \(blocked) 个会话不能选：定时任务需要绑定到项目里、且已发过消息的会话。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// "/名称 参数" 命中自定义命令（用户级、所选会话项目的项目级）或内置提示词命令
    /// （/review、/commit、/init）时返回展开后的提示词；其余原样返回。保存时一次展开并冻结，
    /// 之后改命令文件不影响这个任务（无人值守的任务不在运行时读可能被改过的文件）。
    /// 内置命令（/compact、/memory.propose 等）不展开。
    static func expandingCustomCommand(_ text: String, projectRoot: URL? = nil) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), trimmed.count > 1 else { return text }
        let body = trimmed.dropFirst()
        let name = String(body.prefix { !$0.isWhitespace })
        guard !name.isEmpty,
              !CustomSlashCommandLoader.defaultReservedNames.contains(CommandDefinition.canonicalID(name)),
              let custom = CustomSlashCommandLoader.command(
                named: name, in: CustomSlashCommandLoader.load(projectRoot: projectRoot)),
              custom.source == .user || custom.source == .project || custom.source == .builtinPrompt
        else { return text }
        let expanded = custom.expandForSending(
            arguments: String(body.dropFirst(name.count)), projectRoot: projectRoot, allowedRoots: [])
        return expanded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : expanded
    }

    private func applyPreset() {
        if let generated = SchedulerCronPreset.cron(preset, hour: hour, minute: minute, weekday: weekday) {
            cron = generated
        }
    }

    private func chooseSession(_ option: SchedulerSessionOption) {
        selectedSessionID = option.id
        sessionID = option.id.uuidString
        projectID = option.projectID ?? ""
        // 保留编辑中任务原来的回合号，只在换了会话时自动取最新。
        if task == nil || task?.targetSessionID != option.id || turnID.isEmpty {
            turnID = String(option.userTurnCount)
        }
    }

    private func save() {
        guard CronValidator.validate(cron.trimmingCharacters(in: .whitespacesAndNewlines)) == nil else {
            error = CronValidator.validate(cron.trimmingCharacters(in: .whitespacesAndNewlines))
            return
        }
        let targetSession = UUID(uuidString: sessionID.trimmingCharacters(in: .whitespacesAndNewlines))
        let targetProject = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetTurn = Int(turnID.trimmingCharacters(in: .whitespacesAndNewlines))
        // 自定义斜杠命令在保存时就展开成完整提示词：任务摘要、授权预览和之后每次执行用的是同一段文字。
        let command = Self.expandingCustomCommand(self.command, projectRoot: selectedOption?.projectRoot)
        if var current = task {
            current.name = name
            current.cronExpression = cron.trimmingCharacters(in: .whitespacesAndNewlines)
            current.command = command
            current.isEnabled = isEnabled
            current.targetSessionID = targetSession
            current.targetProjectID = targetProject.isEmpty ? nil : targetProject
            current.targetTurnID = targetTurn
            current.opensNewSessionEachRun = opensNewSession
            if let error = store.update(current, expectedVersion: task?.version,
                                        expectedEnablementRevision: task?.enablementRevision) {
                self.error = error
                return
            }
        } else if let error = store.add(
            name: name,
            cronExpression: cron.trimmingCharacters(in: .whitespacesAndNewlines),
            command: command,
            isEnabled: isEnabled,
            targetSessionID: targetSession,
            targetProjectID: targetProject.isEmpty ? nil : targetProject,
            targetTurnID: targetTurn,
            opensNewSessionEachRun: opensNewSession
        ) {
            self.error = error
            return
        }
        dismiss()
    }
}
