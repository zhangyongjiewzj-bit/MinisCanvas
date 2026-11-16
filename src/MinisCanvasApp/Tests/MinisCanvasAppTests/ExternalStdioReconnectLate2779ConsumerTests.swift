import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-EXTH actual stdio same-attempt reconnect and late output")
@MainActor
struct ExternalStdioReconnectLate2779ConsumerTests {
    @Test func sameAttemptCheckpointContinuesAfterOldProcessLateAndDuplicateDelivery() async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "EXTH-2779")
        defer { try? profile.cleanupDisposableRoots() }
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
        old = '--owned-lease=new' not in sys.argv[1:]
        count = 0
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
                    # The retired process emits after the App has accepted a
                    # new owner's event. Its late output must not advance the
                    # persisted checkpoint or appear in either event capture.
                    print(json.dumps({'method':'item/started','params':{'threadId':thread,'turnId':'turn-completed','item':{'id':'late-old','type':'commandExecution'}}}), flush=True)
                    print(json.dumps({'method':'turn/completed','params':{'threadId':thread,'turn':{'id':'turn-completed','status':'completed'}}}), flush=True)
                    break
                count += 1
                print(json.dumps({'method':'item/started','params':{'threadId':thread,'turnId':'turn-new','item':{'id':'new-'+str(count),'type':'commandExecution'}}}), flush=True)
        """#.utf8).write(to: server)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: server.path)
        let composition = ProductionOrchestrationDefaults.makeExternalSessionAuthorization(runtimeConsumer: nil)
        composition.configureExternalSourceRegistration(hostID: "synthetic-2779")
        let sourceID = try composition.registerSelectedReadRoot(kind: .codex, rootURL: sessions)
        let profileID = try #require(composition.supervisedProfileID(for: sourceID))
        let runtimeDirectory = profile.rootDirectory.appendingPathComponent("external-session-runtime", isDirectory: true)
        let runtimeFile = runtimeDirectory.appendingPathComponent("\(sourceID.rawValue).json")
        try composition.configureSyntheticCodexControl(sourceID: sourceID, executableURL: server,
                                                      homeURL: home, runtimeDirectory: runtimeDirectory)
        let statusGrant = try await composition.issueReadGrant(
            authorizationID: .init(rawValue: "2779-status"), sourceID: sourceID, profileID: profileID,
            target: .source(sourceID), scopes: [.metadata, .status], lifetime: 60)
        _ = try await composition.activateSelectedReadRoot(sourceID: sourceID, readGrant: statusGrant)
        let resumeGrant = try await composition.issueControlGrant(
            authorizationID: .init(rawValue: "2779-resume"), sourceID: sourceID, profileID: profileID,
            target: .thread(threadID), operations: [.resume], lifetime: 60)
        try await composition.activateSyntheticCodexControl(sourceID: sourceID, readGrant: statusGrant,
                                                           controlGrant: resumeGrant)
        // The real transport deliberately filters custom environment keys.
        // Supply the synthetic peer's mode through its existing argv input.
        let replacement = try ExternalSessionCodexStdioConnection(executableURL: server,
            arguments: ["app-server", "--stdio", "--owned-lease=new"],
            environment: ["CODEX_HOME": home.path], workingDirectory: home)
        do {
            let adapter = try #require(composition.adapter(for: sourceID))
            let eventsGrant = try await composition.issueReadGrant(
                authorizationID: .init(rawValue: "2779-events"), sourceID: sourceID, profileID: profileID,
                target: .thread(threadID), scopes: [.events], lifetime: 60)
            let oldCapture = External2779Capture()
            try await composition.subscribeSyntheticCodexEvents(sourceID: sourceID, threadID: threadID,
                                                               readGrant: eventsGrant, onEvent: { oldCapture.append($0) })
            let oldOwner = adapter.runtimeSnapshot.ownerID
            let status = try await adapter.status(target: .init(sourceID: sourceID, threadID: threadID), readGrant: statusGrant)
            let receipt = try await adapter.control(request: .init(sourceID: sourceID, threadID: threadID,
                operation: .resume, expectedCursor: status.observedCursor, idempotencyKey: "2779-once"), controlGrant: resumeGrant)
            #expect(receipt.outcome == .accepted || receipt.outcome == .completed)
            try Data().write(to: home.appendingPathComponent("allow-initial-terminal"))
            #expect(await waitUntil { adapter.runtimeSnapshot.eventCheckpoint?.eventID != nil && adapter.runtimeSnapshot.state == .connected })
            let previous = try #require(adapter.runtimeSnapshot.eventCheckpoint)
            #expect(await waitUntil { oldCapture.hasKind(.turnCompleted) })
            let reconnected = try await adapter.reconnect(readGrant: statusGrant)
            let newOwner = try #require(reconnected.ownerID)
            #expect(newOwner != oldOwner)
            #expect(reconnected.state == .connected)
            #expect(!reconnected.requiresSideEffectReconciliation)
            try await replacement.connect()
            #expect(await replacement.isReady())
            let capture = External2779Capture()
            let worker = Task {
                try await adapter.streamCodexNotifications(from: replacement, threadID: threadID,
                    correlationID: previous.identity.correlationID, attemptID: previous.identity.attemptID,
                    ownerID: newOwner, readGrant: eventsGrant, onEvent: { capture.append($0) },
                    onSubscribed: { capture.ready() })
            }
            #expect(await waitUntil { capture.isReady })
            _ = try await replacement.request(method: "thread/resume", params: ["threadId": .string(thread)])
            #expect(await waitUntil { capture.has("item:new-1") })
            let beforeOldEOF = adapter.runtimeSnapshot
            let beforeCheckpoint = try #require(beforeOldEOF.eventCheckpoint)
            #expect(beforeOldEOF.eventCheckpoint?.identity == previous.identity)
            #expect(beforeCheckpoint.sequence > previous.sequence)
            #expect(beforeCheckpoint.sourceCursor != previous.sourceCursor)
            let acceptedNewEvent = try #require(capture.event("item:new-1"))
            let acceptedBeforeDuplicate = try Data(contentsOf: runtimeFile)
            #expect(try await adapter.consumeExternalEvent(
                acceptedNewEvent,
                correlationID: previous.identity.correlationID,
                attemptID: previous.identity.attemptID,
                ownerID: newOwner,
                connectionGeneration: reconnected.generation,
                readGrant: eventsGrant
            ) == .rejectedLateResult)
            #expect(try Data(contentsOf: runtimeFile) == acceptedBeforeDuplicate)
            try Data().write(to: home.appendingPathComponent("old-eof"))
            // Listener removal happens only after its adapter stream returns.
            #expect(await waitUntil { !composition.hasActiveCodexEventListener(for: sourceID) })
            #expect(adapter.runtimeSnapshot.ownerID == newOwner)
            #expect(adapter.runtimeSnapshot.generation == reconnected.generation)
            #expect(adapter.runtimeSnapshot.state == .connected)
            #expect(!adapter.runtimeSnapshot.requiresSideEffectReconciliation)
            #expect(adapter.runtimeSnapshot.eventCheckpoint == beforeOldEOF.eventCheckpoint)
            #expect(try Data(contentsOf: runtimeFile) == acceptedBeforeDuplicate)
            #expect(!oldCapture.has("item:late-old"))
            #expect(!capture.has("item:late-old"))
            #expect(oldCapture.count(.turnCompleted) == 1)
            _ = try await replacement.request(method: "thread/resume", params: ["threadId": .string(thread)])
            #expect(await waitUntil { capture.has("item:new-2") })
            let resumedCheckpoint = try #require(adapter.runtimeSnapshot.eventCheckpoint)
            #expect(resumedCheckpoint.identity == previous.identity)
            #expect(resumedCheckpoint.sequence > beforeCheckpoint.sequence)
            #expect(resumedCheckpoint.sourceCursor != beforeCheckpoint.sourceCursor)
            // The current lease's real EOF must still retain UNKNOWN, rather
            // than being suppressed by the stale-listener safety fence.
            await replacement.close()
            try await worker.value
            #expect(adapter.runtimeSnapshot.ownerID == nil)
            #expect(adapter.runtimeSnapshot.state == .recoveryRequired)
            #expect(adapter.runtimeSnapshot.requiresSideEffectReconciliation)
            #expect(adapter.runtimeSnapshot.eventCheckpoint == resumedCheckpoint)
        } catch {
            try? Data().write(to: home.appendingPathComponent("allow-initial-terminal"))
            try? Data().write(to: home.appendingPathComponent("old-eof"))
            await replacement.close()
            _ = await composition.revoke(sourceID: sourceID, profileID: profileID)
            throw error
        }
        _ = await composition.revoke(sourceID: sourceID, profileID: profileID)
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

private final class External2779Capture: @unchecked Sendable {
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
    func hasKind(_ kind: ExternalSessionEventKindV1) -> Bool {
        lock.withLock { events.contains { $0.kind == kind } }
    }
    func count(_ kind: ExternalSessionEventKindV1) -> Int {
        lock.withLock { events.filter { $0.kind == kind }.count }
    }
}
