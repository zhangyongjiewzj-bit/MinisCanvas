import Foundation
import CanvasCore

/// Immutable identity for a document-stage request that is executed outside
/// the UI. The stage ID is the node ID for late-write-back validation.
struct DocumentStageExecutionContext: Codable, Equatable, Hashable, Sendable {
    let identity: CanvasExecutionIdentity
    let attempt: Int
    let providerSnapshot: ProviderSnapshot
    let idempotencyKey: String

    init(
        identity: CanvasExecutionIdentity,
        attempt: Int = 1,
        providerSnapshot: ProviderSnapshot,
        idempotencyKey: String? = nil
    ) {
        self.identity = identity
        self.attempt = max(1, attempt)
        self.providerSnapshot = providerSnapshot
        self.idempotencyKey = idempotencyKey ?? [
            identity.canvasID.uuidString.lowercased(),
            identity.runID.uuidString.lowercased(),
            identity.graphRevision.description,
            identity.nodeID.uuidString.lowercased(),
            identity.nodeRevision.description,
            providerSnapshot.providerID,
            providerSnapshot.modelID,
            providerSnapshot.configurationFingerprint,
        ].joined(separator: "|")
    }

    func withAttempt(_ nextAttempt: Int) -> Self {
        Self(
            identity: identity,
            attempt: nextAttempt,
            providerSnapshot: providerSnapshot,
            idempotencyKey: idempotencyKey
        )
    }
}

// MARK: - 文档 AI 流水线（F16b）：纯数据模型
//
// 漫剧文本创作流程在文档工作区完成：每阶段独立选模型（providerID/modelID 由
// UI 层写入），逐阶段手动触发（每步人工审核打磨，不做一键流水线）。
// 本文件只定义数据模型；执行引擎与 UI 在后续段落实现。
//
// 级联约定：首个阶段为「小说导入」（input = 小说原文），后续阶段 input 接
// 上一阶段 output；用户回跳编辑某阶段后，调用 markDownstreamStale(fromIndex:)
// 把该索引之后的所有阶段标 stale（上游改动后下游待重跑）。

/// 阶段执行状态。
enum StageStatus: String, Codable, Sendable, Equatable, CaseIterable {
    /// 待执行
    case pending
    /// 执行中
    case running
    /// 执行完成，待人工审核
    case awaitingReview
    /// 审核通过
    case done
    /// 上游改动后下游待重跑
    case stale
}

extension StageStatus {
    /// 界面显示名；持久化值（rawValue）不变。
    var displayName: String {
        switch self {
        case .pending: "待执行"
        case .running: "执行中"
        case .awaitingReview: "待审核"
        case .done: "已通过"
        case .stale: "需重跑"
        }
    }
}

/// Secret-free link between a document stage and its durable result artifact.
/// The source ID is optional for the first stage; all revisions are opaque
/// fingerprints and never contain prompt text or provider credentials.
struct DocumentOutputLineage: Codable, Sendable, Equatable {
    let artifactID: String
    let sourceArtifactID: String?
    let sourceRevision: String
    let resultRevision: String
    let recordedAt: Date
}

/// Execution is independent from manual review (`StageStatus`). Old documents
/// have no execution record and remain pending until an explicit user action.
enum DocumentStageRunState: String, Codable, Sendable { case pending, running, succeeded, failed }
extension DocumentStageRunState {
    /// 界面显示名；持久化值（rawValue）不变。
    var displayName: String {
        switch self {
        case .pending: "未运行"
        case .running: "运行中"
        case .succeeded: "运行成功"
        case .failed: "运行失败"
        }
    }
}
struct DocumentStageRun: Codable, Sendable, Equatable {
    let id: UUID
    let sourceRevision: String
    var state: DocumentStageRunState
    var failureMessage: String?
}

