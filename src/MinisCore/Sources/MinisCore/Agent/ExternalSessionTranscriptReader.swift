import CryptoKit
import Darwin
import Foundation

/// Errors of the external-session read path. `errorDescription` carries only a
/// stable code (never a filesystem path) so it is safe to hand to the model.
enum ExternalSessionReadError: Error, Equatable, LocalizedError, Sendable {
    struct Candidate: Equatable, Sendable {
        let source: String
        let sessionID: String
        let title: String
    }

    case noAuthorizedRoot
    case sourceNotAuthorized
    case sessionNotFound
    case ambiguousName([Candidate])
    case invalidCursor
    case fileUnreadable
    case invalidParameter(String)

    var code: String {
        switch self {
        case .noAuthorizedRoot: return "no_authorized_root"
        case .sourceNotAuthorized: return "source_not_authorized"
        case .sessionNotFound: return "session_not_found"
        case .ambiguousName: return "ambiguous_name"
        case .invalidCursor: return "invalid_cursor"
        case .fileUnreadable: return "file_unreadable"
        case .invalidParameter: return "invalid_parameter"
        }
    }

    var errorDescription: String? {
        switch self {
        case .noAuthorizedRoot:
            return "no_authorized_root: 可在“设置→隐私”打开“允许读取本机 Codex / Claude Code 会话”；或mount the sessions folder (.codex/sessions) or projects folder (.claude/projects) itself in Settings; mounting a parent folder does not authorize external session reading."
        case .invalidParameter(let name):
            return "invalid_parameter: \(name)"
        case .ambiguousName(let candidates):
            let items: [[String: Any]] = candidates.map {
                ["source": $0.source, "session_id": $0.sessionID,
                 "title": ExternalSessionReadTool.envelope($0.title)]
            }
            let object: [String: Any] = [
                "error": "ambiguous_name", "candidates": items,
                "content_trust": ExternalSessionReadTool.contentTrust,
                "notice": ExternalSessionReadTool.notice
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: object,
                    options: [.sortedKeys, .withoutEscapingSlashes]) else { return "ambiguous_name" }
            return String(decoding: data, as: UTF8.self)
        default:
            return code
        }
    }
}

/// Tunable bounds. The defaults are the production values; tests pass smaller
/// values to exercise the same code paths without multi-gigabyte fixtures.
struct ExternalSessionReadLimits: Sendable {
    var maxLineBytes = 4 << 20
    var maxScanBytes = 32 << 20
    var maxEnumeratedEntries = 200_000
    var headBytes = 64 << 10
    var nameSearchWindow = 200
    var titleCharacters = 40
    static let standard = ExternalSessionReadLimits()
}

/// Result of resolving a session by exact ID or by name.
struct LocatedSession: Equatable, Sendable {
    let id: String
    let source: String
    let fileMTime: Date
    let cwd: String?
    let title: String?
}

/// Streaming, bounded reader for Codex rollout and Claude Code project
/// transcripts. It never loads a whole file, never requires a stable file
/// snapshot (live sessions append), and skips bad lines/files with counts.
enum ExternalSessionTranscriptReader {
    typealias QualifiedRoot = ExternalSessionFormatMap.QualifiedRoot

    struct SessionFile: Sendable {
        let map: ExternalSessionFormatMap
        let rootPath: String
        /// Path components below the root; the last one is the file name.
        let relativePath: [String]
        let id: String
        let mtimeNs: Int64
        var mtime: Date { Date(timeIntervalSince1970: Double(mtimeNs) / 1_000_000_000) }
        var source: String { map.source }
    }

    struct SessionHead: Sendable {
        let title: String?
        let cwd: String?
    }

    struct ListedSession: Sendable {
        let file: SessionFile
        let head: SessionHead
    }

    struct ListPage: Sendable {
        let sessions: [ListedSession]
        let hasMore: Bool
        let nextCursor: String?
        let skippedFiles: Int
        let scannedNote: String?
    }

    struct MessageItem: Sendable, Equatable {
        let index: Int
        let role: String
        let text: String
        let truncated: Bool
    }

    struct MessagePage: Sendable {
        let messages: [MessageItem]
        let hasMore: Bool
        let nextCursor: String
        let skippedLines: Int
        let formatNote: String?
    }

    struct NameSearch: Sendable {
        let matches: [ListedSession]
        let note: String?
    }

    // MARK: Authorization

