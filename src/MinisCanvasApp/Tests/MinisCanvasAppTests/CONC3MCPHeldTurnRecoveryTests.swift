import CryptoKit
import Darwin
import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private actor CONC3MCPSignal {
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        guard !fired else { return }
        fired = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        if fired { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    var isFired: Bool { fired }
}

private actor CONC3MCPCalls {
    private(set) var count = 0
    private(set) var oldReturned = false
    func begin() -> Int { count += 1; return count }
    func markOldReturned() { oldReturned = true }
}

/// Only the synthetic wire is held. Manager grants, registry, App Composer,
/// cancellation, journal settlement and session persistence stay production.
private struct CONC3MCPTransport: MCPTransport {
    let entered: CONC3MCPSignal
    let release: CONC3MCPSignal
    let calls: CONC3MCPCalls
    let holdsFirstCall: Bool

    func start() async throws {}
    func stop() {}
    func notify(_ notification: MCPJSONRPCNotification) throws {}

    func send(_ request: MCPJSONRPCRequest) async throws -> MCPJSONRPCResponse {
        switch request.method {
        case "initialize":
            return MCPJSONRPCResponse(id: request.id, result: .object([
                "protocolVersion": .string("2024-11-05"),
                "capabilities": .object([:]),
                "serverInfo": .object(["name": .string("owned-conc3"), "version": .string("1")]),
            ]))
        case "tools/list":
            return MCPJSONRPCResponse(id: request.id, result: .object([
                "tools": .array([.object([
                    "name": .string("echo"),
                    "inputSchema": .object(["type": .string("object")]),
                ])]),
            ]))
        case "tools/call":
            let number = await calls.begin()
            let isOldHeldCall = holdsFirstCall && number == 1
            if isOldHeldCall {
                await entered.signal()
                await release.wait() // Intentionally returns after the App has cancelled A.
                await calls.markOldReturned()
            }
            let value = isOldHeldCall ? "OLD-LATE-MCP-CONC3" : "FRESH-MCP-CONC3-\(number)"
            return MCPJSONRPCResponse(id: request.id, result: .object([
                "content": .array([.object(["type": .string("text"), "text": .string(value)])]),
            ]))
        default:
            return MCPJSONRPCResponse(id: request.id,
                error: MCPJSONRPCError(code: -32601, message: "unknown synthetic method"))
        }
    }
}

private final class CONC3MCPProvider: LLMProvider, @unchecked Sendable {
    let name = "conc3-owned-provider"
    var model = LLMModel(id: "conc3-owned-model", displayName: "Owned CONC3", provider: "conc3-owned-provider")
    let capabilities: Set<ProviderCapability> = [.streaming, .tools]
    let toolName: String
    let callID: String
    private let lock = NSLock()
    private var calls = 0
    private var catalogs: [[String]] = []

    init(toolName: String, callID: String) {
        self.toolName = toolName
        self.callID = callID
    }

    var requestCount: Int { lock.withLock { calls } }
    var firstCatalog: [String] { lock.withLock { catalogs.first ?? [] } }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        LLMResponse(text: "unexpected text-only route", stopReason: "stop", usage: nil)
    }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        let number = lock.withLock { () -> Int in
            calls += 1
            catalogs.append(tools.map(\.name))
            return calls
        }
        if number == 1, tools.contains(where: { $0.name == toolName }) {
            return LLMResponse(text: "", stopReason: "tool_calls", usage: nil, toolCalls: [
                LLMToolCall(id: callID, name: toolName,
                    rawArguments: "{\"value\":\"owned\"}", arguments: ["value": "owned"]),
            ])
        }
        return LLMResponse(text: "FRESH-ASSISTANT-CONC3", stopReason: "stop", usage: nil)
    }

    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct CONC3MCPApproval: ApprovalDelegate {
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        ApprovalDecision(approved: true, confirmed: true,
            requestID: request.requestID, bindingDigest: request.identityDigest)
    }
}

