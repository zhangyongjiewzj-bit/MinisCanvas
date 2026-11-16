import Foundation

/// Stable, secret-free state shown by the artifact output consumer.
///
/// The projection deliberately omits target paths and receipt payloads. The
/// caller must obtain an approved URL from `ArtifactStore.targetURL` after the
/// state says `.ready`; a user-facing card can therefore survive reopen and
/// recovery without becoming a filesystem path transport.
enum ArtifactOutputProjectionState: String, Codable, Sendable, Equatable {
    case ready
    case stale
    case missing
    case invalidTarget
    case quarantined
    case versionMismatch
    case deleted
    case rollbackAvailable
    case recoveryRequired
}

enum ArtifactOutputRecoveryAction: String, Codable, Sendable, Equatable {
    case reopen
}

struct ArtifactOutputUserProjection: Codable, Sendable, Equatable {
    let artifactID: String
    let state: ArtifactOutputProjectionState
    let title: String
    let detail: String
    let canOpen: Bool
    let canReveal: Bool
    let canReopen: Bool
    let recoveryAction: ArtifactOutputRecoveryAction?

    var isActionable: Bool {
        canOpen || canReveal || canReopen
    }

    static func project(_ validation: ArtifactTargetValidation) -> Self {
        let state: ArtifactOutputProjectionState
        switch validation.status {
        case .ready: state = .ready
        case .stale: state = .stale
        case .missing: state = .missing
        case .invalidTarget: state = .invalidTarget
        case .quarantined: state = .quarantined
        case .versionMismatch: state = .versionMismatch
        case .deleted: state = .deleted
        case .rollbackAvailable: state = .rollbackAvailable
        case .recoveryRequired: state = .recoveryRequired
        }

        let canOpen = state == .ready
        let canReveal = state == .ready
        let canReopen = state == .rollbackAvailable
        return Self(
            artifactID: validation.artifactID,
            state: state,
            title: Self.title(for: state),
            detail: Self.detail(for: state),
            canOpen: canOpen,
            canReveal: canReveal,
            canReopen: canReopen,
            recoveryAction: canReopen ? .reopen : nil
        )
    }

    private static func title(for state: ArtifactOutputProjectionState) -> String {
        switch state {
        case .ready: return "结果可用"
        case .stale: return "结果已变化"
        case .missing: return "结果文件不存在"
        case .invalidTarget: return "结果目标无效"
        case .quarantined: return "结果已隔离"
        case .versionMismatch: return "结果版本不匹配"
        case .deleted: return "结果已删除"
        case .rollbackAvailable: return "结果可恢复"
        case .recoveryRequired: return "结果需要恢复"
        }
    }

    private static func detail(for state: ArtifactOutputProjectionState) -> String {
        switch state {
        case .ready: return "可打开或在 Finder 中定位。"
        case .stale: return "文件内容已变化，已阻止打开。"
        case .missing: return "文件已不存在，请重新生成。"
        case .invalidTarget: return "目标不在允许目录内，已阻止访问。"
        case .quarantined: return "收据快照已隔离，等待恢复。"
        case .versionMismatch: return "收据版本不匹配，已阻止访问。"
        case .deleted: return "结果已删除，无法打开。"
        case .rollbackAvailable: return "可安全执行重新打开恢复。"
        case .recoveryRequired: return "结果需要恢复后才能继续。"
        }
    }
}

extension ArtifactTargetValidation {
    /// Maps a store validation into the stable user-facing output state.
    /// Neither the validation message nor its target path is copied through.
    var userProjection: ArtifactOutputUserProjection {
        ArtifactOutputUserProjection.project(self)
    }
}

/// Secret-free source backlink carried by a durable result projection. The
/// source artifact is optional for a first result; opaque revisions prevent a
/// later result from being mistaken for a different source after reopen.
struct ArtifactResultCardSourceBacklink: Codable, Sendable, Equatable {
    let sourceArtifactID: String?
    let sourceRevision: String
    let producerRevision: String
    let resultRevision: String

    var isNavigable: Bool {
        guard let sourceArtifactID else { return false }
        return !sourceArtifactID.isEmpty
    }

