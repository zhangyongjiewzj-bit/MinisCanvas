import Foundation

/// Safe lifecycle states for a catalog projection. `degraded` still contains
/// valid siblings, but tells an existing consumer that the scan was partial.
enum SkillCatalogRefreshStatus: String, Equatable, Sendable {
    case unscanned
    case refreshing
    case ready
    case degraded
    case invalidated

    var stableSummary: String {
        switch self {
        case .unscanned: return "技能目录：未扫描"
        case .refreshing: return "技能目录：刷新中"
        case .ready: return "技能目录：正常"
        case .degraded: return "技能目录：部分项目被拒绝"
        case .invalidated: return "技能目录：待刷新"
        }
    }
}

/// Bounded retry projection for a partial refresh. A caller may offer one
/// retry after a degraded scan; repeated failures become exhausted instead of
/// creating an unbounded rescan loop.
enum SkillCatalogRefreshRetryState: String, Equatable, Sendable {
    case notNeeded
    case retryAvailable
    case exhausted

    var stableSummary: String {
        switch self {
        case .notNeeded: return "技能目录：无需重试"
        case .retryAvailable: return "技能目录：可重试一次"
        case .exhausted: return "技能目录：重试次数已用尽"
        }
    }
}

struct SkillCatalogRefreshRetryBudget: Equatable, Sendable {
    static let maxDegradedAttempts = 2
    private(set) var degradedAttempts = 0
    private var scopeKey = ""

    /// Bind the budget to the input scope that produced its prior failures.
    /// A new root/state scope starts with a fresh retry allowance.
    mutating func bind(scopeKey: String) -> Bool {
        guard self.scopeKey != scopeKey else { return false }
        self.scopeKey = scopeKey
        degradedAttempts = 0
        return true
    }

    /// A cancelled projection has no accepted result to retry. Preserve the
    /// scope identity while giving its next foreground reload a fresh budget.
    mutating func resetAfterCancellation() {
        degradedAttempts = 0
    }

    mutating func record(status: SkillCatalogRefreshStatus) -> SkillCatalogRefreshRetryState {
        guard status == .degraded else {
            degradedAttempts = 0
            return .notNeeded
        }
        degradedAttempts = min(degradedAttempts + 1, Self.maxDegradedAttempts)
        return degradedAttempts < Self.maxDegradedAttempts ? .retryAvailable : .exhausted
    }
}

/// The identity of one asynchronous catalog projection. A later generation
/// or a different scope invalidates every result carrying an older token.
struct SkillCatalogRefreshToken: Equatable, Sendable {
    let generation: UInt64
    let scopeKey: String
}

/// Small value-only gate shared by settings and picker refresh consumers.
/// Keeping the gate independent from SwiftUI makes stale-result behavior
/// testable without starting an App, WebView or package runner.
struct SkillCatalogRefreshGate: Sendable {
    private(set) var generation: UInt64 = 0
    private(set) var scopeKey = ""

    mutating func begin(scopeKey: String) -> SkillCatalogRefreshToken {
        generation &+= 1
        self.scopeKey = scopeKey
        return SkillCatalogRefreshToken(generation: generation, scopeKey: scopeKey)
    }

    mutating func invalidate(scopeKey: String) {
        generation &+= 1
        self.scopeKey = scopeKey
    }

    /// Cancel only the currently active projection. A newer refresh already
    /// owns the gate and must keep its state when an older task is cancelled.
    mutating func cancel(_ token: SkillCatalogRefreshToken) -> Bool {
        guard accepts(token) else { return false }
        generation &+= 1
        return true
    }

    func accepts(_ token: SkillCatalogRefreshToken) -> Bool {
        token.generation == generation && token.scopeKey == scopeKey
    }
}

/// Value-only gate for the process-wide picker cache. A scope transition
/// invalidates every in-flight scan before it can republish an older report.
struct SkillCatalogCacheRequestToken: Equatable, Sendable {
    let generation: UInt64
    let scopeKey: String
}

struct SkillCatalogCacheRequestGate: Sendable {
    private(set) var generation: UInt64 = 0
    private(set) var scopeKey = ""

    mutating func begin(scopeKey: String) -> SkillCatalogCacheRequestToken {
        generation &+= 1
        self.scopeKey = scopeKey
        return SkillCatalogCacheRequestToken(generation: generation, scopeKey: scopeKey)
    }

    mutating func invalidate() {
        generation &+= 1
        scopeKey = ""
    }

    func accepts(_ token: SkillCatalogCacheRequestToken) -> Bool {
        token.generation == generation && token.scopeKey == scopeKey
    }
}

/// A stable opaque identity for a scan input. Only the digest is retained or
/// exposed, so diagnostic/status surfaces cannot disclose an absolute path.
enum SkillCatalogScopeKey {
    static func make(
        appSkillsRoot: URL,
        servers: [String] = [],
        enabledStates: [String: Bool] = [:],
        directoryRoots: [URL] = []
    ) -> String {
        var values = [appSkillsRoot.standardizedFileURL.path]
        values.append(contentsOf: directoryRoots.map { $0.standardizedFileURL.path }.sorted())
        values.append(contentsOf: servers.sorted())
        values.append(contentsOf: enabledStates.keys.sorted().map { key in
            "\(key)=\(enabledStates[key] == true ? "1" : "0")"
        })

        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in values.joined(separator: "\u{1f}").utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "scope-\(String(hash, radix: 16))"
    }
}

/// Picker cache value plus the report and lifecycle identity that produced it.
/// The old array-only APIs remain compatibility shells over this snapshot.
struct SkillCatalogCacheSnapshot: Equatable, Sendable {
    let catalog: [PickerCatalogItem]
    let diagnostics: SkillCatalogDiagnosticReport
    let status: SkillCatalogRefreshStatus
    let generation: UInt64
    let scopeKey: String

    var stableSummary: String {
        "\(status.stableSummary)；\(diagnostics.stableSummary)"
    }
}
