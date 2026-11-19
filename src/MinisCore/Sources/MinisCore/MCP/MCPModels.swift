import Foundation
import CryptoKit

// MARK: - JSON Value (arbitrary JSON for inputSchema / params / results)

/// A lossless Codable representation of arbitrary JSON — used for MCP
/// `inputSchema`, request `params`, and response `result` payloads (MCP
/// 协议中这些字段都是任意 JSON 值，`[String: Any]` 无法直接 Codable)。
public enum MCPJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([MCPJSONValue])
    case object([String: MCPJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([MCPJSONValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: MCPJSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .number(let n): try container.encode(n)
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }

    // MARK: Conversions

    /// Convert to a Foundation `Any` (NSNull/NSNumber/String/Array/Dictionary)
    /// — convenient for `[String: Any]`-style bridging into ToolExecutor.
    public var asAny: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let a): return a.map { $0.asAny }
        case .object(let o): return o.mapValues { $0.asAny }
        }
    }

    /// Convert a Foundation `Any` (as produced by JSONSerialization) into a
    /// `MCPJSONValue`. Falls back to `.null` for unsupported types.
    public static func fromAny(_ any: Any) -> MCPJSONValue {
        switch any {
        case let v as MCPJSONValue: return v
        case _ as NSNull: return .null
        case let v as NSNumber:
            // JSONSerialization 给出的 NSNumber：整数 0/1 不能被当成布尔。
            if CFGetTypeID(v) == CFBooleanGetTypeID() { return .bool(v.boolValue) }
            return .number(v.doubleValue)
        case let v as Bool: return .bool(v)
        case let v as Int: return .number(Double(v))
        case let v as Double: return .number(v)
        case let v as String: return .string(v)
        case let v as [Any]: return .array(v.map { fromAny($0) })
        case let v as [String: Any]: return .object(v.mapValues { fromAny($0) })
        default: return .null
        }
    }
}

// MARK: - MCP Tool

/// One tool exposed by an MCP server (`tools/list` result entry).
public struct MCPTool: Codable, Equatable, Sendable {
    public var name: String
    public var description: String?
    /// JSON Schema object describing the tool's input (`inputSchema`).
    /// Stored as an arbitrary JSON value so non-standard schemas round-trip.
    public var inputSchema: MCPJSONValue?
    public var _meta: MCPJSONValue?
    /// 服务器在 tools/list 里给出的 `annotations`（如 `readOnlyHint`）。只是服务器的自述：
    /// 仅用于计划模式放行，绝不用来免审批；不参与工具摘要（见 `encode`），避免翻转提示就让已有授权失效。
    public var annotations: MCPJSONValue?
    public var requiresUserInteraction: Bool {
        guard case .object(let metadata)? = _meta else { return false }
        return metadata["anthropic/requiresUserInteraction"] == .bool(true)
    }
    /// 服务器自述这个工具只读（`annotations.readOnlyHint == true`）。
    public var readOnlyHint: Bool {
        guard case .object(let values)? = annotations else { return false }
        return values["readOnlyHint"] == .bool(true)
    }

    public init(
        name: String, description: String? = nil, inputSchema: MCPJSONValue? = nil,
        _meta: MCPJSONValue? = nil, annotations: MCPJSONValue? = nil
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self._meta = _meta
        self.annotations = annotations
    }

    private enum CodingKeys: String, CodingKey {
        case name, description, inputSchema, _meta, annotations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        inputSchema = try container.decodeIfPresent(MCPJSONValue.self, forKey: .inputSchema)
        _meta = try container.decodeIfPresent(MCPJSONValue.self, forKey: ._meta)
        annotations = try container.decodeIfPresent(MCPJSONValue.self, forKey: .annotations)
    }

