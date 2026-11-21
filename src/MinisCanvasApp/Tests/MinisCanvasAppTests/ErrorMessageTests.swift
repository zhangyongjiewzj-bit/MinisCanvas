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
                ? "本回合的工具调用已达上限（5 次），已先停下。点「继续」可接着做，也可以把任务拆小后再试"
                : "Max iterations exceeded (5) — please simplify the task or split it into steps"),
            (AgentLoopError.outputTokenCeilingExhausted, isChinese
                ? "当前上下文没有剩余输出额度，请增大上下文长度或缩短输入后重试"
                : "No output tokens remain in this context — increase the context length or shorten the input"),
            (ComposerAuthorizationError.modeExceedsAutonomyCeiling(required: .l2, maximum: .l1),
                "当前模式超出了你设置的运行安全上限。请把输入框齿轮里的模式改为手动审批，或到 设置 → 智能体运行 → 运行安全上限 调高上限。"),
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
            #expect(content.contains(ChatStore.unknownErrorMessage(.internalFailure)))
            #expect(content.contains("（CHAT-UNKNOWN:internal）"))
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

    /// 用户 11/21 会话 BE8372C4：工具超时以前显示"应用内部出现未归类的错误"。
    @Test func toolTimeoutIsShownAsAPlainRetryableMessage() {
        let message = ChatStore.userErrorMessage(ToolExecutorError.toolTimeout("shell_execute"))
        #expect(message == ChatStore.toolTimeoutTurnMessage)
        #expect(!message.contains("CHAT-UNKNOWN"))
        #expect(!message.contains("shell_execute"))
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

// MARK: - 八组：面向用户的错误说明（G-08 / G-14 / U-10 / T2-1）

@Suite("用户可见错误说明收口")
@MainActor
struct UserFacingErrorTextTests {
    @Test func englishInternalTagsAreRemovedButHTTPCodesStay() {
        let network = LLMError.networkError(underlying: URLError(.timedOut))
        let shown = UserFacingErrorText.stripEnglishTag(network.friendlyMessage(locale: Locale(identifier: "zh_CN")))
        #expect(!shown.contains("network"))
        #expect(shown.contains("请求超时"))
        let http = LLMError.httpStatus(code: 429, detail: "rate limit").friendlyMessage(locale: Locale(identifier: "zh_CN"))
        #expect(UserFacingErrorText.stripEnglishTag(http) == http)
        #expect(http.contains("429"))
        let provider = ChatStore.userErrorMessage(LLMError.providerError(message: "x"))
        #expect(!provider.contains("（provider）"))
    }

    @Test func systemEnglishDescriptionNeverReachesTheUser() {
        let path = "/Users/someone/secret-folder/a.txt"
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError,
            userInfo: [NSLocalizedDescriptionKey: "The file \(path) couldn’t be opened."])
        let shown = UserFacingErrorText.describe(cocoa)
        #expect(!shown.contains(path))
        #expect(!shown.contains("couldn’t"))
        #expect(UserFacingErrorText.containsChinese(shown))
        let owned = NSError(domain: "owned", code: 1, userInfo: [NSLocalizedDescriptionKey: "目标会话已被移走"])
        #expect(UserFacingErrorText.describe(owned) == "目标会话已被移走")
        let english = NSError(domain: "owned", code: 2, userInfo: [NSLocalizedDescriptionKey: "Boom token=abc"])
        #expect(!UserFacingErrorText.describe(english).contains("token=abc"))
    }

    /// 为什么必须扫描源码：约 90 处展示点分散在各个视图和控制器里，行为测试无法逐一触达；
    /// 新增一处把 `.localizedDescription` 直接拼进用户文字的写法，只有源码扫描能立刻发现。
    /// 白名单列的是确实安全的位置：固定中文文案的类型化错误、只进日志或生命周期记录的原因、
    /// 画布冻结范围内的文件。数字是该文件允许出现的最大次数，新增请改走 UserFacingErrorText.describe。
    @Test func viewLayerDoesNotInterpolateRawLocalizedDescription() throws {
        let allowed: [String: Int] = [
            "UserFacingErrorText.swift": 3,
            // 固定中文文案的类型化错误
            "ChatStore.swift": 12, "MCPManagerView.swift": 2, "ChatGPTAccountCard.swift": 2,
            "PackageFeatureManifest.swift": 4, "ContextPanelView.swift": 2,
            // 只进生命周期记录或已脱敏的摘要，不上屏
            "ChatAgentEngine.swift": 4, "SessionDrafts.swift": 2, "SettingsCenter.swift": 5,
            // 画布、视频节点、分镜相关（画布冻结，本轮不动）
            "BridgeStore.swift": 6, "CanvasStore.swift": 3, "CanvasMutationCoordinator.swift": 1,
            "AssetPanelView.swift": 1, "StoryboardWorkbenchView.swift": 1, "StoryboardExporter.swift": 2,
            "NodeChatStore.swift": 2, "NodeTextInspectorView.swift": 1, "VideoTaskExecutor.swift": 3,
        ]
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MinisCanvasApp")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }
        #expect(!files.isEmpty)
        var offenders: [String] = []
        for name in files {
            let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            let count = text.components(separatedBy: "localizedDescription").count - 1
            if count > (allowed[name] ?? 0) { offenders.append("\(name): \(count) > \(allowed[name] ?? 0)") }
        }
        #expect(offenders.isEmpty, "新增了直接展示 localizedDescription 的写法：\(offenders)")
    }
}
