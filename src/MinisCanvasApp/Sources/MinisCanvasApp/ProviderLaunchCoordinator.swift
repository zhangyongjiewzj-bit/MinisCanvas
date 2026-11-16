import Foundation
import MinisCore

/// The result of constructing one provider during the app's launch/turn
/// boundary.  A provider failure is deliberately represented as a small,
/// secret-free state instead of being allowed to escape into the composition
/// root and take down the window.
enum ProviderLaunchFailure: Equatable, Sendable {
    case credentialUnavailable
    case keychainUnavailable
    case initializationFailed
}

enum ProviderLaunchState: Equatable, Sendable {
    case ready
    case degraded(ProviderLaunchFailure)

    var isRecoverable: Bool {
        if case .degraded = self { return true }
        return false
    }
}

struct ProviderLaunchStatus: Equatable, Sendable {
    let providerID: String
    let state: ProviderLaunchState
}

/// Retry budget for provider construction. The upper bound is intentionally
/// small so a broken provider cannot block launch or create an unbounded retry
/// loop. A provider is marked ready only after a factory call succeeds.
struct ProviderRecoveryRetryPolicy: Equatable, Sendable {
    let maxAttempts: Int

    init(maxAttempts: Int = 3) {
        self.maxAttempts = max(1, min(maxAttempts, 3))
    }

    static let singleAttempt = Self(maxAttempts: 1)
    static let `default` = Self(maxAttempts: 3)
}

/// Immutable, secret-free projection shared by Settings and each turn's
/// runtime snapshot.  Sorting makes the projection deterministic even when
/// the source is a dictionary whose iteration order is not contractual.
struct ProviderLaunchSnapshot: Equatable, Sendable {
    let statuses: [ProviderLaunchStatus]

    static let empty = Self(statuses: [])

    init(statuses: [ProviderLaunchStatus]) {
        self.statuses = statuses.sorted {
            $0.providerID.localizedCaseInsensitiveCompare($1.providerID)
                == .orderedAscending
        }
    }

    func status(for providerID: String) -> ProviderLaunchStatus? {
        statuses.first {
            $0.providerID.caseInsensitiveCompare(providerID) == .orderedSame
        }
    }

    var readyProviderIDs: [String] {
        statuses.compactMap { status in
            if case .ready = status.state { return status.providerID }
            return nil
        }
    }

    var degradedProviderIDs: [String] {
        statuses.compactMap { status in
            if case .degraded = status.state { return status.providerID }
            return nil
        }
    }
}

/// Best-effort provider construction for the launch boundary.
///
/// The coordinator has no UI, network, or Keychain side effects of its own;
/// callers supply the already-scoped construction closures.  Each candidate
/// is isolated, so a denied/missing credential or a provider-specific factory
/// error marks only that provider as degraded.  The returned core can still
/// present a window and use any provider that did initialize.
enum ProviderLaunchCoordinator {
    struct Candidate<Provider> {
        let providerID: String
        let initialize: () throws -> Provider

        init(providerID: String, initialize: @escaping () throws -> Provider) {
            self.providerID = providerID
            self.initialize = initialize
        }
    }

    struct Result<Provider> {
        let ready: [Provider]
        let statuses: [ProviderLaunchStatus]

        var snapshot: ProviderLaunchSnapshot {
            ProviderLaunchSnapshot(statuses: statuses)
        }

        /// Provider health is not a window-health gate.  The app remains
        /// usable for settings, session, and other healthy providers even if
        /// every external provider is degraded.
        var canPresentWindow: Bool { true }

        var degradedProviderIDs: [String] {
            statuses.compactMap { status in
                if case .degraded = status.state { return status.providerID }
                return nil
            }
        }
    }

    static func initialize<Provider>(
        _ candidates: [Candidate<Provider>]
    ) -> Result<Provider> {
        initialize(candidates, retryPolicy: .singleAttempt)
    }

    /// Initializes each provider with a bounded, provider-local retry budget.
    /// A `.ready` status is emitted only from a successful factory invocation;
    /// exhausting retries remains degraded and never falls through to ready.
    static func initialize<Provider>(
        _ candidates: [Candidate<Provider>],
        retryPolicy: ProviderRecoveryRetryPolicy
    ) -> Result<Provider> {
        var ready: [Provider] = []
        var statuses: [ProviderLaunchStatus] = []
        statuses.reserveCapacity(candidates.count)

        for candidate in candidates {
            guard var machine = ProviderRecoveryNavigationMachine(
                providerID: candidate.providerID,
                maxAttempts: retryPolicy.maxAttempts
            ) else {
                statuses.append(
                    ProviderLaunchStatus(
                        providerID: candidate.providerID,
                        state: .degraded(.initializationFailed)
                    )
                )
                continue
            }
            var finalStatus: ProviderLaunchStatus?
            while machine.beginRetry() {
                do {
                    let value = try candidate.initialize()
                    ready.append(value)
                    let status = ProviderLaunchStatus(
                        providerID: candidate.providerID,
                        state: .ready
                    )
                    finalStatus = status
                    _ = machine.apply(status: status)
                    break
                } catch {
                    let status = ProviderLaunchStatus(
                        providerID: candidate.providerID,
                        state: .degraded(failure(for: error))
                    )
                    finalStatus = status
                    _ = machine.apply(status: status)
                }
            }
            if let finalStatus {
                statuses.append(finalStatus)
            } else {
                statuses.append(
                    ProviderLaunchStatus(
                        providerID: candidate.providerID,
                        state: .degraded(.initializationFailed)
                    )
                )
            }
        }

        return Result(ready: ready, statuses: statuses)
    }

    /// Collapse implementation errors at the boundary.  No error text or
    /// credential material is retained in the launch projection.
    static func failure(for error: Error) -> ProviderLaunchFailure {
        if let error = error as? EnvVarPersistenceError {
            switch error {
            case .keychainReadMissing, .keychainWriteFailed, .keychainDeleteFailed,
                 .keychainRollbackFailed:
                return .keychainUnavailable
            case .keychainReadDenied, .keychainReadFailed:
                return .keychainUnavailable
            case .missingCredential:
                return .credentialUnavailable
            case .invalidName, .metadataWriteFailed:
                return .initializationFailed
            }
        }
        if let error = error as? ProviderFactory.FactoryError {
            if case .noCredentials = error { return .credentialUnavailable }
            return .initializationFailed
        }
        return .initializationFailed
    }
}

/// Minimal composition-root seam for dependencies that may fail while the
/// first window is being assembled.  It is intentionally generic and has no
/// knowledge of BridgeStore or provider secrets, so a disposable/degraded
/// dependency can keep the UI alive while the affected feature reports its
/// own health.
enum AppLaunchCoordinator {
    static func resolve<Value>(
        primary: () throws -> Value,
        degraded: () -> Value
    ) -> Value {
        do {
            return try primary()
        } catch {
            return degraded()
        }
    }
}