    /// 编码结果同时用于工具摘要，所以不写出 `annotations`（只读提示不影响授权绑定）。
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(inputSchema, forKey: .inputSchema)
        try container.encodeIfPresent(_meta, forKey: ._meta)
    }

    /// `inputSchema` as a `[String: Any]` dictionary (nil if not an object).
    public var inputSchemaObject: [String: Any]? {
        guard case .object(let obj)? = inputSchema else { return nil }
        return obj.mapValues { $0.asAny }
    }

    /// Strict mapping for callers that need a canonical agent definition.
    /// Unsupported JSON Schema types fail explicitly because coercing them to
    /// string would change the tool contract. The existing catalog keeps its
    /// compatibility fallback for legacy callers.
    public func makeAgentToolDefinition() throws -> AgentToolDefinition? {
        guard !name.isEmpty else {
            throw MCPClientError.invalidSchema("tool name is empty")
        }
        guard case .object(let schema)? = inputSchema else {
            return AgentToolDefinition(name: name, description: description ?? "", parameters: [:], required: [])
        }
        if let type = schema["type"], type != .string("object") {
            throw MCPClientError.invalidSchema("tool '\(name)' schema type must be object")
        }

        var parameters: [String: AgentToolParam] = [:]
        if let rawProperties = schema["properties"] {
            guard case .object(let properties) = rawProperties else {
                throw MCPClientError.invalidSchema("tool '\(name)' properties must be an object")
            }
            for (propertyName, propertyValue) in properties {
                guard case .object(let property) = propertyValue else {
                    throw MCPClientError.invalidSchema("tool '\(name)' property '\(propertyName)' is not an object")
                }
                let type: AgentParamType
                switch property["type"] {
                case .string("string"), nil:
                    type = .string
                case .string("integer"):
                    type = .integer
                case .string("boolean"):
                    type = .boolean
                default:
                    throw MCPClientError.invalidSchema("tool '\(name)' property '\(propertyName)' uses unsupported type")
                }
                let propertyDescription: String
                if let rawDescription = property["description"] {
                    guard case .string(let value) = rawDescription else {
                        throw MCPClientError.invalidSchema(
                            "tool '\(name)' property '\(propertyName)' description must be a string"
                        )
                    }
                    propertyDescription = value
                } else {
                    propertyDescription = ""
                }
                let enumValues: [String]?
                if property["enum"] != nil, type != .string {
                    throw MCPClientError.invalidSchema(
                        "tool '\(name)' property '\(propertyName)' enum is unsupported for non-string type"
                    )
                }
                if let rawEnum = property["enum"] {
                    guard case .array(let values) = rawEnum else {
                        throw MCPClientError.invalidSchema(
                            "tool '\(name)' property '\(propertyName)' enum must be an array"
                        )
                    }
                    guard !values.isEmpty else {
                        throw MCPClientError.invalidSchema(
                            "tool '\(name)' property '\(propertyName)' enum must not be empty"
                        )
                    }
                    var strings: [String] = []
                    strings.reserveCapacity(values.count)
                    for value in values {
                        guard case .string(let string) = value else {
                            throw MCPClientError.invalidSchema(
                                "tool '\(name)' property '\(propertyName)' enum contains a non-string value"
                            )
                        }
                        strings.append(string)
                    }
                    guard Set(strings).count == strings.count else {
                        throw MCPClientError.invalidSchema(
                            "tool '\(name)' property '\(propertyName)' enum contains duplicate values"
                        )
                    }
                    enumValues = strings
                } else {
                    enumValues = nil
                }
                parameters[propertyName] = AgentToolParam(
                    type: type,
                    description: propertyDescription,
                    enumValues: enumValues
                )
            }
        }

        var required: [String] = []
        var seenRequired = Set<String>()
        if let rawRequired = schema["required"] {
            guard case .array(let values) = rawRequired else {
                throw MCPClientError.invalidSchema("tool '\(name)' required must be an array")
            }
            for value in values {
                guard case .string(let propertyName) = value else {
                    throw MCPClientError.invalidSchema("tool '\(name)' required contains a non-string value")
                }
                guard seenRequired.insert(propertyName).inserted else {
                    throw MCPClientError.invalidSchema(
                        "tool '\(name)' required contains duplicate property '\(propertyName)'"
                    )
                }
                guard parameters[propertyName] != nil else {
                    throw MCPClientError.invalidSchema(
                        "tool '\(name)' required property '\(propertyName)' is not declared"
                    )
                }
                required.append(propertyName)
            }
        }
        return AgentToolDefinition(
            name: name,
            description: description ?? "",
            parameters: parameters,
            required: required,
            propertyOrdering: parameters.keys.sorted()
        )
    }
}

// MARK: - MCP Server

