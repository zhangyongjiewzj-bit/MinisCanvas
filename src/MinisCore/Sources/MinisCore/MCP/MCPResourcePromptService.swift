import Foundation

// MARK: - MCP 资源（@ 引用）与提示词（斜杠命令）
//
// 只读能力：resources/list、resources/read、prompts/list、prompts/get。
// 只对“已启用且已在设置页授权服务器”的服务器发请求；资源内容和提示词展开结果都先脱敏、再限长，
// 资源的身份是“服务器 + URI”，不同服务器的同名 URI 互不相干。

public struct MCPResourceInfo: Sendable, Equatable {
    public let uri: String
    public let name: String
    public let description: String?
    public let mimeType: String?

    public init(uri: String, name: String, description: String? = nil, mimeType: String? = nil) {
        self.uri = uri
        self.name = name
        self.description = description
        self.mimeType = mimeType
    }
}

public struct MCPPromptArgument: Sendable, Equatable {
    public let name: String
    public let description: String?
    public let required: Bool

    public init(name: String, description: String? = nil, required: Bool = false) {
        self.name = name
        self.description = description
        self.required = required
    }
}

public struct MCPPromptInfo: Sendable, Equatable {
    public let name: String
    public let description: String?
    public let arguments: [MCPPromptArgument]

    public init(name: String, description: String? = nil, arguments: [MCPPromptArgument] = []) {
        self.name = name
        self.description = description
        self.arguments = arguments
    }
}

/// 一条可被 @ 引用的 MCP 资源（带来源服务器）。
public struct MCPResourceItem: Sendable, Equatable, Identifiable {
    public let serverID: String
    public let serverName: String
    public let info: MCPResourceInfo

    public var id: String { "\(serverID)\u{1f}\(info.uri)" }
    public var uri: String { info.uri }
    public var title: String { info.name }

    public init(serverID: String, serverName: String, info: MCPResourceInfo) {
        self.serverID = serverID
        self.serverName = serverName
        self.info = info
    }
}

/// 一条可用斜杠菜单调用的 MCP 提示词，形如 `/mcp__服务器__提示词`。
public struct MCPPromptItem: Sendable, Equatable, Identifiable {
    public let serverID: String
    public let serverName: String
    public let info: MCPPromptInfo

    public var id: String { "\(serverID)\u{1f}\(info.name)" }

    public init(serverID: String, serverName: String, info: MCPPromptInfo) {
        self.serverID = serverID
        self.serverName = serverName
        self.info = info
    }

    /// 斜杠命令名（不含 "/"）：服务器和提示词名中不是字母数字、下划线、连字符的字符换成下划线。
    /// 名字含中文等非 ASCII 字符时会被换成同样的下划线而撞名，所以追加由原名算出的稳定短后缀区分。
    public var slashName: String {
        "mcp__\(MCPResourcePromptService.uniqueSanitized(serverID))__\(MCPResourcePromptService.uniqueSanitized(info.name))"
    }

    /// 参数提示，例如 "<code> [style]"；必填参数用尖括号。
    public var argumentHint: String? {
        guard !info.arguments.isEmpty else { return nil }
        return info.arguments.map { $0.required ? "<\($0.name)>" : "[\($0.name)]" }.joined(separator: " ")
    }
}

public enum MCPResourcePromptError: Error, Equatable, Sendable, LocalizedError {
    case unavailable
    case promptNotFound
    case missingArgument(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable: return "该 MCP 服务器当前不可用：请到设置里确认已启用并已授权。"
        case .promptNotFound: return "没有找到这个 MCP 提示词：请重新打开斜杠菜单后再选。"
        case .missingArgument(let name): return "缺少必填参数“\(name)”：请按提示补全后再发送。"
        }
    }
}

public final class MCPResourcePromptService: @unchecked Sendable {
    /// 资源内容、提示词展开结果的字符上限（脱敏之后再截断）。
    public static let maxContentCharacters = 20_000
    private static let listCacheSeconds: TimeInterval = 60
    /// 读取失败只短暂记住（避免输入每个字符都去重连出问题的服务器），服务恢复后很快能重新读到。
    private static let failureCacheSeconds: TimeInterval = 5

