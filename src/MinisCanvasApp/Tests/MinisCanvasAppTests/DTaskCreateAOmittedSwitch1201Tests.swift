import Foundation
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

private final class TaskCreate1201HeldProvider: LLMProvider, @unchecked Sendable {
    let name = "TaskCreate1201Synthetic"
    var model = LLMModel(id: "taskcreate-1201", displayName: "Synthetic", provider: "TaskCreate1201Synthetic")
    let capabilities: Set<ProviderCapability> = [.streaming]
    private let lock = NSLock()
    private var pending: [AsyncThrowingStream<LLMStreamChunk, Error>.Continuation] = []

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        LLMResponse(text: "synthetic", stopReason: "end_turn", usage: nil)
    }

    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock { pending.append(continuation) }
        }
    }

    var hasPendingStream: Bool { lock.withLock { !pending.isEmpty } }

    func finishAll() {
        let streams = lock.withLock { () -> [AsyncThrowingStream<LLMStreamChunk, Error>.Continuation] in
            let captured = pending
            pending.removeAll()
            return captured
        }
        for stream in streams { stream.finish() }
    }
}

// Only the HTTP transport is synthetic; the actual OpenAI provider decodes
// the returned JSON before AgentLoop dispatches into the production executor.
private final class TaskCreate1201HTTPState: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [Data] = []
    private var count = 0
    func prepare(_ values: [Data]) { lock.withLock { responses = values; count = 0 } }
    func next() -> Data? { lock.withLock {
        guard !responses.isEmpty else { return nil }
        count += 1
        return responses.removeFirst()
    } }
    var requestCount: Int { lock.withLock { count } }
}

