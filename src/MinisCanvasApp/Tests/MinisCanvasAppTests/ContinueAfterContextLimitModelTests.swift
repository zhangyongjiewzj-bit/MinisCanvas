import Foundation
import Testing
import Observation
import MinisCore
@testable import MinisCanvasApp

@Suite("Continue in new session keeps the selected model", .serialized)
@MainActor
struct ContinueAfterContextLimitModelTests {
    @Test func continuationSummaryCallsProviderOnMainActorAndPublishesPreview() async {
        let probe = ContinuationMainActorProbe()
        let draft = SessionContinuationDraft(sourceSessionID: UUID())
        await draft.generate(messages: [.init(role: .user, content: "synthetic summary history")],
            provider: ContinuationMainActorProbeProvider(probe: probe))
        #expect(probe.calls == 1)
        #expect(probe.wasMainThread)
        // 2026-11-16：摘要改为“有损摘要”格式（由模型生成、会有损，原话以用户为准）；
        // 不再断言整段文字，只验证来源标注与模型摘要正文。
        // 交接摘要只给摘要正文（不带“续做”提示和原话块），供用户审阅后作为新会话背景。
        #expect(!draft.previewText.hasPrefix("以下是此前对话的摘要"))
        #expect(draft.previewText.contains("main actor model summary"))
        #expect(draft.failureMessage == nil)
        #expect(!draft.isGenerating)
    }

    private func record(provider: String, model: String, ready: Bool = true) -> ProviderReadinessPersistenceRecord {
        ProviderReadinessPersistenceRecord(
            providerID: provider, modelID: model,
            status: ready ? .passed : .unavailable,
            readinessState: ready ? .mock : .blocked,
            checkedAt: Date(), evidenceID: ready ? "synthetic-continue-ready" : nil,
            isApplied: ready, expiresAt: Date().addingTimeInterval(300))
    }

