import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-EXTE owned stdio steer, interrupt and cancellation confirmation")
@MainActor
struct ExternalStdioSteerInterrupt2877ConsumerTests {
    @Test func steerAndInterruptConsumeRealResponsesAndTurnTerminal() async throws {
        try await withOwnedFixture(explicitCancel: false) { fixture in
            let adapter = fixture.adapter
            let initial = try #require(adapter.runtimeSnapshot.eventCheckpoint)
            let steer = try await adapter.control(request: .init(
                sourceID: fixture.sourceID, threadID: fixture.threadID, turnID: fixture.turnID,
                operation: .steer, expectedCursor: initial.sourceCursor,
                idempotencyKey: "2877-steer-once", boundedInput: fixture.steerInput), controlGrant: fixture.controlGrant)
            #expect(steer.operation == .steer && steer.outcome == .accepted)
            #expect(steer.turnID == fixture.turnID)
            #expect(await waitUntil { fixture.capture.has("item:steer-accepted") })
            #expect(adapter.runtimeSnapshot.eventCheckpoint?.identity == initial.identity)
            #expect(adapter.runtimeSnapshot.eventCheckpoint!.sequence > initial.sequence)
            let beforeInterrupt = try #require(adapter.runtimeSnapshot.eventCheckpoint)
            let receipt = try await adapter.control(request: .init(
                sourceID: fixture.sourceID, threadID: fixture.threadID, turnID: fixture.turnID,
                operation: .interrupt, expectedCursor: beforeInterrupt.sourceCursor,
                idempotencyKey: "2877-interrupt-once"), controlGrant: fixture.controlGrant)
            #expect(receipt.outcome == .accepted && receipt.operation == .interrupt)
            #expect(!fixture.capture.hasKind(.turnCancelled), "request ACK is not a cancelled-turn event")
            #expect(adapter.runtimeSnapshot.eventCheckpoint == beforeInterrupt)
            try fixture.allow("allow-interrupt-terminal")
            #expect(await waitUntil { fixture.capture.hasKind(.turnCancelled) })
            let confirmed = try #require(adapter.runtimeSnapshot.eventCheckpoint)
            #expect(confirmed.identity == initial.identity)
            #expect(confirmed.sequence > beforeInterrupt.sequence)
            #expect(confirmed.sourceCursor != beforeInterrupt.sourceCursor)
            #expect(adapter.runtimeSnapshot.state == .connected)
            #expect(!adapter.runtimeSnapshot.requiresSideEffectReconciliation)
            try assertWireRequests(fixture)
        }
    }

