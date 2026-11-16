import Foundation
import Darwin
import Testing
import MinisCore
@testable import MinisCanvasApp

@MainActor private final class ARCH1ConnectFinished { var value = false }

private actor ARCH1StatusBarrier {
    private var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func hasEntered() -> Bool { entered }
    func open() { released = true; continuation?.resume(); continuation = nil }
}

private struct ARCH1StatusAdapter: ExistingAgentSessionAdapter {
    let source: ExternalSessionSourceV1
    let barrier: ARCH1StatusBarrier?
    func listThreads(query: ExternalSessionThreadQueryV1, readGrant: ExternalSessionReadGrantV1) async throws -> ExternalSessionThreadPageV1 {
        ExternalSessionThreadPageV1(sourceID: source.sourceID, threads: [], observedCursor: query.cursor)
    }
    func read(request: ExternalSessionReadRequestV1, readGrant: ExternalSessionReadGrantV1) async throws -> ExternalSessionReadPageV1 {
        ExternalSessionReadPageV1(sourceID: source.sourceID, threadID: request.threadID, turns: [], events: [], observedCursor: request.cursor)
    }
    func status(target: ExternalSessionStatusTargetV1, readGrant: ExternalSessionReadGrantV1) async throws -> ExternalSessionStatusV1 {
        if let barrier { await barrier.wait() }
        return ExternalSessionStatusV1(sourceID: source.sourceID, threadID: target.threadID,
            turnID: target.turnID, threadStatus: .active, observedCursor: .beginning)
    }
    func control(request: ExternalSessionControlRequestV1, controlGrant: ExternalSessionControlGrantV1) async throws -> ExternalSessionControlReceiptV1 {
        throw ExternalSessionAppAdapterError.operationNotGranted(request.operation)
    }
}

@Suite("D-ARCH1 production same-source connection admission", .serialized)
@MainActor
struct ExternalRuntimeConnectionAdmissionTests {
    @Test("owned memory connect admits only one source generation")
    func ownedMemoryDoubleConnectHasOneRuntimeWriter() async throws {
        try await exercise(ownedMemory: true)
    }

    @Test("synthetic control connect shares the source admission fence")
    func syntheticControlDoubleConnectHasOneRuntimeWriter() async throws {
        try await exercise(ownedMemory: false)
    }

    @Test("retired runtime rejects pending callback and retained old grant before any write")
    func replacementAndRevocationRejectOldAdapterWrites() async throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = formal.rootDirectory.appendingPathComponent("ARCH1-retire-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try #require(root.path.hasPrefix("/Users/") && root.resolvingSymlinksInPath() == root)
        let url = root.appendingPathComponent("runtime.json")
        let source = ExternalSessionSourceV1(sourceID: .init(rawValue: "arch1-owned-source"),
            kind: .codex, adapterVersion: "owned-status-barrier", profileID: .init(rawValue: "arch1-profile"),
            hostID: "arch1-host", capabilities: [.readMetadata, .status, .stream], authState: .authorized)
        let composition = ExternalSessionAuthorizationComposition()
        let barrier = ARCH1StatusBarrier()
        let old = composition.makeAdapter(implementation: ARCH1StatusAdapter(source: source, barrier: barrier),
                                          runtimePersistenceURL: url)
        let grant = try await composition.issueReadGrant(authorizationID: .init(rawValue: "arch1-original-status"),
            sourceID: source.sourceID, profileID: source.profileID, target: .source(source.sourceID),
            scopes: [.status], lifetime: 90)
        let oldTask = Task { () -> Result<ExternalSessionRuntimeSnapshot, any Error> in
            do { return .success(try await old.connect(readGrant: grant)) }
            catch { return .failure(error) }
        }
        var newTask: Task<Result<ExternalSessionRuntimeSnapshot, any Error>, Never>?
        var oldResult: Result<ExternalSessionRuntimeSnapshot, any Error>?
        var newResult: Result<ExternalSessionRuntimeSnapshot, any Error>?
        var businessError: (any Error)?
        var bytesB: Data?
        var lateCallbackBytesEqual = false
        var retainedOldConnectRejected = false
        var revokedOldReconnectRejected = false
        do {
            var entered = false
            for _ in 0..<400 {
                if await barrier.hasEntered() { entered = true; break }
                try await Task.sleep(for: .milliseconds(5))
            }
            try #require(entered)
            let replacement = composition.makeAdapter(
                implementation: ARCH1StatusAdapter(source: source, barrier: nil), runtimePersistenceURL: url)
            newTask = Task {
                do { return .success(try await replacement.connect(readGrant: grant)) }
                catch { return .failure(error) }
            }
            newResult = await newTask?.value
            bytesB = try Data(contentsOf: url)
            _ = try JSONSerialization.jsonObject(with: try #require(bytesB))
            await barrier.open()
            oldResult = await oldTask.value
            lateCallbackBytesEqual = try Data(contentsOf: url) == bytesB
            do { _ = try await old.connect(readGrant: grant) }
            catch ExternalSessionAppAdapterError.runtimeUnavailable { retainedOldConnectRejected = true }
            #expect(try Data(contentsOf: url) == bytesB)
            _ = await composition.revoke(sourceID: source.sourceID, profileID: source.profileID)
            let bytesAfterRevoke = try Data(contentsOf: url)
            do { _ = try await replacement.reconnect(readGrant: grant) }
            catch ExternalSessionAppAdapterError.runtimeUnavailable { revokedOldReconnectRejected = true }
            #expect(try Data(contentsOf: url) == bytesAfterRevoke)
            // This models a previously retained unqualified EOF callback too:
            // the central write fence must cover more than beginConnect.
            old.disconnect()
            #expect(try Data(contentsOf: url) == bytesAfterRevoke)
        } catch { businessError = error }
        await barrier.open()
        oldResult = await oldTask.value
        if let newTask { newResult = await newTask.value }
        _ = await composition.revoke(sourceID: source.sourceID, profileID: source.profileID)
        let oldRejected: Bool
        if case .failure(let error) = oldResult,
           let typed = error as? ExternalSessionAppAdapterError, typed == .runtimeUnavailable {
            oldRejected = true
        } else { oldRejected = false }
        let newConnected: Bool
        if case .success(let snapshot) = newResult { newConnected = snapshot.state == .connected }
        else { newConnected = false }
        let evidence: [String: Any] = ["root": root.path, "oldCallerTaskJoined": true,
            "newCallerTaskJoined": newTask != nil, "oldPendingCallbackRejected": oldRejected,
            "newConnected": newConnected, "lateCallbackBytesEqualB": lateCallbackBytesEqual,
            "retainedOldConnectRejected": retainedOldConnectRejected,
            "revokedOldReconnectRejected": revokedOldReconnectRejected]
        let data = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("ACTUAL_OLD_REFERENCE_WRITE_FENCE.json"))
        FileHandle.standardError.write(Data(("ARCH1_OLD_REFERENCE_ACTUAL " + String(decoding: data, as: UTF8.self) + "\n").utf8))
        if let businessError { throw businessError }
        #expect(oldRejected)
        #expect(newConnected)
        #expect(lateCallbackBytesEqual)
        #expect(retainedOldConnectRejected)
        #expect(revokedOldReconnectRejected)
    }

