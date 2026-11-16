import CryptoKit
import Foundation

/// Local trust classification for a skill payload. It never grants execution privilege.
public enum SkillTrust: String, Codable, Equatable, Sendable {
    case bundled
    case local
    case untrusted
}

public enum SkillLifecycleAction: String, Codable, Equatable, Sendable {
    case propose
    case approve
    case activate
    case rollback
    case quarantine
}

public enum SkillLifecycleState: String, Codable, Equatable, Sendable {
    case proposed
    case approved
    case active
    case rolledBack
    case quarantined
}

/// Stable enablement projection shared by settings and injection receipts.
/// The projection intentionally has no executable or source-payload state.
public enum SkillEnablementState: String, Codable, Equatable, Sendable {
    case pending
    case rejected
    case active
    case rollback
}

/// Stable, credential-free manifest for a local SKILL.md payload.
public struct SkillManifest: Codable, Equatable, Sendable {
    public static let currentSchema = "miniscore.skill-manifest"
    public static let currentVersion = 1

    public let schema: String
    public let version: Int
    public let skillID: String
    public let name: String
    public let contentHash: String
    public let trust: SkillTrust

    /// Stable, credential-free identity for the source revision. The
    /// identity deliberately contains the skill id and payload hash only;
    /// URLs and local paths are not persisted as trust claims.
    public var sourceIdentity: String {
        "skill:\(skillID)@\(contentHash)"
    }

    /// Validate the fields that make a manifest safe to persist and compare
    /// at a deployment boundary. Content itself is checked by the registry.
    public var rejection: SkillLifecycleRejection? {
        let trimmedID = skillID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty, !trimmedName.isEmpty,
              skillID == trimmedID,
              skillID != ".", skillID != "..",
              !skillID.contains("/"), !skillID.contains("\\"),
              !skillID.unicodeScalars.contains(where: { $0.value < 0x20 })
        else { return .invalidIdentity }
        guard schema == Self.currentSchema else { return .invalidIdentity }
        guard version == Self.currentVersion else { return .invalidVersion }
        guard Self.isValidContentHash(contentHash) else { return .emptyContentHash }
        guard trust != .untrusted else { return .untrusted }
        return nil
    }

    public init(skillID: String, name: String, content: String, trust: SkillTrust,
                schema: String = SkillManifest.currentSchema,
                version: Int = SkillManifest.currentVersion) {
        self.schema = schema
        self.version = version
        self.skillID = skillID
        self.name = name
        self.contentHash = Self.hash(content)
        self.trust = trust
    }

    public static func hash(_ content: String) -> String {
        SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func isValidContentHash(_ hash: String) -> Bool {
        hash.count == 64 && hash.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57)
                || (scalar.value >= 97 && scalar.value <= 102)
        }
    }
}

public enum SkillLifecycleRejection: String, Codable, Equatable, Sendable {
    case invalidIdentity
    case invalidVersion
    case emptyContentHash
    case untrusted
    case hashChanged
    case invalidTransition
    case invalidApproval
    case expired
}

/// Explicit approval supplied by the user-facing review boundary.
///
/// The store may create a proposal without this value, but it must never
/// create an active receipt without a non-empty approver identity.
public struct SkillApproval: Equatable, Sendable {
    public let approverID: String
    public let scope: MemoryScope?
    public let expiresAt: Date?

    public init(
        approverID: String,
        scope: MemoryScope? = nil,
        expiresAt: Date? = nil
    ) {
        self.approverID = approverID
        self.scope = scope
        self.expiresAt = expiresAt
    }
}

/// A value-only receipt. It records lifecycle intent and does not execute a skill.
public struct SkillLifecycleReceipt: Codable, Equatable, Sendable {
    public let receiptID: String
    public let skillID: String
    public let contentHash: String
    public let trust: SkillTrust
    public let action: SkillLifecycleAction
    public let state: SkillLifecycleState
    public let reason: String
    public let approvedBy: String?
    public let scope: MemoryScope?
    public let expiresAt: Date?
    public let previousContentHash: String?
    /// Source revision identity carried with the lifecycle proof. It is
    /// derived when decoding older receipts so restart remains fail-closed.
    public let sourceIdentity: String

    /// User-facing enablement state derived from the durable lifecycle proof.
    /// Proposed and approved receipts remain pending until activation.
    public var enablementState: SkillEnablementState {
        switch state {
        case .proposed, .approved: return .pending
        case .active: return .active
        case .rolledBack: return .rollback
        case .quarantined: return .rejected
        }
    }

