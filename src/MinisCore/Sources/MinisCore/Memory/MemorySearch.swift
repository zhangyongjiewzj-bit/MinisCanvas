import Foundation

// MARK: - MemorySearch

/// Explainable lexical result projection for one active memory fact.
public struct MemorySearchHit: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let factID: String
    public let revision: Int
    public let score: Int
    public let matchedTerms: [String]
    public let retrievalMethod: String
    public let sourceDigest: String?
    public let sourceProposalID: String?
    public let sourceRef: String?
    public let provenanceRedacted: Bool
    public let redactionSummary: String

    public var id: String { factID }

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        factID: String,
        revision: Int,
        score: Int,
        matchedTerms: [String],
        retrievalMethod: String,
        sourceDigest: String?,
        sourceProposalID: String?,
        sourceRef: String?,
        provenanceRedacted: Bool,
        redactionSummary: String
    ) {
        self.schemaVersion = schemaVersion
        self.factID = factID
        self.revision = revision
        self.score = score
        self.matchedTerms = matchedTerms
        self.retrievalMethod = retrievalMethod
        self.sourceDigest = sourceDigest
        self.sourceProposalID = sourceProposalID
        self.sourceRef = sourceRef
        self.provenanceRedacted = provenanceRedacted
        self.redactionSummary = redactionSummary
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case factID
        case revision
        case score
        case matchedTerms
        case retrievalMethod
        case sourceDigest
        case sourceProposalID
        case sourceRef
        case provenanceRedacted
        case redactionSummary
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decodeIfPresent(
            Int.self,
            forKey: .schemaVersion
        ) ?? Self.currentSchemaVersion
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "unsupported memory search hit schema version"
            )
        }

        self.schemaVersion = schemaVersion
        self.factID = try container.decode(String.self, forKey: .factID)
        self.revision = try container.decode(Int.self, forKey: .revision)
        self.score = try container.decode(Int.self, forKey: .score)
        self.matchedTerms = try container.decode([String].self, forKey: .matchedTerms)
        self.retrievalMethod = try container.decode(String.self, forKey: .retrievalMethod)
        self.sourceDigest = try container.decodeIfPresent(String.self, forKey: .sourceDigest)
        self.sourceProposalID = try container.decodeIfPresent(
            String.self,
            forKey: .sourceProposalID
        )
        self.sourceRef = try container.decodeIfPresent(String.self, forKey: .sourceRef)
        self.provenanceRedacted = try container.decode(
            Bool.self,
            forKey: .provenanceRedacted
        )
        self.redactionSummary = try container.decode(String.self, forKey: .redactionSummary)
        try validateDecodedContract(in: container)
    }

    private func validateDecodedContract(
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws {
        guard !factID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              revision > 0,
              score >= 0,
              !retrievalMethod.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .factID,
                in: container,
                debugDescription: "invalid memory search hit identity or score"
            )
        }
        if provenanceRedacted {
            guard sourceProposalID == nil,
                  sourceRef == nil,
                  !redactionSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .provenanceRedacted,
                    in: container,
                    debugDescription: "redacted hit retained source identity"
                )
            }
        } else {
            guard redactionSummary == "none" else {
                throw DecodingError.dataCorruptedError(
                    forKey: .redactionSummary,
                    in: container,
                    debugDescription: "unredacted hit has a redaction summary"
                )
            }
        }
    }
}

/// Combined memory search: category filter + keyword + time range.
///
/// Wraps `MemoryStore` and applies all three dimensions in one pass. Results
/// are returned newest first, matching `MemoryStore.facts()` ordering.
public struct MemorySearch: Sendable {

    public let store: MemoryStore

    public init(store: MemoryStore) {
        self.store = store
    }

    public static let lexicalRetrievalMethod = "lexical-substring-v1"

    /// Search facts with optional filters:
    ///
    /// - `categories`: only facts in these categories. `nil` (default) means
    ///   no category filter.
    /// - `keyword`: case-insensitive substring match against fact text.
    ///   `nil` or empty means no keyword filter.
    /// - `from`: only facts created at or after this date.
    /// - `to`: only facts created at or before this date.
    ///
    /// All provided filters are ANDed. Results are newest first.
    public func search(
        categories: Set<MemoryCategory>? = nil,
        keyword: String? = nil,
        from: Date? = nil,
        to: Date? = nil,
        scope: MemoryScopeFilter? = nil
    ) throws -> [MemoryFact] {
        let needle = keyword?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let activeFacts: [MemoryFact]
        if let scope {
            activeFacts = try store.activeFacts(within: scope)
        } else {
            activeFacts = try store.activeFacts()
        }

        return activeFacts.filter { fact in
            if let categories, !categories.contains(fact.category) { return false }
            if let needle, !needle.isEmpty, !fact.text.lowercased().contains(needle) { return false }
            if let from, fact.createdAt < from { return false }
            if let to, fact.createdAt > to { return false }
            return true
        }
    }

