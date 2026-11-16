import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-MEMORY-05/12 approved predecessor presentation after Settings edit", .serialized)
@MainActor
struct MemoryEditApprovedOrigin0835Tests {
    @Test("Settings edit keeps current candidate unknown and shows only verified prior approval after cold reopen")
    func realSettingsEditPreservesAuditableOriginWithoutInheritingGrant() throws {
        _ = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "memory-edit-origin-0835", processEnvironment: [:],
            processArguments: ["/tmp/MinisCanvasAppTests.xctest"], canvasRuntimeState: .disabled)
        defer { try? profile.cleanupDisposableRoots() }
        let root = profile.rootDirectory.appendingPathComponent("owned-memory-edit-origin")
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let store = MemoryStore(directory: root)
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keychain),
            memoryStore: store,
            sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcp.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        )
        let scope = MemoryScope(sessionID: "session-0835", projectID: "project-0835")
        center.memoryScopeProvider = { scope }
        let grant = try center.provisionMemoryCandidateSubmission()
        #expect(grant.sourceID == "settings-center")
        #expect(center.addMemoryFactResult("0835 first approved text") == .added)
        let original = try #require(center.memoryFacts.first)
        let originalEnvelope = try #require(center.memoryProposalConsumer.envelopes().first)
        #expect(originalEnvelope.sourceID == grant.sourceID)
        #expect(originalEnvelope.submissionEpoch == grant.epoch)
        #expect(originalEnvelope.approvalReceipt?.state == .approved)

        let second = try center.editMemoryFact(id: original.id, newText: "0835 second text")
        let third = try center.editMemoryFact(id: second.id, newText: "0835 third text")
        #expect(third.revision == 3 && third.supersedesFactID == second.id)
        #expect(third.writeProvenance == nil)
        #expect(third.sourceProposalID == "user-edit:\(second.id):r3")
        #expect(third.sourceRef == "settings://memory/\(second.id)/revision-3")
        let after = try store.facts()
        #expect(after.count == 3)
        #expect(after.first(where: { $0.id == original.id })?.lifecycleState == .superseded)
        #expect(after.first(where: { $0.id == second.id })?.lifecycleState == .superseded)
        #expect(center.memoryFacts == [third])
        #expect(try center.memoryProposalConsumer.envelopes() == [originalEnvelope])

        // Fresh owner reads the real persisted fact and approval ledgers. The
        // edited content has no new candidate grant; history is separately
        // labelled as the predecessor's approval, never copied into the fact.
        let reopenedStore = MemoryStore(directory: root)
        let reopenedConsumer = MemoryProposalConsumer(store: reopenedStore)
        #expect(try reopenedStore.facts() == after)
        #expect(try reopenedConsumer.envelopes() == [originalEnvelope])
        let active = try #require(reopenedStore.activeFacts().first)
        let clear = ChatTranscriptRedactor(secretValues: [])
        let snapshot = try MemoryActiveFactSourceSnapshot(consumer: reopenedConsumer)
        let view = MemoryActiveFactSourceView(fact: active, snapshot: snapshot, redactor: clear)
        let rendered = String(view.renderedText.characters)
        #expect(view.accessibilityText == rendered)
        #expect(rendered.contains("候选来源 ID：旧记录未提供 · 提交授权纪元：旧记录未提供"))
        #expect(rendered.contains("前序已批准来源 ID：settings-center · 当时提交授权纪元：\(grant.epoch)"))
        #expect(rendered.contains("不代表当前修订的提交授权"))
        #expect(rendered.contains("来源引用（候选声明）：settings:<path>"))
        #expect(!rendered.contains(third.sourceRef!))
        #expect(!rendered.contains("来源提交授权：已开启"))
        #expect(try reopenedStore.facts() == after)

        // A legacy fact has no approved proposal. Editing it must not borrow
        // the unrelated Settings proposal even when it shares the same scope.
        let legacy = try store.addFact("0835 legacy text", memoryScope: scope)
        let legacyEdited = try center.editMemoryFact(id: legacy.id, newText: "0835 legacy edit")
        let legacyStore = MemoryStore(directory: root)
        let legacySnapshot = try MemoryActiveFactSourceSnapshot(
            consumer: MemoryProposalConsumer(store: legacyStore))
        let legacyText = legacySnapshot.text(for: legacyEdited, redactor: clear)
        #expect(legacyText.contains("候选来源 ID：旧记录未提供"))
        #expect(!legacyText.contains("前序已批准来源 ID"))

        // Revoking future submissions must not erase the approved predecessor
        // or turn its old grant into permission for the edited revision.
        _ = try center.memoryProposalConsumer.revokeCandidateSubmission(sourceID: grant.sourceID)
        let revokedStore = MemoryStore(directory: root)
        let revokedText = try MemoryActiveFactSourceSnapshot(
            consumer: MemoryProposalConsumer(store: revokedStore)).text(for: third, redactor: clear)
        #expect(revokedText.contains("前序已批准来源 ID：settings-center"))
        #expect(!revokedText.contains("来源提交授权：已开启"))
        #expect(try revokedStore.facts().first(where: { $0.id == third.id }) == third)
    }
}
