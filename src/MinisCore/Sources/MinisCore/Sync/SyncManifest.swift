import Foundation

// MARK: - SyncScope

/// 可同步的数据域。对应 MinisCore 各 Store：
/// sessions → SessionStore / memories → MemoryStore / skills → SkillStore /
/// settings → SettingsStore。
public enum SyncScope: String, Codable, CaseIterable, Sendable {
    case sessions
    case memories
    case skills
    case settings
}

extension SyncScope {
    /// 数据域中文名（F14 P1-3：UI 提示「哪个域失败」用）。
    public var displayName: String {
        switch self {
        case .sessions: return "会话"
        case .memories: return "记忆"
        case .skills: return "技能"
        case .settings: return "设置"
        }
    }
}

// MARK: - SyncManifest

/// 快照清单：随每个导出的快照一起序列化，供导入端校验。
///
/// 继承 OpenMinis 手机端 Sync 设计（Agent/Sync/V2/SyncCore.swift 的
/// SyncManifest 概念），macOS 简化版只保留核心字段：
/// `version` / `exportedAt` / `deviceName` / `scopes`。
/// `dirtyScopes` 为可选附加字段：导出时把 SyncManager 记录的
/// dirty 标记一并带上，导入端可据此提示"哪些域有未同步改动"。
public struct SyncManifest: Codable, Equatable, Sendable {
    /// 当前快照格式版本。导入端校验 `version == currentVersion`。
    public static let currentVersion = 1

    /// The canonical application that produces new MinisCanvas snapshots.
    /// Older v1 snapshots have no source marker and remain importable.
    public static let applicationIdentifier = "com.miniscanvas.MinisCanvas"

    /// Protected `.minissync` outer-container version. The inner manifest
    /// remains at `currentVersion` after authentication and decryption.
    public static let protectedContainerVersion = 2

    /// 快照格式版本。
    public let version: Int
    /// 导出时间。
    public let exportedAt: Date
    /// 导出设备名（macOS 版手动导出/导入替代 iCloud 的设备标识）。
    public let deviceName: String
    /// Exporting application identity, when present. This is a format marker,
    /// not an authentication of the exporting device or user.
    public let sourceApplicationID: String?
    /// 快照包含的数据域（SyncScope.rawValue 数组）。
    public let scopes: [String]
    /// 本次导出实际携带的、导出时仍处于 dirty 状态的数据域（自动同步
    /// 策略：onChange 标记 dirty，导出时带上）。可选字段，旧快照无此键
    /// 时解码为 nil。
    public var dirtyScopes: [String]?

    public init(
        version: Int = SyncManifest.currentVersion,
        exportedAt: Date = Date(),
        deviceName: String,
        sourceApplicationID: String? = SyncManifest.applicationIdentifier,
        scopes: [String],
        dirtyScopes: [String]? = nil
    ) {
        self.version = version
        self.exportedAt = exportedAt
        self.deviceName = deviceName
        self.sourceApplicationID = sourceApplicationID
        self.scopes = scopes
        self.dirtyScopes = dirtyScopes
    }

    /// 校验快照：版本匹配 + scope 非空 +（可选）必需 scope 完整。
    ///
    /// - Parameters:
    ///   - expectedVersion: 期望的格式版本，默认 `currentVersion`。
    ///   - requiredScopes: 调用方要求快照必须包含的域；为 nil 时只做
    ///     版本 + 非空校验。
    public func validate(
        expectedVersion: Int = SyncManifest.currentVersion,
        requiredScopes: Set<SyncScope>? = nil
    ) throws {
        guard version == expectedVersion else {
            throw SyncManifestError.unsupportedVersion(expected: expectedVersion, found: version)
        }
        if let sourceApplicationID,
           sourceApplicationID != Self.applicationIdentifier {
            throw SyncManifestError.wrongSourceApplication(sourceApplicationID)
        }
        guard !scopes.isEmpty else {
            throw SyncManifestError.emptyScopes
        }
        if let required = requiredScopes {
            let present = Set(scopes)
            let missing = Set(required.map(\.rawValue)).subtracting(present)
            if !missing.isEmpty {
                throw SyncManifestError.missingScopes(missing.sorted())
            }
        }
    }
}

// MARK: - Errors

public enum SyncManifestError: Error, Equatable, Sendable {
    /// 快照版本与当前格式不匹配（旧版或未知格式）。
    case unsupportedVersion(expected: Int, found: Int)
    /// Snapshot explicitly identifies a different application as its source.
    case wrongSourceApplication(String)
    /// 快照未声明任何数据域。
    case emptyScopes
    /// 快照缺少必需的数据域。
    case missingScopes([String])
    /// 快照清单声明了某域，但载荷中缺少对应数据（scope 不完整）。
    case incompletePayload([String])
    /// 数据无法解析为合法快照。
    case invalidSnapshot(String)
}

