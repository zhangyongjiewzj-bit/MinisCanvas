import CryptoKit
import Foundation

// MARK: - Shared typed settings contract

/// A credential is named by an opaque, one-use handle at the conversation
/// boundary. The handle is not a credential and is never resolved by MinisCore.
public struct BL6CredentialHandle: Codable, Equatable, Hashable, Sendable {
    public let id: String

    public init(id: String) {
        self.id = id
    }
}

/// Values crossing the settings boundary are typed. Secret values are reduced
/// to presence metadata and therefore cannot be serialized as plaintext.
public indirect enum BL6SettingValue: Codable, Equatable, Sendable {
    case text(String)
    case toggle(Bool)
    case integer(Int)
    case decimal(Double)
    case list([String])
    case object([String: BL6SettingValue])
    case redactedSecret(present: Bool)

    private enum CodingKeys: String, CodingKey { case kind, text, toggle, integer, decimal, list, object, present }
    private enum Kind: String, Codable { case text, toggle, integer, decimal, list, object, redactedSecret }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value): try c.encode(Kind.text, forKey: .kind); try c.encode(value, forKey: .text)
        case .toggle(let value): try c.encode(Kind.toggle, forKey: .kind); try c.encode(value, forKey: .toggle)
        case .integer(let value): try c.encode(Kind.integer, forKey: .kind); try c.encode(value, forKey: .integer)
        case .decimal(let value): try c.encode(Kind.decimal, forKey: .kind); try c.encode(value, forKey: .decimal)
        case .list(let value): try c.encode(Kind.list, forKey: .kind); try c.encode(value, forKey: .list)
        case .object(let value): try c.encode(Kind.object, forKey: .kind); try c.encode(value, forKey: .object)
        case .redactedSecret(let present): try c.encode(Kind.redactedSecret, forKey: .kind); try c.encode(present, forKey: .present)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .text: self = .text(try c.decode(String.self, forKey: .text))
        case .toggle: self = .toggle(try c.decode(Bool.self, forKey: .toggle))
        case .integer: self = .integer(try c.decode(Int.self, forKey: .integer))
        case .decimal: self = .decimal(try c.decode(Double.self, forKey: .decimal))
        case .list: self = .list(try c.decode([String].self, forKey: .list))
        case .object: self = .object(try c.decode([String: BL6SettingValue].self, forKey: .object))
        case .redactedSecret: self = .redactedSecret(present: try c.decode(Bool.self, forKey: .present))
        }
    }
}

public enum BL6SettingValueKind: String, Codable, Equatable, Sendable {
    case text, toggle, integer, decimal, list, object, secret
}

public struct BL6SettingsCatalogEntry: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let kind: BL6SettingValueKind
    public let mutable: Bool
    public let secret: Bool

    public init(id: String, kind: BL6SettingValueKind, mutable: Bool = true, secret: Bool = false) {
        self.id = id
        self.kind = kind
        self.mutable = mutable
        self.secret = secret
    }
}

public struct BL6EffectiveSettingsSnapshot: Codable, Equatable, Sendable {
    public let catalogRevision: String
    public let values: [String: BL6SettingValue]

    public init(catalogRevision: String, values: [String: BL6SettingValue]) {
        self.catalogRevision = catalogRevision
        self.values = values
    }

    public func value(for id: String) -> BL6SettingValue? { values[id] }
}

// MARK: - Provider-safe reasoning summary contract

/// The display preference is deliberately separate from chat-output length.
/// It is a value-only setting that can be copied into a turn snapshot without
/// ever carrying hidden reasoning or a prompt instruction to reveal it.
public enum BL6ReasoningSummaryMode: String, Codable, CaseIterable, Equatable, Sendable {
    case automatic
    case concise
    case detailed
    case off
}

public enum BL6ReasoningSummaryAvailability: String, Codable, Equatable, Sendable {
    case available
    case unavailable
    case hidden
}

