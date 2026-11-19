import Foundation
import CryptoKit
import Observation
import MinisCore

/// Secret-free provider-save diagnostics consumed by the edit sheet. The
/// category intentionally carries no provider name, path, credential, or raw
/// persistence error text.
enum ProviderSaveFailureCategory: Equatable, Sendable {
    case duplicateName
    case invalidName
    case missingCredential
    case keychainReadMissing
    case keychainReadDenied
    case keychainReadFailed
    case keychainWriteFailed
    case keychainDeleteFailed
    case metadataWriteFailed
    case keychainRollbackFailed
    case unknown

    init(persistenceError: EnvVarPersistenceError?) {
        switch persistenceError {
        case .invalidName: self = .invalidName
        case .missingCredential: self = .missingCredential
        case .keychainReadMissing: self = .keychainReadMissing
        case .keychainReadDenied: self = .keychainReadDenied
        case .keychainReadFailed: self = .keychainReadFailed
        case .keychainWriteFailed: self = .keychainWriteFailed
        case .keychainDeleteFailed: self = .keychainDeleteFailed
        case .metadataWriteFailed: self = .metadataWriteFailed
        case .keychainRollbackFailed: self = .keychainRollbackFailed
        case nil: self = .unknown
        }
    }

    static let allMessages: [String] = [
        ProviderSaveFailureCategory.duplicateName, .invalidName, .missingCredential,
        .keychainReadMissing, .keychainReadDenied, .keychainReadFailed, .keychainWriteFailed,
        .keychainDeleteFailed, .metadataWriteFailed, .keychainRollbackFailed, .unknown,
    ].map(\.message)

    var message: String {
        switch self {
        case .duplicateName:
            return "保存失败：已存在同名供应商。"
        case .invalidName:
            return "保存失败：供应商名称不合法（需字母开头，仅含字母/数字/下划线）。"
        case .missingCredential:
            return "保存失败：API Key 不能为空。"
        case .keychainReadMissing:
            return "保存失败：旧 API Key 已不在钥匙串中；请直接输入新 Key 后重试。"
        case .keychainReadDenied:
            return "保存失败：钥匙串拒绝读取旧 API Key；请检查钥匙串权限，或直接输入新 Key 替换。"
        case .keychainReadFailed:
            return "保存失败：读取旧 API Key 时发生钥匙串错误；请重试，或直接输入新 Key 替换。"
        case .keychainWriteFailed:
            return "保存失败：凭据安全存储失败，当前内容未改变。"
        case .keychainDeleteFailed:
            return "保存失败：旧凭据清理失败，当前内容未改变。"
        case .metadataWriteFailed:
            return "保存失败：供应商元数据写入失败，当前内容未改变。"
        case .keychainRollbackFailed:
            return "保存失败：安全存储回滚失败，已拒绝继续保存。"
        case .unknown:
            return "保存失败：凭据持久化失败，当前内容未改变。"
        }
    }
}

/// Opaque, secret-free identity for one credential binding. The token is
/// deliberately not derived from or comparable to credential bytes.
struct ProviderCredentialVersion: Equatable, Hashable, Sendable {
    private let rawValue: UUID

    init() {
        rawValue = UUID()
    }

    static func fresh() -> Self {
        Self()
    }

    var opaqueValue: String {
        rawValue.uuidString.lowercased()
    }
}

/// Readiness may be reused only when the credential binding is unchanged.
enum ProviderCredentialVersionBoundary {
    static func canReuse(
        observed: ProviderCredentialVersion,
        current: ProviderCredentialVersion
    ) -> Bool {
        observed == current
    }
}

enum ProviderReadinessOperation: Hashable, Sendable {
    case reachability
    case authentication
    case modelDiscovery
    case minimalModelRequest(String)
}

struct ProviderReadinessTransportRequest: Sendable {
    var ownedMMAction: OwnedMMActionTicket? = nil
    let operation: ProviderReadinessOperation
    let providerID: String
    let baseURL: URL
    let apiKey: String
    let modelID: String?
    let protocolType: ProviderWireProtocol
}

struct ProviderReadinessTransportResponse: Equatable, Sendable {
    let statusCode: Int
    let body: String
    let modelIDs: [String]
    let latency: Int?
    let errorCategory: ProviderReadinessFailureCategory?

    init(
        statusCode: Int,
        body: String = "",
        modelIDs: [String] = [],
        latency: Int? = nil,
        errorCategory: ProviderReadinessFailureCategory? = nil
    ) {
        self.statusCode = statusCode
        self.body = body
        self.modelIDs = modelIDs
        self.latency = latency
        self.errorCategory = errorCategory
    }
}

enum SettingsProviderReadinessTransportError: Error, Equatable, Sendable, LocalizedError {
    case missingCredential
    case invalidURL
    case timeout
    case redirectRejected
    case invalidResponse
    case unavailable

    var errorDescription: String? {
        switch self {
        case .missingCredential:
            return "readiness request requires a credential"
        case .invalidURL:
            return "readiness URL rejected"
        case .timeout:
            return "readiness request timed out"
        case .redirectRejected:
            return "readiness redirect rejected"
        case .invalidResponse:
            return "readiness response invalid"
        case .unavailable:
            return "readiness transport unavailable"
        }
    }
}

protocol SettingsProviderReadinessTransport: Sendable {
    /// Only the production URLSession transport may promote a successful
    /// remote probe to live evidence. Test transports remain unverified.
    var canProduceLiveEvidence: Bool { get }

    func send(_ request: ProviderReadinessTransportRequest) async throws -> ProviderReadinessTransportResponse
}

extension SettingsProviderReadinessTransport {
    var canProduceLiveEvidence: Bool { false }
}

/// Disposable/field profiles must not retain a URLSession-backed readiness
/// transport. An attempted probe is rejected before any request reaches the
/// network and can never be promoted to live evidence.
struct FailClosedProviderReadinessTransport: SettingsProviderReadinessTransport {
    let canProduceLiveEvidence = false

    func send(
        _ request: ProviderReadinessTransportRequest
    ) async throws -> ProviderReadinessTransportResponse {
        throw SettingsProviderReadinessTransportError.unavailable
    }
}

enum ProviderReadinessStageStatus: String, Equatable, Sendable {
    case notRun
    case loading
    case passed
    case failed
    case cancelled
}

struct ProviderReadinessStage: Equatable, Sendable {
    let status: ProviderReadinessStageStatus
    let detail: String
    let statusCode: Int?
}

struct ProviderModelReadiness: Identifiable, Equatable, Sendable {
    let modelID: String
    let status: ProviderReadinessStageStatus
    let redactedResult: String
    let readiness: ProviderReadiness?
    let errorCategory: ProviderReadinessFailureCategory?
    let latency: Int?
    let lineage: ProviderReadinessLineage

    init(
        modelID: String,
        status: ProviderReadinessStageStatus,
        redactedResult: String,
        readiness: ProviderReadiness?,
        errorCategory: ProviderReadinessFailureCategory? = nil,
        latency: Int? = nil,
        lineage: ProviderReadinessLineage? = nil
    ) {
        self.modelID = modelID
        self.status = status
        self.redactedResult = redactedResult
        self.readiness = readiness
        self.errorCategory = errorCategory ?? readiness?.errorCategory
        self.latency = latency ?? readiness?.latency
        self.lineage = lineage
            ?? readiness?.lineage
            ?? ProviderReadinessLineage.derived(
                providerID: "settings",
                modelID: modelID,
                checkedAt: readiness?.checkedAt ?? Date()
            )
    }

    var id: String { modelID }
}

struct SettingsProviderReadinessReport: Equatable, Sendable {
    let recordID: String
    let providerID: String
    let checkedAt: Date
    let configuration: ProviderReadinessStage
    let reachability: ProviderReadinessStage
    let authentication: ProviderReadinessStage
    let modelDiscovery: ProviderReadinessStage
    let discoveredModelIDs: [String]
    let modelChecks: [ProviderModelReadiness]
    let state: ProviderReadinessState
    let redactedResult: String
    var configurationFingerprint: String? = nil
}

enum ProviderDraftProbeState: Equatable, Sendable {
    case idle
    case loading
    case loaded([String])
    case empty
    case failed(String)
    case cancelled
}

/// 只用于“默认勾选”和“抽测挑选”：名字像向量、重排、语音、图像、审核的模型多半不是聊天模型。
/// 不拒绝任何模型，用户仍可手动勾选。
enum ProviderModelNameHeuristics {
    private static let nonChatKeywords = [
        "embed", "rerank", "whisper", "tts", "transcribe", "moderation",
        "dall-e", "dalle", "stable-diffusion", "sdxl", "text-to-image", "image-gen"
    ]
    static func likelyNonChat(_ modelID: String) -> Bool {
        let lower = modelID.lowercased()
        return nonChatKeywords.contains { lower.contains($0) }
    }
}

enum ProviderDraftModelMerger {
    /// Keep every manual row in place, then append only new discovered IDs.
    static func merge(manual: [String], discovered: [String]) -> [String] {
        var result = manual
        var seen = Set(
            manual.compactMap {
                let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
        )
        for rawModelID in discovered {
            let modelID = rawModelID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !modelID.isEmpty, seen.insert(modelID).inserted else { continue }
            result.append(modelID)
        }
        return result
    }
}

// MARK: - 设置中心数据接线（D5）
//
// 统一持有 D1 SettingsStore（AppSettings 持久化）/ C1a EnvVarStore /
// C1c LogManager / C2b MemoryStore / SessionStore / ProviderFactory 注册表，
// 向 SwiftUI 设置中心暴露可绑定状态与操作。
//
// 只做加法：不修改 MinisCore 既有 API 行为。

// MARK: - 日志级别互转（SettingsLogLevel ↔ LogManager.LogLevel）

extension LogLevel {
    /// 将持久化的 `SettingsLogLevel` 映射为 `LogManager` 级别。
    public init(_ level: SettingsLogLevel) {
        switch level {
        case .debug: self = .debug
        case .info: self = .info
        case .warn: self = .warn
        case .error: self = .error
        }
    }
}

extension SettingsLogLevel {
    /// 将 `LogManager` 级别映射回持久化级别。
    public init(_ level: LogLevel) {
        switch level {
        case .debug: self = .debug
        case .info: self = .info
        case .warn: self = .warn
        case .error: self = .error
        }
    }
}

enum SettingsDeletionError: Error, Equatable {
    case notFound(String)
    case operationFailed(String)
    case rollbackFailed(String)
}

private struct SettingsLogFingerprint: Codable {
    let timestamp: Date
    let level: Int
    let category: String
    let message: String
}

private enum SettingsSessionBatchKind {
    case retention
    case all

    var targetID: String {
        switch self {
        case .retention: return "sessions.retention"
        case .all: return "sessions.all"
        }
    }

    var targetName: String {
        switch self {
        case .retention: return "过期会话"
        case .all: return "全部会话"
        }
    }
}

private struct SettingsSessionBatchRecoveryReceipt: Codable {
    let aggregate: DeletionReceipt
    let childReceipts: [DeletionReceipt]
}

struct MemoryImportResult: Equatable, Sendable {
    let added: Int
    let skipped: Int
}

/// The destination choices shown for an editable Markdown import.  All three
/// choices are bound to the concrete active session/project scope at preview;
/// the choice controls visibility metadata and is never inferred from the
/// Markdown text.
enum MemoryImportScope: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case personal
    case project
    case temporary

    var id: String { rawValue }

    var label: String {
        switch self {
        case .personal: return "个人"
        case .project: return "项目"
        case .temporary: return "临时"
        }
    }

    var explanation: String {
        switch self {
        case .personal:
            return "当前本地用户可见，并保留在当前记忆存储中。"
        case .project:
            return "绑定当前会话与项目，沿用现有项目记忆隔离。"
        case .temporary:
            return "绑定当前会话，适合先导入后手动删除的内容。"
        }
    }
}

/// Compatibility spelling for callers that describe this as a Markdown
/// scope.  The persisted facts still use the existing `MemoryScope` contract.
typealias MemoryMarkdownImportScope = MemoryImportScope
typealias MemoryMarkdownScopeSelection = MemoryImportScope

enum MemoryMarkdownImportError: Error, Equatable, Sendable, LocalizedError {
    case invalidPreview
    case sourceChanged
    case scopeNotSelected
    case invalidScope
    case scopeChanged
    case ownerChanged

    var errorDescription: String? {
        switch self {
        case .invalidPreview:
            return "记忆 Markdown 预览已失效，请重新选择文件。"
        case .sourceChanged:
            return "记忆 Markdown 文件在确认前已变化，请重新预览。"
        case .scopeNotSelected:
            return "请选择记忆导入作用域后再确认。"
        case .invalidScope:
            return "当前记忆作用域不可用，请先选择有效的会话和项目。"
        case .scopeChanged:
            return "当前会话或项目在确认前发生变化，请重新预览。"
        case .ownerChanged:
            return "当前本地用户身份在确认前发生变化，请重新预览。"
        }
    }
}

struct MemoryMarkdownImportPreview: Identifiable, Equatable, Sendable {
    let id: UUID
    let sourceURL: URL?
    let sourceName: String
    let sourceData: Data
    let sourceHash: String
    let document: MemoryMarkdownDocument
    let capturedScope: MemoryScope?
    let selectedScope: MemoryImportScope?
    let boundTargetScope: MemoryScope?
    let boundOwnerUserID: String?

    var facts: [MemoryFact] { document.facts }
    var categoryCounts: [MemoryCategory: Int] { document.categoryCounts }
    var factCount: Int { document.facts.count }
    var contentHash: String { sourceHash }
    var scope: MemoryImportScope? { selectedScope }

    fileprivate init(
        id: UUID = UUID(),
        sourceURL: URL?,
        sourceName: String,
        sourceData: Data,
        sourceHash: String,
        document: MemoryMarkdownDocument,
        capturedScope: MemoryScope?,
        selectedScope: MemoryImportScope? = nil,
        boundTargetScope: MemoryScope? = nil,
        boundOwnerUserID: String? = nil
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.sourceName = sourceName
        self.sourceData = sourceData
        self.sourceHash = sourceHash
        self.document = document
        self.capturedScope = capturedScope
        self.selectedScope = selectedScope
        self.boundTargetScope = boundTargetScope
        self.boundOwnerUserID = boundOwnerUserID
    }

    fileprivate func selecting(
        _ scope: MemoryImportScope,
        target: MemoryScope,
        ownerUserID: String?
    ) -> Self {
        Self(
            id: id,
            sourceURL: sourceURL,
            sourceName: sourceName,
            sourceData: sourceData,
            sourceHash: sourceHash,
            document: document,
            capturedScope: capturedScope,
            selectedScope: scope,
            boundTargetScope: target,
            boundOwnerUserID: ownerUserID
        )
    }
}

enum MemoryExportFormat: String, Codable, Equatable, Sendable {
    case json
    case markdown

    var fileExtension: String { rawValue == "json" ? "json" : "md" }
    var label: String { rawValue == "json" ? "JSON" : "Markdown" }
}

struct MemoryFileExportReceipt: Equatable, Sendable {
    let format: MemoryExportFormat
    let url: URL
    let byteCount: Int
    let contentHash: String
}

private struct MemoryMarkdownImportPlan: Sendable {
    let targetScope: MemoryScope
    let incomingFacts: [MemoryFact]
    let trustedPrincipal: MemoryTrustedPrincipal?
}

enum MemoryFileExportError: Error, Equatable, Sendable, LocalizedError {
    case invalidDestination
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .invalidDestination:
            return "导出目标不是有效的文件路径。"
        case .verificationFailed:
            return "导出文件未通过完成性校验。"
        }
    }
}

enum MemoryFileEditorPreparation: Equatable, Sendable {
    case ready(relativePath: String, content: String)
    case unreadable
}

/// Truthful outcome for the file-based memory editor.  The UI uses this
/// result to dismiss only after the throwing store has completed successfully;
/// failures intentionally carry no raw filesystem detail.
enum MemoryFileOperationResult: Equatable, Sendable {
    case saved
    case deleted
    case saveInvalidTarget
    case saveFailed
    case deleteInvalidTarget
    case deleteFailed

    var succeeded: Bool {
        switch self {
        case .saved, .deleted:
            return true
        case .saveInvalidTarget, .saveFailed, .deleteInvalidTarget, .deleteFailed:
            return false
        }
    }

    func message(for name: String) -> String {
        switch self {
        case .saved:
            return "已保存 " + name + "。"
        case .deleted:
            return "已删除 " + name + "。"
        case .saveInvalidTarget:
            return "保存失败：找不到记忆文件 " + name + "，编辑内容和文件列表未改变，可重试。"
        case .saveFailed:
            return "保存失败：" + name + " 未改变，编辑内容和文件列表已保留，可重试。"
        case .deleteInvalidTarget:
            return "删除失败：找不到记忆文件 " + name + "，文件列表未改变，可重试。"
        case .deleteFailed:
            return "删除失败：" + name + " 未改变，文件列表已保留，可重试。"
        }
    }
}

// MARK: - SettingsCenter

@MainActor
@Observable
final class SettingsCenter {
    var systemNotifications: SystemNotificationController?
    /// Same controller the Settings page "常驻" section edits; the conversation keep-awake switch goes through it.
    var residentLifecycle: ResidentLifecycleController?
    /// 对话里说"忘掉…"时预填到 设置 › 记忆 检索框的词；记忆页读取并检索一次后清空。
    var pendingMemorySearchQuery: String?
    /// Only user-initiated, built-in producers receive a first-launch default.
    /// External scheduler/agent source IDs are deliberately absent from this list.
    enum BuiltInMemoryCandidateSource: String, CaseIterable, Identifiable {
        case settingsCenter = "settings-center"
        case composerCommand = "composer-command"
        case presetCommand = "preset-command"
        case chatSessionRuntime = "chat-session-runtime"
        case userRequestedChatFact = "composer-user-memory"

        var id: String { sourceID }

        var sourceID: String {
            self == .userRequestedChatFact ? MemoryProposalConsumer.chatProjectSourceID : rawValue
        }

        var label: String {
            switch self {
            case .settingsCenter: "记忆设置"
            case .composerCommand: "斜杠命令"
            case .presetCommand: "快捷记忆命令"
            case .chatSessionRuntime: "聊天记忆提议"
            case .userRequestedChatFact: "对话中明确请求记住的事实"
            }
        }
    }

    static let memoryCandidateSubmissionSourceID = BuiltInMemoryCandidateSource.settingsCenter.rawValue

    /// Production composition installs one canonical settings owner before
    /// the main content is rendered. Views may read it, never replace it.
    @MainActor
    private(set) static weak var active: SettingsCenter?

    enum ContextTurnSettingsResolution: Sendable {
        case accepted(ContextTurnSettingsSnapshot)
        case ownerUnavailable
        case scopeMismatch
        case invalid
    }

    /// Capture mutable settings before the turn suspends. Directory identity
    /// is checked separately on the worker against the root admitted at attach.
    struct ContextTurnSettingsInputs: Sendable {
        let ownerDirectory: URL?
        let resolution: ContextTurnSettingsResolution
        /// C7：显式上下文长度超过所选模型窗口、已被钳制到窗口时非 nil。
        let clampNotice: ContextClampNotice?
    }

    /// C7：显式上下文长度超窗被钳制的事实与提示文案。
    /// 同一会话同一 (requestedTokens, windowTokens) 只提示一次，由消费方按 `dedupeKey` 去重。
    struct ContextClampNotice: Sendable, Equatable {
        let modelID: String
        let requestedTokens: Int
        let windowTokens: Int

        var dedupeKey: String { "\(modelID)|\(requestedTokens)|\(windowTokens)" }

        var displayLine: String {
            "所选上下文长度 \(requestedTokens) 超过 \(modelID) 窗口，已按 \(windowTokens) 处理"
        }
    }

    static func captureContextTurnSettingsInputs(
        sessionID: String, model: LLMModel
    ) -> ContextTurnSettingsInputs {
        guard let center = active else {
            return ContextTurnSettingsInputs(ownerDirectory: nil, resolution: .ownerUnavailable, clampNotice: nil)
        }
        let window = model.contextWindowTokens
        let requested = center.settingsMirror.agent.contextLengthTokens
        // C7：超窗时钳制到窗口并产出提示，而不是让 Core 初始化器返回 nil 中止整轮。
        // Core 初始化器的“超窗返回 nil”合同不变。
        let clamped: Int? = requested.map { $0 > window ? window : $0 }
        let clampNotice: ContextClampNotice? = requested.flatMap { value in
            value > window
                ? ContextClampNotice(modelID: model.id, requestedTokens: value, windowTokens: window)
                : nil
        }
        let snapshot = ContextTurnSettingsSnapshot(
            sessionID: sessionID,
            modelID: model.id,
            modelContextWindowTokens: window,
            requestedContextLengthTokens: clamped,
            historyTurnLimit: center.settingsMirror.agent.historyTurnLimit
        )
        return ContextTurnSettingsInputs(
            ownerDirectory: center.sessionStore.directory,
            resolution: snapshot.map(ContextTurnSettingsResolution.accepted) ?? .invalid,
            clampNotice: clampNotice
        )
    }

    /// Production's two SessionStore objects may be distinct, so use the
    /// canonical directory identity already used by BridgeStore's AJ-2 gate.
    /// A different disposable/profile root must never supply this turn's settings.
    static func contextTurnSettingsSnapshot(
        for sessionStore: SessionStore,
        sessionID: String,
        model: LLMModel,
        canonicalizeDirectory: @Sendable (URL) -> URL = {
            $0.resolvingSymlinksInPath().standardizedFileURL
        }
    ) -> ContextTurnSettingsResolution {
        let captured = captureContextTurnSettingsInputs(sessionID: sessionID, model: model)
        guard let ownerDirectory = captured.ownerDirectory else { return .ownerUnavailable }
        let expected = canonicalizeDirectory(sessionStore.directory)
        let actual = canonicalizeDirectory(ownerDirectory)
        guard expected == actual else { return .scopeMismatch }
        return captured.resolution
    }

    // 数据层实例（可注入，测试传临时目录）
    let settingsStore: SettingsStore
    let envStore: EnvVarStore
    let memoryStore: MemoryStore
    var memoryExportBeforeWriteForTesting: (@Sendable () async -> Void)?
    var backupExportBeforeDispatchForTesting: (@Sendable () async -> Void)?
    let memoryProposalConsumer: MemoryProposalConsumer
    /// App composition binds this to the active ChatStore session/project.
    /// Missing binding is fail-closed for all memory writes.
    var memoryScopeProvider: (() -> MemoryScope?)?
    /// Local identity used only for the explicit Personal Markdown target.
    /// A host with an account identity may replace this provider; tests can
    /// set it to nil to verify the fail-closed path.
    var memoryOwnerUserIDProvider: (() -> String?)? = {
        ProcessUIDMemoryPrincipalSource.production.trustedPrincipal()?.userID
    }
    var memoryTrustedPrincipalProvider: (() -> MemoryTrustedPrincipal?)? = {
        ProcessUIDMemoryPrincipalSource.production.trustedPrincipal()
    }
    /// AJ-47：文件式记忆（GLOBAL.md / SOUL.md / 每日日志）。
    let memoryFileStore: MemoryFileStore
    let sessionStore: SessionStore
    private let sessionDeletionService: SessionDeletionService
    @ObservationIgnored
    var onConfirmedSessionDeletion: (([String]) -> Void)?
    /// O-04: returns a Chinese refusal when the session still has a running
    /// background child. Set by the composition root; nil means no live work known.
    @ObservationIgnored
    var sessionDeletionBlocker: ((String) -> String?)?
    let logManager: LogManager
    /// E6: MCP 服务器配置管理（CRUD + mcps.json 持久化）。
    let mcpManager: MCPServerManager
    /// F14 P1-3：技能库实例（SyncManager 的 skills 域共用）。
    /// 生产默认 `SkillStore()`（~/Library/Application Support/MinisCore/skills，
    /// 与 BridgeStore 启动部署 manju-* 同根）；测试注入临时根。
    let skillStore: SkillStore
    /// 波4：用量统计（token 消耗 / API 调用 / 分模型聚合，UserDefaults 持久化）。
    /// 生产默认 `UsageStore()`（.standard）；测试注入临时 suite 隔离。
    let usageStore: UsageStore
    /// BL6 immutable effective-settings boundary. A failed catalog validation
    /// locks this instance closed until the owning SettingsCenter is rebuilt.
    let bl6SettingsSnapshotGuard: BL6SettingsSnapshotGuard
    /// WP-2：Settings 是 Provider readiness 的生产 consumer。
    /// 只存储无密钥事实，供聊天模型选择器的 Core projection 消费。
    let providerReadinessStore: ProviderReadinessStore
    /// P3-ISO：mandatory Canvas/Chat isolation projection.
    /// The descriptor is backed by the existing MinisCore boundary contract
    /// and is intentionally not persisted or writable.
    var canvasChatIsolationPolicy: CanvasChatIsolationPolicyDescriptor {
        .current
    }
    /// The production composition root binds this callback so a policy change
    /// takes effect without requiring an application restart.
    @ObservationIgnored
    var onApprovalPolicyChanged: ((ApprovalPolicy) -> Void)?
    /// P3-TERM-01：终端规则变更只影响后续请求；消费方保存 immutable snapshot。
    @ObservationIgnored
    var onTerminalPolicyChanged: ((TerminalPolicySnapshot) -> Void)?
    /// L2：Composer 默认策略变更回调。消费方只更新后续请求的选择；
    /// 已创建的回合继续使用自己的 immutable snapshot。
    @ObservationIgnored
    var onComposerPolicyChanged: ((ComposerPolicySettings) -> Void)?
    /// A committed user ceiling rebuilds only subsequent production turns.
    @ObservationIgnored
    var onPolicyRuntimeDefaultsChanged: ((ProductionPolicyDefaults) -> Void)?
    /// A durable Settings edit refreshes ChatStore's value for future turns.
    /// The App binds this to restorePersona, which does not write back here.
    @ObservationIgnored
    var onPersonaSettingsChanged: ((Persona, Bool) -> Void)?
    /// F1-01：供应商改名成功后，把会话里按旧名保存的服务商选择改到新名字。
    /// App 装配到 ChatStore；这里只传名字，不传任何凭据。
    @ObservationIgnored
    var onProviderRenamed: ((_ oldName: String, _ newName: String) -> Void)?
    /// F1-09：查询仍选用某个供应商的会话标题，供删除确认框如实列出影响。
    @ObservationIgnored
    var providerDependentSessionTitles: ((_ providerName: String) -> [String])?
    /// 只转发已提交的 canonical 输出模式，供当前 ChatStore 下回合读取。
    @ObservationIgnored
    var onChatOutputModeSettingsChanged: ((ChatOutputMode) -> Void)?
    /// P3-CHILD-40: runtime composition callback for the canonical selection.
    /// The callback carries a value snapshot and never becomes a second store.
    @ObservationIgnored
    var onChildConcurrencySelectionChanged: ((ChildConcurrencySelection) -> Void)?
    /// Publish only a successfully committed file-access snapshot to the
    /// production composition root; existing turns keep their captured engine.
    @ObservationIgnored
    var onFileAccessSettingsChanged: (() -> Void)?
    /// The asynchronous re-attach started by the latest committed file-access
    /// change. Callers that act on the new roots right away (the project folder
    /// auto-mount retry) await it; otherwise they would still see the old roots.
    @ObservationIgnored
    var pendingFileAccessAttachment: Task<Void, Never>?
    /// BL6 resolves opaque credential handles only at the secure composition
    /// boundary; neither ChatStore nor a model receives credential bytes.
    @ObservationIgnored
    var bl6CredentialResolver: ((BL6CredentialHandle) -> String?)?
    /// Provider/settings cross-store failures are fail-closed and sticky until
    /// an explicit reconciliation rebuilds this SettingsCenter.
    @ObservationIgnored
    private(set) var bl6SettingsTransactionState: BL6SettingsTransactionState = .ready
    @ObservationIgnored var conversationHookStore: HookConfigStore?

    /// F14 P1-3：数据备份导入/导出（sessions+memories+skills+settings 四域）。
    /// 在 init 尾部赋值（@Observable 宏不支持 lazy var）。
    let syncManager: SyncManager
    @ObservationIgnored private let backupShortcutStore: ShortcutStore?

    // E22 根因修复：@Observable 只追踪「存储属性」。
    // 旧实现里 appearance/accentTheme/defaultProviderID 等是计算属性，
    // get 直接读 settingsStore.settings（非追踪点）→ Picker 选值后 store
    // 已写入但视图不刷新，表现为「选不生效、像没有确认按钮」。
    // 现在所有设置类计算属性 get 读 `settingsMirror`（被 @Observable 追踪，
    // 视图 body 建立依赖），set 先更新镜像（自动通知视图立即刷新）再写
    // store（持久化）——「选即生效」：主题色 .tint / 外观明暗 / 默认模型
    // 全部即时变化。
    var settingsMirror: AppSettings
    /// Secret-free persistence status for the settings UI. A successful
    /// transaction clears the previous error; a failed transaction leaves the
    /// effective mirror/runtime unchanged and exposes only the typed failure.
    private(set) var lastPersistenceError: SettingsPersistenceError? = nil

    /// Stable settings/provider identity consumed by the Settings surface.
    /// This is derived from the canonical mirror and metadata snapshot, so a
    /// reload cannot replace a provider row with a position-based identity.
    var settingsAppliedStateProjection: SettingsAppliedStateProjection {
        let revision = (try? stableFingerprint(settingsMirror)) ?? "unavailable"
        let providers = providerRecords
            .filter(\.isProviderRecord)
            .map { SettingsStateClassification.providerProjectionIdentity(for: $0) }
            .sorted { $0.providerID < $1.providerID }
        let descriptors = SettingsStateClassification.descriptors(
            for: .canonicalSetting
        )
        let live = descriptors.compactMap { descriptor -> String? in
            guard SettingsStateClassification.applyState(for: descriptor) == .liveApplied else {
                return nil
            }
            return descriptor.settingsKey ?? descriptor.owner
        }.sorted()
        let restart = descriptors.compactMap { descriptor -> String? in
            guard SettingsStateClassification.applyState(for: descriptor) == .restartRequired else {
                return nil
            }
            return descriptor.settingsKey ?? descriptor.owner
        }.sorted()
        return SettingsAppliedStateProjection(
            settingsRevision: revision,
            providers: providers,
            liveAppliedSettingKeys: live,
            restartRequiredSettingKeys: restart
        )
    }

    /// Most recent provider-save failure, mapped from MinisCore's typed,
    /// secret-free persistence error for the provider edit sheet.
    private(set) var providerSaveFailure: ProviderSaveFailureCategory?

    /// Keep the provider failure projection behind the SettingsCenter owner.
    /// Callers may submit only the already-typed, secret-free category; the
    /// stored diagnostic never becomes a generally writable property.
    func projectProviderSaveFailure(_ failure: ProviderSaveFailureCategory) {
        providerSaveFailure = failure
    }

    /// Risk acknowledgement is intentionally session-scoped. It never rewrites
    /// the persisted user selection and resets when that selection changes.
    private var childConcurrencyRiskAcknowledgedValue = false
    /// P3-SAFE-01：唯一由 SettingsCenter 持有的 Safe Mode / Kill Switch 状态。
    /// Payload 复用现有 SettingsStore.providerSettings，避免第二 Store。
    private(set) var safetyControlState: SafetyControlState
    /// Production composition binds this callback to BridgeStore's runtime
    /// admission boundary. The callback carries the same immutable snapshot
    /// exposed to the settings UI.
    @ObservationIgnored
    var onSafetyRuntimeSnapshotChanged: ((SafetyRuntimeSnapshot) -> Void)?

