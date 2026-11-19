import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

// Only the remote HTTP service is replaced. SDK, frozen route, secure factory,
// ChatStore terminal fence and SessionStore are the production consumers.
private final class Provider604Wire: URLProtocol, @unchecked Sendable {
    enum Reply: Sendable { case status(Int), timeout, cancelled, success, held }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]
    nonisolated(unsafe) private static var requests: [String: Int] = [:]
    nonisolated(unsafe) private static var stops: [String: Int] = [:]

    static func configure(primary: Reply, backup: Reply = .success) {
        lock.lock(); defer { lock.unlock() }
        replies = ["primary": primary, "backup": backup]
        requests = [:]; stops = [:]
    }
    static func count(_ provider: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return requests[provider, default: 0]
    }
    static func stopCount(_ provider: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return stops[provider, default: 0]
    }
    private static func next(_ provider: String) -> Reply {
        lock.lock(); defer { lock.unlock() }
        requests[provider, default: 0] += 1
        return replies[provider] ?? .status(599)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let provider = url.pathComponents.contains("backup") ? "backup" : "primary"
        switch Self.next(provider) {
        case .timeout:
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
        case .cancelled:
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
        case .status(let code):
            let response = HTTPURLResponse(url: url, statusCode: code,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{\"error\":\"wire-private604\"}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .success, .held:
            let held: Bool
            if case .held = Self.reply(for: provider) { held = true } else { held = false }
            let response = HTTPURLResponse(url: url, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let text = held ? "partial604 " : "completed604"
            let delta = "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"\(text)\"},\"finish_reason\":null}]}\n\n"
            client?.urlProtocol(self, didLoad: Data(delta.utf8))
            if !held {
                client?.urlProtocol(self, didLoad: Data("data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n".utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }
    private static func reply(for provider: String) -> Reply? {
        lock.lock(); defer { lock.unlock() }
        return replies[provider]
    }
    override func stopLoading() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let provider = request.url?.pathComponents.contains("backup") == true ? "backup" : "primary"
        Self.stops[provider, default: 0] += 1
    }
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Self.self]
        return URLSession(configuration: configuration)
    }
}

private final class Provider604NoTools: ToolExecutor, @unchecked Sendable {
    func execute(name: String, input: [String: Any]) async throws -> String {
        Issue.record("HTTP-only fixture must never dispatch a tool")
        throw LLMError.providerError(message: "unexpected synthetic tool")
    }
}

@MainActor
private final class Provider604Observation {
    var values: [ProviderRuntimeRouteObservation] = []
}

@Suite("D-PROVIDER-11/13 actual SDK conversation persistence", .serialized)
@MainActor
struct ProviderSDKConversation604Tests {
    private struct Fixture {
        let root: URL
        let suite: String
        let chat: ChatStore
        let store: SessionStore
        let observations: Provider604Observation
        let sessions: [URLSession]
        let prior: [(id: UUID, role: String, content: String)]
    }

    private func fixture(fallback: Bool = false, configured: Bool = true) throws -> Fixture {
        let suite = "ProviderSDK604-\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let defaults = try #require(UserDefaults(suiteName: suite))
        let chat = ChatStore(preferencesDefaults: defaults,
            logManager: LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 30))
        let store = SessionStore(directory: root.appendingPathComponent("sessions"))
        #expect(chat.attachPersistence(store))
        let facts = ComposerPolicyFactSource(knownCapabilities: ["shell_execute"],
            grantedCapabilities: ["shell_execute"], allowedWriteRoots: [root.path],
            workspaceID: chat.composerWorkspaceID, revision: "sdk604-policy",
            grantEpoch: "sdk604-epoch", leaseID: "sdk604-lease",
            expiresAt: .distantFuture, autonomyCeiling: .l3)
        chat.configureComposerPolicy(facts)
        chat.composerPolicySelection = ComposerPolicySelection(mode: .auto,
            approvalScope: .request, effort: .standard, bypassModeConfirmed: false)
        let primarySession = Provider604Wire.session()
        let backupSession = Provider604Wire.session()
        func sdk(_ name: String, session: URLSession) -> OpenAICompatibleProvider {
            OpenAICompatibleProvider(apiKey: "fixed-synthetic604",
                model: LLMModel(id: "\(name)-model", displayName: name, provider: name),
                customBaseURL: "https://fixture.invalid/\(name)", appendV1Suffix: false,
                session: session, providerName: name)
        }
        let primary = sdk("primary", session: primarySession)
        let backup = sdk("backup", session: backupSession)
        let observations = Provider604Observation()
        let injector = SkillInjector(store: SkillStore(skillsRoot: root.appendingPathComponent("skills")))
        chat.turnRuntimeSnapshotFactory = { [weak chat] turn, box in
            // Missing readiness enters through the real constructor failure,
            // following BridgeStore's existing error-snapshot handoff.
            do {
                let snapshot = try ProviderRuntimeSnapshot(providerID: box.name, modelID: box.model.id,
                    readinessEvidenceID: configured ? "live-settings:" + String(repeating: "a", count: 64) : nil,
                    applyReceiptID: configured ? "provider-readiness-apply:sdk604" : nil,
                    fallbackProvenance: fallback ? [ProviderRuntimeFallback(providerID: backup.name,
                        modelID: backup.model.id, readinessEvidenceID: "sdk604-backup-readiness",
                        applyReceiptID: "provider-readiness-apply:sdk604-backup")] : [])
                let route = try ProviderRuntimeRoute(snapshot: snapshot, primary: box,
                    fallbacks: fallback ? [backup] : [], observationSink: { observation in
                        await MainActor.run {
                            observations.values.append(observation)
                            guard let chat, let session = UUID(uuidString: turn.sessionID),
                                  let identity = chat.activeExecutionIdentity(for: session) else { return }
                            _ = chat.ingestProviderRuntimeObservation(observation, executionIdentity: identity)
                        }
                    })
                return ChatTurnRuntimeSnapshot(turn: turn, skillInjector: injector.snapshotForTurn(),
                    mcpBridge: nil, providerRuntimeRoute: route, requiresProviderRuntimeRoute: true)
            } catch let error as ProviderRuntimeSnapshotError {
                return ChatTurnRuntimeSnapshot(turn: turn, skillInjector: injector.snapshotForTurn(),
                    mcpBridge: nil, providerRuntimeRouteError: error, requiresProviderRuntimeRoute: true)
            } catch {
                preconditionFailure("unexpected synthetic route construction failure")
            }
        }
        let now = Date()
        let goal = GoalEnvelope(scopeID: "sdk604-synthetic", allowedCapabilities: ["shell_execute"],
            fileRoots: [root.path], budget: 100, deadline: now.addingTimeInterval(3600),
            concurrencyLimit: 1, autonomyLevel: .l3, creatorID: "ProviderSDKConversation604Tests", createdAt: now)
        let lease = AutonomyLease(goalID: goal.goalID, scopeID: goal.scopeID, issuedAt: now, expiresAt: goal.deadline)
        chat.agentEngine = AgentLoopChatEngine(toolExecutor: PolicyRuntimeBinding(goal: goal, lease: lease).wrap(Provider604NoTools()),
            requestBudget: chat.budgetTracker,
            approvalGate: ApprovalGate(policyByTool: ["shell_execute": .autoApprove]),
            toolExecutionFactLedger: try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts-v4.json")),
            composerPolicyFacts: facts)
        chat.streamingProviderOverride = primary
        return Fixture(root: root, suite: suite, chat: chat, store: store,
            observations: observations, sessions: [primarySession, backupSession],
            prior: chat.messages.map { ($0.id, $0.role.rawValue, $0.content) })
    }

    private func submit(_ f: Fixture) throws -> (UUID, AgentExecutionIdentity) {
        let session = try #require(f.chat.activeSessionID)
        f.chat.draftText = "owned synthetic604 request"
        f.chat.submitComposer()
        return (session, try #require(f.chat.activeExecutionIdentity(for: session)))
    }

    private func settle(_ f: Fixture) async throws {
        for _ in 0..<1000 where f.chat.isStreaming { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!f.chat.isStreaming, "actual production turn must settle")
    }

    private func verifyPersistence(_ f: Fixture, session: UUID) throws -> String {
        let priorIDs = Set(f.prior.map(\.id))
        let added = f.chat.messages.filter { !priorIDs.contains($0.id) && $0.role != .system }
        #expect(added.map { $0.role.rawValue } == ["user", "assistant"])
        for prior in f.prior {
            #expect(f.chat.messages.first(where: { $0.id == prior.id })?.content == prior.content)
        }
        let content = try #require(added.last).content
        #expect(!content.contains("wire-private604"))
        #expect(!content.contains("fixed-synthetic604"))
        let persisted = try #require(f.store.loadSession(id: session.uuidString))
        let visible = f.chat.messages.filter { $0.role != .system }
        #expect(persisted.messages.map { $0.role.rawValue } == visible.map { $0.role.rawValue })
        #expect(persisted.messages.map(\.content) == visible.map(\.content))
        let defaults: UserDefaults = try #require(UserDefaults(suiteName: f.suite))
        let reopened = ChatStore(preferencesDefaults: defaults,
            logManager: LogManager(directory: f.root.appendingPathComponent("reopened-logs")))
        #expect(reopened.attachPersistence(SessionStore(directory: f.root.appendingPathComponent("sessions"))))
        let restored = reopened.messages.filter { $0.role != .system }
        #expect(restored.map { $0.role.rawValue } == visible.map { $0.role.rawValue })
        #expect(restored.map(\.content) == visible.map(\.content))
        return content
    }

    private func finish(_ f: Fixture) {
        f.chat.stopAllStreamingForSafety()
        for session in f.sessions { session.invalidateAndCancel() }
        // Retain fixture-owned files for readback; no real preferences/data.
        print("PROVIDER604_OWN_ROOT " + f.root.path)
    }

    @Test func unconfiguredConstructorFailureMakesNoSDKRequest() async throws {
        Provider604Wire.configure(primary: .success)
        let f = try fixture(configured: false); defer { finish(f) }
        let (session, identity) = try submit(f)
        try await settle(f)
        #expect(Provider604Wire.count("primary") == 0 && Provider604Wire.count("backup") == 0)
        let content = try verifyPersistence(f, session: session)
        #expect(content.contains("未配置"))
        #expect(f.chat.terminalReceipt(for: identity)?.outcome == .failed)
    }

    @Test(arguments: [401, 403, 404, 429, 500, 503])
    func httpFailureTravelsThroughSDKRouteAndPersistentPublicConsumer(code: Int) async throws {
        Provider604Wire.configure(primary: .status(code))
        let f = try fixture(); defer { finish(f) }
        let (session, identity) = try submit(f)
        try await settle(f)
        let content = try verifyPersistence(f, session: session)
        let expected: ProviderRequestFailureKind = switch code {
        case 401: .unauthorized
        case 403: .permissionDenied
        case 404: .notFound
        case 429: .rateLimited
        default: .server
        }
        let attempt = try #require(f.observations.values.last?.attempts.first(where: { !$0.succeeded }))
        #expect(attempt.failureKind == expected && attempt.statusCode == code)
        if code >= 500 {
            #expect(content.contains(String(code)))
            #expect(content.contains(HTTPStatusMessages.message(for: code).zh))
            // Explicit approved Chinese copy complements the existing shared-message check.
            #expect(content.contains(code == 500 ? "服务端内部错误" : "服务暂时不可用"))
        } else {
            #expect(content.contains("HTTP \(code)"))
        }
        #expect(Provider604Wire.count("primary") == 1 && Provider604Wire.count("backup") == 0)
        #expect(f.chat.terminalReceipt(for: identity)?.outcome == .failed)
        #expect(f.chat.markExecutionSucceeded(sessionID: session, executionIdentity: identity) == false)
    }

    @Test func timeoutIsTypedPublicAndNeverReplayedOrFallbacked() async throws {
        Provider604Wire.configure(primary: .timeout)
        let f = try fixture(fallback: true); defer { finish(f) }
        let (session, identity) = try submit(f)
        try await settle(f)
        let content = try verifyPersistence(f, session: session)
        let attempt = try #require(f.observations.values.last?.attempts.first(where: { !$0.succeeded }))
        #expect(attempt.failureKind == .timeout && attempt.statusCode == nil)
        #expect(content.contains("超时") || content.lowercased().contains("timed out"))
        #expect(Provider604Wire.count("primary") == 1 && Provider604Wire.count("backup") == 0)
        #expect(f.chat.terminalReceipt(for: identity)?.outcome == .failed)
    }

    @Test func sdkAcquisitionCancellationIsTerminalWithoutFallback() async throws {
        Provider604Wire.configure(primary: .cancelled)
        let f = try fixture(fallback: true); defer { finish(f) }
        let (session, identity) = try submit(f)
        try await settle(f)
        let content = try verifyPersistence(f, session: session)
        #expect(content.contains("取消") || content.contains("中断") || content.lowercased().contains("cancel"))
        #expect(content.components(separatedBy: "请求已取消").count - 1 == 1)
        let attempt = try #require(f.observations.values.last?.attempts.first(where: { !$0.succeeded }))
        #expect(attempt.failureKind == .cancelled && attempt.statusCode == nil)
        #expect(Provider604Wire.count("primary") == 1 && Provider604Wire.count("backup") == 0)
        #expect(f.chat.terminalReceipt(for: identity)?.outcome == .cancelled)
    }

    @Test func primary404BackupSDKCompletionPersistsExactlyOnceAndRejectsLateProjection() async throws {
        Provider604Wire.configure(primary: .status(404))
        let f = try fixture(fallback: true); defer { finish(f) }
        let (session, identity) = try submit(f)
        try await settle(f)
        let content = try verifyPersistence(f, session: session)
        #expect(content.components(separatedBy: "completed604").count - 1 == 1)
        #expect(content.components(separatedBy: ChatStore.fallbackRouteProjectionPrefix).count - 1 == 1)
        #expect(content.contains("HTTP 404") && content.contains("backup"))
        #expect(Provider604Wire.count("primary") == 1 && Provider604Wire.count("backup") == 1)
        #expect(f.chat.terminalReceipt(for: identity)?.outcome == .succeeded)
        let observation = try #require(f.observations.values.last)
        #expect(observation.servedProviderID == "backup")
        #expect(f.chat.ingestProviderRuntimeObservation(observation, executionIdentity: identity) == false)
        #expect(f.chat.markExecutionSucceeded(sessionID: session, executionIdentity: identity) == false)
        #expect(try verifyPersistence(f, session: session) == content)
    }

    @Test func exhaustedSDKFallbackNeverLoopsOrPublishesSuccessfulCompletion() async throws {
        Provider604Wire.configure(primary: .status(404), backup: .status(403))
        let f = try fixture(fallback: true); defer { finish(f) }
        let (session, identity) = try submit(f)
        try await settle(f)
        let content = try verifyPersistence(f, session: session)
        #expect(!content.contains("completed604"))
        #expect(content.contains("HTTP 404") && content.contains("HTTP 403"))
        #expect(Provider604Wire.count("primary") == 1 && Provider604Wire.count("backup") == 1)
        #expect(f.chat.terminalReceipt(for: identity)?.outcome == .failed)
        let observation = try #require(f.observations.values.last)
        #expect(observation.servedProviderID == nil)
        #expect(f.chat.ingestProviderRuntimeObservation(observation, executionIdentity: identity) == false)
        #expect(f.chat.markExecutionSucceeded(sessionID: session, executionIdentity: identity) == false)
        #expect(try verifyPersistence(f, session: session) == content)
    }

    @Test func stoppingActualBackupHTTPStreamRetiresIdentityAndRejectsLateCompletion() async throws {
        Provider604Wire.configure(primary: .status(404), backup: .held)
        let f = try fixture(fallback: true); defer { finish(f) }
        let (session, identity) = try submit(f)
        for _ in 0..<500 {
            if f.chat.messages.last?.content.contains("partial604") == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(f.chat.messages.last?.content.contains("partial604") == true)
        f.chat.stopStreaming()
        try await settle(f)
        for _ in 0..<200 where Provider604Wire.stopCount("backup") == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(Provider604Wire.stopCount("backup") > 0)
        let content = try verifyPersistence(f, session: session)
        let assistant = try #require(f.chat.messages.last(where: { $0.role == .assistant }))
        #expect(assistant.wasInterrupted)
        #expect(ChatTranscriptFormatter.attributedString([assistant]).string.contains("已中断"))
        #expect(ChatTranscriptFormatter.accessibilityText([assistant]).contains("已中断"))
        #expect(!content.contains("已中断") && !content.contains("completed604"))
        #expect(!content.contains(ChatStore.fallbackRouteProjectionPrefix))
        #expect(Provider604Wire.count("primary") == 1 && Provider604Wire.count("backup") == 1)
        #expect(f.chat.terminalReceipt(for: identity)?.outcome == .cancelled)
        let observation = try #require(f.observations.values.last)
        #expect(f.chat.ingestProviderRuntimeObservation(observation, executionIdentity: identity) == false)
        #expect(f.chat.markExecutionSucceeded(sessionID: session, executionIdentity: identity) == false)
        #expect(try verifyPersistence(f, session: session) == content)
    }

    @Test func stoppedSDKTurnCannotSettleNextSendOrReopenedTranscript2645() async throws {
        Provider604Wire.configure(primary: .held)
        let f = try fixture(); defer { finish(f) }
        let (session, firstIdentity) = try submit(f)
        for _ in 0..<500 {
            if f.chat.messages.last?.content.contains("partial604") == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(f.chat.messages.last?.content.contains("partial604") == true)
        f.chat.stopStreaming()
        try await settle(f)
        for _ in 0..<200 where Provider604Wire.stopCount("primary") == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(Provider604Wire.stopCount("primary") > 0)
        #expect(Provider604Wire.count("primary") == 1)
        let firstReceipt = try #require(f.chat.terminalReceipt(for: firstIdentity))
        #expect(firstReceipt.outcome == .cancelled)
        let stoppedMessages = f.chat.messages.filter { $0.role != .system }
        let oldObservation = try #require(f.observations.values.last)

        // Reuse the same SDK sessions, frozen route factory, engine and Store.
        // Only the synthetic remote service now answers the next request.
        Provider604Wire.configure(primary: .success)
        f.chat.draftText = "owned synthetic2645 next request"
        f.chat.submitComposer()
        let secondIdentity = try #require(f.chat.activeExecutionIdentity(for: session))
        #expect(secondIdentity.turn.sessionID == firstIdentity.turn.sessionID)
        #expect(secondIdentity.turn != firstIdentity.turn)
        #expect(secondIdentity.operationID != firstIdentity.operationID)
        #expect(!f.chat.ingestProviderRuntimeObservation(oldObservation, executionIdentity: firstIdentity))
        #expect(!f.chat.markExecutionSucceeded(sessionID: session, executionIdentity: firstIdentity))
        #expect(f.chat.activeExecutionIdentity(for: session) == secondIdentity)
        try await settle(f)
        #expect(Provider604Wire.count("primary") == 1)
        #expect(f.chat.terminalReceipt(for: firstIdentity) == firstReceipt)
        #expect(f.chat.terminalReceipt(for: secondIdentity)?.outcome == .succeeded)
        let visible = f.chat.messages.filter { $0.role != .system }
        #expect(Array(visible.prefix(stoppedMessages.count)).map(\.content) == stoppedMessages.map(\.content))
        #expect(visible.count == stoppedMessages.count + 2)
        #expect(visible[visible.count - 2].content == "owned synthetic2645 next request")
        #expect(visible.last?.content == "completed604")
        #expect(Set(visible.map(\.id)).count == visible.count)

        let freshStore = SessionStore(directory: f.root.appendingPathComponent("sessions"))
        let durable = try #require(freshStore.loadSession(id: session.uuidString))
        #expect(durable.messages.map(\.content) == visible.map(\.content))
        let defaults = try #require(UserDefaults(suiteName: f.suite))
        let reopened = ChatStore(preferencesDefaults: defaults,
            logManager: LogManager(directory: f.root.appendingPathComponent("next-reopened-logs")))
        #expect(reopened.attachPersistence(freshStore))
        let restored = reopened.messages.filter { $0.role != .system }
        #expect(restored.map(\.content) == visible.map(\.content))
        #expect(!f.chat.markExecutionFailed(sessionID: session, executionIdentity: firstIdentity,
                                          reason: "synthetic old generation"))
        #expect(freshStore.loadSession(id: session.uuidString)?.messages.map(\.content) == durable.messages.map(\.content))
    }

}
