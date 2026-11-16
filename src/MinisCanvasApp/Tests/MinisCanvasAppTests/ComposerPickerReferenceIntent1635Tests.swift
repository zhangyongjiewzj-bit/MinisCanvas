import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

/// Only the remote response is controlled. The registered owned catalog,
/// ordinary Composer, detached prompt preparation and AgentLoop are real.
private final class PickerIntentProvider1635: LLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
    struct Request: Sendable { let messages: [LLMMessage]; let systemPrompt: String }
    let name = "picker-intent-owned1635"
    var model = LLMModel(id: "picker-intent-model1635", displayName: "Owned1635", provider: "picker-intent-owned1635")
    let capabilities: Set<ProviderCapability> = [.tools]
    var runtimeConfigurationMaterial: String? = "owned-picker-intent1635"
    private let lock = NSLock()
    private var recorded: [Request] = []
    var requests: [Request] { lock.withLock { recorded } }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        lock.withLock { recorded.append(.init(messages: messages, systemPrompt: systemPrompt ?? "")) }
        return LLMResponse(text: "OWNED1635_NORMAL_FINAL", stopReason: "stop", usage: nil)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt, maxTokens: maxTokens, temperature: temperature)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@Suite("COM18 owned picker mentions distinguish current intent from reference data", .serialized)
@MainActor
struct ComposerPickerReferenceIntent1635Tests {
    @Test("frozen intent text alone controls picker matching")
    func frozenIntentDoesNotFallBackToReferenceBearingUserMessage() throws {
        let plugin = PickerCatalogItem(
            id: "plugin:owned1635", kind: .plugin, name: "OwnedPlugin1635",
            detail: "synthetic", isEnabled: true
        )
        let base = ChatTurnPromptPreprocessInput(
            basePrompt: "base", userMessage: "资料正文 @OwnedPlugin1635",
            memoryEnabled: false, memoryInjector: nil, memoryScope: nil,
            skillInjector: nil, legacySkillResult: .init(fragment: nil, receipts: []),
            pickerCatalog: [plugin], steers: [], intentText: "请概括资料。"
        )
        let withoutIntentReference = try #require(ChatTurnPromptPreprocessor.prepare(base))
        #expect(!withoutIntentReference.systemPrompt.contains("OwnedPlugin1635"))

        let explicit = ChatTurnPromptPreprocessInput(
            basePrompt: "base", userMessage: "资料正文 @unregistered",
            memoryEnabled: false, memoryInjector: nil, memoryScope: nil,
            skillInjector: nil, legacySkillResult: .init(fragment: nil, receipts: []),
            pickerCatalog: [plugin], steers: [], intentText: "@OwnedPlugin1635 请概括资料。"
        )
        let withIntentReference = try #require(ChatTurnPromptPreprocessor.prepare(explicit))
        #expect(withIntentReference.systemPrompt.contains("- 插件：OwnedPlugin1635（MCP）"))
    }

