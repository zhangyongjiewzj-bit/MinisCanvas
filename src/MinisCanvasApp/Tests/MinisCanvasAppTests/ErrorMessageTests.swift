import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

// MARK: - 对话错误文案回归测试

/// 只用于驱动 ChatStore 的错误路径：不调用真实 Provider，确保测试离线且确定性。
final class ErrorMessageTestProvider: LLMProvider, @unchecked Sendable {
    let name: String
    var model: LLMModel

    init(name: String = "错误测试 Provider", modelID: String = "error-test-model") {
        self.name = name
        self.model = LLMModel(id: modelID, displayName: modelID, provider: name)
    }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        fatalError("ErrorMessageTests 不应调用 sendMessage")
    }

    func streamMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        fatalError("ErrorMessageTests 不应调用 streamMessage")
    }
}

/// 让 streamReply 在引擎边界直接抛错，覆盖 ChatStore.catch 的真实接线。
final class ErrorMessageThrowingEngine: ComposerSnapshotForwardingTestEngine, @unchecked Sendable {
    let error: Error

    init(error: Error) {
        self.error = error
    }

    var isAvailable: Bool { true }

    func streamReply(
        provider: any LLMProvider,
        history: [ChatMessageUI],
        systemPrompt: String,
        maxTokens: Int
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        throw error
    }

    func interrupt() {}

    func compactContext(
        provider: any LLMProvider,
        history: [ChatMessageUI],
        systemPrompt: String,
        keepRecent: Int
    ) async -> CompactionResult {
        CompactionResult(messages: [], summary: nil, compactedCount: 0)
    }
}

@Suite("对话错误信息（模型上下文与友好原因）")
@MainActor
struct ErrorMessageTests {
    private let providerName = "错误测试 Provider"
    private let modelID = "error-test-model"

    @MainActor
    private func makeChat(error: Error) -> ChatStore {
        let chat = ChatStore()
        chat.streamingProviderOverride = ErrorMessageTestProvider(
            name: providerName,
            modelID: modelID
        )
        chat.agentEngine = ErrorMessageThrowingEngine(error: error)
        return chat
    }

