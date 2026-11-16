import Foundation

/// Stable, non-sensitive classes for completed skill-injection builds.
///
/// The enum deliberately contains no request text, skill names, paths, or
/// content hashes. It is suitable for aggregate telemetry and diagnostics.
public enum SkillInjectionBuildErrorClass: String, Codable, Equatable, Sendable {
    case none
    case noEligibleCandidates
    case budgetDisabled
    case allCandidatesRejected
    case partiallyRejected
    case registryRejected
}

/// A monotonic time source used by skill-injection measurements.
public protocol SkillInjectionMonotonicClock: Sendable {
    func nowNanoseconds() -> UInt64
}

public struct SystemSkillInjectionMonotonicClock: SkillInjectionMonotonicClock {
    public init() {}

    public func nowNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}

/// One completed build sample. It contains counts and an elapsed duration only;
/// no request, body, skill identity, or secret is retained.
public struct SkillInjectionPerformanceSample: Codable, Equatable, Sendable {
    public let durationNanoseconds: UInt64
    public let eligibleCandidateCount: Int
    public let errorClass: SkillInjectionBuildErrorClass

    public init(
        durationNanoseconds: UInt64,
        eligibleCandidateCount: Int,
        errorClass: SkillInjectionBuildErrorClass
    ) {
        self.durationNanoseconds = durationNanoseconds
        self.eligibleCandidateCount = max(0, eligibleCandidateCount)
        self.errorClass = errorClass
    }
}

/// A value snapshot of bounded skill-injection performance telemetry.
public struct SkillInjectionPerformanceSnapshot: Codable, Equatable, Sendable {
    public let capacity: Int
    public let eligibleBuildCount: UInt64
    public let eligibleCandidateCount: UInt64
    public let completedBuildCount: UInt64
    public let completedDurationNanoseconds: UInt64
    public let errorCounts: [String: UInt64]
    public let samples: [SkillInjectionPerformanceSample]

    public init(
        capacity: Int,
        eligibleBuildCount: UInt64,
        eligibleCandidateCount: UInt64,
        completedBuildCount: UInt64,
        completedDurationNanoseconds: UInt64,
        errorCounts: [String: UInt64],
        samples: [SkillInjectionPerformanceSample]
    ) {
        self.capacity = capacity
        self.eligibleBuildCount = eligibleBuildCount
        self.eligibleCandidateCount = eligibleCandidateCount
        self.completedBuildCount = completedBuildCount
        self.completedDurationNanoseconds = completedDurationNanoseconds
        self.errorCounts = errorCounts
        self.samples = samples
    }
}

/// Thread-safe, fixed-capacity metrics for `SkillInjector` builds.
///
/// Counters are cumulative for the lifetime of this collector while `samples`
/// is a ring containing only the most recent `capacity` completed builds.
public final class SkillInjectionPerformanceMetrics: @unchecked Sendable {
    public struct MeasurementToken: Sendable {
        fileprivate let startNanoseconds: UInt64

        fileprivate init(startNanoseconds: UInt64) {
            self.startNanoseconds = startNanoseconds
        }
    }

    private let lock = NSLock()
    private let clock: any SkillInjectionMonotonicClock
    private var ring: [SkillInjectionPerformanceSample] = []
    private var nextRingIndex = 0
    private var eligibleBuilds: UInt64 = 0
    private var eligibleCandidates: UInt64 = 0
    private var completedBuilds: UInt64 = 0
    private var completedDuration: UInt64 = 0
    private var errors: [String: UInt64] = [:]

    public let capacity: Int

    public init(
        capacity: Int = 64,
        clock: any SkillInjectionMonotonicClock = SystemSkillInjectionMonotonicClock()
    ) {
        self.capacity = max(1, capacity)
        self.clock = clock
        ring.reserveCapacity(self.capacity)
    }

    public func beginBuild() -> MeasurementToken {
        MeasurementToken(startNanoseconds: clock.nowNanoseconds())
    }

    /// Completes one build and records only bounded, non-sensitive metrics.
    public func complete(
        _ token: MeasurementToken,
        eligibleCandidateCount: Int,
        errorClass: SkillInjectionBuildErrorClass
    ) {
        let end = clock.nowNanoseconds()
        let duration = end >= token.startNanoseconds
            ? end - token.startNanoseconds
            : 0
        let eligible = max(0, eligibleCandidateCount)
        let sample = SkillInjectionPerformanceSample(
            durationNanoseconds: duration,
            eligibleCandidateCount: eligible,
            errorClass: errorClass
        )

        lock.lock()
        defer { lock.unlock() }
        if eligible > 0 {
            eligibleBuilds &+= 1
            eligibleCandidates &+= UInt64(eligible)
        }
        completedBuilds &+= 1
        completedDuration &+= duration
        if errorClass != .none {
            errors[errorClass.rawValue, default: 0] &+= 1
        }
        if ring.count < capacity {
            ring.append(sample)
        } else {
            ring[nextRingIndex] = sample
            nextRingIndex = (nextRingIndex + 1) % capacity
        }
    }

    public func snapshot() -> SkillInjectionPerformanceSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let orderedSamples: [SkillInjectionPerformanceSample]
        if ring.count < capacity || nextRingIndex == 0 {
            orderedSamples = ring
        } else {
            orderedSamples = Array(ring[nextRingIndex...]) + Array(ring[..<nextRingIndex])
        }
        return SkillInjectionPerformanceSnapshot(
            capacity: capacity,
            eligibleBuildCount: eligibleBuilds,
            eligibleCandidateCount: eligibleCandidates,
            completedBuildCount: completedBuilds,
            completedDurationNanoseconds: completedDuration,
            errorCounts: errors,
            samples: orderedSamples
        )
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        ring.removeAll(keepingCapacity: true)
        nextRingIndex = 0
        eligibleBuilds = 0
        eligibleCandidates = 0
        completedBuilds = 0
        completedDuration = 0
        errors.removeAll(keepingCapacity: true)
    }
}