// MARK: - 导入结果（F14 P1-2：写盘错误不再吞）

/// 单个数据域的恢复结果（F14 P1-2）。
///
/// `importSnapshot` 逐域恢复，每域的写盘错误独立捕获：
/// 某域失败不影响其余域继续恢复，结果逐域记录。
public struct SyncScopeResult: Sendable {
    /// 本次实际尝试恢复的数据域。
    public let scope: SyncScope
    /// 该域写盘是否全部成功。
    public let succeeded: Bool
    /// 该域内失败的明细（成功时为空）。
    /// sessions/skills 按条目记录（如 `s-1`、`写作规范`），
    /// memories/settings 为整域一条（`facts.json` / `settings`）。
    public let failures: [SyncScopeFailure]

    public init(scope: SyncScope, succeeded: Bool, failures: [SyncScopeFailure]) {
        self.scope = scope
        self.succeeded = succeeded
        self.failures = failures
    }
}

/// 单个域内一条恢复失败明细（条目级，F14 P1-2）。
public struct SyncScopeFailure: Sendable {
    /// 失败条目的标识（会话 id / 技能 id；整域写失败为域级描述如 `facts.json`）。
    public let item: String
    /// 底层错误描述。
    public let reason: String

    public init(item: String, reason: String) {
        self.item = item
        self.reason = reason
    }
}

/// 一次 `importSnapshot` 的逐域结果汇总（F14 P1-2）。
///
/// 成功域照常落盘；失败域的明细在 `scopeResults` 里可查。
/// `importSnapshot` 在存在失败域时抛 `SyncImportError`（携带本结构），
/// 调用方既可 catch 拿明细，也可在抛错前读取返回值（`@discardableResult`）。
public struct SyncImportResult: Sendable {
    /// 校验通过的快照清单。
    public let manifest: SyncManifest
    /// 逐域恢复结果（仅包含本次实际尝试恢复的域）。
    public let scopeResults: [SyncScopeResult]

    public init(manifest: SyncManifest, scopeResults: [SyncScopeResult]) {
        self.manifest = manifest
        self.scopeResults = scopeResults
    }

    /// 全部尝试恢复的域是否都成功。
    public var allSucceeded: Bool { scopeResults.allSatisfy(\.succeeded) }

    /// 恢复失败的数据域（按声明顺序）。
    public var failedScopes: [SyncScope] {
        scopeResults.filter { !$0.succeeded }.map(\.scope)
    }

    /// 恢复成功的数据域（按声明顺序）。
    public var succeededScopes: [SyncScope] {
        scopeResults.filter(\.succeeded).map(\.scope)
    }

    /// 面向用户的中文摘要（F14 P1-3：设置中心导入提示用）。
    /// 全部成功：「导入成功：会话、记忆、技能、设置」；
    /// 部分失败：「会话、技能 导入成功；记忆、设置 导入失败」。
    public var summaryMessage: String {
        let okNames = succeededScopes.map(\.displayName)
        let badNames = failedScopes.map(\.displayName)
        if badNames.isEmpty {
            return "导入成功：\(okNames.joined(separator: "、"))"
        }
        if okNames.isEmpty {
            return "导入失败：\(badNames.joined(separator: "、"))"
        }
        return "\(okNames.joined(separator: "、")) 导入成功；\(badNames.joined(separator: "、")) 导入失败"
    }
}

/// `importSnapshot` 存在失败域时抛出的错误（F14 P1-2）。
///
/// 携带逐域结果 `result`：成功域的数据已落盘生效，失败域明细可查。
/// 与 manifest 校验类错误（版本/缺载荷）区分：校验失败不写任何数据，
/// 本错误表示「部分恢复成功、部分写盘失败」。
public struct SyncImportError: Error, Sendable {
    /// 逐域结果（含成功域与失败域明细）。
    public let result: SyncImportResult

    public init(result: SyncImportResult) {
        self.result = result
    }

    /// 恢复失败的数据域。
    public var failedScopes: [SyncScope] { result.failedScopes }

    /// 面向用户的中文错误描述（含失败域名 + 每域首条失败原因）。
    public var message: String {
        let parts: [String] = result.scopeResults.compactMap { scopeResult in
            guard !scopeResult.succeeded else { return nil }
            let reasons = scopeResult.failures.map { "\($0.item): \($0.reason)" }
            let detail = reasons.isEmpty ? "" : "（\(reasons.joined(separator: "；"))）"
            return "\(scopeResult.scope.displayName)\(detail)"
        }
        return "部分数据域恢复失败：\(parts.joined(separator: "、"))"
    }
}