    private func sendAndWait(for chat: ChatStore) async throws -> String {
        chat.draftText = "触发模型错误"
        chat.sendDraft()
        for _ in 0..<200 {
            if !chat.isStreaming {
                return chat.messages.last?.content ?? ""
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return chat.messages.last?.content ?? ""
    }

    @Test func knownSafeStopsReachTheActualAssistantWithoutUnknownGuidance() async throws {
        let isChinese = Locale.current.language.languageCode?.identifier.lowercased().hasPrefix("zh") ?? false
        let cases: [(error: any Error, expected: String)] = [
            (AgentLoopError.maxIterationsExceeded(5), isChinese
                ? "已达到最大迭代次数（5），请简化任务或拆分步骤后重试"
                : "Max iterations exceeded (5) — please simplify the task or split it into steps"),
            (AgentLoopError.outputTokenCeilingExhausted, isChinese
                ? "当前上下文没有剩余输出额度，请增大上下文长度或缩短输入后重试"
                : "No output tokens remain in this context — increase the context length or shorten the input"),
            (ComposerAuthorizationError.modeExceedsAutonomyCeiling(required: .l2, maximum: .l1),
                "当前模式需要自主权上限 L2，而你的上限是 L1。请把输入框齿轮里的模式改为手动审批，或到 设置 → 智能体运行 → 运行安全上限 调高上限。"),
            (AgentLoopChatEngine.ContextManifestConsumptionError.contextLengthExceeded,
                "当前上下文已超过设置的长度上限，本次请求未执行。请缩短输入或在新会话继续。")
        ]
        for item in cases {
            let chat = makeChat(error: item.error)
            defer { chat.stopAllStreamingForSafety() }
            let content = try await sendAndWait(for: chat)
            try #require(!chat.isStreaming)
            let assistant = try #require(chat.messages.last(where: { $0.role == .assistant }))
            #expect(assistant.content == content)
            #expect(content.contains(item.expected))
            #expect(!content.contains("CHAT-UNKNOWN"))
        }
    }

    @Test func unlistedErrorsKeepTheActualAssistantPayloadFree() async throws {
        let privatePayload = "SYNTHETIC-PRIVATE-BODY bearer=not-a-real-key /synthetic/private/path"
        let cases: [any Error] = [
            NSError(domain: "SyntheticUnknown", code: 17,
                userInfo: [NSLocalizedDescriptionKey: privatePayload]),
            AgentLoopError.invalidToolCatalog(privatePayload),
            ComposerAuthorizationError.missingCapabilityGrant(privatePayload),
            NSError(domain: "SyntheticUnlistedContextFailure", code: 18,
                userInfo: [NSLocalizedDescriptionKey: privatePayload]),
            AgentLoopStructuredFailure(agentError: .maxIterationsExceeded(5),
                message: privatePayload, toolExecutionFacts: [])
        ]
        for error in cases {
            let chat = makeChat(error: error)
            defer { chat.stopAllStreamingForSafety() }
            let content = try await sendAndWait(for: chat)
            try #require(!chat.isStreaming)
            let assistant = try #require(chat.messages.last(where: { $0.role == .assistant }))
            #expect(assistant.content == content)
            #expect(content.contains("操作未完成（CHAT-UNKNOWN）。请重试；若重复出现，请输入 /doctor 打开环境诊断，导出诊断包并附上此错误信息。"))
            #expect(!content.contains(privatePayload))
            #expect(!content.contains("SYNTHETIC-PRIVATE-BODY"))
            #expect(!content.contains("/synthetic/private/path"))
        }
    }

    @Test func staleSessionModelSelectionsExplainWhyTheRequestWasStopped() async throws {
        let removed = EnvVarEntry(
            name: "R6_C_01_PROVIDER", value: "",
            baseURL: "https://example.invalid", modelNames: [modelID]
        )
        let engineError = NSError(domain: "R6-C-01 unexpected engine invocation", code: 1)

        let restrictedChat = makeChat(error: engineError)
        restrictedChat.newSession()
        restrictedChat.setCustomProvider(removed)
        var allowedModels = [modelID]
        restrictedChat.modelAllowlistProvider = { allowedModels }
        allowedModels = ["other-allowed-model"]

        let restrictedContent = try await sendAndWait(for: restrictedChat)
        let restrictedAssistant = try #require(restrictedChat.messages.last(where: { $0.role == .assistant }))
        #expect(restrictedAssistant.content == restrictedContent)
        #expect(restrictedContent.contains("模型 \(modelID) 不在设置的可用白名单中，当前请求未执行。"))
        #expect(!restrictedContent.contains("CHAT-UNKNOWN"))

        let deletedChat = ChatStore()
        deletedChat.agentEngine = ErrorMessageThrowingEngine(error: engineError)
        var records = [removed]
        deletedChat.providerRecordsSource = { records }
        deletedChat.newSession()
        deletedChat.setCustomProvider(removed)
        records.removeAll()

        let deletedContent = try await sendAndWait(for: deletedChat)
        let deletedAssistant = try #require(deletedChat.messages.last(where: { $0.role == .assistant }))
        #expect(deletedAssistant.content == deletedContent)
        #expect(deletedContent.contains("服务商不可用：\(removed.name) 配置记录已删除，当前请求未执行"))
        #expect(!deletedContent.contains("CHAT-UNKNOWN"))
    }

    @Test func networkErrorIncludesProviderModelAndFriendlyReason() async throws {
        let error = LLMError.networkError(underlying: URLError(.timedOut))
        let content = try await sendAndWait(for: makeChat(error: error))

        #expect(content.contains("错误"))
        #expect(content.contains("（自定义 · \(modelID)）"))
        #expect(!content.contains(providerName))
        #expect(content.contains("网络错误"))
        // I0957: App copy stays Chinese even when the test process locale is English.
        #expect(content.contains("请求超时"))
        #expect(error.friendlyMessage(locale: Locale(identifier: "zh_CN")).contains("请求超时"))
        // The Core API still honors an explicit English locale and its existing copy.
        #expect(error.friendlyMessage(locale: Locale(identifier: "en_US")).contains("Request timed out"))
    }

    @Test func unauthorizedErrorIncludesProviderModelAndAPIKeyReason() async throws {
        let error = LLMError.httpStatus(code: 401, detail: "Unauthorized")
        let content = try await sendAndWait(for: makeChat(error: error))

        #expect(content.contains("错误"))
        #expect(content.contains("（自定义 · \(modelID)）"))
        #expect(!content.contains(providerName))
        #expect(content.contains("401"))
        #expect(content.contains("API Key"))
        #expect(content.contains("请检查 API Key"))
        #expect(!content.contains("HERMES_CUSTOM_QWEN38_API_KEY"))
        #expect(content.components(separatedBy: "API Key 无效或已过期").count == 2)
    }

    @Test func rateLimitErrorIncludesProviderModelAndFriendlyReason() async throws {
        let error = LLMError.httpStatus(code: 429, detail: "rate limit")
        let content = try await sendAndWait(for: makeChat(error: error))

        #expect(content.contains("错误"))
        #expect(content.contains("（自定义 · \(modelID)）"))
        #expect(!content.contains(providerName))
        #expect(content.contains("429"))
        #expect(content.contains("限流"))
    }

    @Test func interruptedErrorUsesOnlyInterruptedHint() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ErrorMessage-interrupted-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let chat = makeChat(error: InterruptedError())
        defer {
            chat.stopAllStreamingForSafety()
            try? FileManager.default.removeItem(at: directory)
        }
        #expect(chat.attachPersistence(SessionStore(directory: directory)))
        let sessionID = try #require(chat.activeSessionID)
        let content = try await sendAndWait(for: chat)
        #expect(!content.contains("**错误**"))
        let reopened = ChatStore()
        #expect(reopened.attachPersistence(SessionStore(directory: directory)))
        let message = try #require(reopened.sessions.first(where: { $0.id == sessionID })?.messages.last)
        #expect(message.role == .assistant && message.wasInterrupted && !message.isStreaming)
        #expect(message.content == content && !message.content.contains("**错误**"))
        #expect(ChatTranscriptFormatter.accessibilityText([message]).contains("已中断"))
    }

    @Test func rawURLErrorIsMappedToFriendlyChineseReason() {
        let error = URLError(.cannotConnectToHost)
        let message = ChatStore.userErrorMessage(error)

        #expect(message.contains("网络错误"))
        // I0957: App copy is independent of the test process locale.
        #expect(message.contains("无法连接到服务器"))
        #expect(LLMError.networkError(underlying: error)
            .friendlyMessage(locale: Locale(identifier: "zh_CN")).contains("无法连接到服务器"))
        #expect(LLMError.networkError(underlying: error)
            .friendlyMessage(locale: Locale(identifier: "en_US")).contains("Cannot connect to the server"))
    }

    @Test func providerRuntimeSnapshotErrorIsActionableAndDoesNotLeakInternalDetails() {
        let message = ChatStore.userErrorMessage(
            ProviderRuntimeSnapshotError.invalidApplyReceiptIdentity("internal-receipt")
        )

        // G-15：界面文案把 Provider 改为"服务商"。
        #expect(message.contains("服务商"))
        #expect(!message.contains("Provider"))
        #expect(message.contains("设置"))
        #expect(message.contains("重试"))
        #expect(!message.contains("ProviderRuntimeSnapshotError"))
        #expect(!message.contains("internal-receipt"))
    }

    @Test func fallbackRouterErrorsUseActionableChineseWithoutDetails() {
        let maliciousTrail = FallbackRouterError.allProvidersFailed([
            FallbackRouter.FallbackEvent(
                providerID: "malicious-provider-id",
                errorDescription: "Bearer token PII /private/tmp/evidence/body",
                attempt: 1
            )
        ])
        let allFailedMessage = ChatStore.userErrorMessage(maliciousTrail)
        #expect(
            allFailedMessage
                == "所有服务商均失败，请返回设置检查服务商和模型配置后重试。"
        )

        let emptyChainMessage = ChatStore.userErrorMessage(
            FallbackRouterError.emptyChain
        )
        #expect(
            emptyChainMessage
                == "未配置可用的服务商，请返回设置配置服务商和模型后重试。"
        )

        for message in [allFailedMessage, emptyChainMessage] {
            #expect(!message.contains("malicious-provider-id"))
            #expect(!message.contains("Bearer"))
            #expect(!message.contains("token"))
            #expect(!message.contains("PII"))
            #expect(!message.contains("/private/tmp"))
            #expect(!message.contains("evidence"))
        }
    }
}
