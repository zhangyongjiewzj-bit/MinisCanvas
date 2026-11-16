import Foundation

/// Capabilities controlled by the phase-3 Safe Mode and offline Kill Switch.
enum SafetyControlFeature: String, Codable, CaseIterable, Identifiable, Sendable {
    case canvas
    case mcp
    case externalAgents
    case childOrchestration
    case userSkills
    case browserTerminalSideEffects
    case experimentalMemoryImport
    case chat
    case backup
    case recovery

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .canvas: return "画布"
        case .mcp: return "工具与服务连接（MCP）"
        case .externalAgents: return "外部智能体"
        case .childOrchestration: return "子任务编排"
        case .userSkills: return "用户技能"
        case .browserTerminalSideEffects: return "浏览器与终端副作用"
        case .experimentalMemoryImport: return "实验性记忆导入"
        case .chat: return "对话"
        case .backup: return "备份"
        case .recovery: return "恢复"
        }
    }

    var safetyMeaning: String {
        switch self {
        case .canvas: return "控制画布操作及其副作用是否可以运行"
        case .mcp: return "控制工具与服务连接是否可以发起外部操作"
        case .externalAgents: return "控制外部智能体连接是否可以继续运行"
        case .childOrchestration: return "控制子任务编排是否可以启动新的子任务"
        case .userSkills: return "控制用户技能是否可以被加载和执行"
        case .browserTerminalSideEffects: return "控制浏览器和终端副作用是否可以执行"
        case .experimentalMemoryImport: return "控制实验性记忆导入是否可以执行"
        case .chat: return "保留对话能力，安全锁定时仍可使用"
        case .backup: return "保留备份能力，安全锁定时仍可使用"
        case .recovery: return "保留恢复能力，安全锁定时仍可使用"
        }
    }

    var defaultEnabled: Bool { true }

    var isForced: Bool {
        switch self {
        case .chat, .backup, .recovery: return true
        default: return false
        }
    }

    /// All capability rows are read-only: only the two top-level safety
    /// controls may be changed, and those controls are owned by SettingsCenter.
    var isReadOnly: Bool { true }

    var owner: String { "P3-SAFE-01/L04" }

    var deletionCondition: String {
        switch self {
        case .canvas:
            return "Remove when Canvas is retired or phase-3 isolation is accepted."
        case .mcp:
            return "Remove after staged MCP enablement and rollback evidence are accepted."
        case .externalAgents:
            return "Remove after external-agent isolation and recovery evidence are accepted."
        case .childOrchestration:
            return "Remove after the 40-child staged ring is accepted."
        case .userSkills:
            return "Remove after user-Skill containment and rollback are accepted."
        case .browserTerminalSideEffects:
            return "Remove after browser and terminal side-effect gates are accepted."
        case .experimentalMemoryImport:
            return "Remove after experimental memory import has a recoverable release contract."
        case .chat:
            return "Keep for the lifetime of the application."
        case .backup:
            return "Keep until backup is replaced by an equivalent recoverable path."
        case .recovery:
            return "Keep for the lifetime of the application."
        }
    }

    var cleanupStage: String {
        switch self {
        case .chat, .backup, .recovery:
            return "Never in phase 3"
        default:
            return "Phase 3 graduation"
        }
    }
}

/// Read-only manifest row exposed to settings and diagnostics consumers.
struct SafetyFeatureFlag: Codable, Equatable, Identifiable, Sendable {
    let feature: SafetyControlFeature
    let owner: String
    let defaultEnabled: Bool
    let isEnabled: Bool
    let isForced: Bool
    let isReadOnly: Bool
    let deletionCondition: String
    let cleanupStage: String

    var id: String { feature.id }
    var key: String { feature.rawValue }
    var defaultValue: Bool { defaultEnabled }
    var deleteCondition: String { deletionCondition }
}

