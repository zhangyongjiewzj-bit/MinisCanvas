import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

/// Field defect: a skill activated through the ordinary user path (global
/// receipt, scope == nil) that the user selects with @name in a project
/// session is silently not injected. Product design (SKILL876, SkillsStore
/// approveLocalSkill doc comment) keeps "project-bound injection requires
/// exact scope", so the contract pinned here is: exact-scope review injects,
/// everything else stays out, and a rejected explicit selection must leave a
/// visible trace instead of vanishing.
/// Real SkillStore on a real on-disk root, real SkillInjector, real
/// ChatTurnPromptPreprocessor.prepare; nothing under test is mocked.
@Suite("Project scope global skill injection", .serialized)
@MainActor
struct ProjectScopeGlobalSkillInjectionTests {
    private let alphaID = "g22-skill-alpha"
    private let betaID = "g22-skill-beta"
    private let alphaBody = "ALPHA_BODY_SENTINEL_7f3a91"
    private let betaBody = "BETA_BODY_SENTINEL_c20e54"
    private let project = MemoryScope(sessionID: "project-ext-session", projectID: "project-ext")
    private let otherProject = MemoryScope(sessionID: "other-session", projectID: "other-project")

    private func document(name: String, description: String, body: String) -> String {
        "---\nname: \(name)\ndescription: \(description)\nversion: 1.0.0\n---\n\(body)\n"
    }
    private var alphaDoc: String { document(name: alphaID, description: "zebra palette helper", body: alphaBody) }
    private var betaDoc: String { document(name: betaID, description: "quartz ledger tool", body: betaBody) }

    private func ownedRoot() throws -> URL {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = formal.temporaryDirectory
            .appendingPathComponent("project-scope-global-skill-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func prepare(store: SkillStore, scope: MemoryScope?) throws -> ChatTurnPromptPreprocessResult {
        let injector = SkillInjector(store: store)
        let picker = PickerCatalogItem(
            id: "skill:\(alphaID)", kind: .skill, name: alphaID, detail: "zebra palette helper")
        let input = ChatTurnPromptPreprocessInput(
            basePrompt: "BASE_PROMPT", userMessage: "@\(alphaID) 请处理",
            memoryEnabled: false, memoryInjector: nil, memoryScope: scope,
            skillInjector: injector, legacySkillResult: .init(fragment: nil, receipts: []),
            pickerCatalog: [picker], steers: [], intentText: "@\(alphaID) 请处理")
        return try #require(ChatTurnPromptPreprocessor.prepare(input))
    }

    /// The field state: user import path => global active receipt.
    private func importGlobalActive(_ store: SkillStore, _ content: String, id: String) throws {
        try store.importSkill(content: content)
        let receipt = try #require(store.lifecycleReceipt(for: id))
        #expect(receipt.state == .active && receipt.action == .activate)
        #expect(receipt.scope == nil)
        #expect(receipt.approvedBy?.isEmpty == false)
        #expect(store.allSkills().first { $0.id == id }?.isEnabled == true)
    }

    @Test("explicitly approved global skill injects only when selected in a project")
    func globalActiveSelectionInProjectScopeHasVisibleReason() throws {
        let root = try ownedRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        try importGlobalActive(store, alphaDoc, id: alphaID)
        try importGlobalActive(store, betaDoc, id: betaID)

        let result = try prepare(store: store, scope: project)
        #expect(result.systemPrompt.contains(alphaBody))
        #expect(!result.systemPrompt.contains(betaBody))
        #expect(result.systemPrompt.contains("<injected_skills>"))
        let receipts = result.skillReceipts.filter { $0.skillID == alphaID }
        #expect(receipts.count == 1 && receipts.first?.state == .active && receipts.first?.omittedReason == nil)
    }

    @Test("exact-scope review injects only the selected body")
    func exactScopeReviewInjectsOnlySelected() throws {
        let root = try ownedRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        try importGlobalActive(store, betaDoc, id: betaID)
        _ = try store.importSkillThroughLifecycle(
            content: alphaDoc, source: .file, reason: "exact scope review", scope: project,
            approval: SkillApproval(approverID: "g22-reviewer", scope: project))

        let result = try prepare(store: store, scope: project)
        #expect(result.systemPrompt.contains("<injected_skills>"))
        #expect(result.systemPrompt.contains(alphaBody))
        #expect(!result.systemPrompt.contains(betaBody))
    }

    @Test("disabled, unapproved and other-project receipts never inject")
    func negativeCasesStayOut() throws {
        let root = try ownedRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // disabled global skill, selected with no scope as well as in project
        let disabled = SkillStore(skillsRoot: root.appendingPathComponent("disabled"))
        try importGlobalActive(disabled, alphaDoc, id: alphaID)
        #expect(disabled.setEnabled(alphaID, enabled: false))
        for scope in [nil, project] as [MemoryScope?] {
            let r = try prepare(store: disabled, scope: scope)
            #expect(!r.systemPrompt.contains(alphaBody) && !r.systemPrompt.contains("<injected_skills>"))
        }

        // proposal only: no approvedBy, not active
        let proposed = SkillStore(skillsRoot: root.appendingPathComponent("proposed"))
        _ = try proposed.importSkillThroughLifecycle(
            content: alphaDoc, source: .file, reason: "proposal only", scope: nil, approval: nil)
        let receipt = try #require(proposed.lifecycleReceipt(for: alphaID))
        #expect(receipt.state == .proposed && receipt.approvedBy == nil)
        for scope in [nil, project] as [MemoryScope?] {
            let r = try prepare(store: proposed, scope: scope)
            #expect(!r.systemPrompt.contains(alphaBody) && !r.systemPrompt.contains("<injected_skills>"))
        }

        // receipt bound to a different project
        let foreign = SkillStore(skillsRoot: root.appendingPathComponent("foreign"))
        _ = try foreign.importSkillThroughLifecycle(
            content: alphaDoc, source: .file, reason: "other project review", scope: otherProject,
            approval: SkillApproval(approverID: "g22-reviewer", scope: otherProject))
        let r = try prepare(store: foreign, scope: project)
        #expect(!r.systemPrompt.contains(alphaBody) && !r.systemPrompt.contains("<injected_skills>"))
    }
}