/// Immutable, display-only metadata supplied by a Provider that explicitly
/// supports safe reasoning summaries. Raw reasoning is not representable in
/// this contract: callers can provide only a bounded, scrubbed summary.
public struct BL6ReasoningSummarySnapshot: Codable, Equatable, Sendable {
    public let mode: BL6ReasoningSummaryMode
    public let availability: BL6ReasoningSummaryAvailability
    public let providerID: String
    public let modelID: String
    public let safeSummary: String?
    public let capturedForTurnID: String?

    public init(
        mode: BL6ReasoningSummaryMode,
        providerID: String,
        modelID: String,
        providerSupportsSafeSummary: Bool,
        safeSummary: String? = nil,
        capturedForTurnID: String? = nil
    ) {
        self.mode = mode
        self.providerID = providerID
        self.modelID = modelID
        self.capturedForTurnID = capturedForTurnID

        guard mode != .off else {
            availability = .hidden
            self.safeSummary = nil
            return
        }
        guard providerSupportsSafeSummary else {
            availability = .unavailable
            self.safeSummary = nil
            return
        }

        let scrubbed = Self.scrub(safeSummary, mode: mode)
        availability = scrubbed == nil ? .unavailable : .available
        self.safeSummary = scrubbed
    }

    public static let hidden = BL6ReasoningSummarySnapshot(
        mode: .off,
        providerID: "",
        modelID: "",
        providerSupportsSafeSummary: false
    )

    public var isVisible: Bool {
        availability == .available && safeSummary != nil
    }

    public var displayText: String? {
        isVisible ? safeSummary : nil
    }

    /// User-facing state is explicit when a Provider cannot supply a safe
    /// summary. It never substitutes a fabricated summary.
    public var statusText: String {
        switch availability {
        case .available: return "推理摘要：已提供安全摘要"
        case .unavailable: return "当前模型不提供推理摘要"
        case .hidden: return "推理摘要：已关闭"
        }
    }

    private static func scrub(
        _ summary: String?,
        mode: BL6ReasoningSummaryMode
    ) -> String? {
        guard var summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty else {
            return nil
        }
        // Provider metadata is flattened to one line before display and is
        // scrubbed for common secret/path forms at this boundary.
        summary = summary.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        summary = summary.replacingOccurrences(
            of: "(?i)(https?://|file://)[^\\s]+",
            with: "[已隐藏链接]",
            options: .regularExpression
        )
        summary = summary.replacingOccurrences(
            of: "(?i)(api[-_ ]?key|token|secret|password)\\s*[:=]\\s*[^\\s]+",
            with: "$1:[已隐藏]",
            options: .regularExpression
        )
        summary = summary.replacingOccurrences(
            of: "(^|\\s)/[^\\s]+",
            with: "$1[已隐藏路径]",
            options: .regularExpression
        )
        let limit = mode == .detailed ? 4_000 : 1_600
        let bounded = String(summary.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
        return bounded.isEmpty ? nil : bounded
    }
}

public extension BL6EffectiveSettingsSnapshot {
    /// Read an optional mode from the typed Composer policy object. Older
    /// snapshots intentionally fall back to `.automatic` for compatibility.
    var reasoningSummaryMode: BL6ReasoningSummaryMode {
        if case let .text(raw) = values["agent.reasoning-summary-mode"],
           let mode = BL6ReasoningSummaryMode(rawValue: raw) {
            return mode
        }
        if case let .object(policy) = values["agent.composer-policy"],
           case let .text(raw) = policy["reasoningSummaryMode"] ?? policy["reasoning-summary-mode"],
           let mode = BL6ReasoningSummaryMode(rawValue: raw) {
            return mode
        }
        return .automatic
    }

    func reasoningSummarySnapshot(
        providerID: String,
        modelID: String,
        providerSupportsSafeSummary: Bool,
        safeSummary: String? = nil,
        capturedForTurnID: String? = nil
    ) -> BL6ReasoningSummarySnapshot {
        BL6ReasoningSummarySnapshot(
            mode: reasoningSummaryMode,
            providerID: providerID,
            modelID: modelID,
            providerSupportsSafeSummary: providerSupportsSafeSummary,
            safeSummary: safeSummary,
            capturedForTurnID: capturedForTurnID
        )
    }
}

public enum BL6SettingsCatalogError: Error, Equatable, Sendable {
    case emptyRevision
    case unknownSetting(String)
    case missingSetting(String)
    case kindMismatch(String)
    case invalidValue(String)
    case secretMustBeRedacted(String)
    case excludedSetting(String)
}

public struct BL6SettingsCatalog: Sendable, Equatable {
    public let entries: [BL6SettingsCatalogEntry]

