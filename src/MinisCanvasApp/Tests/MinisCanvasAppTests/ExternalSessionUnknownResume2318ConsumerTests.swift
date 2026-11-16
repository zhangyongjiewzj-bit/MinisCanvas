import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("External UNKNOWN resume uses its original optional turn identity")
@MainActor
struct ExternalSessionUnknownResume2318ConsumerTests {
    @Test func crashedStdioResumeCanQuerySameThreadWithoutClaimingItsEffect() async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "EXTI-2318")
        defer { try? profile.cleanupDisposableRoots() }
        let home = profile.rootDirectory.appendingPathComponent("owned-codex-home", isDirectory: true)
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        let day = sessions.appendingPathComponent("2026/10/01", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let thread = "12345678-1234-1234-1234-123456789abc"
        let threadID = ExternalSessionThreadID(rawValue: thread)
        let rollout = day.appendingPathComponent("rollout-2026-10-01T00-00-00-\(thread).jsonl")
        try Data("""
        {"timestamp":"2026-10-01T00:00:00Z","type":"session_meta","payload":{"id":"\(thread)","cwd":"/synthetic/project","cli_version":"0.151.0"}}
        """.utf8).write(to: rollout)

        // The owned process records the request but exits before sending a
        // response. Its liveness and any later transcript state are not a
        // receipt for this particular resume invocation.
        let server = profile.rootDirectory.appendingPathComponent("synthetic-codex-server.py")
        try Data(#"""
        #!/usr/bin/python3
        import json, os, sys
        home = os.environ['CODEX_HOME']
        for line in sys.stdin:
            req = json.loads(line)
            method = req.get('method')
            if method == 'initialize':
                print(json.dumps({'id':req['id'],'result':{'userAgent':'miniscanvas/0.151.0 (synthetic)','platformFamily':'unix','platformOs':'macos'}}), flush=True)
            elif method == 'thread/resume':
                with open(os.path.join(home, 'resume-requests'), 'a') as marker:
                    marker.write('received\n')
                sys.exit(0)
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
            authorizationID: ExternalSessionAuthorizationID(rawValue: "exti-2318-status"),
            sourceID: sourceID, profileID: profileID, target: .source(sourceID),
            scopes: [.metadata, .status], lifetime: 60
        )
        _ = try await composition.activateSelectedReadRoot(sourceID: sourceID, readGrant: readGrant)
        let controlGrant = try await composition.issueControlGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "exti-2318-resume"),
            sourceID: sourceID, profileID: profileID, target: .thread(threadID),
            operations: [.resume], lifetime: 60
        )
        try await composition.activateSyntheticCodexControl(
            sourceID: sourceID, readGrant: readGrant, controlGrant: controlGrant
        )
        do {
            let first = try #require(composition.adapter(for: sourceID))
            let eventsGrant = try await composition.issueReadGrant(
                authorizationID: ExternalSessionAuthorizationID(rawValue: "exti-2318-events"),
                sourceID: sourceID, profileID: profileID, target: .thread(threadID),
                scopes: [.events], lifetime: 60
            )
            try await composition.subscribeSyntheticCodexEvents(
                sourceID: sourceID, threadID: threadID, readGrant: eventsGrant
            )
            let status = try await first.status(
                target: ExternalSessionStatusTargetV1(sourceID: sourceID, threadID: threadID),
                readGrant: readGrant
            )
            let original = ExternalSessionControlRequestV1(
                sourceID: sourceID, threadID: threadID, operation: .resume,
                expectedCursor: status.observedCursor, idempotencyKey: "exti-2318-once"
            )
            await #expect(throws: Error.self) {
                _ = try await first.control(request: original, controlGrant: controlGrant)
            }
            #expect(first.runtimeSnapshot.requiresSideEffectReconciliation)
            #expect(first.runtimeSnapshot.unconfirmedControl?.turnID == nil)
            #expect(first.runtimeSnapshot.unconfirmedControl?.operation == .resume)
            // Another owned fixture writer can make the same thread look
            // completed. That is target state, not this control's receipt.
            var transcript = try Data(contentsOf: rollout)
            transcript.append(Data("\n".utf8))
            transcript.append(Data("""
            {"timestamp":"2026-10-01T00:00:01Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"synthetic foreign completion"}]}}
            {"timestamp":"2026-10-01T00:00:02Z","type":"event_msg","payload":{"type":"task_complete"}}
            """.utf8))
            try transcript.write(to: rollout)
            for _ in 0..<200 {
                if !composition.hasActiveCodexEventListener(for: sourceID) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(!composition.hasActiveCodexEventListener(for: sourceID))

            // Activation reopens the actual persisted App runtime with a fresh
            // connection. It must never resubmit the old control automatically.
            try await composition.activateSyntheticCodexControl(
                sourceID: sourceID, readGrant: readGrant, controlGrant: controlGrant
            )
            let recovered = try #require(composition.adapter(for: sourceID))
            #expect(recovered.runtimeSnapshot.requiresSideEffectReconciliation)
            #expect(recovered.runtimeSnapshot.unconfirmedControl?.turnID == nil)
            await #expect(throws: ExternalSessionAppAdapterError.targetMismatch) {
                _ = try await recovered.reconcileExternalSideEffect(
                    threadID: ExternalSessionThreadID(rawValue: "foreign-thread"),
                    turnID: nil, readGrant: readGrant
                )
            }
            await #expect(throws: ExternalSessionAppAdapterError.targetMismatch) {
                _ = try await recovered.reconcileExternalSideEffect(
                    threadID: threadID,
                    turnID: ExternalSessionTurnID(rawValue: "foreign-turn"), readGrant: readGrant
                )
            }
            let observed = try await recovered.reconcileExternalSideEffect(
                threadID: threadID, turnID: nil, readGrant: readGrant
            )
            #expect(observed.threadID == threadID)
            #expect(observed.turnID == nil)
            #expect(observed.turnStatus == .succeeded)
            #expect(recovered.runtimeSnapshot.requiresSideEffectReconciliation)
            await #expect(throws: ExternalSessionAppAdapterError.sideEffectReconciliationRequired) {
                _ = try await recovered.control(request: original, controlGrant: controlGrant)
            }
            let markers = try String(
                contentsOf: home.appendingPathComponent("resume-requests"), encoding: .utf8
            )
            #expect(markers.split(separator: "\n").count == 1)
            _ = await composition.revoke(sourceID: sourceID, profileID: profileID)
        } catch {
            _ = await composition.revoke(sourceID: sourceID, profileID: profileID)
            throw error
        }
    }
}
