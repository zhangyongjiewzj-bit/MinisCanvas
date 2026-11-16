import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

// 第二批线 Q：对话里管理会话（RED）。只做现有界面（侧栏菜单/回收站/导出）已有的动作。
// 依据：审计 26 号第一、五节（第五节 1/3/4/6/7 项）与 25 号；对齐 Claude Code 宿主 set_session_title /
// set_pinned / set_unread / archive / unarchive / delete_session / export_transcript / list_sessions。
//
// ===================== 接口约定（修复作者照此实现）=====================
// A. 复用 conversation_settings 的类型化键（不另造工具），一次 apply 只允许 1 个键（同 mcp.* 口径）。
//    expectedRevision = settings_catalog 新增的顶层字段 `sessionRevision`（只覆盖会话元数据——标题/置顶/
//    未读/归档/分组/项目/回收站状态——不含 updatedAt 与消息，否则一个对话回合就会让它过期）。
//    “当前会话” = 发起该工具调用的会话（回执里的 sessionID）。
//   session.current.title    text      → ChatStore.applyRenameSession（空白标题拒绝，原值不变）
//   session.current.pinned   toggle    → ChatStore.setPinned
//   session.current.unread   toggle    → ChatStore.setUnread
//   session.current.archived toggle    → 拒绝（总控裁定：不对当前会话做归档，不新增回合结束钩子）；
//                                        回执原因：不能在当前会话内归档自身，请在侧栏操作
//   session.current.group    text      → 组名；已存在 → ChatStore.moveSession；不存在 → createGroup(named:)
//                                        后再移入（对应侧栏“新建组”）；"" → moveSession(toGroup:nil)“不分组”
//   session.current.project  object   → {name:text, working_directory:text}；与侧栏“归入项目”同一校验
//                                        SessionSidebarPresentation.projectDirectory，目录不存在则拒绝；
//                                        name 为空 = 解除归属（ChatStore.setProject）。只关联，不授予文件访问
//   session.<uuid>.archived  toggle    → 非当前会话：false=从归档恢复（restoreSession 的语义，但**不得切走
//                                        当前活动会话**）；true=归档该活动会话
//   session.<uuid>.trashed   toggle    → true=移入回收站（previewCurrentDeletion→deleteSession/
//                                        deleteArchivedSession，可逆）；false=从回收站恢复（
//                                        restoreTrashedSession 的语义，但**不得切走当前活动会话**）。
//                                        目标是当前会话时拒绝（对齐 CC delete_session 不可对自身）。
//                                        不提供永久删除。
//   所有写入都走现有设置审批卡（BL6SettingsToolApproval.toolName）：依据 26 号第五节“写入一律沿用
//   conversation_settings 的审批卡 + 回执 + undoReceipt”，目录里没有“某些键免卡”的机制，且 CC 的
//   delete_session 在任何权限模式（含 bypass）都出卡——所以移入回收站在 bypass / 范围同意下也必须再弹。
//   settings_catalog 读取（无卡）新增 values/entries：session.current.id（只读）、.title、.pinned、.unread、
//   .archived、.group、.project，agentMutable=true（id 除外）。
// B. session_read 新增 scope（工具 schema 的 scope 枚举加 "list"/"export"，session_id 对这两个 scope 非必填）：
//   scope=list  可带 query（只匹配标题/项目名/组名等元数据子串，绝不搜消息正文）；输出 JSON
//               {"sessions":[{session_id, title, updated_at(ISO8601), state:"active"|"archived"|"trashed",
//                 current:Bool, pinned:Bool, unread:Bool, project_name:String?, group:String?}]}，
//               只含元数据，不含任何会话正文；回收站项 state=trashed（session_id=被删会话 ID，供恢复用）。
//               沿用 session_read 每次一张审批卡（26 号第五节第 3 项：与线 L 一致，避免第二套规则）。
//   scope=export 返回**当前会话**的 Markdown，文本与侧栏导出同源（SessionMarkdownExport.markdown，同一
//               ChatTranscriptRedactor 脱敏，不含工具摘要）；不落盘（落盘走 file_write 的授权目录与卡）。
//               同样每次一张 session_read 卡。读正文（scope=messages）仍走线 L 的原有审批卡，不在此改。

private actor Batch2QApproval: ApprovalDelegate {
    private(set) var requests: [ApprovalRequest] = []
    private let denied: Set<String>

    init(denying denied: Set<String> = []) { self.denied = denied }

    var settingsRequests: [ApprovalRequest] {
        requests.filter { $0.toolName == BL6SettingsToolApproval.toolName }
    }
    var sessionReadRequests: [ApprovalRequest] {
        requests.filter { $0.toolName == SessionReadTool.toolName }
    }

    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        requests.append(request)
        let allowed = !denied.contains(request.toolName)
        return ApprovalDecision(
            approved: allowed, confirmed: allowed,
            requestID: request.requestID, bindingDigest: request.identityDigest
        )
    }
}