    public init(entries: [BL6SettingsCatalogEntry]) {
        self.entries = entries.sorted { $0.id < $1.id }
    }

    public static let excludedConversationKeys = ["context_length", "history_rounds"]
    public static let production = BL6SettingsCatalog(entries: [
        BL6SettingsCatalogEntry(id: "general.appearance", kind: .text),
        BL6SettingsCatalogEntry(id: "general.accent-theme", kind: .text),
        // P3-SET-01 / F-125A: the converged theme preset is a first-class typed-settings
        // key, not only its two legacy projections. Registered here because
        // `effectiveSnapshot` fails closed both ways; the projection emit and the
        // key-count pins land in the same unit as this entry.
        BL6SettingsCatalogEntry(id: "general.theme-preset", kind: .text),
        BL6SettingsCatalogEntry(id: "general.default-provider-id", kind: .text),
        BL6SettingsCatalogEntry(id: "general.default-model-id", kind: .text),
        BL6SettingsCatalogEntry(id: "general.sub-model-reference", kind: .text),
        BL6SettingsCatalogEntry(id: "general.model-speed-tier", kind: .text),
        BL6SettingsCatalogEntry(id: "general.chat-output-mode", kind: .text),
        BL6SettingsCatalogEntry(id: "general.language", kind: .text),
        BL6SettingsCatalogEntry(id: "agent.max-loop-iterations", kind: .integer),
        BL6SettingsCatalogEntry(id: "agent.tool-timeout-seconds", kind: .integer),
        BL6SettingsCatalogEntry(id: "agent.concurrent-tool-limit", kind: .integer),
        BL6SettingsCatalogEntry(id: "agent.child-concurrency-user-selected", kind: .integer),
        BL6SettingsCatalogEntry(id: "agent.child-concurrency-enabled-session-count", kind: .integer),
        BL6SettingsCatalogEntry(id: "agent.auto-compact-threshold", kind: .decimal),
        BL6SettingsCatalogEntry(id: "agent.fallback-enabled", kind: .toggle),
        BL6SettingsCatalogEntry(id: "agent.persona-enabled", kind: .toggle),
        BL6SettingsCatalogEntry(id: "agent.persona-preset", kind: .text),
        BL6SettingsCatalogEntry(id: "agent.persona", kind: .object),
        BL6SettingsCatalogEntry(id: "agent.memory-enabled", kind: .toggle),
        BL6SettingsCatalogEntry(id: "agent.approval-policy", kind: .text),
        BL6SettingsCatalogEntry(id: "agent.available-model-whitelist", kind: .list),
        BL6SettingsCatalogEntry(id: "agent.new-message-interrupts-generation", kind: .toggle),
        BL6SettingsCatalogEntry(id: "agent.composer-policy", kind: .object),
        BL6SettingsCatalogEntry(id: "agent.policy-runtime-defaults", kind: .object),
        BL6SettingsCatalogEntry(id: "agent.terminal-policy", kind: .object),
        BL6SettingsCatalogEntry(id: "privacy.redact-env-values", kind: .toggle),
        BL6SettingsCatalogEntry(id: "privacy.log-level", kind: .text),
        BL6SettingsCatalogEntry(id: "privacy.collect-analytics", kind: .toggle),
        BL6SettingsCatalogEntry(id: "privacy.allowed-root-path", kind: .text),
        BL6SettingsCatalogEntry(id: "privacy.denied-root-paths", kind: .list),
        BL6SettingsCatalogEntry(id: "privacy.mounted-folder-paths", kind: .list),
        BL6SettingsCatalogEntry(id: "storage.session-retention-days", kind: .integer),
        BL6SettingsCatalogEntry(id: "storage.memory-limit-mb", kind: .integer),
        BL6SettingsCatalogEntry(id: "storage.auto-delete-old-sessions", kind: .toggle),
        BL6SettingsCatalogEntry(id: "browser.user-agent-preset", kind: .text),
        BL6SettingsCatalogEntry(id: "browser.custom-user-agent", kind: .text),
        BL6SettingsCatalogEntry(id: "browser.viewport-mode", kind: .text),
        BL6SettingsCatalogEntry(id: "browser.custom-viewport-width", kind: .integer),
        BL6SettingsCatalogEntry(id: "browser.custom-viewport-height", kind: .integer),
        BL6SettingsCatalogEntry(id: "browser.idle-tab-timeout-minutes", kind: .integer),
        BL6SettingsCatalogEntry(id: "typography.ui-base-font-size", kind: .integer),
        BL6SettingsCatalogEntry(id: "credential.provider-api-key", kind: .secret, secret: true)
    ])

