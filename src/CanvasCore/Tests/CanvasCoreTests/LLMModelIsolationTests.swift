import Testing
import Foundation
@testable import CanvasCore

// MARK: - P1 画布模型隔离：LLM 必须使用节点级完整配置

@Suite("P1 画布模型 fail-closed")
struct LLMModelIsolationTests {

    private struct ReturningLLMInvoker: LLMInvoker {
        func invoke(prompt: String, backend: NodeBackendConfig) async throws -> String {
            "不应在缺少节点模型配置时调用"
        }
    }

    private func makeLLMNode() -> CanvasNode {
        CanvasNode(type: "llm", title: "LLM")
    }

    private func expectRejected(
        backend: NodeBackendConfig?,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        do {
            _ = try await LLMNodeExecutor(llmInvoker: ReturningLLMInvoker()).execute(
                node: makeLLMNode(),
                inputs: ["text": AnyHashable("输入")],
                backend: backend
            )
            Issue.record("缺少完整节点模型配置时必须拒绝执行", sourceLocation: sourceLocation)
        } catch let error as NodeExecutorsError {
            #expect(
                error.localizedDescription.contains("模型配置"),
                "应报告节点模型配置错误，而不是调用全局默认模型",
                sourceLocation: sourceLocation
            )
        } catch {
            Issue.record("应抛 NodeExecutorsError，实际为 \(error)", sourceLocation: sourceLocation)
        }
    }

    @Test func nilBackendIsRejectedBeforeInvocation() async {
        await expectRejected(backend: nil)
    }

    @Test func emptyProviderIsRejectedBeforeInvocation() async {
        await expectRejected(
            backend: NodeBackendConfig(providerID: "", modelID: "qwen3.8-max-preview")
        )
    }

    @Test func emptyModelIsRejectedBeforeInvocation() async {
        await expectRejected(
            backend: NodeBackendConfig(providerID: "bailian", modelID: "")
        )
    }

    @Test func localQCStillExecutesWithoutModelConfiguration() async throws {
        let node = CanvasNode(type: ManjuNodeType.qcCheck.rawValue, title: "QC")
        let executor = try #require(
            NodeExecutors(llmInvoker: nil).executor(for: ManjuNodeType.qcCheck.rawValue)
        )
        let output = try await executor.execute(
            node: node,
            inputs: ["text": AnyHashable("没有槽位结构的本地 QC 输入")],
            backend: nil
        )

        #expect(output["status"] as? String == "FAIL")
        #expect((output["report"] as? String)?.isEmpty == false)
    }
}
