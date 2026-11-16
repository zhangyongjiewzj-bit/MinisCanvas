import Foundation
import Darwin
import Testing
@testable import MinisCore

/// Synthetic only. The test owner supplies the isolated formal root; no app,
/// provider, or real Keychain is started by this candidate suite.
private final class PairFenceBacking: KeychainBacking, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var writes = 0
    private var failure = false
    private var hook: (@Sendable () throws -> Void)?
    private var hookFailures: [Error] = []
    func configure(fail: Bool = false, onSet: (@Sendable () throws -> Void)? = nil) {
        lock.withLock { failure = fail; hook = onSet }
    }
    var writeCount: Int { lock.withLock { writes } }
    func set(_ value: String, forKey key: String) -> Bool {
        let action = lock.withLock { () -> ((@Sendable () throws -> Void)?, Bool) in
            writes += 1
            return (hook, failure)
        }
        do { try action.0?() }
        catch { lock.withLock { hookFailures.append(error) }; return false }
        guard !action.1 else { return false }
        lock.withLock { values[key] = value }
        return true
    }
    func checkHookFailures() throws {
        let failures = lock.withLock { hookFailures }
        if let error = failures.first { throw error }
    }
    func get(_ key: String) -> String? { lock.withLock { values[key] } }
    func delete(_ key: String) -> Bool {
        _ = lock.withLock { values.removeValue(forKey: key) }
        return true
    }
}

/// In-memory JSON-RPC only; toggling tools/list failure drives the real
/// registry refresh -> manager retirement -> catalog consumer path.
private final class PairFenceDiscoveryTransport: MCPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var listFails = false
    func failList(_ value: Bool) { lock.withLock { listFails = value } }
    func start() async throws {}
    func stop() {}
    func notify(_ notification: MCPJSONRPCNotification) throws {}
    func send(_ request: MCPJSONRPCRequest) async throws -> MCPJSONRPCResponse {
        switch request.method {
        case "initialize":
            return MCPJSONRPCResponse(id: request.id, result: .object([
                "protocolVersion": .string("2024-11-05"), "capabilities": .object([:]),
                "serverInfo": .object(["name": .string("pair-fence-synthetic"), "version": .string("1")])
            ]))
        case "tools/list":
            if lock.withLock({ listFails }) {
                return MCPJSONRPCResponse(id: request.id,
                    error: MCPJSONRPCError(code: -32000, message: "synthetic failed refresh"))
            }
            return MCPJSONRPCResponse(id: request.id, result: .object([
                "tools": .array([.object([
                    "name": .string("synthetic"),
                    "inputSchema": .object(["type": .string("object")])
                ])])
            ]))
        default:
            return MCPJSONRPCResponse(id: request.id,
                error: MCPJSONRPCError(code: -32601, message: "synthetic unsupported method"))
        }
    }
}

// The blocking wait stays in a synchronous helper, on an owned detached task.
// It has the same one-call five-second budget and is awaited before assertions.
private func pairFenceWaitForBarrier(_ semaphore: DispatchSemaphore) -> DispatchTimeoutResult {
    semaphore.wait(timeout: .now() + 5)
}


/// Test-only owner: the production Lease never leaves this synchronous block.
/// Async test code observes readiness and requests release; it does not own a
/// locked NSLock or depend on resuming on the thread that acquired it.
private final class PairFenceSynchronousLeaseHolder: @unchecked Sendable {
    private struct Failure: Error {
        let stage: String
        let code: Int32
    }
    private struct Failures: Error { let errors: [Error] }
    private let ready = DispatchSemaphore(value: 0)
    private let releaseRequested = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private let stateLock = NSLock()
    private var readyResult: Result<Void, Error>?
    private var finishedResult: Result<Void, Error>?

    init(configURL: URL, authorizationURL: URL) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                let lease = try MCPPersistentWriteFence.acquire(
                    configURL: configURL, authorizationURL: authorizationURL
                )
                var acquireThread: UInt64 = 0
                let acquireCode = pthread_threadid_np(nil, &acquireThread)
                let acquired: Result<Void, Error> = acquireCode == 0
                    ? .success(()) : .failure(Failure(stage: "acquire thread ID", code: acquireCode))
                stateLock.withLock { readyResult = acquired }
                ready.signal()
                let releaseArrived = releaseRequested.wait(timeout: .now() + 5) == .success
                var releaseThread: UInt64 = 0
                let releaseCode = pthread_threadid_np(nil, &releaseThread)
                // Acquisition and release are in this same synchronous GCD
                // block even if the awaiting Swift task changes executors.
                lease.release()
                let outcome: Result<Void, Error>
                if acquireCode != 0 { outcome = acquired }
                else if releaseCode != 0 {
                    outcome = .failure(Failure(stage: "release thread ID", code: releaseCode))
                } else if acquireThread != releaseThread {
                    outcome = .failure(Failure(stage: "lease owner thread changed", code: ESTALE))
                } else if !releaseArrived {
                    outcome = .failure(Failure(stage: "release budget 5s", code: ETIMEDOUT))
                } else { outcome = .success(()) }
                print("MCP_PAIR_LEASE_THREAD acquire=\(acquireThread) release=\(releaseThread) same=\(acquireCode == 0 && releaseCode == 0 && acquireThread == releaseThread) releaseWithin5s=\(releaseArrived)")
                stateLock.withLock { finishedResult = outcome }
                finished.signal()
            } catch {
                stateLock.withLock {
                    readyResult = .failure(error)
                    finishedResult = .failure(error)
                }
                ready.signal()
                finished.signal()
            }
        }
    }

    /// Called only from a synchronous detached wait, never an async context.
    func waitUntilReady() throws {
        guard ready.wait(timeout: .now() + 5) == .success else {
            throw Failure(stage: "ready budget 5s", code: ETIMEDOUT)
        }
        let result = stateLock.withLock { readyResult }
        guard let result else { throw Failure(stage: "missing ready result", code: EINVAL) }
        try result.get()
    }

    /// Requests release and waits for actual terminal worker status before
    /// returning to the root-cleanup owner, including business-failure paths.
    func releaseAndJoin() throws {
        releaseRequested.signal()
        let joinedWithinBudget = finished.wait(timeout: .now() + 5) == .success
        if !joinedWithinBudget {
            // The budget is already failed, never retried into PASS. Still
            // join the owned worker before allowing exact-root cleanup; the
            // formal runner remains the outer termination watchdog.
            finished.wait()
        }
        let result = stateLock.withLock { finishedResult }
        guard let result else { throw Failure(stage: "missing terminal result", code: EINVAL) }
        if !joinedWithinBudget {
            let timeout = Failure(stage: "join budget 5s", code: ETIMEDOUT)
            if case .failure(let error) = result { throw Failures(errors: [timeout, error]) }
            throw timeout
        }
        try result.get()
    }
}