    public func completeValues(overriding values: [String: BL6SettingValue]) -> [String: BL6SettingValue] {
        var result: [String: BL6SettingValue] = [:]
        for entry in entries {
            switch entry.kind {
            case .text: result[entry.id] = .text("")
            case .toggle: result[entry.id] = .toggle(false)
            case .integer: result[entry.id] = .integer(0)
            case .decimal: result[entry.id] = .decimal(0)
            case .list: result[entry.id] = .list([])
            case .object: result[entry.id] = .object([:])
            case .secret: result[entry.id] = .redactedSecret(present: false)
            }
        }
        for (id, value) in values {
            switch id {
            case "default.provider": result["general.default-provider-id"] = value
            case "default.model": result["general.default-model-id"] = value
            default: result[id] = value
            }
        }
        return result
    }

    public func effectiveSnapshot(revision: String, values: [String: BL6SettingValue]) throws -> BL6EffectiveSettingsSnapshot {
        guard !revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BL6SettingsCatalogError.emptyRevision }
        let known = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        for id in values.keys where known[id] == nil {
            if Self.excludedConversationKeys.contains(id) { throw BL6SettingsCatalogError.excludedSetting(id) }
            throw BL6SettingsCatalogError.unknownSetting(id)
        }
        for entry in entries {
            guard let value = values[entry.id] else { throw BL6SettingsCatalogError.missingSetting(entry.id) }
            if entry.secret {
                guard case .redactedSecret = value else { throw BL6SettingsCatalogError.secretMustBeRedacted(entry.id) }
            } else if !Self.matches(value, kind: entry.kind) {
                if Self.hasExpectedType(value, kind: entry.kind) {
                    throw BL6SettingsCatalogError.invalidValue(entry.id)
                }
                throw BL6SettingsCatalogError.kindMismatch(entry.id)
            }
        }
        return BL6EffectiveSettingsSnapshot(catalogRevision: revision, values: values)
    }

    private static func matches(_ value: BL6SettingValue, kind: BL6SettingValueKind) -> Bool {
        switch (value, kind) {
        case (.text, .text), (.toggle, .toggle), (.redactedSecret, .secret), (.list, .list), (.object, .object): return true
        case let (.integer(value), .integer): return value >= 0
        case let (.decimal(value), .decimal): return value.isFinite && value >= 0
        default: return false
        }
    }

    private static func hasExpectedType(_ value: BL6SettingValue, kind: BL6SettingValueKind) -> Bool {
        switch (value, kind) {
        case (.text, .text), (.toggle, .toggle), (.integer, .integer),
             (.decimal, .decimal), (.list, .list), (.object, .object),
             (.redactedSecret, .secret): return true
        default: return false
        }
    }

