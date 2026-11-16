import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private final class MCP303Signal: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var isSignaled: Bool { lock.withLock { signaled } }
    func signal() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            signaled = true
            let pending = waiters
            waiters = []
            return pending
        }
        pending.forEach { $0.resume() }
    }
    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Bool in
                if signaled { return true }
                waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }
}

private final class MCP303Transport: MCPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var valueType: String
    private let listFailure: (any Error)?
    private var listCount = 0
    private var callCount = 0
    private var exitsOnCall = false
    private var exited = false
    let entered: MCP303Signal?
    let release: MCP303Signal?
    init(valueType: String = "string", entered: MCP303Signal? = nil, release: MCP303Signal? = nil,
         listFailure: (any Error)? = nil) {
        self.valueType = valueType
        self.listFailure = listFailure
        self.entered = entered
        self.release = release
    }
    var lists: Int { lock.withLock { listCount } }
    var calls: Int { lock.withLock { callCount } }
    var isReady: Bool { lock.withLock { !exited } }
    func replaceSchema(with type: String) { lock.withLock { valueType = type } }
    func exitOnNextCall() { lock.withLock { exitsOnCall = true } }
    func recoverExitedFixture() { lock.withLock { exited = false; exitsOnCall = false } }
    func start() async throws {
        if !isReady { throw MCPClientError.processExited(7) }
    }
    func notify(_ notification: MCPJSONRPCNotification) throws {}
    func stop() {}
    func send(_ request: MCPJSONRPCRequest) async throws -> MCPJSONRPCResponse {
        switch request.method {
        case "initialize":
            return MCPJSONRPCResponse(id: request.id, result: .object([
                "protocolVersion": .string("2024-11-05"), "capabilities": .object([:]),
                "serverInfo": .object(["name": .string("fixture"), "version": .string("1")])
            ]))
        case "tools/list":
            entered?.signal()
            if let release { await release.wait() }
            if let listFailure { throw listFailure }
            let type = lock.withLock { () -> String in listCount += 1; return valueType }
            return MCPJSONRPCResponse(id: request.id, result: .object([
                "tools": .array([.object([
                    "name": .string("greet"),
                    "inputSchema": .object([
                        "type": .string("object"),
                        "properties": .object(["value": .object(["type": .string(type)])]),
                        "required": .array([.string("value")])
                    ])
                ])])
            ]))
        case "tools/call":
            let exits = lock.withLock { () -> Bool in
                callCount += 1
                return exitsOnCall
            }
            if exits {
                lock.withLock { exited = true }
                throw MCPClientError.processExited(7)
            }
            return MCPJSONRPCResponse(id: request.id, result: .object([
                "content": .array([.object(["type": .string("text"), "text": .string("fixture")])])
            ]))
        default:
            return MCPJSONRPCResponse(id: request.id, error: MCPJSONRPCError(code: -32601, message: "unknown fixture method"))
        }
    }
}