    /// Convenience: search by a single category plus keyword.
    public func search(
        category: MemoryCategory,
        keyword: String? = nil,
        scope: MemoryScopeFilter? = nil
    ) throws -> [MemoryFact] {
        try search(categories: [category], keyword: keyword, scope: scope)
    }

    /// Return stable, explainable provenance projections for active facts.
    ///
    /// The default result never includes superseded, rolled-back, or
    /// tombstoned records. Equal timestamps use revision and fact id
    /// tie-breakers, so a fresh store instance returns the same order.
    public func searchHits(
        categories: Set<MemoryCategory>? = nil,
        keyword: String? = nil,
        from: Date? = nil,
        to: Date? = nil,
        scope: MemoryScopeFilter? = nil
    ) throws -> [MemorySearchHit] {
        try searchHits(categories: categories, keyword: keyword, from: from, to: to, scope: scope,
            displayFacts: nil)
    }

    func searchHits(
        categories: Set<MemoryCategory>? = nil,
        keyword: String? = nil,
        from: Date? = nil,
        to: Date? = nil,
        scope: MemoryScopeFilter?,
        displayFacts: [MemoryFact]?
    ) throws -> [MemorySearchHit] {
        let terms = Self.retrievalTerms(for: keyword)
        // A nonempty punctuation-only query must not become an unfiltered read.
        guard !Self.hasNonWhitespaceQuery(keyword) || !terms.isEmpty else {
            return []
        }
        let activeFacts: [MemoryFact]
        if let displayFacts {
            activeFacts = displayFacts
        } else if let scope {
            activeFacts = try store.activeFacts(within: scope)
        } else {
            activeFacts = try store.activeFacts()
        }
        let fullProvenance = Self.allowsFullProvenance(for: scope)

        return activeFacts.compactMap { fact -> (fact: MemoryFact, terms: [String])? in
            if let categories, !categories.contains(fact.category) { return nil }
            if let from, fact.createdAt < from { return nil }
            if let to, fact.createdAt > to { return nil }

            guard !terms.isEmpty else {
                return (fact, [])
            }
            let text = fact.text
                .precomposedStringWithCanonicalMapping
                .lowercased()
            let matchedTerms = terms.filter { text.contains($0) }
            guard !matchedTerms.isEmpty else { return nil }
            return (fact, matchedTerms)
        }
        .sorted {
            if $0.terms.count != $1.terms.count {
                return $0.terms.count > $1.terms.count
            }
            return Self.newestFirst($0.fact, $1.fact)
        }
        .map { item in
            MemorySearchHit(
                factID: item.fact.id,
                revision: item.fact.revision,
                score: item.terms.count,
                matchedTerms: item.terms,
                retrievalMethod: Self.lexicalRetrievalMethod,
                sourceDigest: item.fact.contentDigest,
                sourceProposalID: fullProvenance ? item.fact.sourceProposalID : nil,
                sourceRef: fullProvenance ? item.fact.sourceRef : nil,
                provenanceRedacted: !fullProvenance,
                redactionSummary: fullProvenance
                    ? "none"
                    : "sourceProposalID/sourceRef redacted outside exact session scope"
            )
        }
    }

    /// Preserve first occurrence order so repeated and mixed-case terms do not inflate scores.
    static func retrievalTerms(for keyword: String?) -> [String] {
        guard let keyword else { return [] }
        let normalized = keyword
            .precomposedStringWithCanonicalMapping
            .lowercased()
        var terms: [String] = []
        var seen = Set<String>()
        for rawTerm in normalized.split(whereSeparator: { character in
            character.unicodeScalars.allSatisfy { scalar in
                CharacterSet.whitespacesAndNewlines.contains(scalar)
                    || CharacterSet.punctuationCharacters.contains(scalar)
                    || CharacterSet.symbols.contains(scalar)
            }
        }) {
            let term = String(rawTerm)
            guard !term.isEmpty, seen.insert(term).inserted else { continue }
            terms.append(term)
        }
        return terms
    }

    private static func hasNonWhitespaceQuery(_ keyword: String?) -> Bool {
        guard let keyword else { return false }
        return !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func allowsFullProvenance(for scope: MemoryScopeFilter?) -> Bool {
        guard let scope else { return true }
        guard case .session = scope else { return false }
        return true
    }

    private static func newestFirst(_ lhs: MemoryFact, _ rhs: MemoryFact) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        if lhs.revision != rhs.revision {
            return lhs.revision > rhs.revision
        }
        return lhs.id < rhs.id
    }
}
