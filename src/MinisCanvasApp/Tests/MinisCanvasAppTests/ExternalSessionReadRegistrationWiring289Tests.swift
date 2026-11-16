import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// P3-EXT-01 (N-EXT01-REG): the read-side local-store adapter
/// (`ExternalSessionLocalStoreAdapter`, MinisCore) must have a production
/// consumer wired through the composition-root factory.
///
/// Every row exercises the real production seam —
/// `ProductionOrchestrationDefaults.makeExternalSessionAuthorization` plus
/// `registerLocalStoreReadSide`, the exact pair `MinisCanvasAppMain.init`
/// performs at launch — against a live `SessionStore` in a fresh temporary
/// directory seeded with synthetic `ChatSession` records. No static fixture
/// stands in for the store, and no assertion here weakens a product rule:
/// each one fails if the registration is removed, given a nil ledger, or
/// starts advertising a control capability.
@Suite("External-session read registration wiring (DEV-289)")
@MainActor
struct ExternalSessionReadRegistrationWiring289Tests {
    /// Fixed clock constant declared `nonisolated` so the `@Sendable` clock
    /// closures below can read it (same convention as lane 139's suite).
    private nonisolated static let now = Date(timeIntervalSince1970: 200_000)
    private static let issuedAt = Date(timeIntervalSince1970: 199_950)
    private static let lifetime: TimeInterval = 1_000