/// Transport kind of an MCP server.
public enum MCPTransportType: String, Codable, Sendable {
    /// Spawn a local process and speak JSON-RPC over its stdin/stdout
    /// (newline-delimited JSON).
    case stdio
    /// POST JSON-RPC to an HTTP(S) endpoint.
    /// TODO(B1f): streamable-HTTP/SSE 会话暂未实现，仅支持 request/response。
    case http
}

/// One MCP server entry managed by `MCPServerManager`. Configuration concept reference: OpenMinis
/// `MCPStore.MCPServerConfig` (参考源码: Agent/Session/MCPStore.swift), trimmed
/// to MinisCore's native-macOS needs.
public struct MCPServer: Codable, Identifiable, Equatable, Sendable {
    public var id: String            // unique key, e.g. "github"
    public var name: String          // display name
    public var type: MCPTransportType
    public var enabled: Bool

    // STDIO transport
    public var command: String?
    public var args: [String]
    public var env: [String: String]

    // HTTP transport
    public var url: String?
    public var headers: [String: String]

    /// Handshake / `tools/list` timeout in seconds (default 60). Part of the
    /// descriptor fingerprint, so it is kept stable for existing grants.
    public var timeoutSeconds: Int
    /// 工具调用超时（秒）。nil 表示默认 10 分钟（对齐 Claude Code 的长时工具）；
    /// 不进入描述指纹，修改它不会让已有授权失效。
    public var callTimeoutSeconds: Int?
    /// 从项目 .mcp.json 导入的本地服务器在该项目根目录启动。nil = 默认目录。
    /// 只有非空时才进入描述指纹，已有服务器的授权不受影响。
    public var workingDirectory: String?

    public static let defaultCallTimeoutSeconds = 600
    public var effectiveCallTimeoutSeconds: Int { callTimeoutSeconds ?? Self.defaultCallTimeoutSeconds }

    public init(
        id: String,
        name: String,
        type: MCPTransportType = .stdio,
        enabled: Bool = true,
        command: String? = nil,
        args: [String] = [],
        env: [String: String] = [:],
        url: String? = nil,
        headers: [String: String] = [:],
        timeoutSeconds: Int = 60,
        callTimeoutSeconds: Int? = nil,
        workingDirectory: String? = nil
    ) {
        self.workingDirectory = workingDirectory
        self.id = id
        self.name = name
        self.type = type
        self.enabled = enabled
        self.command = command
        self.args = args
        self.env = env
        self.url = url
        self.headers = headers
        self.timeoutSeconds = timeoutSeconds
        self.callTimeoutSeconds = callTimeoutSeconds
    }

    /// Human-readable transport target ("https://…" or "npx …").
    public var transportSummary: String {
        let raw: String
        switch type {
        case .http: raw = url ?? ""
        case .stdio:
            let argStr = args.joined(separator: " ")
            raw = argStr.isEmpty ? (command ?? "") : "\(command ?? "") \(argStr)"
        }
        let knownSecrets: [String] = env.compactMap { key, value in
            guard !value.isEmpty, MCPServerSecretPolicy.isSecretKey(key) else { return nil }
            return value
        } + headers.compactMap { key, value in
            guard !value.isEmpty, MCPServerSecretPolicy.isSecretKey(key) else { return nil }
            return value
        }
        return MCPServerSecretPolicy.redactText(raw, knownSecrets: knownSecrets)
    }