    public init(
        skillID: String,
        contentHash: String,
        trust: SkillTrust,
        action: SkillLifecycleAction,
        state: SkillLifecycleState,
        reason: String,
        receiptID: String = UUID().uuidString,
        approvedBy: String? = nil,
        scope: MemoryScope? = nil,
        expiresAt: Date? = nil,
        previousContentHash: String? = nil,
        sourceIdentity: String? = nil
    ) {
        self.receiptID = receiptID
        self.skillID = skillID
        self.contentHash = contentHash
        self.trust = trust
        self.action = action
        self.state = state
        self.reason = reason
        self.approvedBy = approvedBy
        self.scope = scope
        self.expiresAt = expiresAt
        self.previousContentHash = previousContentHash
        self.sourceIdentity = sourceIdentity ?? "skill:\(skillID)@\(contentHash)"
    }

    private enum CodingKeys: String, CodingKey {
        case receiptID, skillID, contentHash, trust, action, state, reason
        case approvedBy, scope, expiresAt, previousContentHash
        case sourceIdentity
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.receiptID = try c.decodeIfPresent(String.self, forKey: .receiptID) ?? UUID().uuidString
        self.skillID = try c.decode(String.self, forKey: .skillID)
        self.contentHash = try c.decode(String.self, forKey: .contentHash)
        self.trust = try c.decode(SkillTrust.self, forKey: .trust)
        self.action = try c.decode(SkillLifecycleAction.self, forKey: .action)
        self.state = try c.decode(SkillLifecycleState.self, forKey: .state)
        self.reason = try c.decode(String.self, forKey: .reason)
        self.approvedBy = try c.decodeIfPresent(String.self, forKey: .approvedBy)
        self.scope = try c.decodeIfPresent(MemoryScope.self, forKey: .scope)
        self.expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
        self.previousContentHash = try c.decodeIfPresent(String.self, forKey: .previousContentHash)
        self.sourceIdentity = try c.decodeIfPresent(String.self, forKey: .sourceIdentity)
            ?? "skill:\(skillID)@\(contentHash)"
    }
}

/// Result of a production skill import. The receipt is the only proof that
/// the imported content crossed the lifecycle boundary and may be injected.
public struct SkillLifecycleImportResult: Sendable {
    public let skill: Skill
    public let receipt: SkillLifecycleReceipt

    public init(skill: Skill, receipt: SkillLifecycleReceipt) {
        self.skill = skill
        self.receipt = receipt
    }
}

/// Pure local state machine for Skill proposal, approval, activation, quarantine and rollback.
public enum SkillLifecycle {
    public static func propose(
        _ manifest: SkillManifest,
        scope: MemoryScope? = nil,
        reason: String
    ) -> SkillLifecycleReceipt {
        if let rejection = manifest.rejection {
            return SkillLifecycleReceipt(
                skillID: manifest.skillID,
                contentHash: manifest.contentHash,
                trust: manifest.trust,
                action: .quarantine,
                state: .quarantined,
                reason: "manifest rejected: \(rejection.rawValue)",
                scope: scope,
                sourceIdentity: manifest.sourceIdentity
            )
        }
        return SkillLifecycleReceipt(skillID: manifest.skillID, contentHash: manifest.contentHash,
                              trust: manifest.trust, action: .propose,
                              state: manifest.trust == .untrusted ? .quarantined : .proposed,
                              reason: reason, scope: scope,
                              sourceIdentity: manifest.sourceIdentity)
    }

    /// Compatibility-only transition for existing pure-contract callers.
    /// Production stores must use the explicit `SkillApproval` overload.
    public static func approve(_ proposal: SkillLifecycleReceipt, reason: String) -> SkillLifecycleReceipt? {
        approve(
            proposal,
            approval: SkillApproval(approverID: "legacy-explicit-boundary", scope: proposal.scope),
            reason: reason
        )
    }

    public static func approve(
        _ proposal: SkillLifecycleReceipt,
        approval: SkillApproval,
        reason: String
    ) -> SkillLifecycleReceipt? {
        guard proposal.action == .propose,
              proposal.state == .proposed,
              proposal.trust != .untrusted,
              !approval.approverID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              proposal.scope == approval.scope,
              approval.expiresAt.map({ $0 > Date() }) ?? true
        else { return nil }
        return SkillLifecycleReceipt(
            skillID: proposal.skillID,
            contentHash: proposal.contentHash,
            trust: proposal.trust,
            action: .approve,
            state: .approved,
            reason: reason,
            approvedBy: approval.approverID,
            scope: approval.scope,
            expiresAt: approval.expiresAt,
            sourceIdentity: proposal.sourceIdentity
        )
    }

