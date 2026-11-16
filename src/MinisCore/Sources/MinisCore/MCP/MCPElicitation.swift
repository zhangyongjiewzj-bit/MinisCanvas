import Foundation

public struct MCPElicitationContext: Sendable, Equatable {
    public let serverID: String
    public let serverName: String
    public let requestID: MCPID
    public let runtimeID: UUID
    public let invocation: MCPToolInvocationIdentity
    public let oneShotID: UUID
}

public enum MCPElicitationTaskContext {
    @TaskLocal public static var handler: (@Sendable (MCPElicitationContext, MCPElicitationForm) async throws -> MCPElicitationResult)?
}

public struct MCPElicitationResult: Sendable, Equatable {
    public enum Action: String, Sendable { case accept, decline, cancel }
    public let action: Action
    public let content: [String: MCPJSONValue]
    public init(action: Action, content: [String: MCPJSONValue] = [:]) {
        self.action = action
        self.content = content
    }
    public var json: MCPJSONValue {
        var result: [String: MCPJSONValue] = ["action": .string(action.rawValue)]
        if action == .accept { result["content"] = .object(content) }
        return .object(result)
    }
}

public struct MCPElicitationUserCancelled: Error, Sendable {}

/// A deliberately bounded form subset. Unknown schema keywords are rejected,
/// never stripped: doing so would silently change the server's contract.
public struct MCPElicitationForm: Sendable, Equatable {
    public struct Field: Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        public let description: String
        public let type: String
        public let required: Bool
        public let choices: [String]?
        public let minimum: Double?
        public let maximum: Double?
        public let minLength: Int
        public let maxLength: Int
        public let initialText: String
    }
    public let message: String
    public let fields: [Field]
    public static let maximumInputCharacters = 4_000

    public init(params: MCPJSONValue?) throws {
        func invalid() -> MCPClientError { .invalidSchema("Unsupported or oversized MCP elicitation form") }
        guard let params, try JSONEncoder().encode(params).count <= 64 * 1024,
              case .object(let object) = params,
              Set(object.keys).isSubset(of: ["mode", "message", "requestedSchema", "_meta"]),
              object["mode"] == nil || object["mode"] == .string("form"),
              case .string(let message)? = object["message"], message.count <= 2_000,
              case .object(let schema)? = object["requestedSchema"],
              Set(schema.keys).isSubset(of: ["type", "properties", "required", "$schema"]),
              schema["type"] == .string("object"),
              case .object(let properties)? = schema["properties"], properties.count <= 16 else { throw invalid() }
        let required: [String]
        if let raw = schema["required"] {
            guard case .array(let values) = raw else { throw invalid() }
            required = try values.map { value in
                guard case .string(let key) = value, properties[key] != nil else { throw invalid() }
                return key
            }
            guard Set(required).count == required.count else { throw invalid() }
        } else { required = [] }
        var fields: [Field] = []
        for key in properties.keys.sorted() {
            guard !key.isEmpty, key.count <= 128,
                  case .object(let value)? = properties[key],
                  case .string(let type)? = value["type"],
                  ["string", "number", "integer", "boolean"].contains(type) else { throw invalid() }
            var allowed: Set<String> = ["type", "title", "description", "default"]
            if type == "string" { allowed.formUnion(["enum", "minLength", "maxLength"]) }
            if type == "number" || type == "integer" { allowed.formUnion(["minimum", "maximum"]) }
            guard Set(value.keys).isSubset(of: allowed) else { throw invalid() }
            func text(_ name: String, fallback: String, limit: Int) throws -> String {
                guard let raw = value[name] else { return fallback }
                guard case .string(let result) = raw, result.count <= limit else { throw invalid() }
                return result
            }
            func number(_ name: String) throws -> Double? {
                guard let raw = value[name] else { return nil }
                guard case .number(let result) = raw, result.isFinite else { throw invalid() }
                return result
            }
            let lower = try number("minLength") ?? 0
            let upper = try number("maxLength") ?? Double(Self.maximumInputCharacters)
            guard lower >= 0, upper >= lower, upper <= Double(Self.maximumInputCharacters),
                  lower.rounded() == lower, upper.rounded() == upper else { throw invalid() }
            let minimum = try number("minimum"), maximum = try number("maximum")
            if let minimum, let maximum, minimum > maximum { throw invalid() }
            var choices: [String]?
            if let raw = value["enum"] {
                guard case .array(let entries) = raw, !entries.isEmpty, entries.count <= 64 else { throw invalid() }
                choices = try entries.map {
                    guard case .string(let entry) = $0, entry.count <= Self.maximumInputCharacters else { throw invalid() }
                    return entry
                }
                guard Set(choices ?? []).count == choices?.count else { throw invalid() }
            }
            let initial: String
            switch value["default"] {
            case nil: initial = ""
            case .string(let text)?: guard type == "string" else { throw invalid() }; initial = text
            case .bool(let flag)?: guard type == "boolean" else { throw invalid() }; initial = flag ? "true" : "false"
            case .number(let number)?: guard type == "number" || type == "integer", number.isFinite else { throw invalid() }; initial = String(number)
            default: throw invalid()
            }
            fields.append(Field(id: key, title: try text("title", fallback: key, limit: 256),
                description: try text("description", fallback: "", limit: 1_000), type: type,
                required: required.contains(key), choices: choices, minimum: minimum, maximum: maximum,
                minLength: Int(lower), maxLength: Int(upper), initialText: initial))
        }
        self.message = message
        self.fields = fields
        guard message.utf8.count + fields.reduce(0, { $0 + $1.title.utf8.count + $1.description.utf8.count + $1.initialText.utf8.count + ($1.choices ?? []).joined().utf8.count }) <= 24 * 1024 else { throw invalid() }
        // Validate defaults independently; absent required answers are left for
        // the user, never invented. Invalid defaults reject the entire form.
        for field in fields {
            if case .object(let property)? = properties[field.id], property["default"] != nil {
                _ = try value(field, text: field.initialText)
            }
        }
    }

    private func value(_ field: Field, text: String) throws -> MCPJSONValue {
        func invalid() -> MCPClientError { .invalidSchema("MCP form field '\(field.id)' is invalid or exceeds its limit") }
        guard text.count <= Self.maximumInputCharacters else { throw invalid() }
        switch field.type {
        case "string":
            guard text.count >= field.minLength, text.count <= field.maxLength,
                  field.choices?.contains(text) ?? true else { throw invalid() }
            return .string(text)
        case "boolean":
            guard text == "true" || text == "false" else { throw invalid() }
            return .bool(text == "true")
        case "number", "integer":
            guard let number = Double(text), number.isFinite,
                  field.type != "integer" || number.rounded() == number,
                  field.minimum.map({ number >= $0 }) ?? true,
                  field.maximum.map({ number <= $0 }) ?? true else { throw invalid() }
            return .number(number)
        default: throw invalid()
        }
    }

    public func validate(_ result: MCPElicitationResult) throws {
        guard result.action == .accept else {
            guard result.content.isEmpty else { throw MCPClientError.invalidSchema("Non-accept MCP answer cannot contain content") }
            return
        }
        guard Set(result.content.keys).isSubset(of: Set(fields.map(\.id))) else { throw MCPClientError.invalidSchema("Unknown MCP form answer") }
        for field in fields {
            guard let raw = result.content[field.id] else {
                if field.required { throw MCPClientError.invalidSchema("Missing required MCP answer") }
                continue
            }
            let text: String
            switch (field.type, raw) {
            case ("string", .string(let input)): text = input
            case ("boolean", .bool(let input)): text = input ? "true" : "false"
            case ("number", .number(let input)), ("integer", .number(let input)): text = String(input)
            default: throw MCPClientError.invalidSchema("MCP answer has wrong type")
            }
            _ = try value(field, text: text)
        }
        guard try JSONEncoder().encode(result.json).count <= 32 * 1024 else { throw MCPClientError.invalidSchema("MCP form response exceeds 32 KiB") }
    }

    public func response(texts: [String: String]) throws -> MCPElicitationResult {
        guard Set(texts.keys).isSubset(of: Set(fields.map(\.id))) else { throw MCPClientError.invalidSchema("Unknown MCP form answer") }
        var result: [String: MCPJSONValue] = [:]
        for field in fields {
            let text = texts[field.id] ?? ""
            if text.isEmpty && !field.required { continue }
            result[field.id] = try value(field, text: text)
        }
        let response = MCPElicitationResult(action: .accept, content: result)
        guard try JSONEncoder().encode(response.json).count <= 32 * 1024 else { throw MCPClientError.invalidSchema("MCP form response exceeds 32 KiB") }
        return response
    }
}

extension MCPID {
    var jsonValue: MCPJSONValue {
        switch self { case .int(let value): return .number(Double(value)); case .string(let value): return .string(value) }
    }
    init?(jsonValue: MCPJSONValue) {
        switch jsonValue {
        case .string(let value): self = .string(value)
        case .number(let value):
            guard value.isFinite, value.rounded() == value, let integer = Int(exactly: value) else { return nil }
            self = .int(integer)
        default: return nil
        }
    }
}
