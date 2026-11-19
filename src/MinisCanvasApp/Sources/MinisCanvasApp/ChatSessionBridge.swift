import Foundation
import CryptoKit
import Darwin
import MinisCore

/// Durable App-owned conversation metadata for the App-side consumer.
///
/// `MinisCore.LLMMessage` intentionally carries only provider payloads, so a
/// generic file attachment (and its user-facing name) would otherwise be
/// dropped at the `ChatMessageUI -> LLMMessage` boundary.  This sidecar keeps
/// the attachment list and trusted Composer intent keyed by the persisted
/// message order plus a content digest. The digest is a fence: editing,
/// truncating, or reordering a transcript cannot accidentally attach old UI
/// metadata or retry authority to a different message.
/// The write is a complete envelope and uses an atomic replacement; missing or
/// corrupt sidecars fail closed and leave the normal transcript recoverable.
///
/// Schema 3 adds the D-CHAT-18 turn-timing projection.  `MinisCore.LLMMessage`
/// has no slot for App display metadata, so a completed turn's duration, phase
/// timings and its turn-creation Provider/model snapshot would otherwise be
/// dropped at exactly the same boundary as a generic attachment — i.e. every
/// older turn lost its timing line after a restart.  It is therefore stored in
/// this sidecar under the same index + content-digest fence.
/// Schema 5 records Composer-produced attachment text spans so a restored
/// video's timecodes cannot borrow identical words from user text or another
/// attachment. Earlier sidecars have no such source identity and reject frames.
/// A turn-owned wire projection. Only exact canonical messages are replaced;
/// unknown or newly produced content cannot borrow another message's sidecar.
struct ChatProviderMediaProjection: Sendable {
    struct Replacement: Sendable {
        let source: LLMMessage
        let projected: LLMMessage
    }
    let replacements: [Replacement]
    var currentMessage: LLMMessage? = nil

    func apply(_ messages: [LLMMessage]) -> [LLMMessage] {
        let currentIndex = messages.lastIndex { $0.role == .user && $0 == currentMessage }
        return messages.enumerated().map { index, message in
            guard index != currentIndex else { return message }
            return replacements.first(where: { $0.source == message })?.projected ?? message
        }
    }
}

/// Immutable delivery coordinates for one actually prepared model generation.
struct ChatProviderHistoryProjection: Sendable {
    let sessionID: String
    let sourceRevision: UInt64
    let checkpointID: String?
    let sourceRange: Range<Int>
    let omittedIndices: Set<Int>

    func selecting(_ range: Range<Int>) throws -> Self {
        guard range.lowerBound >= sourceRange.lowerBound,
              range.upperBound <= sourceRange.upperBound else {
            throw SessionStoreError.sessionSnapshotConflict(sessionID)
        }
        return Self(sessionID: sessionID, sourceRevision: sourceRevision,
            checkpointID: checkpointID, sourceRange: range,
            omittedIndices: Set(omittedIndices.filter(range.contains).map { $0 - range.lowerBound }))
    }

    func apply(to request: [LLMMessage]) throws -> [LLMMessage] {
        try Task.checkCancellation()
        guard !omittedIndices.isEmpty else { return request }
        guard request.count >= sourceRange.count else {
            throw SessionStoreError.sessionSnapshotConflict(sessionID)
        }
        return request.enumerated().compactMap { index, message in
            omittedIndices.contains(index) ? nil : message
        }
    }
}

enum ChatAttachmentPersistence {
    static let schemaVersion = 5
    static let fileName = "chat-attachment-ownership.json"
    // Keep recovery metadata within the existing persisted-state budget used
    // by SessionDocumentStore. The bound is checked before JSON decoding.
    private static let maxSidecarBytes = 8 * 1024 * 1024

