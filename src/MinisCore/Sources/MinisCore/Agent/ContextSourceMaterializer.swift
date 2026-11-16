import Foundation

/// Deterministic, provider-independent materialization of context sources.
///
/// This is a Core contract only. It does not call a provider, persist a
/// manifest, or mutate application state. Every input source receives a
/// decision so cropping and rejection remain auditable.
public struct ContextSourceMaterializer: Sendable {
    public struct Source: Sendable, Equatable, Hashable, Codable {
        public enum Kind: String, Sendable, Equatable, Hashable, Codable {
            case system
            case memory
            case task
            case receipt
            case attachment
            case canvas
            case toolResult
            case skill
            case other
        }

        public static let currentVersion = ContextItem.currentVersion

        public let identifier: String
        public let content: String
        public let tokenCost: Int
        public let kind: Kind
        public let level: ContextItem.Level
        public let scope: String
        public let provenance: String
        public let contentHash: String
        public let required: Bool
        public let nonDroppable: Bool
        public let version: Int

        public init(
            identifier: String,
            content: String,
            tokenCost: Int,
            kind: Kind = .other,
            level: ContextItem.Level = .l3,
            scope: String = "conversation",
            provenance: String = "local",
            contentHash: String? = nil,
            required: Bool = false,
            nonDroppable: Bool = false,
            version: Int = Source.currentVersion
        ) {
            self.identifier = identifier
            self.content = content
            self.tokenCost = tokenCost
            self.kind = kind
            self.level = level
            self.scope = scope
            self.provenance = provenance
            self.contentHash = contentHash ?? ContextItem.hash(content: content, identifier: identifier)
            self.required = required
            self.nonDroppable = nonDroppable
            self.version = version
        }

        public var isProtected: Bool {
            required || nonDroppable
        }

        public var hasValidHash: Bool {
            contentHash == ContextItem.hash(content: content, identifier: identifier)
        }
    }

    public enum Reason: String, Sendable, Equatable, Hashable, Codable {
        case negativeBudget
        case invalidIdentifier
        case duplicateIdentifier
        case negativeTokenCost
        case invalidVersion
        case invalidScope
        case invalidProvenance
        case invalidContentHash
        case invalidSourceContract
        case protectedSourceExceedsBudget
        case batchRejected
        case budgetExceeded
    }

    public enum DecisionDisposition: String, Sendable, Equatable, Hashable, Codable {
        case accepted
        case dropped
        case rejected
    }

    public struct Decision: Sendable, Equatable, Hashable, Codable {
        public let sourceID: String
        public let inputIndex: Int
        public let disposition: DecisionDisposition
        public let reason: Reason?

        public init(
            sourceID: String,
            inputIndex: Int,
            disposition: DecisionDisposition,
            reason: Reason?
        ) {
            self.sourceID = sourceID
            self.inputIndex = inputIndex
            self.disposition = disposition
            self.reason = reason
        }
    }

    public struct Result: Sendable, Equatable, Codable {
        public let requestedBudget: Int
        public let usedBudget: Int
        public let acceptedSources: [Source]
        public let decisions: [Decision]
        public let rejection: Reason?
        public let rejectionSourceIDs: [String]

        public init(
            requestedBudget: Int,
            usedBudget: Int,
            acceptedSources: [Source],
            decisions: [Decision],
            rejection: Reason?,
            rejectionSourceIDs: [String]
        ) {
            self.requestedBudget = requestedBudget
            self.usedBudget = usedBudget
            self.acceptedSources = acceptedSources
            self.decisions = decisions
            self.rejection = rejection
            self.rejectionSourceIDs = rejectionSourceIDs
        }

        public var droppedSourceIDs: [String] {
            decisions.compactMap { decision in
                decision.disposition == .dropped ? decision.sourceID : nil
            }
        }

        public var isAccepted: Bool {
            rejection == nil
        }
    }

    public init() {}

    public static func materialize(sources: [Source], budget: Int) -> Result {
        Self().materialize(sources: sources, budget: budget)
    }

    public static func materialize(_ sources: [Source], budget: Int) -> Result {
        materialize(sources: sources, budget: budget)
    }

