import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("SETC Skills typed projection from the production settings owner")
@MainActor
struct SkillsStoreTypedCatalogAdapter2116Tests {
    private typealias Adapter = SkillsStoreTypedCatalogAdapter

    private func ownedRoot(_ label: String) throws -> URL {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = formal.temporaryDirectory
            .appendingPathComponent("setc-skills-2116-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func expectError(
        _ expected: Adapter.ProjectionError,
        _ operation: () throws -> Void
    ) {
        do {
            try operation()
            Issue.record("Expected \(expected), but projection accepted the request")
        } catch let actual as Adapter.ProjectionError {
            #expect(actual == expected)
        } catch {
            Issue.record("Unexpected projection error: \(error)")
        }
    }

    @Test func approvedEntriesProjectOnlyTypedEnablementAndReopenFromOwner() throws {
        let root = try ownedRoot("reopen")
        defer { try? FileManager.default.removeItem(at: root) }
        let appRoot = root.appendingPathComponent("app-skills", isDirectory: true)
        let hermesRoot = root.appendingPathComponent("hermes", isDirectory: true)
        let stateURL = root.appendingPathComponent("enabled.json")
        let appStore = SkillStore(skillsRoot: appRoot)
        let approved = try appStore.importSkillThroughLifecycle(
            content: "---\nname: setc-approved\ndescription: synthetic\nversion: 1.0.0\n---\nowned body",
            source: .bundled,
            reason: "SETC synthetic approved skill",
            approval: SkillApproval(approverID: "setc-2116-owned")
        )
        let hermesDirectory = hermesRoot.appendingPathComponent("creative/setc-hermes", isDirectory: true)
        try FileManager.default.createDirectory(at: hermesDirectory, withIntermediateDirectories: true)
        _ = try appStore.importSkillThroughLifecycle(
            content: "---\nname: setc-hermes\ndescription: synthetic\n---\nowned body", source: .file,
            reason: "explicit owned typed projection fixture",
            approval: SkillApproval(approverID: "typed-2116"))
        let store = SkillsStore(appStore: appStore, stateFileURL: stateURL)
        #expect(store.catalogRefreshStatus == .ready)

        let appKey = "skills.app:\(approved.skill.id).enabled"
        let hermesKey = "skills.app:setc-hermes.enabled"
        let values = try Adapter.snapshot(from: store)
        #expect(values == [appKey: .toggle(true), hermesKey: .toggle(true)])
        let preview = try Adapter.preview(settingID: appKey, value: .toggle(false), in: store)
        #expect(preview.requiresLifecycleApproval)
        #expect(preview.currentEnabled && !preview.proposedEnabled)
        try Adapter.revalidate(preview, in: store)
        #expect(store.isEnabled("app:\(approved.skill.id)"), "preview must not mutate the owner")

        guard case .success = store.setEnabled("app:\(approved.skill.id)", enabled: false) else {
            Issue.record("Existing lifecycle owner rejected synthetic disable")
            return
        }
        let reopened = SkillsStore(
            appStore: SkillStore(skillsRoot: appRoot),
            stateFileURL: stateURL
        )
        #expect(try Adapter.snapshot(from: reopened)[appKey] == .toggle(false))
        #expect(try Adapter.snapshot(from: reopened)[hermesKey] == .toggle(true))
        expectError(.stalePreview) { try Adapter.revalidate(preview, in: store) }
    }

    @Test func rejectsUnscannedUnknownWrongTypePendingReviewAndStaleGeneration() throws {
        let root = try ownedRoot("reject")
        defer { try? FileManager.default.removeItem(at: root) }
        let appStore = SkillStore(skillsRoot: root.appendingPathComponent("app-skills"))
        let hermesRoot = root.appendingPathComponent("hermes")
        try FileManager.default.createDirectory(at: hermesRoot, withIntermediateDirectories: true)
        let stateURL = root.appendingPathComponent("enabled.json")
        let unscanned = SkillsStore(
             appStore: appStore,
            stateFileURL: stateURL, loadImmediately: false
        )
        expectError(.catalogUnavailable) { _ = try Adapter.snapshot(from: unscanned) }

        let pending = try appStore.importSkillThroughLifecycle(
            content: "---\nname: setc-pending\ndescription: synthetic\nversion: 1.0.0\n---\nowned body",
            source: .file,
            reason: "SETC synthetic pending proposal"
        )
        unscanned.reload()
        #expect(unscanned.catalogRefreshStatus == .ready)
        let key = "skills.app:\(pending.skill.id).enabled"
        #expect(unscanned.hasPendingLocalSkillReview(for: "app:\(pending.skill.id)"))
        expectError(.unknownSetting) {
            _ = try Adapter.preview(settingID: "skills.app:missing.enabled", value: .toggle(true), in: unscanned)
        }
        expectError(.invalidValue) {
            _ = try Adapter.preview(settingID: key, value: .text("true"), in: unscanned)
        }
        expectError(.pendingReview) {
            _ = try Adapter.preview(settingID: key, value: .toggle(true), in: unscanned)
        }

        let hermesDirectory = hermesRoot.appendingPathComponent("creative/setc-reload", isDirectory: true)
        try FileManager.default.createDirectory(at: hermesDirectory, withIntermediateDirectories: true)
        _ = try appStore.importSkillThroughLifecycle(
            content: "---\nname: setc-reload\ndescription: synthetic\n---\nowned body", source: .file,
            reason: "explicit owned typed projection fixture",
            approval: SkillApproval(approverID: "typed-2116"))
        unscanned.reload()
        let hermesKey = "skills.app:setc-reload.enabled"
        expectError(.unchanged) {
            _ = try Adapter.preview(settingID: hermesKey, value: .toggle(true), in: unscanned)
        }
        let preview = try Adapter.preview(settingID: hermesKey, value: .toggle(false), in: unscanned)
        unscanned.reload()
        expectError(.stalePreview) { try Adapter.revalidate(preview, in: unscanned) }
    }
}
