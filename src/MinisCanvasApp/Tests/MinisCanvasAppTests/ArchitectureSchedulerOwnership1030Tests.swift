import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

@Suite("ARCH1 actual App scheduler production assembly 1030", .serialized)
@MainActor
struct ArchitectureSchedulerOwnership1030Tests {
    /// Build each root through the functions called by AppMain. There is no
    /// copied SchedulerTaskRuntime wiring or synthetic store implementation.
    @MainActor private struct Root {
        let profile: RuntimeIsolationProfile
        let sessions: SessionStore
        let settings: SettingsCenter
        let bridge: BridgeStore
        let schedulerStore: SchedulerTaskStore
        let runtime: SchedulerTaskRuntime

        init(profile: RuntimeIsolationProfile) {
            self.profile = profile
            let defaults = profile.makeUserDefaults()
            let shortcuts = ShortcutStore(defaults: defaults)
            let sessions = SessionStore(directory: profile.sessionDirectory)
            let badges = SessionBadgeStore(directory: profile.minisCanvasDirectory)
            let logger = profile.makeLogManager()
            let settings = ProductionDomainAssembly.makeSettings(
                profile: profile,
                keychain: KeychainStore(backing: InMemoryKeychainBacking()),
                sessionStore: sessions,
                sessionBadgeStore: badges,
                logManager: logger,
                store: shortcuts,
                readinessTransport: FailClosedProviderReadinessTransport(),
                providerReadinessStore: ProviderReadinessStore(
                    directory: profile.providerConfigurationDirectory
                )
            )
            let skills = SkillsStore(
                appStore: settings.skillStore,
                stateFileURL: profile.skillStateURL,
                loadImmediately: false
            )
            let schedulerLedgerURL = profile.minisCanvasDirectory.appendingPathComponent(
                "scheduler-occurrences-v1.json", isDirectory: false
            )
            let schedulerStore = SchedulerTaskStore(
                defaults: defaults, occurrenceLedgerURL: schedulerLedgerURL
            )
            let workflows = WorkflowStore.startForAppBootstrap(
                storeDirectory: profile.minisCanvasDirectory.appendingPathComponent(
                    "Workflows", isDirectory: true
                )
            )
            let bridge = ProductionDomainAssembly.makeBridge(
                profile: profile, bootstrapFailure: nil, settings: settings,
                store: shortcuts, defaults: defaults, skillsStore: skills,
                schedulerStore: schedulerStore, logManager: logger,
                workflowStore: workflows, sessionBadgeStore: badges,
                sessionStore: sessions
            )
            self.sessions = sessions
            self.settings = settings
            self.bridge = bridge
            self.schedulerStore = schedulerStore
            self.runtime = ProductionDomainAssembly.makeSchedulerRuntime(
                store: schedulerStore, bridge: bridge, settings: settings
            )
        }
    }