    /// Stable hash of the non-secret descriptor. Environment variables and
    /// headers are intentionally excluded so the fingerprint never contains
    /// credentials and secret rotation does not silently grant a tool.
    public var descriptorFingerprint: String {
        struct Descriptor: Codable {
            var type: MCPTransportType
            var command: String?
            var args: [String]
            var url: String?
            var timeoutSeconds: Int
        }
        struct DescriptorWithDirectory: Codable {
            var base: Descriptor
            var workingDirectory: String
        }
        let descriptor = Descriptor(type: type, command: command, args: args, url: url, timeoutSeconds: timeoutSeconds)
        let encoder = JSONEncoder()
        if let workingDirectory, !workingDirectory.isEmpty {
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(DescriptorWithDirectory(base: descriptor, workingDirectory: workingDirectory)) else { return "invalid" }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(descriptor) else { return "invalid" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// One page returned by `tools/list`.  The opaque cursor is intentionally
/// kept beside the page so a caller can fence each await before requesting or
/// publishing the next page.
public struct MCPToolListPage: Equatable, Sendable {
    public let tools: [MCPTool]
    public let nextCursor: String?
    /// UTF-8 bytes of the JSON-RPC result object for this page.
    public let jsonBytes: Int
    /// UTF-8 bytes of all serialized `inputSchema` values on this page.
    public let serializedSchemaBytes: Int
    /// Configuration identity and client lifecycle epoch that produced it.
    public let serverIdentity: String
    public let transportGeneration: UInt64

    public init(
        tools: [MCPTool],
        nextCursor: String? = nil,
        jsonBytes: Int = 0,
        serializedSchemaBytes: Int = 0,
        serverIdentity: String = "",
        transportGeneration: UInt64 = 0
    ) {
        self.tools = tools
        self.nextCursor = nextCursor
        self.jsonBytes = max(0, jsonBytes)
        self.serializedSchemaBytes = max(0, serializedSchemaBytes)
        self.serverIdentity = serverIdentity
        self.transportGeneration = transportGeneration
    }
}

// MARK: - JSON-RPC (MCP 协议消息结构)

private func isValidMCPMethod(_ method: String) -> Bool {
    !method.isEmpty && !method.unicodeScalars.contains { scalar in
        scalar.value < 0x20 || scalar.value == 0x7F
    }
}

/// JSON-RPC id — integer or string (MCP allows both).
public enum MCPID: Codable, Hashable, Sendable {
    case int(Int)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid JSON-RPC id")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let i): try container.encode(i)
        case .string(let s): try container.encode(s)
        }
    }
}

/// JSON-RPC request (`id` + `method` + optional `params`).
public struct MCPJSONRPCRequest: Codable, Equatable, Sendable {
    public var jsonrpc: String
    public var id: MCPID
    public var method: String
    public var params: MCPJSONValue?

    public init(id: MCPID, method: String, params: MCPJSONValue? = nil, jsonrpc: String = "2.0") {
        self.jsonrpc = jsonrpc
        self.id = id
        self.method = method
        self.params = params
    }

    private enum CodingKeys: String, CodingKey {
        case jsonrpc, id, method, params, result, error
    }

    public func encode(to encoder: Encoder) throws {
        guard jsonrpc == "2.0" else {
            throw MCPClientError.invalidMessage("unsupported JSON-RPC version")
        }
        guard isValidMCPMethod(method) else {
            throw MCPClientError.invalidMessage("JSON-RPC method must not be empty")
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        try container.encode(id, forKey: .id)
        try container.encode(method, forKey: .method)
        try container.encodeIfPresent(params, forKey: .params)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let jsonrpc = try container.decode(String.self, forKey: .jsonrpc)
        guard jsonrpc == "2.0" else {
            throw DecodingError.dataCorruptedError(
                forKey: .jsonrpc,
                in: container,
                debugDescription: "Unsupported JSON-RPC version"
            )
        }
        guard !container.contains(.result), !container.contains(.error) else {
            throw DecodingError.dataCorruptedError(
                forKey: .method,
                in: container,
                debugDescription: "Request cannot contain response fields"
            )
        }
        let method = try container.decode(String.self, forKey: .method)
        guard isValidMCPMethod(method) else {
            throw DecodingError.dataCorruptedError(
                forKey: .method,
                in: container,
                debugDescription: "JSON-RPC method must not be empty"
            )
        }
        self.jsonrpc = jsonrpc
        self.id = try container.decode(MCPID.self, forKey: .id)
        self.method = method
        self.params = try container.decodeIfPresent(MCPJSONValue.self, forKey: .params)
    }
}

/// JSON-RPC error object (`error: { code, message, data? }`).
public struct MCPJSONRPCError: Codable, Equatable, Sendable {
    public var code: Int
    public var message: String
    public var data: MCPJSONValue?

    public init(code: Int, message: String, data: MCPJSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

/// JSON-RPC response (`id` + `result` XOR `error`).
public struct MCPJSONRPCResponse: Codable, Equatable, Sendable {
    public var jsonrpc: String
    public var id: MCPID?
    public var result: MCPJSONValue?
    public var error: MCPJSONRPCError?

    public init(jsonrpc: String = "2.0", id: MCPID? = nil, result: MCPJSONValue? = nil, error: MCPJSONRPCError? = nil) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.result = result
        self.error = error
    }

    private enum CodingKeys: String, CodingKey {
        case jsonrpc, id, result, error
    }

    public func encode(to encoder: Encoder) throws {
        guard jsonrpc == "2.0" else {
            throw MCPClientError.invalidMessage("unsupported JSON-RPC version")
        }
        guard (result != nil) != (error != nil) else {
            throw MCPClientError.invalidMessage(
                "JSON-RPC response must contain exactly one of result or error"
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(result, forKey: .result)
        try container.encodeIfPresent(error, forKey: .error)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let jsonrpc = try container.decode(String.self, forKey: .jsonrpc)
        guard jsonrpc == "2.0" else {
            throw DecodingError.dataCorruptedError(
                forKey: .jsonrpc,
                in: container,
                debugDescription: "Unsupported JSON-RPC version"
            )
        }
        let hasResult = container.contains(.result)
        let hasError = container.contains(.error)
        guard hasResult != hasError else {
            throw DecodingError.dataCorruptedError(
                forKey: hasResult ? .result : .error,
                in: container,
                debugDescription: "Response must contain exactly one of result or error"
            )
        }
        let result = try container.decodeIfPresent(MCPJSONValue.self, forKey: .result)
        let error = try container.decodeIfPresent(MCPJSONRPCError.self, forKey: .error)
        guard !hasError || error != nil else {
            throw DecodingError.dataCorruptedError(
                forKey: .error,
                in: container,
                debugDescription: "Response error must be an object"
            )
        }
        self.jsonrpc = jsonrpc
        self.id = try container.decodeIfPresent(MCPID.self, forKey: .id)
        self.result = result
        self.error = error
    }

    public var isError: Bool { error != nil }

    /// A response is usable only for the request that owns its id. This is
    /// required for stateless transports where a late or misrouted response
    /// cannot be filtered by a pending-request table.
    public func matches(request: MCPJSONRPCRequest) -> Bool {
        id == request.id
    }
}

/// Typed, secret-safe projection of one JSON-RPC response.  Consumers use the
/// disposition to render state without parsing transport strings or trusting
/// arbitrary server error text.
public struct MCPResponseProjection: Codable, Equatable, Sendable {
    public enum Disposition: String, Codable, Equatable, Sendable {
        case success
        case remoteError
        case malformedResponse
        case transportFailure
        case permissionDenied
        case invocationRejected
        case unknown
    }

    public let disposition: Disposition
    public let result: MCPJSONValue?
    public let error: MCPErrorProjection?

    public init(response: MCPJSONRPCResponse) {
        if let remoteError = response.error {
            self.disposition = .remoteError
            self.result = nil
            self.error = MCPErrorProjection.remote(code: remoteError.code)
        } else if let result = response.result {
            self.disposition = .success
            self.result = result
            self.error = nil
        } else {
            self.disposition = .malformedResponse
            self.result = nil
            self.error = MCPErrorProjection.malformed
        }
    }

    public static func success(_ result: MCPJSONValue) -> Self {
        Self(disposition: .success, result: result, error: nil)
    }

    public static func failure(_ error: MCPErrorProjection) -> Self {
        Self(disposition: error.disposition, result: nil, error: error)
    }

    private init(
        disposition: Disposition,
        result: MCPJSONValue?,
        error: MCPErrorProjection?
    ) {
        self.disposition = disposition
        self.result = result
        self.error = error
    }
}

/// Safe error data crossing the MCP-to-product boundary.  The projection
/// intentionally omits remote messages and transport details, which may
/// contain credentials, command lines, or server-controlled instructions.
public struct MCPErrorProjection: Codable, Equatable, Sendable {
    public let disposition: MCPResponseProjection.Disposition
    public let code: Int?
    public let message: String

    private init(
        disposition: MCPResponseProjection.Disposition,
        code: Int?,
        message: String
    ) {
        self.disposition = disposition
        self.code = code
        self.message = message
    }

    fileprivate static func remote(code: Int) -> Self {
        Self(disposition: .remoteError, code: code, message: "MCP server returned an error")
    }

    fileprivate static let malformed = Self(
        disposition: .malformedResponse,
        code: nil,
        message: "MCP server returned an invalid response"
    )

    public static func from(_ error: Error) -> Self {
        switch error {
        case let error as MCPClientError:
            switch error {
            case .rpcError(let code, _):
                return remote(code: code)
            case .permissionDenied:
                return Self(disposition: .permissionDenied, code: nil, message: "MCP tool permission denied")
            case .badResponse, .invalidMessage, .invalidSchema:
                return malformed
            default:
                return Self(disposition: .transportFailure, code: nil, message: "MCP transport failed")
            }
        case is MCPToolInvocationFenceError:
            return Self(disposition: .invocationRejected, code: nil, message: "MCP invocation was rejected")
        default:
            return Self(disposition: .unknown, code: nil, message: "MCP invocation failed")
        }
    }
}

/// JSON-RPC notification (`method` + optional `params`, no `id`).
public struct MCPJSONRPCNotification: Codable, Equatable, Sendable {
    public var jsonrpc: String
    public var method: String
    public var params: MCPJSONValue?

    public init(method: String, params: MCPJSONValue? = nil, jsonrpc: String = "2.0") {
        self.jsonrpc = jsonrpc
        self.method = method
        self.params = params
    }

    private enum CodingKeys: String, CodingKey {
        case jsonrpc, method, params, id, result, error
    }

    public func encode(to encoder: Encoder) throws {
        guard jsonrpc == "2.0" else {
            throw MCPClientError.invalidMessage("unsupported JSON-RPC version")
        }
        guard isValidMCPMethod(method) else {
            throw MCPClientError.invalidMessage("JSON-RPC method must not be empty")
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        try container.encode(method, forKey: .method)
        try container.encodeIfPresent(params, forKey: .params)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let jsonrpc = try container.decode(String.self, forKey: .jsonrpc)
        guard jsonrpc == "2.0" else {
            throw DecodingError.dataCorruptedError(
                forKey: .jsonrpc,
                in: container,
                debugDescription: "Unsupported JSON-RPC version"
            )
        }
        guard !container.contains(.id), !container.contains(.result), !container.contains(.error) else {
            throw DecodingError.dataCorruptedError(
                forKey: .method,
                in: container,
                debugDescription: "Notification cannot contain id or response fields"
            )
        }
        let method = try container.decode(String.self, forKey: .method)
        guard isValidMCPMethod(method) else {
            throw DecodingError.dataCorruptedError(
                forKey: .method,
                in: container,
                debugDescription: "JSON-RPC method must not be empty"
            )
        }
        self.jsonrpc = jsonrpc
        self.method = method
        self.params = try container.decodeIfPresent(MCPJSONValue.self, forKey: .params)
    }
}

/// One wire message on an MCP transport — request / response / notification.
/// Stdio 传输使用 newline-delimited JSON: 每条消息一行（`encodeLine`/`decodeLine`）。
public enum MCPMessage: Codable, Equatable, Sendable {
    case request(MCPJSONRPCRequest)
    case response(MCPJSONRPCResponse)
    case notification(MCPJSONRPCNotification)

    // MARK: Codable

    public init(from decoder: Decoder) throws {
        let rawContainer = try decoder.container(keyedBy: AnyCodingKey.self)
        let knownKeys: Set<String> = ["jsonrpc", "id", "method", "params", "result", "error"]
        guard rawContainer.allKeys.allSatisfy({ knownKeys.contains($0.stringValue) }) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown JSON-RPC envelope key")
            )
        }
        let container = try decoder.container(keyedBy: EnvelopeKeys.self)
        let hasMethod = container.contains(.method)
        let hasID = container.contains(.id)
        let hasResult = container.contains(.result)
        let hasError = container.contains(.error)
        if hasMethod {
            guard !hasResult, !hasError else {
                throw DecodingError.dataCorruptedError(
                    forKey: .method,
                    in: container,
                    debugDescription: "JSON-RPC envelope mixes request and response fields"
                )
            }
            if hasID {
                self = .request(try MCPJSONRPCRequest(from: decoder))
            } else {
                self = .notification(try MCPJSONRPCNotification(from: decoder))
            }
        } else if hasID || hasResult || hasError {
            self = .response(try MCPJSONRPCResponse(from: decoder))
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .jsonrpc,
                in: container,
                debugDescription: "Not a JSON-RPC message"
            )
        }
    }

    private enum EnvelopeKeys: String, CodingKey {
        case jsonrpc, id, method, params, result, error
    }

    private struct AnyCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .request(let r): try container.encode(r)
        case .response(let r): try container.encode(r)
        case .notification(let n): try container.encode(n)
        }
    }

    /// Encode as a single JSON line (stdio framing, MCP transport spec).
    public func encodeLine() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard let line = String(data: data, encoding: .utf8) else {
            throw MCPClientError.invalidMessage("message is not valid UTF-8")
        }
        return line
    }

    /// Decode one JSON line into a message.
    public static func decodeLine(_ line: String) throws -> MCPMessage {
        guard let data = line.data(using: .utf8) else {
            throw MCPClientError.invalidMessage("line is not valid UTF-8")
        }
        return try decodeData(data)
    }

    static func decodeData(_ data: Data) throws -> MCPMessage {
        try MCPWireDecoder.validate(data)
        return try JSONDecoder().decode(MCPMessage.self, from: data)
    }

    static func decodeResponseData(_ data: Data) throws -> MCPJSONRPCResponse {
        try MCPWireDecoder.validate(data)
        return try JSONDecoder().decode(MCPJSONRPCResponse.self, from: data)
    }
}

/// Bounded, duplicate-aware validation for JSON received from an MCP server.
/// Foundation's JSONDecoder is intentionally used for schema decoding, but it
/// treats duplicate object keys as last-write-wins and has no input limits.
private enum MCPWireDecoder {
    private static let maxBytes = 1_048_576
    private static let maxDepth = 64

