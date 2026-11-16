import Foundation
import CryptoKit
import Darwin

/// Read-only access to explicitly selected Codex rollout JSONL files. The root is
/// supplied by the caller; this type never resolves the user's Codex home.
public struct ExternalSessionCodexRolloutReadAdapter: ExistingAgentSessionAdapter, ExternalSessionProjectMembershipVerifier {
    private let reader: ExternalSessionJSONLReader
    public var source: ExternalSessionSourceV1 { reader.source }

    public init(
        sourceID: ExternalSessionSourceID,
        profileID: ExternalSessionProfileID,
        hostID: String,
        rootURL: URL,
        authorizationLedger: ExternalSessionAuthorizationLedgerV1,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        reader = ExternalSessionJSONLReader(kind: .codex, sourceID: sourceID,
            profileID: profileID, hostID: hostID, rootURL: rootURL,
            authorizationLedger: authorizationLedger, clock: clock)
    }

    public func listThreads(query: ExternalSessionThreadQueryV1, readGrant: ExternalSessionReadGrantV1) async throws -> ExternalSessionThreadPageV1 {
        try await reader.listThreads(query: query, readGrant: readGrant)
    }
    public func read(request: ExternalSessionReadRequestV1, readGrant: ExternalSessionReadGrantV1) async throws -> ExternalSessionReadPageV1 {
        try await reader.read(request: request, readGrant: readGrant)
    }
    public func status(target: ExternalSessionStatusTargetV1, readGrant: ExternalSessionReadGrantV1) async throws -> ExternalSessionStatusV1 {
        try await reader.status(target: target, readGrant: readGrant)
    }
    public func control(request: ExternalSessionControlRequestV1, controlGrant: ExternalSessionControlGrantV1) async throws -> ExternalSessionControlReceiptV1 {
        reader.unsupportedControl(request)
    }
    public func contains(threadID: ExternalSessionThreadID, projectID: ExternalSessionProjectID) async throws -> Bool {
        try reader.contains(threadID: threadID, projectID: projectID)
    }
}

/// Read-only access to the documented Claude Code local JSONL shape. Desktop
/// registry-only and remote sessions are outside this adapter's capability.
public struct ExternalSessionClaudeCodeReadAdapter: ExistingAgentSessionAdapter, ExternalSessionProjectMembershipVerifier {
    private let reader: ExternalSessionJSONLReader
    public var source: ExternalSessionSourceV1 { reader.source }

    public init(
        sourceID: ExternalSessionSourceID,
        profileID: ExternalSessionProfileID,
        hostID: String,
        rootURL: URL,
        authorizationLedger: ExternalSessionAuthorizationLedgerV1,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        reader = ExternalSessionJSONLReader(kind: .claudeCode, sourceID: sourceID,
            profileID: profileID, hostID: hostID, rootURL: rootURL,
            authorizationLedger: authorizationLedger, clock: clock)
    }

    public func listThreads(query: ExternalSessionThreadQueryV1, readGrant: ExternalSessionReadGrantV1) async throws -> ExternalSessionThreadPageV1 {
        try await reader.listThreads(query: query, readGrant: readGrant)
    }
    public func read(request: ExternalSessionReadRequestV1, readGrant: ExternalSessionReadGrantV1) async throws -> ExternalSessionReadPageV1 {
        try await reader.read(request: request, readGrant: readGrant)
    }
    public func status(target: ExternalSessionStatusTargetV1, readGrant: ExternalSessionReadGrantV1) async throws -> ExternalSessionStatusV1 {
        try await reader.status(target: target, readGrant: readGrant)
    }
    public func control(request: ExternalSessionControlRequestV1, controlGrant: ExternalSessionControlGrantV1) async throws -> ExternalSessionControlReceiptV1 {
        reader.unsupportedControl(request)
    }
    public func contains(threadID: ExternalSessionThreadID, projectID: ExternalSessionProjectID) async throws -> Bool {
        try reader.contains(threadID: threadID, projectID: projectID)
    }
}

