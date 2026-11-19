import AppKit
import Foundation
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

/// Only the remote endpoint is synthetic. Its captured bodies and credential
/// remain in memory; no raw Provider response or shell input is an artifact.
private final class Credential2901Wire: URLProtocol, @unchecked Sendable {
    struct Observation: Sendable {
        let body: Data
        let authorization: String?
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sentinel = ""
    nonisolated(unsafe) private static var captured: [Observation] = []
    static func configure(_ value: String) {
        lock.withLock { sentinel = value; captured = [] }
    }
    static var observations: [Observation] { lock.withLock { captured } }
    static var command: String { lock.withLock { "echo ordinary2901 api_key=" + sentinel } }
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "fixture2901.invalid"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                guard count > 0 else { break }
                body.append(bytes, count: count)
            }
        }
        let (ordinal, value) = Self.lock.withLock { () -> (Int, String) in
            Self.captured.append(.init(body: body,
                authorization: request.value(forHTTPHeaderField: "Authorization")))
            return (Self.captured.count, Self.sentinel)
        }
        do {
            let argument = String(decoding: try JSONSerialization.data(
                withJSONObject: ["command": "echo ordinary2901 api_key=" + value + " && touch ordinary2901-marker"],
                options: [.sortedKeys]), as: UTF8.self)
            let tool: [String: Any] = ["index": 0, "id": "credential2901-shell", "type": "function",
                "function": ["name": "shell_execute", "arguments": argument]]
            let content = (ordinal == 1 ? "ordinary2901 call " : "ordinary2901 final ") + value
            let finish = ordinal == 1 ? "tool_calls" : "stop"
            let stream = (try JSONSerialization.jsonObject(with: body) as? [String: Any])?["stream"] as? Bool == true
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": stream ? "text/event-stream" : "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if stream {
                var delta: [String: Any] = ["content": content]
                if ordinal == 1 { delta["tool_calls"] = [tool] }
                let chunk: [String: Any] = ["choices": [["index": 0, "delta": delta, "finish_reason": NSNull()]]]
                let end: [String: Any] = ["choices": [["index": 0, "delta": [:], "finish_reason": finish]]]
                for payload in [chunk, end] {
                    client?.urlProtocol(self, didLoad: Data("data: ".utf8)
                        + (try JSONSerialization.data(withJSONObject: payload)) + Data("\n\n".utf8))
                }
                client?.urlProtocol(self, didLoad: Data("data: [DONE]\n\n".utf8))
            } else {
                var message: [String: Any] = ["role": "assistant", "content": content]
                if ordinal == 1 {
                    var bufferedTool = tool
                    bufferedTool.removeValue(forKey: "index")
                    message["tool_calls"] = [bufferedTool]
                }
                let responseBody: [String: Any] = ["choices": [["index": 0, "message": message,
                    "finish_reason": finish]]]
                client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: responseBody))
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private actor Credential2901Approval: ApprovalDelegate {
    private(set) var requests: [ApprovalRequest] = []
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        requests.append(request)
        return ApprovalDecision(approved: true, confirmed: true,
            requestID: request.requestID, bindingDigest: request.identityDigest)
    }
}

private final class Credential2901ToolObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(ActionRecord, [ToolExecutionReceipt])] = []
    func record(_ action: ActionRecord, receipts: [ToolExecutionReceipt]) {
        lock.withLock { recorded.append((action, receipts)) }
    }
    var values: [(ActionRecord, [ToolExecutionReceipt])] { lock.withLock { recorded } }
}

