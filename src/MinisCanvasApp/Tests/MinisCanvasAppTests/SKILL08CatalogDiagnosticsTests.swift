import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private func sk08TempDir(_ label: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SK8-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func writeSK08Skill(at directory: URL, content: String) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try content.write(
        to: directory.appendingPathComponent("SKILL.md"),
        atomically: true,
        encoding: .utf8
    )
}

@Suite("SKILL-08 bounded catalog diagnostics")
struct SKILL08CatalogDiagnosticsTests {
    @Test func hermesDiagnosticsLocateOnlyTheSafeBasenameAndKeepSibling() throws {
        let root = try sk08TempDir("hermes-safe")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSK08Skill(
            at: root.appendingPathComponent("bad"),
            content: "---\nname: Bad\nNAME: Duplicate\nversion: 1.0.0\n---\nSECRET_BODY"
        )
        try writeSK08Skill(
            at: root.appendingPathComponent("good"),
            content: "---\nname: Good\nversion: 1.0.0\n---\nbody"
        )

        let picker = SkillsScanner.mergedEntriesWithDiagnostics(appSnapshot: SkillStore(skillsRoot: root.appendingPathComponent(".canonical-app")).snapshot(), enabledStates: [:], localRoots: [root])
        let settings = SkillsScanner.scanLocalDirectoryWithDiagnostics(root: root)
        for report in [picker.diagnostics, settings.diagnostics] {
            #expect(report.rejectedCount == 1)
            #expect(report.samples.count == 1)
            #expect(report.samples[0].source == .localDirectory)
            #expect(report.samples[0].locator == "bad")
            #expect(report.samples[0].code == .documentRejected)
            #expect(report.safeMessages.allSatisfy { !$0.contains(root.path) })
            #expect(report.safeMessages.allSatisfy { !$0.contains("SECRET_BODY") })
        }
        #expect(picker.entries.map(\.name) == ["Good"])
        #expect(settings.entries.map(\.name) == ["Good"])
    }

