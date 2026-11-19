import Foundation
import Testing
@testable import MinisCore

struct ExternalSessionFormatMapTests {
    private func row(_ json: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    // MARK: File names

    @Test func codexFileNamesMapToTheTrailingUUID() {
        let id = "019a3c2e-1111-7222-8333-444455556666"
        let map = ExternalSessionFormatMap.codex
        #expect(map.fileNamePattern("rollout-2026-11-01T10-00-00-\(id).jsonl") == id)
        #expect(map.fileNamePattern("rollout-2026-11-01T10-00-00-\(id).json") == nil)
        #expect(map.fileNamePattern("2026-11-01T10-00-00-\(id).jsonl") == nil)
        #expect(map.fileNamePattern("rollout-2026-11-01T10-00-00-not-a-uuid.jsonl") == nil)
    }

    @Test func claudeFileNamesMustBeBareUUIDs() {
        let id = UUID().uuidString.lowercased()
        let map = ExternalSessionFormatMap.claudeCode
        #expect(map.fileNamePattern("\(id).jsonl") == id)
        #expect(map.fileNamePattern("agent-\(id).jsonl") == nil)
        #expect(map.fileNamePattern("\(id).txt") == nil)
    }

    // MARK: Row projection

    @Test func codexRulesProjectEveryDeclaredMessageVariant() throws {
        let map = ExternalSessionFormatMap.codex
        let id = "x"
        func project(_ json: String) throws -> (role: String, text: String)? {
            map.message(from: try row(json), fileSessionID: id)
        }
        let user = try project(#"{"type":"event_msg","payload":{"type":"user_message","message":"u"}}"#)
        #expect(user?.role == "user" && user?.text == "u")
        let agent = try project(#"{"type":"event_msg","payload":{"type":"agent_message","message":"a"}}"#)
        #expect(agent?.role == "assistant" && agent?.text == "a")
        let blocks = try project(#"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","content":[{"type":"input_text","text":"p1"},{"type":"input_text","text":"p2"},{"type":"image","text":"IMG"}]}}}"#)
        #expect(blocks?.role == "user" && blocks?.text == "p1\np2")
        let fallback = try project(#"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","text":"t"}}}"#)
        #expect(fallback?.role == "assistant" && fallback?.text == "t")
        // Not conversation: tool item, response_item stream, blank text.
        #expect(try project(#"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","text":"ls"}}}"#) == nil)
        #expect(try project(#"{"type":"response_item","payload":{"type":"message","role":"user","content":"x"}}"#) == nil)
        #expect(try project(#"{"type":"event_msg","payload":{"type":"user_message","message":"  \n "}}"#) == nil)
    }

    @Test func claudeRulesUseMessageRoleAndRequireMatchingSessionID() throws {
        let map = ExternalSessionFormatMap.claudeCode
        let id = "11111111-2222-3333-4444-555555555555"
        let ok = map.message(from: try row(#"{"type":"user","sessionId":"\#(id)","message":{"role":"user","content":"q"}}"#), fileSessionID: id)
        #expect(ok?.role == "user" && ok?.text == "q")
        let other = map.message(from: try row(#"{"type":"user","sessionId":"zzz","message":{"role":"user","content":"q"}}"#), fileSessionID: id)
        #expect(other == nil)
        let oddRole = map.message(from: try row(#"{"type":"assistant","sessionId":"\#(id)","message":{"role":"system","content":"q"}}"#), fileSessionID: id)
        #expect(oddRole == nil)
        let mixed = map.message(from: try row(#"{"type":"assistant","sessionId":"\#(id)","message":{"role":"assistant","content":[{"type":"thinking","thinking":"T"},{"type":"text","text":"keep"},{"type":"tool_use","name":"x"}]}}"#), fileSessionID: id)
        #expect(mixed?.text == "keep")
    }

    // MARK: Root qualification (shared with the Settings mount notice)

    @Test func rootQualificationRequiresExactSuffixRealDirectoryAndRealpathSuffix() throws {
        let home = try ExtFixture.Home()
        defer { home.remove() }
        #expect(ExternalSessionMountQualification.qualifyingSource(forMountedPath: home.codexRoot.path) == "codex")
        #expect(ExternalSessionMountQualification.qualifyingSource(forMountedPath: home.claudeRoot.path) == "claude_code")
        #expect(ExternalSessionMountQualification.isQualifyingMount(home.codexRoot.path))
        for path in [home.url.path, home.url.appendingPathComponent(".codex").path,
                     home.url.appendingPathComponent(".claude").path,
                     "/nonexistent-\(UUID().uuidString)/.codex/sessions"] {
            #expect(!ExternalSessionMountQualification.isQualifyingMount(path), "\(path) must not qualify")
        }

        // A symlink with the right name, and a directory reached through a symlink
        // to a differently named target, both fail; an ordinary parent symlink
        // (e.g. /var -> /private/var) does not.
        let target = home.url.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let aliasHome = home.url.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: aliasHome.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: aliasHome.appendingPathComponent(".codex/sessions"), withDestinationURL: target)
        #expect(!ExternalSessionMountQualification.isQualifyingMount(aliasHome.appendingPathComponent(".codex/sessions").path))

        let viaParentLink = home.url.appendingPathComponent("linkedhome")
        try FileManager.default.createSymbolicLink(at: viaParentLink, withDestinationURL: home.url)
        #expect(ExternalSessionMountQualification.isQualifyingMount(viaParentLink.appendingPathComponent(".codex/sessions").path))
        let qualified = ExternalSessionFormatMap.qualifiedRoots(from: [viaParentLink.appendingPathComponent(".codex/sessions"), home.codexRoot])
        #expect(qualified.count == 1, "the same real folder mounted twice is one root")
    }

    // MARK: locate (used by the send tool)

    @Test func locateByExactIDReturnsMTimeCwdAndRedactedTitle() throws {
        let home = try ExtFixture.Home()
        defer { home.remove() }
        let id = UUID().uuidString.lowercased()
        let mtime = Date(timeIntervalSince1970: 1_700_000_123)
        try ExtFixture.writeCodex(home, id: id, lines: [
            try ExtFixture.codexMeta(id: id, cwd: "/work/located"),
            try ExtFixture.codexUser("  Fix the\n   login   bug sk-ABCDEFGH1234567890XYZ and more words beyond forty chars  ")
        ], mtime: mtime)

        let located = try ExternalSessionTranscriptReader.locate(session: id, source: "codex", roots: [home.codexRoot])
        #expect(located.id == id)
        #expect(located.source == "codex")
        #expect(abs(located.fileMTime.timeIntervalSince(mtime)) < 0.001)
        #expect(located.cwd == "/work/located")
        let title = try #require(located.title)
        #expect(title.hasPrefix("Fix the login bug "))
        #expect(!title.contains("sk-"))
        #expect(title.count <= 40)

        // UUID case does not matter.
        let upper = try ExternalSessionTranscriptReader.locate(session: id.uppercased(), source: "codex", roots: [home.codexRoot])
        #expect(upper.id == id)
    }

    @Test func locateResolvesNamesToOneSessionAndRefusesAmbiguityOrWrongSource() throws {
        let home = try ExtFixture.Home()
        defer { home.remove() }
        let one = UUID().uuidString.lowercased()
        let two = UUID().uuidString.lowercased()
        let three = UUID().uuidString.lowercased()
        try ExtFixture.writeCodex(home, id: one, lines: [try ExtFixture.codexMeta(id: one), try ExtFixture.codexUser("refactor parser")])
        try ExtFixture.writeCodex(home, id: two, lines: [try ExtFixture.codexMeta(id: two), try ExtFixture.codexUser("refactor lexer")])
        try ExtFixture.writeClaude(home, id: three, lines: [try ExtFixture.claudeUser(session: three, "write docs")])
        let roots = [home.codexRoot, home.claudeRoot]

        #expect(try ExternalSessionTranscriptReader.locate(session: "PARSER", source: "codex", roots: roots).id == one)
        #expect(try ExternalSessionTranscriptReader.locate(session: "docs", source: "claude_code", roots: roots).id == three)

        let ambiguous = #expect(throws: ExternalSessionReadError.self) {
            _ = try ExternalSessionTranscriptReader.locate(session: "refactor", source: "codex", roots: roots)
        }
        if case .ambiguousName(let candidates)? = ambiguous {
            #expect(Set(candidates.map(\.sessionID)) == [one, two])
        } else {
            Issue.record("expected ambiguous_name")
        }
        #expect(throws: ExternalSessionReadError.sessionNotFound) {
            _ = try ExternalSessionTranscriptReader.locate(session: "docs", source: "codex", roots: roots)
        }
        #expect(throws: ExternalSessionReadError.sessionNotFound) {
            _ = try ExternalSessionTranscriptReader.locate(session: UUID().uuidString, source: "codex", roots: roots)
        }
        #expect(throws: ExternalSessionReadError.sourceNotAuthorized) {
            _ = try ExternalSessionTranscriptReader.locate(session: one, source: "claude_code", roots: [home.codexRoot])
        }
        #expect(throws: ExternalSessionReadError.noAuthorizedRoot) {
            _ = try ExternalSessionTranscriptReader.locate(session: one, source: "codex", roots: [])
        }
        #expect(throws: ExternalSessionReadError.invalidParameter("source")) {
            _ = try ExternalSessionTranscriptReader.locate(session: one, source: "hermes", roots: roots)
        }
    }

    @Test func toolNameComesFromTheSharedConstants() {
        #expect(ExternalSessionReadTool.toolName == "external_session_read")
        #expect(ExternalSessionReadTool.definition().name == ExternalSessionToolNames.read)
        let properties = Set(ExternalSessionReadTool.definition().parameters.keys)
        #expect(properties == ["source", "session", "name", "cursor", "limit", "max_chars", "include_tools"])
        #expect(ExternalSessionReadTool.definition().required.isEmpty)
    }
}
