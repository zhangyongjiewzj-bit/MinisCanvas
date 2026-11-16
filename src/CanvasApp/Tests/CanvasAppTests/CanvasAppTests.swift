import Foundation
import Testing
import CanvasCore
@testable import CanvasApp

/// CanvasApp 纯逻辑单元测试：JobTicket 槽位解析/任务单构建、NodeTypeRegistry 注册表、LocalBackendKind 元数据。
/// 不涉及 UI/AppKit 运行时，不测试 Ollama 相关功能，不发起网络探测。
///
/// 2026-08-06 迁移说明：本文件原为 XCTest（`import XCTest` + XCTestCase）。
/// CLT-only 工具链（本机 xcode-select 指向 CommandLineTools）没有 XCTest.framework，
/// `import XCTest` 报 "no such module 'XCTest'"，测试无法真实编译；此前 run_tests.sh
/// 显示 OK 是复用了 .build 中的陈旧测试产物（假绿）。Swift Testing（`import Testing`）
/// 随 CLT 提供，是本仓库唯一可运行的测试框架（与 MinisCore 全部测试一致），故迁移。
@Suite("CanvasApp 纯逻辑")
struct CanvasAppTests {

    // MARK: - JobTicket.parseSlots

    @Test func testParseSlotsSplitsImagePromptIntoEightSlots() throws {
        let template = try #require(ManjuPromptTemplates.template(for: .imagePrompt))
        #expect(template.slots.count == 8)

        let text = """
        [TYPE]
        竖版 3:4 角色定妆图

        [REFERENCE]
        参考图：asset://char-01 只继承脸与肤色

        [LAYOUT]
        半身居中，留白向上

        [STRUCTURE]
        粗布直裾，磨损袖口

        [MATERIAL]
        亚麻织纹，微透光

        [COLOR]
        玄青 70 / 月白 20 / 赭金 8 / 朱砂 2

        [LIGHT]
        侧逆光轮廓光

        [FORBID]
        现代鞋、高跟鞋、换脸
        """

        let sections = JobTicket.parseSlots(text, template: template)
        #expect(sections.count == 8)
        #expect(sections.map(\.name) == template.slots.map(\.name))
        #expect(sections.first?.content == "竖版 3:4 角色定妆图")
        let forbid = sections.first { $0.name == "FORBID" }
        #expect(forbid?.content == "现代鞋、高跟鞋、换脸")
    }

    @Test func testParseSlotsIgnoresBracketsNotInTemplate() throws {
        let template = try #require(ManjuPromptTemplates.template(for: .imagePrompt))
        let sections = JobTicket.parseSlots("正文里有 [随意括号] 但没有模板槽位标记", template: template)
        #expect(sections.isEmpty)
    }

    // MARK: - JobTicket.buildPrompt

    @Test func testBuildPromptFillsMissingSlotsWithPlaceholder() throws {
        let template = try #require(ManjuPromptTemplates.template(for: .videoPrompt))
        #expect(template.slots.count == 9)

        let prompt = JobTicket.buildPrompt(from: template, params: ["slot.MODE": "I2V"])
        #expect(prompt.contains("[MODE]\nI2V"))
        #expect(prompt.contains("[ACTION]\n（待填）"))
        // 9 槽结构完整：每个槽位标记都出现
        for slot in template.slots {
            #expect(prompt.contains("[\(slot.name)]"), "缺少槽位标记 \(slot.name)")
        }
    }

    // MARK: - JobTicket.make / suggestedPlatform / extractReferenceIDs

    @Test func testMakeFallbackJobTicketKeepsFullSlotStructure() throws {
        let node = CanvasNode(type: ManjuNodeType.imageGen.rawValue, title: "生图")
        let template = try #require(ManjuPromptTemplates.template(for: .imagePrompt))
        let ticket = JobTicket.make(
            node: node,
            template: template,
            promptText: nil,
            fallbackParams: [
                "slot.TYPE": "竖版 3:4 角色定妆图",
                "slot.FORBID": "现代鞋、高跟鞋",
            ],
            referenceImages: ["asset://char-01"]
        )
        #expect(ticket.isFallback)
        #expect(ticket.nodeType == "imageGen")
        #expect(ticket.nodeTitle == "生图")
        #expect(ticket.slotCount == 8)
        #expect(ticket.slots.count == 8)
        #expect(ticket.forbid == "现代鞋、高跟鞋")
        #expect(ticket.suggestedPlatform == "即梦 Seedream（网页版）")
        #expect(ticket.referenceImages == ["asset://char-01"])
        #expect(ticket.copyableText == ticket.prompt)
        #expect(ticket.markdown.contains("# 生成任务单 · 生图"))
    }

