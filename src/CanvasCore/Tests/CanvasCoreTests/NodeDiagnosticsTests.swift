import Foundation
import Testing
@testable import CanvasCore

// MARK: - 测试辅助

/// 固定输出的 mock LLM 调用器
private struct MockLLMInvoker: LLMInvoker {
    let output: String
    func invoke(prompt: String, backend: NodeBackendConfig) async throws -> String {
        output
    }
}

/// 固定建议的 mock 修复提供方
private struct MockRepairProvider: AgentRepairProvider {
    let suggestion: RepairSuggestion
    func repair(diagnostic: NodeDiagnosticContext) async throws -> RepairSuggestion {
        suggestion
    }
}

/// 记录诊断上下文的 mock 提供方（final class：引用语义，断言桥正确传参）
private final class CapturingRepairProvider: AgentRepairProvider, @unchecked Sendable {
    let suggestion: RepairSuggestion
    var captured: NodeDiagnosticContext?
    init(suggestion: RepairSuggestion) {
        self.suggestion = suggestion
    }
    func repair(diagnostic: NodeDiagnosticContext) async throws -> RepairSuggestion {
        captured = diagnostic
        return suggestion
    }
}

/// 始终失败的执行上下文（模拟无修复桥的节点失败路径）
private struct AlwaysFailingContext: NodeExecutionContext {
    func resolveInputs(
        for node: CanvasNode,
        in graph: NodeGraph,
        outputs: @escaping (CanvasNode.ID) -> [String: AnyHashable]?
    ) throws -> [String: AnyHashable]? {
        nil
    }

    func execute(node: CanvasNode, inputs: [String: AnyHashable]?) throws -> [String: AnyHashable] {
        throw NodeExecutorsError.llmInvocationFailed("mock 调用失败")
    }
}

// MARK: - NodeDiagnostics 测试

struct NodeDiagnosticsTests {

    // MARK: 上下文收集

    @Test func collectDiagnosticCarriesNodeInfo() {
        let node = CanvasNode(
            type: "llm", title: "分镜生成",
            backendConfig: NodeBackendConfig(providerID: "bailian", modelID: "qwen3.8-max")
        )
        let error = NodeExecutorsError.missingLLMInvoker("llm")

        let ctx = NodeDiagnostics.collectDiagnostic(
            from: node, error: error, inputs: nil
        )

        #expect(ctx.nodeID == node.id)
        #expect(ctx.nodeType == "llm")
        #expect(ctx.nodeTitle == "分镜生成")
        #expect(ctx.errorDescription.contains("未注入 LLMInvoker"))
        #expect(ctx.inputs.isEmpty)
        #expect(ctx.upstreamOutputKeys.isEmpty)
    }

    @Test func collectDiagnosticSanitizesSensitiveInputs() {
        let node = CanvasNode(type: "imageGen", title: "生图")
        let inputs: [String: AnyHashable] = [
            "prompt": "赛博朋克街道",
            "apiKey": "sk-1234567890",
            "secret_token": "abc",
            "password": "hunter2",
            "negativePrompt": "模糊",
            "authorization": "Bearer xyz",
        ]

        let ctx = NodeDiagnostics.collectDiagnostic(
            from: node, error: NodeExecutorsError.unknownNodeType("imageGen"),
            inputs: inputs
        )

        #expect(ctx.inputs["prompt"] == "赛博朋克街道")
        #expect(ctx.inputs["negativePrompt"] == "模糊")
        // 敏感字段必须剔除
        #expect(ctx.inputs["apiKey"] == nil)
        #expect(ctx.inputs["secret_token"] == nil)
        #expect(ctx.inputs["password"] == nil)
        #expect(ctx.inputs["authorization"] == nil)
    }

    @Test func collectDiagnosticDescribesAndTruncatesValues() {
        let node = CanvasNode(type: "text", title: "长文本")
        let long = String(repeating: "字", count: 2000)
        let inputs: [String: AnyHashable] = [
            "count": 42,
            "ok": true,
            "longText": long,
        ]

        let ctx = NodeDiagnostics.collectDiagnostic(
            from: node, error: NodeExecutorsError.unknownNodeType("text"),
            inputs: inputs
        )

        #expect(ctx.inputs["count"] == "42")
        #expect(ctx.inputs["ok"] == "true")
        #expect(ctx.inputs["longText"]?.contains("已截断") == true)
        #expect((ctx.inputs["longText"]?.count ?? 0) < 2000)
    }