    static func validate(_ data: Data) throws {
        guard data.count <= maxBytes else {
            throw MCPClientError.invalidMessage("JSON-RPC payload exceeds byte limit")
        }
        guard String(data: data, encoding: .utf8) != nil else {
            throw MCPClientError.invalidMessage("JSON-RPC payload is not valid UTF-8")
        }
        var scanner = Scanner(bytes: Array(data))
        try scanner.scanValue(depth: 0)
        scanner.skipWhitespace()
        guard scanner.isAtEnd else {
            throw MCPClientError.invalidMessage("JSON-RPC payload has trailing data")
        }
    }

    private struct Scanner {
        let bytes: [UInt8]
        var index = 0

        var isAtEnd: Bool { index == bytes.count }

        mutating func skipWhitespace() {
            while index < bytes.count && (bytes[index] == 0x20 || bytes[index] == 0x09 || bytes[index] == 0x0A || bytes[index] == 0x0D) {
                index += 1
            }
        }

        mutating func scanValue(depth: Int) throws {
            guard depth <= MCPWireDecoder.maxDepth else {
                throw MCPClientError.invalidMessage("JSON-RPC payload nesting exceeds limit")
            }
            skipWhitespace()
            guard index < bytes.count else {
                throw MCPClientError.invalidMessage("JSON-RPC payload is truncated")
            }
            switch bytes[index] {
            case 0x7B:
                guard depth < MCPWireDecoder.maxDepth else {
                    throw MCPClientError.invalidMessage("JSON-RPC payload nesting exceeds limit")
                }
                try scanObject(depth: depth + 1)
            case 0x5B:
                guard depth < MCPWireDecoder.maxDepth else {
                    throw MCPClientError.invalidMessage("JSON-RPC payload nesting exceeds limit")
                }
                try scanArray(depth: depth + 1)
            case 0x22: _ = try scanString()
            default: scanScalar()
            }
        }

