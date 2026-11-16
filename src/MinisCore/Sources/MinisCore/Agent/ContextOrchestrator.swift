import Foundation
import CryptoKit

/// Typed, provenance-bound context item used by the orchestration boundary.
public struct ContextItem: Sendable, Equatable, Hashable, Codable {
    public enum Level: String, Sendable, Equatable, Hashable, Codable { case l0, l1, l2, l3 }
    public static let currentVersion = 1
    public let identifier: String
    public let content: String
    public let tokenCost: Int
    public let level: Level
    public let scope: String
    public let provenance: String
    public let contentHash: String
    public let required: Bool
    public let version: Int

    public init(identifier: String, content: String, tokenCost: Int, level: Level = .l3,
                scope: String = "conversation", provenance: String = "local", contentHash: String? = nil,
                required: Bool = false, version: Int = ContextItem.currentVersion) {
        self.identifier = identifier; self.content = content; self.tokenCost = tokenCost
        self.level = level; self.scope = scope; self.provenance = provenance
        self.contentHash = contentHash ?? Self.hash(content: content, identifier: identifier)
        self.required = required; self.version = version
    }
    public static func hash(content: String, identifier: String) -> String {
        SHA256.hash(data: Data((identifier + "\u{0}" + content).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public var hasValidHash: Bool { contentHash == Self.hash(content: content, identifier: identifier) }
}

/// Pure manifest builder for an immutable conversation snapshot.
///
/// This contract deliberately has no provider, network, persistence, or app-store
/// dependency. A future composition owner may consume the returned manifest only
/// after its own authorization and lifecycle checks.
public final class ContextOrchestrator: @unchecked Sendable {
    public struct Input: Sendable, Equatable {
        public let snapshot: ConversationContextSnapshotV1
        public let entries: [Entry]
        public let contextItems: [ContextItem]

        public init(snapshot: ConversationContextSnapshotV1, entries: [Entry]) {
            self.snapshot = snapshot
            self.entries = entries
            self.contextItems = entries.map {
                ContextItem(
                    identifier: $0.identifier,
                    content: $0.content,
                    tokenCost: $0.tokenCost,
                    required: $0.required
                )
            }
        }

        public init(snapshot: ConversationContextSnapshotV1, contextItems: [ContextItem]) {
            self.snapshot = snapshot
            self.contextItems = contextItems
            self.entries = contextItems.map {
                Entry(
                    identifier: $0.identifier,
                    content: $0.content,
                    tokenCost: $0.tokenCost,
                    required: $0.required
                )
            }
        }
    }

    public struct Entry: Sendable, Equatable, Hashable, Codable {
        public let identifier: String
        public let content: String
        public let tokenCost: Int
        public let required: Bool

        public init(identifier: String, content: String, tokenCost: Int, required: Bool = false) {
            self.identifier = identifier
            self.content = content
            self.tokenCost = tokenCost
            self.required = required
        }
    }

    public struct Manifest: Sendable, Equatable, Codable {
        public let snapshotID: String
        public let entries: [Entry]

        public init(snapshotID: String, entries: [Entry]) {
            self.snapshotID = snapshotID
            self.entries = entries
        }
    }

    public enum CacheDisposition: String, Sendable, Equatable, Codable {
        case hit
        case miss
        case notApplicable
    }

    public enum Rejection: String, Sendable, Equatable, Codable {
        case negativeBudget
        case invalidSnapshot
        case negativeTokenCost
        case invalidContextItem
        case requiredItemExceedsBudget
        case budgetOverflow
    }

    public struct Receipt: Sendable, Equatable, Codable {
        public let requestedBudget: Int
        public let usedBudget: Int
        public let droppedEntryIDs: [String]
        public let cacheDisposition: CacheDisposition
        public let rejection: Rejection?

        public init(
            requestedBudget: Int,
            usedBudget: Int,
            droppedEntryIDs: [String],
            cacheDisposition: CacheDisposition,
            rejection: Rejection?
        ) {
            self.requestedBudget = requestedBudget
            self.usedBudget = usedBudget
            self.droppedEntryIDs = droppedEntryIDs
            self.cacheDisposition = cacheDisposition
            self.rejection = rejection
        }

        public var wasCropped: Bool { !droppedEntryIDs.isEmpty }
    }

    public struct Result: Sendable, Equatable {
        public let manifest: Manifest?
        public let receipt: Receipt

        public init(manifest: Manifest?, receipt: Receipt) {
            self.manifest = manifest
            self.receipt = receipt
        }
    }

    /// Immutable handoff prepared for one AgentLoop turn.
    ///
    /// The handoff is created before asynchronous work starts. Consumers must
    /// carry this value through the turn instead of rereading active session,
    /// provider, or model state.
    public struct AgentLoopInput: Sendable, Equatable {
        public let snapshot: ConversationContextSnapshotV1
        public let manifest: Manifest
        public let receipt: Receipt
        public let executionIdentity: AgentExecutionIdentity

        public init?(
            snapshot: ConversationContextSnapshotV1,
            manifest: Manifest,
            receipt: Receipt,
            executionIdentity: AgentExecutionIdentity
        ) {
            guard let usedBudget = ContextOrchestrator.totalTokenCost(manifest.entries.map(\.tokenCost)) else {
                return nil
            }
            guard snapshot.snapshotID == snapshot.canonicalSnapshotID(),
                  manifest.snapshotID == snapshot.snapshotID,
                  manifest.entries.count <= ContextOrchestrator.maxEntryCount,
                  receipt.droppedEntryIDs.count <= ContextOrchestrator.maxDroppedEntryCount,
                  manifest.entries.allSatisfy({ $0.tokenCost >= 0 }),
                  ContextOrchestrator.hasUniqueValidEntryIdentifiers(manifest.entries),
                  ContextOrchestrator.hasUniqueValidDroppedEntryIdentifiers(receipt.droppedEntryIDs),
                  receipt.rejection == nil,
                  receipt.requestedBudget >= 0,
                  receipt.usedBudget >= 0,
                  receipt.usedBudget == usedBudget,
                  receipt.usedBudget <= receipt.requestedBudget,
                  receipt.cacheDisposition == .hit || receipt.cacheDisposition == .miss,
                  executionIdentity.isValid else {
                return nil
            }
            self.snapshot = snapshot
            self.manifest = manifest
            self.receipt = receipt
            self.executionIdentity = executionIdentity
        }
    }

    public enum AgentLoopInputRejection: Sendable, Equatable {
        case invalidExecutionIdentity
        case rejected(ConsumerSeam.Rejection)
    }

    public struct AgentLoopInputResult: Sendable, Equatable {
        public let input: AgentLoopInput?
        public let rejection: AgentLoopInputRejection?

        public init(input: AgentLoopInput?, rejection: AgentLoopInputRejection?) {
            self.input = input
            self.rejection = rejection
        }
    }

    /// Result metadata carried back by an asynchronous AgentLoop completion.
    ///
    /// The result body is intentionally outside this seam; the only data needed
    /// to decide whether a caller may write it back is the frozen identity.
    public struct AgentLoopWriteback: Sendable, Equatable {
        public let snapshot: ConversationContextSnapshotV1
        public let executionIdentity: AgentExecutionIdentity

        public init(
            snapshot: ConversationContextSnapshotV1,
            executionIdentity: AgentExecutionIdentity
        ) {
            self.snapshot = snapshot
            self.executionIdentity = executionIdentity
        }
    }

    public enum WritebackRejection: Sendable, Equatable {
        case inactiveExecution
        case invalidSnapshot
        case snapshotMismatch
        case executionIdentityMismatch
    }

    public enum WritebackValidation: Sendable, Equatable {
        case accepted
        case rejected(WritebackRejection)
    }

    /// Lifecycle gate for asynchronous AgentLoop writeback.
    ///
    /// A completed or cancelled handoff is retired before any later callback can
    /// be accepted or re-registered. Snapshot and execution identity are both
    /// checked, so a callback from an older turn cannot update a newer conversation.
    /// Successful validation consumes the handoff while holding the same lock,
    /// making duplicate completion callbacks fail closed before they can write.
    public final class AgentLoopWritebackGate: @unchecked Sendable {
        private let lock = NSLock()
        private let turnContextStore: AgentTurnContextStore?
        private let recoveryUnavailable: Bool
        private var activeIdentities: Set<AgentExecutionIdentity> = []
        private var retiredIdentities: Set<AgentExecutionIdentity> = []

        /// `store` is optional to preserve the in-memory/offline contract.
        /// Production composition roots that need restart durability inject a
        /// persistent `AgentTurnContextStore`.
        public init(store: AgentTurnContextStore? = nil, recoveryUnavailable: Bool = false) {
            self.turnContextStore = store
            self.recoveryUnavailable = recoveryUnavailable
        }

        /// The production stream caller must share this exact durable store
        /// with the gate. Constructing a second store from the same URL would
        /// carry a stale persistence baseline and could not safely project a
        /// terminal fact after the gate admits writeback.
        public var lifecycleStore: AgentTurnContextStore? {
            turnContextStore
        }

        @discardableResult
        public func begin(_ input: AgentLoopInput) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !recoveryUnavailable,
                  input.snapshot.snapshotID == input.snapshot.canonicalSnapshotID(),
                  input.executionIdentity.isValid,
                  !retiredIdentities.contains(input.executionIdentity) else {
                return false
            }
            if let turnContextStore {
                do {
                    guard try turnContextStore.begin(
                        identity: input.executionIdentity,
                        snapshot: input.snapshot
                    ) else {
                        return false
                    }
                } catch {
                    return false
                }
            }
            return activeIdentities.insert(input.executionIdentity).inserted
        }

        public func validate(
            _ writeback: AgentLoopWriteback,
            for input: AgentLoopInput,
            currentSnapshot: ConversationContextSnapshotV1
        ) -> WritebackValidation {
            lock.lock()
            defer { lock.unlock() }
            guard !recoveryUnavailable,
                  activeIdentities.contains(input.executionIdentity) else {
                return .rejected(.inactiveExecution)
            }
            guard input.executionIdentity.isValid,
                  writeback.executionIdentity.isValid else {
                return .rejected(.executionIdentityMismatch)
            }
            guard writeback.executionIdentity == input.executionIdentity else {
                return .rejected(.executionIdentityMismatch)
            }
            guard input.snapshot.snapshotID == input.snapshot.canonicalSnapshotID(),
                  writeback.snapshot.snapshotID == writeback.snapshot.canonicalSnapshotID(),
                  currentSnapshot.snapshotID == currentSnapshot.canonicalSnapshotID() else {
                retire(input.executionIdentity)
                return .rejected(.invalidSnapshot)
            }
            guard input.snapshot.matches(currentSnapshot) else {
                retire(input.executionIdentity)
                return .rejected(.snapshotMismatch)
            }
            guard input.snapshot.matches(writeback.snapshot) else {
                return .rejected(.snapshotMismatch)
            }
            if let turnContextStore {
                do {
                    guard try turnContextStore.admitWriteback(
                        identity: input.executionIdentity,
                        snapshot: writeback.snapshot,
                        currentSnapshot: currentSnapshot
                    ) else {
                        return .rejected(.inactiveExecution)
                    }
                } catch {
                    return .rejected(.inactiveExecution)
                }
            }
            // Validation is the writeback admission point. Retire it before
            // releasing the lock so a duplicate callback cannot also pass.
            retire(input.executionIdentity)
            return .accepted
        }

        public func finish(_ input: AgentLoopInput) {
            lock.lock()
            if let turnContextStore {
                _ = try? turnContextStore.complete(
                    identity: input.executionIdentity,
                    snapshot: input.snapshot
                )
            }
            retire(input.executionIdentity)
            lock.unlock()
        }

        public func cancel(_ input: AgentLoopInput) {
            lock.lock()
            if let turnContextStore {
                _ = try? turnContextStore.cancel(
                    identity: input.executionIdentity,
                    snapshot: input.snapshot
                )
            }
            retire(input.executionIdentity)
            lock.unlock()
        }

        private func retire(_ identity: AgentExecutionIdentity) {
            activeIdentities.remove(identity)
            retiredIdentities.insert(identity)
        }
    }

    /// Pure audit boundary for receipts returned by makeManifest(_:budget:).
    ///
    /// Receipt-only callers cannot reconstruct a manifest, so this seam validates
    /// just receipt-internal invariants and returns an immutable audit value. It
    /// has no persistence, provider, network, UI, or orchestrator-cache effects.
    public enum ReceiptAuditSeam {
        public struct NormalizedReceipt: Sendable, Equatable, Codable {
            public let requestedBudget: Int
            public let usedBudget: Int
            public let droppedEntryIDs: [String]
            public let cacheDisposition: CacheDisposition

            public init(
                requestedBudget: Int,
                usedBudget: Int,
                droppedEntryIDs: [String],
                cacheDisposition: CacheDisposition
            ) {
                self.requestedBudget = requestedBudget
                self.usedBudget = usedBudget
                self.droppedEntryIDs = droppedEntryIDs
                self.cacheDisposition = cacheDisposition
            }
        }

        public enum Rejection: Sendable, Equatable {
            case orchestratorRejected(ContextOrchestrator.Rejection)
            case negativeRequestedBudget
            case negativeUsedBudget
            case budgetExceeded
            case invalidCacheDisposition
            case droppedEntryCountExceeded
            case invalidDroppedEntryIdentifier
            case duplicateDroppedEntryIdentifier
        }

        public enum Audit: Sendable, Equatable {
            case accepted(NormalizedReceipt)
            case rejected(Rejection)
        }

        public static func normalize(_ receipt: Receipt) -> Audit {
            if let rejection = receipt.rejection {
                return .rejected(.orchestratorRejected(rejection))
            }
            guard receipt.requestedBudget >= 0 else {
                return .rejected(.negativeRequestedBudget)
            }
            guard receipt.usedBudget >= 0 else {
                return .rejected(.negativeUsedBudget)
            }
            guard receipt.usedBudget <= receipt.requestedBudget else {
                return .rejected(.budgetExceeded)
            }
            guard receipt.cacheDisposition == .hit || receipt.cacheDisposition == .miss else {
                return .rejected(.invalidCacheDisposition)
            }
            guard receipt.droppedEntryIDs.count <= ContextOrchestrator.maxDroppedEntryCount else {
                return .rejected(.droppedEntryCountExceeded)
            }
            guard receipt.droppedEntryIDs.allSatisfy(ContextOrchestrator.hasValidEntryIdentifier) else {
                return .rejected(.invalidDroppedEntryIdentifier)
            }
            guard ContextOrchestrator.hasUniqueEntryIdentifiers(receipt.droppedEntryIDs) else {
                return .rejected(.duplicateDroppedEntryIdentifier)
            }
            return .accepted(NormalizedReceipt(
                requestedBudget: receipt.requestedBudget,
                usedBudget: receipt.usedBudget,
                droppedEntryIDs: receipt.droppedEntryIDs,
                cacheDisposition: receipt.cacheDisposition
            ))
        }
    }

    /// Pure consumer boundary for manifests returned by makeManifest(_:budget:).
    ///
    /// It validates only supplied values. It does not invoke a provider, persist a
    /// manifest, mutate orchestrator cache state, or perform network/UI work.
    public enum ConsumerSeam {
        public enum Rejection: Sendable, Equatable {
            case orchestratorRejected(ContextOrchestrator.Rejection)
            case missingManifest
            case snapshotMismatch
            case negativeRequestedBudget
            case negativeEntryTokenCost
            case usedBudgetMismatch
            case budgetExceeded
            case invalidCacheDisposition
            case invalidEntryIdentifier
            case duplicateEntryIdentifier
            case entryCountExceeded
            case budgetOverflow
            case droppedEntryCountExceeded
            case invalidDroppedEntryIdentifier
            case duplicateDroppedEntryIdentifier
        }

        public enum Validation: Sendable, Equatable {
            case accepted(manifest: Manifest, receipt: Receipt)
            case rejected(Rejection)
        }

        public static func validate(
            _ result: Result,
            for snapshot: ConversationContextSnapshotV1
        ) -> Validation {
            if let rejection = result.receipt.rejection {
                return .rejected(.orchestratorRejected(rejection))
            }
            guard let manifest = result.manifest else {
                return .rejected(.missingManifest)
            }
            guard snapshot.snapshotID == snapshot.canonicalSnapshotID(),
                  manifest.snapshotID == snapshot.snapshotID else {
                return .rejected(.snapshotMismatch)
            }
            guard manifest.entries.count <= ContextOrchestrator.maxEntryCount else {
                return .rejected(.entryCountExceeded)
            }
            guard result.receipt.droppedEntryIDs.count <= ContextOrchestrator.maxDroppedEntryCount else {
                return .rejected(.droppedEntryCountExceeded)
            }
            guard result.receipt.requestedBudget >= 0 else {
                return .rejected(.negativeRequestedBudget)
            }
            guard manifest.entries.allSatisfy({ $0.tokenCost >= 0 }) else {
                return .rejected(.negativeEntryTokenCost)
            }
            guard manifest.entries.allSatisfy({ ContextOrchestrator.hasValidEntryIdentifier($0.identifier) }) else {
                return .rejected(.invalidEntryIdentifier)
            }
            guard ContextOrchestrator.hasUniqueEntryIdentifiers(manifest.entries) else {
                return .rejected(.duplicateEntryIdentifier)
            }
            guard result.receipt.droppedEntryIDs.allSatisfy(ContextOrchestrator.hasValidEntryIdentifier) else {
                return .rejected(.invalidDroppedEntryIdentifier)
            }
            guard ContextOrchestrator.hasUniqueEntryIdentifiers(result.receipt.droppedEntryIDs) else {
                return .rejected(.duplicateDroppedEntryIdentifier)
            }

            guard let usedBudget = ContextOrchestrator.totalTokenCost(manifest.entries.map(\.tokenCost)) else {
                return .rejected(.budgetOverflow)
            }
            guard result.receipt.usedBudget == usedBudget else {
                return .rejected(.usedBudgetMismatch)
            }
            guard usedBudget <= result.receipt.requestedBudget else {
                return .rejected(.budgetExceeded)
            }
            guard result.receipt.cacheDisposition == .hit || result.receipt.cacheDisposition == .miss else {
                return .rejected(.invalidCacheDisposition)
            }
            return .accepted(manifest: manifest, receipt: result.receipt)
        }
    }

    private var cache: [CacheKey: Manifest] = [:]
    private let lock = NSLock()

    private static let maxEntryCount = 1_024
    private static let maxDroppedEntryCount = 1_024
    private static let maxIdentityUTF8Bytes = 256
    private static let maxContentHashUTF8Bytes = 256

    public init() {}

    public func prepareAgentLoopInput(
        _ input: Input,
        budget: Int,
        executionIdentity: AgentExecutionIdentity
    ) -> AgentLoopInputResult {
        guard executionIdentity.isValid else {
            return AgentLoopInputResult(
                input: nil,
                rejection: .invalidExecutionIdentity
            )
        }

        let result = makeManifest(input, budget: budget)
        switch ConsumerSeam.validate(result, for: input.snapshot) {
        case .accepted(let manifest, let receipt):
            guard let handoff = AgentLoopInput(
                snapshot: input.snapshot,
                manifest: manifest,
                receipt: receipt,
                executionIdentity: executionIdentity
            ) else {
                return AgentLoopInputResult(
                    input: nil,
                    rejection: .rejected(.snapshotMismatch)
                )
            }
            return AgentLoopInputResult(input: handoff, rejection: nil)
        case .rejected(let rejection):
            return AgentLoopInputResult(
                input: nil,
                rejection: .rejected(rejection)
            )
        }
    }

    public func makeManifest(_ input: Input, budget: Int) -> Result {
        guard budget >= 0 else {
            return rejected(budget: budget, rejection: .negativeBudget)
        }
        guard input.snapshot.snapshotID == input.snapshot.canonicalSnapshotID() else {
            return rejected(budget: budget, rejection: .invalidSnapshot)
        }
        guard input.entries.count <= Self.maxEntryCount,
              input.contextItems.count <= Self.maxEntryCount else {
            return rejected(budget: budget, rejection: .invalidContextItem)
        }
        guard input.entries.allSatisfy({ $0.tokenCost >= 0 }) else {
            return rejected(budget: budget, rejection: .negativeTokenCost)
        }
        guard input.contextItems.allSatisfy({
            $0.version == ContextItem.currentVersion
                && Self.hasValidEntryIdentifier($0.identifier)
                && Self.hasValidIdentity($0.scope)
                && Self.hasValidIdentity($0.provenance)
                && $0.contentHash.utf8.count <= Self.maxContentHashUTF8Bytes
                && $0.hasValidHash
        }) else {
            return rejected(budget: budget, rejection: .invalidContextItem)
        }
        guard Self.hasUniqueEntryIdentifiers(input.contextItems.map(\.identifier)) else {
            return rejected(budget: budget, rejection: .invalidContextItem)
        }
        guard let requiredCost = Self.totalTokenCost(
            input.contextItems.filter(\.required).map(\.tokenCost)
        ) else {
            return rejected(budget: budget, rejection: .budgetOverflow)
        }
        guard requiredCost <= budget else {
            return rejected(budget: budget, rejection: .requiredItemExceedsBudget)
        }

        let key = CacheKey(input: input, budget: budget)
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] {
            guard let cachedUsedBudget = Self.totalTokenCost(cached.entries.map(\.tokenCost)) else {
                cache.removeValue(forKey: key)
                return rejected(budget: budget, rejection: .budgetOverflow)
            }
            return Result(
                manifest: cached,
                receipt: Receipt(
                    requestedBudget: budget,
                    usedBudget: cachedUsedBudget,
                    droppedEntryIDs: croppedEntryIDs(from: input.entries, accepted: cached.entries),
                    cacheDisposition: .hit,
                    rejection: nil
                )
            )
        }

        var usedBudget = requiredCost
        var acceptedIndexes = Set<Int>()
        for index in input.contextItems.indices where input.contextItems[index].required {
            acceptedIndexes.insert(index)
        }
        for index in input.contextItems.indices where !input.contextItems[index].required {
            let entry = input.entries[index]
            let (candidateBudget, overflowed) = usedBudget.addingReportingOverflow(entry.tokenCost)
            if !overflowed && candidateBudget <= budget {
                acceptedIndexes.insert(index)
                usedBudget = candidateBudget
            }
        }
        let accepted = input.entries.indices.compactMap {
            acceptedIndexes.contains($0) ? input.entries[$0] : nil
        }
        let dropped = input.entries.indices.compactMap {
            acceptedIndexes.contains($0) ? nil : input.entries[$0].identifier
        }
        let manifest = Manifest(snapshotID: input.snapshot.snapshotID, entries: accepted)
        cache[key] = manifest

        return Result(
            manifest: manifest,
            receipt: Receipt(
                requestedBudget: budget,
                usedBudget: usedBudget,
                droppedEntryIDs: dropped,
                cacheDisposition: .miss,
                rejection: nil
            )
        )
    }

    private func rejected(budget: Int, rejection: Rejection) -> Result {
        Result(
            manifest: nil,
            receipt: Receipt(
                requestedBudget: budget,
                usedBudget: 0,
                droppedEntryIDs: [],
                cacheDisposition: .notApplicable,
                rejection: rejection
            )
        )
    }

    private func croppedEntryIDs(from entries: [Entry], accepted: [Entry]) -> [String] {
        let acceptedIdentifiers = Set(accepted.map(\.identifier))
        return entries.compactMap { acceptedIdentifiers.contains($0.identifier) ? nil : $0.identifier }
    }

    private static func hasValidEntryIdentifier(_ identifier: String) -> Bool {
        hasValidIdentity(identifier)
    }

    private static func hasValidIdentity(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed == value,
              value.utf8.count <= maxIdentityUTF8Bytes else {
            return false
        }
        return !value.unicodeScalars.contains(where: { scalar in
            let scalarValue = scalar.value
            return CharacterSet.controlCharacters.contains(scalar)
                || scalar.properties.generalCategory == .format
                || (0x202A...0x202E).contains(scalarValue)
                || (0x2066...0x2069).contains(scalarValue)
        })
    }

    private static func totalTokenCost(_ costs: [Int]) -> Int? {
        var total = 0
        for cost in costs {
            guard cost >= 0 else { return nil }
            let (next, overflowed) = total.addingReportingOverflow(cost)
            guard !overflowed else { return nil }
            total = next
        }
        return total
    }

    private static func hasUniqueValidDroppedEntryIdentifiers(_ identifiers: [String]) -> Bool {
        identifiers.allSatisfy(hasValidEntryIdentifier)
            && hasUniqueEntryIdentifiers(identifiers)
    }

    private static func hasUniqueEntryIdentifiers(_ entries: [Entry]) -> Bool {
        hasUniqueEntryIdentifiers(entries.map(\.identifier))
    }

    private static func hasUniqueValidEntryIdentifiers(_ entries: [Entry]) -> Bool {
        entries.allSatisfy { hasValidEntryIdentifier($0.identifier) }
            && hasUniqueEntryIdentifiers(entries)
    }

    private static func hasUniqueEntryIdentifiers(_ identifiers: [String]) -> Bool {
        Set(identifiers).count == identifiers.count
    }

    private struct CacheKey: Hashable {
        let snapshot: ConversationContextSnapshotV1
        let entries: [Entry]
        let contextItems: [ContextItem]
        let budget: Int

        init(input: Input, budget: Int) {
            self.snapshot = input.snapshot
            self.entries = input.entries
            self.contextItems = input.contextItems
            self.budget = budget
        }
    }
}
