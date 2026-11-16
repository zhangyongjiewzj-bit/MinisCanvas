import Foundation

// MARK: - MemorySearchDisplayConsumer

/// User-visible projection of one local memory retrieval result.
///
/// This projection is deliberately separate from prompt assembly. It carries
/// the fact text, creation time, source visibility and lexical explanation so
/// a UI can explain a result without placing retrieval metadata in a model
/// prompt.
public struct MemorySearchDisplayItem: Equatable, Identifiable, Sendable {
    public let factID: String
    public let text: String
    public let createdAt: Date
    public let revision: Int
    public let score: Int
    public let matchedTerms: [String]
    public let sourceDescription: String
    public let sourceRef: String?
    public let provenanceRedacted: Bool
    public let recallExplanation: String

    public var id: String { factID }

    /// Stable, locale-independent value suitable for a compact UI timestamp.
    public var createdAtLabel: String {
        ISO8601DateFormatter().string(from: createdAt)
    }
}

public struct MemorySearchDisplayResult: Equatable, Sendable {
    public let items: [MemorySearchDisplayItem]
    public let explanation: String

    public var isEmpty: Bool { items.isEmpty }
}

public enum MemorySearchDisplayError: Error, Equatable, Sendable {
    /// The store changed between the hit projection and its display join.
    case inconsistentFact(String)
}

/// Independent consumer for a user-facing local retrieval view.
///
/// `MemorySearch` owns matching, scope filtering and ranking. This consumer
/// only joins each hit with the active fact needed for visible text/time and
/// produces explainable display fields. It never writes memory or assembles a
/// model-facing prompt.
public struct MemorySearchDisplayConsumer: Sendable {
    public let search: MemorySearch

    public init(search: MemorySearch) {
        self.search = search
    }

    public func retrieve(
        categories: Set<MemoryCategory>? = nil,
        keyword: String? = nil,
        from: Date? = nil,
        to: Date? = nil,
        scope: MemoryScopeFilter? = nil
    ) throws -> MemorySearchDisplayResult {
        // A user-visible projection must never fall back to the store-wide
        // active-facts read when the host has no concrete scope. Callers can
        // still use MemorySearch directly for its lower-level unscoped API.
        guard let scope, scope.isValid else {
            return MemorySearchDisplayResult(
                items: [],
                explanation: "未提供有效的记忆作用域，检索已拒绝。"
            )
        }

        // Both store reads and the display join belong to one admitted view.
        // The store's own nested reads reuse this admission; a concurrent edit
        // cannot pair an old hit with new text or provenance.
        return try PersistenceTransactionFence.withRead([search.store.persistenceDomain]) {
            let activeFacts = try search.store.activeFactsForDisplay(within: scope)
            let hits = try search.searchHits(
                categories: categories,
                keyword: keyword,
                from: from,
                to: to,
                scope: scope,
                displayFacts: activeFacts
            )
            let items = try Self.displayItems(hits: hits, activeFacts: activeFacts)
            let explanation: String
            if items.isEmpty {
                explanation = "当前作用域没有匹配的本地记忆。"
            } else {
                explanation = "本地检索命中 \(items.count) 条；结果按命中词数、创建时间、修订号和事实 ID 稳定排序。"
            }
            return MemorySearchDisplayResult(items: items, explanation: explanation)
        }
    }

    /// Read only the profile document and the active facts of the verified owner.
    public func retrieveUserLevel(
        keyword: String, trustedPrincipal: MemoryTrustedPrincipal?, files: MemoryFileStore
    ) throws -> (facts: MemorySearchDisplayResult, globalDocumentMatched: Bool) {
        let terms = MemorySearch.retrievalTerms(for: keyword)
        let items: [MemorySearchDisplayItem]
        if let trustedPrincipal, !terms.isEmpty {
            items = try PersistenceTransactionFence.withRead([search.store.persistenceDomain]) {
                let active = try search.store.activeFacts().filter {
                    $0.visibility == .personal && $0.ownerUserID == trustedPrincipal.userID
                }
                let hits = try search.searchHits(keyword: keyword, scope: .user(userID: trustedPrincipal.userID),
                    displayFacts: active)
                return try Self.displayItems(hits: hits, activeFacts: active)
            }
        } else {
            items = []
        }
        let document = !terms.isEmpty ? try files.readGlobalForInjection() : nil
        let globalDocumentMatched = document.map {
            let text = $0.precomposedStringWithCanonicalMapping.lowercased()
            return terms.contains(where: { text.contains($0) })
        } ?? false
        let explanation = trustedPrincipal == nil
            ? "未确认当前用户身份，仅检索全局记忆文档。"
            : "在当前用户的个人事实和全局记忆文档中检索。"
        return (MemorySearchDisplayResult(items: items, explanation: explanation), globalDocumentMatched)
    }

    static func displayItems(
        hits: [MemorySearchHit],
        activeFacts: [MemoryFact]
    ) throws -> [MemorySearchDisplayItem] {
        let factsByID = Dictionary(uniqueKeysWithValues: activeFacts.map { ($0.id, $0) })
        return try hits.map { hit in
            guard let fact = factsByID[hit.factID],
                  fact.revision == hit.revision,
                  fact.contentDigest == hit.sourceDigest,
                  hit.provenanceRedacted || (
                    fact.sourceProposalID == hit.sourceProposalID
                        && fact.sourceRef == hit.sourceRef
                  ) else {
                throw MemorySearchDisplayError.inconsistentFact(hit.factID)
            }
            return MemorySearchDisplayItem(
                factID: fact.id,
                text: fact.text,
                createdAt: fact.createdAt,
                revision: fact.revision,
                score: hit.score,
                matchedTerms: hit.matchedTerms,
                sourceDescription: Self.sourceDescription(for: hit),
                sourceRef: hit.provenanceRedacted ? nil : hit.sourceRef,
                provenanceRedacted: hit.provenanceRedacted,
                recallExplanation: Self.recallExplanation(for: hit)
            )
        }
    }

    private static func sourceDescription(for hit: MemorySearchHit) -> String {
        if hit.provenanceRedacted {
            return "当前作用域（来源详情已隐藏）"
        }
        if let sourceRef = hit.sourceRef,
           !sourceRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return sourceRef
        }
        if let proposalID = hit.sourceProposalID,
           !proposalID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "记忆 proposal \(proposalID)"
        }
        return "本地记忆（未记录来源）"
    }

    private static func recallExplanation(for hit: MemorySearchHit) -> String {
        if hit.matchedTerms.isEmpty {
            return "未提供关键词；按创建时间、修订号和事实 ID 排序。"
        }
        let terms = hit.matchedTerms.joined(separator: "、")
        return "命中 \(hit.score) 个检索词（\(terms)）；按命中词数、创建时间、修订号和事实 ID 排序。"
    }
}
