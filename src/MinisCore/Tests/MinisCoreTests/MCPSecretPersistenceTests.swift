import Foundation
import Testing
@testable import MinisCore

// S1（HIGH security slice）: MCP env/headers 不得以明文持久化/导出。
// 持久化（mcps.json，含回收站）与导出（exportMCPJSON）必须排除 secret 值；
// 运行期行为通过安全引用保留：保存时 secret 值写入 Keychain、磁盘只留占位，
// 重新加载时从 Keychain 还原真实值。非 secret 键值照常明文往返。

/// 进程内 Keychain backing（本文件专用，测试不触碰真实钥匙串）。
private final class MCPKeychainInMemoryBacking: KeychainBacking, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: String] = [:]

    func set(_ value: String, forKey key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        store[key] = value
        return true
    }

    func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return store[key]
    }

    func delete(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        store.removeValue(forKey: key)
        return true
    }
}

private func makeTempDir(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MinisCore-MCPSecret-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// 一个同时携带 secret 与非 secret env/header 的服务器。
private func makeSecretServer() -> MCPServer {
    MCPServer(
        id: "secrets-demo",
        name: "Secrets Demo",
        type: .http,
        enabled: true,
        command: nil,
        args: [],
        env: [
            "PATH": "/usr/bin",
            "NODE_ENV": "production",
            "GITHUB_API_KEY": "sk-secret-abc123",
            "DEBUG": "1",
        ],
        url: "https://mcp.example.com/mcp",
        headers: [
            "Authorization": "Bearer tok-xyz789",
            "X-Request-Id": "req-1",
        ],
        timeoutSeconds: 30
    )
}

struct MCPSecretPersistenceTests {

    // MARK: - 持久化（mcps.json）

    @Test func persistedFileExcludesSecretValuesAndKeepsNonSecrets() throws {
        let dir = try makeTempDir("persist")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("mcps.json")
        let manager = MCPServerManager(fileURL: file, keychain: KeychainStore(backing: MCPKeychainInMemoryBacking()))
        try manager.addServer(makeSecretServer())

        let text = try String(contentsOf: file, encoding: .utf8)
        // Secret 值绝不能出现在磁盘文件里。
        #expect(!text.contains("sk-secret-abc123"))
        #expect(!text.contains("tok-xyz789"))
        // 安全引用生效：secret 位置只保留可恢复的 Keychain reference。
        #expect(text.contains("keychain-ref:"))
        // 非 secret 键值照常明文持久化（运行期契约不变）。
        // 注意：JSONEncoder 默认转义斜杠（\/usr\/bin），故断言用无斜杠的值。
        #expect(text.contains("production"))
        #expect(!text.contains("req-1"))
    }

    @Test func trashedServerPersistenceExcludesSecrets() throws {
        let dir = try makeTempDir("trash")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("mcps.json")
        let manager = MCPServerManager(fileURL: file, keychain: KeychainStore(backing: MCPKeychainInMemoryBacking()))
        try manager.addServer(makeSecretServer())
        let intent = try manager.deletionIntent(id: "secrets-demo")
            .withFirstConfirmation("I reviewed this exact MCP server")
            .withSecondConfirmation("I confirm moving this MCP server to trash")
        _ = try manager.deleteServer(intent)

        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("sk-secret-abc123"))
        #expect(!text.contains("tok-xyz789"))
    }

    // MARK: - 导出（exportMCPJSON）

    @Test func exportJSONExcludesSecretValuesAndKeepsNonSecrets() throws {
        let file = try makeTempDir("export").appendingPathComponent("mcps.json")
        let manager = MCPServerManager(fileURL: file, keychain: KeychainStore(backing: MCPKeychainInMemoryBacking()))
        let json = try #require(manager.exportMCPJSON(server: makeSecretServer()))

        #expect(!json.contains("sk-secret-abc123"))
        #expect(!json.contains("tok-xyz789"))
        #expect(json.contains("/usr/bin"))
        #expect(!json.contains("req-1"))
    }

    // MARK: - 运行期行为保留（安全引用还原）

    @Test func reloadRestoresSecretValuesFromKeychain() throws {
        let dir = try makeTempDir("reload")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("mcps.json")
        let backing = MCPKeychainInMemoryBacking()
        let manager = MCPServerManager(fileURL: file, keychain: KeychainStore(backing: backing))
        try manager.addServer(makeSecretServer())

        // 磁盘只存占位；新实例（模拟重启）必须从 Keychain 还原真实值。
        let reloaded = MCPServerManager(fileURL: file, keychain: KeychainStore(backing: backing))
        let server = try #require(reloaded.server(id: "secrets-demo"))
        #expect(server.env["GITHUB_API_KEY"] == "sk-secret-abc123")
        #expect(server.headers["Authorization"] == "Bearer tok-xyz789")
        #expect(server.env["PATH"] == "/usr/bin")
        #expect(server.headers["X-Request-Id"] == "req-1")
    }

    // MARK: - 旧格式明文迁移

    @Test func legacyPlaintextFileIsMigratedAndStripped() throws {
        let dir = try makeTempDir("legacy")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("mcps.json")
        // S1 之前版本写出的文件：secret 值明文躺在磁盘上。
        let legacy = """
        {"servers":[{"id":"legacy","name":"Legacy","type":"stdio","enabled":true,"command":"npx","args":[],"env":{"API_TOKEN":"plain-secret-1","PATH":"/bin"},"headers":{},"timeoutSeconds":60}],"trashServers":[],"revision":1}
        """
        try legacy.write(to: file, atomically: true, encoding: .utf8)

        let manager = MCPServerManager(fileURL: file, keychain: KeychainStore(backing: MCPKeychainInMemoryBacking()))
        // 运行期值保留。
        #expect(manager.server(id: "legacy")?.env["API_TOKEN"] == "plain-secret-1")
        #expect(manager.server(id: "legacy")?.env["PATH"] == "/bin")
        // 加载即迁移：文件被重写，明文被剥离。
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("plain-secret-1"))
        #expect(text.contains("/bin"))
    }

    // MARK: - 密钥键分类

    @Test func secretPolicyClassifiesSensitiveKeys() {
        #expect(MCPServerSecretPolicy.isSecretKey("GITHUB_API_KEY"))
        #expect(MCPServerSecretPolicy.isSecretKey("api_token"))
        #expect(MCPServerSecretPolicy.isSecretKey("Authorization"))
        #expect(MCPServerSecretPolicy.isSecretKey("X-API-Key"))
        #expect(MCPServerSecretPolicy.isSecretKey("Cookie"))
        #expect(!MCPServerSecretPolicy.isSecretKey("PATH"))
        #expect(!MCPServerSecretPolicy.isSecretKey("DEBUG"))
        #expect(!MCPServerSecretPolicy.isSecretKey("X-Request-Id"))
        #expect(!MCPServerSecretPolicy.isSecretKey("HOME"))
    }

    @Test func secretPolicyRejectsConflictingCaseVariantIdentity() {
        #expect(MCPServerSecretPolicy.ambiguousSecretIdentities([
            "API_KEY": "one-secret",
            " api-key ": "different-secret",
        ]) == ["API_KEY"])
        #expect(MCPServerSecretPolicy.ambiguousSecretIdentities([
            "API_KEY": "same-secret",
            "api_key": "same-secret",
        ]).isEmpty)
    }

    @Test func transportSecretsRoundTripThroughReferencesAndSummaryRedaction() throws {
        let dir = try makeTempDir("transport")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("mcps.json")
        let backing = MCPKeychainInMemoryBacking()
        let keychain = KeychainStore(backing: backing)
        let manager = MCPServerManager(fileURL: file, keychain: keychain)
        let original = MCPServer(
            id: "transport-secrets",
            name: "Transport Secrets",
            type: .http,
            args: ["--api-key=arg-secret-123", "--token", "separate-secret-999", "--plain=ok"],
            env: ["API_KEY": "env-secret-123"],
            url: "https://mcp.example.test/mcp?token=url-secret-789&mode=read"
        )
        try manager.addServer(original)

        let persisted = try String(contentsOf: file, encoding: .utf8)
        #expect(!persisted.contains("arg-secret-123"))
        #expect(!persisted.contains("separate-secret-999"))
        #expect(!persisted.contains("url-secret-789"))
        #expect(persisted.contains("keychain-ref:"))
        #expect(manager.server(id: original.id)?.args == original.args)
        #expect(manager.server(id: original.id)?.url == original.url)
        let transportSummary = manager.server(id: original.id)?.transportSummary ?? ""
        #expect(transportSummary.contains("env-secret-123") == false)
        #expect(transportSummary.contains("url-secret-789") == false)
        #expect(transportSummary.contains("separate-secret-999") == false)

        let reloaded = MCPServerManager(fileURL: file, keychain: keychain)
        #expect(reloaded.server(id: original.id)?.args == original.args)
        #expect(reloaded.server(id: original.id)?.url == original.url)

        var updated = original
        updated.args[0] = "--api-key=arg-secret-456"
        try manager.updateServer(updated)
        let updatedPersisted = try String(contentsOf: file, encoding: .utf8)
        #expect(updatedPersisted.contains(".r2."))
        #expect(!updatedPersisted.contains("arg-secret-123"))
        #expect(updatedPersisted != persisted)

        let oldFile = dir.appendingPathComponent("old-mcps.json")
        try persisted.write(to: oldFile, atomically: true, encoding: .utf8)
        let oldReloaded = MCPServerManager(fileURL: oldFile, keychain: keychain)
        #expect(oldReloaded.server(id: original.id)?.args == original.args)
        #expect(oldReloaded.server(id: original.id)?.env["API_KEY"] == "env-secret-123")
    }
}
