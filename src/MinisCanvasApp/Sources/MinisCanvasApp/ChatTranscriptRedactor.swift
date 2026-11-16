import Foundation
import MinisCore

/// Stable role vocabulary for the persisted chat transcript. It is separate
/// from the UI enum so persistence never depends on a view implementation.
enum ChatTranscriptEntryRole: String, Codable, Equatable, Sendable {
    case user
    case assistant
    case tool
    case system
}

/// One metadata-light transcript entry. Content is redacted at the storage
/// boundary; attachments and absolute paths are intentionally not included.
struct ChatTranscriptEntry: Codable, Equatable, Sendable {
    let role: ChatTranscriptEntryRole
    let text: String

    init(role: ChatTranscriptEntryRole, text: String) {
        self.role = role
        self.text = text
    }
}

/// Typed identity for one session/turn/stream lineage. Sequence is kept in
/// the envelope so the same identity can advance monotonically.
struct ChatTranscriptIdentity: Codable, Hashable, Equatable, Sendable {
    let sessionID: String
    let turnID: String
    let streamID: String

    init(sessionID: String, turnID: String, streamID: String) throws {
        guard Self.isSafePart(sessionID), Self.isSafePart(turnID), Self.isSafePart(streamID)
        else { throw ChatTranscriptPersistenceError.invalidIdentity }
        self.sessionID = sessionID
        self.turnID = turnID
        self.streamID = streamID
    }

    private static func isSafePart(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.unicodeScalars.allSatisfy { scalar in
                scalar.value >= 0x20 && scalar.value != 0x7F
                    && scalar != "/" && scalar != "\\"
            }
    }
}

/// Atomic, restart-readable transcript envelope. No raw provider response or
/// credential field exists in this schema.
struct ChatTranscriptEnvelope: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    let schemaVersion: Int
    let identity: ChatTranscriptIdentity
    let sequence: UInt64
    let terminal: Bool
    let entries: [ChatTranscriptEntry]
    let savedAt: Date
}

enum ChatTranscriptPersistenceError: Error, Equatable, Sendable, LocalizedError {
    case invalidIdentity
    case duplicateWrite
    case lateWrite
    case identityConflict
    case recoveryRequired
    case writeFailed

    /// User-facing next action without exposing a filesystem path or payload.
    var userAction: String {
        switch self {
        case .invalidIdentity: return "重新打开当前会话后再试。"
        case .duplicateWrite: return "这条回复已保存，无需重复发送。"
        case .lateWrite: return "旧回复已结束，请重新生成当前回复。"
        case .identityConflict: return "当前回复正在恢复，请等待完成后再继续。"
        case .recoveryRequired: return "草稿已隔离，请重新打开会话或丢弃损坏草稿。"
        case .writeFailed: return "保存失败，请重试；原有内容保持不变。"
        }
    }

    var errorDescription: String? { userAction }
}

/// Stable restore state consumed by the chat transcript surface. This is a
/// derived projection: it carries only already-redacted entries and safe
/// identity metadata, never the raw provider response or a filesystem path.
enum ChatTranscriptConsumerState: String, Codable, Equatable, Sendable {
    case empty
    case restored
    case resumeRequired
    case recoveryRequired
}

/// Explicit user-facing action for a restored transcript. No action mutates
/// data implicitly; the UI must choose resume or discard explicitly.
enum ChatTranscriptRecoveryAction: String, Codable, Equatable, Sendable {
    case none
    case resume
    case reopenOrDiscard
}

/// Reopen/consumer projection for one chat session.
struct ChatTranscriptConsumerProjection: Codable, Equatable, Sendable {
    let state: ChatTranscriptConsumerState
    let sessionID: String
    let identity: ChatTranscriptIdentity?
    let sequence: UInt64?
    let terminal: Bool?
    let entries: [ChatTranscriptEntry]
    let message: String
    let recoveryAction: ChatTranscriptRecoveryAction

    var isActionable: Bool { recoveryAction != .none }

