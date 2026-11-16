import Darwin
import Foundation
import Testing
@testable import MinisCore

private actor Terminal523CleanupGate {
    private(set) var started = false
    private(set) var waitingForCleanup = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func start() { started = true }
    func cleanup() async {
        waitingForCleanup = true
        if !released { await withCheckedContinuation { waiter = $0 } }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

private actor Terminal523Completion {
    private(set) var finished = false
    func finish() { finished = true }
}

private struct Terminal523GatedRunner: TerminalProcessRunner {
    let gate: Terminal523CleanupGate
    func run(command: String, workdir: URL, timeout: Duration) async throws -> TerminalProcessResult {
        await gate.start()
        do { try await Task.sleep(for: .seconds(60)) }
        catch {
            await gate.cleanup()
            throw CancellationError()
        }
        return TerminalProcessResult(exitCode: 0, stdout: "synthetic", stderr: "")
    }
}

private struct Terminal523TruncatedRunner: TerminalProcessRunner {
    func run(command: String, workdir: URL, timeout: Duration) async throws -> TerminalProcessResult {
        TerminalProcessResult(exitCode: 9, stdout: "synthetic captured prefix", stderr: "synthetic stderr",
                              outputWasTruncated: true)
    }
}

/// SOURCE_ONLY until ROOT schedules runtime. Real-runner methods create only an
/// owned temporary script/PID manifest and exercise the existing policy-approved
/// Python command. No host configuration, credentials, arbitrary PIDs or UI.
@Suite("D-TERMINAL-06/07 owned process completion", .serialized)
struct TerminalLifecycle523Tests: Sendable {
    private struct OwnedPIDs: Decodable { let parent: Int32; let child: Int32; let group: Int32 }

    private func root() throws -> URL {
        let result = FileManager.default.temporaryDirectory
            .appendingPathComponent("Terminal523-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return result
    }

    private func context(_ root: URL, suffix: String = "old") -> TerminalExecutionContext {
        TerminalExecutionContext(sessionID: "terminal523-session-\(suffix)", turnID: "terminal523-turn-\(suffix)",
            taskID: "terminal523-task-\(suffix)", projectID: "terminal523-project", workdir: root.path)
    }

    private func request(_ root: URL, command: String, timeout: Duration = .seconds(10),
                         approved: Bool = false, suffix: String = "old") -> TerminalExecutionRequest {
        let base = TerminalExecutionRequest(capabilityID: "shell_execute", command: command,
                                            context: context(root, suffix: suffix), timeout: timeout)
        guard approved else { return base }
        return TerminalExecutionRequest(capabilityID: base.capabilityID, command: command, context: base.context,
            approval: TerminalApproval(scopeID: base.context.projectID, requestFingerprint: base.requestFingerprint,
                                       expiresAt: Date().addingTimeInterval(60)), timeout: timeout)
    }

    private func until(_ timeout: Duration = .seconds(4),
                       _ condition: @escaping @Sendable () async -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    private func installScript(_ root: URL) throws {
        // All redaction values are fixed synthetic markers, never real secrets.
        let script = """
        import json, os, subprocess, sys, time
        mode = sys.argv[1]
        if mode == "group":
            child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
            with open("pids.partial", "w") as f:
                json.dump({"parent": os.getpid(), "child": child.pid, "group": os.getpgid(0)}, f)
            os.replace("pids.partial", "pids.json")
            print("synthetic-owned-parent", flush=True)
            child.wait()
        elif mode == "late":
            time.sleep(3.2)
            print("synthetic-late-stdout", flush=True)
            print("api_key=Terminal523FixedSyntheticMarkerABCDEFG", file=sys.stderr, flush=True)
            print("synthetic-late-stderr", file=sys.stderr, flush=True)
        elif mode == "large":
            print("synthetic-stdout", flush=True)
            print("api_key=Terminal523FixedSyntheticMarkerABCDEFG", file=sys.stderr, flush=True)
            sys.stderr.write("界" * 30000)
            sys.stderr.flush()
        elif mode.startswith("quoted-"):
            quote = chr(34) if mode.endswith("double") else chr(39)
            print("synthetic-quoted-stdout", flush=True)
            if mode == "quoted-adjacent-single":
                value = "abc" + chr(92)
            elif mode == "quoted-escaped-double":
                value = "Terminal523EscapedSyntheticMarker" + chr(92) + quote + "R" * 90000
            elif mode == "quoted-backslash-double":
                value = "Terminal523BackslashSyntheticMarkerABCDEFG" + chr(92) * 2
            elif mode == "quoted-escape-boundary-double":
                prefix = "api_key=" + quote + "Terminal523BoundarySyntheticMarker"
                fill = 65536 - len(prefix.encode("utf-8")) - 1
                value = "Terminal523BoundarySyntheticMarker" + "T" * fill + chr(92) + quote + "R" * 10000
            elif mode.startswith("quoted-complete-"):
                value = "Terminal523QuotedSyntheticMarkerABCDEFG"
            else:
                value = "Terminal523QuotedSyntheticMarker" + "Q" * 90000 + "FixedSyntheticEnd"
            sys.stderr.write("api_key=" + quote + value + quote)
            if mode == "quoted-adjacent-single":
                sys.stderr.write(" password=" + quote + "Terminal523AdjacentSyntheticMarkerABCDEFG" + quote)
            sys.stderr.write("\\n")
            if mode == "quoted-backslash-double":
                sys.stderr.write("ordinary-after-real-quote\\n" + "界" * 30000)
            if mode == "quoted-adjacent-single":
                sys.stderr.write("ordinary-after-adjacent-values\\n" + "界" * 30000)
            sys.stderr.flush()
        elif mode == "ordinary-large":
            sys.stdout.write("synthetic-ordinary-prefix\\n" + "ordinary-tail-界" * 10000)
            sys.stdout.flush()
        elif mode.startswith("binary-stderr-"):
            print("synthetic-readable-stdout", flush=True)
            separator = bytes([0]) if mode.endswith("nul") else bytes([255])
            sys.stderr.buffer.write(b"api_key=FA" + separator + b"KE_TERMINAL1872_SENTINEL\\n")
            sys.stderr.buffer.flush()
            sys.exit(17)
        elif mode == "split-utf8":
            for byte in "界".encode("utf-8"):
                sys.stdout.buffer.write(bytes([byte]))
                sys.stdout.buffer.flush()
                time.sleep(0.06)
            sys.stdout.buffer.write(b"\\n")
            sys.stdout.buffer.flush()
        elif mode == "clipped-utf8":
            prefix = b"api_key=" + b"F" * 65000 + b" \\n"
            sys.stderr.buffer.write(prefix + b"A" * (65535 - len(prefix)) + "界".encode("utf-8") + b"tail")
            sys.stderr.buffer.flush()
        """
        try Data(script.utf8).write(to: root.appendingPathComponent("worker.py"))
    }

    private func pids(_ root: URL) throws -> OwnedPIDs {
        try JSONDecoder().decode(OwnedPIDs.self, from: Data(contentsOf: root.appendingPathComponent("pids.json")))
    }

    private func processExists(_ pid: Int32) -> Bool { Darwin.kill(pid, 0) == 0 || errno == EPERM }

    @Test func cancellationWaitsForOwnedRunnerCleanupBeforePublishingReceipt() async throws {
        let directory = try root()
        let gate = Terminal523CleanupGate()
        let completion = Terminal523Completion()
        let boundary = TerminalBoundary(policy: TerminalPolicy(scopeID: "terminal523-project", allowedRoot: directory),
                                        runner: Terminal523GatedRunner(gate: gate))
        let operation = Task {
            let receipt = await boundary.execute(request(directory, command: "echo synthetic", timeout: .seconds(20)))
            await completion.finish()
            return receipt
        }
        let started = await until { await gate.started }
        #expect(started)
        boundary.stop()
        boundary.stop()
        let cleaning = await until { await gate.waitingForCleanup }
        #expect(cleaning)
        // Keep cleanup blocked while giving a prematurely published receipt
        // time to run its completion actor. An immediate false can also occur
        // in the old implementation merely because that task has not resumed.
        let prematureCompletion = await until(.milliseconds(250)) { await completion.finished }
        #expect(!prematureCompletion)
        await gate.release()
        let receipt = await operation.value
        let completedAfterCleanup = await completion.finished
        #expect(completedAfterCleanup)
        #expect(receipt.error == TerminalBoundaryError.cancelled.rawValue)
        #expect(receipt.exitCode == nil)
        #expect(receipt.sessionID == "terminal523-session-old")
    }

    @Test(arguments: [TerminalBoundaryError.cancelled, .timeout])
    func stopAndTimeoutReclaimOnlyTheOwnedGroup(outcome: TerminalBoundaryError) async throws {
        let directory = try root()
        try installScript(directory)
        let boundary = TerminalBoundary(policy: TerminalPolicy(scopeID: "terminal523-project", allowedRoot: directory))
        let timeout: Duration = outcome == .timeout ? .seconds(2) : .seconds(20)
        let operation = Task {
            await boundary.execute(request(directory, command: "/usr/bin/python3 worker.py group",
                                           timeout: timeout, approved: true))
        }
        let ready = await until { FileManager.default.fileExists(atPath: directory.appendingPathComponent("pids.json").path) }
        guard ready else {
            boundary.stop(); operation.cancel(); _ = await operation.value
            Issue.record("Owned process PID manifest was not produced")
            return
        }
        let owned: OwnedPIDs
        do { owned = try pids(directory) }
        catch { boundary.stop(); operation.cancel(); _ = await operation.value; throw error }
        #expect(owned.parent > 0 && owned.child > 0 && owned.group > 0)
        #expect(owned.group != getpgrp())
        #expect(processExists(owned.child))
        if outcome == .cancelled { boundary.stop(); boundary.stop() }
        let receipt = await operation.value
        #expect(receipt.error == outcome.rawValue)
        #expect(receipt.exitCode == nil)
        #expect(receipt.taskID == "terminal523-task-old")
        // An orphan zombie can briefly remain visible while init reaps it.
        // Require bounded group/PID disappearance, not merely a returned error.
        let gone = await until(.seconds(2)) {
            !processExists(-owned.group) && !processExists(owned.parent) && !processExists(owned.child)
        }
        #expect(gone)
    }

    @Test func stoppedInvocationCannotPublishIntoTheNextContext() async throws {
        let directory = try root()
        try installScript(directory)
        let boundary = TerminalBoundary(policy: TerminalPolicy(scopeID: "terminal523-project", allowedRoot: directory))
        let old = Task { await boundary.execute(request(directory, command: "/usr/bin/python3 worker.py group",
                                                       timeout: .seconds(20), approved: true)) }
        let ready = await until { FileManager.default.fileExists(atPath: directory.appendingPathComponent("pids.json").path) }
        guard ready else {
            boundary.stop(); old.cancel(); _ = await old.value
            Issue.record("Owned old invocation never became ready")
            return
        }
        let owned: OwnedPIDs
        do { owned = try pids(directory) }
        catch { boundary.stop(); old.cancel(); _ = await old.value; throw error }
        boundary.stop()
        let fresh = await boundary.execute(request(directory, command: "echo fresh-owned-523", suffix: "fresh"))
        let previous = await old.value
        #expect(previous.error == TerminalBoundaryError.cancelled.rawValue)
        #expect(previous.sessionID == "terminal523-session-old")
        #expect(fresh.error == nil)
        #expect(fresh.exitCode == 0)
        #expect(fresh.output == "fresh-owned-523\n")
        #expect(fresh.sessionID == "terminal523-session-fresh")
        #expect(fresh.requestFingerprint != previous.requestFingerprint)
        let gone = await until(.seconds(2)) { !processExists(-owned.group) && !processExists(owned.child) }
        #expect(gone)
    }

    @Test func lateStdoutAndStderrAreCapturedThenRedacted() async throws {
        let directory = try root()
        try installScript(directory)
        let boundary = TerminalBoundary(policy: TerminalPolicy(scopeID: "terminal523-project", allowedRoot: directory))
        let receipt = await boundary.execute(request(directory, command: "/usr/bin/python3 worker.py late",
                                                    timeout: .seconds(8), approved: true))
        #expect(receipt.error == nil)
        #expect(receipt.exitCode == 0)
        #expect(receipt.output.hasPrefix("synthetic-late-stdout\n"))
        #expect(receipt.output.contains("synthetic-late-stderr"))
        #expect(receipt.output.contains(ContentSecretRedactor.mask("Terminal523FixedSyntheticMarkerABCDEFG")))
        #expect(!receipt.output.contains("Terminal523FixedSyntheticMarkerABCDEFG"))
    }

    @Test func realByteCaptureRetainsUnicodeAndReportsTruncation() async throws {
        let directory = try root()
        try installScript(directory)
        let boundary = TerminalBoundary(policy: TerminalPolicy(scopeID: "terminal523-project", allowedRoot: directory))
        let receipt = await boundary.execute(request(directory, command: "/usr/bin/python3 worker.py large",
                                                    approved: true))
        #expect(receipt.error == nil)
        #expect(receipt.exitCode == 0)
        #expect(receipt.output.hasPrefix("synthetic-stdout\n"))
        #expect(receipt.output.contains("界"))
        #expect(receipt.output.contains(ContentSecretRedactor.mask("Terminal523FixedSyntheticMarkerABCDEFG")))
        #expect(!receipt.output.contains("Terminal523FixedSyntheticMarkerABCDEFG"))
        #expect(receipt.output.hasSuffix("\n[truncated]"))
    }

    @Test func captureTruncationRemainsExplicitEvenWhenProjectedTextIsShort() async throws {
        let directory = try root()
        let boundary = TerminalBoundary(policy: TerminalPolicy(scopeID: "terminal523-project", allowedRoot: directory),
                                        runner: Terminal523TruncatedRunner())
        let receipt = await boundary.execute(request(directory, command: "echo synthetic"))
        #expect(receipt.error == nil)
        #expect(receipt.exitCode == 9)
        #expect(receipt.output == "synthetic captured prefix\nsynthetic stderr\n[truncated]")
    }

    @Test(arguments: ["double", "single"])
    func completeQuotedSyntheticValuesKeepTheExistingMask(quote: String) async throws {
        let directory = try root()
        try installScript(directory)
        let boundary = TerminalBoundary(policy: TerminalPolicy(scopeID: "terminal523-project", allowedRoot: directory))
        let receipt = await boundary.execute(request(directory,
            command: "/usr/bin/python3 worker.py quoted-complete-\(quote)", approved: true))
        #expect(receipt.error == nil)
        #expect(receipt.exitCode == 0)
        let preservedOrdinaryPrefix = receipt.output.hasPrefix("synthetic-quoted-stdout\n")
        let usesExistingMask = receipt.output.contains(ContentSecretRedactor.mask("Terminal523QuotedSyntheticMarkerABCDEFG"))
        let leakedSyntheticValue = receipt.output.contains("Terminal523QuotedSyntheticMarkerABCDEFG")
        let claimsTruncation = receipt.output.contains("[truncated]")
        #expect(preservedOrdinaryPrefix)
        #expect(usesExistingMask)
        #expect(!leakedSyntheticValue)
        #expect(!claimsTruncation)
    }

    @Test(arguments: ["double", "single"])
    func byteClippedQuotedSyntheticValuesCannotReachTheReceipt(quote: String) async throws {
        let directory = try root()
        try installScript(directory)
        let boundary = TerminalBoundary(policy: TerminalPolicy(scopeID: "terminal523-project", allowedRoot: directory))
        let receipt = await boundary.execute(request(directory,
            command: "/usr/bin/python3 worker.py quoted-clipped-\(quote)", approved: true))
        #expect(receipt.error == nil)
        #expect(receipt.exitCode == 0)
        // Assert booleans only so even the old implementation's negative
        // control cannot put its long synthetic receipt into failure logs.
        let preservedOrdinaryPrefix = receipt.output.hasPrefix("synthetic-quoted-stdout\n")
        let quoteDelimiter = quote == "double" ? "\"" : "'"
        let maskedPartialValue = receipt.output.contains(
            "api_key=" + quoteDelimiter + String(repeating: "*", count: 128)
        )
        let leakedSyntheticPrefix = receipt.output.contains("Terminal523QuotedSyntheticMarker")
        let leakedSyntheticBody = receipt.output.contains("QQQQQQQQQQQQQQQQ")
        let reportsTruncation = receipt.output.hasSuffix("\n[truncated]")
        #expect(preservedOrdinaryPrefix)
        #expect(maskedPartialValue)
        #expect(!leakedSyntheticPrefix)
        #expect(!leakedSyntheticBody)
        #expect(reportsTruncation)
        #expect(receipt.output.count == TerminalReceipt.maximumOutputCharacters + "\n[truncated]".count)
    }

    @Test func ordinaryLargeOutputRetainsItsBoundedReadablePrefix() async throws {
        let directory = try root()
        try installScript(directory)
        let boundary = TerminalBoundary(policy: TerminalPolicy(scopeID: "terminal523-project", allowedRoot: directory))
        let receipt = await boundary.execute(request(directory,
            command: "/usr/bin/python3 worker.py ordinary-large", approved: true))
        #expect(receipt.error == nil)
        #expect(receipt.exitCode == 0)
        #expect(receipt.output.hasPrefix("synthetic-ordinary-prefix\nordinary-tail-界"))
        #expect(receipt.output.count == TerminalReceipt.maximumOutputCharacters + "\n[truncated]".count)
        #expect(receipt.output.hasSuffix("\n[truncated]"))
    }

    @Test(arguments: ["nul", "invalid"])
    func realBinaryStderrIsClassifiedWithoutPublishingFragmentsOrLosingExit(separator: String) async throws {
        let directory = try root()
        try installScript(directory)
        let boundary = TerminalBoundary(policy: TerminalPolicy(scopeID: "terminal523-project", allowedRoot: directory))
        let receipt = await boundary.execute(request(directory,
            command: "/usr/bin/python3 worker.py binary-stderr-\(separator)", approved: true))
        #expect(receipt.error == nil)
        #expect(receipt.exitCode == 17)
        #expect(receipt.output.hasPrefix("synthetic-readable-stdout\n"))
        #expect(receipt.output.contains("[binary output omitted]"))
        #expect(!receipt.output.contains("FA"))
        #expect(!receipt.output.contains("KE_TERMINAL1872_SENTINEL"))
    }

    @Test func realSplitUTF8IsJoinedBeforeTextClassification() async throws {
        let directory = try root()
        try installScript(directory)
        let boundary = TerminalBoundary(policy: TerminalPolicy(scopeID: "terminal523-project", allowedRoot: directory))
        let receipt = await boundary.execute(request(directory,
            command: "/usr/bin/python3 worker.py split-utf8", approved: true))
        #expect(receipt.error == nil)
        #expect(receipt.exitCode == 0)
        #expect(receipt.output == "界\n")
    }

    @Test func realByteCapPreservesCompleteUTF8PrefixAndActualTruncation() async throws {
        let directory = try root()
        try installScript(directory)
        let boundary = TerminalBoundary(policy: TerminalPolicy(scopeID: "terminal523-project", allowedRoot: directory))
        let receipt = await boundary.execute(request(directory,
            command: "/usr/bin/python3 worker.py clipped-utf8", approved: true))
        #expect(receipt.error == nil)
        #expect(receipt.exitCode == 0)
        let maskedCapturedPrefix = receipt.output.hasPrefix("api_key=" + String(repeating: "*", count: 128))
        #expect(maskedCapturedPrefix)
        #expect(!receipt.output.contains(String(repeating: "F", count: 16)))
        #expect(receipt.output.count == TerminalReceipt.maximumOutputCharacters + "\n[truncated]".count)
        #expect(!receipt.output.contains("\u{FFFD}"))
        #expect(receipt.output.hasSuffix("\n[truncated]"))
    }

    @Test(arguments: ["quoted-escaped-double", "quoted-backslash-double", "quoted-escape-boundary-double"])
    func capturedQuotedEscapesUseRealQuoteBoundaries(mode: String) async throws {
        let directory = try root()
        try installScript(directory)
        let boundary = TerminalBoundary(policy: TerminalPolicy(scopeID: "terminal523-project", allowedRoot: directory))
        let receipt = await boundary.execute(request(directory,
            command: "/usr/bin/python3 worker.py \(mode)", approved: true))
        #expect(receipt.error == nil)
        #expect(receipt.exitCode == 0)
        let preservedOrdinaryPrefix = receipt.output.hasPrefix("synthetic-quoted-stdout\n")
        let leakedSyntheticPrefix = receipt.output.contains("Terminal523")
        let leakedSyntheticBody = receipt.output.contains("RRRRRRRRRRRRRRRR") || receipt.output.contains("TTTTTTTTTTTTTTTT")
        let reportsTruncation = receipt.output.hasSuffix("\n[truncated]")
        let usesExistingMask: Bool
        if mode == "quoted-backslash-double" {
            usesExistingMask = receipt.output.contains(
                ContentSecretRedactor.mask("Terminal523BackslashSyntheticMarkerABCDEFG\\\\")
            )
            let preservedTextAfterRealQuote = receipt.output.contains("ordinary-after-real-quote\n界")
            #expect(preservedTextAfterRealQuote)
        } else {
            // A byte-clipped quoted value has no trustworthy closing quote.
            // Its captured prefix is completely masked before the UI cap.
            usesExistingMask = receipt.output.contains(
                "api_key=\"" + String(repeating: "*", count: 128)
            )
        }
        #expect(preservedOrdinaryPrefix)
        #expect(!leakedSyntheticPrefix)
        #expect(!leakedSyntheticBody)
        #expect(usesExistingMask)
        #expect(reportsTruncation)
        #expect(receipt.output.count == TerminalReceipt.maximumOutputCharacters + "\n[truncated]".count)
    }

    @Test func singleQuotedLiteralBackslashPreservesAdjacentCredentialIdentity() async throws {
        let directory = try root()
        try installScript(directory)
        let boundary = TerminalBoundary(policy: TerminalPolicy(scopeID: "terminal523-project", allowedRoot: directory))
        let receipt = await boundary.execute(request(directory,
            command: "/usr/bin/python3 worker.py quoted-adjacent-single", approved: true))
        #expect(receipt.error == nil)
        #expect(receipt.exitCode == 0)
        let preservedOrdinaryPrefix = receipt.output.hasPrefix("synthetic-quoted-stdout\n")
        let maskedFirstValue = receipt.output.contains("api_key='" + ContentSecretRedactor.mask("abc\\") + "'")
        let maskedAdjacentValue = receipt.output.contains("password='" + ContentSecretRedactor.mask("Terminal523AdjacentSyntheticMarkerABCDEFG") + "'")
        let leakedSyntheticValue = receipt.output.contains("Terminal523AdjacentSyntheticMarkerABCDEFG")
        let preservedOrdinaryTail = receipt.output.contains("ordinary-after-adjacent-values\n界")
        let reportsTruncation = receipt.output.hasSuffix("\n[truncated]")
        #expect(preservedOrdinaryPrefix)
        #expect(maskedFirstValue)
        #expect(maskedAdjacentValue)
        #expect(!leakedSyntheticValue)
        #expect(preservedOrdinaryTail)
        #expect(reportsTruncation)
    }

    @Test(arguments: [false, true])
    func capturedAssignmentControlsPreserveMaskAndOrdinaryEscapes(wasTruncated: Bool) {
        // These are output contracts, independent of scanner implementation.
        let ordinary = #"ordinary="a\"b" path='c\' plain-after"#
        let masked = "api_key=\"" + String(repeating: "*", count: 128) + "\" ordinary-after-mask"
        let result = TerminalProcessResult(exitCode: 0, stdout: ordinary, stderr: masked,
                                           outputWasTruncated: wasTruncated)
        #expect(result.stdout == ordinary)
        #expect(result.stderr == masked)
        #expect(result.exitCode == 0)
        #expect(result.outputWasTruncated == wasTruncated)

        let complete = TerminalProcessResult(exitCode: 0,
            stdout: "password=\"SyntheticCompleteValueABCDEFG\" ordinary-after-secret", stderr: "",
            outputWasTruncated: wasTruncated)
        #expect(complete.stdout == "password=\"" + ContentSecretRedactor.mask("SyntheticCompleteValueABCDEFG") + "\" ordinary-after-secret")
        #expect(complete.stderr.isEmpty)
    }

}