/// Versioned, settings-backed safety state.
///
/// The state deliberately contains no transport, process, Canvas, MCP, or
/// agent references. It is safe to restore and evaluate before those modules
/// are composed, including while offline.
struct SafetyControlState: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let settingsKey = "__miniscanvas.safetyControl"
    static let payloadKey = "state"

    let schemaVersion: Int
    var safeModeEnabled: Bool
    var killSwitchEnabled: Bool

    static let defaults = SafetyControlState(
        schemaVersion: currentVersion,
        safeModeEnabled: false,
        killSwitchEnabled: false
    )

    /// A persisted payload that cannot be trusted must not silently reopen
    /// optional work after restart. This is distinct from first-launch
    /// defaults, where no payload exists yet.
    static let failClosedDefaults = SafetyControlState(
        schemaVersion: currentVersion,
        safeModeEnabled: true,
        killSwitchEnabled: true
    )

    init(
        schemaVersion: Int = SafetyControlState.currentVersion,
        safeModeEnabled: Bool = false,
        killSwitchEnabled: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.safeModeEnabled = safeModeEnabled
        self.killSwitchEnabled = killSwitchEnabled
    }

    /// Safety settings are a single canonical payload.  Both unknown future
    /// schemas and stale pre-v1 payloads fail closed instead of being
    /// interpreted as today's control plane.  A future schema may change the
    /// meaning of either flag, while an older schema may have omitted a
    /// safety boundary; treating either as current could re-enable optional
    /// work after a restart.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard version == Self.currentVersion else {
            self = .failClosedDefaults
            return
        }
        self.init(
            schemaVersion: Self.currentVersion,
            safeModeEnabled: try container.decodeIfPresent(Bool.self, forKey: .safeModeEnabled) ?? false,
            killSwitchEnabled: try container.decodeIfPresent(Bool.self, forKey: .killSwitchEnabled) ?? false
        )
    }

    var isOptionalModuleLockActive: Bool {
        safeModeEnabled || killSwitchEnabled
    }

    var version: Int { schemaVersion }

    var optionalFeatures: [SafetyControlFeature] {
        SafetyControlFeature.allCases.filter { !$0.isForced }
    }

    var forcedFeatures: [SafetyControlFeature] {
        SafetyControlFeature.allCases.filter(\.isForced)
    }

    var disabledFeatures: [SafetyControlFeature] {
        optionalFeatures.filter { !isEnabled($0) }
    }

    func isEnabled(_ feature: SafetyControlFeature) -> Bool {
        feature.isForced || !isOptionalModuleLockActive
    }

    var featureFlags: [SafetyFeatureFlag] {
        SafetyControlFeature.allCases.map { feature in
            SafetyFeatureFlag(
                feature: feature,
                owner: feature.owner,
                defaultEnabled: feature.defaultEnabled,
                isEnabled: isEnabled(feature),
                isForced: feature.isForced,
                isReadOnly: feature.isReadOnly,
                deletionCondition: feature.deletionCondition,
                cleanupStage: feature.cleanupStage
            )
        }
    }

    var flags: [SafetyFeatureFlag] { featureFlags }

    var isSafeModeActive: Bool { safeModeEnabled }

    var isKillSwitchActive: Bool { killSwitchEnabled }

    var allOptionalModulesDisabled: Bool {
        optionalFeatures.allSatisfy { !isEnabled($0) }
    }

    var coreFeaturesRemainEnabled: Bool {
        forcedFeatures.allSatisfy(isEnabled)
    }

    var scope: String {
        "画布、工具连接、外部智能体、子任务编排、用户技能、浏览器与终端副作用、实验性记忆导入"
    }

    var source: String {
        "设置中心（SettingsCenter）"
    }

    var resetDescription: String {
        "Safe Mode=false；Kill Switch=false"
    }

    var effectiveState: String {
        isOptionalModuleLockActive ? "可选能力已关闭；对话、备份、恢复保持可用" : "可选能力默认可用"
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case safeModeEnabled
        case killSwitchEnabled
    }
}

/// Frozen runtime-facing name for the settings-backed safety snapshot.
typealias SafetyRuntimeSnapshot = SafetyControlState

enum SafetyRuntimeAdmissionError: Error, Equatable, Sendable, LocalizedError {
    case featureDisabled(SafetyControlFeature)
    case staleRuntime(SafetyControlFeature)

    var errorDescription: String? {
        switch self {
        case .featureDisabled(let feature):
            return "\(feature.displayName) 已被 Safe Mode/Kill Switch 关闭"
        case .staleRuntime(let feature):
            return "\(feature.displayName) 回调已过期，拒绝晚到结果"
        }
    }
}

struct SafetyRuntimeTransitionReceipt: Codable, Equatable, Sendable {
    let generation: UInt64
    let cancelledOptionalWorkIDs: [String]
    let retainedCheckpointIDs: [String]
    let lateCallbackRejected: Bool

    init(
        generation: UInt64,
        cancelledOptionalWorkIDs: [String] = [],
        retainedCheckpointIDs: [String] = [],
        lateCallbackRejected: Bool = false
    ) {
        self.generation = generation
        self.cancelledOptionalWorkIDs = cancelledOptionalWorkIDs
        self.retainedCheckpointIDs = retainedCheckpointIDs
        self.lateCallbackRejected = lateCallbackRejected
    }

    var cancelledWorkIDs: [String] { cancelledOptionalWorkIDs }
    var checkpointIDs: [String] { retainedCheckpointIDs }
    var lateCallbackRejection: Bool { lateCallbackRejected }
}

typealias SafetyFlag = SafetyFeatureFlag