    @Test("revoke joins a pending real handshake before admitting the next generation")
    func revocationJoinsPendingHandshakeBeforeReconnect() async throws {
        try await exercise(ownedMemory: true, revokeWhileConnecting: true)
    }

    private func exercise(ownedMemory: Bool, revokeWhileConnecting: Bool = false) async throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = formal.rootDirectory.appendingPathComponent("ARCH1-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try #require(root.path.hasPrefix("/Users/") && root.resolvingSymlinksInPath() == root)
        let home = root.appendingPathComponent("codex-home", isDirectory: true)
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        let runtime = root.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let server = root.appendingPathComponent("owned-handshake.py")
        try Data(#"""
        #!/usr/bin/python3 -IS
        import json, os, select, sys, time
        home = os.environ['CODEX_HOME']
        def marker(name, text='1'):
            with os.fdopen(os.open(os.path.join(home,name),os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600),'w') as f: f.write(text)
        try:
            marker('slot-A')
            slot='A'
        except FileExistsError:
            marker('slot-B')
            slot='B'
        marker('identity-'+slot+'.json',json.dumps({'pid':os.getpid(),'ppid':os.getppid(),'uid':os.getuid()}))
        deadline=time.monotonic()+60
        while time.monotonic()<deadline and not os.path.exists(os.path.join(home,'retire-all')):
            if not select.select([sys.stdin],[],[],0.01)[0]: continue
            line=sys.stdin.readline()
            if not line: break
            req=json.loads(line)
            if req.get('method')=='initialize':
                marker('initialize-'+slot)
                while not os.path.exists(os.path.join(home,'release-'+slot)):
                    if time.monotonic()>=deadline or os.path.exists(os.path.join(home,'retire-all')): sys.exit(0)
                    time.sleep(0.005)
                print(json.dumps({'id':req['id'],'result':{'userAgent':'miniscanvas/0.151.0 (owned ARCH1 synthetic)','platformFamily':'unix','platformOs':'macos'}}),flush=True)
        """#.utf8).write(to: server)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: server.path)
        let composition = ExternalSessionAuthorizationComposition()
        composition.configureExternalSourceRegistration(hostID: "owned-arch1-host")
        composition.configureMemoryProposalConsumer(MemoryProposalConsumer(
            store: MemoryStore(directory: root.appendingPathComponent("memory", isDirectory: true))
        ))
        try composition.configureControlledMemoryRuntimeDirectory(runtime)
        let source = try composition.registerSelectedReadRoot(kind: .codex, rootURL: sessions)
        let profile = try #require(composition.supervisedProfileID(for: source))
        let read = try await composition.issueReadGrant(authorizationID: .init(rawValue: "arch1-status"),
            sourceID: source, profileID: profile, target: .source(source), scopes: [.metadata, .status], lifetime: 90)
        _ = try await composition.activateSelectedReadRoot(sourceID: source, readGrant: read)
        let control = try await composition.issueControlGrant(authorizationID: .init(rawValue: "arch1-control"),
            sourceID: source, profileID: profile, target: .thread(.init(rawValue: "owned-thread")),
            operations: [.resume], lifetime: 90)
        try composition.configureSyntheticCodexControl(sourceID: source, executableURL: server,
                                                       homeURL: home, runtimeDirectory: runtime)
        func connect(readGrant: ExternalSessionReadGrantV1? = nil) async -> Result<Void, any Error> {
            let selectedRead = readGrant ?? read
            do {
                if ownedMemory {
                    try await composition.connectOwnedCodexMemorySource(sourceID: source,
                        executableURL: server, statusReadGrant: selectedRead)
                } else {
                    try await composition.activateSyntheticCodexControl(sourceID: source,
                        readGrant: selectedRead, controlGrant: control)
                }
                return .success(())
            } catch { return .failure(error) }
        }
        let a = Task { await connect() }
        var b: Task<Result<Void, any Error>, Never>?
        var completions: [ExternalSessionCodexStdioTermination] = []
        var resultA: Result<Void, any Error>?
        var resultB: Result<Void, any Error>?
        var ownerAfterA: String?
        var ownerAfterB: String?
        var bytesAfterA: Data?
        var bytesAfterB: Data?
        var businessError: (any Error)?
        let runtimeFile = runtime.appendingPathComponent(source.rawValue + ".json")
        var revokeTask: Task<UInt64, Never>?
        var revokedFirstTaskJoined = false
        var firstProcessGone0 = false
        var firstProcessGone5 = false
        do {
            try #require(try await waitUntil { exists(home, "initialize-A") })
            if revokeWhileConnecting {
                let identity = try #require(try JSONSerialization.jsonObject(
                    with: Data(contentsOf: home.appendingPathComponent("identity-A.json"))) as? [String: Int])
                let pidValue = try #require(identity["pid"])
                let pid = try #require(pid_t(exactly: pidValue))
                try #require(identity["ppid"] == Int(getpid()) && identity["uid"] == Int(geteuid()))
                try #require(pid > 1 && pid != getpid())
                revokeTask = Task { await composition.revoke(sourceID: source, profileID: profile) }
                _ = await revokeTask?.value
                resultA = await a.value
                revokedFirstTaskJoined = true
                errno = 0
                firstProcessGone0 = Darwin.kill(pid, 0) == -1 && errno == ESRCH
                try await Task.sleep(for: .seconds(5))
                errno = 0
                firstProcessGone5 = Darwin.kill(pid, 0) == -1 && errno == ESRCH
                try #require(!FileManager.default.fileExists(atPath: runtimeFile.path))
                let fresh = try await composition.issueReadGrant(
                    authorizationID: .init(rawValue: "arch1-after-revoke"), sourceID: source,
                    profileID: profile, target: .source(source), scopes: [.metadata, .status], lifetime: 90)
                b = Task { await connect(readGrant: fresh) }
                try #require(try await waitUntil { exists(home, "initialize-B") })
                try Data().write(to: home.appendingPathComponent("release-B"))
                resultB = await b?.value
                if case .success = resultB {
                    completions.append(try #require(await composition.ownedCodexTermination(sourceID: source)))
                    ownerAfterB = composition.adapter(for: source)?.runtimeSnapshot.ownerID
                    bytesAfterB = try Data(contentsOf: runtimeFile)
                }
            } else {
            let bFinished = ARCH1ConnectFinished()
            b = Task {
                let result = await connect()
                bFinished.value = true
                return result
            }
            // A remains in its real handshake. B either reaches its own handshake
            // (old duplicate admission) or returns refusal (the intended contract).
            try #require(try await waitUntil { exists(home, "initialize-B") || bFinished.value })
            try Data().write(to: home.appendingPathComponent("release-A"))
            resultA = await a.value
            if case .success = resultA {
                completions.append(try #require(await composition.ownedCodexTermination(sourceID: source)))
                ownerAfterA = composition.adapter(for: source)?.runtimeSnapshot.ownerID
                bytesAfterA = try Data(contentsOf: runtimeFile)
            }
            try Data().write(to: home.appendingPathComponent("release-B"))
            resultB = await b?.value
            if case .success = resultB {
                let completion = try #require(await composition.ownedCodexTermination(sourceID: source))
                if !completions.contains(where: { $0.ownerID == completion.ownerID }) { completions.append(completion) }
                ownerAfterB = composition.adapter(for: source)?.runtimeSnapshot.ownerID
                bytesAfterB = try Data(contentsOf: runtimeFile)
            }
            }
        } catch { businessError = error }
        // All return/throw routes release our fake barriers, then actually join
        // both original caller Tasks. Retain this UUID root as RED/raw evidence.
        try? Data().write(to: home.appendingPathComponent("release-A"))
        resultA = await a.value
        if let revokeTask { _ = await revokeTask.value }
        if let current = await composition.ownedCodexTermination(sourceID: source),
           !completions.contains(where: { $0.ownerID == current.ownerID }) { completions.append(current) }
        try? Data().write(to: home.appendingPathComponent("release-B"))
        if let b { resultB = await b.value }
        if let current = await composition.ownedCodexTermination(sourceID: source),
           !completions.contains(where: { $0.ownerID == current.ownerID }) { completions.append(current) }
        try? Data().write(to: home.appendingPathComponent("retire-all"))
        _ = await composition.revoke(sourceID: source, profileID: profile)
        var receipts: [ExternalSessionCodexStdioTerminationReceipt] = []
        var missingCompletion = false
        for completion in completions {
            // A displaced connection is no longer in the composition dictionary.
            // Its original token is retained; a live .wait() refusal is never a join.
            var receipt: ExternalSessionCodexStdioTerminationReceipt?
            for _ in 0..<400 {
                do { receipt = try await completion.wait(); break }
                catch ExternalSessionCodexJSONRPCError.alreadyConnected {
                    try? await Task.sleep(for: .milliseconds(5))
                }
            }
            if let receipt { receipts.append(receipt) } else { missingCompletion = true }
        }
        let successes = [resultA, resultB].compactMap { $0 }.filter {
            if case .success = $0 { return true }; return false
        }.count
        let evidence: [String: Any] = ["root": root.path, "ownedMemory": ownedMemory,
            "successes": successes, "revokeWhileConnecting": revokeWhileConnecting,
            "actualFMTemporaryDirectory": FileManager.default.temporaryDirectory.path,
            "pendingRevokeTaskAndFirstCallerJoined": revokedFirstTaskJoined,
            "pendingProcessGone0": firstProcessGone0, "pendingProcessGone5": firstProcessGone5,
            "pendingPrivateCompletionReceiptExposed": false,
            "runtimeOwnerAfterA": ownerAfterA ?? "NONE",
            "runtimeOwnerAfterB": ownerAfterB ?? "NONE", "runtimeBytesChangedAtoB": bytesAfterA != nil && bytesAfterB != nil && bytesAfterA != bytesAfterB,
            "callerTaskAJoined": true, "callerTaskBJoined": b != nil,
            "originalConnectionCompletionsJoined": receipts.count,
            "allReceiptsComplete": receipts.allSatisfy(\.isComplete),
            "actualCompletionReceipts": receipts.map { receipt in
                ["ownerID": receipt.ownerID.uuidString,
                 "pid": receipt.processIdentifier ?? -1,
                 "terminationStatus": receipt.terminationStatus ?? -1,
                 "processWaited": receipt.processWaited, "readerEOF": receipt.readerReachedEOF,
                 "parserJoined": receipt.parserTasksJoined, "requestJoined": receipt.requestTasksJoined,
                 "callbackJoined": receipt.callbackTasksJoined, "stdoutClosed": receipt.stdoutClosed,
                 "allPipeHandlesClosed": receipt.allPipeHandlesClosed] as [String: Any]
            }]
        let data = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("ACTUAL_CONNECTION_ADMISSION.json"))
        FileHandle.standardError.write(Data(("ARCH1_CONNECT_ACTUAL " + String(decoding: data, as: UTF8.self) + "\n").utf8))
        try #require(!missingCompletion)
        let allReceiptsComplete = receipts.allSatisfy { $0.isComplete }
        try #require(allReceiptsComplete)
        if let businessError { throw businessError }
        #expect(successes == 1)
        #expect(exists(home, "initialize-A"))
        if revokeWhileConnecting {
            #expect(exists(home, "initialize-B"))
            #expect(revokedFirstTaskJoined && firstProcessGone0 && firstProcessGone5)
            #expect(ownerAfterB != nil)
            if case .failure = resultA {} else { Issue.record("revoked pending caller unexpectedly succeeded") }
        } else {
            #expect(!exists(home, "initialize-B"))
            #expect(ownerAfterA != nil)
        }
        #expect(completions.count == 1)
    }

    private func exists(_ root: URL, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
    }
    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws -> Bool {
        for _ in 0..<400 {
            if predicate() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }
}