@Suite("MCP303 Settings canonical discovery consumer")
@MainActor
struct MCP303SettingsDiscoveryConsumerTests {
    @Test("Composer picker read cannot become a second MCP configuration writer")
    func pickerReadDoesNotRetireTheLiveSettingsDiscovery() async throws {
        let fieldRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("arch3-picker-\(UUID().uuidString)", isDirectory: true)
        let environment = [
            RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
            RuntimeIsolationProfile.fieldActivationRootKey: fieldRoot.path
        ]
        let arguments = ["/Applications/MinisCanvas.app/Contents/MacOS/MinisCanvas",
                         RuntimeIsolationProfile.fieldActivationArgument]
        let profile = try RuntimeIsolationProfile.makePackagedField(
            processEnvironment: environment, processArguments: arguments
        )
        defer { try? profile.cleanupDisposableRoots() }
        let keychain = profile.makeKeychainStore()
        let manager = MCPServerManager(fileURL: profile.mcpConfigurationURL, keychain: keychain)
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: profile.settingsDirectory),
            envStore: EnvVarStore(directory: profile.providerConfigurationDirectory, keychain: keychain),
            memoryStore: MemoryStore(directory: profile.memoryDirectory),
            sessionStore: SessionStore(directory: profile.sessionDirectory),
            logManager: LogManager(directory: profile.logDirectory),
            mcpManager: manager,
            skillStore: SkillStore(skillsRoot: profile.minisCoreDirectory.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite("arch3-\(UUID().uuidString)")),
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessStore: ProviderReadinessStore(directory: profile.providerConfigurationDirectory)
        )
        let server = MCPServer(id: "settings", name: "Settings fixture", type: .stdio,
                               command: "never-launched-fake")
        #expect(center.addMCPServer(server))
        #expect(center.setMCPServerAuthorized(id: server.id, authorized: true))
        #expect(center.setMCPToolAuthorized(serverID: server.id, toolName: "greet", authorized: true))
        let transport = MCP303Transport()
        #expect(await center.discoverMCPTools(for: server, clientFactory: {
            MCPClient(server: $0, transport: transport)
        }))
        let live = try #require(manager.discoverySnapshot(serverID: server.id))
        let before = try Data(contentsOf: profile.mcpConfigurationURL)
        let beforeJSON = try #require(JSONSerialization.jsonObject(with: before) as? [String: Any])
        #expect((beforeJSON["discoverySnapshots"] as? [String: Any])?[server.id] != nil)

        // Bind the actual production Composer projection to the same root
        // owners while the Settings transport and discovery remain live.
        let chat = ChatStore(preferencesDefaults: profile.makeUserDefaults(), logManager: center.logManager)
        #expect(ProductionPickerCatalogWiring.bind(chat: chat, center: center, profile: profile))
        chat.loadPickerCatalog()
        #expect(chat.pickerCatalog.contains { $0.id == "plugin:\(server.id)" })
        let refresh = chat.pickerCatalogRefreshLoader
        _ = refresh()
        #expect(manager.discoverySnapshot(serverID: server.id) == live)
        let after = try Data(contentsOf: profile.mcpConfigurationURL)
        #expect(after == before, "The UI picker must only project the live Store; a second manager init must not retire its durable discovery")

        let foreignRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("arch3-foreign-\(UUID().uuidString)", isDirectory: true)
        let foreignProfile = try RuntimeIsolationProfile.makePackagedField(
            processEnvironment: [
                RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                RuntimeIsolationProfile.fieldActivationRootKey: foreignRoot.path
            ], processArguments: arguments
        )
        defer { try? foreignProfile.cleanupDisposableRoots() }
        #expect(!ProductionPickerCatalogWiring.bind(chat: chat, center: center, profile: foreignProfile))
        #expect(chat.pickerCatalogLoader().isEmpty)
        #expect(try Data(contentsOf: profile.mcpConfigurationURL) == before)
    }

    private func fixture(ownedBadge: Bool = false) throws -> (URL, SettingsCenter, MCPServerManager, MCPServer) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp303-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let manager = MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain)
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: root),
            envStore: EnvVarStore(directory: root, keychain: keychain),
            memoryStore: MemoryStore(directory: root),
            sessionStore: SessionStore(directory: root),
            sessionBadgeStore: ownedBadge ? SessionBadgeStore(directory: root.appendingPathComponent("badges")) : .shared,
            logManager: LogManager(directory: root, ringCapacity: 10),
            mcpManager: manager,
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite("mcp303-\(root.lastPathComponent)"))
        )
        let server = MCPServer(id: "settings", name: "Settings fixture", type: .stdio, command: "never-launched-fake")
        #expect(center.addMCPServer(server))
        #expect(center.setMCPServerAuthorized(id: server.id, authorized: true))
        #expect(center.setMCPToolAuthorized(serverID: server.id, toolName: "greet", authorized: true))
        return (root, center, manager, server)
    }

    @Test(arguments: ["timeout", "launch", "protocol", "permission", "stale", "transport"])
    func discoveryFailureProvidesSafeActionableReason(category: String) async throws {
        let (root, center, manager, server) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let sensitive = "private-server-detail " + root.path
        let error: any Error
        let expected: String
        switch category {
        case "timeout":
            error = MCPClientError.timeout(sensitive)
            expected = "请求超时"
        case "launch":
            error = MCPClientError.spawnFailed(sensitive)
            expected = "本地服务器启动失败"
        case "protocol":
            error = MCPClientError.rpcError(code: -1, message: sensitive)
            expected = "服务器响应无效"
        case "permission":
            error = MCPClientError.permissionDenied(sensitive)
            expected = "服务器拒绝了请求"
        case "stale":
            error = MCPDiscoveryError.stale(sensitive)
            expected = "配置或授权已变化"
        default:
            error = MCPDiscoveryError.transportEpochChanged(sensitive)
            expected = "传输会话已变化"
        }
        let transport = MCP303Transport(listFailure: error)
        var visibleMessage: String?
        let succeeded = await center.discoverMCPTools(for: server,
            clientFactory: { MCPClient(server: $0, transport: transport) },
            onFailure: { visibleMessage = $0 })
        #expect(!succeeded)
        let message = try #require(visibleMessage)
        #expect(message.hasPrefix("工具发现失败：") && message.contains(expected))
        #expect(!message.contains(root.path) && !message.contains("private-server-detail"))
        #expect(center.mcpTools(for: server.id).isEmpty && manager.discoverySnapshot(serverID: server.id) == nil)
        #expect(transport.calls == 0)
    }

    @Test("Settings discovery publishes the canonical cache consumed by the next turn")
    func settingsDiscoveryFeedsCanonicalTurnCache() async throws {
        let (root, center, manager, server) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = MCP303Transport()
        let factory: @Sendable (MCPServer) -> MCPClient = { MCPClient(server: $0, transport: transport) }
        #expect(await center.discoverMCPTools(for: server, clientFactory: factory))
        let snapshot = try #require(manager.discoverySnapshot(serverID: server.id))
        #expect(center.mcpTools(for: server.id) == snapshot.tools)
        #expect(manager.authorization(serverID: server.id)?.schemaBindingDigest == snapshot.schemaDigest)
        let registry = MCPToolRegistry(manager: manager, clientFactory: factory)
        defer { registry.disconnectAll() }
        let turn = try registry.snapshotForTurn()
        #expect(try await turn.mcpBoundTools().map(\.fullName) == ["mcp_settings_greet"])
        #expect(transport.lists == 1, "The next turn reuses the manager cache instead of re-discovering")
    }

    @Test("a schema change found in Settings revokes the grant and fences an already frozen turn")
    func settingsSchemaDriftRetiresGrantAndFrozenTurn() async throws {
        let (root, center, manager, server) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = MCP303Transport()
        let factory: @Sendable (MCPServer) -> MCPClient = { MCPClient(server: $0, transport: transport) }
        #expect(await center.discoverMCPTools(for: server, clientFactory: factory))
        let registry = MCPToolRegistry(manager: manager, clientFactory: factory)
        defer { registry.disconnectAll() }
        let oldTurn = try registry.snapshotForTurn()
        #expect(try await oldTurn.mcpBoundTools().count == 1)
        transport.replaceSchema(with: "integer")
        #expect(await center.discoverMCPTools(for: server, clientFactory: factory))
        #expect(!center.isMCPToolAuthorized(serverID: server.id, toolName: "greet"))
        #expect(try await oldTurn.mcpBoundTools().isEmpty)
        await #expect(throws: MCPClientError.toolNotFound("mcp_settings_greet")) {
            _ = try await oldTurn.callMCPTool(fullName: "mcp_settings_greet", arguments: ["value": "old"])
        }
        #expect(transport.calls == 0)
    }

    @Test("a disabled Settings generation cannot publish a late tools list")
    func disableDuringSettingsDiscoveryRejectsLatePublication() async throws {
        let (root, center, manager, server) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = MCP303Signal(), release = MCP303Signal()
        defer { release.signal() }
        let transport = MCP303Transport(entered: entered, release: release)
        let task = Task { await center.discoverMCPTools(for: server, clientFactory: { MCPClient(server: $0, transport: transport) }) }
        for _ in 0..<100 where !entered.isSignaled { try await Task.sleep(for: .milliseconds(10)) }
        #expect(entered.isSignaled)
        #expect(center.toggleMCPServer(id: server.id, enabled: false))
        release.signal()
        #expect(await task.value == false)
        #expect(center.mcpTools(for: server.id).isEmpty)
        #expect(manager.discoverySnapshot(serverID: server.id) == nil)
    }

    @Test("cancelled Settings discovery cannot publish a list or canonical snapshot")
    func cancellationDuringSettingsDiscoveryRejectsPublication() async throws {
        let (root, center, manager, server) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = MCP303Signal(), release = MCP303Signal()
        defer { release.signal() }
        let transport = MCP303Transport(entered: entered, release: release)
        let task = Task { await center.discoverMCPTools(for: server, clientFactory: { MCPClient(server: $0, transport: transport) }) }
        for _ in 0..<100 where !entered.isSignaled { try await Task.sleep(for: .milliseconds(10)) }
        #expect(entered.isSignaled)
        task.cancel()
        release.signal()
        #expect(await task.value == false)
        #expect(center.mcpTools(for: server.id).isEmpty)
        #expect(manager.discoverySnapshot(serverID: server.id) == nil)
    }

    @Test("cancelling an older refresh cannot erase its replacement projection")
    func cancelledOlderRefreshCannotEraseNewerProjection() async throws {
        let (root, center, manager, server) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = MCP303Signal(), release = MCP303Signal()
        defer { release.signal() }
        let oldTransport = MCP303Transport(entered: entered, release: release)
        let old = Task { await center.discoverMCPTools(for: server, clientFactory: { MCPClient(server: $0, transport: oldTransport) }) }
        for _ in 0..<100 where !entered.isSignaled { try await Task.sleep(for: .milliseconds(10)) }
        #expect(entered.isSignaled)
        let newerTransport = MCP303Transport()
        #expect(await center.discoverMCPTools(for: server, clientFactory: { MCPClient(server: $0, transport: newerTransport) }))
        let accepted = try #require(manager.discoverySnapshot(serverID: server.id))
        old.cancel()
        release.signal()
        #expect(await old.value == false)
        #expect(center.mcpTools(for: server.id) == accepted.tools)
        #expect(manager.discoverySnapshot(serverID: server.id) == accepted)
    }

    @Test func obsoleteDiscoveryFailureCannotReplaceCurrentVisibleResult() async throws {
        let (root, center, _, server) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = MCP303Signal(), release = MCP303Signal()
        defer { release.signal() }
        let oldTransport = MCP303Transport(entered: entered, release: release,
            listFailure: MCPClientError.timeout("private-old-failure"))
        var staleFailurePublished = false
        let old = Task {
            await center.discoverMCPTools(for: server,
                clientFactory: { MCPClient(server: $0, transport: oldTransport) },
                onFailure: { _ in staleFailurePublished = true })
        }
        for _ in 0..<100 where !entered.isSignaled { try await Task.sleep(for: .milliseconds(10)) }
        #expect(entered.isSignaled)
        let currentTransport = MCP303Transport()
        #expect(await center.discoverMCPTools(for: server,
            clientFactory: { MCPClient(server: $0, transport: currentTransport) }))
        let current = center.mcpTools(for: server.id)
        release.signal()
        #expect(await old.value == false)
        #expect(!staleFailurePublished)
        #expect(center.mcpTools(for: server.id) == current)
    }

    // Capture the actual controlled Provider arguments, not a reconstruction
    // from tools/list or from the assertions. The owned root stays retained.
    private func retainProviderRuntime2932(
        root: URL, stage: String, conversationID: String, requestedTurnID: Int, provider: ProductionMCPProvider,
        discoveryBefore: MCPDiscoverySnapshot?, manager: MCPServerManager,
        server: MCPServer, ledger: ToolExecutionFactLedger, transport: MCP303Transport
    ) throws {
        let directory = root.appendingPathComponent("runtime-values2932", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        func object<T: Encodable>(_ value: T) throws -> Any {
            try JSONSerialization.jsonObject(with: encoder.encode(value), options: [.fragmentsAllowed])
        }
        let definitions = provider.receivedToolDefinitions.map { request in
            request.map { definition -> [String: Any] in
                ["openAIFunction": definition.openAIFunctionDict,
                 "propertyOrdering": definition.propertyOrdering.map { $0 as Any } ?? NSNull()]
            }
        }
        let values: [String: Any] = [
            "requirement": "D-MCP-03", "stage": stage, "ownedRoot": root.path,
            "testRunID": ProcessInfo.processInfo.environment["MINISCANVAS_TEST_RUN_ID"] ?? "NOT_SET",
            "requestedConversationID": conversationID, "requestedTurnID": requestedTurnID,
            "serverID": server.id, "requestedToolName": provider.requestedToolName,
            "providerName": provider.name, "modelID": provider.model.id,
            "discoveryBeforeProvider": try object(discoveryBefore),
            "discoveryAfterProvider": try object(manager.discoverySnapshot(serverID: server.id)),
            "actualProviderToolDefinitions": definitions,
            "actualToolExecutionFacts": try object(ledger.facts),
            "actualPendingReceipts": try object(ledger.pendingReceipts),
            "transportListCount": transport.lists, "transportCallCount": transport.calls
        ]
        let artifact = directory.appendingPathComponent("\(stage).json")
        try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
            .write(to: artifact, options: .atomic)
        try Data(contentsOf: root.appendingPathComponent("mcps.json"))
            .write(to: directory.appendingPathComponent("\(stage)-configuration.raw.json"), options: .atomic)
        print("TASK2932_MCP03_RUNTIME stage=\(stage) root=\(root.path) artifact=\(artifact.path) receipts=\(ledger.facts.map(\.receiptID))")
    }

    private func retainMCPRefusal2932(
        _ error: Error, root: URL, toolName: String,
        ledger: ToolExecutionFactLedger, transport: MCP303Transport
    ) throws {
        let directory = root.appendingPathComponent("runtime-values2932", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let actual = error as NSError
        let values: [String: Any] = ["ownedRoot": root.path, "toolName": toolName,
            "errorType": String(reflecting: type(of: error)), "error": error.localizedDescription,
            "errorDomain": actual.domain, "errorCode": actual.code,
            "transportCallCount": transport.calls, "durableReceiptIDs": ledger.facts.map(\.receiptID)]
        let artifact = directory.appendingPathComponent("disabled-direct-refusal.json")
        try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
            .write(to: artifact, options: .atomic)
        print("TASK2932_MCP03_REFUSAL root=\(root.path) artifact=\(artifact.path)")
    }

    @Test("Settings discovery reaches actual Provider schema and dynamic calls in cached fresh turns")
    func settingsDiscoveryFeedsProviderCatalogAndDynamicCallAcrossTurns() async throws {
        let (root, center, manager, server) = try fixture(ownedBadge: true)
        print("TASK2932_MCP03_BEGIN case=catalog593 root=\(root.path)")
        let transport = MCP303Transport()
        let factory: @Sendable (MCPServer) -> MCPClient = { MCPClient(server: $0, transport: transport) }
        #expect(await center.discoverMCPTools(for: server, clientFactory: factory))
        let discovery = try #require(manager.discoverySnapshot(serverID: server.id))
        let fullName = MCPBoundTool.makeFullName(serverID: server.id, toolName: "greet")
        let registry = MCPToolRegistry(manager: manager, clientFactory: factory)
        defer { registry.disconnectAll() }
        let ledger = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts593.json"))

        func runFreshTurn(_ turnID: Int, callsTool: Bool) async throws -> ProductionMCPProvider {
            let discoveryBefore2932 = manager.discoverySnapshot(serverID: server.id)
            // Same producer-owned snapshot feeds the catalog and dynamic executor.
            // The transport and Provider are synthetic; these production consumers are not replaced.
            let frozen = try registry.snapshotForTurn()
            let bridge = TurnScopedMCPToolBridge(base: frozen)
            let builtin = BuiltinToolExecutor(allowedRoot: root, mcpBridge: bridge)
            let createdAt = Date()
            let goal = GoalEnvelope(
                scopeID: "test:mcp-settings593",
                allowedCapabilities: builtin.registeredToolNames,
                fileRoots: [root.path], budget: 10,
                deadline: createdAt.addingTimeInterval(60), concurrencyLimit: 1,
                autonomyLevel: .l1, createdAt: createdAt
            )
            let lease = AutonomyLease(goalID: goal.goalID, scopeID: goal.scopeID,
                                      issuedAt: createdAt, expiresAt: goal.deadline)
            let executor = PolicyEnforcedToolExecutor(base: builtin, goal: goal, lease: lease,
                                                       capabilityResolver: builtin)
            let engine = AgentLoopChatEngine(toolExecutor: executor, maxIterations: 3,
                                             approvalDelegate: ProductionApprovalDelegate(),
                                             mcpBridge: bridge, toolExecutionFactLedger: ledger)
            let provider = ProductionMCPProvider()
            provider.requestedToolName = fullName
            provider.returnsPlainResponse = !callsTool
            let conversationID2932 = "mcp-settings593-\(turnID)"
            let localTurnID2932 = 1
            let stream = try await engine.streamReply(
                provider: provider, history: [ChatMessageUI(role: .user, content: "synthetic MCP request")],
                systemPrompt: "synthetic MCP fixture", maxTokens: 128,
                // This standalone engine owns a fresh controller starting at local turn 1.
                // Distinct conversations also keep the durable invocation identities distinct.
                conversationID: conversationID2932, authorizedSessionReadSessionID: nil, turnID: localTurnID2932
            )
            var output = ""
            for try await event in stream {
                if case .textDelta(let text) = event { output += text }
            }
            #expect(output == (callsTool ? "完成" : "plain"))
            try retainProviderRuntime2932(root: root, stage: "catalog593-turn-\(turnID)",
                conversationID: conversationID2932, requestedTurnID: localTurnID2932, provider: provider,
                discoveryBefore: discoveryBefore2932, manager: manager, server: server,
                ledger: ledger, transport: transport)
            return provider
        }

        for turnID in [1, 2] {
            let provider = try await runFreshTurn(turnID, callsTool: true)
            #expect(provider.receivedToolDefinitions.count == 2)
            for definitions in provider.receivedToolDefinitions {
                let definition = try #require(definitions.first { $0.name == fullName })
                #expect(definition.parameters["value"]?.type == .string)
                #expect(definition.required == ["value"])
                #expect(definitions.filter { $0.name.hasPrefix("mcp_") }.map(\.name) == [fullName])
            }
            let bound = try await registry.snapshotForTurn().mcpBoundTools()
            #expect(bound.map(\.serverID) == [server.id])
            #expect(bound.map(\.tool) == discovery.tools)
            #expect(manager.discoverySnapshot(serverID: server.id) == discovery)
            #expect(transport.lists == 1, "Both real Provider turns reuse the same canonical revision")
            #expect(transport.calls == turnID)
        }

        #expect(center.toggleMCPServer(id: server.id, enabled: false))
        let disabled = try await runFreshTurn(3, callsTool: false)
        #expect(disabled.receivedToolDefinitions.count == 1)
        #expect(disabled.receivedToolDefinitions.allSatisfy { definitions in
            !definitions.contains { $0.name == fullName }
        })
        let disabledTurn = try registry.snapshotForTurn()
        await #expect(throws: MCPClientError.toolNotFound(fullName)) {
            do {
                _ = try await disabledTurn.callMCPTool(fullName: fullName, arguments: ["value": "denied"])
            } catch {
                try retainMCPRefusal2932(error, root: root, toolName: fullName,
                    ledger: ledger, transport: transport)
                throw error
            }
        }
        #expect(transport.calls == 2, "A disabled next turn neither advertises nor calls the server")
        #expect(transport.lists == 1)
        #expect(manager.discoverySnapshot(serverID: server.id) == nil)

        #expect(center.toggleMCPServer(id: server.id, enabled: true))
        #expect(center.setMCPServerAuthorized(id: server.id, authorized: true))
        #expect(center.setMCPToolAuthorized(serverID: server.id, toolName: "greet", authorized: true))
        #expect(await center.discoverMCPTools(for: server, clientFactory: factory))
        let rediscovery = try #require(manager.discoverySnapshot(serverID: server.id))
        #expect(rediscovery.serverID == discovery.serverID)
        #expect(rediscovery.revision > discovery.revision)
        #expect(rediscovery.schemaDigest == discovery.schemaDigest)
        let reenabled = try await runFreshTurn(4, callsTool: true)
        #expect(reenabled.receivedToolNames.count == 2)
        #expect(reenabled.receivedToolNames.allSatisfy { $0.contains(fullName) })
        #expect(transport.calls == 3)
        #expect(transport.lists == 2)
    }

    @Test("an observed server exit retires its cached schema before the next Provider turn")
    func exitedServerLeavesNextProviderCatalogUntilExplicitRediscovery() async throws {
        let (root, center, manager, server) = try fixture(ownedBadge: true)
        print("TASK2932_MCP03_BEGIN case=exit2504 root=\(root.path)")
        let transport = MCP303Transport()
        let factory: @Sendable (MCPServer) -> MCPClient = { MCPClient(server: $0, transport: transport) }
        #expect(await center.discoverMCPTools(for: server, clientFactory: factory))
        let original = try #require(manager.discoverySnapshot(serverID: server.id))
        let fullName = MCPBoundTool.makeFullName(serverID: server.id, toolName: "greet")
        let registry = MCPToolRegistry(manager: manager, clientFactory: factory)
        defer { registry.disconnectAll() }
        let ledger = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts2504.json"))

        func providerTurn(_ turn: Int, callsTool: Bool) async throws -> ProductionMCPProvider {
            let discoveryBefore2932 = manager.discoverySnapshot(serverID: server.id)
            let frozen = try registry.snapshotForTurn()
            let bridge = TurnScopedMCPToolBridge(base: frozen)
            let builtin = BuiltinToolExecutor(allowedRoot: root, mcpBridge: bridge)
            let createdAt = Date()
            let goal = GoalEnvelope(scopeID: "test:mcp-exit2504",
                allowedCapabilities: builtin.registeredToolNames, fileRoots: [root.path], budget: 10,
                deadline: createdAt.addingTimeInterval(60), concurrencyLimit: 1,
                autonomyLevel: .l1, createdAt: createdAt)
            let lease = AutonomyLease(goalID: goal.goalID, scopeID: goal.scopeID,
                issuedAt: createdAt, expiresAt: goal.deadline)
            let executor = PolicyEnforcedToolExecutor(base: builtin, goal: goal, lease: lease,
                capabilityResolver: builtin)
            let engine = AgentLoopChatEngine(toolExecutor: executor, maxIterations: 3,
                approvalDelegate: ProductionApprovalDelegate(), mcpBridge: bridge,
                toolExecutionFactLedger: ledger)
            let provider = ProductionMCPProvider()
            provider.requestedToolName = fullName
            provider.returnsPlainResponse = !callsTool
            let conversationID2932 = "mcp-exit2504-\(turn)"
            let localTurnID2932 = 1
            let stream = try await engine.streamReply(provider: provider,
                history: [ChatMessageUI(role: .user, content: "synthetic exited server")],
                systemPrompt: "synthetic MCP fixture", maxTokens: 128,
                conversationID: conversationID2932, authorizedSessionReadSessionID: nil, turnID: localTurnID2932)
            for try await _ in stream { }
            try retainProviderRuntime2932(root: root, stage: "exit2504-turn-\(turn)",
                conversationID: conversationID2932, requestedTurnID: localTurnID2932, provider: provider,
                discoveryBefore: discoveryBefore2932, manager: manager, server: server,
                ledger: ledger, transport: transport)
            return provider
        }

        transport.exitOnNextCall()
        let failed = try await providerTurn(1, callsTool: true)
        #expect(failed.receivedToolDefinitions.count == 2)
        let advertised = try #require(failed.receivedToolDefinitions.first?.first { $0.name == fullName })
        #expect(advertised.parameters["value"]?.type == .string)
        #expect(transport.calls == 1)
        #expect(manager.discoverySnapshot(serverID: server.id) == nil,
            "A known-dead server must not keep its old tools/list in the next model request")

        let next = try await providerTurn(2, callsTool: false)
        #expect(next.receivedToolDefinitions.count == 1)
        #expect(next.receivedToolDefinitions[0].allSatisfy { $0.name != fullName })
        #expect(try await registry.snapshotForTurn().mcpBoundTools().isEmpty)
        #expect(transport.calls == 1)

        // A later explicit, same-schema rediscovery may rebind the existing
        // grant; an observed failure must neither mint nor revoke that grant.
        transport.recoverExitedFixture()
        #expect(await center.discoverMCPTools(for: server, clientFactory: factory))
        let rebound = try #require(manager.discoverySnapshot(serverID: server.id))
        #expect(rebound.schemaDigest == original.schemaDigest)
        #expect(transport.lists >= 2, "Recovery requires a real new tools/list response")
        #expect(rebound != original, "A same-schema reconnect still has a new publication identity")
        let retiredOldPublication = try manager.retireDiscoveryAfterFailedRefresh(serverID: server.id, expected: original)
        #expect(!retiredOldPublication,
            "A late failure from the old connection must not retire a newer successful discovery")
        #expect(manager.discoverySnapshot(serverID: server.id) == rebound)
        let recovered = try await providerTurn(3, callsTool: false)
        #expect(recovered.receivedToolDefinitions[0].contains { $0.name == fullName })
    }

    @Test("Real dynamic executor rejects stale schema, unknown name, changed identity and revoked next turns with zero calls",
          arguments: ["schema", "unknown", "changed-identity", "revoked"])
    func settingsDiscoveryRejectionsReachDynamicExecutorWithoutExternalCalls(_ rejection: String) async throws {
        let (root, center, manager, server) = try fixture(ownedBadge: true)
        let transport = MCP303Transport()
        let factory: @Sendable (MCPServer) -> MCPClient = { MCPClient(server: $0, transport: transport) }
        #expect(await center.discoverMCPTools(for: server, clientFactory: factory))
        let registry = MCPToolRegistry(manager: manager, clientFactory: factory)
        defer { registry.disconnectAll() }
        let fullName = MCPBoundTool.makeFullName(serverID: server.id, toolName: "greet")
        let originalTurn = try registry.snapshotForTurn()
        #expect(try await originalTurn.mcpBoundTools().map(\.fullName) == [fullName])
        var rejectedName = fullName
        switch rejection {
        case "schema":
            transport.replaceSchema(with: "integer")
            #expect(await center.discoverMCPTools(for: server, clientFactory: factory))
            #expect(!center.isMCPToolAuthorized(serverID: server.id, toolName: "greet"))
            #expect(try await originalTurn.mcpBoundTools().isEmpty)
        case "unknown":
            rejectedName = "mcp_settings_missing"
        case "changed-identity":
            let replacement = MCPServer(id: server.id, name: server.name, type: .stdio,
                                        command: "never-launched-replacement")
            #expect(center.addMCPServer(replacement))
            #expect(!center.isMCPServerAuthorized(id: server.id))
            #expect(manager.discoverySnapshot(serverID: server.id) == nil)
        case "revoked":
            #expect(center.setMCPServerAuthorized(id: server.id, authorized: false))
            #expect(manager.discoverySnapshot(serverID: server.id) == nil)
        default:
            Issue.record("unsupported synthetic rejection case")
        }
        let nextTurn = try registry.snapshotForTurn()
        let bridge = TurnScopedMCPToolBridge(base: nextTurn)
        let nextNames = try await bridge.mcpBoundTools().map(\.fullName)
        #expect(!nextNames.contains(rejectedName))
        if rejection != "unknown" { #expect(nextNames.isEmpty) }
        await Self.expectDynamicRejection(root: root, bridge: bridge, name: rejectedName)
        #expect(transport.calls == 0, "The real dynamic name fence must reject before tools/call")
    }

    // Keep the non-Sendable production executor local to its nonisolated execution
    // context. Only the existing Sendable URL/bridge/name cross the MainActor boundary.
    private nonisolated static func expectDynamicRejection(
        root: URL, bridge: TurnScopedMCPToolBridge, name: String
    ) async {
        let executor = BuiltinToolExecutor(allowedRoot: root, mcpBridge: bridge)
        await #expect(throws: ToolExecutorError.unknownTool(name)) {
            _ = try await executor.execute(name: name, input: ["value": "synthetic denied"])
        }
        #expect(!executor.registeredToolNames.contains(name))
    }

}
