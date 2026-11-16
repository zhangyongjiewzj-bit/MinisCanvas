import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

@Suite("2179 Skills catalog uses the App root owner", .serialized)
@MainActor
struct SkillsStoreBoundCatalog2179Tests {
    private typealias Adapter = SkillsStoreTypedCatalogAdapter

    private func root(_ label: String) throws -> URL {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let directory = formal.temporaryDirectory.appendingPathComponent(
            "skills-bound-2179-\(label)-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func addApprovedEntry(at root: URL) throws {
        let store = SkillStore(skillsRoot: root.appendingPathComponent("app-skills", isDirectory: true))
        _ = try store.importSkillThroughLifecycle(
            content: "---\nname: bound-same\ndescription: synthetic\n---\nowned body", source: .file,
            reason: "explicit owned fixture approval",
            approval: SkillApproval(approverID: "bound-2179"))
    }

    private func owner(at root: URL, loadImmediately: Bool = true) -> SkillsStore {
        SkillsStore(
            appStore: SkillStore(skillsRoot: root.appendingPathComponent("app-skills", isDirectory: true)),
            stateFileURL: root.appendingPathComponent("enabled.json"),
            loadImmediately: loadImmediately
        )
    }

    @Test("same stable entry ID in another profile cannot read the trusted owner")
    func rejectsForeignOwnerEvenWithSameEntryID() throws {
        let leftRoot = try root("left")
        let rightRoot = try root("right")
        try addApprovedEntry(at: leftRoot)
        try addApprovedEntry(at: rightRoot)
        let left = owner(at: leftRoot)
        let right = owner(at: rightRoot)
        #expect(left.catalogRefreshStatus == .ready)
        #expect(right.catalogRefreshStatus == .ready)
        #expect(left.entries.map(\.id) == right.entries.map(\.id))
        #expect(throws: Adapter.ProjectionError.untrustedOwner) {
            _ = try Adapter.snapshot(from: left, boundTo: right)
        }
        #expect(try Adapter.snapshot(from: left, boundTo: left) == [
            "skills.app:bound-same.enabled": .toggle(true)
        ])
    }

    @Test("unscanned owner fails closed and pending entry is absent beside a ready sibling")
    func unreadyAndPendingDoNotProject() throws {
        let directory = try root("pending")
        try addApprovedEntry(at: directory)
        let appStore = SkillStore(skillsRoot: directory.appendingPathComponent("app-skills"))
        let store = SkillsStore(
            appStore: appStore,
            stateFileURL: directory.appendingPathComponent("enabled.json"),
            loadImmediately: false
        )
        #expect(throws: Adapter.ProjectionError.catalogUnavailable) {
            _ = try Adapter.snapshot(from: store, boundTo: store)
        }
        let pending = try appStore.importSkillThroughLifecycle(
            content: "---\nname: pending-bound\ndescription: synthetic\nversion: 1.0.0\n---\nowned body",
            source: .file,
            reason: "2179 synthetic pending source"
        )
        store.reload()
        #expect(store.catalogRefreshStatus == .ready)
        let values = try Adapter.snapshot(from: store, boundTo: store)
        #expect(values == ["skills.app:bound-same.enabled": .toggle(true)])
        #expect(values["skills.app:\(pending.skill.id).enabled"] == nil)
        #expect(throws: Adapter.ProjectionError.pendingReview) {
            _ = try Adapter.preview(
                settingID: "skills.app:\(pending.skill.id).enabled",
                value: .toggle(true),
                in: store
            )
        }
    }
}