    private let manager: MCPServerManager
    private let clientFactory: @Sendable (MCPServer) -> MCPClient
    private let lock = NSLock()
    private var clients: [String: MCPClient] = [:]
    private var resourceCache: [String: (fingerprint: String, at: Date, items: [MCPResourceInfo], failed: Bool)] = [:]
    private var promptCache: [String: (fingerprint: String, at: Date, items: [MCPPromptInfo], failed: Bool)] = [:]

    public init(
        manager: MCPServerManager,
        clientFactory: @escaping @Sendable (MCPServer) -> MCPClient = { MCPClient(server: $0) }
    ) {
        self.manager = manager
        self.clientFactory = clientFactory
    }

    /// 含非 ASCII 字符的名字：清理后再追加原名的 FNV-1a 稳定短哈希（不用 hashValue，它每次启动都变）。
    public static func uniqueSanitized(_ value: String) -> String {
        let clean = sanitized(value)
        guard value.contains(where: { !$0.isASCII }) else { return clean }
        var hash: UInt32 = 2_166_136_261
        for byte in value.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        let hex = String(hash, radix: 16)
        return clean + "_" + String(repeating: "0", count: 8 - hex.count) + hex
    }

    public static func sanitized(_ value: String) -> String {
        String(value.map { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "_" || character == "-")
                ? character : "_"
        })
    }

    /// 已启用且已授权的服务器；未授权的服务器不会被发任何请求。
    private func eligibleServers() -> [MCPServer] {
        manager.listServers().filter { $0.enabled && manager.isServerAuthorized($0) }
    }

    private func client(for server: MCPServer) -> MCPClient {
        lock.lock()
        defer { lock.unlock() }
        if let existing = clients[server.id], existing.server.descriptorFingerprint == server.descriptorFingerprint {
            return existing
        }
        clients[server.id]?.disconnect()
        let created = clientFactory(server)
        clients[server.id] = created
        return created
    }

    public func disconnectAll() {
        lock.lock()
        let current = clients
        clients.removeAll()
        resourceCache.removeAll()
        promptCache.removeAll()
        lock.unlock()
        for client in current.values { client.disconnect() }
    }

    // MARK: 资源

    /// 全部已授权服务器的资源，按查询词过滤（名称、URI、服务器名包含，忽略大小写），最多 `limit` 条。
    public func resources(matching query: String, limit: Int = 8) async -> [MCPResourceItem] {
        await resourcesReport(matching: query, limit: limit).items
    }

    /// 同 `resources(matching:limit:)`，另外返回读取列表失败的服务器名，界面据此区分“没有资源”和“读取失败”。
    public func resourcesReport(matching query: String, limit: Int = 8) async -> (items: [MCPResourceItem], failedServers: [String]) {
        let needle = query.lowercased()
        var result: [MCPResourceItem] = []
        var failedServers: [String] = []
        for server in eligibleServers() {
            let (infos, failed) = await cachedResources(for: server)
            if failed { failedServers.append(server.name) }
            for info in infos {
                if needle.isEmpty
                    || info.name.lowercased().contains(needle)
                    || info.uri.lowercased().contains(needle)
                    || server.name.lowercased().contains(needle) {
                    result.append(MCPResourceItem(serverID: server.id, serverName: server.name, info: info))
                }
            }
        }
        return (Array(result.prefix(max(0, limit))), failedServers)
    }

    private func cachedResources(for server: MCPServer) async -> (items: [MCPResourceInfo], failed: Bool) {
        let fingerprint = server.descriptorFingerprint
        let cached: (items: [MCPResourceInfo], failed: Bool)? = lock.withLock {
            guard let entry = resourceCache[server.id], entry.fingerprint == fingerprint,
                  Date().timeIntervalSince(entry.at) < (entry.failed ? Self.failureCacheSeconds : Self.listCacheSeconds)
            else { return nil }
            return (entry.items, entry.failed)
        }
        if let cached { return cached }
        let items: [MCPResourceInfo]
        let failed: Bool
        do {
            items = try await client(for: server).listResources()
            failed = false
        } catch {
            items = []
            failed = true
        }
        if Task.isCancelled { return (items, failed) }
        lock.withLock { resourceCache[server.id] = (fingerprint, Date(), items, failed) }
        return (items, failed)
    }

    /// 读取一条资源：只走该资源自己的服务器，内容先脱敏再限长。
    public func readResource(_ item: MCPResourceItem) async throws -> String {
        guard let server = eligibleServers().first(where: { $0.id == item.serverID }) else {
            throw MCPResourcePromptError.unavailable
        }
        let text = try await client(for: server).readResource(uri: item.uri)
        return Self.bounded(text)
    }

    // MARK: 提示词

    public func prompts() async -> [MCPPromptItem] {
        await promptsReport().items
    }

    /// 同 `prompts()`，另外返回读取列表失败的服务器名。
    public func promptsReport() async -> (items: [MCPPromptItem], failedServers: [String]) {
        var result: [MCPPromptItem] = []
        var failedServers: [String] = []
        for server in eligibleServers() {
            let (infos, failed) = await cachedPrompts(for: server)
            if failed { failedServers.append(server.name) }
            for info in infos {
                result.append(MCPPromptItem(serverID: server.id, serverName: server.name, info: info))
            }
        }
        return (result, failedServers)
    }

    private func cachedPrompts(for server: MCPServer) async -> (items: [MCPPromptInfo], failed: Bool) {
        let fingerprint = server.descriptorFingerprint
        let cached: (items: [MCPPromptInfo], failed: Bool)? = lock.withLock {
            guard let entry = promptCache[server.id], entry.fingerprint == fingerprint,
                  Date().timeIntervalSince(entry.at) < (entry.failed ? Self.failureCacheSeconds : Self.listCacheSeconds)
            else { return nil }
            return (entry.items, entry.failed)
        }
        if let cached { return cached }
        let items: [MCPPromptInfo]
        let failed: Bool
        do {
            items = try await client(for: server).listPrompts()
            failed = false
        } catch {
            items = []
            failed = true
        }
        if Task.isCancelled { return (items, failed) }
        lock.withLock { promptCache[server.id] = (fingerprint, Date(), items, failed) }
        return (items, failed)
    }

    /// 把参数文字对应到提示词的参数：支持 `名称=值`，其余按空白切分后依次填入尚未指定的参数（支持引号）。
    public static func promptArguments(for prompt: MCPPromptInfo, argumentText: String) throws -> [String: String] {
        var values: [String: String] = [:]
        var positional: [String] = []
        for word in CustomSlashCommand.splitArguments(argumentText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            if let equals = word.firstIndex(of: "="), equals != word.startIndex {
                let key = String(word[..<equals])
                if prompt.arguments.contains(where: { $0.name == key }) {
                    values[key] = String(word[word.index(after: equals)...])
                    continue
                }
            }
            positional.append(word)
        }
        var rest = positional[...]
        for argument in prompt.arguments where values[argument.name] == nil {
            guard let next = rest.first else { break }
            // 最后一个参数收下全部剩余文字，免得用户必须加引号。
            if argument.name == prompt.arguments.last?.name {
                values[argument.name] = rest.joined(separator: " ")
                rest = []
            } else {
                values[argument.name] = next
                rest = rest.dropFirst()
            }
        }
        for argument in prompt.arguments where argument.required && (values[argument.name] ?? "").isEmpty {
            throw MCPResourcePromptError.missingArgument(argument.name)
        }
        return values
    }

    /// 展开一条 `/mcp__服务器__提示词 参数`：调用 prompts/get，结果脱敏、限长后作为用户消息文本。
    public func expandPrompt(slashName: String, argumentText: String) async throws -> String {
        let wanted = slashName.lowercased()
        guard let item = await prompts().first(where: { $0.slashName.lowercased() == wanted }),
              let server = eligibleServers().first(where: { $0.id == item.serverID }) else {
            throw MCPResourcePromptError.promptNotFound
        }
        let arguments = try Self.promptArguments(for: item.info, argumentText: argumentText)
        let text = try await client(for: server).getPrompt(name: item.info.name, arguments: arguments)
        return Self.bounded(text)
    }

    /// 脱敏后再限长；超长时说明被截断。
    public static func bounded(_ text: String, limit: Int = maxContentCharacters) -> String {
        let redacted = ContentSecretRedactor.redact(text)
        guard redacted.count > limit else { return redacted }
        return String(redacted.prefix(limit)) + "\n…（内容过长，已截断，共 \(redacted.count) 字符）"
    }
}
