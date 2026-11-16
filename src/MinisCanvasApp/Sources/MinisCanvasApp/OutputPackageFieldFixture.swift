import Darwin
import Foundation
import MinisCore

/// Explicit, disposable field producer for the ordinary output UI. It submits
/// one synthetic Composer turn to the real BridgeStore-owned AgentLoop; no
/// transcript, tool phase, file-change record, or terminal fact is seeded.
enum OutputPackageFieldFixture {
    static let activationArgument = "--output-field-journey"
    private static let markerName = "output-field-fixture-v1.marker"
    private static let markerContents = "OUTPUT_FIELD_FIXTURE_V1\n"

    enum FixtureError: LocalizedError {
        case unsafeRoot, invalidMarker, missingSession, missingProductionEngine
        case producerDidNotReachTerminal, approvalPolicyUnavailable, scriptedMockAlreadyInUse

        var errorDescription: String? {
            switch self {
            case .unsafeRoot: "输出现场根不是本用户的隔离目录"
            case .invalidMarker: "输出现场标记无效，拒绝重复运行"
            case .missingSession: "输出现场缺少活跃会话"
            case .missingProductionEngine: "输出现场缺少生产 AgentLoop 或文件台账"
            case .producerDidNotReachTerminal: "输出现场生产回合未形成真实终态"
            case .approvalPolicyUnavailable: "输出现场无法设置隔离审批策略"
            case .scriptedMockAlreadyInUse: "输出现场已有脚本回合，拒绝覆盖"
            }
        }
    }

    static func isRequested(
        profile: RuntimeIsolationProfile,
        sessionFieldJourney: Bool,
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let count = arguments.filter { $0 == activationArgument }.count
        guard count > 0 else { return false }
        precondition(count == 1, "Output field journey activation must be unique")
        precondition(profile.mode == .packagedField && sessionFieldJourney,
                     "Output field journey requires the session packaged-field profile")
        precondition(environment[RuntimeIsolationProfile.fieldActivationMarkerKey] == "1",
                     "Output field journey requires the explicit field marker")
        return true
    }