    private func fixture(directory: URL) throws -> (ChatStore, ProviderReadinessStore) {
        let readiness = ProviderReadinessStore(directory: directory)
        readiness.upsert([
            record(provider: "CONTINUE_SOURCE", model: "first-model"),
            record(provider: "CONTINUE_SOURCE", model: "selected-model"),
            record(provider: "CONTINUE_DEFAULT", model: "default-model")
        ])
        let source = EnvVarEntry(name: "CONTINUE_SOURCE", value: "", baseURL: "https://source.invalid/v1",
            modelNames: ["first-model", "selected-model"], protocolType: .openaiCompatible)
        let fallback = EnvVarEntry(name: "CONTINUE_DEFAULT", value: "", baseURL: "https://default.invalid/v1",
            modelNames: ["default-model"], protocolType: .openaiCompatible)
        let chat = ChatStore(providerReadinessStore: readiness)
        // The model-selection tests choose the supported no-summary branch.
        // Never let draft generation reach a configured or network provider.
        chat.compactionProviderOverride = ContinueModelSyntheticSummaryFailureProvider()
        chat.providerRecordsSource = { [source, fallback] }
        #expect(chat.applyDefaultProviderModel(general: GeneralSettings(
            defaultProviderID: "custom.CONTINUE_DEFAULT", defaultModelID: "default-model")))
        #expect(chat.applyChatModel(providerID: source.name, modelID: "selected-model"))
        chat.modelSpeedTier = .quality
        return (chat, readiness)
    }

    private func continueThroughConfirmedEmptySummary(_ chat: ChatStore) async throws {
        chat.continueAfterContextLimit()
        let draft = try #require(chat.sessionContinuationDraft)
        // Observe completion instead of sleeping/polling or altering production
        // generation state. Eight changes bound this synthetic driver's work;
        // the test's time limit also cancels a missing completion notification.
        for _ in 0..<8 {
            if !draft.isGenerating { break }
            let changes = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            withObservationTracking { _ = draft.isGenerating } onChange: {
                changes.continuation.yield(())
                changes.continuation.finish()
            }
            var iterator = changes.stream.makeAsyncIterator()
            _ = try #require(await iterator.next())
        }
        try #require(!draft.isGenerating)
        #expect(draft.previewText.isEmpty)
        #expect(draft.confirmedBackgroundText == nil)
        chat.confirmSessionContinuation()
        #expect(chat.sessionContinuationDraft == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func continuationKeepsExactModelTierAndSourceWhileOrdinaryNewSessionKeepsDefault() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("continue-model-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (chat, _) = try fixture(directory: directory)
        chat.newSession(projectID: "synthetic-project", projectName: "合成项目",
            workingDirectory: directory.path, groupID: UUID())
        #expect(chat.applyChatModel(providerID: "CONTINUE_SOURCE", modelID: "selected-model"))
        chat.modelSpeedTier = .quality
        let source = try #require(chat.sessions.first(where: { $0.id == chat.activeSessionID }))
        chat.appendUser("保留原问题")
        chat.appendAssistant("保留原回答")
        chat.draftText = "未发送的原草稿"
        let history = chat.messages
        let originalTier = chat.modelSpeedTier
        chat.composerPolicySelection.effort = .high
        chat.recordTokens(try #require(chat.budgetCapTokens) + 1)
        try await continueThroughConfirmedEmptySummary(chat)
        let continued = try #require(chat.sessions.first(where: { $0.id == chat.activeSessionID }))
        #expect(continued.id != source.id)
        #expect(chat.selectedCustomProvider?.name == "CONTINUE_SOURCE")
        #expect(chat.selectedModelID == "selected-model")
        #expect(chat.modelSpeedTier == originalTier)
        #expect(continued.providerTypeRaw == "custom.CONTINUE_SOURCE")
        #expect(continued.modelID == "selected-model")
        #expect(continued.projectID == source.projectID && continued.groupID == source.groupID)
        #expect(continued.workingDirectory == source.workingDirectory)
        #expect(chat.messages.isEmpty && chat.draftText.isEmpty)
        #expect(chat.lastComposerSubmissionSnapshot == nil)
        var receivedEffort: ComposerEffort?
        chat.onComposerCommandPolicy = { _, snapshot in
            receivedEffort = snapshot.effort
            return .reject
        }
        #expect(chat.submitRegisteredComposerCommand(id: "status", args: [:]))
        #expect(receivedEffort == .high)
        #expect(chat.lastComposerSubmissionSnapshot?.effort == .high)
        #expect(chat.lastComposerSubmissionSnapshot?.sessionID == continued.id.uuidString)
        chat.switchSession(id: source.id)
        #expect(chat.messages == history && chat.draftText == "未发送的原草稿")
        chat.newSession()
        #expect(chat.selectedCustomProvider?.name == "CONTINUE_DEFAULT")
        #expect(chat.selectedModelID == "default-model")
        #expect(chat.sessions.last?.providerTypeRaw == nil)
    }

    /// S-08：会话绑定的服务商被删除后切回该会话，改用全局默认模型时要有一次提示，不能悄悄换家。
    @Test(.timeLimit(.minutes(1)))
    func switchingBackToASessionWhoseProviderWasRemovedShowsOneNotice() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("continue-model-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (chat, _) = try fixture(directory: directory)
        let boundID = try #require(chat.activeSessionID)
        #expect(chat.sessions.first(where: { $0.id == boundID })?.providerTypeRaw == "custom.CONTINUE_SOURCE")
        chat.newSession()
        #expect(chat.activeSessionID != boundID)
        // 服务商记录被删。
        chat.providerRecordsSource = { [] }
        chat.switchSession(id: boundID)
        #expect(chat.sessions.first(where: { $0.id == boundID })?.providerTypeRaw == nil)
        let notice = try #require(chat.pastedTextActionFeedback)
        #expect(notice.contains("selected-model"))
        #expect(notice.contains("已不可用"))
    }

    @Test func sessionModelOverrideNoticeNamesTheModelThenTheProvider() {
        #expect(ChatStore.sessionModelOverrideDisplayName(providerRaw: "custom.foo", modelID: "m1") == "m1")
        #expect(ChatStore.sessionModelOverrideDisplayName(providerRaw: "custom.foo", modelID: nil) == "foo")
        #expect(ChatStore.sessionModelOverrideDisplayName(providerRaw: nil, modelID: nil) == "未知")
    }

    @Test(.timeLimit(.minutes(1)))
    func unavailableOrIncompleteSourceUsesDefaultWithAccurateReason() async throws {
        // Reuse one fallback behavior test for readiness failure and each
        // incomplete identity shape; no source-string assertions are used.
        for missingField in ["none", "provider", "model"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("continue-model-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let (chat, readiness) = try fixture(directory: directory)
            let sourceID = try #require(chat.activeSessionID)
            let history = chat.messages
            switch missingField {
            case "provider": chat.selectedCustomProvider = nil
            case "model": chat.selectedModelID = nil
            default:
                readiness.upsert(record(provider: "CONTINUE_SOURCE", model: "selected-model", ready: false))
            }
            chat.recordTokens(try #require(chat.budgetCapTokens) + 1)
            try await continueThroughConfirmedEmptySummary(chat)
            #expect(chat.activeSessionID != sourceID)
            #expect(chat.selectedCustomProvider?.name == "CONTINUE_DEFAULT")
            #expect(chat.selectedModelID == "default-model")
            #expect(chat.sessions.last?.providerTypeRaw == nil)
            let expectedReason = missingField == "none"
                ? "原会话模型未通过当前可用性检查" : "原会话没有完整模型选择可沿用"
            #expect(chat.messages.contains(where: {
                $0.role == .system && $0.content.contains(expectedReason)
                    && $0.content.contains("全局默认") && $0.content.contains("default-model")
            }))
            #expect(chat.messages(forSession: sourceID) == history)
            #expect(chat.lastComposerSubmissionSnapshot == nil)
        }
    }

    @Test func continuationWithoutContextLimitDoesNotChangeSessionOrSelection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("continue-model-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (chat, _) = try fixture(directory: directory)
        let session = chat.activeSessionID
        let history = chat.messages
        let count = chat.sessions.count
        chat.continueAfterContextLimit()
        #expect(chat.activeSessionID == session && chat.sessions.count == count)
        #expect(chat.selectedCustomProvider?.name == "CONTINUE_SOURCE")
        #expect(chat.selectedModelID == "selected-model" && chat.modelSpeedTier == .quality)
        #expect(chat.messages == history)
    }
}