    public static func activate(_ approval: SkillLifecycleReceipt, currentContentHash: String, reason: String) -> SkillLifecycleReceipt? {
        guard approval.action == .approve, approval.state == .approved,
              approval.trust != .untrusted,
              approval.approvedBy.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) == true,
              approval.contentHash == currentContentHash,
              approval.expiresAt.map({ $0 > Date() }) ?? true else { return nil }
        return SkillLifecycleReceipt(
            skillID: approval.skillID,
            contentHash: approval.contentHash,
            trust: approval.trust,
            action: .activate,
            state: .active,
            reason: reason,
            approvedBy: approval.approvedBy,
            scope: approval.scope,
            expiresAt: approval.expiresAt,
            sourceIdentity: approval.sourceIdentity
        )
    }

    /// Validate the receipt a production consumer is about to honor.
    /// This is value-only and fails closed on missing approval, scope drift,
    /// expiry, or content drift.
    public static func isActivationValid(
        _ receipt: SkillLifecycleReceipt,
        currentContentHash: String,
        scope: MemoryScope? = nil,
        now: Date = Date()
    ) -> Bool {
        guard receipt.action == .activate,
              receipt.state == .active,
              receipt.trust != .untrusted,
              receipt.approvedBy.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) == true,
              receipt.contentHash == currentContentHash,
              (receipt.scope == scope || (
                  receipt.scope == nil && isExplicitGlobalApprover(receipt.approvedBy)
              )),
              receipt.expiresAt.map({ $0 > now }) ?? true,
              receipt.sourceIdentity == "skill:\(receipt.skillID)@\(receipt.contentHash)"
        else { return false }
        return true
    }

    // SkillsStore's Settings review and SkillStore's explicit user import
    // supply these markers. Composer and legacy migration use other markers.
    private static func isExplicitGlobalApprover(_ approver: String?) -> Bool {
        guard let approver else { return false }
        return approver.hasPrefix("settings-explicit-review:") || approver == "explicit-user-import"
    }

    public static func rollback(
        _ active: SkillLifecycleReceipt,
        previousContentHash: String? = nil,
        previousReceipt: SkillLifecycleReceipt? = nil,
        reason: String
    ) -> SkillLifecycleReceipt? {
        let selectedContentHash = previousContentHash
            ?? previousReceipt?.contentHash
            ?? active.contentHash
        guard [.propose, .approve, .activate].contains(active.action),
              [.proposed, .approved, .active].contains(active.state),
              active.trust != .untrusted,
              active.sourceIdentity == "skill:\(active.skillID)@\(active.contentHash)",
              isValidContentHash(selectedContentHash),
              previousContentHash.map({ $0 == selectedContentHash }) ?? true
        else { return nil }

        if let previousReceipt {
            guard previousReceipt.skillID == active.skillID,
                  previousReceipt.action == .activate,
                  previousReceipt.state == .active,
                  previousReceipt.trust == active.trust,
                  previousReceipt.contentHash == selectedContentHash,
                  previousReceipt.sourceIdentity
                      == "skill:\(previousReceipt.skillID)@\(selectedContentHash)",
                  previousReceipt.approvedBy.map({
                      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  }) == true
            else { return nil }
        }

        let authorization = previousReceipt ?? active
        return SkillLifecycleReceipt(
            skillID: active.skillID,
            contentHash: selectedContentHash,
            trust: authorization.trust,
            action: .rollback,
            state: .rolledBack,
            reason: reason,
            approvedBy: authorization.approvedBy,
            scope: authorization.scope,
            expiresAt: authorization.expiresAt,
            previousContentHash: previousContentHash ?? previousReceipt?.contentHash,
            sourceIdentity: "skill:\(active.skillID)@\(selectedContentHash)"
        )
    }

    /// Produce a durable quarantine outcome without ever treating the
    /// rejected payload as injectable content.
    public static func quarantine(
        _ receipt: SkillLifecycleReceipt,
        reason: String
    ) -> SkillLifecycleReceipt {
        SkillLifecycleReceipt(
            skillID: receipt.skillID,
            contentHash: receipt.contentHash,
            trust: receipt.trust,
            action: .quarantine,
            state: .quarantined,
            reason: reason,
            approvedBy: receipt.approvedBy,
            scope: receipt.scope,
            expiresAt: receipt.expiresAt,
            previousContentHash: receipt.previousContentHash,
            sourceIdentity: receipt.sourceIdentity
        )
    }

    private static func isValidContentHash(_ hash: String) -> Bool {
        hash.count == 64 && hash.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57)
                || (scalar.value >= 97 && scalar.value <= 102)
        }
    }
}

/// Rejection reasons used by the canonical registry before an injection
/// candidate is handed to the prompt builder.
public enum SkillRegistryRejection: String, Codable, Equatable, Sendable {
    case missingReceipt
    case inactiveReceipt
    /// The durable source manifest is absent or does not describe the
    /// payload projected into this registry entry.  Registry consumers must
    /// reject this before considering a lifecycle receipt.
    case invalidManifest
    case sourceOutsideRoot
    case missingSource
    case sourceHashMismatch
    case identityMismatch
    case untrustedSource
}

