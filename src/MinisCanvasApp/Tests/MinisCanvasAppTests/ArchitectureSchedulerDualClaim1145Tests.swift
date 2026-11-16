import Darwin
import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

/// Only the controlled SDK endpoint is test-owned. Provider construction,
/// route authority, scheduler claims and ChatStore submission stay production.
private final class ArchitectureScheduler1145Loopback: @unchecked Sendable {
    private struct FDIdentity: Sendable {
        let descriptor: Int32
        let device: dev_t
        let inode: ino_t
        let mode: mode_t

        init(_ descriptor: Int32) throws {
            var value = stat()
            guard fstat(descriptor, &value) == 0 else {
                throw LifecycleError.operation("fstat-owned-fd", errno)
            }
            self.descriptor = descriptor
            device = value.st_dev
            inode = value.st_ino
            mode = value.st_mode
        }

        func requireUnchanged() throws {
            let current = try Self(descriptor)
            guard current.device == device, current.inode == inode, current.mode == mode else {
                throw LifecycleError.identityChanged(descriptor)
            }
        }
    }

    private enum LifecycleError: Error {
        case operation(String, Int32)
        case identityChanged(Int32)
        case invalidListenerAddress
        case joinTimedOut
    }

    private let descriptor: Int32
    private let wakeRead: Int32
    private let wakeWrite: Int32
    private let listenerIdentity: FDIdentity
    private let wakeReadIdentity: FDIdentity
    private let wakeWriteIdentity: FDIdentity
    private let lock = NSLock()
    private let stopLock = NSLock()
    private let worker = DispatchGroup()
    private var calls = 0
    private var stopping = false
    private var closed = false
    private var closureFailure: (any Error)?
    private var activeClient: Int32?
    private var workerFailure: (any Error)?
    private let holdResponses: Bool
    private let responseGate = DispatchSemaphore(value: 0)
    let port: UInt16

