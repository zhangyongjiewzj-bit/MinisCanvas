import Foundation
import CanvasCore
import MinisCore

/// 画布 Blender 白模渲染的真实调用实现（M3b）。
///
/// 实现 CanvasCore 的 `BlenderRenderInvoker` 注入点，直连 MinisCore `BlenderBridge`：
/// `blender -b -P <script>` 后台渲染，返回生成的 PNG 路径列表。
/// Blender 未安装 / 渲染失败 / 超时 / 无输出等错误由 BlenderBridge 抛出并透传。
public struct CanvasBlenderInvoker: BlenderRenderInvoker {

    public init() {}

    public func render(
        script: String,
        outputDir: String,
        frameRange: (Int, Int)?
    ) async throws -> [String] {
        try await BlenderBridge.renderWhitemodel(
            script: script,
            outputDir: outputDir,
            frameRange: frameRange
        )
    }
}