    @Test func cancelAcknowledgementWaitsForMatchingTerminalAndRejectsForeignAndLate() async throws {
        try await withOwnedFixture(explicitCancel: true) { fixture in
            let adapter = fixture.adapter
            let before = adapter.runtimeSnapshot
            let checkpoint = try #require(before.eventCheckpoint)
            let owner = try #require(before.ownerID)
            let receipt = try await adapter.cancel(sourceID: fixture.sourceID,
                threadID: fixture.threadID, turnID: fixture.turnID,
                expectedCursor: checkpoint.sourceCursor,
                idempotencyKey: "2877-cancel-once", controlGrant: fixture.controlGrant)
            #expect(receipt.outcome == .accepted)
            #expect(adapter.runtimeSnapshot.state == .cancelling,
                    "an empty interrupt ACK cannot confirm the target turn stopped")
            #expect(adapter.runtimeSnapshot.eventCheckpoint == checkpoint)
            #expect(adapter.runtimeSnapshot.unconfirmedControl?.operation == .interrupt)
            #expect(adapter.runtimeSnapshot.unconfirmedControl?.turnID == fixture.turnID)
            #expect(!adapter.runtimeSnapshot.requiresSideEffectReconciliation)
            #expect(!fixture.capture.hasKind(.turnCancelled))
            try fixture.allow("allow-interrupt-terminal")
            #expect(await waitUntil { fixture.capture.hasKind(.turnCancelled) })
            let event = try #require(fixture.capture.event(.turnCancelled))
            #expect(event.turnID == fixture.turnID)
            let confirmed = try #require(adapter.runtimeSnapshot.eventCheckpoint)
            #expect(confirmed.identity == checkpoint.identity)
            #expect(confirmed.sequence > checkpoint.sequence)
            #expect(adapter.runtimeSnapshot.state == .cancelled)
            #expect(adapter.runtimeSnapshot.unconfirmedControl == nil)
            #expect(!adapter.runtimeSnapshot.requiresSideEffectReconciliation)
            #expect(fixture.capture.count(.turnCancelled) == 1,
                    "same-thread foreign-turn terminal must not settle this cancellation")
            let bytes = try Data(contentsOf: fixture.runtimeFile)
            let late = try await adapter.consumeExternalEvent(event,
                correlationID: checkpoint.identity.correlationID,
                attemptID: checkpoint.identity.attemptID, ownerID: owner,
                connectionGeneration: before.generation, readGrant: fixture.eventsGrant)
            #expect(late == .rejectedLateResult || late == .rejectedDisconnected)
            #expect(adapter.runtimeSnapshot.eventCheckpoint == confirmed)
            #expect(try Data(contentsOf: fixture.runtimeFile) == bytes)
            try fixture.allow("allow-late-terminal")
            try assertWireRequests(fixture)
        }
    }

    @Test func matchingTerminalBeforeAcknowledgementIsNotOverwrittenByLateACK() async throws {
        try await withOwnedFixture(explicitCancel: true, terminalBeforeACK: true) { fixture in
            let initial = try #require(fixture.adapter.runtimeSnapshot.eventCheckpoint)
            let pending = Task {
                try await fixture.adapter.cancel(sourceID: fixture.sourceID,
                    threadID: fixture.threadID, turnID: fixture.turnID,
                    expectedCursor: initial.sourceCursor, idempotencyKey: "2877-terminal-before-ack",
                    controlGrant: fixture.controlGrant)
            }
            #expect(await waitUntil { FileManager.default.fileExists(atPath:
                fixture.home.appendingPathComponent("interrupt-observed").path) })
            #expect(fixture.adapter.runtimeSnapshot.state == .cancelling)
            try fixture.allow("allow-interrupt-terminal")
            #expect(await waitUntil { fixture.capture.hasKind(.turnCancelled) })
            #expect(fixture.adapter.runtimeSnapshot.state == .cancelled)
            let confirmed = try #require(fixture.adapter.runtimeSnapshot.eventCheckpoint)
            #expect(confirmed.identity == initial.identity && confirmed.sequence > initial.sequence)
            let durable = try Data(contentsOf: fixture.runtimeFile)
            try fixture.allow("allow-interrupt-ack")
            let receipt = try await pending.value
            #expect(receipt.outcome == .accepted)
            #expect(fixture.adapter.runtimeSnapshot.state == .cancelled)
            #expect(fixture.adapter.runtimeSnapshot.eventCheckpoint == confirmed)
            #expect(fixture.adapter.runtimeSnapshot.unconfirmedControl == nil)
            #expect(!fixture.adapter.runtimeSnapshot.requiresSideEffectReconciliation)
            #expect(try Data(contentsOf: fixture.runtimeFile) == durable)
            try fixture.allow("allow-late-terminal")
            try assertWireRequests(fixture)
        }
    }

    @Test func pendingCancellationCannotBeReplacedByForeignProgressOrApproval() async throws {
        try await withOwnedFixture(explicitCancel: true, pendingNoise: true) { fixture in
            let checkpoint = try #require(fixture.adapter.runtimeSnapshot.eventCheckpoint)
            let receipt = try await fixture.adapter.cancel(sourceID: fixture.sourceID,
                threadID: fixture.threadID, turnID: fixture.turnID,
                expectedCursor: checkpoint.sourceCursor, idempotencyKey: "2877-cancel-noise",
                controlGrant: fixture.controlGrant)
            #expect(receipt.outcome == .accepted)
            // A barrier notification follows both unsolicited noise frames.
            #expect(await waitUntil { FileManager.default.fileExists(atPath:
                fixture.home.appendingPathComponent("foreign-terminal-emitted").path) })
            try fixture.allow("allow-interrupt-terminal")
            #expect(await waitUntil { fixture.capture.hasKind(.turnCancelled) })
            #expect(!fixture.capture.has("item:foreign-progress"))
            #expect(!fixture.capture.hasKind(.approvalRequired))
            #expect(fixture.adapter.runtimeSnapshot.pendingApproval == nil)
            #expect(fixture.adapter.runtimeSnapshot.state == .cancelled)
            #expect(fixture.adapter.runtimeSnapshot.eventCheckpoint?.identity == checkpoint.identity)
            #expect(fixture.adapter.runtimeSnapshot.eventCheckpoint?.sequence == checkpoint.sequence + 1)
        }
    }

    @Test func secondCancelCannotOverwritePendingSubmittedIdentityBeforeTerminal() async throws {
        try await withOwnedFixture(explicitCancel: true) { fixture in
            let initial = try #require(fixture.adapter.runtimeSnapshot.eventCheckpoint)
            _ = try await fixture.adapter.cancel(sourceID: fixture.sourceID,
                threadID: fixture.threadID, turnID: fixture.turnID,
                expectedCursor: initial.sourceCursor, idempotencyKey: "2877-first-pending-cancel",
                controlGrant: fixture.controlGrant)
            let pending = fixture.adapter.runtimeSnapshot
            await #expect(throws: ExternalSessionAppAdapterError.runtimeUnavailable) {
                _ = try await fixture.adapter.cancel(sourceID: fixture.sourceID,
                    threadID: fixture.threadID, turnID: fixture.turnID,
                    expectedCursor: initial.sourceCursor, idempotencyKey: "2877-second-pending-cancel",
                    controlGrant: fixture.controlGrant)
            }
            #expect(fixture.adapter.runtimeSnapshot.state == .cancelling)
            #expect(fixture.adapter.runtimeSnapshot.unconfirmedControl == pending.unconfirmedControl)
            #expect(fixture.adapter.runtimeSnapshot.ownerID == pending.ownerID)
            #expect(fixture.adapter.runtimeSnapshot.generation == pending.generation)
            try fixture.allow("allow-interrupt-terminal")
            #expect(await waitUntil { fixture.capture.hasKind(.turnCancelled) })
            #expect(fixture.adapter.runtimeSnapshot.state == .cancelled)
            try assertWireRequests(fixture)
        }
    }

    @Test func pendingCancellationReopenRetainsExactSubmittedUnknownAndCannotRetry() async throws {
        try await withOwnedFixture(explicitCancel: true) { fixture in
            let initial = try #require(fixture.adapter.runtimeSnapshot.eventCheckpoint)
            _ = try await fixture.adapter.cancel(sourceID: fixture.sourceID,
                threadID: fixture.threadID, turnID: fixture.turnID,
                expectedCursor: initial.sourceCursor, idempotencyKey: "2877-cancel-reopen",
                controlGrant: fixture.controlGrant)
            let record = try #require(fixture.adapter.runtimeSnapshot.unconfirmedControl)
            let reader = ExternalSessionCodexRolloutReadAdapter(sourceID: fixture.sourceID,
                profileID: fixture.controlGrant.profileID, hostID: "synthetic-2877",
                rootURL: fixture.home.appendingPathComponent("sessions", isDirectory: true),
                authorizationLedger: fixture.composition.ledger)
            let reopened = ExternalSessionAppAdapter.production(implementation: reader,
                runtimePersistenceURL: fixture.runtimeFile, authorizationLedger: fixture.composition.ledger)
            #expect(reopened.runtimeSnapshot.requiresSideEffectReconciliation)
            #expect(reopened.runtimeSnapshot.state == .recoveryRequired)
            #expect(reopened.runtimeSnapshot.ownerID == nil)
            #expect(reopened.runtimeSnapshot.unconfirmedControl == record)
            await #expect(throws: ExternalSessionAppAdapterError.sideEffectReconciliationRequired) {
                _ = try await reopened.cancel(sourceID: fixture.sourceID,
                    threadID: fixture.threadID, turnID: fixture.turnID, expectedCursor: initial.sourceCursor,
                    idempotencyKey: "2877-blind-retry", controlGrant: fixture.controlGrant)
            }
            try assertWireRequests(fixture)
        }
    }

    @Test func pendingCancellationRevocationCannotPublishLateTerminalOrRepeatControl() async throws {
        try await withOwnedFixture(explicitCancel: true) { fixture in
            let initial = try #require(fixture.adapter.runtimeSnapshot.eventCheckpoint)
            _ = try await fixture.adapter.cancel(sourceID: fixture.sourceID,
                threadID: fixture.threadID, turnID: fixture.turnID,
                expectedCursor: initial.sourceCursor, idempotencyKey: "2877-cancel-revoke",
                controlGrant: fixture.controlGrant)
            let submitted = try #require(fixture.adapter.runtimeSnapshot.unconfirmedControl)
            // Advance the real production ledger before releasing the owned
            // terminal, so this is an epoch test rather than a scheduling race.
            let revokedEpoch = await fixture.composition.ledger.revoke(sourceID: fixture.sourceID,
                profileID: fixture.controlGrant.profileID)
            #expect(revokedEpoch > fixture.eventsGrant.revocationEpoch)
            try fixture.allow("allow-interrupt-terminal")
            try fixture.allow("allow-late-terminal")
            let epoch = await fixture.composition.revoke(sourceID: fixture.sourceID,
                                                        profileID: fixture.controlGrant.profileID)
            #expect(epoch > fixture.eventsGrant.revocationEpoch)
            #expect(!fixture.capture.hasKind(.turnCancelled))
            #expect(fixture.adapter.runtimeSnapshot.unconfirmedControl == submitted)
            #expect(fixture.adapter.runtimeSnapshot.requiresSideEffectReconciliation)
            #expect(fixture.adapter.runtimeSnapshot.state == .recoveryRequired)
            #expect(fixture.adapter.runtimeSnapshot.eventCheckpoint == initial)
            await #expect(throws: ExternalSessionAppAdapterError.sideEffectReconciliationRequired) {
                _ = try await fixture.adapter.cancel(sourceID: fixture.sourceID,
                    threadID: fixture.threadID, turnID: fixture.turnID, expectedCursor: initial.sourceCursor,
                    idempotencyKey: "2877-after-revoke", controlGrant: fixture.controlGrant)
            }
            try assertWireRequests(fixture)
        }
    }

    @Test func writtenInterruptTimeoutRetainsUnknownAndCannotBecomeCancelled() async throws {
        try await withOwnedFixture(explicitCancel: true, timeoutACK: true) { fixture in
            let initial = try #require(fixture.adapter.runtimeSnapshot.eventCheckpoint)
            await #expect(throws: Error.self) {
                _ = try await fixture.adapter.cancel(sourceID: fixture.sourceID,
                    threadID: fixture.threadID, turnID: fixture.turnID, expectedCursor: initial.sourceCursor,
                    idempotencyKey: "2877-timeout", controlGrant: fixture.controlGrant)
            }
            let submitted = try #require(fixture.adapter.runtimeSnapshot.unconfirmedControl)
            #expect(submitted.threadID == fixture.threadID && submitted.turnID == fixture.turnID)
            #expect(submitted.controlRevocationEpoch == fixture.controlGrant.revocationEpoch)
            #expect(fixture.adapter.runtimeSnapshot.requiresSideEffectReconciliation)
            #expect(fixture.adapter.runtimeSnapshot.state == .recoveryRequired)
            #expect(fixture.adapter.runtimeSnapshot.eventCheckpoint == initial)
            #expect(!fixture.capture.hasKind(.turnCancelled))
            try fixture.allow("allow-interrupt-ack")
            await #expect(throws: ExternalSessionAppAdapterError.sideEffectReconciliationRequired) {
                _ = try await fixture.adapter.cancel(sourceID: fixture.sourceID,
                    threadID: fixture.threadID, turnID: fixture.turnID, expectedCursor: initial.sourceCursor,
                    idempotencyKey: "2877-timeout-repeat", controlGrant: fixture.controlGrant)
            }
            try assertWireRequests(fixture)
        }
    }

    private func withOwnedFixture(explicitCancel: Bool, terminalBeforeACK: Bool = false,
                                 pendingNoise: Bool = false, timeoutACK: Bool = false,
                                 body: (External2877Fixture) async throws -> Void) async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "EXTE-2877")
        defer { try? profile.cleanupDisposableRoots() }
        let home = profile.rootDirectory.appendingPathComponent("owned-codex-home", isDirectory: true)
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        let day = sessions.appendingPathComponent("2026/10/05", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let thread = "12345678-1234-1234-1234-123456789abc"
        let turn = "turn_owned"
        let input = "继续核对自有测试文件，不增加任务范围"
        try Data("""
        {"timestamp":"2026-10-05T00:00:00Z","type":"session_meta","payload":{"id":"\(thread)","cwd":"/synthetic/project","cli_version":"0.151.0"}}
        """.utf8).write(to: day.appendingPathComponent("rollout-2026-10-05T00-00-00-\(thread).jsonl"))
        let scenario: [String: Any] = ["mode": "controlled", "threadID": thread,
                                      "turnID": turn, "steerInput": input, "foreignTerminal": explicitCancel,
                                      "terminalBeforeACK": terminalBeforeACK,
                                      "pendingNoise": pendingNoise, "timeoutACK": timeoutACK]
        try JSONSerialization.data(withJSONObject: scenario).write(to: home.appendingPathComponent("owned-control-scenario.json"))
        // The field fixture and this test share one server source. Copying to
        // the owned root only supplies executable permissions for this run.
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repository.deleteLastPathComponent() }
        let donor = repository.appendingPathComponent("scripts/testing/773-owned-control-server.py")
        let server = profile.rootDirectory.appendingPathComponent("owned-server.py")
        try FileManager.default.copyItem(at: donor, to: server)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: server.path)
        let composition = ProductionOrchestrationDefaults.makeExternalSessionAuthorization(runtimeConsumer: nil)
        composition.configureExternalSourceRegistration(hostID: "synthetic-2877")
        let source = try composition.registerSelectedReadRoot(kind: .codex, rootURL: sessions)
        let profileID = try #require(composition.supervisedProfileID(for: source))
        let threadID = ExternalSessionThreadID(rawValue: thread)
        let runtimeDirectory = profile.rootDirectory.appendingPathComponent("external-runtime", isDirectory: true)
        let runtimeFile = runtimeDirectory.appendingPathComponent("\(source.rawValue).json")
        try composition.configureSyntheticCodexControl(sourceID: source, executableURL: server,
                                                      homeURL: home, runtimeDirectory: runtimeDirectory)
        do {
            let statusGrant = try await composition.issueReadGrant(authorizationID: .init(rawValue: "2877-status"),
                sourceID: source, profileID: profileID, target: .source(source), scopes: [.metadata, .status], lifetime: 60)
            _ = try await composition.activateSelectedReadRoot(sourceID: source, readGrant: statusGrant)
            let control = try await composition.issueControlGrant(authorizationID: .init(rawValue: "2877-control"),
                sourceID: source, profileID: profileID, target: .thread(threadID), operations: [.resume, .steer, .interrupt], lifetime: 60)
            try await composition.activateSyntheticCodexControl(sourceID: source, readGrant: statusGrant, controlGrant: control)
            let adapter = try #require(composition.adapter(for: source))
            let events = try await composition.issueReadGrant(authorizationID: .init(rawValue: "2877-events"),
                sourceID: source, profileID: profileID, target: .thread(threadID), scopes: [.events], lifetime: 60)
            let capture = External2877Capture()
            try await composition.subscribeSyntheticCodexEvents(sourceID: source, threadID: threadID,
                                                               readGrant: events, onEvent: { capture.append($0) })
            let status = try await adapter.status(target: .init(sourceID: source, threadID: threadID), readGrant: statusGrant)
            let resume = try await adapter.control(request: .init(sourceID: source, threadID: threadID,
                operation: .resume, expectedCursor: status.observedCursor, idempotencyKey: "2877-resume-once"), controlGrant: control)
            #expect(resume.outcome == .accepted)
            try Data().write(to: home.appendingPathComponent("allow-turn-started"))
            #expect(await waitUntil { capture.hasKind(.turnStarted) })
            try await body(External2877Fixture(adapter: adapter, sourceID: source, threadID: threadID,
                turnID: .init(rawValue: turn), home: home, runtimeFile: runtimeFile,
                steerInput: input, controlGrant: control, eventsGrant: events, capture: capture,
                composition: composition))
        } catch {
            for marker in ["allow-turn-started", "allow-interrupt-terminal", "allow-interrupt-ack", "allow-late-terminal"] {
                try? Data().write(to: home.appendingPathComponent(marker))
            }
            _ = await composition.revoke(sourceID: source, profileID: profileID)
            throw error
        }
        for marker in ["allow-interrupt-terminal", "allow-interrupt-ack", "allow-late-terminal"] {
            try? Data().write(to: home.appendingPathComponent(marker))
        }
        _ = await composition.revoke(sourceID: source, profileID: profileID)
    }

    private func assertWireRequests(_ fixture: External2877Fixture) throws {
        let lines = try String(contentsOf: fixture.home.appendingPathComponent("requests.jsonl"), encoding: .utf8)
        let requests = try lines.split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        #expect(requests.filter { $0["method"] as? String == "turn/interrupt" }.count == 1)
        if let steer = requests.first(where: { $0["method"] as? String == "turn/steer" }) {
            let params = try #require(steer["params"] as? [String: Any])
            #expect(params["expectedTurnId"] as? String == fixture.turnID.rawValue)
            let input = try #require(params["input"] as? [[String: String]])
            #expect(input == [["type": "text", "text": fixture.steerInput]])
        }
        let interrupt = try #require(requests.first { $0["method"] as? String == "turn/interrupt" })
        let params = try #require(interrupt["params"] as? [String: String])
        #expect(params == ["threadId": fixture.threadID.rawValue, "turnId": fixture.turnID.rawValue])
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

@MainActor
private struct External2877Fixture {
    let adapter: ExternalSessionAppAdapter
    let sourceID: ExternalSessionSourceID
    let threadID: ExternalSessionThreadID
    let turnID: ExternalSessionTurnID
    let home: URL
    let runtimeFile: URL
    let steerInput: String
    let controlGrant: ExternalSessionControlGrantV1
    let eventsGrant: ExternalSessionReadGrantV1
    let capture: External2877Capture
    let composition: ExternalSessionAuthorizationComposition
    func allow(_ marker: String) throws { try Data().write(to: home.appendingPathComponent(marker)) }
}

private final class External2877Capture: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ExternalSessionEventV1] = []
    func append(_ event: ExternalSessionEventV1) { lock.withLock { events.append(event) } }
    func has(_ sourceRef: String) -> Bool { lock.withLock { events.contains { $0.sourceRef == sourceRef } } }
    func hasKind(_ kind: ExternalSessionEventKindV1) -> Bool { lock.withLock { events.contains { $0.kind == kind } } }
    func event(_ kind: ExternalSessionEventKindV1) -> ExternalSessionEventV1? { lock.withLock { events.first { $0.kind == kind } } }
    func count(_ kind: ExternalSessionEventKindV1) -> Int { lock.withLock { events.filter { $0.kind == kind }.count } }
}
