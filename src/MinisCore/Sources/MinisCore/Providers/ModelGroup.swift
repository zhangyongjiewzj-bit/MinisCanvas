import Foundation

public enum RoutingStrategy: String, Codable, Hashable, Sendable {
    case fallback, loadBalance
}

public enum FallbackStrategy: String, Codable, Hashable, Sendable {
    case limited, always
}

public struct ModelGroup: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var memberEntryIds: [String]
    public var strategy: RoutingStrategy
    public var fallbackStrategy: FallbackStrategy
    public var defaultThinkingLevel: ThinkingLevel?
    public var contextLimitTokens: Int?
    public var lastContextLimitTokens: Int?

    public init(id: String = UUID().uuidString, name: String, memberEntryIds: [String],
                strategy: RoutingStrategy = .fallback, fallbackStrategy: FallbackStrategy = .limited,
                defaultThinkingLevel: ThinkingLevel? = nil, contextLimitTokens: Int? = nil,
                lastContextLimitTokens: Int? = nil) {
        self.id = id
        self.name = name
        self.memberEntryIds = memberEntryIds
        self.strategy = strategy
        self.fallbackStrategy = fallbackStrategy
        self.defaultThinkingLevel = defaultThinkingLevel
        self.contextLimitTokens = contextLimitTokens
        self.lastContextLimitTokens = lastContextLimitTokens
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, memberEntryIds, strategy, fallbackStrategy, defaultThinkingLevel, contextLimitTokens, lastContextLimitTokens
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(String.self, forKey: .id)
        name = try fields.decode(String.self, forKey: .name)
        memberEntryIds = try fields.decode([String].self, forKey: .memberEntryIds)
        strategy = try fields.decode(RoutingStrategy.self, forKey: .strategy)
        fallbackStrategy = try fields.decodeIfPresent(FallbackStrategy.self, forKey: .fallbackStrategy) ?? .limited
        contextLimitTokens = try fields.decodeIfPresent(Int.self, forKey: .contextLimitTokens)
        lastContextLimitTokens = try fields.decodeIfPresent(Int.self, forKey: .lastContextLimitTokens)
        defaultThinkingLevel = try fields.decodeIfPresent(String.self, forKey: .defaultThinkingLevel).map(ThinkingLevel.decoded)
    }
}