/// Value-only source/hash identity for one discovered skill. Paths are
/// normalized and resolved only for validation; they are never executable.
public struct SkillRegistryEntry: Codable, Equatable, Sendable {
    public let skillID: String
    public let name: String
    public let sourceIdentity: String
    public let sourcePath: String
    public let contentHash: String
    public let trust: SkillTrust
    public let enabled: Bool

    public init(
        skill: Skill,
        root: URL,
        receipt: SkillLifecycleReceipt?
    ) {
        let rootURL = root.standardizedFileURL.resolvingSymlinksInPath()
        let sourceURL = rootURL
            .appendingPathComponent(skill.id, isDirectory: true)
            .appendingPathComponent("SKILL.md")
        self.skillID = skill.id
        self.name = skill.name
        self.sourceIdentity = receipt?.sourceIdentity
            ?? "skill:\(skill.id)@\(receipt?.contentHash ?? "")"
        self.sourcePath = sourceURL.path
        self.contentHash = receipt?.contentHash ?? ""
        self.trust = receipt?.trust ?? .untrusted
        self.enabled = skill.isEnabled
    }

    /// Validate filesystem containment, source trust, and the receipt's
    /// content hash before a skill can reach a prompt consumer.
    public func rejection(
        content: String?,
        root: URL,
        now: Date = Date()
    ) -> SkillRegistryRejection? {
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedSource = URL(fileURLWithPath: sourcePath)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard resolvedSource.path == resolvedRoot.path
            || resolvedSource.path.hasPrefix(resolvedRoot.path + "/")
        else { return .sourceOutsideRoot }
        guard !contentHash.isEmpty else { return .missingReceipt }
        guard trust != .untrusted else { return .untrustedSource }
        guard enabled else { return .inactiveReceipt }
        guard let content, !content.isEmpty else { return .missingSource }
        guard SkillManifest.hash(content) == contentHash else {
            return .sourceHashMismatch
        }
        guard sourceIdentity == "skill:\(skillID)@\(contentHash)" else {
            return .identityMismatch
        }
        return nil
    }
}

/// Canonical, immutable registry projection used by production consumers.
/// The SkillStore remains the durable owner; this projection prevents each
/// consumer from inventing a different source/hash or root policy.
public struct SkillRegistry: Sendable, Equatable {
    public let root: URL
    public let entries: [String: SkillRegistryEntry]
    /// Stable identity for the registry projection consumed by one turn.
    /// Enablement, lifecycle proof, and manifest state all participate so a
    /// later turn cannot silently reuse an earlier projection.
    public let revision: String

    public init(store: SkillStore) {
        self.root = store.skillsRoot.standardizedFileURL.resolvingSymlinksInPath()
        var result: [String: SkillRegistryEntry] = [:]
        var revisionParts: [String] = []
        for skill in store.allSkills() {
            let receipt = store.lifecycleReceipt(for: skill.id)
            let entry = SkillRegistryEntry(
                skill: skill,
                root: root,
                receipt: receipt
            )
            result[skill.id] = entry
            let manifest = skill.integrity.manifest
            revisionParts.append([
                skill.id,
                receipt?.receiptID ?? "",
                receipt?.action.rawValue ?? "",
                receipt?.state.rawValue ?? "",
                entry.contentHash,
                entry.sourceIdentity,
                entry.trust.rawValue,
                entry.enabled ? "enabled" : "disabled",
                skill.integrity.state.rawValue,
                manifest?.schema ?? "",
                String(manifest?.version ?? 0),
                manifest?.skillID ?? "",
                manifest?.source.dbValue ?? "",
                manifest?.skillVersion ?? "",
                manifest?.contentHash ?? "",
                skill.integrity.observedContentHash ?? ""
            ].joined(separator: "\u{1f}"))
        }
        self.entries = result
        self.revision = SkillManifest.hash(
            revisionParts.sorted().joined(separator: "\n")
        )
    }

    public func entry(for skillID: String) -> SkillRegistryEntry? {
        entries[skillID]
    }

    public func rejection(
        for skill: Skill,
        content: String?,
        now: Date = Date()
    ) -> SkillRegistryRejection? {
        guard let entry = entries[skill.id] else { return .missingReceipt }
        // Keep the canonical registry honest about the durable source proof.
        // A matching lifecycle receipt alone is not enough: a missing,
        // malformed, or superseded manifest must never reach an injector.
        guard skill.integrity.state == .verified,
              let manifest = skill.integrity.manifest,
              manifest.skillID == skill.id,
              manifest.contentHash == entry.contentHash else {
            return .invalidManifest
        }
        return entry.rejection(content: content, root: root, now: now)
    }
}