        mutating func scanObject(depth: Int) throws {
            index += 1
            skipWhitespace()
            var keys = Set<String>()
            if index < bytes.count, bytes[index] == 0x7D {
                index += 1
                return
            }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == 0x22 else {
                    throw MCPClientError.invalidMessage("JSON-RPC object key is missing")
                }
                let key = try scanString()
                guard keys.insert(key).inserted else {
                    throw MCPClientError.invalidMessage("JSON-RPC object contains duplicate key")
                }
                skipWhitespace()
                guard index < bytes.count, bytes[index] == 0x3A else {
                    throw MCPClientError.invalidMessage("JSON-RPC object is missing a colon")
                }
                index += 1
                try scanValue(depth: depth)
                skipWhitespace()
                guard index < bytes.count else {
                    throw MCPClientError.invalidMessage("JSON-RPC object is truncated")
                }
                if bytes[index] == 0x7D {
                    index += 1
                    return
                }
                guard bytes[index] == 0x2C else {
                    throw MCPClientError.invalidMessage("JSON-RPC object is missing a separator")
                }
                index += 1
            }
        }

        mutating func scanArray(depth: Int) throws {
            index += 1
            skipWhitespace()
            if index < bytes.count, bytes[index] == 0x5D {
                index += 1
                return
            }
            while true {
                try scanValue(depth: depth)
                skipWhitespace()
                guard index < bytes.count else {
                    throw MCPClientError.invalidMessage("JSON-RPC array is truncated")
                }
                if bytes[index] == 0x5D {
                    index += 1
                    return
                }
                guard bytes[index] == 0x2C else {
                    throw MCPClientError.invalidMessage("JSON-RPC array is missing a separator")
                }
                index += 1
            }
        }