    public func materialize(sources: [Source], budget: Int) -> Result {
        if budget < 0 {
            return rejected(
                sources: sources,
                budget: budget,
                reason: .negativeBudget,
                sourceReasons: [:],
                rejectionSourceIDs: []
            )
        }

        let contractReasons = contractViolations(in: sources)
        if !contractReasons.isEmpty {
            return rejected(
                sources: sources,
                budget: budget,
                reason: .invalidSourceContract,
                sourceReasons: contractReasons,
                rejectionSourceIDs: sources.compactMap { source in
                    contractReasons[source.identifier] == nil ? nil : source.identifier
                }
            )
        }

        let protectedSources = sources.filter(\.isProtected)
        var protectedTotal = 0
        var protectedTotalOverflowed = false
        for source in protectedSources {
            let (sum, overflowed) = protectedTotal.addingReportingOverflow(source.tokenCost)
            protectedTotalOverflowed = protectedTotalOverflowed || overflowed
            protectedTotal = overflowed ? Int.max : sum
        }
        if protectedTotalOverflowed || protectedTotal > budget {
            var runningTotal = 0
            var runningTotalOverflowed = false
            var overBudgetIDs: [String] = []
            for source in protectedSources {
                let (sum, overflowed) = runningTotal.addingReportingOverflow(source.tokenCost)
                runningTotalOverflowed = runningTotalOverflowed || overflowed
                runningTotal = overflowed ? Int.max : sum
                if runningTotalOverflowed || runningTotal > budget {
                    overBudgetIDs.append(source.identifier)
                }
            }
            let overBudgetIDSet = Set(overBudgetIDs)
            let decisions = sources.enumerated().map { index, source in
                if overBudgetIDSet.contains(source.identifier) {
                    return Decision(
                        sourceID: source.identifier,
                        inputIndex: index,
                        disposition: .rejected,
                        reason: .protectedSourceExceedsBudget
                    )
                }
                return Decision(
                    sourceID: source.identifier,
                    inputIndex: index,
                    disposition: .rejected,
                    reason: .batchRejected
                )
            }
            return Result(
                requestedBudget: budget,
                usedBudget: 0,
                acceptedSources: [],
                decisions: decisions,
                rejection: .protectedSourceExceedsBudget,
                rejectionSourceIDs: overBudgetIDs
            )
        }

        var usedBudget = protectedTotal
        var acceptedIndexes = Set<Int>()
        for (index, source) in sources.enumerated() where source.isProtected {
            acceptedIndexes.insert(index)
        }

        var decisions: [Decision] = []
        decisions.reserveCapacity(sources.count)
        for (index, source) in sources.enumerated() {
            if acceptedIndexes.contains(index) {
                decisions.append(Decision(
                    sourceID: source.identifier,
                    inputIndex: index,
                    disposition: .accepted,
                    reason: nil
                ))
                continue
            }

            let remainingBudget = budget - usedBudget
            if source.tokenCost <= remainingBudget {
                acceptedIndexes.insert(index)
                usedBudget += source.tokenCost
                decisions.append(Decision(
                    sourceID: source.identifier,
                    inputIndex: index,
                    disposition: .accepted,
                    reason: nil
                ))
            } else {
                decisions.append(Decision(
                    sourceID: source.identifier,
                    inputIndex: index,
                    disposition: .dropped,
                    reason: .budgetExceeded
                ))
            }
        }

        let acceptedSources = sources.enumerated().compactMap { index, source in
            acceptedIndexes.contains(index) ? source : nil
        }
        return Result(
            requestedBudget: budget,
            usedBudget: usedBudget,
            acceptedSources: acceptedSources,
            decisions: decisions,
            rejection: nil,
            rejectionSourceIDs: []
        )
    }

    public func materialize(_ sources: [Source], budget: Int) -> Result {
        materialize(sources: sources, budget: budget)
    }

    private func contractViolations(in sources: [Source]) -> [String: Reason] {
        var reasons: [String: Reason] = [:]
        var seenIDs = Set<String>()

        for source in sources {
            let reason: Reason?
            if source.identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                reason = .invalidIdentifier
            } else if source.tokenCost < 0 {
                reason = .negativeTokenCost
            } else if source.version != Source.currentVersion {
                reason = .invalidVersion
            } else if source.scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                reason = .invalidScope
            } else if source.provenance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                reason = .invalidProvenance
            } else if !source.hasValidHash {
                reason = .invalidContentHash
            } else if !seenIDs.insert(source.identifier).inserted {
                reason = .duplicateIdentifier
            } else {
                reason = nil
            }

            if let reason {
                reasons[source.identifier] = reasons[source.identifier] ?? reason
            }
        }

        // Mark the first occurrence too when an identifier is duplicated.
        let duplicateIDs = Dictionary(grouping: sources.indices, by: { sources[$0].identifier })
            .filter { $0.value.count > 1 }
            .map(\.key)
        for duplicateID in duplicateIDs {
            reasons[duplicateID] = .duplicateIdentifier
        }
        return reasons
    }

    private func rejected(
        sources: [Source],
        budget: Int,
        reason: Reason,
        sourceReasons: [String: Reason],
        rejectionSourceIDs: [String]
    ) -> Result {
        let decisions = sources.enumerated().map { index, source in
            let sourceReason = sourceReasons[source.identifier] ?? (
                reason == .invalidSourceContract ? .batchRejected : reason
            )
            return Decision(
                sourceID: source.identifier,
                inputIndex: index,
                disposition: .rejected,
                reason: sourceReason
            )
        }
        return Result(
            requestedBudget: budget,
            usedBudget: 0,
            acceptedSources: [],
            decisions: decisions,
            rejection: reason,
            rejectionSourceIDs: rejectionSourceIDs
        )
    }
}