    /// Resolves which mounted roots may be read. Performs no directory I/O
    /// unless a root lexically matches a qualifying layout.
    static func authorizedRoots(for source: String?, roots: [URL]) throws -> [QualifiedRoot] {
        if let source, ExternalSessionFormatMap.map(forSource: source) == nil {
            throw ExternalSessionReadError.invalidParameter("source")
        }
        let qualified = ExternalSessionFormatMap.qualifiedRoots(from: roots)
        guard !qualified.isEmpty else { throw ExternalSessionReadError.noAuthorizedRoot }
        guard let source else { return qualified }
        let filtered = qualified.filter { $0.source == source }
        guard !filtered.isEmpty else { throw ExternalSessionReadError.sourceNotAuthorized }
        return filtered
    }

    // MARK: Locate (shared with the send tool)

    /// Resolves `session` (an exact UUID, or a name) to exactly one session
    /// under an authorized root. Names are matched against the titles of the
    /// newest sessions only; zero matches is `sessionNotFound`, several is
    /// `ambiguousName` (never auto-picked).
    static func locate(session: String, source: String, roots: [URL],
                       knownSecrets: [String] = [],
                       limits: ExternalSessionReadLimits = .standard) throws -> LocatedSession {
        let qualified = try authorizedRoots(for: source, roots: roots)
        let resolved = try resolve(session: session, qualified: qualified,
                                   knownSecrets: knownSecrets, limits: limits)
        return LocatedSession(id: resolved.file.id, source: resolved.file.source,
                              fileMTime: resolved.file.mtime,
                              cwd: resolved.head.cwd, title: resolved.head.title)
    }