    private struct SidecarFileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let linkCount: UInt64
    }

    /// D-CHAT-18: the durable half of one turn's App-only display metadata.
    ///
    /// It is written only when the turn reached a terminal state, because an
    /// unfinished `ChatTurnTimingMetadata` legitimately reports
    /// `durationMilliseconds == nil` and renders "回合进行中" from a live clock;
    /// reviving that after a restart would claim a turn is still running and
    /// inflate its processed time forever, which is a fabricated terminal value
    /// of the kind this whole sidecar refuses to invent.
    struct TurnTimingRecord: Codable, Equatable, Sendable {
        let timing: ChatTurnTimingMetadata
        /// Provider display name frozen when the turn was created — never read
        /// back from the current global/session Provider selection.
        var providerName: String?
        var providerDisplayLabel: String? = nil
        /// Canonical model identifier frozen when the turn was created.
        var modelID: String?
    }

    struct MessageRecord: Codable, Equatable, Sendable {
        let messageIndex: Int
        let contentDigest: String
        var attachments: [ChatAttachment]
        /// Composer-produced text/reference item count; absent on legacy history.
        var producerTextAttachmentCount: Int? = nil
        /// Exact Composer-produced attachment spans; absent on legacy history.
        var composedContentOwnership: ChatComposedContentOwnership? = nil
        var referenceCard: PastedTextReferenceCard? = nil
        /// Only populated by the isolated Composer submission producer. It is
        /// never copied into `MinisCore.LLMMessage` or provider messages.
        var trustedSessionReadIntent: String? = nil
        /// D-CHAT-18 turn timing + frozen Provider/model identity for an
        /// already-closed turn.  App display metadata only: it never joins the
        /// provider payload, because `asLLMMessage()` projects role, content,
        /// media and tool fields exclusively.
        var turnTiming: TurnTimingRecord? = nil
        /// Display-only stop fact; never joined to Core/provider content.
        var wasInterrupted: Bool? = nil
        var inlineToolAnchors: [ChatInlineToolAnchor]? = nil
        /// Schema 4: App-authored task navigation, never a model instruction.
        var sessionReferenceCard: SessionReferenceCard? = nil
    }

    /// R3-09：每条消息的真实时间。`MinisCore.LLMMessage` 没有时间槽，重启后
    /// 全部消息会被当成“启动时刻”创建，“回退会话并恢复文件”按下一条消息的
    /// 时间找文件检查点就会漏恢复。时间与消息位置+内容摘要绑定（同
    /// `MessageRecord` 的围栏），摘要对不上就不回填。独立于 `messages`：
    /// 没有附件/回合元数据的普通消息也要有时间，却不能因此产生附件记录。
    struct MessageTimeRecord: Codable, Equatable, Sendable {
        let messageIndex: Int
        let contentDigest: String
        let timestamp: Date
    }

    struct SessionRecord: Codable, Equatable, Sendable {
        let sessionID: String
        var messages: [MessageRecord]
        /// 可选键：旧文件没有，按空处理；旧版本读新文件会忽略它。
        var messageTimes: [MessageTimeRecord]? = nil
    }

    /// 时间绑定用的内容指纹。只用于本文件的 `MessageTimeRecord`，
    /// 采用 base64 以免启动时对每条消息做逐字节格式化。
    private static func timeBindingDigest(_ content: String) -> String {
        Data(SHA256.hash(data: Data(content.utf8))).base64EncodedString()
    }

    private struct Envelope: Codable {
        let schemaVersion: Int
        let sessions: [SessionRecord]
    }

    static func url(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName, isDirectory: false)
    }

    /// Build records for App-only attachment/reference metadata, trusted
    /// Composer intent and the terminal D-CHAT-18 turn-timing projection.
    /// System notices are excluded because they are not part of the persisted
    /// transcript.
    static func records(for session: ChatThread) -> SessionRecord {
        var records: [MessageRecord] = []
        var times: [MessageTimeRecord] = []
        var persistedIndex = 0
        for message in session.messages where message.role != .system {
            // R3-09：只写可信时间。重启后拿不到时间、被临时记成“启动时刻”的
            // 消息不写，免得把假时间固化成真时间。
            if !message.hasUnverifiedTimestamp {
                times.append(MessageTimeRecord(
                    messageIndex: persistedIndex,
                    contentDigest: timeBindingDigest(
                        message.attachments.isEmpty ? message.content : message.asLLMMessage().content),
                    timestamp: message.timestamp))
            }
            let card = message.referenceCard.flatMap {
                message.role == .user && validReference($0, sessionID: session.id.uuidString, content: message.content, attachments: message.attachments) ? $0 : nil
            }
            let turnTiming = terminalTurnTimingRecord(from: message)
            let sessionCard = message.role == .assistant
                ? message.sessionReferenceCard.flatMap {
                    $0.sourceSessionID == session.id.uuidString ? $0 : nil
                } : nil
            if !message.attachments.isEmpty || card != nil
                || turnTiming != nil || sessionCard != nil || message.wasInterrupted
                || !message.inlineToolAnchors.isEmpty || message.producerTextAttachmentCount != nil {
                let projectedContent = message.asLLMMessage().content
                // A failed-video rewrite removes generated spans and must
                // drop old ownership. An audio-recovery diagnostic only adds
                // a known prefix: shift fully validated producer spans to the
                // new Core text so an intact video survives another reopen.
                let ownership = message.role == .user
                    ? ownershipForProjectedContent(message, projectedContent: projectedContent)
                    : nil
                records.append(
                    MessageRecord(
                        messageIndex: persistedIndex,
                        contentDigest: digest(projectedContent),
                        attachments: message.attachments.map(\.sidecarProjection),
                        producerTextAttachmentCount: message.producerTextAttachmentCount,
                        composedContentOwnership: ownership,
                        referenceCard: card,
                        trustedSessionReadIntent: nil,
                        turnTiming: turnTiming,
                        wasInterrupted: message.wasInterrupted ? true : nil,
                        inlineToolAnchors: message.content.utf16.elementsEqual(projectedContent.utf16) && !message.inlineToolAnchors.isEmpty
                            ? message.inlineToolAnchors : nil,
                        sessionReferenceCard: sessionCard
                    )
                )
            }
            persistedIndex += 1
        }
        return SessionRecord(sessionID: session.id.uuidString, messages: records,
                             messageTimes: times.isEmpty ? nil : times)
    }

    private static func ownershipForProjectedContent(
        _ message: ChatMessageUI, projectedContent: String
    ) -> ChatComposedContentOwnership? {
        guard let original = message.composedContentOwnership,
              validatedOwnedParts(original, content: message.content,
                  attachments: message.attachments) != nil else { return nil }
        if projectedContent == message.content { return original }

        let audioNotices = audioRestoreNotices(message.attachments)
        guard !audioNotices.isEmpty else { return nil }
        let prefix = audioNotices.joined(separator: "\n") + "\n\n"
        // Compare the entire projection. A matching substring in user prose
        // cannot authorize a part, and video-failure rewrites cannot pass.
        guard projectedContent == prefix + message.content else { return nil }
        let prefixBytes = Data(prefix.utf8)
        let bodyBytes = Data(message.content.utf8.prefix(original.bodyUTF8Length))
        // When the user's body was empty, the prefix's trailing two newlines
        // become the first body/attachment separator, not body bytes.
        let prefixBodyLength = original.bodyUTF8Length == 0
            ? prefixBytes.count - 2 : prefixBytes.count
        var shiftedBody = Data(prefixBytes.prefix(prefixBodyLength))
        shiftedBody.append(bodyBytes)
        let shifted = ChatComposedContentOwnership(
            bodyUTF8Length: original.bodyUTF8Length + prefixBodyLength,
            bodyDigest: ChatComposedContentOwnership.digest(shiftedBody),
            contentDigest: ChatComposedContentOwnership.digest(Data(projectedContent.utf8)),
            attachmentParts: original.attachmentParts.map { part in
                ChatComposedContentOwnership.AttachmentPart(
                    attachmentID: part.attachmentID,
                    utf8Offset: part.utf8Offset + prefixBytes.count,
                    utf8Length: part.utf8Length, digest: part.digest
                )
            }
        )
        guard validatedOwnedParts(shifted, content: projectedContent,
            attachments: message.attachments) != nil else { return nil }
        return shifted
    }

    fileprivate static func audioRestoreNotices(_ attachments: [ChatAttachment]) -> [String] {
        attachments.compactMap { attachment -> String? in
            guard attachment.kind == .audio, attachment.status == .failed,
                  attachment.failureReason == "音频历史字节与正史记录校验失败；未附加该音频"
            else { return nil }
            return "音频 \(attachment.fileName) 的历史字节恢复校验失败；本轮未附加该音频，不能按原文的已附加说明判断其内容。"
        }
    }

    /// Save the complete ownership map. Empty sessions are retained in the
    /// envelope so an old sidecar cannot resurrect deleted attachment links.
    /// Only IDs admitted by the existing reversible trash receipts retain their
    /// prior records; restored active records always replace that retained copy.
    static func save(sessions: [ChatThread], to directory: URL,
                     retainingTrashedSessionIDs: Set<String> = []) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var sessionRecords = sessions.map(records(for:))
        if !retainingTrashedSessionIDs.isEmpty {
            let activeIDs = Set(sessionRecords.map(\.sessionID))
            // 旧文件读一次、解码一次；保留的记录连消息时间一起带上，不然回收站里的会话
            // 恢复后所有消息都会变成“时间未核实”。
            let priorEnvelope = try readSidecar(at: url(in: directory)).map {
                try JSONDecoder().decode(Envelope.self, from: $0)
            }
            let prior = try priorEnvelope.map { try decodeSidecar($0) } ?? [:]
            let priorTimes = Dictionary(
                (priorEnvelope?.sessions ?? []).compactMap { record in
                    record.messageTimes.map { (record.sessionID, $0) }
                }, uniquingKeysWith: { first, _ in first })
            for id in retainingTrashedSessionIDs.subtracting(activeIDs) {
                if let messages = prior[id] {
                    sessionRecords.append(
                        SessionRecord(sessionID: id, messages: messages, messageTimes: priorTimes[id]))
                }
            }
        }
        let sidecar = url(in: directory)
        var ordered = sessionRecords.sorted { $0.sessionID < $1.sessionID }
        var data = try encode(ordered)
        if data.count > maxSidecarBytes {
            ordered = try degradingLargestTextAttachments(ordered)
            data = try encode(ordered)
        }
        try writeBoundedSidecar(data, to: sidecar, expectedIdentity: try sidecarIdentity(at: sidecar))
    }

    /// 元数据超过 8MB 上限时，把最大的文本附件降级为只存引用（文件名、大小、路径、
    /// 原文字数）：全文仍在会话正文里，附件的 data 只服务界面预览，丢掉不影响发给模型的内容。
    /// 只降级有原路径、且所在消息没有粘贴引用卡的附件（引用卡校验要用附件全文）。
    /// 降级后仍超限就原样返回，由写入处按原有规则报错。
    static func degradingLargestTextAttachments(_ records: [SessionRecord]) throws -> [SessionRecord] {
        var result = records
        while true {
            let excess = try encode(result).count - maxSidecarBytes
            if excess <= 0 { return result }
            var candidates: [(record: Int, message: Int, attachment: Int, bytes: Int)] = []
            for (r, record) in result.enumerated() {
                for (m, message) in record.messages.enumerated() where message.referenceCard == nil {
                    for (a, attachment) in message.attachments.enumerated()
                    where attachment.kind == .text && attachment.status == .ready
                        && attachment.fileURL != nil {
                        if let data = attachment.data { candidates.append((r, m, a, data.count)) }
                    }
                }
            }
            guard !candidates.isEmpty else { return result }
            candidates.sort { ($0.bytes, $1.record, $1.message, $1.attachment) > ($1.bytes, $0.record, $0.message, $0.attachment) }
            var saved = 0
            for candidate in candidates {
                let old = result[candidate.record].messages[candidate.message].attachments[candidate.attachment]
                result[candidate.record].messages[candidate.message].attachments[candidate.attachment] =
                    ChatAttachment(
                        id: old.id, kind: old.kind, fileName: old.fileName, fileType: old.fileType,
                        mimeType: old.mimeType, size: old.size, data: nil, fileURL: old.fileURL,
                        status: old.status, failureReason: old.failureReason,
                        deliveryQuarantined: old.deliveryQuarantined,
                        originalTextCharacterCount: old.originalTextCharacterCount)
                // JSON 里 Data 是 base64，约 4/3 倍。
                saved += candidate.bytes / 3 * 4
                if saved >= excess { break }
            }
        }
    }

    /// Save only metadata for a transcript already committed by the caller.
    /// An empty record supersedes older legacy ownership for the same session.
    static func save(session: ChatThread, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sidecar = sessionSidecarURL(for: session.id, in: directory)
        let expectedIdentity = try sidecarIdentity(at: sidecar)
        var record = records(for: session)
        var prior: (messages: [MessageRecord], times: [MessageTimeRecord])?
        if expectedIdentity != nil {
            // 同一个分片只读一次、解码一次。
            prior = try loadSessionShard(sessionID: session.id, at: sidecar)
            if prior?.messages == record.messages && (prior?.times ?? []) == (record.messageTimes ?? []) { return }
        }
        var data = try encode([record])
        if data.count > maxSidecarBytes {
            // 超上限：最大的文本附件降级为只存引用（已降级过的会话不必每次重写）。
            record = try degradingLargestTextAttachments([record])[0]
            if prior?.messages == record.messages && (prior?.times ?? []) == (record.messageTimes ?? []) { return }
            data = try encode([record])
        }
        try writeBoundedSidecar(data, to: sidecar, expectedIdentity: expectedIdentity)
    }

    /// Called from terminal deletion while its validated receipt remains
    /// durable. Retrying after a partial cleanup is safe.
    static func retire(sessionIDs: Set<String>, in directory: URL) throws {
        let legacy = url(in: directory)
        let legacyIdentity = try sidecarIdentity(at: legacy)
        var updatedLegacy: Data?
        if let data = try readSidecar(at: legacy) {
            // Validate the full envelope, then keep its original schema and
            // unknown fields when removing only exact ownership records.
            _ = try decodeSidecar(data)
            guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sessions = object["sessions"] as? [[String: Any]] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let retained = sessions.filter { record in
                guard let id = record["sessionID"] as? String else { return true }
                return !sessionIDs.contains(id)
            }
            if retained.count != sessions.count {
                object["sessions"] = retained
                updatedLegacy = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            }
        }

        // Validate all targeted shards before changing either representation.
        // Non-UUID Core task IDs exist only in the legacy envelope.
        var shards: [(url: URL, identity: SidecarFileIdentity)] = []
        for rawID in sessionIDs.sorted() {
            guard let id = UUID(uuidString: rawID), id.uuidString == rawID else { continue }
            let sidecar = sessionSidecarURL(for: id, in: directory)
            guard let identity = try sidecarIdentity(at: sidecar) else { continue }
            guard try loadSessionSidecar(sessionID: id, at: sidecar) != nil else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            shards.append((sidecar, identity))
        }

        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { _ = Darwin.close(descriptor) }

        // A retry may already see the filtered envelope after a failed sync.
        // Make that rename durable before removing any authoritative shard.
        if let updatedLegacy {
            try writeBoundedSidecar(updatedLegacy, to: legacy, expectedIdentity: legacyIdentity)
        }
        if !shards.isEmpty {
            guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
        }
        for shard in shards {
            guard try sidecarIdentity(at: shard.url) == shard.identity,
                  shard.url.path.withCString({ Darwin.unlink($0) }) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Read the requested session only. A present shard is authoritative even
    /// when empty or unreadable; only a missing shard can consult legacy data.
    static func load(
        forSessionID sessionID: String, from directory: URL,
        legacy: Result<[String: [MessageRecord]], Error>? = nil
    ) throws -> [MessageRecord]? {
        if let id = UUID(uuidString: sessionID),
           let records = try loadSessionSidecar(sessionID: id, at: sessionSidecarURL(for: id, in: directory)) {
            return records
        }
        if let legacy { return try legacy.get()[sessionID] }
        return try load(from: directory)[sessionID]
    }

    /// R3-09：读取某会话分片里保存的消息时间。分片不存在（或只有旧版内容）
    /// 返回空数组，调用方据此把消息保持为“时间未核实”。
    static func loadMessageTimes(forSessionID sessionID: String, from directory: URL) throws -> [MessageTimeRecord] {
        guard let id = UUID(uuidString: sessionID) else { return [] }
        return try loadSessionMessageTimes(sessionID: id, at: sessionSidecarURL(for: id, in: directory))
    }

    private static func loadSessionMessageTimes(sessionID: UUID, at sidecar: URL) throws -> [MessageTimeRecord] {
        try loadSessionShard(sessionID: sessionID, at: sidecar)?.times ?? []
    }

    /// 启动时每个会话恢复附件归属和消息时间：分片只读一次、解码一次（原来各读各的，读两遍）。
    /// 分片不存在时归属记录再按旧版合并文件查（`legacy` 为启动时已读好的那一份），时间为空。
    static func loadSessionRecordsAndTimes(
        forSessionID sessionID: String, from directory: URL,
        legacy: Result<[String: [MessageRecord]], Error>? = nil
    ) throws -> (records: [MessageRecord]?, times: [MessageTimeRecord]) {
        if let id = UUID(uuidString: sessionID),
           let shard = try loadSessionShard(sessionID: id, at: sessionSidecarURL(for: id, in: directory)) {
            return (shard.messages, shard.times)
        }
        if let legacy { return (try legacy.get()[sessionID], []) }
        return (try load(from: directory)[sessionID], [])
    }

    /// 读一次、解码一次，同时给出该会话的归属记录和消息时间。分片不存在返回 nil。
    private static func loadSessionShard(
        sessionID: UUID, at sidecar: URL
    ) throws -> (messages: [MessageRecord], times: [MessageTimeRecord])? {
        guard let data = try readSidecar(at: sidecar) else { return nil }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        let records = try decodeSidecar(envelope)
        guard records.count == 1, let messages = records[sessionID.uuidString] else {
            throw NSError(
                domain: "ChatAttachmentPersistence",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "附件归属与会话不匹配"]
            )
        }
        let times = envelope.sessions.first { $0.sessionID == sessionID.uuidString }?.messageTimes ?? []
        return (messages, times)
    }

    static func sessionSidecarURL(for sessionID: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("chat-attachment-ownership.\(sessionID.uuidString).json", isDirectory: false)
    }

    private static func loadSessionSidecar(sessionID: UUID, at sidecar: URL) throws -> [MessageRecord]? {
        try loadSessionShard(sessionID: sessionID, at: sidecar)?.messages
    }

    private static func encode(_ sessions: [SessionRecord]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Envelope(schemaVersion: schemaVersion, sessions: sessions))
    }

    private static func writeBoundedSidecar(
        _ data: Data, to sidecar: URL, expectedIdentity: SidecarFileIdentity?
    ) throws {
        guard data.count <= maxSidecarBytes else {
            throw NSError(
                domain: "ChatAttachmentPersistence",
                code: 27,
                userInfo: [NSLocalizedDescriptionKey: "附件归属 sidecar 超出大小上限"]
            )
        }
        let temporary = sidecar
            .deletingLastPathComponent()
            .appendingPathComponent(".\(fileName).\(UUID().uuidString).tmp", isDirectory: false)
        var descriptor: Int32 = -1
        do {
            descriptor = open(
                temporary.path,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
            guard descriptor >= 0 else {
                throw NSError(
                    domain: "ChatAttachmentPersistence",
                    code: 29,
                    userInfo: [NSLocalizedDescriptionKey: "无法创建附件归属 sidecar 临时文件"]
                )
            }
            try data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                var offset = 0
                while offset < rawBuffer.count {
                    let count = Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: offset),
                        rawBuffer.count - offset
                    )
                    guard count > 0 else {
                        throw NSError(
                            domain: "ChatAttachmentPersistence",
                            code: 29,
                            userInfo: [NSLocalizedDescriptionKey: "无法写入附件归属 sidecar"]
                        )
                    }
                    offset += count
                }
            }
            guard fsync(descriptor) == 0 else {
                throw NSError(
                    domain: "ChatAttachmentPersistence",
                    code: 29,
                    userInfo: [NSLocalizedDescriptionKey: "无法持久化附件归属 sidecar"]
                )
            }
            guard Darwin.close(descriptor) == 0 else {
                throw NSError(
                    domain: "ChatAttachmentPersistence",
                    code: 29,
                    userInfo: [NSLocalizedDescriptionKey: "无法关闭附件归属 sidecar 临时文件"]
                )
            }
            descriptor = -1
            guard try sidecarIdentity(at: sidecar) == expectedIdentity else {
                throw NSError(
                    domain: "ChatAttachmentPersistence",
                    code: 28,
                    userInfo: [NSLocalizedDescriptionKey: "附件归属 sidecar 在写入期间发生变化"]
                )
            }
            let renameResult = temporary.path.withCString { source in
                sidecar.path.withCString { destination in
                    Darwin.rename(source, destination)
                }
            }
            guard renameResult == 0 else {
                throw NSError(
                    domain: "ChatAttachmentPersistence",
                    code: 29,
                    userInfo: [NSLocalizedDescriptionKey: "无法替换附件归属 sidecar"]
                )
            }
        } catch {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            _ = temporary.path.withCString { Darwin.unlink($0) }
            throw error
        }
    }

    private static func sidecarIdentity(at url: URL) throws -> SidecarFileIdentity? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            guard errno == ENOENT else {
                throw NSError(
                    domain: "ChatAttachmentPersistence",
                    code: 26,
                    userInfo: [NSLocalizedDescriptionKey: "无法读取附件归属 sidecar"]
                )
            }
            return nil
        }
        guard (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1,
              info.st_size >= 0,
              info.st_size <= off_t(maxSidecarBytes) else {
            throw NSError(
                domain: "ChatAttachmentPersistence",
                code: 27,
                userInfo: [NSLocalizedDescriptionKey: "附件归属 sidecar 文件身份或大小无效"]
            )
        }
        return SidecarFileIdentity(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            linkCount: UInt64(info.st_nlink)
        )
    }

    /// Load the sidecar, rejecting future schema versions and malformed data.
    /// A missing sidecar is the compatible legacy state.
    static func load(from directory: URL) throws -> [String: [MessageRecord]] {
        try loadSidecar(at: url(in: directory)) ?? [:]
    }

    private static func loadSidecar(at sidecar: URL) throws -> [String: [MessageRecord]]? {
        guard let data = try readSidecar(at: sidecar) else { return nil }
        return try decodeSidecar(data)
    }

    private static func readSidecar(at sidecar: URL) throws -> Data? {
        var sidecarInfo = stat()
        guard lstat(sidecar.path, &sidecarInfo) == 0 else {
            guard errno == ENOENT else {
                throw NSError(
                    domain: "ChatAttachmentPersistence",
                    code: 26,
                    userInfo: [NSLocalizedDescriptionKey: "无法读取附件归属 sidecar"]
                )
            }
            return nil
        }
        guard (sidecarInfo.st_mode & S_IFMT) == S_IFREG,
              sidecarInfo.st_nlink == 1,
              sidecarInfo.st_size >= 0,
              sidecarInfo.st_size <= off_t(maxSidecarBytes) else {
            throw NSError(
                domain: "ChatAttachmentPersistence",
                code: 27,
                userInfo: [NSLocalizedDescriptionKey: "附件归属 sidecar 文件身份或大小无效"]
            )
        }
        let descriptor = open(sidecar.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw NSError(
                domain: "ChatAttachmentPersistence",
                code: 26,
                userInfo: [NSLocalizedDescriptionKey: "无法读取附件归属 sidecar"]
            )
        }
        defer { _ = close(descriptor) }
        var initialInfo = stat()
        guard fstat(descriptor, &initialInfo) == 0,
              (initialInfo.st_mode & S_IFMT) == S_IFREG,
              initialInfo.st_nlink == 1,
              initialInfo.st_size >= 0,
              initialInfo.st_size <= off_t(maxSidecarBytes),
              initialInfo.st_dev == sidecarInfo.st_dev,
              initialInfo.st_ino == sidecarInfo.st_ino else {
            throw NSError(
                domain: "ChatAttachmentPersistence",
                code: 27,
                userInfo: [NSLocalizedDescriptionKey: "附件归属 sidecar 文件身份或大小无效"]
            )
        }
        var data = Data()
        data.reserveCapacity(Int(initialInfo.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                return read(descriptor, baseAddress, rawBuffer.count)
            }
            guard count >= 0 else {
                throw NSError(
                    domain: "ChatAttachmentPersistence",
                    code: 26,
                    userInfo: [NSLocalizedDescriptionKey: "无法读取附件归属 sidecar"]
                )
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maxSidecarBytes else {
                throw NSError(
                    domain: "ChatAttachmentPersistence",
                    code: 27,
                    userInfo: [NSLocalizedDescriptionKey: "附件归属 sidecar 超出大小上限"]
                )
            }
        }
        var finalInfo = stat()
        guard fstat(descriptor, &finalInfo) == 0,
              (finalInfo.st_mode & S_IFMT) == S_IFREG,
              finalInfo.st_nlink == 1,
              finalInfo.st_size == off_t(data.count),
              finalInfo.st_dev == initialInfo.st_dev,
              finalInfo.st_ino == initialInfo.st_ino,
              finalInfo.st_mtimespec.tv_sec == initialInfo.st_mtimespec.tv_sec,
              finalInfo.st_mtimespec.tv_nsec == initialInfo.st_mtimespec.tv_nsec,
              finalInfo.st_ctimespec.tv_sec == initialInfo.st_ctimespec.tv_sec,
              finalInfo.st_ctimespec.tv_nsec == initialInfo.st_ctimespec.tv_nsec else {
            throw NSError(
                domain: "ChatAttachmentPersistence",
                code: 28,
                userInfo: [NSLocalizedDescriptionKey: "附件归属 sidecar 在读取期间发生变化"]
            )
        }
        var pathInfo = stat()
        guard lstat(sidecar.path, &pathInfo) == 0,
              (pathInfo.st_mode & S_IFMT) == S_IFREG,
              pathInfo.st_nlink == 1,
              pathInfo.st_dev == initialInfo.st_dev,
              pathInfo.st_ino == initialInfo.st_ino else {
            throw NSError(
                domain: "ChatAttachmentPersistence",
                code: 28,
                userInfo: [NSLocalizedDescriptionKey: "附件归属 sidecar 在读取期间发生变化"]
            )
        }
        return data
    }

    private static func decodeSidecar(_ data: Data) throws -> [String: [MessageRecord]] {
        try decodeSidecar(try JSONDecoder().decode(Envelope.self, from: data))
    }

    /// 已解码的文件内容按同一套校验转成各会话的归属记录（调用方需要时间记录时共用同一次解码）。
    private static func decodeSidecar(_ envelope: Envelope) throws -> [String: [MessageRecord]] {
        guard envelope.schemaVersion <= schemaVersion else {
            throw NSError(
                domain: "ChatAttachmentPersistence",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "未知附件归属版本"]
            )
        }
        var recordsBySessionID: [String: [MessageRecord]] = [:]
        for record in envelope.sessions {
            let messageIndices = record.messages.map(\.messageIndex)
            guard !record.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  messageIndices.allSatisfy({ $0 >= 0 }),
                  Set(messageIndices).count == messageIndices.count else {
                throw NSError(
                    domain: "ChatAttachmentPersistence",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "无效附件归属消息索引"]
                )
            }
            guard recordsBySessionID[record.sessionID] == nil else {
                throw NSError(
                    domain: "ChatAttachmentPersistence",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "重复附件归属会话"]
                )
            }
            recordsBySessionID[record.sessionID] = record.messages.map { message in
                var compatible = message
                // The retired intent is never carried forward from a sidecar.
                compatible.trustedSessionReadIntent = nil
                // Pre-v5 records did not capture Composer spans. Never infer
                // ownership from text or accept a backfilled key in an old
                // envelope.
                if envelope.schemaVersion < 5 {
                    compatible.producerTextAttachmentCount = nil
                    compatible.composedContentOwnership = nil
                }
                // Schema 1/2 predate the D-CHAT-18 turn slot. Even a
                // hand-edited legacy payload that happens to carry a similar
                // key has no terminal turn snapshot behind it, so the key is
                // stripped with the same fail-closed precedent as trusted
                // intent. A schema-3 record whose timing is not terminal
                // (`finishedAt == nil`) is equally unusable after a restart —
                // restoring it would revive a live clock as a fake terminal
                // state — and is dropped here as well.
                if envelope.schemaVersion < 3
                    || message.turnTiming?.timing.finishedAt == nil
                    // W5-080: a hand-edited sidecar must not revive an
                    // `.appMessage` ownership record as a restored turn slot.
                    || message.turnTiming?.timing.representsModelTurn == false {
                    compatible.turnTiming = nil
                }
                if envelope.schemaVersion < 4 {
                    compatible.sessionReferenceCard = nil
                }
                return compatible
            }
        }
        return recordsBySessionID
    }

    /// Reattach only when both the persisted message position and content
    /// digest match. A mismatch is intentionally a no-op (fail closed).
    static func restoreAttachments(
        from persisted: MinisCore.ChatSession,
        records: [MessageRecord]?,
        messageTimes: [MessageTimeRecord] = []
    ) -> ChatThread {
        var thread = persisted.asThread()
        // R3-09：回填消息真实时间（位置+内容摘要都对得上才回填）；没有的
        // 保持 `asChatMessageUI` 给的“时间未核实”标记。
        for time in messageTimes
        where thread.messages.indices.contains(time.messageIndex)
            && persisted.messages.indices.contains(time.messageIndex)
            && time.contentDigest == timeBindingDigest(persisted.messages[time.messageIndex].content) {
            thread.messages[time.messageIndex].timestamp = time.timestamp
            thread.messages[time.messageIndex].hasUnverifiedTimestamp = false
        }
        guard let records, !records.isEmpty,
              Set(records.map(\.messageIndex)).count == records.count else { return thread }
        for index in thread.messages.indices {
            guard index < persisted.messages.count,
                  let record = records.first(where: { $0.messageIndex == index }),
                  record.contentDigest == digest(persisted.messages[index].content)
            else { continue }
            thread.messages[index].producerTextAttachmentCount = record.producerTextAttachmentCount
                .flatMap { $0 >= 0 ? $0 : nil }
            // 新格式 sidecar 的图片/音频只有摘要：先按顺序与哈希从 Core 绑回字节。
            let recordAttachments = rebindDigestMedia(
                record.attachments, to: persisted.messages[index]
            )
            let ordinaryAudio = rebindOrdinaryAudio(
                recordAttachments, to: persisted.messages[index].audios
            )
            // The Core transcript is the byte owner for every video PNG. The
            // sidecar records only frame order, times and digests; rebind only
            // if each image still occupies the exact expected payload slot.
            // On mismatch the video frame attachments become failed metadata;
            // their PNGs are not replayed with a fabricated timecode binding.
            if recordAttachments.contains(where: { $0.videoFrames != nil }) {
                let ownedParts = thread.messages[index].role == .user
                    ? record.composedContentOwnership.flatMap {
                    validatedOwnedParts($0, content: persisted.messages[index].content,
                        attachments: recordAttachments)
                    } : nil
                // Valid ownership can remove only exact generated spans if a
                // later frame check fails. Missing/invalid legacy ownership
                // leaves the canonical prose intact and rejects the frames.
                thread.messages[index].composedContentOwnership = ownedParts == nil
                    ? nil : record.composedContentOwnership
                if let attachments = rebindVideoFrames(
                    recordAttachments,
                    to: persisted.messages[index].images, audios: persisted.messages[index].audios,
                    ownedParts: ownedParts
                ) {
                    thread.messages[index].attachments = attachments.enumerated().map { position, attachment in
                        attachment.kind == .audio ? ordinaryAudio[position] : attachment
                    }
                } else {
                    thread.messages[index].attachments = recordAttachments.enumerated().map { position, attachment in
                        if attachment.kind == .audio { return ordinaryAudio[position] }
                        guard attachment.fileType == .video,
                              attachment.videoFrames != nil else { return attachment }
                        return ChatAttachment(
                            id: attachment.id, kind: attachment.kind,
                            fileName: attachment.fileName, fileType: attachment.fileType,
                            mimeType: attachment.mimeType, size: attachment.size,
                            data: nil, fileURL: attachment.fileURL,
                            status: .failed, videoFrames: attachment.videoFrames,
                            deliveryQuarantined: attachment.deliveryQuarantined, videoContext: attachment.videoContext
                        )
                    }
                }
            } else {
                thread.messages[index].attachments = ordinaryAudio
            }
            if let card = record.referenceCard,
               thread.messages[index].role == .user,
               validReference(card, sessionID: persisted.id, content: persisted.messages[index].content, attachments: thread.messages[index].attachments) {
                thread.messages[index].referenceCard = card
            }
            // D-CHAT-18: project the durable terminal snapshot back onto the
            // assistant turn message. `load` already strips pre-schema-3 and
            // non-terminal records; the checks are repeated so a caller that
            // hands records in directly (bypassing `load`) still fails closed.
            // This restores exactly the frozen duration/Provider/model values —
            // never a recomputed or live-clock value.
            if let turn = record.turnTiming,
               thread.messages[index].role == .assistant,
               turn.timing.finishedAt != nil,
               // W5-080: ownership records for App-authored assistant lines are
               // not model turns; never project them back as turn timing even
               // when a caller bypasses `load`.
               turn.timing.representsModelTurn {
                thread.messages[index].turnTiming = turn.timing
                thread.messages[index].turnProviderName = turn.providerName
                thread.messages[index].turnProviderDisplayLabel = ProviderDisplayLabel.safeDisplayText(turn.providerDisplayLabel)
                thread.messages[index].turnModelID = turn.modelID
                // R3-09：旧档没有逐条时间，但终态回合带着回合创建时刻，
                // 它就是该助手消息的创建时间，可作为可信时间。
                if thread.messages[index].hasUnverifiedTimestamp {
                    thread.messages[index].timestamp = turn.timing.startedAt
                    thread.messages[index].hasUnverifiedTimestamp = false
                }
            }
            if thread.messages[index].role == .assistant, let anchors = record.inlineToolAnchors {
                thread.messages[index].inlineToolAnchors = ChatInlineToolAnchor.validated(
                    anchors, in: thread.messages[index].content)
            }
            if record.wasInterrupted == true, thread.messages[index].role == .assistant {
                thread.messages[index].wasInterrupted = true
            }
            if let card = record.sessionReferenceCard,
               thread.messages[index].role == .assistant,
               card.sourceSessionID == persisted.id,
               card.isStructurallyValid {
                thread.messages[index].sessionReferenceCard = card
            }
        }
        return thread
    }

    /// 新格式 sidecar 对图片/音频只存 SHA-256 摘要，字节归 Core 转写所有。
    /// 按与发送时相同的槽位顺序（普通图片 1 槽、视频每帧 1 个图片槽并可带 1 个音频槽、
    /// 普通音频 1 槽）取 Core 字节，哈希与类型都对得上才绑回；对不上的图片标为失败。
    /// 旧格式（sidecar 自带字节、无摘要）原样通过。
    private static func rebindDigestMedia(
        _ attachments: [ChatAttachment], to message: LLMMessage
    ) -> [ChatAttachment] {
        guard attachments.contains(where: { $0.payloadDigest != nil }) else { return attachments }
        var imageSlot = 0
        var audioSlot = 0
        return attachments.map { attachment in
            if let frames = attachment.videoFrames {
                // 与发送时同一套判定：校验不过的视频发送时不占槽位，这里也不计数。
                if attachment.occupiesVideoPayloadSlots {
                    imageSlot += frames.count
                    if attachment.videoContext?.audio != nil { audioSlot += 1 }
                }
                return attachment
            }
            guard attachment.status == .ready, let digest = attachment.payloadDigest,
                  attachment.data == nil else {
                if attachment.kind == .image, attachment.data != nil { imageSlot += 1 }
                // 无效音频发送时不占槽位。
                if attachment.kind == .audio, let data = attachment.data,
                   MediaPayloadValidation.audioFormat(data) != nil { audioSlot += 1 }
                return attachment
            }
            func rebuilt(data: Data?, failed: Bool) -> ChatAttachment {
                var copy = ChatAttachment(
                    id: attachment.id, kind: attachment.kind,
                    fileName: attachment.fileName, fileType: attachment.fileType,
                    mimeType: attachment.mimeType, size: attachment.size,
                    data: data, fileURL: attachment.fileURL,
                    status: failed ? .failed : .ready,
                    failureReason: failed ? "图片历史字节与正史记录校验失败；未附加该图片" : attachment.failureReason,
                    deliveryQuarantined: attachment.deliveryQuarantined,
                    originalTextCharacterCount: attachment.originalTextCharacterCount
                )
                copy.audioTranscript = attachment.audioTranscript
                return copy
            }
            if attachment.kind == .image {
                defer { imageSlot += 1 }
                guard imageSlot < message.images.count,
                      ChatVideoFrame.digest(message.images[imageSlot].data) == digest else {
                    return rebuilt(data: nil, failed: true)
                }
                return rebuilt(data: message.images[imageSlot].data, failed: false)
            }
            if attachment.kind == .audio {
                defer { audioSlot += 1 }
                guard audioSlot < message.audios.count,
                      let data = Data(base64Encoded: message.audios[audioSlot].base64Data),
                      ChatVideoFrame.digest(data) == digest else {
                    // 留空字节但保留摘要，交给 rebindOrdinaryAudio 统一标记失败并占住槽位。
                    var pending = rebuilt(data: nil, failed: false)
                    pending.payloadDigest = digest
                    return pending
                }
                return rebuilt(data: data, failed: false)
            }
            return attachment
        }
    }

    /// The sidecar owns names and UI metadata, never ordinary audio bytes.
    /// Match each ready audio to its exact Core payload slot, including slots
    /// occupied by a video's extracted track. A content digest alone cannot
    /// authenticate a replaced but otherwise valid WAV/MP3 in the sidecar.
    private static func rebindOrdinaryAudio(
        _ attachments: [ChatAttachment], to audios: [LLMMessage.AudioAttachment]
    ) -> [ChatAttachment] {
        var slot = 0
        var rejected = Set<Int>()
        for (index, attachment) in attachments.enumerated() {
            if attachment.kind == .file, attachment.fileType == .video {
                if attachment.occupiesVideoPayloadSlots, attachment.videoContext?.audio != nil { slot += 1 }
                continue
            }
            guard attachment.kind == .audio else { continue }
            let declared = attachment.mimeType?.split(separator: ";", maxSplits: 1)
                .first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard attachment.status == .ready,
                  let data = attachment.data,
                  let format = MediaPayloadValidation.audioFormat(data),
                  (format == "wav" && declared == "audio/wav")
                    || (format == "mp3" && (declared == "audio/mpeg" || declared == "audio/mp3"))
            else {
                if attachment.status == .ready { rejected.insert(index) }
                // 摘要对不上 Core 字节的音频发送时占过一个槽位，后面的音频不能错位。
                if attachment.status == .ready, attachment.data == nil,
                   attachment.payloadDigest != nil { slot += 1 }
                continue
            }
            if slot >= audios.count || audios[slot].format.lowercased() != format
                || audios[slot].base64Data != data.base64EncodedString() {
                rejected.insert(index)
            }
            slot += 1
        }
        // An unaccounted Core slot means the sidecar ordering is incomplete;
        // none of its ordinary audio metadata can safely borrow a slot.
        if slot != audios.count {
            for (index, attachment) in attachments.enumerated() where attachment.kind == .audio {
                rejected.insert(index)
            }
        }
        return attachments.enumerated().map { index, attachment in
            guard rejected.contains(index) else { return attachment }
            return ChatAttachment(
                id: attachment.id, kind: attachment.kind,
                fileName: attachment.fileName, fileType: attachment.fileType,
                mimeType: attachment.mimeType, size: attachment.size,
                data: nil, fileURL: attachment.fileURL, status: .failed,
                failureReason: "音频历史字节与正史记录校验失败；未附加该音频",
                deliveryQuarantined: attachment.deliveryQuarantined
            )
        }
    }

    /// Verify a complete Composer partition: exact Core content digest, user
    /// body boundary, separator positions, attachment order/IDs and each part
    /// digest. No substring search participates in this proof.
    static func validatedOwnedParts(
        _ ownership: ChatComposedContentOwnership,
        content: String, attachments: [ChatAttachment]
    ) -> [String]? {
        let bytes = Array(content.utf8)
        guard ownership.contentDigest == ChatComposedContentOwnership.digest(Data(bytes)),
              ownership.bodyUTF8Length >= 0,
              ownership.bodyUTF8Length <= bytes.count,
              ownership.attachmentParts.count == attachments.count,
              ownership.bodyDigest == ChatComposedContentOwnership.digest(
                Data(bytes.prefix(ownership.bodyUTF8Length))) else { return nil }
        var offset = ownership.bodyUTF8Length
        if offset > 0 && !attachments.isEmpty {
            guard offset + 2 <= bytes.count,
                  bytes[offset] == 10, bytes[offset + 1] == 10 else { return nil }
            offset += 2
        }
        var parts: [String] = []
        parts.reserveCapacity(attachments.count)
        for (index, attachment) in attachments.enumerated() {
            let part = ownership.attachmentParts[index]
            guard part.attachmentID == attachment.id,
                  part.utf8Offset == offset,
                  part.utf8Length > 0,
                  part.utf8Length <= bytes.count - offset,
                  let text = String(bytes: bytes[offset..<(offset + part.utf8Length)],
                      encoding: .utf8),
                  part.digest == ChatComposedContentOwnership.digest(Data(text.utf8))
            else { return nil }
            parts.append(text)
            offset += part.utf8Length
            if index < attachments.count - 1 {
                guard offset + 2 <= bytes.count,
                      bytes[offset] == 10, bytes[offset + 1] == 10 else { return nil }
                offset += 2
            }
        }
        return offset == bytes.count ? parts : nil
    }

    /// Remove only producer-owned parts for failed videos. The user body and
    /// all other attachment parts remain byte-for-byte unchanged.
    static func contentWithoutFailedVideoParts(_ message: ChatMessageUI) -> String? {
        guard let ownership = message.composedContentOwnership,
              let parts = validatedOwnedParts(ownership, content: message.content,
                  attachments: message.attachments),
              let body = String(bytes: Array(message.content.utf8)
                  .prefix(ownership.bodyUTF8Length), encoding: .utf8) else { return nil }
        var retained: [String] = body.isEmpty ? [] : [body]
        for (index, attachment) in message.attachments.enumerated() {
            if attachment.fileType == .video,
               attachment.status == .failed,
               attachment.videoFrames != nil { continue }
            retained.append(parts[index])
        }
        return retained.joined(separator: "\n\n")
    }

    private static func rebindVideoFrames(
        _ attachments: [ChatAttachment],
        to images: [LLMMessage.ImageAttachment], audios: [LLMMessage.AudioAttachment],
        ownedParts: [String]?
    ) -> [ChatAttachment]? {
        guard let ownedParts, ownedParts.count == attachments.count else { return nil }
        var imageIndex = 0
        var audioIndex = 0
        var rebound: [ChatAttachment] = []
        rebound.reserveCapacity(attachments.count)
        for (attachmentIndex, attachment) in attachments.enumerated() {
            // 摘要对不上 Core 字节的音频（data 为空但保留摘要）发送时同样占过一个音频槽位。
            if attachment.kind == .audio,
               attachment.audioAttachment != nil
                || (attachment.status == .ready && attachment.data == nil && attachment.payloadDigest != nil) {
                audioIndex += 1
            }
            if attachment.kind == .image {
                guard imageIndex < images.count,
                      let existing = attachment.imageAttachment,
                      existing.mimeType == images[imageIndex].mimeType,
                      existing.data == images[imageIndex].data else { return nil }
                imageIndex += 1
                rebound.append(attachment)
                continue
            }
            guard attachment.kind == .file,
                  attachment.fileType == .video,
                  let frameMetadata = attachment.videoFrames else {
                rebound.append(attachment)
                continue
            }
            // 发送时校验不过的视频不占槽位：不绑回字节，原样保留。
            guard attachment.occupiesVideoPayloadSlots else {
                rebound.append(attachment)
                continue
            }
            var frames: [ChatVideoFrame] = []
            frames.reserveCapacity(frameMetadata.count)
            for frame in frameMetadata {
                guard imageIndex < images.count,
                      images[imageIndex].mimeType == "image/png",
                      images[imageIndex].data.count <= ChatStore.videoMaxOutputBytes,
                      ChatVideoFrame.digest(images[imageIndex].data) == frame.pngDigest
                else { return nil }
                frames.append(frame.withPayload(images[imageIndex].data))
                imageIndex += 1
            }
            var context = attachment.videoContext
            if let metadata = context?.audio {
                guard context?.isValid(maxOutputBytes: ChatStore.videoMaxOutputBytes, requireAudioPayload: false) == true,
                      audioIndex < audios.count, audios[audioIndex].format == "wav",
                      let data = Data(base64Encoded: audios[audioIndex].base64Data),
                      data.count == metadata.byteCount, MediaVideoAudioTrack.digest(data) == metadata.digest else { return nil }
                context = context?.withAudioPayload(data); audioIndex += 1
            }
            let bound = ChatAttachment(
                id: attachment.id, kind: attachment.kind,
                fileName: attachment.fileName, fileType: attachment.fileType,
                mimeType: attachment.mimeType, size: attachment.size,
                data: attachment.data, fileURL: attachment.fileURL,
                status: attachment.status, videoFrames: frames,
                deliveryQuarantined: attachment.deliveryQuarantined, videoContext: context
            )
            guard bound.videoImageAttachments != nil else { return nil }
            // Only the exact producer-owned segment at this attachment index
            // may authenticate timecodes. Another video's segment or user text
            // cannot lend this sidecar its description.
            guard let description = bound.sampledVideoDescription,
                  ownedParts[attachmentIndex] == description else { return nil }
            rebound.append(bound)
        }
        guard imageIndex == images.count, audioIndex == audios.count else { return nil }
        return rebound
    }

    /// D-CHAT-18 write gate: project a turn's timing + frozen Provider/model
    /// snapshot only when the turn already reached its terminal state
    /// (`finishedAt != nil`).  An in-flight `ChatTurnTimingMetadata` reports
    /// `durationMilliseconds == nil` and renders "回合进行中" from a live
    /// clock; reviving it after a restart would keep inflating "已处理"
    /// forever and pose as a still-running turn — a fabricated terminal value
    /// this sidecar refuses to invent.  Assistant-role only: `ChatStore`
    /// attaches turn timing exclusively to the assistant turn message.
    private static func terminalTurnTimingRecord(from message: ChatMessageUI) -> TurnTimingRecord? {
        guard message.role == .assistant,
              let timing = message.turnTiming,
              // W5-080: `.appMessage` ownership records are closed by
              // definition but carry no model-turn duration — persisting one
              // would spend a schema-3 sidecar slot on a non-turn line.
              timing.representsModelTurn,
              timing.finishedAt != nil else { return nil }
        return TurnTimingRecord(
            timing: timing,
            providerName: normalizedTurnIdentity(message.turnProviderName),
            providerDisplayLabel: ProviderDisplayLabel.safeDisplayText(message.turnProviderDisplayLabel),
            modelID: normalizedTurnIdentity(message.turnModelID)
        )
    }

    /// Blank identity strings carry no display meaning. Unlike trusted intent,
    /// a valid snapshot is stored byte-exact: it is a frozen turn-creation
    /// value and must not be re-trimmed into a different display string.
    private static func normalizedTurnIdentity(_ value: String?) -> String? {
        guard let value else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }

    private static func validReference(
        _ card: PastedTextReferenceCard, sessionID: String, content: String,
        attachments: [ChatAttachment]
    ) -> Bool {
        guard card.sessionID.uuidString == sessionID, !card.material.isEmpty else { return false }
        func matchesPastedContent(_ candidate: String) -> Bool {
            if card.instruction.isEmpty && candidate == card.material { return true }
            let separator = card.kind == .instruction
                ? ComposerPayload.pastedInstructionSeparator : ComposerPayload.pastedTextSeparator
            let suffix = separator + card.material
            guard candidate.hasSuffix(suffix) else { return false }
            return String(candidate.dropLast(suffix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines) == card.instruction
        }
        // Preserve legacy messages whose content was stored without injected
        // attachment descriptions. The complete material fence still applies.
        if matchesPastedContent(content) { return true }
        guard !attachments.isEmpty else { return false }
        // Reuse the actual value-only composition producer; never search for
        // material somewhere in the content or read an attachment's path.
        let attachmentSuffix = "\n\n" + ChatStore.composeUserContent(text: "", attachments: attachments)
        guard content.hasSuffix(attachmentSuffix) else { return false }
        return matchesPastedContent(String(content.dropLast(attachmentSuffix.count)))
    }

    /// Freeze delivery-only replacements from accepted, digest-bound App metadata.
    /// Durable transcript bytes and all checkpoint comparisons remain unchanged.
    static func providerMediaProjection(
        canonical: MinisCore.ChatSession, records: [MessageRecord]?
    ) throws -> ChatProviderMediaProjection {
        guard let records else { return ChatProviderMediaProjection(replacements: []) }
        let restored = restoreAttachments(from: canonical, records: records)
        let currentUserIndex = canonical.messages.lastIndex { $0.role == .user }
        var replacements: [ChatProviderMediaProjection.Replacement] = []
        for record in records where record.attachments.contains(where: { $0.deliveryQuarantined == true }) {
            try Task.checkCancellation()
            let index = record.messageIndex
            guard canonical.messages.indices.contains(index),
                  canonical.messages[index].role == .user,
                  record.contentDigest == digest(canonical.messages[index].content),
                  restored.messages.indices.contains(index),
                  restored.messages[index].asLLMMessage() == canonical.messages[index] else {
                throw ChatSessionRuntimeError.partialHistoryInvalid
            }
            // Explicit retry/current upload retains its own original payload.
            guard index != currentUserIndex else { continue }
            var safe = restored.messages[index]
            let withheld = safe.attachments.filter { $0.deliveryQuarantined == true && $0.hasModelMediaPayload }
            guard !withheld.isEmpty else { continue }
            safe.attachments.removeAll { $0.deliveryQuarantined == true && $0.hasModelMediaPayload }
            safe.content += "\n\n（此前媒体附件未完成发送，本轮未附带；不可视为已读取其内容。）"
            replacements.append(.init(source: canonical.messages[index], projected: safe.asLLMMessage()))
        }
        return ChatProviderMediaProjection(replacements: replacements,
            currentMessage: currentUserIndex.map { canonical.messages[$0] })
    }

    private static func digest(_ content: String) -> String {
        SHA256.hash(data: Data(content.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// The app-side boundary for durable context compaction.
///
/// Manual compaction (the ChatStore action) and automatic compaction (the
/// MinisCore AgentLoop budget policy) must not invent separate persistence
/// formats.  Both call this boundary, which verifies the exact source
/// transcript before delegating the atomic checkpoint write to SessionStore.
enum ChatSessionBridge {
    /// The automatic caller supplies the entire canonical CAS snapshot and
    /// the closed prefix boundary, never its current (possibly projected)
    /// Provider history. Store provenance is independently checked here.
    static func saveCanonicalCompactionPrefix(
        sessionStore: SessionStore, expectedSession: MinisCore.ChatSession,
        closedPrefixCount: Int, result: CompactionResult,
        taskStore: AgentTaskStore?, effectLedger: ToolExecutionFactLedger?
    ) throws -> CompactionCheckpoint? {
        guard CompactionFactCapture.verifyStores(result.retentionFacts ?? [],
            taskStore: taskStore, effectLedger: effectLedger) else {
            throw SessionStoreError.invalidCompactionCheckpoint(expectedSession.id)
        }
        return try sessionStore.compareAndSaveCompactionPrefix(
            expectedSession: expectedSession, closedPrefixCount: closedPrefixCount, result: result)
    }

    static func saveCanonicalCompactionCheckpoint(
        sessionStore: SessionStore,
        sessionID: String,
        sourceMessages: [LLMMessage],
        expectedTranscriptRevision: UInt64? = nil,
        result: CompactionResult,
        taskStore: AgentTaskStore? = nil,
        effectLedger: ToolExecutionFactLedger? = nil
    ) throws -> CompactionCheckpoint? {
        try Task.checkCancellation()
        guard let session = sessionStore.loadSession(id: sessionID) else {
            throw SessionStoreError.sessionNotFound(sessionID)
        }
        if let expectedTranscriptRevision,
           session.transcriptRevision != expectedTranscriptRevision {
            throw SessionStoreError.compactionCheckpointRevisionMismatch(sessionID)
        }
        // A revision fence protects the normal path; the content fence also
        // rejects a stale async result if a legacy caller changed a transcript
        // without advancing its revision.
        guard session.messages == sourceMessages else {
            throw SessionStoreError.compactionCheckpointBoundaryMismatch(sessionID)
        }
        guard CompactionFactCapture.verifyStores(result.retentionFacts ?? [],
            taskStore: taskStore, effectLedger: effectLedger) else {
            throw SessionStoreError.invalidCompactionCheckpoint(sessionID)
        }
        guard result.compactedCount > 0 else { return nil }
        try Task.checkCancellation()
        let checkpoint = try CompactionCheckpoint.makeProjection(
            sessionID: session.id,
            sourceTranscriptRevision: session.transcriptRevision,
            sourceMessages: sourceMessages,
            result: result,
            lineage: session.lineageIdentity
        )
        try Task.checkCancellation()
        return try sessionStore.saveCompactionCheckpoint(checkpoint)
    }

    /// Coordinates from the exact projection produced in this preparation or
    /// transition. No store is read again at provider dispatch.
    static func providerHistoryProjection(
        source: MinisCore.ChatSession, closedPrefixCount: Int,
        interruptedIndices: Set<Int>, checkpoint: CompactionCheckpoint?,
        modelHistoryCount: Int
    ) throws -> ChatProviderHistoryProjection {
        var omitted = Set<Int>()
        if let checkpoint {
            switch checkpoint.schemaVersion {
            case CompactionCheckpoint.segmentedProjectionSchemaVersion, CompactionCheckpoint.lossySummarySchemaVersion:
                // A lossy summary has no exact spans; only its exact tail is addressable.
                if checkpoint.schemaVersion == CompactionCheckpoint.segmentedProjectionSchemaVersion {
                    guard let spans = checkpoint.projectionSpans else {
                        throw SessionStoreError.invalidCompactionCheckpoint(source.id)
                    }
                    for span in spans where span.source.kind == .exact
                        && span.source.range.count == span.projectedRange.count {
                        for index in interruptedIndices where index < closedPrefixCount
                            && span.source.range.contains(index) {
                            omitted.insert(span.projectedRange.lowerBound + index - span.source.range.lowerBound)
                        }
                    }
                }
                // Recent and post-checkpoint messages form the exact suffix.
                // Its offset uses this actual projection, including its own
                // refreshed background facts, never a later resume generation.
                let boundary = checkpoint.compactedMessageRange.upperBound
                for index in interruptedIndices where index >= boundary && index < closedPrefixCount {
                    omitted.insert(modelHistoryCount - closedPrefixCount + index)
                }
            case CompactionCheckpoint.projectionSchemaVersion:
                let boundary = checkpoint.compactedMessageRange.upperBound
                for index in interruptedIndices where index >= boundary && index < closedPrefixCount {
                    omitted.insert(1 + index - boundary)
                }
            default:
                break // Unknown and aggregate projections have no exact identity.
            }
        } else {
            omitted = Set(interruptedIndices.filter { $0 < closedPrefixCount })
        }
        guard omitted.allSatisfy({ (0..<modelHistoryCount).contains($0) }) else {
            throw SessionStoreError.sessionSnapshotConflict(source.id)
        }
        return ChatProviderHistoryProjection(sessionID: source.id,
            sourceRevision: source.transcriptRevision, checkpointID: checkpoint?.checkpointID,
            sourceRange: 0..<modelHistoryCount, omittedIndices: omitted)
    }

    /// Restart/re-entry consumes the derived model history. SessionStore
    /// validates digest, lineage, revision and the canonical source prefix.
    static func resumeCanonicalMessages(
        sessionStore: SessionStore,
        sessionID: String,
        taskStore: AgentTaskStore? = nil,
        effectLedger: ToolExecutionFactLedger? = nil
    ) throws -> [LLMMessage] {
        try Task.checkCancellation()
        let messages = try sessionStore.resumeMessages(sessionID: sessionID)
        // Schema 3 has several source-ordered summary spans separated by exact
        // tool/media groups. SessionStore has already verified each span and
        // its canonical source; the schema-2 single-summary count does not
        // apply to that model projection.
        let checkpoint = try sessionStore.loadLatestCompactionCheckpoint(sessionID: sessionID)
        if checkpoint?.schemaVersion == CompactionCheckpoint.segmentedProjectionSchemaVersion
            || checkpoint?.schemaVersion == CompactionCheckpoint.lossySummarySchemaVersion {
            let facts = checkpoint?.retentionFacts ?? []
            guard CompactionFactCapture.verifyStores(facts, taskStore: taskStore,
                effectLedger: effectLedger) else {
                throw SessionStoreError.invalidCompactionCheckpoint(sessionID)
            }
            // Use the old block solely to locate the derived context. Facts for
            // the next request are read afresh, so a completed task cannot stay
            // presented as unfinished. The background lists only unfinished
            // tasks and receipts that did not succeed; a succeeded receipt is
            // never listed (the summary records what was done).
            // The background block follows the last projected span; a lossy
            // summary is one message, so it follows that message.
            let backgroundPosition = checkpoint?.schemaVersion == CompactionCheckpoint.lossySummarySchemaVersion
                ? 1 : checkpoint?.projectionSpans?.last?.projectedRange.upperBound
            if let canonical = sessionStore.loadSession(id: sessionID),
               let position = backgroundPosition,
               position <= messages.count {
                var refreshed = messages
                if let oldBackground = CompactionFactCapture.backgroundMessage(facts) {
                    guard position < refreshed.count, refreshed[position] == oldBackground else {
                        throw SessionStoreError.invalidCompactionCheckpoint(sessionID)
                    }
                    refreshed.remove(at: position)
                }
                let current = CompactionFactCapture.capture(sessionID: sessionID,
                    revision: canonical.transcriptRevision, messages: canonical.messages,
                    taskStore: taskStore, effectLedger: effectLedger)
                if let background = CompactionFactCapture.backgroundMessage(current) {
                    refreshed.insert(background, at: position)
                }
                return refreshed
            }
            return messages
        }
        let summaryCount = messages.reduce(into: 0) { count, message in
            if LossySummaryCompaction.isProgramSummary(message) {
                count += 1
            }
        }
        guard summaryCount <= 1 else {
            throw SessionStoreError.invalidCompactionCheckpoint(sessionID)
        }
        return messages
    }

    /// 回合内压缩提交后重读的比对：摘要和尾部（连同其后的实时消息）逐条相等即可。
    /// 背景（未完成的任务、未成功的回执）每轮按库里现状重建，摘要请求期间有任务换了状态，
    /// 重建出来的背景和检查点里存的不同，这不算不一致。
    static func resumedMatchesCheckpoint(
        _ resumed: [LLMMessage], checkpoint: CompactionCheckpoint, live: [LLMMessage]
    ) -> Bool {
        let stored = checkpoint.replacementHistory
        guard let recent = checkpoint.projectionRecentCount else { return resumed == stored + live }
        guard recent < stored.count, resumed.first == stored.first else { return false }
        let tail = Array(stored.suffix(recent)) + live
        let backgroundCount = resumed.count - 1 - tail.count
        guard backgroundCount == 0
                || (backgroundCount == 1 && resumed[1].content.hasPrefix("<retained-store-facts>")) else {
            return false
        }
        return Array(resumed.suffix(tail.count)) == tail
    }
}

// MARK: - ChatThread ↔ MinisCore.ChatSession 便捷转换（I8 P1-3 类型统一）
//
// 背景：MinisCore.ChatSession 是持久化模型（id: String + [LLMMessage]），
// MinisCanvasApp.ChatThread 是 UI 线程模型（id: UUID + [ChatMessageUI]，含
// isStreaming 流式标记与 system 画布提示角色）。两者职责不同，不做合并，
// 只在边界（磁盘读写）显式转换 —— 转换逻辑集中在本文件，消除此前
// ChatStore 内联转换与「MinisCore.ChatSession 全限定名」的脆弱写法。

extension ChatThread {
    /// UI 线程 → 持久化模型。
    /// 约定：id 用 uuidString；system 角色（画布事件提示）不落盘（口径同
    /// SessionManager.listWithStats 的消息数统计）。图片、音频和 native
    /// tool metadata 进入 Core transcript，保证重启后模型载荷不变。
    func asPersisted() -> MinisCore.ChatSession {
        MinisCore.ChatSession(
            id: id.uuidString,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            messages: messages
                .filter { $0.role != .system }
                .map { $0.asLLMMessage() },
            transcriptRevision: transcriptRevision,
            pinned: pinned,
            unread: unread,
            projectID: projectID,
            projectName: projectName,
            workingDirectory: workingDirectory,
            groupID: groupID?.uuidString,
            modelID: modelID,
            providerTypeRaw: providerTypeRaw,
            lineageVersion: lineageVersion,
            rootSessionID: rootSessionID,
            parentSessionID: parentSessionID,
            forkedFromSessionID: forkedFromSessionID,
            forkedThroughTranscriptRevision: forkedThroughTranscriptRevision,
            forkedThroughMessageID: forkedThroughMessageID,
            createdByTaskID: createdByTaskID,
            createdByRunID: createdByRunID,
            taskSourceSessionID: taskSourceSessionID
        )
    }
}

extension MinisCore.ChatSession {
    /// 持久化模型 → UI 线程。
    /// 约定：String id 还原为 UUID（失败则随机新 ID）；空标题显示「新会话」。
    func asThread() -> ChatThread {
        ChatThread(
            id: UUID(uuidString: id) ?? UUID(),
            title: title.isEmpty ? "新会话" : title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            // 从磁盘读出的消息没有保存过时间（创建时刻取的是读盘时刻）：先标成未核实，
            // 附件元数据里存有可信时间的再回填。回合中现场转换的消息不经这里，时间可信。
            messages: messages.map { stored in
                var message = stored.asChatMessageUI()
                message.hasUnverifiedTimestamp = true
                return message
            },
            pinned: pinned,
            unread: unread,
            projectID: projectID,
            projectName: projectName,
            workingDirectory: workingDirectory,
            groupID: groupID.flatMap(UUID.init(uuidString:)),
            modelID: modelID,
            providerTypeRaw: providerTypeRaw,
            lineageVersion: lineageVersion,
            rootSessionID: rootSessionID,
            parentSessionID: parentSessionID,
            forkedFromSessionID: forkedFromSessionID,
            forkedThroughTranscriptRevision: forkedThroughTranscriptRevision,
            forkedThroughMessageID: forkedThroughMessageID,
            createdByTaskID: createdByTaskID,
            createdByRunID: createdByRunID,
            taskSourceSessionID: taskSourceSessionID,
            transcriptRevision: transcriptRevision
        )
    }
}

extension ChatMessageUI {
    /// UI 消息 → LLMMessage（system 角色降级为 assistant，调用方先过滤）。
    func asLLMMessage() -> LLMMessage {
        let llmRole: LLMMessage.Role
        switch role {
        case .user:
            llmRole = .user
        case .assistant:
            llmRole = .assistant
        case .tool:
            llmRole = .tool
        case .system:
            // System 画布提示由 asPersisted 过滤；保留旧直接调用方的降级语义。
            llmRole = .assistant
        }
        let failedVideoNotices = attachments.compactMap { attachment -> String? in
            guard attachment.fileType == .video,
                  attachment.status == .failed,
                  attachment.videoFrames != nil else {
                return nil
            }
            return "视频 \(attachment.fileName) 的静帧与时间码恢复校验失败；本轮不附加该视频画面，不能按原时间码判断视频内容。"
        }
        let failedAudioNotices = ChatAttachmentPersistence.audioRestoreNotices(attachments)
        // Only a producer-frozen, fully validated span partition may remove a
        // failed video's generated part. Legacy or malformed ownership keeps
        // the complete canonical body and still refuses the video payload.
        let safeBody = failedVideoNotices.isEmpty ? content
            : (ChatAttachmentPersistence.contentWithoutFailedVideoParts(self) ?? content)
        let notices = failedVideoNotices + failedAudioNotices
        let noticePrefix = notices.joined(separator: "\n") + "\n\n"
        // A prior canonical rewrite may already have saved this exact leading
        // diagnostic. Re-entry must not stack it again; this prefix check does
        // not grant provenance to any of the remaining body text.
        let projectedContent = notices.isEmpty || safeBody.hasPrefix(noticePrefix)
            ? safeBody : noticePrefix + safeBody
        return LLMMessage(
            role: llmRole,
            content: projectedContent,
            images: llmImages,
            audios: llmAudios,
            toolCallID: toolCallID,
            toolCalls: toolCalls,
            legacyToolOutputSummary: legacyToolOutputSummary
        )
    }
}

extension LLMMessage {
    /// LLMMessage → UI 消息（无流式标记，timestamp 取当前时间）。
    /// 时间不是消息的真实时间，标为“未核实”；由 sidecar 的消息时间回填后才可信。
    func asChatMessageUI() -> ChatMessageUI {
        let imageAttachments = images.enumerated().map { index, image in
            ChatAttachment(
                kind: .image,
                fileName: "恢复图片-\(index + 1).bin",
                fileType: .image,
                mimeType: image.mimeType,
                size: Int64(image.data.count),
                data: image.data
            )
        }
        let audioAttachments = audios.enumerated().compactMap { index, audio -> ChatAttachment? in
            guard let data = Data(base64Encoded: audio.base64Data) else { return nil }
            return ChatAttachment(
                kind: .audio,
                fileName: "恢复音频-\(index + 1).\(audio.format)",
                fileType: .audio,
                mimeType: "audio/\(audio.format)",
                size: Int64(data.count),
                data: data
            )
        }
        let uiRole: ChatRole
        switch role {
        case .user:
            uiRole = .user
        case .assistant:
            uiRole = .assistant
        case .tool:
            uiRole = .tool
        }
        return ChatMessageUI(
            role: uiRole,
            content: content,
            attachments: imageAttachments + audioAttachments,
            toolCallID: toolCallID,
            toolCalls: toolCalls,
            legacyToolOutputSummary: legacyToolOutputSummary
        )
    }
}
