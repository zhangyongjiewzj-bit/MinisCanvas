import Foundation
import Testing
import SwiftUI
import MinisCore
@testable import MinisCanvasApp

// RECOVERY-08 consumer coverage. Two domains were measured silent at the
// bound base (isolated/recovered, but never told to the user):
//   domain (a): `BridgeStore.quarantineCorruptProviderRuntimeObservationJournal`
//     moves the corrupt provider-runtime observation journal to
//     `provider-runtime-observations-v1.corrupt-<uuid>.json` and sets
//     `providerRuntimeObservationQuarantineURL`, which had zero readers in
//     the whole tree.
//   domain (b): `AgentTaskStore` init recovery discards an orphaned temporary
//     ledger and records an `orphaned-temporary-file` persistence diagnostic,
//     whose accessor `persistenceDiagnostics()` had zero App-source readers.
// Both are now published through the one computed surface
// `BridgeStore.recoveryNotices` and rendered by the production consumer
// `RecoveryNoticeBanner` wired in `MinisCanvasApp.swift`. Each test below
// states which domain it covers; no test asserts a RED row, a journey, or a
// package outcome.

@Suite("RECOVERY-08 corrupt-data recovery notice consumer")
@MainActor
struct RecoveryCorruptNoticeConsumerTests {
    private func makeTemporaryRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("recovery08-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func repositorySource(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    /// Domain (a): the production load path quarantines the corrupt journal,
    /// preserves the original bytes, continues launch, and the published
    /// recovery notice truthfully states what was isolated and where the
    /// original bytes moved.
    @Test("Quarantined corrupt provider-runtime journal is published as a recovery notice")
    func quarantinedCorruptJournalIsPublishedAsRecoveryNotice() async throws {
        let root = try makeTemporaryRoot("journal")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDirectory = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let corruptBytes = Data("recovery-08-not-a-valid-journal".utf8)
        let journalURL = sessionDirectory.appendingPathComponent("provider-runtime-observations-v1.json")
        try corruptBytes.write(to: journalURL)

        let bridge = BridgeStore()
        await bridge.attachProductionServices(
            sessionDirectory: sessionDirectory,
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json")),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        ).value

        // Isolation behaviour itself must not weaken: the file was moved, the
        // original bytes are preserved, and a fresh journal continues launch.
        let quarantine = try #require(bridge.providerRuntimeObservationQuarantineURL)
        #expect(try Data(contentsOf: quarantine) == corruptBytes)
        #expect(FileManager.default.fileExists(atPath: journalURL.path))

        let notices = bridge.recoveryNotices
        #expect(notices.count == 1)
        let notice = try #require(notices.first)
        #expect(notice.contains("Provider 运行时观察日志已损坏"))
        #expect(notice.contains(quarantine.path))
        #expect(notice.contains("继续使用新的日志"))
    }

    /// Domain (b): AgentTaskStore recovery discards the orphaned temporary
    /// ledger, keeps the durable ledger, and the published recovery notice
    /// carries the canonical diagnostic (operation/reason/message) so the
    /// user learns the recovery happened.
    @Test("Orphaned temporary ledger recovery is published as a recovery notice")
    func orphanedTemporaryLedgerRecoveryIsPublishedAsRecoveryNotice() throws {
        let root = try makeTemporaryRoot("ledger")
        defer { try? FileManager.default.removeItem(at: root) }
        let ledgerURL = root.appendingPathComponent("agent-tasks-v1.json")

        // Seed a durable ledger through the canonical store, then simulate a
        // crash that left an orphaned temporary sibling behind.
        let seed = try AgentTaskStore(persistenceURL: ledgerURL)
        _ = try seed.enqueue(
            taskID: "recovery08-task",
            parentID: "recovery08-parent",
            providerID: nil,
            modelID: nil
        )
        let temporaryURL = ledgerURL.appendingPathExtension("tmp")
        try Data("recovery-08-orphaned-temp".utf8).write(to: temporaryURL)

        let bridge = try BridgeStore(taskStorePersistenceURL: ledgerURL)

        // Recovery behaviour must not weaken: temporary discarded, durable
        // ledger retained and reloaded.
        let diagnostic = try #require(bridge.agentTaskStore.persistenceDiagnostics())
        #expect(diagnostic.operation == "recover")
        #expect(diagnostic.reason == "orphaned-temporary-file")
        #expect(!FileManager.default.fileExists(atPath: temporaryURL.path))
        #expect(FileManager.default.fileExists(atPath: ledgerURL.path))
        #expect(bridge.taskCenterObservation.counts.queued == 1)

        let notices = bridge.recoveryNotices
        #expect(notices.count == 1)
        let notice = try #require(notices.first)
        #expect(notice.contains("任务账本恢复提示"))
        #expect(notice.contains("recover: orphaned-temporary-file"))
        #expect(notice.contains(diagnostic.message))
    }

    /// Both domains, negative control: a clean composition quarantines and
    /// recovers nothing, so the published surface is empty and the consumer
    /// banner has nothing to render (launch is never blocked or notified on
    /// untouched data).
    @Test("Clean launch publishes no recovery notices")
    func cleanLaunchPublishesNoRecoveryNotices() throws {
        let root = try makeTemporaryRoot("clean")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDirectory = root.appendingPathComponent("sessions", isDirectory: true)

        let bridge = try BridgeStore(
            taskStorePersistenceURL: root.appendingPathComponent("agent-tasks-v1.json")
        )
        #expect(bridge.recoveryNotices.isEmpty)
        bridge.attachProductionServices(
            sessionDirectory: sessionDirectory,
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json")),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        )
        #expect(bridge.providerRuntimeObservationQuarantineURL == nil)
        #expect(bridge.agentTaskStore.persistenceDiagnostics() == nil)
        #expect(bridge.recoveryNotices.isEmpty)
    }

    /// Domains (a)+(b) consumer proof: the App root (production code, not
    /// this test) reads `bridge.recoveryNotices` and renders each entry as
    /// text through `RecoveryNoticeBanner`, on a non-blocking overlay path.
    /// Without this reader the published surface would repeat the exact
    /// measured defect (written but never read).
    @Test("App production source consumes the published recovery notices")
    func appSourceConsumesPublishedRecoveryNotices() throws {
        let appSource = try repositorySource(
            "src/MinisCanvasApp/Sources/MinisCanvasApp/MinisCanvasApp.swift"
        )
        // The published surface is read in production view code.
        #expect(appSource.contains("notices: bridge.recoveryNotices"))
        // A real view renders each notice, not just stores the array.
        #expect(appSource.contains("struct RecoveryNoticeBanner"))
        #expect(appSource.contains("Text(notice)"))
        // The banner is an overlay on the normal launched interface: it is
        // never installed on the blocking bootstrap-failure path, so a
        // recovery notice cannot modal-trap or delay a healthy launch.
        #expect(appSource.contains(".overlay(alignment: .top)"))
    }
}
