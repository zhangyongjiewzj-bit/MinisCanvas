import Foundation
import CryptoKit

/// One model- and session-bound settings value captured before a new turn.
/// The revision is content-derived; changing a setting changes the identity
/// without mutating an already-running turn or rewriting its transcript.
public struct ContextTurnSettingsSnapshot: Sendable, Equatable, Hashable {
    public let sessionID: String
    public let modelID: String
    public let modelContextWindowTokens: Int
    public let contextLengthTokens: Int
    public let isContextLengthUserSelected: Bool
    public let historyTurnLimit: Int?
    public let revision: String

    public init?(
        sessionID: String,
        modelID: String,
        modelContextWindowTokens: Int,
        requestedContextLengthTokens: Int?,
        historyTurnLimit: Int?
    ) {
        guard !sessionID.isEmpty, !modelID.isEmpty,
              modelContextWindowTokens > 0,
              requestedContextLengthTokens.map({ $0 > 0 && $0 <= modelContextWindowTokens }) ?? true,
              historyTurnLimit.map({ $0 > 0 }) ?? true else { return nil }
        self.sessionID = sessionID
        self.modelID = modelID
        self.modelContextWindowTokens = modelContextWindowTokens
        self.contextLengthTokens = requestedContextLengthTokens ?? modelContextWindowTokens
        self.isContextLengthUserSelected = requestedContextLengthTokens != nil
        self.historyTurnLimit = historyTurnLimit
        let facts = [
            sessionID, modelID, String(modelContextWindowTokens),
            String(requestedContextLengthTokens ?? 0), String(historyTurnLimit ?? 0)
        ]
        let framed = facts.map { "\($0.utf8.count)#\($0)" }.joined()
        let digest = SHA256.hash(data: Data(framed.utf8))
        revision = "context-settings:v1:" + digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Conversation context snapshot

/// 非敏感、不可变的会话级上下文快照（P3-A4-CONTEXT-CONTRACT-R1）。
///
/// 在某个时刻冻结会话身份（sessionID / conversationID）、provider/model 绑定、
/// 配置指纹与技能集，用于跨会话 / 跨 provider / 跨技能的上下文身份比对与持久化。
/// 与 ParentContextSnapshotV1（编排边界父绑定）互补：本快照以会话为锚点，
/// 覆盖同一会话内 provider/model/skill 的不可变身份契约。
///
/// 身份契约（matches）：
/// - 漂移（声明 snapshotID 与规范派生 ID 不一致）→ fail closed，连自身都不匹配；
/// - 跨会话 / 跨 provider / 跨技能（快照 ID 不一致）→ 拒绝；
/// - 冲突（快照 ID 相同但内容不同）→ 拒绝；
/// - 仅当双方快照 ID 与全部绑定事实一致 → 匹配。
public struct ConversationContextSnapshotV1: Sendable, Equatable, Hashable, Codable {
    enum HistoricalRetentionClassification: Equatable {
        case recognized
        case currentCanonical
        case sizeLimit
        case bindingShape
        case sessionBinding
        case formulaMismatch
        case fingerprintShape
    }

    private static let maxIdentityUTF8Bytes = 256
    private static let maxSkillIdentifierCount = 128
    private static let maxSkillIdentifierBytes = 4_096

    /// 稳定快照 ID：默认由全部绑定事实规范派生；显式传入与规范不一致即视为漂移。
    public let snapshotID: String
    /// 会话唯一标识（跨会话不匹配即拒绝）。
    public let sessionID: String
    /// provider 标识（跨 provider 不匹配即拒绝）。
    public let providerID: String
    /// 模型标识。
    public let modelID: String
    /// 配置指纹（模型配置 / 能力集等）。
    public let configurationFingerprint: String
    /// 技能标识符（有序数组；规范快照 ID 按排序后的技能参与派生）。
    public let skillIdentifiers: [String]
    /// 会话内对话标识（可选；nil 与缺省空串均允许，参与规范派生）。
    public let conversationID: String?

    public init(
        snapshotID: String? = nil,
        sessionID: String,
        providerID: String,
        modelID: String,
        configurationFingerprint: String,
        skillIdentifiers: [String],
        conversationID: String? = nil
    ) {
        self.sessionID = sessionID
        self.providerID = providerID
        self.modelID = modelID
        self.configurationFingerprint = configurationFingerprint
        self.skillIdentifiers = skillIdentifiers
        self.conversationID = conversationID
        let derivedID = Self.canonicalSnapshotID(
            sessionID: sessionID,
            providerID: providerID,
            modelID: modelID,
            configurationFingerprint: configurationFingerprint,
            skillIdentifiers: skillIdentifiers,
            conversationID: conversationID
        )
        self.snapshotID = snapshotID ?? (
            Self.hasValidBindingFacts(
                sessionID: sessionID,
                providerID: providerID,
                modelID: modelID,
                configurationFingerprint: configurationFingerprint,
                skillIdentifiers: skillIdentifiers,
                conversationID: conversationID
            ) ? derivedID : "context:invalid"
        )
    }

    /// 由绑定事实派生规范快照 ID：相同内容 → 相同 ID，稳定可重放。
    /// 技能按排序参与派生，顺序差异不改变规范 ID（但 matches 的内容
    /// 比对仍按有序数组拒绝顺序差异，即同 ID 不同内容 → 冲突拒绝）。
    public func canonicalSnapshotID() -> String {
        Self.canonicalSnapshotID(
            sessionID: sessionID,
            providerID: providerID,
            modelID: modelID,
            configurationFingerprint: configurationFingerprint,
            skillIdentifiers: skillIdentifiers,
            conversationID: conversationID
        )
    }

    /// Whether all binding facts are bounded and the declared ID exactly
    /// matches their canonical projection.
    public var isValid: Bool {
        Self.hasValidBindingFacts(
            sessionID: sessionID,
            providerID: providerID,
            modelID: modelID,
            configurationFingerprint: configurationFingerprint,
            skillIdentifiers: skillIdentifiers,
            conversationID: conversationID
        ) && snapshotID == canonicalSnapshotID()
    }

    /// Pre-framing production IDs may be retained as inert persisted history.
    /// This is deliberately separate from `isValid` and `matches`: an old,
    /// delimiter-based ID must never authorize a new execution or writeback.
    var isRecognizedLegacyProductionSnapshot: Bool {
        historicalRetentionClassification == .recognized
    }

    /// Fixed, payload-free reasons for a historical record remaining blocked.
    /// This classifier is only for load diagnostics; it never authorizes a
    /// snapshot for `matches`, execution, recovery, or writeback.
    var historicalRetentionClassification: HistoricalRetentionClassification {
        guard !isValid else { return .currentCanonical }
        guard Self.hasRetainableHistoricalBindingFacts(
                sessionID: sessionID,
                providerID: providerID,
                modelID: modelID,
                configurationFingerprint: configurationFingerprint,
                skillIdentifiers: skillIdentifiers,
                conversationID: conversationID
              ) else {
            return Self.exceedsHistoricalSizeLimit(
                sessionID: sessionID, providerID: providerID, modelID: modelID,
                configurationFingerprint: configurationFingerprint,
                skillIdentifiers: skillIdentifiers
            ) ? .sizeLimit : .bindingShape
        }
        guard UUID(uuidString: sessionID)?.uuidString == sessionID,
              conversationID == sessionID else { return .sessionBinding }
        guard snapshotID.utf8.count <= 8_192 else { return .sizeLimit }
        guard snapshotID == historicalCanonicalSnapshotID() else { return .formulaMismatch }

        let v1Prefix = "chat:v1:\(providerID):\(modelID):"
        if configurationFingerprint.hasPrefix(v1Prefix) {
            return Self.isPositiveCanonicalInteger(
                String(configurationFingerprint.dropFirst(v1Prefix.count))
            ) ? .recognized : .fingerprintShape
        }
        let parts = configurationFingerprint.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6,
              parts[0] == "chat", parts[1] == "v2",
              Self.isPositiveCanonicalInteger(String(parts[2])),
              parts[3] == "context-settings", parts[4] == "v1",
              parts[5].count == 64 else {
            return .fingerprintShape
        }
        return parts[5].unicodeScalars.allSatisfy {
            (0x30...0x39).contains($0.value) || (0x61...0x66).contains($0.value)
        } ? .recognized : .fingerprintShape
    }

    /// Exact historical formula, used only to classify persisted old records.
    func historicalCanonicalSnapshotID() -> String {
        "context:" + [
            sessionID, providerID, modelID, configurationFingerprint,
            skillIdentifiers.sorted().joined(separator: ","), conversationID ?? ""
        ].joined(separator: ":")
    }

    /// The original producer accepted display names and identifiers containing
    /// separators or interior spaces. They cannot be parsed back from the old
    /// ID, so only the decoded, bounded fields may be retained as inert data.
    /// This does not change the canonical binding rules used by `isValid`.
    private static func hasRetainableHistoricalBindingFacts(
        sessionID: String,
        providerID: String,
        modelID: String,
        configurationFingerprint: String,
        skillIdentifiers: [String],
        conversationID: String?
    ) -> Bool {
        hasValidIdentity(sessionID)
            && hasBoundedHistoricalComponent(providerID, maxBytes: maxIdentityUTF8Bytes)
            && hasBoundedHistoricalComponent(modelID, maxBytes: maxIdentityUTF8Bytes)
            && hasBoundedHistoricalComponent(configurationFingerprint, maxBytes: 1_024)
            && skillIdentifiers.count <= maxSkillIdentifierCount
            && skillIdentifiers.reduce(0) { $0 + $1.utf8.count } <= maxSkillIdentifierBytes
            && skillIdentifiers.allSatisfy {
                hasBoundedHistoricalComponent($0, maxBytes: maxIdentityUTF8Bytes)
            }
            && Set(skillIdentifiers).count == skillIdentifiers.count
            && (conversationID.map { hasValidIdentity($0) } ?? true)
    }

    private static func exceedsHistoricalSizeLimit(
        sessionID: String,
        providerID: String,
        modelID: String,
        configurationFingerprint: String,
        skillIdentifiers: [String]
    ) -> Bool {
        sessionID.utf8.count > maxIdentityUTF8Bytes
            || providerID.utf8.count > maxIdentityUTF8Bytes
            || modelID.utf8.count > maxIdentityUTF8Bytes
            || configurationFingerprint.utf8.count > 1_024
            || skillIdentifiers.count > maxSkillIdentifierCount
            || skillIdentifiers.contains { $0.utf8.count > maxIdentityUTF8Bytes }
            || skillIdentifiers.reduce(0) { $0 + $1.utf8.count } > maxSkillIdentifierBytes
    }

    private static func hasBoundedHistoricalComponent(_ value: String, maxBytes: Int) -> Bool {
        guard !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.utf8.count <= maxBytes else {
            return false
        }
        return !value.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar)
                || scalar.properties.generalCategory == .format
                || (0x202A...0x202E).contains(scalar.value)
                || (0x2066...0x2069).contains(scalar.value)
        }
    }