    // UI 快照（每次 reload 后刷新）
    private(set) var envEntries: [EnvVarEntry] = []
    /// U5：模型供应商记录快照（envvars.json 中携带 baseURL/模型名元数据的条目）。
    private(set) var providerRecords: [EnvVarEntry] = []
    /// Runtime provider health projection. This is copied from ChatStore at
    /// the composition boundary and contains only ready/degraded state, never
    /// credentials or raw initialization errors.
    private(set) var providerLaunchSnapshot: ProviderLaunchSnapshot = .empty
    /// UX06：设置页 Provider readiness consumer 的最近报告（按供应商记录 ID 索引）。
    private(set) var providerReadinessReports: [String: SettingsProviderReadinessReport] = [:]
    private var providerReadinessLocalControlMessages: [String: String] = [:]
    func providerReadinessLocalControlMessage(for provider: EnvVarEntry) -> String? {
        providerReadinessLocalControlMessages[provider.id]
    }
    /// IF-07B：已保存模型逐项 readiness 状态（供应商记录 ID + 模型 ID 隔离）。
    private(set) var providerModelReadinessStates: [String: [String: ProviderModelReadiness]] = [:]
    private(set) var isCheckingProviderReadiness = false
    /// Provider-local loading identity; sibling rows must not enter checking
    /// merely because another provider is being rechecked.
    private(set) var providerReadinessCheckingProviderID: String?
    /// Publication identity only; never grants readiness or credential access.
    private var providerReadinessProbeGenerations: [String: UUID] = [:]
    private var savedProviderReadinessTasks: [String: (id: UUID, task: Task<SettingsProviderReadinessReport?, Never>)] = [:]
    /// IF-07A：Provider 表单 draft 目录发现状态，不写入 EnvVarStore。
    private(set) var providerDraftProbeState: ProviderDraftProbeState = .idle
    private(set) var logEntries: [LogEntry] = []
    private(set) var sessions: [MinisCore.ChatSession] = []
    private(set) var memoryFacts: [MemoryFact] = []
    /// I2-MEMORY-PROJECTION companion: `memoryFacts` carries the active-only
    /// projection; this keeps the full persisted count (active + superseded
    /// history) from the same single read, so export messaging matches the
    /// exported file instead of the visible list.
    private(set) var memoryFactTotalCount: Int = 0
    /// FC-22：最近一次读取记忆失败（文件读不出来）。列表保留上一次读到的内容，
    /// 页面据此提示，不把"读失败"显示成"暂无记忆"。
    private(set) var memoryFactsLoadFailed: Bool = false
    /// AJ-47：文件式记忆文档快照（GLOBAL.md / SOUL.md / 每日日志）。
    private(set) var memoryFiles: [MemoryFileInfo] = []
    /// E6: MCP 服务器列表快照（MCPManagerView 数据源）。
    private(set) var mcpServers: [MCPServer] = []
    /// Discovered tools are a UI projection only; authorization remains
    /// persisted by MCPServerManager and is checked again by MCPToolBridge.
    private(set) var mcpToolsByServer: [String: [MCPTool]] = [:]
    /// Discovery completions are accepted only while this per-server
    /// generation remains current. Lifecycle and authorization changes bump
    /// the generation before their state can race an in-flight tools/list.
    private var mcpDiscoveryGenerations: [String: Int] = [:]

    /// Consume the immutable runtime provider-health projection. Settings is
    /// a read-only consumer; it never reconstructs providers or probes the
    /// Keychain while rendering the first window.
    func updateProviderLaunchSnapshot(_ snapshot: ProviderLaunchSnapshot) {
        providerLaunchSnapshot = snapshot
    }

    /// Read-only lookup used by the provider settings surface to show a
    /// recovery action for one degraded provider without changing healthy
    /// providers' readiness.
    func providerLaunchStatus(for providerID: String) -> ProviderLaunchStatus? {
        providerLaunchSnapshot.status(for: providerID)
    }

    /// Resolve the exact settings destination for one degraded provider.
    /// Healthy providers and records absent from the settings snapshot do not
    /// receive a recovery affordance, preserving provider-local health state.
    func providerRecoveryDestination(for providerID: String) -> ProviderRecoveryDestination? {
        ProviderRecoveryNavigation.destination(
            providerID: providerID,
            status: providerLaunchStatus(for: providerID),
            availableProviderIDs: providerRecords.map(\.name)
        )
    }
    /// 最近一次「从进程导入」命中的变量数（用于 UI 提示）。
    var lastImportCount = 0

    init(
        settingsStore: SettingsStore? = nil,
        envStore: EnvVarStore? = nil,
        memoryStore: MemoryStore? = nil,
        memoryFileStore: MemoryFileStore? = nil,
        sessionStore: SessionStore? = nil,
        sessionBadgeStore: SessionBadgeStore? = nil,
        logManager: LogManager? = nil,
        mcpManager: MCPServerManager? = nil,
        skillStore: SkillStore? = nil,
        usageStore: UsageStore? = nil,
        shortcutStore: ShortcutStore? = nil,
        providerReadinessTransport: (any SettingsProviderReadinessTransport)? = nil,
        providerReadinessSession: URLSession? = nil,
        providerReadinessDeployment: ProviderDeployment = .remote,
        providerReadinessStore: ProviderReadinessStore? = nil
    ) {
        // Resolve once before constructing an omitted default. Fully explicit
        // composition, including the App's blocked bootstrap profile, uses
        // only its injected stores and can still render the safe blocker.
        let needsDefaultProfile = settingsStore == nil || envStore == nil
            || memoryStore == nil || sessionStore == nil || logManager == nil
            || mcpManager == nil || skillStore == nil || usageStore == nil
        let profile = needsDefaultProfile
            ? RuntimeIsolationProfile.defaultConstructionProfile() : nil
        let defaultKeychain = profile?.mode == .isolatedTest
            ? profile?.makeKeychainStore() : nil
        let settingsStore = settingsStore
            ?? SettingsStore(directory: profile!.settingsDirectory)
        let envStore = envStore ?? {
            if let defaultKeychain {
                return EnvVarStore(
                    directory: profile!.providerConfigurationDirectory,
                    keychain: defaultKeychain
                )
            }
            return EnvVarStore(directory: profile!.providerConfigurationDirectory)
        }()
        let memoryStore = memoryStore
            ?? MemoryStore(directory: profile!.memoryDirectory)
        let sessionStore = sessionStore
            ?? SessionStore(directory: profile!.sessionDirectory)
        let logManager = logManager ?? profile!.makeLogManager()
        // Register only values already held by this store. Deferred Keychain
        // references remain unresolved until an existing authorized read.
        envStore.attachLogRedaction(to: logManager)
        let mcpManager = mcpManager ?? {
            if let defaultKeychain {
                return MCPServerManager(
                    fileURL: profile!.mcpConfigurationURL,
                    keychain: defaultKeychain
                )
            }
            return MCPServerManager(fileURL: profile!.mcpConfigurationURL)
        }()
        let skillStore = skillStore ?? SkillStore(
            skillsRoot: profile!.minisCoreDirectory.appendingPathComponent(
                "skills", isDirectory: true
            )
        )
        let usageStore = usageStore
            ?? UsageStore(domain: profile!.usageStoreDefaultsDomain)
        self.settingsStore = settingsStore
        self.envStore = envStore
        self.backupShortcutStore = shortcutStore
        self.memoryStore = memoryStore
        let sharedMemoryProposalConsumer = MemoryProposalConsumer(store: memoryStore)
        self.memoryProposalConsumer = sharedMemoryProposalConsumer
        // AJ-47：文件式记忆与事实记忆共享同一项目目录（各自独立子目录），
        // 未显式注入时复用 memoryStore 的 directory。
        self.memoryFileStore = memoryFileStore ?? MemoryFileStore(directory: memoryStore.directory)
        self.sessionStore = sessionStore
        let sessionManager = SessionManager(
            store: sessionStore, badgeStore: sessionBadgeStore ?? .shared
        )
        self.sessionDeletionService = SessionDeletionService(manager: sessionManager)
        self.logManager = logManager
        self.mcpManager = mcpManager
        self.skillStore = skillStore
        self.usageStore = usageStore
        self.bl6SettingsSnapshotGuard = BL6SettingsSnapshotGuard()
        self.providerReadinessStore = providerReadinessStore
            ?? ProviderReadinessStore(directory: memoryStore.directory)
        self.providerReadinessTransport = providerReadinessTransport
            ?? URLSessionProviderReadinessTransport(
                session: providerReadinessSession ?? .shared,
                canProduceLiveEvidence: providerReadinessSession == nil
            )
        self.providerReadinessDeployment = providerReadinessDeployment
        // F14 P1-3：备份导入/导出接线（四个 store 均已赋值）。
        self.syncManager = SyncManager(
            sessionStore: sessionStore,
            memoryStore: memoryStore,
            skillStore: skillStore,
            settingsStore: settingsStore,
            memoryProposalConsumer: sharedMemoryProposalConsumer,
            providerConfigurationDirectory: shortcutStore == nil ? nil : envStore.metadataDirectory,
            shortcutRecoveryTarget: shortcutStore.flatMap { try? $0.recoveryTarget() }
        )
        do {
            _ = try memoryProposalConsumer.recoverApprovedProposals()
        } catch {
            logManager.error(
                "记忆 proposal 恢复失败，已保持 fail-closed：\(error)",
                category: "Memory"
            )
        }
        // 启动时把持久化的隐私日志级别对齐到 LogManager（live 级别以 LogManager 为准）。
        logManager.minimumLevel = LogLevel(settingsStore.settings.privacy.logLevel)
        // E22: 镜像初始值 = 持久化值（此后由各 setter 维护与 store 同步）。
        let initialSettings = settingsStore.settings
        settingsMirror = initialSettings
        ModelShellEnvironment.configure(stripCredentials: initialSettings.agent.stripModelShellCredentials,
                                        noninteractive: initialSettings.agent.modelShellNoninteractive)
        bl6SettingsTransactionState = Self.loadBL6SettingsTransactionState(
            from: settingsStore.directory
        )
        if settingsStore.lastPersistenceError == .transactionRecoveryRequired {
            bl6SettingsTransactionState = .unknown
        }
        safetyControlState = Self.loadSafetyControlState(from: settingsStore.settings)
        Self.active = self
        reloadAll()
    }

    /// Provision all built-in producers at the app composition boundary.
    /// Each source is inserted only when absent; a revoked record survives
    /// relaunch and is never silently converted back into a grant.
    @discardableResult
    func provisionBuiltInMemoryCandidateSubmissions()
        throws -> [MemoryCandidateSubmissionAuthorization] {
        try BuiltInMemoryCandidateSource.allCases.map { source in
            try memoryProposalConsumer.provisionCandidateSubmissionIfAbsent(
                sourceID: source.sourceID,
                reason: "Built-in user-initiated memory producer default"
            )
        }
    }

    /// Compatibility entry for Settings-only fixtures. Production uses the
    /// full built-in list above; this method never grants unrelated sources.
    @discardableResult
    func provisionMemoryCandidateSubmission()
        throws -> MemoryCandidateSubmissionAuthorization {
        try memoryProposalConsumer.provisionCandidateSubmissionIfAbsent(
            sourceID: Self.memoryCandidateSubmissionSourceID,
            reason: "SettingsCenter user-initiated memory producer default"
        )
    }

    /// The Settings memory tab exposes explicit revocation and re-enablement
    /// for built-in sources. Unknown external identities cannot be granted here.
    func memoryCandidateSubmissionEnabled(
        for source: BuiltInMemoryCandidateSource
    ) throws -> Bool {
        try memoryProposalConsumer.candidateSubmissionAuthorizations()
            .first(where: { $0.sourceID == source.sourceID })?.canSubmit ?? false
    }

    @discardableResult
    func setMemoryCandidateSubmission(
        for source: BuiltInMemoryCandidateSource,
        enabled: Bool
    ) throws -> MemoryCandidateSubmissionAuthorization {
        if enabled {
            return try memoryProposalConsumer.grantCandidateSubmission(
                sourceID: source.sourceID,
                reason: "User enabled built-in memory candidate source"
            )
        }
        return try memoryProposalConsumer.revokeCandidateSubmission(
            sourceID: source.sourceID,
            reason: "User disabled built-in memory candidate source"
        )
    }

    /// User action for one currently persisted, explicitly configured
    /// scheduled task. Its task UUID is the stable candidate-source identity;
    /// scheduler execution authorization alone never grants memory writes.
    func scheduledMemoryCandidateSubmissionEnabled(
        taskID: UUID,
        in schedulerStore: SchedulerTaskStore
    ) throws -> Bool {
        let sourceID = try scheduledMemorySourceID(taskID: taskID, in: schedulerStore)
        return try memoryProposalConsumer.candidateSubmissionAuthorizations()
            .first(where: { $0.sourceID == sourceID })?.canSubmit ?? false
    }

    @discardableResult
    func setScheduledMemoryCandidateSubmission(
        taskID: UUID,
        in schedulerStore: SchedulerTaskStore,
        enabled: Bool
    ) throws -> MemoryCandidateSubmissionAuthorization {
        let sourceID = try scheduledMemorySourceID(taskID: taskID, in: schedulerStore)
        if enabled {
            return try memoryProposalConsumer.grantCandidateSubmission(
                sourceID: sourceID,
                reason: "User enabled this scheduled task to submit memory candidates"
            )
        }
        return try memoryProposalConsumer.revokeCandidateSubmission(
            sourceID: sourceID,
            reason: "User disabled this scheduled task's memory candidates"
        )
    }

    private func scheduledMemorySourceID(
        taskID: UUID,
        in schedulerStore: SchedulerTaskStore
    ) throws -> String {
        guard schedulerStore.persistenceError == nil,
              let task = schedulerStore.task(id: taskID), !task.isDeleted,
              ScheduledMemoryCandidateSource.proposalText(command: task.command) != nil else {
            throw MemoryProposalConsumerError.invalidSourceID
        }
        return ScheduledMemoryCandidateSource.sourceID(taskID: task.id)
    }

    static let bl6SettingsTransactionMarkerFileName = ".bl6-settings-transaction-unknown"
    private static let bl6SettingsTransactionMarker = Data("unknown\n".utf8)

    private static func loadBL6SettingsTransactionState(
        from directory: URL
    ) -> BL6SettingsTransactionState {
        let domain = PersistenceTransactionFence.Domain.settings(directory)
        let admission = PersistenceTransactionFence.read([domain])
        defer { admission.release() }
        let markerURL = directory.appendingPathComponent(
            bl6SettingsTransactionMarkerFileName,
            isDirectory: false
        )
        guard PersistenceTransactionFence.exists(at: markerURL, domain: domain) else {
            return .ready
        }
        // Presence, including malformed or unreadable contents, is unknown.
        // Only a complete explicit reconciliation may clear this fence.
        return .unknown
    }

    /// Persist the sticky transaction fence without relying on settings.json
    /// being writable. The marker is secret-free and contains no identifiers.
    func markBL6SettingsTransactionUnknown() {
        let admission = PersistenceTransactionFence.read([settingsStore.persistenceDomain])
        defer { admission.release() }
        guard (try? admission.requireWritable()) != nil else { return }
        bl6SettingsTransactionState = .unknown
        let markerURL = settingsStore.directory.appendingPathComponent(
            Self.bl6SettingsTransactionMarkerFileName,
            isDirectory: false
        )
        do {
            try FileManager.default.createDirectory(
                at: settingsStore.directory,
                withIntermediateDirectories: true
            )
            try Self.bl6SettingsTransactionMarker.write(to: markerURL, options: .atomic)
        } catch {
            logManager.error(
                "设置事务未知状态无法持久化，已保持 fail-closed",
                category: "Settings"
            )
        }
    }

    /// 当前持久化设置（实时读 store；`settingsMirror` 是追踪视图用的同步副本）。
    var settings: AppSettings { settingsStore.settings }

    /// Commit one settings-store transaction before publishing any observable
    /// mirror or runtime callback. SettingsStore already writes a candidate
    /// atomically; this wrapper keeps SettingsCenter's mirror and callbacks
    /// on the same success boundary. Callers must not mutate `settingsMirror`
    /// before invoking this helper.
    @discardableResult
    func persistSettings(
        _ operation: () -> SettingsUpdateResult,
        onSuccess: (() -> Void)? = nil
    ) -> Bool {
        let previousMirror = settingsMirror
        switch operation() {
        case .success:
            settingsMirror = settingsStore.settings
            lastPersistenceError = nil
            onSuccess?()
            return true
        case .failure(let error):
            settingsMirror = previousMirror
            lastPersistenceError = error
            return false
        }
    }

    /// The single effective browser value consumed by BrowserTabView.
    /// This is a projection of the observable mirror, not a second store.
    var effectiveBrowserSettings: BrowserSettings {
        settingsMirror.browser
    }

    /// Typed state metadata for settings, runtime projections and caches.
    /// Descriptors do not own or persist any value.
    var persistentStateDescriptors: [PersistentStateDescriptor] {
        SettingsStateClassification.descriptors
    }

    /// Build the visible-terminal policy from the same effective safety owner
    /// and the current immutable command-policy snapshot.
    /// The capability id is fail-closed when browser/terminal side effects are
    /// disabled; TerminalBoundary then refuses to reach a process runner.
    func terminalPolicy(
        scopeID: String,
        workdir: String,
        snapshot: TerminalPolicySnapshot? = nil
    ) -> TerminalPolicy {
        TerminalPolicy(
            scopeID: scopeID,
            allowedRoot: URL(fileURLWithPath: workdir, isDirectory: true),
            additionalAllowedRoots: effectiveMountedFolders,
            deniedRoots: runtimeDeniedRoots,
            snapshot: snapshot ?? terminalPolicySnapshot
        )
    }

    /// Canonical persisted terminal-rule value. The Core snapshot is derived
    /// from this mirror and never becomes a second persistence store.
    var terminalPolicySettings: TerminalPolicySettings {
        get { settingsMirror.agent.terminalPolicy }
        set {
            let normalized = newValue.normalized()
            guard settingsMirror.agent.terminalPolicy != normalized else { return }
            _ = persistSettings(
                { settingsStore.update(\.agent.terminalPolicy, to: normalized) },
                onSuccess: { self.onTerminalPolicyChanged?(self.terminalPolicySnapshot) }
            )
        }
    }

    /// Immutable command-policy facts for one new request boundary.
    var terminalPolicySnapshot: TerminalPolicySnapshot {
        TerminalPolicySnapshot(settings: settingsMirror.agent.terminalPolicy)
    }

    /// Reset only the terminal-rule domain. Other settings, credentials and
    /// session data remain untouched.
    func resetTerminalPolicyToDefaults() {
        guard persistSettings({ settingsStore.update(\.agent.terminalPolicy, to: .default) }) else {
            return
        }
        onTerminalPolicyChanged?(terminalPolicySnapshot)
    }

    /// 当前设置文件所在目录（关于页展示）。
    var settingsDirectory: URL { settingsStore.directory }

    /// Secret-free classification for a provider credential read.  The raw
    /// credential exists only in the success payload and is never included in
    /// failure text, accessibility values, or diagnostics.
    enum ProviderCredentialReadFailure: Equatable, Sendable {
        case missing
        case denied
        case failed

        var message: String {
            switch self {
            case .missing:
                return "无法从钥匙串读取当前 API Key：未找到；请直接输入新 Key 替换。"
            case .denied:
                return "无法从钥匙串读取当前 API Key：访问被拒绝；请检查钥匙串权限，或直接输入新 Key 替换。"
            case .failed:
                return "无法从钥匙串读取当前 API Key：读取失败；请重试，或直接输入新 Key 替换。"
            }
        }
    }

    enum ProviderCredentialReadOutcome: Equatable, Sendable {
        case success(String)
        case failure(ProviderCredentialReadFailure)
    }

    /// Read a provider credential through the injected EnvVarStore. This keeps
    /// Settings UI on the same profile-scoped Keychain namespace used by the
    /// provider configuration instead of constructing a default KeychainStore
    /// at the view layer, while preserving the Keychain failure category.
    func providerCredentialRead(named name: String) -> ProviderCredentialReadOutcome {
        switch envStore.readEnvVarResult(name: name) {
        case .success(let value):
            guard let value, !value.isEmpty else {
                return .failure(.missing)
            }
            return .success(value)
        case .failure(let error):
            switch error {
            case .keychainReadMissing:
                return .failure(.missing)
            case .keychainReadDenied:
                return .failure(.denied)
            case .keychainReadFailed:
                return .failure(.failed)
            default:
                return .failure(.failed)
            }
        }
    }

    /// Async credential read for UI and other main-actor callers. The
    /// Keychain operation stays behind EnvVarStore's async boundary, so the
    /// typed missing/denied/failed outcome survives without synchronously
    /// entering Security.framework on the main thread.
    func providerCredentialReadAsync(named name: String) async -> ProviderCredentialReadOutcome {
        switch await envStore.readEnvVarResultAsync(name: name) {
        case .success(let value):
            guard let value, !value.isEmpty else {
                return .failure(.missing)
            }
            return .success(value)
        case .failure(let error):
            switch error {
            case .keychainReadMissing:
                return .failure(.missing)
            case .keychainReadDenied:
                return .failure(.denied)
            case .keychainReadFailed:
                return .failure(.failed)
            default:
                return .failure(.failed)
            }
        }
    }

    /// Compatibility shim for existing non-UI callers.  Callers that need a
    /// user-visible reason should use `providerCredentialRead(named:)`.
    func providerCredential(named name: String) -> String? {
        guard case .success(let value) = providerCredentialRead(named: name) else {
            return nil
        }
        return value
    }

    /// Async counterpart for callers that need the actual Keychain-backed
    /// credential while remaining on the safe async boundary.
    func providerCredentialAsync(named name: String) async -> String? {
        guard case .success(let value) = await providerCredentialReadAsync(named: name) else {
            return nil
        }
        return value
    }

    // MARK: - P3-SAFE-01 Safe Mode / offline Kill Switch

    var safetyRuntimeSnapshot: SafetyRuntimeSnapshot {
        safetyControlState
    }

    var safeModeEnabled: Bool {
        get { safetyControlState.safeModeEnabled }
        set { setSafeMode(newValue) }
    }

    var killSwitchEnabled: Bool {
        get { safetyControlState.killSwitchEnabled }
        set { setKillSwitch(newValue) }
    }

    /// Read-only capability manifest for settings and diagnostics consumers.
    var safetyFeatureFlags: [SafetyFeatureFlag] {
        safetyControlState.featureFlags
    }

    /// Forced safety rows are visible but cannot be toggled independently.
    var forcedSafetyFeatureFlags: [SafetyFeatureFlag] {
        safetyFeatureFlags.filter(\.isForced)
    }

    var optionalModulesDisabled: Bool {
        safetyControlState.allOptionalModulesDisabled
    }

    var chatBackupRecoveryRemainEnabled: Bool {
        safetyControlState.coreFeaturesRemainEnabled
    }

    func isSafetyFeatureEnabled(_ feature: SafetyControlFeature) -> Bool {
        safetyControlState.isEnabled(feature)
    }

    func setSafeMode(_ enabled: Bool) {
        updateSafetyControlState { $0.safeModeEnabled = enabled }
    }

    func setKillSwitch(_ enabled: Bool) {
        // This is intentionally local and synchronous: it remains usable when
        // every network-backed or optional module is unavailable.
        updateSafetyControlState { $0.killSwitchEnabled = enabled }
    }

    func enableSafeMode() { setSafeMode(true) }

    func disableSafeMode() { setSafeMode(false) }

    func engageKillSwitch() { setKillSwitch(true) }

    func disengageKillSwitch() { setKillSwitch(false) }

    func restoreSafetyControlDefaults() {
        guard safetyControlState != .defaults else { return }
        persistSafetyControlState(.defaults)
    }

    private func updateSafetyControlState(
        _ transform: (inout SafetyControlState) -> Void
    ) {
        var next = safetyControlState
        transform(&next)
        // A failed emergency write may already be effective for this session.
        // The same user selection must still retry the missing canonical save.
        guard next != safetyControlState
                || next != Self.loadSafetyControlState(from: settingsStore.settings) else { return }
        persistSafetyControlState(next)
    }

    private func persistSafetyControlState(_ next: SafetyControlState) {
        guard let data = try? JSONEncoder().encode(next),
              let payload = String(data: data, encoding: .utf8) else {
            lastPersistenceError = .encodingFailed
            return
        }
        var providerSettings = settingsStore.settings.providerSettings
        providerSettings[SafetyControlState.settingsKey] = [
            SafetyControlState.payloadKey: payload
        ]
        // Tightening protection is an emergency session effect: it must work
        // even when persistence is unavailable. Relaxation must wait for the
        // durable settings commit, otherwise the live session could run with
        // fewer safeguards than the canonical state restored on relaunch.
        let tightensProtection =
            (next.safeModeEnabled && !safetyControlState.safeModeEnabled)
            || (next.killSwitchEnabled && !safetyControlState.killSwitchEnabled)
        if tightensProtection {
            safetyControlState = next
            onSafetyRuntimeSnapshotChanged?(next)
        }
        _ = persistSettings(
            { settingsStore.update(\.providerSettings, to: providerSettings) },
            onSuccess: {
                if !tightensProtection && self.safetyControlState != next {
                    self.safetyControlState = next
                    self.onSafetyRuntimeSnapshotChanged?(next)
                }
            }
        )
    }

    private static func loadSafetyControlState(from settings: AppSettings) -> SafetyControlState {
        guard let payload = settings.providerSettings[SafetyControlState.settingsKey]?[SafetyControlState.payloadKey] else {
            return .defaults
        }
        guard let data = payload.data(using: .utf8) else {
            return .failClosedDefaults
        }
        return (try? JSONDecoder().decode(SafetyControlState.self, from: data))
            ?? .failClosedDefaults
    }

    /// WP-2：只投影 readiness 事实，不把 Settings 的表单状态直接伪装成聊天模型。
    var chatModelPickerProjection: ChatModelPickerProjection {
        ChatModelPickerProjection(records: providerReadinessStore.records)
    }

    // MARK: - Typography（UX-01）

    /// 全局 UI 基准字号（12...20 pt，步长 1）。
    var uiBaseFontSize: Int {
        get { settingsMirror.typography.uiBaseFontSize }
        set {
            let normalized = TypographySettings(uiBaseFontSize: newValue).uiBaseFontSize
            // Publish the observable mirror only after the atomic store write
            // succeeds; a read-only/corrupt profile must not show an unsaved
            // font size to the settings UI.
            _ = persistSettings {
                settingsStore.update(\.typography.uiBaseFontSize, to: normalized)
            }
        }
    }

    /// 排版设置快照，供 token provider 或设置页按组消费。
    var typography: TypographySettings {
        get { settingsMirror.typography }
        set {
            let normalized = TypographySettings(uiBaseFontSize: newValue.uiBaseFontSize)
            _ = persistSettings {
                settingsStore.update(\.typography, to: normalized)
            }
        }
    }

    /// 仅恢复排版设置默认值，不影响其他用户设置。
    func resetTypographyToDefaults() {
        typography = .default
    }

    // MARK: - 常规（General）

    /// SETTINGS-27/THEME-01：收敛后的唯一外观真值。
    ///
    /// 写入预设会同步重投影两个旧字段（`general.appearance` /
    /// `general.accentTheme`），所以设置页只有这一个入口时，
    /// 「外观模式 × 主题色」的 18 种任意组合既不可达也不可存。
    var themePreset: ThemePreset {
        get { settingsMirror.general.themePreset }
        set {
            // 预设与它的两个投影字段必须原子落盘：走一次 update 事务，
            // 避免重启时读到「新预设 + 旧组合」的半写状态。
            persistSettings({ settingsStore.update(\.general) { general in
                general.setThemePreset(newValue)
            } })
        }
    }

    /// 明暗选择（浅色 / 深色 / 跟随系统），独立于配色预设；产品主题配色不变，
    /// 只决定用浅色版还是深色版。
    var appearance: Appearance {
        get { settingsMirror.general.appearance }
        set {
            persistSettings { settingsStore.update(\.general.appearance, to: newValue) }
        }
    }

    /// 旧「主题色」字段的兼容读投影。调色板已收敛为 AJ-38 定版伪仙，
    /// 写入不再改变生效 token（预设才是真值），仅保留键位与编译兼容。
    var accentTheme: AccentTheme {
        get { settingsMirror.general.accentTheme }
        set {
            // 主题色轴不再决定任何东西：保持当前预设（产品主题自第 1 套配色起也投影为 system 外观，
            // 若再用 appearance 反推预设会把产品主题误改成「跟随系统」）。
            _ = newValue
            themePreset = themePreset
        }
    }

    var defaultProviderID: String? {
        get { settingsMirror.general.defaultProviderID }
        set {
            persistSettings { settingsStore.update(\.general.defaultProviderID, to: newValue) }
        }
    }

    var defaultModelID: String? {
        get { settingsMirror.general.defaultModelID }
        set {
            persistSettings { settingsStore.update(\.general.defaultModelID, to: newValue) }
        }
    }

    /// AJ-40：辅助模型（Sub Model）——轻量任务（标题生成/摘要等）的默认模型。
    var subModelID: String? {
        get { settingsMirror.general.subModelID }
        set {
            persistSettings { settingsStore.update(\.general.subModelID, to: newValue) }
        }
    }

    /// E19 模型速度档位（极快/快/均衡/质量），默认 .balanced。
    var modelSpeedTier: ModelSpeedTier {
        get { settingsMirror.general.modelSpeedTier }
        set {
            persistSettings { settingsStore.update(\.general.modelSpeedTier, to: newValue) }
        }
    }

    /// AJ-52 对话输出模式（详细/正常/极简），默认 .normal。
    var chatOutputMode: ChatOutputMode {
        get { settingsMirror.general.chatOutputMode }
        set {
            persistSettings(
                { settingsStore.update(\.general.chatOutputMode, to: newValue) },
                onSuccess: { self.onChatOutputModeSettingsChanged?(self.chatOutputMode) }
            )
        }
    }

    /// 生产装配和聚焦测试共用这一条双向链；回写失败即返回旧值。
    /// restoreOutputMode 仅更新运行投影，不反写持久化设置。
    func bindChatOutputMode(to chat: ChatStore) {
        chat.restoreOutputMode(chatOutputMode)
        onChatOutputModeSettingsChanged = { [weak chat] committed in
            chat?.restoreOutputMode(committed)
        }
        chat.onOutputModeChanged = { [weak self, weak chat] requested in
            guard let self else { return chat?.outputMode ?? .normal }
            self.chatOutputMode = requested
            return self.chatOutputMode
        }
    }

    var language: String {
        get { settingsMirror.general.language }
        set {
            persistSettings { settingsStore.update(\.general.language, to: newValue) }
        }
    }

    /// Effective native speech locale derived from the existing language
    /// setting. Invalid or missing values return nil (fail closed).
    var effectiveSpeechLocale: Locale? {
        // P3-SPEECH-01 wiring: the previous `try?` silently discarded the
        // resolver error, so an *unsupported* language was indistinguishable
        // from a genuine nil and could not be presented through the capability
        // boundary's `.speechLocaleUnresolved` reason. Resolve explicitly and
        // fail closed to nil only for a missing/unsupported language, never
        // falling back to a different locale.
        do {
            return try SpeechLocaleResolver.runtimeLocale(for: language)
        } catch is SpeechLocaleError {
            return nil
        } catch {
            return nil
        }
    }

    /// ProviderFactory 注册表中的可用 Provider 类型。
    var providers: [ProviderType] { ProviderFactory.shared.registeredTypes }

    /// 指定 provider 的内置模型列表（未选择则空）。
    func models(forProviderID providerID: String?) -> [LLMModel] {
        guard let providerID, let type = ProviderType(rawValue: providerID) else { return [] }
        return type.builtInModels
    }

    /// 语言选项（简体中文 / 英文 / 日文）。
    static let languageOptions: [(code: String, display: String)] = [
        ("zh-Hans", "简体中文"),
        ("en", "English"),
        ("ja", "日本語"),
    ]

    // MARK: - Agent

    var maxLoopIterations: Int {
        get { settingsMirror.agent.maxLoopIterations }
        set {
            persistSettings {
                settingsStore.update(\.agent) {
                    $0.maxLoopIterations = min(100, max(1, newValue))
                    $0.maxLoopIterationsNoticeAcknowledged = true
                }
            }
        }
    }

    var maxLoopIterationsNoticePending: Bool {
        !settingsMirror.agent.maxLoopIterationsNoticeAcknowledged
    }

    func acknowledgeLoopLimitNotice(useNewDefault: Bool) {
        persistSettings {
            settingsStore.update(\.agent) {
                if useNewDefault { $0.maxLoopIterations = 50 }
                $0.maxLoopIterationsNoticeAcknowledged = true
            }
        }
    }

    var maxTokensPerSession: Int {
        get { settingsMirror.agent.maxTokensPerSession }
        set { persistSettings { settingsStore.update(\.agent.maxTokensPerSession, to: max(1, newValue)) } }
    }

    var tokenBudgetUnlimited: Bool {
        get { settingsMirror.agent.tokenBudgetUnlimited }
        set { persistSettings { settingsStore.update(\.agent.tokenBudgetUnlimited, to: newValue) } }
    }

