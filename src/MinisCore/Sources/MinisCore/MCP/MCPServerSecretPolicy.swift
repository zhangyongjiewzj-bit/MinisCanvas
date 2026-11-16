import Foundation

/// S1 (HIGH security slice): MCP 服务器 env/headers 中的 secret 值不得以
/// 明文持久化或导出。
///
/// - isSecretKey(_:)：按键名（大小写不敏感）保守判定 secret 键 —— env 键沿用
///   EnvVarPrivacyStore 的默认敏感后缀（API_KEY / TOKEN / SECRET / PASSWORD /
///   KEY），并额外覆盖 AUTH / COOKIE / CREDENTIAL / BEARER / PROXY 等 MCP
///   stdio/HTTP 常见敏感键（含 Authorization / X-API-Key / Cookie 头）。
/// - MCPServer.redactingSecrets()：返回 transport descriptor 中嵌入 secret
///   被遮蔽的副本，仅用于导出/诊断；持久化由 persistingServer(_:,keychain:)
///   写入可恢复的 Keychain reference。内存中的原始 MCPServer 保持不变。
/// - 真实 secret 值由 MCPServerManager 保存时写入 Keychain（安全引用），
///   重新加载时还原；磁盘上永不落明文。
public enum MCPServerSecretPolicy {

    /// 占位符：磁盘/导出文件中 secret 值的替身。非 secret 键值照常明文。
    public static let redactedMarker = "<redacted>"
    private static let referencePrefix = "<keychain-ref:"
    private static let referenceSuffix = ">"

    /// Keychain 中该键值对应的存储键（安全引用地址，作用域隔离 env/header）。
    public static func keychainKey(serverID: String, scope: MCPServerSecretScope, key: String) -> String {
        "mcp.v1.\(serverID).\(scope.rawValue).\(key)"
    }

    /// 键名是否为 secret（大小写不敏感）。
    public static func isSecretKey(_ name: String) -> Bool {
        let n = canonicalKey(name)
        let suffixes = [
            "API_KEY", "TOKEN", "SECRET", "PASSWORD", "PASSWD", "KEY",
            "AUTH", "COOKIE", "CREDENTIAL", "BEARER",
        ]
        if suffixes.contains(where: { n.hasSuffix($0) }) { return true }
        let fragments = [
            "AUTHORIZATION", "API-KEY", "BEARER", "CREDENTIAL", "COOKIE", "PROXY",
        ]
        if fragments.contains(where: { n.contains($0) }) { return true }
        return false
    }