    @Test func testSuggestedPlatformByModelID() {
        #expect(JobTicket.suggestedPlatform(nodeType: "videoGen", modelID: "kling-v2") == "可灵（网页版）")
        #expect(JobTicket.suggestedPlatform(nodeType: "videoGen", modelID: "seedance-1.0") == "即梦 Seedance（网页版）")
        #expect(JobTicket.suggestedPlatform(nodeType: "imageGen", modelID: "seedream-3.0") == "即梦 Seedream（网页版）")
        #expect(JobTicket.suggestedPlatform(nodeType: "imageGen", modelID: nil) == "即梦 Seedream（网页版）")
        #expect(JobTicket.suggestedPlatform(nodeType: "videoGen", modelID: nil) == "即梦 Seedance / 可灵（网页版）")
    }

    @Test func testExtractReferenceIDsDedupes() {
        let text = "定妆图锁脸。参考图：asset://char-01，母图：asset://scene-02，垫图：asset://char-01"
        #expect(
            JobTicket.extractReferenceIDs(from: text) == ["asset://char-01", "asset://scene-02"]
        )
        #expect(JobTicket.extractReferenceIDs(from: "没有参考图的普通文本").isEmpty)
    }

    // MARK: - NodeTypeRegistry

    @Test func testNodeTypeRegistryCoversBasicAndManjuSpecs() {
        #expect(NodeTypeRegistry.basicSpecs.count == 4)
        #expect(NodeTypeRegistry.manjuSpecs.count == ManjuNodeType.allCases.count)
        #expect(NodeTypeRegistry.specs.count == 4 + ManjuNodeType.allCases.count)

        let imageGen = NodeTypeRegistry.spec(for: ManjuNodeType.imageGen.rawValue)
        #expect(imageGen != nil)
        #expect(imageGen?.title == "生图")
        #expect(NodeTypeRegistry.spec(for: "不存在的类型") == nil)

        let node = imageGen?.makeNode(position: Point(x: 10, y: 20))
        #expect(node?.type == "imageGen")
        #expect(node?.position == Point(x: 10, y: 20))
        #expect(node?.backendConfig?.providerID == "gimage2")
    }

    // MARK: - LocalBackendKind（仅纯元数据，不发起网络探测）

    @Test func testLocalBackendKindMetadata() {
        #expect(LocalBackendKind.allCases.count == 4)
        #expect(LocalBackendKind.comfyui.defaultBaseURL == "http://localhost:8188")
        #expect(LocalBackendKind.sdWebUI.defaultBaseURL == "http://localhost:7860")
        #expect(LocalBackendKind.comfyui.probePath == "/system_stats")
        #expect(LocalBackendKind.sdWebUI.probePath == "/sdapi/v1/options")
        #expect(LocalBackendKind.wan.probePath == "/system_stats")
    }
}

// MARK: - I7 P0-2/P0-3：真实注入 + 纯 async 执行链路
//
// 执行链路测试：mock LLMInvoker 返回文本 / 抛错误（确定性、不联网、不测 Ollama）。
// 覆盖：executeAsync 文本输出、失败记录、主线程同步桥不死锁（P0-3 回归）、
// FallbackLLMInvoker 无 key 降级（P0-2）、CanvasStore.runGraph 后台调度 + 主线程回写。

/// 确定性 mock LLM 调用器（LLMInvoker 要求 Sendable，全部存储属性 Sendable）
private struct MockLLMInvoker: LLMInvoker {
    enum MockError: Error, LocalizedError, Sendable {
        case boom
        var errorDescription: String? { "mock LLM 调用失败" }
    }

    let text: String?
    let error: MockError?

    init(text: String? = "mock 回复", error: MockError? = nil) {
        self.text = text
        self.error = error
    }

    func invoke(prompt: String, backend: NodeBackendConfig) async throws -> String {
        if let error { throw error }
        return text ?? ""
    }
}

/// 执行链路 suite 全部测试都在主线程（@MainActor）运行，与 XCTest 时代的
/// `@MainActor final class` 语义一致；suite 内测试因 MainActor 隔离天然串行。
@MainActor
@Suite("CanvasApp 执行链路")
struct CanvasAppExecutionChainTests {

    private func makeContext(invoker: any LLMInvoker) -> GraphExecutionContext {
        GraphExecutionContext(
            executors: NodeExecutors(llmInvoker: invoker),
            imageInvoker: ImageGenInvoker()
        )
    }

    /// 执行链路（async 版）：注入的 invoker 返回文本 → llm 节点输出 text + succeeded
    @Test func testExecuteAsyncLLMNodeReturnsMockText() async throws {
        let context = makeContext(invoker: MockLLMInvoker(text: "你好，画布"))
        let node = CanvasNode(
            type: "llm",
            title: "LLM",
            backendConfig: NodeBackendConfig(providerID: "mock", modelID: "mock-model")
        )
        let output = try await context.executeAsync(node: node, inputs: nil)
        #expect(output["text"] as? String == "你好，画布")
        #expect(output["status"] as? String == "succeeded")
        #expect(context.lastErrors[node.id] == nil, "成功执行后不应残留错误")
    }

