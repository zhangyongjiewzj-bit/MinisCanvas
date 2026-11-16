import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@MainActor
private final class DiagnosticHealthTestClock {
    var now = Date(timeIntervalSince1970: 1_756_000_000)
}

private actor DeferredStorageCheck {
    private var invocationCount = 0
    private var result: CheckedContinuation<DiagnosticStorageProbeOutcome, Never>?
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func invoke(_ profile: RuntimeIsolationProfile) async -> DiagnosticStorageProbeOutcome {
        invocationCount += 1
        let reached = invocationCount
        let ready = startWaiters.filter { $0.0 <= reached }
        startWaiters.removeAll { $0.0 <= reached }
        ready.forEach { $0.1.resume() }
        return await withCheckedContinuation { self.result = $0 }
    }

    func waitForInvocation(_ count: Int) async {
        if invocationCount >= count { return }
        await withCheckedContinuation { self.startWaiters.append((count, $0)) }
    }

    func calls() -> Int { invocationCount }

    func finish(_ outcome: DiagnosticStorageProbeOutcome) {
        result?.resume(returning: outcome)
        result = nil
    }
}

private actor DiagnosticHealthCheckMode {
    private var deferred = false
    func useDeferred() { deferred = true }
    func isDeferred() -> Bool { deferred }
}

private final class DiagnosticKeychainReaderSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func read() -> (status: Int32, flags: UInt32) {
        lock.withLock { count += 1 }
        return (0, 3)
    }
}

@Suite("P3-OBS-01 显式隔离健康快照")
@MainActor
struct DiagnosticHealthRunConsumerTests {
    private func profile(_ label: String = UUID().uuidString) throws -> RuntimeIsolationProfile {
        try RuntimeIsolationProfile.makeIsolatedTest(
            label: "diagnostic-health-\(label)",
            processEnvironment: ["SWIFT_TESTING_ENABLED": "1"],
            processArguments: ["swiftpm-testing-helper"]
        )
    }

    @Test(arguments: [UInt32(3), 2, 1, 0])
    func defaultKeychainFlagsDescribeOnlyLibraryMetadata(flags: UInt32) {
        let mapped = DiagnosticDefaultKeychainStatus.map(status: 0, flags: flags)
        #expect(mapped == .measured(unlocked: flags == 3 || flags == 1, readable: flags == 3 || flags == 2))
        #expect(mapped.message.hasPrefix("默认钥匙串库："))
        #expect(DiagnosticDefaultKeychainStatus.map(status: -1, flags: flags) == .unknown)
    }