/// These errors distinguish an unsupported on-disk variant from absent data.
public enum ExternalSessionJSONLReadError: Error, Equatable, Sendable {
    case invalidRequest
    case sourceMismatch
    case profileMismatch
    case scopeNotGranted
    case targetMismatch
    case grantNotActive
    case invalidCursor
    case unknownThread
    case duplicateThread
    case unsupportedFormat
    case unsafeRoot
    case fileTooLarge
    case unsupportedProjectListing
}

private struct ExternalSessionJSONLReader: Sendable {
    private struct FileIdentity: Sendable {
        let device: UInt64
        let inode: UInt64
    }
    let source: ExternalSessionSourceV1
    let rootURL: URL
    private let rootIdentity: FileIdentity?
    let ledger: ExternalSessionAuthorizationLedgerV1
    let clock: @Sendable () -> Date

    init(kind: ExternalSessionSourceKindV1, sourceID: ExternalSessionSourceID,
         profileID: ExternalSessionProfileID, hostID: String, rootURL: URL,
         authorizationLedger: ExternalSessionAuthorizationLedgerV1,
         clock: @escaping @Sendable () -> Date) {
        // Pin the caller's selected directory to its physical path once the
        // composition layer has admitted the source grant. macOS temporary
        // roots commonly enter through /var -> /private/var; body opens still
        // reject every symlink in the pinned physical path via openat.
        let selectedRoot = rootURL.standardizedFileURL
        let selectedValues = try? selectedRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        // Foundation's resolvingSymlinksInPath leaves macOS /var unchanged;
        // realpath pins the selected directory to its actual physical path.
        let physicalPath = selectedRoot.path.withCString { path -> String? in
            guard let resolved = Darwin.realpath(path, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let normalizedRoot = physicalPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? selectedRoot
        let values = try? normalizedRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        var rootInfo = stat()
        let rootStatOK = normalizedRoot.path.withCString { Darwin.lstat($0, &rootInfo) == 0 }
        let identity = rootStatOK && (rootInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
            ? FileIdentity(device: UInt64(rootInfo.st_dev), inode: UInt64(rootInfo.st_ino)) : nil
        let rootReady = normalizedRoot.isFileURL && normalizedRoot.path != "/" &&
            physicalPath != nil && selectedValues?.isSymbolicLink != true &&
            values?.isDirectory == true && values?.isSymbolicLink != true && identity != nil
        self.source = ExternalSessionSourceV1(sourceID: sourceID, kind: kind,
            adapterVersion: kind == .codex ? "codex-rollout-jsonl-v1/1" : "claude-code-jsonl-v1-v2/1",
            profileID: profileID, hostID: hostID,
            capabilities: rootReady ? [.readMetadata, .readMessages, .status] : [],
            authState: rootReady ? .authorized : .unavailable)
        self.rootURL = normalizedRoot
        self.rootIdentity = identity
        self.ledger = authorizationLedger
        self.clock = clock
    }

    func listThreads(query: ExternalSessionThreadQueryV1, readGrant: ExternalSessionReadGrantV1) async throws -> ExternalSessionThreadPageV1 {
        try validate(readGrant, requestSource: query.sourceID, target: .source(query.sourceID),
                     scope: .metadata, projectID: query.projectID)
        guard query.schemaVersion == ExternalSessionContractV1.schemaVersion,
              query.limit > 0, query.limit <= 50 else { throw ExternalSessionJSONLReadError.invalidRequest }
        // Codex project membership lives in each session header. A project
        // grant cannot authorize scanning sibling projects' headers; callers
        // may list with a source grant or read an exact thread via membership.
        if case .project = readGrant.target { throw ExternalSessionJSONLReadError.unsupportedProjectListing }
        let offset = try cursorOffset(query.cursor, prefix: "jsonl:list:")
        try await active(readGrant)
        let records = try discover().filter { query.projectID == nil || $0.projectID == query.projectID }
            .sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
        guard offset <= records.count else { throw ExternalSessionJSONLReadError.invalidCursor }
        let end = min(offset + Int(query.limit), records.count)
        let threads = records[offset..<end].map { record in
            ExternalSessionThreadV1(sourceID: source.sourceID,
                threadID: ExternalSessionThreadID(rawValue: record.id), projectID: record.projectID,
                title: "\(source.kind == .codex ? "Codex" : "Claude Code") \(record.id.prefix(8))",
                status: .unknown, updatedAt: record.updatedAt,
                sourceCursor: .beginning, readable: true)
        }
        try await active(readGrant)
        return ExternalSessionThreadPageV1(sourceID: source.sourceID, threads: threads,
            nextCursor: end < records.count ? ExternalSessionCursorV1(rawValue: "jsonl:list:\(end)") : nil,
            observedCursor: ExternalSessionCursorV1(rawValue: "jsonl:size:\(records.count)"))
    }

    func read(request: ExternalSessionReadRequestV1, readGrant: ExternalSessionReadGrantV1) async throws -> ExternalSessionReadPageV1 {
        try validate(readGrant, requestSource: request.sourceID, target: .thread(request.threadID), scope: .messages)
        guard request.schemaVersion == ExternalSessionContractV1.schemaVersion,
              request.limit > 0, request.limit <= 50 else { throw ExternalSessionJSONLReadError.invalidRequest }
        try await active(readGrant)
        let record = try locate(request.threadID)
        try requireProjectMembership(readGrant, record: record)
        let messages = try loadMessages(record)
        let eligible = messages.filter { request.turnID == nil || $0.turnID == request.turnID }
        let snapshot = Self.messageSnapshot(threadID: request.threadID, messages: eligible)
        let offset = try cursorOffset(request.cursor, prefix: "jsonl:chunk:\(snapshot):")
        let allChunks = eligible.flatMap { chunks(of: $0, threadID: request.threadID, record: record) }
        guard offset <= allChunks.count else { throw ExternalSessionJSONLReadError.invalidCursor }
        let end = min(offset + Int(request.limit), allChunks.count)
        let selected = Array(allChunks[offset..<end])
        let selectedMessages = eligible.filter { message in
            selected.contains { $0.messageID == "\(record.id):\(message.line)" && $0.chunkIndex == 0 }
        }
        let events = selectedMessages.map { message in
            ExternalSessionEventV1(eventID: ExternalSessionEventID(rawValue: "\(record.id):\(message.line)"),
                sourceID: source.sourceID, threadID: request.threadID, turnID: message.turnID,
                sequence: UInt64(message.line),
                sourceCursor: ExternalSessionCursorV1(rawValue: "jsonl:chunk:\(snapshot):\(end)"),
                occurredAt: message.timestamp ?? record.updatedAt, required: true, kind: .progress,
                payload: ExternalSessionRedactedPayloadV1(kind: message.role, summary: Self.summary(message.text)),
                sourceRef: "\(source.kind.rawValue):\(record.id)#line:\(message.line)")
        }
        let turns = Array(Set(selected.compactMap(\.turnID))).sorted { $0.rawValue < $1.rawValue }.map { turnID in
            ExternalSessionTurnV1(sourceID: source.sourceID, threadID: request.threadID,
                turnID: turnID, status: .unknown,
                sourceCursor: ExternalSessionCursorV1(rawValue: "jsonl:chunk:\(snapshot):\(end)"))
        }
        // Metadata can change while the body is read. Re-resolve membership
        // before publishing the page, then recheck the revocation epoch.
        try requireProjectMembership(readGrant, record: locate(request.threadID))
        try await active(readGrant)
        return ExternalSessionReadPageV1(sourceID: source.sourceID, threadID: request.threadID,
            turns: turns, events: events, messageChunks: selected,
            nextCursor: end < allChunks.count ? ExternalSessionCursorV1(rawValue: "jsonl:chunk:\(snapshot):\(end)") : nil,
            observedCursor: ExternalSessionCursorV1(rawValue: "jsonl:line:\(messages.last?.line ?? 0)"))
    }

    func status(target: ExternalSessionStatusTargetV1, readGrant: ExternalSessionReadGrantV1) async throws -> ExternalSessionStatusV1 {
        let requested: ExternalSessionReadTargetV1 = target.threadID.map(ExternalSessionReadTargetV1.thread) ?? .source(target.sourceID)
        try validate(readGrant, requestSource: target.sourceID, target: requested, scope: .status)
        guard target.schemaVersion == ExternalSessionContractV1.schemaVersion else { throw ExternalSessionJSONLReadError.invalidRequest }
        try await active(readGrant)
        if let threadID = target.threadID {
            let record = try locate(threadID)
            try requireProjectMembership(readGrant, record: record)
            let messages = try loadMessages(record)
            let matching = target.turnID == nil ? messages : messages.filter { $0.turnID == target.turnID }
            if target.turnID != nil && matching.isEmpty { throw ExternalSessionJSONLReadError.unknownThread }
            let last = matching.last
            let lifecycle = try lifecycleStatus(record)
            try requireProjectMembership(readGrant, record: locate(threadID))
            try await active(readGrant)
            return ExternalSessionStatusV1(sourceID: source.sourceID, threadID: threadID,
                turnID: target.turnID,
                threadStatus: lifecycle,
                turnStatus: lifecycle == .completed && last?.role == "assistant" ? .succeeded : .unknown,
                observedCursor: ExternalSessionCursorV1(rawValue: "jsonl:line:\(messages.last?.line ?? 0)"),
                latestSequence: last.map { UInt64($0.line) })
        }
        let count = try discover().count
        try await active(readGrant)
        return ExternalSessionStatusV1(sourceID: source.sourceID,
            observedCursor: ExternalSessionCursorV1(rawValue: "jsonl:size:\(count)"))
    }

    func unsupportedControl(_ request: ExternalSessionControlRequestV1) -> ExternalSessionControlReceiptV1 {
        ExternalSessionControlReceiptV1(sourceID: request.sourceID, threadID: request.threadID,
            turnID: request.turnID, operation: request.operation, outcome: .unsupported,
            sourceCursor: .beginning, detail: "read-only JSONL adapter")
    }

    func contains(threadID: ExternalSessionThreadID, projectID: ExternalSessionProjectID) throws -> Bool {
        try locate(threadID).projectID == projectID
    }

    private func requireProjectMembership(_ grant: ExternalSessionReadGrantV1, record: Record) throws {
        if case let .project(projectID) = grant.target, record.projectID != projectID {
            throw ExternalSessionJSONLReadError.targetMismatch
        }
    }

    private func validate(_ grant: ExternalSessionReadGrantV1, requestSource: ExternalSessionSourceID,
                          target: ExternalSessionReadTargetV1, scope: ExternalSessionReadScopeV1,
                          projectID: ExternalSessionProjectID? = nil) throws {
        guard requestSource == source.sourceID, grant.sourceID == source.sourceID else { throw ExternalSessionJSONLReadError.sourceMismatch }
        guard grant.profileID == source.profileID else { throw ExternalSessionJSONLReadError.profileMismatch }
        guard grant.schemaVersion == ExternalSessionContractV1.schemaVersion,
              grant.issuedAt <= clock(), clock() < grant.expiresAt else { throw ExternalSessionJSONLReadError.grantNotActive }
        guard grant.scopes.contains(scope) else { throw ExternalSessionJSONLReadError.scopeNotGranted }
        let projectThreadAdmission: Bool
        if case .project = grant.target, case .thread = target {
            // The exact membership check follows metadata discovery and precedes body I/O.
            projectThreadAdmission = true
        } else {
            projectThreadAdmission = false
        }
        guard projectThreadAdmission || ExternalSessionLocalStoreAdapter.targetMatches(grant.target, requestedTarget: target,
            projectID: projectID, sourceID: source.sourceID) else { throw ExternalSessionJSONLReadError.targetMismatch }
    }

    private func active(_ grant: ExternalSessionReadGrantV1) async throws {
        try Task.checkCancellation()
        guard clock() < grant.expiresAt, await ledger.isAuthorizationActive(
            sourceID: grant.sourceID, profileID: grant.profileID,
            revocationEpoch: grant.revocationEpoch) else { throw ExternalSessionJSONLReadError.grantNotActive }
        try Task.checkCancellation()
        guard clock() < grant.expiresAt else { throw ExternalSessionJSONLReadError.grantNotActive }
    }

    private func cursorOffset(_ cursor: ExternalSessionCursorV1, prefix: String) throws -> Int {
        if cursor == .beginning { return 0 }
        guard cursor.rawValue.hasPrefix(prefix),
              let value = Int(cursor.rawValue.dropFirst(prefix.count)), value >= 0 else {
            throw ExternalSessionJSONLReadError.invalidCursor
        }
        return value
    }

    private struct Record {
        let id: String
        let projectID: ExternalSessionProjectID
        let url: URL
        let updatedAt: Date
    }
    private struct Message {
        let line: Int
        let role: String
        let text: String
        let turnID: ExternalSessionTurnID
        let timestamp: Date?
    }

    private func discover() throws -> [Record] {
        let root = rootURL
        guard root.isFileURL, root.path != "/", !root.path.isEmpty,
              (try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map({ $0.isDirectory == true && $0.isSymbolicLink != true }) == true else {
            throw ExternalSessionJSONLReadError.unsafeRoot
        }
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { throw ExternalSessionJSONLReadError.unsafeRoot }
        var records: [Record] = []
        var scanned = 0
        while let url = enumerator.nextObject() as? URL {
            scanned += 1
            if scanned > 2_048 { throw ExternalSessionJSONLReadError.unsupportedFormat }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard values.isRegularFile == true, url.pathExtension == "jsonl" else { continue }
            guard (values.fileSize ?? 0) <= 8_388_608 else { continue }
            guard let record = try metadata(url: url, updatedAt: values.contentModificationDate ?? .distantPast) else { continue }
            records.append(record)
            if records.count > 512 { throw ExternalSessionJSONLReadError.unsupportedFormat }
        }
        return records
    }

    private func locate(_ threadID: ExternalSessionThreadID) throws -> Record {
        guard UUID(uuidString: threadID.rawValue) != nil else { throw ExternalSessionJSONLReadError.unknownThread }
        // A thread grant does not authorize metadata reads of sibling threads.
        // Enumerate names only, then open the sole matching file's first line.
        let root = rootURL
        guard root.isFileURL, root.path != "/", !root.path.isEmpty,
              (try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map({ $0.isDirectory == true && $0.isSymbolicLink != true }) == true,
              let enumerator = FileManager.default.enumerator(at: root,
                  includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey],
                  options: [.skipsHiddenFiles]) else { throw ExternalSessionJSONLReadError.unsafeRoot }
        var match: URL?
        var modifiedAt = Date.distantPast
        var scanned = 0
        while let url = enumerator.nextObject() as? URL {
            scanned += 1
            if scanned > 2_048 { throw ExternalSessionJSONLReadError.unsupportedFormat }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard values.isRegularFile == true, url.pathExtension == "jsonl" else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            let isMatch = source.kind == .codex
                ? (name.hasPrefix("rollout-") && name.hasSuffix("-\(threadID.rawValue)"))
                : name == threadID.rawValue
            guard isMatch else { continue }
            guard match == nil else { throw ExternalSessionJSONLReadError.duplicateThread }
            match = url
            modifiedAt = values.contentModificationDate ?? .distantPast
        }
        guard let match, let record = try metadata(url: match, updatedAt: modifiedAt),
              record.id == threadID.rawValue else { throw ExternalSessionJSONLReadError.unknownThread }
        return record
    }

    private func metadata(url: URL, updatedAt: Date, firstLine suppliedLine: Data? = nil) throws -> Record? {
        let name = url.deletingPathExtension().lastPathComponent
        let id: String
        if source.kind == .codex {
            let suffix = name.split(separator: "-").suffix(5).joined(separator: "-")
            guard name.hasPrefix("rollout-"),
                  UUID(uuidString: suffix) != nil else { return nil }
            id = suffix
        } else {
            guard UUID(uuidString: name) != nil else { return nil }
            id = name
        }
        let directoryProjectID: ExternalSessionProjectID? = source.kind == .claudeCode
            ? Self.projectID(for: url.deletingLastPathComponent().lastPathComponent,
                namespace: "claude-project-dir-sha256") : nil
        if let directoryProjectID, suppliedLine == nil {
            // Claude's first JSONL row is already a user message. Derive
            // membership from the selected project directory, so listing or
            // project verification never reads message bytes. Still verify
            // the pinned physical root and every path component.
            let (handle, _) = try openNoFollowFile(url)
            try? handle.close()
            return Record(id: id, projectID: directoryProjectID,
                url: url, updatedAt: updatedAt)
        }
        // Discovery reads only this file's first metadata line. Body reads
        // supply the first line from their own descriptor, avoiding a path
        // reopen between identity validation and transcript acquisition.
        let firstLine: Data
        if let suppliedLine {
            firstLine = suppliedLine
        } else {
            let (handle, initialStat) = try openNoFollowFile(url)
            defer { try? handle.close() }
            firstLine = try readFirstLine(handle)
            try requireStableFile(handle, initialStat)
        }
        guard firstLine.count < 16_384 else { throw ExternalSessionJSONLReadError.unsupportedFormat }
        for line in [firstLine] {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            let payload = source.kind == .codex ? object["payload"] as? [String: Any] : object
            let row = payload ?? [:]
            let rowID = source.kind == .codex ? row["id"] as? String : row["sessionId"] as? String
            let version = source.kind == .codex ? row["cli_version"] as? String : row["version"] as? String
            let validVersion = source.kind == .codex
                ? (version?.hasPrefix("0.") == true || version?.hasPrefix("1.") == true)
                : (version?.hasPrefix("1.") == true || version?.hasPrefix("2.") == true)
            guard rowID == id else { return nil }
            guard let cwd = row["cwd"] as? String, !cwd.isEmpty,
                  validVersion, source.kind != .codex || object["type"] as? String == "session_meta" else { continue }
            let projectID = directoryProjectID ?? Self.projectID(for: cwd,
                namespace: "cwd-sha256")
            return Record(id: id, projectID: projectID,
                url: url, updatedAt: updatedAt)
        }
        throw ExternalSessionJSONLReadError.unsupportedFormat
    }

    private static func projectID(for value: String, namespace: String) -> ExternalSessionProjectID {
        let digest = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        return ExternalSessionProjectID(rawValue: "\(namespace):\(digest)")
    }

    private static func messageSnapshot(threadID: ExternalSessionThreadID,
                                        messages: [Message]) -> String {
        var data = Data(threadID.rawValue.utf8)
        for message in messages {
            for field in [String(message.line), message.role, message.turnID.rawValue, message.text] {
                let bytes = Data(field.utf8)
                var length = UInt64(bytes.count).bigEndian
                withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
                data.append(bytes)
            }
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func openNoFollowFile(_ url: URL) throws -> (FileHandle, stat) {
        guard let rootIdentity else { throw ExternalSessionJSONLReadError.unsafeRoot }
        return try ExternalSessionPinnedJSONLFile.open(url,
            rootDevice: rootIdentity.device, rootInode: rootIdentity.inode)
    }

    private func readFirstLine(_ handle: FileHandle) throws -> Data {
        var line = Data()
        while line.count < 16_384 {
            guard let byte = try handle.read(upToCount: 1), !byte.isEmpty else { break }
            if byte[0] == 10 { return line }
            line.append(byte)
        }
        guard line.count < 16_384 else { throw ExternalSessionJSONLReadError.unsupportedFormat }
        return line
    }

    private func requireStableFile(_ handle: FileHandle, _ initial: stat) throws {
        var current = stat()
        guard Darwin.fstat(handle.fileDescriptor, &current) == 0,
              current.st_dev == initial.st_dev,
              current.st_ino == initial.st_ino,
              current.st_size == initial.st_size,
              current.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
              current.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec,
              current.st_ctimespec.tv_sec == initial.st_ctimespec.tv_sec,
              current.st_ctimespec.tv_nsec == initial.st_ctimespec.tv_nsec else {
            throw ExternalSessionJSONLReadError.unsafeRoot
        }
    }

    private func validatedBodyText(_ record: Record) throws -> String {
        let (handle, initialStat) = try openNoFollowFile(record.url)
        defer { try? handle.close() }
        let firstLine = try readFirstLine(handle)
        guard let current = try metadata(url: record.url, updatedAt: record.updatedAt, firstLine: firstLine),
              current.id == record.id, current.projectID == record.projectID else {
            throw ExternalSessionJSONLReadError.targetMismatch
        }
        var data = firstLine
        data.append(10)
        while data.count <= 8_388_608 {
            let allowance = min(65_536, 8_388_609 - data.count)
            guard allowance > 0, let part = try handle.read(upToCount: allowance), !part.isEmpty else { break }
            data.append(part)
        }
        guard data.count <= 8_388_608, let text = String(data: data, encoding: .utf8) else {
            throw ExternalSessionJSONLReadError.fileTooLarge
        }
        try requireStableFile(handle, initialStat)
        return text
    }

    private func loadMessages(_ record: Record) throws -> [Message] {
        let text = try validatedBodyText(record)
        var messages: [Message] = []
        var codexEvents: [Message] = []
        var codexResponses: [Message] = []
        var turn = 0
        var responseTurn = 0
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if source.kind == .codex {
                guard let payload = object["payload"] as? [String: Any] else { continue }
                if object["type"] as? String == "event_msg" {
                    let eventType = payload["type"] as? String
                    let role: String
                    let content: Any?
                    switch eventType {
                    case "user_message":
                        role = "user"
                        content = payload["message"]
                    case "agent_message":
                        role = "assistant"
                        content = payload["message"]
                    case "item_completed":
                        guard let item = payload["item"] as? [String: Any],
                              let kind = item["type"] as? String else { continue }
                        if kind == "UserMessage" { role = "user" }
                        else if kind == "AgentMessage" { role = "assistant" }
                        else { continue }
                        content = item["content"] ?? item["text"]
                    default: continue
                    }
                    let fragments = Self.textFragments(content)
                    guard !fragments.isEmpty else { continue }
                    if role == "user" { turn += 1 }
                    codexEvents.append(Message(line: index + 1, role: role,
                        text: fragments.joined(separator: "\n"),
                        turnID: ExternalSessionTurnID(rawValue: "turn-\(turn)"),
                        timestamp: Self.date(object["timestamp"] as? String)))
                } else if object["type"] as? String == "response_item",
                          payload["type"] as? String == "message",
                          let role = payload["role"] as? String,
                          role == "user" || role == "assistant" {
                    let fragments = Self.textFragments(payload["content"])
                    guard !fragments.isEmpty else { continue }
                    if role == "user" { responseTurn += 1 }
                    codexResponses.append(Message(line: index + 1, role: role,
                        text: fragments.joined(separator: "\n"),
                        turnID: ExternalSessionTurnID(rawValue: "turn-\(responseTurn)"),
                        timestamp: Self.date(object["timestamp"] as? String)))
                }
            } else {
                guard let rowID = object["sessionId"] as? String, rowID == record.id,
                      let type = object["type"] as? String,
                      type == "user" || type == "assistant",
                      let payload = object["message"] as? [String: Any] else { continue }
                guard let role = payload["role"] as? String, role == "user" || role == "assistant" else { continue }
                let fragments = Self.textFragments(payload["content"])
                guard !fragments.isEmpty else { continue }
                if role == "user" { turn += 1 }
                messages.append(Message(line: index + 1, role: role,
                    text: fragments.joined(separator: "\n"),
                    turnID: ExternalSessionTurnID(rawValue: "turn-\(turn)"),
                    timestamp: Self.date(object["timestamp"] as? String)))
            }
        }
        // Codex's persisted presentation events are the canonical conversation
        // stream. Response items are model input/output and can duplicate them;
        // use response items only for the older variant with no message events.
        return source.kind == .codex
            ? (codexEvents.isEmpty ? codexResponses : codexEvents)
            : messages
    }

    private static func textFragments(_ content: Any?) -> [String] {
        if let string = content as? String { return [string] }
        guard let blocks = content as? [[String: Any]] else { return [] }
        return blocks.compactMap { block in
            guard ["input_text", "output_text", "text", "Text"].contains(block["type"] as? String ?? "") else { return nil }
            return block["text"] as? String
        }
    }

    private func lifecycleStatus(_ record: Record) throws -> ExternalSessionThreadStatusV1 {
        guard source.kind == .codex else { return .unknown }
        let text = try validatedBodyText(record)
        var state = ExternalSessionThreadStatusV1.unknown
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  row["type"] as? String == "event_msg",
                  let payload = row["payload"] as? [String: Any],
                  let kind = payload["type"] as? String else { continue }
            switch kind {
            case "task_started": state = .active
            case "task_complete": state = .completed
            case "task_aborted": state = .interrupted
            default: break
            }
        }
        return state
    }

    private func chunks(of message: Message, threadID: ExternalSessionThreadID, record: Record) -> [ExternalSessionMessageChunkV1] {
        // Redact before slicing, so a secret cannot cross a chunk boundary.
        let redacted = ContentSecretRedactor.redact(message.text)
        var pieces: [String] = []
        var current = ""
        var bytes = 0
        for character in redacted {
            let value = String(character)
            let count = value.utf8.count
            if current.count >= ExternalSessionMessageChunkV1.maximumCharacters ||
                bytes + count > ExternalSessionMessageChunkV1.maximumUTF8Bytes {
                pieces.append(current)
                current = ""
                bytes = 0
            }
            // A single oversized grapheme cannot fit the contract; omit it
            // instead of emitting a malformed chunk.
            guard count <= ExternalSessionMessageChunkV1.maximumUTF8Bytes else { continue }
            current.append(character)
            bytes += count
        }
        if !current.isEmpty || pieces.isEmpty { pieces.append(current) }
        return pieces.enumerated().map { index, piece in
            ExternalSessionMessageChunkV1(sourceID: source.sourceID, threadID: threadID,
                turnID: message.turnID, messageID: "\(record.id):\(message.line)", role: message.role,
                chunkIndex: UInt32(index), text: piece, isLastChunk: index == pieces.count - 1,
                sourceRef: "\(source.kind.rawValue):\(record.id)#line:\(message.line)#chunk:\(index)")
        }
    }

    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }
    private static func summary(_ text: String) -> String {
        let redacted = ContentSecretRedactor.redact(text)
        guard let bounded = try? SessionReadBoundedTextProjection(text: redacted,
            maxCharacters: 512, maxBytes: 2_048) else { return "" }
        return bounded.text + (bounded.isTruncated ? "…" : "")
    }
}

/// Descriptor-based containment for the JSONL reader. Foundation may enumerate
/// an APFS firmlink using another absolute spelling of the same physical root.
/// Path strings are not authority: every component is opened without following
/// symlinks, and the directory chain must include the pinned device/inode.
internal enum ExternalSessionPinnedJSONLFile {
    static func open(_ url: URL, rootDevice: UInt64, rootInode: UInt64) throws -> (FileHandle, stat) {
        let path = url.path
        guard url.isFileURL, path.hasPrefix("/"), path != "/" else {
            throw ExternalSessionJSONLReadError.unsafeRoot
        }
        // Traverse from / with O_NOFOLLOW on every directory component, not
        // merely the final file. A swapped root/intermediate symlink cannot
        // redirect the open outside the explicitly selected physical tree.
        let parts = path.split(separator: "/").map(String.init)
        guard let filename = parts.last, parts.count > 1,
              !parts.contains("."), !parts.contains("..") else { throw ExternalSessionJSONLReadError.unsafeRoot }
        var parent = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw ExternalSessionJSONLReadError.unsafeRoot }
        defer { _ = Darwin.close(parent) }
        var crossedPinnedRoot = false
        for part in parts.dropLast() {
            let next = Darwin.openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw ExternalSessionJSONLReadError.unsafeRoot }
            var openedDirectory = stat()
            guard Darwin.fstat(next, &openedDirectory) == 0 else {
                _ = Darwin.close(next)
                throw ExternalSessionJSONLReadError.unsafeRoot
            }
            if UInt64(openedDirectory.st_dev) == rootDevice,
               UInt64(openedDirectory.st_ino) == rootInode {
                crossedPinnedRoot = true
            }
            _ = Darwin.close(parent)
            parent = next
        }
        // No file bytes are opened until this descriptor chain has traversed
        // the exact selected physical directory. APFS firmlink aliases are
        // accepted by identity; a sibling or replacement root cannot qualify.
        guard crossedPinnedRoot else { throw ExternalSessionJSONLReadError.unsafeRoot }
        let descriptor = Darwin.openat(parent, filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ExternalSessionJSONLReadError.unsafeRoot }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            _ = Darwin.close(descriptor)
            throw ExternalSessionJSONLReadError.unsafeRoot
        }
        guard info.st_size <= 8_388_608 else {
            _ = Darwin.close(descriptor)
            throw ExternalSessionJSONLReadError.fileTooLarge
        }
        return (FileHandle(fileDescriptor: descriptor, closeOnDealloc: true), info)
    }
}