    init(holdResponses: Bool = false) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LifecycleError.operation("socket", errno) }
        var wakeDescriptors: [Int32] = [-1, -1]
        var committed = false
        defer {
            if !committed {
                if wakeDescriptors[0] >= 0 { _ = Darwin.close(wakeDescriptors[0]) }
                if wakeDescriptors[1] >= 0 { _ = Darwin.close(wakeDescriptors[1]) }
                _ = Darwin.close(fd)
            }
        }
        guard pipe(&wakeDescriptors) == 0 else { throw LifecycleError.operation("pipe", errno) }
        for ownedFD in [fd, wakeDescriptors[0], wakeDescriptors[1]] {
            let flags = fcntl(ownedFD, F_GETFL)
            guard flags >= 0, fcntl(ownedFD, F_SETFL, flags | O_NONBLOCK) == 0,
                  fcntl(ownedFD, F_SETFD, FD_CLOEXEC) == 0 else {
                throw LifecycleError.operation("owned-fd-flags", errno)
            }
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            throw LifecycleError.invalidListenerAddress
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            throw LifecycleError.operation("bind-listen", errno)
        }
        let endpoint = try Self.listenerAddress(fd)
        guard endpoint.sin_addr.s_addr == address.sin_addr.s_addr,
              endpoint.sin_port != 0 else { throw LifecycleError.invalidListenerAddress }
        descriptor = fd
        wakeRead = wakeDescriptors[0]
        wakeWrite = wakeDescriptors[1]
        listenerIdentity = try FDIdentity(fd)
        wakeReadIdentity = try FDIdentity(wakeDescriptors[0])
        wakeWriteIdentity = try FDIdentity(wakeDescriptors[1])
        port = UInt16(bigEndian: endpoint.sin_port)
        self.holdResponses = holdResponses
        committed = true
        print("ARCH1145_LOOPBACK_LISTEN pid=\(getpid()) uid=\(geteuid()) fd=\(fd) address=127.0.0.1 port=\(port) dev=\(listenerIdentity.device) inode=\(listenerIdentity.inode) mode=\(listenerIdentity.mode) wakeRead=\(wakeRead) wakeWrite=\(wakeWrite)")
        worker.enter()
        // Explicit stopAndJoin is required: the worker retains this owner until
        // serve returns. Deinit is deliberately not the shutdown mechanism.
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            serve()
            worker.leave()
        }
    }

    func callCount() -> Int { lock.lock(); defer { lock.unlock() }; return calls }
    func releaseResponses() { responseGate.signal() }

    /// Stop admission and wake the poll/accept boundary without a synthetic HTTP
    /// connection (which would corrupt the original request-count assertions).
    /// The caller must retain profile roots if this throws, and clean them only
    /// after a successful join. The active client's recv/send is interrupted too.
    func stopAndJoin() throws {
        stopLock.lock()
        defer { stopLock.unlock() }
        lock.lock()
        if closed {
            let failure = closureFailure
            lock.unlock()
            if let failure { throw failure }
            return
        }
        stopping = true
        var shutdownFailure: (any Error)?
        if let client = activeClient {
            do {
                // The worker closes clients under this same lock; stop only
                // shuts them down, so the descriptor cannot be reused here.
                if Darwin.shutdown(client, SHUT_RDWR) != 0,
                   errno != ENOTCONN { throw LifecycleError.operation("shutdown-client", errno) }
            } catch { shutdownFailure = error }
        }
        lock.unlock()
        responseGate.signal()
        try wakeWriteIdentity.requireUnchanged()
        var byte: UInt8 = 1
        let sent = Darwin.write(wakeWrite, &byte, 1)
        guard sent == 1 || (sent == -1 && errno == EAGAIN) else {
            throw LifecycleError.operation("wake-worker", errno)
        }
        guard worker.wait(timeout: .now() + 3) == .success else {
            throw LifecycleError.joinTimedOut
        }
        // No worker can accept, read, send or close an fd after this join.
        try listenerIdentity.requireUnchanged()
        try wakeReadIdentity.requireUnchanged()
        try wakeWriteIdentity.requireUnchanged()
        let endpoint = try Self.listenerAddress(descriptor)
        var expected = in_addr()
        guard inet_pton(AF_INET, "127.0.0.1", &expected) == 1,
              endpoint.sin_addr.s_addr == expected.s_addr,
              UInt16(bigEndian: endpoint.sin_port) == port else {
            throw LifecycleError.invalidListenerAddress
        }
        var closeFailure: (any Error)?
        for ownedFD in [descriptor, wakeRead, wakeWrite] {
            if Darwin.close(ownedFD) != 0, closeFailure == nil {
                closeFailure = LifecycleError.operation("close-owned-fd", errno)
            }
        }
        lock.lock()
        closed = true
        let failure = workerFailure
        closureFailure = closeFailure ?? shutdownFailure ?? failure
        let remainingClient = activeClient
        lock.unlock()
        print("ARCH1145_LOOPBACK_STOP pid=\(getpid()) uid=\(geteuid()) fd=\(descriptor) address=127.0.0.1 port=\(port) joined=true activeClient=\(remainingClient ?? -1) ownedCloseOK=\(closeFailure == nil)")
        if let closeFailure { throw closeFailure }
        if let shutdownFailure { throw shutdownFailure }
        if let failure { throw failure }
    }

    private static func listenerAddress(_ descriptor: Int32) throws -> sockaddr_in {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &address, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }) == 0 else { throw LifecycleError.operation("getsockname", errno) }
        guard length == socklen_t(MemoryLayout<sockaddr_in>.size),
              address.sin_family == sa_family_t(AF_INET) else {
            throw LifecycleError.invalidListenerAddress
        }
        return address
    }

    private func isStopping() -> Bool { lock.lock(); defer { lock.unlock() }; return stopping }
    private func failWorker(_ error: any Error) {
        lock.lock(); if workerFailure == nil { workerFailure = error }; lock.unlock()
    }

    private func serve() {
        let body = "data: " + #"{"choices":[{"index":0,"delta":{"content":"owned response 1145"},"finish_reason":"stop"}]}"#
            + "\n\ndata: [DONE]\n\n"
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        while !isStopping() {
            var watched = [pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0),
                           pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)]
            let watchedCount = nfds_t(watched.count)
            let ready = poll(&watched, watchedCount, 250)
            if ready < 0 {
                if errno == EINTR { continue }
                failWorker(LifecycleError.operation("poll", errno)); return
            }
            if isStopping() { return }
            if watched[0].revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                failWorker(LifecycleError.operation("listener-poll-state", 0)); return
            }
            guard watched[0].revents & Int16(POLLIN) != 0 else { continue }
            let client = accept(descriptor, nil, nil)
            if client < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
                if !isStopping() { failWorker(LifecycleError.operation("accept", errno)) }
                return
            }
            do {
                // Suppress SIGPIPE only on this test-owned accepted socket.
                var yes: Int32 = 1
                var timeout = timeval(tv_sec: 1, tv_usec: 0)
                let clientFlags = fcntl(client, F_GETFL)
                guard clientFlags >= 0,
                      fcntl(client, F_SETFL, clientFlags & ~O_NONBLOCK) == 0,
                      fcntl(client, F_SETFD, FD_CLOEXEC) == 0,
                      setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes,
                                 socklen_t(MemoryLayout<Int32>.size)) == 0,
                      setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                                 socklen_t(MemoryLayout<timeval>.size)) == 0,
                      setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout,
                                 socklen_t(MemoryLayout<timeval>.size)) == 0 else {
                    throw LifecycleError.operation("client-options", errno)
                }
                lock.lock()
                if stopping { lock.unlock(); _ = Darwin.close(client); return }
                activeClient = client
                lock.unlock()
                var buffer = [UInt8](repeating: 0, count: 65536)
                if recv(client, &buffer, buffer.count, 0) > 0 {
                    lock.lock(); calls += 1; lock.unlock()
                    if holdResponses { _ = responseGate.wait(timeout: .now() + 10) }
                    if !isStopping() {
                        response.withCString { bytes in _ = send(client, bytes, strlen(bytes), 0) }
                    }
                }
                lock.lock()
                if Darwin.close(client) != 0, workerFailure == nil {
                    workerFailure = LifecycleError.operation("close-client", errno)
                }
                activeClient = nil
                lock.unlock()
            } catch {
                // Only socket setup above can throw; the worker still exclusively
                // owns this unregistered fd, which stop cannot close or reuse.
                _ = Darwin.close(client)
                failWorker(error)
                return
            }
        }
    }
}


