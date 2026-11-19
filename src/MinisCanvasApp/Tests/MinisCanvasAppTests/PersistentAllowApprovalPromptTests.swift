import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("ApprovalPromptCenter persistent allow choice")
@MainActor
struct PersistentAllowApprovalPromptTests {
    private func makeRequest(id: String, offer: ApprovalPersistentAllowOffer?) -> ApprovalRequest {
        var request = ApprovalRequest(
            id: id, toolName: "shell_execute", inputSummary: "command: git status",
            riskLevel: .high, requiresApproval: true)
        request.persistentAllowOffer = offer
        return request
    }

    private let available = ApprovalPersistentAllowOffer(
        capability: "shell_execute", summary: "git status", unavailableReason: nil)
    private let unavailable = ApprovalPersistentAllowOffer(
        capability: "shell_execute", summary: "", unavailableReason: "命令含 ; & | $ ( ) ` > < 或换行，每次都需询问")

    private func present(_ center: ApprovalPromptCenter, _ request: ApprovalRequest) async -> Task<ApprovalDecision, Never> {
        let task = Task { await center.present(request) }
        for _ in 0..<100 where center.pendingRequest == nil {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return task
    }

    @Test func selectedChoiceIsCarriedOnlyByAnExplicitApprovalWithAnAvailableOffer() async {
        let center = ApprovalPromptCenter()
        let task = await present(center, makeRequest(id: "persist-yes", offer: available))
        #expect(center.persistAllowSelected == false)
        center.persistAllowSelected = true
        center.resolve(approved: true, reason: "用户允许", confirmed: true)
        let decision = await task.value
        #expect(decision.approved && decision.confirmed && decision.persistAllow)
        #expect(center.persistAllowSelected == false)
    }

    @Test func choiceIsIgnoredForDenyUnavailableOfferAndMissingOffer() async {
        let center = ApprovalPromptCenter()
        let denied = await present(center, makeRequest(id: "persist-deny", offer: available))
        center.persistAllowSelected = true
        center.resolve(approved: false, reason: "用户拒绝", confirmed: false)
        #expect(await denied.value.persistAllow == false)

        let blocked = await present(center, makeRequest(id: "persist-blocked", offer: unavailable))
        center.persistAllowSelected = true
        center.resolve(approved: true, reason: "用户允许", confirmed: true)
        #expect(await blocked.value.persistAllow == false)

        let none = await present(center, makeRequest(id: "persist-none", offer: nil))
        center.persistAllowSelected = true
        center.resolve(approved: true, reason: "用户允许", confirmed: true)
        #expect(await none.value.persistAllow == false)
    }

    @Test func choiceNeverCarriesOverToTheNextPrompt() async {
        let center = ApprovalPromptCenter()
        let first = await present(center, makeRequest(id: "persist-first", offer: available))
        center.persistAllowSelected = true
        center.resolve(approved: true, reason: "用户允许", confirmed: true)
        _ = await first.value

        let second = await present(center, makeRequest(id: "persist-second", offer: available))
        #expect(center.persistAllowSelected == false)
        center.resolve(approved: true, reason: "用户允许", confirmed: true)
        #expect(await second.value.persistAllow == false)
    }

    @Test func highRiskSecondStepKeepsTheChoiceUntilConfirmation() async {
        let center = ApprovalPromptCenter()
        var request = ApprovalRequest(
            id: "persist-l3", toolName: "shell_execute", inputSummary: "command: git status",
            riskLevel: .high, requiresApproval: true, requiresSecondConfirmation: true)
        request.persistentAllowOffer = available
        let task = await present(center, request)
        center.persistAllowSelected = true
        center.approvePending()
        #expect(center.awaitingConfirmation && center.persistAllowSelected)
        center.confirmPending()
        let decision = await task.value
        #expect(decision.approved && decision.persistAllow)
    }

    @Test func settingsListDeletesOneRuleAndClearsAll() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("persistent-allow-ui-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PersistentApprovalRuleStore(fileURL: dir.appendingPathComponent("rules.json"))
        let one = PersistentApprovalRule(
            projectKey: "k", projectRoots: ["/tmp/p"], kind: .shellCommandPrefix,
            capability: "shell_execute", pattern: "git status")
        let two = PersistentApprovalRule(
            projectKey: "k", projectRoots: ["/tmp/p"], kind: .projectDirectory,
            capability: "file_write", pattern: "/tmp/p")
        #expect(store.add(one) && store.add(two))
        #expect(PersistentApprovalRulesSettingsView.title(one) == "命令前缀 git status")
        #expect(PersistentApprovalRulesSettingsView.title(two) == "写入 /tmp/p")
        #expect(store.remove(id: one.id))
        #expect(store.allRules().map(\.id) == [two.id])
        #expect(store.removeAll())
        #expect(PersistentApprovalRuleStore(fileURL: dir.appendingPathComponent("rules.json")).allRules().isEmpty)
    }

    @Test func browserBypassRuleNeedsDedicatedRiskConfirmationControl() async throws {
        let center = ApprovalPromptCenter(), rules = BrowserInteractionRuleStore()
        let session = BrowserSession(scopeID: UUID().uuidString, userAgent: nil,
            navigationPolicy: BrowserNavigationPolicy(allowedDomains: ["one.invalid"]))
        defer { session.close() }
        try await session.loadHTMLString("<html><body><input id='secret' type='password'></body></html>",
                                        baseURL: URL(string: "https://one.invalid/synthetic")!)
        let gate = ApprovalGate()
        func request() -> ApprovalRequest {
            let base = gate.makeRequest(tool: "browser", input: ["action": "type", "selector": "#secret", "text": "synthetic"])
            var value = ApprovalRequest(id: base.id, toolName: base.toolName, inputSummary: base.inputSummary,
                riskLevel: .high, requiresApproval: true, requiresSecondConfirmation: true,
                composerMode: ComposerTaskMode.bypassPermission.rawValue,
                inputDigest: base.inputDigest, identityDigest: base.identityDigest)
            value.browserInteractionInput = base.browserInteractionInput
            return value
        }
        let first = request()
        let generic = Task { await BrowserInteractionApproval.decide(first, session: session,
            rules: rules, delegate: ApprovalPromptDelegate(center: center)) }
        for _ in 0..<100 where center.pendingRequest == nil { try await Task.sleep(for: .milliseconds(1)) }
        #expect(center.pendingRequest?.browserRiskWarning != nil)
        center.approvePending()
        center.confirmPending() // generic approve/confirm is current-call consent only
        let withoutRiskControl = await generic.value
        #expect(withoutRiskControl.approved)
        #expect(rules.rules.isEmpty)

        let second = request()
        let explicit = Task { await BrowserInteractionApproval.decide(second, session: session,
            rules: rules, delegate: ApprovalPromptDelegate(center: center)) }
        for _ in 0..<100 where center.pendingRequest == nil { try await Task.sleep(for: .milliseconds(1)) }
        center.approvePending()
        center.confirmBrowserRiskPending() // exact method wired to approval.browser-confirm-risk
        #expect(await explicit.value.approved)
        #expect(rules.rules.count == 1)
        #expect(rules.rules.first?.mode == .bypass)
    }

    // MARK: 规则管理面板

    private func panelFixture() throws -> (dir: URL, store: PersistentApprovalRuleStore, model: PermissionRulesPanelModel) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("permission-panel-\(UUID().uuidString)", isDirectory: true)
        let root = dir.appendingPathComponent("project", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = PersistentApprovalRuleStore(fileURL: dir.appendingPathComponent("rules.json"))
        let model = PermissionRulesPanelModel(store: store) {
            PermissionRulesPanelContext(facts: nil, workingDirectory: root.path, sessionID: "session-1")
        }
        return (dir, store, model)
    }

    /// MC4-013：撤销规则写盘失败时必须有提示，且规则仍在。
    @Test func panelReportsFailureWhenRemovingRuleCannotBeWritten() throws {
        let (dir, store, model) = try panelFixture()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        model.beginAdd()
        model.draftBehavior = .deny
        model.draftType = .shellPrefix
        model.draftPattern = "git push"
        model.draftScope = .project
        #expect(model.saveDraft())
        let rule = try #require(model.entries.first)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        model.remove(rule.rule.id)
        #expect(model.feedback?.contains("撤销失败") == true)
        #expect(store.allRules().count == 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        model.remove(rule.rule.id)
        #expect(model.feedback == nil)
        #expect(store.allRules().isEmpty)
    }

    @Test func panelAddsEditsDeletesAndExplainsRefusedAllowRules() throws {
        let (dir, store, model) = try panelFixture()
        defer { try? FileManager.default.removeItem(at: dir) }

        model.beginAdd()
        model.draftBehavior = .deny
        model.draftType = .shellPrefix
        model.draftPattern = "git push"
        model.draftScope = .project
        #expect(model.saveDraft())
        let denied = try #require(model.entries.first)
        #expect(denied.rule.behavior == .deny && denied.rule.origin == .manual && denied.scope == .project)

        // 不可记住的命令设为"允许"：留在表单里并给出原因，规则库不变。
        model.beginAdd()
        model.draftBehavior = .allow
        model.draftPattern = "rm"
        #expect(!model.saveDraft())
        #expect(model.isEditorPresented && model.feedback?.contains("rm") == true)
        #expect(store.allRules().count == 1)
        model.isEditorPresented = false

        // 编辑：改成"每次询问"，id 和创建时间保持。
        model.beginEdit(denied)
        #expect(model.draftPattern == "git push" && model.draftBehavior == .deny)
        model.draftBehavior = .ask
        model.draftPattern = "git push --force"
        #expect(model.saveDraft())
        let edited = try #require(model.entries.first)
        #expect(model.entries.count == 1 && edited.rule.id == denied.rule.id && edited.rule.behavior == .ask)
        #expect(edited.rule.createdAt == denied.rule.createdAt && edited.rule.pattern == "git push --force")

        // 本会话范围：只在内存，不写规则文件。
        model.beginAdd()
        model.draftBehavior = .deny
        model.draftType = .webHost
        model.draftPattern = "https://evil.example/path"
        model.draftScope = .session
        #expect(model.saveDraft())
        #expect(model.entries.contains { $0.scope == .session("session-1") && $0.rule.pattern == "evil.example" })
        #expect(store.allRules().count == 1)

        model.remove(edited.rule.id)
        #expect(model.entries.count == 1 && store.allRules().isEmpty)
    }

    @Test func panelImportListsFirstAndOnlySavesTheConfirmedRules() throws {
        let (dir, store, model) = try panelFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("project", isDirectory: true).resolvingSymlinksInPath()
        let claude = root.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        let settings = #"{"permissions":{"allow":["Bash(npm test:*)","Bash(rm:*)"],"deny":["WebFetch(domain:evil.example)"]}}"#
        try Data(settings.utf8).write(to: claude.appendingPathComponent("settings.json"))

        model.prepareImport()
        let preview = try #require(model.importPreview)
        #expect(model.isImportPresented && preview.candidates.count == 2 && preview.skipped.count == 1)
        #expect(preview.skipped.first?.original == "Bash(rm:*)")
        #expect(store.allRules().isEmpty) // 只是列出，没有生效

        let allow = try #require(preview.candidates.first { $0.draft.behavior == .allow })
        model.importSelection.remove(allow.id) // 用户取消勾选"允许"那条
        model.confirmImport()
        #expect(store.allRules().count == 1)
        let saved = try #require(store.allRules().first)
        #expect(saved.behavior == .deny && saved.origin == .imported && saved.pattern == "evil.example")
    }

}