    @Test func selectedExternalRootsRegisterRealReadersWithoutReadingBeforeGrant() async throws {
        let composition = ProductionOrchestrationDefaults.makeExternalSessionAuthorization(runtimeConsumer: nil)
        composition.configureExternalSourceRegistration(hostID: "synthetic-test-host")
        let missingCodexRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("EXT773-absent-codex-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        let missingClaudeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("EXT773-absent-claude-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
        let codexID = try composition.registerSelectedReadRoot(kind: .codex, rootURL: missingCodexRoot)
        let claudeID = try composition.registerSelectedReadRoot(kind: .claudeCode, rootURL: missingClaudeRoot)
        #expect(codexID != claudeID)
        #expect(composition.adapter(for: codexID)?.source.kind == .codex)
        #expect(composition.adapter(for: claudeID)?.source.kind == .claudeCode)
        #expect(composition.adapter(for: codexID)?.source.authState == .unavailable)
        #expect(composition.adapter(for: claudeID)?.source.authState == .unavailable)
        #expect(composition.adapter(for: codexID)?.source.capabilities == [])
        #expect(composition.adapter(for: claudeID)?.source.capabilities == [])
        #expect(await composition.authorizationSnapshot() == .empty)

        let adapter = try #require(composition.adapter(for: codexID))
        let grant = try await composition.issueReadGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "ext773-synthetic-list"),
            sourceID: codexID,
            profileID: adapter.source.profileID,
            target: .source(codexID),
            scopes: [.metadata],
            lifetime: 60
        )
        await #expect(throws: ExternalSessionAppAdapterError.sourceUnavailable) {
            try await composition.activateSelectedReadRoot(sourceID: codexID, readGrant: grant)
        }
        #expect(composition.adapter(for: codexID)?.source.authState == .unavailable)
        #expect(adapter.source.capabilities == [])
    }

    @Test func selectedCodexRootBecomesReadableOnlyAfterUserGrantAndCanBeRevoked() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EXT773-synthetic-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        let day = root.appendingPathComponent("2026/10/01", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let thread = "12345678-1234-1234-1234-123456789abc"
        let file = day.appendingPathComponent("rollout-2026-10-01T00-00-00-\(thread).jsonl")
        try Data("""
        {"timestamp":"2026-10-01T00:00:00Z","type":"session_meta","payload":{"id":"\(thread)","cwd":"/synthetic/project","cli_version":"0.151.0"}}
        {"timestamp":"2026-10-01T00:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"synthetic-773-content"}]}}
        """.utf8).write(to: file)
        let composition = ProductionOrchestrationDefaults.makeExternalSessionAuthorization(runtimeConsumer: nil)
        composition.configureExternalSourceRegistration(hostID: "synthetic-test-host")
        let sourceID = try composition.registerSelectedReadRoot(kind: .codex, rootURL: root)
        #expect(composition.adapter(for: sourceID)?.source.authState == .unavailable)
        let profileID = try #require(composition.supervisedProfileID(for: sourceID))
        let grant = try await composition.issueReadGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "ext773-synthetic-read"),
            sourceID: sourceID,
            profileID: profileID,
            target: .source(sourceID),
            scopes: [.metadata, .messages],
            lifetime: 60
        )
        let adapter = try await composition.activateSelectedReadRoot(sourceID: sourceID, readGrant: grant)
        #expect(adapter.source.kind == .codex)
        #expect(adapter.source.capabilities == [.readMetadata, .readMessages, .status])
        let list = try await adapter.listThreads(
            query: ExternalSessionThreadQueryV1(sourceID: sourceID, limit: 10),
            readGrant: grant
        )
        #expect(list.threads.map(\.threadID.rawValue) == [thread])
        let page = try await adapter.read(
            request: ExternalSessionReadRequestV1(
                sourceID: sourceID,
                threadID: ExternalSessionThreadID(rawValue: thread),
                limit: 10
            ),
            readGrant: grant
        )
        #expect(page.messageChunks.map(\.text).joined() == "synthetic-773-content")
        _ = await composition.revoke(sourceID: sourceID, profileID: profileID)
        await #expect(throws: ExternalSessionAppAdapterError.grantRevoked) {
            try await adapter.listThreads(
                query: ExternalSessionThreadQueryV1(sourceID: sourceID, limit: 10),
                readGrant: grant
            )
        }
    }

    @Test func disposableAppEntryRegistersOnlyExplicitSyntheticControlConfiguration() throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "EXT773-field")
        defer { try? profile.cleanupDisposableRoots() }
        let composition = ProductionOrchestrationDefaults.makeExternalSessionAuthorization(runtimeConsumer: nil)
        composition.configureExternalSourceRegistration(hostID: "synthetic-test-host")
        let home = profile.rootDirectory.appendingPathComponent("owned-codex-home", isDirectory: true)
        let sourceID = try #require(ProductionOrchestrationDefaults.registerSyntheticExternalCodexIfConfigured(
            composition: composition,
            profile: profile,
            environment: [
                "MINISCANVAS_EXT_SYNTHETIC_CODEX_HOME": home.path,
                "MINISCANVAS_EXT_SYNTHETIC_CODEX_EXECUTABLE": "/usr/bin/true"
            ]
        ))
        #expect(composition.isReadRootPending(for: sourceID))
        #expect(composition.hasConfiguredSyntheticCodexControl(for: sourceID))
        #expect(composition.adapter(for: sourceID)?.source.capabilities == [])
        #expect(composition.supportedControlOperations(for: sourceID).isEmpty)
        #expect(ProductionOrchestrationDefaults.registerSyntheticExternalCodexIfConfigured(
            composition: composition,
            profile: profile,
            environment: [:]
        ) == nil)
    }

    @Test func syntheticCodexReadControlAndEventShareOneAuthorizedSource() async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "EXT773-control")
        defer { try? profile.cleanupDisposableRoots() }
        let home = profile.rootDirectory.appendingPathComponent("owned-codex-home", isDirectory: true)
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        let day = sessions.appendingPathComponent("2026/10/01", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let thread = "12345678-1234-1234-1234-123456789abc"
        try Data("""
        {"timestamp":"2026-10-01T00:00:00Z","type":"session_meta","payload":{"id":"\(thread)","cwd":"/synthetic/project","cli_version":"0.151.0"}}
        {"timestamp":"2026-10-01T00:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"synthetic-control-773"}]}}
        """.utf8).write(to: day.appendingPathComponent("rollout-2026-10-01T00-00-00-\(thread).jsonl"))
        let server = profile.rootDirectory.appendingPathComponent("synthetic-codex-server.py")
        try Data(#"""
        #!/usr/bin/python3
        import json,os,sys
        open(os.path.join(os.environ['CODEX_HOME'],'server-started'),'w').close()
        for line in sys.stdin:
            req=json.loads(line)
            method=req.get('method')
            rid=req.get('id')
            if method is None and rid=='approval-1':
                tid='12345678-1234-1234-1234-123456789abc'
                print(json.dumps({'method':'serverRequest/resolved','params':{'threadId':tid,'requestId':'approval-1'}}),flush=True)
                print(json.dumps({'method':'turn/completed','params':{'threadId':tid,'turn':{'id':'turn_owned','status':'completed'}}}),flush=True)
                continue
            if method=='initialized':
                continue
            if method=='initialize':
                result={'userAgent':'miniscanvas/0.151.0 (synthetic)','platformFamily':'unix','platformOs':'macos'}
            elif method=='thread/resume':
                tid=req['params']['threadId']
                print(json.dumps({'method':'turn/started','params':{'threadId':tid,'turn':{'id':'turn_owned'}}}),flush=True)
                print(json.dumps({'id':'approval-1','method':'item/commandExecution/requestApproval','params':{'threadId':tid,'turnId':'turn_owned','itemId':'command-1'}}),flush=True)
                result={'thread':{'id':tid}}
            else:
                result=None
            if rid is not None:
                if result is None:
                    print(json.dumps({'id':rid,'error':{'code':-32000,'message':'unsupported'}}),flush=True)
                else:
                    print(json.dumps({'id':rid,'result':result}),flush=True)
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
            authorizationID: ExternalSessionAuthorizationID(rawValue: "ext773-control-status"),
            sourceID: sourceID, profileID: profileID, target: .source(sourceID),
            scopes: [.metadata, .messages, .status], lifetime: 60
        )
        _ = try await composition.activateSelectedReadRoot(sourceID: sourceID, readGrant: readGrant)
        #expect(composition.supportedControlOperations(for: sourceID).isEmpty)
        let unissuedControl = ExternalSessionControlGrantV1(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "ext773-forged-control"),
            sourceID: sourceID, profileID: profileID,
            target: .thread(ExternalSessionThreadID(rawValue: thread)),
            operations: [.resume], issuedAt: Date().addingTimeInterval(-1),
            expiresAt: Date().addingTimeInterval(60), revocationEpoch: readGrant.revocationEpoch
        )
        await #expect(throws: ExternalSessionAppAdapterError.operationNotGranted(.resume)) {
            try await composition.activateSyntheticCodexControl(
                sourceID: sourceID, readGrant: readGrant, controlGrant: unissuedControl
            )
        }
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("server-started").path))
        let controlGrant = try await composition.issueControlGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "ext773-control-resume"),
            sourceID: sourceID, profileID: profileID,
            target: .thread(ExternalSessionThreadID(rawValue: thread)),
            operations: [.resume], lifetime: 60
        )
        try await composition.activateSyntheticCodexControl(
            sourceID: sourceID, readGrant: readGrant, controlGrant: controlGrant
        )
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent("server-started").path))
        let adapter = try #require(composition.adapter(for: sourceID))
        #expect(adapter.source.capabilities.contains(.stream))
        #expect(adapter.source.capabilities.contains(.resume))
        let eventsGrant = try await composition.issueReadGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "ext773-events"),
            sourceID: sourceID, profileID: profileID,
            target: .thread(ExternalSessionThreadID(rawValue: thread)),
            scopes: [.events], lifetime: 60
        )
        try await composition.subscribeSyntheticCodexEvents(
            sourceID: sourceID,
            threadID: ExternalSessionThreadID(rawValue: thread),
            readGrant: eventsGrant
        )
        #expect(composition.hasActiveCodexEventListener(for: sourceID))
        let status = try await adapter.status(
            target: ExternalSessionStatusTargetV1(sourceID: sourceID, threadID: ExternalSessionThreadID(rawValue: thread)),
            readGrant: readGrant
        )
        let receipt = try await adapter.control(
            request: ExternalSessionControlRequestV1(
                sourceID: sourceID, threadID: ExternalSessionThreadID(rawValue: thread),
                operation: .resume, expectedCursor: status.observedCursor,
                idempotencyKey: "ext773-resume-once"
            ), controlGrant: controlGrant
        )
        #expect(receipt.outcome == .accepted)
        for _ in 0..<100 {
            if adapter.runtimeSnapshot.eventCheckpoint != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(adapter.runtimeSnapshot.eventCheckpoint != nil)
        for _ in 0..<100 {
            if adapter.runtimeSnapshot.pendingApproval != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(adapter.runtimeSnapshot.pendingApproval?.requestID == "s:approval-1")
        let approvalGrant = try await composition.issueControlGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "ext773-control-approve"),
            sourceID: sourceID, profileID: profileID,
            target: .thread(ExternalSessionThreadID(rawValue: thread)),
            operations: [.approve], lifetime: 60
        )
        try await composition.respondToSyntheticCodexApproval(
            sourceID: sourceID, decision: .approve, controlGrant: approvalGrant
        )
        for _ in 0..<100 {
            if adapter.runtimeSnapshot.pendingApproval == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(adapter.runtimeSnapshot.pendingApproval == nil)
        _ = await composition.revoke(sourceID: sourceID, profileID: profileID)
        #expect(!composition.hasActiveCodexEventListener(for: sourceID))
        #expect(adapter.runtimeSnapshot.state == .disconnected)
        await #expect(throws: ExternalSessionAppAdapterError.grantRevoked) {
            try await adapter.listThreads(
                query: ExternalSessionThreadQueryV1(sourceID: sourceID, limit: 10),
                readGrant: readGrant
            )
        }
    }

    @Test(arguments: ["normal", "malformed", "bounded"])
    func terminatedSyntheticCodexProcessReleasesOnlyItsConnectionLease(mode: String) async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "EXTI-process-\(mode)")
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
        let script = #"""
        #!/usr/bin/python3
        import json, os, sys, time
        home = os.environ['CODEX_HOME']
        with open(os.path.join(home, 'server-starts'), 'a') as marker:
            marker.write('started\n')
        mode = '__MODE__'
        for line in sys.stdin:
            req = json.loads(line)
            method = req.get('method')
            rid = req.get('id')
            if method == 'initialized':
                continue
            if method == 'initialize':
                result = {'userAgent':'miniscanvas/0.151.0 (synthetic)', 'platformFamily':'unix', 'platformOs':'macos'}
            elif method == 'thread/resume':
                with open(os.path.join(home, 'control-requests'), 'a') as marker:
                    marker.write('resume\n')
                result = {'thread':{'id':req['params']['threadId']}}
            else:
                result = None
            if rid is not None:
                if result is None:
                    print(json.dumps({'id':rid,'error':{'code':-32000,'message':'unsupported'}}), flush=True)
                else:
                    print(json.dumps({'id':rid,'result':result}), flush=True)
            if method == 'thread/resume':
                # The test releases this synthetic process only after the
                # real control consumer has recorded its response.
                while not os.path.exists(os.path.join(home, 'allow-terminal')):
                    time.sleep(0.01)
                if mode == 'bounded':
                    print(json.dumps({'method':'item/agentMessage/delta','params':{'threadId':req['params']['threadId'],'itemId':'message-1','delta':'x' * (128 * 1024 + 1)}}), flush=True)
                    continue
                if mode == 'malformed':
                    print('{malformed', flush=True)
                else:
                    print(json.dumps({'method':'turn/completed','params':{'threadId':req['params']['threadId'],'turn':{'id':'turn-owned','status':'completed'}}}), flush=True)
                break
        """#.replacingOccurrences(of: "__MODE__", with: mode)
        try Data(script.utf8).write(to: server)
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
            authorizationID: ExternalSessionAuthorizationID(rawValue: "exti-process-status-\(mode)"),
            sourceID: sourceID, profileID: profileID, target: .source(sourceID),
            scopes: [.metadata, .status], lifetime: 60
        )
        _ = try await composition.activateSelectedReadRoot(sourceID: sourceID, readGrant: readGrant)
        let controlGrant = try await composition.issueControlGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "exti-process-resume-\(mode)"),
            sourceID: sourceID, profileID: profileID, target: .thread(threadID),
            operations: [.resume], lifetime: 60
        )
        try await composition.activateSyntheticCodexControl(
            sourceID: sourceID, readGrant: readGrant, controlGrant: controlGrant
        )
        do {
            let firstAdapter = try #require(composition.adapter(for: sourceID))
            let eventsGrant = try await composition.issueReadGrant(
                authorizationID: ExternalSessionAuthorizationID(rawValue: "exti-process-events-\(mode)"),
                sourceID: sourceID, profileID: profileID, target: .thread(threadID),
                scopes: [.events], lifetime: 60
            )
            try await composition.subscribeSyntheticCodexEvents(
                sourceID: sourceID, threadID: threadID, readGrant: eventsGrant
            )
            let status = try await firstAdapter.status(
                target: ExternalSessionStatusTargetV1(sourceID: sourceID, threadID: threadID),
                readGrant: readGrant
            )
            _ = try await firstAdapter.control(
                request: ExternalSessionControlRequestV1(
                    sourceID: sourceID, threadID: threadID, operation: .resume,
                    expectedCursor: status.observedCursor, idempotencyKey: "exti-resume-once-\(mode)"
                ), controlGrant: controlGrant
            )
            try Data().write(to: home.appendingPathComponent("allow-terminal"))
            // The deadline bounds the assertion only. The listener terminates on
            // process EOF, invalid JSON, or its own bounded-delta refusal.
            for _ in 0..<200 {
                if !composition.hasActiveCodexEventListener(for: sourceID) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(!composition.hasActiveCodexEventListener(for: sourceID))
            #expect(firstAdapter.runtimeSnapshot.state != .connected)
            if mode == "malformed" {
                #expect(firstAdapter.runtimeSnapshot.requiresSideEffectReconciliation)
            }
            if mode == "bounded" {
                // The subscriber ended, but the owned process is still healthy.
                // It must remain leased until explicit revocation, not be killed
                // to make room for an automatic reconnection.
                await #expect(throws: ExternalSessionAppAdapterError.operationNotGranted(.resume)) {
                    try await composition.activateSyntheticCodexControl(
                        sourceID: sourceID, readGrant: readGrant, controlGrant: controlGrant
                    )
                }
                let starts = try String(contentsOf: home.appendingPathComponent("server-starts"), encoding: .utf8)
                #expect(starts.split(separator: "\n").count == 1)
                _ = await composition.revoke(sourceID: sourceID, profileID: profileID)
                return
            }
            // Replacement retires the old mutable adapter in memory. Compare
            // the registered lease's terminal generation, frozen before that.
            let terminalGeneration = firstAdapter.runtimeSnapshot.generation
            // Re-entry uses the same production grant checks. The second process
            // receives no control request: a terminal event cannot auto-resubmit.
            try await composition.activateSyntheticCodexControl(
                sourceID: sourceID, readGrant: readGrant, controlGrant: controlGrant
            )
            let secondAdapter = try #require(composition.adapter(for: sourceID))
            #expect(secondAdapter.runtimeSnapshot.generation > terminalGeneration)
            if mode == "malformed" {
                #expect(secondAdapter.runtimeSnapshot.requiresSideEffectReconciliation)
            }
            let starts = try String(contentsOf: home.appendingPathComponent("server-starts"), encoding: .utf8)
            #expect(starts.split(separator: "\n").count == 2)
            let controls = try String(contentsOf: home.appendingPathComponent("control-requests"), encoding: .utf8)
            #expect(controls.split(separator: "\n").count == 1)
            _ = await composition.revoke(sourceID: sourceID, profileID: profileID)
        } catch {
            _ = await composition.revoke(sourceID: sourceID, profileID: profileID)
            throw error
        }
    }

    private var sourceID: ExternalSessionSourceID {
        ProductionOrchestrationDefaults.localSessionStoreSourceID
    }
    private var profileID: ExternalSessionProfileID {
        ProductionOrchestrationDefaults.localSessionStoreProfileID
    }

    private struct Fixture {
        let directory: URL
        let store: SessionStore
    }

    private func makeFixtureWithSyntheticSessions() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCanvasApp-W289-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SessionStore(directory: directory)
        // Deterministic order under test is updatedAt desc, then id asc.
        try store.updateSession(Self.syntheticSession(id: "synth-alpha", updatedAt: 100))
        try store.updateSession(Self.syntheticSession(id: "synth-beta", updatedAt: 200))
        return Fixture(directory: directory, store: store)
    }

    private static func syntheticSession(id: String, updatedAt: TimeInterval) -> ChatSession {
        ChatSession(
            id: id,
            title: "synthetic \(id)",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            messages: [
                LLMMessage(role: .user, content: "SYNTHETIC-W289-PROMPT \(id)"),
                LLMMessage(role: .assistant, content: "SYNTHETIC-W289-REPLY \(id)"),
            ],
            transcriptRevision: 2
        )
    }

    private func registered(
        consumer: TaskCenterControlConsumer? = nil
    ) throws -> (
        ExternalSessionAuthorizationComposition,
        ExternalSessionAppAdapter,
        Fixture
    ) {
        let fixture = try makeFixtureWithSyntheticSessions()
        let composition = ProductionOrchestrationDefaults.makeExternalSessionAuthorization(
            runtimeConsumer: consumer
        )
        let adapter = composition.registerLocalStoreReadSide(
            store: fixture.store,
            sourceID: sourceID,
            profileID: profileID,
            hostID: "w289-test-host",
            clock: { Self.now }
        )
        return (composition, adapter, fixture)
    }

    private func metadataGrant(
        _ composition: ExternalSessionAuthorizationComposition,
        suffix: String
    ) async throws -> ExternalSessionReadGrantV1 {
        try await composition.issueReadGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "w289-\(suffix)"),
            sourceID: sourceID,
            profileID: profileID,
            target: .source(sourceID),
            scopes: [.metadata],
            issuedAt: Self.issuedAt,
            lifetime: Self.lifetime
        )
    }

    // MARK: - The registration is the production consumer

    @Test func registrationSupervisesTheLocalStoreAndPublishesThroughTheExistingSeam() async throws {
        let consumer = TaskCenterControlConsumer(store: AgentTaskStore())
        // Before registration the shipped projection is nil exactly as before
        // this lane (lane 139 characterization).
        #expect(consumer.externalSessionRuntime == nil)
        let (composition, adapter, fixture) = try registered(consumer: consumer)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        #expect(composition.supervisedSourceIDs == [sourceID])
        let supervised = try #require(composition.adapter(for: sourceID))
        #expect(supervised.source == adapter.source)
        // The published source is the adapter this owner built, and its
        // capability set is exactly the read side: no control capability ever
        // rides on the registration (Canonical read/control split).
        #expect(adapter.source.sourceID == sourceID)
        #expect(adapter.source.capabilities == [.readMetadata, .readMessages, .status])
        #expect(adapter.source.capabilities.isDisjoint(
            with: [.resume, .fork, .steer, .interrupt, .approval]
        ))
        // Task Center's already-existing read-only projection starts publishing
        // through `bindExternalSessionRuntime`; no new consumer code was needed.
        let projection = try #require(consumer.externalSessionRuntime)
        #expect(projection.snapshot.state == ExternalSessionRuntimeState.disconnected)
        #expect(projection.snapshot.ownerID == nil)
    }

    @Test func registeredReadSideServesRealStoreSessionsViaListReadStatus() async throws {
        let (composition, adapter, fixture) = try registered()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let page = try await adapter.listThreads(
            query: ExternalSessionThreadQueryV1(sourceID: sourceID, limit: 10),
            readGrant: try metadataGrant(composition, suffix: "list")
        )
        #expect(page.sourceID == sourceID)
        #expect(page.threads.map(\.threadID.rawValue) == ["synth-beta", "synth-alpha"])
        #expect(page.threads.first?.title == "synthetic synth-beta")

        let threadID = ExternalSessionThreadID(rawValue: "synth-alpha")
        let transcriptGrant = try await composition.issueReadGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "w289-read-thread"),
            sourceID: sourceID,
            profileID: profileID,
            target: .thread(threadID),
            scopes: [.messages],
            issuedAt: Self.issuedAt,
            lifetime: Self.lifetime
        )
        let transcript = try await adapter.read(
            request: ExternalSessionReadRequestV1(sourceID: sourceID, threadID: threadID, limit: 50),
            readGrant: transcriptGrant
        )
        #expect(transcript.sourceID == sourceID)
        #expect(transcript.threadID == threadID)
        #expect(!transcript.turns.isEmpty)

        let statusGrant = try await composition.issueReadGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "w289-status"),
            sourceID: sourceID,
            profileID: profileID,
            target: .source(sourceID),
            scopes: [.status],
            issuedAt: Self.issuedAt,
            lifetime: Self.lifetime
        )
        let status = try await adapter.status(
            target: ExternalSessionStatusTargetV1(sourceID: sourceID),
            readGrant: statusGrant
        )
        #expect(status.sourceID == sourceID)
        // The status cursor is derived from the live store size (2 seeded
        // sessions), proving the reads cross into the real SessionStore.
        #expect(status.observedCursor == ExternalSessionCursorV1(rawValue: "local:size:2"))
    }

    // MARK: - Fail-closed semantics survive registration

    @Test func unissuedGrantIsRefusedThroughTheWiredLedger() async throws {
        let (composition, adapter, fixture) = try registered()
        defer { withExtendedLifetime(composition) {} }
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        // A syntactically valid grant for the same pair that no ledger ever
        // issued must fail closed. This is only possible because the
        // registration injected the owner's ledger non-optionally.
        let unissued = ExternalSessionReadGrantV1(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "w289-unissued-\(UUID().uuidString)"),
            sourceID: sourceID,
            profileID: profileID,
            target: .source(sourceID),
            scopes: [.metadata],
            issuedAt: Self.issuedAt,
            expiresAt: Self.issuedAt.addingTimeInterval(Self.lifetime),
            revocationEpoch: 0
        )
        await #expect(throws: ExternalSessionAppAdapterError.grantRevoked) {
            _ = try await adapter.listThreads(
                query: ExternalSessionThreadQueryV1(sourceID: sourceID, limit: 10),
                readGrant: unissued
            )
        }
    }

    @Test func revocationStopsTheNextReadThroughTheRegisteredConsumer() async throws {
        let (composition, adapter, fixture) = try registered()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let grant = try await metadataGrant(composition, suffix: "revoke")
        let first = try await adapter.listThreads(
            query: ExternalSessionThreadQueryV1(sourceID: sourceID, limit: 10),
            readGrant: grant
        )
        #expect(first.threads.count == 2)

        let epoch = await composition.revoke(sourceID: sourceID, profileID: profileID)
        #expect(epoch == 1)
        await #expect(throws: ExternalSessionAppAdapterError.grantRevoked) {
            _ = try await adapter.listThreads(
                query: ExternalSessionThreadQueryV1(sourceID: sourceID, limit: 10),
                readGrant: grant
            )
        }
    }

    @Test func controlRequestsAreRefusedAtTheGateForTheReadOnlySource() async throws {
        let (composition, adapter, fixture) = try registered()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let controlGrant = try await composition.issueControlGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "w289-control"),
            sourceID: sourceID,
            profileID: profileID,
            target: .thread(ExternalSessionThreadID(rawValue: "synth-alpha")),
            operations: [.resume],
            issuedAt: Self.issuedAt,
            lifetime: Self.lifetime
        )
        // 772's runtime gate rejects a disconnected adapter before any
        // provider control call. This local read-only source never connects.
        await #expect(throws: ExternalSessionAppAdapterError.runtimeUnavailable) {
            _ = try await adapter.control(
                request: ExternalSessionControlRequestV1(
                    sourceID: sourceID,
                    threadID: ExternalSessionThreadID(rawValue: "synth-alpha"),
                    operation: .resume,
                    expectedCursor: .beginning,
                    idempotencyKey: "w289-op-1"
                ),
                controlGrant: controlGrant
            )
        }
    }
}