    @Test func appDiagnosticsUseStableIDLocatorAndKeepValidStoreEntries() throws {
        let root = try sk08TempDir("app-safe")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillStore(skillsRoot: root)
        _ = try store.importSkill(
            content: "---\nname: Good App\nversion: 1.0.0\n---\nbody",
            source: .file
        )
        let bad = try store.importSkill(
            content: "---\nname: Bad App\nversion: 1.0.0\n---\nbody",
            source: .file
        )
        try "---\nname: Bad App\nNAME: Duplicate\nversion: 1.0.0\n---\nSECRET_APP_BODY".write(
            to: store.skillDirectoryURL(for: bad.id).appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        let picker = SkillCatalogLoader.storeSkillItemsWithDiagnostics(from: store)
        let settings = SkillsScanner.scanAppWithDiagnostics(store: store)
        for report in [picker.diagnostics, settings.diagnostics] {
            #expect(report.rejectedCount == 1)
            #expect(report.samples[0].source == .app)
            #expect(report.samples[0].locator == bad.id)
            #expect(report.samples[0].code == .documentRejected)
            #expect(report.safeMessages.allSatisfy { !$0.contains(root.path) })
            #expect(report.safeMessages.allSatisfy { !$0.contains("SECRET_APP_BODY") })
        }
        #expect(picker.items.map(\.name) == ["Good App"])
        #expect(settings.entries.map(\.name) == ["Good App"])
    }

    @Test func reportSamplesAreBoundedWhileCountsRemainComplete() throws {
        let root = try sk08TempDir("bounded")
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<40 {
            try writeSK08Skill(
                at: root.appendingPathComponent("bad-\(index)"),
                content: "---\nname: Bad\nNAME: Duplicate\nversion: 1.0.0\n---\nBODY-\(index)"
            )
        }

        let result = SkillsScanner.mergedEntriesWithDiagnostics(appSnapshot: SkillStore(skillsRoot: root.appendingPathComponent(".canonical-app")).snapshot(), enabledStates: [:], localRoots: [root])
        #expect(result.entries.isEmpty)
        #expect(result.diagnostics.rejectedCount == 40)
        #expect(result.diagnostics.counts[.documentRejected] == 40)
        #expect(result.diagnostics.samples.count == SkillCatalogDiagnosticReport.maxSamples)
        #expect(result.diagnostics.suppressedSampleCount == 8)
        #expect(result.diagnostics.safeMessages.allSatisfy { !$0.contains(root.path) })
        #expect(result.diagnostics.safeMessages.allSatisfy { !$0.contains("BODY-") })
    }

    @Test func combinedSettingsReportMergesAppAndHermesWithoutGrowingSamples() throws {
        let hermesRoot = try sk08TempDir("combined-hermes")
        let appRoot = try sk08TempDir("combined-app")
        defer {
            try? FileManager.default.removeItem(at: hermesRoot)
            try? FileManager.default.removeItem(at: appRoot)
        }
        try writeSK08Skill(
            at: hermesRoot.appendingPathComponent("bad-hermes"),
            content: "---\nname: Bad Hermes\nNAME: Duplicate\nversion: 1.0.0\n---\nbody"
        )
        let store = SkillStore(skillsRoot: appRoot)
        _ = try store.importSkill(
            content: "---\nname: Good App\nversion: 1.0.0\n---\nbody",
            source: .file
        )

        let result = SkillsScanner.mergedEntriesWithDiagnostics(
            appSnapshot: store.snapshot(),
            enabledStates: [:], localRoots: [hermesRoot]
        )
        #expect(result.entries.map(\.name) == ["Good App"])
        #expect(result.diagnostics.rejectedCount == 1)
        #expect(result.diagnostics.samples.count == 1)
        #expect(result.diagnostics.safeMessages[0].contains("bad-hermes"))
    }

    @Test func combinedScannerUsesFrozenSnapshotAfterCanonicalSkillDrift() throws {
        let hermesRoot = try sk08TempDir("drift-hermes")
        let appRoot = try sk08TempDir("drift-app")
        defer {
            try? FileManager.default.removeItem(at: hermesRoot)
            try? FileManager.default.removeItem(at: appRoot)
        }
        let store = SkillStore(skillsRoot: appRoot)
        let skill = try store.importSkill(
            content: "---\nname: Stable App\nversion: 1.0.0\n---\nbody",
            source: .file
        )
        let snapshot = store.snapshot()
        let receiptURL = store.lifecycleReceiptsFileURL
        let beforeReceiptBytes = try Data(contentsOf: receiptURL)
        try "---\nname: Drifted\nNAME: Duplicate\nversion: 1.0.0\n---\nchanged"
            .write(
                to: store.skillDirectoryURL(for: skill.id).appendingPathComponent("SKILL.md"),
                atomically: true,
                encoding: .utf8
            )

        let result = SkillsScanner.mergedEntriesWithDiagnostics(
            appSnapshot: snapshot,
            enabledStates: [:], localRoots: [hermesRoot]
        )

        #expect(result.entries.map(\.name) == ["Stable App"])
        #expect(result.diagnostics.rejectedCount == 0)
        #expect(try Data(contentsOf: receiptURL) == beforeReceiptBytes)
    }

    @MainActor
    @Test(arguments: [false, true])
    func originalProjectionReloadStaysFrozenAfterDrift(background: Bool) async throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = formal.rootDirectory.appendingPathComponent("arch1-reload-drift-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = SkillStore(skillsRoot: root.appendingPathComponent("app"))
        let imported = try owner.importSkill(content: "---\nname: Stable App\nversion: 1.0.0\n---\nbody", source: .file)
        let projection = SkillsStore(appStore: owner,
            stateFileURL: root.appendingPathComponent("enablement.json"), loadImmediately: false)
        // Capture the positive control before external mutation. The actual
        // projection captures only when reload/reloadInBackground is called.
        let capturedBeforeDrift = owner.snapshot()
        let receiptBytes = try Data(contentsOf: owner.lifecycleReceiptsFileURL)
        let document = owner.skillDirectoryURL(for: imported.id).appendingPathComponent("SKILL.md")
        let drift = "---\nname: Drifted\nNAME: Duplicate\nversion: 1.0.0\n---\nchanged"
        try drift.write(to: document, atomically: true, encoding: .utf8)
        let frozenBefore = SkillsScanner.mergedEntriesWithDiagnostics(
            appSnapshot: capturedBeforeDrift, enabledStates: [:])
        #expect(frozenBefore.entries.map(\.name) == ["Stable App"])
        #expect(frozenBefore.diagnostics.rejectedCount == 0)
        if background { await projection.reloadInBackground().value } else { projection.reload() }
        // This real path captures after drift; reject the corrupt input while
        // keeping the canonical source and lifecycle receipt byte-for-byte.
        #expect(projection.entries.isEmpty)
        #expect(projection.catalogDiagnostics.rejectedCount == 1)
        #expect(projection.catalogDiagnostics.safeMessages == ["app:stable-app:document_rejected"])
        #expect(try Data(contentsOf: owner.lifecycleReceiptsFileURL) == receiptBytes)
        #expect(try String(contentsOf: document, encoding: .utf8) == drift)
        // The canonical writer observes and quarantines the corrupt document;
        // retaining a disabled metadata row is its intended integrity policy.
        owner.reload()
        let live = try #require(owner.allSkills().first { $0.id == imported.id })
        #expect(!live.isEnabled)
        #expect(live.integrity.state == .hashMismatch)
        #expect(owner.lifecycleReceipt(for: imported.id)?.state == .quarantined)
        #expect(try String(contentsOf: document, encoding: .utf8) == drift)
    }

    // Diagnostic only: retain originalProjectionReloadStaysFrozenAfterDrift
    // and every original assertion unchanged. The variable is capture time.
    @MainActor
    @Test("ARCH1 drift diagnostic distinguishes capture-before and capture-after plus live metadata")
    func originalProjectionDriftCaptureTimingDiagnostic() async throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        for background in [false, true] {
            let root = formal.rootDirectory.appendingPathComponent("arch1-capture-diag-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let owner = SkillStore(skillsRoot: root.appendingPathComponent("app"))
            let original = "---\nname: Stable App\nversion: 1.0.0\n---\nbody"
            let imported = try owner.importSkill(content: original, source: .file)
            _ = root.appendingPathComponent("hermes")
            let projection = SkillsStore(appStore: owner,
                stateFileURL: root.appendingPathComponent("enablement.json"), loadImmediately: false)
            let beforeSnapshot = owner.snapshot()
            #expect(beforeSnapshot.rawContents[imported.id] == original)
            let receiptURL = owner.lifecycleReceiptsFileURL
            let beforeReceipts = try Data(contentsOf: receiptURL)
            let document = owner.skillDirectoryURL(for: imported.id).appendingPathComponent("SKILL.md")
            let drift = "---\nname: Drifted\nNAME: Duplicate\nversion: 1.0.0\n---\nchanged"
            try drift.write(to: document, atomically: true, encoding: .utf8)
            let afterSnapshot = owner.snapshot()
            let beforeResult = SkillsScanner.mergedEntriesWithDiagnostics(
                 appSnapshot: beforeSnapshot, enabledStates: [:])
            let afterResult = SkillsScanner.mergedEntriesWithDiagnostics(
                 appSnapshot: afterSnapshot, enabledStates: [:])
            // Positive control differs solely in snapshot capture time.
            #expect(beforeResult.entries.map(\.name) == ["Stable App"])
            #expect(beforeResult.diagnostics.rejectedCount == 0)
            print("ARCH1_CAPTURE_DIAG background=\(background) beforeOriginal=\(beforeSnapshot.rawContents[imported.id] == original) afterDrift=\(afterSnapshot.rawContents[imported.id] == drift) beforeEntries=\(beforeResult.entries.map(\.name)) beforeReject=\(beforeResult.diagnostics.rejectedCount) afterEntries=\(afterResult.entries.map(\.name)) afterReject=\(afterResult.diagnostics.rejectedCount)")
            if background { await projection.reloadInBackground().value } else { projection.reload() }
            let scannerDidNotWrite = try Data(contentsOf: receiptURL) == beforeReceipts
            #expect(scannerDidNotWrite)
            print("ARCH1_PROJECTION_DIAG background=\(background) entries=\(projection.entries.map(\.name)) rejected=\(projection.catalogDiagnostics.rejectedCount) diagnostic=\(projection.catalogDiagnostics.safeMessages) receiptUnchanged=\(scannerDidNotWrite)")
            owner.reload()
            let live = owner.allSkills().first { $0.id == imported.id }
            print("ARCH1_LIVE_DIAG background=\(background) retained=\(live != nil) enabled=\(String(describing: live?.isEnabled)) integrity=\(String(describing: live?.integrity)) lifecycle=\(String(describing: owner.lifecycleReceipt(for: imported.id)?.state))")
        }
    }
}