private final class TaskCreate1201URLProtocol: URLProtocol, @unchecked Sendable {
    static let state = TaskCreate1201HTTPState()
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "taskcreate1201.invalid"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let data = Self.state.next(),
              let response = HTTPURLResponse(url: url, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

// Observe real typed receipts without substituting production behavior.
@MainActor
private final class TaskCreate1201ObservedHandler: ProjectSessionProductionHandler {
    let production: ProjectSessionAppHandler
    var requests: [ProjectSessionCreateRequest] = []
    var committed: [ProjectSessionCommittedCreation] = []
    init(production: ProjectSessionAppHandler) { self.production = production }
    func listProjects(source: ProjectSessionTrustedSource) async throws -> [ProjectSessionAuthorizedProject] {
        try await production.listProjects(source: source)
    }
    func resolveProject(id: String, source: ProjectSessionTrustedSource) async throws -> ProjectSessionAuthorizedProject {
        try await production.resolveProject(id: id, source: source)
    }
    func authorizeCreate(_ request: ProjectSessionCreateRequest) async throws -> Bool {
        try await production.authorizeCreate(request)
    }
    func createSession(_ request: ProjectSessionCreateRequest) async throws -> ProjectSessionCreateOutcome {
        requests.append(request)
        let outcome = try await production.createSession(request)
        if case .committed(let value) = outcome { committed.append(value) }
        return outcome
    }
}

@Suite("D-TASKCREATEA omitted switch production handler direct assertions", .serialized)
@MainActor
struct DTaskCreateAOmittedSwitch1201Tests {
    @Test("omitted switch keeps source active and replays one committed initial task")
    func omittedSwitchCreatesOnceWithoutSwitchingSource() async throws {
        _ = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "taskcreate-1201", processEnvironment: [:],
            processArguments: ["/tmp/MinisCanvasAppTests.xctest"], canvasRuntimeState: .disabled)
        defer { try? profile.cleanupDisposableRoots() }
        let root = profile.rootDirectory
        let projectDirectory = root.appendingPathComponent("native-selected-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let sessionDirectory = profile.sessionDirectory
        let store = SessionStore(directory: sessionDirectory)
        let defaults = profile.makeUserDefaults()
        let chat = ChatStore(preferencesDefaults: defaults, logManager: profile.makeLogManager())
        #expect(chat.attachPersistence(store, badgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges"))))
        chat.restoreSpeedTier(.fast)
        let facts = ComposerPolicyFactSource(knownCapabilities: [], grantedCapabilities: [],
            allowedWriteRoots: [], workspaceID: chat.composerWorkspaceID,
            revision: "taskcreate-1201-policy", grantEpoch: "taskcreate-1201-epoch",
            leaseID: "taskcreate-1201-lease", expiresAt: .distantFuture, autonomyCeiling: .l1)
        chat.configureComposerPolicy(facts)
        chat.agentEngine = FallbackChatEngine(composerPolicyFacts: facts)
        let provider = TaskCreate1201HeldProvider()
        chat.streamingProviderOverride = provider
        defer { chat.stopAllStreamingForSafety(); provider.finishAll() }

        let sourceID = chat.applyNewSession(title: "来源")
        let parentSentinel = String(repeating: "PARENT_ONLY_1201_", count: 512)
        chat.appendUser(parentSentinel)
        let neighborID = chat.applyNewSession(title: "邻会话")
        chat.appendUser("NEIGHBOR_ONLY_1201")
        #expect(chat.applySwitchSession(id: sourceID))
        let neighborFile = sessionDirectory.appendingPathComponent("sessions/\(neighborID.uuidString).json")
        let neighborBefore = try Data(contentsOf: neighborFile)

        let capsule = "APPROVED_CAPSULE_ONLY_1201"
        #expect(chat.setPastedTextDraft(PastedTextDraft(id: UUID(), text: capsule,
            source: .pasteboard, kind: .reference)))
        chat.draftText = "从这次用户消息创建任务"
        chat.submitComposer()
        let deadline = ContinuousClock.now + .seconds(5)
        while (chat.activeExecutionIdentity(for: sourceID) == nil || !provider.hasPendingStream)
            && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let snapshot = try #require(chat.lastComposerSubmissionSnapshot)
        let active = try #require(chat.activeExecutionIdentity(for: sourceID))
        #expect(active.turn.messageID == snapshot.messageID)
        #expect(chat.isStreaming)
        #expect(provider.hasPendingStream)
        // Finish fixture setup before recording source byte invariants: the
        // production source turn has admitted its normal streaming placeholder.
        chat.touchSession(sourceID)

