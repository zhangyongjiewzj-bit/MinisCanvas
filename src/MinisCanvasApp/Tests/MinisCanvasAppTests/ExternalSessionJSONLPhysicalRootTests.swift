import Foundation
import Darwin
import Testing
@testable import MinisCore

@Suite("External JSONL physical root containment across APFS aliases")
struct ExternalSessionJSONLPhysicalRootTests {
    private let thread = "12345678-1234-1234-1234-123456789abc"

    private func fixture() throws -> (base: URL, root: URL, file: URL) {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let base = formal.rootDirectory.appendingPathComponent("EXTD-root-"+UUID().uuidString, isDirectory: true)
        let root = base.appendingPathComponent("sessions", isDirectory: true)
        let day = root.appendingPathComponent("2026/10/01", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let file = day.appendingPathComponent("rollout-2026-10-01T00-00-00-\(thread).jsonl")
        try Data("""
        {"type":"session_meta","payload":{"id":"\(thread)","cwd":"/owned/project","cli_version":"0.151.0"}}
        {"type":"event_msg","payload":{"type":"user_message","message":"owned-root-content"}}
        """.utf8).write(to: file)
        return (base, root, file)
    }

    private func info(_ url: URL) throws -> stat {
        var value = stat()
        try #require(url.path.withCString { Darwin.lstat($0, &value) } == 0)
        return value
    }

    private func apfsSpellings(of root: URL) throws -> (canonical: URL, alias: URL) {
        let dataVolume = "/System/Volumes/Data"
        let raw = root.path
        let aliasPath = raw.hasPrefix(dataVolume + "/") ? String(raw.dropFirst(dataVolume.count)) : raw
        let canonical = URL(fileURLWithPath: dataVolume + aliasPath, isDirectory: true)
        let alias = URL(fileURLWithPath: aliasPath, isDirectory: true)
        try #require(canonical.path != alias.path)
        let expected = try info(root)
        for spelling in [canonical, alias] {
            let actual = try info(spelling)
            try #require((actual.st_mode & S_IFMT) == S_IFDIR)
            try #require(actual.st_dev == expected.st_dev)
            try #require(actual.st_ino == expected.st_ino)
        }
        return (canonical, alias)
    }

    private func open(_ file: URL, pinned: stat) throws -> FileHandle {
        try ExternalSessionPinnedJSONLFile.open(file, rootDevice: UInt64(pinned.st_dev),
            rootInode: UInt64(pinned.st_ino)).0
    }

    @Test("Canonical selected root and Foundation APFS alias read the same authorized session")
    func canonicalAndAliasReadersReturnSameListReadStatus() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let (canonical, alias) = try apfsSpellings(of: f.root)
        let canonicalStat = try info(canonical), aliasStat = try info(alias)
        #expect(canonicalStat.st_dev == aliasStat.st_dev)
        #expect(canonicalStat.st_ino == aliasStat.st_ino)
        let ledger = ExternalSessionAuthorizationLedgerV1()
        let source = ExternalSessionSourceID(rawValue: "owned-canonical")
        let profile = ExternalSessionProfileID(rawValue: "owned-canonical-profile")
        let grant = try await ledger.issueReadGrant(authorizationID: .init(rawValue: "canonical-read"),
            sourceID: source, profileID: profile, target: .source(source),
            scopes: [.metadata, .messages, .status], issuedAt: Date().addingTimeInterval(-1), lifetime: 120)
        var observed: [[String]] = []
        for selected in [canonical, alias] {
            let adapter = ExternalSessionCodexRolloutReadAdapter(sourceID: source, profileID: profile,
                hostID: "owned-host", rootURL: selected, authorizationLedger: ledger)
            let list = try await adapter.listThreads(query: .init(sourceID: source, limit: 10), readGrant: grant)
            #expect(list.threads.map(\.threadID.rawValue) == [thread])
            let page = try await adapter.read(request: .init(sourceID: source,
                threadID: .init(rawValue: thread), limit: 10), readGrant: grant)
            #expect(page.events.map(\.payload.summary) == ["owned-root-content"])
            let status = try await adapter.status(target: .init(sourceID: source,
                threadID: .init(rawValue: thread)), readGrant: grant)
            #expect(status.threadID?.rawValue == thread)
            observed.append(page.messageChunks.map(\.text))
        }
        #expect(observed[0] == observed[1])
    }

    @Test("Candidate outside pinned root is refused even with matching prefix and hardlinked file")
    func siblingWithSamePrefixAndSameFileInodeCannotCrossRoot() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let pinned = try info(f.root)
        let outside = f.base.appendingPathComponent("sessions-other", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let linked = outside.appendingPathComponent(f.file.lastPathComponent)
        #expect(f.file.path.hasPrefix(f.root.path))
        try #require(f.file.path.withCString { from in linked.path.withCString { to in Darwin.link(from, to) } } == 0)
        #expect(try info(linked).st_ino == info(f.file).st_ino)
        #expect(throws: ExternalSessionJSONLReadError.unsafeRoot) { try open(linked, pinned: pinned) }
        let allowed = try open(f.file, pinned: pinned)
        try allowed.close()
    }