    init(
        state: ChatTranscriptConsumerState,
        sessionID: String,
        identity: ChatTranscriptIdentity? = nil,
        sequence: UInt64? = nil,
        terminal: Bool? = nil,
        entries: [ChatTranscriptEntry] = [],
        message: String,
        recoveryAction: ChatTranscriptRecoveryAction = .none
    ) {
        self.state = state
        self.sessionID = sessionID
        self.identity = identity
        self.sequence = sequence
        self.terminal = terminal
        self.entries = entries
        self.message = message
        self.recoveryAction = recoveryAction
    }

    static func empty(sessionID: String) -> ChatTranscriptConsumerProjection {
        ChatTranscriptConsumerProjection(
            state: .empty,
            sessionID: sessionID,
            message: "当前会话没有可恢复的对话记录。"
        )
    }

    static func restored(
        sessionID: String,
        envelope: ChatTranscriptEnvelope
    ) -> ChatTranscriptConsumerProjection {
        let state: ChatTranscriptConsumerState = envelope.terminal
            ? .restored
            : .resumeRequired
        let message = envelope.terminal
            ? "已恢复上一轮对话，可以开始新消息。"
            : "已恢复未完成的回复，请明确选择继续生成或丢弃草稿。"
        return ChatTranscriptConsumerProjection(
            state: state,
            sessionID: sessionID,
            identity: envelope.identity,
            sequence: envelope.sequence,
            terminal: envelope.terminal,
            entries: envelope.entries,
            message: message,
            recoveryAction: envelope.terminal ? .none : .resume
        )
    }

    static func recoveryRequired(
        sessionID: String,
        action: String
    ) -> ChatTranscriptConsumerProjection {
        ChatTranscriptConsumerProjection(
            state: .recoveryRequired,
            sessionID: sessionID,
            message: action,
            recoveryAction: .reopenOrDiscard
        )
    }
}

/// S2: content-level redaction seam for chat transcript surfaces.
///
/// Reuses MinisCore EnvVarRedactor (all characters become asterisks;
/// plain substring replacement, no regex, so no ReDoS;
/// values shorter than minMatchLen are skipped). The app never invents a second
/// masking policy. ChatTranscriptFormatter.plainText / attributedString /
/// accessibilityText all funnel through this seam so copy-all, the visible
/// transcript, and screen-reader output never contain known secret values,
/// while non-secret content is preserved verbatim.
struct ChatTranscriptRedactor: Sendable {
    /// Known secret values; empty = pass-through (no redaction).
    let secretValues: [String]

    init(secretValues: [String]) {
        self.secretValues = secretValues
    }

    /// Build from env-var store entries: only `isSecret` entries participate.
    init(entries: [EnvVarEntry]) {
        self.secretValues = entries
            .filter { $0.isSecret && !$0.value.isEmpty }
            .map(\.value)
    }

    /// Build from the store's current in-memory snapshot.
    ///
    /// Do not call `getEnvVar` here: Keychain-backed values are intentionally
    /// loaded only by a credential consumer that needs them. View construction
    /// must remain side-effect free so the first window cannot be blocked by a
    /// Keychain authorization prompt.
    init(store: EnvVarStore) {
        self.init(entries: store.allEnvVars)
    }

    /// Apply the shared secret, remote-content, path, and length bounds.
    func redact(_ text: String) -> String {
        ProductRedactionPolicy.redact(
            text,
            knownSecrets: secretValues,
            maxLength: ProductRedactionPolicy.maxTranscriptFieldLength
        )
    }

    /// A normal conversation body is already owned by the session transcript.
    /// Keep complete text and non-credential public links while masking secrets
    /// and local paths. The 4096-character field cap belongs to audit/receipt and
    /// tool projections; applying it here hid the rest of long model replies.
    func redactVisibleConversationBody(_ text: String) -> String {
        ProductRedactionPolicy.redactConversationBody(text, knownSecrets: secretValues)
    }

    /// Raw model responses use the same format-aware redaction as tools and
    /// transcript rendering (Bearer, `sk-`, query credentials, headers, and
    /// URL userinfo), even when no configured secret list is available.
    func redactRawResponse(_ text: String) -> String {
        redact(text)
    }

    func redact(_ entry: ChatTranscriptEntry) -> ChatTranscriptEntry {
        ChatTranscriptEntry(role: entry.role, text: redactRawResponse(entry.text))
    }
}
