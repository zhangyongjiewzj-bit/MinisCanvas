import Foundation
import MinisCore

/// The only field a degraded provider may route the user to for recovery.
/// This is an identifier, never a credential or an error payload.
enum ProviderRecoveryFocus: String, Equatable, Hashable, Sendable {
    case apiKey
}

/// Stable, secret-free destination for the provider recovery action.
/// Provider IDs are canonicalized once so case-only changes cannot move focus
/// to a different row or make the action identity change between renders.
struct ProviderRecoveryDestination: Identifiable, Equatable, Hashable, Sendable {
    let providerID: String
    let focus: ProviderRecoveryFocus

    init?(providerID: String, focus: ProviderRecoveryFocus = .apiKey) {
        let canonical = EnvVarStore.canonicalName(providerID)
        guard !canonical.isEmpty else { return nil }
        self.providerID = canonical
        self.focus = focus
    }

    var id: String {
        "provider-recovery:\(providerID):\(focus.rawValue)"
    }
}

/// Typed lifecycle for one provider recovery journey. A recovery attempt is
/// never considered ready from navigation alone; readiness must be reported by
/// the provider launch boundary through `apply(status:)`.
enum ProviderRecoveryNavigationState: String, Codable, Equatable, Sendable {
    case idle
    case retrying
    case degraded
    case ready
    case exhausted

    var canRetry: Bool { self == .idle || self == .degraded }
}

/// Identity-bound, bounded retry state machine shared by recovery navigation
/// and the launch coordinator. It prevents an old route or a retry budget
/// overflow from manufacturing a false-ready provider status.
struct ProviderRecoveryNavigationMachine: Equatable, Sendable {
    let providerID: String
    let maxAttempts: Int
    private(set) var attempts: Int = 0
    private(set) var state: ProviderRecoveryNavigationState = .idle

    init?(providerID: String, maxAttempts: Int = 3) {
        guard let destination = ProviderRecoveryDestination(providerID: providerID) else {
            return nil
        }
        self.providerID = destination.providerID
        self.maxAttempts = max(1, min(maxAttempts, 3))
    }

    /// Starts at most one bounded recovery attempt. Repeated calls while the
    /// provider is retrying, ready, or exhausted are rejected.
    mutating func beginRetry() -> Bool {
        guard state.canRetry, attempts < maxAttempts else {
            if attempts >= maxAttempts { state = .exhausted }
            return false
        }
        attempts += 1
        state = .retrying
        return true
    }

    /// Applies only a status for this canonical provider and only while a
    /// retry is in flight. A route cannot transition itself to `.ready`.
    @discardableResult
    mutating func apply(status: ProviderLaunchStatus) -> Bool {
        guard status.providerID.caseInsensitiveCompare(providerID) == .orderedSame,
              state == .retrying else {
            return false
        }
        switch status.state {
        case .ready:
            state = .ready
        case .degraded:
            state = attempts >= maxAttempts ? .exhausted : .degraded
        }
        return true
    }
}

/// Pure resolver used by SettingsCenter and contract tests. A recovery route
/// exists only for a known degraded provider; healthy and unknown providers
/// intentionally produce no action.
enum ProviderRecoveryNavigation {
    static func destination(
        providerID: String,
        status: ProviderLaunchStatus?,
        availableProviderIDs: [String]
    ) -> ProviderRecoveryDestination? {
        let canonicalProviderID = EnvVarStore.canonicalName(providerID)
        let matchingProviders = availableProviderIDs.filter {
            EnvVarStore.canonicalName($0) == canonicalProviderID
        }
        guard let status,
              !canonicalProviderID.isEmpty,
              matchingProviders.count == 1,
              EnvVarStore.canonicalName(status.providerID) == canonicalProviderID,
              status.state.isRecoverable,
              let destination = ProviderRecoveryDestination(providerID: canonicalProviderID) else {
            return nil
        }
        return destination
    }
}
