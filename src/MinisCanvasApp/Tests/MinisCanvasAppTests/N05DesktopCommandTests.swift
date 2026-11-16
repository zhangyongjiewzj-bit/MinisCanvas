import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("N05 desktop commands source candidate")
@MainActor
struct N05DesktopCommandTests {
    @discardableResult
    private func installDesktop(_ chat: ChatStore, openedPages: @escaping (String) -> Void = { _ in },
        openedLocalNavigation: @escaping (String) -> Void = { Issue.record("Unexpected navigation: \($0)") }
    ) -> ComposerCommandAdjudicationCenter {
        let facts = ComposerPolicyFactSource(knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: chat.composerWorkspaceID, revision: "n05-central", leaseID: "n05-central",
            expiresAt: Date().addingTimeInterval(60), autonomyCeiling: .l2)
        chat.configureComposerPolicy(facts)
        let desktop = N05DesktopCommandConsumer(chat: chat, openSettings: openedPages,
            openModelPicker: { openedLocalNavigation("model") },
            openContext: { openedLocalNavigation("context") },
            openDoctor: { openedLocalNavigation("doctor") },
            enterPlanMode: { chat.enterPlanMode(description: $0) },
            redactor: { ChatTranscriptRedactor(secretValues: []) })
        let center = ComposerCommandAdjudicationCenter()
        center.desktopCommandAction = { request, snapshot in try desktop.execute(request, snapshot: snapshot) }
        chat.onComposerCommandPolicy = { request, snapshot in
            center.evaluate(request: request, snapshot: snapshot, facts: chat.composerPolicyFacts)
        }
        chat.agentEngine = FallbackChatEngine(composerPolicyFacts: facts)
        return center
    }