    var toolTimeoutSeconds: Int {
        get { settingsMirror.agent.toolTimeoutSeconds }
        set {
            persistSettings { settingsStore.update(\.agent.toolTimeoutSeconds, to: newValue) }
        }
    }

    var stripModelShellCredentials: Bool {
        get { settingsMirror.agent.stripModelShellCredentials }
        set {
            persistSettings({ settingsStore.update(\.agent.stripModelShellCredentials, to: newValue) },
                onSuccess: { self.configureModelShellEnvironment() })
        }
    }

    var modelShellNoninteractive: Bool {
        get { settingsMirror.agent.modelShellNoninteractive }
        set {
            persistSettings({ settingsStore.update(\.agent.modelShellNoninteractive, to: newValue) },
                onSuccess: { self.configureModelShellEnvironment() })
        }
    }

    /// 审批卡的呈现方式与超时自动拒绝：重启后保持（审批卡上的开关改动经这里落盘）。
    @discardableResult
    func setApprovalPresentation(inline: Bool, timeoutSeconds: Double) -> Bool {
        let seconds = timeoutSeconds.isFinite ? min(3600, max(0, timeoutSeconds)) : 0
        // 两项设置合成一次写盘，不会出现只落盘一半。
        return persistSettings({
            settingsStore.update(\.agent) {
                $0.approvalInlineEnabled = inline
                $0.approvalTimeoutSeconds = seconds
            }
        })
    }

    var approvalInlineEnabledSetting: Bool { settingsMirror.agent.approvalInlineEnabled }
    var approvalTimeoutSecondsSetting: Double { settingsMirror.agent.approvalTimeoutSeconds }

    private func configureModelShellEnvironment() {
        ModelShellEnvironment.configure(stripCredentials: settingsMirror.agent.stripModelShellCredentials,
                                        noninteractive: settingsMirror.agent.modelShellNoninteractive)
    }

    var shellCommandTimeoutSeconds: Int {
        get { settingsMirror.agent.shellCommandTimeoutSeconds }
        set {
            let seconds = Int(ShellCommandTimeoutPolicy.seconds(newValue))
            persistSettings { settingsStore.update(\.agent.shellCommandTimeoutSeconds, to: seconds) }
        }
    }

    var concurrentToolLimit: Int {
        get { settingsMirror.agent.concurrentToolLimit }
        set {
            persistSettings { settingsStore.update(\.agent.concurrentToolLimit, to: newValue) }
        }
    }

    // MARK: - Child concurrency (P3-CHILD-40)

    /// Advisory recommendation. It is deliberately separate from the
    /// persisted user choice and never silently rewrites that choice.
    var childConcurrencyRecommended: Int {
        ChildConcurrencySelection.default.recommended
    }

    var childConcurrencyHardLimit: Int {
        ChildConcurrencySelection.hardMaximum
    }

    /// Persisted user choice, validated to the independent hard ceiling.
    var childConcurrencyUserSelected: Int {
        get { settingsMirror.agent.childConcurrencyUserSelected }
        set {
            guard (1...childConcurrencyHardLimit).contains(newValue) else { return }
            _ = persistSettings(
                { settingsStore.update(\.agent.childConcurrencyUserSelected, to: newValue) },
                onSuccess: {
                    self.publishChildConcurrencySelectionAfterCommit()
                }
            )
        }
    }

    /// P3-CHILD-40 / D-CHILDA · 166-B（用户裁决「B：设置里显式选 N」）：
    /// 用户显式选择的「启用并行会话数」，与每会话 1–40 同级、同硬上限
    /// （1...40），共用同一风险确认闸语义（改动清 ack、ack 只在需要确认时
    /// 可置真）。默认 1 恒等旧行为（旧推导件不传该参数、落 ChildConcurrencySelection
    /// 默认 1）。这是全局预算 enabled_session_count 的唯一用户侧取数源；模型/外部
    /// 自报值仍被 rejection 合同拒动（零改动）。
    var childConcurrencyEnabledSessionCount: Int {
        get { settingsMirror.agent.childConcurrencyEnabledSessionCount }
        set {
            guard (1...childConcurrencyHardLimit).contains(newValue) else { return }
            _ = persistSettings(
                { settingsStore.update(\.agent.childConcurrencyEnabledSessionCount, to: newValue) },
                onSuccess: {
                    self.publishChildConcurrencySelectionAfterCommit()
                }
            )
        }
    }

    /// Explicit acknowledgement is required only when a persisted user choice
    /// exceeds its advisory side: per-session selection above the recommendation
    /// (P3-CHILD-40) or, since 166-B, an enabled-session count above the
    /// neutral 1x default.
    var childConcurrencyRiskAcknowledged: Bool {
        get { childConcurrencyRiskAcknowledgedValue }
        set {
            childConcurrencyRiskAcknowledgedValue =
                (childConcurrencyUserSelected > childConcurrencyRecommended
                    || childConcurrencyEnabledSessionCount > 1) && newValue
            onChildConcurrencySelectionChanged?(childConcurrencySelection)
        }
    }

    /// Publish the same risk-acknowledgement reset and runtime projection after
    /// either the UI setter or an atomic typed-settings commit has persisted.
    /// The typed path must not call a setter after its replay/CAS commit: that
    /// would write settings a second time and change the receipt revision.
    func publishChildConcurrencySelectionAfterCommit() {
        childConcurrencyRiskAcknowledgedValue = false
        onChildConcurrencySelectionChanged?(childConcurrencySelection)
    }

    /// Canonical projection consumed by production orchestration.
    /// Without acknowledgement, effective runtime remains conservative while
    /// the persisted user selection remains untouched. The
    /// `enabledSessionCount` argument carries the 166-B user-side value; with
    /// the persisted default of 1 the projection is byte-identical to the
    /// pre-166-B behaviour (no argument → ChildConcurrencySelection default 1).
    var childConcurrencySelection: ChildConcurrencySelection {
        let selected = childConcurrencyUserSelected
        let effective = childConcurrencyRiskAcknowledged
            ? selected
            : min(selected, childConcurrencyRecommended)
        return try! ChildConcurrencySelection(
            userSelected: selected,
            recommended: childConcurrencyRecommended,
            effective: effective,
            enabledSessionCount: childConcurrencyEnabledSessionCount
        )
    }

    var childConcurrencyEffective: Int {
        childConcurrencySelection.effective
    }

    func resetChildConcurrencyToDefaults() {
        _ = persistSettings(
            { settingsStore.update(\.agent) { agent in
                agent.childConcurrencyUserSelected = ChildConcurrencySelection.default.userSelected
                agent.childConcurrencyEnabledSessionCount = 1
            } },
            onSuccess: {
                self.childConcurrencyRiskAcknowledgedValue = false
                self.onChildConcurrencySelectionChanged?(self.childConcurrencySelection)
            }
        )
    }

    var autoCompactThreshold: Double {
        get { settingsMirror.agent.autoCompactThreshold }
        set {
            persistSettings { settingsStore.update(\.agent.autoCompactThreshold, to: newValue) }
        }
    }

    /// 0 = model metadata 自动值。仅允许非负输入；本轮实际模型上限由
    /// ContextTurnSettingsSnapshot 再次校验，防止会话切换后沿用过大值。
    var contextLengthTokens: Int {
        get { settingsMirror.agent.contextLengthTokens ?? 0 }
        set { _ = setContextLengthTokens(newValue) }
    }

    @discardableResult
    func setContextLengthTokens(_ value: Int) -> Bool {
        guard value >= 0 else { return false }
        let candidate: Int? = value == 0 ? nil : value
        guard settingsMirror.agent.contextLengthTokens != candidate else { return true }
        return persistSettings {
            settingsStore.update(\.agent.contextLengthTokens, to: candidate)
        }
    }

    /// 0 = 全部历史轮次；正值包含当前用户轮次。
    var historyTurnLimit: Int {
        get { settingsMirror.agent.historyTurnLimit ?? 0 }
        set { _ = setHistoryTurnLimit(newValue) }
    }

    @discardableResult
    func setHistoryTurnLimit(_ value: Int) -> Bool {
        guard value >= 0 else { return false }
        let candidate: Int? = value == 0 ? nil : value
        guard settingsMirror.agent.historyTurnLimit != candidate else { return true }
        return persistSettings {
            settingsStore.update(\.agent.historyTurnLimit, to: candidate)
        }
    }

    /// Informational bound for the configured default model. An explicitly
    /// selected conversation model can differ; turn admission checks that model.
    var defaultModelContextWindowTokens: Int? {
        models(forProviderID: defaultProviderID)
            .first(where: { $0.id == defaultModelID })?.contextWindowTokens
    }

    var fallbackEnabled: Bool {
        get { settingsMirror.agent.fallbackEnabled }
        set {
            persistSettings { settingsStore.update(\.agent.fallbackEnabled, to: newValue) }
        }
    }

    /// User-only checkpoint entry. Model settings tools have no mutation key
    /// for this control. Reuse the current file-access runtime rebind boundary.
    var fileCheckpointsEnabled: Bool {
        get { settingsMirror.agent.fileCheckpointsEnabled }
        set {
            persistSettings({ settingsStore.update(\.agent.fileCheckpointsEnabled, to: newValue) },
                onSuccess: { self.onFileAccessSettingsChanged?() })
        }
    }

    /// 后台任务完成后自动续跑。只给用户界面用，模型设置工具没有对应的修改键；立即对之后的判断生效。
    var backgroundAutoContinueEnabled: Bool {
        get { settingsMirror.agent.backgroundAutoContinueEnabled }
        set { persistSettings { settingsStore.update(\.agent.backgroundAutoContinueEnabled, to: newValue) } }
    }

    /// Native user preference only; not registered with the model settings tool.
    var browserWriteEnabled: Bool {
        get { settingsMirror.agent.browserWriteEnabled }
        set { persistSettings { settingsStore.update(\.agent.browserWriteEnabled, to: newValue) } }
    }

    var childMutationsEnabled: Bool {
        get { settingsMirror.agent.childMutationsEnabled }
        set {
            persistSettings {
                settingsStore.update(\.agent) {
                    $0.childMutationsEnabled = newValue
                    $0.childMutationsExplicitlySelected = true
                }
            }
        }
    }

    var childModelOverridesEnabled: Bool {
        get { settingsMirror.agent.childModelOverridesEnabled }
        set {
            persistSettings { settingsStore.update(\.agent.childModelOverridesEnabled, to: newValue) }
        }
    }

    var childModelThinkingLevelCeiling: ThinkingLevel? {
        get { settingsMirror.agent.childModelThinkingLevelCeiling }
        set {
            persistSettings { settingsStore.update(\.agent.childModelThinkingLevelCeiling, to: newValue) }
        }
    }

    /// Goal18 CHILD-DELETE-AUTO · user-only. Not in `BL6SettingsCatalog`, so the
    /// model settings tool can neither read-modify nor write it (its candidate is
    /// a copy of the mirror and only catalog keys are applied: the current value
    /// is kept). A commit reuses the file-access runtime rebind so the next
    /// production attachment (new turns / new child tasks) gets the new
    /// `ChildDeletionReviewConfiguration`; child tasks already running keep the
    /// reviewer they were built with.
    var childDeletionAutoReviewEnabled: Bool {
        get { settingsMirror.agent.childDeletionAutoReviewEnabled }
        set {
            persistSettings({ settingsStore.update(\.agent.childDeletionAutoReviewEnabled, to: newValue) },
                onSuccess: { self.onFileAccessSettingsChanged?() })
        }
    }

    /// Canonical real directories, read-only here; mutate through
    /// `addChildDeletionAutoReviewDirectory` / `removeChildDeletionAutoReviewDirectory`.
    var childDeletionAutoReviewWhitelist: [String] {
        settingsMirror.agent.childDeletionAutoReviewWhitelist
    }

    /// Per-entry state for the settings list: a stored entry that is no longer
    /// usable (missing / replaced by a symlink / too broad) is shown as 已失效
    /// and is ignored when the reviewer configuration is derived.
    func childDeletionAutoReviewEntryStatus(_ path: String) -> ChildDeletionReviewSettings.EntryStatus {
        ChildDeletionReviewSettings.entryStatus(path)
    }

    enum ChildDeletionWhitelistAddResult: Equatable {
        case added(String)
        case alreadyPresent(String)
        case notADirectory
        case tooBroad(String)
        case limitReached
        case persistenceFailed
    }

    /// Stores the symlink-resolved real path of an existing directory. Files,
    /// missing paths, the filesystem root, the home directory and its ancestors,
    /// system roots and MinisCanvas' own data directories are refused.
    @discardableResult
    func addChildDeletionAutoReviewDirectory(_ url: URL) -> ChildDeletionWhitelistAddResult {
        let canonical: String
        switch ChildDeletionReviewSettings.checkedDirectory(url) {
        case .notADirectory: return .notADirectory
        case .tooBroad(let reason): return .tooBroad(reason)
        case .accepted(let path): canonical = path
        }
        let current = settingsMirror.agent.childDeletionAutoReviewWhitelist
        if current.contains(canonical) { return .alreadyPresent(canonical) }
        guard current.count < ChildDeletionReviewSettings.maxWhitelistDirectories else { return .limitReached }
        let committed = persistSettings({
            settingsStore.update(\.agent.childDeletionAutoReviewWhitelist, to: current + [canonical])
        }, onSuccess: { self.onFileAccessSettingsChanged?() })
        return committed ? .added(canonical) : .persistenceFailed
    }

    @discardableResult
    func removeChildDeletionAutoReviewDirectory(_ path: String) -> Bool {
        let current = settingsMirror.agent.childDeletionAutoReviewWhitelist
        guard current.contains(path) else { return false }
        return persistSettings({
            settingsStore.update(\.agent.childDeletionAutoReviewWhitelist, to: current.filter { $0 != path })
        }, onSuccess: { self.onFileAccessSettingsChanged?() })
    }

    /// AJ-47：默认启用记忆（新会话默认加载 GLOBAL.md 与每日记忆；单会话可覆盖）。
    var memoryEnabled: Bool {
        get { settingsMirror.agent.memoryEnabled }
        set {
            persistSettings { settingsStore.update(\.agent.memoryEnabled, to: newValue) }
        }
    }

    var globalInstructionsEnabled: Bool {
        get { settingsMirror.agent.globalInstructionsEnabled }
        set { persistSettings { settingsStore.update(\.agent.globalInstructionsEnabled, to: newValue) } }
    }

    /// Persisted fallback policy for tools whose approval is not set by the current mode.
    var approvalPolicy: ApprovalPolicy {
        get { settingsMirror.agent.approvalPolicy }
        set { confirmApprovalPolicy(newValue) }
    }

    func confirmApprovalPolicy(_ policy: ApprovalPolicy) {
        persistSettings(
            {
                settingsStore.update(\.agent) {
                    $0.approvalPolicy = policy
                    $0.legacyAutomaticApprovalCompatibilityActive = false
                }
            },
            onSuccess: { self.onApprovalPolicyChanged?(policy) }
        )
    }

    /// 11/16：停用所有工具前的审批策略，恢复时还原。持久化在 `AgentSettings.approvalPolicyBeforeToolsDisabled`，
    /// 与策略同一次写入，重启后仍可还原；没有记录（例如策略本来就是 deny）时回落到每次询问。
    var toolsDisabled: Bool {
        get { approvalPolicy == .deny || approvalPolicy == .never }
        set {
            guard newValue != toolsDisabled else { return }
            let policy: ApprovalPolicy
            if newValue {
                policy = .deny
            } else {
                policy = settingsMirror.agent.approvalPolicyBeforeToolsDisabled ?? .alwaysAsk
            }
            persistSettings(
                {
                    settingsStore.update(\.agent) {
                        if newValue { $0.approvalPolicyBeforeToolsDisabled = $0.approvalPolicy }
                        else { $0.approvalPolicyBeforeToolsDisabled = nil }
                        $0.approvalPolicy = policy
                        $0.legacyAutomaticApprovalCompatibilityActive = false
                    }
                },
                onSuccess: { self.onApprovalPolicyChanged?(policy) }
            )
        }
    }

    var legacyAutomaticApprovalCompatibilityActive: Bool {
        settingsMirror.agent.legacyAutomaticApprovalCompatibilityActive
    }

    func disableLegacyAutomaticApprovalCompatibility() {
        guard legacyAutomaticApprovalCompatibilityActive else { return }
        persistSettings(
            { settingsStore.update(\.agent.legacyAutomaticApprovalCompatibilityActive, to: false) },
            onSuccess: { self.onApprovalPolicyChanged?(self.approvalPolicy) }
        )
    }

    var legacyApprovalPolicyNoticePending: Bool { settingsMirror.agent.legacyApprovalPolicyNoticePending }
    var legacyApprovalScopeNoticePending: Bool { settingsMirror.agent.legacyApprovalScopeNoticePending }

    func acknowledgeLegacyApprovalNotices() {
        persistSettings {
            settingsStore.update(\.agent) {
                $0.legacyApprovalPolicyNoticePending = false
                $0.legacyApprovalScopeNoticePending = false
            }
        }
    }

    /// AJ-40：智能体可用模型白名单（模型 ID 列表；空 = 全部可用）。
    var availableModelWhitelist: [String] {
        get { settingsMirror.agent.availableModelWhitelist }
        set {
            persistSettings { settingsStore.update(\.agent.availableModelWhitelist, to: newValue) }
        }
    }

    /// R8：对话执行阶段新输入打断当前生成（新输入最高优先级；默认开启）。
    var newMessageInterruptsGeneration: Bool {
        get { settingsMirror.agent.newMessageInterruptsGeneration }
        set {
            persistSettings { settingsStore.update(\.agent.newMessageInterruptsGeneration, to: newValue) }
        }
    }

    /// L2：新 Composer 请求的默认策略（mode/scope/effort/bypass）。
    var composerPolicy: ComposerPolicySettings {
        get { settingsMirror.agent.composerPolicy }
        set {
            guard settingsMirror.agent.composerPolicy != newValue else { return }
            persistSettings(
                { settingsStore.update(\.agent.composerPolicy, to: newValue) },
                onSuccess: { self.onComposerPolicyChanged?(newValue) }
            )
        }
    }

    /// PolicyRuntime user ceiling, backed by the existing AgentSettings store.
    /// The conversation settings tool remains denied by its separate catalog.
    var policyRuntimeDefaults: ProductionPolicyDefaults {
        settingsMirror.agent.policyRuntimeDefaults
    }

    /// Read provenance from the live configuration authority, never from the
    /// Goal's merged domains or an arbitrary injected defaults value.
    func networkDomainConfigurationSnapshot(
        expectedDefaults: ProductionPolicyDefaults
    ) -> NetworkDomainConfigurationProvenance {
        guard bl6SettingsTransactionState == .ready,
              settingsStore.lastPersistenceError != .transactionRecoveryRequired,
              settingsMirror.agent.policyRuntimeDefaults == expectedDefaults,
              settingsStore.settings.agent.policyRuntimeDefaults == expectedDefaults,
              expectedDefaults.isValidUserConfiguration else { return .unknown }
        return .actualLocalSettingsConfiguredCeiling(
            domains: settingsStore.settings.agent.policyRuntimeDefaults.networkDomains)
    }

    @discardableResult
    func updatePolicyRuntimeDefaults(_ value: ProductionPolicyDefaults) -> Bool {
        guard bl6SettingsTransactionState == .ready,
              settingsStore.lastPersistenceError != .transactionRecoveryRequired,
              value.isValidUserConfiguration else { return false }
        guard value != settingsMirror.agent.policyRuntimeDefaults else { return true }
        return persistSettings(
            { settingsStore.update(\.agent.policyRuntimeDefaults, to: value) },
            onSuccess: { self.onPolicyRuntimeDefaultsChanged?(value) }
        )
    }

    // MARK: - 人格（Persona，波4）

    /// 是否启用人格（注入 systemPrompt 前缀）。
    var personaEnabled: Bool {
        get { settingsMirror.agent.personaEnabled }
        set {
            persistSettings(
                { settingsStore.update(\.agent.personaEnabled, to: newValue) },
                onSuccess: { self.publishPersonaSettings() }
            )
        }
    }

    /// 当前选中的预设（UI 切换；不自动改写 persona 内容，除非经 applyPersonaPreset）。
    var personaPreset: PersonaPreset {
        get { settingsMirror.agent.personaPreset }
        set {
            persistSettings { settingsStore.update(\.agent.personaPreset, to: newValue) }
        }
    }

    /// 人格内容（名称/简介/语气/能力），可编辑字段直接改。
    var persona: Persona {
        get { settingsMirror.agent.persona }
        set {
            persistSettings(
                { settingsStore.update(\.agent.persona, to: newValue) },
                onSuccess: { self.publishPersonaSettings() }
            )
        }
    }

    /// 一键切换预设：更新 personaPreset 并把 persona 内容填充为该预设默认值。
    func applyPersonaPreset(_ preset: PersonaPreset) {
        persistSettings(
            { settingsStore.update(\.agent) { agent in
                agent.personaPreset = preset
                agent.persona = preset.defaultPersona
            } },
            onSuccess: { self.publishPersonaSettings() }
        )
    }

    private func publishPersonaSettings() {
        onPersonaSettingsChanged?(
            settingsMirror.agent.persona,
            settingsMirror.agent.personaEnabled
        )
    }

    // MARK: - 隐私（Privacy）

    var redactEnvValues: Bool {
        get { settingsMirror.privacy.redactEnvValues }
        set {
            persistSettings { settingsStore.update(\.privacy.redactEnvValues, to: newValue) }
        }
    }

    /// 隐私页的日志级别：写回 AppSettings 并同步到 LogManager。
    var privacyLogLevel: SettingsLogLevel {
        get { settingsMirror.privacy.logLevel }
        set {
            persistSettings(
                { settingsStore.update(\.privacy.logLevel, to: newValue) },
                onSuccess: { self.logManager.minimumLevel = LogLevel(newValue) }
            )
        }
    }

    var collectAnalytics: Bool {
        get { settingsMirror.privacy.collectAnalytics }
        set {
            persistSettings { settingsStore.update(\.privacy.collectAnalytics, to: newValue) }
        }
    }

    // MARK: - AJ-28 文件访问权限（联动 ToolExecutor.allowedRoot / deniedRoots）

    /// Publish the next runtime policy only after one durable settings write.
    @discardableResult
    private func persistFileAccessSettings(_ operation: () -> SettingsUpdateResult) -> Bool {
        persistSettings(operation, onSuccess: { self.onFileAccessSettingsChanged?() })
    }

    /// 持久化的 Agent 授权根目录路径；nil = 默认（用户主目录）。
    var fileAccessAllowedRoot: String? {
        get { settingsMirror.privacy.allowedRootPath }
        set {
            _ = persistFileAccessSettings {
                settingsStore.update(\.privacy.allowedRootPath, to: newValue)
            }
        }
    }

    /// 持久化的额外被拒绝目录路径列表（空 = 使用默认拒绝目录）。
    var fileAccessDeniedRoots: [String] {
        get { settingsMirror.privacy.deniedRootPaths }
        set {
            _ = persistFileAccessSettings {
                settingsStore.update(\.privacy.deniedRootPaths, to: newValue)
            }
        }
    }

    /// 授权根的界面说明；实际路径由会话项目提供。
    var effectiveAllowedRoot: String {
        fileAccessAllowedRoot ?? "当前会话项目目录"
    }

    /// 当前生效的被拒绝目录路径列表（未显式设置时回落到默认拒绝目录，即 Application Support）。
    var effectiveDeniedRoots: [String] {
        if !fileAccessDeniedRoots.isEmpty {
            return fileAccessDeniedRoots
        }
        return BuiltinToolExecutor.defaultDeniedRoots().map(\.path)
    }

    /// The runtime must retain product-denied roots when a user adds more.
    /// Keep effectiveDeniedRoots as the existing editable Settings UI list.
    var runtimeDeniedRoots: [String] {
        var roots = BuiltinToolExecutor.defaultDeniedRoots().map(\.path)
        for path in fileAccessDeniedRoots where !roots.contains(path) {
            roots.append(path)
        }
        return roots
    }