    @MainActor
    static func run(
        profile: RuntimeIsolationProfile, bridge: BridgeStore,
        sessionFieldJourney: Bool,
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        settingsCenter: SettingsCenter? = nil
    ) async throws {
        guard PackageFieldFixtureArguments.areValid(arguments, environment: environment),
              arguments.filter({ $0 == activationArgument }).count == 1,
              sessionFieldJourney, profile.mode == .packagedField,
              environment[RuntimeIsolationProfile.fieldActivationMarkerKey] == "1"
        else { throw FixtureError.unsafeRoot }
        try profile.validateDisposableRootIdentity()
        let rootFD = Darwin.open(
            profile.rootDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootFD >= 0 else { throw FixtureError.unsafeRoot }
        defer { _ = Darwin.close(rootFD) }
        var info = stat()
        guard Darwin.fstat(rootFD, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              (info.st_mode & 0o777) == 0o700,
              info.st_uid == geteuid(),
              profile.mode == .packagedField else { throw FixtureError.unsafeRoot }
        let marker = profile.rootDirectory.appendingPathComponent(markerName)
        if FileManager.default.fileExists(atPath: marker.path) {
            guard (try? String(contentsOf: marker, encoding: .utf8)) == markerContents else {
                throw FixtureError.invalidMarker
            }
            return
        }
        guard let sessionID = bridge.chat.activeSessionID else { throw FixtureError.missingSession }
        guard bridge.chat.agentEngine is AgentLoopChatEngine,
              bridge.productionBuiltinToolExecutor != nil,
              bridge.productionFileChangeLedger != nil else {
            throw FixtureError.missingProductionEngine
        }
        let toolRoot = profile.rootDirectory.appendingPathComponent(
            "output-field-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: toolRoot, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let readFile = toolRoot.appendingPathComponent("read-\(UUID().uuidString).txt")
        let changedFile = toolRoot.appendingPathComponent("change-\(UUID().uuidString).txt")
        let missingFile = toolRoot.appendingPathComponent("missing-\(UUID().uuidString).txt")
        try "OUTPUT_FIELD synthetic read only\n".write(
            to: readFile, atomically: true, encoding: .utf8
        )
        let provider = OutputFieldControlledProvider(
            readFile: readFile, changedFile: changedFile, missingFile: missingFile
        )
        // Claim before the asynchronous production submission. A restart
        // leaves reviewable partial facts, never a replayed tool call.
        let markerFD = Darwin.openat(
            rootFD, markerName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600
        )
        guard markerFD >= 0 else { throw FixtureError.invalidMarker }
        let markerBytes = Array(markerContents.utf8)
        let wrote = markerBytes.withUnsafeBytes { bytes in
            Darwin.write(markerFD, bytes.baseAddress, bytes.count)
        }
        _ = Darwin.close(markerFD)
        guard wrote == markerBytes.count else { throw FixtureError.invalidMarker }

        // The 43 read-only calls must not occupy the approval card. This
        // profile-local policy still always asks for high-risk write and edit.
        if let settingsCenter {
            settingsCenter.approvalPolicy = .riskOnlyAsk
            guard settingsCenter.approvalPolicy == .riskOnlyAsk else {
                throw FixtureError.approvalPolicyUnavailable
            }
        } else {
            // Focused tests construct BridgeStore without the App settings UI.
            bridge.updateApprovalPolicy(.riskOnlyAsk)
        }
        let chat = bridge.chat
        let turnToken = "OUTPUT_FIELD_TURN_\(UUID().uuidString)"
        guard MockProvider.shared.installOutputFieldScript(token: turnToken, provider: provider)
        else { throw FixtureError.scriptedMockAlreadyInUse }
        defer { MockProvider.shared.removeOutputFieldScript(token: turnToken) }
        chat.streamingProviderOverride = MockProvider.shared
        defer { chat.streamingProviderOverride = nil }
        chat.draftText = "\(turnToken) 合成工具与逐文件差异现场"
        chat.submitComposer()
        let deadline = ContinuousClock.now + .seconds(300)
        var sawStreaming = false
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            sawStreaming = sawStreaming || chat.isStreaming
            if sawStreaming && !chat.isStreaming { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        if chat.isStreaming { chat.stopStreaming() }
        let count = await provider.responseCount
        let ledgerCount = bridge.productionFileChangeLedger?
            .records(sessionID: sessionID.uuidString).count ?? 0
        let finalContent = try? String(contentsOf: changedFile, encoding: .utf8)
        guard sawStreaming, count >= 5,
              finalContent == "OUTPUT_FIELD edited synthetic content\n",
              ledgerCount >= 2 else {
            print(
                "OUTPUT_FIELD_PROGRESS responses=\(count) sawStreaming=\(sawStreaming) "
                    + "streaming=\(chat.isStreaming) ledger=\(ledgerCount) "
                    + "changedExists=\(finalContent != nil) "
                    + "pending=\(bridge.approvalCenter.pendingRequest?.toolName ?? "none") "
                    + "events=\(chat.conversationEventProjection.events.count)"
            )
            throw FixtureError.producerDidNotReachTerminal
        }
        print("OUTPUT_FIELD_READY session=\(sessionID.uuidString) toolRoot=\(toolRoot.path) providerResponses=\(count)")
    }
}

/// The only Provider used by this field flag. Responses are bounded native
/// tool calls; the real AgentLoop validates their catalog, approval and effects.
final class OutputFieldControlledProvider: AssistantStreamingLLMProvider, @unchecked Sendable {
    let name = "output-field-controlled"
    var model = LLMModel(id: "output-field-synthetic", displayName: "输出现场合成模型", provider: "output-field-controlled")
    let capabilities: Set<ProviderCapability> = [.streaming, .tools]
    private let script: Script

    init(readFile: URL, changedFile: URL, missingFile: URL) {
        script = Script(readFile: readFile, changedFile: changedFile, missingFile: missingFile)
    }

    var responseCount: Int { get async { await script.responseCount } }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse { try await script.next() }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
        maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse { try await script.next() }

    func streamMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        throw LLMError.unsupportedCapability(.streaming)
    }

    func streamAssistantMessage(
        messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
        maxTokens: Int, temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMAssistantStreamEvent, Error> {
        let response = try await script.next()
        return AsyncThrowingStream { continuation in
            continuation.yield(.completed(response))
            continuation.finish()
        }
    }

    private actor Script {
        let readFile: URL
        let changedFile: URL
        let missingFile: URL
        private(set) var responseCount = 0

        init(readFile: URL, changedFile: URL, missingFile: URL) {
            self.readFile = readFile
            self.changedFile = changedFile
            self.missingFile = missingFile
        }

        func next() throws -> LLMResponse {
            responseCount += 1
            switch responseCount {
            case 1:
                // 42 canonical tool events exceed the Inspector's 40-row page;
                // one missing path adds a real failed result without an effect.
                let reads = try (1...42).map { index in
                    try call("file_read", id: "output-read-\(index)",
                             ["tool_title": "读取隔离样本 \(index)", "path": readFile.path])
                }
                return LLMResponse(text: "", stopReason: "tool_calls", usage: nil,
                    toolCalls: reads + [try call("file_read", id: "output-read-missing",
                        ["tool_title": "读取不存在隔离样本", "path": missingFile.path])])
            case 2:
                return LLMResponse(text: "", stopReason: "tool_calls", usage: nil,
                    toolCalls: [try call("file_write", id: "output-write",
                        ["tool_title": "写入隔离输出文件", "path": changedFile.path,
                         "content": "OUTPUT_FIELD original synthetic content\n"])])
            case 3:
                return LLMResponse(text: "", stopReason: "tool_calls", usage: nil,
                    toolCalls: [try call("file_read", id: "output-read-before-edit",
                        ["tool_title": "复读隔离输出文件", "path": changedFile.path])])
            case 4:
                return LLMResponse(text: "", stopReason: "tool_calls", usage: nil,
                    toolCalls: [try call("file_edit", id: "output-edit",
                        ["tool_title": "编辑隔离输出文件", "path": changedFile.path,
                         "old_string": "original", "new_string": "edited"])])
            default:
                return LLMResponse(text: "输出现场合成工具回合已结束。", stopReason: "end_turn", usage: nil)
            }
        }

        private func call(_ name: String, id: String, _ input: [String: Any]) throws -> LLMToolCall {
            let raw = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
            return LLMToolCall(id: id, name: name,
                rawArguments: String(decoding: raw, as: UTF8.self), arguments: input)
        }
    }
}
