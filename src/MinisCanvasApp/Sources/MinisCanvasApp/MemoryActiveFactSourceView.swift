import Foundation
import SwiftUI
import MinisCore

/// A read-only snapshot of the existing proposal and submission ledgers.
/// Reading or rendering this value never grants a source or activates a fact.
struct MemoryActiveFactSourceSnapshot: Sendable {
    private let proposals: [String: MemoryProposalEnvelope]
    private let authorizations: [String: MemoryCandidateSubmissionAuthorization]
    private let facts: [String: MemoryFact]
    private let available: Bool

    init(consumer: MemoryProposalConsumer) throws {
        let loadedProposals = try consumer.envelopes()
        let proposalsByID = Dictionary(loadedProposals.map {
            ($0.proposal.proposalID, $0)
        }, uniquingKeysWith: { first, _ in first })
        guard proposalsByID.count == loadedProposals.count else {
            throw MemoryProposalConsumerError.proposalConflict
        }
        let loadedAuthorizations = try consumer.candidateSubmissionAuthorizations()
        let authorizationsByID = Dictionary(loadedAuthorizations.map {
            ($0.sourceID, $0)
        }, uniquingKeysWith: { first, _ in first })
        guard authorizationsByID.count == loadedAuthorizations.count else {
            throw MemoryProposalConsumerError.invalidSourceID
        }
        let loadedFacts = try consumer.store.facts()
        let factsByID = Dictionary(loadedFacts.map { ($0.id, $0) },
                                   uniquingKeysWith: { first, _ in first })
        guard factsByID.count == loadedFacts.count else {
            throw MemoryStoreError.conflictingFactID
        }
        proposals = proposalsByID
        authorizations = authorizationsByID
        facts = factsByID
        available = true
    }

    private init() {
        proposals = [:]; authorizations = [:]; facts = [:]; available = false
    }
    static let unavailable = MemoryActiveFactSourceSnapshot()

    private func matchingProposal(for fact: MemoryFact) -> MemoryProposalEnvelope? {
        fact.sourceProposalID.flatMap { proposals[$0] }.flatMap { proposal in
            guard let scope = fact.memoryScope, scope.isValid,
                  let digest = fact.contentDigest, !digest.isEmpty,
                  proposal.proposal.memoryScope == scope,
                  proposal.text == fact.text,
                  proposal.contentDigest == digest,
                  proposal.writeProvenance == fact.writeProvenance else { return nil }
            return proposal
        }
    }

    /// A Settings edit has its own new revision and content digest; it must not
    /// inherit the predecessor's candidate grant or typed write provenance.
    /// Only show the earlier approved source as historical lineage after
    /// validating every persisted supersession hop and its original envelope.
    private func approvedPredecessor(for fact: MemoryFact) -> MemoryProposalEnvelope? {
        guard available, facts[fact.id] == fact, fact.supersedesFactID != nil else { return nil }
        var current = fact
        var visited: Set<String> = [fact.id]
        while let priorID = current.supersedesFactID {
            guard visited.insert(priorID).inserted,
                  let prior = facts[priorID], prior.lifecycleState == .superseded,
                  current.revision == prior.revision + 1,
                  current.sourceProposalID == "user-edit:\(prior.id):r\(current.revision)",
                  current.sourceRef == "settings://memory/\(prior.id)/revision-\(current.revision)",
                  let scope = current.memoryScope, scope.isValid,
                  scope == prior.memoryScope,
                  current.sourceSessionID == prior.sourceSessionID,
                  current.ownerUserID == prior.ownerUserID,
                  current.visibility == prior.visibility,
                  current.temporaryLifetimeID == prior.temporaryLifetimeID,
                  current.category == prior.category else { return nil }
            if let proposal = matchingProposal(for: prior),
               proposal.state == .active,
               let approval = proposal.approvalReceipt,
               approval.state == .approved,
               approval.proposalID == prior.sourceProposalID,
               approval.memoryScope == prior.memoryScope,
               proposal.sourceID != nil, proposal.submissionEpoch != nil {
                return proposal
            }
            current = prior
        }
        return nil
    }

    func text(for fact: MemoryFact, redactor: ChatTranscriptRedactor) -> String {
        let lineage = matchingProposal(for: fact)
        // Typed origin comes from the fact. Built-in proposals without a typed
        // tuple use their exact persisted lineage, never a guessed source.
        let origin = fact.writeProvenance
        let sourceID = origin?.sourceID ?? lineage?.sourceID
        let epoch = origin?.submissionEpoch ?? lineage?.submissionEpoch
        var lines = [
            "候选来源 ID：\(redactor.redact(sourceID ?? "旧记录未提供")) · 提交授权纪元：\(epoch.map { String($0) } ?? "旧记录未提供")",
            "来源引用（候选声明）：\(redactor.redact(fact.sourceRef ?? "未提供"))"
        ]
        if let predecessor = approvedPredecessor(for: fact),
           let precedingSource = predecessor.sourceID,
           let precedingEpoch = predecessor.submissionEpoch {
            lines.append("前序已批准来源 ID：\(redactor.redact(precedingSource)) · 当时提交授权纪元：\(precedingEpoch)（不代表当前修订的提交授权）")
        }
        if let origin {
            lines.append("来源声明（非身份签名或授权）：actor \(redactor.redact(origin.actorID)) · run \(redactor.redact(origin.runID)) · trigger \(redactor.redact(origin.triggerID))")
        }
        switch fact.lifecycleState {
        case .active: lines.append("记忆状态：已激活")
        case .superseded: lines.append("记忆状态：已替代")
        case .rolledBack: lines.append("记忆状态：已回滚")
        case .tombstoned: lines.append("记忆状态：已删除")
        }
        if available, let sourceID, let authorization = authorizations[sourceID] {
            lines.append(authorization.canSubmit
                ? "来源提交授权：已开启；新增事实仍须逐条批准。"
                : "来源提交授权：已撤回；已批准记忆仍保留。")
        } else {
            lines.append("来源提交授权：状态未提供")
        }
        return lines.joined(separator: "\n")
    }
}

/// The active Memory card renders and exposes the same protected payload.
/// The production consumer test checks this renderer payload after reopening
/// facts and both ledgers; it does not scan source or mirror the engine.
struct MemoryActiveFactSourceView: View {
    let renderedText: AttributedString
    let accessibilityText: String
    let factID: String

    init(fact: MemoryFact, snapshot: MemoryActiveFactSourceSnapshot,
         redactor: ChatTranscriptRedactor) {
        let text = snapshot.text(for: fact, redactor: redactor)
        renderedText = AttributedString(text)
        accessibilityText = text
        factID = fact.id
    }

    var body: some View {
        DisclosureGroup("来源详情") {
            Text(renderedText)
            .textSelection(.enabled)
            .foregroundStyle(.secondary)
            .accessibilityLabel(accessibilityText)
            .accessibilityIdentifier("settings.memory.active-source.\(factID)")
        }
    }
}