    /// Normalize policy identity without changing the runtime dictionary key.
    private static func canonicalKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: "-", with: "_")
    }

    /// Case/format variants with different secret values are ambiguous and
    /// must not be persisted under two identities.
    public static func ambiguousSecretIdentities(_ values: [String: String]) -> [String] {
        var identities: [String: Set<String>] = [:]
        for (key, value) in values where !value.isEmpty && isSecretKey(key) {
            identities[canonicalKey(key), default: []].insert(value)
        }
        return identities.filter { $0.value.count > 1 }.map { $0.key }.sorted()
    }

    /// Redact a transport dictionary at the boundary where it may be written
    /// or projected. The helper is shared by env and headers so they cannot
    /// drift into different secret rules.
    public static func redactedValues(_ values: [String: String]) -> [String: String] {
        values.reduce(into: [String: String]()) { result, entry in
            let (key, value) = entry
            result[key] = value.isEmpty || !isSecretKey(key) ? value : redactedMarker
        }
    }

    /// Whether a dictionary still contains a non-empty value under a secret
    /// key. This is an assertion helper for persistence/export callers.
    public static func containsUnredactedSecret(_ values: [String: String]) -> Bool {
        values.contains { key, value in
            !value.isEmpty && isSecretKey(key) && value != redactedMarker
        }
    }

    /// Redact embedded credentials before free-form MCP text is projected to
    /// an agent turn, transcript, or diagnostic surface. The shared content
    /// redactor covers bearer tokens, credential query parameters, URL
    /// userinfo, and provider-style keys without introducing a second policy.
    public static func redactText(_ text: String, knownSecrets: [String] = []) -> String {
        ContentSecretRedactor.redact(text, knownSecrets: knownSecrets)
    }

    private static func referenceKey(serverID: String, scope: MCPServerSecretScope, key: String, revision: Int) -> String {
        "mcp.v2.\(serverID).\(scope.rawValue).r\(revision).\(key)"
    }

    private static func reference(serverID: String, scope: MCPServerSecretScope, key: String, revision: Int) -> String {
        referencePrefix + referenceKey(serverID: serverID, scope: scope, key: key, revision: revision) + referenceSuffix
    }

    private static func referencedKey(_ value: String) -> String? {
        guard value.hasPrefix(referencePrefix), value.hasSuffix(referenceSuffix) else { return nil }
        return String(value.dropFirst(referencePrefix.count).dropLast(referenceSuffix.count))
    }

    /// Prepare the exact transport descriptor for disk. Every secret-bearing
    /// field is stored under an owner/revision Keychain key and replaced by a
    /// reversible reference. All HTTP header values use references; ordinary
    /// non-secret environment values remain unchanged.
    public static func persistingServer(_ server: MCPServer, keychain: KeychainStore, revision: Int = 0) throws -> MCPServer {
        let collisions = ambiguousSecretIdentities(server.env) + ambiguousSecretIdentities(server.headers)
        if let collision = collisions.sorted().first {
            throw MCPServerSecretStoreError.ambiguousSecretIdentity(collision)
        }
        let knownSecrets: [String] = server.env.compactMap { key, value in
            guard !value.isEmpty, isSecretKey(key) else { return nil }
            return value
        } + server.headers.compactMap { _, value in
            guard !value.isEmpty else { return nil }
            return value
        }
        var copy = server
        copy.env = try persistDictionary(server.env, serverID: server.id, scope: .env, revision: revision, keychain: keychain)
        copy.headers = try persistDictionary(server.headers, serverID: server.id, scope: .header, revision: revision, keychain: keychain, allValuesAreSecret: true)
        copy.args = try server.args.enumerated().map { index, argument in
            let precededBySecretFlag = index > server.args.startIndex
                && isSecretArgumentLabel(server.args[index - 1])
            return try persistEmbedded(
                argument,
                serverID: server.id,
                scope: .argument,
                key: String(index),
                knownSecrets: knownSecrets,
                force: precededBySecretFlag,
                revision: revision,
                keychain: keychain
            )
        }
        if let url = server.url {
            copy.url = try persistEmbedded(url, serverID: server.id, scope: .url, key: "value", knownSecrets: knownSecrets, revision: revision, keychain: keychain)
        }
        return copy
    }

    /// Restore reversible transport references. Missing references disable the
    /// server at the Manager boundary instead of sending a marker onward.
    public static func restoringServer(_ server: MCPServer, keychain: KeychainStore) -> (server: MCPServer, missingReference: Bool) {
        var copy = server
        var missing = false
        copy.env = server.env.mapValues { value in
            guard let key = referencedKey(value) else { return value }
            guard let restored = keychain.get(key) else { missing = true; return value }
            return restored
        }
        copy.headers = server.headers.mapValues { value in
            guard let key = referencedKey(value) else { return value }
            guard let restored = keychain.get(key) else { missing = true; return value }
            return restored
        }
        copy.args = server.args.map { value in
            guard let key = referencedKey(value) else { return value }
            guard let restored = keychain.get(key) else { missing = true; return value }
            return restored
        }
        if let url = server.url, let key = referencedKey(url) {
            if let restored = keychain.get(key) {
                copy.url = restored
            } else {
                missing = true
            }
        }
        if missing { copy.enabled = false }
        return (copy, missing)
    }

    private static func persistEmbedded(
        _ value: String,
        serverID: String,
        scope: MCPServerSecretScope,
        key: String,
        knownSecrets: [String],
        force: Bool = false,
        revision: Int,
        keychain: KeychainStore
    ) throws -> String {
        guard !value.isEmpty, force || redactText(value, knownSecrets: knownSecrets) != value else { return value }
        let storageKey = referenceKey(serverID: serverID, scope: scope, key: key, revision: revision)
        guard keychain.set(value, forKey: storageKey) else {
            throw MCPServerSecretStoreError.keychainWriteFailed(storageKey)
        }
        return reference(serverID: serverID, scope: scope, key: key, revision: revision)
    }

    private static func persistDictionary(
        _ values: [String: String],
        serverID: String,
        scope: MCPServerSecretScope,
        revision: Int,
        keychain: KeychainStore,
        allValuesAreSecret: Bool = false
    ) throws -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in values {
            guard !value.isEmpty, allValuesAreSecret || isSecretKey(key) else {
                result[key] = value
                continue
            }
            let storageKey = referenceKey(serverID: serverID, scope: scope, key: key, revision: revision)
            guard keychain.set(value, forKey: storageKey) else {
                throw MCPServerSecretStoreError.keychainWriteFailed(storageKey)
            }
            result[key] = reference(serverID: serverID, scope: scope, key: key, revision: revision)
        }
        return result
    }

    static func isSecretArgumentLabel(_ value: String) -> Bool {
        let label = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return !label.isEmpty && !label.contains("=") && isSecretKey(label)
    }
}

/// 安全引用作用域：区分 env 与 header，避免同键名跨作用域碰撞。
public enum MCPServerSecretScope: String, Sendable {
    case env
    case header
    case argument
    case url
}

extension MCPServer {
    /// 返回 env/headers 中 secret 键值被占位符替换的副本（非 secret 键值原样；
    /// 空值不替换）。仅用于持久化/导出；运行期请使用原始值。
    public func redactingSecrets() -> MCPServer {
        var copy = self
        let knownSecrets: [String] = env.compactMap { key, value in
            guard !value.isEmpty, MCPServerSecretPolicy.isSecretKey(key) else { return nil }
            return value
        } + headers.compactMap { _, value in
            guard !value.isEmpty else { return nil }
            return value
        }

        copy.env = MCPServerSecretPolicy.redactedValues(copy.env)
        copy.headers = copy.headers.mapValues { $0.isEmpty ? "" : MCPServerSecretPolicy.redactedMarker }
        let originalArgs = copy.args
        copy.args = originalArgs.enumerated().map { index, argument in
            if index > originalArgs.startIndex,
               MCPServerSecretPolicy.isSecretArgumentLabel(originalArgs[index - 1]) {
                return MCPServerSecretPolicy.redactedMarker
            }
            return MCPServerSecretPolicy.redactText(argument, knownSecrets: knownSecrets)
        }
        copy.url = copy.url.map {
            MCPServerSecretPolicy.redactText($0, knownSecrets: knownSecrets)
        }

        return copy
    }
}
