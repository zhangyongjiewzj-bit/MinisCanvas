import CryptoKit
import Darwin
import Foundation
import Network
import Testing
import MinisCore
@testable import MinisCanvasApp

// The listener owns only a synthetic remote HTTP service. URLSession, the
// OpenAI-compatible SDK, BridgeStore, ChatStore and SessionStore are production.
private final class CONC3HTTPServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "conc3.http.owned.listener")
    private let lock = NSLock()
    private let listener: NWListener
    private var connections: [Int: NWConnection] = [:]
    private var received: [Int: Data] = [:]
    private var nextID = 0
    private var requestBodies: [Data] = []
    private var oldPeerClosed = false
    private var watchdogCount = 0
    private var lateAttempted = false
    private var stopping = false
    private var listenerCancelled = false
    private var peerWaiter: CheckedContinuation<Bool, Never>?
    private var stopWaiter: CheckedContinuation<Void, Never>?

    var baseURL: String { "http://127.0.0.1:\(listener.port!.rawValue)" }
    var snapshot: (requests: Int, oldClosed: Bool, watchdog: Int, lateAttempted: Bool) {
        lock.withLock { (requestBodies.count, oldPeerClosed, watchdogCount, lateAttempted) }
    }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready, .failed: ready.signal()
            case .cancelled:
                guard let self else { return }
                self.listenerCancelled = true
                self.finishStopIfJoined()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.nextID += 1
            let id = self.nextID
            self.connections[id] = connection
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                if case .cancelled = state {
                    self.connections.removeValue(forKey: id)
                    self.finishStopIfJoined()
                }
            }
            connection.start(queue: self.queue)
            self.readRequest(id, connection)
            // A watchdog close is a test failure, never proof of cancellation.
            self.queue.asyncAfter(deadline: .now() + 6) { [weak self] in
                guard let self, !self.stopping, self.connections[id] != nil else { return }
                self.lock.withLock { self.watchdogCount += 1 }
                connection.cancel()
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 3) == .success,
              let port = listener.port, port.rawValue != 0 else {
            listener.cancel()
            throw URLError(.cannotConnectToHost)
        }
    }

    private func readRequest(_ id: Int, _ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.received[id, default: Data()].append(data) }
            let bytes = self.received[id, default: Data()]
            if let boundary = bytes.range(of: Data("\r\n\r\n".utf8)),
               let headers = String(data: bytes[..<boundary.lowerBound], encoding: .utf8) {
                let length = headers.components(separatedBy: "\r\n")
                    .first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                let body = bytes[boundary.upperBound...]
                if body.count >= length {
                    self.lock.withLock { self.requestBodies.append(Data(body.prefix(length))) }
                    let text = id == 1 ? "OLD-HTTP-CONC3" : "FRESH-HTTP-CONC3-\(id)"
                    let delta = "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"\(text)\"},\"finish_reason\":null}]}\n\n"
                    let prefix = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
                    self.send(connection, prefix + self.chunk(delta))
                    if id == 1 {
                        self.readOldPeerClose(id, connection)
                    } else {
                        self.send(connection, self.chunk("data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n") + "0\r\n\r\n", close: true)
                    }
                    return
                }
            }
            if !complete && error == nil { self.readRequest(id, connection) }
        }
    }

    private func readOldPeerClose(_ id: Int, _ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] _, _, complete, error in
            guard let self else { return }
            if complete || error != nil {
                guard !self.stopping else { return }
                self.lock.withLock { self.oldPeerClosed = true }
                // Retire our half only after peer closure and the late send
                // invocation have both been observed on this serial queue.
                if self.lock.withLock({ self.lateAttempted }) { connection.cancel() }
                let waiter = self.peerWaiter
                self.peerWaiter = nil
                waiter?.resume(returning: true)
            } else {
                self.readOldPeerClose(id, connection)
            }
        }
    }

    func attemptLateOldDelta() {
        queue.async { [self] in
            guard let old = connections[1] else { return }
            // This witnesses a send invocation, not successful wire delivery.
            lock.withLock { lateAttempted = true }
            send(old, chunk("data: {\"choices\":[{\"delta\":{\"content\":\"LATE-HTTP-CONC3\"}}]}\n\n"))
            if lock.withLock({ oldPeerClosed }) { old.cancel() }
        }
    }

    func awaitOldPeerClosed() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if lock.withLock({ oldPeerClosed }) {
                    continuation.resume(returning: true)
                    return
                }
                peerWaiter = continuation
                queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self, let pending = self.peerWaiter else { return }
                    self.peerWaiter = nil
                    pending.resume(returning: false)
                }
            }
        }
    }

    func stopAndJoin() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                stopping = true
                stopWaiter = continuation
                listener.cancel()
                for connection in connections.values { connection.cancel() }
                finishStopIfJoined()
            }
        }
    }

    private func finishStopIfJoined() {
        guard stopping, listenerCancelled, connections.isEmpty else { return }
        let waiter = stopWaiter
        stopWaiter = nil
        waiter?.resume()
    }

    private func chunk(_ value: String) -> String {
        "\(String(value.utf8.count, radix: 16))\r\n\(value)\r\n"
    }
    private func send(_ connection: NWConnection, _ text: String, close: Bool = false) {
        connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in
            if close { connection.cancel() }
        })
    }
}

