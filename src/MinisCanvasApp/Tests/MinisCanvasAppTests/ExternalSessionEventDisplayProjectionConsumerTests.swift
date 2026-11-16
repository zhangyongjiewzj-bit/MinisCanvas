import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-EXTF authorized external delta display")
@MainActor
struct ExternalSessionEventDisplayProjectionConsumerTests {
    @Test func realCompositionDeliversOnlyRedactedCurrentSubscriptionChunks() async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "EXTF-display")
        defer { try? profile.cleanupDisposableRoots() }
        let home = profile.rootDirectory.appendingPathComponent("owned-codex-home", isDirectory: true)
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        let day = sessions.appendingPathComponent("2026/10/01", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let thread = "12345678-1234-1234-1234-123456789abc"
        let threadID = ExternalSessionThreadID(rawValue: thread)
        try Data("""
        {"timestamp":"2026-10-01T00:00:00Z","type":"session_meta","payload":{"id":"\(thread)","cwd":"/synthetic/project","cli_version":"0.151.0"}}
        """.utf8).write(to: day.appendingPathComponent("rollout-2026-10-01T00-00-00-\(thread).jsonl"))
        let server = profile.rootDirectory.appendingPathComponent("synthetic-codex-server.py")
        try Data(#"""
        #!/usr/bin/python3 -IS
        import json, os, sys, time
        home = os.environ['CODEX_HOME']
        for line in sys.stdin:
            req = json.loads(line)
            method = req.get('method')
            rid = req.get('id')
            if method == 'initialized':
                continue
            if method == 'initialize':
                result = {'userAgent':'miniscanvas/0.151.0 (synthetic)','platformFamily':'unix','platformOs':'macos'}
            elif method == 'thread/resume':
                result = {'thread':{'id':req['params']['threadId']}}
            else:
                result = None
            if rid is not None:
                if result is None:
                    print(json.dumps({'id':rid,'error':{'code':-32000,'message':'unsupported'}}), flush=True)
                else:
                    print(json.dumps({'id':rid,'result':result}), flush=True)
            if method == 'thread/resume':
                tid = req['params']['threadId']
                print(json.dumps({'method':'item/agentMessage/delta','params':{'threadId':tid,'turnId':'turn-a','itemId':'message-1','delta':'api_key='}}), flush=True)
                print(json.dumps({'method':'item/agentMessage/delta','params':{'threadId':tid,'turnId':'turn-a','itemId':'message-1','delta':'owned_sample_1881'}}), flush=True)
                print(json.dumps({'method':'item/completed','params':{'threadId':tid,'turnId':'turn-a','item':{'id':'message-1','type':'agentMessage','text':'api_key=owned_sample_1881'}}}), flush=True)
                while not os.path.exists(os.path.join(home, 'send-second')):
                    time.sleep(0.01)
                print(json.dumps({'method':'item/completed','params':{'threadId':tid,'turnId':'turn-a','item':{'id':'message-2','type':'agentMessage','text':'after-switch'}}}), flush=True)
        """#.utf8).write(to: server)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: server.path)

        let composition = ProductionOrchestrationDefaults.makeExternalSessionAuthorization(runtimeConsumer: nil)
        composition.configureExternalSourceRegistration(hostID: "synthetic-test-host")
        let sourceID = try composition.registerSelectedReadRoot(kind: .codex, rootURL: sessions)
        let profileID = try #require(composition.supervisedProfileID(for: sourceID))
        try composition.configureSyntheticCodexControl(
            sourceID: sourceID, executableURL: server, homeURL: home,
            runtimeDirectory: profile.rootDirectory.appendingPathComponent("external-session-runtime", isDirectory: true)
        )
        let readGrant = try await composition.issueReadGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "extf-display-status"),
            sourceID: sourceID, profileID: profileID, target: .source(sourceID),
            scopes: [.metadata, .status], lifetime: 60
        )
        _ = try await composition.activateSelectedReadRoot(sourceID: sourceID, readGrant: readGrant)
        let controlGrant = try await composition.issueControlGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "extf-display-resume"),
            sourceID: sourceID, profileID: profileID, target: .thread(threadID),
            operations: [.resume], lifetime: 60
        )
        try await composition.activateSyntheticCodexControl(
            sourceID: sourceID, readGrant: readGrant, controlGrant: controlGrant
        )
        do {
            let adapter = try #require(composition.adapter(for: sourceID))
            let eventsGrant = try await composition.issueReadGrant(
                authorizationID: ExternalSessionAuthorizationID(rawValue: "extf-display-events"),
                sourceID: sourceID, profileID: profileID, target: .thread(threadID),
                scopes: [.events], lifetime: 60
            )
            let generation = adapter.runtimeSnapshot.generation
            let displayed = ExternalSessionEventDisplayProjection()
            let revoked = ExternalSessionEventDisplayProjection()
            let wrongGeneration = ExternalSessionEventDisplayProjection()
            let displayedID = displayed.begin(
                sourceID: sourceID, threadID: threadID, generation: generation, grant: eventsGrant
            )
            let revokedID = revoked.begin(
                sourceID: sourceID, threadID: threadID, generation: generation, grant: eventsGrant
            )
            let wrongID = wrongGeneration.begin(
                sourceID: sourceID, threadID: threadID, generation: generation + 1, grant: eventsGrant
            )
            let displayConsumer = displayed.consumer(composition: composition, subscriptionID: displayedID)
            let revokeConsumer = revoked.consumer(composition: composition, subscriptionID: revokedID)
            let wrongConsumer = wrongGeneration.consumer(composition: composition, subscriptionID: wrongID)
            try await composition.subscribeSyntheticCodexEvents(
                sourceID: sourceID, threadID: threadID, readGrant: eventsGrant,
                onEvent: { event in
                    displayConsumer(event)
                    revokeConsumer(event)
                    wrongConsumer(event)
                }
            )
            let status = try await adapter.status(
                target: ExternalSessionStatusTargetV1(sourceID: sourceID, threadID: threadID),
                readGrant: readGrant
            )
            _ = try await adapter.control(
                request: ExternalSessionControlRequestV1(
                    sourceID: sourceID, threadID: threadID, operation: .resume,
                    expectedCursor: status.observedCursor, idempotencyKey: "extf-display-once"
                ), controlGrant: controlGrant
            )
            for _ in 0..<200 {
                if !displayed.chunks.isEmpty { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(!displayed.chunks.isEmpty)
            #expect(!displayed.chunks.map(\.text).joined().contains("owned_sample_1881"))
            #expect(!revoked.chunks.isEmpty)
            #expect(wrongGeneration.chunks.isEmpty)
            let checkpoint = try #require(adapter.runtimeSnapshot.eventCheckpoint)

            // The UI calls the same reset on source/thread selection changes.
            // A later real notification from the old subscription stays out.
            displayed.reset()
            try Data().write(to: home.appendingPathComponent("send-second"))
            for _ in 0..<200 {
                if (adapter.runtimeSnapshot.eventCheckpoint?.sequence ?? 0) > checkpoint.sequence { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect((adapter.runtimeSnapshot.eventCheckpoint?.sequence ?? 0) > checkpoint.sequence)
            #expect(displayed.chunks.isEmpty)
            #expect(wrongGeneration.chunks.isEmpty)

            _ = await composition.revoke(sourceID: sourceID, profileID: profileID)
            revoked.reconcileAuthorization(await composition.authorizationSnapshot())
            #expect(revoked.chunks.isEmpty)
        } catch {
            _ = await composition.revoke(sourceID: sourceID, profileID: profileID)
            throw error
        }
    }
}
