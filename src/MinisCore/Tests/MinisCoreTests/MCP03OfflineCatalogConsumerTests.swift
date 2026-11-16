import Foundation
import Testing
@testable import MinisCore

@Suite("D-MCP-03 observed stdio disconnect leaves no advertised tool")
struct MCP03OfflineCatalogConsumerTests {
    @Test func failedStdioRefreshRetiresToolFromNextProviderCatalog() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCP03-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let online = root.appendingPathComponent("online")
        try Data().write(to: online)
        let script = root.appendingPathComponent("server.sh")
        let source = #"""
        #!/bin/sh
        [ -f "$MCP03_ONLINE" ] || exit 7
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
          [ -z "$id" ] && continue
          method=$(printf '%s' "$line" | sed -n 's/.*"method":"\([^"]*\)".*/\1/p' | tr -d '\')
          case "$method" in
            initialize) printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"fixture","version":"1"}}}\n' "$id";;
            tools/list) printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"greet","description":"local fixture","inputSchema":{"type":"object"}}]}}\n' "$id";;
            *) printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"unknown"}}\n' "$id";;
          esac
        done
        """#
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let managerURL = root.appendingPathComponent("mcps.json")
        let manager = MCPServerManager(fileURL: managerURL)
        let server = MCPServer(
            id: "fixture", name: "Fixture", type: .stdio, command: "/bin/sh",
            args: [script.path], env: ["MCP03_ONLINE": online.path], timeoutSeconds: 2
        )
        try manager.addServer(server)
        try manager.authorizeServer(id: server.id)
        try manager.authorizeTool(serverID: server.id, toolName: "greet")
        let registry = MCPToolRegistry(manager: manager)
        defer { registry.disconnectAll() }
        try await registry.refreshTools()
        let fullName = MCPBoundTool.makeFullName(serverID: server.id, toolName: "greet")
        let first = try await AgentToolCatalog.makeTools(includingMCPFrom: registry.snapshotForTurn())
        #expect(first.contains { $0.name == fullName })

        // The fixture now exits before initialize. This is an observed failed
        // refresh, not an inferred network outage or a user configuration read.
        try FileManager.default.removeItem(at: online)
        try await registry.refreshTools()
        #expect(manager.discoverySnapshot(serverID: server.id) == nil)
        let second = try await AgentToolCatalog.makeTools(includingMCPFrom: registry.snapshotForTurn())
        #expect(!second.contains { $0.name == fullName })

        // A restart must not re-advertise the old persisted discovery cache.
        let reopened = MCPServerManager(fileURL: managerURL)
        let afterRestart = MCPToolRegistry(manager: reopened)
        defer { afterRestart.disconnectAll() }
        let third = try await AgentToolCatalog.makeTools(includingMCPFrom: afterRestart.snapshotForTurn())
        #expect(!third.contains { $0.name == fullName })

        // Retirement is not a permanent permission revocation. The same
        // explicit grant can advertise again after a fresh successful list.
        try Data().write(to: online)
        try await registry.refreshTools()
        let recovered = try await AgentToolCatalog.makeTools(includingMCPFrom: registry.snapshotForTurn())
        #expect(recovered.contains { $0.name == fullName })
    }
}
