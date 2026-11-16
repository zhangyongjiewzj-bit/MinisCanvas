import AppKit
import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

// Reuse the existing serialized Settings native host and real actions. This
// adds the missing user decision surface; it does not simulate a decision by
// calling approve/reject directly or treat a rendered candidate as a fact.
extension SettingsNativeInteractionConsumerTests {
    @Test("scoped pending memory requires the actual native approve or refuse action")
    @MainActor
    func pendingMemoryNativeDecisionsKeepForeignCandidatesAndPersistOnlyApproval() throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "pending-memory-native",
            processEnvironment: [:], processArguments: ["MemoryProposalNativeDecisionConsumerTests.xctest"],
            canvasRuntimeState: .disabled)
        defer { try? profile.cleanupDisposableRoots() }
        let scope = MemoryScope(sessionID: "native-review-A", projectID: "native-project-A")
        let foreignScope = MemoryScope(sessionID: "native-review-B", projectID: "native-project-B")
        let source = SettingsCenter.BuiltInMemoryCandidateSource.composerCommand
        let keychain = profile.makeKeychainStore()
        @MainActor func center() -> SettingsCenter {
            let value = SettingsCenter(settingsStore: SettingsStore(directory: profile.settingsDirectory),
                envStore: profile.makeEnvironmentStore(keychain: keychain),
                memoryStore: MemoryStore(directory: profile.memoryDirectory),
                sessionStore: SessionStore(directory: profile.sessionDirectory),
                logManager: profile.makeLogManager(),
                mcpManager: MCPServerManager(fileURL: profile.mcpConfigurationURL, keychain: keychain),
                skillStore: SkillStore(skillsRoot: profile.hermesSkillsDirectory),
                usageStore: UsageStore(domain: profile.usageStoreDefaultsDomain))
            value.memoryScopeProvider = { scope }
            return value
        }
        let owner = center()
        _ = try owner.provisionBuiltInMemoryCandidateSubmissions()
        let provenance = MemoryWriteProvenanceInput(actorID: "native-review-actor",
            runID: "native-review-run", triggerID: "native-review-trigger", sourceID: source.rawValue)
        let foreign = try owner.memoryProposalConsumer.submit(proposalID: "foreign-pending-native",
            text: "FOREIGN_CANDIDATE_MUST_STAY_PENDING", within: foreignScope,
            sourceRef: "synthetic://foreign-review", sourceID: source.rawValue, writeProvenance: provenance)
        let rejected = try owner.memoryProposalConsumer.submit(proposalID: "reject-pending-native",
            text: "NATIVE_REFUSE_MUST_NOT_BECOME_FACT", within: scope,
            sourceRef: "synthetic://native-review-rejected", sourceID: source.rawValue, writeProvenance: provenance)
        #expect(try owner.memoryStore.facts().isEmpty)
        let host = makeSettingsWindow(center: owner)
        defer { closeSettingsWindow(host) }

        @MainActor func node(_ identifier: String) throws -> AnyObject {
            for _ in 0..<20 {
                pumpSettingsRunLoop()
                if let value = findSettingsAX(in: host.window, identifier: identifier) { return value }
            }
            return try #require(nil as AnyObject?, Comment(rawValue: "Missing actual Settings control: \(identifier)"))
        }
        @MainActor func press(_ identifier: String) throws {
            let value = try node(identifier)
            try #require(settingsAXPress(value, in: host.window))
            pumpSettingsRunLoop()
        }
        @MainActor func showAndCheckOrigin(_ proposal: MemoryProposalEnvelope, reference: String) throws {
            let proposalID = proposal.proposal.proposalID
            let disclosure = try #require(NativeConsumerOwnedAX.find(in: host.window, label: "来源详情"))
            try #require(settingsAXPress(disclosure, in: host.window))
            pumpSettingsRunLoop()
            _ = try #require(NativeConsumerOwnedAX.findDisplayedText(in: host.window,
                exactText: "来源引用（候选声明）：\(reference)"))
            _ = try #require(NativeConsumerOwnedAX.findDisplayedText(in: host.window,
                exactText: "提议：\(proposalID) · 待审核"))
            let epoch = try #require(proposal.submissionEpoch)
            _ = try #require(NativeConsumerOwnedAX.findDisplayedText(in: host.window,
                exactText: "候选来源 ID：\(source.rawValue) · 提交授权纪元：\(epoch)"))
            let contentDigest = try #require(proposal.contentDigest)
            _ = try #require(NativeConsumerOwnedAX.findDisplayedText(in: host.window,
                exactText: "内容摘要：\(contentDigest)"))
            _ = try #require(NativeConsumerOwnedAX.findDisplayedText(in: host.window,
                exactText: "来源声明（非身份签名或授权）：actor native-review-actor · run native-review-run · trigger native-review-trigger"))
        }
        try press("settings-tab-memory")
        try press("settings.memory.refresh-proposals")
        #expect(try owner.pendingMemoryProposals().map { $0.proposal.proposalID } == [rejected.proposal.proposalID])
        // Real mounted view + explicit refresh have not approved anything.
        #expect(try owner.memoryStore.facts().isEmpty)
        #expect(try MemoryStore(directory: profile.memoryDirectory).facts().isEmpty)
        try showAndCheckOrigin(rejected, reference: "synthetic://native-review-rejected")
        try press("settings.memory.reject-proposal")
        #expect(try owner.memoryStore.facts().isEmpty)
        let afterRefusal = try owner.memoryProposalConsumer.envelopes()
        #expect(afterRefusal.first { $0.proposal.proposalID == rejected.proposal.proposalID }?.state == .rejected)
        #expect(afterRefusal.first { $0.proposal.proposalID == foreign.proposal.proposalID } == foreign)
        #expect(try owner.pendingMemoryProposals().isEmpty)

        let approved = try owner.memoryProposalConsumer.submit(proposalID: "approve-pending-native",
            text: "NATIVE_APPROVED_OWNED_FACT", within: scope,
            sourceRef: "synthetic://native-review-approved", sourceID: source.rawValue, writeProvenance: provenance)
        try press("settings.memory.refresh-proposals")
        #expect(try owner.memoryStore.facts().isEmpty)
        #expect(try owner.pendingMemoryProposals().map { $0.proposal.proposalID } == [approved.proposal.proposalID])
        try showAndCheckOrigin(approved, reference: "synthetic://native-review-approved")
        try press("settings.memory.approve-proposal")
        let fact = try #require(try owner.memoryStore.facts().first)
        #expect(try owner.memoryStore.facts().count == 1)
        #expect(fact.text == "NATIVE_APPROVED_OWNED_FACT" && fact.memoryScope == scope)
        #expect(fact.sourceProposalID == approved.proposal.proposalID)
        #expect(fact.sourceRef == "synthetic://native-review-approved")
        #expect(fact.writeProvenance?.actorID == provenance.actorID)
        #expect(fact.writeProvenance?.runID == provenance.runID)
        #expect(fact.writeProvenance?.triggerID == provenance.triggerID)
        #expect(fact.writeProvenance?.sourceID == source.rawValue)
        #expect(try owner.pendingMemoryProposals().isEmpty)
        let reopened = center()
        #expect(try reopened.memoryStore.facts() == [fact])
        let records = try reopened.memoryProposalConsumer.envelopes()
        #expect(records.first { $0.proposal.proposalID == rejected.proposal.proposalID }?.state == .rejected)
        #expect(records.first { $0.proposal.proposalID == foreign.proposal.proposalID } == foreign)
        let settled = try #require(records.first { $0.proposal.proposalID == approved.proposal.proposalID })
        #expect(settled.state == .active)
        #expect(settled.approvalReceipt != nil)
    }
}
