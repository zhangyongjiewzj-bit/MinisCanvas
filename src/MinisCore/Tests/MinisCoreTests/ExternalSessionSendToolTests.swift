import Foundation
import Testing
@testable import MinisCore

// The synthetic peer below is the *other side* of the process boundary (it
// stands in for codex / claude). It records what it received; the code under
// test (tool + CLIProcessRunner + environment sanitising) runs for real.

fileprivate final class PeerCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    private var _binary: String?
    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
    var binary: String? { lock.lock(); defer { lock.unlock() }; return _binary }
    func record(_ binary: String) { lock.lock(); _count += 1; _binary = binary; lock.unlock() }
}

fileprivate struct SyntheticPeer {
    let dir: URL
    let script: URL

    init(body: String = "") throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("send-peer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        script = dir.appendingPathComponent("peer.sh")
        let text = """
        #!/bin/bash
        D='\(dir.path)'
        for a in "$@"; do printf '%s\\0' "$a"; done > "$D/argv"
        pwd -P > "$D/cwd"
        env > "$D/env_all"
        cat > "$D/stdin"
        \(body)
        """
        try text.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    func remove() { try? FileManager.default.removeItem(at: dir) }
    func data(_ name: String) -> Data? { try? Data(contentsOf: dir.appendingPathComponent(name)) }
    func text(_ name: String) -> String? { data(name).map { String(decoding: $0, as: UTF8.self) } }
    var argv: [String] {
        (data("argv") ?? Data()).split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
    }

    func runner(_ calls: PeerCalls) -> ExternalSessionSendTool.Runner {
        let path = script.path
        return { binary, arguments, cwd, timeout, stdin in
            calls.record(binary)
            // Substitute the synthetic peer for the resolved binary; every other
            // argument is passed through exactly as the tool produced it.
            return try await CLIProcessRunner.run(
                binary: path, arguments: arguments, workingDirectory: cwd,
                timeoutSeconds: timeout, standardInput: stdin)
        }
    }
}

fileprivate let resolvedBinary: ExternalSessionSendTool.BinaryResolver = { template in
    "/resolved/\(template.source)"
}

fileprivate let fixedID = "0197c2a4-1b2c-7d3e-8f40-5a6b7c8d9e0f"

fileprivate func target(
    source: String = "codex",
    id: String = fixedID,
    mtimeAge: TimeInterval = 3600,
    now: Date,
    cwd: String? = nil,
    title: String? = "fix the build"
) -> ExternalSessionSendTarget {
    ExternalSessionSendTarget(
        sessionID: id, source: source, fileMTime: now.addingTimeInterval(-mtimeAge),
        cwd: cwd, title: title)
}

fileprivate func decode(_ json: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
}

fileprivate func waitFor(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return condition()
}

fileprivate func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

fileprivate func realPath(_ path: String) -> String {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    return realpath(path, &buffer).map { String(cString: $0) } ?? path
}

/// True when the operation throws (any error); used instead of capturing
/// non-Sendable inputs in an `#expect(throws:)` closure.
fileprivate func throwsError(_ operation: () async throws -> String) async -> Bool {
    do { _ = try await operation(); return false } catch { return true }
}

@Suite("external_session_send", .serialized)
struct ExternalSessionSendToolTests {
    private let now = Date()

    private func input(
        source: String = "codex", session: String = fixedID, message: String = "hello",
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var result: [String: Any] = ["source": source, "session": session, "message": message]
        for (key, value) in extra { result[key] = value }
        return result
    }

    @Test
    func messageGoesThroughStdinVerbatim_NotArgvNotShell() async throws {
        let peer = try SyntheticPeer()
        defer { peer.remove() }
        let marker = peer.dir.appendingPathComponent("shell-ran")
        let message = "- not an option\n\"double\" 'single' $(touch \(marker.path)) `touch \(marker.path)`\n; rm -rf nothing\n末尾"
        for source in ["codex", "claude_code"] {
            let t = target(source: source, now: now)
            let calls = PeerCalls()
            let result = try decode(try await ExternalSessionSendTool.perform(
                input: input(source: source, message: message), target: t, knownSecrets: [],
                runner: peer.runner(calls), binaryResolver: resolvedBinary))
            #expect(result["ok"] as? Bool == true)
            #expect(peer.data("stdin") == Data(message.utf8))
            let expected = ExternalSessionCommandTemplate.template(for: source)!.argv(t.sessionID)
            #expect(peer.argv == expected)
            #expect(!peer.argv.contains { $0.contains("touch") || $0.contains("not an option") })
            #expect(!FileManager.default.fileExists(atPath: marker.path))
            #expect(calls.binary == "/resolved/\(source)")
        }
    }

    @Test
    func unknownSourceOrBadParametersAreRejectedBeforeAnyProcessStarts() async throws {
        let peer = try SyntheticPeer()
        defer { peer.remove() }
        let calls = PeerCalls()
        let t = target(now: now)
        let bad: [[String: Any]] = [
            input(source: "hermes"),
            input(source: "codex exec; id"),
            input(message: String(repeating: "a", count: 1001)),
            input(message: ""),
            input(session: "fix the build"),          // names are not accepted
            input(session: "0197c2a4-1b2c-7d3e-8f40-ffffffffffff"), // not the located session
            input(extra: ["timeout_seconds": 901]),
            input(extra: ["timeout_seconds": 0])
        ]
        for item in bad {
            let threw = await throwsError {
                try await ExternalSessionSendTool.perform(
                    input: item, target: t, knownSecrets: [],
                    runner: peer.runner(calls), binaryResolver: resolvedBinary)
            }
            #expect(threw, "\(item) must be rejected")
        }
        #expect(calls.count == 0)
        #expect(peer.data("argv") == nil)
        // Exactly 1000 characters is accepted.
        let ok = try decode(try await ExternalSessionSendTool.perform(
            input: input(message: String(repeating: "a", count: 1000)), target: t,
            knownSecrets: [], runner: peer.runner(calls), binaryResolver: resolvedBinary))
        #expect(ok["ok"] as? Bool == true)
    }

    @Test
    func sessionIDThatIsNotABareUUIDNeverReachesArgv() async throws {
        let peer = try SyntheticPeer()
        defer { peer.remove() }
        let calls = PeerCalls()
        for id in ["--yolo", "-x", "abc; id", "../../etc"] {
            let threw = await throwsError {
                try await ExternalSessionSendTool.perform(
                    input: input(), target: target(id: id, now: now), knownSecrets: [],
                    runner: peer.runner(calls), binaryResolver: resolvedBinary)
            }
            #expect(threw, "id \(id) must be rejected")
        }
        #expect(calls.count == 0)
    }

    @Test
    func exitCodeAndRedactedBoundedOutputReturned() async throws {
        let secret = "SENTINEL-KEY-91f3a7c2"
        let peer = try SyntheticPeer(body: """
        head -c 1048576 /dev/zero | tr '\\0' 'x'
        printf '%s' 'tail-before-\(secret)-tail-after-END'
        """)
        defer { peer.remove() }
        let result = try decode(try await ExternalSessionSendTool.perform(
            input: input(), target: target(now: now), knownSecrets: [secret],
            runner: peer.runner(PeerCalls()), binaryResolver: resolvedBinary))
        #expect(result["ok"] as? Bool == true)
        #expect(result["exit_code"] as? Int == 0)
        #expect(result["truncated"] as? Bool == true)
        let output = try #require(result["output"] as? [String: Any])
        #expect(output["content_trust"] as? String == "untrusted_external_data")
        let text = try #require(output["text"] as? String)
        #expect(text.utf8.count <= 16 * 1024)
        #expect(text.hasSuffix("-END"))
        #expect(!text.contains(secret))
        #expect(result["notice"] as? String == ExternalSessionSendTool.notice)
    }

    @Test
    func nonZeroExitIsReportedNotThrown_StderrRedacted() async throws {
        let secret = "SENTINEL-KEY-0b44d1e8"
        let peer = try SyntheticPeer(body: "echo 'boom \(secret)' >&2; exit 3")
        defer { peer.remove() }
        let result = try decode(try await ExternalSessionSendTool.perform(
            input: input(), target: target(now: now), knownSecrets: [secret],
            runner: peer.runner(PeerCalls()), binaryResolver: resolvedBinary))
        #expect(result["ok"] as? Bool == false)
        #expect(result["exit_code"] as? Int == 3)
        let stderr = try #require((result["stderr_tail"] as? [String: Any])?["text"] as? String)
        #expect(stderr.contains("boom"))
        #expect(!stderr.contains(secret))
    }

    @Test
    func timeoutKillsWholeProcessGroupAndReportsTimeout() async throws {
        let peer = try SyntheticPeer(body: """
        sleep 60 &
        echo $! > "$D/child.pid"
        wait
        """)
        defer { peer.remove() }
        let result = try decode(try await ExternalSessionSendTool.perform(
            input: input(extra: ["timeout_seconds": 1]), target: target(now: now),
            knownSecrets: [], runner: peer.runner(PeerCalls()), binaryResolver: resolvedBinary))
        #expect(result["ok"] as? Bool == false)
        #expect(result["error"] as? String == "timeout")
        let pid = try #require(Int32(peer.text("child.pid")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""))
        #expect(await waitFor { !isAlive(pid) }, "grandchild started by this test must be gone")
    }

    @Test
    func cancellationKillsChildProcessGroup() async throws {
        let peer = try SyntheticPeer(body: """
        sleep 60 &
        echo $! > "$D/child.pid"
        wait
        """)
        defer { peer.remove() }
        let runner = peer.runner(PeerCalls())
        let startedAt = now
        let task = Task {
            try await ExternalSessionSendTool.perform(
                input: input(extra: ["timeout_seconds": 120]), target: target(now: startedAt),
                knownSecrets: [], runner: runner, binaryResolver: resolvedBinary)
        }
        let appeared = await waitFor {
            (peer.text("child.pid")?.trimmingCharacters(in: .whitespacesAndNewlines))
                .flatMap { Int32($0) } != nil
        }
        #expect(appeared)
        let pid = try #require(Int32(peer.text("child.pid")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""))
        #expect(isAlive(pid))
        task.cancel()
        let result = try decode(try await task.value)
        #expect(result["ok"] as? Bool == false)
        #expect(result["error"] as? String == "cancelled")
        #expect(await waitFor { !isAlive(pid) }, "grandchild started by this test must be gone")
    }

    @Test
    func childEnvironmentDoesNotInheritProviderKeys() async throws {
        let name = "MINIS_SEND_TEST_API_KEY"
        let value = "env-sentinel-\(UUID().uuidString)"
        setenv(name, value, 1)
        defer { unsetenv(name) }
        let peer = try SyntheticPeer()
        defer { peer.remove() }
        _ = try await ExternalSessionSendTool.perform(
            input: input(), target: target(now: now), knownSecrets: [],
            runner: peer.runner(PeerCalls()), binaryResolver: resolvedBinary)
        let env = try #require(peer.text("env_all"))
        #expect(!env.contains(value))
        #expect(!env.contains(name))
        #expect(env.contains("PATH="))
    }

    @Test
    func missingBinaryIsReportedAndNothingIsSpawned() async throws {
        let calls = PeerCalls()
        let peer = try SyntheticPeer()
        defer { peer.remove() }
        let result = try decode(try await ExternalSessionSendTool.perform(
            input: input(), target: target(now: now), knownSecrets: [],
            runner: peer.runner(calls), binaryResolver: { _ in nil }))
        #expect(result["ok"] as? Bool == false)
        #expect(result["error"] as? String == "binary_not_found")
        #expect(calls.count == 0)
    }

    @Test
    func resultCarriesNoRecentlyWrittenField() async throws {
        let peer = try SyntheticPeer()
        defer { peer.remove() }
        let result = try decode(try await ExternalSessionSendTool.perform(
            input: input(), target: target(mtimeAge: 1, now: now), knownSecrets: [],
            runner: peer.runner(PeerCalls()), binaryResolver: resolvedBinary))
        #expect(result["recently_written"] == nil)
        #expect(result["seconds_since_write"] == nil)
    }

    @Test
    func secretShapedMessageIsRefusedSoCardAndSentStringAreIdentical() async throws {
        let secret = "SENTINEL-KEY-77aa10"
        let peer = try SyntheticPeer()
        defer { peer.remove() }
        let calls = PeerCalls()
        let item = input(message: "use \(secret) now")
        let refused = await throwsError {
            try await ExternalSessionSendTool.perform(
                input: item, target: target(now: now), knownSecrets: [secret],
                runner: peer.runner(calls), binaryResolver: resolvedBinary)
        }
        #expect(refused)
        let cardRefused = await throwsError {
            try ExternalSessionSendTool.approvalSummary(
                input: item, target: target(now: now), knownSecrets: [secret],
                binaryResolver: resolvedBinary)
        }
        #expect(cardRefused)
        #expect(calls.count == 0)
        // Without the secret the same text is accepted and sent verbatim.
        _ = try await ExternalSessionSendTool.perform(
            input: input(message: "use it now"), target: target(now: now), knownSecrets: [secret],
            runner: peer.runner(calls), binaryResolver: resolvedBinary)
        #expect(peer.data("stdin") == Data("use it now".utf8))
    }

    @Test
    func summaryWholeCardMustFitFourKiBElseRefused() throws {
        // 1000 CJK characters are ~3000 bytes: with the fixed lines still < 4096.
        let fits = try ExternalSessionSendTool.approvalSummary(
            input: input(message: String(repeating: "界", count: 1000)),
            target: target(now: now, title: "t"), binaryResolver: resolvedBinary)
        #expect(fits.utf8.count <= 4096)
        #expect(fits.contains(String(repeating: "界", count: 1000)), "message must be shown in full")
        // A long title pushes the same card over the dialog window: refuse, do not truncate.
        let longTitle = String(repeating: "标", count: 600)
        #expect(throws: ToolExecutorError.self) {
            _ = try ExternalSessionSendTool.approvalSummary(
                input: input(message: String(repeating: "界", count: 1000)),
                target: target(now: now, title: longTitle), binaryResolver: resolvedBinary)
        }
    }

    @Test
    func approvalSummaryContainsFullRedactedMessageCommandCwdIrrevocableNotice() throws {
        let cwd = FileManager.default.temporaryDirectory.path
        let secret = "SENTINEL-KEY-c8e2"
        let message = "line one\nplease use \(secret) never\nline three"
        let t = target(mtimeAge: 5, now: now, cwd: cwd, title: "Title with \(secret)")
        let summary = try ExternalSessionSendTool.approvalSummary(
            input: input(message: message.replacingOccurrences(of: secret, with: "plain")),
            target: t, knownSecrets: [secret], binaryResolver: resolvedBinary)
        #expect(summary.contains("line one"))
        #expect(summary.contains("line three"))
        #expect(!summary.contains(secret))
        #expect(summary.contains(t.sessionID))
        #expect(summary.contains("/resolved/codex exec resume --all \(t.sessionID) -"))
        #expect(summary.contains(cwd))
        #expect(summary.contains("正被桌面端使用"), "always-on concurrency notice")
        #expect(!summary.contains("秒前"))
        #expect(summary.contains("不可撤回"))
        #expect(summary.contains("无法限制"))
        #expect(summary.contains("当前模型提供商"))
        #expect(summary.contains("来自外部会话，仅供辨认"))
    }

    @Test
    func peerRunsInTranscriptCwd_MissingDirectoryRefusesToSend_NilLeavesUnset() async throws {
        let real = FileManager.default.temporaryDirectory
            .appendingPathComponent("send-cwd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: real) }

        let peer = try SyntheticPeer()
        defer { peer.remove() }
        _ = try await ExternalSessionSendTool.perform(
            input: input(), target: target(now: now, cwd: real.path), knownSecrets: [],
            runner: peer.runner(PeerCalls()), binaryResolver: resolvedBinary)
        #expect(peer.text("cwd")?.trimmingCharacters(in: .whitespacesAndNewlines) == realPath(real.path))

        // Recorded directory no longer exists: error, nothing started.
        let calls = PeerCalls()
        let missing = "/no/such/dir-\(UUID().uuidString)"
        let refused = await throwsError {
            try await ExternalSessionSendTool.perform(
                input: input(), target: target(now: now, cwd: missing), knownSecrets: [],
                runner: peer.runner(calls), binaryResolver: resolvedBinary)
        }
        #expect(refused)
        let cardRefused = await throwsError {
            try ExternalSessionSendTool.approvalSummary(
                input: input(), target: target(now: now, cwd: missing),
                binaryResolver: resolvedBinary)
        }
        #expect(cardRefused)
        #expect(calls.count == 0)

        // Nothing recorded: no cwd is set, the child inherits the caller's.
        let other = try SyntheticPeer()
        defer { other.remove() }
        _ = try await ExternalSessionSendTool.perform(
            input: input(), target: target(now: now, cwd: nil), knownSecrets: [],
            runner: other.runner(PeerCalls()), binaryResolver: resolvedBinary)
        #expect(other.text("cwd")?.trimmingCharacters(in: .whitespacesAndNewlines)
                == realPath(FileManager.default.currentDirectoryPath))
    }

    @Test
    func cwdIsNotAToolParameter() {
        let definition = ExternalSessionSendTool.definition()
        #expect(definition.parameters["cwd"] == nil)
        #expect(ExternalSessionSendTool.toolName == ExternalSessionToolNames.send)
        #expect(ExternalSessionToolNames.read == "external_session_read")
    }

    @Test
    func definitionDeclaresRequiredParametersWithoutAModelTitle() {
        let definition = ExternalSessionSendTool.definition()
        #expect(definition.name == "external_session_send")
        #expect(Set(definition.required) == ["source", "session", "message"])
        #expect(definition.parameters["tool_title"] == nil)
        #expect(definition.parameters["timeout_seconds"]?.type == .integer)
    }
}

