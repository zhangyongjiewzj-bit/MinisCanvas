import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("MCP tool authorization settings")
@MainActor
struct MCPToolAuthorizationSettingsContractTests {
    @Test("SettingsCenter persists and revokes individual MCP tool grants")
    func persistsAndRevokesIndividualToolGrant() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCP-tool-grants-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let server = MCPServer(
            id: "files",
            name: "Files",
            type: .stdio,
            command: "tool-server"
        )
        let manager = MCPServerManager(
            fileURL: root.appendingPathComponent("mcps.json")
        )
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: root),
            envStore: EnvVarStore(directory: root),
            memoryStore: MemoryStore(directory: root),
            sessionStore: SessionStore(directory: root),
            logManager: LogManager(directory: root, ringCapacity: 10),
            mcpManager: manager
        )

        #expect(center.addMCPServer(server))
        #expect(center.setMCPServerAuthorized(id: server.id, authorized: true))
        #expect(
            center.setMCPToolAuthorized(
                serverID: server.id,
                toolName: "read_file",
                authorized: true
            )
        )
        #expect(center.isMCPToolAuthorized(serverID: server.id, toolName: "read_file"))

        let reloaded = MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"))
        #expect(reloaded.isToolAuthorized(serverID: server.id, toolName: "read_file"))

        #expect(
            center.setMCPToolAuthorized(
                serverID: server.id,
                toolName: "read_file",
                authorized: false
            )
        )
        #expect(!center.isMCPToolAuthorized(serverID: server.id, toolName: "read_file"))
        #expect(
            !center.setMCPToolAuthorized(
                serverID: server.id,
                toolName: " \n\t ",
                authorized: true
            )
        )
        #expect(!center.isMCPToolAuthorized(serverID: server.id, toolName: " \n\t "))
    }

    @Test("Revoked grants remain denied after manager reconnect")
    func revokedGrantRemainsDeniedAfterManagerReconnect() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCP-grant-reconnect-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let server = MCPServer(
            id: "files",
            name: "Files",
            type: .stdio,
            command: "tool-server"
        )
        let authorizationURL = root.appendingPathComponent("mcps.json")
        let manager = MCPServerManager(fileURL: authorizationURL)
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: root),
            envStore: EnvVarStore(directory: root),
            memoryStore: MemoryStore(directory: root),
            sessionStore: SessionStore(directory: root),
            logManager: LogManager(directory: root, ringCapacity: 10),
            mcpManager: manager
        )

        #expect(center.addMCPServer(server))
        #expect(center.setMCPServerAuthorized(id: server.id, authorized: true))
        #expect(
            center.setMCPToolAuthorized(
                serverID: server.id,
                toolName: "read_file",
                authorized: true
            )
        )
        #expect(
            MCPServerManager(fileURL: authorizationURL)
                .isToolAuthorized(serverID: server.id, toolName: "read_file")
        )

        #expect(
            center.setMCPToolAuthorized(
                serverID: server.id,
                toolName: "read_file",
                authorized: false
            )
        )
        let afterToolRevoke = MCPServerManager(fileURL: authorizationURL)
        #expect(afterToolRevoke.isServerAuthorized(server))
        #expect(!afterToolRevoke.isToolAuthorized(serverID: server.id, toolName: "read_file"))

        #expect(center.setMCPServerAuthorized(id: server.id, authorized: false))
        let afterServerRevoke = MCPServerManager(fileURL: authorizationURL)
        #expect(!afterServerRevoke.isServerAuthorized(server))
        #expect(!afterServerRevoke.isToolAuthorized(serverID: server.id, toolName: "read_file"))
    }

    @Test("Changed server identity denies stale authorization")
    func changedServerIdentityDeniesStaleAuthorization() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCP-identity-fence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let original = MCPServer(
            id: "files",
            name: "Files",
            type: .stdio,
            command: "tool-server-v1"
        )
        let replacement = MCPServer(
            id: original.id,
            name: original.name,
            type: original.type,
            command: "tool-server-v2"
        )
        let authorizationURL = root.appendingPathComponent("mcps.json")
        let manager = MCPServerManager(fileURL: authorizationURL)
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: root),
            envStore: EnvVarStore(directory: root),
            memoryStore: MemoryStore(directory: root),
            sessionStore: SessionStore(directory: root),
            logManager: LogManager(directory: root, ringCapacity: 10),
            mcpManager: manager
        )

        #expect(center.addMCPServer(original))
        #expect(center.setMCPServerAuthorized(id: original.id, authorized: true))
        #expect(
            center.setMCPToolAuthorized(
                serverID: original.id,
                toolName: "read_file",
                authorized: true
            )
        )
        #expect(manager.isServerAuthorized(original))
        #expect(!manager.isServerAuthorized(replacement))

        #expect(center.addMCPServer(replacement))
        let reconnected = MCPServerManager(fileURL: authorizationURL)
        #expect(reconnected.server(id: original.id) == replacement)
        #expect(reconnected.authorization(serverID: original.id) == nil)
        #expect(!reconnected.isServerAuthorized(replacement))
        #expect(!reconnected.isToolAuthorized(serverID: original.id, toolName: "read_file"))
    }

    @Test("MCP manager UI exposes discovery and per-tool grant controls")
    func mcpManagerUIContract() throws {
        let sourceURL = URL(
            fileURLWithPath: #filePath
        )
        let viewURL = sourceURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Sources/MinisCanvasApp/MCPManagerView.swift"
            )
        let source = try String(contentsOf: viewURL, encoding: .utf8)

        let discoveryStart = try #require(source.range(of: "private func discoverTools(for server: MCPServer)"))
        let discoveryEnd = try #require(source.range(of: "private func reconnect", range: discoveryStart.upperBound..<source.endIndex))
        let discoveryAction = String(source[discoveryStart.lowerBound..<discoveryEnd.lowerBound])
        #expect(discoveryAction.contains("await center.discoverMCPTools(for: server, clientFactory: nil)"))
        #expect(discoveryAction.contains("discoveryErrors[server.id] = message"))
        #expect(discoveryAction.contains("if succeeded { discoveryRevision &+= 1 }"))

        let centerURL = viewURL.deletingLastPathComponent().appendingPathComponent("SettingsCenter.swift")
        let centerSource = try String(contentsOf: centerURL, encoding: .utf8)
        let centerStart = try #require(centerSource.range(of: "func discoverMCPTools(\n"))
        let centerEnd = try #require(centerSource.range(of: "private func invalidateMCPDiscovery",
            range: centerStart.upperBound..<centerSource.endIndex))
        let canonicalDiscovery = String(centerSource[centerStart.lowerBound..<centerEnd.lowerBound])
        #expect(canonicalDiscovery.contains("try await mcpManager.discoverTools(\n                serverID: server.id,\n                clientFactory: clientFactory"))
        #expect(canonicalDiscovery.contains("mcpManager.isServerAuthorized(currentServer)"))
        #expect(canonicalDiscovery.contains("currentServer.descriptorFingerprint == server.descriptorFingerprint"))
        #expect(canonicalDiscovery.contains("mcpDiscoveryGenerations[server.id, default: 0] == generation"))
        #expect(canonicalDiscovery.contains("mcpManager.isServerAuthorized(latestServer)"))
        #expect(canonicalDiscovery.contains("accepted.descriptorFingerprint == descriptorFingerprint"))
        #expect(canonicalDiscovery.contains("accepted.tools == tools"))
        #expect(!canonicalDiscovery.contains("setMCPToolAuthorized"))
        #expect(!canonicalDiscovery.contains("setMCPServerAuthorized"))
        #expect(source.contains("center.mcpManager.cachedTools(serverID: server.id)"))
        #expect(source.contains("setMCPToolAuthorized"))
        #expect(source.contains("工具授权"))
        #expect(source.contains("刷新 tools/list"))
        #expect(source.contains("mcp.server."))
        #expect(source.contains("tools.refresh"))
        #expect(source.contains("tools.empty"))
        #expect(source.contains("tools.error"))
        #expect(source.contains("tool."))
        #expect(source.contains("accessibilityLabel"))
        #expect(source.contains("accessibilityValue"))
        #expect(source.contains("Toggle(\"启用 \\(server.name)\""))
        #expect(source.contains("ProgressView()"))
    }

    @Test("Saving an MCP draft clears stale connection and discovery diagnostics")
    func savingDraftClearsStaleDiagnostics() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
        let viewURL = sourceURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MinisCanvasApp/MCPManagerView.swift")
        let source = try String(contentsOf: viewURL, encoding: .utf8)
        let start = try #require(source.range(of: "private func saveServerDraft"))
        let end = source.range(
            of: "\n    // MARK: 头部",
            range: start.upperBound..<source.endIndex
        )?.lowerBound ?? source.endIndex
        let saveFunction = String(source[start.lowerBound..<end])

        #expect(saveFunction.contains("if saved {"))
        #expect(saveFunction.contains("testResults[draft.id] = nil"))
        #expect(saveFunction.contains("discoveryErrors[draft.id] = nil"))
        #expect(saveFunction.range(of: "if saved {")!.lowerBound <
            saveFunction.range(of: "lastActionMessage")!.lowerBound)
    }

    @Test("Failed MCP draft save does not invalidate existing diagnostics")
    func failedDraftSavePreservesDiagnostics() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
        let viewURL = sourceURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MinisCanvasApp/MCPManagerView.swift")
        let source = try String(contentsOf: viewURL, encoding: .utf8)
        let start = try #require(source.range(of: "private func saveServerDraft"))
        let end = source.range(
            of: "\n    // MARK: 头部",
            range: start.upperBound..<source.endIndex
        )?.lowerBound ?? source.endIndex
        let saveFunction = String(source[start.lowerBound..<end])

        // 11/16：保存失败改为按原因分类的提示（配置已被修改 / 写入失败）。
        let failureRange = try #require(saveFunction.range(of: "MCPFailureMessage.save("))
        let successGuard = try #require(saveFunction.range(of: "if saved {"))
        #expect(successGuard.upperBound <= failureRange.lowerBound)
        #expect(saveFunction.contains("return saved"))
        let failureTail = String(saveFunction[failureRange.lowerBound..<saveFunction.endIndex])
        #expect(!failureTail.contains("testResults[draft.id] = nil"))
        #expect(!failureTail.contains("discoveryErrors[draft.id] = nil"))
    }

    @Test("MCP discovery rejects stale lifecycle completions")
    func discoveryFenceContract() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
        let settingsURL = sourceURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Sources/MinisCanvasApp/SettingsCenter.swift"
            )
        let source = try String(contentsOf: settingsURL, encoding: .utf8)

        #expect(source.contains("mcpDiscoveryGenerations"))
        #expect(source.contains("invalidateMCPDiscovery(for: server.id)"))
        #expect(source.contains("currentServer.enabled"))
        #expect(source.contains("mcpManager.isServerAuthorized(currentServer)"))
        #expect(source.contains("descriptorFingerprint"))
        #expect(source.contains("mcpManager.snapshot().revision"))
        #expect(source.contains("authorizationSnapshot"))
        #expect(source.contains("latestServer.enabled"))
        #expect(source.contains("mcpDiscoveryGenerations[server.id, default: 0] == generation"))
    }

    @Test("MCP connection diagnostics are grant and lifecycle fenced")
    func connectionDiagnosticFenceContract() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
        let settingsURL = sourceURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Sources/MinisCanvasApp/SettingsCenter.swift"
            )
        let viewURL = sourceURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Sources/MinisCanvasApp/MCPManagerView.swift"
            )
        let settingsSource = try String(contentsOf: settingsURL, encoding: .utf8)
        let viewSource = try String(contentsOf: viewURL, encoding: .utf8)

        #expect(settingsSource.contains("func testMCPServer(_ server: MCPServer) async -> String?"))
        #expect(settingsSource.contains("currentServer.enabled"))
        #expect(settingsSource.contains("mcpManager.isServerAuthorized(currentServer)"))
        #expect(settingsSource.contains("currentServer.descriptorFingerprint == server.descriptorFingerprint"))
        #expect(settingsSource.contains("authorizationSnapshot"))
        #expect(settingsSource.contains("return nil"))
        // The typed result API retains the same nil-completion lifecycle fence.
        #expect(viewSource.contains("await center.testMCPServerResult(server)"))
        #expect(viewSource.contains("guard let result else"))
        #expect(viewSource.contains("connection-test"))
        #expect(viewSource.contains("不授予工具权限"))
        #expect(viewSource.contains("connection-test.result"))
        #expect(viewSource.contains("MCPTestResultStatus"))
        #expect(viewSource.contains("accessibilityValue(result.accessibilityValue)"))
        #expect(viewSource.contains("case success = \"成功\""))
        #expect(viewSource.contains("case rejected = \"已拒绝\""))
        #expect(viewSource.contains("case error = \"错误\""))
    }

    @Test("Diagnostic redaction rejects raw transport details")
    func diagnosticRedactionRejectsRawTransportDetails() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
        let settingsURL = sourceURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Sources/MinisCanvasApp/SettingsCenter.swift"
            )
        let settingsSource = try String(contentsOf: settingsURL, encoding: .utf8)
        let functionStart = try #require(
            settingsSource.range(of: "func testMCPServer(_ server: MCPServer) async -> String?")
        )
        let functionEnd = settingsSource.range(
            of: "\n    // MARK: - 恢复默认",
            range: functionStart.upperBound..<settingsSource.endIndex
        )?.lowerBound ?? settingsSource.endIndex
        let functionSource = String(settingsSource[functionStart.lowerBound..<functionEnd])

        let redactedCases = [
            ("MCPClientError.timeout", "请求超时，请检查服务器是否可达。"),
            ("MCPClientError.spawnFailed", "本地服务器启动失败，请检查命令和权限。"),
            ("MCPClientError.invalidServer", "服务器配置无效，请检查传输类型和端点。"),
            ("MCPClientError.rpcError", "服务器响应无效，请检查协议兼容性。"),
            ("MCPClientError.permissionDenied", "服务器拒绝了请求，请检查服务器授权和配置。"),
        ]
        for (errorCase, safeMessage) in redactedCases {
            #expect(functionSource.contains(errorCase))
            #expect(functionSource.contains(safeMessage))
        }

        let forbiddenLeaks = [
            "error.localizedDescription",
            "String(describing: error)",
            "server.command",
            "server.url",
            "transportSummary",
        ]
        for forbiddenLeak in forbiddenLeaks {
            #expect(!functionSource.contains(forbiddenLeak))
        }
    }

    @Test("MCP diagnostic errors redact transport details before UI and AX")
    func connectionDiagnosticRedactionContract() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
        let settingsURL = sourceURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Sources/MinisCanvasApp/SettingsCenter.swift"
            )
        let viewURL = sourceURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Sources/MinisCanvasApp/MCPManagerView.swift"
            )
        let settingsSource = try String(contentsOf: settingsURL, encoding: .utf8)
        let viewSource = try String(contentsOf: viewURL, encoding: .utf8)
        let functionStart = try #require(
            settingsSource.range(of: "func testMCPServer(_ server: MCPServer) async -> String?")
        )
        let functionEnd = settingsSource.range(
            of: "\n    // MARK: - 恢复默认",
            range: functionStart.upperBound..<settingsSource.endIndex
        )?.lowerBound ?? settingsSource.endIndex
        let functionSource = String(settingsSource[functionStart.lowerBound..<functionEnd])

        #expect(functionSource.contains("redactedMCPTestFailure"))
        #expect(functionSource.contains("return MCPTestResult(status: .error, message: redactedMCPTestFailure(error))"))
        #expect(!functionSource.contains("error.localizedDescription"))
        #expect(!functionSource.contains("String(describing: error)"))
        #expect(settingsSource.contains("private func redactedMCPTestFailure"))
        #expect(settingsSource.contains("MCPClientError.timeout"))
        #expect(settingsSource.contains("MCPClientError.spawnFailed"))
        #expect(settingsSource.contains("MCPClientError.invalidServer"))
        #expect(viewSource.contains("accessibilityValue(result.accessibilityValue)"))
    }
}
