import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private final class DD4BTransportProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var methods: [String] = []

    func record(_ method: String) {
        lock.lock()
        methods.append(method)
        lock.unlock()
    }

    var recordedMethods: [String] {
        lock.lock()
        defer { lock.unlock() }
        return methods
    }
}

private struct DD4BFailingMCPTransport: MCPTransport {
    let probe: DD4BTransportProbe

    func start() async throws {}

    func send(_ request: MCPJSONRPCRequest) async throws -> MCPJSONRPCResponse {
        probe.record(request.method)
        throw MCPClientError.rpcError(code: 401, message: "unauthorized")
    }

    func notify(_ notification: MCPJSONRPCNotification) throws {}

    func stop() {}
}

private final class DD4BTextTurnProvider: LLMProvider, @unchecked Sendable {
    let name = "DD4B fixture provider"
    var model = LLMModel(
        id: "dd4b-text-model",
        displayName: "DD4B text model",
        provider: "dd4b-fixture"
    )
    let capabilities: Set<ProviderCapability> = [.streaming, .tools]

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        LLMResponse(text: "ordinary text turn remains available", stopReason: "stop", usage: nil)
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        try await sendMessage(
            messages: messages,
            systemPrompt: systemPrompt,
            maxTokens: maxTokens,
            temperature: temperature
        )
    }

    func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.text("ordinary text turn remains available"))
            continuation.yield(.finished(stopReason: "stop"))
            continuation.finish()
        }
    }
}

private struct DD4BFailingCatalogBridge: MCPToolBridge, Sendable {
    let secret: String

    func mcpBoundTools() async throws -> [MCPBoundTool] {
        throw MCPClientError.permissionDenied(secret)
    }

    func callMCPTool(fullName: String, arguments: [String: Any]?) async throws -> String {
        throw MCPClientError.toolNotFound(fullName)
    }
}

private final class B2MCPProjectionEngine: ComposerSnapshotForwardingTestEngine, @unchecked Sendable {
    var isAvailable: Bool { true }

    func interrupt() {}

    func streamReply(
        provider: any LLMProvider,
        history: [ChatMessageUI],
        systemPrompt: String,
        maxTokens: Int
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                try? await Task.sleep(for: .milliseconds(20))
                guard !Task.isCancelled else {
                    continuation.finish()
                    return
                }
                continuation.yield(.contentBlockStart(.mcpDiscoveryFailure(.authorization)))
                continuation.yield(.textDelta("ordinary text remains available"))
                continuation.yield(.done(stopReason: .endTurn))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func compactContext(
        provider: any LLMProvider,
        history: [ChatMessageUI],
        systemPrompt: String,
        keepRecent: Int
    ) async -> CompactionResult {
        CompactionResult(messages: [], summary: nil, compactedCount: 0)
    }
}

@Suite("DD4B MCP credential and ordinary text-turn isolation")
@MainActor
struct MCPTextTurnCredentialIsolationTests {
    @Test func productionStreamEmitsTypedMCPDiscoveryFailureWithoutRawError() async throws {
        let secret = "dd4b-stream-secret-sentinel"
        let engine = AgentLoopChatEngine(
            mcpBridge: DD4BFailingCatalogBridge(secret: secret)
        )
        let stream = try await engine.streamReply(
            provider: DD4BTextTurnProvider(),
            history: [ChatMessageUI(role: .user, content: "普通文本")],
            systemPrompt: "test",
            maxTokens: 128,
            conversationID: "dd4b-stream-discovery-failure",
            authorizedSessionReadSessionID: nil,
            turnID: 1
        )

        var output = ""
        var discoveryFailure: AgentToolCatalogDiscoveryFailure?
        for try await event in stream {
            switch event {
            case .contentBlockStart(.mcpDiscoveryFailure(let failure)):
                discoveryFailure = failure
            case .textDelta(let text):
                output += text
            default:
                break
            }
        }

        #expect(discoveryFailure == .authorization)
        #expect(output == "ordinary text turn remains available")
        #expect(String(describing: discoveryFailure).contains(secret) == false)
    }