private final class Batch2QProvider:
    LLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable
{
    let name = "batch2q-offline"
    var model = LLMModel(id: "batch2q-model", displayName: "Batch2Q", provider: "batch2q-offline")
    let capabilities: Set<ProviderCapability> = [.tools]
    var runtimeConfigurationMaterial: String? = "batch2q-isolated"
    private let lock = NSLock()
    private var requests: [[LLMMessage]] = []
    private let callName: String
    private let callInput: [String: Any]
    private let callID: String

    init(name: String, input: [String: Any], callID: String) {
        callName = name
        callInput = input
        self.callID = callID
    }

    var returnedToolMessage: String? {
        lock.withLock {
            requests.dropFirst().flatMap { $0 }
                .first(where: { $0.role == .tool && $0.toolCallID == callID })?.content
        }
    }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt, tools: [],
                              maxTokens: maxTokens, temperature: temperature)
    }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        let count = lock.withLock { requests.append(messages); return requests.count }
        if count == 1 {
            let data = try JSONSerialization.data(withJSONObject: callInput, options: [.sortedKeys])
            let call = LLMToolCall(
                id: callID, name: callName,
                rawArguments: String(decoding: data, as: UTF8.self), arguments: callInput
            )
            return LLMResponse(text: "", stopReason: "tool_calls", usage: nil, toolCalls: [call])
        }
        return LLMResponse(text: "已处理。", stopReason: "stop", usage: nil)
    }

    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct Batch2QSeeds {
    let pinned: UUID      // 置顶、正文 bodyPinned
    let archived: UUID    // 已归档、归属项目
    let plain: UUID       // 普通活动会话
    let current: UUID     // 发起工具调用的当前会话
}

@Suite("Batch2Q conversation session management", .serialized)
@MainActor
struct Batch2Q_ConversationSessionManagementTests {
    private static let bodyPinned = "BATCH2Q_BODY_PINNED_SECRET_TEXT"
    private static let bodyArchived = "BATCH2Q_BODY_ARCHIVED_SECRET_TEXT"
    private static let bodyPlain = "BATCH2Q_BODY_PLAIN_SECRET_TEXT"
    private static let bodyCurrent = "BATCH2Q_BODY_CURRENT_EXPORT_TEXT /Users/someone/.ssh/id_rsa"
    private static let allBodies = [bodyPinned, bodyArchived, bodyPlain]

