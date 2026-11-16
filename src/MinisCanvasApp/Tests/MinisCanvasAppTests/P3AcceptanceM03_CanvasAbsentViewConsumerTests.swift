import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Phase 3 Chat view without a Canvas runtime")
@MainActor
struct P3AcceptanceM03_CanvasAbsentViewConsumerTests {
    @Test("a saved Canvas pane falls back to Chat without collapsing the three-panel layout")
    func savedCanvasChoiceUsesChatInPhase3() {
        #expect(CanvasViewAdmission.layout(.canvas, canvasAvailable: false) == .chat)
        #expect(CanvasViewAdmission.layout(.split, canvasAvailable: false) == .split)
        #expect(CanvasViewAdmission.pane(.canvas, canvasAvailable: false) == .chat)
        #expect(CanvasViewAdmission.panes(canvasAvailable: false) == [.chat])

        #expect(CanvasViewAdmission.layout(.canvas, canvasAvailable: true) == .canvas)
        #expect(CanvasViewAdmission.pane(.canvas, canvasAvailable: true) == .canvas)
        #expect(CanvasViewAdmission.panes(canvasAvailable: true) == MainPane.allCases)
    }

    @Test("the Chat slash menu hides Canvas while keeping ordinary commands")
    func phase3SlashMenuOmitsCanvas() {
        let registry = CommandRegistry()
        registry.registerComposerCommands()
        let canvasInPhase3 = GlobalComposer.visibleSlashEntries(
            for: "/canvas.run", registry: registry,
            sessionState: .neutral, canvasAvailable: false
        )
        let canvasInPhase4 = GlobalComposer.visibleSlashEntries(
            for: "/canvas.run", registry: registry,
            sessionState: .neutral, canvasAvailable: true
        )
        let helpInPhase3 = GlobalComposer.visibleSlashEntries(
            for: "/help", registry: registry,
            sessionState: .neutral, canvasAvailable: false
        )
        #expect(canvasInPhase3.isEmpty)
        #expect(canvasInPhase4.map(\.id) == ["canvas.run"])
        #expect(helpInPhase3.map(\.id) == ["help"])
    }

    @Test("the production palette has Chat and settings commands but no Canvas entry")
    func phase3PaletteOmitsCanvasCommands() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-canvas-absent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = try #require(UserDefaults(suiteName: "p3.canvas-absent.\(UUID().uuidString)"))
        let log = LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 20)
        let memory = MemoryStore(directory: root.appendingPathComponent("memory"))
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults),
            preferencesDefaults: defaults,
            logManager: log,
            sessionDocumentStore: SessionDocumentStore(directory: root.appendingPathComponent("documents")),
            contextManifestStore: ContextManifestStore(),
            memoryStore: memory,
            memoryProposalConsumer: MemoryProposalConsumer(store: memory),
            canvasFeatureLane: .phase3NonCanvas
        )
        let backendConfigs = Dictionary(uniqueKeysWithValues: LocalBackendKind.allCases.map {
            ($0, LocalBackendConfig(kind: $0, baseURL: $0.defaultBaseURL, enabled: false))
        })
        let dependencies = CommandDependencies(
            env: EnvVarStore(directory: root.appendingPathComponent("environment")),
            log: log,
            backends: LocalBackends(configs: backendConfigs),
            sessions: SessionStore(directory: root.appendingPathComponent("sessions")),
            memory: memory,
            workflows: WorkflowStore(storeDirectory: root.appendingPathComponent("workflows"))
        )

        #expect(bridge.canvasIfAvailable.map { _ in 1 } == nil)
        #expect(bridge.canvasBoundaryIfAvailable.map { _ in 1 } == nil)
        let registry = AppCommandCatalog.makeRegistry(bridge: bridge, dependencies: dependencies)
        let ids = Set(registry.allCommands().map(\.id))
        #expect(ids.contains("session.new"))
        #expect(ids.contains("settings.open"))
        #expect(ids.contains("ui.chat.compact"))
        #expect(ids.contains("ui.layout.split"))
        #expect(ids.contains("ui.layout.chat"))
        #expect(registry.command(id: "ui.layout.split")?.title == "布局：聊天三栏")
        #expect(!ids.contains("ui.pipeline"))
        #expect(!ids.contains("ui.layout.canvas"))
        #expect(!ids.contains("ui.canvas.run"))
        #expect(!ids.contains(where: { $0.hasPrefix("ui.add-node.") }))
        let canvasMetadata = registry.allCommands().filter { $0.category == .canvas }
        #expect(Set(canvasMetadata.map(\.id)) == ["canvas.run", "canvas.cancel", "canvas.minimap"])
        for command in canvasMetadata {
            guard case .disabled(let reason) = command.currentAvailability else {
                Issue.record("Phase 3 Canvas metadata must never be executable")
                continue
            }
            #expect(reason == ComposerCommandAdjudicationCenter.missingExecutorReason(for: command.id))
        }
    }
}
