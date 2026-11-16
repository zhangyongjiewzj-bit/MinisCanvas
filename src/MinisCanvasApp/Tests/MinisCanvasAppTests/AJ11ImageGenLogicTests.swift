import Testing
import Foundation
@testable import MinisCanvasApp
import CanvasCore
import MinisCore

// MARK: - AJ-11：生图功能逻辑完善（参数传透 / 参考图 img2img / 结果回填）
//
// 覆盖 AJ-11 三项核心逻辑：
// 1. App 层 NodeTypeRegistry 的 imageGen spec 补齐 U-2 端口（prompt + image 输入端口）
// 2. 生图参数传透：MinisCanvasImageInvoker.makeImageRequest 把 提示词/尺寸/模型/参考图
//    真正组装进 CloudImageRequest（参考图经 imageURL 透传，U-2 图生图语义）
// 3. Gimage2Provider 请求体把参考图（img2img）并入 payload（image 字段）
// 4. 结果回填路径：imageGen 节点输出 status=succeeded + image 路径 → syncGeneratedResults
//    写回 backendConfig.params[result.path/kind/name]（与「导入结果」键约定一致）

@Suite("AJ-11 生图功能逻辑完善", .serialized)
@MainActor
struct AJ11ImageGenLogicTests {

    init() {
        TestEnvIsolation.hermeticize()
    }

    // MARK: - 1) imageGen spec 对齐 U-2 端口

    @Test func imageGenSpecHasImageInputPort() {
        let spec = NodeTypeRegistry.spec(for: ManjuNodeType.imageGen.rawValue)
        #expect(spec != nil, "imageGen 应有注册表规格")
        let inputNames = spec?.inputs.map(\.name) ?? []
        #expect(inputNames.contains("prompt"), "imageGen 应有 prompt 输入端口")
        #expect(inputNames.contains("image"), "imageGen 应有 image 输入端口（图生图参考图，U-2）")
        #expect(spec?.outputs.map(\.name) == ["image"])
        // 默认后端仍为 gimage2 / 1024x1024
        #expect(spec?.defaultBackendConfig?.providerID == "gimage2")
        #expect(spec?.defaultBackendConfig?.params["size"] == "1024x1024")
    }

    @Test func makeImageNodeBuiltFromSpecHasImagePort() {
        let spec = NodeTypeRegistry.spec(for: ManjuNodeType.imageGen.rawValue)
        let node = spec?.makeNode()
        #expect(node?.inputs.map(\.name) == ["prompt", "image"], "imageGen 新建节点应含 prompt + image 输入端口")
    }

    // MARK: - 2) 参数传透：makeImageRequest

    @Test func makeImageRequestPassesReferenceImage() {
        let backend = NodeBackendConfig(
            providerType: .cloud, providerID: "gimage2", modelID: "gpt-image-2-official",
            params: ["size": "1024x1024"]
        )
        let request = MinisCanvasImageInvoker.makeImageRequest(
            prompt: "青崖观夜景，伪仙写实",
            referenceImage: "/tmp/ref_first_frame.png",
            backend: backend
        )
        #expect(request.prompt == "青崖观夜景，伪仙写实")
        #expect(request.imageURL == "/tmp/ref_first_frame.png",
                "参考图必须透传到 CloudImageRequest.imageURL（img2img）")
        #expect(request.size == "1024x1024", "size 参数必须透传")
        #expect(request.modelOverride == "gpt-image-2",
                "节点未配模型或占位模型时兜底 GIMAGE2_MODEL_G2（默认 gpt-image-2）")
    }

    @Test func makeImageRequestNilReferenceIsTxt2Img() {
        let request = MinisCanvasImageInvoker.makeImageRequest(
            prompt: "文生图", referenceImage: nil, backend: nil
        )
        #expect(request.imageURL == nil, "无参考图 = 纯文生图（imageURL 为 nil）")
    }

    @Test func normalizedReferenceImageTrimsWhitespace() {
        #expect(MinisCanvasImageInvoker.normalizedReferenceImage("  /tmp/a.png  ") == "/tmp/a.png")
        #expect(MinisCanvasImageInvoker.normalizedReferenceImage("   ") == nil, "空白视为未传入")
        #expect(MinisCanvasImageInvoker.normalizedReferenceImage("") == nil)
        #expect(MinisCanvasImageInvoker.normalizedReferenceImage(nil) == nil)
    }

    @Test func makeImageRequestModelOverrideRespectsCustomModel() {
        let backend = NodeBackendConfig(
            providerType: .cloud, providerID: "gimage2", modelID: "my-custom-image-model",
            params: [:]
        )
        let request = MinisCanvasImageInvoker.makeImageRequest(
            prompt: "p", referenceImage: nil, backend: backend
        )
        #expect(request.modelOverride == "my-custom-image-model",
                "节点配置了非占位模型时必须透传节点模型")
    }

    // MARK: - 3) Gimage2Provider 请求体并入参考图（已由 MinisCore CloudBackendProvidersTests 覆盖，
    //    此处因跨模块访问 internal buildRequestBody 编译受限，不重复断言）

    // MARK: - 4) 结果回填（由 P0-1 RunEnvelopeTests + store.finishRun 覆盖，此处不再重复）
    // 注：结果回填路径（imageGen 输出 → backendConfig.params[result.path/kind/name]）
    // 已由 RunEnvelopeTests 验证，且依赖 isRunning/envelope 状态机，此处不重复断言。
}