    public func revision(for values: [String: BL6SettingValue]) throws -> String {
        let snapshot = try effectiveSnapshot(revision: "pending", values: values)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(snapshot.values)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum BL6SettingsSnapshotGuardError: Error, Equatable, Sendable {
    case locked
    case invalid(BL6SettingsCatalogError)
}

public final class BL6SettingsSnapshotGuard: @unchecked Sendable {
    private let catalog: BL6SettingsCatalog
    private let lock = NSLock()
    private var locked = false

    public init(catalog: BL6SettingsCatalog = .production) { self.catalog = catalog }

    public func apply(revision: String, values: [String: BL6SettingValue]) throws -> BL6EffectiveSettingsSnapshot {
        lock.lock(); defer { lock.unlock() }
        guard !locked else { throw BL6SettingsSnapshotGuardError.locked }
        do { return try catalog.effectiveSnapshot(revision: revision, values: values) }
        catch let error as BL6SettingsCatalogError { locked = true; throw BL6SettingsSnapshotGuardError.invalid(error) }
        catch { locked = true; throw BL6SettingsSnapshotGuardError.invalid(.emptyRevision) }
    }

    public func reject(_ error: BL6SettingsCatalogError) {
        _ = error
        lock.lock(); locked = true; lock.unlock()
    }
}

/// The mutation vocabulary accepted by the conversation settings bridge.
/// Values are always typed and credentials are represented only by an opaque
/// one-use handle issued by `BL6OneUseCredentialBroker`.
public enum BL6SettingsOperation: String, Codable, Equatable, Sendable {
    case apply
    case reset
    case rollback
    case configureProvider = "configure_provider"
}

public enum BL6SettingsApproval: Codable, Equatable, Sendable {
    case pending
    case approved(receiptID: String)

    private enum CodingKeys: String, CodingKey { case kind, receiptID }
    private enum Kind: String, Codable { case pending, approved }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pending:
            try c.encode(Kind.pending, forKey: .kind)
        case .approved(let receiptID):
            try c.encode(Kind.approved, forKey: .kind)
            try c.encode(receiptID, forKey: .receiptID)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .pending: self = .pending
        case .approved: self = .approved(receiptID: try c.decode(String.self, forKey: .receiptID))
        }
    }
}

/// Provider configuration is intentionally separate from ordinary settings.
/// The model-facing contract can carry a handle, but never the credential it
/// names. `keepExisting` and `clear` are explicit to make empty input safe.
public enum BL6ProviderCredentialMutation: Codable, Equatable, Sendable {
    case keepExisting
    case opaqueHandle(BL6CredentialHandle)
    case clear

    private enum CodingKeys: String, CodingKey { case kind, handle }
    private enum Kind: String, Codable { case keepExisting, opaqueHandle, clear }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .keepExisting: try c.encode(Kind.keepExisting, forKey: .kind)
        case .opaqueHandle(let handle):
            try c.encode(Kind.opaqueHandle, forKey: .kind)
            try c.encode(handle, forKey: .handle)
        case .clear: try c.encode(Kind.clear, forKey: .kind)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .keepExisting: self = .keepExisting
        case .opaqueHandle: self = .opaqueHandle(try c.decode(BL6CredentialHandle.self, forKey: .handle))
        case .clear: self = .clear
        }
    }
}

public struct BL6ProviderConfigurationPlan: Codable, Equatable, Sendable {
    public let providerID: String
    public let baseURL: String
    public let modelIDs: [String]
    public let protocolType: String
    public let credential: BL6ProviderCredentialMutation

    public init(
        providerID: String,
        baseURL: String,
        modelIDs: [String],
        protocolType: String,
        credential: BL6ProviderCredentialMutation = .keepExisting
    ) {
        self.providerID = providerID
        self.baseURL = baseURL
        self.modelIDs = modelIDs
        self.protocolType = protocolType
        self.credential = credential
    }
}

public struct BL6SettingsIntent: Codable, Equatable, Sendable {
    public let requestID: String
    public let operation: BL6SettingsOperation
    public let changes: [String: BL6SettingValue]
    public let expectedRevision: String?
    public let approval: BL6SettingsApproval
    public let providerConfiguration: BL6ProviderConfigurationPlan?

