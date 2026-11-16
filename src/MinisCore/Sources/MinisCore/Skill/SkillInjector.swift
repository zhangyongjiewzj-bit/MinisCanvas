//
//  SkillInjector.swift
//  MinisCore
//
//  Given a user message, matches relevant skills (keyword match against
//  name/description) and returns the skill bodies to inject into the system
//  prompt — Claude-Codex-style progressive disclosure: metadata always known,
//  body injected only when the skill triggers.
//

import Foundation

/// Matches user messages against the skill catalog and produces injection
/// fragments for system-prompt assembly.
/// 本会话此前注入过的技能：按 ID 和内容哈希绑定。
public struct RetainedSkill: Sendable, Hashable {
    public let id: String
    public let contentHash: String
    public init(id: String, contentHash: String) {
        self.id = id
        self.contentHash = contentHash
    }
}

public final class SkillInjector: @unchecked Sendable {
    private final class RevisionClock: @unchecked Sendable {
        private let lock = NSLock()
        private var nextValue: UInt64 = 1

        func next() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            let value = nextValue
            nextValue += 1
            return value
        }
    }

    private static let revisionClock = RevisionClock()

    public let store: SkillStore

    /// Bounded, non-sensitive runtime metrics for completed injection builds.
    public let performanceMetrics: SkillInjectionPerformanceMetrics

    /// Maximum number of skill bodies injected for a single message.
    public var maxInjectedSkills: Int

    /// Minimum match score required before a skill counts as relevant.
    /// P2-5: a single CJK bigram hit scores 1 — common bigrams like
    /// 「制作」「视频」 would otherwise inject long bodies on nearly every
    /// message. Score ≥ 2 requires at least two weak hits or one token hit.
    public var minimumScore: Int

    /// Total character budget for the assembled injection fragment
    /// (header + skill blocks). Skills beyond the budget are dropped and
    /// noted as 「已省略 N 篇技能」. P2-5: bounds system-prompt token cost.
    public var maxInjectedCharacters: Int

    /// Optional per-skill body budget. Nil preserves the historical behavior.
    public var maxCharactersPerSkill: Int?

    /// Registry revision captured by this injector's turn projection.
    /// A changed live registry invalidates the injector rather than allowing
    /// an older payload to cross an enablement or restart boundary.
    public let registryRevision: String
    private let registryFingerprint: String

    private static let logger = AppLogger(category: "SkillInjector")

    public init(
        store: SkillStore,
        maxInjectedSkills: Int = 3,
        minimumScore: Int = 2,
        maxInjectedCharacters: Int = 8_000,
        maxCharactersPerSkill: Int? = nil,
        performanceMetrics: SkillInjectionPerformanceMetrics = SkillInjectionPerformanceMetrics()
    ) {
        self.store = store
        self.performanceMetrics = performanceMetrics
        self.maxInjectedSkills = maxInjectedSkills
        self.minimumScore = minimumScore
        self.maxInjectedCharacters = maxInjectedCharacters
        self.maxCharactersPerSkill = maxCharactersPerSkill
        let registry = SkillRegistry(store: store)
        self.registryFingerprint = registry.revision
        self.registryRevision = String(Self.revisionClock.next()) + ":" + registry.revision
    }

    /// Build an injector over a captured projection while preserving the
    /// caller's revision fence.  A live injector must not silently advance to
    /// a newer enablement or source revision during the same request.
    private init(
        store: SkillStore,
        maxInjectedSkills: Int,
        minimumScore: Int,
        maxInjectedCharacters: Int,
        maxCharactersPerSkill: Int?,
        registryFingerprint: String,
        registryRevision: String,
        performanceMetrics: SkillInjectionPerformanceMetrics
    ) {
        self.store = store
        self.performanceMetrics = performanceMetrics
        self.maxInjectedSkills = maxInjectedSkills
        self.minimumScore = minimumScore
        self.maxInjectedCharacters = maxInjectedCharacters
        self.maxCharactersPerSkill = maxCharactersPerSkill
        self.registryFingerprint = registryFingerprint
        self.registryRevision = registryRevision
    }

    /// Freeze all mutable SkillStore inputs for one task/turn while preserving
    /// the configured matching and character budgets.
    public func snapshotForTurn() -> SkillInjector {
        SkillInjector(
            store: store.makeSnapshotStore(),
            maxInjectedSkills: maxInjectedSkills,
            minimumScore: minimumScore,
            maxInjectedCharacters: maxInjectedCharacters,
            maxCharactersPerSkill: maxCharactersPerSkill,
            performanceMetrics: performanceMetrics
        )
    }

    /// Turn authority/configuration are copied values; no mutable live store
    /// or injector is sent to the worker. The existing lock-protected metrics
    /// sink and Sendable filesystem observer retain observation only.
    public struct TurnPreparation: Sendable {
        let capture: SkillStore.TurnCapture
        let maxInjectedSkills: Int
        let minimumScore: Int
        let maxInjectedCharacters: Int
        let maxCharactersPerSkill: Int?
        let performanceMetrics: SkillInjectionPerformanceMetrics

        @concurrent
        public func prepare() async -> SkillInjector? {
            guard let frozenStore = capture.prepareStore(), !Task.isCancelled else { return nil }
            return SkillInjector(store: frozenStore, maxInjectedSkills: maxInjectedSkills,
                minimumScore: minimumScore, maxInjectedCharacters: maxInjectedCharacters,
                maxCharactersPerSkill: maxCharactersPerSkill, performanceMetrics: performanceMetrics)
        }

        public func matchesCurrentStore(_ store: SkillStore) -> Bool {
            store.matchesTurnAuthority(capture)
        }
    }

    public func captureTurnPreparation(skillsEnabled: Bool = true) -> TurnPreparation {
        TurnPreparation(capture: store.captureTurnAuthority(),
            maxInjectedSkills: skillsEnabled ? maxInjectedSkills : 0,
            minimumScore: minimumScore, maxInjectedCharacters: maxInjectedCharacters,
            maxCharactersPerSkill: maxCharactersPerSkill, performanceMetrics: performanceMetrics)
    }

    // MARK: - Matching

    /// Skills relevant to `userMessage`, ranked by how many description
    /// keywords hit. Only enabled skills are considered.
    ///
    /// Matching rules (case-insensitive):
    /// 1. The skill's name appears as a whole word in the message → strong hit.
    /// 2. Any description token (≥3 chars, non-CJK word) appears in the message.
    /// 3. For CJK descriptions, each character bigram that appears in the
    ///    message counts as a hit (handles Chinese text without word spaces).
    public func matchingSkills(
        for userMessage: String,
        within scope: MemoryScope? = nil
    ) -> [Skill] {
        guard maxInjectedSkills > 0 else { return [] }
        let message = userMessage.lowercased()
        let messageTokens = Set(tokenize(message))
        let messageBigrams = Set(cjkBigrams(message))
        let registry = SkillRegistry(store: store)
        guard registry.revision == registryFingerprint else { return [] }

        let candidates = store.allSkills()
        let injectable = store.injectableSkills(candidates, within: scope) { skill, raw in
            registry.rejection(for: skill, content: raw) == nil
        }
        var scored: [(skill: Skill, score: Int, trustRank: Int)] = []
        for skill in candidates where injectable.contains(skill.id) {
            let nameLower = skill.name.lowercased()
            var score = 0

            // Whole-word name hit.
            if messageTokens.contains(nameLower) || containsWholePhrase(nameLower, in: message) {
                score += 10
            }

            // Description token hits (skip very short tokens and pure CJK runs
            // which produce useless single chars).
            let descTokens = tokenize(skill.description.lowercased())
            for token in descTokens where token.count >= 3 && !isMostlyCJK(token) {
                if messageTokens.contains(token) || message.contains(token) {
                    score += 2
                }
            }

            // 2026-11-15 第七版：描述写成"用途。触发：词、词……"时，二字组只在用途上计分，
            // 触发词按整个词组匹配，命中一个就够门槛；没有"触发："的描述保持原来的打分。
            let descriptionParts = skill.description.lowercased().components(separatedBy: "触发：")
            for bigram in cjkBigrams(descriptionParts[0]) where messageBigrams.contains(bigram) {
                score += 1
            }
            if descriptionParts.count > 1 {
                let triggers = descriptionParts[1].split(whereSeparator: { "、，,;；".contains($0) })
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "。"))) }
                for phrase in triggers where phrase.count >= 2 && message.contains(phrase) {
                    score += 2
                }
            }

            // P2-5: only skills meeting the minimum score threshold qualify.
            if score >= minimumScore {
                let trustRank: Int
                switch registry.entry(for: skill.id)?.trust {
                case .some(.bundled): trustRank = 0
                case .some(.local): trustRank = 1
                case .some(.untrusted), .none: trustRank = 2
                }
                scored.append((skill, score, trustRank))
            }
        }

        return scored
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                if $0.trustRank != $1.trustRank { return $0.trustRank < $1.trustRank }
                return $0.skill.id < $1.skill.id
            }
            .prefix(maxInjectedSkills)
            .map(\.skill)
    }

    // MARK: - Injection

    /// Skill bodies to inject for a message (the SKILL.md body text only).
    public func injectableBodies(
        for userMessage: String,
        within scope: MemoryScope? = nil
    ) -> [String] {
        matchingSkills(for: userMessage, within: scope).compactMap { store.skillContent($0.id) }
    }

    /// Build a ready-to-append system-prompt fragment:
    ///
    ///     <injected_skills>
    ///     <skill name="...">
    ///     ...body...
    ///     </skill>
    ///     </injected_skills>
    ///
    /// Returns nil when nothing matches or nothing fits the character budget.
    public func buildInjectionFragment(
        for userMessage: String,
        within scope: MemoryScope? = nil
    ) -> String? {
        buildInjection(for: userMessage, within: scope).fragment
    }

    /// Build a prompt fragment together with immutable, value-only receipts.
    /// Every matched candidate gets a receipt, including candidates omitted by
    /// either the per-skill or total character budget.
    public func buildInjection(
        for userMessage: String,
        within scope: MemoryScope? = nil
    ) -> SkillInjectionResult {
        buildInjection(for: userMessage, selectedSkillIDs: [], within: scope)
    }

    /// Build the normal automatic injection and force the supplied canonical
    /// skill IDs through the same registry, manifest, trust, enablement and
    /// receipt path. Picker catalog content is never consumed here.
    public func buildInjection(
        for userMessage: String,
        selectedSkillIDs: [String],
        retainedSkills: [RetainedSkill] = [],
        within scope: MemoryScope? = nil
    ) -> SkillInjectionResult {
        // Matching, body reads, manifest hashes and receipts must all come
        // from one immutable projection.  The BridgeStore fallback consumer
        // owns a live injector, so separate reads can otherwise match an
        // enabled revision and inject its stale body after a source change.
        let projected = SkillInjector(
            store: store.makeSnapshotStore(),
            maxInjectedSkills: maxInjectedSkills,
            minimumScore: minimumScore,
            maxInjectedCharacters: maxInjectedCharacters,
            maxCharactersPerSkill: maxCharactersPerSkill,
            registryFingerprint: registryFingerprint,
            registryRevision: registryRevision,
            performanceMetrics: performanceMetrics
        )
        return projected.buildInjectionOnProjection(
            for: userMessage,
            selectedSkillIDs: selectedSkillIDs,
            retainedSkills: retainedSkills,
            within: scope
        )
    }

    /// Enabled, trusted skills that may be injected in `scope`, in store order.
    private func injectableCandidates(within scope: MemoryScope?) -> [Skill] {
        let registry = SkillRegistry(store: store)
        guard registry.revision == registryFingerprint else { return [] }
        let candidates = store.allSkills()
        let injectable = store.injectableSkills(candidates, within: scope) { skill, raw in
            registry.rejection(for: skill, content: raw) == nil
        }
        return candidates.filter { injectable.contains($0.id) }
    }

    /// 2026-11-15 提示词方案 v2：每回合常驻的技能目录（名字 + 一句话用途）。
    /// 只列当前作用域可注入的技能；正文仍按相关性注入。
    public func catalogFragment(within scope: MemoryScope? = nil, maxCharacters: Int = 600) -> String? {
        guard maxInjectedSkills > 0 else { return nil }
        let skills = injectableCandidates(within: scope)
        guard !skills.isEmpty else { return nil }
        let open = "<skill_catalog>\n可用技能（名称：用途）。与任务相关的技能正文会另行附上：\n"
        let close = "</skill_catalog>"
        var body = ""
        var listed = 0
        for skill in skills {
            // 描述里"触发："之后是给匹配用的触发词，目录里只显示前面的用途。
            let purpose = (skill.description.components(separatedBy: "触发：").first ?? skill.description)
                .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "。")))
            let line = "- " + xmlEscape(skill.name, attribute: false)
                + (purpose.isEmpty ? "" : "：" + xmlEscape(String(purpose.prefix(60)), attribute: false)) + "\n"
            if open.count + body.count + line.count + close.count + 16 > maxCharacters { break }
            body += line
            listed += 1
        }
        guard listed > 0 else { return nil }
        if listed < skills.count { body += "（另有 \(skills.count - listed) 个未列出）\n" }
        return open + body + close
    }

    private func buildInjectionOnProjection(
        for userMessage: String,
        selectedSkillIDs: [String],
        retainedSkills: [RetainedSkill] = [],
        within scope: MemoryScope?
    ) -> SkillInjectionResult {
        let measurement = performanceMetrics.beginBuild()
        let matched = matchingSkills(for: userMessage, within: scope)
        let selected = selectedSkillCandidates(
            ids: selectedSkillIDs,
            request: userMessage,
            within: scope
        )
        // An explicit picker selection is a user request and therefore gets
        // priority over the bounded automatic ranking.  Keep the automatic
        // candidates afterward, de-duplicated by canonical skill ID.
        var seen = Set<String>()
        let forced = selected.accepted.filter { seen.insert($0.id).inserted }
        let automatic = matched.filter { seen.insert($0.id).inserted }
        // 本会话此前命中过的技能（最多 2 篇）排在本回合新命中的之后，
        // 走同一套信任、作用域和字数预算；已不可注入的静默跳过。
        let retained: [Skill]
        if retainedSkills.isEmpty {
            retained = []
        } else {
            // 内容变了（例如同名技能更新后重新批准）就不再保持，要重新命中才注入。
            let available = injectableCandidates(within: scope)
            retained = retainedSkills.prefix(2).compactMap { kept in
                available.first {
                    $0.id == kept.id && store.rawContent($0.id).map(SkillManifest.hash) == kept.contentHash
                }
            }.filter { seen.insert($0.id).inserted }
        }
        let generated = buildInjection(
            for: forced + automatic + retained,
            userMessage: userMessage
        )
        let result = SkillInjectionResult(
            fragment: generated.fragment,
            receipts: generated.receipts + selected.rejected
        )
        let eligibleCandidateCount = forced.count + automatic.count + retained.count
        performanceMetrics.complete(
            measurement,
            eligibleCandidateCount: eligibleCandidateCount,
            errorClass: performanceErrorClass(
                for: result,
                eligibleCandidateCount: eligibleCandidateCount
            )
        )
        return result
    }

    private func performanceErrorClass(
        for result: SkillInjectionResult,
        eligibleCandidateCount: Int
    ) -> SkillInjectionBuildErrorClass {
        if maxInjectedSkills <= 0 || maxInjectedCharacters <= 0 {
            return .budgetDisabled
        }
        let isRegistryRejection: (SkillInjectionReceipt) -> Bool = { receipt in
            switch receipt.omittedReason {
            case "missing_registry_entry", "registry_revision_changed", "scope_rejected":
                return true
            default:
                return false
            }
        }
        guard eligibleCandidateCount > 0 else {
            return result.receipts.contains(where: isRegistryRejection)
                ? .registryRejected
                : .noEligibleCandidates
        }
        guard result.receipts.contains(where: { $0.omittedReason != nil }) else {
            return .none
        }
        if result.receipts.contains(where: isRegistryRejection) {
            return .registryRejected
        }
        return result.fragment == nil ? .allCandidatesRejected : .partiallyRejected
    }

    private func selectedSkillCandidates(
        ids: [String],
        request: String,
        within scope: MemoryScope?
    ) -> (accepted: [Skill], rejected: [SkillInjectionReceipt]) {
        var seen = Set<String>()
        let normalizedIDs = ids.compactMap { rawID -> String? in
            let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = trimmed.hasPrefix("skill:")
                ? String(trimmed.dropFirst("skill:".count))
                : trimmed
            guard !id.isEmpty, seen.insert(id).inserted else { return nil }
            return id
        }
        guard !normalizedIDs.isEmpty else { return ([], []) }

        let initialRegistry = SkillRegistry(store: store)
        guard maxInjectedSkills > 0, maxInjectedCharacters > 0 else {
            let skillsByID = Dictionary(uniqueKeysWithValues: store.allSkills().map { ($0.id, $0) })
            return ([], normalizedIDs.map { skillID in
                Self.rejectedSelectionReceipt(
                    skillID: skillID,
                    skill: skillsByID[skillID],
                    registry: initialRegistry,
                    request: request,
                    budget: max(0, maxInjectedCharacters),
                    reason: "injection_budget_disabled"
                )
            })
        }
        var accepted: [Skill] = []
        var rejected: [SkillInjectionReceipt] = []
        for skillID in normalizedIDs {
            let skill = store.allSkills().first { $0.id == skillID }
            guard let skill else {
                rejected.append(Self.rejectedSelectionReceipt(
                    skillID: skillID,
                    skill: nil,
                    registry: initialRegistry,
                    request: request,
                    budget: maxInjectedCharacters,
                    reason: "missing_registry_entry"
                ))
                continue
            }
            guard initialRegistry.revision == registryFingerprint else {
                rejected.append(Self.rejectedSelectionReceipt(
                    skillID: skillID,
                    skill: skill,
                    registry: initialRegistry,
                    request: request,
                    budget: maxInjectedCharacters,
                    reason: "registry_revision_changed"
                ))
                continue
            }
            guard store.isInjectable(skill, within: scope) else {
                let currentRegistry = SkillRegistry(store: store)
                let reason = currentRegistry.rejection(
                    for: skill,
                    content: store.rawContent(skill.id)
                )?.rawValue ?? "scope_rejected"
                rejected.append(Self.rejectedSelectionReceipt(
                    skillID: skillID,
                    skill: skill,
                    registry: currentRegistry,
                    request: request,
                    budget: maxInjectedCharacters,
                    reason: reason
                ))
                continue
            }
            let currentRegistry = SkillRegistry(store: store)
            guard currentRegistry.revision == registryFingerprint,
                  currentRegistry.rejection(
                      for: skill,
                      content: store.rawContent(skill.id)
                  ) == nil else {
                let reason = currentRegistry.rejection(
                    for: skill,
                    content: store.rawContent(skill.id)
                )?.rawValue ?? "registry_revision_changed"
                rejected.append(Self.rejectedSelectionReceipt(
                    skillID: skillID,
                    skill: skill,
                    registry: currentRegistry,
                    request: request,
                    budget: maxInjectedCharacters,
                    reason: reason
                ))
                continue
            }
            accepted.append(skill)
        }
        return (accepted, rejected)
    }

    private static func rejectedSelectionReceipt(
        skillID: String,
        skill: Skill?,
        registry: SkillRegistry,
        request: String,
        budget: Int,
        reason: String
    ) -> SkillInjectionReceipt {
        let entry = skill.flatMap { registry.entry(for: $0.id) }
        let contentHash = entry?.contentHash ?? skill?.integrity.manifest?.contentHash ?? ""
        let sourceIdentity = entry?.sourceIdentity
            ?? (skill == nil ? "skill-picker:missing:\(skillID)" :
                SkillInjectionReceipt.expectedSourceIdentity(
                    skillID: skillID,
                    contentHash: contentHash
                ))
        return SkillInjectionReceipt(
            receiptID: stableReceiptID(
                skillID: skillID,
                version: skill?.version ?? "unknown",
                contentHash: contentHash,
                reason: reason
            ),
            request: request,
            skillID: skill?.id ?? skillID,
            version: skill?.version ?? "unknown",
            contentHash: contentHash,
            matchedTerms: skill.map { [$0.name] } ?? [],
            injectedCharacters: 0,
            budget: budget,
            omittedReason: reason,
            sourceIdentity: sourceIdentity,
            state: .rejected
        )
    }

    private func buildInjection(
        for matched: [Skill],
        userMessage: String
    ) -> SkillInjectionResult {
        guard maxInjectedSkills > 0, maxInjectedCharacters > 0, !matched.isEmpty else {
            return SkillInjectionResult(fragment: nil, receipts: [])
        }
        let headerOpen = "<injected_skills>\n"
        let headerClose = "</injected_skills>"
        var xml = headerOpen
        var injectedNames: [String] = []
        var omitted = 0
        var receipts: [SkillInjectionReceipt] = []
        for skill in matched {
            if injectedNames.count >= maxInjectedSkills {
                let contentHash = store.rawContent(skill.id).map(SkillManifest.hash) ?? ""
                receipts.append(SkillInjectionReceipt(
                    receiptID: Self.stableReceiptID(
                        skillID: skill.id,
                        version: skill.version,
                        contentHash: contentHash,
                        reason: "max_injected_skills"
                    ),
                    request: userMessage,
                    skillID: skill.id,
                    version: skill.version,
                    contentHash: contentHash,
                    matchedTerms: matchedTerms(for: skill, in: userMessage),
                    injectedCharacters: 0,
                    budget: maxInjectedCharacters,
                    omittedReason: "max_injected_skills",
                    state: .rejected
                ))
                omitted += 1
                continue
            }
            let escapedName = xmlEscape(skill.name, attribute: true)
            var block = "<skill name=\"\(escapedName)\">\n"
            let body = store.skillContent(skill.id) ?? ""
            if !body.isEmpty {
                block += xmlEscape(body, attribute: false) + "\n"
            }
            block += "</skill>\n"
            let contentHash = store.rawContent(skill.id).map(SkillManifest.hash) ?? ""
            let terms = matchedTerms(for: skill, in: userMessage)
            if let maxCharactersPerSkill, body.count > maxCharactersPerSkill {
                omitted += 1
                receipts.append(SkillInjectionReceipt(
                    receiptID: Self.stableReceiptID(
                        skillID: skill.id,
                        version: skill.version,
                        contentHash: contentHash,
                        reason: "skill_character_budget"
                    ),
                    skillID: skill.id,
                    version: skill.version,
                    contentHash: contentHash,
                    matchedTerms: terms,
                    injectedCharacters: 0,
                    omittedReason: "skill_character_budget"
                ))
                continue
            }
            // P2-5: enforce the total character budget on the assembled
            // fragment; skills that don't fit are dropped and counted.
            // Always reserve room for the omission marker + closing tag so
            // the final fragment fits within maxInjectedCharacters.
            let markerReserve = omittedMarker(for: matched.count).count
            if xml.count + block.count + headerClose.count + markerReserve > maxInjectedCharacters {
                omitted += 1
                receipts.append(SkillInjectionReceipt(
                    receiptID: Self.stableReceiptID(
                        skillID: skill.id,
                        version: skill.version,
                        contentHash: contentHash,
                        reason: "total_character_budget"
                    ),
                    skillID: skill.id,
                    version: skill.version,
                    contentHash: contentHash,
                    matchedTerms: terms,
                    injectedCharacters: 0,
                    omittedReason: "total_character_budget"
                ))
                continue
            }
            xml += block
            injectedNames.append(skill.name)
            receipts.append(SkillInjectionReceipt(
                receiptID: Self.stableReceiptID(
                    skillID: skill.id,
                    version: skill.version,
                    contentHash: contentHash,
                    reason: nil
                ),
                skillID: skill.id,
                version: skill.version,
                contentHash: contentHash,
                matchedTerms: terms,
                injectedCharacters: block.count
            ))
        }
        guard !injectedNames.isEmpty else {
            Self.logger.info("skill injection skipped: \(matched.count) skill(s) matched but none fit the \(maxInjectedCharacters)-char budget")
            return SkillInjectionResult(fragment: nil, receipts: receipts)
        }
        if omitted > 0 {
            xml += omittedMarker(for: omitted)
        }
        xml += headerClose
        // P2-5: observability — record exactly which skills were injected.
        Self.logger.info("skill injection: injected=[\(injectedNames.joined(separator: ", "))] omitted=\(omitted) chars=\(xml.count)")
        return SkillInjectionResult(fragment: xml, receipts: receipts)
    }

    private static func stableReceiptID(
        skillID: String,
        version: String,
        contentHash: String,
        reason: String?
    ) -> UUID {
        SkillInjectionReceipt.stableID(
            skillID: skillID,
            version: version,
            contentHash: contentHash,
            reason: reason
        )
    }

    private func matchedTerms(for skill: Skill, in userMessage: String) -> [String] {
        let message = userMessage.lowercased()
        let tokens = Set(tokenize(message))
        var terms: [String] = []
        if containsWholePhrase(skill.name.lowercased(), in: message) {
            terms.append(skill.name)
        }
        for token in tokenize(skill.description.lowercased())
        where token.count >= 3
            && !isMostlyCJK(token)
            && (tokens.contains(token) || message.contains(token)) {
            terms.append(token)
        }
        for bigram in cjkBigrams(skill.description.lowercased())
        where message.contains(bigram) {
            terms.append(bigram)
        }
        return Array(Set(terms)).sorted()
    }

    private func containsWholePhrase(_ phrase: String, in message: String) -> Bool {
        guard !phrase.isEmpty else { return false }
        var searchStart = message.startIndex
        while searchStart < message.endIndex,
              let range = message.range(of: phrase, options: [], range: searchStart..<message.endIndex) {
            let beforeIsWord = range.lowerBound > message.startIndex
                && message[message.index(before: range.lowerBound)].isLetter
            let afterIsWord = range.upperBound < message.endIndex
                && message[range.upperBound].isLetter
            if !beforeIsWord && !afterIsWord { return true }
            searchStart = range.upperBound
        }
        return false
    }

    private func xmlEscape(_ value: String, attribute: Bool) -> String {
        var result = value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        if attribute {
            result = result.replacingOccurrences(of: "\"", with: "&quot;")
        }
        return result
    }

    private func omittedMarker(for count: Int) -> String {
        "…（已省略 \(count) 篇技能）\n"
    }

    // MARK: - Tokenization

    /// Split on non-alphanumeric characters (Unicode letters survive, so CJK
    /// text becomes a single token).
    private func tokenize(_ text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private func isMostlyCJK(_ token: String) -> Bool {
        let cjk = token.filter { $0.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
        } }
        return !cjk.isEmpty && Double(cjk.count) / Double(token.count) > 0.6
    }

    /// CJK character bigrams for substring matching in space-less Chinese.
    private func cjkBigrams(_ text: String) -> Set<String> {
        let chars = Array(text.filter { $0.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
        } })
        guard chars.count >= 2 else { return [] }
        var bigrams = Set<String>()
        for i in 0..<(chars.count - 1) {
            bigrams.insert(String(chars[i...i + 1]))
        }
        return bigrams
    }
}

/// Stable, explicit receipt vocabulary consumed by production prompt builders.
/// The stored fields remain source-compatible while these aliases make the
/// injected/skipped decision and its reason unambiguous to downstream callers.
public extension SkillInjectionReceipt {
    static func stableID(
        skillID: String,
        version: String,
        contentHash: String,
        reason: String?
    ) -> UUID {
        let seed = [skillID, version, contentHash, reason ?? "injected"].joined(separator: "|")
        let hex = Array(SkillManifest.hash(seed))
        let uuidText = [
            String(hex[0..<8]),
            String(hex[8..<12]),
            String(hex[12..<16]),
            String(hex[16..<20]),
            String(hex[20..<32])
        ].joined(separator: "-")
        return UUID(uuidString: uuidText) ?? UUID()
    }

    var injected: Bool { injectedCharacters > 0 && omittedReason == nil }
    var skipped: Bool { !injected }
    var reason: String? { omittedReason }
    var hash: String { contentHash }
}
