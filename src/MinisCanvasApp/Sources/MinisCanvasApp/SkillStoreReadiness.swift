import Foundation
import MinisCore

/// Waits for the canonical App store without reading or importing an external source.
enum SkillStoreReadiness {
    enum DeploymentStatus: Equatable, Sendable {
        case pending
        case ready(imported: [String])
        case failed(failures: Int)
    }

    struct PreparedDeployment: Sendable {
        let status: DeploymentStatus
        let injector: SkillInjector?
        let terminalCapture: SkillInjector.TurnPreparation?
    }

    /// Shared app-owned work: cancelling a turn cannot cancel deployment for
    /// every other turn. No directory query or registry construction runs in
    /// the caller's first UI frame.
    final class Deployment: Sendable {
        private final class TerminalState: @unchecked Sendable {
            private let lock = NSLock()
            private var prepared: PreparedDeployment?
            func publish(_ value: PreparedDeployment) { lock.withLock { prepared = value } }
            func snapshot() -> PreparedDeployment? { lock.withLock { prepared } }
        }
        let task: Task<PreparedDeployment, Never>
        private let terminal: TerminalState

        init(store: SkillStore) {
            let terminal = TerminalState()
            self.terminal = terminal
            task = Task.detached(priority: .userInitiated) {
                await store.waitForInitialLoad()
                guard store.isInitialLoadComplete else {
                    let prepared = PreparedDeployment(status: .failed(failures: 1),
                        injector: nil, terminalCapture: nil)
                    terminal.publish(prepared)
                    return prepared
                }

                let injector = SkillInjector(store: store)
                let prepared = PreparedDeployment(status: .ready(imported: []),
                    injector: injector, terminalCapture: injector.captureTurnPreparation())
                terminal.publish(prepared)
                return prepared
            }
        }

        var hasFailed: Bool {
            guard let prepared = terminal.snapshot() else { return false }
            if case .failed = prepared.status { return true }
            return false
        }

        func preparationForTurn() -> TurnPreparation {
            // Completed deployments use the usual cheap request-time capture.
            // A turn submitted while deployment is pending may adopt only its
            // exact terminal capture, never later live-store changes.
            TurnPreparation(deployment: self,
                immediateCapture: terminal.snapshot()?.injector?.captureTurnPreparation())
        }
    }

    /// The turn freezes the completed deployment's authority exactly once.
    /// The MainActor callback only compares this captured authority; it never
    /// waits for a disk reader or initializes a registry.
    final class TurnPreparation: @unchecked Sendable {
        private let deployment: Deployment
        private let lock = NSLock()
        private var captured: SkillInjector.TurnPreparation?
        private let immediateCapture: SkillInjector.TurnPreparation?

        fileprivate init(deployment: Deployment,
                         immediateCapture: SkillInjector.TurnPreparation?) {
            self.deployment = deployment
            self.immediateCapture = immediateCapture
        }

        func capture() async -> SkillInjector.TurnPreparation? {
            guard !Task.isCancelled else { return nil }
            let capture: SkillInjector.TurnPreparation?
            if let immediateCapture {
                capture = immediateCapture
            } else {
                let prepared = await deployment.task.value
                capture = prepared.terminalCapture
            }
            guard !Task.isCancelled, let capture else { return nil }
            lock.withLock { captured = capture }
            return capture
        }

        func matchesCurrentStore(_ store: SkillStore) -> Bool {
            lock.withLock { captured?.matchesCurrentStore(store) ?? false }
        }
    }

}
