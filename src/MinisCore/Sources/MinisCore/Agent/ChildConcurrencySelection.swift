import Foundation

/// Typed child-concurrency facts kept separate from the global tool limit.
///
/// P3-CHILD-40 / detail row D-CHILDB「并列展示selected/recommended/effective/
/// actual/queued与原因」: this ONE value object carries all five named quantities
/// together — the three ceilings it always held (`userSelected` / `recommended` /
/// `effective`) plus the two authority-reported runtime quantities in `runtime`
/// (`actual` / `queued`) — and hands them to its consumer as a single ordered
/// projection (`sideBySideProjection`) in which every stage that diverges carries
/// its own reason. The consumer renders rows; it never has to join a second model.
public struct ChildConcurrencySelection: Codable, Equatable, Sendable {
    public static let hardMaximum = 40

    public let userSelected: Int
    public let recommended: Int
    public let effective: Int
    public let enabledSessionCount: Int

    /// The `actual` + `queued` half of the five-value projection, together with the
    /// two governor states that explain where `actual` sits. `nil` means "the
    /// concurrency authority has not reported yet" and is deliberately never folded
    /// into `0`: "nothing is running" and "nobody told me" are different facts, and
    /// rendering an estimate as a measurement is exactly what this row forbids.
    public let runtime: RuntimeReport?

    public var globalRequestedCapacity: Int {
        enabledSessionCount * userSelected
    }

    public enum ValidationError: Error, Equatable, Sendable {
        case userSelectedOutOfRange(Int)
        case recommendedOutOfRange(Int)
        case effectiveOutOfRange(Int)
        case effectiveExceedsSelection
        case enabledSessionCountOutOfRange(Int)
        case actualRunningOutOfRange(Int)
        case queuedRequestsOutOfRange(Int)
        case degradedCeilingOutOfRange(Int)
    }

    public init(
        userSelected: Int,
        recommended: Int,
        effective: Int,
        enabledSessionCount: Int = 1,
        runtime: RuntimeReport? = nil
    ) throws {
        guard (1...Self.hardMaximum).contains(userSelected) else {
            throw ValidationError.userSelectedOutOfRange(userSelected)
        }
        guard (1...Self.hardMaximum).contains(recommended) else {
            throw ValidationError.recommendedOutOfRange(recommended)
        }
        guard (1...Self.hardMaximum).contains(effective) else {
            throw ValidationError.effectiveOutOfRange(effective)
        }
        guard effective <= userSelected else {
            throw ValidationError.effectiveExceedsSelection
        }
        guard enabledSessionCount >= 0,
              enabledSessionCount <= Int.max / Self.hardMaximum else {
            throw ValidationError.enabledSessionCountOutOfRange(enabledSessionCount)
        }

        self.userSelected = userSelected
        self.recommended = recommended
        self.effective = effective
        self.enabledSessionCount = enabledSessionCount
        // A `RuntimeReport` is already validated by its own initialiser, so the
        // selection stores it as-is instead of re-deriving it.
        self.runtime = runtime
    }

    public static let `default` = try! Self(
        userSelected: 4,
        recommended: 4,
        effective: 4
    )
}

// MARK: - P3-CHILD-40 five-value joint projection (D-CHILDB)

extension ChildConcurrencySelection {

    /// The runtime half of the projection: the two quantities a per-session
    /// selection cannot derive on its own, plus the governor states already
    /// observable on `ChildConcurrencyGovernor`. Every field maps 1:1 onto an
    /// existing reporting surface (`currentGlobalActive`, the fairness-queue depth,
    /// the checkpoint's `degradedCeiling` / `killSwitchEngaged`), so reporting them
    /// here forks no second source of truth: this type measures nothing and polls
    /// nothing, it only carries what its owner read.
    ///
    /// `actualRunning` and `queued` are kept in ONE report on purpose: they come
    /// from the same snapshot of the same authority, so a consumer can never render
    /// an actual from one instant against a queued count from another.
    ///
    /// Neither field carries the per-session `hardMaximum` bound, because the row
    /// accounts globally (`N * per-session ceiling`, e.g. 4x40 = 160): a legitimate
    /// aggregate above 40 must not be rejected or silently clamped here.
    public struct RuntimeReport: Codable, Equatable, Sendable {
        /// Children running right now, as reported by the concurrency authority.
        public let actualRunning: Int
        /// Launch requests waiting for a slot, as reported by the same authority.
        public let queued: Int
        /// Non-nil while the governor is throttling new grants via
        /// `degradeActualConcurrency(to:)`; nil when the full policy ceiling holds.
        public let degradedCeiling: Int?
        /// Kill Switch engaged: new launches are stopped, running children untouched.
        public let newLaunchesStopped: Bool

        public init(
            actualRunning: Int,
            queued: Int,
            degradedCeiling: Int? = nil,
            newLaunchesStopped: Bool = false
        ) throws {
            guard actualRunning >= 0 else {
                throw ChildConcurrencySelection.ValidationError.actualRunningOutOfRange(actualRunning)
            }
            guard queued >= 0 else {
                throw ChildConcurrencySelection.ValidationError.queuedRequestsOutOfRange(queued)
            }
            if let degradedCeiling, degradedCeiling < 0 {
                throw ChildConcurrencySelection.ValidationError.degradedCeilingOutOfRange(degradedCeiling)
            }
            self.actualRunning = actualRunning
            self.queued = queued
            self.degradedCeiling = degradedCeiling
            self.newLaunchesStopped = newLaunchesStopped
        }
    }

    /// One named quantity of the row's five, in the row's own canonical order.
    public enum Stage: String, CaseIterable, Codable, Sendable {
        case selected
        case recommended
        case effective
        case actual
        case queued

