import Foundation

public enum StagedEnablementRing: Int, CaseIterable, Codable, Sendable {
    case internalPreview = 0
    case a7aBasicAgent
    case toolMCP
    case externalAgent
    case child4
    case child8
    case child16
    case child24
    case child40
    case rc
    case stable

    public var requiresExternalSafety: Bool {
        rawValue >= Self.externalAgent.rawValue
    }

    public var childQuota: Int? {
        switch self {
        case .child4: return 4
        case .child8: return 8
        case .child16: return 16
        case .child24: return 24
        case .child40: return 40
        default: return nil
        }
    }
}

public enum StagedSignalStatus: String, Codable, Equatable, Sendable {
    case green
    case red
    case missing
}

public struct StagedEnablementSignals: Codable, Equatable, Sendable {
    public let error: StagedSignalStatus
    public let performance: StagedSignalStatus
    public let memory: StagedSignalStatus
    public let disk: StagedSignalStatus
    public let processReap: StagedSignalStatus
    public let business: StagedSignalStatus

    public init(
        error: StagedSignalStatus,
        performance: StagedSignalStatus,
        memory: StagedSignalStatus,
        disk: StagedSignalStatus,
        processReap: StagedSignalStatus,
        business: StagedSignalStatus
    ) {
        self.error = error
        self.performance = performance
        self.memory = memory
        self.disk = disk
        self.processReap = processReap
        self.business = business
    }

    public static let allGreen = StagedEnablementSignals(
        error: .green,
        performance: .green,
        memory: .green,
        disk: .green,
        processReap: .green,
        business: .green
    )

    public var blockingSignals: [String] {
        [
            ("error", error),
            ("performance", performance),
            ("memory", memory),
            ("disk", disk),
            ("processReap", processReap),
            ("business", business),
        ]
        .compactMap { $0.1 == .green ? nil : $0.0 }
    }
}

public struct StagedEnablementPrerequisites: Codable, Equatable, Sendable {
    public let isolatedProfileReady: Bool
    public let killSwitchReady: Bool
    public let profileID: String?
    public let killSwitchID: String?

    public init(
        isolatedProfileReady: Bool,
        killSwitchReady: Bool,
        profileID: String? = nil,
        killSwitchID: String? = nil
    ) {
        self.isolatedProfileReady = isolatedProfileReady
        self.killSwitchReady = killSwitchReady
        self.profileID = profileID
        self.killSwitchID = killSwitchID
    }

    public static let internalOnly = StagedEnablementPrerequisites(
        isolatedProfileReady: true,
        killSwitchReady: true
    )

    public static let externalReady = StagedEnablementPrerequisites(
        isolatedProfileReady: true,
        killSwitchReady: true,
        profileID: "isolated-profile",
        killSwitchID: "global-kill-switch"
    )

    public var satisfiesExternalSafety: Bool {
        isolatedProfileReady
            && killSwitchReady
            && !(profileID?.isEmpty ?? true)
            && !(killSwitchID?.isEmpty ?? true)
    }
}

public struct StagedEnablementReceipt: Codable, Equatable, Sendable {
    public let receiptID: String
    public let head: String
    public let ring: StagedEnablementRing
    public let signals: StagedEnablementSignals
    public let prerequisites: StagedEnablementPrerequisites
    public let explicitRollback: Bool
    public let rollbackReason: String?

    public init(
        receiptID: String,
        head: String,
        ring: StagedEnablementRing,
        signals: StagedEnablementSignals,
        prerequisites: StagedEnablementPrerequisites,
        explicitRollback: Bool = false,
        rollbackReason: String? = nil
    ) {
        self.receiptID = receiptID
        self.head = head
        self.ring = ring
        self.signals = signals
        self.prerequisites = prerequisites
        self.explicitRollback = explicitRollback
        self.rollbackReason = rollbackReason
    }
}

public struct StagedEnablementState: Codable, Equatable, Sendable {
    public let currentRing: StagedEnablementRing
    public let failStopReason: [String]?
    public let lastAcceptedReceiptID: String?

    public init(
        currentRing: StagedEnablementRing,
        failStopReason: [String]? = nil,
        lastAcceptedReceiptID: String? = nil
    ) {
        self.currentRing = currentRing
        self.failStopReason = failStopReason
        self.lastAcceptedReceiptID = lastAcceptedReceiptID
    }
}

public enum StagedEnablementError: Error, Equatable, Sendable {
    case staleHead
    case staleRing
    case nonMonotonicPromotion
    case rollbackRequired
    case failStopped([String])
    case redSignals([String])
    case missingExternalSafetyPrerequisite
    case invalidReceipt
}

/// Pure promotion state machine. It records no external side effects.
public final class StagedEnablementController: @unchecked Sendable {
    private let expectedHead: String
    private let lock = NSLock()
    private var state: StagedEnablementState

    public init(
        expectedHead: String,
        initialRing: StagedEnablementRing = .internalPreview
    ) {
        self.expectedHead = expectedHead
        self.state = StagedEnablementState(currentRing: initialRing)
    }

    public func snapshot() -> StagedEnablementState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    @discardableResult
    public func promote(
        to target: StagedEnablementRing,
        receipt: StagedEnablementReceipt
    ) throws -> StagedEnablementState {
        lock.lock()
        defer { lock.unlock() }

        try validateReceipt(receipt, expectedRing: target)
        guard target.rawValue > state.currentRing.rawValue else {
            if target.rawValue < state.currentRing.rawValue {
                throw StagedEnablementError.rollbackRequired
            }
            throw StagedEnablementError.nonMonotonicPromotion
        }
        guard state.failStopReason == nil else {
            throw StagedEnablementError.failStopped(state.failStopReason ?? [])
        }

        let blockingSignals = receipt.signals.blockingSignals
        guard blockingSignals.isEmpty else {
            state = StagedEnablementState(
                currentRing: state.currentRing,
                failStopReason: blockingSignals,
                lastAcceptedReceiptID: state.lastAcceptedReceiptID
            )
            throw StagedEnablementError.redSignals(blockingSignals)
        }

        guard !target.requiresExternalSafety || receipt.prerequisites.satisfiesExternalSafety else {
            throw StagedEnablementError.missingExternalSafetyPrerequisite
        }

        state = StagedEnablementState(
            currentRing: target,
            lastAcceptedReceiptID: receipt.receiptID
        )
        return state
    }

    @discardableResult
    public func rollback(
        to target: StagedEnablementRing,
        receipt: StagedEnablementReceipt
    ) throws -> StagedEnablementState {
        lock.lock()
        defer { lock.unlock() }

        try validateReceipt(receipt, expectedRing: target)
        guard target.rawValue < state.currentRing.rawValue else {
            throw StagedEnablementError.invalidReceipt
        }
        guard receipt.explicitRollback,
              !(receipt.rollbackReason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        else {
            throw StagedEnablementError.rollbackRequired
        }

        state = StagedEnablementState(
            currentRing: target,
            lastAcceptedReceiptID: receipt.receiptID
        )
        return state
    }

    private func validateReceipt(
        _ receipt: StagedEnablementReceipt,
        expectedRing: StagedEnablementRing
    ) throws {
        guard receipt.head == expectedHead else {
            throw StagedEnablementError.staleHead
        }
        guard receipt.ring == expectedRing,
              !receipt.receiptID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw StagedEnablementError.staleRing
        }
    }
}
