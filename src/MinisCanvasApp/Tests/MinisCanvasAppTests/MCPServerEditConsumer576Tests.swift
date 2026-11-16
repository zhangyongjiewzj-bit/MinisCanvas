import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("MCP576 Settings server edit production consumer", .serialized)
@MainActor
struct MCPServerEditConsumer576Tests {
    @Test func headerReplacementKeepsSecretsOutOfFormAndRejectsAmbiguity() throws {
        let original = MCPServer(id: "headers", name: "Headers", type: .http,
            url: "https://example.invalid/mcp", headers: ["Authorization": "Bearer synthetic"])
        var draft = MCPServerEditDraft(existing: original)
        #expect(draft.headerRows.first?.value == "")
        #expect(draft.server()?.headers == original.headers)
        draft.headerRows[0].value = "Bearer replacement"
        #expect(draft.server()?.headers["Authorization"] == "Bearer replacement")
        draft.headerRows.append(MCPHeaderEditRow(name: "authorization", value: "duplicate"))
        #expect(draft.server() == nil)
        draft.headerRows.removeAll()
        #expect(draft.server()?.headers.isEmpty == true)
    }

    @Test func pastedCommandLineUsesQuotedExecutableAndPreservesExistingArguments() throws {
        let original = MCPServer(id: "command576", name: "Synthetic", type: .stdio,
            command: "/synthetic/original tool", args: ["--existing", "kept argument"],
            env: ["FIXTURE_VALUE": "preserved value"])
        var draft = MCPServerEditDraft(existing: original)
        draft.command = #""/synthetic/tool with spaces" --mode "two words" 'literal"quote'"#
        let saved = try #require(draft.server())
        #expect(saved.command == "/synthetic/tool with spaces")
        #expect(saved.args == ["--mode", "two words", "literal\"quote", "--existing", "kept argument"])
        #expect(saved.env == original.env)
    }

    @Test func pastedStdioCommandKeepsEmptyArgumentsAndRejectsUnclosedQuotes() throws {
        var draft = MCPServerEditDraft()
        draft.id = "quoted576"
        draft.name = "Synthetic"
        draft.command = #"fixture "" --flag"#
        draft.argsText = #"'' "two words""#
        let saved = try #require(draft.server())
        #expect(saved.args == ["", "--flag", "", "two words"])
        draft.command = #"fixture "unfinished"#
        #expect(!draft.isValid)
        #expect(draft.server() == nil)
        draft.command = "fixture"
        draft.argsText = #"'unfinished"#
        #expect(!draft.isValid)
        #expect(draft.server() == nil)
    }