        let taskURL = root.appendingPathComponent("agent-tasks-1201.json")
        let taskStore = try AgentTaskStore(persistenceURL: taskURL)
        var approvalCount = 0
        let handler = try ProjectSessionAppHandler(chat: chat, sessionStore: store, taskStore: taskStore,
            workspaceBindings: ProjectSessionWorkspaceBindings(), directory: root,
            fileAccessExecutor: BuiltinToolExecutor(allowedRoot: root, deniedRoots: []),
            approval: { _, preview in
                approvalCount += 1
                #expect(preview.contains(capsule))
                #expect(!preview.contains(parentSentinel))
                return true
            })
        let projectID = try handler.authorizeFolderFromNativePicker(projectDirectory)
        let controller = TurnController()
        let handle = await controller.beginTurn()
        defer { Task { await handle.finish() } }
        let parent = try ParentRuntimeIdentitySeed(sessionID: sourceID.uuidString,
            conversationID: sourceID.uuidString, taskID: snapshot.taskID,
            actorID: "taskcreate-1201-owned").makeIdentity(using: handle)
        let context = AgentExecutionContextSnapshot(provider: provider, approvalGate: nil,
            turnController: controller, currentConversationID: sourceID.uuidString,
            makeChildBudget: nil, deadline: nil, taskStore: taskStore,
            parentTurnHandle: handle, parentRuntimeIdentity: parent)
        let observation = TaskCreate1201ObservedHandler(production: handler)
        let executor = ProjectSessionToolExecutor(handler: observation)
        let idempotencyKey = UUID().uuidString
        let sourceFile = sessionDirectory.appendingPathComponent("sessions/\(sourceID.uuidString).json")
        let sourceBefore = try Data(contentsOf: sourceFile)
        let sourceMessagesBefore = try Self.messageBytes(sourceBefore)
        let outcomes = try await AgentExecutionContext.$current.withValue(context) {
            let wireProbe = try await Self.probeWireInput(executor: executor, projectID: projectID)
            #expect(wireProbe == "success")
            try await Self.verifyWireVersionMatrix(executor: executor, projectID: projectID)
            try await Self.runActualProviderLoop(executor: executor, sourceID: sourceID.uuidString,
                taskID: snapshot.taskID, projectID: projectID, directory: root)
            // Positive production JSON admission must now succeed.
            #expect(observation.requests.isEmpty)
            let resolved = try await executor.execute(name: ProjectSessionToolContract.projectResolve,
                input: ["input_version": 1, "project_id": projectID])
            let project = try #require(JSONSerialization.jsonObject(with: Data(resolved.utf8))
                as? [String: Any])
            let reference = try #require((project["project"] as? [String: Any])?["workdir_reference"] as? String)
            let input: [String: Any] = [
                "input_version": 1, "source_session_id": sourceID.uuidString,
                "source_turn_id": parent.turnID, "project_id": projectID,
                "workdir_reference": reference, "title": "合成目标任务",
                "initial_task": "处理这份授权资料", "capsule_reference": "source-turn-reference-v1",
                "idempotency_key": idempotencyKey
            ]
            let switchFieldOmitted = input["switch_after_create"] == nil
            #expect(switchFieldOmitted)
            let encodedInput = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
            let first = try await executor.execute(name: ProjectSessionToolContract.sessionCreate,
                input: try Self.freshInput(encodedInput))
            #expect(chat.activeSessionID == sourceID)
            let committed = try #require(observation.committed.first)
            #expect(committed.creationReceipt.action.switchAfterCreate == false)
            #expect(committed.didSwitch == false)
            let targetFile = sessionDirectory.appendingPathComponent("sessions/\(committed.targetSessionID).json")
            let sourceAfterCreate = try Data(contentsOf: sourceFile)
            let targetAfterCreate = try Data(contentsOf: targetFile)
            // Claude1248: preserve every old message, add exactly one App
            // backlink, and keep full files unchanged on idempotent replay.
            if let evidencePath = ProcessInfo.processInfo.environment["TASKCREATE1201_EVIDENCE"] {
                let evidence = URL(fileURLWithPath: evidencePath, isDirectory: true)
                try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
                try sourceBefore.write(to: evidence.appendingPathComponent("source.before.json"))
                try sourceAfterCreate.write(to: evidence.appendingPathComponent("source.after-create.json"))
                try neighborBefore.write(to: evidence.appendingPathComponent("neighbor.before.json"))
                try Data(contentsOf: neighborFile).write(to: evidence.appendingPathComponent("neighbor.after-create.json"))
                try targetAfterCreate.write(to: evidence.appendingPathComponent("target.after-create.json"))
                try Data(first.utf8).write(to: evidence.appendingPathComponent("executor.first.json"))
            }
            let sourceMessagesAfter = try Self.messageBytes(sourceAfterCreate)
            #expect(Array(sourceMessagesAfter.prefix(sourceMessagesBefore.count)) == sourceMessagesBefore)
            #expect(sourceMessagesAfter.count == sourceMessagesBefore.count + 1)
            let source = try #require(chat.sessions.first { $0.id == sourceID })
            let backlinkMessages = source.messages.filter { $0.sessionReferenceCard != nil }
            #expect(backlinkMessages.count == 1)
            let backlinkMessage = try #require(backlinkMessages.first)
            let backlink = try #require(backlinkMessage.sessionReferenceCard)
            #expect(backlinkMessage.role == .assistant)
            #expect(backlinkMessage.turnTiming?.owner == .appMessage)
            #expect(backlink.id == committed.sourceBacklinkID)
            #expect(backlink.sourceSessionID == sourceID.uuidString)
            #expect(backlink.targetSessionID == committed.targetSessionID)
            #expect(backlink.taskID == committed.creationReceipt.request.taskID)
            #expect(backlink.runID == committed.runID)
            #expect(chat.hasSourceCard(backlink.id, sourceID: sourceID.uuidString))
            let sidecarFile = ChatAttachmentPersistence.sessionSidecarURL(for: sourceID, in: sessionDirectory)
            let sidecarAfterCreate = try Data(contentsOf: sidecarFile)
            if let evidencePath = ProcessInfo.processInfo.environment["TASKCREATE1201_EVIDENCE"] {
                try sidecarAfterCreate.write(to: URL(fileURLWithPath: evidencePath)
                    .appendingPathComponent("sidecar.after-create.json"))
            }
            let target = try #require(store.loadSession(id: committed.targetSessionID))
            #expect(target.messages.count == 1)
            #expect(target.messages[0].role == .user)
            #expect(target.messages[0].content == "处理这份授权资料\n\n用户已批准从本次来源消息转交的资料：\n" + capsule)
            #expect(try Data(contentsOf: neighborFile) == neighborBefore)
            let replay = try await executor.execute(name: ProjectSessionToolContract.sessionCreate,
                input: try Self.freshInput(encodedInput))
            #expect(chat.activeSessionID == sourceID)
            #expect(try Data(contentsOf: sourceFile) == sourceAfterCreate)
            #expect(try Data(contentsOf: targetFile) == targetAfterCreate)
            #expect(try Data(contentsOf: neighborFile) == neighborBefore)
            #expect(store.loadSession(id: committed.targetSessionID)?.messages.count == 1)
            #expect(chat.sessions.first { $0.id == sourceID }?.messages.compactMap(\.sessionReferenceCard).count == 1)
            #expect(try Data(contentsOf: sidecarFile) == sidecarAfterCreate)
            if let evidencePath = ProcessInfo.processInfo.environment["TASKCREATE1201_EVIDENCE"] {
                let evidence = URL(fileURLWithPath: evidencePath, isDirectory: true)
                try Data(contentsOf: sourceFile).write(to: evidence.appendingPathComponent("source.after-replay.json"))
                try Data(contentsOf: neighborFile).write(to: evidence.appendingPathComponent("neighbor.after-replay.json"))
                try Data(contentsOf: targetFile).write(to: evidence.appendingPathComponent("target.after-replay.json"))
                try Data(contentsOf: sidecarFile).write(to: evidence.appendingPathComponent("sidecar.after-replay.json"))
                try Data(replay.utf8).write(to: evidence.appendingPathComponent("executor.replay.json"))
                let assertions: [String: Any] = [
                    "scope": "production-json-input; actual-provider-AgentLoop-executor-projectResolve",
                    "wire_probe_result": wireProbe,
                    "switch_after_create_omitted": switchFieldOmitted,
                    "receipt_action_switchAfterCreate": committed.creationReceipt.action.switchAfterCreate,
                    "committed_didSwitch": committed.didSwitch,
                    "activeSessionID": chat.activeSessionID?.uuidString ?? "",
                    "sourceID": sourceID.uuidString,
                    "targetID": committed.targetSessionID,
                    "taskID": committed.creationReceipt.request.taskID,
                    "runID": committed.runID,
                    "source_old_message_count": sourceMessagesBefore.count,
                    "source_after_message_count": sourceMessagesAfter.count,
                    "source_old_message_bytes_unchanged": Array(sourceMessagesAfter.prefix(sourceMessagesBefore.count)) == sourceMessagesBefore,
                    "source_full_file_unchanged_after_create": sourceAfterCreate == sourceBefore,
                    "backlink_count": backlinkMessages.count,
                    "backlink_app_authored": backlinkMessage.turnTiming?.owner == .appMessage,
                    "backlink_targetID": backlink.targetSessionID,
                    "target_initial_task_count": target.messages.count,
                    "source_replay_bytes_unchanged": try Data(contentsOf: sourceFile) == sourceAfterCreate,
                    "target_replay_bytes_unchanged": try Data(contentsOf: targetFile) == targetAfterCreate,
                    "neighbor_bytes_unchanged": try Data(contentsOf: neighborFile) == neighborBefore,
                    "sidecar_replay_bytes_unchanged": try Data(contentsOf: sidecarFile) == sidecarAfterCreate
                ]
                try JSONSerialization.data(withJSONObject: assertions, options: [.sortedKeys, .prettyPrinted])
                    .write(to: evidence.appendingPathComponent("direct-assertions.json"))
            }
            return (first, replay)
        }
        let first = try #require(JSONSerialization.jsonObject(with: Data(outcomes.0.utf8)) as? [String: Any])
        let replay = try #require(JSONSerialization.jsonObject(with: Data(outcomes.1.utf8)) as? [String: Any])
        #expect(first["status"] as? String == "committed")
        #expect(replay["status"] as? String == "committed")
        #expect(first["did_switch"] as? Bool == false)
        #expect(replay["did_switch"] as? Bool == false)
        #expect(observation.requests.count == 2)
        #expect(observation.requests.allSatisfy { $0.switchAfterCreate == false })
        #expect(observation.committed.count == 2)
        #expect(observation.committed.allSatisfy {
            $0.creationReceipt.action.switchAfterCreate == false && $0.didSwitch == false
        })
        let targetID = try #require(first["target_session_id"] as? String)
        let taskID = try #require(first["task_id"] as? String)
        let runID = try #require(first["run_id"] as? String)
        #expect(replay["target_session_id"] as? String == targetID)
        #expect(replay["task_id"] as? String == taskID)
        #expect(replay["run_id"] as? String == runID)
        #expect(approvalCount == 1)
        #expect(taskStore.taskCenterSnapshots().filter { $0.taskID == taskID }.count == 1)

        let targetFile = sessionDirectory.appendingPathComponent("sessions/\(targetID).json")
        let targetBytes = try Data(contentsOf: targetFile)
        #expect(targetBytes.range(of: Data(parentSentinel.utf8)) == nil)
        #expect(targetBytes.range(of: Data("NEIGHBOR_ONLY_1201".utf8)) == nil)
        #expect(targetBytes.range(of: Data(capsule.utf8)) != nil)
        #expect(try Data(contentsOf: neighborFile) == neighborBefore)
        let sourceAfter = try Data(contentsOf: sourceFile)
        #expect(sourceAfter.range(of: Data(parentSentinel.utf8)) != nil)

    }
    // Actual production OpenAI admission preserves Foundation numeric values.
    // The original pre-repair failure remains in focused04/focused05 evidence.
    nonisolated private static func probeWireInput(
        executor: ProjectSessionToolExecutor, projectID: String
    ) async throws -> String {
        let rawData = try JSONSerialization.data(withJSONObject: [
            "input_version": 1, "project_id": projectID
        ], options: [.sortedKeys])
        let raw = try #require(String(data: rawData, encoding: .utf8))
        let call = try #require(ProviderToolCallBoundary.parseOpenAI([
            "id": "wire-probe-1201", "type": "function",
            "function": ["name": ProjectSessionToolContract.projectResolve, "arguments": raw]
        ]))
        let version = try #require(call.arguments["input_version"])
        let numericIsInt = version is Int
        let numericIsBool = version is Bool
        let result: String
        do {
            _ = try await executor.execute(name: call.name, input: call.arguments)
            result = "success"
        } catch ProjectSessionToolContractError.invalidInput(let key) {
            result = "invalidInput(\(key))"
        }
        if let evidencePath = ProcessInfo.processInfo.environment["TASKCREATE1201_EVIDENCE"] {
            let evidence = URL(fileURLWithPath: evidencePath, isDirectory: true)
            try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
            try rawData.write(to: evidence.appendingPathComponent("wire.input.json"))
            let observed: [String: Any] = [
                "ingress": "ProviderToolCallBoundary.parseOpenAI",
                "consumer": "ProjectSessionToolExecutor.execute",
                "input_version_is_Int": numericIsInt,
                "input_version_is_Bool": numericIsBool,
                "result": result,
                "full_provider_agent_journey_run": false
            ]
            try JSONSerialization.data(withJSONObject: observed, options: [.prettyPrinted, .sortedKeys])
                .write(to: evidence.appendingPathComponent("wire.probe.json"))
        }
        return result
    }

    nonisolated private static func verifyWireVersionMatrix(
        executor: ProjectSessionToolExecutor, projectID: String
    ) async throws {
        var observations: [[String: String]] = []
        for ingress in ["OpenAI", "Anthropic"] {
            for version in ["1", "true", "false", "1.5", "9223372036854775808", "18446744073709551616", "-18446744073709551616", "0", "2"] {
                let idJSON = try JSONSerialization.data(withJSONObject: [projectID])
                let encodedID = String(decoding: idJSON, as: UTF8.self).dropFirst().dropLast()
                let raw = "{\"input_version\":\(version),\"project_id\":\(encodedID)}"
                let call: LLMToolCall
                if ingress == "OpenAI" {
                    call = try #require(ProviderToolCallBoundary.parseOpenAI([
                        "id": "version-matrix-1201", "type": "function",
                        "function": ["name": ProjectSessionToolContract.projectResolve, "arguments": raw]
                    ]))
                } else {
                    let input = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
                    call = try #require(ProviderToolCallBoundary.parseAnthropic([
                        "id": "version-matrix-1201", "type": "tool_use",
                        "name": ProjectSessionToolContract.projectResolve, "input": input
                    ]))
                }
                let decoded = OrchestrateRequestV1.decodeInteger(call.arguments["input_version"])
                if ["1", "0", "2"].contains(version) {
                    #expect(decoded == Int(version))
                } else {
                    #expect(decoded == nil)
                }
                let result: String
                do {
                    let receipt = try await executor.execute(name: call.name, input: call.arguments)
                    #expect(receipt.contains(projectID))
                    result = "accepted"
                } catch ProjectSessionToolContractError.invalidInput(let key) {
                    #expect(key == "input_version")
                    result = "rejected"
                }
                #expect(result == (version == "1" ? "accepted" : "rejected"))
                observations.append(["ingress": ingress, "version_raw": version, "input_raw": raw, "result": result])
            }
        }
        if let path = ProcessInfo.processInfo.environment["TASKCREATE1201_EVIDENCE"] {
            try JSONSerialization.data(withJSONObject: observations, options: [.sortedKeys, .prettyPrinted])
                .write(to: URL(fileURLWithPath: path).appendingPathComponent("wire.version-matrix.json"))
        }
    }

    nonisolated private static func runActualProviderLoop(
        executor: ProjectSessionToolExecutor, sourceID: String, taskID: String, projectID: String, directory: URL
    ) async throws {
        let inputData = try JSONSerialization.data(withJSONObject: ["input_version": 1, "project_id": projectID])
        let rawArguments = String(decoding: inputData, as: UTF8.self)
        let firstData = try JSONSerialization.data(withJSONObject: ["choices": [[
            "index": 0, "finish_reason": "tool_calls", "message": [
                "role": "assistant", "content": NSNull(), "tool_calls": [[
                    "id": "provider-wire-1201", "type": "function", "function": [
                        "name": ProjectSessionToolContract.projectResolve, "arguments": rawArguments
                    ]
                ]]
            ]
        ]]])
        let finalData = try JSONSerialization.data(withJSONObject: ["choices": [[
            "index": 0, "finish_reason": "stop", "message": ["role": "assistant", "content": "wire completed"]
        ]]])
        TaskCreate1201URLProtocol.state.prepare([firstData, finalData])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TaskCreate1201URLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let provider = OpenAICompatibleProvider(apiKey: "synthetic-taskcreate1201-key",
            customBaseURL: "https://taskcreate1201.invalid", session: session)
        // Admit only this read-only catalog tool; the real handler still requires
        // the native folder grant and verified current parent runtime.
        let gate = ApprovalGate(policyByTool: [ProjectSessionToolContract.projectResolve: .autoApprove])
        let controller = TurnController()
        let nextTurnID = await controller.turnID + 1
        let identity = AgentExecutionIdentity(turn: AgentTurnIdentity(
            sessionID: sourceID, turnID: nextTurnID, messageID: UUID().uuidString),
            operationID: UUID().uuidString, attempt: 1)
        let ledgerURL = directory.appendingPathComponent("wire-tool-execution-facts.json")
        let ledger = try ToolExecutionFactLedger(persistenceURL: ledgerURL)
        let loop = AgentLoop(maxIterations: 3, approvalGate: gate,
            turnController: controller, loopDetector: nil, timeout: 5,
            toolExecutionFactLedger: ledger)
        let result = try await loop.run(messages: [LLMMessage(role: .user, content: "resolve authorized project")],
            systemPrompt: nil, provider: provider, toolExecutor: executor,
            tools: ProjectSessionToolContract.definitions, currentConversationID: sourceID,
            parentIdentitySeed: ParentRuntimeIdentitySeed(sessionID: sourceID, conversationID: sourceID,
                taskID: taskID, actorID: "wire-1201-owned"), executionIdentity: identity)
        #expect(result.toolCallsExecuted == 1)
        #expect(result.iterationCount == 2)
        #expect(result.executionIdentity == identity)
        #expect(result.toolExecutionFacts.count == 1)
        #expect(result.toolExecutionFacts.first?.status == .succeeded)
        #expect(result.toolExecutionFacts.first?.toolName == ProjectSessionToolContract.projectResolve)
        #expect(TaskCreate1201URLProtocol.state.requestCount == 2)
        let output = try #require(result.messages.first { $0.role == .tool }?.content)
        let receipt = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        #expect(receipt["ok"] as? Bool == true)
        #expect((receipt["project"] as? [String: Any])?["project_id"] as? String == projectID)
        if let path = ProcessInfo.processInfo.environment["TASKCREATE1201_EVIDENCE"] {
            let evidence = URL(fileURLWithPath: path)
            try firstData.write(to: evidence.appendingPathComponent("wire.provider-response.json"))
            try Data(contentsOf: ledgerURL).write(to: evidence.appendingPathComponent("wire.tool-ledger.json"))
            try JSONEncoder().encode(result.toolExecutionFacts)
                .write(to: evidence.appendingPathComponent("wire.terminal-facts.json"))
            try Data(output.utf8).write(to: evidence.appendingPathComponent("wire.agentloop-tool-result.json"))
            try JSONSerialization.data(withJSONObject: [
                "provider": "OpenAICompatibleProvider", "transport": "isolated URLProtocol fixture",
                "toolCallsExecuted": result.toolCallsExecuted, "iterationCount": result.iterationCount,
                "requests": TaskCreate1201URLProtocol.state.requestCount, "ok": receipt["ok"] as? Bool == true
            ], options: [.sortedKeys, .prettyPrinted]).write(to: evidence.appendingPathComponent("wire.full-chain.json"))
        }
    }

    // Each nonisolated executor call owns its fresh decoded dictionary. The
    // replay shares only immutable Sendable JSON bytes, never actor-bound Any.
    nonisolated private static func freshInput(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // The existing backlink appends one App-authored source message. Compare
    // every pre-existing canonical message's JSON bytes, then require exact
    // whole-file byte stability across the idempotent replay.
    private static func messageBytes(_ data: Data) throws -> [Data] {
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(object["messages"] as? [[String: Any]])
        return try messages.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
    }
}