    public init(
        requestID: String = UUID().uuidString,
        operation: BL6SettingsOperation = .apply,
        changes: [String: BL6SettingValue] = [:],
        expectedRevision: String? = nil,
        approval: BL6SettingsApproval = .pending,
        providerConfiguration: BL6ProviderConfigurationPlan? = nil
    ) {
        self.requestID = requestID
        self.operation = operation
        self.changes = changes
        self.expectedRevision = expectedRevision
        self.approval = approval
        self.providerConfiguration = providerConfiguration
    }
}

/// Strict model-facing shape for the later production tool. Request identity,
/// approval and rollback values are supplied only by the trusted owner.
public struct BL6SettingsApprovedInput: Codable, Equatable, Sendable {
    public static let approvalPolicyKey = "agent.approval-policy"
    public static let unsupportedApprovalPolicyMessage =
        "对话只能将工具审批策略设为每次询问或只问高风险。autoApprove、never 和停用所有工具不适用于此入口。"
    public let operation: BL6SettingsOperation
    public let changes: [String: BL6SettingValue]
    public let expectedRevision: String
    public let undoReceiptID: String?

    public init(operation: BL6SettingsOperation, changes: [String: BL6SettingValue] = [:],
                expectedRevision: String, undoReceiptID: String? = nil) {
        self.operation = operation
        self.changes = changes
        self.expectedRevision = expectedRevision
        self.undoReceiptID = undoReceiptID
    }

    private enum CodingKeys: String, CodingKey {
        case operation, changes, expectedRevision, undoReceiptID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        operation = try container.decode(BL6SettingsOperation.self, forKey: .operation)
        changes = try container.decodeIfPresent([String: BL6SettingValue].self, forKey: .changes) ?? [:]
        expectedRevision = try container.decode(String.self, forKey: .expectedRevision)
        undoReceiptID = try container.decodeIfPresent(String.self, forKey: .undoReceiptID)
    }

    public func validateForApprovedEffect() throws {
        guard !expectedRevision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BL6SettingsDispatchError.invalidIntent("expected revision required")
        }
        switch operation {
        case .apply:
            guard !changes.isEmpty, undoReceiptID == nil else {
                throw BL6SettingsDispatchError.invalidIntent("apply shape")
            }
            if let value = changes[Self.approvalPolicyKey] {
                guard changes.count == 1, case .text(let rawPolicy) = value,
                      rawPolicy == ApprovalPolicy.alwaysAsk.rawValue
                        || rawPolicy == ApprovalPolicy.riskOnlyAsk.rawValue else {
                    throw BL6SettingsDispatchError.invalidIntent(Self.unsupportedApprovalPolicyMessage)
                }
            }
        case .reset:
            guard changes.isEmpty, undoReceiptID == nil else {
                throw BL6SettingsDispatchError.invalidIntent("reset shape")
            }
        case .rollback:
            guard changes.isEmpty, let undoReceiptID,
                  !undoReceiptID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BL6SettingsDispatchError.invalidIntent("undo receipt reference required")
            }
        case .configureProvider:
            throw BL6SettingsDispatchError.invalidIntent("provider requires separate recovery contract")
        }
    }
}

extension BL6SettingsCatalog {
    /// Mandatory security controls and secrets are never mutable by the
    /// conversation tool, even if ordinary Settings UI can edit some of them.
    public static let deniedApprovedMutationKeys: Set<String> = [
        "context_length", "history_rounds", "credential.provider-api-key",
        "agent.approval-policy", "agent.composer-policy", "agent.policy-runtime-defaults",
        "agent.terminal-policy", "agent.available-model-whitelist",
        "privacy.redact-env-values", "privacy.allowed-root-path",
        "privacy.denied-root-paths", "privacy.mounted-folder-paths",
        "privacy.log-level", "general.default-provider-id",
        "general.default-model-id", "general.sub-model-reference",
        "storage.session-retention-days", "storage.auto-delete-old-sessions"
    ]

    public func validateApprovedMutation(changedKeys: [String]) throws {
        let entriesByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        for key in changedKeys {
            let approvalPolicyOnly = changedKeys == [BL6SettingsApprovedInput.approvalPolicyKey]
            guard let entry = entriesByID[key], entry.mutable, !entry.secret,
                  approvalPolicyOnly || !Self.deniedApprovedMutationKeys.contains(key) else {
                throw BL6SettingsDispatchError.invalidIntent("setting is read-only: \(key)")
            }
        }
    }
}