    /// 执行链路错误：invoker 抛错 → executeAsync 抛出 + lastErrors 记录（UI 失败提示数据源）
    @Test func testExecuteAsyncLLMNodeFailureRecordsLastError() async {
        let context = makeContext(invoker: MockLLMInvoker(error: .boom))
        let node = CanvasNode(
            type: "llm",
            title: "LLM",
            backendConfig: NodeBackendConfig(providerID: "mock", modelID: "mock-model")
        )
        do {
            _ = try await context.executeAsync(node: node, inputs: nil)
            Issue.record("应抛出 LLM 调用失败错误")
        } catch {
            #expect(context.lastErrors[node.id] != nil, "失败后应记录 lastErrors")
        }
    }

    /// P0-3 回归：同步桥（NodeExecutionContext 协议路径）在主线程调用不死锁。
    /// 桥接用 Task.detached 启动异步工作（不继承 MainActor 隔离）；旧实现 Task {} 必死锁。
    @Test func testSyncExecuteBridgeDoesNotDeadlockOnMainActor() throws {
        let context = makeContext(invoker: MockLLMInvoker(text: "桥接回复"))
        let node = CanvasNode(
            type: "llm",
            title: "LLM",
            backendConfig: NodeBackendConfig(providerID: "mock", modelID: "mock-model")
        )
        // 本 suite 全部 @MainActor：直接在主线程阻塞调用同步协议路径
        let output = try context.execute(node: node, inputs: nil)
        #expect(output["text"] as? String == "桥接回复")
    }

    /// P0-2 无 key 降级：CanvasLLMInvoker 对未接入 provider 抛 unsupportedProvider
    /// → FallbackLLMInvoker 降级占位输出（不联网、不依赖环境变量）
    @Test func testFallbackLLMInvokerDegradesWhenProviderUnsupported() async throws {
        let invoker = FallbackLLMInvoker()
        // gimage2 不在 LLM 端点路由（bailian/ollama/openai）内 → 确定性降级
        let backend = NodeBackendConfig(providerID: "gimage2")
        let text = try await invoker.invoke(prompt: "测试提示词", backend: backend)
        #expect(text.contains("【LLM 待接入】"), "应降级为占位输出，实际：\(text)")
    }

    /// P0-2/P0-3 端到端：CanvasStore.runGraph 后台调度（Task.detached）+ 主线程回写，
    /// mock 文本经 文本→LLM 链路透传；死锁/主线程阻塞会在轮询超时处暴露
    @Test func testCanvasStoreRunGraphWithMockInvoker() async throws {
        let context = makeContext(invoker: MockLLMInvoker(text: "生成的图片路径 /tmp/gen.png"))

        let textNode = CanvasNode(
            type: "text", title: "文本",
            outputs: [Port(name: "text", direction: .output, dataType: "string")]
        )
        let llmNode = CanvasNode(
            type: "llm", title: "LLM",
            inputs: [Port(name: "prompt", direction: .input, dataType: "string")],
            outputs: [Port(name: "text", direction: .output, dataType: "string")],
            backendConfig: NodeBackendConfig(providerID: "mock", modelID: "mock-model")
        )
        let graph = NodeGraph(nodes: [textNode, llmNode], edges: [
            Edge(fromNode: textNode.id, fromPort: textNode.outputs[0].id,
                 toNode: llmNode.id, toPort: llmNode.inputs[0].id)
        ])
        let store = CanvasStore(graph: graph, context: context)
        store.runGraph()

        // 轮询等待后台调度完成（最多 5s；死锁场景会卡满超时 → 断言失败）
        let deadline = Date().addingTimeInterval(5)
        while store.isRunning && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!store.isRunning, "执行应在超时内完成（P0-3：不得阻塞/死锁主线程）")
        #expect(store.graph.node(id: llmNode.id)?.status == .succeeded)
        #expect(
            store.lastResult?.output(of: llmNode.id)?["text"] as? String
                == "生成的图片路径 /tmp/gen.png"
        )
        #expect(store.nodeErrors.isEmpty, "mock 成功链路不应产生节点错误")
    }

    /// P0-3：执行失败经后台调度回写状态（错误信息上屏数据源），主线程不被阻塞
    @Test func testCanvasStoreRunGraphFailureWriteback() async throws {
        let context = makeContext(invoker: MockLLMInvoker(error: .boom))
        let llmNode = CanvasNode(
            type: "llm",
            title: "LLM",
            backendConfig: NodeBackendConfig(providerID: "mock", modelID: "mock-model")
        )
        let store = CanvasStore(graph: NodeGraph(nodes: [llmNode]), context: context)
        store.runGraph()

        let deadline = Date().addingTimeInterval(5)
        while store.isRunning && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!store.isRunning)
        #expect(store.graph.node(id: llmNode.id)?.status == .failed)
        #expect(store.nodeErrors[llmNode.id] != nil, "失败节点错误应回写到 nodeErrors")
    }
}
