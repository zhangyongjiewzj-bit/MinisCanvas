import Testing
@testable import CanvasCore

// MARK: - F10 P0-02：一键流水线的节点必须带有效默认 backendConfig
//
// 修复前（issues/UX_CODEX_MANJU_UI_TEST_20260804_011641.md §P0-02）：
// ManjuPipelineTemplate.makeNode 不写 backendConfig → LLM 节点 providerID 为空 →
// MinisCanvasLLMInvoker 走「未接入 Provider」占位引导，一键流水线执行不出真实结果。
// 修复后：LLM 节点默认 bailian/qwen3.8-max-preview（MinisCore 内置 DashScope 模型表首项），
// 生图 gimage2/gpt-image-2-official，生视频 kling/kling-v2。

@Suite("F10 P0-02 流水线默认后端配置")
struct F10PipelineBackendDefaultsTests {

    private func firstNode(of type: ManjuNodeType, in graph: NodeGraph) -> CanvasNode? {
        graph.nodes.first { $0.type == type.rawValue }
    }

    /// 流水线生成的全部 LLM 节点 backendConfig 非空、providerID/modelID 非空且为有效内置项
    @Test func llmNodesHaveUsableDefaultBackend() throws {
        let graph = ManjuPipelineTemplate.makeManjuPipeline(assets: .demo)
        let llmTypes: [ManjuNodeType] = [
            .novelImport, .plotOutline, .script, .storyboard,
            .imagePrompt, .videoPrompt, .qcCheck,
        ]
        for type in llmTypes {
            let node = try #require(firstNode(of: type, in: graph), "缺少节点 \(type.rawValue)")
            let config = try #require(node.backendConfig, "\(type.rawValue) 应带 backendConfig")
            #expect(!config.providerID.isEmpty, "\(type.rawValue) providerID 不应为空")
            #expect(!config.modelID.isEmpty, "\(type.rawValue) modelID 不应为空")
            #expect(config.providerType == .cloud)
            // 有效内置项：百炼 DashScope 内置模型表首项（MinisCore LLMModel.qwen38MaxPreview）
            #expect(config.providerID == "bailian", "\(type.rawValue) 默认应走 bailian")
            #expect(config.modelID == "qwen3.8-max-preview",
                    "\(type.rawValue) 默认模型应为内置可用的 qwen3.8-max-preview")
        }
    }

    /// 生图/生视频节点带对应媒体后端（不是 LLM 配置）
    @Test func mediaNodesHaveMediaBackend() throws {
        let graph = ManjuPipelineTemplate.makeManjuPipeline(assets: .demo)

        let imageGen = try #require(firstNode(of: .imageGen, in: graph)?.backendConfig)
        #expect(imageGen.providerID == "gimage2")
        #expect(!imageGen.modelID.isEmpty)

        let videoGen = try #require(firstNode(of: .videoGen, in: graph)?.backendConfig)
        #expect(videoGen.providerID == "kling")
        #expect(!videoGen.modelID.isEmpty)
        // P0-05 联动：默认参数带时长/分辨率（UI 选择器格式），执行层归一化后透传 Provider
        #expect(videoGen.params["duration"] != nil)
        #expect(videoGen.params["resolution"] != nil)
    }

    /// 系统提示词注入不覆盖默认 provider/model（params 合并而非整体替换）
    @Test func systemPromptInjectionKeepsDefaultBackend() throws {
        let graph = ManjuPipelineTemplate.makeManjuPipeline(assets: .demo)
        let script = try #require(firstNode(of: .script, in: graph))
        let config = try #require(script.backendConfig)
        #expect(config.params[ManjuPipelineTemplate.systemPromptKey] != nil,
                "系统提示词应仍然注入")
        #expect(config.providerID == "bailian", "注入提示词后 providerID 不应丢失")
        #expect(config.modelID == "qwen3.8-max-preview", "注入提示词后 modelID 不应丢失")
    }

    /// defaultBackendConfig(for:) 路由表：LLM 类 → bailian，媒体类 → 对应后端，
    /// blenderPreview/assetRef 不依赖模型后端（nil）
    @Test func defaultBackendConfigRoutingTable() {
        #expect(ManjuPipelineTemplate.defaultBackendConfig(for: .blenderPreview) == nil)
        #expect(ManjuPipelineTemplate.defaultBackendConfig(for: .assetRef) == nil)
        for type in ManjuNodeType.allCases {
            guard let config = ManjuPipelineTemplate.defaultBackendConfig(for: type) else { continue }
            #expect(!config.providerID.isEmpty, "\(type.rawValue) 默认配置 providerID 不应为空")
            #expect(!config.modelID.isEmpty, "\(type.rawValue) 默认配置 modelID 不应为空")
        }
    }
}