    @Test("reference @skill/plugin cannot become current selection; explicit current intent still selects",
          arguments: [false, true])
    func ordinaryReferenceMentionsDoNotSelectButExplicitIntentDoes(explicitSelection: Bool) async throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("picker-intent1635-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let badges = SessionBadgeStore(directory: root.appendingPathComponent("badges"))
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let readiness = ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        let now = Date()
        // Match the existing U4 ordinary controlled-provider route receipt.
        // This is explicit synthetic transport readiness, not a live credential.
        try #require(readiness.upsert([ProviderReadinessPersistenceRecord(
            providerID: "picker-intent-owned1635", modelID: "picker-intent-model1635",
            status: .passed, readinessState: .mock, checkedAt: now,
            evidenceID: "owned1635-readiness", isApplied: true,
            discoveryReceiptID: "owned1635-discovery", discoveredAt: now,
            applyReceiptID: "provider-readiness-apply:owned1635", appliedAt: now)]))
        let center = SettingsCenter(settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("providers"), keychain: keychain),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            sessionStore: sessions, sessionBadgeStore: badges,
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite("picker-intent1635-" + UUID().uuidString)),
            providerReadinessStore: readiness)
        let skill = try center.skillStore.importSkillThroughLifecycle(
            content: "---\nname: OwnedSkill1635\ndescription: registered synthetic selection\n---\nOWNED1635_CANONICAL_SKILL_BODY",
            source: .file, reason: "owned local explicit lifecycle approval",
            approval: SkillApproval(approverID: "owned-synthetic-user1635"))
        let plugin = try center.mcpManager.addServer(MCPServer(id: "ownedplugin1635", name: "OwnedPlugin1635",
            type: .stdio, command: "/usr/bin/false"))
        #expect(plugin.name == "OwnedPlugin1635")
        let receiptBefore = center.skillStore.lifecycleReceipt(for: skill.skill.id)
        let journalBefore = try Data(contentsOf: center.skillStore.lifecycleReceiptsFileURL)
        let defaults = try #require(UserDefaults(suiteName: "picker-intent1635-" + UUID().uuidString))
        let ownedHermes = root.appendingPathComponent("hermes")
        try FileManager.default.createDirectory(at: ownedHermes, withIntermediateDirectories: true)
        let skills = SkillsStore(appStore: center.skillStore,
                                stateFileURL: root.appendingPathComponent("skill-enabled.json"))
        let bridge = try BridgeStore(taskStorePersistenceURL: root.appendingPathComponent("tasks.json"),
            shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            settingsCatalogSkillsStore: skills, logManager: LogManager(directory: root.appendingPathComponent("bridge-logs")),
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("workflows")),
            sessionBadgeStore: badges, sessionDocumentStore: SessionDocumentStore(directory: sessions.directory),
            sessionStore: sessions, memoryStore: center.memoryStore, providerReadinessStore: readiness,
            canvasFeatureLane: .phase3NonCanvas)
        defer { bridge.chat.stopAllStreamingForSafety() }
        bridge.bindProductionEffectiveSettingsSource { [weak center] in center?.bl6EffectiveSettingsSnapshot }
        await bridge.attachProductionServices(fileAccessAllowedRoot: root, sessionDirectory: sessions.directory,
            skillStore: center.skillStore, externalNetworkAllowed: true).value
        #expect(bridge.chat.agentEngine is AgentLoopChatEngine)
        let sessionID = try #require(bridge.chat.activeSessionID)
        let catalog = SkillCatalogLoader.loadCatalog(appStore: center.skillStore,
             servers: center.mcpManager.listServers())
        #expect(catalog.contains { $0.id == "skill:" + skill.skill.id && $0.isEnabled })
        #expect(catalog.contains { $0.id == "plugin:" + plugin.id && $0.isEnabled })
        bridge.chat.pickerCatalogLoader = { catalog }
        bridge.chat.loadPickerCatalog()
        #expect(bridge.chat.selectedPickerItems.isEmpty)
        let provider = PickerIntentProvider1635()
        bridge.chat.streamingProviderOverride = provider
        let instruction = explicitSelection ? "@OwnedSkill1635 @OwnedPlugin1635 请概括资料。" : "请概括资料。"
        let material = "外部引用只描述名称 @OwnedSkill1635 @OwnedPlugin1635\n" +
            (1...130).map { "OWNED1635_REFERENCE_LINE_\($0) 不属于本轮选择。" }.joined(separator: "\n")
        bridge.chat.draftText = instruction
        #expect(PastedTextComposerConsumer.accept(ComposerPasteEvent(text: material, bodyBefore: instruction), in: bridge.chat))
        #expect(bridge.chat.activePastedTextDraft?.kind == .reference)
        #expect(bridge.chat.selectedPickerItems.isEmpty)
        bridge.chat.submitComposer()
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while bridge.chat.isStreaming && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(!bridge.chat.isStreaming)
        print("COM18_PICKER1635_PREWIRE explicit=\(explicitSelection) submission=\(bridge.chat.lastComposerSubmissionSnapshot != nil) invalidSettings=\(bridge.chat.lastSubmissionBlockedByInvalidSettings) feedback=\(bridge.chat.pastedTextActionFeedback ?? "nil") assistants=\(bridge.chat.messages.filter { $0.role == .assistant }.map(\.content))")
        #expect(provider.requests.count == 1)
        let request = try #require(provider.requests.first)
        #expect(request.messages.contains { $0.role == .user && $0.content.contains(material) })
        #expect(request.systemPrompt.contains("OWNED1635_CANONICAL_SKILL_BODY") == explicitSelection)
        #expect(request.systemPrompt.contains("- 插件：OwnedPlugin1635（MCP）") == explicitSelection)
        #expect(bridge.chat.lastSkillInjectionReceipts.contains { $0.skillID == skill.skill.id && $0.injected } == explicitSelection)
        let submitted = try #require(bridge.chat.lastComposerSubmissionSnapshot)
        let user = try #require(bridge.chat.messages.last { $0.role == .user })
        #expect(submitted.sessionID == sessionID.uuidString && submitted.messageID == user.id.uuidString)
        #expect(user.trustedSessionReadIntent == nil)
        let reference = try #require(user.referenceCard)
        #expect(reference.material == material && reference.instruction == instruction && reference.sessionID == sessionID)
        #expect(bridge.chat.messages.last { $0.role == .assistant }?.content == "OWNED1635_NORMAL_FINAL")
        #expect(bridge.chat.selectedPickerItems.isEmpty)
        let persisted = try #require(SessionStore(directory: sessions.directory).loadSession(id: sessionID.uuidString))
        #expect(persisted.messages.contains { $0.role == .user && $0.content.contains(material) })
        #expect(center.skillStore.lifecycleReceipt(for: skill.skill.id) == receiptBefore)
        #expect(try Data(contentsOf: center.skillStore.lifecycleReceiptsFileURL) == journalBefore)
        print("COM18_PICKER1635 explicit=\(explicitSelection) source=\(sessionID) message=\(user.id) requests=\(provider.requests.count) skillBody=\(request.systemPrompt.contains("OWNED1635_CANONICAL_SKILL_BODY")) plugin=\(request.systemPrompt.contains("- 插件：OwnedPlugin1635（MCP）")) root=\(root.path)")
    }
}
