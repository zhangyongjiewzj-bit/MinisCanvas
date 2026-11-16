import CryptoKit
import Darwin
import Foundation
import Testing
@testable import MinisCore

@_silgen_name("proc_pidinfo")
private func conc2ProcInfo(_ pid: Int32, _ flavor: Int32, _ argument: UInt64,
                          _ buffer: UnsafeMutableRawPointer?, _ size: Int32) -> Int32

private struct CONC2Generation: Codable, Equatable, Sendable {
    let pid: Int32
    let uid: UInt32
    let start_sec: UInt64
    let start_usec: UInt64
}

private enum CONC2Observation: Sendable {
    case originalAlive
    case originalGone
    case unknown(Int32)
}

private func conc2Generation(_ expected: CONC2Generation) -> CONC2Observation {
    var buffer = [UInt8](repeating: 0, count: 136) // Darwin proc_bsdinfo ABI.
    errno = 0
    let count = buffer.withUnsafeMutableBytes {
        conc2ProcInfo(expected.pid, 3, 0, $0.baseAddress, Int32($0.count))
    }
    let code = errno
    guard count == 136 else {
        return count == 0 && [ESRCH, ENOENT].contains(code)
            ? .originalGone : .unknown(code)
    }
    let current = buffer.withUnsafeBytes { raw in
        CONC2Generation(pid: Int32(raw.loadUnaligned(fromByteOffset: 12, as: UInt32.self)),
                        uid: raw.loadUnaligned(fromByteOffset: 20, as: UInt32.self),
                        start_sec: raw.loadUnaligned(fromByteOffset: 120, as: UInt64.self),
                        start_usec: raw.loadUnaligned(fromByteOffset: 128, as: UInt64.self))
    }
    return current == expected ? .originalAlive : .originalGone
}

private func conc2Save(_ value: [String: Any], at url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

private func conc2JSON(_ url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private func conc2Pause(_ duration: Duration) async {
    // Teardown polling must not become a busy loop after test-task cancel.
    let sleeper = Task.detached { try? await Task.sleep(for: duration) }
    await sleeper.value
}

private func conc2DecodeGeneration(_ value: Any?) -> CONC2Generation? {
    guard let value, JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
    return try? JSONDecoder().decode(CONC2Generation.self, from: data)
}

/// This independent thread is fixture custody, not a replacement API result.
/// On cutoff it records the missed behavior bound and asks only the synthetic
/// holder to exit naturally. It never cancels/abandons the production call.
private final class CONC2FiniteLease: @unchecked Sendable {
    private let condition = NSCondition()
    private var returned = false
    private var cutoff = false
    private var releaseFailure: String?
    private var thread: Thread?
    let directory: URL
    let nonce: String
    let deadline: TimeInterval

    init(directory: URL, nonce: String, deadline: TimeInterval) {
        self.directory = directory
        self.nonce = nonce
        self.deadline = deadline
        let worker = Thread { [self] in run() }
        worker.name = "miniscanvas.conc2.finite-fixture-lease"
        thread = worker
        worker.start()
    }

    private func run() {
        condition.lock()
        while !returned && ProcessInfo.processInfo.systemUptime < deadline {
            _ = condition.wait(until: Date().addingTimeInterval(0.02))
        }
        cutoff = !returned
        let missed = cutoff
        condition.unlock()
        if missed {
            try? conc2Save(["status": "CLEANUP_RELEASE_CUTOFF_AFTER_BEHAVIOR_BOUND_NOT_EXIT",
                            "nonce": nonce, "uptime": ProcessInfo.processInfo.systemUptime,
                            "no_signal": true], at: directory.appendingPathComponent("bound-exceeded.json"))
            print("CONC2_CLEANUP_RELEASE_CUTOFF nonce=\(nonce) fixtureReleaseOnly=true hostStillOwned=true notPASSBound=true")
        }
        do { try writeNaturalRelease() }
        catch {
            condition.lock(); releaseFailure = String(describing: error); condition.unlock()
        }
    }

    private func writeNaturalRelease() throws {
        let file = directory.appendingPathComponent("release.json")
        let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        let data = try JSONSerialization.data(withJSONObject: ["nonce": nonce, "natural_release": true])
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard n > 0 else { throw POSIXError(.EIO) }
                offset += n
            }
        }
        guard fsync(fd) == 0 else { throw POSIXError(.EIO) }
    }

    func callReturned() {
        condition.lock(); returned = true; condition.broadcast(); condition.unlock()
    }

    func finish() async -> (cutoff: Bool, error: String?) {
        while thread?.isFinished != true { await conc2Pause(.milliseconds(10)) }
        return snapshot()
    }

    private func snapshot() -> (cutoff: Bool, error: String?) {
        condition.lock()
        let value = (cutoff, releaseFailure)
        condition.unlock()
        return value
    }
}

