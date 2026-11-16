import Testing
import Foundation
import CanvasCore
import MinisCore
@testable import MinisCanvasApp

// MARK: - I8 节点模型选择面板 + ProviderIDMap 接线

@Suite("I8 模型选择面板")
@MainActor
struct I8ModelPanelTests {

    // MARK: CanvasStore 面板状态与方法

    @Test func presentModelPanelSelectsAndOpens() {
        let store = CanvasStore()
        guard let node = store.addNode(ofType: "llm") else {
            Issue.record("llm 节点创建失败")
            return
        }
        store.presentModelPanel(for: node.id)
        #expect(store.selectedNodeID == node.id)
        #expect(store.modelPanelNodeID == node.id)
        store.closeModelPanel()
        #expect(store.modelPanelNodeID == nil)
    }

    @Test func updateAndClearBackendConfig() {
        let store = CanvasStore()
        guard let node = store.addNode(ofType: "image") else {
            Issue.record("image 节点创建失败")
            return
        }
        // 点选即生效：一个 tap 写入 providerID + modelID
        var config = NodeBackendConfig()
        config.providerType = .cloud
        config.providerID = "gimage2"
        config.modelID = "gpt-image-2-official"
        config.params["size"] = "1024x1024"
        store.updateBackendConfig(config, for: node.id)

        let updated = store.graph.node(id: node.id)
        #expect(updated?.backendConfig?.providerID == "gimage2")
        #expect(updated?.backendConfig?.modelID == "gpt-image-2-official")
        #expect(updated?.backendConfig?.params["size"] == "1024x1024")

        // 清空 → 跟随全局默认
        store.clearBackendConfig(for: node.id)
        #expect(store.graph.node(id: node.id)?.backendConfig == nil)

        // 不存在的节点 ID 安全忽略
        store.updateBackendConfig(config, for: UUID())
        store.clearBackendConfig(for: UUID())
    }

    // MARK: ModelCatalog 常用置顶 ⭐