    @Test("same-root active scheduler assembly, stop and legal rebuild, foreign root isolation")
    func actualAppSchedulerRootLifecycleAndCompetingAssembly() throws {
        _ = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "arch1-scheduler1030", processEnvironment: [:],
            processArguments: ["/tmp/MinisCanvasAppTests.xctest"],
            canvasRuntimeState: .disabled
        )
        defer { B1ARCHOriginalFixtureSupport.cleanupProfile(profile) }
        try B1ARCHOriginalFixtureSupport.qualifyProfile(profile)
        let foreignProfile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "arch1-scheduler1030-foreign", processEnvironment: [:],
            processArguments: ["/tmp/MinisCanvasAppTests.xctest"],
            canvasRuntimeState: .disabled
        )
        defer { B1ARCHOriginalFixtureSupport.cleanupProfile(foreignProfile) }
        try B1ARCHOriginalFixtureSupport.qualifyProfile(foreignProfile)

        let first = Root(profile: profile)
        #expect(first.schedulerStore.add(
            name: "合成原组合根", cronExpression: "* * * * *", command: "无实际提交"
        ) == nil)
        let task = try #require(first.schedulerStore.allTasks().first)
        let originalPreflight = first.bridge.chat.schedulerProviderPreflight(for: task)
        #expect(first.runtime.providerPreflight(taskID: task.id) == originalPreflight)
        #expect(!originalPreflight.isReadyForExecution)
        first.runtime.start()
        defer { first.runtime.stop() }
        #expect(first.runtime.isStarted)

        // The second request is another original production composition over
        // the same isolated profile, not two hand-written scheduler stores.
        let competing = Root(profile: profile)
        #expect(competing.schedulerStore.task(id: task.id) != nil)
        #expect(competing.runtime.providerPreflight(taskID: task.id) == originalPreflight)
        #expect(!competing.runtime.isStarted)
        competing.runtime.start()
        defer { competing.runtime.stop() }
        // This records current dual-active behavior; it is an ARCH1 gap, not
        // proof of duplicate delivery or a permitted second production owner.
        #expect(first.runtime.isStarted && competing.runtime.isStarted)
        // A poll may persist a triggered occurrence even when preflight is
        // unready. Both roots must observe the same durable trigger, without
        // either root submitting or delivering the synthetic command.
        #expect(first.schedulerStore.occurrences.contains { firstRow in
            competing.schedulerStore.occurrences.contains { $0.id == firstRow.id }
        })
        #expect(first.schedulerStore.occurrences.allSatisfy {
            $0.submissionReceipt == nil && $0.deliveryReceipt == nil
        })
        #expect(competing.schedulerStore.occurrences.allSatisfy {
            $0.submissionReceipt == nil && $0.deliveryReceipt == nil
        })

        first.runtime.stop()
        competing.runtime.stop()
        let replacement = Root(profile: profile)
        #expect(replacement.schedulerStore.task(id: task.id) != nil)
        replacement.runtime.start()
        #expect(replacement.runtime.isStarted)
        replacement.runtime.stop()

        let foreign = Root(profile: foreignProfile)
        #expect(foreign.schedulerStore.task(id: task.id) == nil)
        foreign.runtime.start()
        #expect(foreign.runtime.isStarted)
        foreign.runtime.stop()
    }

    @Test("ARCH1 original factory same-process owner requires its exact fencing token for durable writes")
    func originalFactorySameProcessWriterRejectsForeignLeaseToken() throws {
        _ = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "arch1-scheduler1030-token-boundary", processEnvironment: [:],
            processArguments: ["/tmp/MinisCanvasAppTests.xctest"], canvasRuntimeState: .disabled)
        defer { B1ARCHOriginalFixtureSupport.cleanupProfile(profile) }
        try B1ARCHOriginalFixtureSupport.qualifyProfile(profile)
        let canonical = Root(profile: profile)
        #expect(canonical.schedulerStore.add(name: "同进程token边界",
            cronExpression: "* * * * *", command: "仅持久写权测试不提交Provider",
            targetSessionID: UUID(), targetProjectID: "arch1-token-boundary", targetTurnID: 1) == nil)
        let task = try #require(canonical.schedulerStore.allTasks().first)
        try #require(canonical.schedulerStore.authorize(task.id))
        let now = Date()
        let occurrence = try #require(canonical.schedulerStore.reserveOccurrence(taskID: task.id, at: now))
        for (from, to) in [(SchedulerOccurrenceState.triggered, SchedulerOccurrenceState.authorized),
                           (.authorized, .admitted), (.admitted, .dispatched)] {
            try #require(canonical.schedulerStore.compareAndSwapOccurrence(id: occurrence.id,
                expected: from, next: to, expectedControlRevision: occurrence.controlRevision, now: now))
        }
        let processOwner = SchedulerTaskStore.currentProcessLeaseOwnerID()
        try #require(!processOwner.isEmpty)
        let token = try #require(canonical.schedulerStore.claimLease(id: occurrence.id,
            owner: processOwner, expectedControlRevision: occurrence.controlRevision, now: now))
        try #require(canonical.schedulerStore.heartbeat(id: occurrence.id,
            owner: processOwner, token: token, now: now))
        // Same process can construct a reader; its object identity is not the
        // authority. The persisted owner+token pair is the authority.
        let reader = Root(profile: profile)
        #expect(reader.schedulerStore !== canonical.schedulerStore)
        #expect(reader.schedulerStore.occurrenceLedgerURL == canonical.schedulerStore.occurrenceLedgerURL)
        let loaded = try #require(reader.schedulerStore.occurrence(id: occurrence.id))
        #expect(loaded.leaseOwner == processOwner && loaded.leaseToken == token)
        let ledgerURL = canonical.schedulerStore.occurrenceLedgerURL
        let before = try Data(contentsOf: ledgerURL)
        let forgedToken = UUID().uuidString
        #expect(forgedToken != token)
        #expect(!reader.schedulerStore.heartbeat(id: occurrence.id,
            owner: processOwner, token: forgedToken, now: now.addingTimeInterval(1)))
        #expect(reader.schedulerStore.persistenceError == nil)
        #expect(try Data(contentsOf: ledgerURL) == before)
        #expect(!reader.schedulerStore.heartbeat(id: occurrence.id,
            owner: processOwner + ":foreign", token: token, now: now.addingTimeInterval(1)))
        #expect(reader.schedulerStore.persistenceError == nil)
        #expect(try Data(contentsOf: ledgerURL) == before)
        // Legal same-process successor holding the exact token may renew;
        // this is a positive control, not global second-object rejection.
        #expect(reader.schedulerStore.heartbeat(id: occurrence.id,
            owner: processOwner, token: token, now: now.addingTimeInterval(2)))
        #expect(try Data(contentsOf: ledgerURL) != before)
        let renewed = try #require(reader.schedulerStore.occurrence(id: occurrence.id))
        #expect(renewed.leaseOwner == processOwner && renewed.leaseToken == token)
        #expect(renewed.state == .running)
        #expect(renewed.submissionReceipt == nil && renewed.deliveryReceipt == nil)
    }
}
