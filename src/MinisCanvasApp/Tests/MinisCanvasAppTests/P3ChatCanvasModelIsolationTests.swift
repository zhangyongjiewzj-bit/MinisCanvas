import Testing
import Foundation
import CanvasCore
import MinisCore
@testable import MinisCanvasApp

private struct P3ModelIsolationDownloader: VideoAssetDownloader {
    func download(remoteURL: String, recordID: String, into directory: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(recordID).mp4")
        try Data("model-isolation".utf8).write(to: destination, options: .atomic)
        return destination
    }
}

private struct P3ModelIsolationProviderFactoryError: Error {}

@Suite("P3 对话模型与画布模型完全隔离")
@MainActor
struct P3ChatCanvasModelIsolationTests {

    @Test func unconfiguredCanvasModelDoesNotFallBackToChatSelection() throws {
        let chat = ChatStore()
        chat.selectModel(.deepSeekReasoner)

        let canvas = CanvasStore()
        let node = try #require(canvas.addNode(ofType: ManjuNodeType.imageGen.rawValue))
        canvas.clearBackendConfig(for: node.id)

        #expect(canvas.canvasModelSelection(for: node.id) == nil)
        canvas.runGraph(from: Set([node.id]))

        #expect(!canvas.isRunning)
        #expect(canvas.statusMessage?.contains("未单独配置模型") == true)
        #expect(chat.selectedProviderType == .deepSeek)
        #expect(chat.selectedModelID == "deepseek-reasoner")
        #expect(chat.sessions.first?.providerTypeRaw == ProviderType.deepSeek.rawValue)
        #expect(chat.sessions.first?.modelID == "deepseek-reasoner")
    }

    @Test func partialCanvasModelConfigurationFailsClosed() throws {
        let canvas = CanvasStore()
        let node = try #require(canvas.addNode(ofType: ManjuNodeType.videoGen.rawValue))
        let partialConfigurations = [
            NodeBackendConfig(providerType: .cloud, providerID: "kling", modelID: ""),
            NodeBackendConfig(providerType: .cloud, providerID: "", modelID: "kling-v2"),
            NodeBackendConfig(providerType: .cloud, providerID: "   ", modelID: "   "),
        ]

        for config in partialConfigurations {
            canvas.updateBackendConfig(config, for: node.id)
            #expect(canvas.canvasModelSelection(for: node.id) == nil)
            canvas.runGraph(from: Set([node.id]))
            #expect(!canvas.isRunning)
            #expect(canvas.statusMessage?.contains("未单独配置模型") == true)
        }
    }

    @Test
    func recoveryRejectsProviderOnlyCanvasModelSnapshot() throws {
        let providerID = "p3-recovery-provider-only"
        let node = CanvasNode(
            type: ManjuNodeType.videoGen.rawValue,
            title: "恢复模型缺失",
            backendConfig: NodeBackendConfig(
                providerType: .cloud,
                providerID: providerID,
                modelID: " "
            )
        )
        let graph = NodeGraph(nodes: [node], revision: 11)
        let canvasID = UUID()
        let scope = CanvasRecoveryScopeBox()
        scope.replace(canvasID: canvasID, graph: graph)
        let identity = CanvasExecutionIdentity(
            canvasID: canvasID,
            runID: UUID(),
            graphRevision: graph.structuralRevision,
            nodeID: node.id,
            nodeRevision: graph.structuralRevision
        )
        let snapshot = ProviderSnapshot(
            providerID: providerID,
            modelID: providerID,
            capabilities: [.video],
            configurationFingerprint: MinisCanvasVideoInvoker.configurationFingerprint(
                providerID: providerID,
                modelID: providerID
            )
        )
        let context = MediaTaskContext(
            identity: identity,
            providerSnapshot: snapshot,
            promptFingerprint: "p3-provider-only-recovery"
        )

        #expect(scope.identity(for: context) == nil)
        #expect(scope.workerProjection(for: context) == nil)
    }

    @Test
    func scopedVideoInvokerRejectsBlankCanvasModelBeforeProviderFactory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-model-isolation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let node = CanvasNode(type: ManjuNodeType.videoGen.rawValue, title: "模型缺失")
        let canvasID = UUID()
        let runID = UUID()
        let invoker = MinisCanvasVideoInvoker(
            taskStore: VideoTaskStore(directory: directory),
            assetDirectory: directory.appendingPathComponent("assets", isDirectory: true),
            assetDownloader: P3ModelIsolationDownloader(),
            providerFactory: { _ in throw P3ModelIsolationProviderFactoryError() },
            assetStore: CanvasAssetStore(),
            scopeProvider: { node in
                CanvasExecutionIdentity(
                    canvasID: canvasID,
                    runID: runID,
                    graphRevision: 3,
                    nodeID: node.id,
                    nodeRevision: 3
                )
            }
        )
        let backend = NodeBackendConfig(
            providerType: .cloud,
            providerID: "p3-model-isolation-provider",
            modelID: " "
        )