    @Test("Replacing selected root after identity pin cannot reuse its authority")
    func swappedRootAfterPinFailsBeforeFileRead() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let pinned = try info(f.root)
        let moved = f.base.appendingPathComponent("moved-root", isDirectory: true)
        try FileManager.default.moveItem(at: f.root, to: moved)
        let replacementDay = f.root.appendingPathComponent("2026/10/01", isDirectory: true)
        try FileManager.default.createDirectory(at: replacementDay, withIntermediateDirectories: true)
        try Data("foreign-root".utf8).write(to: f.file)
        #expect(try info(f.root).st_ino != pinned.st_ino)
        #expect(throws: ExternalSessionJSONLReadError.unsafeRoot) { try open(f.file, pinned: pinned) }
    }

    @Test("Intermediate and final symlink swaps after selection stay no-follow")
    func swappedIntermediateAndFinalSymlinksNeverReturnOutsideBytes() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let pinned = try info(f.root)
        let day = f.file.deletingLastPathComponent()
        let outside = f.base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("forbidden-outside".utf8).write(to: outside.appendingPathComponent(f.file.lastPathComponent))
        let moved = f.base.appendingPathComponent("saved-day", isDirectory: true)
        try FileManager.default.moveItem(at: day, to: moved)
        try FileManager.default.createSymbolicLink(at: day, withDestinationURL: outside)
        #expect(throws: ExternalSessionJSONLReadError.unsafeRoot) { try open(f.file, pinned: pinned) }
        try FileManager.default.removeItem(at: day)
        try FileManager.default.moveItem(at: moved, to: day)
        try FileManager.default.removeItem(at: f.file)
        try FileManager.default.createSymbolicLink(at: f.file, withDestinationURL: outside.appendingPathComponent(f.file.lastPathComponent))
        #expect(throws: ExternalSessionJSONLReadError.unsafeRoot) { try open(f.file, pinned: pinned) }
    }

    @Test(arguments: ["canonical", "alias"])
    func rawDotDotCandidateIsRejectedBeforeDescriptorTraversal(spelling: String) throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let pinned = try info(f.root)
        let aliases = try apfsSpellings(of: f.root)
        let selectedRoot = spelling == "canonical" ? aliases.canonical : aliases.alias
        let selectedInfo = try info(selectedRoot)
        #expect(selectedInfo.st_dev == pinned.st_dev)
        #expect(selectedInfo.st_ino == pinned.st_ino)
        let ordinaryCandidate = selectedRoot.appendingPathComponent("2026/10/01")
            .appendingPathComponent(f.file.lastPathComponent)
        // Positive control uses the exact same pinned physical root and file.
        // A legitimate APFS spelling is not treated as a traversal segment.
        let ordinaryHandle = try open(ordinaryCandidate, pinned: pinned)
        defer { try? ordinaryHandle.close() }
        #expect(try ordinaryHandle.readToEnd() == Data(contentsOf: f.file))

        // Construct a literal file URL rather than appending a ".." path
        // component: a Foundation convenience constructor may normalize it.
        try #require(selectedRoot.absoluteString.hasSuffix("/"))
        let rawInput = selectedRoot.absoluteString + "../sessions/2026/10/01/" + f.file.lastPathComponent
        let rawCandidate = try #require(URL(string: rawInput))
        try #require(rawCandidate.isFileURL)
        try #require(rawCandidate.absoluteString.contains("/../"))
        try #require(rawCandidate.path.contains("/../"))
        try #require(rawCandidate.path.split(separator: "/").contains(".."))
        let normalizedRawInfo = try info(rawCandidate.standardizedFileURL)
        let normalizedOrdinaryInfo = try info(ordinaryCandidate.standardizedFileURL)
        #expect(normalizedRawInfo.st_dev == normalizedOrdinaryInfo.st_dev)
        #expect(normalizedRawInfo.st_ino == normalizedOrdinaryInfo.st_ino)
        print("EXTD_RAW_DOTDOT spelling=\(spelling) raw_input=\(rawInput) raw_path=\(rawCandidate.path) root_dev=\(pinned.st_dev) root_ino=\(pinned.st_ino) expected_error=unsafeRoot")

        // This is the actual production JSONL fd boundary used by the reader,
        // not a fabricated public-API rejection: Reader.init standardizes its
        // selected root and its public read API only accepts a thread ID.
        #expect(throws: ExternalSessionJSONLReadError.unsafeRoot) {
            let unexpectedHandle = try open(rawCandidate, pinned: pinned)
            try unexpectedHandle.close()
        }
    }

    @Test("A symlink alias of the selected root remains rejected")
    func selectedRootSymlinkIsNotAnAPFSIdentityAlias() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let alias = f.base.appendingPathComponent("user-symlink", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.root)
        let candidate = alias.appendingPathComponent("2026/10/01").appendingPathComponent(f.file.lastPathComponent)
        #expect(throws: ExternalSessionJSONLReadError.unsafeRoot) { try open(candidate, pinned: info(f.root)) }
        let reader = ExternalSessionCodexRolloutReadAdapter(sourceID: .init(rawValue: "symlink-source"),
            profileID: .init(rawValue: "symlink-profile"), hostID: "owned-host",
            rootURL: alias, authorizationLedger: ExternalSessionAuthorizationLedgerV1())
        #expect(reader.source.authState == .unavailable)
    }
}
