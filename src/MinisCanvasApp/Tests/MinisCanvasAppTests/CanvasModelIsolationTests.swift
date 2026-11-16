import Testing
import Foundation
import CanvasCore
import MinisCore
@testable import MinisCanvasApp

@Suite("P1 画布 invoker 模型隔离", .serialized)
struct CanvasModelIsolationTests {

    @Test func canvasInvokerRejectsEmptyModelInsteadOfUsingGlobalDefault() async {
        TestEnvIsolation.hermeticize()
        let backend = NodeBackendConfig(
            providerType: .cloud, providerID: "bailian", modelID: ""
        )

        do {
            _ = try await MinisCanvasLLMInvoker().invoke(
                prompt: "不能触发真实调用",
                backend: backend
            )
            Issue.record("画布 invoker 不得从全局默认模型补齐空 modelID")
        } catch let error as LLMError {
            #expect(
                error.localizedDescription.contains("modelID"),
                "应明确指出画布节点缺少 modelID，而不是进入无 key/默认模型路径"
            )
        } catch {
            Issue.record("应抛 LLMError，实际为 \(error)")
        }
    }
}