    static func resolve(session: String, qualified: [QualifiedRoot], knownSecrets: [String],
                        limits: ExternalSessionReadLimits) throws -> ListedSession {
        let trimmed = session.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ExternalSessionReadError.invalidParameter("session") }
        if UUID(uuidString: trimmed) != nil {
            guard let file = findByID(trimmed, qualified: qualified, limits: limits) else {
                throw ExternalSessionReadError.sessionNotFound
            }
            return ListedSession(file: file, head: try readHead(file, knownSecrets: knownSecrets, limits: limits))
        }
        let search = try searchByName(trimmed, qualified: qualified, knownSecrets: knownSecrets, limits: limits)
        switch search.matches.count {
        case 0:
            throw ExternalSessionReadError.sessionNotFound
        case 1:
            return search.matches[0]
        default:
            throw ExternalSessionReadError.ambiguousName(search.matches.map {
                .init(source: $0.file.source, sessionID: $0.file.id, title: $0.head.title ?? "")
            })
        }
    }

    static func findByID(_ id: String, qualified: [QualifiedRoot],
                         limits: ExternalSessionReadLimits) -> SessionFile? {
        let wanted = id.lowercased()
        return enumerate(qualified, limits: limits).files.first { $0.id.lowercased() == wanted }
    }

    /// Title-substring search over the newest `nameSearchWindow` sessions.
    static func searchByName(_ name: String, qualified: [QualifiedRoot], knownSecrets: [String],
                             limits: ExternalSessionReadLimits) throws -> NameSearch {
        let needle = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, needle.count <= 64 else { throw ExternalSessionReadError.invalidParameter("name") }
        let files = enumerate(qualified, limits: limits).files
        let window = files.prefix(limits.nameSearchWindow)
        var matches: [ListedSession] = []
        for file in window {
            guard let head = try? readHead(file, knownSecrets: knownSecrets, limits: limits),
                  let title = head.title,
                  title.range(of: needle, options: .caseInsensitive) != nil else { continue }
            matches.append(ListedSession(file: file, head: head))
        }
        let note = files.count > window.count
            ? "searched_newest_\(window.count)_of_\(files.count)_sessions_by_modified_time" : nil
        return NameSearch(matches: matches, note: note)
    }

    // MARK: Listing

    static func listPage(qualified: [QualifiedRoot], cursor: String?, limit: Int,
                         knownSecrets: [String], limits: ExternalSessionReadLimits) throws -> ListPage {
        let enumeration = enumerate(qualified, limits: limits)
        var candidates = enumeration.files
        if let cursor {
            let key = try decodeListCursor(cursor)
            candidates = candidates.filter { isAfter($0, key) }
        }
        let hasMore = candidates.count > limit
        let page = Array(candidates.prefix(limit))
        var sessions: [ListedSession] = []
        var skipped = 0
        for file in page {
            if let head = try? readHead(file, knownSecrets: knownSecrets, limits: limits) {
                sessions.append(ListedSession(file: file, head: head))
            } else {
                skipped += 1
            }
        }
        if !page.isEmpty && sessions.isEmpty { throw ExternalSessionReadError.fileUnreadable }
        var next: String?
        if hasMore, let last = page.last {
            next = "xl1.\(last.mtimeNs).\(last.source).\(last.id.lowercased())"
        }
        return ListPage(sessions: sessions, hasMore: hasMore, nextCursor: next, skippedFiles: skipped,
                        scannedNote: enumeration.truncated
                            ? "enumeration_truncated_at_\(limits.maxEnumeratedEntries)_entries" : nil)
    }

    private struct ListKey { let mtimeNs: Int64; let source: String; let id: String }

    private static func decodeListCursor(_ cursor: String) throws -> ListKey {
        let parts = cursor.split(separator: ".", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, parts[0] == "xl1", let ns = Int64(parts[1]),
              ExternalSessionFormatMap.map(forSource: parts[2]) != nil,
              UUID(uuidString: parts[3]) != nil else { throw ExternalSessionReadError.invalidCursor }
        return ListKey(mtimeNs: ns, source: parts[2], id: parts[3].lowercased())
    }

    private static func isAfter(_ file: SessionFile, _ key: ListKey) -> Bool {
        if file.mtimeNs != key.mtimeNs { return file.mtimeNs < key.mtimeNs }
        return (file.source, file.id.lowercased()) > (key.source, key.id)
    }

    // MARK: Enumeration (names + lstat only; no file is opened)

    static func enumerate(_ roots: [QualifiedRoot], limits: ExternalSessionReadLimits)
        -> (files: [SessionFile], truncated: Bool) {
        var found: [SessionFile] = []
        var visited = 0
        var truncated = false
        for root in roots {
            guard let map = ExternalSessionFormatMap.map(forSource: root.source) else { continue }
            walk(directory: root.path, relative: [], map: map, rootPath: root.path,
                 limits: limits, found: &found, visited: &visited, truncated: &truncated)
            if truncated { break }
        }
        // One entry per (source, id): the newest copy wins.
        var best: [String: SessionFile] = [:]
        for file in found {
            let key = file.source + "\u{0}" + file.id.lowercased()
            if let existing = best[key], existing.mtimeNs >= file.mtimeNs { continue }
            best[key] = file
        }
        let files = best.values.sorted { lhs, rhs in
            if lhs.mtimeNs != rhs.mtimeNs { return lhs.mtimeNs > rhs.mtimeNs }
            return (lhs.source, lhs.id.lowercased()) < (rhs.source, rhs.id.lowercased())
        }
        return (files, truncated)
    }

    private static func walk(directory: String, relative: [String], map: ExternalSessionFormatMap,
                             rootPath: String, limits: ExternalSessionReadLimits,
                             found: inout [SessionFile], visited: inout Int, truncated: inout Bool) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
        for name in names.sorted() {
            if visited >= limits.maxEnumeratedEntries { truncated = true; return }
            visited += 1
            let path = directory + "/" + name
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            let kind = info.st_mode & S_IFMT
            if kind == S_IFDIR {
                guard relative.count + 1 < map.fileDepth else { continue }
                walk(directory: path, relative: relative + [name], map: map, rootPath: rootPath,
                     limits: limits, found: &found, visited: &visited, truncated: &truncated)
                if truncated { return }
            } else if kind == S_IFREG, let id = map.fileNamePattern(name) {
                let mtimeNs = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
                found.append(SessionFile(map: map, rootPath: rootPath, relativePath: relative + [name],
                                         id: id, mtimeNs: mtimeNs))
            }
            // Symbolic links and everything else are ignored.
        }
    }

    // MARK: Pinned open

    /// Opens the file component by component with `O_NOFOLLOW`, so a symlink
    /// anywhere below the root (including the file itself) is refused.
    static func openFile(_ file: SessionFile) throws -> Int32 {
        var descriptor = Darwin.open(file.rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ExternalSessionReadError.fileUnreadable }
        for (index, component) in file.relativePath.enumerated() {
            let isFile = index == file.relativePath.count - 1
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (isFile ? 0 : O_DIRECTORY)
            let next = Darwin.openat(descriptor, component, flags)
            Darwin.close(descriptor)
            guard next >= 0 else { throw ExternalSessionReadError.fileUnreadable }
            descriptor = next
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(descriptor)
            throw ExternalSessionReadError.fileUnreadable
        }
        return descriptor
    }

    // MARK: Head (title and cwd)

    static func readHead(_ file: SessionFile, knownSecrets: [String],
                         limits: ExternalSessionReadLimits) throws -> SessionHead {
        let descriptor = try openFile(file)
        defer { Darwin.close(descriptor) }
        var buffer = [UInt8](repeating: 0, count: limits.headBytes)
        var total = 0
        while total < limits.headBytes {
            let count = buffer.withUnsafeMutableBytes { raw in
                pread(descriptor, raw.baseAddress! + total, limits.headBytes - total, off_t(total))
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw ExternalSessionReadError.fileUnreadable
            }
            if count == 0 { break }
            total += count
        }
        var lines = buffer[0..<total].split(separator: 0x0A, omittingEmptySubsequences: false)
        // A full window ending mid-line has an incomplete last line.
        if total == limits.headBytes, buffer[total - 1] != 0x0A, !lines.isEmpty { lines.removeLast() }
        var title: String?
        var cwd: String?
        for line in lines {
            if title != nil && cwd != nil { break }
            guard !line.isEmpty,
                  let row = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            if cwd == nil { cwd = file.map.cwd(from: row) }
            if title == nil,
               let message = file.map.message(from: row, fileSessionID: file.id),
               file.map.titleRoles.contains(message.role) {
                title = makeTitle(message.text, knownSecrets: knownSecrets, characters: limits.titleCharacters)
            }
        }
        return SessionHead(title: title, cwd: cwd)
    }

    /// Redact first (so a secret cannot straddle the cut), then collapse
    /// whitespace and cut.
    static func makeTitle(_ text: String, knownSecrets: [String], characters: Int) -> String? {
        let capped = text.utf8.count > 8_192 ? String(text.prefix(2_048)) : text
        let redacted = ContentSecretRedactor.redact(capped, knownSecrets: knownSecrets)
        let collapsed = redacted.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(characters))
    }

    // MARK: Message pages

    /// 工具调用与结果每条最多这么多字符（参数、结果只给摘要）。
    static let toolItemMaxCharacters = 1_500

    static func readPage(_ file: SessionFile, cursor: String?, limit: Int, maxChars: Int,
                         includeTools: Bool = false,
                         knownSecrets: [String], limits: ExternalSessionReadLimits) throws -> MessagePage {
        let descriptor = try openFile(file)
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw ExternalSessionReadError.fileUnreadable }

        var offset: Int64 = 0
        var startIndex = 0
        if let cursor {
            let decoded = try decodeMessageCursor(cursor)
            guard decoded.sessionID.lowercased() == file.id.lowercased(),
                  decoded.dev == Int64(info.st_dev), decoded.ino == info.st_ino,
                  decoded.offset >= 0, Int64(info.st_size) >= decoded.offset,
                  prefixHash(descriptor, offset: decoded.offset) == decoded.prefixHash else {
                throw ExternalSessionReadError.invalidCursor
            }
            offset = decoded.offset
            startIndex = decoded.index
        }

        var raw: [(role: String, text: String)] = []
        var skipped = 0
        let result = try scanLines(descriptor, from: offset, limits: limits) { line in
            guard let data = line.data else { skipped += 1; return true }
            if data.allSatisfy({ $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }) { return true }
            guard let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                skipped += 1
                return true
            }
            if let message = file.map.message(from: row, fileSessionID: file.id) {
                raw.append(message)
            }
            // 游标按整行前进：一行里的所有块都装进这一页（页可能略超 limit），避免页尾丢掉本行后面的块。
            if includeTools {
                raw.append(contentsOf: file.map.toolItems(from: row, fileSessionID: file.id))
            }
            return raw.count < limit
        }

        let items: [MessageItem] = raw.enumerated().map { position, message in
            let capped = message.text.utf8.count > 400_000 ? String(message.text.prefix(100_000)) : message.text
            let redacted = ContentSecretRedactor.redact(capped, knownSecrets: knownSecrets)
            let isTool = message.role == "tool_call" || message.role == "tool_result"
            let cap = isTool ? min(maxChars, Self.toolItemMaxCharacters) : maxChars
            let truncated = redacted.count > cap || capped.count != message.text.count
            return MessageItem(index: startIndex + position, role: message.role,
                               text: String(redacted.prefix(cap)), truncated: truncated)
        }

        var current = stat()
        let size = fstat(descriptor, &current) == 0 ? Int64(current.st_size) : result.nextOffset
        guard let hash = prefixHash(descriptor, offset: result.nextOffset) else {
            throw ExternalSessionReadError.fileUnreadable
        }
        let next = MessageCursor(dev: Int64(info.st_dev), ino: info.st_ino, offset: result.nextOffset,
                                 prefixHash: hash, index: startIndex + items.count, sessionID: file.id.lowercased())
        let note = (file.source == "codex" && items.isEmpty && startIndex == 0 && result.reachedEOF)
            ? "no_event_msg_rows" : nil
        return MessagePage(messages: items,
                           hasMore: !result.reachedEOF && result.nextOffset < size,
                           nextCursor: try encodeMessageCursor(next),
                           skippedLines: skipped, formatNote: note)
    }

    // MARK: Message cursor

    struct MessageCursor: Codable, Equatable {
        var dev: Int64
        var ino: UInt64
        var offset: Int64
        var prefixHash: String
        var index: Int
        var sessionID: String
        enum CodingKeys: String, CodingKey {
            case dev, ino, offset, prefixHash, index
            case sessionID = "session_id"
        }
    }

    static func encodeMessageCursor(_ cursor: MessageCursor) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(cursor)
        let base64 = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "xs1." + base64
    }

    static func decodeMessageCursor(_ text: String) throws -> MessageCursor {
        guard text.hasPrefix("xs1.") else { throw ExternalSessionReadError.invalidCursor }
        var base64 = String(text.dropFirst(4))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let cursor = try? JSONDecoder().decode(MessageCursor.self, from: data) else {
            throw ExternalSessionReadError.invalidCursor
        }
        return cursor
    }

    /// First 8 bytes of SHA-256 over (up to) the 64 bytes before `offset`.
    /// Detects in-place rewrites near the cursor; appends do not change it.
    static func prefixHash(_ descriptor: Int32, offset: Int64) -> String? {
        let start = max(0, offset - 64)
        let length = Int(offset - start)
        var bytes = [UInt8](repeating: 0, count: length)
        var done = 0
        while done < length {
            let count = bytes.withUnsafeMutableBytes { raw in
                pread(descriptor, raw.baseAddress! + done, length - done, off_t(start) + off_t(done))
            }
            if count < 0, errno == EINTR { continue }
            if count <= 0 { return nil }
            done += count
        }
        return SHA256.hash(data: bytes).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Line scanner

    struct ScannedLine {
        let start: Int64
        let end: Int64
        /// nil when the line exceeded `maxLineBytes` (its content was dropped).
        let data: Data?
    }

    struct ScanResult {
        /// Start of the first line not yet consumed.
        let nextOffset: Int64
        let reachedEOF: Bool
    }

    /// Reads 64 KiB blocks and hands complete lines to `visit` (return false to
    /// stop). Lines over `maxLineBytes` are reported with `data == nil`. A final
    /// line without a newline is consumed only if it is complete JSON, because a
    /// live writer may still be appending it. Stops after `maxScanBytes`.
    static func scanLines(_ descriptor: Int32, from start: Int64, limits: ExternalSessionReadLimits,
                          visit: (ScannedLine) -> Bool) throws -> ScanResult {
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        var position = start           // file offset of buffer[0]
        var lineStart = start
        var partial = Data()
        var oversize = false
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in
                pread(descriptor, raw.baseAddress!, raw.count, off_t(position))
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw ExternalSessionReadError.fileUnreadable
            }
            if count == 0 {
                if !oversize, !partial.isEmpty,
                   (try? JSONSerialization.jsonObject(with: partial)) != nil {
                    _ = visit(ScannedLine(start: lineStart, end: position, data: partial))
                    return ScanResult(nextOffset: position, reachedEOF: true)
                }
                return ScanResult(nextOffset: lineStart, reachedEOF: true)
            }
            var cursor = 0
            while cursor < count {
                if let newline = buffer[cursor..<count].firstIndex(of: 0x0A) {
                    append(buffer[cursor..<newline], to: &partial, oversize: &oversize, limit: limits.maxLineBytes)
                    let end = position + Int64(newline) + 1
                    let line = ScannedLine(start: lineStart, end: end, data: oversize ? nil : partial)
                    let keepGoing = visit(line)
                    partial = Data()
                    oversize = false
                    lineStart = end
                    cursor = newline + 1
                    if !keepGoing || end - start >= Int64(limits.maxScanBytes) {
                        return ScanResult(nextOffset: end, reachedEOF: false)
                    }
                } else {
                    append(buffer[cursor..<count], to: &partial, oversize: &oversize, limit: limits.maxLineBytes)
                    cursor = count
                }
            }
            position += Int64(count)
        }
    }

    private static func append(_ bytes: ArraySlice<UInt8>, to partial: inout Data,
                               oversize: inout Bool, limit: Int) {
        if oversize { return }
        if partial.count + bytes.count > limit {
            oversize = true
            partial = Data()
        } else {
            partial.append(contentsOf: bytes)
        }
    }
}