        /// Display title, matching the wording already used by the consuming
        /// surface and the child-lifecycle schema (用户选择/系统建议/有效上限/
        /// 实际运行/排队).
        public var title: String {
            switch self {
            case .selected: "用户选择"
            case .recommended: "系统建议"
            case .effective: "有效上限"
            case .actual: "实际运行"
            case .queued: "排队请求"
            }
        }
    }

    /// A reason attached to the stage where the value diverges. Only two kinds of
    /// statement live here, and neither invents a cause:
    ///
    /// 1. an arithmetic relation between values this type already carries
    ///    (recommended vs selected, effective vs recommended, actual vs effective,
    ///    queued above zero);
    /// 2. a state the reporter observed on the governor (degraded ceiling, stopped
    ///    new launches).
    ///
    /// The over-ceiling *risk* wording (Token / Provider / 内存 / CPU / 温度 /
    /// UI 流畅度) stays in `ChildConcurrencyRiskAdvisory.recommendation`; this enum
    /// does not duplicate it, and it says nothing about WHY the authority chose a
    /// value it did not report.
    public enum Deviation: String, CaseIterable, Codable, Equatable, Sendable {
        case recommendedBelowSelected
        case effectiveBelowRecommended
        case actualBelowEffective
        case actualAboveEffective
        case governorDegradedCeiling
        case governorStoppedNewLaunches
        case queuedRequestsWaiting

        /// The stage this reason is rendered against.
        public var stage: Stage {
            switch self {
            case .recommendedBelowSelected: .recommended
            case .effectiveBelowRecommended: .effective
            case .actualBelowEffective, .actualAboveEffective,
                 .governorDegradedCeiling, .governorStoppedNewLaunches: .actual
            case .queuedRequestsWaiting: .queued
            }
        }

        /// Short human-readable reason text for side-by-side rendering.
        public var explanation: String {
            switch self {
            case .recommendedBelowSelected: "系统建议低于用户选择，用户所选值未被改写"
            case .effectiveBelowRecommended: "有效上限低于系统建议"
            case .actualBelowEffective: "实际运行低于有效上限"
            case .actualAboveEffective: "实际运行高于有效上限"
            case .governorDegradedCeiling: "并发治理器已降低实际并发上限"
            case .governorStoppedNewLaunches: "Kill Switch 生效，仅停止新启动"
            case .queuedRequestsWaiting: "存在等待槽位的排队请求"
            }
        }
    }

    /// One row of the side-by-side display: the stage's value plus every reason
    /// that explains a divergence at that stage. `value == nil` means the authority
    /// has not reported this quantity yet (only possible for the runtime stages).
    public struct StageValue: Equatable, Sendable {
        public let stage: Stage
        public let value: Int?
        public let deviations: [Deviation]

        public init(stage: Stage, value: Int?, deviations: [Deviation] = []) {
            self.stage = stage
            self.value = value
            self.deviations = deviations
        }

        /// `标题 值（原因；原因）` — the row's「并列展示…与原因」shape, already
        /// composed so a text/AX consumer does not re-derive the pairing.
        public var displayText: String {
            let valueText = value.map(String.init) ?? "未上报"
            let reasonText = deviations.map(\.explanation).joined(separator: "；")
            if reasonText.isEmpty {
                return "\(stage.title) \(valueText)"
            }
            return "\(stage.title) \(valueText)（\(reasonText)）"
        }
    }

    /// All five quantities in canonical order, each with its reasons. Returns five
    /// rows even before a runtime report exists: the unreported stages come back as
    /// `value == nil` so the surface can show the gap instead of dropping the stage.
    public var sideBySideProjection: [StageValue] {
        var rows: [StageValue] = [
            StageValue(stage: .selected, value: userSelected, deviations: []),
            StageValue(
                stage: .recommended,
                value: recommended,
                deviations: recommended < userSelected ? [.recommendedBelowSelected] : []
            ),
            StageValue(
                stage: .effective,
                value: effective,
                deviations: effective < recommended ? [.effectiveBelowRecommended] : []
            ),
        ]
        guard let runtime else {
            rows.append(StageValue(stage: .actual, value: nil, deviations: []))
            rows.append(StageValue(stage: .queued, value: nil, deviations: []))
            return rows
        }

        var actualReasons: [Deviation] = []
        if runtime.actualRunning < effective {
            actualReasons.append(.actualBelowEffective)
        } else if runtime.actualRunning > effective {
            actualReasons.append(.actualAboveEffective)
        }
        if runtime.degradedCeiling != nil {
            actualReasons.append(.governorDegradedCeiling)
        }
        if runtime.newLaunchesStopped {
            actualReasons.append(.governorStoppedNewLaunches)
        }
        rows.append(
            StageValue(stage: .actual, value: runtime.actualRunning, deviations: actualReasons)
        )
        rows.append(
            StageValue(
                stage: .queued,
                value: runtime.queued,
                deviations: runtime.queued > 0 ? [.queuedRequestsWaiting] : []
            )
        )
        return rows
    }

    /// The five stages joined on one line, for a single-label consumer (e.g. an
    /// accessibility value that must state all five at once).
    public var sideBySideSummary: String {
        sideBySideProjection.map(\.displayText).joined(separator: " · ")
    }

    /// Replace the runtime half without touching the three user-facing ceilings.
    /// Provided so the reporting consumer can attach a fresh snapshot in one call
    /// instead of re-spelling four validated initialiser arguments; the user's
    /// selection stays byte-identical because this type never rewrites it.
    public func withRuntime(_ report: RuntimeReport?) throws -> ChildConcurrencySelection {
        try ChildConcurrencySelection(
            userSelected: userSelected,
            recommended: recommended,
            effective: effective,
            enabledSessionCount: enabledSessionCount,
            runtime: report
        )
    }
}