    @Test func pinnedModelsSortToFront() {
        let entries = ModelCatalog.cloudProviders
            .flatMap(\.entries)
        #expect(!entries.isEmpty)
        let sorted = ModelCatalog.sorted(entries)
        // 置顶集合内的模型全部排在未置顶之前
        let firstUnstarred = sorted.firstIndex { !$0.starred }
        if let idx = firstUnstarred {
            for e in sorted[..<idx] { #expect(e.starred) }
            for e in sorted[idx...] { #expect(!e.starred) }
        }
        // 置顶清单覆盖全部云厂商的旗舰模型
        #expect(ModelCatalog.isPinned("qwen3.8-max-preview"))
        #expect(ModelCatalog.isPinned("gpt-image-2-official"))
        #expect(ModelCatalog.isPinned("kling-v2"))
        #expect(ModelCatalog.isPinned("seedance-v2"))
        #expect(ModelCatalog.isPinned("deepseek-v3"))
    }

    // MARK: ProviderIDMap 接线（providerID → ProviderType → 模型列表）

    @Test func cloudCatalogResolvesThroughProviderIDMap() {
        // 面板只展示 ProviderIDMap 可解析的 provider：目录必须全部可解析
        #expect(ModelCatalog.resolvedCloudProviders.count == ModelCatalog.cloudProviders.count)
        for provider in ModelCatalog.cloudProviders {
            let type = ProviderIDMap.providerType(fromID: provider.id)
            #expect(type != nil, "云端目录 providerID \(provider.id) 未在 ProviderIDMap 中登记")
        }
        // 双向：映射表给出的 providerID 能在目录中找到对应 provider（模型列表可查）
        for provider in ModelCatalog.resolvedCloudProviders {
            if let id = ProviderIDMap.providerID(from: ProviderIDMap.providerType(fromID: provider.id)!) {
                #expect(id == provider.id)
            }
        }
    }

    @Test func cloudCatalogModelsMatchProviderCapability() {
        // 每个 provider 的模型能力归属：LLM 类全 llm；生图全 image；生视频全 video；
        // 即梦同时带视频（seedance）与图片（seedream）模型。
        func expectAll(_ providerID: String, _ capability: NodeCapability) {
            let provider = ModelCatalog.cloudProviders.first { $0.id == providerID }
            #expect(provider != nil, "目录缺少 \(providerID)")
            #expect(provider?.entries.allSatisfy { $0.capability == capability } == true,
                    "\(providerID) 模型能力应为 \(capability)")
        }
        for llmID in ["bailian", "openai", "claude", "deepseek"] { expectAll(llmID, .llm) }
        expectAll("gimage2", .image)
        expectAll("kling", .video)
        // 即梦：seedance 系列 = video，seedream = image
        let jimeng = ModelCatalog.cloudProviders.first { $0.id == "jimeng" }
        #expect(jimeng?.entries.contains { $0.id == "seedance-v2" && $0.capability == .video } == true)
        #expect(jimeng?.entries.contains { $0.id == "seedream-v2" && $0.capability == .image } == true)
    }

    @Test func localProvidersRenderOfflineWithoutProbe() {
        // Ollama 未部署：默认离线 → 本地组无模型（面板显示"未检测到本地后端"）
        let llmLocal = ModelCatalog.localProviders(capability: .llm)
        #expect(llmLocal.contains { $0.id == "ollama" })
        #expect(llmLocal.first { $0.id == "ollama" }?.entries.isEmpty == true)

        let imageLocal = ModelCatalog.localProviders(capability: .image)
        #expect(imageLocal.contains { $0.id == "comfyui-local" })
        #expect(imageLocal.contains { $0.id == "stable-diffusion-local" })

        let videoLocal = ModelCatalog.localProviders(capability: .video)
        #expect(videoLocal.contains { $0.id == "wan-local" })

        // 探测接入后：ollama 在线 → 真实模型名进列表
        let online = ModelCatalog.localProviders(
            status: ["ollama": true], ollamaModels: ["glm-5.2", "llama3.2"], capability: .llm
        )
        let ollama = online.first { $0.id == "ollama" }
        #expect(ollama?.entries.map(\.id) == ["glm-5.2", "llama3.2"])
    }

    @Test func capabilityFiltersCloudGroup() {
        // 生图节点：云端组只保留 image 能力模型
        let imageEntries = ModelCatalog.resolvedCloudProviders
            .flatMap { $0.entries.filter { $0.capability == .image } }
        #expect(imageEntries.contains { $0.id == "gpt-image-2-official" })
        #expect(imageEntries.contains { $0.id == "seedream-v2" })
        #expect(!imageEntries.contains { $0.id == "gpt-5.5" })

        // 生视频节点：只保留 video 能力模型
        let videoEntries = ModelCatalog.resolvedCloudProviders
            .flatMap { $0.entries.filter { $0.capability == .video } }
        #expect(videoEntries.contains { $0.id == "kling-v2" })
        #expect(!videoEntries.contains { $0.id == "deepseek-v3" })
    }

    // MARK: 徽标短名

    @Test func badgeShortNameTruncatesAtDot() {
        // 与 CanvasApp badgeShortName 行为一致：首个 '.' 前片段，再截 12 字符
        #expect(NodeBackendConfig(modelID: "qwen3.8-max-preview").badgeShortName == "qwen3")
        #expect(NodeBackendConfig(modelID: "gpt-image-2-official").badgeShortName == "gpt-image-2-")
        #expect(NodeBackendConfig(modelID: "kling-v2").badgeShortName == "kling-v2")
        #expect(NodeBackendConfig(modelID: "").badgeShortName == "默认")
        // 无 '.' 的短模型名完整保留
        #expect(NodeBackendConfig(modelID: "llama3.2").badgeShortName == "llama3")
    }
}

// MARK: - 便捷构造（测试用）

extension NodeBackendConfig {
    init(modelID: String) {
        self.init()
        self.modelID = modelID
    }
}
