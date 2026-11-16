import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-EXTF actual stdio pending approval turn scope")
@MainActor
struct ExternalApprovalForeignTurn2175ConsumerTests {
    @Test(arguments: ["completed", "failed", "interrupted"])
    func foreignTurnTerminalKeepsApprovalBoundToOriginalTurn(_ foreignStatus: String) async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "EXTF-2175")
        defer { try? profile.cleanupDisposableRoots() }
        let home = profile.rootDirectory.appendingPathComponent("owned-codex-home", isDirectory: true)
        defer {
            try? Data().write(to: home.appendingPathComponent("send-foreign"))
            try? Data().write(to: home.appendingPathComponent("release-resolution"))
            try? Data().write(to: home.appendingPathComponent("send-late"))
        }
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        let day = sessions.appendingPathComponent("2026/10/04", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let thread = "12345678-1234-1234-1234-123456789abc"
        let threadID = ExternalSessionThreadID(rawValue: thread)
        try Data("""
        {"timestamp":"2026-10-04T00:00:00Z","type":"session_meta","payload":{"id":"\(thread)","cwd":"/synthetic/project","cli_version":"0.151.0"}}
        """.utf8).write(to: day.appendingPathComponent("rollout-2026-10-04T00-00-00-\(thread).jsonl"))
        let server = profile.rootDirectory.appendingPathComponent("synthetic-codex-server.py")
        let script = #"""
        #!/usr/bin/python3 -IS
        import json, os, sys, time
        home = os.environ['CODEX_HOME']
        thread = None
        for line in sys.stdin:
            req = json.loads(line)
            method = req.get('method')
            rid = req.get('id')
            if method == 'initialized':
                continue
            if method == 'initialize':
                print(json.dumps({'id':rid,'result':{'userAgent':'miniscanvas/0.151.0 (synthetic)','platformFamily':'unix','platformOs':'macos'}}), flush=True)
            elif method == 'thread/resume':
                thread = req['params']['threadId']
                print(json.dumps({'id':rid,'result':{'thread':{'id':thread}}}), flush=True)
                print(json.dumps({'id':701,'method':'item/commandExecution/requestApproval','params':{'threadId':thread,'turnId':'turn-current','itemId':'command-current'}}), flush=True)
                while not os.path.exists(os.path.join(home, 'send-foreign')):
                    time.sleep(0.01)
                print(json.dumps({'method':'turn/completed','params':{'threadId':thread,'turn':{'id':'turn-old','status':'FOREIGN_STATUS'}}}), flush=True)
                print(json.dumps({'method':'item/started','params':{'threadId':thread,'turnId':'turn-current','item':{'id':'after-foreign','type':'commandExecution'}}}), flush=True)
                print(json.dumps({'method':'item/agentMessage/delta','params':{'threadId':thread,'turnId':'turn-current','itemId':'pause-message','delta':'safe pause'}}), flush=True)
                print(json.dumps({'method':'item/completed','params':{'threadId':thread,'turnId':'turn-current','item':{'id':'pause-message','type':'agentMessage','text':'safe pause'}}}), flush=True)
            elif method is None and rid == 701:
                with open(os.path.join(home, 'owned-response.json'), 'w') as f:
                    json.dump(req['result'], f)
                while not os.path.exists(os.path.join(home, 'release-resolution')):
                    time.sleep(0.01)
                print(json.dumps({'method':'serverRequest/resolved','params':{'threadId':thread,'requestId':701}}), flush=True)
                print(json.dumps({'method':'turn/completed','params':{'threadId':thread,'turn':{'id':'turn-current','status':'completed'}}}), flush=True)
                while not os.path.exists(os.path.join(home, 'send-late')):
                    time.sleep(0.01)
                print(json.dumps({'id':701,'method':'item/commandExecution/requestApproval','params':{'threadId':thread,'turnId':'turn-current','itemId':'late-command'}}), flush=True)
                print(json.dumps({'method':'item/started','params':{'threadId':thread,'turnId':'turn-current','item':{'id':'late-item','type':'commandExecution'}}}), flush=True)
                sys.exit(0)
        """#
        try Data(script.replacingOccurrences(of: "FOREIGN_STATUS", with: foreignStatus).utf8).write(to: server)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: server.path)
        let composition = ProductionOrchestrationDefaults.makeExternalSessionAuthorization(runtimeConsumer: nil)
        composition.configureExternalSourceRegistration(hostID: "synthetic-2175")
        let sourceID = try composition.registerSelectedReadRoot(kind: .codex, rootURL: sessions)
        let profileID = try #require(composition.supervisedProfileID(for: sourceID))
        let runtimeDirectory = profile.rootDirectory.appendingPathComponent("external-session-runtime", isDirectory: true)
        try composition.configureSyntheticCodexControl(sourceID: sourceID, executableURL: server,
                                                      homeURL: home, runtimeDirectory: runtimeDirectory)
        let statusGrant = try await composition.issueReadGrant(
            authorizationID: .init(rawValue: "2175-status"), sourceID: sourceID, profileID: profileID,
            target: .source(sourceID), scopes: [.metadata, .status], lifetime: 60)
        _ = try await composition.activateSelectedReadRoot(sourceID: sourceID, readGrant: statusGrant)
        let resumeGrant = try await composition.issueControlGrant(
            authorizationID: .init(rawValue: "2175-resume"), sourceID: sourceID, profileID: profileID,
            target: .thread(threadID), operations: [.resume], lifetime: 60)
        try await composition.activateSyntheticCodexControl(sourceID: sourceID, readGrant: statusGrant,
                                                           controlGrant: resumeGrant)
        do {
            let adapter = try #require(composition.adapter(for: sourceID))
            let eventsGrant = try await composition.issueReadGrant(
                authorizationID: .init(rawValue: "2175-events"), sourceID: sourceID, profileID: profileID,
                target: .thread(threadID), scopes: [.events], lifetime: 60)
            let capture = External2175EventCapture()
            try await composition.subscribeSyntheticCodexEvents(sourceID: sourceID, threadID: threadID,
                                                               readGrant: eventsGrant, onEvent: { capture.append($0) })
            let status = try await adapter.status(target: .init(sourceID: sourceID, threadID: threadID),
                                                  readGrant: statusGrant)
            _ = try await adapter.control(request: .init(sourceID: sourceID, threadID: threadID,
                operation: .resume, expectedCursor: status.observedCursor, idempotencyKey: "2175-once"),
                controlGrant: resumeGrant)
            #expect(await waitUntil { adapter.runtimeSnapshot.state == .waitingApproval })
            let original = try #require(adapter.runtimeSnapshot.pendingApproval)
            #expect(original.turnID?.rawValue == "turn-current")
            #expect(original.requestID == "i:701")
            try Data().write(to: home.appendingPathComponent("send-foreign"))
            // The following same-turn progress is a real downstream barrier:
            // rejection must retain the live attempt so this event is delivered.
            #expect(await waitUntil { capture.hasSourceRef("item:after-foreign") })
            #expect(adapter.runtimeSnapshot.state == .waitingApproval)
            #expect(adapter.runtimeSnapshot.pendingApproval == original)
            #expect(!capture.hasTerminal(turnID: "turn-old"))
            #expect(await waitUntil { capture.hasItemDelta("safe pause") })
            #expect(adapter.runtimeSnapshot.eventCheckpoint?.eventID != nil)
            // Original matching request and turn must still complete normally.
            let approveGrant = try await composition.issueControlGrant(
                authorizationID: .init(rawValue: "2175-approve"), sourceID: sourceID, profileID: profileID,
                target: .thread(threadID), operations: [.approve], lifetime: 60)
            try await composition.respondToSyntheticCodexApproval(sourceID: sourceID, decision: .approve,
                                                                  controlGrant: approveGrant)
            #expect(adapter.runtimeSnapshot.state == .waitingApproval)
            #expect(adapter.runtimeSnapshot.pendingApproval?.responseAttempted == true)
            // The same live request remains paused until the server resolves
            // it. A second local approval must not emit a second response.
            await #expect(throws: ExternalSessionAppAdapterError.runtimeUnavailable) {
                try await composition.respondToSyntheticCodexApproval(
                    sourceID: sourceID, decision: .approve, controlGrant: approveGrant
                )
            }
            try Data().write(to: home.appendingPathComponent("release-resolution"))
            #expect(await waitUntil {
                adapter.runtimeSnapshot.state == .connected && adapter.runtimeSnapshot.pendingApproval == nil
                    && capture.hasTerminal(turnID: "turn-current")
            })
            #expect(!adapter.runtimeSnapshot.requiresSideEffectReconciliation)
            let replyData = try Data(contentsOf: home.appendingPathComponent("owned-response.json"))
            let reply = try #require(JSONSerialization.jsonObject(with: replyData) as? [String: String])
            #expect(reply == ["decision": "accept"])
            let completedCheckpoint = try #require(adapter.runtimeSnapshot.eventCheckpoint)
            let deliveredCount = capture.count
            try Data().write(to: home.appendingPathComponent("send-late"))
            #expect(await waitUntil { adapter.runtimeSnapshot.state == .disconnected })
            #expect(capture.count == deliveredCount)
            #expect(adapter.runtimeSnapshot.eventCheckpoint == completedCheckpoint)
            #expect(!capture.hasSourceRef("item:late-command"))
            #expect(!capture.hasSourceRef("item:late-item"))
            let persisted = try Data(contentsOf: runtimeDirectory.appendingPathComponent("\(sourceID.rawValue).json"))
            let object = try #require(JSONSerialization.jsonObject(with: persisted) as? [String: Any])
            #expect(object["pendingApproval"] == nil)
        } catch {
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

private final class External2175EventCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ExternalSessionEventV1] = []
    func append(_ event: ExternalSessionEventV1) { lock.withLock { events.append(event) } }
    var count: Int { lock.withLock { events.count } }
    func hasSourceRef(_ reference: String) -> Bool { lock.withLock { events.contains { $0.sourceRef == reference } } }
    func hasItemDelta(_ text: String) -> Bool {
        lock.withLock { events.contains { $0.kind == .itemDelta && $0.payload.summary.contains(text) } }
    }
    func hasTerminal(turnID: String) -> Bool {
        lock.withLock {
            events.contains { $0.turnID?.rawValue == turnID && [.turnCompleted, .turnFailed, .turnCancelled].contains($0.kind) }
        }
    }
}
