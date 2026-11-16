import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-EXTI owned process, lease, runtime and transcript recovery")
@MainActor
struct ExternalFourDomainUnknown2808ConsumerTests {
    @Test func submittedForkWithoutReceiptSurvivesFreshProcessAndReadStoreAsUnknown() async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "EXTI-2808")
        defer { try? profile.cleanupDisposableRoots() }
        let home = profile.rootDirectory.appendingPathComponent("owned-codex-home", isDirectory: true)
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        let day = sessions.appendingPathComponent("2026/10/05", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let thread = "12345678-1234-1234-1234-123456789abc"
        let threadID = ExternalSessionThreadID(rawValue: thread)
        let turnID = ExternalSessionTurnID(rawValue: "turn-1")
        let transcriptURL = day.appendingPathComponent("rollout-2026-10-05T00-00-00-\(thread).jsonl")
        try Data("""
        {"timestamp":"2026-10-05T00:00:00Z","type":"session_meta","payload":{"id":"\(thread)","cwd":"/synthetic/project","cli_version":"0.151.0"}}
        {"timestamp":"2026-10-05T00:00:01Z","type":"event_msg","payload":{"type":"task_started"}}
        {"timestamp":"2026-10-05T00:00:02Z","type":"event_msg","payload":{"type":"user_message","message":"owned-transcript-2808-user"}}
        {"timestamp":"2026-10-05T00:00:03Z","type":"event_msg","payload":{"type":"agent_message","message":"owned-transcript-2808-answer"}}
        {"timestamp":"2026-10-05T00:00:04Z","type":"event_msg","payload":{"type":"task_complete"}}
        """.utf8).write(to: transcriptURL)
        let transcriptBefore = try Data(contentsOf: transcriptURL)

        let server = profile.rootDirectory.appendingPathComponent("synthetic-codex-server.py")
        try Data(#"""
        #!/usr/bin/python3 -IS
        import json, os, sys, time
        home = os.environ['CODEX_HOME']
        with open(os.path.join(home, 'server-starts'), 'a') as marker:
            marker.write('started\n')
        for line in sys.stdin:
            req = json.loads(line)
            method, rid = req.get('method'), req.get('id')
            if method == 'initialized':
                continue
            if method == 'initialize':
                print(json.dumps({'id':rid,'result':{'userAgent':'miniscanvas/0.151.0 (synthetic)','platformFamily':'unix','platformOs':'macos'}}), flush=True)
            elif method == 'thread/fork':
                # The request reached this owned process, but no response or
                # child identity was returned. A transcript terminal is not a
                # receipt for this fork and cannot make a retry safe.
                with open(os.path.join(home, 'fork-submissions'), 'a') as marker:
                    marker.write('submitted\n')
                print(json.dumps({'method':'turn/started','params':{'threadId':req['params']['threadId'],'turn':{'id':'turn-1'}}}), flush=True)
                while not os.path.exists(os.path.join(home, 'allow-fork-exit')):
                    time.sleep(0.01)
                os._exit(0)
            elif rid is not None:
                print(json.dumps({'id':rid,'error':{'code':-32000,'message':'unsupported'}}), flush=True)
        """#.utf8).write(to: server)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: server.path)

        let composition = ProductionOrchestrationDefaults.makeExternalSessionAuthorization(runtimeConsumer: nil)
        composition.configureExternalSourceRegistration(hostID: "owned-2808")
        let sourceID = try composition.registerSelectedReadRoot(kind: .codex, rootURL: sessions)
        let profileID = try #require(composition.supervisedProfileID(for: sourceID))
        let runtimeDirectory = profile.rootDirectory.appendingPathComponent("external-runtime", isDirectory: true)
        let runtimeURL = runtimeDirectory.appendingPathComponent("\(sourceID.rawValue).json")
        try composition.configureSyntheticCodexControl(
            sourceID: sourceID, executableURL: server, homeURL: home, runtimeDirectory: runtimeDirectory
        )
        let readGrant = try await composition.issueReadGrant(
            authorizationID: .init(rawValue: "2808-read"), sourceID: sourceID, profileID: profileID,
            target: .source(sourceID), scopes: [.metadata, .messages, .status], lifetime: 60
        )
        _ = try await composition.activateSelectedReadRoot(sourceID: sourceID, readGrant: readGrant)
        let forkGrant = try await composition.issueControlGrant(
            authorizationID: .init(rawValue: "2808-fork"), sourceID: sourceID, profileID: profileID,
            target: .thread(threadID), operations: [.fork], lifetime: 60
        )
        try await composition.activateSyntheticCodexControl(
            sourceID: sourceID, readGrant: readGrant, controlGrant: forkGrant
        )
        do {
            let firstAdapter = try #require(composition.adapter(for: sourceID))
            let oldOwner = try #require(firstAdapter.runtimeSnapshot.ownerID)
            let eventsGrant = try await composition.issueReadGrant(
                authorizationID: .init(rawValue: "2808-events"), sourceID: sourceID,
                profileID: profileID, target: .thread(threadID), scopes: [.events], lifetime: 60
            )
            try await composition.subscribeSyntheticCodexEvents(
                sourceID: sourceID, threadID: threadID, readGrant: eventsGrant
            )
            let transcript = try await firstAdapter.read(
                request: .init(sourceID: sourceID, threadID: threadID, limit: 10), readGrant: readGrant
            )
            #expect(transcript.messageChunks.map(\.text).joined().contains("owned-transcript-2808-answer"))
            let status = try await firstAdapter.status(
                target: .init(sourceID: sourceID, threadID: threadID, turnID: turnID), readGrant: readGrant
            )
            #expect(status.turnStatus == .succeeded)
            let request = ExternalSessionControlRequestV1(
                sourceID: sourceID, threadID: threadID, turnID: turnID,
                operation: .fork, expectedCursor: status.observedCursor, idempotencyKey: "2808-fork-once"
            )
            let controlTask = Task {
                try await firstAdapter.control(request: request, controlGrant: forkGrant)
            }
            #expect(await waitUntil { firstAdapter.runtimeSnapshot.eventCheckpoint != nil })
            let checkpoint = try #require(firstAdapter.runtimeSnapshot.eventCheckpoint)
            #expect(checkpoint.threadID == threadID)
            #expect(checkpoint.identity.isValid)
            #expect(try lines(at: home.appendingPathComponent("fork-submissions")) == 1)
            try Data().write(to: home.appendingPathComponent("allow-fork-exit"))
            do {
                _ = try await controlTask.value
                Issue.record("The owned stdio child exited without a fork receipt")
            } catch {
                // The actual child wrote the request marker before closing.
            }
            #expect(await waitUntil { !composition.hasActiveCodexEventListener(for: sourceID) })
            #expect(firstAdapter.runtimeSnapshot.requiresSideEffectReconciliation)
            let submitted = try #require(firstAdapter.runtimeSnapshot.unconfirmedControl)
            #expect(submitted.threadID == threadID)
            #expect(submitted.turnID == turnID)
            #expect(submitted.operation == .fork)
            #expect(submitted.connectionOwnerID == oldOwner)
            #expect(firstAdapter.runtimeSnapshot.eventCheckpoint == checkpoint)
            #expect(try Data(contentsOf: transcriptURL) == transcriptBefore)
            #expect(try lines(at: home.appendingPathComponent("fork-submissions")) == 1)
            let persisted = try Data(contentsOf: runtimeURL)
            #expect(!String(decoding: persisted, as: UTF8.self).contains("owned-transcript-2808-answer"))

            // The terminated process released its connection lease. A second
            // owned child and a newly constructed App adapter load the same
            // runtime record; neither receives an automatic control request.
            try await composition.activateSyntheticCodexControl(
                sourceID: sourceID, readGrant: readGrant, controlGrant: forkGrant
            )
            let recovered = try #require(composition.adapter(for: sourceID))
            #expect(recovered.runtimeSnapshot.ownerID != oldOwner)
            #expect(recovered.runtimeSnapshot.unconfirmedControl == submitted)
            #expect(recovered.runtimeSnapshot.eventCheckpoint == checkpoint)
            #expect(recovered.runtimeSnapshot.requiresSideEffectReconciliation)
            #expect(recovered.source.capabilities.contains(.fork))
            #expect(try lines(at: home.appendingPathComponent("server-starts")) == 2)
            #expect(try lines(at: home.appendingPathComponent("fork-submissions")) == 1)

            // A fresh production JSONL reader still sees the same transcript.
            // Its successful turn status describes the source, not the fork.
            let freshReadStore = ExternalSessionCodexRolloutReadAdapter(
                sourceID: sourceID, profileID: profileID, hostID: "owned-2808",
                rootURL: sessions, authorizationLedger: composition.ledger
            )
            #expect(freshReadStore.source.capabilities == [.readMetadata, .readMessages, .status])
            let freshPage = try await freshReadStore.read(
                request: .init(sourceID: sourceID, threadID: threadID, limit: 10), readGrant: readGrant
            )
            #expect(freshPage.messageChunks == transcript.messageChunks)
            let recoveredPage = try await recovered.read(
                request: .init(sourceID: sourceID, threadID: threadID, limit: 10), readGrant: readGrant
            )
            #expect(recoveredPage.messageChunks == freshPage.messageChunks)
            let observed = try await recovered.reconcileExternalSideEffect(
                threadID: threadID, turnID: turnID, readGrant: readGrant
            )
            #expect(observed.turnStatus == .succeeded)
            #expect(recovered.runtimeSnapshot.unconfirmedControl?.observedTurnStatus == .succeeded)
            #expect(recovered.runtimeSnapshot.requiresSideEffectReconciliation)
            await #expect(throws: ExternalSessionAppAdapterError.sideEffectReconciliationRequired) {
                _ = try await recovered.control(request: request, controlGrant: forkGrant)
            }
            #expect(try lines(at: home.appendingPathComponent("fork-submissions")) == 1)
            #expect(try Data(contentsOf: transcriptURL) == transcriptBefore)
        } catch {
            try? Data().write(to: home.appendingPathComponent("allow-fork-exit"))
            _ = await composition.revoke(sourceID: sourceID, profileID: profileID)
            throw error
        }
        _ = await composition.revoke(sourceID: sourceID, profileID: profileID)
    }

    private func lines(at url: URL) throws -> Int {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").count
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}
