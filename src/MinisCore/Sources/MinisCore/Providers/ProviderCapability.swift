import Foundation

/// Capabilities exposed by an LLM provider's wire implementation.
///
/// These are execution capabilities, not model marketing metadata. A provider
/// must advertise a capability only when its request and response path handles
/// it. In particular, a tools request must fail explicitly when `.tools` is
/// absent; it must never silently become a plain text request.
public enum ProviderCapability: String, CaseIterable, Codable, Hashable, Sendable {
    case streaming
    case tools
    case vision
    case audio
    case image
    case video

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let capability = Self(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown provider capability '\(raw)'"
            )
        }
        self = capability
    }
}

/// A claim arriving from a descriptive/configuration boundary. Only a known
/// typed capability can enter authorization; free-form claims are retained as
/// rejected evidence and never treated as permissions.
public enum ProviderCapabilityClaim: Codable, Equatable, Hashable, Sendable {
    case typed(ProviderCapability)
    case description(String)

    private enum CodingKeys: String, CodingKey { case kind, value }
    private enum Kind: String, Codable { case typed, description }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .typed(let capability):
            try container.encode(Kind.typed, forKey: .kind)
            try container.encode(capability, forKey: .value)
        case .description(let value):
            try container.encode(Kind.description, forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .typed:
            self = .typed(try container.decode(ProviderCapability.self, forKey: .value))
        case .description:
            self = .description(try container.decode(String.self, forKey: .value))
        }
    }
}