    private func makeFixture() throws -> (SettingsCenter, BridgeStore, URL) {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("batch2q-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let badges = SessionBadgeStore(directory: root.appendingPathComponent("badges"))
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let readiness = ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        let now = Date()
        try #require(readiness.upsert([
            ProviderReadinessPersistenceRecord(
                providerID: "batch2q-offline", modelID: "batch2q-model",
                status: .passed, readinessState: .mock, checkedAt: now,
                evidenceID: "batch2q-synthetic-readiness", isApplied: true,
                discoveryReceiptID: "batch2q-synthetic-discovery", discoveredAt: now,
                applyReceiptID: "provider-readiness-apply:batch2q-synthetic",
                appliedAt: now
            )
        ]))
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("providers"), keychain: keychain),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            sessionStore: sessions, sessionBadgeStore: badges,
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            mcpManager: MCPServerManager(
                fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain
            ),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite("batch2q-\(UUID().uuidString)")),
            providerReadinessStore: readiness
        )
        let defaults = try #require(UserDefaults(suiteName: "batch2q-\(UUID().uuidString)"))
        let skills = SkillsStore(
            appStore: center.skillStore,
            stateFileURL: root.appendingPathComponent("skill-state.json")
        )
        let scheduler = SchedulerTaskStore(
            defaults: defaults,
            occurrenceLedgerURL: root.appendingPathComponent("scheduler-occurrences.json")
        )
        let bridge = try BridgeStore(
            taskStorePersistenceURL: root.appendingPathComponent("agent-tasks.json"),
            shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            settingsCatalogSkillsStore: skills,
            settingsCatalogSchedulerStore: scheduler,
            logManager: LogManager(directory: root.appendingPathComponent("bridge-logs")),
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("workflows")),
            sessionBadgeStore: badges,
            sessionDocumentStore: SessionDocumentStore(directory: sessions.directory),
            sessionStore: sessions, memoryStore: center.memoryStore,
            providerReadinessStore: readiness,
            canvasFeatureLane: .phase3NonCanvas
        )
        bridge.bindProductionEffectiveSettingsSource { [weak center] in
            center?.bl6EffectiveSettingsSnapshot
        }
        return (center, bridge, root)
    }

    /// 装配生产组合并种下 4 个会话；最后切回 `current`，它就是模型调用工具时的“当前会话”。
    private func attachAndSeed(
        _ bridge: BridgeStore, _ center: SettingsCenter, _ root: URL,
        approval: Batch2QApproval,
        mode: ComposerTaskMode = .manual,
        scope: ComposerApprovalScope = .request,
        bypassConfirmed: Bool = false
    ) async -> Batch2QSeeds {
        await bridge.attachProductionServices(
            fileAccessAllowedRoot: root, sessionDirectory: center.sessionStore.directory,
            approvalDelegateOverride: approval,
            policyDefaults: batch2BypassPolicyDefaults(mode), externalNetworkAllowed: true,
            sessionReadSecretStore: center.envStore
        ).value
        // 会话归入项目后目录读取要核对记忆作用域；与生产装配一致，由 SettingsCenter 提供同一作用域。
        center.memoryScopeProvider = { [weak chat = bridge.chat] in chat?.activeMemoryScope }
        bridge.chat.composerPolicySelection = ComposerPolicySelection(
            mode: mode, approvalScope: scope,
            effort: .standard, bypassModeConfirmed: bypassConfirmed
        )
        let chat = bridge.chat
        let pinned = chat.applyNewSession(title: "Q置顶会话")
        chat.appendUser(Self.bodyPinned)
        chat.setPinned(true, sessionID: pinned)
        let archived = chat.applyNewSession(
            title: "Q归档会话", projectID: "q-proj", projectName: "Q项目", workingDirectory: root.path)
        chat.appendUser(Self.bodyArchived)
        chat.archiveSession(id: archived)
        let plain = chat.applyNewSession(title: "Q普通会话")
        chat.appendUser(Self.bodyPlain)
        let current = chat.applyNewSession(title: "Q当前会话")
        chat.appendUser(Self.bodyCurrent)
        return Batch2QSeeds(pinned: pinned, archived: archived, plain: plain, current: current)
    }

    private func run(_ bridge: BridgeStore, tool: String, input: [String: Any],
                     callID: String) async throws -> Batch2QProvider {
        let provider = Batch2QProvider(name: tool, input: input, callID: callID)
        bridge.chat.streamingProviderOverride = provider
        bridge.chat.draftText = "批次2Q 合成请求。"
        bridge.chat.submitComposer()
        try await Task.sleep(for: .milliseconds(100))
        let deadline = Date().addingTimeInterval(20)
        while bridge.chat.isStreaming && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(!bridge.chat.isStreaming)
        return provider
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        return condition()
    }

    private func catalog(_ bridge: BridgeStore, callID: String) async throws -> [String: Any] {
        let read = try await run(bridge, tool: BL6SettingsToolApproval.catalogToolName,
                                 input: [:], callID: callID)
        let body = try #require(read.returnedToolMessage)
        return try #require(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
    }

    private func sessionRevision(_ bridge: BridgeStore, callID: String) async throws -> String {
        let body = try await catalog(bridge, callID: callID)
        return try #require(body["sessionRevision"] as? String)
    }

    private func text(_ value: String) -> [String: Any] { ["kind": "text", "text": value] }
    private func toggle(_ value: Bool) -> [String: Any] { ["kind": "toggle", "toggle": value] }

    private func change(_ bridge: BridgeStore, key: String, value: [String: Any],
                        callID: String) async throws -> Batch2QProvider {
        let revision = try await sessionRevision(bridge, callID: callID + "-rev")
        return try await run(bridge, tool: BL6SettingsToolApproval.toolName, input: [
            "operation": "apply", "expectedRevision": revision, "changes": [key: value]
        ], callID: callID)
    }

    private func failed(_ provider: Batch2QProvider) -> Bool {
        provider.returnedToolMessage?.contains("Error executing tool") == true
    }

    private func receipt(_ provider: Batch2QProvider) throws -> BL6SettingsReceipt {
        let body = try #require(provider.returnedToolMessage)
        return try JSONDecoder().decode(BL6SettingsReceipt.self, from: Data(body.utf8))
    }

    private func thread(_ chat: ChatStore, _ id: UUID) -> ChatThread? {
        chat.sessions.first { $0.id == id } ?? chat.archivedSessions.first { $0.id == id }
    }

    private func trash(_ chat: ChatStore, _ id: UUID) throws -> DeletionReceipt {
        let preview = try chat.previewCurrentDeletion(id: id)
        let confirmed = preview.intent
            .withFirstConfirmation("已核对这份预览").withSecondConfirmation("移入回收站")
        return preview.archived
            ? try chat.deleteArchivedSession(id: id, intent: confirmed)
            : try chat.deleteSession(id: id, intent: confirmed)
    }

    // MARK: 0 目录

    @Test("catalog exposes the current-session keys as mutable, and sessionRevision survives an ordinary turn")
    func catalogExposesCurrentSessionKeys() async throws {
        let (center, bridge, root) = try makeFixture()
        defer { bridge.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: root) }
        let approval = Batch2QApproval()
        let seeds = await attachAndSeed(bridge, center, root, approval: approval)

        let first = try await catalog(bridge, callID: "b2q-cat-1")
        let revision = try #require(first["sessionRevision"] as? String)
        #expect(!revision.isEmpty)
        let values = try #require(first["values"] as? [String: Any])
        func decoded(_ key: String) throws -> BL6SettingValue {
            let raw = try #require(values[key], "目录缺少 \(key)")
            return try JSONDecoder().decode(
                BL6SettingValue.self,
                from: JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed]))
        }
        #expect(try decoded("session.current.id") == .text(seeds.current.uuidString))
        #expect(try decoded("session.current.title") == .text("Q当前会话"))
        #expect(try decoded("session.current.pinned") == .toggle(false))
        #expect(try decoded("session.current.unread") == .toggle(false))
        #expect(try decoded("session.current.archived") == .toggle(false))
        let entries = try #require(first["entries"] as? [[String: Any]])
        for key in ["session.current.title", "session.current.pinned", "session.current.unread",
                    "session.current.archived", "session.current.group", "session.current.project"] {
            let entry = try #require(entries.first { $0["id"] as? String == key }, "entries 缺少 \(key)")
            #expect(entry["agentMutable"] as? Bool == true, "\(key) 应可写")
        }
        let idEntry = try #require(entries.first { $0["id"] as? String == "session.current.id" })
        #expect(idEntry["agentMutable"] as? Bool == false)

        // 上一回合改变了消息与 updatedAt，但元数据没变：修订号必须不变，否则读完目录再写永远过期。
        let second = try await catalog(bridge, callID: "b2q-cat-2")
        #expect(second["sessionRevision"] as? String == revision)
    }

    // MARK: 1 当前会话元数据

    @Test("rename: card shows the new title, allow renames like the sidebar; deny changes nothing")
    func renameCurrentSession() async throws {
        let (center, bridge, root) = try makeFixture()
        defer { bridge.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: root) }
        let approval = Batch2QApproval()
        let seeds = await attachAndSeed(bridge, center, root, approval: approval)

        let provider = try await change(bridge, key: "session.current.title",
                                        value: text("Q新标题"), callID: "b2q-rename")
        let asked = await approval.settingsRequests
        #expect(asked.count == 1)
        #expect(asked.first?.inputSummary.contains("Q新标题") == true)
        #expect(thread(bridge.chat, seeds.current)?.title == "Q新标题")
        #expect(!failed(provider))
        let issued = try receipt(provider)
        #expect(issued.changedKeys == ["session.current.title"])
        #expect(issued.rollbackValues["session.current.title"] == .text("Q当前会话"))
        // 其它会话不受影响
        #expect(thread(bridge.chat, seeds.plain)?.title == "Q普通会话")
    }

    @Test("denied rename and blank title leave the title untouched")
    func renameDeniedOrBlankKeepsTitle() async throws {
        let (center, bridge, root) = try makeFixture()
        defer { bridge.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: root) }
        let approval = Batch2QApproval(denying: [BL6SettingsToolApproval.toolName])
        let seeds = await attachAndSeed(bridge, center, root, approval: approval)

        let denied = try await change(bridge, key: "session.current.title",
                                      value: text("Q不该生效"), callID: "b2q-rename-deny")
        #expect(await approval.settingsRequests.count == 1)
        #expect(thread(bridge.chat, seeds.current)?.title == "Q当前会话")
        #expect(failed(denied))

        let allowed = Batch2QApproval()
        let (center2, bridge2, root2) = try makeFixture()
        defer { bridge2.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: root2) }
        let seeds2 = await attachAndSeed(bridge2, center2, root2, approval: allowed)
        let blank = try await change(bridge2, key: "session.current.title",
                                     value: text("   "), callID: "b2q-rename-blank")
        #expect(thread(bridge2.chat, seeds2.current)?.title == "Q当前会话")
        #expect(failed(blank), "空白标题与侧栏重命名一致：拒绝")
    }

    @Test("pin / unpin the current session like the sidebar menu", arguments: [true, false])
    func pinCurrentSession(_ target: Bool) async throws {
        let (center, bridge, root) = try makeFixture()
        defer { bridge.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: root) }
        let approval = Batch2QApproval()
        let seeds = await attachAndSeed(bridge, center, root, approval: approval)
        if !target { bridge.chat.setPinned(true, sessionID: seeds.current) }

        let provider = try await change(bridge, key: "session.current.pinned",
                                        value: toggle(target), callID: "b2q-pin-\(target)")
        #expect(await approval.settingsRequests.count == 1)
        #expect(thread(bridge.chat, seeds.current)?.pinned == target)
        #expect(!failed(provider))
        #expect(try receipt(provider).rollbackValues["session.current.pinned"] == .toggle(!target))
    }

    @Test("mark the current session unread / read like the sidebar menu", arguments: [true, false])
    func unreadCurrentSession(_ target: Bool) async throws {
        let (center, bridge, root) = try makeFixture()
        defer { bridge.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: root) }
        let approval = Batch2QApproval()
        let seeds = await attachAndSeed(bridge, center, root, approval: approval)
        if !target { bridge.chat.setUnread(true, sessionID: seeds.current) }

        _ = try await change(bridge, key: "session.current.unread",
                             value: toggle(target), callID: "b2q-unread-\(target)")
        #expect(await approval.settingsRequests.count == 1)
        #expect(thread(bridge.chat, seeds.current)?.unread == target)
    }

    @Test("archiving the current session is refused (no turn-end hook): state unchanged, the reason names the sidebar")
    func archiveCurrentSessionRefused() async throws {
        let (center, bridge, root) = try makeFixture()
        defer { bridge.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: root) }
        let approval = Batch2QApproval()
        let seeds = await attachAndSeed(bridge, center, root, approval: approval)

        let provider = try await change(bridge, key: "session.current.archived",
                                        value: toggle(true), callID: "b2q-archive-self")
        #expect(await approval.settingsRequests.count == 1)
        #expect(failed(provider))
        #expect(provider.returnedToolMessage?.contains("不能在当前会话内归档自身，请在侧栏操作") == true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(bridge.chat.sessions.contains { $0.id == seeds.current })
        #expect(!bridge.chat.archivedSessions.contains { $0.id == seeds.current })
        #expect(bridge.chat.activeSessionID == seeds.current)
    }

    @Test("denied archive of the current session keeps it active")
    func deniedArchiveCurrentKeepsActive() async throws {
        let (center, bridge, root) = try makeFixture()
        defer { bridge.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: root) }
        let approval = Batch2QApproval(denying: [BL6SettingsToolApproval.toolName])
        let seeds = await attachAndSeed(bridge, center, root, approval: approval)

        _ = try await change(bridge, key: "session.current.archived",
                             value: toggle(true), callID: "b2q-archive-self-deny")
        try await Task.sleep(for: .milliseconds(300))
        #expect(await approval.settingsRequests.count == 1)
        #expect(bridge.chat.sessions.contains { $0.id == seeds.current })
        #expect(bridge.chat.activeSessionID == seeds.current)
        #expect(bridge.chat.archivedSessions.contains { $0.id == seeds.current } == false)
    }

    // MARK: 2 归档恢复（其它会话）

    @Test("unarchive another session: it returns to the active list, the current session stays active")
    func unarchiveOtherSession() async throws {
        let (center, bridge, root) = try makeFixture()
        defer { bridge.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: root) }
        let approval = Batch2QApproval()
        let seeds = await attachAndSeed(bridge, center, root, approval: approval)
        #expect(bridge.chat.archivedSessions.contains { $0.id == seeds.archived })

        let provider = try await change(
            bridge, key: "session.\(seeds.archived.uuidString).archived",
            value: toggle(false), callID: "b2q-unarchive")
        #expect(await approval.settingsRequests.count == 1)
        #expect(!failed(provider))
        #expect(bridge.chat.sessions.contains { $0.id == seeds.archived })
        #expect(!bridge.chat.archivedSessions.contains { $0.id == seeds.archived })
        // 界面上的“恢复”会切换到被恢复的会话；对话里恢复不得把正在对话的会话切走。
        #expect(bridge.chat.activeSessionID == seeds.current)
    }

    @Test("archive another active session; deny leaves it active")
    func archiveOtherSession() async throws {
        let (center, bridge, root) = try makeFixture()
        defer { bridge.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: root) }
        let approval = Batch2QApproval()
        let seeds = await attachAndSeed(bridge, center, root, approval: approval)

        _ = try await change(bridge, key: "session.\(seeds.plain.uuidString).archived",
                             value: toggle(true), callID: "b2q-archive-other")
        #expect(bridge.chat.archivedSessions.contains { $0.id == seeds.plain })
        #expect(!bridge.chat.sessions.contains { $0.id == seeds.plain })
        #expect(bridge.chat.activeSessionID == seeds.current)

        let (center2, bridge2, root2) = try makeFixture()
        defer { bridge2.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: root2) }
        let denying = Batch2QApproval(denying: [BL6SettingsToolApproval.toolName])
        let seeds2 = await attachAndSeed(bridge2, center2, root2, approval: denying)
        _ = try await change(bridge2, key: "session.\(seeds2.plain.uuidString).archived",
                             value: toggle(true), callID: "b2q-archive-other-deny")
        #expect(bridge2.chat.sessions.contains { $0.id == seeds2.plain })
        #expect(await denying.settingsRequests.count == 1)
    }

    // MARK: 3 回收站

    @Test("move another session to the trash: card names it and says it is recoverable; allow matches the sidebar Delete")
    func trashOtherSession() async throws {
        let (center, bridge, root) = try makeFixture()
        defer { bridge.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: root) }
        let approval = Batch2QApproval()
        let seeds = await attachAndSeed(bridge, center, root, approval: approval)

        let provider = try await change(
            bridge, key: "session.\(seeds.plain.uuidString).trashed",
            value: toggle(true), callID: "b2q-trash")
        let asked = await approval.settingsRequests
        #expect(asked.count == 1)
        let summary = try #require(asked.first?.inputSummary)
        #expect(summary.contains("Q普通会话"))
        #expect(summary.contains("回收站"))
        #expect(!failed(provider))
        #expect(!bridge.chat.sessions.contains { $0.id == seeds.plain })
        #expect(bridge.chat.sessionTrashEntries.contains { $0.receipt.targetID == seeds.plain.uuidString })
        #expect(bridge.chat.activeSessionID == seeds.current)
    }

    @Test("an archived session can also be moved to the trash")
    func trashArchivedSession() async throws {
        let (center, bridge, root) = try makeFixture()
        defer { bridge.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: root) }
        let approval = Batch2QApproval()
        let seeds = await attachAndSeed(bridge, center, root, approval: approval)

        _ = try await change(bridge, key: "session.\(seeds.archived.uuidString).trashed",
                             value: toggle(true), callID: "b2q-trash-archived")
        #expect(!bridge.chat.archivedSessions.contains { $0.id == seeds.archived })
        #expect(bridge.chat.sessionTrashEntries.contains { $0.receipt.targetID == seeds.archived.uuidString })
    }

    @Test("the current session can never be moved to the trash (CC delete_session refuses self)")
    func trashCurrentSessionRefused() async throws {
        let (center, bridge, root) = try makeFixture()
        defer { bridge.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: root) }
        let approval = Batch2QApproval()
        let seeds = await attachAndSeed(bridge, center, root, approval: approval)
        let trashBefore = bridge.chat.sessionTrashEntries.count

        let provider = try await change(
            bridge, key: "session.\(seeds.current.uuidString).trashed",
            value: toggle(true), callID: "b2q-trash-self")
        #expect(failed(provider))
        #expect(bridge.chat.sessions.contains { $0.id == seeds.current })
        #expect(bridge.chat.activeSessionID == seeds.current)
        #expect(bridge.chat.sessionTrashEntries.count == trashBefore)
    }

    @Test("manual refusal leaves the session active and trash untouched")
    func trashAlwaysAsksEvenInBypass() async throws {
        let (center, bridge, root) = try makeFixture()
        defer { bridge.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: root) }
        let approval = Batch2QApproval(denying: [BL6SettingsToolApproval.toolName])
        let seeds = await attachAndSeed(bridge, center, root, approval: approval,
                                        mode: .manual, bypassConfirmed: false)

        let provider = try await change(
            bridge, key: "session.\(seeds.plain.uuidString).trashed",
            value: toggle(true), callID: "b2q-trash-refusal")
        #expect(await approval.settingsRequests.count == 1)
        #expect(failed(provider))
        #expect(bridge.chat.sessions.contains { $0.id == seeds.plain })
        #expect(bridge.chat.sessionTrashEntries.isEmpty)
    }

    @Test("confirmed bypass moves a session to recoverable trash without a card")
    func confirmedBypassMovesSessionToRecoverableTrash() async throws {
        let (center, bridge, root) = try makeFixture()
        defer { bridge.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: root) }
        let approval = Batch2QApproval(denying: [BL6SettingsToolApproval.toolName])
        let seeds = await attachAndSeed(bridge, center, root, approval: approval,
                                        mode: .bypassPermission, bypassConfirmed: true)
        let key = "session.\(seeds.plain.uuidString).trashed"
        let provider = try await change(bridge, key: key, value: toggle(true), callID: "b2q-trash-bypass")
        #expect(await approval.settingsRequests.isEmpty)
        #expect(try receipt(provider).changedKeys == [key])
        #expect(!bridge.chat.sessions.contains { $0.id == seeds.plain })
        #expect(bridge.chat.sessionTrashEntries.contains { $0.receipt.targetID == seeds.plain.uuidString })
        #expect(bridge.chat.activeSessionID == seeds.current)
    }

    @Test("a session/workspace consent earned by an ordinary change never covers moving a session to the trash",
          arguments: [ComposerApprovalScope.session, .workspace])
    func scopedConsentCannotCoverTrash(_ scope: ComposerApprovalScope) async throws {
        let (center, bridge, root) = try makeFixture()
        defer { bridge.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: root) }
        let approval = Batch2QApproval()
        let seeds = await attachAndSeed(bridge, center, root, approval: approval, scope: scope)

        _ = try await change(bridge, key: "session.current.pinned",
                             value: toggle(true), callID: "b2q-scope-pin")
        #expect(await approval.settingsRequests.count == 1)
        _ = try await change(bridge, key: "session.\(seeds.plain.uuidString).trashed",
                             value: toggle(true), callID: "b2q-scope-trash")
        let asked = await approval.settingsRequests
        #expect(asked.count == 2, "移入回收站必须再弹一张卡")
        #expect(asked.last?.inputSummary.contains("回收站") == true)
    }

    @Test("restore a session from the trash: it comes back, the current session stays active")
    func restoreFromTrash() async throws {
        let (center, bridge, root) = try makeFixture()
        defer { bridge.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: root) }
        let approval = Batch2QApproval()
        let seeds = await attachAndSeed(bridge, center, root, approval: approval)
        _ = try trash(bridge.chat, seeds.plain)
        #expect(!bridge.chat.sessions.contains { $0.id == seeds.plain })

        let provider = try await change(
            bridge, key: "session.\(seeds.plain.uuidString).trashed",
            value: toggle(false), callID: "b2q-restore")
        #expect(await approval.settingsRequests.count == 1)
        #expect(!failed(provider))
        #expect(bridge.chat.sessions.contains { $0.id == seeds.plain })
        #expect(!bridge.chat.sessionTrashEntries.contains { $0.receipt.targetID == seeds.plain.uuidString })
        // 侧栏“恢复”会 switchSession 到被恢复的会话；对话里恢复不得切走当前会话。
        #expect(bridge.chat.activeSessionID == seeds.current)
    }

    // MARK: 4 分组与项目

    @Test("move the current session into an existing group, then back to no group")
    func moveToExistingGroupAndBack() async throws {
        let (center, bridge, root) = try makeFixture()
        defer { bridge.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: root) }
        let approval = Batch2QApproval()
        let seeds = await attachAndSeed(bridge, center, root, approval: approval)
        let group = try #require(bridge.chat.createGroup(named: "Q分组"))

        _ = try await change(bridge, key: "session.current.group",
                             value: text("Q分组"), callID: "b2q-group")
        #expect(thread(bridge.chat, seeds.current)?.groupID == group.id)
        #expect(bridge.chat.groups.count == 1, "已有组：不得重复新建")

        _ = try await change(bridge, key: "session.current.group",
                             value: text(""), callID: "b2q-ungroup")
        #expect(thread(bridge.chat, seeds.current)?.groupID == nil)
        #expect(await approval.settingsRequests.count == 2)
    }

    @Test("an unknown group name creates the group (sidebar New Group) and moves the session in")
    func unknownGroupNameCreatesGroup() async throws {
        let (center, bridge, root) = try makeFixture()
        defer { bridge.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: root) }
        let approval = Batch2QApproval()
        let seeds = await attachAndSeed(bridge, center, root, approval: approval)
        #expect(bridge.chat.groups.isEmpty)

        _ = try await change(bridge, key: "session.current.group",
                             value: text("Q新建组"), callID: "b2q-group-new")
        let group = try #require(bridge.chat.groups.first { $0.name == "Q新建组" })
        #expect(thread(bridge.chat, seeds.current)?.groupID == group.id)
    }

    @Test("denied group change moves nothing and creates no group")
    func deniedGroupChange() async throws {
        let (center, bridge, root) = try makeFixture()
        defer { bridge.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: root) }
        let approval = Batch2QApproval(denying: [BL6SettingsToolApproval.toolName])
        let seeds = await attachAndSeed(bridge, center, root, approval: approval)

        _ = try await change(bridge, key: "session.current.group",
                             value: text("Q不该创建"), callID: "b2q-group-deny")
        #expect(bridge.chat.groups.isEmpty)
        #expect(thread(bridge.chat, seeds.current)?.groupID == nil)
        #expect(await approval.settingsRequests.count == 1)
    }

    @Test("assign the current session to a project with an existing directory, like the sidebar; clearing the name unassigns")
    func assignAndClearProject() async throws {
        let (center, bridge, root) = try makeFixture()
        defer { bridge.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: root) }
        let approval = Batch2QApproval()
        let seeds = await attachAndSeed(bridge, center, root, approval: approval)
        let expectedDirectory = try #require(SessionSidebarPresentation.projectDirectory(root.path)).path

        let project: [String: Any] = ["kind": "object", "object": [
            "name": text("Q项目甲"), "working_directory": text(root.path)
        ]]
        _ = try await change(bridge, key: "session.current.project",
                             value: project, callID: "b2q-project")
        let assigned = try #require(thread(bridge.chat, seeds.current))
        #expect(assigned.projectID == ChatStore.projectID(for: "Q项目甲"))
        #expect(assigned.projectName == "Q项目甲")
        #expect(assigned.workingDirectory == expectedDirectory)

        let cleared: [String: Any] = ["kind": "object", "object": [
            "name": text(""), "working_directory": text("")
        ]]
        _ = try await change(bridge, key: "session.current.project",
                             value: cleared, callID: "b2q-project-clear")
        let after = try #require(thread(bridge.chat, seeds.current))
        #expect(after.projectID == nil)
        #expect(after.projectName == nil)
        #expect(after.workingDirectory == nil)
    }

    @Test("a non-existent working directory is rejected and the project assignment stays as it was")
    func invalidProjectDirectoryRejected() async throws {
        let (center, bridge, root) = try makeFixture()
        defer { bridge.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: root) }
        let approval = Batch2QApproval()
        let seeds = await attachAndSeed(bridge, center, root, approval: approval)

        let project: [String: Any] = ["kind": "object", "object": [
            "name": text("Q坏目录"), "working_directory": text(root.path + "/no-such-directory")
        ]]
        let provider = try await change(bridge, key: "session.current.project",
                                        value: project, callID: "b2q-project-bad")
        #expect(failed(provider))
        let session = try #require(thread(bridge.chat, seeds.current))
        #expect(session.projectName == nil)
        #expect(session.workingDirectory == nil)
    }

    // MARK: 5 会话列表（session_read scope=list）

    private func listedSessions(_ provider: Batch2QProvider) throws -> [[String: Any]] {
        let body = try #require(provider.returnedToolMessage)
        let object = try #require(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        return try #require(object["sessions"] as? [[String: Any]])
    }

    @Test("scope=list returns metadata for active, archived and trashed sessions and never any message body")
    func listReturnsMetadataOnly() async throws {
        let (center, bridge, root) = try makeFixture()
        defer { bridge.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: root) }
        let approval = Batch2QApproval()
        let seeds = await attachAndSeed(bridge, center, root, approval: approval)
        let trashed = bridge.chat.applyNewSession(title: "Q回收站会话")
        bridge.chat.appendUser("BATCH2Q_BODY_TRASHED_SECRET_TEXT")
        _ = try trash(bridge.chat, trashed)
        #expect(bridge.chat.applySwitchSession(id: seeds.current))

        let provider = try await run(bridge, tool: SessionReadTool.toolName,
                                     input: ["scope": "list"], callID: "b2q-list")
        let cards = await approval.sessionReadRequests
        #expect(cards.count == 1, "list 沿用 session_read 每次一张卡")
        #expect(cards.first?.inputSummary.contains("scope: list") == true)

        let body = try #require(provider.returnedToolMessage)
        for secret in Self.allBodies + ["BATCH2Q_BODY_TRASHED_SECRET_TEXT", "BATCH2Q_BODY_CURRENT_EXPORT_TEXT"] {
            #expect(!body.contains(secret), "list 不得带出正文：\(secret)")
        }
        let rows = try listedSessions(provider)
        func row(_ id: UUID) -> [String: Any]? { rows.first { $0["session_id"] as? String == id.uuidString } }
        let pinnedRow = try #require(row(seeds.pinned))
        #expect(pinnedRow["title"] as? String == "Q置顶会话")
        #expect(pinnedRow["state"] as? String == "active")
        #expect(pinnedRow["pinned"] as? Bool == true)
        #expect(pinnedRow["current"] as? Bool == false)
        #expect(pinnedRow["updated_at"] as? String != nil)
        let archivedRow = try #require(row(seeds.archived))
        #expect(archivedRow["state"] as? String == "archived")
        #expect(archivedRow["project_name"] as? String == "Q项目")
        #expect(try #require(row(seeds.current))["current"] as? Bool == true)
        let trashedRow = try #require(row(trashed))
        #expect(trashedRow["state"] as? String == "trashed")
        #expect(trashedRow["title"] as? String == "Q回收站会话")
    }

    @Test("scope=list with query filters on title/project metadata only, never on message text")
    func listQueryIsMetadataOnly() async throws {
        let (center, bridge, root) = try makeFixture()
        defer { bridge.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: root) }
        let approval = Batch2QApproval()
        let seeds = await attachAndSeed(bridge, center, root, approval: approval)

        let byTitle = try await run(bridge, tool: SessionReadTool.toolName,
                                    input: ["scope": "list", "query": "归档"], callID: "b2q-list-q1")
        let titleRows = try listedSessions(byTitle)
        #expect(titleRows.compactMap { $0["session_id"] as? String } == [seeds.archived.uuidString])

        let byBody = try await run(bridge, tool: SessionReadTool.toolName,
                                   input: ["scope": "list", "query": Self.bodyPinned], callID: "b2q-list-q2")
        #expect(try listedSessions(byBody).isEmpty, "query 命中正文不算命中：list 不是正文搜索入口")
    }

    @Test("a denied list call returns nothing")
    func deniedListReturnsNothing() async throws {
        let (center, bridge, root) = try makeFixture()
        defer { bridge.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: root) }
        let approval = Batch2QApproval(denying: [SessionReadTool.toolName])
        _ = await attachAndSeed(bridge, center, root, approval: approval)

        let provider = try await run(bridge, tool: SessionReadTool.toolName,
                                     input: ["scope": "list"], callID: "b2q-list-deny")
        #expect(await approval.sessionReadRequests.count == 1)
        let body = try #require(provider.returnedToolMessage)
        #expect(body.contains("Error executing tool"))
        #expect(!body.contains("Q置顶会话"))
    }

    // MARK: 6 导出当前会话（session_read scope=export）

    @Test("scope=export returns the current session as the same redacted Markdown the sidebar export writes")
    func exportCurrentSessionMatchesSidebarFormat() async throws {
        let (center, bridge, root) = try makeFixture()
        defer { bridge.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: root) }
        let approval = Batch2QApproval()
        let seeds = await attachAndSeed(bridge, center, root, approval: approval)
        let redactor = ChatTranscriptRedactor(store: center.envStore)

        let provider = try await run(bridge, tool: SessionReadTool.toolName,
                                     input: ["scope": "export"], callID: "b2q-export")
        let cards = await approval.sessionReadRequests
        #expect(cards.count == 1)
        #expect(cards.first?.inputSummary.contains("scope: export") == true)

        let markdown = try #require(provider.returnedToolMessage)
        #expect(markdown.hasPrefix("# " + redactor.redactVisibleConversationBody("Q当前会话") + "\n"))
        #expect(markdown.contains("## 用户"))
        #expect(markdown.contains(redactor.redactVisibleConversationBody(Self.bodyCurrent)))
        // 只导出当前会话，不带出其它会话正文
        for secret in Self.allBodies { #expect(!markdown.contains(secret)) }
        _ = seeds
    }
}