    @Test func chatStoreProjectsMCPDiscoveryFailureWithoutSecretOrCrossTurnWriteback() async throws {
        let notice = "MCP 工具未授权，已继续使用内置工具。请在设置中授权后重试。"
        let rawSentinel = "dd4b-chat-store-raw-error-sentinel"
        let provider = DD4BTextTurnProvider()

        let normalChat = ChatStore()
        normalChat.agentEngine = B2MCPProjectionEngine()
        normalChat.streamingProviderOverride = provider
        normalChat.draftText = "普通文本"
        let originalSessionID = try #require(normalChat.activeSessionID)
        normalChat.sendDraft()
        normalChat.newSession()
        let replacementSessionID = try #require(normalChat.activeSessionID)

        var originalContent = ""
        for _ in 0..<40 {
            let originalMessage = normalChat.sessions
                .first(where: { $0.id == originalSessionID })?.messages.last
            originalContent = originalMessage?.content ?? ""
            if originalContent.contains(notice),
               originalContent.contains("ordinary text remains available"),
               originalMessage?.isStreaming == false {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let replacementContent = normalChat.sessions
            .first(where: { $0.id == replacementSessionID })?.messages
            .map(\.content).joined(separator: "\n") ?? ""
        #expect(originalContent.contains(notice))
        #expect(originalContent.contains("ordinary text remains available"))
        #expect(!originalContent.contains(rawSentinel))
        #expect(!replacementContent.contains(notice), "旧回合诊断不得写入新会话")

        let conciseChat = ChatStore()
        conciseChat.agentEngine = B2MCPProjectionEngine()
        conciseChat.streamingProviderOverride = provider
        conciseChat.setOutputMode(.concise)
        conciseChat.draftText = "极简文本"
        conciseChat.sendDraft()

        var conciseContent = ""
        for _ in 0..<40 {
            conciseContent = conciseChat.messages.last?.content ?? ""
            if conciseContent.contains(notice),
               conciseContent.contains("ordinary text remains available"),
               conciseChat.messages.last?.isStreaming == false {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(conciseContent.contains(notice))
        #expect(conciseContent.contains("ordinary text remains available"))
        #expect(!conciseContent.contains(rawSentinel))
    }

    @Test func mcpAuthFailureIsRedactedWithoutBlockingOrdinaryTextTurn() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DD4B-MCP-Credential-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let syntheticCredential = "dd4b-synthetic-credential-sentinel"
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let manager = MCPServerManager(
            fileURL: root.appendingPathComponent("mcps.json"),
            keychain: keychain
        )
        let server = MCPServer(
            id: "dd4b-auth-failure",
            name: "DD4B Auth Failure",
            type: .stdio,
            command: nil,
            env: ["API_TOKEN": syntheticCredential],
            headers: ["Authorization": "Bearer \(syntheticCredential)"]
        )
        try manager.addServer(server)
        try manager.authorizeServer(id: server.id)

        let probe = DD4BTransportProbe()
        let registry = MCPToolRegistry(
            manager: manager,
            clientFactory: { server in
                MCPClient(
                    server: server,
                    transport: DD4BFailingMCPTransport(probe: probe)
                )
            }
        )
        try await registry.refreshTools()
        #expect(try await registry.mcpBoundTools().isEmpty)
        #expect(probe.recordedMethods.contains("initialize"))

        let logManager = LogManager(
            directory: root.appendingPathComponent("logs"),
            ringCapacity: 20
        )
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(
                directory: root.appendingPathComponent("env"),
                keychain: keychain
            ),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
            logManager: logManager,
            mcpManager: manager,
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        )
        let diagnostic = try #require(await center.testMCPServer(server))
        #expect(diagnostic.contains("连接失败"))
        #expect(!diagnostic.contains(syntheticCredential))

        let rawFailure = MCPClientError.rpcError(
            code: 401,
            message: "credential=\(syntheticCredential)"
        ).localizedDescription
        let redactor = ChatTranscriptRedactor(secretValues: [syntheticCredential])
        let messages = [ChatMessageUI(role: .assistant, content: rawFailure)]
        let plain = ChatTranscriptFormatter.plainText(messages, redactor: redactor)
        let accessibility = ChatTranscriptFormatter.accessibilityText(messages, redactor: redactor)
        #expect(!plain.contains(syntheticCredential))
        #expect(!accessibility.contains(syntheticCredential))

        logManager.error(diagnostic, category: "MCP")
        center.reloadLogs()
        #expect(!center.logEntries.map(\.message).joined(separator: "\n").contains(syntheticCredential))
        let persistedLog = try #require(logManager.logFileURL())
        let persistedLogText = try String(contentsOf: persistedLog, encoding: .utf8)
        #expect(!persistedLogText.contains(syntheticCredential))

        let persistedMCP = try String(
            contentsOf: root.appendingPathComponent("mcps.json"),
            encoding: .utf8
        )
        #expect(!persistedMCP.contains(syntheticCredential))
        let exported = try #require(manager.exportMCPJSON(server: server))
        #expect(!exported.contains(syntheticCredential))
        #expect(exported.contains("<redacted>"))

        let turn = AgentTurnIdentity(
            sessionID: "fd79-credential-isolation-session",
            turnID: 1,
            messageID: "fd79-credential-isolation-message"
        )
        let ceiling: AutonomyLevel = .l1
        let composerSnapshot = ComposerSubmissionSnapshot(
            mode: .manual,
            approvalScope: .request,
            effort: .standard,
            sessionID: turn.sessionID,
            turnID: turn.turnID,
            taskID: "fd79-credential-isolation-task",
            attemptID: "fd79-credential-isolation-attempt",
            messageID: turn.messageID,
            inputDigest: "fd79-credential-isolation-input",
            workspaceID: "fd79-credential-isolation-workspace",
            createdAt: Date(timeIntervalSince1970: 1_787_200_000),
            policyRevision: "fd79-credential-isolation-policy",
            grantEpoch: "fd79-credential-isolation-epoch",
            autonomyCeiling: ceiling
        )
        let engine = AgentLoopChatEngine(
            composerPolicyFacts: ComposerPolicyFactSource(
                knownCapabilities: [],
                grantedCapabilities: [],
                allowedWriteRoots: [],
                workspaceID: composerSnapshot.workspaceID,
                revision: composerSnapshot.policyRevision,
                grantEpoch: composerSnapshot.grantEpoch,
                leaseID: "fd79-credential-isolation-lease",
                expiresAt: .distantFuture,
                autonomyCeiling: ceiling
            )
        )
        let executionIdentity = AgentExecutionIdentity(
            turn: turn,
            operationID: "fd79-credential-isolation-operation"
        )
        let runtimeSnapshot = ChatTurnRuntimeSnapshot(
            turn: turn,
            skillInjector: SkillInjector(
                store: SkillStore(
                    skillsRoot: root.appendingPathComponent("skills")
                )
            ).snapshotForTurn(),
            mcpBridge: try registry.snapshotForTurn()
        )
        let stream = try await engine.streamReply(
            provider: DD4BTextTurnProvider(),
            history: [ChatMessageUI(role: .user, content: "普通文本回合")],
            systemPrompt: "test",
            maxTokens: 128,
            conversationID: turn.sessionID,
            authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil,
            turnID: turn.turnID,
            composerSnapshot: composerSnapshot,
            executionIdentity: executionIdentity,
            turnRuntimeSnapshot: runtimeSnapshot
        )
        var output = ""
        for try await event in stream {
            if case .textDelta(let text) = event {
                output += text
            }
        }
        #expect(output == "ordinary text turn remains available")
    }
}