    @Test func collectDiagnosticSortsUpstreamKeys() {
        let node = CanvasNode(type: "llm", title: "下游")
        let ctx = NodeDiagnostics.collectDiagnostic(
            from: node,
            error: NodeExecutorsError.llmInvocationFailed("boom"),
            inputs: nil,
            upstreamOutputKeys: ["zeta", "alpha", "mid"]
        )
        #expect(ctx.upstreamOutputKeys == ["alpha", "mid", "zeta"])
    }

    @Test func isSensitiveKeyMatchesCaseInsensitively() {
        #expect(NodeDiagnostics.isSensitiveKey("apiKey"))
        #expect(NodeDiagnostics.isSensitiveKey("API_KEY"))
        #expect(NodeDiagnostics.isSensitiveKey("mySecret"))
        #expect(NodeDiagnostics.isSensitiveKey("access_token"))
        #expect(!NodeDiagnostics.isSensitiveKey("prompt"))
        #expect(!NodeDiagnostics.isSensitiveKey("negativePrompt"))
    }

    // MARK: AgentRepairBridge

    @Test func bridgeWithMockProviderReturnsSuggestion() async throws {
        let node = CanvasNode(type: "llm", title: "脚本")
        let expected = RepairSuggestion(
            suggestedFix: "注入 LLMInvoker",
            confidence: 0.95,
            updatedParams: ["providerID": "bailian"],
            explanation: "缺少调用器"
        )
        let provider = CapturingRepairProvider(suggestion: expected)

        let suggestion = try await AgentRepairBridge.diagnoseAndRepair(
            node: node,
            error: NodeExecutorsError.missingLLMInvoker("llm"),
            inputs: ["prompt": "开场", "apiKey": "sk-leak"],
            provider: provider
        )

        #expect(suggestion == expected)
        // 桥必须把脱敏后的上下文传给 provider（apiKey 不进入）
        #expect(provider.captured?.nodeID == node.id)
        #expect(provider.captured?.inputs["prompt"] == "开场")
        #expect(provider.captured?.inputs["apiKey"] == nil)
    }

    @Test func bridgeWithContextProviderForm() async throws {
        let ctx = NodeDiagnostics.collectDiagnostic(
            nodeID: UUID(),
            nodeType: "blenderPreview",
            nodeTitle: "白模",
            error: NodeExecutorsError.blenderInvocationFailed("超时"),
            inputs: ["script": "bpy.ops.mesh.primitive_cube_add()"],
            upstreamOutputKeys: []
        )
        let provider = MockRepairProvider(
            suggestion: RepairSuggestion(suggestedFix: "缩短脚本", confidence: 0.5)
        )

        let suggestion = try await AgentRepairBridge.diagnoseAndRepair(context: ctx, provider: provider)
        #expect(suggestion.suggestedFix == "缩短脚本")
    }

    @Test func bridgeWithNilProviderReturnsNilWithoutCrashing() async {
        // 未配置修复桥（provider == nil）：不崩、不抛，直接返回 nil
        let node = CanvasNode(type: "llm", title: "无桥节点")
        let suggestion = await AgentRepairBridge.diagnoseAndRepairIfAvailable(
            node: node,
            error: NodeExecutorsError.llmInvocationFailed("boom"),
            inputs: ["prompt": "x"],
            provider: nil
        )
        #expect(suggestion == nil)
    }

    @Test func bridgeSwallowsProviderErrorInSafeVariant() async {
        // provider 内部抛错（如 LLM 调用失败）：安全变体吞掉，返回 nil
        struct ThrowingProvider: AgentRepairProvider {
            func repair(diagnostic: NodeDiagnosticContext) async throws -> RepairSuggestion {
                throw NodeExecutorsError.llmInvocationFailed("LLM 挂了")
            }
        }
        let node = CanvasNode(type: "llm", title: "坏 provider")
        let suggestion = await AgentRepairBridge.diagnoseAndRepairIfAvailable(
            node: node,
            error: NodeExecutorsError.llmInvocationFailed("boom"),
            inputs: nil,
            provider: ThrowingProvider()
        )
        #expect(suggestion == nil)
    }