    @Test func absoluteCommandLineSplitsAndExistingExecutableWithSpacesStaysWhole() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }

        let executable = root.appendingPathComponent("runner")
        let spacedExecutable = root.appendingPathComponent("runner with spaces")
        for file in [executable, spacedExecutable] {
            try Data().write(to: file)
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }

        var draft = MCPServerEditDraft()
        draft.id = "absolute576"
        draft.name = "Synthetic"
        draft.command = executable.path + #" --flag "" "two words""#
        #expect(draft.server()?.command == executable.path)
        #expect(draft.server()?.args == ["--flag", "", "two words"])
        draft.command = spacedExecutable.path
        #expect(draft.server()?.command == spacedExecutable.path)
        #expect(draft.server()?.args == [])
        draft.command = root.appendingPathComponent("missing tool").path + " --flag"
        #expect(!draft.isValid)
        #expect(draft.server() == nil)
    }

    @Test func editPreservesIdentityAndUntouchedConfiguration() throws {
        let original = MCPServer(id: "edit576", name: "Original", type: .stdio,
            command: "fixture-never-spawned", args: ["--path", "folder with spaces"],
            env: ["FIXTURE_TOKEN": "synthetic-only"], headers: ["X-Fixture": "synthetic-header"],
            timeoutSeconds: 17)
        var draft = MCPServerEditDraft(existing: original)
        #expect(draft.envText.isEmpty)
        #expect(draft.server() == original)
        draft.name = "Edited"
        draft.envText = "DEBUG=1"
        let edited = try #require(draft.server())
        #expect(edited.id == original.id)
        #expect(edited.args == original.args)
        #expect(edited.env == ["FIXTURE_TOKEN": "synthetic-only", "DEBUG": "1"])
        #expect(edited.headers == original.headers)
        #expect(edited.timeoutSeconds == 17)
        draft.id = "different"
        #expect(draft.server() == nil)
        draft.id = original.id
        draft.envText = "malformed"
        #expect(draft.server() == nil)
    }

    @Test func editSaveDisableEnableAndReopenFeedCanonicalNextTurn() async throws {
        let fixture = try Fixture()
        let center = fixture.center
        var draft = MCPServerEditDraft()
        draft.id = "edit576"
        draft.name = "Original"
        draft.command = "fixture-never-spawned"
        #expect(draft.save(to: center))
        let original = try #require(center.mcpManager.server(id: draft.id))
        #expect(center.setMCPServerAuthorized(id: original.id, authorized: true))
        #expect(center.setMCPToolAuthorized(serverID: original.id, toolName: "echo", authorized: true))
        let transport = Transport()
        let factory: @Sendable (MCPServer) -> MCPClient = { MCPClient(server: $0, transport: transport) }
        #expect(await center.discoverMCPTools(for: original, clientFactory: factory))
        let registry = MCPToolRegistry(manager: center.mcpManager, clientFactory: factory)
        defer { registry.disconnectAll() }
        let oldTurn = try registry.snapshotForTurn()
        #expect(try await oldTurn.mcpBoundTools().map(\.fullName) == ["mcp_edit576_echo"])
        #expect(transport.lists == 1)

        var edit = MCPServerEditDraft(existing: original)
        edit.name = "Edited"
        edit.command = "fixture-edited-never-spawned"
        #expect(edit.save(to: center))
        #expect(center.mcpServers.count == 1)
        #expect(center.mcpServers.first?.name == "Edited")
        #expect(center.mcpManager.discoverySnapshot(serverID: original.id) == nil)
        #expect(!center.isMCPServerAuthorized(id: original.id))
        // An in-flight turn keeps its captured configuration. The edit must
        // fence the next turn; schema drift has its separate shared-lineage fence.
        #expect(try await oldTurn.mcpBoundTools().map(\.fullName) == ["mcp_edit576_echo"])
        let editedTurnBeforeReauthorization = try registry.snapshotForTurn()
        #expect(try await editedTurnBeforeReauthorization.mcpBoundTools().isEmpty)
        await #expect(throws: MCPClientError.toolNotFound("mcp_edit576_echo")) {
            _ = try await editedTurnBeforeReauthorization.callMCPTool(fullName: "mcp_edit576_echo", arguments: nil)
        }
        #expect(transport.calls == 0)

        let reopened = MCPServerManager(fileURL: fixture.fileURL, keychain: fixture.keychain)
        #expect(reopened.listServers() == center.mcpServers)
        #expect(!reopened.isServerAuthorized(try #require(reopened.server(id: original.id))))
        #expect(center.setMCPServerAuthorized(id: original.id, authorized: true))
        #expect(center.setMCPToolAuthorized(serverID: original.id, toolName: "echo", authorized: true))
        let current = try #require(center.mcpManager.server(id: original.id))
        #expect(await center.discoverMCPTools(for: current, clientFactory: factory))
        let nextTurn = try registry.snapshotForTurn()
        #expect(try await nextTurn.mcpBoundTools().map(\.fullName) == ["mcp_edit576_echo"])
        #expect(transport.lists == 2, "new turn consumes the Settings canonical discovery cache")
        #expect(center.toggleMCPServer(id: current.id, enabled: false))
        #expect(center.mcpTools(for: current.id).isEmpty)
        #expect(try await nextTurn.mcpBoundTools().map(\.fullName) == ["mcp_edit576_echo"])
        let disabledTurn = try registry.snapshotForTurn()
        #expect(try await disabledTurn.mcpBoundTools().isEmpty)
        await #expect(throws: MCPClientError.toolNotFound("mcp_edit576_echo")) {
            _ = try await disabledTurn.callMCPTool(fullName: "mcp_edit576_echo", arguments: nil)
        }
        #expect(transport.calls == 0)
        #expect(center.toggleMCPServer(id: current.id, enabled: true))
        #expect(center.mcpManager.discoverySnapshot(serverID: current.id) == nil)
        let enabled = try #require(center.mcpManager.server(id: current.id))
        #expect(enabled.enabled)
        #expect(center.setMCPServerAuthorized(id: enabled.id, authorized: true))
        #expect(center.setMCPToolAuthorized(serverID: enabled.id, toolName: "echo", authorized: true))
        #expect(await center.discoverMCPTools(for: enabled, clientFactory: factory))
        let enabledTurn = try registry.snapshotForTurn()
        #expect(try await enabledTurn.mcpBoundTools().map(\.fullName) == ["mcp_edit576_echo"])
        #expect(transport.lists == 3, "reenable requires fresh canonical discovery before the next turn")
        let enabledReopened = MCPServerManager(fileURL: fixture.fileURL, keychain: fixture.keychain)
        #expect(enabledReopened.listServers() == center.mcpServers)
        #expect(enabledReopened.server(id: current.id)?.enabled == true)
        #expect(transport.calls == 0)
    }

    @Test func rejectedOrUnsubmittedDraftNeverOverwritesCurrentServer() throws {
        let fixture = try Fixture()
        let original = MCPServer(id: "edit576", name: "Original", command: "never-spawned")
        #expect(fixture.center.addMCPServer(original))
        var draft = MCPServerEditDraft(existing: original)
        draft.name = "Unsubmitted"
        #expect(fixture.center.mcpManager.server(id: original.id) == original)
        var collision = MCPServerEditDraft()
        collision.id = original.id
        collision.name = "Collision"
        collision.command = "never-spawned"
        #expect(!collision.save(to: fixture.center))
        var newer = original
        newer.name = "Newer"
        #expect(fixture.center.addMCPServer(newer))
        #expect(!draft.save(to: fixture.center))
        #expect(fixture.center.mcpManager.server(id: original.id) == newer)
        #expect(fixture.center.removeMCPServer(id: original.id))
        #expect(!draft.save(to: fixture.center))
        #expect(fixture.center.mcpServers.isEmpty)
    }

    @MainActor
    private struct Fixture {
        let keychain: KeychainStore
        let fileURL: URL
        let center: SettingsCenter
        init() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp576-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            keychain = KeychainStore(backing: InMemoryKeychainBacking())
            fileURL = root.appendingPathComponent("mcps.json")
            center = SettingsCenter(
                settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
                envStore: EnvVarStore(directory: root.appendingPathComponent("provider"), keychain: keychain),
                memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
                sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
                logManager: LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 10),
                mcpManager: MCPServerManager(fileURL: fileURL, keychain: keychain),
                skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
                usageStore: UsageStore(domain: .suite("mcp576-" + UUID().uuidString)))
        }
    }

    private final class Transport: MCPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var listCount = 0
        private var callCount = 0
        var lists: Int { lock.withLock { listCount } }
        var calls: Int { lock.withLock { callCount } }
        func start() async throws {}
        func notify(_ notification: MCPJSONRPCNotification) throws {}
        func stop() {}
        func send(_ request: MCPJSONRPCRequest) async throws -> MCPJSONRPCResponse {
            switch request.method {
            case "initialize":
                return MCPJSONRPCResponse(id: request.id, result: .object([
                    "protocolVersion": .string("2024-11-05"), "capabilities": .object([:]),
                    "serverInfo": .object(["name": .string("fixture"), "version": .string("1")])]))
            case "tools/list":
                lock.withLock { listCount += 1 }
                return MCPJSONRPCResponse(id: request.id, result: .object([
                    "tools": .array([.object(["name": .string("echo"),
                        "inputSchema": .object(["type": .string("object")])])])]))
            case "tools/call":
                lock.withLock { callCount += 1 }
                return MCPJSONRPCResponse(id: request.id, result: .object([
                    "content": .array([.object(["type": .string("text"), "text": .string("fixture")])])]))
            default:
                return MCPJSONRPCResponse(id: request.id, error: MCPJSONRPCError(code: -32601, message: "fixture unsupported"))
            }
        }
    }
}