    private static func isPositiveCanonicalInteger(_ value: String) -> Bool {
        guard let number = Int(value), number > 0 else { return false }
        return String(number) == value
    }

    private static func canonicalSnapshotID(
        sessionID: String,
        providerID: String,
        modelID: String,
        configurationFingerprint: String,
        skillIdentifiers: [String],
        conversationID: String?
    ) -> String {
        let sortedSkills = skillIdentifiers.sorted()
        if [sessionID, providerID, modelID, configurationFingerprint, conversationID ?? ""]
            .allSatisfy(Self.canUseLegacyCanonicalComponent),
           sortedSkills.allSatisfy(Self.canUseLegacyCanonicalComponent) {
            let skills = sortedSkills.joined(separator: ",")
            return "context:" + [
                sessionID,
                providerID,
                modelID,
                configurationFingerprint,
                skills,
                conversationID ?? ""
            ].joined(separator: ":")
        }

        let framedSkills = sortedSkills.map(Self.frameCanonicalComponent).joined()
        return "context:v2:" + [
            sessionID,
            providerID,
            modelID,
            configurationFingerprint,
            framedSkills,
            conversationID ?? ""
        ].map(Self.frameCanonicalComponent).joined()
    }

    private static func frameCanonicalComponent(_ value: String) -> String {
        "\(value.utf8.count)#\(value)"
    }