    func navigation(using context: ArtifactSourceNavigationContext) -> ArtifactSourceNavigationProjection {
        ArtifactSourceNavigationProjection.project(backlink: self, context: context)
    }
}

enum ArtifactSourceProjectAccess: String, Codable, Sendable, Equatable {
    case currentProject
    case authorizedProject
    case missingProject
}

enum ArtifactSourceTaskAvailability: String, Codable, Sendable, Equatable {
    case available
    case missing
    case deleted
}

enum ArtifactSourceRestartIdentity: String, Codable, Sendable, Equatable {
    case notRequired
    case revalidated
    case mismatch
    case unavailable
}

/// A persistent result card never chooses a different project on behalf of a
/// user. The caller must carry the current user decision into the navigation
/// projection after restart.
enum ArtifactSourceNavigationDecision: String, Codable, Sendable, Equatable {
    case remainOnCurrent
    case switchToSource
}

/// Caller-owned facts required before a persistent result backlink may
/// navigate to its source. Bookmark state is an authorization result and never
/// carries a path or bookmark payload through this projection.
struct ArtifactSourceNavigationContext: Codable, Sendable, Equatable {
    let currentProjectID: String
    let sourceProjectID: String?
    let sourceTaskID: String?
    let resolvedSourceArtifactID: String?
    let observedSourceRevision: String?
    let projectAccess: ArtifactSourceProjectAccess
    let bookmarkAuthorized: Bool
    let taskAvailability: ArtifactSourceTaskAvailability
    let restartIdentity: ArtifactSourceRestartIdentity
}

enum ArtifactSourceNavigationState: String, Codable, Sendable, Equatable {
    case navigable
    case blocked
    case notRequested
}

/// Safe source-backlink navigation projection. Blocked states retain only a
/// stable user action and never return a project/task target or filesystem
/// data.
struct ArtifactSourceNavigationProjection: Codable, Sendable, Equatable {
    let state: ArtifactSourceNavigationState
    let projectID: String?
    let taskID: String?
    let sourceArtifactID: String?
    let detail: String
    let actionableError: String?

    var isNavigable: Bool { state == .navigable }

    static func notRequested() -> Self {
        Self(
            state: .notRequested,
            projectID: nil,
            taskID: nil,
            sourceArtifactID: nil,
            detail: "用户未选择切换来源。",
            actionableError: nil
        )
    }

    static func project(
        backlink: ArtifactResultCardSourceBacklink,
        context: ArtifactSourceNavigationContext
    ) -> Self {
        guard let sourceArtifactID = backlink.sourceArtifactID,
              !sourceArtifactID.isEmpty else {
            return blocked("结果没有来源 artifact，无法跳转。")
        }
        guard !backlink.sourceRevision.isEmpty,
              let sourceProjectID = context.sourceProjectID,
              !sourceProjectID.isEmpty else {
            return blocked("来源项目或版本缺失，无法跳转。")
        }
        guard let sourceTaskID = context.sourceTaskID,
              !sourceTaskID.isEmpty else {
            return blocked("来源任务不存在，无法跳转。")
        }
        guard !context.currentProjectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return blocked("当前项目身份缺失，已阻止跳转。")
        }

        switch context.projectAccess {
        case .currentProject:
            guard sourceProjectID == context.currentProjectID else {
                return blocked("来源项目范围不匹配，已阻止跳转。")
            }
        case .authorizedProject:
            guard context.bookmarkAuthorized else {
                return blocked("来源项目尚未获得书签授权，无法跳转。")
            }
        case .missingProject:
            return blocked("来源项目不存在，无法跳转。")
        }

        switch context.taskAvailability {
        case .available:
            break
        case .missing:
            return blocked("来源任务不存在，无法跳转。")
        case .deleted:
            return blocked("来源任务已删除，无法跳转。")
        }

        guard context.resolvedSourceArtifactID == sourceArtifactID else {
            return blocked("来源 artifact 身份不匹配，已阻止跳转。")
        }
        switch context.restartIdentity {
        case .notRequired:
            break
        case .revalidated:
            guard context.observedSourceRevision == backlink.sourceRevision else {
                return blocked("来源版本与重启后的记录不匹配，已阻止跳转。")
            }
        case .mismatch:
            return blocked("来源身份与重启后的记录不匹配，已阻止跳转。")
        case .unavailable:
            return blocked("来源身份未完成恢复校验，已阻止跳转。")
        }