@Suite("ARCH1 production Scheduler dual-claim 1145", .serialized)
@MainActor
struct ArchitectureSchedulerDualClaim1145Tests {
    @MainActor private struct Root {
        let profile: RuntimeIsolationProfile
        let sessions: SessionStore
        let settings: SettingsCenter
        let bridge: BridgeStore
        let scheduler: SchedulerTaskStore
        let runtime: SchedulerTaskRuntime
        let readiness: ProviderReadinessStore

        init(profile: RuntimeIsolationProfile, now: @escaping @MainActor @Sendable () -> Date = Date.init) {
            let defaults = profile.makeUserDefaults()
            let shortcuts = ShortcutStore(defaults: defaults)
            let sessions = SessionStore(directory: profile.sessionDirectory)
            let badges = SessionBadgeStore(directory: profile.minisCanvasDirectory)
            let logger = profile.makeLogManager()
            let readiness = ProviderReadinessStore(directory: profile.providerConfigurationDirectory)
            let settings = ProductionDomainAssembly.makeSettings(
                profile: profile,
                keychain: KeychainStore(backing: InMemoryKeychainBacking()),
                sessionStore: sessions, sessionBadgeStore: badges, logManager: logger,
                store: shortcuts, readinessTransport: FailClosedProviderReadinessTransport(),
                providerReadinessStore: readiness
            )
            let skills = SkillsStore(
                appStore: settings.skillStore, stateFileURL: profile.skillStateURL,
                loadImmediately: false)
            let scheduler = SchedulerTaskStore(defaults: defaults,
                occurrenceLedgerURL: profile.minisCanvasDirectory.appendingPathComponent("scheduler-occurrences-v1.json"))
            let workflows = WorkflowStore.startForAppBootstrap(
                storeDirectory: profile.minisCanvasDirectory.appendingPathComponent("Workflows"))
            let bridge = ProductionDomainAssembly.makeBridge(
                profile: profile, bootstrapFailure: nil, settings: settings,
                store: shortcuts, defaults: defaults, skillsStore: skills,
                schedulerStore: scheduler, logManager: logger, workflowStore: workflows,
                sessionBadgeStore: badges, sessionStore: sessions)
            self.profile = profile
            self.sessions = sessions
            self.settings = settings
            self.bridge = bridge
            self.scheduler = scheduler
            self.readiness = readiness
            self.runtime = ProductionDomainAssembly.makeSchedulerRuntime(
                store: scheduler, bridge: bridge, settings: settings, now: now)
        }