// MARK: - Pending reader merge (branch claude/ext-read-20261109)
//
// These need the real `ExternalSessionTranscriptReader.locate` from line R and
// synthetic transcripts laid out as the format map describes. They are written
// but cannot be exercised until line R is merged: UNRUN / pending.

@Suite("external_session_send location (pending line R)", .serialized)
struct ExternalSessionSendLocationTests {
    private func makeRoot() throws -> (base: URL, sessions: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("send-root-\(UUID().uuidString)", isDirectory: true)
        let sessions = base.appendingPathComponent(".codex/sessions/2026/11/09", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        return (base, sessions)
    }

    private func writeRollout(
        in directory: URL, id: String, firstUserText: String, cwd: String
    ) throws {
        let name = "rollout-2026-11-09T10-00-00-\(id).jsonl"
        let meta = #"{"type":"session_meta","payload":{"id":"\#(id)","cwd":"\#(cwd)"}}"#
        let user = #"{"type":"event_msg","payload":{"type":"user_message","message":"\#(firstUserText)"}}"#
        try (meta + "\n" + user + "\n").write(
            to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    @Test
    func sessionOutsideAuthorizedRootIsNotFoundAndNothingStarts() async throws {
        let (base, _) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let peer = try SyntheticPeer()
        defer { peer.remove() }
        let calls = PeerCalls()
        let roots = [base.appendingPathComponent(".codex/sessions")]
        let threw = await throwsError {
            try await ExternalSessionSendTool.execute(
                input: ["source": "codex", "session": UUID().uuidString.lowercased(), "message": "hi"],
                roots: roots, knownSecrets: [], runner: peer.runner(calls),
                binaryResolver: resolvedBinary)
        }
        #expect(threw)
        #expect(calls.count == 0)
    }

    @Test
    func nameIsRejectedWithoutLocating_UUIDUnderRootRunsInRecordedCwd() async throws {
        let (base, sessions) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let idA = UUID().uuidString.lowercased()
        let cwd = FileManager.default.temporaryDirectory.path
        try writeRollout(in: sessions, id: idA, firstUserText: "alpha unique task", cwd: cwd)
        let roots = [base.appendingPathComponent(".codex/sessions")]
        let peer = try SyntheticPeer()
        defer { peer.remove() }
        let calls = PeerCalls()

        // A name (even an unambiguous one) is not accepted by send.
        let byName = await throwsError {
            try await ExternalSessionSendTool.execute(
                input: ["source": "codex", "session": "alpha unique", "message": "hi"],
                roots: roots, knownSecrets: [], runner: peer.runner(calls),
                binaryResolver: resolvedBinary)
        }
        #expect(byName)
        #expect(calls.count == 0)

        let result = try decode(try await ExternalSessionSendTool.execute(
            input: ["source": "codex", "session": idA, "message": "hi"],
            roots: roots, knownSecrets: [], runner: peer.runner(calls),
            binaryResolver: resolvedBinary))
        #expect(result["session_id"] as? String == idA)
        #expect(peer.argv == ["exec", "resume", "--all", idA, "-"])
        #expect(peer.text("cwd")?.trimmingCharacters(in: .whitespacesAndNewlines) == realPath(cwd))

        // The card for the same call is built from the located session.
        let card = try await ExternalSessionSendTool.approvalSummary(
            input: ["source": "codex", "session": idA, "message": "hi"], roots: roots)
        #expect(card.contains(idA))
        #expect(card.contains("alpha unique task"))
    }
}