private struct CONC3MCPSeed: Codable {
    let parentPID: Int32
    let sessionA: UUID
    let sessionB: UUID
    let oldExecution: AgentExecutionIdentity
    let newExecution: AgentExecutionIdentity
    let oldSessionSHA256: String
    let newSessionSHA256: String
    let grant: MCPToolAuthorization
    let oldFactSucceeded: Bool
    let newFactSucceeded: Bool
}

@Suite("D-CONC3 held MCP production turn cancellation, late result and cold recovery", .serialized)
@MainActor
struct CONC3MCPHeldTurnRecoveryTests {
    private let serverID = "conc3-owned"

    private func until(_ condition: @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<800 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func sessionBytes(_ store: SessionStore, _ id: UUID) throws -> Data {
        try Data(contentsOf: store.sessionsDirectory.appendingPathComponent(id.uuidString + ".json"))
    }

    private func manager(_ root: URL) -> MCPServerManager {
        MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"))
    }

    private func registry(_ manager: MCPServerManager, transport: CONC3MCPTransport) -> MCPToolRegistry {
        MCPToolRegistry(manager: manager, clientFactory: { server in
            MCPClient(server: server, transport: transport)
        })
    }

    private func bridge(_ root: URL, manager: MCPServerManager,
                        registry: MCPToolRegistry) async throws -> (app: BridgeStore, settings: SettingsCenter) {
        let readiness = ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        #expect(readiness.upsert([ProviderReadinessPersistenceRecord(
            providerID: "conc3-owned-provider", modelID: "conc3-owned-model", status: .passed,
            readinessState: .mock, checkedAt: Date(), evidenceID: "conc3-owned-primary",
            isApplied: true, discoveryReceiptID: "conc3-owned-discovery",
            applyReceiptID: "provider-readiness-apply:conc3-owned-discovery", appliedAt: Date())]))
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
        let installation = app.attachProductionServices(fileAccessAllowedRoot: root, fileAccessDeniedRoots: [],
            sessionDirectory: root, mcpManager: manager, mcpBridgeOverride: registry,
            approvalDelegateOverride: CONC3MCPApproval())
        await installation.value
        try #require(app.chat.sessionStore === sessions)
        return (app, settings)
    }

    @Test func heldMCPCallCannotWriteAfterCancelAndSwitchAndColdProcessCanContinue() async throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        if let phase = ProcessInfo.processInfo.environment["CONC3_MCP_CHILD_PHASE"] {
            let shared = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["CONC3_MCP_SHARED_ROOT"]),
                             isDirectory: true)
            try #require(shared.standardizedFileURL.path.hasPrefix(formal.rootDirectory.standardizedFileURL.path + "/"))
            #expect(phase == "reopen")
            try await coldReopen(shared)
            return
        }
        let root = formal.rootDirectory.appendingPathComponent("conc3-mcp-" + UUID().uuidString,
                                                                 isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let m = manager(root)
        let server = MCPServer(id: serverID, name: "Owned CONC3", type: .http,
                               url: "http://127.0.0.1:1")
        try m.addServer(server)
        try m.authorizeServer(id: serverID)
        try m.authorizeTool(serverID: serverID, toolName: "echo")
        let entered = CONC3MCPSignal(), release = CONC3MCPSignal(), calls = CONC3MCPCalls()
        defer { Task { await release.signal() } }
        let wire = CONC3MCPTransport(entered: entered, release: release, calls: calls, holdsFirstCall: true)
        let reg = registry(m, transport: wire)
        defer { reg.disconnectAll() }
        try await reg.refreshTools()
        let name = MCPBoundTool.makeFullName(serverID: serverID, toolName: "echo")
        #expect(try await reg.mcpBoundTools().map(\.fullName).contains(name))
        let grant = try #require(m.authorization(serverID: serverID))
        #expect(grant.serverID == serverID)
        #expect(grant.descriptorFingerprint == server.descriptorFingerprint)
        #expect(grant.authorizedToolNames == ["echo"])
        #expect(grant.schemaBindingDigest == m.discoverySnapshot(serverID: serverID)?.schemaDigest)
        let store = SessionStore(directory: root)
        let sessionA = UUID()
        _ = try store.createSession(id: sessionA.uuidString, title: "MCP A")
        let (app, settings) = try await bridge(root, manager: m, registry: reg)
        defer { withExtendedLifetime(settings) {} }
        try #require(SettingsCenter.active === settings)
        try #require(app.chat.sessionStore === settings.sessionStore)
        let chat = app.chat
        defer { chat.stopAllStreamingForSafety() }
        #expect(chat.activeSessionID == sessionA)
        let first = CONC3MCPProvider(toolName: name, callID: "conc3-old-call")
        chat.streamingProviderOverride = first
        chat.draftText = "call owned MCP A"
        chat.sendDraft()
        let firstEntered = await until { await entered.isFired }
        print("CONC3_MCP_FIRST providerRequests=\(first.requestCount) catalogCount=\(first.firstCatalog.count) containsExpectedTool=\(first.firstCatalog.contains(name)) ownerMatches=\(SettingsCenter.active === settings) handlerEntered=\(firstEntered)")
        try #require(firstEntered)
        #expect(first.firstCatalog.contains(name))
        let oldExecution = try #require(chat.activeExecutionIdentity(for: sessionA))
        #expect(chat.isStreaming)
        chat.stopStreaming()
        let cancelled = try #require(chat.terminalReceipt(for: oldExecution))
        #expect(cancelled.outcome == .cancelled)
        let oldBytes = try sessionBytes(store, sessionA)
        chat.newSession()
        let sessionB = try #require(chat.activeSessionID)
        #expect(sessionB != sessionA)
        await release.signal()
        try #require(await until { await calls.oldReturned })
        let second = CONC3MCPProvider(toolName: name, callID: "conc3-new-call")
        chat.streamingProviderOverride = second
        chat.draftText = "call owned MCP B"
        chat.sendDraft()
        try #require(await until { !chat.isStreaming && second.requestCount >= 2 })
        let newExecution = try #require(chat.executionSnapshot(forSessionID: sessionB)?.executionIdentity)
        #expect(newExecution.operationID != oldExecution.operationID)
        #expect(second.firstCatalog.contains(name))
        #expect(chat.terminalReceipt(for: newExecution)?.outcome == .succeeded)
        #expect(try sessionBytes(store, sessionA) == oldBytes)
        #expect(chat.sessions.flatMap(\.messages).allSatisfy { !$0.content.contains("OLD-LATE-MCP-CONC3") })
        let engine = try #require(chat.agentEngine as? AgentLoopChatEngine)
        let facts = engine.toolExecutionFactLedger.facts
        #expect(!facts.contains { $0.executionIdentity == oldExecution && $0.status == .succeeded })
        #expect(facts.contains { $0.executionIdentity == newExecution && $0.status == .succeeded })
        let seed = CONC3MCPSeed(parentPID: getpid(), sessionA: sessionA, sessionB: sessionB,
            oldExecution: oldExecution, newExecution: newExecution,
            oldSessionSHA256: digest(oldBytes), newSessionSHA256: digest(try sessionBytes(store, sessionB)),
            grant: grant,
            oldFactSucceeded: false, newFactSucceeded: true)
        try JSONEncoder().encode(seed).write(to: root.appendingPathComponent("seed.json"), options: .atomic)
        let cold = try await launchCold(root)
        #expect(cold.status == 0 && cold.pid != getpid())
        print("CONC3_MCP parent=\(getpid()) cold=\(cold.pid) child_EXIT=\(cold.status) root=\(root.path)")
    }

    private func coldReopen(_ root: URL) async throws {
        let seed = try JSONDecoder().decode(CONC3MCPSeed.self,
            from: Data(contentsOf: root.appendingPathComponent("seed.json")))
        #expect(seed.parentPID != getpid())
        let store = SessionStore(directory: root)
        #expect(digest(try sessionBytes(store, seed.sessionA)) == seed.oldSessionSHA256)
        #expect(digest(try sessionBytes(store, seed.sessionB)) == seed.newSessionSHA256)
        let m = manager(root)
        let server = try #require(m.server(id: serverID))
        #expect(m.authorization(serverID: serverID) == seed.grant)
        #expect(seed.grant.descriptorFingerprint == server.descriptorFingerprint)
        #expect(m.isServerAuthorized(server))
        #expect(m.isToolAuthorized(serverID: serverID, toolName: "echo"))
        let entered = CONC3MCPSignal(), release = CONC3MCPSignal(), calls = CONC3MCPCalls()
        let wire = CONC3MCPTransport(entered: entered, release: release, calls: calls, holdsFirstCall: false)
        let reg = registry(m, transport: wire)
        defer { reg.disconnectAll() }
        try await reg.refreshTools()
        #expect(m.discoverySnapshot(serverID: serverID)?.schemaDigest == seed.grant.schemaBindingDigest)
        let (app, settings) = try await bridge(root, manager: m, registry: reg)
        defer { withExtendedLifetime(settings) {} }
        try #require(SettingsCenter.active === settings)
        try #require(app.chat.sessionStore === settings.sessionStore)
        let chat = app.chat
        defer { chat.stopAllStreamingForSafety() }
        chat.switchSession(id: seed.sessionB)
        let reopened = try #require(chat.agentEngine as? AgentLoopChatEngine)
        #expect(!reopened.toolExecutionFactLedger.facts.contains {
            $0.executionIdentity == seed.oldExecution && $0.status == .succeeded
        })
        #expect(reopened.toolExecutionFactLedger.facts.contains {
            $0.executionIdentity == seed.newExecution && $0.status == .succeeded
        })
        let third = CONC3MCPProvider(toolName: MCPBoundTool.makeFullName(serverID: serverID, toolName: "echo"),
                                     callID: "conc3-cold-call")
        chat.streamingProviderOverride = third
        chat.draftText = "call MCP after cold reopen"
        chat.sendDraft()
        try #require(await until { !chat.isStreaming && third.requestCount >= 2 })
        let coldExecution = try #require(chat.executionSnapshot(forSessionID: seed.sessionB)?.executionIdentity)
        #expect(coldExecution.operationID != seed.newExecution.operationID)
        #expect(chat.terminalReceipt(for: coldExecution)?.outcome == .succeeded)
        #expect(third.firstCatalog.contains(third.toolName))
        #expect(reopened.toolExecutionFactLedger.facts.contains {
            $0.executionIdentity == coldExecution && $0.status == .succeeded
        })
        #expect(digest(try sessionBytes(store, seed.sessionA)) == seed.oldSessionSHA256)
        #expect(!chat.sessions.flatMap(\.messages).contains { $0.content.contains("OLD-LATE-MCP-CONC3") })
        #expect(reopened.toolExecutionFactLedger.pendingReceipts.isEmpty)
        try m.revokeTool(serverID: serverID, toolName: "echo")
        let revoked = manager(root)
        #expect(!revoked.isToolAuthorized(serverID: serverID, toolName: "echo"))
        #expect(revoked.authorization(serverID: serverID)?.authorizedToolNames.isEmpty == true)
        print("CONC3_MCP_COLD pid=\(getpid()) old=0 fresh=\(await calls.count) root=\(root.path)")
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
                                 "--no-parallel", "--filter", "CONC3MCPHeldTurnRecoveryTests"]
        } else {
            // A directly executed test bundle remains a valid real exec path.
            bundle = executable
            process.arguments = ["--testing-library", "swift-testing", "--no-parallel",
                                 "--filter", "CONC3MCPHeldTurnRecoveryTests"]
        }
        if inherited.contains("--test-bundle-path") {
            #expect(bundle.path.contains(".xctest/Contents/MacOS/"))
        } else {
            // The native runner re-execs this exact signed AppMain, never an invented helper.
            let appMain = try #require(Bundle.main.executableURL).standardizedFileURL
            try #require(bundle == appMain)
            try #require(bundle.lastPathComponent == "MinisCanvasOriginalAppMain")
            try #require(bundle.path.contains("R13OriginalAppMain.app/Contents/MacOS/"))
        }
        try #require(FileManager.default.fileExists(atPath: bundle.path))
        process.executableURL = executable
        var environment = ProcessInfo.processInfo.environment
        environment["CONC3_MCP_CHILD_PHASE"] = "reopen"
        environment["CONC3_MCP_SHARED_ROOT"] = root.path
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