private struct CONC2CallOutcome: Sendable {
    let classification: String
}

@Suite("D-CONC2 N3C0021+C0043 real detached stdout custody", .serialized)
struct CONC2DetachedSessionStdoutBoundaryTests {
    private let fixtureSHA = "bacd1cc162ac3a44be29113683a4cf347bba678e9b6ed3377d5416bebcdd5dcb"
    private let identitySHA = "a21c42c24902e92b7704cff8fd7d77aaafaffc4a76c87caebfed91fc8d888f66"

    /// One method, four serial observations; no filtered alternate or product
    /// injection. Current production APIs have no typed HOLD case, so only
    /// their exact timeout/cancellation classifications can pass this test.
    @Test("setsid double-fork stdout holder: both production entries timeout and cancel remain bounded")
    func detachedSessionStdoutTimeoutAndCancelAcrossBothProductionEntries() async throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = formal.rootDirectory.appendingPathComponent("conc2-detached-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        #expect(root.resolvingSymlinksInPath() == root)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/CONC2DetachedStdout/conc2_detached_stdout.py")
        let identity = fixture.deletingLastPathComponent().appendingPathComponent("process_identity.py")
        #expect(try digest(fixture) == fixtureSHA)
        #expect(try digest(identity) == identitySHA)
        guard try digest(fixture) == fixtureSHA, try digest(identity) == identitySHA else { return }
        for entry in ["terminal", "external-agent"] {
            for mode in ["timeout", "cancel"] {
                guard await exercise(entry: entry, mode: mode, root: root, fixture: fixture) else {
                    print("CONC2_FIXTURE_REJECTED_REMAINING_CASES_NOT_RUN evidence=\(root.path)")
                    return
                }
            }
        }
        // Deliberately preserve fixtures, raw outcomes, and failed evidence.
        print("CONC2_ALL_FOUR_CALLS_AND_FINITE_HOLDERS_SETTLED evidence=\(root.path)")
    }

    private func digest(_ file: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
    }

    private func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func exercise(entry: String, mode: String, root: URL, fixture: URL) async -> Bool {
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let directory = root.appendingPathComponent(entry + "-" + mode + "-" + nonce)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { Issue.record("CONC2_FIXTURE_DIRECTORY_REFUSED \(error)"); return false }
        // The real TerminalPolicy admits arguments only within this case root.
        // Stage exact original fixture bytes; never broaden production roots.
        let localFixture = directory.appendingPathComponent("conc2_detached_stdout.py")
        let localIdentity = directory.appendingPathComponent("process_identity.py")
        do {
            try FileManager.default.copyItem(at: fixture, to: localFixture)
            try FileManager.default.copyItem(at: fixture.deletingLastPathComponent()
                .appendingPathComponent("process_identity.py"), to: localIdentity)
            for file in [localFixture, localIdentity] {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
            guard try digest(localFixture) == fixtureSHA, try digest(localIdentity) == identitySHA else {
                Issue.record("CONC2_CASE_LOCAL_FIXTURE_BYTES_MISMATCH_NOT_PRODUCT_RED")
                return false
            }
        } catch {
            Issue.record("CONC2_CASE_LOCAL_FIXTURE_PREPARATION_FAILED \(error)")
            return false
        }
        let arguments = ["-I", "-B", localFixture.path, "--case-root", directory.path,
                         "--nonce", nonce, "--hard-seconds", "20"]
        let context = TerminalExecutionContext(sessionID: "conc2-session", turnID: nonce,
            taskID: "conc2-task", projectID: "conc2-project", workdir: directory.path)
        let boundary = TerminalBoundary(policy: TerminalPolicy(scopeID: "conc2-project", allowedRoot: directory))
        let command = (["/usr/bin/python3"] + arguments).map(quote).joined(separator: " ")
        let duration: Duration = .seconds(2) // B1105: both branches use timeout2, PASS <=2+3 seconds.
        let bare = TerminalExecutionRequest(capabilityID: "shell_execute", command: command,
                                             context: context, timeout: duration)
        let request = TerminalExecutionRequest(capabilityID: bare.capabilityID, command: command,
            context: context, approval: TerminalApproval(scopeID: "conc2-project",
                requestFingerprint: bare.requestFingerprint, expiresAt: Date().addingTimeInterval(60)),
            timeout: duration)
        let launch = ProcessInfo.processInfo.systemUptime
        let call = Task { () -> CONC2CallOutcome in
            if entry == "terminal" {
                let receipt = await boundary.execute(request)
                return CONC2CallOutcome(classification: receipt.error ?? "success")
            }
            do {
                _ = try await CLIProcessRunner.run(binary: "/usr/bin/python3", arguments: arguments,
                    workingDirectory: directory, timeoutSeconds: 2,
                    executionID: nonce)
                return CONC2CallOutcome(classification: "success")
            } catch is CancellationError {
                return CONC2CallOutcome(classification: "cancelled")
            } catch let error as ExternalAgentError {
                switch error {
                case .timeout: return CONC2CallOutcome(classification: "timeout")
                default: return CONC2CallOutcome(classification: "external-other-error")
                }
            } catch { return CONC2CallOutcome(classification: "unexpected-error") }
        }
        // A timeout watchdog is armed independently before registration polling.
        var measuredFrom = launch
        var lease: CONC2FiniteLease? = mode == "timeout"
            ? CONC2FiniteLease(directory: directory, nonce: nonce, deadline: launch + 10) : nil
        let readyDeadline = launch + 1.5
        while conc2JSON(directory.appendingPathComponent("holder.json")) == nil,
              ProcessInfo.processInfo.systemUptime < readyDeadline {
            await conc2Pause(.milliseconds(10))
        }
        let holder = conc2JSON(directory.appendingPathComponent("holder.json"))
        let leader = conc2JSON(directory.appendingPathComponent("leader.json"))
        let intermediate = conc2JSON(directory.appendingPathComponent("intermediate.json"))
        let reaped = conc2JSON(directory.appendingPathComponent("intermediate.reaped.json"))
        let holderGeneration = conc2DecodeGeneration(holder?["generation"])
        let leaderGeneration = conc2DecodeGeneration(leader?["generation"])
        let middleGeneration = conc2DecodeGeneration(intermediate?["generation"])
        var holderAlive = false
        if let holderGeneration, case .originalAlive = conc2Generation(holderGeneration) {
            holderAlive = holderGeneration.uid == geteuid()
        }
        let dev = holder?["stdout_dev"] as? UInt64
        let inode = holder?["stdout_ino"] as? UInt64
        let gates: [Bool] = [
            holder?["nonce"] as? String == nonce,
            holder?["detached_from_leader_sid"] as? Bool == true,
            holder?["detached_from_leader_pgid"] as? Bool == true,
            holder?["adopted_from_intermediate"] as? Bool == true,
            holder?["stdout_is_pipe"] as? Bool == true,
            dev != nil && dev == (leader?["stdout_dev"] as? UInt64),
            inode != nil && inode == (leader?["stdout_ino"] as? UInt64),
            reaped?["true_waitpid_of_direct_intermediate_only"] as? Bool == true,
            (reaped?["pid"] as? Int32) == middleGeneration?.pid,
            (reaped?["status"] as? Int) == 0,
            holderAlive, leaderGeneration != nil, middleGeneration != nil
        ]
        let qualified = gates.allSatisfy { $0 }
        #expect(qualified, "CONC2_FIXTURE_NOT_QUALIFIED: never call a precondition miss product RED")
        if mode == "cancel" {
            measuredFrom = ProcessInfo.processInfo.systemUptime
            lease = CONC2FiniteLease(directory: directory, nonce: nonce, deadline: measuredFrom + 10)
            // Exercise the actual public Terminal stop; the external entry's
            // original task-cancellation handler resolves its own registry.
            if entry == "terminal" { boundary.stop() } else { call.cancel() }
        }
        let outcome = await call.value // Never abandon the real production call.
        let elapsed = ProcessInfo.processInfo.systemUptime - measuredFrom
        lease?.callReturned()
        let settled = await lease?.finish()
        #expect(settled?.error == nil, "finite-holder natural release write must succeed")
        #expect(settled?.cutoff == false && elapsed <= 5,
                "CONC2_B1105_BEHAVIOR_RED: timeout2+3s exceeded; cleanup release/host HOLD is not typed product HOLD")
        #expect(outcome.classification == (mode == "timeout" ? "timeout" : "cancelled"))
        try? conc2Save(["entry": entry, "mode": mode, "nonce": nonce,
                       "fixture_qualified": qualified, "elapsed_seconds": elapsed,
                       "behavior_bound_seconds": 5, "request_timeout_seconds": 2,
                       "cleanup_release_deadline_seconds": 10, "cutoff_fired": settled?.cutoff ?? true,
                       "classification": outcome.classification,
                       "fixture_hard_seconds": 20, "holder_waitpid_claim": false,
                       "signals_by_test": [], "production_call_Task_value_joined": true],
                      at: directory.appendingPathComponent("production-call-result.json"))
        // This exact typed result is returned by TerminalBoundary.execute's
        // policy guard before installing an invocation or calling the runner.
        // Preserve the failed expectations above, stop the other cases, and do
        // not invent missing fixture PIDs or wait forever for a fork not made.
        if entry == "terminal", outcome.classification == "pathViolation",
           holder == nil, leader == nil, intermediate == nil, reaped == nil {
            try? conc2Save(["nonce": nonce, "entry": entry, "mode": mode,
                           "classification": outcome.classification,
                           "production_call_Task_value_joined": true,
                           "pre_spawn_TerminalBoundary_policy_rejection": true,
                           "fixture_PID_count": 0, "not_a_product_bounded_PASS": true],
                          at: directory.appendingPathComponent("FIXTURE_PRESPAWN_PATH_REJECTION_NO_FORK.json"))
            print("CONC2_PRESPAWN_POLICY_REJECTION_NO_FORK_REMAINING_NOT_RUN evidence=\(directory.path)")
            return false
        }
        var known = [leaderGeneration, middleGeneration, holderGeneration].compactMap { $0 }
        while known.count != 3 {
            // Missing registration is not proof that no fork happened. Keep
            // this test/outer host owned; never publish an empty known0 PASS.
            print("CONC2_HOLD_MISSING_FIXTURE_REGISTRATION_NOT_CLOSED evidence=\(directory.path)")
            await conc2Pause(.milliseconds(200))
            known = ["leader.json", "intermediate.json", "holder.json"].compactMap {
                let record = conc2JSON(directory.appendingPathComponent($0))
                guard record?["nonce"] as? String == nonce else { return nil }
                return conc2DecodeGeneration(record?["generation"])
            }
        }
        await awaitAllOriginalGenerationsGone(known, directory: directory, label: "known0")
        await conc2Pause(.seconds(5))
        await awaitAllOriginalGenerationsGone(known, directory: directory, label: "known-plus5")
        let intent = conc2JSON(directory.appendingPathComponent("holder.natural-exit-intent.json"))
        #expect(conc2DecodeGeneration(intent?["generation"]) == holderGeneration)
        print("CONC2_CASE_SETTLED entry=\(entry) mode=\(mode) elapsed=\(elapsed) qualified=\(qualified) result=\(outcome.classification) evidence=\(directory.path)")
        return qualified
    }

    private func awaitAllOriginalGenerationsGone(_ known: [CONC2Generation], directory: URL,
                                                 label: String) async {
        while true {
            var allGone = true
            for generation in known {
                switch conc2Generation(generation) {
                case .originalGone: break
                case .originalAlive, .unknown: allGone = false
                }
            }
            if allGone {
                let encoded = (try? JSONEncoder().encode(known)).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? []
                try? conc2Save(["known": encoded, "all_original_generations_gone": true,
                               "uptime": ProcessInfo.processInfo.systemUptime,
                               "not_waitpid_of_reparented_holder": true],
                              at: directory.appendingPathComponent(label + ".json"))
                return
            }
            // No clock expiry becomes a fake exit, signal, or abandoned owner.
            print("CONC2_HOLD_ORIGINAL_GENERATION_OR_METADATA_UNKNOWN evidence=\(directory.path)")
            await conc2Pause(.milliseconds(200))
        }
    }
}
