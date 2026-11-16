import Foundation

// MARK: - MemoryOverview

/// Snapshot of the whole memory store for settings / management UI.
public struct MemoryOverview: Sendable {
    /// Total number of stored facts.
    public let factCount: Int
    /// On-disk size of `facts.json` in bytes (0 when the file doesn't exist yet).
    public let storageBytes: Int
    /// Sum of UTF-8 byte lengths of all fact texts.
    public let textBytes: Int
    /// Fact count per category.
    public let categoryCounts: [MemoryCategory: Int]
    /// Most recent facts, newest first (capped at `recentLimit`).
    public let recentFacts: [MemoryFact]
}

// MARK: - MemoryManager

/// High-level memory management built on top of `MemoryStore`.
///
/// Provides the operations a memory-management UI needs: an overview of
/// usage, pruning of old facts, and JSON/Markdown export/import (backup or
/// transfer between stores).
///
/// Thread-safety: reads go through `MemoryStore`'s public API. Restore/import
/// is delegated to the injected `MemoryProposalConsumer`, which owns scope
/// admission, durable receipt, and the locked store transaction.
public final class MemoryManager: @unchecked Sendable {

    public let store: MemoryStore
    var overviewReadObserver: (@Sendable () -> Void)?
    public let memoryProposalConsumer: MemoryProposalConsumer

    public init(
        store: MemoryStore,
        memoryProposalConsumer: MemoryProposalConsumer? = nil
    ) {
        self.store = store
        self.memoryProposalConsumer = memoryProposalConsumer
            ?? MemoryProposalConsumer(store: store)
    }

    // MARK: - Overview

    /// Snapshot of store usage: fact count, byte usage, per-category counts
    /// and the most recent facts.
    public func overview(recentLimit: Int = 10) throws -> MemoryOverview {
        return try PersistenceTransactionFence.withRead([store.persistenceDomain]) {
            try PersistenceTransactionFence.requireLiveRead(store.persistenceDomain)
            return try {
            let facts = try store.facts()
            overviewReadObserver?()
            var categoryCounts: [MemoryCategory: Int] = [:]
            var textBytes = 0
            for fact in facts {
                categoryCounts[fact.category, default: 0] += 1
                textBytes += fact.text.utf8.count
            }
            let storageBytes = try PersistenceTransactionFence.byteCount(at: store.fileURL, domain: store.persistenceDomain)
            return MemoryOverview(
                factCount: facts.count,
                storageBytes: storageBytes,
                textBytes: textBytes,
                categoryCounts: categoryCounts,
                recentFacts: Array(facts.prefix(max(0, recentLimit)))
            )

            }()
        }
    }

    // MARK: - Pruning

    /// Trim the store down to `maxFacts` facts.
    ///
    /// - Parameter keepNewest: when `true` (default) the newest `maxFacts`
    ///   facts are kept and the oldest are removed; when `false` the oldest
    ///   `maxFacts` are kept instead.
    /// - Returns: the facts that were removed.
    @discardableResult
    public func prune(maxFacts: Int, keepNewest: Bool = true) throws -> [MemoryFact] {
        return try PersistenceTransactionFence.withWrite([store.persistenceDomain]) {
            guard maxFacts >= 0 else { return [] }
            let all = try store.facts() // newest first
            guard all.count > maxFacts else { return [] }

            let kept: [MemoryFact]
            if maxFacts == 0 {
                kept = []
            } else {
                kept = keepNewest
                    ? Array(all.prefix(maxFacts))
                    : Array(all.suffix(maxFacts))
            }
            let removed = all.filter { !kept.contains($0) }
            for fact in removed {
                try store.removeFact(id: fact.id)
            }
            return removed

        }
    }

    // MARK: - Export / Import

    /// Export all facts (newest first) as pretty-printed JSON.
    public func export() throws -> Data {
        return try PersistenceTransactionFence.withRead([store.persistenceDomain]) {
            try PersistenceTransactionFence.requireLiveRead(store.persistenceDomain)
            return try {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(store.loadFacts())

            }()
        }
    }

    /// Export all facts as a readable Markdown document.  Stable IDs and the
    /// provenance fields required for a lossless re-import live in metadata
    /// comments immediately above each visible list item.
    public func exportMarkdown() throws -> Data {
        return try PersistenceTransactionFence.withRead([store.persistenceDomain]) {
            try PersistenceTransactionFence.requireLiveRead(store.persistenceDomain)
            return try MemoryMarkdownCodec.encode(store.loadFacts())
        }
    }

    public func exportMarkdownData() throws -> Data {
        try exportMarkdown()
    }

    public func exportMarkdownString() throws -> String {
        String(decoding: try exportMarkdown(), as: UTF8.self)
    }

    /// Parse Markdown without writing.  Settings uses this as the immutable
    /// source snapshot shown to the user before a scope is selected.
    public func previewMarkdown(_ data: Data) throws -> MemoryMarkdownDocument {
        try MemoryMarkdownCodec.decode(data)
    }

    /// Import facts from JSON previously produced by `export()` (or any
    /// `[MemoryFact]`-shaped payload).
    ///
    /// The target scope is explicit. Missing scope metadata in legacy payloads
    /// is bound to that target; a different scope, invalid fact, or conflicting
    /// duplicate is rejected by the shared consumer.
    /// - Returns: the number of facts newly imported.
    @discardableResult
    public func importJSON(
        _ data: Data,
        within memoryScope: MemoryScope,
        reason: String = "memory JSON import"
    ) throws -> Int {
        return try PersistenceTransactionFence.withWrite([store.persistenceDomain]) {
            let incoming = try JSONDecoder().decode([MemoryFact].self, from: data)
            let result = try memoryProposalConsumer.restoreFacts(
                incoming,
                within: memoryScope,
                mode: .merge,
                reason: reason
            )
            return result.added

        }
    }

    /// Import a parsed Markdown document through the same scoped consumer used
    /// by JSON restore.  Scope metadata embedded in a document remains
    /// untrusted and is checked by `MemoryProposalConsumer` before any write.
    @discardableResult
    public func importMarkdown(
        _ data: Data,
        within memoryScope: MemoryScope,
        reason: String = "memory Markdown import"
    ) throws -> Int {
        let document = try MemoryMarkdownCodec.decode(data)
        let existingReceiptIDs = Set(
            try memoryProposalConsumer.restoreReceipts().map(\.restoreID)
        )
        let restored = try importFacts(document.facts, within: memoryScope, reason: reason)
        return existingReceiptIDs.contains(restored.receipt.restoreID) ? 0 : restored.added
    }

    @discardableResult
    public func importMarkdown(
        _ markdown: String,
        within memoryScope: MemoryScope,
        reason: String = "memory Markdown import"
    ) throws -> Int {
        try importMarkdown(Data(markdown.utf8), within: memoryScope, reason: reason)
    }

    /// Import facts through the shared production restore path.  This helper
    /// lets a settings consumer explicitly retarget an editable Markdown
    /// document after preview while keeping JSON compatibility unchanged.
    @discardableResult
    public func importFacts(
        _ facts: [MemoryFact],
        within memoryScope: MemoryScope,
        mode: MemoryRestoreMode = .merge,
        reason: String = "memory restore",
        trustedPrincipal: MemoryTrustedPrincipal? = nil
    ) throws -> MemoryRestoreResult {
        try PersistenceTransactionFence.withWrite([store.persistenceDomain]) {
            try memoryProposalConsumer.restoreFacts(
                facts,
                within: memoryScope,
                mode: mode,
                reason: reason,
                trustedPrincipal: trustedPrincipal
            )
        }
    }
}
