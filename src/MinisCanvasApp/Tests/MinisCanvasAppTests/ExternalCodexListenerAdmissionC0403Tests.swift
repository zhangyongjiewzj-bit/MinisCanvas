import Foundation
import Dispatch
import Darwin
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

// Test-only extension holds the actual ledger executor at the public actor hop.
// It adds no production hook and releases on every test path or its own deadline.
private final class C0403LedgerGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    private var expired = false
    func hold() {
        condition.lock()
        entered = true
        condition.broadcast()
        let deadline = Date().addingTimeInterval(15)
        while !released && Date() < deadline { _ = condition.wait(until: deadline) }
        expired = !released
        condition.unlock()
    }
    func open() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    func snapshot() -> (entered: Bool, released: Bool, expired: Bool) {
        condition.lock(); defer { condition.unlock() }
        return (entered, released, expired)
    }
}
private extension ExternalSessionAuthorizationLedgerV1 {
    func c0403HoldOwnedTestExecutor(_ gate: C0403LedgerGate) { gate.hold() }
}
@MainActor private final class C0403CallerState {
    var secondFinished = false
}

@Suite("D-CONC2 C0403 actual composition subscription admission", .serialized)
@MainActor
struct ExternalCodexListenerAdmissionC0403Tests {
    @Test
    func laterAdmissionIsRejectedBeforeLedgerHopWithoutCreatingListenerWork() async throws {
        try await exercise(cancelFirstBeforeAuthorization: false)
    }

    @Test
    func cancelledPendingAdmissionReleasesReservationBeforeARealRetry() async throws {
        try await exercise(cancelFirstBeforeAuthorization: true)
    }