    // MARK: AgentRepairProviderLLM

    @Test func llmProviderParsesJSONSuggestion() async throws {
        let json = #"""
        ```json
        {"suggestedFix": "改用注入的 LLMInvoker", "confidence": 0.9, "updatedParams": {"modelID": "qwen3.8-max"}, "explanation": "缺少调用器"}
        ```
        """#
        let provider = AgentRepairProviderLLM(llmInvoker: MockLLMInvoker(output: json))
        let node = CanvasNode(type: "llm", title: "脚本")

        let suggestion = try await provider.repair(
            diagnostic: NodeDiagnostics.collectDiagnostic(
                from: node,
                error: NodeExecutorsError.missingLLMInvoker("llm"),
                inputs: ["prompt": "开场"]
            )
        )

        #expect(suggestion.suggestedFix == "改用注入的 LLMInvoker")
        #expect(suggestion.confidence == 0.9)
        #expect(suggestion.updatedParams?["modelID"] == "qwen3.8-max")
        #expect(suggestion.explanation == "缺少调用器")
    }

    @Test func llmProviderFallsBackOnUnparseableOutput() async throws {
        let provider = AgentRepairProviderLLM(llmInvoker: MockLLMInvoker(output: "抱歉，我无法解析"))
        let node = CanvasNode(type: "llm", title: "脚本")

        let suggestion = try await provider.repair(
            diagnostic: NodeDiagnostics.collectDiagnostic(
                from: node,
                error: NodeExecutorsError.missingLLMInvoker("llm"),
                inputs: nil
            )
        )

        // fallback：原样文本 + 置信度 0，不丢信息
        #expect(suggestion.suggestedFix == "抱歉，我无法解析")
        #expect(suggestion.confidence == 0)
        #expect(suggestion.updatedParams == nil)
    }

    @Test func llmProviderPromptContainsDiagnosticInfo() {
        let node = CanvasNode(type: "imageGen", title: "生图")
        let ctx = NodeDiagnostics.collectDiagnostic(
            from: node,
            error: NodeExecutorsError.unknownNodeType("imageGen"),
            inputs: ["prompt": "赛博朋克街道"],
            upstreamOutputKeys: ["分镜文本"]
        )

        let prompt = AgentRepairProviderLLM.buildSystemPrompt(diagnostic: ctx)

        #expect(prompt.contains("imageGen"))
        #expect(prompt.contains("生图"))
        #expect(prompt.contains("未知节点类型"))
        #expect(prompt.contains("prompt: 赛博朋克街道"))
        #expect(prompt.contains("分镜文本"))
    }

    @Test func parseSuggestionToleratesSurroundingNoise() {
        let noisy = "好的，以下是建议：\n{\"suggestedFix\": \"加个输入\", \"confidence\": 0.6} 完"
        let parsed = AgentRepairProviderLLM.parseSuggestion(from: noisy)
        #expect(parsed?.suggestedFix == "加个输入")
        #expect(parsed?.confidence == 0.6)
        #expect(parsed?.updatedParams == nil)
        #expect(parsed?.explanation == "")
    }

    // MARK: 无桥场景（调度层）

    @Test func dagFailureWithoutRepairBridgeStillPropagates() {
        // 不接任何修复桥：节点失败 → failed，下游 skipped，调度不崩
        let a = CanvasNode(type: "llm", title: "A")
        let b = CanvasNode(type: "llm", title: "B")
        let pOut = Port(name: "out", direction: .output, dataType: "text")
        let pIn = Port(name: "in", direction: .input, dataType: "text")
        var graph = NodeGraph()
        graph.addNode(a)
        graph.addNode(b)
        graph.addEdge(Edge(fromNode: a.id, fromPort: pOut.id, toNode: b.id, toPort: pIn.id))

        var scheduler = DAGScheduler()
        let result = try? scheduler.run(graph: graph, context: AlwaysFailingContext())

        #expect(result?.status(of: a.id) == .failed)
        #expect(result?.status(of: b.id) == .skipped)
    }
}
