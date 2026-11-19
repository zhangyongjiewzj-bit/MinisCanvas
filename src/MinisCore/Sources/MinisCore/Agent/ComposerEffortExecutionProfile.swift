import Foundation

/// Application-level execution budget derived from the immutable Composer
/// submission snapshot. This does not grant capabilities or alter approval.
public struct ComposerEffortExecutionProfile: Equatable, Sendable {
    /// The effort selected at the request boundary. Kept separate from the
    /// effective runtime effort so policy may be conservative without
    /// silently rewriting the submitted choice.
    public let selectedEffort: ComposerEffort
    public let effectiveEffort: ComposerEffort

    /// Compatibility spelling for callers that only need the selected effort.
    public let effort: ComposerEffort
    public let maxIterations: Int
    public let maxTokens: Int

    public static let maxIterationCap = 100
    public static let maxTokenCap = 64_000

    public init(
        effort: ComposerEffort,
        baseMaxIterations: Int,
        baseMaxTokens: Int,
        maxOutputTokensCeiling: Int? = nil
    ) {
        self.init(
            selectedEffort: effort,
            effectiveEffort: effort,
            baseMaxIterations: baseMaxIterations,
            baseMaxTokens: baseMaxTokens,
            maxOutputTokensCeiling: maxOutputTokensCeiling
        )
    }

    /// Creates a bounded execution budget while preserving both effort
    /// values captured by the orchestration request. A lower effective value
    /// is allowed for conservative runtime policy; the selected value remains
    /// observable for user-facing explanation and receipts.
    public init(
        selectedEffort: ComposerEffort,
        effectiveEffort: ComposerEffort,
        baseMaxIterations: Int,
        baseMaxTokens: Int,
        maxOutputTokensCeiling: Int? = nil
    ) {
        self.selectedEffort = selectedEffort
        self.effectiveEffort = effectiveEffort
        self.effort = selectedEffort
        let safeIterations = max(1, min(baseMaxIterations, Self.maxIterationCap))
        let safeTokens = max(1, min(baseMaxTokens, Self.maxTokenCap))

        let scaledTokens: Int
        switch effectiveEffort {
        case .low:
            maxIterations = max(1, safeIterations / 2)
            scaledTokens = max(1, safeTokens / 2)
        case .standard:
            maxIterations = safeIterations
            scaledTokens = safeTokens
        case .high:
            maxIterations = min(Self.maxIterationCap, max(1, safeIterations * 3 / 2))
            scaledTokens = min(Self.maxTokenCap, max(1, safeTokens * 3 / 2))
        }
        // A selected context length is an independent hard boundary. In
        // particular, high effort must not inflate a clipped base past it.
        maxTokens = maxOutputTokensCeiling.map { min(scaledTokens, max(0, $0)) }
            ?? scaledTokens
    }

    public init(
        snapshot: ComposerSubmissionSnapshot,
        baseMaxIterations: Int,
        baseMaxTokens: Int,
        maxOutputTokensCeiling: Int? = nil
    ) {
        self.init(
            effort: snapshot.effort,
            baseMaxIterations: baseMaxIterations,
            baseMaxTokens: baseMaxTokens,
            maxOutputTokensCeiling: maxOutputTokensCeiling
        )
    }
}