        do {
            _ = try await invoker.generate(
                node: node,
                prompt: "no provider fallback",
                firstFrame: nil,
                backend: backend
            )
            Issue.record("scoped 画布执行不得用 providerID 补齐空 modelID")
        } catch VideoTaskExecutionError.contextMismatch(let detail) {
            #expect(detail.contains("model"))
        } catch {
            Issue.record("空 modelID 应在 providerFactory 前 fail-closed，实际为 \(error)")
        }
    }

    @Test func localRerunChecksOnlyTargetAndDownstreamModels() async throws {
        let canvas = CanvasStore()
        let unconfiguredUpstream = try #require(
            canvas.addNode(ofType: ManjuNodeType.imageGen.rawValue)
        )
        let configuredTarget = try #require(
            canvas.addNode(ofType: ManjuNodeType.videoGen.rawValue)
        )
        canvas.clearBackendConfig(for: unconfiguredUpstream.id)
        #expect(canvas.connectNodes(fromID: unconfiguredUpstream.id, toID: configuredTarget.id))

        canvas.runGraph(from: Set([configuredTarget.id]))

        #expect(canvas.isRunning)
        #expect(canvas.currentRunEnvelope != nil)
        #expect(canvas.statusMessage == "局部重跑中…")
        canvas.cancelRun()
        let deadline = Date().addingTimeInterval(2)
        while canvas.isRunning && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(!canvas.isRunning)
    }

    @Test func chatPickerChangesOnlyChatSelection() throws {
        let canvas = CanvasStore()
        let node = try #require(canvas.addNode(ofType: ManjuNodeType.imageGen.rawValue))
        let canvasSelection = try #require(canvas.canvasModelSelection(for: node.id))
        let chat = ChatStore()
        let suiteName = "p3-chat-canvas-isolation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var picker = ModelPickerState(provider: nil, modelID: nil, tier: nil)
        picker.selectProvider(.deepSeek)
        picker.selectModel("deepseek-reasoner")
        picker.selectTier(.quality)
        picker.apply(to: chat, defaults: defaults)

        #expect(chat.selectedProviderType == .deepSeek)
        #expect(chat.selectedModelID == "deepseek-reasoner")
        #expect(canvas.canvasModelSelection(for: node.id) == canvasSelection)
        #expect(canvas.graph.node(id: node.id)?.backendConfig?.providerID == "gimage2")
        #expect(canvas.graph.node(id: node.id)?.backendConfig?.modelID == "gpt-image-2-official")
    }

    @Test func canvasPickerChangesOnlyCanvasSelection() throws {
        let chat = ChatStore()
        chat.selectModel(.qwen38MaxPreview)
        let chatProvider = chat.selectedProviderType
        let chatModel = chat.selectedModelID
        let threadProvider = chat.sessions.first?.providerTypeRaw
        let threadModel = chat.sessions.first?.modelID

        let canvas = CanvasStore()
        let node = try #require(canvas.addNode(ofType: ManjuNodeType.imageGen.rawValue))
        let config = NodeInspectorView.applyingModelSelection(
            to: node.backendConfig,
            modelID: "seedream-v2",
            providerID: "jimeng",
            providerType: .cloud
        )
        canvas.updateBackendConfig(config, for: node.id)

        let canvasSelection = try #require(canvas.canvasModelSelection(for: node.id))
        #expect(canvasSelection.providerID == "jimeng")
        #expect(canvasSelection.modelID == "seedream-v2")
        #expect(chat.selectedProviderType == chatProvider)
        #expect(chat.selectedModelID == chatModel)
        #expect(chat.sessions.first?.providerTypeRaw == threadProvider)
        #expect(chat.sessions.first?.modelID == threadModel)
    }

    @Test func persistenceAndRestoreKeepChatAndCanvasNamespacesSeparate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-model-isolation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let chatDirectory = root.appendingPathComponent("chat", isDirectory: true)
        let canvasDirectory = root.appendingPathComponent("canvas", isDirectory: true)

        let chat = ChatStore()
        chat.attachPersistence(SessionStore(directory: chatDirectory))
        chat.setProvider(.deepSeek)
        chat.applyPickedModel(modelID: "deepseek-reasoner")

        let canvasDrafts = DraftStore(directory: canvasDirectory)
        let canvas = CanvasStore()
        canvas.attachDraftStore(canvasDrafts)
        let node = try #require(canvas.addNode(ofType: ManjuNodeType.imageGen.rawValue))
        canvas.updateBackendConfig(
            NodeBackendConfig(
                providerType: .cloud,
                providerID: "jimeng",
                modelID: "seedream-v2",
                params: ["size": "2K"]
            ),
            for: node.id
        )
        canvas.flushCanvasDraft()

        let restoredChat = ChatStore()
        restoredChat.attachPersistence(SessionStore(directory: chatDirectory))
        let restoredCanvas = CanvasStore()
        restoredCanvas.attachDraftStore(DraftStore(directory: canvasDirectory))
        let draft = try #require(restoredCanvas.recoverableCanvasDraft())
        #expect(restoredCanvas.restoreCanvas(from: draft))

        #expect(restoredChat.selectedProviderType == .deepSeek)
        #expect(restoredChat.selectedModelID == "deepseek-reasoner")
        #expect(restoredChat.sessions.first?.providerTypeRaw == ProviderType.deepSeek.rawValue)
        #expect(restoredChat.sessions.first?.modelID == "deepseek-reasoner")

        let restoredCanvasSelection = try #require(
            restoredCanvas.canvasModelSelection(for: node.id)
        )
        #expect(restoredCanvasSelection.providerID == "jimeng")
        #expect(restoredCanvasSelection.modelID == "seedream-v2")

        restoredChat.selectModel(.qwen38MaxPreview)
        #expect(restoredCanvas.canvasModelSelection(for: node.id) == restoredCanvasSelection)

        restoredCanvas.updateBackendConfig(
            NodeBackendConfig(
                providerType: .cloud,
                providerID: "gimage2",
                modelID: "gpt-image-2-official"
            ),
            for: node.id
        )
        #expect(restoredChat.selectedProviderType == .dashScope)
        #expect(restoredChat.selectedModelID == "qwen3.8-max-preview")
        #expect(restoredChat.sessions.first?.providerTypeRaw == ProviderType.dashScope.rawValue)
        #expect(restoredChat.sessions.first?.modelID == "qwen3.8-max-preview")
    }
}