    @Test func shortcutsDispatchUsesTheExistingSettingsNavigationWithoutStartingATurn() async throws {
        try await B1TaskOriginalFixtureSupport.withRoot("shortcuts-desktop-route") { root async throws -> Void in
            let suite = "shortcuts-route-" + UUID().uuidString
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let bridge = BridgeStore(shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
                logManager: LogManager(directory: root.appendingPathComponent("logs")),
                workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("workflows")),
                sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
                sessionDocumentStore: SessionDocumentStore(directory: root.appendingPathComponent("documents")),
                agentTaskStore: try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json")),
                contextManifestStore: try ContextManifestStore(persistenceURL: root.appendingPathComponent("contexts.json")),
                memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
                commandEnvStore: EnvVarStore(directory: root.appendingPathComponent("env"),
                    keychain: KeychainStore(backing: InMemoryKeychainBacking())),
                canvasFeatureLane: .phase3NonCanvas)
            var openedPages: [String?] = []
            bridge.deepLinkHandler.onOpenSettings = { openedPages.append($0) }
            let chat = bridge.chat
            _ = installDesktop(chat, openedPages: { bridge.deepLinkHandler.handle(.openSettings(id: $0)) })
            defer { chat.onComposerCommandPolicy = nil; bridge.deepLinkHandler.onOpenSettings = nil }
            let source = try #require(chat.activeSessionID)
            let before = chat.messages
            let bindings = ShortcutAction.allCases.map { bridge.shortcutStore.binding(for: $0) }
            chat.draftText = "/shortcuts"
            chat.submitComposer()
            #expect(openedPages == ["快捷键"])
            #expect(chat.lastComposerCommandReceipt?.commandID == "shortcuts")
            #expect(chat.lastComposerCommandReceipt?.disposition == .execute)
            #expect(chat.pendingComposerCommand == nil && chat.draftText.isEmpty)
            #expect(chat.activeSessionID == source && chat.messages == before)
            #expect(chat.turnTaskForTests(sessionID: source) == nil && !chat.isActiveSessionGenerating)
            #expect(ShortcutAction.allCases.map { bridge.shortcutStore.binding(for: $0) } == bindings)
            #expect(bridge.canvasIfAvailable == nil)
            chat.draftText = "/shortcuts arbitrary"
            chat.submitComposer()
            #expect(openedPages == ["快捷键"])
            #expect(chat.lastComposerCommandReceipt?.commandID == "shortcuts")
            #expect(chat.lastComposerCommandReceipt?.disposition == .reject)
            #expect(ShortcutAction.allCases.map { bridge.shortcutStore.binding(for: $0) } == bindings)
            #expect(chat.turnTaskForTests(sessionID: source) == nil && !chat.isActiveSessionGenerating)
        }
    }

    @Test func clearConsumesTheOldSlashBeforeSwitchingSessions() throws {
        let chat = ChatStore()
        installDesktop(chat)
        defer { chat.onComposerCommandPolicy = nil }
        let source = try #require(chat.activeSessionID)
        chat.appendUser("keep this conversation")
        chat.draftText = "/clear"
        chat.submitComposer()
        #expect(chat.activeSessionID != source)
        #expect(chat.draftText.isEmpty)
        chat.switchSession(id: source)
        #expect(chat.draftText.isEmpty)
        #expect(chat.messages.contains { $0.content == "keep this conversation" })
    }

    @Test func planSlashDescriptionIsAnActualLiteralTurnAndOffersTheCompletedPlan() async throws {
        let chat = ChatStore()
        installDesktop(chat)
        defer { chat.stopAllStreamingForSafety(); chat.onComposerCommandPolicy = nil }
        let source = try #require(chat.activeSessionID)
        chat.streamingProviderOverride = N05ImmediateProvider()
        chat.draftText = "/plan /clear"
        chat.submitComposer()
        let running = try #require(chat.turnTaskForTests(sessionID: source))
        await running.value
        #expect(chat.activeSessionID == source)
        #expect(chat.messages.first(where: { $0.role == .user })?.content == "/clear")
        #expect(chat.composerPolicySelection.mode == .plan)
        #expect(chat.activePlanApproval?.markdown == "1. Inspect the input.\n2. Verify the change.")
    }

    @Test(arguments: ["status", "tasks", "usage"])
    func busyReadOnlyCommandsAreImmediateAndRenameKeepsFIFO(commandID: String) async throws {
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let chat = ChatStore()
        var opened: [String] = []
        let center = installDesktop(chat, openedPages: { opened.append($0) })
        var observedRead: String?
        center.statusProjection = { _ in
            observedRead = "status"
            return chat.isActiveSessionGenerating ? "生成中" : "空闲"
        }
        let taskStore = AgentTaskStore()
        _ = try taskStore.enqueue(taskID: "n05-background", parentID: "n05-parent",
            providerID: "synthetic", modelID: "synthetic")
        center.tasksProjection = {
            observedRead = "tasks"
            return TaskCenterSlashCommandAdapter(
                observation: TaskCenterObservationSnapshot(taskStore: taskStore)).execute("/tasks")
        }
        defer {
            entered.continuation.finish(); release.continuation.finish()
            chat.stopAllStreamingForSafety(); chat.onComposerCommandPolicy = nil
        }
        let session = try #require(chat.activeSessionID)
        chat.streamingProviderOverride = N05WaitingProvider(entered: entered.continuation, release: release.stream)
        chat.draftText = "start a real turn"
        chat.submitComposer()
        let running = try #require(chat.turnTaskForTests(sessionID: session))
        var iterator = entered.stream.makeAsyncIterator()
        _ = await iterator.next()
        chat.draftText = "/" + commandID
        #expect(chat.enqueueComposer())
        #expect(chat.lastComposerCommandReceipt?.commandID == commandID)
        #expect(chat.lastComposerCommandReceipt?.disposition == .execute)
        #expect(chat.activeQueuedComposerMessages.isEmpty)
        if commandID == "usage" { #expect(opened == ["用量"]) }
        else {
            #expect(observedRead == commandID)
            #expect(opened.isEmpty)
            let projection = try #require(center.projection)
            #expect(projection.text.contains(commandID == "tasks" ? "n05-background" : "生成中"))
        }
        #expect(chat.isActiveSessionGenerating)
        chat.draftText = "/rename first"
        chat.interruptAndSend()
        #expect(chat.isActiveSessionGenerating)
        #expect(chat.submitRegisteredComposerCommand(id: "rename", args: ["title": "second"]))
        #expect(chat.activeQueuedComposerMessages.map(\.text) == ["/rename first", "/rename second"])
        release.continuation.yield(())
        release.continuation.finish()
        await running.value
        #expect(chat.activeQueuedComposerMessages.isEmpty)
        #expect(chat.sessions.first(where: { $0.id == session })?.title == "second")
        #expect(chat.messages.last?.wasInterrupted == false)
    }

    @Test(arguments: ["context", "doctor"])
    func localNavigationConsumesTheCommandWithoutAppendingATurn(commandID: String) throws {
        let chat = ChatStore()
        var opened: [String] = []
        _ = installDesktop(chat, openedLocalNavigation: { opened.append($0) })
        defer { chat.onComposerCommandPolicy = nil }
        let before = chat.messages
        chat.draftText = "/" + commandID
        chat.submitComposer()
        #expect(opened == [commandID])
        #expect(chat.lastComposerCommandReceipt?.commandID == commandID)
        #expect(chat.lastComposerCommandReceipt?.disposition == .execute)
        #expect(chat.pendingComposerCommand == nil)
        #expect(chat.draftText.isEmpty && chat.messages == before)
        #expect(!chat.isActiveSessionGenerating)
    }

    @Test func textArgumentsPreserveWhitespaceAndEquals() throws {
        let registry = CommandRegistry()
        registry.registerComposerCommands()
        for (input, key, expected) in [
            ("/compact 保留 model=x 的决策", "hint", "保留 model=x 的决策"),
            ("/rename 模型 model=x 对照", "title", "模型 model=x 对照"),
            ("/plan 比较 a=b 再拟定方案", "description", "比较 a=b 再拟定方案")
        ] {
            let parsed = CommandParser().parse(input, registry: registry)
            let request = try #require(registry.makePendingRequest(for: parsed))
            #expect(request.args[key] == expected)
        }
    }

    @Test func optionalCopyAndCostAliasResolve() throws {
        let registry = CommandRegistry()
        registry.registerComposerCommands()
        let copy = CommandParser().parse("/copy", registry: registry)
        switch registry.validatedComposerPendingRequest(for: copy, requestID: UUID()) {
        case .success(let request): #expect(request.commandID == "copy")
        case .failure: Issue.record("Default /copy should not require N")
        }
        #expect(CommandParser().parse("/cost", registry: registry).command?.id == "usage")
    }

    @Test func slashMenuAndPaletteEnumerateSameRegistry() throws {
        let registry = CommandRegistry()
        registry.registerComposerCommands()
        let suite = "N05-palette-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = CommandPaletteModel(registry: registry, display: [:],
            favorites: FavoriteCommandsStore(defaults: defaults))
        let slashIDs = Set(ComposerSlashCommandMenu.descriptors(registry: registry).map(\.id))
        #expect(Set(model.sections.flatMap(\.commands).map(\.id)) == slashIDs)
        let modelRow = try #require(model.sections.flatMap(\.commands).first { $0.id == "model" })
        #expect(modelRow.isEnabled)
    }

    @Test func skillArgumentHintReachesVisiblePickerDetail() throws {
        let skill = try #require(SkillCatalogLoader.skillItem(skillMD: """
        ---
        name: compare
        description: Compare records
        argument-hint: '[file] [format]'
        ---
        Use $ARGUMENTS as input.
        """, directoryName: "compare"))
        #expect(skill.detail.contains("[file] [format]"))
        #expect(skill.detail.contains("Compare records"))
        #expect(skill.content == "Use $ARGUMENTS as input.")
    }


}

private struct N05ImmediateProvider: LLMProvider, Sendable {
    let name = "Mock"
    var model = LLMModel(id: "mock-echo", displayName: "Offline plan", provider: "Mock")
    let capabilities: Set<ProviderCapability> = [.streaming]
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        LLMResponse(text: "1. Inspect the input.\n2. Verify the change.", stopReason: "end_turn", usage: nil)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.text("1. Inspect the input.\n2. Verify the change."))
            continuation.yield(.finished(stopReason: "end_turn"))
            continuation.finish()
        }
    }
}
private struct N05WaitingProvider: LLMProvider, Sendable {
    let entered: AsyncStream<Void>.Continuation
    let release: AsyncStream<Void>
    let name = "Mock"
    var model = LLMModel(id: "mock-echo", displayName: "Offline queued command", provider: "Mock")
    let capabilities: Set<ProviderCapability> = [.streaming]
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        throw LLMError.unsupportedCapability(.tools)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        entered.yield(())
        var iterator = release.makeAsyncIterator()
        _ = await iterator.next()
        try Task.checkCancellation()
        return AsyncThrowingStream { continuation in
            continuation.yield(.text("completed without interruption"))
            continuation.yield(.finished(stopReason: "end_turn"))
            continuation.finish()
        }
    }
}
