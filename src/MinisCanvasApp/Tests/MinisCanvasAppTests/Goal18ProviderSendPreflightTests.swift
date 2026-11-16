import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Goal18 one-shot provider send readiness")
@MainActor struct Goal18ProviderSendPreflightTests {
    private func root() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("Goal18SendPreflight-" + UUID().uuidString).resolvingSymlinksInPath()
        try #require(path.path.hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"))
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }
    private func subject(root: URL) throws -> ChatStore {
        let chat = ChatStore(providerReadinessStore: ProviderReadinessStore(directory: root))
        let modelID = try #require(ProviderType.openAI.builtInModels.first?.id)
        let route = try #require(ChatStore.BuiltinReadinessBinding.route(for: .openAI))
        let record = EnvVarEntry(name: ProviderType.openAI.rawValue, value: "", isSecret: true,
            baseURL: route.baseURL, modelNames: [modelID], protocolType: route.wire)
        chat.providerRecordsSource = { [record] }
        chat.providerCredentialMetadataSource = { _, _ in "synthetic-revision" }
        chat.providerConstructionPauseForTests = { [weak chat] in
            await MainActor.run {
                Issue.record("An unapplied readiness fixture reached provider construction")
                chat?.stopStreamingPreservingQueue()
            }
        }
        chat.selectedProviderType = .openAI
        chat.selectedModelID = modelID
        chat.draftText = "原始草稿"
        return chat
    }
    private func settle(_ chat: ChatStore) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while chat.isComposerCredentialPreflightPending && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!chat.isComposerCredentialPreflightPending)
    }
    @Test func failedReadinessChecksOnceAndPreservesUnsentDraft() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = try subject(root: root)
        var checks = 0
        chat.providerReadinessPreflight = { _, _ in checks += 1 }
        let count = chat.messages.count
        chat.submitComposer()
        chat.submitComposer()
        try await settle(chat)
        #expect(checks == 1)
        #expect(chat.draftText == "原始草稿")
        #expect(chat.messages.count == count)
        #expect(chat.pastedTextActionFeedback?.contains("草稿已保留") == true)
    }
    @Test func unavailableCredentialMetadataExplainsUnsentDraftAndRecovery() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = try subject(root: root)
        var metadataRead: CheckedContinuation<String?, Never>?
        defer {
            chat.cancelComposerCredentialPreflight()
            metadataRead?.resume(returning: nil)
        }
        chat.providerCredentialMetadataSource = { _, _ in
            guard !Task.isCancelled else { return nil }
            return await withCheckedContinuation { metadataRead = $0 }
        }
        let originalMessages = chat.messages
        chat.submitComposer()
        let deadline = ContinuousClock.now + .seconds(3)
        while metadataRead == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let read = try #require(metadataRead)
        #expect(chat.isComposerProviderPreparationPending)
        metadataRead = nil
        read.resume(returning: nil)

        try await settle(chat)
        #expect(chat.draftText == "原始草稿")
        #expect(chat.messages == originalMessages)
        #expect(!chat.isActiveSessionGenerating)
        let feedback = try #require(chat.pastedTextActionFeedback)
        #expect(feedback.contains("凭据"))
        #expect(feedback.contains("草稿已保留"))
        #expect(feedback.contains("连接设置") && feedback.contains("重试"))
    }

    @Test func stalledPreparationTimesOutBeforeLateMetadataCanResumeSend() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = try subject(root: root)
        var stalledRead: CheckedContinuation<String?, Never>?
        var metadataReads = 0
        var releasedReadReturned = false
        defer {
            chat.cancelComposerCredentialPreflight()
            stalledRead?.resume(returning: nil)
        }
        chat.providerCredentialMetadataSource = { _, _ in
            guard !Task.isCancelled else { return nil }
            metadataReads += 1
            if metadataReads == 1 {
                let revision: String? = await withCheckedContinuation { stalledRead = $0 }
                releasedReadReturned = true
                return revision
            }
            return "synthetic-revision"
        }

        let originalMessages = chat.messages
        let startedAt = ContinuousClock.now
        chat.submitComposer()
        let entryLimit = startedAt + .seconds(3)
        while stalledRead == nil && ContinuousClock.now < entryLimit {
            try await Task.sleep(for: .milliseconds(10))
        }
        let read = try #require(stalledRead)
        try #require(chat.isComposerProviderPreparationPending)

        // The proposed cap is 30 seconds. Allow one second for the MainActor
        // to observe and present the terminal state under the test runner.
        let observationLimit = startedAt + .seconds(31)
        while chat.isComposerProviderPreparationPending && ContinuousClock.now < observationLimit {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!chat.isComposerProviderPreparationPending)
        let timeoutFeedback = chat.pastedTextActionFeedback
        #expect(timeoutFeedback?.contains("超时") == true)
        #expect(timeoutFeedback?.contains("草稿已保留") == true)
        #expect(timeoutFeedback?.contains("重试") == true)
        #expect(chat.draftText == "原始草稿")
        #expect(chat.messages == originalMessages)

        stalledRead = nil
        read.resume(returning: "synthetic-revision")
        let releaseLimit = ContinuousClock.now + .seconds(3)
        while !releasedReadReturned && ContinuousClock.now < releaseLimit {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(releasedReadReturned)
        try await settle(chat)
        #expect(metadataReads == 1)
        #expect(chat.pastedTextActionFeedback == timeoutFeedback)
        #expect(chat.draftText == "原始草稿")
        #expect(chat.messages == originalMessages)
        #expect(!chat.isActiveSessionGenerating)
    }

    @Test func missingCallbackCannotConsumeDraftOrStartModelTurn() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = try subject(root: root)
        let count = chat.messages.count
        chat.submitComposer()
        try await settle(chat)
        #expect(chat.draftText == "原始草稿")
        #expect(chat.messages.count == count)
        #expect(!chat.isActiveSessionGenerating)
    }
    @Test func draftChangedDuringCheckCannotBeOverwrittenByLateProbe() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = try subject(root: root)
        var checks = 0
        chat.providerReadinessPreflight = { [weak chat] _, _ in
            checks += 1
            chat?.draftText = "用户的新草稿"
        }
        let count = chat.messages.count
        chat.submitComposer()
        try await settle(chat)
        #expect(checks == 1)
        #expect(chat.draftText == "用户的新草稿")
        #expect(chat.messages.count == count)
        #expect(!chat.isActiveSessionGenerating)
    }
    @Test func unAppliedReceiptAfterCheckStillCannotStartModelTurn() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = try subject(root: root)
        let readiness = try #require(chat.providerReadinessStore)
        var checks = 0
        chat.providerReadinessPreflight = { name, modelID in
            checks += 1
            readiness.upsert(ProviderReadinessPersistenceRecord(providerID: name, modelID: modelID,
                status: .passed, readinessState: .mock, checkedAt: Date(),
                evidenceID: "goal18-non-live-unapplied", isApplied: false))
        }
        let count = chat.messages.count
        chat.submitComposer()
        try await settle(chat)
        #expect(checks == 1)
        #expect(chat.draftText == "原始草稿")
        #expect(chat.messages.count == count)
        #expect(!chat.isActiveSessionGenerating)
    }
    @Test func sessionChangeDuringCheckCannotSendIntoEitherConversation() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = try subject(root: root)
        let source = try #require(chat.activeSessionID)
        let sourceMessages = chat.messages
        var destinationMessages: [ChatMessageUI] = []
        var checks = 0
        chat.providerReadinessPreflight = { [weak chat] _, _ in
            checks += 1
            chat?.newSession()
            destinationMessages = chat?.messages ?? []
        }
        chat.submitComposer()
        try await settle(chat)
        #expect(chat.activeSessionID != source)
        #expect(checks == 1)
        #expect(chat.messages == destinationMessages)
        #expect(!chat.messages.contains(where: { $0.role == .user || $0.turnTiming?.representsModelTurn == true }))
        chat.switchSession(id: source)
        #expect(chat.draftText == "原始草稿")
        #expect(chat.messages == sourceMessages)
    }
    @Test func capsuleChangeDuringCheckRetainsBothCapsulesAndDoesNotConsume() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = try subject(root: root)
        let first = PastedTextDraft(id: UUID(), text: "第一资料", source: .pasteboard)
        let second = PastedTextDraft(id: UUID(), text: "后加资料", source: .pasteboard)
        #expect(chat.setPastedTextDraft(first))
        let sourceMessages = chat.messages
        var checks = 0
        chat.providerReadinessPreflight = { [weak chat] _, _ in
            checks += 1
            _ = chat?.setPastedTextDraft(second)
        }
        chat.submitComposer()
        try await settle(chat)
        #expect(checks == 1)
        #expect(chat.activePastedTextDrafts == [first, second])
        #expect(chat.draftText == "原始草稿")
        #expect(chat.messages == sourceMessages)
    }
    @Test func revokedPolicyDuringCheckCannotResumeSubmission() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = try subject(root: root)
        let facts = ComposerPolicyFactSource(knownCapabilities: [], grantedCapabilities: [],
            allowedWriteRoots: [root.path], workspaceID: chat.composerWorkspaceID, revision: "before",
            grantEpoch: "synthetic", leaseID: "fixture", expiresAt: Date().addingTimeInterval(60), autonomyCeiling: .l3)
        chat.configureComposerPolicy(facts)
        let revokedFacts = ComposerPolicyFactSource(
            knownCapabilities: facts.knownCapabilities, grantedCapabilities: facts.grantedCapabilities,
            capabilityGrantBindings: facts.capabilityGrantBindings,
            allowedWriteRoots: facts.allowedWriteRoots, workspaceID: facts.workspaceID,
            revision: facts.revision, grantEpoch: facts.grantEpoch, leaseID: facts.leaseID,
            expiresAt: facts.expiresAt, revoked: true, autonomyCeiling: facts.autonomyCeiling)
        let sourceMessages = chat.messages
        var checks = 0
        chat.providerReadinessPreflight = { [weak chat] _, _ in
            checks += 1
            chat?.configureComposerPolicy(revokedFacts)
        }
        chat.submitComposer()
        try await settle(chat)
        #expect(chat.draftText == "原始草稿")
        #expect(checks == 1)
        #expect(chat.composerPolicyFacts.revoked)
        #expect(chat.messages == sourceMessages)
    }

}
