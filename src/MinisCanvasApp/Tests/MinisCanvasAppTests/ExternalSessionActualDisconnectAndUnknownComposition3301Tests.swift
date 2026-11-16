import Foundation
import Testing
import Darwin
import MinisCore
@testable import MinisCanvasApp

@Suite("D-EXTH actual EOF then durable checkpoint same-attempt continuation 3301")
@MainActor
struct ExternalSessionActualDisconnectAndUnknownComposition3301Tests {
    @Test func actualProcessEOFBeforeReopenRetainsSameAttemptAndRefusesActualOldEvent() async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "EXTH-3301")
        let home = profile.rootDirectory.appendingPathComponent("owned-codex-home", isDirectory: true)
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        let day = sessions.appendingPathComponent("2026/10/04", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let thread = "12345678-1234-1234-1234-123456789abc"
        let threadID = ExternalSessionThreadID(rawValue: thread)
        try Data("""
        {"timestamp":"2026-10-04T00:00:00Z","type":"session_meta","payload":{"id":"\(thread)","cwd":"/synthetic/project","cli_version":"0.151.0"}}
        """.utf8).write(to: day.appendingPathComponent("rollout-2026-10-04T00-00-00-\(thread).jsonl"))
        let server = profile.rootDirectory.appendingPathComponent("synthetic-codex-server.py")
        try Data(#"""
        #!/usr/bin/python3 -IS
        import json, os, sys, time
        home = os.environ['CODEX_HOME']
        old = not os.path.exists(os.path.join(home, 'first-process-finished'))
        count = 0
        with open(os.path.join(home, "pid-old" if old else "pid-new"), "w") as f: f.write(str(os.getpid()))
        for line in sys.stdin:
            req = json.loads(line)
            method, rid = req.get('method'), req.get('id')
            if method == 'initialized':
                continue
            if method == 'initialize':
                print(json.dumps({'id':rid,'result':{'userAgent':'miniscanvas/0.151.0 (synthetic)','platformFamily':'unix','platformOs':'macos'}}), flush=True)
            elif method == 'thread/resume':
                thread = req['params']['threadId']
                print(json.dumps({'id':rid,'result':{'thread':{'id':thread}}}), flush=True)
                if old:
                    # Wait until the App has consumed the control receipt.
                    # Response and notification use independent readers, so
                    # printing the response first alone cannot establish it.
                    while not os.path.exists(os.path.join(home, 'allow-initial-terminal')):
                        time.sleep(0.01)
                    print(json.dumps({'method':'turn/completed','params':{'threadId':thread,'turn':{'id':'turn-completed','status':'completed'}}}), flush=True)
                    while not os.path.exists(os.path.join(home, 'old-eof')):
                        time.sleep(0.01)
                    # This process really exits before the App constructs its
                    # next runtime. Replay below uses the captured actual event,
                    # not a fixture-constructed event envelope.
                    open(os.path.join(home, 'first-process-finished'), 'w').close()
                    break
                count += 1
                print(json.dumps({'method':'item/started','params':{'threadId':thread,'turnId':'turn-new','item':{'id':'new-'+str(count),'type':'commandExecution'}}}), flush=True)
        """#.utf8).write(to: server)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: server.path)
        let composition = ProductionOrchestrationDefaults.makeExternalSessionAuthorization(runtimeConsumer: nil)
        composition.configureExternalSourceRegistration(hostID: "synthetic-3301")
        let sourceID = try composition.registerSelectedReadRoot(kind: .codex, rootURL: sessions)
        let profileID = try #require(composition.supervisedProfileID(for: sourceID))
        let runtimeDirectory = profile.rootDirectory.appendingPathComponent("external-session-runtime", isDirectory: true)
        let runtimeFile = runtimeDirectory.appendingPathComponent("\(sourceID.rawValue).json")
        try composition.configureSyntheticCodexControl(sourceID: sourceID, executableURL: server,
                                                      homeURL: home, runtimeDirectory: runtimeDirectory)
        let statusGrant = try await composition.issueReadGrant(
            authorizationID: .init(rawValue: "3301-status"), sourceID: sourceID, profileID: profileID,
            target: .source(sourceID), scopes: [.metadata, .status], lifetime: 60)
        _ = try await composition.activateSelectedReadRoot(sourceID: sourceID, readGrant: statusGrant)
        let resumeGrant = try await composition.issueControlGrant(
            authorizationID: .init(rawValue: "3301-resume"), sourceID: sourceID, profileID: profileID,
            target: .thread(threadID), operations: [.resume], lifetime: 60)
        try await composition.activateSyntheticCodexControl(sourceID: sourceID, readGrant: statusGrant,
                                                           controlGrant: resumeGrant)
        do {
            let adapter = try #require(composition.adapter(for: sourceID))
            let eventsGrant = try await composition.issueReadGrant(
                authorizationID: .init(rawValue: "3301-events"), sourceID: sourceID, profileID: profileID,
                target: .thread(threadID), scopes: [.events], lifetime: 60)
            let oldCapture = External3301Capture()
            try await composition.subscribeSyntheticCodexEvents(sourceID: sourceID, threadID: threadID,
                                                               readGrant: eventsGrant, onEvent: { oldCapture.append($0) })
            let oldOwner = adapter.runtimeSnapshot.ownerID
            let previousGeneration = adapter.runtimeSnapshot.generation
            let status = try await adapter.status(target: .init(sourceID: sourceID, threadID: threadID), readGrant: statusGrant)
            let receipt = try await adapter.control(request: .init(sourceID: sourceID, threadID: threadID,
                operation: .resume, expectedCursor: status.observedCursor, idempotencyKey: "3301-once"), controlGrant: resumeGrant)
            #expect(receipt.outcome == .accepted || receipt.outcome == .completed)
            try Data().write(to: home.appendingPathComponent("allow-initial-terminal"))
            #expect(await waitUntil { adapter.runtimeSnapshot.eventCheckpoint?.eventID != nil && adapter.runtimeSnapshot.state == .connected })
            let previous = try #require(adapter.runtimeSnapshot.eventCheckpoint)
            #expect(await waitUntil { oldCapture.hasKind(.turnCompleted) })
            let oldPID = try ownedPID3301(home.appendingPathComponent("pid-old"), server: server)
            let originalOwner = try #require(oldOwner)
            let originalTerminal = try #require(oldCapture.eventKind(.turnCompleted))
            let checkpointBytes = try Data(contentsOf: runtimeFile)
            try Data().write(to: home.appendingPathComponent("old-eof"))
            try #require(await waitUntil { !composition.hasActiveCodexEventListener(for: sourceID) })
            try #require(await waitUntil { processGone3301(oldPID) },
                "The old owned process must really exit before runtime construction, not merely rotate its App owner")
            #expect(adapter.runtimeSnapshot.ownerID == nil)
            #expect(adapter.runtimeSnapshot.state == .disconnected)
            #expect(!adapter.runtimeSnapshot.requiresSideEffectReconciliation)
            #expect(adapter.runtimeSnapshot.eventCheckpoint == previous)
            let disconnectedBytes = try Data(contentsOf: runtimeFile)
            #expect(disconnectedBytes != checkpointBytes,
                "Actual EOF must persist the retired owner independently of the retained checkpoint")

            // Re-enter through the composition's production control factory.
            // It must preserve the clean checkpoint identity instead of minting
            // a new listener UUID for the replacement stream.
            try await composition.activateSyntheticCodexControl(
                sourceID: sourceID, readGrant: statusGrant, controlGrant: resumeGrant
            )
            let recovered = try #require(composition.adapter(for: sourceID))
            let newPID = try ownedPID3301(home.appendingPathComponent("pid-new"), server: server)
            #expect(newPID != oldPID)
            #expect(recovered.runtimeSnapshot.ownerID != nil)
            #expect(recovered.runtimeSnapshot.eventCheckpoint == previous)
            #expect(!recovered.runtimeSnapshot.requiresSideEffectReconciliation)
            let reconnected = recovered.runtimeSnapshot
            let newOwner = try #require(reconnected.ownerID)
            #expect(newOwner != oldOwner)
            #expect(reconnected.state == .connected)
            #expect(!reconnected.requiresSideEffectReconciliation)
            let capture = External3301Capture()
            try await composition.subscribeSyntheticCodexEvents(
                sourceID: sourceID, threadID: threadID, readGrant: eventsGrant,
                onEvent: { capture.append($0) }
            )
            // Composition returns only after the Core subscriber has been
            // admitted, so this marks the same readiness boundary that the
            // lower-level stream helper exposed through `onSubscribed`.
            capture.ready()
            #expect(await waitUntil { capture.isReady })
            let resumedStatus = try await recovered.status(
                target: .init(sourceID: sourceID, threadID: threadID), readGrant: statusGrant
            )
            _ = try await recovered.control(
                request: .init(sourceID: sourceID, threadID: threadID,
                    operation: .resume, expectedCursor: resumedStatus.observedCursor,
                    idempotencyKey: "3301-reconnect"), controlGrant: resumeGrant
            )
            try #require(await waitUntil { capture.has("item:new-1") })
            let accepted = try #require(recovered.runtimeSnapshot.eventCheckpoint)
            #expect(accepted.identity == previous.identity)
            #expect(accepted.sequence > previous.sequence)
            #expect(accepted.sourceCursor != previous.sourceCursor)
            let current = recovered.runtimeSnapshot
            let bytes = try Data(contentsOf: runtimeFile)
            // Both calls replay original decoded producer events. No synthetic
            // identity/event/output envelope is accepted as lifecycle evidence.
            #expect(try await recovered.consumeExternalEvent(originalTerminal,
                correlationID: previous.identity.correlationID, attemptID: previous.identity.attemptID,
                ownerID: originalOwner, connectionGeneration: previousGeneration,
                readGrant: eventsGrant) == .rejectedLateResult)
            let actualCurrent = try #require(capture.event("item:new-1"))
            #expect(try await recovered.consumeExternalEvent(actualCurrent,
                correlationID: previous.identity.correlationID, attemptID: previous.identity.attemptID,
                ownerID: newOwner, connectionGeneration: reconnected.generation,
                readGrant: eventsGrant) == .rejectedLateResult)
            #expect(recovered.runtimeSnapshot == current)
            #expect(try Data(contentsOf: runtimeFile) == bytes)
            #expect(capture.count(.turnCompleted) == 0)
            #expect(Darwin.kill(newPID, 0) == 0)
            _ = try await recovered.control(
                request: .init(sourceID: sourceID, threadID: threadID,
                    operation: .resume, expectedCursor: accepted.sourceCursor,
                    idempotencyKey: "3301-reconnect-2"), controlGrant: resumeGrant
            )
            #expect(await waitUntil { capture.has("item:new-2") })
            let continued = try #require(recovered.runtimeSnapshot.eventCheckpoint)
            #expect(continued.identity == previous.identity)
            #expect(continued.sequence > accepted.sequence)
            #expect(continued.sourceCursor != accepted.sourceCursor)
            // A current active attempt's actual EOF is still UNKNOWN; the stale
            // event fence must not suppress this positive loss-of-lease path.
            _ = await composition.revoke(sourceID: sourceID, profileID: profileID)
            #expect(await waitUntil { processGone3301(newPID) })
            #expect(recovered.runtimeSnapshot.ownerID == nil)
            #expect(recovered.runtimeSnapshot.state == .recoveryRequired)
            #expect(recovered.runtimeSnapshot.requiresSideEffectReconciliation)
            #expect(recovered.runtimeSnapshot.eventCheckpoint == continued)
            print("ACTUAL_RECOVERY_3301 old_pid=\(oldPID) old_os_gone_before_reopen=true fresh_pid=\(newPID) same_attempt=true actual_old_event_refused=true current_duplicate_refused=true current_eof_unknown=true new_os_gone=true")
        } catch {
            try? Data().write(to: home.appendingPathComponent("allow-initial-terminal"))
            try? Data().write(to: home.appendingPathComponent("old-eof"))
            _ = await composition.revoke(sourceID: sourceID, profileID: profileID)
            throw error
        }
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

private final class External3301Capture: @unchecked Sendable {
    private let lock = NSLock()
    private var subscribed = false
    private var events: [ExternalSessionEventV1] = []
    var isReady: Bool { lock.withLock { subscribed } }
    func ready() { lock.withLock { subscribed = true } }
    func append(_ event: ExternalSessionEventV1) { lock.withLock { events.append(event) } }
    func has(_ sourceRef: String) -> Bool { lock.withLock { events.contains { $0.sourceRef == sourceRef } } }
    func event(_ sourceRef: String) -> ExternalSessionEventV1? {
        lock.withLock { events.first { $0.sourceRef == sourceRef } }
    }
    func eventKind(_ kind: ExternalSessionEventKindV1) -> ExternalSessionEventV1? {
        lock.withLock { events.first { $0.kind == kind } }
    }
    func hasKind(_ kind: ExternalSessionEventKindV1) -> Bool {
        lock.withLock { events.contains { $0.kind == kind } }
    }
    func count(_ kind: ExternalSessionEventKindV1) -> Int {
        lock.withLock { events.filter { $0.kind == kind }.count }
    }
}

private func ownedPID3301(_ file: URL, server: URL) throws -> pid_t {
    let pid = try #require(pid_t(try String(contentsOf: file, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)))
    try #require(pid > 1 && pid != getpid() && Darwin.kill(pid, 0) == 0)
    let query = Process()
    query.executableURL = URL(fileURLWithPath: "/bin/ps")
    query.arguments = ["-ww", "-p", String(pid), "-o", "command="]
    let output = Pipe()
    query.standardOutput = output
    try query.run()
    query.waitUntilExit()
    let actual = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let expected = server.resolvingSymlinksInPath().standardizedFileURL.path
    let scripts = actual.split(whereSeparator: \.isWhitespace).filter {
        $0.hasPrefix("/") && URL(fileURLWithPath: String($0))
            .resolvingSymlinksInPath().standardizedFileURL.path == expected
    }
    try #require(query.terminationStatus == 0 && scripts.count == 1)
    var configured = stat()
    var observed = stat()
    let argument = try #require(scripts.first)
    try #require(Darwin.lstat(server.path, &configured) == 0)
    try #require(Darwin.lstat(String(argument), &observed) == 0)
    try #require(configured.st_dev == observed.st_dev && configured.st_ino == observed.st_ino)
    print("ACTUAL_OWNED_PROCESS_3301 pid=\(pid) argv=\(actual.trimmingCharacters(in: .whitespacesAndNewlines))")
    return pid
}

private func processGone3301(_ pid: pid_t) -> Bool {
    Darwin.kill(pid, 0) != 0 && errno == ESRCH
}
