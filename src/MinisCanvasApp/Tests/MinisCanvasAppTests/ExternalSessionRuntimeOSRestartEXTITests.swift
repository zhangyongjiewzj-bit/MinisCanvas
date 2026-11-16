import Foundation
import AppKit
import Darwin
import CryptoKit
import Testing
import MinisCore
@testable import MinisCanvasApp

private struct EXTIOSRequest: Codable {
    let root: URL
    let proof: URL
    let parentPID: Int32
    let nonce: String
}

private struct EXTIOSWriterProof: Codable {
    let writerPID: Int32
    let externalPID: Int32
    let nonce: String
    let sourceID: ExternalSessionSourceID
    let profileID: ExternalSessionProfileID
    let threadID: ExternalSessionThreadID
    let runtimeURL: URL
    let sessionsURL: URL
    let rolloutURL: URL
    let markerURL: URL
    let originalRequest: ExternalSessionControlRequestV1
    let unconfirmed: ExternalSessionUnconfirmedControlV1
    let runtimeSHA256: String
    let externalRequestCount: Int
}

private struct EXTIOSReaderRequest: Codable {
    let writer: EXTIOSWriterProof
    let proof: URL
}

private struct EXTIOSReaderProof: Codable {
    let readerPID: Int32
    let writerPID: Int32
    let externalPID: Int32
    let nonce: String
    let recoveredIdentity: Bool
    let freshReadAuthorization: Bool
    let freshControlAuthorization: Bool
    let foreignSourceRejected: Bool
    let foreignThreadRejected: Bool
    let foreignTurnRejected: Bool
    let observedSucceededButStillUnknown: Bool
    let secondControlRejectedBeforeTransport: Bool
    let externalRequestCount: Int
}

private enum EXTIOSNoReplay: Error { case unexpectedControl }

private final class EXTIOSExitNotice: @unchecked Sendable {
    private let lock = NSLock()
    private var terminatedAt: ContinuousClock.Instant?

    func record() {
        let observedAt = ContinuousClock().now
        lock.lock()
        terminatedAt = observedAt
        lock.unlock()
    }

    func timestamp() -> ContinuousClock.Instant? {
        lock.lock()
        defer { lock.unlock() }
        return terminatedAt
    }
}

private actor EXTIOSControlTransport: ExternalSessionControlTransportV1 {
    private(set) var calls = 0
    func send(request: ExternalSessionControlRequestV1,
              controlGrant: ExternalSessionControlGrantV1) async throws -> ExternalSessionControlReceiptV1 {
        calls += 1
        throw EXTIOSNoReplay.unexpectedControl
    }
}

private struct EXTIOSColdComposite: ExistingAgentSessionAdapter {
    let source: ExternalSessionSourceV1
    let reader: ExternalSessionCodexRolloutReadAdapter
    let controller: ExternalSessionControlLedgerAdapter
    func listThreads(query: ExternalSessionThreadQueryV1,
                     readGrant: ExternalSessionReadGrantV1) async throws -> ExternalSessionThreadPageV1 {
        try await reader.listThreads(query: query, readGrant: readGrant)
    }
    func read(request: ExternalSessionReadRequestV1,
              readGrant: ExternalSessionReadGrantV1) async throws -> ExternalSessionReadPageV1 {
        try await reader.read(request: request, readGrant: readGrant)
    }
    func status(target: ExternalSessionStatusTargetV1,
                readGrant: ExternalSessionReadGrantV1) async throws -> ExternalSessionStatusV1 {
        try await reader.status(target: target, readGrant: readGrant)
    }
    func control(request: ExternalSessionControlRequestV1,
                 controlGrant: ExternalSessionControlGrantV1) async throws -> ExternalSessionControlReceiptV1 {
        try await controller.control(request: request, controlGrant: controlGrant)
    }
}

@Suite("D-EXTI App runtime UNKNOWN survives a distinct OS process", .serialized)
@MainActor
struct ExternalSessionRuntimeOSRestartEXTITests {
    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func markerCount(_ url: URL) throws -> Int {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").count
    }