    private func exercise(cancelFirstBeforeAuthorization: Bool) async throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = formal.rootDirectory.appendingPathComponent("C0403-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try #require(root.path.hasPrefix("/Users/") && root.resolvingSymlinksInPath() == root)
        let home = root.appendingPathComponent("owned-home", isDirectory: true)
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        let runtime = root.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let server = root.appendingPathComponent("owned-c0403.py")
        try Data(#"""
        #!/usr/bin/python3 -IS
        import json, os, select, sys, time
        home=os.environ['CODEX_HOME']
        with os.fdopen(os.open(os.path.join(home,'identity.json'),os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600),'w') as f:
            json.dump({'pid':os.getpid(),'ppid':os.getppid(),'uid':os.getuid()},f)
        deadline=time.monotonic()+90
        while time.monotonic()<deadline and not os.path.exists(os.path.join(home,'retire')):
            if not select.select([sys.stdin],[],[],0.01)[0]: continue
            line=sys.stdin.readline()
            if not line: break
            req=json.loads(line)
            if req.get('method')=='initialize':
                print(json.dumps({'id':req['id'],'result':{'userAgent':'miniscanvas/0.151.0 (owned C0403)','platformFamily':'unix','platformOs':'macos'}}),flush=True)
            elif req.get('method')=='thread/resume':
                print(json.dumps({'id':req['id'],'result':{'thread':{'id':req['params']['threadId']}}}),flush=True)
        """#.utf8).write(to: server)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: server.path)
        let composition = ExternalSessionAuthorizationComposition()
        composition.configureExternalSourceRegistration(hostID: "owned-c0403-host")
        let source = try composition.registerSelectedReadRoot(kind: .codex, rootURL: sessions)
        let profile = try #require(composition.supervisedProfileID(for: source))
        let thread = ExternalSessionThreadID(rawValue: "owned-c0403-thread")
        let status = try await composition.issueReadGrant(authorizationID: .init(rawValue: "c0403-status"),
            sourceID: source, profileID: profile, target: .source(source), scopes: [.metadata, .status], lifetime: 90)
        _ = try await composition.activateSelectedReadRoot(sourceID: source, readGrant: status)
        let control = try await composition.issueControlGrant(authorizationID: .init(rawValue: "c0403-control"),
            sourceID: source, profileID: profile, target: .thread(thread), operations: [.resume], lifetime: 90)
        try composition.configureSyntheticCodexControl(sourceID: source, executableURL: server,
                                                       homeURL: home, runtimeDirectory: runtime)
        try await composition.activateSyntheticCodexControl(sourceID: source, readGrant: status, controlGrant: control)
        let completion = await composition.ownedCodexTermination(sourceID: source)
        let events: ExternalSessionReadGrantV1
        do {
            events = try await composition.issueReadGrant(authorizationID: .init(rawValue: "c0403-events"),
                sourceID: source, profileID: profile, target: .thread(thread), scopes: [.events], lifetime: 90)
        } catch {
            try? Data().write(to: home.appendingPathComponent("retire"))
            _ = await composition.revoke(sourceID: source, profileID: profile)
            if let completion { _ = try await completion.wait() }
            throw error
        }
        let ledger = composition.ledger
        let gate = C0403LedgerGate()
        let ledgerHolder = Task.detached { await ledger.c0403HoldOwnedTestExecutor(gate) }
        let state = C0403CallerState()
        var first: Task<Result<Void, any Error>, Never>?
        var second: Task<Result<Void, any Error>, Never>?
        var retry: Task<Result<Void, any Error>, Never>?
        var firstResult: Result<Void, any Error>?
        var secondResult: Result<Void, any Error>?
        var retryResult: Result<Void, any Error>?
        var secondFinishedWhileLedgerHeld = false
        var admissionOccupiedWhileLedgerHeld = false
        var noPublishedListenerAfterCancelledJoin = false
        var businessError: (any Error)?
        @MainActor func subscribe() async -> Result<Void, any Error> {
            do { try await composition.subscribeSyntheticCodexEvents(sourceID: source, threadID: thread, readGrant: events); return .success(()) }
            catch { return .failure(error) }
        }
        do {
            try #require(try await waitUntil { gate.snapshot().entered })
            first = Task { await subscribe() }
            try #require(try await waitUntil { composition.hasActiveCodexEventListener(for: source) })
            // The real production busy projection includes the admission reservation.
            // This ledger executor is still held, so A cannot yet create its listener Task.
            second = Task { let result = await subscribe(); state.secondFinished = true; return result }
            secondFinishedWhileLedgerHeld = try await waitUntil { state.secondFinished }
            admissionOccupiedWhileLedgerHeld = composition.hasActiveCodexEventListener(for: source)
            if cancelFirstBeforeAuthorization { first?.cancel() }
            gate.open()
            await ledgerHolder.value
            if let first { firstResult = await first.value }
            if let second { secondResult = await second.value }
            if cancelFirstBeforeAuthorization {
                noPublishedListenerAfterCancelledJoin = !composition.hasActiveCodexEventListener(for: source)
                retry = Task { await subscribe() }
                retryResult = await retry?.value
            }
        } catch { businessError = error }
        // No assertion/throw skips releasing the held actor or original caller joins.
        gate.open()
        await ledgerHolder.value
        try? Data().write(to: home.appendingPathComponent("retire"))
        _ = await composition.revoke(sourceID: source, profileID: profile)
        if let first { firstResult = await first.value }
        if let second { secondResult = await second.value }
        if let retry { retryResult = await retry.value }
        let ownedCompletion = try #require(completion)
        let receipt = try await ownedCompletion.wait()
        let secondRejected: Bool
        if case .failure(let error) = secondResult,
           let typed = error as? ExternalSessionAppAdapterError, typed == .runtimeUnavailable { secondRejected = true }
        else { secondRejected = false }
        let firstSucceeded: Bool
        if case .success = firstResult { firstSucceeded = true } else { firstSucceeded = false }
        let firstCancelled: Bool
        if case .failure(let error) = firstResult, error is CancellationError { firstCancelled = true }
        else { firstCancelled = false }
        let retrySucceeded: Bool
        if case .success = retryResult { retrySucceeded = true } else { retrySucceeded = false }
        let evidence: [String: Any] = ["root": root.path, "cancelFirstBeforeAuthorization": cancelFirstBeforeAuthorization,
            "secondFinishedWhileLedgerHeld": secondFinishedWhileLedgerHeld, "secondRejected": secondRejected,
            "admissionOccupiedWhileLedgerHeld": admissionOccupiedWhileLedgerHeld,
            "firstSucceeded": firstSucceeded, "firstCancelled": firstCancelled,
            "noPublishedListenerAfterCancelledJoin": noPublishedListenerAfterCancelledJoin, "retrySucceeded": retrySucceeded,
            "ledgerGateExpired": gate.snapshot().expired, "ledgerHolderJoined": true,
            "firstCallerJoined": first != nil, "secondCallerJoined": second != nil, "retryCallerJoined": retry != nil,
            "rejectedListenerTaskCreation": "ZERO_BY_PRE_AWAIT_GUARD_SOURCE_POSITION_NOT_A_RUNTIME_TASK_COUNTER",
            "ownedReceiptComplete": receipt.isComplete, "ownerID": receipt.ownerID.uuidString,
            "pid": receipt.processIdentifier ?? -1, "processWaited": receipt.processWaited,
            "readerEOF": receipt.readerReachedEOF, "parserJoined": receipt.parserTasksJoined,
            "requestJoined": receipt.requestTasksJoined, "callbackJoined": receipt.callbackTasksJoined,
            "allPipeHandlesClosed": receipt.allPipeHandlesClosed,
            "listenerAbsentAfterRevoke": !composition.hasActiveCodexEventListener(for: source)]
        let data = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("ACTUAL_C0403_ADMISSION.json"))
        FileHandle.standardError.write(Data(("C0403_ADMISSION_ACTUAL " + String(decoding: data, as: UTF8.self) + "\n").utf8))
        if let businessError { throw businessError }
        #expect(secondFinishedWhileLedgerHeld)
        #expect(secondRejected)
        #expect(admissionOccupiedWhileLedgerHeld)
        #expect(!gate.snapshot().expired)
        #expect(receipt.isComplete)
        #expect(!composition.hasActiveCodexEventListener(for: source))
        if cancelFirstBeforeAuthorization {
            #expect(firstCancelled && noPublishedListenerAfterCancelledJoin && retrySucceeded)
        } else { #expect(firstSucceeded) }
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws -> Bool {
        for _ in 0..<100 {
            if predicate() { return true }
            try await Task.sleep(for: .milliseconds(5))
        }
        return predicate()
    }
}