private struct CONC3HTTPSeed: Codable {
    let parentPID: Int32
    let baseURL: String
    let sessionA: UUID
    let sessionB: UUID
    let executionA: AgentExecutionIdentity
    let executionB: AgentExecutionIdentity
    let bytesA: String
    let bytesB: String
}

@Suite("D-CONC3 actual HTTP SDK turn cancel, switch and OS cold recovery", .serialized)
@MainActor
struct CONC3HTTPColdTurnConsumerTests {
    private func until(_ predicate: @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<800 {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await predicate()
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func bytes(_ store: SessionStore, _ id: UUID) throws -> Data {
        try Data(contentsOf: store.sessionsDirectory.appendingPathComponent(id.uuidString + ".json"))
    }

    private func provider(_ baseURL: String, session: URLSession) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(apiKey: "owned-synthetic-conc3",
            model: LLMModel(id: "conc3-http-model", displayName: "Owned HTTP", provider: "CONC3HTTP"),
            customBaseURL: baseURL, appendV1Suffix: false, session: session,
            providerName: "CONC3HTTP")
    }

    private func bridge(_ root: URL) async throws -> (app: BridgeStore, settings: SettingsCenter) {
        let readiness = ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        #expect(readiness.upsert([ProviderReadinessPersistenceRecord(
            providerID: "CONC3HTTP", modelID: "conc3-http-model", status: .passed,
            readinessState: .mock, checkedAt: Date(), evidenceID: "conc3-http-primary",
            isApplied: true, discoveryReceiptID: "conc3-http-discovery",
            applyReceiptID: "provider-readiness-apply:conc3-http-discovery", appliedAt: Date())]))
        let sessions = SessionStore(directory: root)
        let app = BridgeStore(sessionStore: sessions, providerReadinessStore: readiness)
        let settings = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("env"),
                keychain: KeychainStore(backing: InMemoryKeychainBacking())),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            sessionStore: sessions,
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            logManager: app.chat.logManager,
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("settings-mcps.json"),
                keychain: KeychainStore(backing: InMemoryKeychainBacking())),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite("conc3-owner-" + UUID().uuidString)),
            providerReadinessStore: readiness)
        try #require(SettingsCenter.active === settings)
        try #require(settings.sessionStore === sessions)
        let installation = app.attachProductionServices(fileAccessAllowedRoot: root,
            fileAccessDeniedRoots: [], sessionDirectory: root)
        await installation.value
        try #require(app.chat.sessionStore === sessions)
        return (app, settings)
    }

    @Test func heldRealHTTPStreamCannotSettleOldSessionAfterSwitchOrColdRestart() async throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        if ProcessInfo.processInfo.environment["CONC3_HTTP_CHILD_PHASE"] == "reopen" {
            let shared = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["CONC3_HTTP_SHARED_ROOT"]),
                             isDirectory: true)
            try #require(shared.standardizedFileURL.path.hasPrefix(formal.rootDirectory.standardizedFileURL.path + "/"))
            try await coldReopen(shared)
            return
        }
        let root = formal.rootDirectory.appendingPathComponent("conc3-http-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let server = try CONC3HTTPServer()
        do {
            try await parentFlow(root, server: server)
            await server.stopAndJoin()
        } catch {
            await server.stopAndJoin()
            throw error
        }
    }

    private func parentFlow(_ root: URL, server: CONC3HTTPServer) async throws {
        let store = SessionStore(directory: root)
        let sessionA = UUID()
        _ = try store.createSession(id: sessionA.uuidString, title: "HTTP A")
        let (app, settings) = try await bridge(root)
        defer { withExtendedLifetime(settings) {} }
        try #require(SettingsCenter.active === settings)
        try #require(app.chat.sessionStore === settings.sessionStore)
        let chat = app.chat
        defer { chat.stopAllStreamingForSafety() }
        #expect(chat.activeSessionID == sessionA)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        chat.streamingProviderOverride = provider(server.baseURL, session: session)
        chat.draftText = "HTTP A held"
        chat.sendDraft()
        let firstToken = await until { chat.messages.last?.content.contains("OLD-HTTP-CONC3") == true }
        print("CONC3_HTTP_FIRST requestCount=\(server.snapshot.requests) ownerMatches=\(SettingsCenter.active === settings) tokenObserved=\(firstToken)")
        try #require(firstToken)
        let executionA = try #require(chat.activeExecutionIdentity(for: sessionA))
        let writebackA = try #require(chat.activeWritebackIdentity(for: sessionA))
        let assistantA = try #require(chat.messages.last?.id)
        chat.stopStreaming()
        let cancelled = try #require(chat.terminalReceipt(for: executionA))
        #expect(cancelled.outcome == .cancelled)
        let stoppedA = try bytes(store, sessionA)
        chat.newSession()
        let sessionB = try #require(chat.activeSessionID)
        #expect(sessionB != sessionA)
        server.attemptLateOldDelta()
        #expect(await server.awaitOldPeerClosed())
        chat.draftText = "HTTP B valid"
        chat.sendDraft()
        try #require(await until { !chat.isStreaming &&
            chat.messages.last?.content.contains("FRESH-HTTP-CONC3-2") == true })
        let executionB = try #require(chat.executionSnapshot(forSessionID: sessionB)?.executionIdentity)
        #expect(executionB.operationID != executionA.operationID)
        #expect(chat.terminalReceipt(for: executionB)?.outcome == .succeeded)
        #expect(chat.terminalReceipt(for: executionA) == cancelled)
        #expect(!chat.updateMessageContent(sessionID: sessionA, messageID: assistantA,
                                           identity: writebackA, append: "LATE-HTTP-CONC3"))
        #expect(!chat.markExecutionSucceeded(sessionID: sessionA,
                                             executionIdentity: executionA))
        #expect(try bytes(store, sessionA) == stoppedA)
        #expect(chat.sessions.flatMap(\.messages).allSatisfy { !$0.content.contains("LATE-HTTP-CONC3") })
        let seed = CONC3HTTPSeed(parentPID: getpid(), baseURL: server.baseURL,
            sessionA: sessionA, sessionB: sessionB, executionA: executionA, executionB: executionB,
            bytesA: digest(stoppedA), bytesB: digest(try bytes(store, sessionB)))
        try JSONEncoder().encode(seed).write(to: root.appendingPathComponent("seed.json"), options: .atomic)
        let cold = try await launchCold(root)
        #expect(cold.status == 0 && cold.pid != getpid())
        let wire = server.snapshot
        #expect(wire.requests == 3 && wire.oldClosed && wire.lateAttempted && wire.watchdog == 0)
        print("CONC3_HTTP parent=\(getpid()) cold=\(cold.pid) child_EXIT=\(cold.status) requests=\(wire.requests) watchdog=\(wire.watchdog)")
    }

    private func coldReopen(_ root: URL) async throws {
        let seed = try JSONDecoder().decode(CONC3HTTPSeed.self,
            from: Data(contentsOf: root.appendingPathComponent("seed.json")))
        #expect(seed.parentPID != getpid())
        let store = SessionStore(directory: root)
        #expect(digest(try bytes(store, seed.sessionA)) == seed.bytesA)
        #expect(digest(try bytes(store, seed.sessionB)) == seed.bytesB)
        let (app, settings) = try await bridge(root)
        defer { withExtendedLifetime(settings) {} }
        try #require(SettingsCenter.active === settings)
        try #require(app.chat.sessionStore === settings.sessionStore)
        let chat = app.chat
        defer { chat.stopAllStreamingForSafety() }
        chat.switchSession(id: seed.sessionB)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        chat.streamingProviderOverride = provider(seed.baseURL, session: session)
        chat.draftText = "HTTP C after cold restart"
        chat.sendDraft()
        try #require(await until { !chat.isStreaming &&
            chat.messages.last?.content.contains("FRESH-HTTP-CONC3-3") == true })
        let executionC = try #require(chat.executionSnapshot(forSessionID: seed.sessionB)?.executionIdentity)
        #expect(executionC.operationID != seed.executionB.operationID)
        #expect(chat.terminalReceipt(for: executionC)?.outcome == .succeeded)
        #expect(digest(try bytes(store, seed.sessionA)) == seed.bytesA)
        #expect(chat.sessions.flatMap(\.messages).allSatisfy { !$0.content.contains("LATE-HTTP-CONC3") })
        print("CONC3_HTTP_COLD pid=\(getpid()) oldAunchanged=true")
    }

    private func launchCold(_ root: URL) async throws -> (pid: Int32, status: Int32) {
        let process = Process()
        let inherited = CommandLine.arguments
        let executable = URL(fileURLWithPath: inherited[0]).standardizedFileURL
        let bundle: URL
        if let flag = inherited.firstIndex(of: "--test-bundle-path") {
            // SwiftPM runs Swift Testing suites through its helper; re-exec the
            // helper with the loaded bundle so the child actually runs tests.
            try #require(flag + 1 < inherited.count)
            try #require(executable.path.hasSuffix("/usr/libexec/swift/pm/swiftpm-testing-helper"))
            bundle = URL(fileURLWithPath: inherited[flag + 1]).standardizedFileURL
            process.arguments = ["--test-bundle-path", bundle.path, "--testing-library", "swift-testing",
                                 "--no-parallel", "--filter", "CONC3HTTPColdTurnConsumerTests"]
        } else {
            // A directly executed test bundle remains a valid real exec path.
            bundle = executable
            process.arguments = ["--testing-library", "swift-testing", "--no-parallel",
                                 "--filter", "CONC3HTTPColdTurnConsumerTests"]
        }
        if inherited.contains("--test-bundle-path") {
            #expect(bundle.path.contains(".xctest/Contents/MacOS/"))
        } else {
            // Match the already-audited MCP cold-exec identity contract.
            let appMain = try #require(Bundle.main.executableURL).standardizedFileURL
            try #require(bundle == appMain)
            try #require(bundle.lastPathComponent == "MinisCanvasOriginalAppMain")
            try #require(bundle.path.contains("R13OriginalAppMain.app/Contents/MacOS/"))
        }
        try #require(FileManager.default.fileExists(atPath: bundle.path))
        process.executableURL = executable
        var environment = ProcessInfo.processInfo.environment
        environment["CONC3_HTTP_CHILD_PHASE"] = "reopen"
        environment["CONC3_HTTP_SHARED_ROOT"] = root.path
        process.environment = environment
        let rawURL = root.appendingPathComponent("cold.framework.raw.log")
        #expect(FileManager.default.createFile(atPath: rawURL.path, contents: nil))
        let output = try FileHandle(forWritingTo: rawURL)
        defer { try? output.close() }
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let pid = process.processIdentifier
        let limit = ContinuousClock.now.advanced(by: .seconds(40))
        while process.isRunning, ContinuousClock.now < limit {
            try await Task.sleep(for: .milliseconds(20))
        }
        let timedOut = process.isRunning
        if timedOut { process.terminate() } // Only this owned synthetic child.
        process.waitUntilExit()
        try JSONEncoder().encode(["pid": String(pid), "REAL_EXIT": String(process.terminationStatus),
                                  "timedOut": String(timedOut)])
            .write(to: root.appendingPathComponent("cold.terminal.json"), options: .atomic)
        #expect(!timedOut && process.terminationReason == .exit)
        return (pid, process.terminationStatus)
    }
}