/// 文档流水线的单个阶段。
struct DocumentStage: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    /// 阶段名（如「剧情大纲」）
    var name: String
    /// UI 层选定的 provider；空串 = 未选
    var providerID: String
    /// UI 层选定的模型；空串 = 未选
    var modelID: String
    /// 中文提示词模板（执行引擎与 input 拼装后发给模型）
    var promptTemplate: String
    /// 输入文本（通常为上一阶段 output；首阶段为小说原文）
    var input: String
    /// 本阶段模型输出
    var output: String
    var status: StageStatus
    var execution: DocumentStageRun?
    /// 持久化结果引用；stage reopen 时只显示引用状态，不自动获得执行权。
    var outputLineage: DocumentOutputLineage?

    init(
        id: UUID = UUID(),
        name: String,
        providerID: String = "",
        modelID: String = "",
        promptTemplate: String = "",
        input: String = "",
        output: String = "",
        status: StageStatus = .pending,
        outputLineage: DocumentOutputLineage? = nil,
        execution: DocumentStageRun? = nil
    ) {
        self.id = id
        self.name = name
        self.providerID = providerID
        self.modelID = modelID
        self.promptTemplate = promptTemplate
        self.input = input
        self.output = output
        self.status = status
        self.outputLineage = outputLineage
        self.execution = execution
    }
}

/// 文档流水线：有序阶段链 + 当前焦点索引。
///
/// currentIndex 按「位置」解释：removeStage 会平移/夹取保持合法；
/// moveStage 只调整阶段顺序，不移动焦点（UI 层按 stage.id 自行跟踪选中）。
struct DocumentPipeline: Codable, Sendable, Equatable {
    var stages: [DocumentStage]
    var currentIndex: Int

    init(stages: [DocumentStage] = [], currentIndex: Int = 0) {
        self.stages = stages
        self.currentIndex = stages.isEmpty
            ? 0
            : min(max(currentIndex, 0), stages.count - 1)
    }

    // MARK: 顺序维护

    /// 追加阶段到末尾；原本为空时焦点落到 0。
    mutating func appendStage(_ stage: DocumentStage) {
        let wasEmpty = stages.isEmpty
        stages.append(stage)
        if wasEmpty { currentIndex = 0 }
    }

    /// 删除指定索引的阶段，返回被删阶段；越界返回 nil。
    /// 焦点索引：被删阶段在焦点之前 → 前移一位；随后夹取到合法区间。
    @discardableResult
    mutating func removeStage(at index: Int) -> DocumentStage? {
        guard stages.indices.contains(index) else { return nil }
        let removed = stages.remove(at: index)
        if stages.isEmpty {
            currentIndex = 0
        } else if index < currentIndex {
            currentIndex -= 1
        } else {
            currentIndex = min(currentIndex, stages.count - 1)
        }
        return removed
    }

    /// 移动阶段：source 取出后插入 destination（数组搬移语义）。
    /// 越界或 source == destination 为无操作；焦点索引不跟随。
    mutating func moveStage(from source: Int, to destination: Int) {
        guard source != destination,
              stages.indices.contains(source),
              stages.indices.contains(destination) else { return }
        let stage = stages.remove(at: source)
        stages.insert(stage, at: destination)
    }

    // MARK: 回跳编辑级联

    /// 回跳编辑：把 fromIndex 之后（不含自身）的所有阶段标 .stale。
    /// 越界为无操作。fromIndex 阶段本身不动（其状态由编辑动作的调用方决定）。
    mutating func markDownstreamStale(fromIndex: Int) {
        guard stages.indices.contains(fromIndex) else { return }
        guard fromIndex + 1 < stages.count else { return }
        for i in (fromIndex + 1)..<stages.count {
            stages[i].status = .stale
            stages[i].outputLineage = nil
        }
    }

    /// Attach a result reference only after the stage output has reached a
    /// terminal state. Replacing it is explicit and leaves the old artifact
    /// available to the artifact store's rollback metadata.
    mutating func attachOutputLineage(
        at index: Int,
        artifactID: String,
        sourceArtifactID: String?,
        sourceRevision: String,
        resultRevision: String,
        recordedAt: Date = Date()
    ) {
        guard stages.indices.contains(index), !artifactID.isEmpty,
              !sourceRevision.isEmpty, !resultRevision.isEmpty,
              stages[index].status == .awaitingReview || stages[index].status == .done else { return }
        stages[index].outputLineage = DocumentOutputLineage(
            artifactID: artifactID,
            sourceArtifactID: sourceArtifactID,
            sourceRevision: sourceRevision,
            resultRevision: resultRevision,
            recordedAt: recordedAt
        )
    }