        mutating func scanString() throws -> String {
            let start = index
            index += 1
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 0x22 {
                    index += 1
                    let token = Data(bytes[start..<index])
                    guard let value = try? JSONDecoder().decode(String.self, from: token) else {
                        throw MCPClientError.invalidMessage("JSON-RPC string is malformed")
                    }
                    return value
                }
                if byte < 0x20 {
                    throw MCPClientError.invalidMessage("JSON-RPC string contains a control character")
                }
                if byte == 0x5C {
                    index += 1
                    guard index < bytes.count else {
                        throw MCPClientError.invalidMessage("JSON-RPC string escape is truncated")
                    }
                }
                index += 1
            }
            throw MCPClientError.invalidMessage("JSON-RPC string is unterminated")
        }

        mutating func scanScalar() {
            while index < bytes.count {
                switch bytes[index] {
                case 0x20, 0x09, 0x0A, 0x0D, 0x2C, 0x5D, 0x7D:
                    return
                default:
                    index += 1
                }
            }
        }
    }
}

// MARK: - Convenience

extension MCPJSONRPCRequest {
    /// Encode this request as a single newline-delimited JSON line (stdio framing).
    public func encodeLine() throws -> String {
        try MCPMessage.request(self).encodeLine()
    }
}

// MARK: - Client errors

