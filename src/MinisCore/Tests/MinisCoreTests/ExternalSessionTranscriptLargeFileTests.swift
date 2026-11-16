import Foundation
import Testing
@testable import MinisCore

/// Scale behaviour of the streaming reader. All files are generated at run time
/// under a temporary directory; no large fixture is checked in.
struct ExternalSessionTranscriptLargeFileTests {

    /// Writes a rollout of roughly `noiseMegabytes` MiB by streaming lines to disk:
    /// a 23 KB header line, then `pairs` user/agent message pairs each followed by
    /// one large non-message line.
    private func writeLargeRollout(_ home: ExtFixture.Home, id: String, pairs: Int,
                                   noiseBytes: Int) throws -> URL {
        let directory = home.codexRoot.appendingPathComponent("2026/11/01", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("rollout-2026-11-01T10-00-00-\(id).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        func put(_ line: String) throws { try handle.write(contentsOf: Data((line + "\n").utf8)) }
        try put(try ExtFixture.codexMeta(id: id, cwd: "/work/large", padding: 23_000))
        let noise = try ExtFixture.codexNoise(bytes: noiseBytes)
        for index in 0..<pairs {
            try put(try ExtFixture.codexUser("question \(index)"))
            try put(try ExtFixture.codexAgent("answer \(index)"))
            try put(noise)
        }
        return url
    }

    @Test func codexRolloutOver8MiBListsAndFirstPageReads() async throws {
        let home = try ExtFixture.Home()
        defer { home.remove() }
        let id = UUID().uuidString.lowercased()
        // 20 pairs x ~1 MB noise line: about 20 MiB.
        let url = try writeLargeRollout(home, id: id, pairs: 20, noiseBytes: 1_000_000)
        let size = try #require(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        #expect(size > 8 * 1_048_576)

        // Listing opens only the head: the 23 KB header line does not hide it.
        let list = try await ExtFixture.call([:], roots: [home.codexRoot])
        #expect(ExtFixture.sessionIDs(list) == [id])
        #expect(ExtFixture.titles(list) == ["question 0"])
        let cwd = (list["sessions"] as? [[String: Any]])?.first.flatMap { ($0["cwd"] as? [String: Any])?["text"] as? String }
        #expect(cwd == "/work/large")

        // First page, then the continuation.
        let first = try await ExtFixture.call(["session": id, "limit": 5], roots: [home.codexRoot])
        #expect(ExtFixture.messageTexts(first) == ["question 0", "answer 0", "question 1", "answer 1", "question 2"])
        #expect(first["has_more"] as? Bool == true)
        let cursor = try #require(first["next_cursor"] as? String)
        #expect(!cursor.isEmpty)
        let second = try await ExtFixture.call(["session": id, "cursor": cursor, "limit": 50], roots: [home.codexRoot])
        #expect(ExtFixture.messageIndexes(second).first == 5)
        #expect(ExtFixture.messageTexts(second).first == "answer 2")
        #expect(ExtFixture.messageTexts(second).count == 35)
        #expect(second["has_more"] as? Bool == false)
        #expect(second["skipped_lines"] as? Int == 0)
    }

    @Test func scanBudgetExhaustionYieldsAContinuationCursorInsteadOfAnError() async throws {
        let home = try ExtFixture.Home()
        defer { home.remove() }
        let id = UUID().uuidString.lowercased()
        // Messages only at the head and far down the file.
        let directory = home.codexRoot.appendingPathComponent("2026/11/01", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var lines = [try ExtFixture.codexMeta(id: id), try ExtFixture.codexUser("head message")]
        let noise = try ExtFixture.codexNoise(bytes: 100_000)
        for _ in 0..<40 { lines.append(noise) }
        lines.append(try ExtFixture.codexAgent("tail message"))
        try ExtFixture.writeCodex(home, id: id, lines: lines)

        var limits = ExternalSessionReadLimits()
        limits.maxScanBytes = 1_000_000          // roughly 10 noise lines per call
        var cursor: String?
        var texts: [String] = []
        var calls = 0
        var sawEmptyContinuation = false
        while calls < 20 {
            var input: [String: Any] = ["session": id]
            if let cursor { input["cursor"] = cursor }
            let page = try await ExtFixture.call(input, roots: [home.codexRoot], limits: limits)
            calls += 1
            let pageTexts = ExtFixture.messageTexts(page)
            if pageTexts.isEmpty && page["has_more"] as? Bool == true { sawEmptyContinuation = true }
            texts += pageTexts
            cursor = page["next_cursor"] as? String
            if page["has_more"] as? Bool != true { break }
        }
        #expect(texts == ["head message", "tail message"])
        #expect(sawEmptyContinuation)
        #expect(calls > 2 && calls < 20)
    }

    @Test func claudeProjectsWith3000FilesListsNewest50AndSurvivesInsertBetweenPages() async throws {
        let home = try ExtFixture.Home()
        defer { home.remove() }
        let base = 1_700_000_000.0
        var ids: [String] = []
        for index in 0..<3000 {
            let id = UUID().uuidString.lowercased()
            ids.append(id)
            try ExtFixture.writeClaude(home, project: "-proj-\(index % 30)", id: id,
                                       lines: [try ExtFixture.claudeUser(session: id, "message \(index)")],
                                       mtime: Date(timeIntervalSince1970: base + Double(index)))
        }
        let roots = [home.claudeRoot]

        // Newest 50 first (a larger limit is capped at 50).
        let first = try await ExtFixture.call(["limit": 500], roots: roots)
        let expectedFirst = (0..<50).map { ids[2999 - $0] }
        #expect(ExtFixture.sessionIDs(first) == expectedFirst)
        #expect(first["has_more"] as? Bool == true)
        #expect(ExtFixture.titles(first).first == "message 2999")
        let cursor = try #require(first["next_cursor"] as? String)

        // Newer sessions appear between page one and page two.
        var inserted: [String] = []
        for offset in 0..<3 {
            let id = UUID().uuidString.lowercased()
            inserted.append(id)
            try ExtFixture.writeClaude(home, project: "-proj-new", id: id,
                                       lines: [try ExtFixture.claudeUser(session: id, "late \(offset)")],
                                       mtime: Date(timeIntervalSince1970: base + 100_000 + Double(offset)))
        }
        let second = try await ExtFixture.call(["limit": 50, "cursor": cursor], roots: roots)
        #expect(ExtFixture.sessionIDs(second) == (50..<100).map { ids[2999 - $0] })

        // Walk to the end: every original session exactly once, no inserted one.
        var seen = ExtFixture.sessionIDs(first) + ExtFixture.sessionIDs(second)
        var next = second["next_cursor"] as? String
        var pages = 2
        while let current = next, pages < 100 {
            let page = try await ExtFixture.call(["limit": 50, "cursor": current], roots: roots)
            seen += ExtFixture.sessionIDs(page)
            next = page["has_more"] as? Bool == true ? page["next_cursor"] as? String : nil
            pages += 1
        }
        #expect(seen.count == 3000)
        #expect(Set(seen) == Set(ids))
        #expect(Set(seen).isDisjoint(with: inserted))
        #expect(pages == 60)

        // Default page size for listings is 20.
        let defaults = try await ExtFixture.call([:], roots: roots)
        #expect(ExtFixture.sessionIDs(defaults).count == 20)
        #expect(ExtFixture.sessionIDs(defaults).prefix(3) == inserted.reversed().prefix(3))
    }

    @Test func enumerationCapTruncatesWithANoteInsteadOfThrowing() async throws {
        let home = try ExtFixture.Home()
        defer { home.remove() }
        for index in 0..<150 {
            let id = UUID().uuidString.lowercased()
            try ExtFixture.writeClaude(home, id: id, lines: [try ExtFixture.claudeUser(session: id, "m\(index)")])
        }
        var limits = ExternalSessionReadLimits()
        limits.maxEnumeratedEntries = 100
        let result = try await ExtFixture.call(["limit": 50], roots: [home.claudeRoot], limits: limits)
        let note = try #require(result["scanned_note"] as? String)
        #expect(note.contains("truncated"))
        #expect(ExtFixture.sessionIDs(result).count == 50)

        let full = try await ExtFixture.call(["limit": 50], roots: [home.claudeRoot])
        #expect(full["scanned_note"] is NSNull)
    }

    @Test func headReadHandlesFirstLineLongerThanTheHeadWindow() async throws {
        let home = try ExtFixture.Home()
        defer { home.remove() }
        let id = UUID().uuidString.lowercased()
        // A header line larger than the window cannot yield a title or cwd, but the
        // session is still listed and readable.
        try ExtFixture.writeCodex(home, id: id, lines: [
            try ExtFixture.codexMeta(id: id, padding: 90_000),
            try ExtFixture.codexUser("after the giant header")])
        let list = try await ExtFixture.call([:], roots: [home.codexRoot])
        #expect(ExtFixture.sessionIDs(list) == [id])
        #expect(ExtFixture.titles(list) == [""])
        let read = try await ExtFixture.call(["session": id], roots: [home.codexRoot])
        #expect(ExtFixture.messageTexts(read) == ["after the giant header"])
    }
}