@Suite("D-CREDI SDK wire plus approved shell positive egress consumers", .serialized)
@MainActor
struct CredentialSecretEgress2901Tests {
    /// Capture the Boolean before invoking Testing: failed assertions must not
    /// render a credential or unsanitized outlet into the test log.
    private func expectAbsent(_ value: String, in text: String, outlet: String) {
        let absent = !text.contains(value)
        #expect(absent, "complete synthetic credential absent from \(outlet)")
    }
    private func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
    @Test func oneCustodyFeedsRealSDKToolTurnAndPositiveDurableConsumers() async throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = formal.rootDirectory.appendingPathComponent("Credential2901-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let domain = "Credential2901-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain); Credential2901Wire.configure("") }
        let backing = InMemoryKeychainBacking()
        let keychain = KeychainStore(backing: backing)
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("core")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keychain,
                                 privacyStore: EnvVarPrivacyStore(defaults: defaults)),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("chat")),
            memoryFileStore: MemoryFileStore(directory: root.appendingPathComponent("chat")),
            sessionStore: SessionStore(directory: root.appendingPathComponent("chat")),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("core/skills")),
            usageStore: UsageStore(domain: .suite(domain)))
        let chat = ChatStore(preferencesDefaults: defaults, logManager: center.logManager)
        try #require(chat.attachPersistence(center.sessionStore))
        defer { chat.stopAllStreamingForSafety() }
        let sessionID = try #require(chat.activeSessionID)
        chat.setProject(.init(id: "credential2901-project", name: "Synthetic 2901", workingDirectory: root.path),
                        forSession: sessionID)
        chat.credentialBroker.attach(center: center, externalNetworkAllowed: false)
        let value = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let credentialName = "SYNTHETIC2901_API_KEY"
        let capture = try #require(chat.credentialBroker.captureSecureField(value, sessionID: sessionID))
        let outcome = await chat.credentialBroker.confirm(requestID: capture.id, sessionID: sessionID,
            providerID: credentialName, baseURL: "https://fixture2901.invalid/v1",
            modelIDs: ["gpt-4o-mini"], protocolType: .openaiCompatible, riskConfirmed: true)
        try #require(outcome == .savedProbeBlocked)
        let custodyMatches = backing.get(credentialName) == value
        try #require(custodyMatches)
        let scope = try #require(chat.activeMemoryScope)
        center.memoryScopeProvider = { scope }
        _ = try center.memoryStore.addFact("ordinary2901 scoped memory", sourceSessionID: sessionID.uuidString,
                                          memoryScope: scope)
        chat.memoryEnabledProvider = { true }
        chat.memoryInjector = MemoryInjector(store: center.memoryStore)
        Credential2901Wire.configure(value)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Credential2901Wire.self]
        let sdk = OpenAICompatibleProvider(apiKey: try #require(backing.get(credentialName)), model: .gpt4oMini,
            customBaseURL: "https://fixture2901.invalid/v1", session: URLSession(configuration: configuration))
        let facts = ComposerPolicyFactSource(knownCapabilities: ["shell_execute"],
            grantedCapabilities: ["shell_execute"], allowedWriteRoots: [root.path],
            workspaceID: chat.composerWorkspaceID, revision: "credential2901-policy",
            grantEpoch: "credential2901-epoch", leaseID: "credential2901-lease",
            expiresAt: .distantFuture, autonomyCeiling: .l3)
        chat.configureComposerPolicy(facts)
        chat.composerPolicySelection = .init(mode: .manual, approvalScope: .request, effort: .standard,
                                             bypassModeConfirmed: false)
        chat.turnRuntimeSnapshotFactory = { turn, _ in
            ChatTurnRuntimeSnapshot(turn: turn,
                skillInjector: SkillInjector(store: center.skillStore).snapshotForTurn(), mcpBridge: nil)
        }
        let now = Date()
        let goal = GoalEnvelope(scopeID: "credential2901-owned", allowedCapabilities: ["shell_execute"],
            fileRoots: [root.path], budget: 100, deadline: now.addingTimeInterval(3600), concurrencyLimit: 1,
            autonomyLevel: .l3, creatorID: "Credential2901", createdAt: now)
        let lease = AutonomyLease(goalID: goal.goalID, scopeID: goal.scopeID, issuedAt: now, expiresAt: goal.deadline)
        let ledger = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("tool-facts.json"))
        let observed = Credential2901ToolObservation()
        let recording = RecordingToolExecutor(
            base: PolicyRuntimeBinding(goal: goal, lease: lease).wrap(BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])),
            onRecorded: { action in observed.record(action, receipts: ledger.pendingReceipts) },
            knownSecretValues: ChatTranscriptRedactor(store: center.envStore).secretValues)
        let approval = Credential2901Approval()
        chat.agentEngine = AgentLoopChatEngine(toolExecutor: recording, requestBudget: chat.budgetTracker,
            approvalGate: ApprovalGate(policyByTool: ["shell_execute": .alwaysAsk], delegate: approval),
            toolExecutionFactLedger: ledger, composerPolicyFacts: facts)
        chat.streamingProviderOverride = sdk
        chat.composerSubmissionDiagnosticsEnabled = true
        // Enter through the production NSTextView paste handler with an owned
        // pasteboard seam. The earlier boundary test stops before approval;
        // this turn carries that same paste through the SDK and tool outlets.
        let composerView = ComposerPasteAwareTextView(frame: .zero)
        composerView.string = "ordinary2901 question "
        composerView.setSelectedRange(NSRange(location: composerView.string.utf16.count, length: 0))
        composerView.pasteboardStringProvider = { value }
        composerView.onPasteEvent = {
            chat.interceptCredentialPaste($0) || PastedTextComposerConsumer.accept($0, in: chat)
        }
        composerView.paste(nil)
        #expect(composerView.string == "ordinary2901 question ")
        #expect(chat.draftText.contains("ordinary2901 question"))
        expectAbsent(value, in: chat.draftText, outlet: "composer draft")
        chat.submitComposer()
        await (try #require(chat.turnTaskForTests(sessionID: sessionID))).value
        try #require(!chat.isStreaming)
        let wire = Credential2901Wire.observations
        try #require(wire.count == 2)
        for request in wire {
            let authMatches = request.authorization == "Bearer " + value
            #expect(authMatches)
            expectAbsent(value, in: String(decoding: request.body, as: UTF8.self), outlet: "actual SDK body")
        }
        let next = try #require(try JSONSerialization.jsonObject(with: wire[1].body) as? [String: Any])
        let history = try #require(next["messages"] as? [[String: Any]])
        let toolMessages = history.filter { $0["role"] as? String == "tool" }
        try #require(toolMessages.count == 1)
        let toolText = try #require(toolMessages[0]["content"] as? String)
        let toolResult = try #require(try JSONSerialization.jsonObject(with: Data(toolText.utf8)) as? [String: Any])
        #expect(toolResult["exit_code"] as? Int == 0)
        #expect((toolResult["stdout"] as? String)?.contains("ordinary2901") == true)
        #expect(toolMessages[0]["tool_call_id"] as? String == "credential2901-shell")
        let approvalRequests = await approval.requests
        try #require(approvalRequests.count == 1)
        #expect(approvalRequests[0].callID == "credential2901-shell")
        // Composer requests carry their own call identity. `binding` is the
        // separate AgentGate context and is intentionally nil on this path.
        #expect(approvalRequests[0].sessionID == sessionID.uuidString)
        #expect(approvalRequests[0].approvalScope == "request")
        let actions = observed.values
        try #require(actions.count == 1 && actions[0].0.succeeded)
        try #require(actions[0].1.count == 1)
        expectAbsent(value, in: try json(actions[0].0), outlet: "RecordingToolExecutor action")
        expectAbsent(value, in: try json(actions[0].1), outlet: "minted bound tool receipt")
        let fact = try #require(ledger.facts.first)
        #expect(ledger.facts.count == 1 && fact.status == .succeeded && fact.toolName == "shell_execute")
        #expect(fact.toolCallID == "credential2901-shell" && fact.receiptID == actions[0].1[0].receiptID)
        #expect(fact.outputSummary?.displaySuffix?.contains("退出码 0") == true)
        #expect(ledger.pendingReceipts.isEmpty)
        expectAbsent(value, in: String(decoding: try Data(contentsOf: root.appendingPathComponent("tool-facts.json")),
                                      as: UTF8.self), outlet: "durable tool fact ledger")

        // The right terminal is a separate production consumer of the same
        // in-memory command. This branch is not native AX or a second AgentLoop.
        let terminal = TerminalStore(contextSnapshot: TerminalContextSnapshot(sessionID: sessionID.uuidString,
            turnID: "credential2901-terminal", taskID: "credential2901-terminal", projectID: "credential2901-project",
            workdir: root.path), settings: center)
        defer { terminal.stop() }
        terminal.input = Credential2901Wire.command
        terminal.submit()
        if terminal.pendingConfirmation != nil { terminal.confirmPending() }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(15))
        while terminal.isRunning && clock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(!terminal.isRunning)
        #expect(terminal.output.contains("ordinary2901") && terminal.output.contains("退出码 0"))
        expectAbsent(value, in: terminal.output, outlet: "actual right TerminalStore echo and process output")

        let saved = try #require(SessionStore(directory: center.sessionStore.directory).loadSession(id: sessionID.uuidString))
        #expect(saved.messages.contains { $0.role == .assistant && $0.content.contains("ordinary2901 final") })
        expectAbsent(value, in: try json(saved), outlet: "reopened transcript")
        expectAbsent(value, in: String(decoding: try Data(contentsOf: center.sessionStore.sessionsDirectory
            .appendingPathComponent(sessionID.uuidString + ".json")), as: UTF8.self), outlet: "transcript disk bytes")
        let redactor = ChatTranscriptRedactor(store: center.envStore)
        let plain = ChatTranscriptFormatter.plainText(chat.messages, redactor: redactor)
        #expect(plain.contains("ordinary2901 final"))
        expectAbsent(value, in: plain, outlet: "transcript export formatter")
        expectAbsent(value, in: ChatTranscriptFormatter.accessibilityText(chat.messages, redactor: redactor),
                     outlet: "AX formatter only; native AX untested")
        try #require(!center.logManager.recentLogs().isEmpty)
        expectAbsent(value, in: center.logManager.recentLogsText(), outlet: "log ring")
        expectAbsent(value, in: String(decoding: try Data(contentsOf: root.appendingPathComponent("logs/app.log")),
                                      as: UTF8.self), outlet: "durable log")
        let diagnostic = DiagnosticExportController(runtimeSummaryProvider: {
            .init(appState: .ready, activeSessionPresent: true, activeSessionStreaming: chat.isStreaming)
        })
        let destination = root.appendingPathComponent("diagnostic.json")
        await diagnostic.export(to: destination)
        let receipt = try #require(diagnostic.lastReceipt)
        try #require(receipt.byteCount > 0)
        let diagnosticBytes = try Data(contentsOf: destination)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(DiagnosticBundle.self, from: diagnosticBytes).runtime.activeSessionPresent == true)
        expectAbsent(value, in: String(decoding: diagnosticBytes, as: UTF8.self), outlet: "diagnostic export bytes")
        expectAbsent(value, in: String(describing: receipt), outlet: "diagnostic export receipt")
        let backup = root.appendingPathComponent("synthetic.minissync")
        try #require(!center.exportBackup(to: backup).isError)
        let backupBytes = try Data(contentsOf: backup)
        let envelope = try JSONDecoder().decode(SyncSnapshotEnvelope.self, from: backupBytes)
        #expect(Set(envelope.manifest.scopes) == Set(SyncScope.allCases.map(\.rawValue)))
        #expect(envelope.sessions?.contains { $0.id == sessionID.uuidString
            && $0.messages.contains { $0.content.contains("ordinary2901 final") } } == true)
        #expect(envelope.memories?.contains { $0.text.contains("ordinary2901 scoped memory") } == true)
        expectAbsent(value, in: String(decoding: backupBytes, as: UTF8.self), outlet: "actual four-domain backup")
    }
}
