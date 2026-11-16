import Testing
import Foundation
import CanvasCore
import MinisCore
@testable import MinisCanvasApp

// MARK: - C 线：生图节点「生图参数」面板写回
//
// 右侧检查器（NodeInspectorView）生图参数面板的控件改动即时写回
// node.backendConfig。写回逻辑抽成 NodeInspectorView 静态纯函数
// （applyingParam / applyingModelSelection），生图/生视频面板共用。
// 面板消费的键与执行器一一对应：params["size"]（尺寸）、
// params["negativePrompt"]（负向提示词）→ MinisCanvasImageInvoker.makeImageRequest
// → CloudImageRequest —— 只使用执行链路真实存在的键，不发明新键。

@Suite("生图参数面板写回")
@MainActor
struct NodeInspectorImageParamsTests {

    // MARK: 参数写回辅助（纯函数，面板 binding 的底层）

    @Test func applyingParamWritesSizeIntoConfig() {
        let config = NodeInspectorView.applyingParam("size", "1024x1024", to: nil)
        #expect(config.params["size"] == "1024x1024")
        #expect(config.modelID == "", "仅写 params，不动模型字段")
    }

    @Test func applyingModelSelectionWritesModelAndKeepsParams() {
        var config = NodeInspectorView.applyingParam("size", "1024x1024", to: nil)
        config = NodeInspectorView.applyingModelSelection(
            to: config, modelID: "gpt-image-2-official",
            providerID: "gimage2", providerType: .cloud
        )
        #expect(config.modelID == "gpt-image-2-official")
        #expect(config.providerID == "gimage2")
        #expect(config.providerType == .cloud)
        #expect(config.params["size"] == "1024x1024", "模型选择写回不得清掉已有 params")
    }

    @Test func applyingModelSelectionEmptyClearsModelOnly() {
        var config = NodeInspectorView.applyingParam("size", "1536x1024", to: nil)
        config = NodeInspectorView.applyingModelSelection(
            to: config, modelID: "gpt-image-2-official",
            providerID: "gimage2", providerType: .cloud
        )
        // 「未配置」→ 清空模型，保留 params
        config = NodeInspectorView.applyingModelSelection(
            to: config, modelID: "", providerID: "", providerType: .cloud
        )
        #expect(config.modelID == "")
        #expect(config.providerID == "")
        #expect(config.params["size"] == "1536x1024", "清空模型不得清掉 params")
    }

    @Test func applyingModelSelectionRejectsPartialSelection() {
        let config = NodeInspectorView.applyingModelSelection(
            to: nil, modelID: "seedream-v2", providerID: "   ", providerType: .cloud
        )
        #expect(config.modelID == "")
        #expect(config.providerID == "")
    }

    // MARK: 面板 → store 全链路（模拟右侧面板设置 size/model 后写回）

    @Test func panelWriteBackPersistsToStore() {
        let store = CanvasStore()
        guard let node = store.addNode(ofType: ManjuNodeType.imageGen.rawValue) else {
            Issue.record("imageGen 节点创建失败")
            return
        }
        // 模拟面板控件操作：尺寸 Picker 选 16:9 → applyingParam；模型 Picker 选 gimage2 → applyingModelSelection
        var config = NodeInspectorView.applyingParam("size", "1792x1024", to: node.backendConfig)
        config = NodeInspectorView.applyingModelSelection(
            to: config, modelID: "gpt-image-2-official",
            providerID: "gimage2", providerType: .cloud
        )
        store.updateBackendConfig(config, for: node.id)

        let updated = store.graph.node(id: node.id)
        #expect(updated?.backendConfig?.params["size"] == "1792x1024")
        #expect(updated?.backendConfig?.modelID == "gpt-image-2-official")
        #expect(updated?.backendConfig?.providerID == "gimage2")
        #expect(updated?.backendConfig?.providerType == .cloud)
    }

    // MARK: 执行器消费：面板键真正进入 Provider 请求

    @Test func makeImageRequestPassesPanelKeys() {
        let backend = NodeBackendConfig(
            providerType: .cloud, providerID: "gimage2", modelID: "gpt-image-2-official",
            params: ["size": "1024x1024", "negativePrompt": "低清, 水印"]
        )
        let request = MinisCanvasImageInvoker.makeImageRequest(
            prompt: "赛博朋克街景", referenceImage: nil, backend: backend
        )
        #expect(request.size == "1024x1024")
        #expect(request.negativePrompt == "低清, 水印")
    }

    @Test func makeImageRequestNormalizesEmptyNegativePrompt() {
        let backend = NodeBackendConfig(
            providerType: .cloud, providerID: "gimage2", modelID: "",
            params: ["negativePrompt": "   "]
        )
        let request = MinisCanvasImageInvoker.makeImageRequest(
            prompt: "赛博朋克街景", referenceImage: nil, backend: backend
        )
        #expect(request.negativePrompt == nil, "空白负向提示词视为未设置")

        // 归一化辅助
        #expect(MinisCanvasImageInvoker.normalizedOptionalText(nil) == nil)
        #expect(MinisCanvasImageInvoker.normalizedOptionalText("") == nil)
        #expect(MinisCanvasImageInvoker.normalizedOptionalText("   ") == nil)
        #expect(MinisCanvasImageInvoker.normalizedOptionalText("  a  ") == "a")
    }
}
