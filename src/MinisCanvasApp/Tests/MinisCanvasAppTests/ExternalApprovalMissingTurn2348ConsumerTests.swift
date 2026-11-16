import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-EXTF actual stdio approval without a turn identity")
@MainActor
struct ExternalApprovalMissingTurn2348ConsumerTests {
    @Test func foreignTerminalCannotClearTurnlessPendingApproval() async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "EXTF-2348")
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
        thread = '12345678-1234-1234-1234-123456789abc'
        for line in sys.stdin:
            req = json.loads(line)
            method = req.get('method')
            rid = req.get('id')
            if method == 'initialized':
                continue
            if method == 'initialize':
                print(json.dumps({'id':rid,'result':{'userAgent':'miniscanvas/0.151.0 (synthetic)','platformFamily':'unix','platformOs':'macos'}}), flush=True)
            elif method == 'thread/resume':
                with open(os.path.join(home, 'resume-requests'), 'a') as marker:
                    marker.write('received\n')
                print(json.dumps({'id':rid,'result':{'thread':{'id':thread}}}), flush=True)
                # This validly framed JSON-RPC request has no turnId. It must
                # not let a later, unrelated turn close this pending approval.
                print(json.dumps({'id':701,'method':'item/commandExecution/requestApproval',
                                  'params':{'threadId':thread,'itemId':'command-unbound'}}), flush=True)
                while not os.path.exists(os.path.join(home, 'send-foreign')):
                    time.sleep(0.01)
                print(json.dumps({'method':'turn/completed','params':{
                    'threadId':thread,'turn':{'id':'foreign-turn','status':'completed'}}}), flush=True)
                print(json.dumps({'method':'item/started','params':{
                    'threadId':thread,'turnId':'foreign-turn','item':{'id':'after-foreign','type':'commandExecution'}}}), flush=True)
                with open(os.path.join(home, 'foreign-written'), 'w') as marker:
                    marker.write('sent')
                while not os.path.exists(os.path.join(home, 'allow-exit')):
                    time.sleep(0.01)
        """#.utf8).write(to: server)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: server.path)

        let composition = ProductionOrchestrationDefaults.makeExternalSessionAuthorization(runtimeConsumer: nil)
        composition.configureExternalSourceRegistration(hostID: "synthetic-2348")
        let sourceID = try composition.registerSelectedReadRoot(kind: .codex, rootURL: sessions)
        let profileID = try #require(composition.supervisedProfileID(for: sourceID))
        try composition.configureSyntheticCodexControl(
            sourceID: sourceID, executableURL: server, homeURL: home,
            runtimeDirectory: profile.rootDirectory.appendingPathComponent("external-session-runtime", isDirectory: true)
        )
        let statusGrant = try await composition.issueReadGrant(
            authorizationID: .init(rawValue: "2348-status"), sourceID: sourceID,
            profileID: profileID, target: .source(sourceID), scopes: [.metadata, .status], lifetime: 60
        )
        _ = try await composition.activateSelectedReadRoot(sourceID: sourceID, readGrant: statusGrant)
        let resumeGrant = try await composition.issueControlGrant(
            authorizationID: .init(rawValue: "2348-resume"), sourceID: sourceID,
            profileID: profileID, target: .thread(threadID), operations: [.resume], lifetime: 60
        )
        try await composition.activateSyntheticCodexControl(
            sourceID: sourceID, readGrant: statusGrant, controlGrant: resumeGrant
        )
        do {
            let adapter = try #require(composition.adapter(for: sourceID))
            let eventsGrant = try await composition.issueReadGrant(
                authorizationID: .init(rawValue: "2348-events"), sourceID: sourceID,
                profileID: profileID, target: .thread(threadID), scopes: [.events], lifetime: 60
            )
            let capture = External2348EventCapture()
            try await composition.subscribeSyntheticCodexEvents(
                sourceID: sourceID, threadID: threadID, readGrant: eventsGrant,
                onEvent: { capture.append($0) }
            )
            let status = try await adapter.status(
                target: .init(sourceID: sourceID, threadID: threadID), readGrant: statusGrant
            )
            let receipt = try await adapter.control(
                request: .init(sourceID: sourceID, threadID: threadID, operation: .resume,
                               expectedCursor: status.observedCursor, idempotencyKey: "2348-resume-once"),
                controlGrant: resumeGrant
            )
            #expect(receipt.outcome == .accepted)
            #expect(await waitUntil {
                adapter.runtimeSnapshot.pendingApproval?.requestID == "i:701"
                    || adapter.runtimeSnapshot.requiresSideEffectReconciliation
            })
            let checkpointBefore = adapter.runtimeSnapshot.eventCheckpoint
            try Data().write(to: home.appendingPathComponent("send-foreign"))
            #expect(await waitUntil {
                FileManager.default.fileExists(atPath: home.appendingPathComponent("foreign-written").path)
            })
            // The child remains alive. Wait for the ordered downstream event,
            // or a fail-closed recovery transition; EOF cannot make this pass.
            #expect(await waitUntil {
                capture.hasSourceRef("item:after-foreign")
                    || adapter.runtimeSnapshot.state != .waitingApproval
            })
            let after = adapter.runtimeSnapshot
            #expect(after.state == .waitingApproval || after.state == .recoveryRequired)
            #expect(after.pendingApproval != nil || after.requiresSideEffectReconciliation)
            #expect(!capture.hasTerminal(turnID: "foreign-turn"))
            #expect(after.eventCheckpoint?.eventID != checkpointBefore?.eventID
                    || after.requiresSideEffectReconciliation)
            let requests = try String(contentsOf: home.appendingPathComponent("resume-requests"), encoding: .utf8)
            #expect(requests.split(separator: "\n").count == 1)
            try Data().write(to: home.appendingPathComponent("allow-exit"))
            _ = await composition.revoke(sourceID: sourceID, profileID: profileID)
        } catch {
            try? Data().write(to: home.appendingPathComponent("allow-exit"))
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

private final class External2348EventCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ExternalSessionEventV1] = []
    func append(_ event: ExternalSessionEventV1) { lock.withLock { events.append(event) } }
    func hasSourceRef(_ reference: String) -> Bool {
        lock.withLock { events.contains { $0.sourceRef == reference } }
    }
    func hasTerminal(turnID: String) -> Bool {
        lock.withLock {
            events.contains { $0.turnID?.rawValue == turnID
                && [.turnCompleted, .turnFailed, .turnCancelled].contains($0.kind) }
        }
    }
}