    private func ownedProcess(filter: String, key: String, request: some Encodable,
                              root: URL, log: String) throws -> (Process, URL, FileHandle) {
        let executable = try #require(CommandLine.arguments.first)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        if let flag = CommandLine.arguments.firstIndex(of: "--test-bundle-path") {
            let bundle = try #require(CommandLine.arguments.indices.contains(flag + 1)
                                      ? CommandLine.arguments[flag + 1] : nil)
            process.arguments = ["--test-bundle-path", bundle, "--testing-library", "swift-testing",
                                 "--filter", filter]
        } else {
            process.arguments = ["--testing-library", "swift-testing", "--no-parallel",
                                 "--filter", filter]
        }
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "EXTI_OS_WRITER_REQUEST")
        environment.removeValue(forKey: "EXTI_OS_READER_REQUEST")
        environment[key] = try JSONEncoder().encode(request).base64EncodedString()
        process.environment = environment
        let path = root.appendingPathComponent(log)
        try #require(FileManager.default.createFile(atPath: path.path, contents: nil))
        let handle = try FileHandle(forWritingTo: path)
        process.standardOutput = handle
        process.standardError = handle
        return (process, path, handle)
    }

    private func runNaturally(_ process: Process, phase: String, log: URL) async throws -> Bool {
        let expectedExecutable = try #require(process.executableURL)
            .resolvingSymlinksInPath().standardizedFileURL
        let clock = ContinuousClock()
        let notice = EXTIOSExitNotice()
        process.terminationHandler = { _ in notice.record() }
        try process.run()
        let pid = process.processIdentifier
        let businessDeadline = clock.now + .seconds(20)
        print("EXTI_OS_OWNED_PROCESS phase=\(phase) pid=\(pid) executable=\(expectedExecutable.path) startedAt=\(Date().timeIntervalSince1970)")
        var launchDate: Date?
        var exited = false

        func recordLaunchIfAvailable() {
            guard launchDate == nil,
                  let app = NSRunningApplication(processIdentifier: pid),
                  let date = app.launchDate else { return }
            launchDate = date
            let observedExecutable = app.executableURL?.path ?? "unavailable"
            print("EXTI_OS_OWNED_START phase=\(phase) pid=\(pid) launch=\(date.timeIntervalSince1970) executable=\(observedExecutable)")
        }
        func sameOwnedProcessIsLive() -> Bool {
            // This retained Process has not terminated or been reaped; its PID cannot be reused.
            // LaunchServices registration and launchDate are optional diagnostics only.
            process.processIdentifier == pid && process.isRunning && notice.timestamp() == nil
        }
        func pauseForExitDelivery() async {
            // Unlike a blocking semaphore wait, this leaves the native event loop responsive.
            // Cancellation must not abandon the directly owned worker or its open log handles.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { continuation.resume() }
            }
        }
        func observeExit(until deadline: ContinuousClock.Instant) async -> Bool {
            while !exited {
                recordLaunchIfAvailable()
                exited = notice.timestamp() != nil
                if exited || clock.now >= deadline { break }
                await pauseForExitDelivery()
            }
            return exited
        }
        let observedBusinessExit = await observeExit(until: businessDeadline)
        let launchDescription = launchDate.map { String($0.timeIntervalSince1970) } ?? "unavailable"
        print("EXTI_OS_LAUNCH_DATE phase=\(phase) pid=\(pid) available=\(launchDate != nil) launch=\(launchDescription)")
        if observedBusinessExit,
           let terminatedAt = notice.timestamp(), terminatedAt <= businessDeadline {
            print("EXTI_OS_OWNED_EXIT phase=\(phase) pid=\(pid) natural=true reason=\(process.terminationReason.rawValue) status=\(process.terminationStatus)")
            return false
        }

        // A late termination, including status zero, cannot turn this fixed failure into PASS.
        Issue.record("EXTI owned \(phase) exceeded the original 20-second natural-exit guard")
        print("EXTI_OS_TIMEOUT_FAIL phase=\(phase) pid=\(pid) log=\(log.path)")
        if sameOwnedProcessIsLive() {
            print("EXTI_OS_FAILURE_CLEANUP phase=\(phase) pid=\(pid) signal=TERM launch=\(launchDescription)")
            process.terminate()
            _ = await observeExit(until: clock.now + .seconds(2))
            if !exited, sameOwnedProcessIsLive() {
                let result = kill(pid, SIGKILL)
                let failure = result == 0 ? 0 : errno
                print("EXTI_OS_FAILURE_CLEANUP phase=\(phase) pid=\(pid) signal=KILL result=\(result) errno=\(failure) launch=\(launchDescription)")
                // This second bounded interval observes KILL delivery, never extends the business guard.
                _ = await observeExit(until: clock.now + .seconds(2))
            }
        }
        if !exited {
            print("EXTI_OS_STOP_BATCH_OWNED_PROCESS_STILL_LIVE phase=\(phase) pid=\(pid) log=\(log.path) userInterventionRequired=true furtherSignals=0")
            // Explicit custody HOLD, not another business wait or a successful test return.
            // Keep this Process and the caller's log handles alive until actual termination;
            // no reader/next leaf can start, and no more automatic signals are sent.
            while !exited {
                await pauseForExitDelivery()
                exited = notice.timestamp() != nil
            }
        }
        print("EXTI_OS_OWNED_EXIT phase=\(phase) pid=\(pid) natural=false reason=\(process.terminationReason.rawValue) status=\(process.terminationStatus)")
        return true
    }

    @Test func actualCompositionUnknownSurvivesWriterExitAndColdReader() async throws {
        let profile = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = profile.rootDirectory.appendingPathComponent("exti-os-" + UUID().uuidString,
                                                                 isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let nonce = UUID().uuidString
        let writerProofURL = root.appendingPathComponent("writer-proof.json")
        let writerRequest = EXTIOSRequest(root: root, proof: writerProofURL,
                                          parentPID: getpid(), nonce: nonce)
        let (writer, writerLog, writerHandle) = try ownedProcess(
            filter: "writeUnknownThroughActualComposition()", key: "EXTI_OS_WRITER_REQUEST",
            request: writerRequest, root: root, log: "writer.raw.log")
        defer { try? writerHandle.close() }
        let writerTimedOut = try await runNaturally(writer, phase: "writer", log: writerLog)
        try writerHandle.synchronize()
        let writerRaw = try String(contentsOf: writerLog, encoding: .utf8)
        print("EXTI_OS_WRITER pid=\(writer.processIdentifier) exit=\(writer.terminationStatus) rawSHA=\(digest(Data(writerRaw.utf8)))")
        try #require(!writerTimedOut && writer.terminationStatus == 0)
        try #require(writerRaw.contains("Test writeUnknownThroughActualComposition() passed after")
                     && writerRaw.contains("Test run with 1 test in 1 suite passed after"))
        let writerProof = try JSONDecoder().decode(EXTIOSWriterProof.self,
                                                   from: Data(contentsOf: writerProofURL))
        try #require(writerProof.writerPID == writer.processIdentifier
                     && writerProof.writerPID != getpid() && writerProof.nonce == nonce)
        #expect(writerProof.externalRequestCount == 1)
        #expect(try markerCount(writerProof.markerURL) == 1)
        #expect(writerProof.externalPID != writerProof.writerPID
                && writerProof.externalPID != getpid())
        #expect(kill(writerProof.externalPID, 0) == -1 && errno == ESRCH)
        #expect(digest(try Data(contentsOf: writerProof.runtimeURL)) == writerProof.runtimeSHA256)

        // Another producer can complete the target after the writer exits;
        // its state is not a receipt for this specific resume call.
        var transcript = try Data(contentsOf: writerProof.rolloutURL)
        transcript.append(Data("\n".utf8))
        transcript.append(Data("""
        {"timestamp":"2026-10-01T00:00:01Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"synthetic foreign completion"}]}}
        {"timestamp":"2026-10-01T00:00:02Z","type":"event_msg","payload":{"type":"task_complete"}}
        """.utf8))
        try transcript.write(to: writerProof.rolloutURL)

        let readerProofURL = root.appendingPathComponent("reader-proof.json")
        let readerRequest = EXTIOSReaderRequest(writer: writerProof, proof: readerProofURL)
        let (reader, readerLog, readerHandle) = try ownedProcess(
            filter: "coldProcessReopensUnknownWithNewLegalGrants()",
            key: "EXTI_OS_READER_REQUEST", request: readerRequest,
            root: root, log: "reader.raw.log")
        defer { try? readerHandle.close() }
        let readerTimedOut = try await runNaturally(reader, phase: "reader", log: readerLog)
        try readerHandle.synchronize()
        let readerRaw = try String(contentsOf: readerLog, encoding: .utf8)
        print("EXTI_OS_READER pid=\(reader.processIdentifier) exit=\(reader.terminationStatus) rawSHA=\(digest(Data(readerRaw.utf8)))")
        try #require(!readerTimedOut && reader.terminationStatus == 0)
        try #require(readerRaw.contains("Test coldProcessReopensUnknownWithNewLegalGrants() passed after")
                     && readerRaw.contains("Test run with 1 test in 1 suite passed after"))
        let readerProof = try JSONDecoder().decode(EXTIOSReaderProof.self,
                                                   from: Data(contentsOf: readerProofURL))
        #expect(readerProof.writerPID == writerProof.writerPID
                && readerProof.externalPID == writerProof.externalPID
                && readerProof.readerPID == reader.processIdentifier
                && readerProof.readerPID != writerProof.writerPID
                && readerProof.readerPID != getpid() && readerProof.nonce == nonce)
        #expect(readerProof.recoveredIdentity && readerProof.freshReadAuthorization
                && readerProof.freshControlAuthorization)
        #expect(readerProof.foreignSourceRejected && readerProof.foreignThreadRejected
                && readerProof.foreignTurnRejected)
        #expect(readerProof.observedSucceededButStillUnknown
                && readerProof.secondControlRejectedBeforeTransport)
        #expect(readerProof.externalRequestCount == 1)
        #expect(try markerCount(writerProof.markerURL) == 1)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["EXTI_OS_WRITER_REQUEST"] != nil))
    func writeUnknownThroughActualComposition() async throws {
        let encoded = try #require(ProcessInfo.processInfo.environment["EXTI_OS_WRITER_REQUEST"])
        let request = try JSONDecoder().decode(EXTIOSRequest.self,
                                                from: #require(Data(base64Encoded: encoded)))
        try #require(getpid() != request.parentPID)
        let home = request.root.appendingPathComponent("owned-codex-home", isDirectory: true)
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        let day = sessions.appendingPathComponent("2026/10/01", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let thread = "12345678-1234-1234-1234-123456789abc"
        let threadID = ExternalSessionThreadID(rawValue: thread)
        let rollout = day.appendingPathComponent("rollout-2026-10-01T00-00-00-\(thread).jsonl")
        try Data("""
        {"timestamp":"2026-10-01T00:00:00Z","type":"session_meta","payload":{"id":"\(thread)","cwd":"/synthetic/project","cli_version":"0.151.0"}}
        """.utf8).write(to: rollout)
        let server = request.root.appendingPathComponent("synthetic-codex-server.py")
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
                    marker.write(str(os.getpid()) + '\n')
                sys.exit(0)
        """#.utf8).write(to: server)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: server.path)
        let composition = ProductionOrchestrationDefaults.makeExternalSessionAuthorization(runtimeConsumer: nil)
        composition.configureExternalSourceRegistration(hostID: "synthetic-test-host")
        let sourceID = try composition.registerSelectedReadRoot(kind: .codex, rootURL: sessions)
        let profileID = try #require(composition.supervisedProfileID(for: sourceID))
        let runtimeDirectory = request.root.appendingPathComponent("external-session-runtime", isDirectory: true)
        try composition.configureSyntheticCodexControl(sourceID: sourceID, executableURL: server,
            homeURL: home, runtimeDirectory: runtimeDirectory)
        let readGrant = try await composition.issueReadGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "exti-os-writer-read-\(request.nonce)"),
            sourceID: sourceID, profileID: profileID, target: .source(sourceID),
            scopes: [.metadata, .status], lifetime: 60)
        _ = try await composition.activateSelectedReadRoot(sourceID: sourceID, readGrant: readGrant)
        let controlGrant = try await composition.issueControlGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "exti-os-writer-control-\(request.nonce)"),
            sourceID: sourceID, profileID: profileID, target: .thread(threadID),
            operations: [.resume], lifetime: 60)
        try await composition.activateSyntheticCodexControl(sourceID: sourceID,
            readGrant: readGrant, controlGrant: controlGrant)
        let adapter = try #require(composition.adapter(for: sourceID))
        let status = try await adapter.status(
            target: ExternalSessionStatusTargetV1(sourceID: sourceID, threadID: threadID),
            readGrant: readGrant)
        let original = ExternalSessionControlRequestV1(
            sourceID: sourceID, threadID: threadID, operation: .resume,
            expectedCursor: status.observedCursor, idempotencyKey: "exti-os-once")
        await #expect(throws: Error.self) {
            _ = try await adapter.control(request: original, controlGrant: controlGrant)
        }
        let unknown = try #require(adapter.runtimeSnapshot.unconfirmedControl)
        #expect(adapter.runtimeSnapshot.requiresSideEffectReconciliation)
        #expect(unknown.sourceID == sourceID && unknown.profileID == profileID)
        #expect(unknown.threadID == threadID && unknown.turnID == nil)
        #expect(unknown.operation == .resume && unknown.controlAuthorizationID == controlGrant.authorizationID)
        let runtimeURL = runtimeDirectory.appendingPathComponent("\(sourceID.rawValue).json")
        let marker = home.appendingPathComponent("resume-requests")
        let count = try markerCount(marker)
        #expect(count == 1)
        let externalPID = try #require(Int32(try String(contentsOf: marker,
            encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(externalPID != getpid())
        let proof = EXTIOSWriterProof(writerPID: getpid(), externalPID: externalPID,
            nonce: request.nonce,
            sourceID: sourceID, profileID: profileID, threadID: threadID,
            runtimeURL: runtimeURL, sessionsURL: sessions, rolloutURL: rollout,
            markerURL: marker, originalRequest: original, unconfirmed: unknown,
            runtimeSHA256: digest(try Data(contentsOf: runtimeURL)), externalRequestCount: count)
        try JSONEncoder().encode(proof).write(to: request.proof)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["EXTI_OS_READER_REQUEST"] != nil))
    func coldProcessReopensUnknownWithNewLegalGrants() async throws {
        let encoded = try #require(ProcessInfo.processInfo.environment["EXTI_OS_READER_REQUEST"])
        let request = try JSONDecoder().decode(EXTIOSReaderRequest.self,
                                                from: #require(Data(base64Encoded: encoded)))
        let writer = request.writer
        try #require(getpid() != writer.writerPID)
        #expect(digest(try Data(contentsOf: writer.runtimeURL)) == writer.runtimeSHA256)
        let ledger = ExternalSessionAuthorizationLedgerV1()
        let reader = ExternalSessionCodexRolloutReadAdapter(
            sourceID: writer.sourceID, profileID: writer.profileID,
            hostID: "synthetic-test-host", rootURL: writer.sessionsURL,
            authorizationLedger: ledger)
        let source = ExternalSessionSourceV1(sourceID: writer.sourceID, kind: .codex,
            adapterVersion: reader.source.adapterVersion + "+codex-app-server-verified",
            profileID: writer.profileID, hostID: "synthetic-test-host",
            capabilities: reader.source.capabilities.union([.resume]), authState: .authorized)
        let transport = EXTIOSControlTransport()
        let controller = ExternalSessionControlLedgerAdapter(source: source,
            ledger: ledger, transport: transport)
        let composition = ExternalSessionAuthorizationComposition(ledger: ledger, runtimeConsumer: nil)
        let adapter = composition.makeAdapter(
            implementation: EXTIOSColdComposite(source: source, reader: reader, controller: controller),
            runtimePersistenceURL: writer.runtimeURL)
        let restored = try #require(adapter.runtimeSnapshot.unconfirmedControl)
        #expect(restored == writer.unconfirmed)
        #expect(adapter.runtimeSnapshot.requiresSideEffectReconciliation)
        // Cold process authorization is newly issued for the same frozen
        // source and target. No writer-process grant is inserted here.
        let readGrant = try await composition.issueReadGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "exti-os-reader-read-\(writer.nonce)"),
            sourceID: writer.sourceID, profileID: writer.profileID,
            target: .source(writer.sourceID), scopes: [.metadata, .status], lifetime: 60)
        let controlGrant = try await composition.issueControlGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "exti-os-reader-control-\(writer.nonce)"),
            sourceID: writer.sourceID, profileID: writer.profileID,
            target: .thread(writer.threadID), operations: [.resume], lifetime: 60)
        #expect(readGrant.authorizationID != restored.controlAuthorizationID)
        #expect(controlGrant.authorizationID != restored.controlAuthorizationID)
        #expect(await ledger.isAuthorizationActive(sourceID: writer.sourceID,
            profileID: writer.profileID, revocationEpoch: readGrant.revocationEpoch))
        let handshake = try await adapter.reconnect(readGrant: readGrant)
        #expect(handshake.state == .recoveryRequired && handshake.requiresSideEffectReconciliation)
        #expect(adapter.runtimeSnapshot.unconfirmedControl == writer.unconfirmed)
        let foreignSource = ExternalSessionSourceID(rawValue: "foreign-source")
        let foreignProfile = ExternalSessionProfileID(rawValue: "foreign-profile")
        let foreignGrant = try await ledger.issueReadGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "exti-os-foreign-\(writer.nonce)"),
            sourceID: foreignSource, profileID: foreignProfile,
            target: .source(foreignSource), scopes: [.status], lifetime: 60)
        await #expect(throws: ExternalSessionAppAdapterError.sourceMismatch) {
            _ = try await adapter.reconcileExternalSideEffect(
                threadID: writer.threadID, turnID: nil, readGrant: foreignGrant)
        }
        await #expect(throws: ExternalSessionAppAdapterError.targetMismatch) {
            _ = try await adapter.reconcileExternalSideEffect(
                threadID: ExternalSessionThreadID(rawValue: "foreign-thread"),
                turnID: nil, readGrant: readGrant)
        }
        await #expect(throws: ExternalSessionAppAdapterError.targetMismatch) {
            _ = try await adapter.reconcileExternalSideEffect(
                threadID: writer.threadID,
                turnID: ExternalSessionTurnID(rawValue: "foreign-turn"), readGrant: readGrant)
        }
        let observed = try await adapter.reconcileExternalSideEffect(
            threadID: writer.threadID, turnID: nil, readGrant: readGrant)
        #expect(observed.turnStatus == .succeeded)
        #expect(adapter.runtimeSnapshot.requiresSideEffectReconciliation)
        #expect(adapter.runtimeSnapshot.unconfirmedControl?.sourceID == writer.sourceID)
        #expect(adapter.runtimeSnapshot.unconfirmedControl?.profileID == writer.profileID)
        #expect(adapter.runtimeSnapshot.unconfirmedControl?.threadID == writer.threadID)
        #expect(adapter.runtimeSnapshot.unconfirmedControl?.turnID == nil)
        #expect(adapter.runtimeSnapshot.unconfirmedControl?.operation == .resume)
        #expect(adapter.runtimeSnapshot.unconfirmedControl?.controlAuthorizationID == writer.unconfirmed.controlAuthorizationID)
        #expect(adapter.runtimeSnapshot.unconfirmedControl?.observedTurnStatus == .succeeded)
        await #expect(throws: ExternalSessionAppAdapterError.sideEffectReconciliationRequired) {
            _ = try await adapter.control(request: writer.originalRequest, controlGrant: controlGrant)
        }
        #expect(await transport.calls == 0)
        let count = try markerCount(writer.markerURL)
        #expect(count == 1)
        let readerPID = getpid()
        let originalAuthorization = restored.controlAuthorizationID
        let readIsFresh = readGrant.authorizationID != originalAuthorization
        let controlIsFresh = controlGrant.authorizationID != originalAuthorization
        let stillUnknown = observed.turnStatus == .succeeded
            && adapter.runtimeSnapshot.requiresSideEffectReconciliation
        let didNotTransport = await transport.calls == 0
        let proof = EXTIOSReaderProof(readerPID: readerPID, writerPID: writer.writerPID,
            externalPID: writer.externalPID,
            nonce: writer.nonce, recoveredIdentity: restored == writer.unconfirmed,
            freshReadAuthorization: readIsFresh, freshControlAuthorization: controlIsFresh,
            foreignSourceRejected: true, foreignThreadRejected: true, foreignTurnRejected: true,
            observedSucceededButStillUnknown: stillUnknown,
            secondControlRejectedBeforeTransport: didNotTransport,
            externalRequestCount: count)
        try JSONEncoder().encode(proof).write(to: request.proof)
    }
}