        func bootstrap() async {
            await ProductionOrchestrationDefaults.attachProductionServices(
                to: bridge, fileAccessAllowedRoot: profile.rootDirectory,
                fileAccessDeniedRoots: [URL(fileURLWithPath: NSHomeDirectory())],
                sessionDirectory: sessions.directory, mcpManager: settings.mcpManager,
                skillStore: settings.skillStore, canvasRuntimeState: .disabled,
                externalNetworkAllowed: false, controlledFieldLoopbackAllowed: true,
                sessionReadSecretStore: settings.envStore
            ).value
        }

        func prepareInput(port: UInt16, revision: String, checkedAt: Date = Date()) {
            let chat = bridge.chat
            let facts = ComposerPolicyFactSource(
                knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
                workspaceID: chat.composerWorkspaceID, revision: revision,
                grantEpoch: "owned-epoch-1145", leaseID: "owned-lease-1145",
                expiresAt: Date().addingTimeInterval(3600), autonomyCeiling: .l1)
            chat.configureComposerPolicy(facts)
            let record = EnvVarEntry(
                name: "ARCH1145_SYNTHETIC_API_KEY", value: "synthetic-field-key", isSecret: true,
                baseURL: "http://127.0.0.1:\(port)", modelNames: ["field-model-1145"],
                protocolType: .openaiCompatible)
            chat.providerRecordsSource = { [record] }
            chat.schedulerCredentialVersionSource = { _ in "synthetic-revision-1145" }
            readiness.upsert(ProviderReadinessPersistenceRecord(
                providerID: record.name, modelID: "field-model-1145",
                status: .passed, readinessState: .live, checkedAt: checkedAt,
                evidenceID: "live-settings:" + String(repeating: "a", count: 64), isApplied: true))
            print("ARCH1145_ROUTE allowed=\(bridge.productionControlledFieldLoopbackAllowed) applied=\(chat.applyChatModel(providerID: record.name, modelID: "field-model-1145"))")
        }
    }

