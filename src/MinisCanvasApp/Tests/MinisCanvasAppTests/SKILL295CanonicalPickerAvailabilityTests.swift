import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-SKILL-04 canonical picker availability")
@MainActor
struct SKILL295CanonicalPickerAvailabilityTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill295-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func content(_ name: String) -> String {
        "---\nname: \(name)\ndescription: bounded availability fixture\nversion: 1.0.0\n---\nbody for \(name)"
    }

    @Test("only approved canonical skills enter the catalog and injection")
    func onlyApprovedCanonicalSkillsAreExecutablePickerItems() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let appStore = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        _ = try appStore.importSkillThroughLifecycle(content: content("pending"),
            source: .file, reason: "unapproved canonical fixture")
        let approved = try appStore.importSkillThroughLifecycle(
            content: content("approved"), source: .file, reason: "explicit fixture approval",
            approval: SkillApproval(approverID: "skill295")
        )
        let catalog = SkillCatalogLoader.loadCatalog(appStore: appStore, servers: [])
        #expect(catalog.map(\.id) == ["skill:\(approved.skill.id)"])
        let injector = SkillInjector(store: appStore)
        #expect(injector.buildInjection(for: "approved", selectedSkillIDs: catalog.map(\.id)).receipts.contains { $0.injected })
        #expect(injector.buildInjection(for: "pending", selectedSkillIDs: ["skill:pending"]).receipts.allSatisfy { !$0.injected })
    }

    @Test("a committed disable removes the visible skill and its old Composer selection")
    func disabledSkillDisappearsAndPrunesOldSelection() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let appStore = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let imported = try appStore.importSkill(content: content("enabled"), source: .file)
        let chat = ChatStore()
        chat.pickerCatalogLoader = { SkillCatalogLoader.loadCatalog(appStore: appStore, servers: []) }
        chat.loadPickerCatalog()
        let item = try #require(chat.pickerCatalog.first)
        chat.togglePickerItem(item)
        #expect(!chat.selectedPickerItems.isEmpty)
        appStore.setEnabled(imported.id, enabled: false)
        chat.loadPickerCatalog()
        #expect(chat.pickerCatalog.isEmpty)
        #expect(chat.selectedPickerItems.isEmpty)
        #expect(chat.draftText.isEmpty)
    }

    @Test("quarantine and a persisted disable override both exclude skills")
    func quarantinedAndPersistentlyDisabledSkillsAreExcluded() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let appStore = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let imported = try appStore.importSkill(content: content("approved"), source: .file)
        _ = try appStore.importSkillThroughLifecycle(
            content: content("untrusted"), source: .url("https://example.invalid/skill.md"), reason: "untrusted fixture"
        )
        let catalog = SkillCatalogLoader.loadCatalog(
            appStore: appStore, servers: [],
            enabledStates: ["app:\(imported.id)": false]
        )
        #expect(catalog.isEmpty)
        #expect(appStore.lifecycleReceipt(for: "untrusted")?.state == .quarantined)
    }

    @Test("listing a scoped approved skill does not broaden its turn authorization")
    func pickerAvailabilityPreservesScopedAuthorization() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let appStore = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let scope = MemoryScope(sessionID: "skill295-session", projectID: "skill295-project")
        let imported = try appStore.importSkillThroughLifecycle(
            content: content("scoped"), source: .file, reason: "scoped fixture",
            scope: scope, approval: SkillApproval(approverID: "skill295", scope: scope)
        )
        let catalog = SkillCatalogLoader.loadCatalog(appStore: appStore, servers: [])
        #expect(catalog.map(\.id) == ["skill:\(imported.skill.id)"])
        let injector = SkillInjector(store: appStore)
        #expect(injector.buildInjection(for: "scoped", selectedSkillIDs: catalog.map(\.id)).fragment == nil)
        #expect(injector.buildInjection(for: "scoped", selectedSkillIDs: catalog.map(\.id), within: scope).receipts.contains { $0.injected })
    }

    @Test("packaged field picker reads the same approved canonical skill as Settings")
    func packagedFieldPickerUsesTheSettingsProfileRoot() throws {
        let ownedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill957-field-\(UUID().uuidString)", isDirectory: true)
        let environment = [
            RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
            RuntimeIsolationProfile.fieldActivationRootKey: ownedRoot.path
        ]
        let arguments = ["/Applications/MinisCanvas.app/Contents/MacOS/MinisCanvas",
                         RuntimeIsolationProfile.fieldActivationArgument]
        let profile = try RuntimeIsolationProfile.makePackagedField(
            processEnvironment: environment,
            processArguments: arguments
        )
        defer { try? profile.cleanupDisposableRoots() }

        let canonicalRoot = profile.minisCoreDirectory.appendingPathComponent("skills", isDirectory: true)
        let settingsStore = SkillsStore(
            appStore: SkillStore(skillsRoot: canonicalRoot),
            stateFileURL: profile.skillStateURL
        )
        let selected = ownedRoot.appendingPathComponent("selected-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        try content("skill957-owned").write(
            to: selected.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )

        let proposed = try settingsStore.proposeLocalSkill(from: selected).get()
        func pickerItems() -> [PickerCatalogItem] {
            let inputs = SkillCatalogLoader.defaultInputs(
                processEnvironment: environment,
                processArguments: arguments,
                processName: "MinisCanvas"
            )
            return SkillCatalogLoader.loadCatalog(
                appStore: inputs.appStore,
                servers: inputs.servers,
                enabledStates: inputs.enabledStates
            )
        }
        #expect(pickerItems().allSatisfy { $0.id != "skill:skill957-owned" },
                "A proposal must remain absent from the Composer picker")

        _ = try settingsStore.approveLocalSkill(proposed).get()
        #expect(settingsStore.entries.contains { $0.id == "app:skill957-owned" && $0.isEnabled })
        let inputs = SkillCatalogLoader.defaultInputs(
            processEnvironment: environment,
            processArguments: arguments,
            processName: "MinisCanvas"
        )
        #expect(inputs.appStore.skillsRoot == canonicalRoot)
        #expect(pickerItems().contains { $0.id == "skill:skill957-owned" && $0.isEnabled },
                "The default picker path must see the skill approved in Settings")

        try settingsStore.setEnabled("app:skill957-owned", enabled: false).get()
        #expect(pickerItems().allSatisfy { $0.id != "skill:skill957-owned" })
        try settingsStore.setEnabled("app:skill957-owned", enabled: true).get()
        #expect(pickerItems().contains { $0.id == "skill:skill957-owned" && $0.isEnabled })
    }

}
