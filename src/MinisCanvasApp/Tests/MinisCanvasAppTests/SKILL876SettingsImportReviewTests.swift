import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("SKILL876 explicit Settings import and review")
@MainActor
struct SKILL876SettingsImportReviewTests {
    private let document = """
        ---
        name: skill876-owned
        description: selected owned skill
        version: 1.0.0
        ---
        complete owned body line one
        complete owned body line two
        """

    @Test("selected local source remains proposed and disabled until explicit Settings approval, including restart")
    func proposalThenApprovalUsesCanonicalConsumer() throws {
        let root = try ownedRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = try selectedDirectory(in: root, content: document)
        let skillsRoot = root.appendingPathComponent("skills")
        let stateURL = root.appendingPathComponent("enabled.json")
        let canonical = SkillStore(skillsRoot: skillsRoot)
        let settings = SkillsStore(
            appStore: canonical,
            stateFileURL: stateURL
        )
        let proposal = try #require(settings.proposeLocalSkill(from: selected).successValue)
        let pending = try #require(canonical.lifecycleReceipt(for: proposal.skillID))
        #expect(pending.state == .proposed)
        #expect(pending.action == .propose)
        #expect(pending.approvedBy == nil)
        #expect(pending.scope == nil)
        #expect(pending.contentHash == SkillManifest.hash(document))
        #expect(canonical.allSkills().first { $0.id == proposal.skillID }?.isEnabled == false)
        #expect(SkillInjector(store: canonical).buildInjection(for: "skill876-owned").fragment == nil)
        #expect(SkillCatalogLoader.loadCatalog(
            appStore: canonical, servers: []
        ).isEmpty)
        guard case .failure = settings.setEnabled("app:\(proposal.skillID)", enabled: true) else {
            Issue.record("pending proposal was enabled through the ordinary toggle")
            return
        }

        let reopenedStore = SkillStore(skillsRoot: skillsRoot)
        let reopened = SkillsStore(
            appStore: reopenedStore,
            stateFileURL: stateURL
        )
        let recovered = try #require(reopened.pendingLocalSkillReview(for: "app:\(proposal.skillID)"))
        #expect(recovered.contentHash == proposal.contentHash)
        #expect(reopenedStore.lifecycleReceipt(for: proposal.skillID)?.state == .proposed)
        #expect(SkillInjector(store: reopenedStore).buildInjection(for: "skill876-owned").fragment == nil)
        let active = try #require(reopened.approveLocalSkill(recovered).successValue)
        #expect(active.state == .active)
        #expect(active.action == .activate)
        #expect(active.scope == nil)
        #expect(active.contentHash == proposal.contentHash)
        #expect(active.approvedBy?.hasPrefix("settings-explicit-review:local-uid-") == true)
        #expect(SkillInjector(store: reopenedStore).buildInjection(for: "skill876-owned")
            .fragment?.contains("complete owned body line two") == true)
        #expect(SkillCatalogLoader.loadCatalog(
            appStore: reopenedStore, servers: []
        ).map(\.id) == ["skill:\(proposal.skillID)"])
        let projectScope = MemoryScope(sessionID: "owned-session", projectID: "owned-project")
        #expect(SkillInjector(store: reopenedStore).buildInjection(
            for: "skill876-owned", within: projectScope
        ).fragment?.contains("complete owned body line two") == true)
        #expect(reopened.pendingLocalSkillReview(for: "app:\(proposal.skillID)") == nil)
    }

    @Test("explicit re-review replaces the installed copy approval with only the current exact scope")
    func installedCopyReviewBindsScopeAndRejectsStaleContextOrContent() throws {
        let root = try ownedRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let canonical = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let installed = try canonical.importSkill(content: document)
        let settings = SkillsStore(appStore: canonical, stateFileURL: root.appendingPathComponent("enabled.json"))
        let selected = MemoryScope(sessionID: "owned-a", projectID: "project-a")
        let otherSession = MemoryScope(sessionID: "owned-b", projectID: "project-a")
        let otherProject = MemoryScope(sessionID: "owned-a", projectID: "project-b")
        let draft = try #require(settings.reviewAppSkill(for: "app:" + installed.id, in: selected).successValue)
        let previous = try #require(canonical.lifecycleReceipt(for: installed.id))
        #expect(canonical.lifecycleReceipt(for: installed.id) == previous)
        guard case .failure(.proposalChanged) = settings.approveLocalSkill(draft, currentScope: otherProject) else {
            Issue.record("a different current scope consumed the review")
            return
        }
        #expect(canonical.lifecycleReceipt(for: installed.id) == previous)
        let approved = try #require(settings.approveLocalSkill(draft, currentScope: selected).successValue)
        #expect(approved.scope == selected && approved.receiptID != previous.receiptID)
        #expect(canonical.rawContent(installed.id) == document)
        let injector = SkillInjector(store: canonical)
        #expect(injector.buildInjection(for: "skill876-owned", within: selected)
            .fragment?.contains("complete owned body line two") == true)
        #expect(injector.buildInjection(for: "skill876-owned", within: otherSession).fragment == nil)
        #expect(injector.buildInjection(for: "skill876-owned", within: otherProject).fragment == nil)
        #expect(injector.buildInjection(for: "skill876-owned").fragment == nil)

        let stale = try #require(settings.reviewAppSkill(for: "app:" + installed.id, in: selected).successValue)
        let replacement = document + "\nseparately approved replacement"
        _ = try canonical.importSkill(content: replacement)
        guard case .failure(.proposalChanged) = settings.approveLocalSkill(stale, currentScope: selected) else {
            Issue.record("a stale review approved replacement bytes")
            return
        }
        #expect(canonical.rawContent(installed.id) == replacement)
    }

    @Test("changed canonical body cannot be approved from an old review draft")
    func changedBodyRejectsApproval() throws {
        let root = try ownedRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = try selectedDirectory(in: root, content: document)
        let canonical = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let settings = SkillsStore(
            appStore: canonical,
            stateFileURL: root.appendingPathComponent("enabled.json")
        )
        let draft = try #require(settings.proposeLocalSkill(from: selected).successValue)
        let canonicalFile = canonical.skillDirectoryURL(for: draft.skillID).appendingPathComponent("SKILL.md")
        try document.replacingOccurrences(of: "line two", with: "altered line")
            .write(to: canonicalFile, atomically: true, encoding: .utf8)
        guard case .failure(.proposalChanged) = settings.approveLocalSkill(draft) else {
            Issue.record("changed canonical bytes were approved from a stale review")
            return
        }
        #expect(canonical.lifecycleReceipt(for: draft.skillID)?.state == .proposed)
        #expect(SkillInjector(store: canonical).buildInjection(for: "skill876-owned").fragment == nil)
    }

    @Test("project-scoped proposal is never offered by the global Settings review")
    func scopedProposalDoesNotAcquireGlobalApproval() throws {
        let root = try ownedRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let canonical = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let scope = MemoryScope(sessionID: "owned-session", projectID: "owned-project")
        let scoped = try canonical.importSkillThroughLifecycle(
            content: document,
            source: .file,
            reason: "owned scoped negative fixture",
            scope: scope,
            approval: nil
        )
        let settings = SkillsStore(
            appStore: canonical,
            stateFileURL: root.appendingPathComponent("enabled.json")
        )
        let settingsID = "app:\(scoped.skill.id)"
        #expect(!settings.hasPendingLocalSkillReview(for: settingsID))
        #expect(settings.pendingLocalSkillReview(for: settingsID) == nil)
        #expect(canonical.lifecycleReceipt(for: scoped.skill.id)?.scope == scope)
        #expect(canonical.lifecycleReceipt(for: scoped.skill.id)?.state == .proposed)
    }

    @Test("a present source manifest must match the selected local content and file provenance")
    func sidecarCannotBeIgnoredOrRelabeledAsLocalFile() throws {
        let root = try ownedRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let canonical = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let settings = SkillsStore(
            appStore: canonical,
            stateFileURL: root.appendingPathComponent("enabled.json")
        )
        let exact = SkillSourceManifest(
            skillID: "skill876-owned", source: .file,
            skillVersion: "1.0.0", content: document
        )
        let invalid: [(String, Data)] = [
            ("malformed", Data("{not-json".utf8)),
            ("schema", try JSONEncoder().encode(SkillSourceManifest(
                skillID: "skill876-owned", source: .file,
                skillVersion: "1.0.0", content: document, schema: "unknown.skill-source"
            ))),
            ("manifest-version", try JSONEncoder().encode(SkillSourceManifest(
                skillID: "skill876-owned", source: .file,
                skillVersion: "1.0.0", content: document, version: 99
            ))),
            ("id", try JSONEncoder().encode(SkillSourceManifest(
                skillID: "different-skill", source: .file,
                skillVersion: "1.0.0", content: document
            ))),
            ("version", try JSONEncoder().encode(SkillSourceManifest(
                skillID: "skill876-owned", source: .file,
                skillVersion: "9.9.9", content: document
            ))),
            ("hash", try JSONEncoder().encode(SkillSourceManifest(
                skillID: "skill876-owned", source: .file,
                skillVersion: "1.0.0", content: document + " changed"
            ))),
            ("url-source", try JSONEncoder().encode(SkillSourceManifest(
                skillID: "skill876-owned", source: .url("https://example.invalid/skill.md"),
                skillVersion: "1.0.0", content: document
            ))),
            ("bundled-source", try JSONEncoder().encode(SkillSourceManifest(
                skillID: "skill876-owned", source: .bundled,
                skillVersion: "1.0.0", content: document
            ))),
            ("session-source", try JSONEncoder().encode(SkillSourceManifest(
                skillID: "skill876-owned", source: .session,
                skillVersion: "1.0.0", content: document
            )))
        ]
        for (label, sidecar) in invalid {
            let selected = try selectedDirectory(in: root, content: document, name: label)
            try sidecar.write(to: selected.appendingPathComponent("manifest.json"))
            guard case .failure = settings.proposeLocalSkill(from: selected) else {
                Issue.record("\(label) sidecar was silently relabeled as local-file provenance")
                return
            }
            #expect(canonical.allSkills().isEmpty)
            #expect(canonical.lifecycleReceipt(for: "skill876-owned") == nil)
        }
        let selectedExact = try selectedDirectory(in: root, content: document, name: "exact-file")
        try JSONEncoder().encode(exact).write(to: selectedExact.appendingPathComponent("manifest.json"))
        let proposal = try #require(settings.proposeLocalSkill(from: selectedExact).successValue)
        #expect(canonical.lifecycleReceipt(for: proposal.skillID)?.state == .proposed)
        #expect(canonical.allSkills().first { $0.id == proposal.skillID }?.isEnabled == false)
    }

    private func ownedRoot() throws -> URL {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = formal.temporaryDirectory.appendingPathComponent("skill876-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func selectedDirectory(in root: URL, content: String, name: String = "selected") throws -> URL {
        let selected = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        try content.write(
            to: selected.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        return selected
    }
}

private extension Result {
    var successValue: Success? {
        guard case .success(let value) = self else { return nil }
        return value
    }
}