    @Test("two real production roots claim one authorized due task and retain one durable delivery")
    func productionRootsDoNotDoubleSubmitTheSameDueOccurrence() async throws {
        _ = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "arch1-dual-claim-1145", processEnvironment: [:],
            processArguments: ["/tmp/MinisCanvasAppTests.xctest"], canvasRuntimeState: .disabled)
        defer { B1ARCHOriginalFixtureSupport.cleanupProfile(profile) }
        try B1ARCHOriginalFixtureSupport.qualifyProfile(profile)
        let foreignProfile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "arch1-dual-claim-1145-foreign", processEnvironment: [:],
            processArguments: ["/tmp/MinisCanvasAppTests.xctest"], canvasRuntimeState: .disabled)
        defer { B1ARCHOriginalFixtureSupport.cleanupProfile(foreignProfile) }
        try B1ARCHOriginalFixtureSupport.qualifyProfile(foreignProfile)
        let targetID = UUID()
        let projectID = "arch1-owned-project-1145"
        let command = "owned request 1145"
        let initialSessions = SessionStore(directory: profile.sessionDirectory)
        var target = try initialSessions.createSession(id: targetID.uuidString, title: "owned target", projectID: projectID)
        target.providerTypeRaw = "custom.ARCH1145_SYNTHETIC_API_KEY"
        target.modelID = "field-model-1145"
        try initialSessions.updateSession(target)
        try initialSessions.saveMessage(LLMMessage(role: .user, content: "original source 1145"), sessionID: targetID.uuidString)

        let provider = try ArchitectureScheduler1145Loopback()
        defer {
            do { try provider.stopAndJoin() }
            catch {
                B1ARCHOriginalFixtureSupport.blockProfileCleanup(profile,
                    reason: "ARCH1145_HTTP_STOP_JOIN_FAILED")
                B1ARCHOriginalFixtureSupport.blockProfileCleanup(foreignProfile,
                    reason: "ARCH1145_HTTP_STOP_JOIN_FAILED")
                Issue.record(error, "owned HTTP fixture stop/join failed; profile roots retained")
            }
        }
        let now = Date()
        let first = Root(profile: profile, now: { now })
        await first.bootstrap()
        first.prepareInput(port: provider.port, revision: "owned-policy-1145", checkedAt: now)
        #expect(first.scheduler.add(name: "owned schedule", cronExpression: "* * * * *",
            command: command, targetSessionID: targetID, targetProjectID: projectID,
            targetTurnID: 1) == nil)
        let taskID = try #require(first.scheduler.allTasks().first?.id)
        let digest = try #require(first.bridge.chat.schedulerSourceAnchorDigest(
            sessionID: targetID, projectID: projectID, ordinal: 1))
        var preview = try #require(first.scheduler.preview(taskID: taskID, now: now))
        preview.observedSourceAnchorDigest = digest
        preview.observedPolicyRevision = "owned-policy-1145"
        #expect(first.scheduler.confirmPreview(preview, actorID: "owned-actor-1145",
            scopeID: projectID, policyRevision: "owned-policy-1145", now: now,
            sourceAnchorConfirmed: true, currentSourceAnchorDigest: digest,
            currentPolicyRevision: "owned-policy-1145"))
        #expect(first.runtime.providerPreflight(taskID: taskID)?.isReadyForExecution == true)

        let competing = Root(profile: profile, now: { now })
        await competing.bootstrap()
        competing.prepareInput(port: provider.port, revision: "owned-policy-1145", checkedAt: now)
        #expect(competing.scheduler.task(id: taskID) != nil)
        #expect(competing.runtime.providerPreflight(taskID: taskID)?.isReadyForExecution == true)
        first.runtime.start()
        competing.runtime.start()
        defer { first.runtime.stop(); competing.runtime.stop() }
        print("ARCH1145_START firstRecovery=\(first.runtime.lastRecoveryCount) secondRecovery=\(competing.runtime.lastRecoveryCount) first=\(String(reflecting: first.scheduler.latestOccurrence(for: taskID))) second=\(String(reflecting: competing.scheduler.latestOccurrence(for: taskID)))")
        for _ in 0..<300 where provider.callCount() == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(provider.callCount() > 0, "A real authorized production submission must start")
        try await Task.sleep(nanoseconds: 100_000_000)
        let submittedCount = provider.callCount()
        #expect(submittedCount == 1, "Two production roots must not submit one canonical task twice")

        let ledgerURL = profile.minisCanvasDirectory.appendingPathComponent("scheduler-occurrences-v1.json")
        var terminal: SchedulerOccurrence?
        for _ in 0..<300 {
            let reopened = SchedulerTaskStore(defaults: profile.makeUserDefaults(), occurrenceLedgerURL: ledgerURL)
            terminal = reopened.latestOccurrence(for: taskID)
            if terminal?.state.isTerminal == true { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let done = try #require(terminal)
        print("ARCH1145_DONE providerCalls=\(provider.callCount()) first=\(String(reflecting: first.scheduler.latestOccurrence(for: taskID))) second=\(String(reflecting: competing.scheduler.latestOccurrence(for: taskID))) durable=\(String(reflecting: done))")
        let canonical = SchedulerTaskStore(defaults: profile.makeUserDefaults(), occurrenceLedgerURL: ledgerURL)
        #expect(canonical.occurrences.filter { $0.taskID == taskID }.count == 1)
        #expect(canonical.occurrenceJournal.filter { $0.occurrenceID == done.id && $0.state == .leased }.count == 1,
            "The durable journal must contain exactly one successful lease claim")
        #expect(canonical.occurrenceJournal.filter { $0.occurrenceID == done.id && $0.state == .succeeded }.count == 1)
        #expect(done.state == .succeeded)
        #expect(done.submissionReceipt?.status == .delivered)
        let persistedTarget = try #require(SessionStore(directory: profile.sessionDirectory).loadSession(id: targetID.uuidString))
        #expect(persistedTarget.scheduledTranscriptDeliveries.count == 1)
        #expect(persistedTarget.messages.filter { $0.content == command }.count == 1)
        #expect(persistedTarget.messages.filter { $0.content == "owned response 1145" }.count == 1)

        first.runtime.stop()
        competing.runtime.stop()
        let replacement = Root(profile: profile, now: { now })
        await replacement.bootstrap()
        replacement.prepareInput(port: provider.port, revision: "owned-policy-1145", checkedAt: now)
        replacement.runtime.start()
        replacement.runtime.pollNow(at: now)
        replacement.runtime.stop()
        #expect(provider.callCount() == submittedCount)
        let foreign = Root(profile: foreignProfile)
        await foreign.bootstrap()
        foreign.prepareInput(port: provider.port, revision: "owned-policy-1145")
        #expect(foreign.scheduler.task(id: taskID) == nil)
        foreign.runtime.start()
        foreign.runtime.stop()
        #expect(provider.callCount() == submittedCount)
    }

    @Test("physical alias reuses the canonical row and stale writer cannot replace its ledger")
    func physicalAliasAndStaleWriterFailClosed() throws {
        _ = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "arch1-ledger-alias-1145", processEnvironment: [:],
            processArguments: ["/tmp/MinisCanvasAppTests.xctest"], canvasRuntimeState: .disabled)
        defer { B1ARCHOriginalFixtureSupport.cleanupProfile(profile) }
        try B1ARCHOriginalFixtureSupport.qualifyProfile(profile)
        let ledger = profile.minisCanvasDirectory.appendingPathComponent("scheduler-occurrences-v1.json")
        let aliasDirectory = profile.rootDirectory.appendingPathComponent("scheduler-alias-1145")
        try FileManager.default.createSymbolicLink(at: aliasDirectory,
            withDestinationURL: profile.minisCanvasDirectory)
        try B1ARCHOriginalFixtureSupport.registerOwnedLink(aliasDirectory, target: profile.minisCanvasDirectory)
        let aliasedLedger = aliasDirectory.appendingPathComponent("scheduler-occurrences-v1.json")
        let defaults = profile.makeUserDefaults()
        let first = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        #expect(first.add(name: "alias task", cronExpression: "* * * * *", command: "alias input",
            targetSessionID: UUID(), targetProjectID: "alias-project", targetTurnID: 1) == nil)
        let taskID = try #require(first.allTasks().first?.id)
        #expect(first.authorize(taskID))
        let second = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: aliasedLedger)
        let now = Date()
        let direct = try #require(first.reserveOccurrence(taskID: taskID, at: now))
        let alias = try #require(second.reserveOccurrence(taskID: taskID, at: now))
        #expect(alias.id == direct.id)
        #expect(alias.idempotencyKey == direct.idempotencyKey)
        #expect(first.compareAndSwapOccurrence(id: direct.id, expected: .triggered, next: .authorized,
            expectedControlRevision: direct.controlRevision, now: now))
        let winningBytes = try Data(contentsOf: ledger)
        #expect(!second.compareAndSwapOccurrence(id: alias.id, expected: .triggered, next: .authorized,
            expectedControlRevision: alias.controlRevision, now: now))
        #expect(second.persistenceError == .ledgerWriteFailed(path: aliasedLedger.path))
        #expect(try Data(contentsOf: ledger) == winningBytes)
        let reopened = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        #expect(reopened.occurrences.count == 1)
        #expect(reopened.occurrence(id: direct.id)?.state == .authorized)
        #expect(reopened.occurrenceJournal.filter { $0.state == .authorized }.count == 1)
    }

    @Test("opening a second live production root preserves the first root's unexpired lease")
    func secondLiveRootDoesNotMisclassifyRunningLeaseAsCrash() async throws {
        _ = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "arch1-live-lease-1145", processEnvironment: [:],
            processArguments: ["/tmp/MinisCanvasAppTests.xctest"], canvasRuntimeState: .disabled)
        defer { B1ARCHOriginalFixtureSupport.cleanupProfile(profile) }
        try B1ARCHOriginalFixtureSupport.qualifyProfile(profile)
        let targetID = UUID()
        let projectID = "arch1-live-project-1145"
        let sessions = SessionStore(directory: profile.sessionDirectory)
        var target = try sessions.createSession(id: targetID.uuidString, title: "live target", projectID: projectID)
        target.providerTypeRaw = "custom.ARCH1145_SYNTHETIC_API_KEY"
        target.modelID = "field-model-1145"
        try sessions.updateSession(target)
        try sessions.saveMessage(LLMMessage(role: .user, content: "live source 1145"), sessionID: targetID.uuidString)
        let endpoint = try ArchitectureScheduler1145Loopback(holdResponses: true)
        defer {
            do { try endpoint.stopAndJoin() }
            catch {
                B1ARCHOriginalFixtureSupport.blockProfileCleanup(profile,
                    reason: "ARCH1145_HTTP_STOP_JOIN_FAILED")
                Issue.record(error, "owned HTTP fixture stop/join failed; profile root retained")
            }
        }
        defer { endpoint.releaseResponses() }
        let first = Root(profile: profile)
        await first.bootstrap()
        first.prepareInput(port: endpoint.port, revision: "live-policy-1145")
        #expect(first.scheduler.add(name: "live lease", cronExpression: "* * * * *",
            command: "live request 1145", targetSessionID: targetID,
            targetProjectID: projectID, targetTurnID: 1) == nil)
        let taskID = try #require(first.scheduler.allTasks().first?.id)
        let digest = try #require(first.bridge.chat.schedulerSourceAnchorDigest(
            sessionID: targetID, projectID: projectID, ordinal: 1))
        let now = Date()
        var preview = try #require(first.scheduler.preview(taskID: taskID, now: now))
        preview.observedSourceAnchorDigest = digest
        preview.observedPolicyRevision = "live-policy-1145"
        #expect(first.scheduler.confirmPreview(preview, actorID: "live-actor-1145",
            scopeID: projectID, policyRevision: "live-policy-1145", now: now,
            sourceAnchorConfirmed: true, currentSourceAnchorDigest: digest,
            currentPolicyRevision: "live-policy-1145"))
        first.runtime.start()
        defer { first.runtime.stop() }
        for _ in 0..<300 where endpoint.callCount() == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(endpoint.callCount() == 1)
        let running = try #require(first.scheduler.latestOccurrence(for: taskID))
        #expect(running.state == .running && running.leaseExpiresAt.map { $0 > Date() } == true)
        let second = Root(profile: profile)
        await second.bootstrap()
        second.prepareInput(port: endpoint.port, revision: "live-policy-1145")
        second.runtime.start()
        defer { second.runtime.stop() }
        let ledgerURL = profile.minisCanvasDirectory.appendingPathComponent("scheduler-occurrences-v1.json")
        let after = SchedulerTaskStore(defaults: profile.makeUserDefaults(), occurrenceLedgerURL: ledgerURL)
        print("ARCH1145_LIVE secondRecovery=\(second.runtime.lastRecoveryCount) before=\(running.state) after=\(String(reflecting: after.latestOccurrence(for: taskID)))")
        #expect(second.runtime.lastRecoveryCount == 0,
            "A concurrent live root is not a crashed owner")
        #expect(after.latestOccurrence(for: taskID)?.state == .running)
        func leaseDiagnostic(latest: SchedulerOccurrence?, store: SchedulerTaskStore?) -> Comment {
            let original = store?.occurrence(id: running.id)
            return Comment(rawValue:
                "sameOccurrence=\(latest?.id == running.id) sameMinute=\(latest?.scheduledMinute == running.scheduledMinute)"
                + " originalState=\(original?.state.rawValue ?? "UNOBSERVED")"
                + " originalSameToken=\(original != nil && original?.leaseToken == running.leaseToken)")
        }
        #expect(after.latestOccurrence(for: taskID)?.leaseToken == running.leaseToken,
            leaseDiagnostic(latest: after.latestOccurrence(for: taskID), store: after))
        endpoint.releaseResponses()
        var terminal: SchedulerOccurrence?
        var terminalStore: SchedulerTaskStore?
        for _ in 0..<300 {
            let reopened = SchedulerTaskStore(defaults: profile.makeUserDefaults(), occurrenceLedgerURL: ledgerURL)
            terminalStore = reopened
            terminal = reopened.latestOccurrence(for: taskID)
            if terminal?.state.isTerminal == true { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(terminal?.state == .succeeded, leaseDiagnostic(latest: terminal, store: terminalStore))
        #expect(endpoint.callCount() == 1)
    }

    @Test("owned OS child identity distinguishes live, wrong birth, natural exit and legacy owner")
    func ownedProcessLeaseIdentityPositiveAndNegative() throws {
        _ = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["2"]
        child.environment = ["PATH": "/usr/bin:/bin", "LANG": "C"]
        child.currentDirectoryURL = try #require(try FormalTestIsolationPaths.resolveCurrentProcess()).rootDirectory
        try child.run()
        print("ARCH_OWNED_CHILD_ADMISSION pid=\(child.processIdentifier) pgid=\(getpgid(child.processIdentifier)) executable=/bin/sleep durationSeconds=2")
        let owner = try #require(SchedulerTaskStore.processLeaseOwnerID(pid: child.processIdentifier))
        let childPID = child.processIdentifier
        let childPGID = getpgid(childPID)
        print("ARCH_OWNED_CHILD pid=\(childPID) pgid=\(childPGID) owner=\(owner) executable=/bin/sleep timeoutSeconds=4")
        var initialChildInfo = proc_bsdinfo()
        try #require(proc_pidinfo(childPID, PROC_PIDTBSDINFO, 0, &initialChildInfo,
            Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size))
        let childUID = initialChildInfo.pbi_uid
        let childStartSec = initialChildInfo.pbi_start_tvsec
        let childStartUSec = initialChildInfo.pbi_start_tvusec
        let watchdog = Task.detached {
            do { try await Task.sleep(nanoseconds: 4_000_000_000) } catch { return }
            var observed = proc_bsdinfo()
            let size = proc_pidinfo(childPID, PROC_PIDTBSDINFO, 0, &observed,
                Int32(MemoryLayout<proc_bsdinfo>.size))
            if child.isRunning && size == Int32(MemoryLayout<proc_bsdinfo>.size)
                && observed.pbi_pid == UInt32(childPID) && observed.pbi_uid == childUID
                && observed.pbi_start_tvsec == childStartSec && observed.pbi_start_tvusec == childStartUSec {
                child.terminate()
            }
        }
        defer {
            watchdog.cancel()
            if child.isRunning && SchedulerTaskStore.processLeaseOwnerID(pid: childPID) == owner { child.terminate(); child.waitUntilExit() }
            print("ARCH_OWNED_CHILD_CLEANUP pid=\(childPID) running=\(child.isRunning) originalOwnerLive=\(String(describing: SchedulerTaskStore.processLeaseOwnerLiveness(owner))) status=\(child.terminationStatus)")
        }
        #expect(SchedulerTaskStore.processLeaseOwnerLiveness(owner) == true)
        let fields = owner.split(separator: ":").map(String.init)
        #expect(fields.count == 6)
        try #require(fields.count == 6)
        var wrongBirth = fields
        wrongBirth[5] = String((UInt64(fields[5]) ?? 0) + 1)
        #expect(SchedulerTaskStore.processLeaseOwnerLiveness(wrongBirth.joined(separator: ":")) == false)
        #expect(SchedulerTaskStore.processLeaseOwnerLiveness("scheduler-runtime") == false)
        child.waitUntilExit()
        #expect(child.terminationStatus == 0)
        #expect(SchedulerTaskStore.processLeaseOwnerLiveness(owner) == false)
    }
}