    private static func canUseLegacyCanonicalComponent(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x2D, 0x2E, 0x30...0x39, 0x41...0x5A, 0x5F, 0x61...0x7A:
                return true
            default:
                return false
            }
        }
    }

    private static func hasValidIdentity(_ value: String, allowEmpty: Bool = false) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (allowEmpty && value.isEmpty) || (!trimmed.isEmpty && trimmed == value),
              value.utf8.count <= maxIdentityUTF8Bytes else {
            return false
        }
        guard !value.unicodeScalars.contains(where: {
            CharacterSet.whitespacesAndNewlines.contains($0)
        }) else {
            return false
        }
        return !value.unicodeScalars.contains(where: { scalar in
            let scalarValue = scalar.value
            return CharacterSet.controlCharacters.contains(scalar)
                || scalar.properties.generalCategory == .format
                || (0x202A...0x202E).contains(scalarValue)
                || (0x2066...0x2069).contains(scalarValue)
        })
    }

    private static func hasValidBindingFacts(
        sessionID: String,
        providerID: String,
        modelID: String,
        configurationFingerprint: String,
        skillIdentifiers: [String],
        conversationID: String?
    ) -> Bool {
        hasValidIdentity(sessionID)
            && hasValidIdentity(providerID)
            && hasValidIdentity(modelID)
            && hasValidIdentity(configurationFingerprint)
            && skillIdentifiers.allSatisfy { hasValidIdentity($0) }
            && skillIdentifiers.count <= maxSkillIdentifierCount
            && skillIdentifiers.reduce(0) { $0 + $1.utf8.count } <= maxSkillIdentifierBytes
            && Set(skillIdentifiers).count == skillIdentifiers.count
            && (conversationID.map { hasValidIdentity($0, allowEmpty: true) } ?? true)
    }

    /// 上下文身份比对（见类型注释的契约）。任意一侧身份不可验证即返回 false。
    public func matches(_ other: ConversationContextSnapshotV1) -> Bool {
        // 漂移 fail closed：任一侧声明 ID 与规范派生 ID 不一致，身份无法验证。
        guard isValid, other.isValid else {
            return false
        }
        // 跨会话 / 跨 provider / 跨技能（快照 ID 不一致）拒绝。
        guard snapshotID == other.snapshotID else {
            return false
        }
        // 冲突拒绝：快照 ID 相同但内容不同（含技能顺序差异）不匹配。
        return self == other
    }
}

/// Reject old JSON shapes that Codable would silently change or discard when
/// a later ordinary save re-encodes the enclosing version-1 file.
enum LegacyContextJSON {
    static func roundTripsWithoutFieldLoss<Value: Encodable>(
        _ value: Value,
        originalJSON: Any
    ) -> Bool {
        guard let encoded = try? JSONEncoder().encode(value),
              let reencodedJSON = try? JSONSerialization.jsonObject(with: encoded),
              let original = try? JSONSerialization.data(
                withJSONObject: originalJSON, options: [.sortedKeys]
              ),
              let reencoded = try? JSONSerialization.data(
                withJSONObject: reencodedJSON, options: [.sortedKeys]
              ) else {
            return false
        }
        return original == reencoded
    }
}