    /// 设置授权根目录（nil 恢复默认）。返回路径是否有效（非空绝对路径）。
    @discardableResult
    func setFileAccessAllowedRoot(_ path: String?) -> Bool {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return persistFileAccessSettings {
                settingsStore.update(\.privacy.allowedRootPath, to: nil)
            }
        }
        guard trimmed.hasPrefix("/") else { return false }
        return persistFileAccessSettings {
            settingsStore.update(\.privacy.allowedRootPath, to: trimmed)
        }
    }

    /// 添加一条被拒绝目录（去重）。返回是否成功（非空绝对路径）。
    @discardableResult
    func addFileAccessDeniedRoot(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), !trimmed.isEmpty else { return false }
        var roots = fileAccessDeniedRoots
        guard !roots.contains(trimmed) else { return true }
        roots.append(trimmed)
        return persistFileAccessSettings {
            settingsStore.update(\.privacy.deniedRootPaths, to: roots)
        }
    }

    /// 移除一条被拒绝目录。
    func removeFileAccessDeniedRoot(_ path: String) {
        let roots = fileAccessDeniedRoots
        guard roots.contains(path) else { return }
        _ = persistFileAccessSettings {
            settingsStore.update(\.privacy.deniedRootPaths, to: roots.filter { $0 != path })
        }
    }

    /// 重置文件访问权限为默认（授权根回到主目录，清空额外拒绝目录）。
    func resetFileAccessRoots() {
        _ = persistFileAccessSettings {
            settingsStore.update(\.privacy) { privacy in
                privacy.allowedRootPath = nil
                privacy.deniedRootPaths = []
            }
        }
    }

    // MARK: - AJ-45 挂载外部文件夹（联动 ToolExecutor.additionalAllowedRoots）

    /// 持久化的挂载外部文件夹路径列表（Agent 可访问的额外目录白名单）。
    var mountedFolderPaths: [String] {
        get { settingsMirror.privacy.mountedFolderPaths }
        set {
            _ = persistFileAccessSettings {
                settingsStore.update(\.privacy.mountedFolderPaths, to: newValue)
            }
        }
    }

    /// 允许 external_session_* 直接读取本机 Codex / Claude Code 会话目录（无需挂载）。
    var allowLocalAgentSessionRead: Bool {
        get { settingsMirror.privacy.allowLocalAgentSessionRead }
        set {
            _ = persistFileAccessSettings {
                settingsStore.update(\.privacy.allowLocalAgentSessionRead, to: newValue)
            }
        }
    }

    /// 当前生效的挂载目录列表（去重、去首尾空白）。
    var effectiveMountedFolders: [String] {
        mountedFolderPaths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// 是否还能继续挂载（上限 `PrivacySettings.maxMountedFolders`）。
    var canMountMoreFolders: Bool {
        effectiveMountedFolders.count < PrivacySettings.maxMountedFolders
    }

    /// 挂载一个外部文件夹（加入白名单）。返回是否成功：
    /// 失败原因 = 非绝对路径 / 已达上限 / 已挂载过。
    @discardableResult
    func mountFolder(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), !trimmed.isEmpty else { return false }
        var folders = effectiveMountedFolders
        guard !folders.contains(trimmed) else { return false }
        guard folders.count < PrivacySettings.maxMountedFolders else { return false }
        folders.append(trimmed)
        return persistFileAccessSettings {
            settingsStore.update(\.privacy.mountedFolderPaths, to: folders)
        }
    }

    /// 取消挂载一个外部文件夹（从白名单移除）。
    func unmountFolder(_ path: String) {
        let folders = effectiveMountedFolders
        guard folders.contains(path) else { return }
        _ = persistFileAccessSettings {
            settingsStore.update(\.privacy.mountedFolderPaths, to: folders.filter { $0 != path })
        }
    }

    // MARK: - 存储（Storage）

    var sessionRetentionDays: Int {
        get { settingsMirror.storage.sessionRetentionDays }
        set {
            persistSettings { settingsStore.update(\.storage.sessionRetentionDays, to: newValue) }
        }
    }

    var memoryLimitMB: Int? {
        get { settingsMirror.storage.memoryLimitMB }
        set {
            persistSettings { settingsStore.update(\.storage.memoryLimitMB, to: newValue) }
        }
    }

    var autoDeleteOldSessions: Bool {
        get { settingsMirror.storage.autoDeleteOldSessions }
        set {
            persistSettings { settingsStore.update(\.storage.autoDeleteOldSessions, to: newValue) }
        }
    }

    // MARK: - 浏览器（Browser, AJ-49）

    /// Commit one normalized browser value before publishing the observable mirror.
    /// This keeps all six browser controls on the same durable boundary.
    private func updateBrowserSettings(
        _ transform: (inout BrowserSettings) -> Void
    ) {
        var candidate = settingsMirror.browser
        transform(&candidate)
        let normalized = BrowserSettings(
            userAgentPreset: candidate.userAgentPreset,
            customUserAgent: candidate.customUserAgent,
            viewportMode: candidate.viewportMode,
            customViewportWidth: candidate.customViewportWidth,
            customViewportHeight: candidate.customViewportHeight,
            idleTabTimeoutMinutes: candidate.idleTabTimeoutMinutes
        )
        guard normalized != settingsMirror.browser else { return }
        persistSettings { settingsStore.update(\.browser, to: normalized) }
    }

    /// 用户代理预设（移动 Chrome / 桌面 Chrome / 自定义），默认桌面 Chrome。
    var userAgentPreset: UserAgentPreset {
        get { settingsMirror.browser.userAgentPreset }
        set {
            updateBrowserSettings { $0.userAgentPreset = newValue }
        }
    }

    /// 自定义 UA 字符串（`userAgentPreset == .custom` 时生效）。
    var customUserAgent: String {
        get { settingsMirror.browser.customUserAgent }
        set {
            updateBrowserSettings { $0.customUserAgent = newValue }
        }
    }

    /// Viewport 模式（默认按 UA 自动 / 自定义宽×高）。
    var browserViewportMode: BrowserViewportMode {
        get { settingsMirror.browser.viewportMode }
        set {
            updateBrowserSettings { $0.viewportMode = newValue }
        }
    }

    /// 自定义视口宽度（px）。
    var customViewportWidth: Int {
        get { settingsMirror.browser.customViewportWidth }
        set {
            updateBrowserSettings { $0.customViewportWidth = newValue }
        }
    }

    /// 自定义视口高度（px）。
    var customViewportHeight: Int {
        get { settingsMirror.browser.customViewportHeight }
        set {
            updateBrowserSettings { $0.customViewportHeight = newValue }
        }
    }

    /// 空闲标签页超时（分钟，1~240），默认 15。
    var idleTabTimeoutMinutes: Int {
        get { settingsMirror.browser.idleTabTimeoutMinutes }
        set {
            updateBrowserSettings { $0.idleTabTimeoutMinutes = newValue }
        }
    }

    // MARK: - 存储操作（调 MemoryStore / SessionStore 清理）

    /// Legacy entry points are intentionally fail-closed. The caller must keep
    /// the exact preview and supply both user confirmations to the overload.
    func previewSessionDeletion(id: String) throws -> OperationIntent {
        if let reason = sessionDeletionBlocker?(id) { throw SessionDeletionError.deleteFailed(reason) }
        return try sessionDeletionService.preview(sessionID: id)
    }

    @discardableResult
    func deleteSession(id: String) -> OperationIntent? {
        try? previewSessionDeletion(id: id)
    }

    @discardableResult
    func deleteSession(id: String, intent: OperationIntent) throws -> DeletionReceipt {
        if let reason = sessionDeletionBlocker?(intent.targetID) { throw SessionDeletionError.deleteFailed(reason) }
        let receipt = try sessionDeletionService.delete(intent)
        reloadStorage()
        onConfirmedSessionDeletion?([receipt.targetID])
        return receipt
    }

    /// O-04: a session whose parent turn still has a running background child
    /// is never part of a batch. Preview and execution both use this filtered
    /// snapshot, so a session that gains a background child after the preview
    /// changes the batch fingerprint and the stale confirmation is refused.
    private func sessionBatchSnapshot(
        _ kind: SettingsSessionBatchKind,
        now: Date = Date()
    ) throws -> [MinisCore.ChatSession] {
        try sessionBatchCandidates(kind, now: now).filter { sessionDeletionBlocker?($0.id) == nil }
    }

    private func sessionBatchBlockedCount(
        _ kind: SettingsSessionBatchKind,
        now: Date
    ) throws -> Int {
        try sessionBatchCandidates(kind, now: now).filter { sessionDeletionBlocker?($0.id) != nil }.count
    }

    private func sessionBatchCandidates(
        _ kind: SettingsSessionBatchKind,
        now: Date = Date()
    ) throws -> [MinisCore.ChatSession] {
        switch kind {
        case .retention:
            let days = sessionRetentionDays
            guard days >= 1 else {
                throw SessionManagerError.invalidRetention(days)
            }
            // Imported settings bypass the numeric field's UI bounds. Reject
            // an unusable window before reading targets; never select all as
            // a fallback. Keep the existing 24-hour-day retention policy.
            let cutoff = now.addingTimeInterval(-TimeInterval(days) * 86_400)
            guard cutoff.timeIntervalSinceReferenceDate.isFinite,
                  cutoff >= Date.distantPast else {
                throw SessionManagerError.unresolvableRetentionWindow(days: days)
            }
            return sessionStore.listSessions().filter { $0.updatedAt < cutoff }
        case .all:
            return sessionStore.listSessions()
        }
    }

    private func sessionBatchRevision(_ sessions: [MinisCore.ChatSession]) -> Int {
        sessions.count
    }

    private func sessionBatchFingerprint(_ sessions: [MinisCore.ChatSession]) throws -> String {
        // Bind the confirmed batch to the complete persisted session, including
        // transcript, attachments and state. Display metadata can stay unchanged
        // during an upsert; it cannot authorize deletion of a replacement payload.
        // The existing sorted-key encoder throws before any deletion on failure.
        return try stableFingerprint(sessions.sorted { $0.id < $1.id })
    }

    private func previewSessionBatch(
        kind: SettingsSessionBatchKind,
        now: Date,
        ttl: TimeInterval
    ) throws -> OperationIntent {
        let sessions = try sessionBatchSnapshot(kind, now: now)
        let blocked = try sessionBatchBlockedCount(kind, now: now)
        return DeletionGate.preview(
            targetID: kind.targetID,
            targetType: "session.batch",
            targetName: kind.targetName,
            affectedCount: sessions.count,
            impactSummary: blocked == 0
                ? "将会话移入回收站，可逐项恢复"
                : "将会话移入回收站，可逐项恢复。另有 \(blocked) 个会话因还有后台运行的子任务而被排除，请先在任务中心停止它们。",
            reversible: true,
            scopeID: "sessions:\(kind.targetID)",
            revision: sessionBatchRevision(sessions),
            fingerprint: try sessionBatchFingerprint(sessions),
            now: now,
            ttl: ttl
        )
    }

    /// Keep every selected child's canonical parent available until that child
    /// has been moved. Among currently deletable sessions, retain the original
    /// batch order. This also makes rollback's reversed receipts parent-first.
    private func sessionBatchDeletionOrder(
        _ sessions: [MinisCore.ChatSession]
    ) throws -> [MinisCore.ChatSession] {
        var remaining = Set<String>()
        var childCounts: [String: Int] = [:]
        for session in sessions {
            guard remaining.insert(session.id).inserted else {
                throw SessionManagerError.duplicateSessionIdentity(session.id)
            }
            childCounts[session.id] = 0
            // Reuse the Store's full lineage validation before any move. Missing
            // ancestors and cycles must not become a partial destructive batch.
            guard sessionStore.loadSession(id: session.id) != nil else {
                throw SessionStoreError.invalidSessionLineage(session.id)
            }
        }
        // A retention batch must not make a non-selected live or archived
        // descendant unloadable. Refuse the original selection, never expand it.
        let storedSessions = sessionStore.listSessions()
            + sessionDeletionService.manager.archivedSessions()
        for dependent in storedSessions where !remaining.contains(dependent.id) {
            if let parentID = dependent.parentSessionID, remaining.contains(parentID) {
                throw SettingsDeletionError.operationFailed("未选中的子会话仍依赖本批会话")
            }
        }
        for session in sessions {
            if let parentID = session.parentSessionID {
                if remaining.contains(parentID) {
                    childCounts[parentID, default: 0] += 1
                } else if sessionStore.loadSession(id: parentID) == nil {
                    throw SessionStoreError.invalidSessionLineage(session.id)
                }
            }
        }
        var ordered: [MinisCore.ChatSession] = []
        ordered.reserveCapacity(sessions.count)
        while !remaining.isEmpty {
            guard let next = sessions.first(where: {
                remaining.contains($0.id) && childCounts[$0.id] == 0
            }) else {
                throw SessionStoreError.sessionLineageCycle(remaining.sorted().first!)
            }
            ordered.append(next)
            remaining.remove(next.id)
            if let parentID = next.parentSessionID, remaining.contains(parentID) {
                childCounts[parentID, default: 0] -= 1
            }
        }
        return ordered
    }

    private func executeSessionBatch(
        kind: SettingsSessionBatchKind,
        intent: OperationIntent,
        now: Date
    ) throws -> DeletionReceipt {
        let sessions = try sessionBatchSnapshot(kind, now: now)
        guard intent.targetID == kind.targetID,
              intent.targetType == "session.batch",
              intent.scopeID == "sessions:\(kind.targetID)" else {
            throw DeletionGateError.targetChanged
        }

        var childReceipts: [DeletionReceipt] = []
        do {
            let receipt = try DeletionGate.execute(
                intent,
                currentRevision: sessionBatchRevision(sessions),
                currentFingerprint: try sessionBatchFingerprint(sessions),
                now: now
            ) { confirmed in
                do {
                    let deletionOrder = try sessionBatchDeletionOrder(sessions)
                    for session in deletionOrder {
                        // Last-moment guard: a background child may have started
                        // after the snapshot. Refuse (earlier moves are rolled back).
                        if let reason = sessionDeletionBlocker?(session.id) {
                            throw SessionDeletionError.deleteFailed(reason)
                        }
                        let childIntent = try sessionDeletionService.preview(sessionID: session.id)
                            .withFirstConfirmation("已核对本次会话批次预览")
                            .withSecondConfirmation("确认将本批会话移入回收站")
                        childReceipts.append(try sessionDeletionService.delete(childIntent))
                    }
                    if !childReceipts.isEmpty {
                        let recovery = SettingsSessionBatchRecoveryReceipt(
                            aggregate: DeletionGate.receipt(for: confirmed, now: now),
                            childReceipts: childReceipts)
                        let encoded = try JSONEncoder().encode(recovery)
                        try PersistenceTransactionFence.withWrite([sessionStore.persistenceDomain]) {
                            let url = sessionBatchRecoveryURL(operationID: confirmed.operationID)
                            let values = try url.deletingLastPathComponent().resourceValues(
                                forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                            guard values.isDirectory == true, values.isSymbolicLink != true,
                                  !FileManager.default.fileExists(atPath: url.path) else {
                                throw SessionDeletionError.restoreFailed("恢复回执目录或目标无效")
                            }
                            try encoded.write(to: url, options: .atomic)
                        }
                    }
                } catch {
                    var rollbackError: Error?
                    for childReceipt in childReceipts.reversed() {
                        do {
                            try sessionDeletionService.restore(childReceipt)
                        } catch {
                            rollbackError = error
                            break
                        }
                    }
                    if let rollbackError {
                        throw SettingsDeletionError.rollbackFailed(rollbackError.localizedDescription)
                    }
                    throw error
                }
            }
            onConfirmedSessionDeletion?(sessions.map(\.id))
            return receipt
        } catch {
            throw error
        }
    }

    /// 删除超过 `sessionRetentionDays` 天未更新的会话，返回删除数。
    @discardableResult
    func deleteSessionsOlderThanRetention() -> Int {
        0
    }

    func previewSessionsOlderThanRetention(now: Date = Date(), ttl: TimeInterval = 300) throws -> OperationIntent {
        try previewSessionBatch(kind: .retention, now: now, ttl: ttl)
    }

    @discardableResult
    func deleteSessionsOlderThanRetention(intent: OperationIntent, now: Date = Date()) throws -> DeletionReceipt {
        let receipt = try executeSessionBatch(kind: .retention, intent: intent, now: now)
        reloadStorage()
        return receipt
    }

    private func sessionBatchRecoveryURL(operationID: UUID) -> URL {
        sessionStore.sessionsDirectory.appendingPathComponent("_trash", isDirectory: true)
            .appendingPathComponent(".batch-\(operationID.uuidString).receipt")
    }

    /// Resolve original persisted child receipts, never inferred trash IDs.
    func sessionDeletionRecoveryReceipts(from receipt: DeletionReceipt) throws -> [DeletionReceipt] {
        guard [SettingsSessionBatchKind.retention, .all].contains(where: {
            receipt.targetID == $0.targetID && receipt.scopeID == "sessions:\($0.targetID)"
        }), receipt.outcome == "deleted", receipt.affectedCount >= 0 else {
            throw SessionDeletionError.restoreFailed("无效的会话批次恢复回执")
        }
        if receipt.affectedCount == 0 { return [] }
        return try PersistenceTransactionFence.withRead([sessionStore.persistenceDomain]) {
            try PersistenceTransactionFence.requireLiveRead(sessionStore.persistenceDomain)
            let url = sessionBatchRecoveryURL(operationID: receipt.operationID)
            let parent = try url.deletingLastPathComponent().resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard parent.isDirectory == true, parent.isSymbolicLink != true,
                  values.isRegularFile == true, values.isSymbolicLink != true else {
                throw SessionDeletionError.restoreFailed("恢复回执目录或目标无效")
            }
            let recovery = try JSONDecoder().decode(SettingsSessionBatchRecoveryReceipt.self,
                from: PersistenceTransactionFence.data(at: url, domain: sessionStore.persistenceDomain))
            let children = recovery.childReceipts
            guard recovery.aggregate == receipt, children.count == receipt.affectedCount,
                  Set(children.map(\.operationID)).count == children.count,
                  Set(children.map(\.targetID)).count == children.count,
                  children.allSatisfy({
                      $0.operationID != receipt.operationID && $0.outcome == "deleted"
                          && $0.affectedCount == 1 && $0.scopeID == "session:\($0.targetID):active"
                  }) else {
                throw SessionDeletionError.restoreFailed("批次没有有效的逐会话恢复回执")
            }
            return children
        }
    }

    func restoreSessionDeletion(receipt: DeletionReceipt) throws {
        try sessionDeletionService.restore(receipt)
        reloadStorage()
    }

    // MARK: - 自动清理消费者（storage.autoDeleteOldSessions）

    /// `storage.autoDeleteOldSessions` 的行为消费者。仅当用户开启自动清理且
    /// 存在超过 `sessionRetentionDays` 的会话时，返回待清理数量；未开启（默认）
    /// 恒为 0。纯计算，不删除任何数据：真正移除会话仍必须经 `previewSessionsOlderThanRetention`
    /// + `deleteSessionsOlderThanRetention(intent:)` 的两步确认门禁，并只是移入回收站（可恢复）。
    /// 因此开启该开关不会引入任何静默、不可逆的删除。
    var pendingAutoCleanupCount: Int {
        guard autoDeleteOldSessions else { return 0 }
        return (try? sessionBatchSnapshot(.retention))?.count ?? 0
    }

    /// 为自动清理路径生成「可审阅、经门禁确认、可恢复（回收站）」的 OperationIntent。
    /// 只有开关开启且在同一 `now` 下确有超期会话时返回非 nil，否则返回 nil；
    /// 开启时的非法保留窗口会抛错。本方法本身不删除任何会话；调用方拿到 intent 后仍须走
    /// `deleteSessionsOlderThanRetention(intent:)` 由用户确认后才移入回收站。
    func previewAutoCleanupIntentIfEnabled(now: Date = Date(), ttl: TimeInterval = 300) throws -> OperationIntent? {
        guard autoDeleteOldSessions else { return nil }
        guard try !sessionBatchSnapshot(.retention, now: now).isEmpty else { return nil }
        return try previewSessionsOlderThanRetention(now: now, ttl: ttl)
    }

    func previewAllSessions(now: Date = Date(), ttl: TimeInterval = 300) throws -> OperationIntent {
        try previewSessionBatch(kind: .all, now: now, ttl: ttl)
    }

    @discardableResult
    func deleteAllSessions(intent: OperationIntent, now: Date = Date()) throws -> DeletionReceipt {
        let receipt = try executeSessionBatch(kind: .all, intent: intent, now: now)
        reloadStorage()
        return receipt
    }

    func previewMemoryFactDeletion(id: String, now: Date = Date(), ttl: TimeInterval = 300) throws -> OperationIntent {
        guard let fact = try memoryStore.facts().first(where: { $0.id == id }) else {
            throw SettingsDeletionError.notFound(id)
        }
        return DeletionGate.preview(
            targetID: id,
            targetType: "memory.fact",
            targetName: fact.text,
            affectedCount: 1,
            impactSummary: "删除一条长期记忆",
            reversible: false,
            scopeID: "memory:fact:\(id)",
            revision: Int(clamping: Int64(fact.createdAt.timeIntervalSince1970.rounded(.down))),
            fingerprint: try stableFingerprint(fact),
            now: now,
            ttl: ttl
        )
    }

    @discardableResult
    func removeMemoryFact(id: String) -> OperationIntent? {
        try? previewMemoryFactDeletion(id: id)
    }

    @discardableResult
    func removeMemoryFact(id: String, intent: OperationIntent, now: Date = Date()) throws -> DeletionReceipt {
        var rollback: MemoryFactDeletionRollback?
        var mutationStarted = false
        let expectedRevision = try memoryRevision(for: id)
        let expectedFingerprint = try memoryFingerprint(for: id)
        do {
            let receipt = try DeletionGate.execute(
                intent,
                currentRevision: expectedRevision,
                currentFingerprint: expectedFingerprint,
                now: now
            ) { _ in
                mutationStarted = true
                rollback = try memoryStore.removeFactForRollback(
                    id: id,
                    expectedRevision: expectedRevision,
                    expectedFingerprint: expectedFingerprint
                )
                guard try memoryStore.facts().allSatisfy({ $0.id != id }) else {
                    throw SettingsDeletionError.operationFailed("记忆删除后仍存在")
                }
            }
            reloadStorage()
            return receipt
        } catch {
            if mutationStarted, let rollback {
                do { try restoreMemoryFacts(rollback) }
                catch { throw SettingsDeletionError.rollbackFailed(error.localizedDescription) }
            }
            reloadStorage()
            throw error
        }
    }

    /// Agent/user input enters as a proposal; only an explicit approval receipt can write.
    @discardableResult
    func proposeMemoryFact(
        _ text: String,
        category: MemoryCategory = .fact,
        sourceSessionID: String = "app"
    ) -> String? {
        guard let scope = memoryScopeProvider?() else { return nil }
        do {
            return try memoryProposalConsumer.submit(
                text: text,
                category: category,
                within: scope,
                sourceID: Self.memoryCandidateSubmissionSourceID
            ).proposal.proposalID
        } catch {
            return nil
        }
    }

    /// Pending proposals for the currently selected concrete memory scope.
    /// Reading this projection never activates a fact.
    func pendingMemoryProposals() throws -> [MemoryProposalEnvelope] {
        guard let scope = memoryScopeProvider?(), scope.isValid else { return [] }
        return try memoryProposalConsumer.envelopes()
            .filter { envelope in
                envelope.state == .proposed
                    && envelope.proposal.memoryScope == scope
                    && envelope.binding?.matches(
                        scope: scope,
                        proposalID: envelope.proposal.proposalID,
                        sourceHash: envelope.sourceHash ?? "",
                        generation: envelope.generation ?? -1
                    ) == true
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// A Settings user action consumes exactly the proposal that was shown.
    /// The Core consumer rechecks the observed source hash and generation at
    /// the write boundary; a scope switch or changed proposal fails closed.
    func approveDisplayedMemoryProposal(_ displayed: MemoryProposalEnvelope) throws {
        guard displayed.state == .proposed else {
            throw MemoryProposalConsumerError.invalidState(displayed.state)
        }
        guard let scope = memoryScopeProvider?(), scope.isValid else {
            throw MemoryProposalConsumerError.invalidMemoryScope
        }
        guard displayed.proposal.memoryScope == scope else {
            throw MemoryProposalConsumerError.scopeMismatch
        }
        guard let sourceHash = displayed.sourceHash,
              let generation = displayed.generation,
              displayed.binding?.matches(
                  scope: scope,
                  proposalID: displayed.proposal.proposalID,
                  sourceHash: sourceHash,
                  generation: generation
              ) == true else {
            throw MemoryProposalConsumerError.invalidBinding
        }
        guard let current = try memoryProposalConsumer.envelopes().first(where: {
            $0.proposal.proposalID == displayed.proposal.proposalID
        }), current == displayed else {
            throw MemoryProposalConsumerError.proposalConflict
        }
        _ = try memoryProposalConsumer.approve(
            proposalID: displayed.proposal.proposalID,
            within: scope,
            reason: "用户在记忆设置中明确批准",
            generation: generation,
            sourceHash: sourceHash
        )
        reloadStorage()
    }

    /// A refusal consumes only the exact displayed candidate in this scope.
    func rejectDisplayedMemoryProposal(_ displayed: MemoryProposalEnvelope) throws {
        guard let scope = memoryScopeProvider?(), scope.isValid else {
            throw MemoryProposalConsumerError.invalidMemoryScope
        }
        _ = try memoryProposalConsumer.reject(displayed, within: scope)
        reloadStorage()
    }

    enum MemoryFactAddResult: Equatable {
        case added, emptyInput, missingScope, scopeRejected, persistenceFailed

        var message: String {
            switch self {
            case .added: return "已添加一条记忆。"
            case .emptyInput: return "请输入记忆内容。"
            case .missingScope: return "当前会话未归入项目。要对所有会话生效，请写入「全局记忆」（GLOBAL.md）；要只对某个项目生效，请先归入项目。输入内容已保留。"
            case .scopeRejected: return "当前会话的记忆范围不可用，请重新选择项目；输入内容已保留。"
            case .persistenceFailed: return "记忆未能保存，请检查存储后重试；输入内容已保留。"
            }
        }
    }

    /// Preserve the legacy Boolean API while the UI consumes the typed outcome.
    @discardableResult
    func addMemoryFact(_ text: String, category: MemoryCategory = .fact) -> Bool {
        addMemoryFactResult(text, category: category) == .added
    }

    @discardableResult
    func addMemoryFactResult(_ text: String, category: MemoryCategory = .fact) -> MemoryFactAddResult {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .emptyInput }
        guard let scope = memoryScopeProvider?() else { return .missingScope }
        guard scope.isValid else { return .scopeRejected }
        do {
            _ = try memoryProposalConsumer.addManualProjectFact(
                text: text, category: category, within: scope
            )
            reloadStorage()
            return .added
        } catch let error as MemoryProposalConsumerError {
            switch error {
            case .invalidMemoryScope, .scopeMismatch: return .scopeRejected
            default: return .persistenceFailed
            }
        } catch {
            return .persistenceFailed
        }
    }

    enum UserTypedMemoryOutcome: Equatable {
        case project, personal, credentialLike, personalFull, failed
    }

    /// 本人在对话输入框里键入的“请记住…”/“# …”：直接写入，不经提案。
    /// 只允许由输入框的本人提交路径调用（模型提议的记忆仍走提案 + 批准）。
    /// 项目会话写入项目记忆；普通会话写成记忆库里的个人事实（.personal，每回合常驻注入），
    /// 不再改写 GLOBAL.md，所以不会把内置默认全局指令冻结成“已自定义”。
    func addUserTypedMemory(
        _ text: String, within scope: MemoryScope?, sessionID: String? = nil
    ) -> UserTypedMemoryOutcome {
        let fact = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fact.isEmpty else { return .failed }
        guard ContentSecretRedactor.redact(fact) == fact else { return .credentialLike }
        if let scope {
            guard scope.isValid else { return .failed }
            do {
                _ = try memoryProposalConsumer.addManualProjectFact(
                    text: fact, category: .fact, within: scope)
                reloadStorage()
                return .project
            } catch {
                return .failed
            }
        }
        guard let principal = memoryTrustedPrincipalProvider?() else { return .failed }
        migratePersonalMemorySectionFromGlobal()
        do {
            let mine = try memoryStore.activeFacts().filter {
                $0.visibility == .personal && $0.ownerUserID == principal.userID
            }
            if mine.contains(where: { $0.text == fact }) { return .personal }
            guard mine.count < Self.personalMemoryFactLimit else { return .personalFull }
            _ = try memoryStore.addFact(
                fact,
                sourceSessionID: sessionID ?? "",
                category: .fact,
                memoryScope: Self.personalMemoryScope,
                ownerUserID: principal.userID,
                visibility: .personal,
                trustedPrincipal: principal
            )
            reloadStorage()
            return .personal
        } catch {
            return .failed
        }
    }

    /// 个人事实不属于某个会话或项目，用固定范围存放；注入按本人身份取，不看这个范围。
    static let personalMemoryScope = MemoryScope(sessionID: "personal-memory", projectID: "personal-memory")
    /// 常驻注入受 maxFacts 与字符预算约束，个人事实太多只会互相挤掉，这里设上限提示精简。
    static let personalMemoryFactLimit = 200
    private static let personalMemoryHeader = "【我的记忆】"

    /// 把旧版写进 GLOBAL.md 的“【我的记忆】”段迁成个人事实，并从 GLOBAL.md 移除该段。
    /// 移除后剩下的内容与内置默认全局指令一致（或为空）时，删除 GLOBAL.md 回到“未自定义”，
    /// 让以后默认指令的更新继续生效；否则保留用户自己的内容。
    /// 幂等：段不存在就什么也不做；个人事实写入失败时不动 GLOBAL.md，下次再迁。
    @discardableResult
    func migratePersonalMemorySectionFromGlobal() -> Int {
        let existing = memoryFileStore.readGlobal()
        guard let headerRange = existing.range(of: Self.personalMemoryHeader),
              let principal = memoryTrustedPrincipalProvider?() else { return 0 }
        let before = String(existing[..<headerRange.lowerBound])
        let section = String(existing[headerRange.upperBound...])
        var items: [String] = []
        var restLines: [Substring] = []
        var inItems = true
        for line in section.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inItems, trimmed.hasPrefix("- ") {
                let item = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if !item.isEmpty { items.append(item) }
            } else if inItems, trimmed.isEmpty {
                continue
            } else {
                inItems = false
                restLines.append(line)
            }
        }
        do {
            let known = Set(try memoryStore.activeFacts().filter {
                $0.visibility == .personal && $0.ownerUserID == principal.userID
            }.map(\.text))
            for item in items where !known.contains(item) {
                _ = try memoryStore.addFact(
                    item, sourceSessionID: "", category: .fact,
                    memoryScope: Self.personalMemoryScope,
                    ownerUserID: principal.userID, visibility: .personal,
                    trustedPrincipal: principal)
            }
        } catch {
            return 0
        }
        let remainder = (before + restLines.joined(separator: "\n"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let isDefault = remainder.isEmpty
            || remainder == MemoryInjector.defaultGlobalInstructions
                .trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if isDefault {
                _ = try deleteMemoryDocument(named: "GLOBAL.md")
            } else {
                _ = try writeMemoryDocument(named: "GLOBAL.md", content: remainder)
            }
        } catch {
            // 个人事实已写入；GLOBAL.md 下次再清理，重复事实会按文本去重。
        }
        reloadStorage()
        return items.count
    }

    /// MEMORY-05 编辑半区：把一条仍为 active 的长期记忆追加一个新修订。
    /// 写入只走 `MemoryStore.appendRevision` 规范入口（旧修订被 store 置为
    /// superseded，不新增任何并行持久化通道）；空文本与不存在/非 active 目标
    /// 分别以 `emptyFact` / `unknownFact` 失败关闭。
    @discardableResult
    func editMemoryFact(id: String, newText: String) throws -> MemoryFact {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MemoryStoreError.emptyFact }
        let facts = try memoryStore.facts()
        guard let target = facts.first(where: { $0.id == id }),
              target.lifecycleState == .active else {
            throw MemoryStoreError.unknownFact
        }
        return try commitMemoryFactEdit(id: id, text: trimmed, expected: target)
    }

    /// Bind the edit to the revision read before commit. Keeping this step
    /// separate also lets callers verify that a stale snapshot cannot write.
    @discardableResult
    func commitMemoryFactEdit(
        id: String, text: String, expected: MemoryFact,
        makeSettingsReplayRecord: BL6MemoryReplayRecordFactory? = nil
    ) throws -> MemoryFact {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MemoryStoreError.emptyFact }
        guard expected.id == id, expected.lifecycleState == .active else {
            throw MemoryStoreError.concurrentMutation
        }
        let nextRevision = expected.revision + 1
        let fact = try memoryStore.appendRevision(
            to: id,
            text: trimmed,
            trustedPrincipal: memoryTrustedPrincipalProvider?(),
            sourceProposalID: "user-edit:\(id):r\(nextRevision)",
            sourceRef: "settings://memory/\(id)/revision-\(nextRevision)",
            contentDigest: MemoryStore.contentDigest(for: trimmed),
            expectedRevision: expected.revision,
            expectedFingerprint: try stableFingerprint(expected),
            makeSettingsReplayRecord: makeSettingsReplayRecord
        )
        reloadStorage()
        return fact
    }

    /// Import memory facts through one scoped restore transaction.
    ///
    /// This compatibility entry point keeps the existing non-throwing settings
    /// API, while the actual production write path is the throwing method below.
    /// Imported scope metadata is untrusted and is replaced by the active scope
    /// only when the shared restore contract accepts the payload.
    func importMemoryFacts(_ facts: [MemoryFact]) -> MemoryImportResult {
        do {
            return try importMemoryFactsThrowing(facts)
        } catch {
            return MemoryImportResult(added: 0, skipped: facts.count)
        }
    }

    /// Export facts through a strict store read. A corrupt or unreadable
    /// facts file must remain observable to the caller.
    func exportMemoryJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(memoryStore.loadFacts())
    }

    /// Export JSON to a user-selected file and verify the completed file
    /// before returning.  The no-argument data API above remains unchanged for
    /// existing backup callers.
    @discardableResult
    func exportMemoryJSON(to url: URL) throws -> MemoryFileExportReceipt {
        try exportMemoryFile(format: .json, to: url)
    }

    @discardableResult
    func exportMemoryJSONFile(to url: URL) throws -> MemoryFileExportReceipt {
        try exportMemoryJSON(to: url)
    }

    /// Export readable Markdown to a user-selected file.  Metadata comments
    /// preserve stable IDs/provenance so the document can be imported again.
    @discardableResult
    func exportMemoryMarkdown(to url: URL) throws -> MemoryFileExportReceipt {
        try exportMemoryFile(format: .markdown, to: url)
    }

    @discardableResult
    func exportMemoryMarkdownFile(to url: URL) throws -> MemoryFileExportReceipt {
        try exportMemoryMarkdown(to: url)
    }

    /// Background-safe file export used by the settings UI after the save
    /// panel closes.  Completion is published only after an atomic write and a
    /// byte-for-byte read-back succeeds.
    @discardableResult
    func exportMemoryFileAsync(
        format: MemoryExportFormat,
        to url: URL
    ) async throws -> MemoryFileExportReceipt {
        let store = memoryStore
        let consumer = memoryProposalConsumer
        let beforeWrite = memoryExportBeforeWriteForTesting
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let manager = MemoryManager(store: store, memoryProposalConsumer: consumer)
            let data: Data
            switch format {
            case .json:
                data = try manager.export()
            case .markdown:
                data = try manager.exportMarkdown()
            }
            if let beforeWrite { await beforeWrite() }
            try Task.checkCancellation()
            return try Self.writeCompletedMemoryFile(data, format: format, to: url)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    @discardableResult
    private func exportMemoryFile(
        format: MemoryExportFormat,
        to url: URL
    ) throws -> MemoryFileExportReceipt {
        let manager = MemoryManager(store: memoryStore, memoryProposalConsumer: memoryProposalConsumer)
        let data: Data
        switch format {
        case .json:
            data = try manager.export()
        case .markdown:
            data = try manager.exportMarkdown()
        }
        return try Self.writeCompletedMemoryFile(data, format: format, to: url)
    }

    nonisolated private static func writeCompletedMemoryFile(
        _ data: Data,
        format: MemoryExportFormat,
        to url: URL
    ) throws -> MemoryFileExportReceipt {
        let destination = url.standardizedFileURL
        guard !destination.path.isEmpty,
              destination.lastPathComponent != ".",
              destination.lastPathComponent != ".." else {
            throw MemoryFileExportError.invalidDestination
        }
        let fileManager = FileManager.default
        var isDirectory = ObjCBool(false)
        if fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            throw MemoryFileExportError.invalidDestination
        }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination, options: .atomic)
        let completed = try Data(contentsOf: destination)
        guard completed == data else {
            throw MemoryFileExportError.verificationFailed
        }
        return MemoryFileExportReceipt(
            format: format,
            url: destination,
            byteCount: completed.count,
            contentHash: Self.memoryDataDigest(completed)
        )
    }

    /// Parse a Markdown file into an immutable, write-free preview.  The
    /// exact source bytes and the active concrete scope are captured so a
    /// later confirmation cannot accidentally consume a changed file or a
    /// different session/project.
    func previewMemoryMarkdown(
        _ data: Data,
        sourceURL: URL? = nil
    ) throws -> MemoryMarkdownImportPreview {
        let document = try MemoryMarkdownCodec.decode(data)
        return try makeMemoryMarkdownPreview(data, document: document, sourceURL: sourceURL)
    }

    /// Build a preview from a document parsed off the main actor.  The source
    /// hash is checked again at this boundary so a caller cannot pair bytes
    /// with a document from another file.
    func makeMemoryMarkdownPreview(
        _ data: Data,
        document: MemoryMarkdownDocument,
        sourceURL: URL? = nil
    ) throws -> MemoryMarkdownImportPreview {
        guard !data.isEmpty,
              document.sourceHash == Self.memoryDataDigest(data),
              !document.facts.isEmpty else {
            throw MemoryMarkdownImportError.invalidPreview
        }
        let activeScope = memoryScopeProvider?()
        return MemoryMarkdownImportPreview(
            sourceURL: sourceURL,
            sourceName: sourceURL?.lastPathComponent ?? "记忆.md",
            sourceData: data,
            sourceHash: document.sourceHash,
            document: document,
            capturedScope: activeScope
        )
    }

    func previewMemoryMarkdown(from url: URL) throws -> MemoryMarkdownImportPreview {
        try previewMemoryMarkdown(Data(contentsOf: url), sourceURL: url)
    }

    func previewMemoryMarkdownFile(
        _ data: Data,
        sourceURL: URL? = nil
    ) throws -> MemoryMarkdownImportPreview {
        try previewMemoryMarkdown(data, sourceURL: sourceURL)
    }

    /// Bind one of Personal/Project/Temporary to the concrete active scope.
    /// This is still a preview operation: no proposal, receipt, or facts file
    /// is written until `confirmMemoryMarkdownImport` is called.
    func selectMemoryMarkdownScope(
        _ scope: MemoryImportScope,
        for preview: MemoryMarkdownImportPreview
    ) throws -> MemoryMarkdownImportPreview {
        try validateMemoryMarkdownPreview(preview)
        guard let activeScope = memoryScopeProvider?() else {
            throw MemoryMarkdownImportError.invalidScope
        }
        guard activeScope.isValid else {
            throw MemoryMarkdownImportError.invalidScope
        }
        guard preview.capturedScope == activeScope else {
            throw MemoryMarkdownImportError.scopeChanged
        }
        let target = try memoryMarkdownTarget(scope, activeScope: activeScope)
        return preview.selecting(scope, target: target.scope, ownerUserID: target.ownerUserID)
    }

    func updateMemoryMarkdownPreview(
        _ preview: MemoryMarkdownImportPreview,
        scope: MemoryImportScope
    ) throws -> MemoryMarkdownImportPreview {
        try selectMemoryMarkdownScope(scope, for: preview)
    }

    /// Confirm an already-selected preview through the existing scoped
    /// `MemoryProposalConsumer`/`MemoryManager` restore path.
    @discardableResult
    func confirmMemoryMarkdownImport(
        _ preview: MemoryMarkdownImportPreview
    ) throws -> MemoryImportResult {
        guard preview.selectedScope != nil else {
            throw MemoryMarkdownImportError.scopeNotSelected
        }
        let plan = try prepareMemoryMarkdownImport(preview)
        guard isSafetyFeatureEnabled(.experimentalMemoryImport) else {
            throw SafetyRuntimeAdmissionError.featureDisabled(.experimentalMemoryImport)
        }
        let result = try Self.applyMemoryMarkdownImport(
            plan,
            store: memoryStore,
            consumer: memoryProposalConsumer
        )
        reloadStorage()
        return result
    }

    /// Convenience form for callers that select and confirm in one explicit
    /// UI action.  The selection is still bound and revalidated before write.
    @discardableResult
    func confirmMemoryMarkdownImport(
        _ preview: MemoryMarkdownImportPreview,
        selecting scope: MemoryImportScope
    ) throws -> MemoryImportResult {
        let selected = try selectMemoryMarkdownScope(scope, for: preview)
        let plan = try prepareMemoryMarkdownImport(selected)
        guard isSafetyFeatureEnabled(.experimentalMemoryImport) else {
            throw SafetyRuntimeAdmissionError.featureDisabled(.experimentalMemoryImport)
        }
        let result = try Self.applyMemoryMarkdownImport(
            plan,
            store: memoryStore,
            consumer: memoryProposalConsumer
        )
        reloadStorage()
        return result
    }

    /// Async confirmation keeps a large Markdown merge off the main actor.
    /// Scope/source validation happens before dispatch; the shared consumer
    /// still owns the complete atomic restore transaction.
    @discardableResult
    func confirmMemoryMarkdownImportAsync(
        _ preview: MemoryMarkdownImportPreview,
        selecting scope: MemoryImportScope
    ) async throws -> MemoryImportResult {
        let selected = try selectMemoryMarkdownScope(scope, for: preview)
        let plan = try prepareMemoryMarkdownImport(selected)
        guard isSafetyFeatureEnabled(.experimentalMemoryImport) else {
            throw SafetyRuntimeAdmissionError.featureDisabled(.experimentalMemoryImport)
        }
        let store = memoryStore
        let consumer = memoryProposalConsumer
        let result = try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try Self.applyMemoryMarkdownImport(plan, store: store, consumer: consumer)
        }.value
        reloadStorage()
        return result
    }

    @discardableResult
    func importMemoryMarkdown(
        _ data: Data,
        selecting scope: MemoryImportScope = .project
    ) throws -> MemoryImportResult {
        let preview = try previewMemoryMarkdown(data)
        return try confirmMemoryMarkdownImport(preview, selecting: scope)
    }

    @discardableResult
    func importMemoryMarkdown(
        _ data: Data,
        scope: MemoryImportScope
    ) throws -> MemoryImportResult {
        try importMemoryMarkdown(data, selecting: scope)
    }

    private func prepareMemoryMarkdownImport(
        _ preview: MemoryMarkdownImportPreview
    ) throws -> MemoryMarkdownImportPlan {
        guard let selectedScope = preview.selectedScope,
              let targetScope = preview.boundTargetScope,
              let capturedScope = preview.capturedScope,
              selectedScope != MemoryImportScope.personal || preview.boundOwnerUserID != nil else {
            throw MemoryMarkdownImportError.scopeNotSelected
        }
        try validateMemoryMarkdownPreview(preview)
        guard let activeScope = memoryScopeProvider?(), activeScope.isValid else {
            throw MemoryMarkdownImportError.invalidScope
        }
        guard activeScope == capturedScope, activeScope == targetScope else {
            throw MemoryMarkdownImportError.scopeChanged
        }
        let trustedPrincipal = selectedScope == .personal ? memoryTrustedPrincipalProvider?() : nil
        if selectedScope == .personal {
            guard let trustedPrincipal, trustedPrincipal.userID == preview.boundOwnerUserID,
                  let currentOwner = memoryOwnerUserIDProvider?()?.trimmingCharacters(in: .whitespacesAndNewlines),
                  currentOwner == preview.boundOwnerUserID else {
                throw MemoryMarkdownImportError.ownerChanged
            }
        }
        return MemoryMarkdownImportPlan(
            targetScope: targetScope,
            incomingFacts: retargetMemoryMarkdownFacts(
                preview.document.facts,
                ownerUserID: preview.boundOwnerUserID,
                visibility: selectedScope,
                targetScope: targetScope
            ),
            trustedPrincipal: trustedPrincipal
        )
    }

    nonisolated private static func applyMemoryMarkdownImport(
        _ plan: MemoryMarkdownImportPlan,
        store: MemoryStore,
        consumer: MemoryProposalConsumer
    ) throws -> MemoryImportResult {
        let existingReceiptIDs = Set(
            try consumer.restoreReceipts().map(\.restoreID)
        )
        let manager = MemoryManager(store: store, memoryProposalConsumer: consumer)
        let restored = try manager.importFacts(
            plan.incomingFacts,
            within: plan.targetScope,
            mode: .merge,
            reason: "settings memory Markdown import",
            trustedPrincipal: plan.trustedPrincipal
        )
        if existingReceiptIDs.contains(restored.receipt.restoreID) {
            return MemoryImportResult(added: 0, skipped: plan.incomingFacts.count)
        }
        return MemoryImportResult(added: restored.added, skipped: restored.skipped)
    }

    private func validateMemoryMarkdownPreview(
        _ preview: MemoryMarkdownImportPreview
    ) throws {
        guard !preview.sourceData.isEmpty,
              preview.sourceHash == Self.memoryDataDigest(preview.sourceData),
              preview.sourceHash == preview.document.sourceHash,
              !preview.document.facts.isEmpty else {
            throw MemoryMarkdownImportError.invalidPreview
        }
        if let sourceURL = preview.sourceURL {
            guard let current = try? Data(contentsOf: sourceURL),
                  Self.memoryDataDigest(current) == preview.sourceHash else {
                throw MemoryMarkdownImportError.sourceChanged
            }
        }
    }

    private func memoryMarkdownTarget(
        _ scope: MemoryImportScope,
        activeScope: MemoryScope
    ) throws -> (scope: MemoryScope, ownerUserID: String?) {
        guard activeScope.isValid else { throw MemoryMarkdownImportError.invalidScope }
        switch scope {
        case .personal:
            guard let owner = memoryOwnerUserIDProvider?()?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !owner.isEmpty else {
                throw MemoryMarkdownImportError.invalidScope
            }
            return (activeScope, owner)
        case .project, .temporary:
            return (activeScope, nil)
        }
    }

    private func retargetMemoryMarkdownFacts(
        _ facts: [MemoryFact],
        ownerUserID: String?,
        visibility: MemoryImportScope,
        targetScope: MemoryScope
    ) -> [MemoryFact] {
        facts.map { fact in
            let hasProvenance = fact.sourceProposalID != nil
                || fact.sourceRef != nil
                || fact.contentDigest != nil
            return MemoryFact(
                id: fact.id,
                text: fact.text,
                sourceSessionID: fact.sourceSessionID,
                createdAt: fact.createdAt,
                category: fact.category,
                memoryScope: nil,
                ownerUserID: ownerUserID,
                visibility: MemoryVisibility(rawValue: visibility.rawValue),
                temporaryLifetimeID: visibility == .temporary ? "session:" + targetScope.sessionID : nil,
                sourceProposalID: hasProvenance ? fact.sourceProposalID : nil,
                sourceRef: hasProvenance ? fact.sourceRef : nil,
                contentDigest: hasProvenance
                    ? MemoryStore.contentDigest(for: fact.text)
                    : nil,
                revision: fact.revision,
                supersedesFactID: fact.supersedesFactID,
                lifecycleState: fact.lifecycleState,
                activatedAt: fact.activatedAt
            )
        }
    }

    nonisolated private static func memoryDataDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Import JSON through the same scoped restore contract used by snapshot
    /// restore. The active scope is mandatory; the `memoryScope` embedded in a
    /// JSON file is untrusted export-time data (it pins the session UUID that
    /// was active when the file was written) and is replaced by the active
    /// scope at the entry layer, mirroring the Markdown import's explicit
    /// retarget. Every other field passes through unchanged, so a JSON export
    /// re-imports losslessly, and repeated input replays the durable receipt
    /// idempotently.
    func importMemoryJSON(_ data: Data) throws -> MemoryImportResult {
        let facts = try JSONDecoder().decode([MemoryFact].self, from: data)
        return try importMemoryFactsThrowing(facts)
    }

    /// Entry-layer retarget for JSON import.
    ///
    /// Strips only the untrusted `memoryScope` so the shared restore contract
    /// binds the fact to the caller's active scope. Content fields — stable id,
    /// trimmed-free text, category, timestamps, provenance ids, content digest,
    /// revision, supersession, lifecycle state and owner identity — remain
    /// byte-identical. This changes only what the settings entry trusts; the
    /// `MemoryStore`/`MemoryProposalConsumer` restore semantics (including the
    /// fail-closed handling of foreign scopes on the core transfer path and the
    /// durable receipt contract) are untouched.
    private func retargetMemoryJSONFacts(_ facts: [MemoryFact]) -> [MemoryFact] {
        facts.map { fact in
            guard fact.memoryScope != nil else { return fact }
            return MemoryFact(
                id: fact.id,
                text: fact.text,
                sourceSessionID: fact.sourceSessionID,
                createdAt: fact.createdAt,
                category: fact.category,
                memoryScope: nil,
                ownerUserID: fact.ownerUserID,
                visibility: fact.visibility,
                temporaryLifetimeID: fact.temporaryLifetimeID,
                sourceProposalID: fact.sourceProposalID,
                sourceRef: fact.sourceRef,
                contentDigest: fact.contentDigest,
                writeProvenance: fact.writeProvenance,
                revision: fact.revision,
                supersedesFactID: fact.supersedesFactID,
                lifecycleState: fact.lifecycleState,
                activatedAt: fact.activatedAt
            )
        }
    }

    /// Throwing form used by file import so corrupt input and store failures
    /// can be surfaced instead of being reported as skipped facts.
    func importMemoryFactsThrowing(
        _ facts: [MemoryFact],
        expectedScope: MemoryScope? = nil
    ) throws -> MemoryImportResult {
        guard isSafetyFeatureEnabled(.experimentalMemoryImport) else {
            throw SafetyRuntimeAdmissionError.featureDisabled(.experimentalMemoryImport)
        }
        guard let memoryScope = memoryScopeProvider?() else {
            throw MemoryProposalConsumerError.invalidMemoryScope
        }
        // The file picker reads JSON off the main actor. A late result must
        // not silently retarget the selected file to a different session or
        // project while it was being read.
        if let expectedScope, memoryScope != expectedScope {
            throw MemoryProposalConsumerError.scopeMismatch
        }

        let existingReceiptIDs = Set(
            try memoryProposalConsumer.restoreReceipts().map(\.restoreID)
        )
        let restored = try memoryProposalConsumer.restoreFacts(
            retargetMemoryJSONFacts(facts),
            within: memoryScope,
            mode: .merge,
            reason: "settings memory JSON import"
        )
        reloadStorage()
        if existingReceiptIDs.contains(restored.receipt.restoreID) {
            return MemoryImportResult(added: 0, skipped: facts.count)
        }

        let accounted = restored.added + restored.skipped
        return MemoryImportResult(
            added: restored.added,
            skipped: restored.skipped + max(0, facts.count - accounted)
        )
    }

    /// 清空全部记忆事实，返回删除数。
    @discardableResult
    func clearAllMemory() -> Int {
        0
    }

    func previewMemoryClear(now: Date = Date(), ttl: TimeInterval = 300) throws -> OperationIntent {
        let facts = try memoryStore.facts()
        return DeletionGate.preview(
            targetID: "memory.facts",
            targetType: "memory.clear",
            targetName: "全部长期记忆",
            affectedCount: facts.count,
            impactSummary: "永久清空全部长期记忆；成功后无法恢复",
            reversible: false,
            scopeID: "memory:facts",
            revision: facts.count,
            fingerprint: try stableFingerprint(facts),
            now: now,
            ttl: ttl
        )
    }

    @discardableResult
    func clearAllMemory(intent: OperationIntent, now: Date = Date()) throws -> DeletionReceipt {
        guard intent.targetID == "memory.facts",
              intent.targetType == "memory.clear",
              intent.scopeID == "memory:facts",
              intent.operationType == .delete,
              !intent.reversible else {
            throw DeletionGateError.targetChanged
        }
        let before = try memoryStore.facts()
        let expectedFingerprint = try stableFingerprint(before)
        var rollback: MemoryFactDeletionRollback?
        var mutationStarted = false
        do {
            let receipt = try DeletionGate.execute(
                intent,
                currentRevision: before.count,
                currentFingerprint: expectedFingerprint,
                now: now
            ) { _ in
                mutationStarted = true
                rollback = try memoryStore.removeAllFactsForRollback(
                    expectedRevision: before.count,
                    expectedFingerprint: expectedFingerprint
                )
                guard try memoryStore.facts().isEmpty else {
                    throw SettingsDeletionError.operationFailed("记忆清空后仍有数据")
                }
            }
            reloadStorage()
            return receipt
        } catch {
            if mutationStarted, let rollback {
                do { try restoreMemoryFacts(rollback) }
                catch { throw SettingsDeletionError.rollbackFailed(error.localizedDescription) }
            }
            reloadStorage()
            throw error
        }
    }

    struct AtomicBackupDraft: Identifiable, Sendable {
        let id: UUID
        let sourceURL: URL
        let data: Data
        let manifest: SyncManifest
        let sourceCounts: [SyncScope: Int]
        let sourceMemoryScopes: [MemoryScope]
        let hasMissingMemoryProvenance: Bool
        let settingsRecovery: SettingsRecoveryAttachment?
    }
    enum AtomicBackupMetadataError: Error, Equatable, LocalizedError {
        case missingFields([String])
        var errorDescription: String? {
            switch self {
            case .missingFields(let fields): return "备份清单缺少\(fields.joined(separator: "、"))，无法核对来源；请使用包含这些信息的原始备份。"
            }
        }
    }
    private final class ImportCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func cancel() { lock.lock(); value = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
    private(set) var atomicBackupInProgress = false
    private(set) var atomicBackupReopenRequired = false
    private(set) var atomicBackupRecoveryRequired = false
    private(set) var atomicBackupReceipt: SyncAtomicImportReceipt?

    /// Opening a file retains the exact bytes even if a target scope is missing.
    /// It does not export, clear dirty flags, construct stores or create staging.
    func readAtomicBackupDraft(
        from url: URL,
        protection: SyncSnapshotProtection = .legacy
    ) throws -> AtomicBackupDraft {
        let data = try syncManager.readSnapshotFileData(from: url, protection: protection)
        return try makeAtomicBackupDraft(sourceURL: url, data: data)
    }

    /// Password/KDF and file decoding run away from the MainActor. The
    /// caller owns the task generation and rejects late UI publication.
    func readAtomicBackupDraftAsync(
        from url: URL,
        protection: SyncSnapshotProtection
    ) async throws -> AtomicBackupDraft {
        let manager = syncManager
        let data = try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let data = try manager.readSnapshotFileData(from: url, protection: protection)
            try Task.checkCancellation()
            return data
        }.value
        try Task.checkCancellation()
        return try makeAtomicBackupDraft(sourceURL: url, data: data)
    }

    func backupProtectionKindAsync(from url: URL) async throws -> SyncSnapshotProtectionKind {
        let manager = syncManager
        return try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let kind = try manager.snapshotProtectionKind(from: url)
            try Task.checkCancellation()
            return kind
        }.value
    }

    private func makeAtomicBackupDraft(sourceURL url: URL, data: Data) throws -> AtomicBackupDraft {
        struct Header: Decodable {
            let manifest: SyncManifest
            let sessions: [ChatSession]?
            let memories: [MemoryFact]?
            let skills: [String: String]?
            let settings: AppSettings?
            let settingsRecovery: SettingsRecoveryAttachment?
        }
        guard data.count <= 64 * 1024 * 1024 else {
            throw SyncAtomicImportError.invalidSnapshot
        }
        if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let manifest = object["manifest"] as? [String: Any] {
            let missing = [("deviceName", "来源设备"), ("exportedAt", "导出时间")].compactMap { key, name in
                manifest[key] == nil || manifest[key] is NSNull ? name : nil
            }
            guard missing.isEmpty else { throw AtomicBackupMetadataError.missingFields(missing) }
        }
        let header = try JSONDecoder().decode(Header.self, from: data)
        try header.manifest.validate()
        let declared = Set(header.manifest.scopes.compactMap(SyncScope.init(rawValue:)))
        guard declared.count == header.manifest.scopes.count else { throw SyncAtomicImportError.invalidSnapshot }
        guard header.settingsRecovery == nil || declared.contains(.settings) else {
            throw SyncAtomicImportError.invalidSnapshot
        }
        var counts: [SyncScope: Int] = [:]
        for scope in declared {
            switch scope {
            case .sessions: guard let values = header.sessions else { throw SyncAtomicImportError.invalidSnapshot }; counts[scope] = values.count
            case .memories: guard let values = header.memories else { throw SyncAtomicImportError.invalidSnapshot }; counts[scope] = values.count
            case .skills: guard let values = header.skills else { throw SyncAtomicImportError.invalidSnapshot }; counts[scope] = values.count
            case .settings: guard header.settings != nil else { throw SyncAtomicImportError.invalidSnapshot }; counts[scope] = 1
            }
        }
        return AtomicBackupDraft(id: UUID(), sourceURL: url, data: data, manifest: header.manifest, sourceCounts: counts,
                                 sourceMemoryScopes: Array(Set(header.memories?.compactMap(\.memoryScope) ?? [])).sorted { $0.projectID + $0.sessionID < $1.projectID + $1.sessionID },
                                 hasMissingMemoryProvenance: header.memories?.contains(where: { $0.memoryScope == nil }) ?? false,
                                 settingsRecovery: header.settingsRecovery)
    }
    func previewAtomicBackup(_ draft: AtomicBackupDraft, selecting selected: Set<SyncScope>,
                             memoryScope: MemoryScope?) throws -> SyncAtomicImportPreview {
        let shortcutPlan: ShortcutRecoveryPlan?
        if selected.contains(.settings), let attachment = draft.settingsRecovery {
            guard let backupShortcutStore else { throw SyncAtomicImportError.invalidSnapshot }
            shortcutPlan = try backupShortcutStore.prepareRecovery(attachment.shortcutOverrides)
        } else {
            shortcutPlan = nil
        }
        return try syncManager.previewAtomicImport(draft.data, selecting: selected,
                                                   memoryScope: memoryScope, shortcutPlan: shortcutPlan)
    }
    func confirmAtomicBackup(_ draft: AtomicBackupDraft, preview: SyncAtomicImportPreview,
                             confirmation: SyncAtomicImportConfirmation) async throws -> SyncAtomicImportReceipt {
        guard !atomicBackupInProgress && !atomicBackupReopenRequired else { throw PersistenceTransactionError.busy }
        atomicBackupInProgress = true
        defer { atomicBackupInProgress = false }
        let manager = syncManager
        let cancellation = ImportCancellation()
        do {
            let receipt = try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) {
                    try manager.confirmAtomicImport(preview, snapshot: draft.data, confirmation: confirmation,
                                                    cancelled: { cancellation.isCancelled })
                }.value
            } onCancel: { cancellation.cancel() }
            atomicBackupReceipt = receipt
            atomicBackupReopenRequired = receipt.reopenRequired
            return receipt
        } catch {
            if error as? SyncAtomicImportError == .rollbackIncomplete || error as? SyncAtomicImportError == .recoveryRequired {
                atomicBackupRecoveryRequired = true
                atomicBackupReopenRequired = true
            }
            throw error
        }
    }

    // MARK: - 数据备份（F14 P1-3：导出/导入备份，错误不再静默吞）

    private func makeSettingsRecoveryAttachment() throws -> SettingsRecoveryAttachment? {
        guard let backupShortcutStore else { return nil }
        _ = try backupShortcutStore.recoveryTarget()
        return try SettingsRecoveryAttachment(
            providers: envStore.providerRecoveryMetadata(),
            shortcutOverrides: backupShortcutStore.recoveryOverrides()
        )
    }

    /// 导出全四域快照到 `url`。返回 (UI 中文消息, 是否失败)。
    func exportBackup(to url: URL) -> (message: String, isError: Bool) {
        do {
            try syncManager.exportSnapshotFile(to: url,
                                               settingsRecovery: makeSettingsRecoveryAttachment())
            return ("备份已导出：\(url.lastPathComponent)", false)
        } catch {
            return (SettingsFailureMessage.backup(error, operation: .export).message, true)
        }
    }

    /// Protected export keeps KDF and file work off the MainActor. The
    /// caller must reject a late result after cancelling or replacing the UI
    /// operation generation.
    func exportBackupAsync(
        to url: URL,
        protection: SyncSnapshotProtection
    ) async -> (message: String, isError: Bool) {
        let manager = syncManager
        let beforeDispatch = backupExportBeforeDispatchForTesting
        do {
            let attachment = try makeSettingsRecoveryAttachment()
            let worker = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                if let beforeDispatch { await beforeDispatch() }
                try Task.checkCancellation()
                try manager.exportSnapshotFile(to: url, protection: protection,
                                               settingsRecovery: attachment)
            }
            try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            return ("备份已导出：\(url.lastPathComponent)", false)
        } catch {
            return (SettingsFailureMessage.backup(error, operation: .export).message, true)
        }
    }

    /// 从 `url` 导入快照（恢复快照声明的全部域）。返回 (UI 中文消息, 是否失败)：
    /// - 全部成功 → `SyncImportResult.summaryMessage`（「导入成功：会话、记忆、技能、设置」）；
    /// - 部分域写盘失败 → catch `SyncImportError`：summaryMessage + 失败域条目级明细
    ///   （哪些域失败、每条失败原因），成功域数据已生效；
    /// - 快照校验失败（坏文件/版本不匹配/缺载荷）→ 中文校验说明，未写任何数据。
    /// 导入后（无论成败）刷新存储快照（会话/记忆计数即时更新）。
    func importBackup(from url: URL) -> (message: String, isError: Bool) {
        let deletionReviewWasEnabled = settingsStore.settings.agent.childDeletionAutoReviewEnabled
        do {
            let result = try syncManager.importSnapshotFile(
                from: url,
                memoryScope: memoryScopeProvider?()
            )
            refreshImportedDeletionReviewSettings(wasEnabled: deletionReviewWasEnabled)
            reloadStorage()
            return (result.summaryMessage, false)
        } catch let error as SyncImportError {
            refreshImportedDeletionReviewSettings(wasEnabled: deletionReviewWasEnabled)
            reloadStorage()
            return (importFailureDetail(error), true)
        } catch let error as SyncManifestError {
            return (manifestFailureMessage(error), true)
        } catch {
            return ("导入失败：\(error)", true)
        }
    }

    /// N1: SyncManager keeps the local G1 switch and whitelist on import
    /// (`preservingLocalPermissionSettings`), so an import normally leaves the
    /// switch unchanged and triggers no G1 re-attach. A partial import that did
    /// not restore settings leaves it unchanged too. The re-attach below only
    /// fires if the switch actually differs after the import.
    private func refreshImportedDeletionReviewSettings(wasEnabled: Bool) {
        settingsMirror = settingsStore.settings
        if wasEnabled != settingsMirror.agent.childDeletionAutoReviewEnabled {
            onFileAccessSettingsChanged?()
        }
    }

    /// SyncImportError 的中文描述：summaryMessage + 每个失败域的条目级明细。
    /// 形如「记忆 导入成功；会话 导入失败 — 会话（imp-1: 无法写入…）」。
    private func importFailureDetail(_ error: SyncImportError) -> String {
        let parts = error.result.scopeResults.compactMap { scopeResult -> String? in
            guard !scopeResult.succeeded else { return nil }
            let details = scopeResult.failures
                .map { "\($0.item): \($0.reason)" }
                .joined(separator: "；")
            return details.isEmpty
                ? scopeResult.scope.displayName
                : "\(scopeResult.scope.displayName)（\(details)）"
        }
        let summary = error.result.summaryMessage
        return parts.isEmpty ? summary : "\(summary) — \(parts.joined(separator: "、"))"
    }

    /// manifest 校验失败的中文说明（未写入任何数据）。
    private func manifestFailureMessage(_ error: SyncManifestError) -> String {
        switch error {
        case .unsupportedVersion(let expected, let found):
            return "导入失败：快照版本不匹配（期望 v\(expected)，实际 v\(found)）。"
        case .wrongSourceApplication:
            return "导入失败：备份声明来自其他应用，无法导入。"
        case .emptyScopes:
            return "导入失败：快照未声明任何数据域。"
        case .missingScopes(let scopes):
            return "导入失败：快照缺少必需数据域（\(scopes.joined(separator: "、"))）。"
        case .incompletePayload(let scopes):
            return "导入失败：快照载荷不完整（\(scopes.joined(separator: "、")) 数据缺失）。"
        case .invalidSnapshot:
            return "导入失败：不是合法的备份文件。"
        }
    }

    // MARK: - 环境变量（Environment）

    func setEnvVar(name: String, value: String, isSecret: Bool? = nil) -> Bool {
        let ok = envStore.setEnvVar(name: name, value: value, isSecret: isSecret)
        reloadEnv()
        return ok
    }

    /// Only the editor's explicitly labelled privacy save uses this entry.
    func saveExplicitlyClassifiedEnvironmentVariable(
        name: String, value: String, isSecret: Bool
    ) -> Bool {
        let ok = envStore.setEnvVarWithExplicitPrivacyClassification(
            name: name, value: value, isSecret: isSecret)
        reloadEnv()
        return ok
    }

    func previewEnvVarDeletion(name: String, now: Date = Date(), ttl: TimeInterval = 300) throws -> OperationIntent {
        guard let entry = currentEnvEntry(name: name) else {
            throw SettingsDeletionError.notFound(name)
        }
        return envDeletionIntent(
            entry: entry,
            targetType: "environment.variable",
            targetName: entry.name,
            impactSummary: "删除环境变量及其密钥链副本",
            scopeID: "env:\(entry.name)",
            now: now,
            ttl: ttl
        )
    }

    @discardableResult
    func deleteEnvVar(name: String) -> OperationIntent? {
        try? previewEnvVarDeletion(name: name)
    }

    @discardableResult
    func deleteEnvVar(name: String, intent: OperationIntent, now: Date = Date()) throws -> DeletionReceipt {
        let receipt = try executeEnvDeletion(intent: intent, name: name, providerOnly: false, now: now)
        reloadEnv()
        return receipt
    }

    /// 从当前进程环境导入（只新增不覆盖），返回导入数。
    @discardableResult
    func importFromProcessEnvironment() -> Int {
        let count = envStore.loadFromProcessEnvironment()
        lastImportCount = count
        reloadEnv()
        return count
    }

    // MARK: - 模型供应商（U5：增强供应商配置，参照 Codex/Hermes provider 模型）

    private let providerReadinessTransport: any SettingsProviderReadinessTransport
    var mm01FieldLane: DeepSeekMM01FieldLane?
    private let providerReadinessDeployment: ProviderDeployment
    private var providerModelReadinessGenerations: [String: Int] = [:]
    private var providerModelReadinessTasks: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    private var providerCredentialVersions: [String: ProviderCredentialVersion] = [:]

    /// Secret-free binding from the actual store and shared credential domain.
    /// RecoveryScope's workflow token deliberately remains a separate concept.
    func providerCredentialBinding(recordID: String) -> ProviderCredentialBinding? {
        guard let record = providerRecords.first(where: { $0.id == recordID }),
              record.isProviderRecord,
              let binding = envStore.credentialBinding(name: record.name),
              binding.recordID == record.id else { return nil }
        return ProviderCredentialBinding(providerID: binding.recordID,
            credentialName: binding.name, revision: binding.revision)
    }

    /// Resolve the actual binding before a UI send commits its message. Record
    /// replacement while the physical metadata read is suspended fails closed.
    func providerCredentialBindingAsync(recordID: String) async -> ProviderCredentialBinding? {
        guard let record = providerRecords.first(where: { $0.id == recordID }),
              record.isProviderRecord,
              let binding = await envStore.credentialBindingAsync(name: record.name),
              !Task.isCancelled,
              binding.recordID == record.id, binding.name == record.name,
              providerRecords.first(where: { $0.id == recordID }) == record else { return nil }
        return ProviderCredentialBinding(providerID: binding.recordID,
            credentialName: binding.name, revision: binding.revision)
    }

    /// A built-in receipt is valid only for the exact endpoint, wire protocol,
    /// saved model set, and opaque credential revision used by ChatStore.
    private func builtinReadinessFingerprint(for record: EnvVarEntry) -> String? {
        guard let type = ChatStore.chatProviderTypes.first(where: {
            $0.rawValue.caseInsensitiveCompare(record.name) == .orderedSame
        }),
              ChatStore.BuiltinReadinessBinding.record(for: type, in: providerRecords)?.id == record.id,
              let revision = providerCredentialBinding(recordID: record.id)?.revision else {
            return nil
        }
        return ChatStore.BuiltinReadinessBinding.fingerprint(
            record: record,
            credentialRevision: revision
        )
    }

    /// Production UI entry for an already configured, supported built-in.
    /// Missing configuration and unsupported runtime protocols stay closed.
    @discardableResult
    func checkBuiltInProviderReadiness(
        for type: ProviderType
    ) async -> SettingsProviderReadinessReport? {
        guard let record = ChatStore.BuiltinReadinessBinding.record(for: type, in: providerRecords) else {
            return nil
        }
        let revision = providerCredentialBinding(recordID: record.id)?.revision
        let report = await checkProviderReadiness(forProviderName: record.name)
        guard let current = ChatStore.BuiltinReadinessBinding.record(for: type, in: providerRecords),
              current.id == record.id,
              current.baseURL == record.baseURL,
              current.protocolType == record.protocolType,
              current.modelNames == record.modelNames,
              providerCredentialBinding(recordID: record.id)?.revision == revision else {
            invalidateProviderReadiness(for: record, checkedAt: Date())
            return nil
        }
        return report
    }

    func makeProviderCredentialControlsModel(
        recordID: String,
        pasteboard: any ProviderCredentialPasteboard = NativeProviderCredentialPasteboard()
    ) -> ProviderCredentialControlsModel? {
        guard let binding = providerCredentialBinding(recordID: recordID) else { return nil }
        return ProviderCredentialControlsModel(settings: self, binding: binding,
            currentBinding: { [weak self] in self?.providerCredentialBinding(recordID: recordID) },
            pasteboard: pasteboard)
    }

    private enum ProviderReadinessRequestResult {
        case response(ProviderReadinessTransportResponse, latency: Int)
        case failed(
            errorCategory: ProviderReadinessFailureCategory,
            latency: Int
        )
        case cancelled
        case localControl(DeepSeekMM01FieldLane.LocalControlReason)
    }

    /// U5：新增/更新一个模型供应商记录（name + apiKey + baseURL + 多个模型名
    /// + wire 协议类型）。持久化到 envvars.json（EnvVarStore 现有存储机制），
    /// API key 仍走既有 `getEnvVar`/`EnvCredentials` 读取路径。失败返回 false
    /// （变量名不合法）。
    @discardableResult
    func saveProvider(
        name: String,
        apiKey: String,
        baseURL: String?,
        modelNames: [String],
        protocolType: ProviderWireProtocol,
        modelContextWindows: [String: Int]? = nil
    ) -> Bool {
        saveProvider(
            name: name,
            credential: providerCredentialUpdate(name: name, apiKey: apiKey),
            baseURL: baseURL,
            modelNames: modelNames,
            protocolType: protocolType,
            modelContextWindows: modelContextWindows
        )
    }

    /// U5 credential-aware provider save. Metadata edits can explicitly keep
    /// the current Keychain value without reading or rewriting the secret.
    @discardableResult
    func saveProvider(
        name: String,
        credential: ProviderCredentialUpdate,
        baseURL: String?,
        modelNames: [String],
        protocolType: ProviderWireProtocol,
        displayName: String? = nil,
        modelContextWindows: [String: Int]? = nil
    ) -> Bool {
        let existingProvider = providerRecords.first {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }
        let configurationChanged = existingProvider.map {
            providerConfigurationChanged(
                existing: $0,
                credential: credential,
                baseURL: baseURL,
                modelNames: modelNames,
                protocolType: protocolType
            )
        } ?? false
        let ok = envStore.saveProvider(
            name: name,
            credential: credential,
            baseURL: baseURL,
            modelNames: modelNames,
            protocolType: protocolType,
            displayName: displayName,
            modelContextWindows: modelContextWindows
        )
        providerSaveFailure = ok
            ? nil
            : ProviderSaveFailureCategory(persistenceError: envStore.lastPersistenceError)
        reloadEnv()
        if ok, let savedProvider = providerRecords.first(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) {
            if let existingProvider, existingProvider.providerDisplayName != savedProvider.providerDisplayName {
                usageStore.renameProvider(recordID: savedProvider.id, displayName: savedProvider.providerDisplayName)
            }
            let previousCredentialVersion = providerCredentialVersions[savedProvider.name]
            let currentCredentialVersion: ProviderCredentialVersion
            if case .replace = credential {
                currentCredentialVersion = .fresh()
                providerCredentialVersions[savedProvider.name] = currentCredentialVersion
            } else {
                currentCredentialVersion = previousCredentialVersion ?? .fresh()
                providerCredentialVersions[savedProvider.name] = currentCredentialVersion
            }
            let credentialVersionChanged = previousCredentialVersion.map {
                !ProviderCredentialVersionBoundary.canReuse(
                    observed: $0,
                    current: currentCredentialVersion
                )
            } ?? false
            if configurationChanged || credentialVersionChanged {
                invalidateProviderReadinessAfterConfigurationChange(for: savedProvider)
            } else {
                syncSavedProviderModels(savedProvider)
            }
        }
        return ok
    }

    private func providerCredentialUpdate(
        name: String,
        apiKey: String
    ) -> ProviderCredentialUpdate {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // The edit sheet intentionally leaves a Keychain-backed field
            // blank.  Retention is valid for any already-persisted entry,
            // including a legacy plain environment variable being converted
            // into a provider; `providerRecords` omits that latter case.
            return envEntries.contains {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            } ? .keepExisting : .missing
        }
        // A non-empty submission is an explicit replacement.  It must never
        // probe or retain the old Keychain item, because the old item may be
        // missing or denied (the packaged-app migration case).
        return .replace(trimmed)
    }

    private func providerConfigurationChanged(
        existing: EnvVarEntry,
        credential: ProviderCredentialUpdate,
        baseURL: String?,
        modelNames: [String],
        protocolType: ProviderWireProtocol
    ) -> Bool {
        let credentialChanged: Bool
        switch credential {
        case .keepExisting:
            credentialChanged = false
        case .replace(let apiKey):
            // A loaded Keychain-backed entry intentionally keeps its value
            // empty. Treat a non-empty user submission as a replacement
            // without probing the old item: it may be missing or unreadable,
            // and the save path can create/update it directly.
            let existingAPIKey = existing.value.trimmingCharacters(in: .whitespacesAndNewlines)
            credentialChanged = existingAPIKey.isEmpty
                || existingAPIKey != apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        case .missing:
            credentialChanged = true
        }
        let existingBaseURL = existing.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextBaseURL = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        return credentialChanged
            || existingBaseURL != nextBaseURL
            || existing.protocolType != protocolType
            || normalizedModelIDs(existing.modelNames) != normalizedModelIDs(modelNames)
    }

    /// A changed credential, endpoint, protocol, or model catalog cannot reuse
    /// readiness or Apply evidence captured for the previous configuration.
    private func invalidateProviderReadinessAfterConfigurationChange(
        for provider: EnvVarEntry
    ) {
        let knownRecords = providerReadinessStore.records.filter {
            $0.providerID.caseInsensitiveCompare(provider.name) == .orderedSame
        }
        let modelIDs = Set(
            normalizedModelIDs(provider.modelNames)
                + knownRecords.map(\.modelID)
        ).sorted()
        let providerID = provider.id
        for modelID in modelIDs {
            let key = providerModelReadinessKey(providerID: providerID, modelID: modelID)
            providerModelReadinessTasks[key]?.task.cancel()
            providerModelReadinessTasks.removeValue(forKey: key)
            _ = nextProviderModelReadinessGeneration(for: key)
        }
        providerModelReadinessStates.removeValue(forKey: providerID)
        providerReadinessReports.removeValue(forKey: providerID)
        providerReadinessLocalControlMessages.removeValue(forKey: providerID)

        _ = providerReadinessStore.removeProvider(providerID: provider.name)
        let checkedAt = Date()
        for modelID in modelIDs {
            providerReadinessStore.upsert(
                ProviderReadinessPersistenceRecord(
                    providerID: provider.name,
                    modelID: modelID,
                    status: .discovered,
                    readinessState: .unverified,
                    checkedAt: checkedAt,
                    isApplied: false
                )
            )
        }
    }

    /// Make saved model rows visible to the chat projection without claiming
    /// that they passed a readiness probe.
    private func syncSavedProviderModels(_ provider: EnvVarEntry) {
        let providerID = provider.name
        let normalizedModelIDs = normalizedModelIDs(provider.modelNames)
        let knownModelIDs = Set(
            providerReadinessStore.records
                .filter {
                    $0.providerID == ProviderReadinessRevision.canonicalProviderID(providerID)
                }
                .map(\.modelID)
        )
        let checkedAt = Date()
        for modelID in normalizedModelIDs where !knownModelIDs.contains(modelID) {
            providerReadinessStore.upsert(
                ProviderReadinessPersistenceRecord(
                    providerID: providerID,
                    modelID: modelID,
                    status: .discovered,
                    readinessState: .unverified,
                    checkedAt: checkedAt,
                    isApplied: false
                )
            )
        }
        _ = providerReadinessStore.applyDiscoveredModels(
            providerID: providerID,
            modelIDs: normalizedModelIDs
        )
    }

    /// IF-07A：只探测表单中的临时 Provider 配置，不保存 key、URL 或模型目录。
    ///
    /// 目录结果必须由调用方显式应用到 draft，且仅追加去重项；手动模型不会
    /// 被本次探测或结果返回隐式替换。
    @discardableResult
    func probeProviderDraft(
        providerID: String,
        apiKey: String,
        baseURL rawBaseURL: String,
        protocolType: ProviderWireProtocol
    ) async -> ProviderDraftProbeState {
        providerDraftProbeState = .loading
        let trimmedBaseURL = rawBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        var trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        // 本机/局域网服务不需要 Key：留空时用占位值，与保存时一致。
        if trimmedAPIKey.isEmpty, ProviderEndpointPolicy.allowsBlankAPIKey(forBaseURL: trimmedBaseURL) {
            trimmedAPIKey = ProviderEndpointPolicy.localPlaceholderAPIKey
        }

        guard !trimmedAPIKey.isEmpty else {
            return finishProviderDraftProbe(.failed("获取模型列表失败：API Key 不能为空"))
        }
        guard !trimmedBaseURL.isEmpty else {
            return finishProviderDraftProbe(.failed("获取模型列表失败：Base URL 不能为空"))
        }
        guard readinessSupports(protocolType) else {
            return finishProviderDraftProbe(
                .failed("获取模型列表失败：不支持的 Provider 协议（\(protocolType.displayName)）")
            )
        }

        do {
            let validatedBaseURL = try CustomProviderURL.validate(trimmedBaseURL)
            try Task.checkCancellation()
            let response = try await providerReadinessTransport.send(
                ProviderReadinessTransportRequest(
                    operation: .modelDiscovery,
                    providerID: providerID.isEmpty ? "draft-provider" : providerID,
                    baseURL: validatedBaseURL,
                    apiKey: trimmedAPIKey,
                    modelID: nil,
                    protocolType: protocolType
                )
            )
            try Task.checkCancellation()

            guard (200..<300).contains(response.statusCode) else {
                if response.statusCode == 404 || response.statusCode == 405 {
                    return finishProviderDraftProbe(
                        .failed("获取模型列表失败：该服务没有 /models 接口，请手动填写模型名称")
                    )
                }
                return finishProviderDraftProbe(
                    .failed("获取模型列表失败（HTTP \(response.statusCode)）")
                )
            }
            if response.errorCategory == .malformedResponse {
                return finishProviderDraftProbe(
                    .failed("获取模型列表失败：返回的模型列表格式无法识别，请手动填写模型名称")
                )
            }

            let modelIDs = normalizedModelIDs(response.modelIDs)
            return finishProviderDraftProbe(
                modelIDs.isEmpty ? .empty : .loaded(modelIDs)
            )
        } catch {
            let message = ContentSecretRedactor.redact(
                error.localizedDescription,
                knownSecrets: [trimmedAPIKey]
            )
            // 界面只能显示固定文字：能归类的原因给出固定说明，其余保持原样（会被投影成类别）。
            let failure: String
            switch error {
            case let urlFailure as CustomProviderURL.Failure:
                failure = "获取模型列表失败：" + (urlFailure.errorDescription ?? "基础地址不可用")
            case SettingsProviderReadinessTransportError.unavailable:
                failure = "获取模型列表失败：当前运行配置不允许联网"
            case SettingsProviderReadinessTransportError.timeout:
                failure = "获取模型列表失败：连接超时，请检查 Base URL 或网络"
            case is URLError:
                failure = (error as? URLError)?.code == .timedOut
                    ? "获取模型列表失败：连接超时，请检查 Base URL 或网络"
                    : "获取模型列表失败：无法连接服务器，请检查 Base URL 或网络"
            default:
                failure = "获取模型列表失败：\(message)"
            }
            return finishProviderDraftProbe(
                Task.isCancelled ? .cancelled : .failed(failure)
            )
        }
    }

    func providerReadinessReport(for provider: EnvVarEntry) -> SettingsProviderReadinessReport? {
        providerReadinessReports[provider.id]
    }

    /// Reuses completed current-configuration failures; never starts a check.
    func diagnosticCachedFailures(now: Date = Date()) -> HealthReport? {
        guard now.timeIntervalSince1970.isFinite else { return nil }
        var items: [HealthItem] = []
        var observed: [Date] = []
        for (index, record) in providerRecords.enumerated() {
            guard let report = providerReadinessReports[record.id],
                  report.recordID == record.id, report.providerID == record.name,
                  let fingerprint = report.configurationFingerprint,
                  let revision = providerCredentialBinding(recordID: record.id)?.revision,
                  fingerprint == ChatStore.BuiltinReadinessBinding.fingerprint(
                    record: record, credentialRevision: revision),
                  report.checkedAt.timeIntervalSince1970.isFinite,
                  (0...600).contains(now.timeIntervalSince(report.checkedAt)) else { continue }
            let stages = [report.configuration, report.reachability, report.authentication, report.modelDiscovery]
            guard !stages.contains(where: { $0.status == .cancelled || $0.status == .loading }),
                  !report.modelChecks.contains(where: { $0.status == .cancelled || $0.status == .loading }) else { continue }
            let failed = stages.contains { $0.status == .failed }
                || report.modelChecks.contains { $0.status == .failed }
            guard failed else { continue }
            items.append(HealthItem(id: "provider-\(index)", name: "供应商已有检查",
                category: .providers, status: .error, message: "已有检查失败；请到供应商设置处理。"))
            if report.reachability.status == .failed {
                items.append(HealthItem(id: "network-\(index)", name: "已有连接检查",
                    category: .network, status: .error, message: "已有连接检查失败；请到供应商设置处理。"))
            }
            observed.append(report.checkedAt)
        }
        guard let oldest = observed.min() else { return nil }
        return HealthReport(items: items, timestamp: oldest)
    }

    /// Settings-list consumer seam.  Every input is resolved for this
    /// provider ID only, including the in-flight checking identity, so a
    /// credential/readiness failure cannot change a sibling's summary.
    func providerLocalReadinessSummary(
        for provider: EnvVarEntry
    ) -> ProviderLocalReadinessSummary {
        ProviderLocalReadinessSummary.aggregate(
            providerID: provider.id,
            report: providerReadinessReports[provider.id],
            modelStates: provider.modelNames.compactMap {
                providerModelReadiness(for: provider, modelID: $0)
            },
            isChecking: providerReadinessCheckingProviderID == provider.id
        )
    }

    func providerModelReadiness(
        for provider: EnvVarEntry,
        modelID: String
    ) -> ProviderModelReadiness? {
        let normalizedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModelID.isEmpty else { return nil }
        return providerModelReadinessStates[provider.id]?[normalizedModelID]
    }

    func providerModelReadiness(
        forProviderName name: String,
        modelID: String
    ) -> ProviderModelReadiness? {
        guard let record = providerRecords.first(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) else {
            return nil
        }
        return providerModelReadiness(for: record, modelID: modelID)
    }

    /// IF-07B：启动单个已保存模型的 readiness 检查。
    ///
    /// 任务句柄按供应商记录和模型 ID 保存，取消或重试一个模型不会触碰
    /// 其它模型的状态。实际 transport 只发该模型的最小请求，不调用供应商级
    /// readiness 检查，也不把供应商级报告当作单模型结果。
    @discardableResult
    func startProviderModelReadiness(
        forProviderName name: String,
        modelID: String
    ) -> Task<Void, Never> {
        let recordID = providerRecords.first(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        })?.id ?? name
        let key = providerModelReadinessKey(providerID: recordID, modelID: modelID)
        providerModelReadinessTasks[key]?.task.cancel()
        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.checkProviderModelReadiness(
                forProviderName: name,
                modelID: modelID
            )
            // A superseded task may finish after its replacement has started.
            // Only the current owner can remove the cancellation handle.
            if self.providerModelReadinessTasks[key]?.id == taskID {
                self.providerModelReadinessTasks.removeValue(forKey: key)
            }
        }
        providerModelReadinessTasks[key] = (id: taskID, task: task)
        return task
    }

    /// 检查某供应商已保存的全部模型，同时最多 3 个；内置官方路线走供应商级检查（本身就逐个检查模型）。
    @discardableResult
    func startCheckAllProviderModels(forProviderName name: String) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            guard let self, let record = self.providerRecords.first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) else { return }
            if ChatStore.chatProviderTypes.contains(where: {
                $0.rawValue.caseInsensitiveCompare(record.name) == .orderedSame
                    && ChatStore.BuiltinReadinessBinding.route(for: $0) != nil
            }) {
                _ = await self.startProviderReadinessAfterSave(forProviderName: name).value
                return
            }
            let modelIDs = self.normalizedModelIDs(record.modelNames)
            await Self.runLimited(modelIDs, limit: Self.checkAllConcurrencyLimit) { modelID in
                await self.startProviderModelReadiness(forProviderName: name, modelID: modelID).value
            }
        }
    }

    nonisolated static let checkAllConcurrencyLimit = 3

    /// 按并发上限依次处理一批条目：同时运行的数量不超过 limit，完成一个再补一个。
    nonisolated static func runLimited(
        _ items: [String],
        limit: Int,
        operation: @escaping @MainActor @Sendable (String) async -> Void
    ) async {
        await withTaskGroup(of: Void.self) { group in
            var iterator = items.makeIterator()
            var running = 0
            while running < max(1, limit), let item = iterator.next() {
                group.addTask { await operation(item) }
                running += 1
            }
            while await group.next() != nil {
                if let item = iterator.next() {
                    group.addTask { await operation(item) }
                }
            }
        }
    }

    /// IF-07B：检查一个已保存模型；返回值和状态只属于该模型。
    @discardableResult
    func checkProviderModelReadiness(
        forProviderName name: String,
        modelID rawModelID: String
    ) async -> ProviderModelReadiness? {
        guard let record = providerRecords.first(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) else {
            return nil
        }

        // Built-in routes require provider-level discovery and probing before
        // the saved model's Apply evidence can reach ChatStore.
        if ChatStore.chatProviderTypes.contains(where: {
            $0.rawValue.caseInsensitiveCompare(record.name) == .orderedSame
                && ChatStore.BuiltinReadinessBinding.route(for: $0) != nil
        }) {
            return nil
        }

        let modelID = rawModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty,
              record.modelNames.contains(where: {
                  $0.trimmingCharacters(in: .whitespacesAndNewlines) == modelID
              }) else {
            return nil
        }

        let key = providerModelReadinessKey(providerID: record.id, modelID: modelID)
        let previousState = providerModelReadinessStates[record.id]?[modelID]
        let generation = nextProviderModelReadinessGeneration(for: key)
        providerReadinessLocalControlMessages.removeValue(forKey: record.id)
        let checkedAt = Date()
        let lineage = providerReadinessLineage(
            providerID: record.name,
            modelID: modelID,
            checkedAt: checkedAt
        )
        storeProviderModelReadiness(
            ProviderModelReadiness(
                modelID: modelID,
                status: .loading,
                redactedResult: "",
                readiness: nil,
                lineage: lineage
            ),
            for: record.id,
            modelID: modelID,
            key: key,
            generation: generation
        )

        guard readinessSupports(record.protocolType) else {
            return storeAndPersistProviderModelReadiness(
                ProviderModelReadiness(
                    modelID: modelID,
                    status: .failed,
                    redactedResult: unsupportedProtocolDetail(record.protocolType),
                    readiness: nil,
                    errorCategory: .invalidConfiguration,
                    lineage: lineage
                ),
                for: record.id,
                modelID: modelID,
                key: key,
                generation: generation,
                persistenceProviderID: record.name
            )
        }

        let apiKey = await envStore.getEnvVarAsync(name: record.name)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let configuration = validateProviderReadinessConfiguration(
            record: record,
            apiKey: apiKey
        )
        guard let baseURL = configuration.baseURL else {
            return storeAndPersistProviderModelReadiness(
                ProviderModelReadiness(
                    modelID: modelID,
                    status: .failed,
                    redactedResult: configuration.stage.detail,
                    readiness: nil,
                    errorCategory: configurationFailureCategory(
                        apiKey: apiKey
                    ),
                    lineage: lineage
                ),
                for: record.id,
                modelID: modelID,
                key: key,
                generation: generation,
                persistenceProviderID: record.name
            )
        }

        do {
            try Task.checkCancellation()
            let result = await sendReadinessRequest(
                operation: .minimalModelRequest(modelID),
                record: record,
                baseURL: baseURL,
                apiKey: apiKey,
                modelID: modelID
            )
            try Task.checkCancellation()
            if case .localControl = result {
                guard providerModelReadinessGenerations[key] == generation else { return nil }
                providerModelReadinessStates[record.id]?[modelID] = previousState
                return previousState
            }

            guard case .response(let response, let latency) = result else {
                if case .failed(let errorCategory, let latency) = result {
                    let observationAt = Date()
                    let readiness = ProviderReadiness.evaluate(
                        providerID: record.name,
                        modelID: modelID,
                        deployment: providerReadinessDeployment,
                        probe: .unavailable,
                        credential: .available(source: record.name),
                        capabilities: [],
                        checkedAt: observationAt,
                        evidenceID: nil,
                        errorCategory: errorCategory,
                        latency: latency,
                        lineage: lineage
                    )
                    return storeAndPersistProviderModelReadiness(
                        ProviderModelReadiness(
                            modelID: modelID,
                            status: .failed,
                            redactedResult: "最小请求失败",
                            readiness: readiness,
                            errorCategory: errorCategory,
                            latency: latency,
                            lineage: lineage
                        ),
                        for: record.id,
                        modelID: modelID,
                        key: key,
                        generation: generation,
                        persistenceProviderID: record.name
                    )
                }
                throw CancellationError()
            }

            let passed = (200..<300).contains(response.statusCode)
                && response.errorCategory == nil
            let errorCategory = passed
                ? nil
                : response.errorCategory ?? readinessFailureCategory(
                    statusCode: response.statusCode
                )
            let redactedBody = ContentSecretRedactor.redact(
                response.body,
                knownSecrets: [apiKey]
            )
            let detail = redactedBody.isEmpty
                ? (passed ? "最小请求通过" : "最小请求失败（HTTP \(response.statusCode)）")
                : redactedBody
            let observationAt = Date()
            let readiness = ProviderReadiness.evaluate(
                providerID: record.name,
                modelID: modelID,
                deployment: providerReadinessDeployment,
                probe: .reachable,
                credential: .available(source: record.name),
                capabilities: [],
                checkedAt: observationAt,
                evidenceID: passed
                    ? readinessEvidenceID(
                        providerID: record.name,
                        modelID: modelID,
                        statusCode: response.statusCode,
                        checkedAt: observationAt
                    )
                    : nil,
                errorCategory: errorCategory,
                latency: latency,
                lineage: lineage
            )
            return storeAndPersistProviderModelReadiness(
                ProviderModelReadiness(
                    modelID: modelID,
                    status: passed ? .passed : .failed,
                    redactedResult: detail,
                    readiness: readiness,
                    errorCategory: errorCategory,
                    latency: latency,
                    lineage: lineage
                ),
                for: record.id,
                modelID: modelID,
                key: key,
                generation: generation,
                persistenceProviderID: record.name
            )
        } catch is CancellationError {
            let cancelled = ProviderModelReadiness(
                modelID: modelID,
                status: .cancelled,
                redactedResult: "已取消",
                readiness: nil,
                lineage: lineage
            )
            return storeAndPersistProviderModelReadiness(
                cancelled,
                for: record.id,
                modelID: modelID,
                key: key,
                generation: generation,
                persistenceProviderID: record.name
            )
        } catch {
            let detail = ContentSecretRedactor.redact(
                error.localizedDescription,
                knownSecrets: [apiKey]
            )
            let errorCategory = readinessFailureCategory(error)
            return storeAndPersistProviderModelReadiness(
                ProviderModelReadiness(
                    modelID: modelID,
                    status: .failed,
                    redactedResult: detail.isEmpty ? "最小请求失败" : detail,
                    readiness: ProviderReadiness.evaluate(
                        providerID: record.name,
                        modelID: modelID,
                        deployment: providerReadinessDeployment,
                        probe: .unavailable,
                        credential: .available(source: record.name),
                        capabilities: [],
                        checkedAt: Date(),
                        evidenceID: nil,
                        errorCategory: errorCategory,
                        lineage: lineage
                    ),
                    errorCategory: errorCategory,
                    lineage: lineage
                ),
                for: record.id,
                modelID: modelID,
                key: key,
                generation: generation,
                persistenceProviderID: record.name
            )
        }
    }

    /// IF-07B：取消单个模型的当前任务，并将其标记为 cancelled。
    func cancelProviderModelReadiness(
        forProviderName name: String,
        modelID rawModelID: String
    ) {
        guard let record = providerRecords.first(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) else {
            return
        }
        let modelID = rawModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else { return }
        let key = providerModelReadinessKey(providerID: record.id, modelID: modelID)
        providerModelReadinessTasks[key]?.task.cancel()
        providerModelReadinessTasks.removeValue(forKey: key)
        let generation = nextProviderModelReadinessGeneration(for: key)
        _ = storeAndPersistProviderModelReadiness(
            ProviderModelReadiness(
                modelID: modelID,
                status: .cancelled,
                redactedResult: "已取消",
                readiness: nil,
                lineage: providerReadinessLineage(
                    providerID: record.name,
                    modelID: modelID,
                    checkedAt: Date()
                )
            ),
            for: record.id,
            modelID: modelID,
            key: key,
            generation: generation,
            persistenceProviderID: record.name
        )
    }

    private func providerModelReadinessKey(providerID: String, modelID: String) -> String {
        "\(providerID)\u{001F}\(modelID.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    private func nextProviderModelReadinessGeneration(for key: String) -> Int {
        let next = (providerModelReadinessGenerations[key] ?? 0) + 1
        providerModelReadinessGenerations[key] = next
        return next
    }

    @discardableResult
    private func storeProviderModelReadiness(
        _ state: ProviderModelReadiness,
        for providerID: String,
        modelID: String,
        key: String,
        generation: Int
    ) -> ProviderModelReadiness {
        guard providerModelReadinessGenerations[key] == generation else {
            return providerModelReadinessStates[providerID]?[modelID] ?? state
        }
        providerModelReadinessStates[providerID, default: [:]][modelID] = state
        return state
    }

    @discardableResult
    private func storeAndPersistProviderModelReadiness(
        _ state: ProviderModelReadiness,
        for providerID: String,
        modelID: String,
        key: String,
        generation: Int,
        persistenceProviderID: String
    ) -> ProviderModelReadiness {
        let incomingModelID = state.modelID
        let guided = Self.readinessStateWithFailureGuidance(
            state,
            hasPriorPassed: providerReadinessStore.records.contains {
                $0.providerID.caseInsensitiveCompare(persistenceProviderID) == .orderedSame
                    && $0.modelID == incomingModelID && $0.status == .passed
            }
        )
        let stored = storeProviderModelReadiness(
            guided,
            for: providerID,
            modelID: modelID,
            key: key,
            generation: generation
        )
        persistProviderModelReadiness(
            stored,
            providerID: persistenceProviderID,
            generation: generation,
            key: key
        )
        return stored
    }

    /// 失败结果的用户提示：最小请求失败时按失败类别写“原因 + 下一步”（接 HTTPStatusMessages.providerReadinessMessage）；
    /// 瞬时故障且此前已有通过结果时，写明“最近一次检查失败”，此前的通过结果仍保留。
    nonisolated static func readinessStateWithFailureGuidance(
        _ state: ProviderModelReadiness,
        hasPriorPassed: Bool
    ) -> ProviderModelReadiness {
        guard state.status == .failed, let category = state.errorCategory else { return state }
        let message = HTTPStatusMessages.providerReadinessMessage(for: category)
        let guidance = "\(message.zh)。\(message.suggestionZH)"
        let isGenericFailure = state.redactedResult.hasPrefix("最小请求失败")
        let text: String
        if category.isTransient, hasPriorPassed {
            text = "最近一次检查失败：\(message.zh)，此前的检查结果仍保留，可稍后重试"
        } else if isGenericFailure {
            text = guidance
        } else {
            return state
        }
        return ProviderModelReadiness(
            modelID: state.modelID, status: state.status, redactedResult: text,
            readiness: state.readiness, errorCategory: state.errorCategory,
            latency: state.latency, lineage: state.lineage
        )
    }

    /// Persist only terminal model facts. The generation guard prevents a
    /// cancelled or superseded task from overwriting a retry's result.
    private func persistProviderModelReadiness(
        _ state: ProviderModelReadiness,
        providerID: String,
        generation: Int,
        key: String
    ) {
        guard providerModelReadinessGenerations[key] == generation else { return }
        let status: ProviderReadinessPersistenceStatus
        switch state.status {
        case .passed:
            status = .passed
        case .failed, .cancelled:
            // 瞬时故障：此前通过的结果保留不动；没有旧结果的标“未验证”（可重试），不当作配置错误阻断。
            if state.status == .failed, state.errorCategory?.isTransient == true {
                if providerReadinessStore.records.contains(where: {
                    $0.providerID.caseInsensitiveCompare(providerID) == .orderedSame
                        && $0.modelID == state.modelID && $0.status == .passed
                }) { return }
                status = .unverified
            } else {
                status = .unavailable
            }
        case .loading, .notRun:
            return
        }
        providerReadinessStore.upsert(
            ProviderReadinessPersistenceRecord(
                providerID: providerID,
                modelID: state.modelID,
                status: status,
                readinessState: status == .unverified ? .unverified : (state.readiness?.state ?? .blocked),
                checkedAt: state.readiness?.checkedAt ?? Date(),
                errorCategory: state.errorCategory,
                latency: state.latency,
                evidenceID: state.readiness?.evidenceID,
                isApplied: true,
                discoveryReceiptID: state.lineage.discoveryReceiptID,
                discoveredAt: state.lineage.discoveredAt,
                applyReceiptID: state.lineage.applyReceiptID,
                appliedAt: state.lineage.appliedAt
            )
        )
    }

    /// Explicit user-save follow-up. Reuse the existing provider probe and its
    /// redaction, credential binding, generation and durable receipt checks.
    /// Administrative saveProvider callers do not implicitly start network I/O.
    @discardableResult
    func startProviderReadinessAfterSave(forProviderName name: String) -> Task<SettingsProviderReadinessReport?, Never> {
        let key = EnvVarStore.canonicalName(name)
        savedProviderReadinessTasks[key]?.task.cancel()
        let requestID = UUID()
        let task = Task<SettingsProviderReadinessReport?, Never> { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return nil }
            let report = await self.checkProviderReadiness(forProviderName: name)
            if self.savedProviderReadinessTasks[key]?.id == requestID {
                self.savedProviderReadinessTasks.removeValue(forKey: key)
            }
            return report
        }
        savedProviderReadinessTasks[key] = (id: requestID, task: task)
        return task
    }

    @discardableResult
    func checkProviderReadiness(
        forProviderName name: String
    ) async -> SettingsProviderReadinessReport? {
        guard let record = providerRecords.first(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) else {
            return nil
        }
        let startingBindingRevision = providerCredentialBinding(recordID: record.id)?.revision
        let reportFingerprint = startingBindingRevision.map {
            ChatStore.BuiltinReadinessBinding.fingerprint(record: record, credentialRevision: $0)
        }
        let previousReport = providerReadinessReports[record.id]
        providerReadinessLocalControlMessages.removeValue(forKey: record.id)
        let generation = UUID()
        providerReadinessProbeGenerations[record.id] = generation
        defer {
            if providerReadinessProbeGenerations[record.id] == generation {
                providerReadinessProbeGenerations.removeValue(forKey: record.id)
                if providerReadinessCheckingProviderID == record.id {
                    isCheckingProviderReadiness = false
                    providerReadinessCheckingProviderID = nil
                }
            }
        }
        // Every awaited stage must still belong to this probe and this saved
        // configuration before it can publish success or invalidate readiness.
        // Reuse the actual credential binding; this adds no authorization path.
        func isCurrentProbe(allowCancelledResult: Bool = false) -> Bool {
            // A current probe may settle an actual typed cancellation. It may
            // never publish a late success or borrow a replaced probe's identity.
            guard (!Task.isCancelled || allowCancelledResult),
                  providerReadinessProbeGenerations[record.id] == generation,
                  let current = providerRecords.first(where: { $0.id == record.id }),
                  current.name == record.name,
                  current.baseURL == record.baseURL,
                  current.protocolType == record.protocolType,
                  current.modelNames == record.modelNames,
                  providerCredentialBinding(recordID: record.id)?.revision == startingBindingRevision else {
                return false
            }
            return true
        }

        func isCancelledResult(_ result: ProviderReadinessRequestResult) -> Bool {
            if case .cancelled = result { return true }
            return false
        }

        guard isCurrentProbe() else { return nil }
        guard readinessSupports(record.protocolType) else {
            let checkedAt = Date()
            var report = SettingsProviderReadinessReport(
                recordID: record.id,
                providerID: record.name,
                checkedAt: checkedAt,
                configuration: ProviderReadinessStage(
                    status: .failed,
                    detail: unsupportedProtocolDetail(record.protocolType),
                    statusCode: nil
                ),
                reachability: notRunStage,
                authentication: notRunStage,
                modelDiscovery: notRunStage,
                discoveredModelIDs: [],
                modelChecks: [],
                state: .blocked,
                redactedResult: unsupportedProtocolDetail(record.protocolType)
            )
            invalidateProviderReadiness(
                for: record,
                checkedAt: checkedAt,
                errorCategory: .invalidConfiguration
            )
            report.configurationFingerprint = reportFingerprint
            providerReadinessReports[record.id] = report
            return report
        }

        isCheckingProviderReadiness = true
        providerReadinessCheckingProviderID = record.id

        let checkedAt = Date()
        let apiKey = await envStore.getEnvVarAsync(name: record.name)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Async Keychain resolution refreshes EnvVarStore's in-memory secret.
        // Publish that exact value to the live ChatStore directory before a
        // passed receipt can make the built-in route selectable.
        reloadEnv()
        guard isCurrentProbe() else { return nil }
        guard let current = providerRecords.first(where: { $0.id == record.id }),
              current.name == record.name,
              current.baseURL == record.baseURL,
              current.protocolType == record.protocolType,
              current.modelNames == record.modelNames,
              current.value.trimmingCharacters(in: .whitespacesAndNewlines) == apiKey else {
            invalidateProviderReadiness(for: record, checkedAt: Date())
            return nil
        }
        let configuration = validateProviderReadinessConfiguration(
            record: record,
            apiKey: apiKey
        )
        guard let baseURL = configuration.baseURL else {
            var report = SettingsProviderReadinessReport(
                recordID: record.id,
                providerID: record.name,
                checkedAt: checkedAt,
                configuration: configuration.stage,
                reachability: notRunStage,
                authentication: notRunStage,
                modelDiscovery: notRunStage,
                discoveredModelIDs: [],
                modelChecks: [],
                state: .blocked,
                redactedResult: redactedReadinessResult("", apiKey: apiKey)
            )
            invalidateProviderReadiness(
                for: record,
                checkedAt: checkedAt,
                errorCategory: configurationFailureCategory(
                    apiKey: apiKey
                )
            )
            report.configurationFingerprint = reportFingerprint
            providerReadinessReports[record.id] = report
            return report
        }

        var resultLines: [String] = []
        let reachabilityResponse = await sendReadinessRequest(
            operation: .reachability,
            record: record,
            baseURL: baseURL,
            apiKey: apiKey
        )
        guard isCurrentProbe(allowCancelledResult: isCancelledResult(reachabilityResponse)) else { return nil }
        if case .localControl = reachabilityResponse { return previousReport }
        // 可达只看有没有收到 HTTP 响应：401/403/404/429/5xx 也说明服务端可达，
        // 具体问题交给后面的鉴权与模型阶段说明（11/16 现场：错 Key 被报成"不可达"）。
        let reachability = stage(
            from: reachabilityResponse,
            success: { (100..<600).contains($0) },
            successDetail: "服务端可达",
            failureDetail: "未收到有效 HTTP 响应",
            apiKey: apiKey,
            resultLines: &resultLines,
            anyHTTPResponsePasses: true
        )
        guard reachability.status == .passed else {
            var report = SettingsProviderReadinessReport(
                recordID: record.id,
                providerID: record.name,
                checkedAt: checkedAt,
                configuration: configuration.stage,
                reachability: reachability,
                authentication: notRunStage,
                modelDiscovery: notRunStage,
                discoveredModelIDs: [],
                modelChecks: [],
                state: .blocked,
                redactedResult: redactedReadinessResult(
                    resultLines.joined(separator: "\n"),
                    apiKey: apiKey
                )
            )
            invalidateProviderReadiness(
                for: record,
                checkedAt: checkedAt,
                errorCategory: readinessFailureCategory(from: reachabilityResponse)
            )
            report.configurationFingerprint = reportFingerprint
            providerReadinessReports[record.id] = report
            return report
        }

        // 手动填写的模型：服务没有 /models 时，用它们做一次最小对话请求代替鉴权与模型发现。
        let manualModelIDs = normalizedModelIDs(record.modelNames)
        var authenticationResponse = await sendReadinessRequest(
            operation: .authentication,
            record: record,
            baseURL: baseURL,
            apiKey: apiKey
        )
        guard isCurrentProbe(allowCancelledResult: isCancelledResult(authenticationResponse)) else { return nil }
        if case .localControl = authenticationResponse { return previousReport }
        // 很多中转站没有 /models（返回 404/405）：这不是鉴权失败，改用一次最小对话请求判断。
        var modelListEndpointMissing = false
        if isModelListEndpointMissing(authenticationResponse), let probeModelID = manualModelIDs.first {
            modelListEndpointMissing = true
            authenticationResponse = await sendReadinessRequest(
                operation: .minimalModelRequest(probeModelID),
                record: record,
                baseURL: baseURL,
                apiKey: apiKey,
                modelID: probeModelID
            )
            guard isCurrentProbe(allowCancelledResult: isCancelledResult(authenticationResponse)) else { return nil }
            if case .localControl = authenticationResponse { return previousReport }
        }
        let authentication = stage(
            from: authenticationResponse,
            success: { (200..<300).contains($0) },
            successDetail: modelListEndpointMissing ? "鉴权通过（该服务没有 /models，已用一次对话请求确认）" : "鉴权通过",
            failureDetail: !modelListEndpointMissing && isModelListEndpointMissing(authenticationResponse)
                ? "该服务没有 /models 接口，且还没有填写模型名称，无法判断鉴权；请先填写至少一个模型名称"
                : "鉴权失败",
            apiKey: apiKey,
            resultLines: &resultLines
        )
        guard authentication.status == .passed else {
            var report = SettingsProviderReadinessReport(
                recordID: record.id,
                providerID: record.name,
                checkedAt: checkedAt,
                configuration: configuration.stage,
                reachability: reachability,
                authentication: authentication,
                modelDiscovery: notRunStage,
                discoveredModelIDs: [],
                modelChecks: [],
                state: .blocked,
                redactedResult: redactedReadinessResult(
                    resultLines.joined(separator: "\n"),
                    apiKey: apiKey
                )
            )
            invalidateProviderReadiness(
                for: record,
                checkedAt: checkedAt,
                errorCategory: readinessFailureCategory(from: authenticationResponse)
            )
            report.configurationFingerprint = reportFingerprint
            providerReadinessReports[record.id] = report
            return report
        }

        var discoveryResponse: ProviderReadinessRequestResult = .failed(errorCategory: .notFound, latency: 0)
        if !modelListEndpointMissing {
            discoveryResponse = await sendReadinessRequest(
                operation: .modelDiscovery,
                record: record,
                baseURL: baseURL,
                apiKey: apiKey
            )
            guard isCurrentProbe(allowCancelledResult: isCancelledResult(discoveryResponse)) else { return nil }
            if case .localControl = discoveryResponse { return previousReport }
        }
        var discoveredModelIDs: [String]
        if case .response(let response, _) = discoveryResponse, !modelListEndpointMissing {
            let discovered = normalizedModelIDs(response.modelIDs)
            discoveredModelIDs = mm01FieldLane.map { $0.discoverySubset(discovered, record: record) } ?? discovered
        } else {
            discoveredModelIDs = []
        }
        // 没有可用的模型目录（404/405/非 JSON）但用户填了模型：跳过发现，直接检查已填写的模型。
        let skipDiscovery = !manualModelIDs.isEmpty
            && (modelListEndpointMissing || isModelListUnusable(discoveryResponse))
        let modelDiscovery: ProviderReadinessStage
        if skipDiscovery {
            modelDiscovery = ProviderReadinessStage(
                status: .passed,
                detail: "该服务没有可用的模型列表，使用已填写的模型",
                statusCode: nil
            )
            discoveredModelIDs = []
        } else {
            modelDiscovery = stage(
                from: discoveryResponse,
                success: { (200..<300).contains($0) && !discoveredModelIDs.isEmpty },
                successDetail: "发现 \(discoveredModelIDs.count) 个模型",
                failureDetail: discoveryFailureDetail(discoveryResponse, discoveredIsEmpty: discoveredModelIDs.isEmpty),
                apiKey: apiKey,
                resultLines: &resultLines
            )
        }
        guard modelDiscovery.status == .passed else {
            var report = SettingsProviderReadinessReport(
                recordID: record.id,
                providerID: record.name,
                checkedAt: checkedAt,
                configuration: configuration.stage,
                reachability: reachability,
                authentication: authentication,
                modelDiscovery: modelDiscovery,
                discoveredModelIDs: discoveredModelIDs,
                modelChecks: [],
                state: .unverified,
                redactedResult: redactedReadinessResult(
                    resultLines.joined(separator: "\n"),
                    apiKey: apiKey
                )
            )
            invalidateProviderReadiness(
                for: record,
                checkedAt: checkedAt,
                errorCategory: readinessFailureCategory(from: discoveryResponse)
            )
            report.configurationFingerprint = reportFingerprint
            providerReadinessReports[record.id] = report
            return report
        }

        let modelCheckResult = await checkModels(
            modelIDsToCheck(manual: manualModelIDs, discovered: discoveredModelIDs),
            record: record,
            baseURL: baseURL,
            apiKey: apiKey,
            checkedAt: checkedAt
        )
        guard isCurrentProbe(allowCancelledResult: modelCheckResult.checks.contains { $0.status == .cancelled }) else { return nil }
        if modelCheckResult.localControl { return previousReport }
        let modelChecks = modelCheckResult.checks
        resultLines.append(contentsOf: modelCheckResult.resultLines)
        let state: ProviderReadinessState = modelChecks.allSatisfy { $0.status == .passed }
            ? successfulProviderReadinessState
            : .unverified
        var report = SettingsProviderReadinessReport(
            recordID: record.id,
            providerID: record.name,
            checkedAt: checkedAt,
            configuration: configuration.stage,
            reachability: reachability,
            authentication: authentication,
            modelDiscovery: modelDiscovery,
            discoveredModelIDs: discoveredModelIDs,
            modelChecks: modelChecks,
            state: state,
            redactedResult: redactedReadinessResult(
                resultLines.joined(separator: "\n"),
                apiKey: apiKey
            )
        )
        if ChatStore.chatProviderTypes.contains(where: {
            $0.rawValue.caseInsensitiveCompare(record.name) == .orderedSame
                && ChatStore.BuiltinReadinessBinding.route(for: $0) != nil
        }) {
            guard let current = providerRecords.first(where: { $0.id == record.id }),
                  current.name == record.name,
                  current.baseURL == record.baseURL,
                  current.protocolType == record.protocolType,
                  current.modelNames == record.modelNames,
                  let startingBindingRevision,
                  providerCredentialBinding(recordID: record.id)?.revision == startingBindingRevision else {
                return nil
            }
        }
        persistProviderReadinessReport(report, for: record)
        report.configurationFingerprint = reportFingerprint
        providerReadinessReports[record.id] = report
        return report
    }

    /// Project the provider-level report into the same per-model store used by
    /// the chat picker. Newly discovered IDs stay pending until saved/applied.
    private func persistProviderReadinessReport(
        _ report: SettingsProviderReadinessReport,
        for provider: EnvVarEntry
    ) {
        // 某个模型这次只是瞬时失败（限流、超时、5xx）：此前通过的结果保留，不被推翻。
        let previouslyPassed = Set(providerReadinessStore.records.filter {
            $0.providerID.caseInsensitiveCompare(provider.name) == .orderedSame && $0.status == .passed
        }.map(\.modelID))
        let preservedModelIDs = Set(report.modelChecks.filter {
            $0.status == .failed && $0.errorCategory?.isTransient == true
                && previouslyPassed.contains($0.modelID)
        }.map(\.modelID))
        let appliedModelIDs = Set(normalizedModelIDs(provider.modelNames))
        // 这次没测的模型（只抽测少数几个）不参与失效标记，保留旧记录；没有旧记录的就是“未检查”。
        let checkedModelIDs = Set(report.modelChecks.map(\.modelID))
        let knownModelIDs = Set(providerReadinessStore.records.filter {
            $0.providerID.caseInsensitiveCompare(provider.name) == .orderedSame
        }.map(\.modelID)).union(appliedModelIDs)
        let untestedModelIDs = knownModelIDs.subtracting(checkedModelIDs)
        invalidateProviderReadiness(
            for: provider, checkedAt: report.checkedAt,
            preserving: preservedModelIDs.union(untestedModelIDs))
        let configurationFingerprint = builtinReadinessFingerprint(for: provider)
        // 目录里发现但没有测、也没有旧记录的模型：标“未检查”，进入选择器的待应用列表。
        for modelID in normalizedModelIDs(report.discoveredModelIDs)
        where !checkedModelIDs.contains(modelID) && !knownModelIDs.contains(modelID) {
            providerReadinessStore.upsert(
                ProviderReadinessPersistenceRecord(
                    providerID: provider.name,
                    modelID: modelID,
                    status: .discovered,
                    readinessState: .unverified,
                    checkedAt: report.checkedAt,
                    isApplied: false
                )
            )
        }
        for model in report.modelChecks {
            if preservedModelIDs.contains(model.modelID) { continue }
            let transientFailure = model.status == .failed && model.errorCategory?.isTransient == true
            let status: ProviderReadinessPersistenceStatus =
                model.status == .passed ? .passed : (transientFailure ? .unverified : .unavailable)
            providerReadinessStore.upsert(
                ProviderReadinessPersistenceRecord(
                    providerID: provider.name,
                    modelID: model.modelID,
                    status: status,
                    readinessState: transientFailure ? .unverified : (model.readiness?.state
                        ?? (status == .passed ? report.state : .blocked)),
                    checkedAt: model.readiness?.checkedAt ?? report.checkedAt,
                    errorCategory: model.errorCategory,
                    latency: model.latency,
                    evidenceID: model.readiness?.evidenceID,
                    isApplied: appliedModelIDs.contains(model.modelID),
                    discoveryReceiptID: model.lineage.discoveryReceiptID,
                    discoveredAt: model.lineage.discoveredAt,
                    applyReceiptID: model.lineage.applyReceiptID,
                    appliedAt: model.lineage.appliedAt,
                    configurationFingerprint: configurationFingerprint
                )
            )
        }
    }

    /// Provider-level failures invalidate the chat picker projection without
    /// changing the independent model-level readiness state.
    private func invalidateProviderReadiness(
        for provider: EnvVarEntry,
        checkedAt: Date,
        errorCategory: ProviderReadinessFailureCategory? = nil,
        latency: Int? = nil,
        preserving preservedModelIDs: Set<String> = []
    ) {
        let appliedModelIDs = Set(normalizedModelIDs(provider.modelNames))
        let knownRecords = providerReadinessStore.records.filter {
            $0.providerID.caseInsensitiveCompare(provider.name) == .orderedSame
        }
        let modelIDs = appliedModelIDs.union(knownRecords.map(\.modelID))
        // 瞬时故障（限流、超时、5xx、网络不通）不推翻此前的通过结果；没有旧结果的标“未验证”，可重试。
        let isTransient = errorCategory?.isTransient == true

        for modelID in modelIDs {
            if preservedModelIDs.contains(modelID) { continue }
            let existing = knownRecords.first { $0.modelID == modelID }
            if isTransient, existing?.status == .passed { continue }
            let lineage = existing?.lineage ?? providerReadinessLineage(
                providerID: provider.name,
                modelID: modelID,
                checkedAt: checkedAt
            )
            providerReadinessStore.upsert(
                ProviderReadinessPersistenceRecord(
                    providerID: provider.name,
                    modelID: modelID,
                    status: isTransient ? .unverified : .unavailable,
                    readinessState: isTransient ? .unverified : .blocked,
                    checkedAt: checkedAt,
                    errorCategory: errorCategory,
                    latency: latency,
                    evidenceID: nil,
                    isApplied: existing?.isApplied ?? appliedModelIDs.contains(modelID),
                    discoveryReceiptID: lineage.discoveryReceiptID,
                    discoveredAt: lineage.discoveredAt,
                    applyReceiptID: lineage.applyReceiptID,
                    appliedAt: lineage.appliedAt
                )
            )
        }
    }

    private func readinessSupports(_ protocolType: ProviderWireProtocol) -> Bool {
        switch protocolType {
        case .openaiCompatible, .openaiResponses, .anthropic:
            return true
        case .other:
            return false
        }
    }

    private func unsupportedProtocolDetail(_ protocolType: ProviderWireProtocol) -> String {
        "Provider 协议不支持 readiness：\(protocolType.displayName)"
    }

    private var notRunStage: ProviderReadinessStage {
        ProviderReadinessStage(status: .notRun, detail: "未执行", statusCode: nil)
    }

    private func validateProviderReadinessConfiguration(
        record: EnvVarEntry,
        apiKey: String
    ) -> (stage: ProviderReadinessStage, baseURL: URL?) {
        var failures: [String] = []
        guard !apiKey.isEmpty else {
            failures.append("API Key 缺失")
            return (
                ProviderReadinessStage(status: .failed, detail: failures.joined(separator: "；"), statusCode: nil),
                nil
            )
        }
        // 基础地址留空：有预设就用预设默认地址（与新增表单的“可选”提示一致）。
        let configuredBaseURL = record.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rawBaseURL = (configuredBaseURL?.isEmpty == false ? configuredBaseURL : nil)
            ?? ProviderPreset.defaultBaseURL(forCredentialName: record.name) else {
            failures.append("未填写基础地址：该服务没有默认地址，请在编辑里填写服务商提供的地址")
            return (
                ProviderReadinessStage(status: .failed, detail: failures.joined(separator: "；"), statusCode: nil),
                nil
            )
        }
        do {
            let baseURL = try CustomProviderURL.validate(rawBaseURL)
            return (
                ProviderReadinessStage(status: .passed, detail: "配置有效", statusCode: nil),
                baseURL
            )
        } catch {
            failures.append("基础地址无效：\(UserFacingErrorText.describe(error))")
            return (
                ProviderReadinessStage(status: .failed, detail: failures.joined(separator: "；"), statusCode: nil),
                nil
            )
        }
    }

    private func providerReadinessLineage(
        providerID: String,
        modelID: String,
        checkedAt: Date
    ) -> ProviderReadinessLineage {
        providerReadinessStore.records.first {
            $0.providerID.caseInsensitiveCompare(providerID) == .orderedSame
                && $0.modelID == modelID
        }?.lineage
            ?? ProviderReadinessLineage.derived(
                providerID: providerID,
                modelID: modelID,
                checkedAt: checkedAt
            )
    }

    private func configurationFailureCategory(
        apiKey: String
    ) -> ProviderReadinessFailureCategory {
        if apiKey.isEmpty {
            return .missingCredential
        }
        return .invalidConfiguration
    }

    private func readinessFailureCategory(
        statusCode: Int
    ) -> ProviderReadinessFailureCategory {
        switch statusCode {
        case 400, 422:
            return .invalidConfiguration
        case 401:
            return .unauthorized
        case 402, 403:
            // 402 = 余额或额度不足，与无权限同属“账户侧问题”，提示里写明检查余额。
            return .permissionDenied
        case 404:
            return .notFound
        case 408:
            return .timeout
        case 429:
            return .rateLimited
        case 500...:
            return .server
        default:
            return .transport
        }
    }

    private func readinessFailureCategory(
        _ error: Error
    ) -> ProviderReadinessFailureCategory {
        if let failure = error as? DeepSeekMM01FieldLane.ReadinessHTTPFailure {
            return failure.errorCategory ?? readinessFailureCategory(statusCode: failure.statusCode)
        }
        if let error = error as? SettingsProviderReadinessTransportError {
            switch error {
            case .missingCredential:
                return .missingCredential
            case .invalidURL:
                return .invalidConfiguration
            case .timeout:
                return .timeout
            case .redirectRejected, .invalidResponse:
                return error == .invalidResponse ? .malformedResponse : .transport
            case .unavailable:
                return .unavailable
            }
        }
        return .transport
    }

    private func readinessFailureCategory(
        from result: ProviderReadinessRequestResult
    ) -> ProviderReadinessFailureCategory? {
        switch result {
        case .cancelled, .localControl:
            return nil
        case .failed(let category, _):
            return category
        case .response(let response, _):
            guard !(200..<300).contains(response.statusCode) else {
                return response.errorCategory
            }
            return response.errorCategory ?? readinessFailureCategory(
                statusCode: response.statusCode
            )
        }
    }

    /// /models 不存在：404 或 405。
    private func isModelListEndpointMissing(_ result: ProviderReadinessRequestResult) -> Bool {
        guard case .response(let response, _) = result else { return false }
        return response.statusCode == 404 || response.statusCode == 405
    }

    /// 模型目录不可用：404/405，或 2xx 但返回的不是可解析的目录（例如 HTML 页面）。
    private func isModelListUnusable(_ result: ProviderReadinessRequestResult) -> Bool {
        guard case .response(let response, _) = result else { return false }
        if response.statusCode == 404 || response.statusCode == 405 { return true }
        return (200..<300).contains(response.statusCode) && response.errorCategory == .malformedResponse
    }

    private func discoveryFailureDetail(
        _ result: ProviderReadinessRequestResult,
        discoveredIsEmpty: Bool
    ) -> String {
        if case .response(let response, _) = result {
            if response.errorCategory == .malformedResponse {
                return "模型列表格式无法识别（不是常见的 OpenAI 或 Anthropic 目录格式），请手动填写模型名称"
            }
            if isModelListUnusable(result) {
                return "该服务没有 /models 接口，请手动填写模型名称"
            }
        }
        return discoveredIsEmpty ? "模型发现返回空目录" : "模型发现失败"
    }

    /// 只对少量模型发真实请求，不逐个全测：已填写（已应用）的模型里出现在目录中的，
    /// 最多 3 个；已填写的模型都不在目录里时，直接测已填写的前 3 个（不拿目录里的别的模型顶替）；
    /// 什么都没填写才取目录里的第一个。
    func modelIDsToCheck(manual: [String], discovered: [String]) -> [String] {
        let limit = 3
        if discovered.isEmpty { return Array(manual.prefix(limit)) }
        let discoveredSet = Set(discovered)
        // 抽测优先挑名字像聊天模型的，避免抽到向量/语音模型而把整家误判失败。
        let saved = manual.filter { discoveredSet.contains($0) }
        if !saved.isEmpty {
            let chatLike = saved.filter { !ProviderModelNameHeuristics.likelyNonChat($0) }
            return Array((chatLike.isEmpty ? saved : chatLike).prefix(limit))
        }
        if !manual.isEmpty { return Array(manual.prefix(limit)) }
        let first = discovered.first { !ProviderModelNameHeuristics.likelyNonChat($0) } ?? discovered[0]
        return [first]
    }

    /// 408、429 和 5xx 视为偶发故障，检查内可重试。
    private static func isTransientReadinessStatus(_ statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode)
    }

    private func sendReadinessRequest(
        operation: ProviderReadinessOperation,
        record: EnvVarEntry,
        baseURL: URL,
        apiKey: String,
        modelID: String? = nil
    ) async -> ProviderReadinessRequestResult {
        var request = ProviderReadinessTransportRequest(
            operation: operation,
            providerID: record.name,
            baseURL: baseURL,
            apiKey: apiKey,
            modelID: modelID,
            protocolType: record.protocolType
        )
        if mm01FieldLane?.requiresOwnedOutboundAudit == true {
            request.ownedMMAction = OwnedMMOutboundContext.action
        }
        let startedAt = DispatchTime.now().uptimeNanoseconds
        do {
            try Task.checkCancellation()
            // 偶发的 429、超时、5xx 在检查内重试最多 2 次（间隔 0.5 秒、1.5 秒），
            // 不因一次抖动把模型锁成不可用；401/403/404/400 等确定性失败不重试。
            var response: ProviderReadinessTransportResponse
            var transientRetries = 0
            // 受控现场通道要求请求数精确，不做重试。
            let maxTransientRetries = mm01FieldLane == nil ? 2 : 0
            while true {
                do {
                    response = try await providerReadinessTransport.send(request)
                } catch SettingsProviderReadinessTransportError.timeout where transientRetries < maxTransientRetries {
                    try await Task.sleep(nanoseconds: transientRetries == 0 ? 500_000_000 : 1_500_000_000)
                    try Task.checkCancellation()
                    transientRetries += 1
                    continue
                }
                // 余额或额度不足（传输层已归入 permissionDenied）不是偶发故障，不重试。
                if transientRetries < maxTransientRetries, response.errorCategory != .permissionDenied,
                   Self.isTransientReadinessStatus(response.statusCode) {
                    try await Task.sleep(nanoseconds: transientRetries == 0 ? 500_000_000 : 1_500_000_000)
                    try Task.checkCancellation()
                    transientRetries += 1
                    continue
                }
                break
            }
            try Task.checkCancellation()
            let elapsed = Int(
                (DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
            )
            return .response(
                response,
                latency: max(0, response.latency ?? elapsed)
            )
        } catch is CancellationError {
            return .cancelled
        } catch {
            if let reason = mm01FieldLane?.localControlReason(for: error, request: request) {
                providerReadinessLocalControlMessages[record.id] = reason.message
                return .localControl(reason)
            }
            let elapsed = Int(
                (DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
            )
            return .failed(
                errorCategory: readinessFailureCategory(error),
                latency: max(0, elapsed)
            )
        }
    }

    private func stage(
        from result: ProviderReadinessRequestResult,
        success: (Int) -> Bool,
        successDetail: String,
        failureDetail: String,
        apiKey: String,
        resultLines: inout [String],
        anyHTTPResponsePasses: Bool = false
    ) -> ProviderReadinessStage {
        switch result {
        case .localControl(let reason):
            return ProviderReadinessStage(status: .notRun, detail: reason.message, statusCode: nil)
        case .cancelled:
            return ProviderReadinessStage(status: .cancelled, detail: "已取消", statusCode: nil)
        case .failed(let errorCategory, _):
            resultLines.append(errorCategory.rawValue)
            return ProviderReadinessStage(status: .failed, detail: failureDetail, statusCode: nil)
        case .response(let response, _):
            let redactedBody = ContentSecretRedactor.redact(
                response.body,
                knownSecrets: [apiKey]
            )
            if !redactedBody.isEmpty {
                resultLines.append(redactedBody)
            }
            let passed = success(response.statusCode)
                && (anyHTTPResponsePasses || response.errorCategory == nil)
            return ProviderReadinessStage(
                status: passed ? .passed : .failed,
                detail: passed ? successDetail : "\(failureDetail)（HTTP \(response.statusCode)）",
                statusCode: response.statusCode
            )
        }
    }

    /// Keep a safe credential fingerprint when the transport intentionally
    /// drops response bodies. This preserves a useful readiness result while
    /// ensuring the complete credential never enters state or UI text.
    private func redactedReadinessResult(_ text: String, apiKey: String) -> String {
        let redacted = ContentSecretRedactor.redact(
            text,
            knownSecrets: [apiKey]
        )
        let normalizedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedAPIKey.count >= EnvVarRedactor.minMatchLen else {
            return redacted
        }
        let fingerprint = EnvVarRedactor.redact(normalizedAPIKey)
        guard fingerprint != normalizedAPIKey, !redacted.contains(fingerprint) else {
            return redacted
        }
        return redacted.isEmpty ? fingerprint : "\(redacted)\n\(fingerprint)"
    }

    private func normalizedModelIDs(_ modelIDs: [String]) -> [String] {
        var seen = Set<String>()
        return modelIDs.compactMap { raw in
            let modelID = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !modelID.isEmpty, seen.insert(modelID).inserted else { return nil }
            return modelID
        }
    }

    private var successfulProviderReadinessState: ProviderReadinessState {
        switch providerReadinessDeployment {
        case .mock:
            return .mock
        case .local:
            return .local
        case .beta:
            return .beta
        case .remote:
            return providerReadinessTransport.canProduceLiveEvidence ? .live : .unverified
        }
    }

    /// Build a durable, secret-free receipt for one successful production
    /// probe. The response body, URL, and credential never enter the digest.
    private func readinessEvidenceID(
        providerID: String,
        modelID: String,
        statusCode: Int,
        checkedAt: Date
    ) -> String? {
        if providerReadinessDeployment == .mock {
            return "mock-settings:\(providerID):\(modelID)"
        }
        guard providerReadinessDeployment == .remote,
              providerReadinessTransport.canProduceLiveEvidence,
              (200..<300).contains(statusCode) else {
            return nil
        }
        let canonical = [
            providerID,
            modelID,
            String(statusCode),
            String(checkedAt.timeIntervalSince1970)
        ].joined(separator: "\u{001F}")
        let digest = SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "live-settings:\(digest)"
    }

    private func finishProviderDraftProbe(
        _ state: ProviderDraftProbeState
    ) -> ProviderDraftProbeState {
        providerDraftProbeState = state
        return state
    }

    private func checkModels(
        _ modelIDs: [String],
        record: EnvVarEntry,
        baseURL: URL,
        apiKey: String,
        checkedAt: Date
    ) async -> (checks: [ProviderModelReadiness], resultLines: [String], localControl: Bool) {
        var checks: [ProviderModelReadiness] = []
        var resultLines: [String] = []
        for modelID in modelIDs {
            let response = await sendReadinessRequest(
                operation: .minimalModelRequest(modelID),
                record: record,
                baseURL: baseURL,
                apiKey: apiKey,
                modelID: modelID
            )
            if case .localControl = response { return ([], [], true) }
            let stage = stage(
                from: response,
                success: { (200..<300).contains($0) },
                successDetail: "最小请求通过",
                failureDetail: "最小请求失败",
                apiKey: apiKey,
                resultLines: &resultLines
            )
            let redactedResult: String
            if case .response(let response, _) = response {
                redactedResult = redactedReadinessResult(response.body, apiKey: apiKey)
            } else {
                redactedResult = redactedReadinessResult(stage.detail, apiKey: apiKey)
            }
            let evidenceID: String?
            if case .response(let response, _) = response {
                evidenceID = readinessEvidenceID(
                    providerID: record.name,
                    modelID: modelID,
                    statusCode: response.statusCode,
                    checkedAt: checkedAt
                )
            } else {
                evidenceID = nil
            }
            let latency: Int?
            switch response {
            case .response(_, let responseLatency):
                latency = responseLatency
            case .failed(_, let failedLatency):
                latency = failedLatency
            case .cancelled, .localControl:
                latency = nil
            }
            let errorCategory = readinessFailureCategory(from: response)
            let lineage = providerReadinessLineage(
                providerID: record.name,
                modelID: modelID,
                checkedAt: checkedAt
            )
            let readiness = ProviderReadiness.evaluate(
                providerID: record.name,
                modelID: modelID,
                deployment: providerReadinessDeployment,
                probe: stage.status == .passed ? .reachable : .unavailable,
                credential: .available(source: record.name),
                capabilities: [],
                checkedAt: checkedAt,
                evidenceID: stage.status == .passed ? evidenceID : nil,
                errorCategory: errorCategory,
                latency: latency,
                lineage: lineage
            )
            checks.append(
                ProviderModelReadiness(
                    modelID: modelID,
                    status: stage.status,
                    redactedResult: redactedResult,
                    readiness: readiness,
                    errorCategory: errorCategory,
                    latency: latency,
                    lineage: lineage
                )
            )
        }
        return (checks, resultLines, false)
    }

    func previewProviderDeletion(name: String, now: Date = Date(), ttl: TimeInterval = 300) throws -> OperationIntent {
        guard let entry = currentEnvEntry(name: name), entry.isProviderRecord else {
            throw SettingsDeletionError.notFound(name)
        }
        return envDeletionIntent(
            entry: entry,
            targetType: "provider",
            targetName: entry.name,
            impactSummary: Self.providerDeletionImpactSummary(
                dependentSessionTitles: providerDependentSessionTitles?(entry.name) ?? [],
                isDefaultProvider: defaultProviderID?.caseInsensitiveCompare("custom.\(entry.name)") == .orderedSame
            ),
            scopeID: "provider:\(entry.name)",
            now: now,
            ttl: ttl
        )
    }

    /// F1-09：删除确认框的影响说明。会话与默认服务商的后果都如实写出。
    nonisolated static func providerDeletionImpactSummary(
        dependentSessionTitles: [String],
        isDefaultProvider: Bool
    ) -> String {
        var text = "删除供应商配置及其 API 密钥链副本"
        if isDefaultProvider {
            text += "；它是当前默认服务商，删除后默认服务商和默认模型会清空，需要重新选择"
        }
        if !dependentSessionTitles.isEmpty {
            let shown = dependentSessionTitles.prefix(3).map { "「\($0)」" }.joined(separator: "、")
            let more = dependentSessionTitles.count > 3 ? "等 \(dependentSessionTitles.count) 个" : ""
            text += "；\(shown)\(more)会话正在选用它，删除后这些会话会改用默认模型"
        }
        return text
    }

    @discardableResult
    func deleteProvider(name: String) -> OperationIntent? {
        try? previewProviderDeletion(name: name)
    }

    @discardableResult
    func deleteProvider(name: String, intent: OperationIntent, now: Date = Date()) throws -> DeletionReceipt {
        let provider = currentEnvEntry(name: name, resolveCredential: false)
        let receipt = try executeEnvDeletion(intent: intent, name: name, providerOnly: true, now: now)
        if let provider {
            providerReadinessStore.removeProvider(providerID: provider.name)
            usageStore.deleteProvider(recordID: provider.id, at: now)
            // F1-09：默认服务商指向已删除的供应商时一并清空，不留下指向空记录的默认值。
            if let current = defaultProviderID,
               current.caseInsensitiveCompare("custom.\(provider.name)") == .orderedSame {
                defaultProviderID = nil
                defaultModelID = nil
            }
        }
        reloadEnv()
        return receipt
    }

    /// 是否存在同名供应商记录（大小写不敏感，与 canonical 存储一致）。
    /// `excluding` 传正在编辑的记录 id，避免编辑自身被误判为撞名（L1 P2）。
    func providerExists(named name: String, excluding id: String? = nil) -> Bool {
        providerRecords.contains { entry in
            entry.name.caseInsensitiveCompare(name) == .orderedSame && entry.id != id
        }
    }

    /// 供应商改名：完整迁移记录（先按新名保存全部字段，再删除旧记录），
    /// 若该供应商是默认 Provider 则同步修正 defaultProviderID。
    /// 修复：此前只删旧不建新 → 改名后记录丢失（L1 P1）。
    func renameProvider(from old: String, to new: String) {
        // Renaming replaces a persisted credential record and is destructive
        // until the old key is removed. Keep this compatibility entry point
        // fail-closed; callers must preview the exact target first.
    }

    func previewProviderRename(from old: String, to new: String, now: Date = Date(), ttl: TimeInterval = 300) throws -> OperationIntent {
        let canonicalOld = EnvVarStore.canonicalName(old)
        let canonicalNew = EnvVarStore.canonicalName(new)
        guard canonicalOld != canonicalNew else {
            throw SettingsDeletionError.operationFailed("供应商名称没有变化")
        }
        guard let record = currentEnvEntry(name: old, resolveCredential: false) else {
            throw SettingsDeletionError.notFound(old)
        }
        guard currentEnvEntry(name: canonicalNew, resolveCredential: false) == nil else {
            throw SettingsDeletionError.operationFailed("供应商名称已存在")
        }
        return DeletionGate.preview(
            operationType: .permanentDelete,
            targetID: record.name,
            targetType: "provider",
            targetName: "\(record.name) -> \(canonicalNew)",
            affectedCount: 1,
            impactSummary: "迁移供应商配置并删除旧名称",
            reversible: false,
            scopeID: "provider:\(record.name):rename:\(canonicalNew)",
            revision: envRevision(for: record),
            fingerprint: envFingerprint(for: record),
            now: now,
            ttl: ttl
        )
    }

    @discardableResult
    func renameProvider(from old: String, to new: String, intent: OperationIntent, now: Date = Date()) throws -> DeletionReceipt {
        // Keep this compatibility overload metadata-only as well. The unified
        // implementation below owns the sole typed read for blank retention.
        guard let record = currentEnvEntry(name: old, resolveCredential: false) else {
            throw SettingsDeletionError.notFound(old)
        }
        return try renameProvider(
            from: old,
            to: new,
            apiKey: "",
            baseURL: record.baseURL,
            modelNames: record.modelNames,
            protocolType: record.protocolType,
            intent: intent,
            now: now
        )
    }

    @discardableResult
    func renameProvider(
        from old: String,
        to new: String,
        apiKey: String,
        baseURL: String?,
        modelNames: [String],
        protocolType: ProviderWireProtocol,
        modelContextWindows: [String: Int]? = nil,
        intent: OperationIntent,
        now: Date = Date()
    ) throws -> DeletionReceipt {
        let canonicalOld = EnvVarStore.canonicalName(old)
        let canonicalNew = EnvVarStore.canonicalName(new)
        let submitted = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        // Keep the execution snapshot metadata-only for both explicit replacement
        // and blank retention. The latter reads the old secret separately below,
        // after the intent metadata has been validated, so it cannot alter the
        // preview fingerprint or leak into the deletion receipt.
        guard let record = currentEnvEntry(name: old, resolveCredential: false) else {
            throw SettingsDeletionError.notFound(old)
        }
        guard canonicalOld != canonicalNew else {
            throw SettingsDeletionError.operationFailed("供应商名称没有变化")
        }
        guard currentEnvEntry(name: canonicalNew, resolveCredential: false) == nil else {
            throw SettingsDeletionError.operationFailed("供应商名称已存在")
        }
        guard intent.targetID == record.name,
              intent.targetType == "provider",
              intent.targetName == "\(record.name) -> \(canonicalNew)",
              intent.scopeID == "provider:\(record.name):rename:\(canonicalNew)" else {
            throw DeletionGateError.targetChanged
        }
        let effectiveAPIKey: String
        if !submitted.isEmpty {
            // An explicitly entered replacement is passed straight through;
            // EnvVarStore performs the Keychain upsert without probing the old
            // item (which may be missing or unreadable).
            effectiveAPIKey = submitted
        } else {
            // A blank rename means "retain the existing credential". Read it
            // only for this retention path so a missing old item is actionable
            // and never silently produces a renamed provider without a key.
            switch envStore.readEnvVarResult(name: record.name) {
            case .success(let value):
                guard let retained = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !retained.isEmpty else {
                    throw SettingsDeletionError.operationFailed(
                        "旧 API Key 不在钥匙串中；请返回并直接输入新 Key 后重试"
                    )
                }
                effectiveAPIKey = retained
            case .failure(let error):
                let message: String
                switch error {
                case .keychainReadMissing:
                    message = "旧 API Key 不在钥匙串中；请返回并直接输入新 Key 后重试"
                case .keychainReadDenied:
                    message = "钥匙串拒绝读取旧 API Key；请检查钥匙串权限，或直接输入新 Key 替换"
                case .keychainReadFailed:
                    message = "读取旧 API Key 时发生钥匙串错误；请重试，或直接输入新 Key 替换"
                default:
                    message = "旧 API Key 不可用；请返回并直接输入新 Key 后重试"
                }
                throw SettingsDeletionError.operationFailed(message)
            }
        }
        let oldSnapshot = record
        do {
            let receipt = try DeletionGate.execute(
                intent,
                currentRevision: envRevision(for: oldSnapshot),
                currentFingerprint: envFingerprint(for: oldSnapshot),
                now: now
            ) { _ in
                guard saveProvider(
                    name: canonicalNew,
                    apiKey: effectiveAPIKey,
                    baseURL: baseURL,
                    modelNames: modelNames,
                    protocolType: protocolType,
                    modelContextWindows: modelContextWindows ?? oldSnapshot.modelContextWindows
                ) else {
                    throw SettingsDeletionError.operationFailed("新供应商名称无效")
                }
                guard envStore.deleteEnvVar(name: oldSnapshot.name) else {
                    let oldDeleteError = envStore.lastPersistenceError
                    let removedNewProvider = envStore.deleteEnvVar(name: canonicalNew)
                    guard removedNewProvider else {
                        throw SettingsDeletionError.rollbackFailed(
                            "旧供应商删除失败，改名回滚未完成"
                        )
                    }
                    // EnvVarStore restores the old metadata without reading its
                    // Keychain item when deletion fails. Only that typed,
                    // known-safe delete failure proves the old state is intact;
                    // all other errors remain fail-closed after new cleanup.
                    guard oldDeleteError == .keychainDeleteFailed else {
                        throw SettingsDeletionError.rollbackFailed(
                            "旧供应商删除失败，持久化状态无法确认"
                        )
                    }
                    throw SettingsDeletionError.operationFailed("旧供应商删除失败")
                }
                if let current = defaultProviderID,
                   current.caseInsensitiveCompare("custom.\(canonicalOld)") == .orderedSame {
                    let newSuffix = (current == "custom.\(canonicalOld)")
                        ? canonicalNew
                        : canonicalNew.lowercased()
                    defaultProviderID = "custom.\(newSuffix)"
                }
            }
            reloadEnv()
            // F1-01：会话里按旧名保存的服务商选择跟着改名，不退回默认模型。
            onProviderRenamed?(oldSnapshot.name, canonicalNew)
            // The old UUID remains the historical usage lineage. EnvVarStore
            // creates a new UUID for the replacement record; do not silently
            // merge subsequent calls into this old identity by display name.
            usageStore.renameProvider(recordID: oldSnapshot.id,
                                      displayName: canonicalNew, at: now)
            usageStore.deleteProvider(recordID: oldSnapshot.id, at: now)
            return receipt
        } catch {
            reloadEnv()
            throw error
        }
    }

    /// Async counterpart for blank-key retention. SettingsCenter is
    /// main-actor isolated, while a reloaded provider keeps its credential as
    /// a deferred Keychain reference. Resolve it through EnvVarStore's
    /// async-safe boundary before entering the synchronous rename transaction.
    @discardableResult
    func renameProviderAsync(
        from old: String,
        to new: String,
        intent: OperationIntent,
        now: Date = Date()
    ) async throws -> DeletionReceipt {
        guard let record = currentEnvEntry(name: old, resolveCredential: false) else {
            throw SettingsDeletionError.notFound(old)
        }
        let retained: String
        switch await envStore.readEnvVarResultAsync(name: record.name) {
        case .success(let value):
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                throw SettingsDeletionError.operationFailed(
                    "旧 API Key 不在钥匙串中；请返回并直接输入新 Key 后重试"
                )
            }
            retained = value
        case .failure(let error):
            let message: String
            switch error {
            case .keychainReadMissing:
                message = "旧 API Key 不在钥匙串中；请返回并直接输入新 Key 后重试"
            case .keychainReadDenied:
                message = "钥匙串拒绝读取旧 API Key；请检查钥匙串权限，或直接输入新 Key 替换"
            case .keychainReadFailed:
                message = "读取旧 API Key 时发生钥匙串错误；请重试，或直接输入新 Key 替换"
            default:
                message = "旧 API Key 不可用；请返回并直接输入新 Key 后重试"
            }
            throw SettingsDeletionError.operationFailed(message)
        }
        return try renameProvider(
            from: old,
            to: new,
            apiKey: retained,
            baseURL: record.baseURL,
            modelNames: record.modelNames,
            protocolType: record.protocolType,
            intent: intent,
            now: now
        )
    }

    /// Async rename entry point used by the editor when the draft may contain
    /// an explicit replacement. Explicit keys never probe the old Keychain
    /// item; blank drafts retain it through the async path above.
    @discardableResult
    func renameProviderAsync(
        from old: String,
        to new: String,
        apiKey: String,
        baseURL: String?,
        modelNames: [String],
        protocolType: ProviderWireProtocol,
        modelContextWindows: [String: Int]? = nil,
        intent: OperationIntent,
        now: Date = Date()
    ) async throws -> DeletionReceipt {
        let submitted = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard submitted.isEmpty else {
            return try renameProvider(
                from: old,
                to: new,
                apiKey: submitted,
                baseURL: baseURL,
                modelNames: modelNames,
                protocolType: protocolType,
                modelContextWindows: modelContextWindows,
                intent: intent,
                now: now
            )
        }
        return try await renameProviderAsync(from: old, to: new, intent: intent, now: now)
    }

    // MARK: - 日志（Logs）

    /// 日志页的 live 级别以 LogManager 为准；写盘成功后才更新运行态。
    var liveLogLevel: SettingsLogLevel {
        get { SettingsLogLevel(logManager.minimumLevel) }
        set {
            privacyLogLevel = newValue
            // The manager changes future capture only. Refresh the observable
            // ring snapshot so the Logs tab updates its existing-entry view now.
            reloadLogs()
        }
    }

    /// Logs-tab projection of the existing ring. Keep the unfiltered snapshot
    /// for clear previews, and apply the UI limit after severity filtering so
    /// a run of low-level entries cannot hide an older matching entry.
    var visibleLogEntries: [LogEntry] {
        let minimumLevel = logManager.minimumLevel
        return Array(logEntries.filter { $0.level >= minimumLevel }.prefix(200))
    }

    func previewLogClear(now: Date = Date(), ttl: TimeInterval = 300) throws -> OperationIntent {
        let entries = logManager.recentLogs(limit: nil).map {
            SettingsLogFingerprint(timestamp: $0.timestamp, level: $0.level.rawValue, category: $0.category, message: $0.message)
        }
        return DeletionGate.preview(
            targetID: "logs.ring",
            targetType: "logs.clear",
            targetName: "运行日志",
            affectedCount: entries.count,
            impactSummary: "清空当前进程日志缓冲区（磁盘日志文件保留，缓冲区内容清空后不可恢复）",
            // 环形缓冲清空不是回收站移动：进程内无法恢复。必须如实按不可逆申报，
            // 门禁才会要求第二确认逐字输入 永久删除（收紧，不放宽）。
            reversible: false,
            scopeID: "logs:ring",
            revision: entries.count,
            fingerprint: try stableFingerprint(entries),
            now: now,
            ttl: ttl
        )
    }

    @discardableResult
    func clearLogs() -> OperationIntent? {
        try? previewLogClear()
    }

    @discardableResult
    func clearLogs(intent: OperationIntent, now: Date = Date()) throws -> DeletionReceipt {
        let entries = logManager.recentLogs(limit: nil).map {
            SettingsLogFingerprint(timestamp: $0.timestamp, level: $0.level.rawValue, category: $0.category, message: $0.message)
        }
        let receipt = try DeletionGate.execute(
            intent,
            currentRevision: entries.count,
                currentFingerprint: try stableFingerprint(entries),
            now: now
        ) { _ in
            logManager.clearLogs()
            guard logManager.recentLogs(limit: nil).isEmpty else {
                throw SettingsDeletionError.operationFailed("日志清空后仍有缓冲记录")
            }
        }
        reloadLogs()
        return receipt
    }

    // MARK: - MCP 服务器（E6）

    /// 新增/覆盖一个 MCP 服务器（同 id 覆盖），立即持久化。失败返回 false。
    @discardableResult
    func addMCPServer(_ server: MCPServer) -> Bool {
        invalidateMCPDiscovery(for: server.id)
        lastMCPWriteFailure = nil
        do {
            try mcpManager.addServer(server)
            mcpToolsByServer.removeValue(forKey: server.id)
            reloadMCP()
            return true
        } catch {
            lastMCPWriteFailure = error
            return false
        }
    }

    /// 11/16：最近一次 addMCPServer 失败的原因，供设置页区分“配置已被修改”与“写入失败”。
    private(set) var lastMCPWriteFailure: Error?

    func clearMCPWriteFailure() { lastMCPWriteFailure = nil }

    /// 删除服务器（无 id 时 no-op）。失败返回 false。
    @discardableResult
    func removeMCPServer(id: String) -> Bool {
        invalidateMCPDiscovery(for: id)
        do {
            let intent = try mcpManager.deletionIntent(id: id)
            let confirmed = intent
                .withFirstConfirmation("设置中心已确认删除")
                .withSecondConfirmation("设置中心已确认删除")
            _ = try mcpManager.deleteServer(confirmed)
            reloadMCP()
            return true
        } catch {
            lastMCPWriteFailure = error
            return false
        }
    }

    /// 启用/禁用服务器。失败返回 false。
    @discardableResult
    func toggleMCPServer(id: String, enabled: Bool) -> Bool {
        invalidateMCPDiscovery(for: id)
        do {
            try mcpManager.enableServer(id: id, enabled: enabled)
            if !enabled {
                mcpToolsByServer.removeValue(forKey: id)
            }
            reloadMCP()
            return true
        } catch {
            lastMCPWriteFailure = error
            return false
        }
    }

    /// User-facing server authorization is separate from the lifecycle
    /// enabled switch. Granting a server still leaves its tool set deny-all.
    func isMCPServerAuthorized(id: String) -> Bool {
        guard let server = mcpManager.server(id: id) else { return false }
        return mcpManager.isServerAuthorized(server)
    }

    @discardableResult
    func setMCPServerAuthorized(id: String, authorized: Bool) -> Bool {
        invalidateMCPDiscovery(for: id)
        do {
            if authorized {
                _ = try mcpManager.authorizeServer(id: id)
            } else {
                _ = try mcpManager.revokeServer(id: id)
                mcpToolsByServer.removeValue(forKey: id)
            }
            reloadMCP()
            return true
        } catch {
            lastMCPWriteFailure = error
            return false
        }
    }

    /// 批量工具授权（“全部授权/全部取消”）：一次持久化。
    @discardableResult
    func setMCPToolsAuthorized(serverID: String, toolNames: [String], authorized: Bool) -> Bool {
        let names = toolNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !names.isEmpty else { return false }
        do {
            if authorized {
                _ = try mcpManager.authorizeTools(serverID: serverID, toolNames: names)
            } else {
                _ = try mcpManager.revokeTools(serverID: serverID, toolNames: names)
            }
            return true
        } catch {
            lastMCPWriteFailure = error
            return false
        }
    }

    /// 因工具定义摘要变化而被收窄、需要重新授权的工具数。
    func mcpNarrowedToolCount(serverID: String) -> Int {
        mcpManager.schemaNarrowedToolCount(serverID: serverID)
    }

    func mcpTools(for serverID: String) -> [MCPTool] {
        mcpToolsByServer[serverID] ?? []
    }

    func isMCPToolAuthorized(serverID: String, toolName: String) -> Bool {
        let normalizedToolName = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedToolName.isEmpty else { return false }
        return mcpManager.isToolAuthorized(serverID: serverID, toolName: normalizedToolName)
    }

    @discardableResult
    func setMCPToolAuthorized(
        serverID: String,
        toolName: String,
        authorized: Bool
    ) -> Bool {
        let normalizedToolName = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedToolName.isEmpty else { return false }
        do {
            if authorized {
                _ = try mcpManager.authorizeTool(
                    serverID: serverID,
                    toolName: normalizedToolName
                )
            } else {
                _ = try mcpManager.revokeTool(
                    serverID: serverID,
                    toolName: normalizedToolName
                )
            }
            return true
        } catch {
            lastMCPWriteFailure = error
            return false
        }
    }

    /// Discover through the canonical manager so Settings observes the same
    /// schema lineage, revocations and cross-turn cache as the tool registry.
    /// Discovery never grants any tool.
    @discardableResult
    func discoverMCPTools(for server: MCPServer) async -> Bool {
        await discoverMCPTools(for: server, clientFactory: nil)
    }

    /// Injectable transport seam for local synthetic consumer tests. The
    /// production entry above uses the manager's normal client factory.
    @discardableResult
    func discoverMCPTools(
        for server: MCPServer,
        clientFactory: (@Sendable (MCPServer) -> MCPClient)?,
        onFailure: ((String) -> Void)? = nil
    ) async -> Bool {
        guard let currentServer = mcpManager.server(id: server.id),
              currentServer.enabled,
              mcpManager.isServerAuthorized(currentServer),
              currentServer.descriptorFingerprint == server.descriptorFingerprint else {
            onFailure?("工具发现未执行：服务器已禁用、未授权或配置已变化。")
            return false
        }
        // Each refresh owns a replacement projection generation, including
        // overlapping refreshes; an older failure must not erase the newer one.
        invalidateMCPDiscovery(for: server.id)
        let generation = mcpDiscoveryGenerations[server.id, default: 0]
        let descriptorFingerprint = currentServer.descriptorFingerprint
        do {
            let tools = try await mcpManager.discoverTools(
                serverID: server.id,
                clientFactory: clientFactory
            )
            try Task.checkCancellation()
            // The manager may legitimately bind an initial grant or revoke
            // names after schema drift. Validate its accepted snapshot rather
            // than demanding the pre-discovery grant remain byte-identical.
            guard mcpDiscoveryGenerations[server.id, default: 0] == generation,
                  let latestServer = mcpManager.server(id: server.id),
                  latestServer.enabled,
                  mcpManager.isServerAuthorized(latestServer),
                  latestServer.descriptorFingerprint == descriptorFingerprint,
                  let accepted = mcpManager.discoverySnapshot(serverID: server.id),
                  accepted.descriptorFingerprint == descriptorFingerprint,
                  accepted.tools == tools else {
                return false
            }
            mcpToolsByServer[server.id] = accepted.tools
            return true
        } catch {
            // A late failure cannot erase a newer UI projection. For the
            // current request, retain the existing false/typed-error UI route
            // and never leave the previous tools advertised as a fresh result.
            if mcpDiscoveryGenerations[server.id, default: 0] == generation {
                mcpToolsByServer.removeValue(forKey: server.id)
                if !Task.isCancelled,
                   let latestServer = mcpManager.server(id: server.id),
                   latestServer.enabled, mcpManager.isServerAuthorized(latestServer),
                   latestServer.descriptorFingerprint == descriptorFingerprint {
                    onFailure?(redactedMCPTestFailure(error, discovery: true))
                }
            }
            return false
        }
    }

    private func invalidateMCPDiscovery(for serverID: String) {
        mcpDiscoveryGenerations[serverID, default: 0] += 1
    }

    func reloadMCP() {
        mcpServers = mcpManager.listServers()
        mcpToolsByServer = mcpToolsByServer.filter { serverID, _ in
            mcpServers.contains { $0.id == serverID }
        }
    }

    /// 测试连接（MCP 面板「测试连接」按钮）：connect 握手 + tools/list。
    /// 返回面向 UI 的结果消息（成功含工具数）；生命周期变化后的
    /// completion 返回 nil，调用方必须丢弃该结果。
    func testMCPServer(_ server: MCPServer) async -> String? {
        guard let result = await testMCPServerResult(server) else { return nil }
        return (result.ok ? "✅ " : "❌ ") + result.message
    }

    func testMCPServerResult(_ server: MCPServer) async -> MCPTestResult? {
        guard isSafetyFeatureEnabled(.mcp) else {
            return MCPTestResult(status: .error, message: "MCP 已被 Safe Mode/Kill Switch 关闭。")
        }
        guard let currentServer = mcpManager.server(id: server.id),
              currentServer.enabled,
              mcpManager.isServerAuthorized(currentServer),
              currentServer.descriptorFingerprint == server.descriptorFingerprint else {
            return MCPTestResult(status: .rejected, message: "连接测试已拒绝：服务器已禁用、未授权或配置已变化。")
        }
        let generation = mcpDiscoveryGenerations[server.id, default: 0]
        let revision = mcpManager.snapshot().revision
        let descriptorFingerprint = currentServer.descriptorFingerprint
        let authorizationSnapshot = mcpManager.authorization(serverID: server.id)
        let client = mcpManager.makeClient(server: currentServer)
        defer { client.disconnect() }
        do {
            try await client.connect()
            let tools = try await client.listTools()
            guard mcpDiscoveryGenerations[server.id, default: 0] == generation,
                  let latestServer = mcpManager.server(id: server.id),
                  latestServer.enabled,
                  mcpManager.isServerAuthorized(latestServer),
                  latestServer.descriptorFingerprint == descriptorFingerprint,
                  mcpManager.snapshot().revision == revision,
                  mcpManager.authorization(serverID: server.id) == authorizationSnapshot else {
                return nil
            }
            return MCPTestResult(status: .success, message: "连接成功，发现 \(tools.count) 个工具")
        } catch {
            guard mcpDiscoveryGenerations[server.id, default: 0] == generation,
                  let latestServer = mcpManager.server(id: server.id),
                  latestServer.enabled,
                  mcpManager.isServerAuthorized(latestServer),
                  latestServer.descriptorFingerprint == descriptorFingerprint,
                  mcpManager.snapshot().revision == revision,
                  mcpManager.authorization(serverID: server.id) == authorizationSnapshot else {
                return nil
            }
            return MCPTestResult(status: .error, message: redactedMCPTestFailure(error))
        }
    }

    private func redactedMCPTestFailure(_ error: Error, discovery: Bool = false) -> String {
        let reason: String
        switch error {
        case MCPClientError.timeout:
            reason = "请求超时，请检查服务器是否可达。"
        case MCPClientError.spawnFailed, MCPClientError.processExited, MCPClientError.transportNotStarted:
            reason = "本地服务器启动失败，请检查命令和权限。"
        case MCPClientError.invalidServer:
            reason = "服务器配置无效，请检查传输类型和端点。"
        case MCPClientError.invalidMessage, MCPClientError.rpcError, MCPClientError.badResponse,
             MCPClientError.invalidSchema:
            reason = "服务器响应无效，请检查协议兼容性。"
        case MCPClientError.permissionDenied:
            reason = "服务器拒绝了请求，请检查服务器授权和配置。"
        case let changed as MCPDiscoveryError where discovery:
            switch changed {
            case .stale, .serverIdentityChanged:
                reason = "配置或授权已变化，请重新读取工具列表。"
            case .transportEpochChanged:
                reason = "传输会话已变化，请重新连接后读取工具列表。"
            default:
                reason = "配置或连接状态已变化，请核对授权后重新读取工具列表。"
            }
        default:
            reason = discovery ? "请求失败，请检查服务器配置和可达性。"
                : "连接测试失败，请检查服务器配置和可达性。"
        }
        return discovery ? "工具发现失败：\(reason)" : "连接失败：\(reason)"
    }

    // MARK: - 恢复默认

    func resetToDefaults() {
        guard persistSettings({ settingsStore.resetToDefaults() }) else { return }
        // E22: 镜像重同步，设置面板/根视图随默认值立即刷新。
        childConcurrencyRiskAcknowledgedValue = false
        safetyControlState = .defaults
        logManager.minimumLevel = LogLevel(settingsMirror.privacy.logLevel)
        // F3-02：恢复默认后命令环境（去凭据、非交互）也按默认值重新配置。
        configureModelShellEnvironment()
        onChildConcurrencySelectionChanged?(childConcurrencySelection)
        onApprovalPolicyChanged?(settingsMirror.agent.approvalPolicy)
        onPolicyRuntimeDefaultsChanged?(settingsMirror.agent.policyRuntimeDefaults)
        publishPersonaSettings()
        onFileAccessSettingsChanged?()
        onSafetyRuntimeSnapshotChanged?(safetyRuntimeSnapshot)
        onComposerPolicyChanged?(settingsMirror.agent.composerPolicy)
        onChatOutputModeSettingsChanged?(chatOutputMode)
        reloadAll()
    }

    // MARK: - 刷新

    func reloadEnv() {
        envEntries = envStore.allEnvVars
        // U5：供应商快照同步刷新（新增/编辑/删除供应商后立即反映到 UI）。
        providerRecords = envStore.providerRecords
    }

    /// Settings list/detail and edit prefill use the same explicit disclosure
    /// decision as env.list. Import confirmation does not grant value display.
    func environmentDisplayValue(for entry: EnvVarEntry) -> String {
        if entry.isSecret || entry.valueInKeychain {
            return "Keychain 引用：\(EnvVarStore.canonicalName(entry.name))（仅运行时解析）"
        }
        return envStore.mayDisplayValueInList(entry)
            ? entry.value
            : EnvVarStore.EnvVarProcessImportPreviewItem.redactedValuePlaceholder
    }

    func environmentEditablePrefill(for entry: EnvVarEntry) -> String {
        envStore.mayDisplayValueInList(entry) ? entry.value : ""
    }

    // MARK: - 删除门禁辅助

    private func currentEnvEntry(name: String, resolveCredential: Bool = true) -> EnvVarEntry? {
        guard var entry = envStore.entry(name: name) else { return nil }
        // Keychain-backed entries expose metadata separately from their value.
        // Resolve the value before preview and execution fingerprint the entry so
        // both operations describe the same snapshot. Metadata-only callers
        // (for example an explicit replacement rename) deliberately skip the
        // old Keychain item so missing/denied access cannot block replacement.
        if resolveCredential, entry.valueInKeychain, let value = envStore.getEnvVar(name: entry.name) {
            entry.value = value
        }
        return entry
    }

    private func envRevision(for entry: EnvVarEntry) -> Int {
        Int(clamping: Int64(entry.createdAt.timeIntervalSince1970.rounded(.down)))
    }

    private func envFingerprint(for entry: EnvVarEntry) -> String {
        (try? stableFingerprint(entry)) ?? DeletionGate.fingerprint(Data(entry.id.utf8))
    }

    private func envDeletionIntent(
        entry: EnvVarEntry,
        targetType: String,
        targetName: String,
        impactSummary: String,
        scopeID: String,
        now: Date,
        ttl: TimeInterval
    ) -> OperationIntent {
        DeletionGate.preview(
            operationType: .permanentDelete,
            targetID: entry.name,
            targetType: targetType,
            targetName: targetName,
            affectedCount: 1,
            impactSummary: impactSummary,
            reversible: false,
            scopeID: scopeID,
            revision: envRevision(for: entry),
            fingerprint: envFingerprint(for: entry),
            now: now,
            ttl: ttl
        )
    }

    private func executeEnvDeletion(
        intent: OperationIntent,
        name: String,
        providerOnly: Bool,
        now: Date
    ) throws -> DeletionReceipt {
        try DeletionGate.checkLifecycle(intent)
        guard let entry = currentEnvEntry(name: name) else {
            throw SettingsDeletionError.notFound(name)
        }
        guard !providerOnly || entry.isProviderRecord else {
            throw SettingsDeletionError.notFound(name)
        }
        guard intent.targetID == entry.name,
              (!providerOnly || intent.targetType == "provider") else {
            throw DeletionGateError.targetChanged
        }
        return try DeletionGate.execute(
            intent,
            currentRevision: envRevision(for: entry),
            currentFingerprint: envFingerprint(for: entry),
            now: now
        ) { _ in
            guard let current = currentEnvEntry(name: name), (!providerOnly || current.isProviderRecord) else {
                throw SettingsDeletionError.notFound(name)
            }
            guard envStore.deleteEnvVar(name: current.name) else {
                throw SettingsDeletionError.operationFailed("环境变量删除失败")
            }
        }
    }

    private func memoryRevision(for id: String) throws -> Int {
        guard let fact = try memoryStore.facts().first(where: { $0.id == id }) else { return -1 }
        return Int(clamping: Int64(fact.createdAt.timeIntervalSince1970.rounded(.down)))
    }

    private func memoryFingerprint(for id: String) throws -> String {
        guard let fact = try memoryStore.facts().first(where: { $0.id == id }) else { return "" }
        return try stableFingerprint(fact)
    }

    private func stableFingerprint<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return DeletionGate.fingerprint(try encoder.encode(value))
    }

    private func restoreMemoryFacts(_ rollback: MemoryFactDeletionRollback) throws {
        try memoryStore.rollback(rollback)
    }

    func reloadLogs() { logEntries = logManager.recentLogs(limit: nil) }

    func reloadStorage() {
        sessions = sessionStore.listSessions().sorted { $0.updatedAt > $1.updatedAt }
        do {
            // I2-MEMORY-PROJECTION: the Memory tab must present the
            // activeFacts() projection (`facts().filter { lifecycleState ==
            // .active }`, the store's own rule), never the full history —
            // otherwise superseded revisions from MEMORY-05 edits reappear as
            // duplicate rows and deleted facts could leak back into the list.
            let persistedFacts = try memoryStore.facts()
            memoryFactTotalCount = persistedFacts.count
            memoryFacts = persistedFacts.filter { $0.lifecycleState == .active }
            memoryFactsLoadFailed = false
        } catch {
            // Retain the last known good snapshot. A corrupt facts file must
            // not turn the settings view into a false empty-state.
            memoryFactsLoadFailed = true
        }
        memoryFiles = memoryFileStore.listFiles()
    }

    // MARK: - AJ-47 文件式记忆（GLOBAL.md / SOUL.md / 每日日志）

    /// 刷新记忆文件列表（GLOBAL.md / SOUL.md / 每日日志）。
    func reloadMemoryFiles() {
        memoryFiles = memoryFileStore.listFiles()
    }

    /// 读取指定记忆文件内容（GLOBAL.md / SOUL.md / daily/<date>.md / 裸日期名）。
    func readMemoryDocument(named name: String) -> String? {
        memoryFileStore.readDocument(named: name)
    }

    /// Preserve the selected list row's complete target for the editor's
    /// existing read/save/delete consumers. A failed read is not an empty file.
    func prepareMemoryFileEditor(_ file: MemoryFileInfo) -> MemoryFileEditorPreparation {
        guard let content = readMemoryDocument(named: file.relativePath) else {
            return .unreadable
        }
        return .ready(relativePath: file.relativePath, content: content)
    }

    /// 写入指定记忆文件（GLOBAL.md / SOUL.md / 每日日志）。
    @discardableResult
    func writeMemoryDocument(named name: String, content: String) throws -> Bool {
        let ok = try memoryFileStore.writeDocument(named: name, content: content)
        if ok {
            reloadMemoryFiles()
        }
        return ok
    }

    /// Production editor adapter: expose a typed, secret-free result while
    /// retaining the original throwing consumer for existing callers.
    func saveMemoryDocumentResult(named name: String, content: String) -> MemoryFileOperationResult {
        do {
            guard try writeMemoryDocument(named: name, content: content) else {
                return .saveInvalidTarget
            }
            return .saved
        } catch {
            return .saveFailed
        }
    }

    /// 删除指定记忆文件。
    @discardableResult
    func deleteMemoryDocument(named name: String) throws -> Bool {
        let ok = try memoryFileStore.deleteDocument(named: name)
        if ok {
            reloadMemoryFiles()
        }
        return ok
    }

    /// Production editor adapter: expose a typed, secret-free result while
    /// retaining the original throwing consumer for existing callers.
    func deleteMemoryDocumentResult(named name: String) -> MemoryFileOperationResult {
        do {
            guard try deleteMemoryDocument(named: name) else {
                return .deleteInvalidTarget
            }
            return .deleted
        } catch {
            return .deleteFailed
        }
    }

    /// 追加一行到今日日志（对话期间自动创建）。
    @discardableResult
    func appendToDailyLog(_ text: String) throws -> URL {
        let url = try memoryFileStore.appendToDailyLog(text)
        reloadMemoryFiles()
        return url
    }

    func reloadAll() {
        reloadEnv()
        reloadLogs()
        reloadStorage()
        reloadMCP()
        // BL6 atomic restore/compensation also reaches this reload boundary;
        // refresh the real production executor without rewriting in-flight
        // snapshots.
        onTerminalPolicyChanged?(terminalPolicySnapshot)
    }
}