    /// Reconcile a persisted stage reference with the artifact store before
    /// the result consumer exposes an open/reveal action. A failed check keeps
    /// the opaque lineage visible for recovery while making the stage stale;
    /// no untrusted path or response text is copied into the document.
    @discardableResult
    mutating func reconcileOutputLineage(
        at index: Int,
        validation: ArtifactTargetValidation
    ) -> Bool {
        guard stages.indices.contains(index),
              let lineage = stages[index].outputLineage,
              lineage.artifactID == validation.artifactID else { return false }
        guard validation.status == .ready else {
            stages[index].status = .stale
            return false
        }
        return true
    }

    /// Explicit user action after a successful target validation. Reopening a
    /// durable result returns the stage to the review surface; it never
    /// grants execution authority or silently replaces the lineage.
    @discardableResult
    mutating func reopenOutput(
        at index: Int,
        validation: ArtifactTargetValidation
    ) -> Bool {
        guard reconcileOutputLineage(at: index, validation: validation) else { return false }
        stages[index].status = .awaitingReview
        return true
    }

    // MARK: 查询

    /// 首个 status == .pending 阶段的索引；无则 nil。
    /// 注意：stale 是「待重跑」，不计入此处——执行引擎按 stale 单独处理。
    var nextPendingIndex: Int? {
        stages.firstIndex { $0.status == .pending }
    }

    /// Creates a scoped stage token from the immutable stage ID. Callers must
    /// provide the graph/node revisions observed when execution started.
    func executionContext(
        canvasID: UUID,
        runID: UUID,
        graphRevision: Int,
        index: Int,
        nodeRevision: Int,
        attempt: Int = 1,
        providerSnapshot: ProviderSnapshot
    ) -> DocumentStageExecutionContext? {
        guard stages.indices.contains(index) else { return nil }
        return DocumentStageExecutionContext(
            identity: CanvasExecutionIdentity(
                canvasID: canvasID,
                runID: runID,
                graphRevision: graphRevision,
                nodeID: stages[index].id,
                nodeRevision: nodeRevision
            ),
            attempt: attempt,
            providerSnapshot: providerSnapshot
        )
    }
}

// MARK: - 漫剧六阶段预置模板（F16b）

/// 漫剧文本创作流水线模板：小说导入 → 剧情大纲 → 剧本 → 分镜 → 图片提示词 → 视频提示词。
enum ManjuDocumentTemplate {
    /// 提示词模板中的输入占位符（执行引擎替换为本阶段 input）
    static let inputPlaceholder = "{{input}}"

    /// 阶段名（顺序固定）
    static let stageNames: [String] = [
        "小说导入", "剧情大纲", "剧本", "分镜", "图片提示词", "视频提示词",
    ]

    /// 生成一份全新六阶段流水线：每阶段带默认中文提示词模板，
    /// providerID/modelID 留空（UI 层再选），状态全部 .pending，currentIndex = 0。
    static func make() -> DocumentPipeline {
        let templates: [String] = [
            "请将以下小说原文导入并整理排版，保留章节结构与原文内容，不做剧情改写：\n\n\(inputPlaceholder)",
            "请根据以下小说内容提炼剧情大纲，梳理主线、关键冲突、转折点与结局走向：\n\n\(inputPlaceholder)",
            "请根据以下剧情大纲扩写剧本，按场次组织，包含场景描述、人物动作与对白：\n\n\(inputPlaceholder)",
            "请根据以下剧本拆分分镜，逐镜列出镜号、画面内容、景别、运镜方式与情绪基调：\n\n\(inputPlaceholder)",
            "请根据以下分镜为每一镜撰写图片生成提示词，包含主体、场景、风格、光影与构图：\n\n\(inputPlaceholder)",
            "请根据以下分镜与图片提示词撰写视频生成提示词，包含镜头运动、人物动作与节奏时长：\n\n\(inputPlaceholder)",
        ]
        let stages = zip(stageNames, templates).map { name, template in
            DocumentStage(name: name, promptTemplate: template)
        }
        return DocumentPipeline(stages: stages, currentIndex: 0)
    }
}
