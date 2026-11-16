import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-H4A candidate source shown before per-fact activation")
@MainActor
struct MemoryProposalReviewSource2150Tests {
    private let scope = MemoryScope(sessionID: "h4a-session", projectID: "h4a-project")
    private let sourceID = "h4a-owned-composer"

    private func fixture(_ label: String) throws -> (SettingsCenter, URL) {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = formal.temporaryDirectory
            .appendingPathComponent("h4a-source-2150-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: root),
            envStore: EnvVarStore(directory: root),
            memoryStore: MemoryStore(directory: root),
            sessionStore: SessionStore(directory: root),
            logManager: LogManager(directory: root, ringCapacity: 50),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json")),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills", isDirectory: true))
        )
        center.memoryScopeProvider = { scope }
        return (center, root)
    }

    @Test func displaySeparatesGrantedSourceFromClaimBeforeActualApproval() throws {
        let (center, root) = try fixture("approve")
        defer { try? FileManager.default.removeItem(at: root) }
        let consumer = center.memoryProposalConsumer
        let grant = try consumer.grantCandidateSubmission(
            sourceID: sourceID, reason: "synthetic H4A source enable"
        )
        let reference = "claim://different-free-text-source"
        let submitted = try consumer.submit(
            proposalID: "h4a-approved-proposal", text: "只在批准后保存的事实",
            within: scope, sourceRef: reference, sourceID: sourceID
        )
        #expect(submitted.writeProvenance == nil, "ordinary built-in proposals have no typed tuple")
        let displayed = try #require(center.pendingMemoryProposals().first)
        #expect(displayed == submitted)
        let presentation = MemoryProposalReviewSourcePresentation(envelope: displayed)
        #expect(presentation.sourceLine == "候选来源 ID：\(grant.sourceID) · 提交授权纪元：\(grant.epoch)")
        #expect(presentation.referenceLine == "来源引用（候选声明）：\(reference)")
        #expect(try center.memoryStore.facts().isEmpty, "rendering cannot activate a fact")

        try center.approveDisplayedMemoryProposal(displayed)
        let fact = try #require(center.memoryStore.activeFacts().first)
        #expect(fact.sourceProposalID == displayed.proposal.proposalID)
        #expect(fact.sourceRef == reference)
        #expect(try consumer.proposalLineage(forFactID: fact.id, within: scope)?.sourceID == grant.sourceID)
    }

    @Test func visibleSourceDoesNotReplaceRevocationOrDisplayedEnvelopeBinding() throws {
        let (center, root) = try fixture("revoke")
        defer { try? FileManager.default.removeItem(at: root) }
        let consumer = center.memoryProposalConsumer
        _ = try consumer.grantCandidateSubmission(
            sourceID: sourceID, reason: "synthetic H4A source enable"
        )
        _ = try consumer.submit(
            proposalID: "h4a-revoked-proposal", text: "撤权前的待审事实",
            within: scope, sourceRef: "claim://not-an-authorization", sourceID: sourceID
        )
        let displayed = try #require(center.pendingMemoryProposals().first)
        #expect(MemoryProposalReviewSourcePresentation(envelope: displayed).sourceLine.contains(sourceID))
        _ = try consumer.revokeCandidateSubmission(
            sourceID: sourceID, reason: "synthetic H4A source revoke"
        )
        #expect(throws: MemoryProposalConsumerError.proposalConflict) {
            try center.approveDisplayedMemoryProposal(displayed)
        }
        #expect(try center.memoryStore.facts().isEmpty)
    }
}