    @Test func keychainButtonSkipsIsolatedAndFormalProductionBeforeAnyReader() async throws {
        let isolated = try profile()
        let replacement = try profile("keychain-replacement-" + UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: isolated.rootDirectory)
            try? FileManager.default.removeItem(at: replacement.rootDirectory)
        }
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let production = RuntimeIsolationProfile.production
        try #require(production.sessionDirectory.path.hasPrefix(formal.rootDirectory.path + "/"))
        for current in [isolated, production] {
            let spy = DiagnosticKeychainReaderSpy()
            let health = DiagnosticHealthRunController(profile: current, checker: { _ in .refused },
                keychainStatusReader: { spy.read() })
            #expect(health.defaultKeychainStatus == .notChecked)
            #expect(health.defaultKeychainStatusText.contains("具体凭据未检测"))
            let initial = health.localStatusText
            #expect(initial.contains("默认钥匙串库：未检测"))
            await health.refreshReadOnlyStatus().value
            _ = health.localStatusText
            #expect(spy.calls == 0)
            await health.checkDefaultKeychainStatus()
            #expect(health.defaultKeychainStatus == .isolated)
            #expect(health.defaultKeychainCheckedAt == nil && spy.calls == 0)
            #expect(health.localStatusText.contains("隔离或测试环境"))
            #expect(health.localStatusText.contains("不代表具体 API Key ACL"))
            #expect(health.reportForExport() == nil)
            health.cancel()
            #expect(health.defaultKeychainStatus == .notChecked && health.defaultKeychainCheckedAt == nil)
            await health.checkDefaultKeychainStatus()
            health.bindProfile(replacement)
            #expect(health.defaultKeychainStatus == .notChecked && spy.calls == 0)
        }
    }

    @Test func readOnlyRefreshMeasuresConfiguredSessionRootWithoutPayloadOrWriteProbe() async throws {
        let isolated = try profile()
        defer { try? FileManager.default.removeItem(at: isolated.rootDirectory) }
        try FileManager.default.createDirectory(at: isolated.sessionDirectory, withIntermediateDirectories: true)
        let nested = isolated.sessionDirectory.appendingPathComponent("ChatAttachments", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("private-payload")
        let payload = Data("private content must stay local".utf8)
        try payload.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        let probe = DeferredStorageCheck()
        let health = DiagnosticHealthRunController(profile: isolated,
            checker: { await probe.invoke($0) },
            localStatusProvider: { [
                DiagnosticLocalStatus(id: "storage", title: "存储", message: "等待统计",
                    nextStep: "去存储设置", settingsPageID: "settings-tab-storage")
            ] })
        await health.refreshReadOnlyStatus().value
        let text = health.localStatusText
        #expect(text.contains(ByteCountFormatter.string(fromByteCount: Int64(payload.count), countStyle: .file)))
        #expect(text.contains("同卷可用空间"))
        #expect(!text.contains("磁盘剩余未知"))
        #expect(!text.contains(isolated.rootDirectory.path) && !text.contains("private content"))
        #expect(health.storageStatus == nil && health.reportForExport() == nil)
        #expect(await probe.calls() == 0)

        let outside = isolated.rootDirectory.appendingPathComponent("outside-session")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: nested.appendingPathComponent("link"), withDestinationURL: outside)
        await health.refreshReadOnlyStatus().value
        #expect(health.localStatusText.contains("未完整统计"))
        #expect(health.storageStatus == nil)
        health.cancel()
    }

    @Test func exportReadsOnlyCompletedReportAndPreservesFourUnknownDomains() async throws {
        let isolated = try profile()
        defer { try? FileManager.default.removeItem(at: isolated.rootDirectory) }
        let clock = DiagnosticHealthTestClock()
        let calls = DeferredStorageCheck()
        let health = DiagnosticHealthRunController(
            profile: isolated,
            checker: { await calls.invoke($0) },
            clock: { clock.now }
        )
        let export = DiagnosticExportController(
            healthReportProvider: { health.reportForExport() },
            applicationInfoProvider: {
                DiagnosticApplicationInfo(version: "1.2.3", build: "456")
            },
            runtimeSummaryProvider: { .unknown },
            clock: { clock.now.addingTimeInterval(2) }
        )

        let before = try export.makeBundle()
        #expect(await calls.calls() == 0)
        #expect(before.healthSnapshotAt == nil)
        #expect(before.modules.allSatisfy { $0.state == .unknown })

        let run = Task { await health.run() }
        await calls.waitForInvocation(1)
        let during = try export.makeBundle()
        #expect(during.healthSnapshotAt == nil)
        await calls.finish(.writable)
        await run.value

        let after = try export.makeBundle()
        #expect(await calls.calls() == 1)
        #expect(after.healthSnapshotAt == clock.now)
        #expect(after.capturedAt == clock.now.addingTimeInterval(2))
        #expect(after.modules.count == 5)
        #expect(after.modules.first { $0.module == .storage }?.state == .ok)
        #expect(after.modules.filter { $0.module != .storage }.allSatisfy { $0.state == .unknown })
        #expect(after.health.unknownCount == 4)
        #expect(after.runtime.networkProbeTriggered == false)
        let bytes = try JSONEncoder().encode(after)
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(!text.contains(isolated.rootDirectory.path))
        #expect(!text.contains("Authorization"))
    }

    @Test func singleFlightCancelAndLateResultCannotPublish() async throws {
        let isolated = try profile()
        defer { try? FileManager.default.removeItem(at: isolated.rootDirectory) }
        let pending = DeferredStorageCheck()
        let health = DiagnosticHealthRunController(
            profile: isolated,
            checker: { await pending.invoke($0) }
        )

        let first = Task { await health.run() }
        await pending.waitForInvocation(1)
        await health.run()
        #expect(await pending.calls() == 1)
        health.cancel()
        await pending.finish(.writable)
        await first.value
        #expect(health.state == .cancelled)
        #expect(health.reportForExport() == nil)

        let second = Task { await health.run() }
        await pending.waitForInvocation(2)
        await pending.finish(.unwritable)
        await second.value
        #expect(await pending.calls() == 2)
        #expect(health.reportForExport()?.items.first?.status == .error)
    }

    @Test func expiryClockRollbackAndCancelledRefreshKeepOnlyPreviousFreshResult() async throws {
        let isolated = try profile()
        defer { try? FileManager.default.removeItem(at: isolated.rootDirectory) }
        let clock = DiagnosticHealthTestClock()
        let pending = DeferredStorageCheck()
        let mode = DiagnosticHealthCheckMode()
        let health = DiagnosticHealthRunController(
            profile: isolated,
            checker: { profile in
                if await mode.isDeferred() { return await pending.invoke(profile) }
                return .writable
            },
            clock: { clock.now }
        )
        await health.run()
        let completedAt = try #require(health.lastCompletedAt)
        #expect(health.reportForExport() != nil)
        clock.now = completedAt.addingTimeInterval(600)
        #expect(health.reportForExport() != nil)
        clock.now = completedAt.addingTimeInterval(601)
        #expect(health.reportForExport() == nil)
        clock.now = completedAt.addingTimeInterval(-1)
        #expect(health.reportForExport() == nil)

        clock.now = completedAt.addingTimeInterval(10)
        await mode.useDeferred()
        let refresh = Task { await health.run() }
        await pending.waitForInvocation(1)
        #expect(health.reportForExport()?.timestamp == completedAt)
        health.cancel()
        await pending.finish(.writable)
        await refresh.value
        #expect(health.reportForExport()?.timestamp == completedAt)
        #expect(health.lastCompletedAt == completedAt)
    }

    @Test func inFlightRootReplacementRejectsLateCompletion() async throws {
        let isolated = try profile()
        let displaced = isolated.rootDirectory.deletingLastPathComponent()
            .appendingPathComponent("\(isolated.rootDirectory.lastPathComponent)-moved", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: isolated.rootDirectory)
            try? FileManager.default.removeItem(at: displaced)
        }
        let pending = DeferredStorageCheck()
        let health = DiagnosticHealthRunController(
            profile: isolated,
            checker: { await pending.invoke($0) }
        )
        let run = Task { await health.run() }
        await pending.waitForInvocation(1)
        try FileManager.default.moveItem(at: isolated.rootDirectory, to: displaced)
        try FileManager.default.createSymbolicLink(at: isolated.rootDirectory, withDestinationURL: displaced)
        await pending.finish(.writable)
        await run.value
        #expect(health.state == .unavailable)
        #expect(health.reportForExport() == nil)
        #expect(await pending.calls() == 1)
    }

    @Test func refusedCheckDoesNotReplaceLastCompletedSnapshot() async throws {
        let isolated = try profile()
        defer { try? FileManager.default.removeItem(at: isolated.rootDirectory) }
        let clock = DiagnosticHealthTestClock()
        let mode = DiagnosticHealthCheckMode()
        let health = DiagnosticHealthRunController(
            profile: isolated,
            checker: { _ in
                if await mode.isDeferred() { return .refused }
                return .writable
            },
            clock: { clock.now }
        )
        await health.run()
        let original = try #require(health.reportForExport())
        await mode.useDeferred()
        clock.now = clock.now.addingTimeInterval(1)
        await health.run()
        #expect(health.state == .failed)
        #expect(health.reportForExport()?.timestamp == original.timestamp)
    }

    @Test func profileChangeBlockedModeAndReplacedRootRefuseWithoutCallingChecker() async throws {
        let first = try profile()
        let second = try profile()
        defer { try? FileManager.default.removeItem(at: first.rootDirectory) }
        defer { try? FileManager.default.removeItem(at: second.rootDirectory) }
        let calls = DeferredStorageCheck()
        let health = DiagnosticHealthRunController(
            profile: first,
            checker: { await calls.invoke($0) }
        )
        let initial = Task { await health.run() }
        await calls.waitForInvocation(1)
        await calls.finish(.writable)
        await initial.value
        #expect(health.reportForExport() != nil)
        health.bindProfile(second)
        #expect(health.reportForExport() == nil)
        #expect(health.state == .idle)

        health.bindProfile(.production)
        await health.run()
        #expect(health.state == .unavailable)
        #expect(await calls.calls() == 1)

        let replaced = try profile()
        let displaced = replaced.rootDirectory.deletingLastPathComponent()
            .appendingPathComponent("\(replaced.rootDirectory.lastPathComponent)-moved", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: replaced.rootDirectory)
            try? FileManager.default.removeItem(at: displaced)
        }
        try FileManager.default.moveItem(at: replaced.rootDirectory, to: displaced)
        try FileManager.default.createSymbolicLink(at: replaced.rootDirectory, withDestinationURL: displaced)
        health.bindProfile(replaced)
        await health.run()
        #expect(health.state == .unavailable)
        #expect(health.reportForExport() == nil)
        #expect(await calls.calls() == 1)
    }
}
