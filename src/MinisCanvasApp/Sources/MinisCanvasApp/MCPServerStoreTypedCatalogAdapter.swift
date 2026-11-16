import Foundation
import MinisCore

/// Read-only typed projection of the canonical SettingsCenter's MCP store.
/// Catalog authorization and registration remain with the conversation router;
/// these values confer no server, tool, or settings-write grant.
@MainActor
enum MCPServerStoreTypedCatalogAdapter {
    static func snapshot(
        from center: SettingsCenter,
        sessionDirectory: URL
    ) -> [String: BL6SettingValue]? {
        guard SettingsCenter.active === center,
              let expected = BridgeStore.canonicalSessionDirectoryIdentity(center.sessionStore.directory),
              let actual = BridgeStore.canonicalSessionDirectoryIdentity(sessionDirectory),
              expected == actual,
              center.mcpManager.fileURL.isFileURL else {
            return nil
        }

        var values: [String: BL6SettingValue] = [:]
        var seenIDs: Set<String> = []
        for server in center.mcpManager.listServers() {
            guard seenIDs.insert(server.id).inserted,
                  let encodedID = encodedStableID(server.id) else {
                return nil
            }
            let prefix = "mcp.\(encodedID)"
            values["\(prefix).name"] = .text(server.name)
            values["\(prefix).enabled"] = .toggle(server.enabled)
            values["\(prefix).authorized"] = .toggle(center.isMCPServerAuthorized(id: server.id))
            // Native editing exposes this finite transport enum. Its type
            // alone reveals no target, command, environment, or credentials;
            // the conversation executor keeps this descriptor read-only.
            values["\(prefix).type"] = .text(server.type.rawValue)
            // The Settings UI exposes individual tool grants from this same
            // admitted discovery cache. Project only their effective state;
            // no tool schema, transport descriptor, or grant is returned.
            var seenToolNames: Set<String> = []
            for tool in center.mcpManager.cachedTools(serverID: server.id) {
                guard seenToolNames.insert(tool.name).inserted,
                      let encodedName = encodedStableID(tool.name) else {
                    return nil
                }
                values["\(prefix).tools.\(encodedName).authorized"] = .toggle(
                    center.isMCPToolAuthorized(serverID: server.id, toolName: tool.name)
                )
            }
        }
        return values
    }

    private static func encodedStableID(_ id: String) -> String? {
        let bytes = Array(id.utf8)
        guard !bytes.isEmpty, bytes.count <= 256,
              id.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