@Suite("Independent MCP persistent pair stale-write fence")
struct MCPPersistentPairFenceTests {
    private struct FixtureFailure: Error {
        let stage: String
        let code: Int32
    }
    private struct FixtureFailures: Error {
        let business: Error?
        let cleanup: [Error]
    }

    /// Pins the actual FileManager temporary parent and an immediately fresh
    /// UUID child. The formal contract supplies the expected uid/device; no
    /// environment string is accepted as the child's observed identity.
    private struct OwnedRoot {
        let url: URL
        let parentURL: URL
        let name: String
        let parentFD: Int32
        let rootFD: Int32
        let parentIdentity: stat
        let identity: stat
        let formal: FormalTestIsolationPaths

        static func make() throws -> OwnedRoot {
            let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
            let parentURL = FileManager.default.temporaryDirectory
                .standardizedFileURL.resolvingSymlinksInPath()
            let parentFD = parentURL.path.withCString {
                Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard parentFD >= 0 else { throw FixtureFailure(stage: "open actualFM", code: errno) }
            var parentIdentity = stat()
            guard fstat(parentFD, &parentIdentity) == 0 else {
                let code = errno
                let closeResult = Darwin.close(parentFD)
                if closeResult != 0 {
                    throw FixtureFailures(business: FixtureFailure(stage: "stat actualFM", code: code),
                                          cleanup: [FixtureFailure(stage: "close actualFM", code: errno)])
                }
                throw FixtureFailure(stage: "stat actualFM", code: code)
            }
            guard parentIdentity.st_mode & S_IFMT == S_IFDIR,
                  parentIdentity.st_mode & 0o7777 == 0o700,
                  parentIdentity.st_uid == geteuid(), parentIdentity.st_uid == formal.rootOwner,
                  UInt64(parentIdentity.st_dev) == formal.rootDevice else {
                let error = FixtureFailure(stage: "actualFM parent uid/device/700", code: ESTALE)
                guard Darwin.close(parentFD) == 0 else {
                    throw FixtureFailures(business: error,
                        cleanup: [FixtureFailure(stage: "close invalid actualFM parent", code: errno)])
                }
                throw error
            }
            let name = "mcp-pair-fence-\(UUID().uuidString)"
            let created = name.withCString { mkdirat(parentFD, $0, 0o700) }
            guard created == 0 else {
                let code = errno
                let closeResult = Darwin.close(parentFD)
                if closeResult != 0 {
                    throw FixtureFailures(business: FixtureFailure(stage: "mkdir fresh UUID", code: code),
                                          cleanup: [FixtureFailure(stage: "close actualFM", code: errno)])
                }
                throw FixtureFailure(stage: "mkdir fresh UUID", code: code)
            }
            let rootFD = name.withCString {
                openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            var identity = stat()
            guard rootFD >= 0, fstat(rootFD, &identity) == 0 else {
                let code = errno
                var errors: [Error] = []
                // mkdirat just created this still-empty child; unlinkat removes
                // only that directory entry, never follows a replacement link.
                if name.withCString({ unlinkat(parentFD, $0, AT_REMOVEDIR) }) != 0 {
                    errors.append(FixtureFailure(stage: "remove uninitialized fresh child", code: errno))
                }
                if rootFD >= 0, Darwin.close(rootFD) != 0 {
                    errors.append(FixtureFailure(stage: "close fresh child", code: errno))
                }
                if Darwin.close(parentFD) != 0 {
                    errors.append(FixtureFailure(stage: "close actualFM", code: errno))
                }
                throw FixtureFailures(business: FixtureFailure(stage: "open/stat fresh child", code: code),
                                      cleanup: errors)
            }
            // All later validation is business work under a cleanup owner.
            return OwnedRoot(url: parentURL.appendingPathComponent(name, isDirectory: true),
                             parentURL: parentURL, name: name, parentFD: parentFD, rootFD: rootFD,
                             parentIdentity: parentIdentity, identity: identity, formal: formal)
        }

        func validate() throws {
            var parentNow = stat()
            var childNow = stat()
            var rootNow = stat()
            guard parentURL.path.withCString({ fstatat(AT_FDCWD, $0, &parentNow, AT_SYMLINK_NOFOLLOW) }) == 0,
                  parentNow.st_mode & S_IFMT == S_IFDIR,
                  parentNow.st_mode & 0o7777 == 0o700,
                  parentNow.st_dev == parentIdentity.st_dev,
                  parentNow.st_ino == parentIdentity.st_ino,
                  parentNow.st_uid == geteuid(), parentNow.st_uid == formal.rootOwner,
                  UInt64(parentNow.st_dev) == formal.rootDevice,
                  name.withCString({ fstatat(parentFD, $0, &childNow, AT_SYMLINK_NOFOLLOW) }) == 0,
                  fstat(rootFD, &rootNow) == 0,
                  childNow.st_mode & S_IFMT == S_IFDIR,
                  childNow.st_uid == geteuid(), childNow.st_uid == formal.rootOwner,
                  childNow.st_mode & 0o7777 == 0o700,
                  childNow.st_dev == parentNow.st_dev,
                  childNow.st_dev == identity.st_dev, childNow.st_ino == identity.st_ino,
                  rootNow.st_dev == identity.st_dev, rootNow.st_ino == identity.st_ino,
                  childNow.st_ino != parentNow.st_ino,
                  UInt64(childNow.st_ino) != formal.rootInode,
                  url.deletingLastPathComponent().path == parentURL.path,
                  url.standardizedFileURL.resolvingSymlinksInPath().path == url.path else {
                throw FixtureFailure(stage: "freshFM uid/dev/inode/700/nosymlink", code: ESTALE)
            }
        }

        func finish<T>(_ business: Result<T, Error>) throws -> T {
            var errors: [Error] = []
            do {
                try validate()
                try FileManager.default.removeItem(at: url)
                var absent = stat()
                let result = name.withCString {
                    fstatat(parentFD, $0, &absent, AT_SYMLINK_NOFOLLOW)
                }
                guard result == -1, errno == ENOENT else {
                    throw FixtureFailure(stage: "cleanup verify ENOENT", code: errno)
                }
            } catch { errors.append(error) }
            if Darwin.close(rootFD) != 0 {
                errors.append(FixtureFailure(stage: "close fresh child", code: errno))
            }
            if Darwin.close(parentFD) != 0 {
                errors.append(FixtureFailure(stage: "close actualFM", code: errno))
            }
            if !errors.isEmpty {
                switch business {
                case .failure(let error): throw FixtureFailures(business: error, cleanup: errors)
                case .success: throw FixtureFailures(business: nil, cleanup: errors)
                }
            }
            print("MCP_PAIR_FIXTURE_CLEANUP root=\(url.path) uid=\(identity.st_uid) dev=\(identity.st_dev) inode=\(identity.st_ino) ENOENT=true")
            return try business.get()
        }
    }

    private func withRoot<T>(_ body: (URL) throws -> T) throws -> T {
        let owned = try OwnedRoot.make()
        let result = Result {
            try owned.validate()
            print("MCP_PAIR_FIXTURE root=\(owned.url.path) parent=\(owned.parentURL.path) uid=\(owned.identity.st_uid) dev=\(owned.identity.st_dev) inode=\(owned.identity.st_ino) mode=700 nosymlink=true")
            return try body(owned.url)
        }
        return try owned.finish(result)
    }

    private func withRootAsync<T>(_ body: (URL) async throws -> T) async throws -> T {
        let owned = try OwnedRoot.make()
        let result: Result<T, Error>
        do {
            try owned.validate()
            print("MCP_PAIR_FIXTURE root=\(owned.url.path) parent=\(owned.parentURL.path) uid=\(owned.identity.st_uid) dev=\(owned.identity.st_dev) inode=\(owned.identity.st_ino) mode=700 nosymlink=true")
            result = .success(try await body(owned.url))
        }
        catch { result = .failure(error) }
        return try owned.finish(result)
    }
    private func withSynchronousHeldPairLease<T>(
        configURL: URL, authorizationURL: URL,
        _ body: () async throws -> T
    ) async throws -> T {
        let holder = PairFenceSynchronousLeaseHolder(
            configURL: configURL, authorizationURL: authorizationURL
        )
        let business: Result<T, Error>
        do {
            try await Task.detached { try holder.waitUntilReady() }.value
            business = .success(try await body())
        } catch { business = .failure(error) }
        let terminal = await Task.detached { try holder.releaseAndJoin() }.result
        switch terminal {
        case .failure(let cleanup):
            switch business {
            case .failure(let error): throw FixtureFailures(business: error, cleanup: [cleanup])
            case .success: throw FixtureFailures(business: nil, cleanup: [cleanup])
            }
        case .success: return try business.get()
        }
    }

    private func server(_ id: String, name: String? = nil, secret: Bool = false) -> MCPServer {
        MCPServer(id: id, name: name ?? id, type: .http, enabled: true,
                  env: secret ? ["SYNTHETIC_API_KEY": "synthetic-pair-test-value"] : [:],
                  url: "https://mcp.invalid/\(id)")
    }
    private func manager(_ file: URL, _ backing: PairFenceBacking,
                         authorization: URL? = nil) -> MCPServerManager {
        MCPServerManager(fileURL: file, keychain: KeychainStore(backing: backing),
                         authorizationFileURL: authorization)
    }
    private func bytes(_ file: URL) throws -> Data { try Data(contentsOf: file) }
    private func document(_ file: URL) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: bytes(file)) as? [String: Any])
    }
    private func legacy(_ server: MCPServer, to file: URL, revision: Int = 7) throws {
        let entry = try JSONSerialization.jsonObject(with: JSONEncoder().encode(server))
        try JSONSerialization.data(withJSONObject: ["servers": [entry], "revision": revision],
                                   options: [.sortedKeys]).write(to: file)
    }

    @Test("original A+B revision3 is preserved by rejecting the independent stale A writer")
    func staleARejectsBeforeRAMKeychainOrPairChanges() throws {
        try withRoot { root in
            let file = root.appendingPathComponent("mcps.json")
            let backing = PairFenceBacking()
            let owner = manager(file, backing)
            try owner.addServer(server("A"))
            let stale = manager(file, backing)
            try owner.updateServer(server("A", name: "current A"))
            try owner.addServer(server("B"))
            let beforeConfig = try bytes(file)
            let beforeAuth = try bytes(owner.authorizationFileURL)
            let beforeRAM = stale.snapshot()
            let beforeWrites = backing.writeCount
            #expect(throws: MCPPersistenceConflict.staleSnapshot) {
                try stale.updateServer(server("A", name: "stale A", secret: true))
            }
            #expect(stale.listServers() == beforeRAM.servers)
            #expect(backing.writeCount == beforeWrites)
            #expect(try bytes(file) == beforeConfig)
            #expect(try bytes(owner.authorizationFileURL) == beforeAuth)
            #expect(try document(file)["revision"] as? Int == 3)
            let reopened = manager(file, backing)
            #expect(Set(reopened.listServers().map(\.id)) == ["A", "B"])
            try reopened.updateServer(server("A", name: "retry A"))
            #expect(reopened.server(id: "B") != nil)
            #expect(try document(file)["revision"] as? Int == 4)
        }
    }

    @Test("one current owner retains sequential same-ID LWW and explicit delete/restore")
    func currentOwnerLWWDeleteAndReopen() throws {
        try withRoot { root in
            let backing = PairFenceBacking()
            let owner = manager(root.appendingPathComponent("mcps.json"), backing)
            try owner.addServer(server("A", name: "one"))
            try owner.updateServer(server("A", name: "two"))
            try owner.updateServer(server("A", name: "three"))
            let stale = manager(owner.fileURL, backing)
            let intent = try owner.deletionIntent(id: "A")
                .withFirstConfirmation("I reviewed this exact synthetic MCP server")
                .withSecondConfirmation("I confirm moving this synthetic MCP server to trash")
            _ = try owner.deleteServer(intent)
            #expect(throws: MCPPersistenceConflict.staleSnapshot) { try stale.addServer(server("A")) }
            let reopened = manager(owner.fileURL, backing)
            #expect(reopened.server(id: "A") == nil)
            #expect(reopened.trashedServers().first?.name == "three")
            #expect(try reopened.restoreServer(id: "A")?.name == "three")
        }
    }

    @Test("auth-only mutation updates the pair baseline and stale grant cannot undo revocation")
    func authorizationOnlyWritesAndRevocation() throws {
        try withRoot { root in
            let backing = PairFenceBacking()
            let owner = manager(root.appendingPathComponent("mcps.json"), backing)
            try owner.addServer(server("A"))
            _ = try owner.authorizeServer(id: "A")
            _ = try owner.authorizeTool(serverID: "A", toolName: "synthetic")
            let stale = manager(owner.fileURL, backing)
            _ = try owner.revokeServer(id: "A")
            let configBefore = try bytes(owner.fileURL)
            let authBefore = try bytes(owner.authorizationFileURL)
            #expect(throws: MCPPersistenceConflict.staleSnapshot) { try stale.authorizeServer(id: "A") }
            #expect(stale.authorization(serverID: "A") == nil)
            #expect(try bytes(owner.fileURL) == configBefore)
            #expect(try bytes(owner.authorizationFileURL) == authBefore)
            // This succeeds only if the same owner's auth-only baseline refreshed.
            try owner.updateServer(server("A", name: "after revoke"))
            #expect(manager(owner.fileURL, backing).authorization(serverID: "A") == nil)
        }
    }

    @Test("same-revision bytes changed on disk are stale, not fresh")
    func hashDetectsSameRevisionChange() throws {
        try withRoot { root in
            let backing = PairFenceBacking()
            let owner = manager(root.appendingPathComponent("mcps.json"), backing)
            try owner.addServer(server("A"))
            var raw = try document(owner.fileURL)
            var servers = try #require(raw["servers"] as? [[String: Any]])
            servers[0]["name"] = "external same revision"
            raw["servers"] = servers
            try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]).write(to: owner.fileURL)
            let before = try bytes(owner.fileURL)
            #expect(throws: MCPPersistenceConflict.staleSnapshot) { try owner.save() }
            #expect(try bytes(owner.fileURL) == before)
        }
    }

    @Test("delayed frozen preparation carries captured baseline, never latest disk token")
    func frozenPreparationDoesNotAdoptFreshToken() throws {
        try withRoot { root in
            let backing = PairFenceBacking()
            let owner = manager(root.appendingPathComponent("mcps.json"), backing)
            try owner.addServer(server("A"))
            let prepare = owner.captureSnapshotManagerPreparation()
            try owner.addServer(server("B"))
            let frozen = prepare()
            #expect(frozen.server(id: "B") == nil)
            let before = try bytes(owner.fileURL)
            #expect(throws: MCPPersistenceConflict.staleSnapshot) { try frozen.updateServer(server("A")) }
            #expect(try bytes(owner.fileURL) == before)
        }
    }

    @Test("manual visible-only snapshot keeps value equality but is not a complete writable origin")
    func incompleteSnapshotRejectsWithoutChangingPublicEquality() throws {
        try withRoot { root in
            let backing = PairFenceBacking()
            let owner = manager(root.appendingPathComponent("mcps.json"), backing)
            try owner.addServer(server("A"))
            let captured = owner.snapshot()
            let manual = MCPServerManager.Snapshot(
                fileURL: captured.fileURL, authorizationFileURL: captured.authorizationFileURL,
                servers: captured.servers, trashServers: captured.trashServers,
                authorizations: captured.authorizations, discoverySnapshots: captured.discoverySnapshots,
                transportGenerations: captured.transportGenerations, schemaEpochs: captured.schemaEpochs,
                revision: captured.revision
            )
            #expect(manual == captured)
            let incomplete = owner.makeSnapshotManager(from: manual)
            let before = try bytes(owner.fileURL)
            #expect(incomplete.server(id: "A") != nil)
            #expect(incomplete.persistenceWriteConflict() == .incompleteSnapshot)
            #expect(throws: MCPPersistenceConflict.incompleteSnapshot) { try incomplete.save() }
            #expect(try bytes(owner.fileURL) == before)
            let complete = owner.makeSnapshotManager(from: captured)
            try complete.save()
            #expect(try bytes(owner.fileURL) == before)
        }
    }

    @Test("a current snapshot preserves populated BL6 and cleanup journals when explicitly saved")
    func currentSnapshotPreservesHiddenPersistentState() throws {
        try withRoot { root in
            let backing = PairFenceBacking()
            let file = root.appendingPathComponent("mcps.json")
            let owner = manager(file, backing)
            try owner.addServer(server("A"))
            let key = "mcp.41.name"
            let expectedRevision = try #require(owner.bl6NameRevision())
            let input = BL6SettingsApprovedInput(operation: .apply, changes: [key: .text("renamed")],
                                                 expectedRevision: expectedRevision)
            let ready = try owner.prepareBL6NameReplay(input, profileID: root.path).get()
            let receipt = BL6SettingsReceipt(requestID: "snapshot-origin-test", operation: .apply,
                                             previousRevision: ready.previousRevision,
                                             effectiveRevision: ready.effectiveRevision,
                                             changedKeys: ready.changedKeys, rollbackValues: [:])
            let record = BL6SettingsReplayRecord(
                requestID: receipt.requestID, payloadDigest: "synthetic-origin", frozenInput: input,
                approvalBindingDigest: "synthetic-origin-approval", profileID: root.path,
                scope: "session", sessionID: "synthetic", policyRevision: "synthetic",
                grantEpoch: "synthetic", approvalExpiresAt: Date().addingTimeInterval(60),
                operation: .apply, receipt: receipt, rollbackValues: ready.rollbackValues
            )
            #expect(try owner.commitBL6NameReplay(record, profileID: root.path).get() == receipt)
            let tempData = try bytes(file)
            let temp = root.appendingPathComponent(
                ".mcps.json.tmp-\(UUID().uuidString)-\(DeletionGate.fingerprint(tempData))"
            )
            try tempData.write(to: temp)
            let withCleanup = manager(file, backing)
            let cleanupReceipt = try #require(withCleanup.staleTempCleanupReceipts().first)
            #expect(withCleanup.cleanupStaleTemp(receipt: cleanupReceipt) == .removed)
            let raw = try document(file)
            let ledger = try #require(raw["bl6NameCompletions"] as? [String: Any])
            let history = try #require(raw["staleTempCleanupJournalHistory"] as? [Any])
            #expect(!ledger.isEmpty)
            #expect(!history.isEmpty)
            let before = try bytes(file)
            let clone = withCleanup.makeSnapshotManager()
            try clone.save()
            #expect(try bytes(file) == before)
            #expect(try clone.bl6NameReplayRecord(for: receipt.requestID, profileID: root.path).get() == record)
            let reopened = manager(file, backing)
            #expect(try reopened.bl6NameReplayRecord(for: receipt.requestID, profileID: root.path).get() == record)
        }
    }

    @Test("two pairs that share either physical target share a try-only gate, including aliases")
    func overlappingTargetsAndParentAlias() throws {
        try withRoot { root in
            let actual = root.appendingPathComponent("actual")
            try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: false)
            let alias = root.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
            let file = actual.appendingPathComponent("mcps.json")
            let auth = actual.appendingPathComponent("auth.json")
            let held = try MCPPersistentWriteFence.acquire(configURL: file, authorizationURL: auth)
            defer { held.release() }
            #expect(throws: MCPPersistenceConflict.writerBusy) {
                try MCPPersistentWriteFence.acquire(configURL: alias.appendingPathComponent("mcps.json"),
                                                    authorizationURL: actual.appendingPathComponent("other-auth.json"))
            }
            #expect(throws: MCPPersistenceConflict.writerBusy) {
                try MCPPersistentWriteFence.acquire(configURL: actual.appendingPathComponent("other-config.json"),
                                                    authorizationURL: alias.appendingPathComponent("auth.json"))
            }
            // Opposite role overlap is covered too, not merely config==config.
            #expect(throws: MCPPersistenceConflict.writerBusy) {
                try MCPPersistentWriteFence.acquire(configURL: auth,
                                                    authorizationURL: actual.appendingPathComponent("third.json"))
            }
        }
    }

    @Test("case aliases share a gate on insensitive volumes and remain distinct on sensitive volumes")
    func basenameCaseAliasUsesOwningVolumeRules() throws {
        try withRoot { root in
            let volumeValues = try root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            let sensitiveCandidate: Bool? = volumeValues.volumeSupportsCaseSensitiveNames
            let sensitive: Bool = try #require(sensitiveCandidate as Bool?)
            let lease = try MCPPersistentWriteFence.acquire(
                configURL: root.appendingPathComponent("mcps.json"),
                authorizationURL: root.appendingPathComponent("auth.json")
            )
            defer { lease.release() }
            if sensitive {
                let distinct = try MCPPersistentWriteFence.acquire(
                    configURL: root.appendingPathComponent("MCPS.JSON"),
                    authorizationURL: root.appendingPathComponent("other.json")
                )
                distinct.release()
            } else {
                #expect(throws: MCPPersistenceConflict.writerBusy) {
                    try MCPPersistentWriteFence.acquire(
                        configURL: root.appendingPathComponent("MCPS.JSON"),
                        authorizationURL: root.appendingPathComponent("other.json")
                    )
                }
            }
        }
    }

    @Test("independent managers through a symlinked parent compare the same physical pair")
    func aliasedManagerCannotOverwriteCurrentOwner() throws {
        try withRoot { root in
            let actual = root.appendingPathComponent("actual")
            try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: false)
            let alias = root.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
            let backing = PairFenceBacking()
            let owner = manager(actual.appendingPathComponent("mcps.json"), backing)
            try owner.addServer(server("A"))
            let stale = manager(alias.appendingPathComponent("mcps.json"), backing)
            try owner.addServer(server("B"))
            let before = try bytes(owner.fileURL)
            #expect(throws: MCPPersistenceConflict.staleSnapshot) { try stale.updateServer(server("A")) }
            #expect(try bytes(owner.fileURL) == before)
            let reopenedAlias = manager(alias.appendingPathComponent("mcps.json"), backing)
            try reopenedAlias.updateServer(server("A", name: "alias retry"))
            #expect(reopenedAlias.server(id: "B") != nil)
        }
    }

    @Test("a real barrier inside first writer makes second manager busy without any mutation")
    func concurrentBarrierBusyThenStale() async throws {
        try await withRootAsync { root in
            let backing = PairFenceBacking()
            let owner = manager(root.appendingPathComponent("mcps.json"), backing)
            let other = manager(owner.fileURL, backing)
            let reached = DispatchSemaphore(value: 0)
            let resume = DispatchSemaphore(value: 0)
            backing.configure(onSet: {
                reached.signal()
                _ = resume.wait(timeout: .now() + 10)
            })
            let toAdd = server("A", secret: true)
            let writer = Task.detached { try owner.addServer(toAdd) }
            defer { resume.signal() }
            let barrierResult = await Task.detached { pairFenceWaitForBarrier(reached) }.value
            #expect(barrierResult == .success)
            #expect(throws: MCPPersistenceConflict.writerBusy) { try other.addServer(server("B")) }
            #expect(other.listServers().isEmpty)
            #expect(other.persistenceWriteConflict() == nil)
            resume.signal()
            _ = try await writer.value
            #expect(throws: MCPPersistenceConflict.staleSnapshot) { try other.addServer(server("B")) }
            #expect(manager(owner.fileURL, backing).server(id: "A") != nil)
        }
    }

    @Test("a second-file failure preserves original IO error and permanently fences the partial writer")
    func secondFileFailureNeedsReopen() throws {
        try withRoot { root in
            let backing = PairFenceBacking()
            let owner = manager(root.appendingPathComponent("mcps.json"), backing)
            // The synthetic backing is the barrier after validation and before the
            // first config write. It injects a companion rename failure, not stale.
            let auth = owner.authorizationFileURL
            backing.configure(onSet: {
                try FileManager.default.createDirectory(at: auth, withIntermediateDirectories: false)
            })
            do {
                try owner.addServer(server("A", secret: true))
                Issue.record("Expected original second-file rename error")
            } catch let error as MCPDurableWriteError {
                guard case .renameFailed(let path, _) = error else {
                    Issue.record("Expected renameFailed, got \(error)"); return
                }
                #expect(path == auth.path)
            }
            try backing.checkHookFailures()
            #expect(FileManager.default.fileExists(atPath: owner.fileURL.path))
            #expect(owner.persistenceWriteConflict() == .needsReopen)
            #expect(owner.persistenceWriteFailureDescription() != nil)
            let writes = backing.writeCount
            #expect(throws: MCPPersistenceConflict.needsReopen) { try owner.save() }
            #expect(backing.writeCount == writes)
            #expect(owner.authorization(serverID: "A") == nil)
        }
    }

    @Test("constructor migrates legacy secret under lease and retains the loaded authorization companion")
    func constructorLegacyMigrationAndFailure() throws {
        try withRoot { root in
            let file = root.appendingPathComponent("mcps.json")
            let backing = PairFenceBacking()
            let synthetic = server("A", secret: true)
            try legacy(synthetic, to: file)
            let grant = MCPToolAuthorization(serverID: "A", descriptorFingerprint: synthetic.descriptorFingerprint,
                                             serverAuthorized: true, authorizedToolNames: [])
            let auths = try JSONSerialization.jsonObject(with: JSONEncoder().encode([grant]))
            try JSONSerialization.data(withJSONObject: ["authorizations": auths, "revision": 7])
                .write(to: root.appendingPathComponent("mcp-authorizations.json"))
            let migrated = manager(file, backing)
            #expect(migrated.persistenceWriteConflict() == nil)
            #expect(migrated.authorization(serverID: "A")?.serverAuthorized == true)
            #expect(!(try String(contentsOf: file, encoding: .utf8)).contains("synthetic-pair-test-value"))
            try migrated.updateServer(server("A", name: "still current", secret: true))
    
            try withRoot { failedRoot in
                let failedFile = failedRoot.appendingPathComponent("mcps.json")
                try legacy(synthetic, to: failedFile)
                let failedBacking = PairFenceBacking(); failedBacking.configure(fail: true)
                let before = try bytes(failedFile)
                let failed = manager(failedFile, failedBacking)
                #expect(failed.persistenceWriteConflict() == .needsReopen)
                #expect(failed.server(id: "A") != nil) // bounded read diagnostics remain
                #expect(failed.authorization(serverID: "A") == nil)
                #expect(try bytes(failedFile) == before)
                let writes = failedBacking.writeCount
                #expect(throws: MCPPersistenceConflict.needsReopen) { try failed.save() }
                #expect(failedBacking.writeCount == writes)
            }
        }
    }

    @Test("constructor contention never migrates a secret or pretends a failed load was fresh")
    func constructorBusyIsFailClosed() throws {
        try withRoot { root in
            let file = root.appendingPathComponent("mcps.json")
            try legacy(server("A", secret: true), to: file)
            let auth = root.appendingPathComponent("mcp-authorizations.json")
            let backing = PairFenceBacking()
            let lease = try MCPPersistentWriteFence.acquire(configURL: file, authorizationURL: auth)
            let failed = manager(file, backing)
            #expect(failed.persistenceWriteConflict() == .needsReopen)
            #expect(backing.writeCount == 0)
            #expect(failed.server(id: "A") != nil)
            lease.release()
            #expect(throws: MCPPersistenceConflict.needsReopen) { try failed.save() }
            #expect(backing.writeCount == 0)
            #expect(manager(file, backing).persistenceWriteConflict() == nil)
        }
    }
    @Test("failed refresh retires the observed runtime cache even while persistent pair is busy")
    func failedRefreshBusyRetiresCatalogAndFreshPublicationSurvivesOldExpected() async throws {
        try await withRootAsync { root in
            let backing = PairFenceBacking()
            let owner = manager(root.appendingPathComponent("mcps.json"), backing)
            try owner.addServer(server("A"))
            _ = try owner.authorizeServer(id: "A")
            _ = try owner.authorizeTool(serverID: "A", toolName: "synthetic")
            let transport = PairFenceDiscoveryTransport()
            let registry = MCPToolRegistry(manager: owner, clientFactory: {
                MCPClient(server: $0, transport: transport)
            })
            defer { registry.disconnectAll() }
            try await registry.refreshTools()
            let old = try #require(owner.discoverySnapshot(serverID: "A"))
            let name = MCPBoundTool.makeFullName(serverID: "A", toolName: "synthetic")
            #expect(try await registry.mcpBoundTools().contains { $0.fullName == name })
            let configBefore = try bytes(owner.fileURL)
            let authBefore = try bytes(owner.authorizationFileURL)
            try await withSynchronousHeldPairLease(
                configURL: owner.fileURL, authorizationURL: owner.authorizationFileURL
            ) {
                transport.failList(true)
                var busy = false
                do { try await registry.refreshTools() }
                catch MCPPersistenceConflict.writerBusy { busy = true }
                #expect(busy)
                #expect(owner.discoverySnapshot(serverID: "A") == nil)
                #expect(owner.cachedTools(serverID: "A").isEmpty)
                #expect(owner.persistenceWriteConflict() == nil)
                #expect(try bytes(owner.fileURL) == configBefore)
                #expect(try bytes(owner.authorizationFileURL) == authBefore)
                // A later catalog read must not re-advertise the dead publication.
                // With list still failing, expected==nil is a no-op retirement.
                #expect(!(try await registry.mcpBoundTools()).contains { $0.fullName == name })
                let definitions = try await AgentToolCatalog.makeTools(includingMCPFrom: registry)
                #expect(!definitions.contains { $0.name == name })
            }
            transport.failList(false)
            try await registry.refreshTools()
            let fresh = try #require(owner.discoverySnapshot(serverID: "A"))
            #expect(fresh.publicationID != old.publicationID)
            #expect(try await registry.mcpBoundTools().contains { $0.fullName == name })
            // Exact expected identity: an obsolete failure cannot retire fresh.
            #expect(try owner.retireDiscoveryAfterFailedRefresh(serverID: "A", expected: old) == false)
            #expect(owner.discoverySnapshot(serverID: "A") == fresh)
        }
    }

    @Test("retargeting a parent alias after validation cannot write into another locked pair")
    func aliasRetargetAtSecretBarrierRejectsBeforeFilesystemWrite() throws {
        try withRoot { root in
            let a = root.appendingPathComponent("A")
            let b = root.appendingPathComponent("B")
            try FileManager.default.createDirectory(at: a, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: b, withIntermediateDirectories: false)
            let alias = root.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: a)
            let backing = PairFenceBacking()
            let first = manager(alias.appendingPathComponent("mcps.json"), backing)
            try first.addServer(server("A"))
            let other = manager(b.appendingPathComponent("mcps.json"), PairFenceBacking())
            try other.addServer(server("B"))
            let aConfig = try bytes(a.appendingPathComponent("mcps.json"))
            let aAuth = try bytes(a.appendingPathComponent("mcp-authorizations.json"))
            let bConfig = try bytes(other.fileURL)
            let bAuth = try bytes(other.authorizationFileURL)
            let heldB = try MCPPersistentWriteFence.acquire(
                configURL: other.fileURL, authorizationURL: other.authorizationFileURL
            )
            defer { heldB.release() }
            backing.configure(onSet: {
                try FileManager.default.removeItem(at: alias)
                try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: b)
            })
            var changedMappingRejected = false
            do { try first.updateServer(server("A", name: "must not reach B", secret: true)) }
            catch MCPPersistenceConflict.scopeUnavailable(_, let code) {
                changedMappingRejected = code == ESTALE
            }
            try backing.checkHookFailures()
            #expect(changedMappingRejected)
            #expect(first.persistenceWriteConflict() == .needsReopen)
            #expect(try bytes(a.appendingPathComponent("mcps.json")) == aConfig)
            #expect(try bytes(a.appendingPathComponent("mcp-authorizations.json")) == aAuth)
            #expect(try bytes(other.fileURL) == bConfig)
            #expect(try bytes(other.authorizationFileURL) == bAuth)
            // Stable mapping positive control uses the normal existing owner.
            heldB.release()
            try other.updateServer(server("B", name: "legitimate B"))
            #expect(other.server(id: "B")?.name == "legitimate B")
        }
    }

    @Test("descriptor anchor stays in A even if alias changes inside the target IO body")
    func descriptorAnchorDoesNotFollowAliasAfterPrecheck() throws {
        try withRoot { root in
            let a = root.appendingPathComponent("A")
            let b = root.appendingPathComponent("B")
            try FileManager.default.createDirectory(at: a, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: b, withIntermediateDirectories: false)
            let alias = root.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: a)
            let lease = try MCPPersistentWriteFence.acquire(
                configURL: alias.appendingPathComponent("mcps.json"),
                authorizationURL: alias.appendingPathComponent("auth.json")
            )
            defer { lease.release() }
            let duplicate = try lease.duplicateParent(.authorization)
            let anchored = Result {
                try lease.withTarget(.config) { parent, _, _ in
                    try FileManager.default.removeItem(at: alias)
                    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: b)
                    let fd = openat(parent, "descriptor-anchor-probe", O_WRONLY | O_CREAT | O_EXCL, 0o600)
                    guard fd >= 0 else { throw FixtureFailure(stage: "anchor openat", code: errno) }
                    guard Darwin.close(fd) == 0 else {
                        throw FixtureFailure(stage: "anchor close", code: errno)
                    }
                    let copied = openat(duplicate, "cleanup-anchor-probe", O_WRONLY | O_CREAT | O_EXCL, 0o600)
                    guard copied >= 0 else { throw FixtureFailure(stage: "duplicate anchor openat", code: errno) }
                    guard Darwin.close(copied) == 0 else {
                        throw FixtureFailure(stage: "duplicate anchor close", code: errno)
                    }
                }
            }
            guard Darwin.close(duplicate) == 0 else {
                let error = FixtureFailure(stage: "close duplicated parent", code: errno)
                switch anchored {
                case .failure(let business): throw FixtureFailures(business: business, cleanup: [error])
                case .success: throw error
                }
            }
            var changedMappingRejected = false
            do { try anchored.get() }
            catch MCPPersistenceConflict.scopeUnavailable(_, let code) {
                changedMappingRejected = code == ESTALE
            }
            #expect(changedMappingRejected)
            #expect(FileManager.default.fileExists(atPath: a.appendingPathComponent("cleanup-anchor-probe").path))
            #expect(!FileManager.default.fileExists(atPath: b.appendingPathComponent("cleanup-anchor-probe").path))
            #expect(FileManager.default.fileExists(atPath: a.appendingPathComponent("descriptor-anchor-probe").path))
            #expect(!FileManager.default.fileExists(atPath: b.appendingPathComponent("descriptor-anchor-probe").path))
            #expect(!FileManager.default.fileExists(atPath: b.appendingPathComponent("mcps.json").path))
        }
    }

    @Test("constructor mapping change during legacy migration never rewrites the new alias destination")
    func constructorRetargetDuringMigrationIsNotFreshAndDoesNotWriteB() throws {
        try withRoot { root in
            let a = root.appendingPathComponent("A")
            let b = root.appendingPathComponent("B")
            try FileManager.default.createDirectory(at: a, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: b, withIntermediateDirectories: false)
            let alias = root.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: a)
            let aFile = a.appendingPathComponent("mcps.json")
            try legacy(server("A", secret: true), to: aFile)
            let other = manager(b.appendingPathComponent("mcps.json"), PairFenceBacking())
            try other.addServer(server("B"))
            let aBefore = try bytes(aFile)
            let bBefore = try bytes(other.fileURL)
            let bAuthBefore = try bytes(other.authorizationFileURL)
            let heldB = try MCPPersistentWriteFence.acquire(
                configURL: other.fileURL, authorizationURL: other.authorizationFileURL
            )
            defer { heldB.release() }
            let backing = PairFenceBacking()
            backing.configure(onSet: {
                try FileManager.default.removeItem(at: alias)
                try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: b)
            })
            let failed = manager(alias.appendingPathComponent("mcps.json"), backing)
            try backing.checkHookFailures()
            #expect(backing.writeCount > 0) // Migration is not a Keychain transaction.
            #expect(failed.persistenceWriteConflict() == .needsReopen)
            #expect(throws: MCPPersistenceConflict.needsReopen) { try failed.save() }
            #expect(try bytes(aFile) == aBefore)
            #expect(try bytes(other.fileURL) == bBefore)
            #expect(try bytes(other.authorizationFileURL) == bAuthBefore)
            heldB.release()
            let reopened = manager(alias.appendingPathComponent("mcps.json"), PairFenceBacking())
            #expect(reopened.persistenceWriteConflict() == nil)
            try reopened.updateServer(server("B", name: "legitimate reopened alias"))
            #expect(reopened.server(id: "B")?.name == "legitimate reopened alias")
        }
    }

}
