import Foundation
import Testing
@testable import MinisCore

/// Mock-only regression coverage for the user-entered DeepSeek configuration.
/// No live endpoint, credential, or Keychain is used by this suite.
@Suite("DeepSeek OpenAI-compatible regression", .serialized)
struct DeepSeekOpenAICompatibilityRegressionTests {
    private let fixtureKey = "fixture-key"
    private let bareBase = "https://api.deepseek.com"

    @Test("DeepSeek V4 Flash config resolves the official OpenAI-compatible route")
    func configurationDiscoveryAndBearerContract() throws {
        let config = ProviderConfig(
            label: "DeepSeek fixture",
            providerType: .deepSeek,
            customBaseURL: bareBase,
            appendV1Suffix: true,
            apiKey: fixtureKey
        )
        let resolved = config.resolvedBaseURL(default: DeepSeekProvider.defaultBaseURL)
        #expect(resolved.url == bareBase)
        #expect(resolved.appendV1)
        #expect(LLMModel.allDeepSeek.contains(.deepSeekV4Flash))
        #expect(DeepSeekProvider.normalizedOpenAICompatibleBaseURL("  \(bareBase)/v1///  ") == bareBase)

        let adapter = ProviderReadinessWireAdapterFactory.make(for: .openaiCompatible)
        let bareBaseURL = try #require(URL(string: bareBase))
        let catalogRequest = try adapter.makeRequest(
            operation: .modelCatalog,
            baseURL: bareBaseURL,
            modelID: nil,
            apiKey: fixtureKey
        )
        #expect(catalogRequest.httpMethod == "GET")
        #expect(catalogRequest.url?.absoluteString == "\(bareBase)/models")
        #expect(catalogRequest.value(forHTTPHeaderField: "Authorization") == "Bearer \(fixtureKey)")

        let catalog = try JSONSerialization.data(withJSONObject: [
            "data": [
                ["id": "deepseek-v4-flash", "type": "model"],
                // Discovery must preserve provider-side model IDs that this
                // build does not know yet; they are wire identifiers, not an
                // enum allowlist.
                ["id": "deepseek-v4-flash-preview", "type": "model"]
            ]
        ])
        #expect(try adapter.decodeModelCatalog(from: catalog).map(\.id) == [
            "deepseek-v4-flash", "deepseek-v4-flash-preview"
        ])

        let generationRequest = try adapter.makeRequest(
            operation: .modelRequest(modelID: "deepseek-v4-flash"),
            baseURL: bareBaseURL,
            modelID: "deepseek-v4-flash",
            apiKey: fixtureKey
        )
        #expect(generationRequest.httpMethod == "POST")
        #expect(generationRequest.url?.absoluteString == "\(bareBase)/chat/completions")
        #expect(generationRequest.value(forHTTPHeaderField: "Authorization") == "Bearer \(fixtureKey)")
        let body = try #require(generationRequest.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["model"] as? String == "deepseek-v4-flash")

        let unknownModelRequest = try adapter.makeRequest(
            operation: .modelRequest(modelID: "deepseek-v4-flash-preview"),
            baseURL: bareBaseURL,
            modelID: "deepseek-v4-flash-preview",
            apiKey: fixtureKey
        )
        let unknownBody = try #require(unknownModelRequest.httpBody)
        let unknownObject = try #require(JSONSerialization.jsonObject(with: unknownBody) as? [String: Any])
        #expect(unknownObject["model"] as? String == "deepseek-v4-flash-preview")

        let existingV1Request = try adapter.makeRequest(
            operation: .modelCatalog,
            baseURL: try #require(URL(string: "\(bareBase)/v1")),
            modelID: nil,
            apiKey: fixtureKey
        )
        #expect(existingV1Request.url?.path == "/v1/models")

        let customPathRequest = try adapter.makeRequest(
            operation: .modelCatalog,
            baseURL: try #require(URL(string: "https://proxy.example/api")),
            modelID: nil,
            apiKey: fixtureKey
        )
        // 与对话请求同一规则：路径里没有版本段才补 /v1（对话一直是 /api/v1/chat/completions）。
        #expect(customPathRequest.url?.path == "/api/v1/models")
    }

    @Test("V4 Flash generation uses the same route and maps HTTP failures without leaking credentials")
    func generationAndFailureClassificationUseMockTransport() async throws {
        DeepSeekCompatibilityMockURLProtocol.reset { request in
            if request.url?.path == "/chat/completions" {
                return .response(
                    status: 200,
                    body: Data("{\"model\":\"deepseek-v4-flash-preview\",\"choices\":[{\"message\":{\"content\":\"fixture-ok\"}}]}".utf8)
                )
            }
            return .response(status: 404, body: Data("{}".utf8))
        }
        defer { DeepSeekCompatibilityMockURLProtocol.reset(nil) }

        let provider = OpenAICompatibleProvider(
            apiKey: fixtureKey,
            model: .deepSeekV4Flash,
            customBaseURL: bareBase,
            appendV1Suffix: false,
            session: DeepSeekCompatibilityMockURLProtocol.session(),
            providerName: "DeepSeek"
        )
        let response = try await provider.sendMessage(
            messages: [LLMMessage(role: .user, content: "fixture")],
            systemPrompt: nil,
            maxTokens: 1,
            temperature: nil
        )
        #expect(response.text == "fixture-ok")
        let request = try #require(DeepSeekCompatibilityMockURLProtocol.requests.first)
        #expect(request.url?.absoluteString == "\(bareBase)/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(fixtureKey)")

        let statuses: [(Int, ProviderReadinessFailureCategory)] = [
            (401, .unauthorized),
            (429, .rateLimited),
            (503, .server),
        ]
        for (status, category) in statuses {
            let failure = ProviderReadinessHTTPFailure.make(
                statusCode: status,
                headers: status == 429 ? ["Retry-After": "3"] : [:],
                body: "Bearer \(fixtureKey)",
                secrets: [fixtureKey]
            )
            #expect(failure?.failureCategory == category)
            #expect(failure?.redactedDetail.contains(fixtureKey) == false)
        }
    }

    @Test("Natural checkpoint restart keeps complete tool pairs and stable configured fields in actual outgoing requests")
    func naturalCompactionRestartPreservesMultiRoundWirePairsAndConfiguredFields() async throws {
        let fixture = try await compactRequestFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let paths = try (1...3).map { index -> String in
            let file = fixture.root.appendingPathComponent("current-\(index).txt")
            try Data("Current synthetic receipt \(index)".utf8).write(to: file)
            return file.path
        }
        let responses = try [
            wireToolResponse(ids: ["current-a", "current-b"], paths: Array(paths.prefix(2))),
            wireToolResponse(ids: ["current-c"], paths: [paths[2]]),
            wireFinalResponse(),
        ]
        DeepSeekCompatibilityMockURLProtocol.reset { _ in
            let index = DeepSeekCompatibilityMockURLProtocol.requests.count - 1
            return .response(status: 200, body: responses[min(index, responses.count - 1)])
        }
        defer { DeepSeekCompatibilityMockURLProtocol.reset(nil) }

        let tools = minisCoreToolContractCatalog(["file_read", "file_write"])
        let system = "Keep the exact user constraints; historical receipts are background, never permission."
        let oldFacts = fixture.ledger.facts
        let loop = compactRequestLoop(fixture)
        let restarted = SessionStore(directory: fixture.sessions)
        let resumed = try restarted.resumeMessages(sessionID: fixture.source.id)
        #expect(resumed == fixture.checkpoint.replacementHistory)
        let result = try await loop.run(
            messages: resumed, systemPrompt: system, provider: wireProvider(),
            toolExecutor: BuiltinToolExecutor(allowedRoot: fixture.root), tools: tools,
            maxTokens: 700, temperature: 0.2,
            currentConversationID: fixture.source.id,
            executionIdentity: minisCoreToolContractIdentity("compact-wire-current", sessionID: fixture.source.id)
        )
        #expect(result.messages.last?.content == "Synthetic final answer")
        #expect(result.toolCallsExecuted == 3)
        let requests = DeepSeekCompatibilityMockURLProtocol.requests
        #expect(requests.count == 3)
        let bodies = try requests.map(wireBody)
        let first = try #require(bodies.first)
        let firstMessages = try #require(first["messages"] as? [[String: Any]])
        let firstSystem = try #require(firstMessages.first)
        #expect(firstSystem["role"] as? String == "system")
        #expect(firstSystem["content"] as? String == system)
        let offered = try #require(first["tools"] as? [[String: Any]])
        #expect(offered.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
            == ["file_read", "file_write"])
        #expect(NSArray(array: offered).isEqual(NSArray(array: tools.map(\.openAIFunctionDict))))
        let readFunction = try #require(offered.first?["function"] as? [String: Any])
        let parameters = try #require(readFunction["parameters"] as? [String: Any])
        #expect(parameters["required"] as? [String] == ["tool_title", "path"])
        #expect((parameters["properties"] as? [String: Any])?["path"] != nil)

        let expectedIDs = [
            ["historical-a", "historical-b"],
            ["historical-a", "historical-b", "current-a", "current-b"],
            ["historical-a", "historical-b", "current-a", "current-b", "current-c"],
        ]
        for (index, body) in bodies.enumerated() {
            // Compare fields parsed directly from the production HTTP body.
            // Do not re-encode/sort the history or claim a provider cache hit.
            let messages = try #require(body["messages"] as? [[String: Any]])
            let actualSystem = try #require(messages.first)
            #expect(NSDictionary(dictionary: actualSystem).isEqual(NSDictionary(dictionary: firstSystem)))
            #expect((body["tools"] as? NSArray)?.isEqual(NSArray(array: offered)) == true)
            #expect(body["model"] as? String == LLMModel.deepSeekV4Flash.id)
            // F-J08-a: api.deepseek.com only honours max_tokens.
            #expect(body["max_tokens"] as? Int == 700)
            #expect(body["max_completion_tokens"] == nil)
            #expect(body["temperature"] as? Double == 0.2)
            #expect(body["stream"] as? Bool == false)
            try expectSettledWirePairs(messages, expectedIDs: expectedIDs[index])
            let projectedPrefix = messages.dropFirst().prefix(resumed.count)
            #expect(NSArray(array: Array(projectedPrefix)).isEqual(NSArray(array:
                resumed.map { OpenAICompatibleProvider.openAIMessageDict($0,
                    mediaCapabilities: LLMModel.deepSeekV4Flash.capabilities) })))
        }
        #expect(fixture.ledger.facts.count == oldFacts.count + 3)
        #expect(Array(fixture.ledger.facts.prefix(oldFacts.count)) == oldFacts)
        #expect(Set(fixture.ledger.facts.dropFirst(oldFacts.count).map(\.toolCallID))
            == Set(["current-a", "current-b", "current-c"]))
        #expect(fixture.ledger.facts.dropFirst(oldFacts.count).allSatisfy { $0.status == .succeeded })
        for fact in fixture.ledger.facts.dropFirst(oldFacts.count) {
            #expect(fact.status == .succeeded, "Current call \(fact.toolCallID) status \(fact.status)")
        }
        #expect(restarted.loadSession(id: fixture.source.id)?.messages == fixture.source.messages)
        #expect(try restarted.loadLatestCompactionCheckpoint(sessionID: fixture.source.id) == fixture.checkpoint)
    }

    @Test("A new legitimate turn can change prompt and tool schema/order after natural compaction")
    func compactedRequestReflectsLegitimatePromptAndToolChanges() async throws {
        let fixture = try await compactRequestFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let response = try wireFinalResponse()
        DeepSeekCompatibilityMockURLProtocol.reset { _ in .response(status: 200, body: response) }
        defer { DeepSeekCompatibilityMockURLProtocol.reset(nil) }
        let original = minisCoreToolContractCatalog(["file_read", "file_write"])
        let changedRead = AgentToolDefinition(
            name: "file_read", description: "Current user-selected read contract",
            parameters: ["path": AgentToolParam(type: .string, description: "Current synthetic path")],
            required: ["path"]
        )
        let changed = [try #require(original.last), changedRead]
        let reader = SessionStore(directory: fixture.sessions)
        let messages = try reader.resumeMessages(sessionID: fixture.source.id)
        let oldFacts = fixture.ledger.facts
        for (index, tools) in [original, changed].enumerated() {
            let loop = compactRequestLoop(fixture)
            _ = try await loop.run(
                messages: messages, systemPrompt: "Explicit configuration \(index)",
                provider: wireProvider(), toolExecutor: BuiltinToolExecutor(allowedRoot: fixture.root),
                tools: tools, currentConversationID: fixture.source.id,
                executionIdentity: minisCoreToolContractIdentity("compact-config-\(index)", sessionID: fixture.source.id)
            )
        }
        let bodies = try DeepSeekCompatibilityMockURLProtocol.requests.map(wireBody)
        #expect(bodies.count == 2)
        for (index, body) in bodies.enumerated() {
            let sent = try #require(body["messages"] as? [[String: Any]])
            #expect(sent.first?["content"] as? String == "Explicit configuration \(index)")
            try expectSettledWirePairs(sent, expectedIDs: ["historical-a", "historical-b"])
            #expect((body["tools"] as? NSArray)?.isEqual(NSArray(array:
                [original, changed][index].map(\.openAIFunctionDict))) == true)
        }
        let changedBody = try #require(bodies.last)
        let changedTools = try #require(changedBody["tools"] as? [[String: Any]])
        #expect(changedTools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
            == ["file_write", "file_read"])
        let function = try #require(changedTools.last?["function"] as? [String: Any])
        #expect(function["description"] as? String == changedRead.description)
        let parameters = try #require(function["parameters"] as? [String: Any])
        #expect(parameters["required"] as? [String] == ["path"])
        #expect((parameters["properties"] as? [String: Any])?["tool_title"] == nil)
        #expect(fixture.ledger.facts == oldFacts)
        #expect(reader.loadSession(id: fixture.source.id)?.messages == fixture.source.messages)
    }

    @Test("Recomputed checkpoint digests cannot send orphan, duplicate, missing, reordered or late tool results",
          arguments: ["orphan", "duplicate", "missing", "result-before-call", "late"])
    func forgedCompactedToolPairsNeverReachOutgoingRequest(_ mutation: String) async throws {
        let fixture = try await compactRequestFixture(commitCheckpoint: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let checkpoint = fixture.checkpoint
        var history = checkpoint.replacementHistory
        let callIndex = try #require(history.firstIndex { !$0.toolCalls.isEmpty })
        let firstResult = try #require(history.firstIndex { $0.toolCallID == "historical-a" })
        let secondResult = try #require(history.firstIndex { $0.toolCallID == "historical-b" })
        switch mutation {
        case "orphan":
            history[firstResult] = .init(role: .tool, content: "orphan receipt", toolCallID: "no-call")
        case "duplicate":
            history[secondResult] = history[firstResult]
        case "missing":
            history[secondResult] = .init(role: .assistant, content: "Receipt removed from the projection")
        case "result-before-call":
            history.swapAt(callIndex, firstResult)
        case "late":
            history.insert(.init(role: .tool, content: "Unknown late result", toolCallID: "late-call"),
                at: history.count - 1)
        default:
            Issue.record("Unexpected fixture mutation \(mutation)")
        }
        let forged = CompactionCheckpoint(
            schemaVersion: checkpoint.schemaVersion, checkpointID: checkpoint.checkpointID,
            sessionID: checkpoint.sessionID, sourceTranscriptRevision: checkpoint.sourceTranscriptRevision,
            resultTranscriptRevision: checkpoint.resultTranscriptRevision,
            compactedThroughMessageID: checkpoint.compactedThroughMessageID,
            compactedMessageRange: checkpoint.compactedMessageRange,
            summaryMessage: checkpoint.summaryMessage, replacementHistory: history,
            lineage: checkpoint.lineage, sourcePrefixDigest: checkpoint.sourcePrefixDigest,
            projectionSpans: checkpoint.projectionSpans, projectionRecentCount: checkpoint.projectionRecentCount,
            retentionFacts: checkpoint.retentionFacts, contentDigest: "", createdAt: checkpoint.createdAt
        ).withDigest()
        #expect(forged.hasValidDigest)
        let writer = SessionStore(directory: fixture.sessions)
        #expect(throws: SessionStoreError.invalidCompactionCheckpoint(checkpoint.checkpointID)) {
            try writer.saveCompactionCheckpoint(forged)
        }
        #expect(try writer.loadLatestCompactionCheckpoint(sessionID: fixture.source.id) == nil)
        #expect(writer.loadSession(id: fixture.source.id) == fixture.source)
        try writer.saveCompactionCheckpoint(checkpoint)
        #expect(try writer.loadLatestCompactionCheckpoint(sessionID: fixture.source.id) == checkpoint)
        let payload = writer.compactionCheckpointsDirectory.appendingPathComponent(checkpoint.checkpointID + ".json")
        // The writer above rejected the source-invalid candidate. On restart,
        // a sidecar changed after commit must also fail its independent durable
        // chain/manifest binding; a self-recomputed digest is not authority.
        try JSONEncoder().encode(forged).write(to: payload, options: .atomic)
        let response = try wireFinalResponse()
        DeepSeekCompatibilityMockURLProtocol.reset { _ in .response(status: 200, body: response) }
        defer { DeepSeekCompatibilityMockURLProtocol.reset(nil) }
        let reader = SessionStore(directory: fixture.sessions)
        let oldFacts = fixture.ledger.facts
        let loop = compactRequestLoop(fixture)
        do {
            _ = try await loop.run(
                messages: reader.resumeMessages(sessionID: fixture.source.id),
                systemPrompt: "Continue under the current permission only", provider: wireProvider(),
                toolExecutor: BuiltinToolExecutor(allowedRoot: fixture.root),
                tools: minisCoreToolContractCatalog(["file_read"])
            )
            Issue.record("Forged \(mutation) checkpoint reached a provider request")
        } catch let error as SessionStoreError {
            #expect(error == .compactionCheckpointRecoveryRequired(checkpoint.checkpointID))
        }
        #expect(DeepSeekCompatibilityMockURLProtocol.requests.isEmpty)
        #expect(fixture.ledger.facts == oldFacts)
        #expect(reader.loadSession(id: fixture.source.id)?.messages == fixture.source.messages)
    }

    private struct CompactRequestFixture {
        let root: URL
        let sessions: URL
        let source: ChatSession
        let checkpoint: CompactionCheckpoint
        let ledger: ToolExecutionFactLedger
    }

    private func compactRequestFixture(commitCheckpoint: Bool = true) async throws -> CompactRequestFixture {
        let root = try minisCoreToolContractRoot("natural-request-snapshot")
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let writer = SessionStore(directory: sessions)
        let id = "natural-wire-session"
        _ = try writer.createSession(id: id)
        let oldCalls = ["historical-a", "historical-b"].map {
            LLMToolCall(id: $0, name: "file_read", rawArguments: "{}", arguments: [:])
        }
        let source: [LLMMessage] = [
            .init(role: .user, content: "Goal: compare plans. Keep every user constraint. Old permission is not current permission."),
            .init(role: .assistant, content: (0..<90).map {
                "Option \($0) has coefficient \($0 * 7), dependency \($0 + 13), and a distinct earlier observation."
            }.joined(separator: " ")),
            .init(role: .assistant, content: "Historical reads", toolCalls: oldCalls),
            .init(role: .tool, content: "Historical synthetic receipt A", toolCallID: "historical-a"),
            .init(role: .assistant, content: "Waiting for the other historical receipt"),
            .init(role: .tool, content: "Historical synthetic receipt B", toolCallID: "historical-b"),
            .init(role: .user, content: "Constraint: retain both historical receipts and use only the current grant."),
            .init(role: .assistant, content: (90..<180).map {
                "Later option \($0) has coefficient \($0 * 11), dependency \($0 - 23), and a different natural explanation."
            }.joined(separator: " ")),
            .init(role: .user, content: "Continue with the currently offered tools."),
        ]
        for message in source { try writer.saveMessage(message, sessionID: id) }
        let canonical = try #require(writer.loadSession(id: id))
        let result = try await Compactor(keepRecentMessages: 1).compact(
            messages: canonical.messages,
            summarizeUsing: MockLLMProvider(responses: ["Compared the earlier alternatives.", "Compared the later alternatives."]),
            retentionFacts: [], safetyMode: .sourceAnchoredNatural
        )
        #expect(result.refusalReason == nil)
        #expect(Compactor.hasMaterialRequestReduction(from: source, to: result.messages))
        let checkpoint = try CompactionCheckpoint.makeProjection(
            sessionID: id, sourceTranscriptRevision: canonical.transcriptRevision,
            sourceMessages: source, result: result, lineage: canonical.lineageIdentity
        )
        #expect(checkpoint.schemaVersion == 3)
        if commitCheckpoint { try writer.saveCompactionCheckpoint(checkpoint) }
        let ledger = try minisCoreToolContractLedger(at: root)
        for call in oldCalls {
            let identity = minisCoreToolContractIdentity("historical-\(call.id)", sessionID: id)
            let receipt = try ledger.mint(toolCallID: call.id, toolName: call.name,
                attemptID: "historical-attempt-\(call.id)", attemptNumber: 1, executionIdentity: identity)
            _ = try ledger.settle(receipt, status: .succeeded)
        }
        return .init(root: root, sessions: sessions, source: canonical, checkpoint: checkpoint, ledger: ledger)
    }

    private func compactRequestLoop(_ fixture: CompactRequestFixture) -> AgentLoop {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let goal = GoalEnvelope(scopeID: "compact-request-test",
            allowedCapabilities: ["file_read", "file_write"], fileRoots: [fixture.root.path],
            budget: 100, deadline: now.addingTimeInterval(3_600), concurrencyLimit: 1,
            autonomyLevel: .l2, creatorID: "DeepSeekOpenAICompatibilityRegressionTests", createdAt: now)
        let lease = AutonomyLease(goalID: goal.goalID, scopeID: goal.scopeID,
            issuedAt: now, expiresAt: goal.deadline)
        let runtime = PolicyRuntimeBinding(goal: goal, lease: lease, clock: { now })
        var loop = SecureAgentLoopFactory.make(maxIterations: 5,
            approvalGate: ApprovalGate(delegate: CompactRequestApprovalDelegate()),
            policyRuntime: runtime, turnController: TurnController())
        loop.toolExecutionFactLedger = fixture.ledger
        return loop
    }

    private struct CompactRequestApprovalDelegate: ApprovalDelegate {
        func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
            ApprovalDecision(approved: true, confirmed: true, requestID: request.requestID,
                bindingDigest: request.identityDigest)
        }
    }

    private func wireProvider() -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(apiKey: fixtureKey, model: .deepSeekV4Flash,
            customBaseURL: bareBase, appendV1Suffix: false,
            session: DeepSeekCompatibilityMockURLProtocol.session(), providerName: "DeepSeek")
    }

    private func wireBody(_ request: URLRequest) throws -> [String: Any] {
        #expect(request.url?.absoluteString == "\(bareBase)/chat/completions")
        let data: Data
        if let body = request.httpBody {
            data = body
        } else {
            // Foundation may expose the very same encoded bytes as a stream.
            let stream = try #require(request.httpBodyStream)
            stream.open()
            defer { stream.close() }
            var bytes = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                #expect(count >= 0)
                if count <= 0 { break }
                bytes.append(buffer, count: count)
            }
            data = bytes
        }
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func wireToolResponse(ids: [String], paths: [String]) throws -> Data {
        let calls = try zip(ids, paths).map { id, path -> [String: Any] in
            let arguments = try JSONSerialization.data(withJSONObject: [
                "path": path, "tool_title": "Read current synthetic fixture"
            ])
            return ["id": id, "type": "function", "function": [
                "name": "file_read", "arguments": String(decoding: arguments, as: UTF8.self)
            ]]
        }
        return try JSONSerialization.data(withJSONObject: ["choices": [["message": [
            "role": "assistant", "content": "Read current files", "tool_calls": calls
        ], "finish_reason": "tool_calls"]]])
    }

    private func wireFinalResponse() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["choices": [["message": [
            "role": "assistant", "content": "Synthetic final answer"
        ], "finish_reason": "stop"]]])
    }

    private func expectSettledWirePairs(_ messages: [[String: Any]], expectedIDs: [String]) throws {
        var calls: [String] = []
        var results: [String] = []
        for message in messages {
            for call in message["tool_calls"] as? [[String: Any]] ?? [] {
                #expect(message["role"] as? String == "assistant")
                let id = try #require(call["id"] as? String)
                #expect(!calls.contains(id))
                #expect(!results.contains(id))
                calls.append(id)
            }
            if message["role"] as? String == "tool" {
                let id = try #require(message["tool_call_id"] as? String)
                #expect(calls.contains(id))
                #expect(!results.contains(id))
                results.append(id)
            }
        }
        #expect(calls == expectedIDs)
        #expect(results == expectedIDs)
    }
}

private final class DeepSeekCompatibilityMockURLProtocol: URLProtocol, @unchecked Sendable {
    enum MockResponse {
        case response(status: Int, body: Data)
    }

    nonisolated(unsafe) private static var handler: ((URLRequest) -> MockResponse)?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    static func reset(_ handler: ((URLRequest) -> MockResponse)?) {
        self.handler = handler
        requests = []
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Self.self]
        return URLSession(configuration: configuration)
    }

    override func startLoading() {
        Self.requests.append(request)
        guard let response = Self.handler?(request),
              let url = request.url,
              case .response(let status, let body) = response,
              let httpResponse = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