public struct BL6SettingsPlan: Codable, Equatable, Sendable {
    public let requestID: String
    public let operation: BL6SettingsOperation
    public let baseRevision: String
    public let targetValues: [String: BL6SettingValue]
    public let changedKeys: [String]
    public let providerConfiguration: BL6ProviderConfigurationPlan?

    public init(
        requestID: String,
        operation: BL6SettingsOperation,
        baseRevision: String,
        targetValues: [String: BL6SettingValue],
        changedKeys: [String],
        providerConfiguration: BL6ProviderConfigurationPlan?
    ) {
        self.requestID = requestID
        self.operation = operation
        self.baseRevision = baseRevision
        self.targetValues = targetValues
        self.changedKeys = changedKeys.sorted()
        self.providerConfiguration = providerConfiguration
    }
}

public struct BL6SettingsReceipt: Codable, Equatable, Sendable {
    public let receiptID: String
    public let requestID: String
    public let operation: BL6SettingsOperation
    public let previousRevision: String
    public let effectiveRevision: String
    public let changedKeys: [String]
    public let rollbackValues: [String: BL6SettingValue]
    public let visibleOnNextTurn: Bool
    public let secretValuesExposed: Bool

    public init(
        receiptID: String = UUID().uuidString,
        requestID: String,
        operation: BL6SettingsOperation,
        previousRevision: String,
        effectiveRevision: String,
        changedKeys: [String],
        rollbackValues: [String: BL6SettingValue],
        visibleOnNextTurn: Bool = true,
        secretValuesExposed: Bool = false
    ) {
        self.receiptID = receiptID
        self.requestID = requestID
        self.operation = operation
        self.previousRevision = previousRevision
        self.effectiveRevision = effectiveRevision
        self.changedKeys = changedKeys.sorted()
        self.rollbackValues = rollbackValues
        self.visibleOnNextTurn = visibleOnNextTurn
        self.secretValuesExposed = secretValuesExposed
    }
}

public enum BL6SettingsDispatchError: Error, Codable, Equatable, Sendable {
    case approvalRequired
    case staleRevision(expected: String, actual: String)
    case invalidIntent(String)
    case catalog(BL6SettingsCatalogError)
    case providerConfigurationRequired
    case providerMutationFailed
    case transactionUnknown

    private enum CodingKeys: String, CodingKey { case kind, message, expected, actual }
    private enum Kind: String, Codable {
        case approvalRequired, staleRevision, invalidIntent, catalog, providerConfigurationRequired
        case providerMutationFailed, transactionUnknown
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .approvalRequired: try c.encode(Kind.approvalRequired, forKey: .kind)
        case let .staleRevision(expected, actual):
            try c.encode(Kind.staleRevision, forKey: .kind)
            try c.encode(expected, forKey: .expected)
            try c.encode(actual, forKey: .actual)
        case let .invalidIntent(message):
            try c.encode(Kind.invalidIntent, forKey: .kind); try c.encode(message, forKey: .message)
        case let .catalog(error):
            try c.encode(Kind.catalog, forKey: .kind); try c.encode(String(describing: error), forKey: .message)
        case .providerConfigurationRequired: try c.encode(Kind.providerConfigurationRequired, forKey: .kind)
        case .providerMutationFailed: try c.encode(Kind.providerMutationFailed, forKey: .kind)
        case .transactionUnknown: try c.encode(Kind.transactionUnknown, forKey: .kind)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .approvalRequired: self = .approvalRequired
        case .staleRevision:
            self = .staleRevision(
                expected: try c.decode(String.self, forKey: .expected),
                actual: try c.decode(String.self, forKey: .actual)
            )
        case .invalidIntent: self = .invalidIntent(try c.decode(String.self, forKey: .message))
        case .catalog: self = .catalog(.invalidValue(try c.decode(String.self, forKey: .message)))
        case .providerConfigurationRequired: self = .providerConfigurationRequired
        case .providerMutationFailed: self = .providerMutationFailed
        case .transactionUnknown: self = .transactionUnknown
        }
    }
}

