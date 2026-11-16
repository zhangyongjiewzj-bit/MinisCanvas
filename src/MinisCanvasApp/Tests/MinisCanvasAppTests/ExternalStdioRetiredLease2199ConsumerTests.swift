import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-EXTH actual stdio retired lease EOF")
@MainActor
struct ExternalStdioRetiredLease2199ConsumerTests {
    @Test func oldListenerEOFDoesNotDisconnectReconnectedSameAttempt() async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "EXTI-2199")
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
                    break
                count += 1
                print(json.dumps({'method':'item/started','params':{'threadId':thread,'turnId':'turn-new','item':{'id':'new-'+str(count),'type':'commandExecution'}}}), flush=True)
        """#.utf8).write(to: server)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: server.path)
        let composition = ProductionOrchestrationDefaults.makeExternalSessionAuthorization(runtimeConsumer: nil)
        composition.configureExternalSourceRegistration(hostID: "synthetic-2199")
        let sourceID = try composition.registerSelectedReadRoot(kind: .codex, rootURL: sessions)
        let profileID = try #require(composition.supervisedProfileID(for: sourceID))
        let runtimeDirectory = profile.rootDirectory.appendingPathComponent("external-session-runtime", isDirectory: true)
        try composition.configureSyntheticCodexControl(sourceID: sourceID, executableURL: server,
                                                      homeURL: home, runtimeDirectory: runtimeDirectory)
        let statusGrant = try await composition.issueReadGrant(
            authorizationID: .init(rawValue: "2199-status"), sourceID: sourceID, profileID: profileID,
            target: .source(sourceID), scopes: [.metadata, .status], lifetime: 60)
        _ = try await composition.activateSelectedReadRoot(sourceID: sourceID, readGrant: statusGrant)
        let resumeGrant = try await composition.issueControlGrant(
            authorizationID: .init(rawValue: "2199-resume"), sourceID: sourceID, profileID: profileID,
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
                authorizationID: .init(rawValue: "2199-events"), sourceID: sourceID, profileID: profileID,
                target: .thread(threadID), scopes: [.events], lifetime: 60)
            try await composition.subscribeSyntheticCodexEvents(sourceID: sourceID, threadID: threadID,
                                                               readGrant: eventsGrant)
            let oldOwner = adapter.runtimeSnapshot.ownerID
            let status = try await adapter.status(target: .init(sourceID: sourceID, threadID: threadID), readGrant: statusGrant)
            _ = try await adapter.control(request: .init(sourceID: sourceID, threadID: threadID,
                operation: .resume, expectedCursor: status.observedCursor, idempotencyKey: "2199-once"), controlGrant: resumeGrant)
            try Data().write(to: home.appendingPathComponent("allow-initial-terminal"))
            #expect(await waitUntil { adapter.runtimeSnapshot.eventCheckpoint?.eventID != nil && adapter.runtimeSnapshot.state == .connected })
            let previous = try #require(adapter.runtimeSnapshot.eventCheckpoint)
            let reconnected = try await adapter.reconnect(readGrant: statusGrant)
            let newOwner = try #require(reconnected.ownerID)
            #expect(newOwner != oldOwner)
            #expect(reconnected.state == .connected)
            #expect(!reconnected.requiresSideEffectReconciliation)
            try await replacement.connect()
            #expect(await replacement.isReady())
            let capture = External2199Capture()
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
            try Data().write(to: home.appendingPathComponent("old-eof"))
            // Listener removal happens only after its adapter stream returns.
            #expect(await waitUntil { !composition.hasActiveCodexEventListener(for: sourceID) })
            #expect(adapter.runtimeSnapshot.ownerID == newOwner)
            #expect(adapter.runtimeSnapshot.generation == reconnected.generation)
            #expect(adapter.runtimeSnapshot.state == .connected)
            #expect(!adapter.runtimeSnapshot.requiresSideEffectReconciliation)
            #expect(adapter.runtimeSnapshot.eventCheckpoint == beforeOldEOF.eventCheckpoint)
            _ = try await replacement.request(method: "thread/resume", params: ["threadId": .string(thread)])
            #expect(await waitUntil { capture.has("item:new-2") })
            let resumedCheckpoint = try #require(adapter.runtimeSnapshot.eventCheckpoint)
            #expect(resumedCheckpoint.identity == previous.identity)
            #expect(resumedCheckpoint.sequence > beforeCheckpoint.sequence)
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

private final class External2199Capture: @unchecked Sendable {
    private let lock = NSLock()
    private var subscribed = false
    private var events: [ExternalSessionEventV1] = []
    var isReady: Bool { lock.withLock { subscribed } }
    func ready() { lock.withLock { subscribed = true } }
    func append(_ event: ExternalSessionEventV1) { lock.withLock { events.append(event) } }
    func has(_ sourceRef: String) -> Bool { lock.withLock { events.contains { $0.sourceRef == sourceRef } } }
}
