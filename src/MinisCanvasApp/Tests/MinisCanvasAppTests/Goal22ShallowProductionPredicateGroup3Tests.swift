import Foundation
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

/// Only the external model input is scripted. Every response token used for
/// a later call is decoded from the preceding real product tool response.
private final class Group3ProjectWireScript: @unchecked Sendable {
    private let lock = NSLock()
    private let projectName: String
    private let allowedFile: URL
    private let otherFile: URL
    private var observed = [String: String]()
    // DIAGNOSTIC only: no body, path, error description or authority is retained here.
    private var requestCount = 0
    private var sawParentMarker = false
    private var offeredProjectList = false
    private var firstResultShape: String?
    private var lastResultShape: String?
    private var receivedList = false
    private var receivedResolve = false
    var diagnosticShape: String {
        lock.withLock {
            "requests=\(requestCount) parentMarker=\(sawParentMarker) offeredList=\(offeredProjectList) list=\(receivedList) resolve=\(receivedResolve) first={\(firstResultShape ?? "UNOBSERVED")} last={\(lastResultShape ?? "UNOBSERVED")}"
        }
    }
    private var childInitialSeen = false
    var sawInitialChildRequest: Bool { lock.withLock { childInitialSeen } }
    var responses: [String: String] { lock.withLock { observed } }
    private let includesInteractiveCapsule: Bool
    init(projectName: String, allowedFile: URL, otherFile: URL, includesInteractiveCapsule: Bool) {
        self.includesInteractiveCapsule = includesInteractiveCapsule
        self.projectName = projectName
        self.allowedFile = allowedFile
        self.otherFile = otherFile
    }
    // Only HTTP bytes enter the real Factory provider; this object is not an LLMProvider.
    func respond(method: String, path: String, entity: Data) throws -> (contentType: String, body: Data) {
        lock.withLock { requestCount += 1 }
        if method == "GET", ["/models", "/v1/models"].contains(path) {
            return ("application/json", try JSONSerialization.data(withJSONObject:
                ["data": [["id": "g3-project-local", "object": "model"]]]))
        }
        guard method == "POST", ["/chat/completions", "/v1/chat/completions"].contains(path),
              let request = try JSONSerialization.jsonObject(with: entity) as? [String: Any],
              let messages = request["messages"] as? [[String: Any]] else { throw URLError(.badServerResponse) }
        let lastUser = messages.last { $0["role"] as? String == "user" }?["content"] as? String ?? ""
        let tools = request["tools"] as? [[String: Any]] ?? []
        lock.withLock {
            sawParentMarker = sawParentMarker || lastUser.contains("G3_PROJECT_PARENT_REQUEST")
            offeredProjectList = offeredProjectList || tools.contains {
                ($0["function"] as? [String: Any])?["name"] as? String == "project_list"
            }
        }
        let business = lastUser.contains("G3_PROJECT_PARENT_REQUEST") || lastUser.contains("G3_PROJECT_CHILD_INSTRUCTION")
        let message: [String: Any]
        if business {
            message = try businessReply(messages: messages, tools: tools)
        } else {
            message = ["role": "assistant", "content": "G3_OWNED_READINESS_OK"]
        }
        let finish = message["tool_calls"] == nil ? "stop" : "tool_calls"
        if request["stream"] as? Bool == true {
            var delta = message
            if let calls = message["tool_calls"] as? [[String: Any]] {
                delta["tool_calls"] = calls.enumerated().map { index, original in
                    var call = original; call["index"] = index; return call
                }
            }
            let chunk = try JSONSerialization.data(withJSONObject: ["choices": [["index": 0,
                "delta": delta, "finish_reason": finish]]])
            return ("text/event-stream", Data(("data: " + String(decoding: chunk, as: UTF8.self)
                + "\n\ndata: [DONE]\n\n").utf8))
        }
        return ("application/json", try JSONSerialization.data(withJSONObject: ["id": "g3-owned-http",
            "object": "chat.completion", "model": "g3-project-local", "choices": [["index": 0,
                "message": message, "finish_reason": finish]],
            "usage": ["prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2]]))
    }

    private func businessReply(messages: [[String: Any]], tools: [[String: Any]]) throws -> [String: Any] {
        let lastUser = messages.last { $0["role"] as? String == "user" }?["content"] as? String ?? ""
        let last = messages.last { $0["role"] as? String == "tool" }
        if let last {
            let stage: String
            switch last["tool_call_id"] as? String {
            case "g3-project-list": stage = "list"
            case "g3-project-resolve": stage = "resolve"
            case "g3-session-create": stage = "create"
            case "g3-child-read-a": stage = "childA"
            case "g3-child-read-b": stage = "childB"
            default: stage = "OTHER"
            }
            let json = try? JSONSerialization.jsonObject(with: Data((last["content"] as? String ?? "").utf8), options: [.fragmentsAllowed])
            let object = json as? [String: Any]
            let keys = object?.keys.sorted().map { key in
                key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
                    ? String(key.prefix(32)) : "NON_IDENTIFIER"
            }.joined(separator: ",") ?? "NON_OBJECT"
            let ok = (object?["ok"] as? Bool).map(String.init) ?? "absent"
            let shape = "stage=\(stage) json=\(json != nil) keys=[\(keys)] ok=\(ok)"
            lock.withLock {
                if firstResultShape == nil { firstResultShape = shape }
                lastResultShape = shape
                receivedList = receivedList || stage == "list"
                receivedResolve = receivedResolve || stage == "resolve"
            }
        }
        func call(_ name: String, _ id: String, _ input: [String: Any]) throws -> [String: Any] {
            guard tools.contains(where: { ($0["function"] as? [String: Any])?["name"] as? String == name }) else {
                throw LLMError.providerError(message: "real catalog omitted requested tool: " + name)
            }
            let data = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
            let raw = String(decoding: data, as: UTF8.self)
            return ["role": "assistant", "content": NSNull(), "tool_calls": [["id": id, "type": "function",
                "function": ["name": name, "arguments": raw]]]]
        }
        if lastUser.contains("G3_PROJECT_CHILD_INSTRUCTION") {
            switch last?["tool_call_id"] as? String {
            case "g3-child-read-a":
                lock.withLock { observed["child-a"] = last?["content"] as? String ?? "" }
                return try call("file_read", "g3-child-read-b", ["path": otherFile.path])
            case "g3-child-read-b":
                lock.withLock { observed["child-b"] = last?["content"] as? String ?? "" }
                return ["role": "assistant", "content": "G3_CHILD_FINISHED"]
            default:
                lock.withLock { childInitialSeen = true }
                return try call("file_read", "g3-child-read-a", ["path": allowedFile.path])
            }
        }
        switch last?["tool_call_id"] as? String {
        case "g3-project-list":
            let raw = last?["content"] as? String ?? ""
            let object = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
            guard let projects = object?["projects"] as? [[String: Any]],
                  let project = projects.first(where: { $0["display_name"] as? String == projectName }),
                  let id = project["project_id"] as? String,
                  let reference = project["workdir_reference"] as? String else {
                throw LLMError.providerError(message: "actual project_list did not return the owned project")
            }
            lock.withLock { observed["list"] = raw; observed["project-id"] = id; observed["reference"] = reference }
            return try call("project_resolve", "g3-project-resolve", ["input_version": 1, "project_id": id])
        case "g3-project-resolve":
            let raw = last?["content"] as? String ?? ""
            let object = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
            guard let project = object?["project"] as? [String: Any],
                  let id = project["project_id"] as? String,
                  let reference = project["workdir_reference"] as? String else {
                throw LLMError.providerError(message: "actual project_resolve did not return an opaque reference")
            }
            lock.withLock { observed["resolve"] = raw }
            var createInput: [String: Any] = ["input_version": 1,
                "project_id": id, "workdir_reference": reference, "title": "G3 owned target task",
                "initial_task": "G3_PROJECT_CHILD_INSTRUCTION", "idempotency_key": "g3-owned-create-once",
                "switch_after_create": false]
            if includesInteractiveCapsule {
                createInput["capsule_reference"] = "source-turn-reference-v1"
            }
            return try call("session_create", "g3-session-create", createInput)
        case "g3-session-create":
            lock.withLock { observed["create"] = last?["content"] as? String ?? "" }
            return ["role": "assistant", "content": "G3_PARENT_FINISHED"]
        default:
            return try call("project_list", "g3-project-list", ["input_version": 1])
        }
    }
}

/// Group 3 uses the existing product approval and maintenance consumers.
/// No native host, alternate executor, or pre-decided approval delegate.
@Suite("Goal22 shallow production predicates group 3", .serialized)
@MainActor
struct Goal22ShallowProductionPredicateGroup3Tests {
    @Test("N16 update: actual reviewed executor effect, durable prior revision and stale-hash rejection")
    func sameSkillUpdateDiffExecutesThenReopensAndRollsBackWithoutAcceptingAStaleHash() async throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = formal.temporaryDirectory.appendingPathComponent("g22-g3-update-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let skillID = "g22-g3-owned-update"
        let old = "---\nname: \(skillID)\ndescription: owned update scope\nversion: 1.0.0\n---\nG3_OLD_CONSTRAINT"
        let replacement = "---\nname: \(skillID)\ndescription: owned update scope\nversion: 2.0.0\n---\nG3_NEW_CONSTRAINT\nG3_COMPLETE_DIFF_TAIL"
        let canonical = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        _ = try canonical.importSkillThroughLifecycle(content: old, source: .file,
            reason: "owned pre-existing approved revision", approval: SkillApproval(approverID: "g3-owned-user"))
        let file = canonical.skillDirectoryURL(for: skillID).appendingPathComponent("SKILL.md")
        let before = try Data(contentsOf: file)
        #expect(before == Data(old.utf8))
        let now = Date()
        let facts = ComposerPolicyFactSource(knownCapabilities: SkillMaintenanceTool.names,
            grantedCapabilities: SkillMaintenanceTool.names, allowedWriteRoots: [root.path],
            workspaceID: "g3-update-workspace", revision: "g3-policy", grantEpoch: "g3-epoch",
            leaseID: "g3-lease", expiresAt: now.addingTimeInterval(600), autonomyCeiling: .l3)
        let snapshot = ComposerSubmissionSnapshot(mode: .manual, approvalScope: .request,
            effort: .standard, sessionID: "g3-update-session", turnID: 1, taskID: "g3-update-task",
            messageID: "g3-update-message", workspaceID: facts.workspaceID, createdAt: now,
            policyRevision: facts.revision, grantEpoch: facts.grantEpoch, autonomyCeiling: .l3)
        let prompt = ApprovalPromptCenter()
        let maintenance = SkillMaintenanceTool(store: canonical)
        let executor = ComposerPolicyEnforcedToolExecutor(
            base: BuiltinToolExecutor(allowedRoot: root, skillMaintenance: maintenance),
            controller: ComposerAuthorizationController(snapshot: snapshot, facts: facts),
            approvalGate: ApprovalGate(delegate: ApprovalPromptDelegate(center: prompt)),
            skillMaintenance: maintenance)
        let presentation = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        prompt.onPendingRequestChanged = { id, _ in
            if id != nil { presentation.continuation.yield(()) }
        }
        let pending = Task.detached { [executor, old, replacement, skillID,
                                       continuation = presentation.continuation] in
            defer { continuation.finish() }
            let input: [String: Any] = ["skillID": skillID,
                "expectedContentHash": SkillManifest.hash(old), "content": replacement]
            let authorization = try await executor.authorizeExecution(
                callID: "g3-update-call", name: "skill_update", input: input)
            _ = try await executor.execute(preauthorization: authorization,
                callID: "g3-update-call", name: "skill_update", input: input)
        }
        defer {
            prompt.dismissPending()
            pending.cancel()
            prompt.onPendingRequestChanged = nil
            presentation.continuation.finish()
        }
        do {
            var events = presentation.stream.makeAsyncIterator()
            _ = await events.next()
            guard let request = prompt.pendingRequest else {
                prompt.dismissPending()
                pending.cancel()
                _ = await pending.result
                Issue.record("the real skill update never reached the production approval consumer")
                return
            }
            #expect(request.toolName == "skill_update")
            #expect(request.skillDiff?.path == "skills/\(skillID)/SKILL.md")
            #expect(request.skillDiff?.unifiedDiff.contains("-G3_OLD_CONSTRAINT") == true)
            #expect(request.skillDiff?.unifiedDiff.contains("+G3_NEW_CONSTRAINT") == true)
            #expect(request.skillDiff?.unifiedDiff.contains("+G3_COMPLETE_DIFF_TAIL") == true)
            #expect(try Data(contentsOf: file) == before, "displaying the complete diff must not perform the update")
            prompt.approvePending()
            if request.requiresSecondConfirmation {
                try #require(prompt.awaitingConfirmation)
                #expect(try Data(contentsOf: file) == before,
                        "first approval cannot bypass the production second confirmation")
                prompt.confirmPending()
            }
            try await pending.value
        } catch {
            prompt.dismissPending()
            pending.cancel()
            _ = await pending.result
            throw error
        }
        #expect(prompt.pendingRequest == nil)
        #expect(try Data(contentsOf: file) == Data(replacement.utf8))
        let reopened = SkillStore(skillsRoot: canonical.skillsRoot)
        #expect(reopened.allSkills().filter { $0.id == skillID }.count == 1)
        #expect(reopened.rawContent(skillID) == replacement)
        #expect(reopened.canRollbackSkill(skillID))
        await #expect(throws: SkillError.importFailed(reason: "reviewed skill target changed")) {
            try await Task.detached { [executor, old, replacement, skillID] in
                let stale: [String: Any] = ["skillID": skillID,
                    "expectedContentHash": SkillManifest.hash(old), "content": replacement + "\nSTALE_MUST_NOT_WRITE"]
                let authorization = try await executor.authorizeExecution(
                    callID: "g3-stale-update-call", name: "skill_update", input: stale)
                _ = try await executor.execute(preauthorization: authorization,
                    callID: "g3-stale-update-call", name: "skill_update", input: stale)
            }.value
        }
        #expect(prompt.pendingRequest == nil)
        #expect(try Data(contentsOf: file) == Data(replacement.utf8))
        let settings = SkillsStore(appStore: reopened, stateFileURL: root.appendingPathComponent("enabled.json"))
        #expect(settings.canRollback("app:\(skillID)"))
        _ = try settings.rollback("app:\(skillID)").get()
        let afterRollback = SkillStore(skillsRoot: canonical.skillsRoot)
        #expect(afterRollback.allSkills().filter { $0.id == skillID }.count == 1)
        #expect(afterRollback.rawContent(skillID) == old)
        #expect(try Data(contentsOf: file) == before)
    }

    @Test("G22 recycle: App archive, recoverable deletion, undo and restore retain the same owned payload")
    func appRecycleAndUndoKeepArchiveSeparateAndRestoreContentGroupAndAttachment() throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = formal.temporaryDirectory.appendingPathComponent("g22-g3-trash-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "g22-g3-trash-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let badges = SessionBadgeStore(directory: root.appendingPathComponent("badges"))
        let chat = ChatStore(preferencesDefaults: defaults,
            logManager: LogManager(directory: root.appendingPathComponent("logs")))
        #expect(chat.attachPersistence(sessions, badgeStore: badges))
        let group = try #require(chat.createGroup(named: "G3 owned recoverable group"))
        let id = chat.applyNewSession(title: "G3 owned recycle target", projectID: "g3-project",
            projectName: "G3 owned project", workingDirectory: root.path, groupID: group.id)
        let attachment = ChatAttachment(kind: .text, fileName: "g3-owned.txt", fileType: .text,
            data: Data("G3_ATTACHMENT_EXACT_BYTES".utf8))
        chat.appendUser("G3_USER_PAYLOAD", attachments: [attachment])
        chat.appendAssistant("G3_ASSISTANT_PAYLOAD")
        let original = try #require(chat.sessions.first { $0.id == id })
        let canonicalMessages = try #require(sessions.loadSession(id: id.uuidString)).messages
        #expect(original.messages.map { $0.asLLMMessage() } == canonicalMessages)
        #expect(original.messages.contains { $0.role == .user && $0.attachments == [attachment] })
        let other = chat.applyNewSession(title: "G3 unrelated survivor")
        chat.appendUser("G3_OTHER_SESSION_MUST_SURVIVE")
        let unrelated = try #require(sessions.loadSession(id: other.uuidString))

        chat.archiveSession(id: id)
        #expect(!chat.sessions.contains { $0.id == id })
        #expect(chat.archivedSessions.contains { $0.id == id })
        #expect(!chat.sessionTrashEntries.contains { $0.receipt.targetID == id.uuidString })
        chat.restoreSession(id: id)
        #expect(chat.sessions.contains { $0.id == id })
        #expect(!chat.archivedSessions.contains { $0.id == id })
        let first = try chat.previewDeletion(id: id)
        #expect(first.reversible)
        let firstReceipt = try chat.deleteSession(id: id, intent: first
            .withFirstConfirmation("reviewed the owned session only")
            .withSecondConfirmation("move owned session to recoverable trash"))
        #expect(!chat.sessions.contains { $0.id == id })
        #expect(!chat.archivedSessions.contains { $0.id == id })
        #expect(chat.sessionTrashEntries.contains { $0.id == firstReceipt.operationID })
        #expect(chat.canUndoLastSessionDeletion)
        #expect(chat.undoLastSessionDeletion())
        #expect(!chat.sessionTrashEntries.contains { $0.id == firstReceipt.operationID })
        let undone = try #require(chat.sessions.first { $0.id == id })
        // Restore reconstructs UI-only UUID/time/appMessage timing. Compare the
        // complete durable message payload and all attachment references separately.
        #expect(undone.messages.map { $0.asLLMMessage() } == canonicalMessages)
        #expect(undone.messages.map(\.attachments) == original.messages.map(\.attachments))
        #expect(undone.projectID == "g3-project" && undone.groupID == group.id)

        let second = try chat.previewDeletion(id: id)
        let receipt = try chat.deleteSession(id: id, intent: second
            .withFirstConfirmation("reviewed the same restored owned target")
            .withSecondConfirmation("move owned session to recoverable trash"))
        let reopenedStore = SessionStore(directory: sessions.directory)
        let reopened = ChatStore(preferencesDefaults: defaults,
            logManager: LogManager(directory: root.appendingPathComponent("reopened-logs")))
        #expect(reopened.attachPersistence(reopenedStore, badgeStore: badges))
        #expect(!reopened.sessions.contains { $0.id == id })
        #expect(!reopened.archivedSessions.contains { $0.id == id })
        #expect(reopened.sessionTrashEntries.contains { $0.id == receipt.operationID })
        #expect(reopened.restoreTrashedSession(receipt))
        let restored = try #require(reopened.sessions.first { $0.id == id })
        #expect(restored.messages.map { $0.asLLMMessage() } == canonicalMessages)
        #expect(restored.messages.map(\.attachments) == original.messages.map(\.attachments))
        #expect(restored.projectID == "g3-project")
        #expect(restored.projectName == "G3 owned project")
        #expect(restored.workingDirectory == root.path)
        #expect(restored.groupID == group.id)
        #expect(restored.messages.first { $0.role == .user }?.attachments == [attachment])
        #expect(!reopened.archivedSessions.contains { $0.id == id })
        #expect(!reopened.sessionTrashEntries.contains { $0.id == receipt.operationID })
        #expect(reopenedStore.loadSession(id: other.uuidString) == unrelated)
    }

    @Test("G22 project task uses the default Bridge stack and the controlled human click only",
          arguments: ["allow", "deny", "revoke", "scheduled-old-auto", "scheduled-old-auto-manual", "scheduled-old-risk", "scheduled-fresh", "scheduled-revoke-at-native-confirm"])
    func realBridgeProjectListResolveCreateRetainsParentAndRootAuthority(humanChoice: String) async throws {
        _ = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "g3-project-" + humanChoice,
            canvasRuntimeState: .disabled)
        try B1ARCHOriginalFixtureSupport.qualifyProfile(profile)
        let defaults = profile.makeUserDefaults()
        let suite = try #require(profile.userDefaultsSuiteName)
        let usage = UsageStore(domain: .suite(suite), storageKey: "g3-project-" + UUID().uuidString)
        try #require(await usage.waitForPersistence())
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let sessions = SessionStore(directory: profile.sessionDirectory)
        let badges = SessionBadgeStore(directory: profile.minisCanvasDirectory)
        let memory = MemoryStore(directory: profile.memoryDirectory)
        let skills = SkillStore(skillsRoot: profile.minisCoreDirectory.appendingPathComponent("skills"))
        let shortcuts = ShortcutStore(defaults: defaults)
        let tasks = try AgentTaskStore(persistenceURL: profile.minisCanvasDirectory.appendingPathComponent("project-tasks.json"))
        let manifests = try ContextManifestStore(persistenceURL: profile.minisCanvasDirectory.appendingPathComponent("project-context.json"))
        let isScheduled = humanChoice.hasPrefix("scheduled-")
        let scheduledManual = humanChoice == "scheduled-old-auto-manual"
        let migratedAuto = humanChoice == "scheduled-old-auto" || scheduledManual
            || humanChoice == "scheduled-revoke-at-native-confirm"
        if migratedAuto || humanChoice == "scheduled-old-risk" {
            try FileManager.default.createDirectory(at: profile.settingsDirectory, withIntermediateDirectories: true)
            let rawPolicy = migratedAuto ? "autoApprove" : "riskOnlyAsk"
            try JSONSerialization.data(withJSONObject: ["agent": ["approvalPolicy": rawPolicy]])
                .write(to: profile.settingsDirectory.appendingPathComponent(SettingsStore.fileName))
        }
        let center = SettingsCenter(settingsStore: SettingsStore(directory: profile.settingsDirectory),
            envStore: EnvVarStore(directory: profile.providerConfigurationDirectory, keychain: keychain,
                privacyStore: EnvVarPrivacyStore(defaults: defaults)),
            memoryStore: memory, memoryFileStore: MemoryFileStore(directory: profile.memoryDirectory),
            sessionStore: sessions, sessionBadgeStore: badges, logManager: profile.makeLogManager(),
            mcpManager: MCPServerManager(fileURL: profile.mcpConfigurationURL, keychain: keychain),
            skillStore: skills, usageStore: usage, shortcutStore: shortcuts,
            providerReadinessTransport: ControlledLoopbackProviderReadinessTransport(),
            providerReadinessStore: ProviderReadinessStore(directory: profile.providerConfigurationDirectory))
        if isScheduled {
            var defaults = center.policyRuntimeDefaults
            defaults.autonomyLevel = .l3
            try #require(center.updatePolicyRuntimeDefaults(defaults))
            var savedMode = center.composerPolicy
            savedMode.mode = scheduledManual ? .manual : .auto
            center.composerPolicy = savedMode
            let reopened = SettingsStore(directory: profile.settingsDirectory).settings.agent
            try #require(reopened.composerPolicy.mode == savedMode.mode)
            try #require(reopened.policyRuntimeDefaults.autonomyLevel == .l3)
        }
        let settingsSkills = SkillsStore(appStore: skills, stateFileURL: profile.skillStateURL, loadImmediately: false)
        let scheduler = SchedulerTaskStore(defaults: defaults,
            occurrenceLedgerURL: profile.minisCanvasDirectory.appendingPathComponent("project-schedule.json"))
        let bridge = BridgeStore(shortcutStore: shortcuts, preferencesDefaults: defaults,
            settingsCatalogSkillsStore: settingsSkills, settingsCatalogSchedulerStore: scheduler,
            logManager: center.logManager,
            workflowStore: WorkflowStore(storeDirectory: profile.minisCanvasDirectory.appendingPathComponent("Workflows")),
            sessionBadgeStore: badges, sessionDocumentStore: SessionDocumentStore(directory: sessions.directory),
            sessionStore: sessions, canvasRuntimeState: .disabled, agentTaskStore: tasks,
            contextManifestStore: manifests, memoryStore: memory,
            memoryProposalConsumer: center.memoryProposalConsumer, commandEnvStore: center.envStore,
            canonicalMCPManager: center.mcpManager, providerReadinessStore: center.providerReadinessStore,
            taskCenterBindingPersistenceURL: profile.minisCanvasDirectory.appendingPathComponent("project-task-bindings.json"),
            canvasFeatureLane: .phase3NonCanvas)
        // The registered formal root has the original no-symlink authority.
        // Foundation's temporary-directory spelling can retain a /var alias,
        // which the real trusted-instruction reader correctly refuses to follow.
        let formalProfile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let projectsRoot = formalProfile.rootDirectory.appendingPathComponent("g3-native-projects-" + UUID().uuidString,
            isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer {
            // Setup failures precede dispatch; body failures still take the
            // original cancel/join path below before this fallback can run.
            do {
                if FileManager.default.fileExists(atPath: projectsRoot.path) {
                    try FileManager.default.removeItem(at: projectsRoot)
                }
            } catch { Issue.record("Owned canonical projects fixture cleanup failed") }
        }
        let projectA = projectsRoot.appendingPathComponent("g3-project-a", isDirectory: true)
        let projectB = projectsRoot.appendingPathComponent("g3-project-b", isDirectory: true)
        try FileManager.default.createDirectory(at: projectA, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: projectB, withIntermediateDirectories: false)
        let fileA = projectA.appendingPathComponent("owned.txt")
        let fileB = projectB.appendingPathComponent("other.txt")
        try Data("G3_ALLOWED_PROJECT_BYTES".utf8).write(to: fileA)
        try Data("G3_OTHER_PROJECT_MUST_NOT_LEAK".utf8).write(to: fileB)
        let provider = Group3ProjectWireScript(projectName: projectA.lastPathComponent,
            allowedFile: fileA, otherFile: fileB, includesInteractiveCapsule: !isScheduled)
        let wire = try ComposerWire3090(reply: "", maxRequests: 8, responseScript: { method, path, entity in
            try provider.respond(method: method, path: path, entity: entity)
        })
        defer { wire.stop() }
        let providerID = "G3_PROJECT_OWNED_API_KEY"
        var humanRequests: [ProjectSessionCreateRequest] = []
        var humanPreviews: [String] = []
        var humanError: String?
        var approvedReadRequests: [ApprovalRequest] = []
        var deniedReadRequests: [ApprovalRequest] = []
        let expectedReadA = ComposerToolInput(values: ["path": .string(fileA.path)]).digest
        let expectedReadB = ComposerToolInput(values: ["path": .string(fileB.path)]).digest
        var scheduledRuntime: SchedulerTaskRuntime?
        let body: Result<Void, Error>
        do {
            try #require(ProductionPickerCatalogWiring.bind(chat: bridge.chat, center: center, profile: profile))
            // Same live configured-directory input as MinisCanvasApp's composition root.
            bridge.chat.providerRecordsSource = { center.providerRecords }
            bridge.chat.schedulerCredentialVersionSource = { providerID in
                guard let record = center.providerRecords.first(where: {
                    $0.name.caseInsensitiveCompare(providerID) == .orderedSame
                }) else { return nil }
                return center.providerCredentialBinding(recordID: record.id)?.revision
            }
            center.onApprovalPolicyChanged = { [weak bridge, weak center] policy in
                bridge?.updateApprovalPolicy(policy, legacyAutomaticCompatibility:
                    center?.legacyAutomaticApprovalCompatibilityActive == true)
            }
            await bridge.attachProductionServices(agentSettings: isScheduled ? center.settings.agent : .default,
                fileAccessAllowedRoot: projectsRoot,
                sessionDirectory: sessions.directory, mcpManager: center.mcpManager, skillStore: skills,
                projectSessionApproval: { [weak bridge] request, preview in
                    humanRequests.append(request)
                    humanPreviews.append(preview)
                    if humanChoice == "scheduled-revoke-at-native-confirm" {
                        center.disableLegacyAutomaticApprovalCompatibility()
                    }
                    if humanChoice == "revoke" {
                        do {
                            guard let handler = bridge?.productionProjectSessionHandler else {
                                humanError = "real project handler disappeared"; return false
                            }
                            try handler.revokeProject(id: request.project.projectID)
                        } catch { humanError = String(describing: error); return false }
                    }
                    return humanChoice != "deny"
                }, policyDefaults: center.policyRuntimeDefaults, canvasRuntimeState: .disabled, externalRunners: [:], externalNetworkAllowed: false,
                controlledFieldLoopbackAllowed: true, sessionReadSecretStore: center.envStore).value
            if isScheduled { bridge.chat.restoreComposerPolicy(center.composerPolicy) }
            #expect(!bridge.productionExternalNetworkAllowed)
            #expect(bridge.productionControlledFieldLoopbackAllowed)
            let handler = try #require(bridge.productionProjectSessionHandler)
            let projectID = try handler.authorizeFolderFromNativePicker(projectA)
            let otherProjectID = try handler.authorizeFolderFromNativePicker(projectB)
            #expect(projectID != otherProjectID)
            let sourceID = bridge.chat.applyNewSession(title: "G3 owned real parent",
                projectID: isScheduled ? projectID : nil,
                workingDirectory: isScheduled ? projectA.path : nil)
            try #require(center.saveProvider(name: providerID, credential: .replace("g3-owned-nonsecret-input"),
                baseURL: "http://127.0.0.1:\(wire.port)", modelNames: ["g3-project-local"],
                protocolType: .openaiCompatible))
            let checked = try #require(await center.checkProviderModelReadiness(forProviderName: providerID,
                modelID: "g3-project-local"))
            try #require(checked.status == .passed)
            // The real async probe resolved only the injected memory backing.
            // Publish its normal in-memory record so Factory never falls back to a global lookup.
            center.reloadEnv()
            let savedRecord = try #require(center.providerRecords.first { $0.name == providerID })
            try #require(!savedRecord.value.isEmpty)
            try #require(bridge.chat.applyChatModel(providerID: providerID, modelID: "g3-project-local"))
            #expect(bridge.chat.selectedModelID == "g3-project-local")
            let concrete = try #require(try bridge.chat.activeProvider() as? OpenAICompatibleProvider)
            #expect(concrete.name == providerID)
            #expect(concrete.controlledFieldLoopbackOnly)
            #expect(concrete.customBaseURL == "http://127.0.0.1:\(wire.port)")
            #expect(bridge.chat.streamingProviderOverride == nil)
            let baselineIDs = Set(bridge.chat.sessions.map(\.id))
            bridge.chat.appendUser("G3_HISTORY_NOT_FOR_TARGET")
            if isScheduled {
                let runtime = ProductionDomainAssembly.makeSchedulerRuntime(
                    store: scheduler, bridge: bridge, settings: center)
                scheduledRuntime = runtime
                let now = Date()
                let revision = try #require(bridge.chat.schedulerPolicyRevision())
                let anchor = try #require(bridge.chat.schedulerSourceAnchorDigest(
                    sessionID: sourceID, projectID: projectID, ordinal: 1))
                try #require(scheduler.add(name: "owned compatibility run", cronExpression: "* * * * *",
                    command: "G3_PROJECT_PARENT_REQUEST", targetSessionID: sourceID,
                    targetProjectID: projectID, targetTurnID: 1) == nil)
                let scheduledID = try #require(scheduler.allTasks().first?.id)
                var preview = try #require(scheduler.preview(taskID: scheduledID, now: now))
                preview.observedSourceAnchorDigest = anchor
                preview.observedPolicyRevision = revision
                try #require(scheduler.confirmPreview(preview, actorID: "owned fixture user",
                    scopeID: projectID, policyRevision: revision, now: now,
                    sourceAnchorConfirmed: true, currentSourceAnchorDigest: anchor,
                    currentPolicyRevision: revision))
                runtime.pollNow(at: now)
                var sawCreateCard = false
                let deadline = ContinuousClock.now.advanced(by: .seconds(10))
                repeat {
                    if let request = bridge.approvalCenter.pendingRequest {
                        let target = request.sessionID.flatMap { sessions.loadSession(id: $0) }
                        let isBoundReadA = request.toolName == "file_read"
                            && request.callID == "g3-child-read-a"
                            && request.inputDigest == expectedReadA
                            && target?.taskSourceSessionID == sourceID.uuidString
                            && target?.projectID == projectID
                            && target?.createdByTaskID == request.taskID
                            && target?.workingDirectory == projectA.resolvingSymlinksInPath().path
                        let isBoundProjectCall = request.sessionID == sourceID.uuidString
                            && ProjectSessionToolContract.toolNames.contains(request.toolName)
                        if isBoundProjectCall || isBoundReadA {
                            if request.toolName == ProjectSessionToolContract.sessionCreate { sawCreateCard = true }
                            bridge.approvalCenter.approvePending()
                            if request.requiresSecondConfirmation { bridge.approvalCenter.confirmPending() }
                        } else {
                            bridge.approvalCenter.resolve(approved: false, reason: "用户拒绝", confirmed: false,
                                requestID: request.requestID)
                        }
                    }
                    if scheduler.latestOccurrence(for: scheduledID)?.state.isTerminal == true,
                       !bridge.chat.isStreaming { break }
                    try await Task.sleep(for: .milliseconds(10))
                } while ContinuousClock.now < deadline
                #expect(provider.diagnosticShape.contains("parentMarker=true"))
                if provider.responses["create"] == nil {
                    let occurrence = scheduler.latestOccurrence(for: scheduledID)
                    print("G3_SCHEDULED_SHAPE state=\(String(describing: occurrence?.state)) nativeConfirm=\(!humanRequests.isEmpty) createCard=\(sawCreateCard) \(provider.diagnosticShape)")
                }
                if humanChoice == "scheduled-revoke-at-native-confirm" {
                    try #require(scheduler.latestOccurrence(for: scheduledID)?.state.isTerminal == true)
                    #expect(humanRequests.count == 1)
                    #expect(!SettingsStore(directory: profile.settingsDirectory)
                        .settings.agent.legacyAutomaticApprovalCompatibilityActive)
                    let revokedOccurrence = try #require(scheduler.latestOccurrence(for: scheduledID))
                    #expect(bridge.chat.scheduledTargetDelivery(for: revokedOccurrence) == nil)
                    #expect(bridge.chat.messages.compactMap(\.sessionReferenceCard).isEmpty)
                    #expect(!sawCreateCard)
                    #expect(Set(bridge.chat.sessions.map(\.id)) == baselineIDs)
                    #expect(provider.responses["child-a"] == nil)
                    #expect(try Data(contentsOf: fileA) == Data("G3_ALLOWED_PROJECT_BYTES".utf8))
                } else {
                    try #require(scheduler.latestOccurrence(for: scheduledID)?.state == .succeeded)
                    let creation = try #require(provider.responses["create"])
                    let data = Data(creation.utf8)
                    let decoded = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                    let resultShape = creation.hasPrefix("Error executing tool session_create: ")
                        ? "agent_loop_session_create_error" : "other_non_object"
                    let result = try #require(decoded, Comment(rawValue: resultShape))
                    let delivered = try #require(scheduler.latestOccurrence(for: scheduledID))
                    #expect(bridge.chat.scheduledTargetDelivery(for: delivered) != nil)
                    let sourceCardID = try #require(result["source_backlink_id"] as? String)
                    #expect(bridge.chat.hasSourceCard(sourceCardID, sourceID: sourceID.uuidString))
                    #expect(result["status"] as? String == "committed")
                    #expect(sawCreateCard == (humanChoice != "scheduled-old-auto"))
                    #expect(humanRequests.count == 1)
                    #expect(center.legacyAutomaticApprovalCompatibilityActive == migratedAuto)
                    let targetID = try #require(result["target_session_id"] as? String)
                    let created = try #require(sessions.loadSession(id: targetID))
                    #expect(created.taskSourceSessionID == sourceID.uuidString)
                    #expect(created.projectID == projectID)
                    #expect(provider.responses["child-a"]?.contains("G3_ALLOWED_PROJECT_BYTES") == true)
                    #expect(provider.responses["child-b"]?.contains("G3_OTHER_PROJECT_MUST_NOT_LEAK") == false)
                    #expect(try Data(contentsOf: fileB) == Data("G3_OTHER_PROJECT_MUST_NOT_LEAK".utf8))
                    let interactive = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
                    #expect(interactive.loop.approvalGate?.policy(for: ProjectSessionToolContract.sessionCreate) == .alwaysAsk)
                }
            } else {
                let material = PastedTextDraft(id: UUID(), text: "G3_CAPSULE_ONLY_OWNED_MATERIAL",
                    source: .pasteboard, kind: .reference)
                try #require(bridge.chat.setPastedTextDraft(material))
                bridge.chat.draftText = "G3_PROJECT_PARENT_REQUEST"
                bridge.chat.submitComposer()
                let submittedExecution = bridge.chat.activeExecutionIdentity(for: sourceID)
                let originalSourceFacts = bridge.chat.composerPolicyFacts
                var sawFileReadApproval = false
                var sawAID = false
                var sawADigest = false
                var sawBoundReadTarget = false
                var sawProjectToolApproval = false
                var sawOtherApproval = false
                let deadline = ContinuousClock.now.advanced(by: .seconds(10))
                repeat {
                    if let request = bridge.approvalCenter.pendingRequest {
                        // This is the actual policy prompt, not a delegate that
                        // invents its receipt or skips capability/root validation.
                        if request.toolName == "file_read" {
                            let matchesA = request.callID == "g3-child-read-a" && request.inputDigest == expectedReadA
                            let matchesB = request.callID == "g3-child-read-b" && request.inputDigest == expectedReadB
                            let target = request.sessionID.flatMap { sessions.loadSession(id: $0) }
                            let boundTarget = target?.taskSourceSessionID == sourceID.uuidString
                                && target?.projectID == projectID && target?.createdByTaskID == request.taskID
                                && target?.workingDirectory == projectA.resolvingSymlinksInPath().path
                            sawFileReadApproval = true
                            sawAID = sawAID || request.callID == "g3-child-read-a"
                            sawADigest = sawADigest || request.inputDigest == expectedReadA
                            sawBoundReadTarget = sawBoundReadTarget || boundTarget
                            #expect((matchesA || matchesB) && boundTarget)
                            if let taskID = request.taskID,
                               let policy = bridge.taskCenterControlConsumer.topLevelTaskGoalLease(taskID: taskID) {
                                #expect(policy.goal.scopeID == projectID && policy.lease.scopeID == projectID)
                                #expect(PolicyRuntimePathBoundary.isWithinRoots(path: fileA.path, roots: policy.goal.fileRoots))
                                #expect(!PolicyRuntimePathBoundary.isWithinRoots(path: fileB.path, roots: policy.goal.fileRoots))
                                #expect(request.grantEpoch == "composer-epoch:\(policy.goal.goalID.uuidString)")
                            } else { Issue.record("Target read lacks its actual task Goal/lease") }
                            if matchesA && boundTarget {
                                approvedReadRequests.append(request)
                                bridge.approvalCenter.approvePending()
                                if request.requiresSecondConfirmation { bridge.approvalCenter.confirmPending() }
                            } else {
                                if matchesB && boundTarget { deniedReadRequests.append(request) }
                                // This is a real user refusal, not a forged path
                                // violation string or an injected approval receipt.
                                bridge.approvalCenter.resolve(approved: false, reason: "用户拒绝", confirmed: false,
                                    requestID: request.requestID)
                            }
                            if (matchesA || matchesB) && boundTarget {
                                print("G22_PROJECT_READ_AUTH call=\(request.callID) request=\(request.requestID) inputDigest=\(request.inputDigest ?? "none") targetBound=\(boundTarget) matchesA=\(matchesA) matchesB=\(matchesB) allowed=\(matchesA)")
                            }
                        } else if ["project_list", "project_resolve", "session_create"].contains(request.toolName) {
                            sawProjectToolApproval = true
                            bridge.approvalCenter.approvePending()
                            if request.requiresSecondConfirmation { bridge.approvalCenter.confirmPending() }
                        } else {
                            sawOtherApproval = true
                            Issue.record("Unexpected tool requested a project fixture approval")
                            bridge.approvalCenter.resolve(approved: false, reason: "用户拒绝", confirmed: false,
                                requestID: request.requestID)
                        }
                    }
                    try await Task.sleep(for: .milliseconds(10))
                } while (bridge.chat.isStreaming || bridge.chat.isActiveSessionGenerating) && ContinuousClock.now < deadline
                if bridge.chat.isStreaming || bridge.chat.isActiveSessionGenerating {
                    let approvedA = approvedReadRequests.first
                    let resumedA = approvedA.map { request in
                        bridge.composerApprovalReceipts.contains { $0.callID == request.callID && $0.requestID == request.requestID }
                    } ?? false
                    let terminalA = approvedA.map { request in
                        bridge.chat.conversationEvents.contains {
                            $0.kind == .tool && $0.toolCallID == request.callID
                                && $0.identity.sessionID == request.sessionID && $0.status.isTerminal
                        }
                    } ?? false
                    let results = provider.responses
                    let createStatus: String
                    if let create = results["create"] {
                        let object = (try? JSONSerialization.jsonObject(with: Data(create.utf8))) as? [String: Any]
                        createStatus = object?["status"] as? String == "committed" ? "committed" : "other"
                    } else {
                        createStatus = "unseen"
                    }
                    print("G22_PROJECT_TIMEOUT stage=deadline requestCount=\(wire.requests.count) listSeen=\(results["list"] != nil) resolveSeen=\(results["resolve"] != nil) createStatus=\(createStatus) childInitialSeen=\(provider.sawInitialChildRequest) fileReadSeen=\(sawFileReadApproval) aIDSeen=\(sawAID) aDigestSeen=\(sawADigest) boundReadTargetSeen=\(sawBoundReadTarget) projectApprovalSeen=\(sawProjectToolApproval) otherApprovalSeen=\(sawOtherApproval) matchedASubmitted=\(approvedA != nil) matchedAReceipt=\(resumedA) matchedAToolTerminal=\(terminalA) aResultAtProvider=\(results["child-a"] != nil) bResultAtProvider=\(results["child-b"] != nil)")
                }
                try #require(!bridge.chat.isStreaming && !bridge.chat.isActiveSessionGenerating,
                             "owned parent/target production turns did not terminate")
                let actual = provider.responses
                #expect(wire.captureFailure == nil)
                #expect(wire.requests.count <= 8)
                let diagnostic = Comment(rawValue: String("sourceSID=\(sourceID.uuidString) turn=\(submittedExecution.map { String($0.turn.turnID) } ?? "UNOBSERVED") \(provider.diagnosticShape)".prefix(320)))
                #expect(actual["project-id"] == projectID, diagnostic)
                let opaque = try #require(actual["reference"], diagnostic)
                #expect(!opaque.contains(projectA.path))
                #expect(!opaque.hasPrefix("/"))
                #expect(actual["list"] != nil && actual["resolve"] != nil && actual["create"] != nil)
                #expect(humanRequests.count == 1 && humanPreviews.count == 1)
                #expect(humanRequests.first?.source.identity.sessionID == sourceID.uuidString)
                #expect(humanRequests.first?.source.identity.conversationID == sourceID.uuidString)
                #expect(humanRequests.first?.project.projectID == projectID)
                #expect(humanPreviews.first?.contains("G3_PROJECT_CHILD_INSTRUCTION") == true)
                #expect(humanPreviews.first?.contains("G3_CAPSULE_ONLY_OWNED_MATERIAL") == true)
                #expect(humanError == nil)
                let targets = bridge.chat.sessions.filter { $0.taskSourceSessionID == sourceID.uuidString }
                if humanChoice == "allow" {
                    let output = try #require(actual["create"])
                    let json = try #require(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
                    #expect(json["status"] as? String == "committed")
                    let targetID = try #require(json["target_session_id"] as? String)
                    let runID = try #require(json["run_id"] as? String)
                    let cardID = try #require(json["source_backlink_id"] as? String)
                    let target = try #require(sessions.loadSession(id: targetID))
                    #expect(targets.count == 1 && targets.first?.id.uuidString == targetID)
                    #expect(target.taskSourceSessionID == sourceID.uuidString)
                    #expect(target.messages.first?.content.contains("G3_CAPSULE_ONLY_OWNED_MATERIAL") == true)
                    #expect(target.messages.first?.content.contains("G3_HISTORY_NOT_FOR_TARGET") == false)
                    #expect(target.projectID == projectID && target.projectID != otherProjectID)
                    #expect(target.workingDirectory == projectA.resolvingSymlinksInPath().path)
                    let taskID = try #require(json["task_id"] as? String)
                    #expect(target.createdByRunID == runID && target.createdByTaskID == taskID)
                    #expect(bridge.chat.hasSourceCard(cardID, sourceID: sourceID.uuidString))
                    #expect(actual["child-a"]?.contains("G3_ALLOWED_PROJECT_BYTES") == true,
                        Comment(rawValue: String("targetFailure=\(UUID(uuidString: targetID).flatMap { bridge.chat.executionSnapshot(forSessionID: $0)?.failureReason } ?? "UNOBSERVED") wireRequests=\(wire.requests.count) \(provider.diagnosticShape)".prefix(320))))
                    #expect(actual["child-b"] == "Error executing tool file_read: 用户拒绝",
                        Comment(rawValue: String("targetFailure=\(UUID(uuidString: targetID).flatMap { bridge.chat.executionSnapshot(forSessionID: $0)?.failureReason } ?? "UNOBSERVED") wireRequests=\(wire.requests.count) \(provider.diagnosticShape)".prefix(320))))
                    #expect(actual["child-b"]?.contains("G3_OTHER_PROJECT_MUST_NOT_LEAK") == false)
                    #expect(approvedReadRequests.count == 1 && deniedReadRequests.count == 1)
                    let approvedA = try #require(approvedReadRequests.first)
                    let deniedB = try #require(deniedReadRequests.first)
                    let receiptA = try #require(bridge.composerApprovalReceipts.first {
                        $0.callID == approvedA.callID && $0.requestID == approvedA.requestID
                            && $0.inputDigest == expectedReadA && $0.sessionID == targetID && $0.taskID == taskID
                    })
                    #expect(receiptA.persistentRuleID == nil)
                    let hasBReceipt = bridge.composerApprovalReceipts.contains {
                        $0.callID == deniedB.callID && $0.requestID == deniedB.requestID
                    }
                    #expect(!hasBReceipt)
                    let decisionB = try #require(bridge.chat.conversationEvents.first {
                        $0.approvalCompositeKey?.toolCallID == deniedB.callID
                            && $0.approvalIdentityDigest == deniedB.identityDigest
                            && $0.receiptID == deniedB.requestID && $0.approvalDecision == .denied
                    })
                    #expect(decisionB.identity.sessionID == targetID && decisionB.identity.taskID == taskID)
                    #expect(bridge.chat.composerPolicyFacts.allowedWriteRoots == originalSourceFacts.allowedWriteRoots)
                    #expect(bridge.chat.composerPolicyFacts.grantEpoch == originalSourceFacts.grantEpoch)
                    print("G22_PROJECT_READ_AUTH stage=settled aFreshReceipt=true aReceiptDigest=\(receiptA.receiptDigest) bDecisionDenied=\(decisionB.approvalDecision == .denied) bApprovalReceipt=\(hasBReceipt)")
                    #expect(Set(bridge.chat.sessions.map(\.id)).subtracting(baselineIDs).count == 1)
                } else {
                    #expect(targets.isEmpty)
                    #expect(Set(bridge.chat.sessions.map(\.id)) == baselineIDs)
                    #expect(!bridge.chat.messages.contains { $0.sessionReferenceCard != nil })
                    #expect(actual["child-a"] == nil && actual["child-b"] == nil)
                }
                #expect(try Data(contentsOf: fileB) == Data("G3_OTHER_PROJECT_MUST_NOT_LEAK".utf8))
            }
            body = .success(())
        } catch { body = .failure(error) }
        bridge.approvalCenter.dismissPending()
        await scheduledRuntime?.stopAndJoin()
        let ownedTasks = bridge.chat.cancelStreamingForApplicationExit()
        for task in ownedTasks { await task.value }
        try #require(await usage.waitForPersistence())
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: projectsRoot)
        try FileManager.default.removeItem(at: profile.rootDirectory)
        try body.get()
    }
}