public enum MCPClientError: Error, Equatable, Sendable {
    case invalidMessage(String)
    case transportNotStarted
    case spawnFailed(String)
    case processExited(Int32)
    case timeout(String)
    case rpcError(code: Int, message: String)
    case badResponse(String)
    case toolNotFound(String)
    case invalidServer(String)
    case invalidSchema(String)
    case outputLimitExceeded(limit: Int)
    case toolNameCollision(String)
    /// Tool discovery is not an execution grant. The bridge raises this when
    /// a discovered tool is outside its explicit allowlist.
    case permissionDenied(String)
}

/// 工具自己报告失败（`tools/call` 结果里 `isError: true`）。内容是工具返回的说明文字。
public struct MCPToolReportedError: Error, LocalizedError, Equatable, Sendable {
    public let message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

extension MCPClientError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidMessage(let d): return "Invalid MCP message: \(d)"
        case .transportNotStarted: return "MCP transport has not been started"
        case .spawnFailed(let d): return "Failed to spawn MCP server process: \(d)"
        case .processExited(let code): return "MCP server process exited (code \(code))"
        case .timeout(let d): return "MCP request timed out: \(d)"
        case .rpcError(let code, let message): return "MCP RPC error \(code): \(message)"
        case .badResponse(let d): return "Bad MCP response: \(d)"
        case .toolNotFound(let name): return "MCP tool not found: \(name)"
        case .invalidServer(let d): return "Invalid MCP server config: \(d)"
        case .invalidSchema: return "Invalid MCP tool schema"
        case .outputLimitExceeded(let limit): return "MCP tool output exceeded limit of \(limit) characters"
        case .toolNameCollision(let name): return "MCP tool name collision: \(name)"
        case .permissionDenied(let name): return "MCP tool permission denied: \(name)"
        }
    }
}