        return Self(
            state: .navigable,
            projectID: sourceProjectID,
            taskID: sourceTaskID,
            sourceArtifactID: sourceArtifactID,
            detail: "来源任务已校验，可跳转。",
            actionableError: nil
        )
    }

    static func blocked(_ detail: String) -> Self {
        Self(
            state: .blocked,
            projectID: nil,
            taskID: nil,
            sourceArtifactID: nil,
            detail: detail,
            actionableError: detail
        )
    }
}

/// App-authored, secret-free card state that can be persisted and restored
/// across process restarts. The source backlink is retained as opaque
/// lineage facts; navigation still requires a fresh caller-owned context and
/// an explicit user decision.
struct ArtifactResultCardProjection: Codable, Sendable, Equatable {
    static let serializationSchema = "artifact-source-backlink-card"
    static let serializationRevision = 1

    let schema: String
    let revision: Int
    let cardID: String
    let resultArtifactID: String?
    let sourceBacklink: ArtifactResultCardSourceBacklink?

    private enum CodingKeys: String, CodingKey {
        case schema
        case revision
        case cardID
        case resultArtifactID
        case sourceBacklink
    }

    init(
        cardID: String,
        resultArtifactID: String? = nil,
        sourceBacklink: ArtifactResultCardSourceBacklink? = nil
    ) {
        self.schema = Self.serializationSchema
        self.revision = Self.serializationRevision
        self.cardID = cardID
        self.resultArtifactID = resultArtifactID?.isEmpty == false ? resultArtifactID : nil
        self.sourceBacklink = sourceBacklink
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchema = try container.decodeIfPresent(String.self, forKey: .schema)
        let decodedRevision = try container.decodeIfPresent(Int.self, forKey: .revision)
        if let decodedSchema, decodedSchema != Self.serializationSchema {
            throw DecodingError.dataCorruptedError(
                forKey: .schema,
                in: container,
                debugDescription: "Unsupported artifact source backlink card schema"
            )
        }
        if let decodedRevision,
           decodedRevision < 0 || decodedRevision > Self.serializationRevision {
            throw DecodingError.dataCorruptedError(
                forKey: .revision,
                in: container,
                debugDescription: "Unsupported artifact source backlink card revision"
            )
        }

        let cardID = try container.decode(String.self, forKey: .cardID)
        guard !cardID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .cardID,
                in: container,
                debugDescription: "Artifact source backlink card identity is missing"
            )
        }
        let decodedResultArtifactID = try container.decodeIfPresent(
            String.self,
            forKey: .resultArtifactID
        )
        self.schema = Self.serializationSchema
        self.revision = Self.serializationRevision
        self.cardID = cardID
        self.resultArtifactID = decodedResultArtifactID?.isEmpty == false
            ? decodedResultArtifactID
            : nil
        self.sourceBacklink = try container.decodeIfPresent(
            ArtifactResultCardSourceBacklink.self,
            forKey: .sourceBacklink
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.serializationSchema, forKey: .schema)
        try container.encode(Self.serializationRevision, forKey: .revision)
        try container.encode(cardID, forKey: .cardID)
        try container.encodeIfPresent(resultArtifactID, forKey: .resultArtifactID)
        try container.encodeIfPresent(sourceBacklink, forKey: .sourceBacklink)
    }

    /// Restored cards do not auto-switch projects. Only the explicit
    /// `.switchToSource` decision produces a source target.
    func navigation(
        using context: ArtifactSourceNavigationContext,
        decision: ArtifactSourceNavigationDecision
    ) -> ArtifactSourceNavigationProjection {
        guard decision == .switchToSource else {
            return ArtifactSourceNavigationProjection.notRequested()
        }
        guard let sourceBacklink else {
            return ArtifactSourceNavigationProjection.blocked(
                "结果卡没有来源回链，无法跳转。"
            )
        }
        return sourceBacklink.navigation(using: context)
    }
}
