import Foundation

/// Actions understood by the browser production seam.  The allowlist is
/// deliberately independent from page text or model-provided descriptions.
public enum BrowserAction: String, CaseIterable, Codable, Sendable {
    case navigate
    case read
    case back
    case screenshot
    case click
    case type
    case download
    case upload

    public var isWriteAction: Bool {
        switch self {
        case .click, .type, .download, .upload:
            return true
        case .navigate, .read, .back, .screenshot:
            return false
        }
    }
}

/// Explicit browser capability/approval supplied by the production caller.
/// The default grant can only expose read actions.  A page description and an
/// unknown action are never interpreted as a capability grant.
public struct BrowserCapabilityGrant: Codable, Equatable, Sendable {
    public static let writeCapability = "browser.write"

    public let capability: String?
    public let approvalReceipt: String?

    public init(capability: String? = nil, approvalReceipt: String? = nil) {
        self.capability = capability?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.approvalReceipt = approvalReceipt?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static let readOnly = BrowserCapabilityGrant()

    public var permitsWriteActions: Bool {
        capability == Self.writeCapability && !(approvalReceipt?.isEmpty ?? true)
    }

    public func allows(action: String) -> Bool {
        guard let action = BrowserAction(rawValue: action) else { return false }
        return !action.isWriteAction || permitsWriteActions
    }

    public func allowedActions() -> [BrowserAction] {
        BrowserAction.allCases.filter { allows(action: $0.rawValue) }
    }
}

/// 生产 PolicyRuntime GoalEnvelope 的保守默认值（S6）。
///
/// 收紧背景：生产装配（BridgeStore.attachProductionServices）此前直接写死
/// 宽松封套 —— budget: 1_000_000（近似无限）、deadline: .distantFuture
/// （永不过期）、autonomyLevel: .l3（完整自主）、networkDomains: []
/// （fail-closed 但未成文）。本类型把这些默认集中一处并收紧为有界、有限、
/// 低自主的保守值。
///
/// 兼容纪律：默认只作用于「未显式配置」的路径 —— 任何显式传入的
/// ProductionPolicyDefaults（或调用方自行构造的 GoalEnvelope）原样生效，
/// 本类型不参与、不改写显式配置。
public struct ProductionPolicyDefaults: Codable, Equatable, Sendable {
    /// 生产装配的单一默认实例（App 启动时使用一次；可注入覆盖）。
    public static let `default` = ProductionPolicyDefaults()

    /// Browser automation is read-only unless the caller supplies both the
    /// exact write capability and a non-empty approval receipt.
    public static let browserCapability = BrowserCapabilityGrant.readOnly

    /// 单目标请求预算（estimatedCost 单位）。默认 requestBuilder 每次调用计 1；
    /// 1M ≈ 无上限，失控循环可在耗尽整个会话前不被察觉。有界默认（10_000）
    /// 保留充足真实会话余量，同时让 runaway loop 在 budgetExceeded 处停下。
    public var budget: Int

    /// 封套创建时套用的有限时限：deadline = createdAt + deadlineHorizon。
    /// .distantFuture 永不失效；有限默认把一次运行限制在会话长度量级。
    public var deadlineHorizon: TimeInterval

    /// 自主权上限。.l3 允许请求自行升到完整自主；.l1 把中/高风险操作
    /// 留在审批门后（请求默认 .l0，仍需逐个过 ApprovalGate）。
    public var autonomyLevel: AutonomyLevel

    /// 默认网络域名白名单。空 = fail-closed：未显式配置时不放行任何网络调用。
    public var networkDomains: Set<String>

    public init(
        budget: Int = 10_000,
        deadlineHorizon: TimeInterval = 4 * 60 * 60,
        autonomyLevel: AutonomyLevel = .l2,
        networkDomains: Set<String> = []
    ) {
        self.budget = budget
        self.deadlineHorizon = deadlineHorizon
        self.autonomyLevel = autonomyLevel
        self.networkDomains = networkDomains
    }

    /// 相对 createdAt 的有限 deadline（生产封套创建时调用一次，goal/lease 共用）。
    public func deadline(from createdAt: Date = Date()) -> Date {
        createdAt.addingTimeInterval(deadlineHorizon)
    }
}
