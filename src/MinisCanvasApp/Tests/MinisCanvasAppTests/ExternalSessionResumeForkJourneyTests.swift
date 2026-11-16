import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// B4 D-EXTD: production App composition + a separately spawned owned stdio
/// app-server. No provider credentials, real rollouts, UI, or substitute transport.
@Suite("D-EXTD existing synthetic session resume and fork over app-server process")
@MainActor
struct ExternalSessionResumeForkJourneyTests {
    @Test(arguments: ["resume", "fork"])
    func existingSessionResumeAndForkCrossOwnedAppServer(operationName: String) async throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let profile = try RuntimeIsolationProfile.resolveLaunchProfile()
        #expect(profile.rootDirectory == formal.rootDirectory)
        let rootDirectory = profile.rootDirectory.appendingPathComponent("EXTD-Journey-" + operationName + "-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        // Preserve the owned fixture for formal wire/source/original-history review.
        print("EXTD_OWNED_FIXTURE root=\(rootDirectory.path) operation=\(operationName)")
        let home = rootDirectory.appendingPathComponent("owned-home", isDirectory: true)
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        let day = sessions.appendingPathComponent("2026/10/01", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let parent = "12345678-1234-1234-1234-123456789abc"
        let child = "87654321-1234-1234-1234-123456789abc"
        let threadID = ExternalSessionThreadID(rawValue: parent)
        let rollout = day.appendingPathComponent("rollout-2026-10-01T00-00-00-\(parent).jsonl")
        let original = Data("""
        {"timestamp":"2026-10-01T00:00:00Z","type":"session_meta","payload":{"id":"\(parent)","cwd":"/synthetic/project","cli_version":"0.151.0"}}
        {"timestamp":"2026-10-01T00:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"owned-existing-history"}]}}
        """.utf8)
        try original.write(to: rollout)
        let wire = home.appendingPathComponent("wire.jsonl")
        let server = rootDirectory.appendingPathComponent("owned-app-server.py")
        try Data(#"""
        #!/usr/bin/python3
        import json, os, sys
        home = os.environ['CODEX_HOME']
        parent = '12345678-1234-1234-1234-123456789abc'
        child = '87654321-1234-1234-1234-123456789abc'
        day = os.path.join(home, 'sessions', '2026', '10', '01')
        original = os.path.join(day, 'rollout-2026-10-01T00-00-00-'+parent+'.jsonl')
        existing = json.loads(open(original).readline())['payload']['id']
        initialized = False
        def record(direction, value):
            with open(os.path.join(home, 'wire.jsonl'), 'a') as f:
                f.write(json.dumps({'pid':os.getpid(),'direction':direction,'message':value})+'\n')
                f.flush()
                os.fsync(f.fileno())
        def emit(value):
            record('response', value)
            print(json.dumps(value), flush=True)
        for line in sys.stdin:
            req = json.loads(line)
            record('request', req)
            method = req.get('method')
            rid = req.get('id')
            if method == 'initialize':
                emit({'id':rid,'result':{'userAgent':'miniscanvas/0.151.0 (synthetic)','platformFamily':'unix','platformOs':'macos'}})
            elif method == 'initialized':
                initialized = True
            elif method in ('thread/resume', 'thread/fork'):
                if not initialized or req['params']['threadId'] != existing:
                    emit({'id':rid,'error':{'code':-32000,'message':'existing session required'}})
                    continue
                if method == 'thread/resume':
                    emit({'id':rid,'result':{'thread':{'id':existing}}})
                else:
                    target = os.path.join(day, 'rollout-2026-10-01T00-00-02-'+child+'.jsonl')
                    with open(target, 'w') as f:
                        f.write(json.dumps({'timestamp':'2026-10-01T00:00:02Z','type':'session_meta','payload':{'id':child,'cwd':'/synthetic/project','cli_version':'0.151.0','forked_from_id':existing}})+'\n')
                        f.flush()
                        os.fsync(f.fileno())
                    emit({'id':rid,'result':{'thread':{'id':child,'forkedFromId':existing}}})
                    emit({'method':'thread/started','params':{'thread':{'id':child}}})
            elif rid is not None:
                emit({'id':rid,'error':{'code':-32000,'message':'unsupported'}})
        """#.utf8).write(to: server)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: server.path)
        let composition = ProductionOrchestrationDefaults.makeExternalSessionAuthorization(runtimeConsumer: nil)
        composition.configureExternalSourceRegistration(hostID: "owned-extd-host")
        let sourceID = try composition.registerSelectedReadRoot(kind: .codex, rootURL: sessions)
        let profileID = try #require(composition.supervisedProfileID(for: sourceID))
        try composition.configureSyntheticCodexControl(sourceID: sourceID, executableURL: server,
            homeURL: home, runtimeDirectory: rootDirectory.appendingPathComponent("runtime", isDirectory: true))
        let readGrant = try await composition.issueReadGrant(authorizationID: .init(rawValue: "extd-read"),
            sourceID: sourceID, profileID: profileID, target: .source(sourceID),
            scopes: [.metadata, .messages, .status], lifetime: 120)
        _ = try await composition.activateSelectedReadRoot(sourceID: sourceID, readGrant: readGrant)
        let readAdapter = try #require(composition.adapter(for: sourceID))
        let before = try await readAdapter.listThreads(query: .init(sourceID: sourceID, limit: 10), readGrant: readGrant)
        #expect(before.threads.map(\.threadID) == [threadID])
        let operation: ExternalSessionControlOperationV1 = operationName == "resume" ? .resume : .fork
        let grant = try await composition.issueControlGrant(authorizationID: .init(rawValue: "extd-control"),
            sourceID: sourceID, profileID: profileID, target: .thread(threadID),
            operations: [operation], lifetime: 120)
        do {
            try await composition.activateSyntheticCodexControl(sourceID: sourceID, readGrant: readGrant, controlGrant: grant)
            let adapter = try #require(composition.adapter(for: sourceID))
            let status = try await adapter.status(target: .init(sourceID: sourceID, threadID: threadID), readGrant: readGrant)
            let receipt = try await adapter.control(request: .init(sourceID: sourceID, threadID: threadID,
                operation: operation, expectedCursor: status.observedCursor, idempotencyKey: "extd-once-"+operationName),
                controlGrant: grant)
            #expect(receipt.sourceID == sourceID)
            #expect(receipt.threadID == threadID)
            #expect(receipt.operation == operation)
            #expect(receipt.outcome == (operation == .resume ? .accepted : .completed))
            #expect(receipt.childThreadID == (operation == .fork ? .init(rawValue: child) : nil))
            #expect(try Data(contentsOf: rollout) == original)
            let lines = try String(contentsOf: wire, encoding: .utf8).split(separator: "\n")
            let rows = try lines.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
            let calls = rows.filter { ($0["direction"] as? String) == "request" && (($0["message"] as? [String: Any])?["method"] as? String) == "thread/"+operationName }
            let call = try #require(calls.first)
            #expect(calls.count == 1)
            let request = try #require(call["message"] as? [String: Any])
            #expect((request["params"] as? [String: Any])?["threadId"] as? String == parent)
            let responses = rows.filter { row in
                guard row["direction"] as? String == "response",
                    let message = row["message"] as? [String: Any],
                    let id = message["id"] as? NSNumber, let requestID = request["id"] as? NSNumber else { return false }
                return id == requestID
            }
            #expect(responses.count == 1)
            let result = try #require((responses.first?["message"] as? [String: Any])?["result"] as? [String: Any])
            let responseThread = try #require(result["thread"] as? [String: Any])
            #expect(responseThread["id"] as? String == (operation == .fork ? child : parent))
            if operation == .fork {
                #expect(responseThread["forkedFromId"] as? String == parent)
                #expect(FileManager.default.fileExists(atPath: day.appendingPathComponent("rollout-2026-10-01T00-00-02-\(child).jsonl").path))
            }
            let pid = try #require(call["pid"] as? NSNumber)
            #expect(pid.int32Value != ProcessInfo.processInfo.processIdentifier)
            print("EXTD_WIRE_BEGIN operation=\(operationName) child_pid=\(pid)")
            print(try String(contentsOf: wire, encoding: .utf8))
            print("EXTD_WIRE_END operation=\(operationName) original_unchanged=true")
            _ = await composition.revoke(sourceID: sourceID, profileID: profileID)
            #expect(adapter.runtimeSnapshot.state == .disconnected)
        } catch {
            _ = await composition.revoke(sourceID: sourceID, profileID: profileID)
            throw error
        }
    }
}