/// Pure intent → typed plan → effective snapshot reducer. Persistence belongs
/// to SettingsCenter; this type has no chat-local state and is safe to reuse
/// for restart/rollback and old/new session tests.
public struct BL6SettingsExecutor: Sendable {
    public let catalog: BL6SettingsCatalog

    public init(catalog: BL6SettingsCatalog = .production) {
        self.catalog = catalog
    }

    public func plan(
        _ intent: BL6SettingsIntent,
        against current: BL6EffectiveSettingsSnapshot,
        defaults: [String: BL6SettingValue]? = nil
    ) throws -> BL6SettingsPlan {
        guard case let .approved(approvalReceiptID) = intent.approval,
              !approvalReceiptID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BL6SettingsDispatchError.approvalRequired
        }
        if let expected = intent.expectedRevision, expected != current.catalogRevision {
            throw BL6SettingsDispatchError.staleRevision(expected: expected, actual: current.catalogRevision)
        }
        if intent.operation == .configureProvider && intent.providerConfiguration == nil {
            throw BL6SettingsDispatchError.providerConfigurationRequired
        }
        var target = current.values
        switch intent.operation {
        case .apply, .configureProvider:
            target.merge(intent.changes) { _, next in next }
        case .reset:
            guard let defaults else { throw BL6SettingsDispatchError.invalidIntent("reset requires defaults") }
            target = defaults
        case .rollback:
            guard !intent.changes.isEmpty else { throw BL6SettingsDispatchError.invalidIntent("rollback requires receipt values") }
            target = intent.changes
        }
        do {
            _ = try catalog.effectiveSnapshot(revision: "pending", values: target)
        } catch let error as BL6SettingsCatalogError {
            throw BL6SettingsDispatchError.catalog(error)
        }
        let changed = target.keys.filter { target[$0] != current.values[$0] }
        return BL6SettingsPlan(
            requestID: intent.requestID,
            operation: intent.operation,
            baseRevision: current.catalogRevision,
            targetValues: target,
            changedKeys: changed,
            providerConfiguration: intent.providerConfiguration
        )
    }

    public func execute(
        _ plan: BL6SettingsPlan,
        against current: BL6EffectiveSettingsSnapshot
    ) throws -> (snapshot: BL6EffectiveSettingsSnapshot, receipt: BL6SettingsReceipt) {
        guard plan.baseRevision == current.catalogRevision else {
            throw BL6SettingsDispatchError.staleRevision(expected: plan.baseRevision, actual: current.catalogRevision)
        }
        let revision: String
        do {
            revision = try catalog.revision(for: plan.targetValues)
            let snapshot = try catalog.effectiveSnapshot(revision: revision, values: plan.targetValues)
            let receipt = BL6SettingsReceipt(
                requestID: plan.requestID,
                operation: plan.operation,
                previousRevision: current.catalogRevision,
                effectiveRevision: revision,
                changedKeys: plan.changedKeys,
                rollbackValues: current.values
            )
            return (snapshot, receipt)
        } catch let error as BL6SettingsCatalogError {
            throw BL6SettingsDispatchError.catalog(error)
        } catch {
            throw BL6SettingsDispatchError.invalidIntent("revision unavailable")
        }
    }
}

/// A turn captures this value once. Settings changes therefore become visible
/// to the next turn while an in-flight request continues with its immutable
/// settings snapshot.
public struct BL6InFlightSettingsSnapshot: Equatable, Sendable {
    public let snapshot: BL6EffectiveSettingsSnapshot
    public let capturedForTurnID: String
    public let reasoningSummary: BL6ReasoningSummarySnapshot

    public init(
        snapshot: BL6EffectiveSettingsSnapshot,
        capturedForTurnID: String,
        reasoningSummary: BL6ReasoningSummarySnapshot = .hidden
    ) {
        self.snapshot = snapshot
        self.capturedForTurnID = capturedForTurnID
        self.reasoningSummary = reasoningSummary
    }
}