// A local failure exercises the approved editable/failure preview path without
// adding assistant background, preserving every original final-state assertion.
private struct ContinueModelSyntheticSummaryFailureProvider: LLMProvider {
    let name = "synthetic-continue-model-no-summary"
    var model = LLMModel(id: "synthetic", displayName: "synthetic", provider: "synthetic-continue-model-no-summary")
    enum Failure: Error { case noSummary }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        throw Failure.noSummary
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        throw Failure.noSummary
    }
}

@MainActor private final class ContinuationMainActorProbe {
    private(set) var calls = 0
    private(set) var wasMainThread = false
    func record(wasMainThread: Bool) {
        calls += 1
        self.wasMainThread = wasMainThread
    }
}

private struct ContinuationMainActorProbeProvider: LLMProvider {
    let probe: ContinuationMainActorProbe
    let name = "synthetic-main-actor-continuation"
    var model = LLMModel(id: "synthetic", displayName: "synthetic", provider: "synthetic-main-actor-continuation")
    // Synchronous sampling preserves the caller's current thread without an actor hop.
    private nonisolated static func isCallingThreadMain() -> Bool { Thread.isMainThread }

    nonisolated(nonsending) func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        let wasMainThread = Self.isCallingThreadMain()
        await probe.record(wasMainThread: wasMainThread)
        return LLMResponse(text: "main actor model summary", stopReason: "end_turn", usage: nil)
    }
    nonisolated(nonsending) func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
