import Testing
import Foundation
import CanvasCore
import MinisCore
@testable import MinisCanvasApp

// MARK: - U2-r 节点级模型对话窗口测试
//
// 覆盖：nodeChats 隔离（A 节点对话不影响 B、也不碰 agent 的 ChatStore）、
// 发送走该节点 backendConfig 的 provider/model（mock 注入）、
// 无 key / 无 provider 的友好提示（LLMError friendlyMessage 路径）。

@Suite("U2-r 节点级模型对话", .serialized)
@MainActor
struct NodeChatTests {

    /// 记录每次调用的 backend 与历史消息；可注入回复/错误/状态。
    /// （协议为 @MainActor 隔离，mock 同为主线程驱动，无需锁。）
    @MainActor
    final class MockNodeChatClient: NodeChatLLMClient {
        private(set) var calls: [(messages: [NodeChatMessage], backend: NodeBackendConfig?)] = []
        var replyText = "模拟回复"
        var errorToThrow: Error?
        var status: NodeChatConfigStatus = .ready

        func send(messages: [NodeChatMessage], backend: NodeBackendConfig?) async throws -> String {
            calls.append((messages, backend))
            if let errorToThrow { throw errorToThrow }
            return replyText
        }

        func configurationStatus(backend: NodeBackendConfig?) -> NodeChatConfigStatus {
            status
        }
    }

    // MARK: 历史隔离

    @Test func nodeChatsAreIsolatedPerNode() async {
        let client = MockNodeChatClient()
        let store = NodeChatStore(client: client)
        let nodeA = UUID()
        let nodeB = UUID()

        client.replyText = "A 的回复"
        await store.sendNodeChat(nodeID: nodeA, message: "你好 A", backend: nil)
        #expect(store.messages(for: nodeA).count == 2)
        #expect(store.messages(for: nodeA).last?.role == .assistant)
        #expect(store.messages(for: nodeA).last?.content == "A 的回复")
        // B 节点历史为空（A 的对话不污染 B）
        #expect(store.messages(for: nodeB).isEmpty)

        client.replyText = "B 的回复"
        await store.sendNodeChat(nodeID: nodeB, message: "你好 B", backend: nil)
        #expect(store.messages(for: nodeB).count == 2)
        #expect(store.messages(for: nodeB).last?.content == "B 的回复")
        // A 节点历史不受 B 影响
        #expect(store.messages(for: nodeA).count == 2)
        #expect(store.messages(for: nodeA).last?.content == "A 的回复")
    }

    @Test func nodeChatIsolatedFromAgentChatStore() async {
        let client = MockNodeChatClient()
        let nodeChat = NodeChatStore(client: client)
        let agentChat = ChatStore()
        let node = UUID()
        // 新 ChatStore 自带 1 条欢迎语（init 注入），作为 agent 历史基线
        let agentBaseline = agentChat.messages.count

        await nodeChat.sendNodeChat(nodeID: node, message: "你好节点", backend: nil)

        // agent 聊天完全不受节点对话影响（不同 store / 不同历史）
        #expect(nodeChat.messages(for: node).count == 2)
        #expect(agentChat.messages.count == agentBaseline)
        #expect(agentChat.messages.allSatisfy { $0.content != "你好节点" })
    }

    @Test func clearHistoryOnlyAffectsTargetNode() async {
        let client = MockNodeChatClient()
        let store = NodeChatStore(client: client)
        let nodeA = UUID()
        let nodeB = UUID()

        await store.sendNodeChat(nodeID: nodeA, message: "hi", backend: nil)
        await store.sendNodeChat(nodeID: nodeB, message: "hi", backend: nil)
        store.clearHistory(nodeID: nodeA)

        #expect(store.messages(for: nodeA).isEmpty)
        #expect(store.messages(for: nodeB).count == 2)
    }

    // MARK: 发送走该节点 backendConfig 的 provider/model

    @Test func sendRoutesNodeBackendProviderAndModel() async {
        let client = MockNodeChatClient()
        let store = NodeChatStore(client: client)
        let nodeA = UUID()
        let nodeB = UUID()
        let backendA = NodeBackendConfig(
            providerType: .cloud, providerID: "bailian",
            modelID: "qwen3.8-max-preview", params: ["maxTokens": "512"]
        )
        let backendB = NodeBackendConfig(
            providerType: .cloud, providerID: "openai", modelID: "gpt-5.4"
        )

        await store.sendNodeChat(nodeID: nodeA, message: "你好", backend: backendA)
        await store.sendNodeChat(nodeID: nodeB, message: "你好", backend: backendB)

        #expect(client.calls.count == 2)
        // 每个节点用自己的 provider/model
        #expect(client.calls[0].backend == backendA)
        #expect(client.calls[1].backend == backendB)
    }

    @Test func multiTurnSendsFullNodeHistory() async {
        let client = MockNodeChatClient()
        let store = NodeChatStore(client: client)
        let node = UUID()
        let backend = NodeBackendConfig(providerType: .cloud, providerID: "bailian", modelID: "qwen3.8-max-preview")

        await store.sendNodeChat(nodeID: node, message: "第一问", backend: backend)
        client.replyText = "第二问回复"
        await store.sendNodeChat(nodeID: node, message: "第二问", backend: backend)

        // 第二次调用携带完整多轮上下文（user → assistant → user）
        #expect(client.calls.count == 2)
        #expect(client.calls[1].messages.map(\.role) == [.user, .assistant, .user])
        #expect(client.calls[1].messages.map(\.content) == ["第一问", "模拟回复", "第二问"])
    }

    @Test func canvasStoreSendResolvesNodeBackend() async {
        let canvas = CanvasStore()
        guard let node = canvas.addNode(ofType: "llm") else {
            Issue.record("llm 节点创建失败")
            return
        }
        let backend = NodeBackendConfig(
            providerType: .cloud, providerID: "deepseek", modelID: "deepseek-v3"
        )
        canvas.updateBackendConfig(backend, for: node.id)

        let client = MockNodeChatClient()
        canvas.nodeChat = NodeChatStore(client: client)

        await canvas.sendNodeChat(nodeID: node.id, message: "你好")

        // CanvasStore 从节点解析 backendConfig 并透传给该节点模型
        #expect(client.calls.count == 1)
        #expect(client.calls.first?.backend == backend)
        #expect(canvas.nodeChat.messages(for: node.id).count == 2)
    }

    @Test func deletingNodeRemovesItsChatHistory() async {
        let canvas = CanvasStore()
        guard let node = canvas.addNode(ofType: "llm") else {
            Issue.record("llm 节点创建失败")
            return
        }
        let client = MockNodeChatClient()
        canvas.nodeChat = NodeChatStore(client: client)

        await canvas.sendNodeChat(nodeID: node.id, message: "你好")
        #expect(canvas.nodeChat.messages(for: node.id).count == 2)

        canvas.removeNode(id: node.id)
        #expect(canvas.nodeChat.messages(for: node.id).isEmpty)
    }

    // MARK: 无 key / 无 provider 提示（LLMError friendlyMessage 路径）

    @Test func noModelShowsSetupHint() async {
        let store = NodeChatStore()
        let node = UUID()

        // 无 backend → 提示先设置模型
        #expect(store.configurationStatus(nodeID: node, backend: nil) == .noModel)
        #expect(NodeChatConfigStatus.noModel.hint == "该节点未配置模型，请先点击节点设置模型")

        await store.sendNodeChat(nodeID: node, message: "你好", backend: nil)
        let last = store.messages(for: node).last
        #expect(last?.role == .assistant)
        #expect(last?.content.contains("该节点未配置模型，请先点击节点设置模型") == true)
    }

    @Test func emptyModelShowsSetupHint() async {
        TestEnvIsolation.hermeticize()
        let store = NodeChatStore()
        let node = UUID()
        let backend = NodeBackendConfig(
            providerType: .cloud, providerID: "bailian", modelID: ""
        )

        #expect(store.configurationStatus(nodeID: node, backend: backend) == .noModel)

        await store.sendNodeChat(nodeID: node, message: "你好", backend: backend)
        let last = store.messages(for: node).last
        #expect(last?.role == .assistant)
        #expect(last?.content.contains(NodeChatConfigStatus.noModel.hint) == true)
    }

    @Test func noKeyShowsFriendlyHint() async {
        // 隔离测试进程：确保 DASHSCOPE/OPENAI/DEEPSEEK key 不存在 → 走无 key 路径
        TestEnvIsolation.hermeticize()
        let store = NodeChatStore()
        let node = UUID()
        let backend = NodeBackendConfig(
            providerType: .cloud, providerID: "bailian", modelID: "qwen3.8-max-preview"
        )

        // 无 key → 配置状态 .noKey（输入框禁用 + 提示）
        #expect(store.configurationStatus(nodeID: node, backend: backend) == .noKey)

        await store.sendNodeChat(nodeID: node, message: "你好", backend: backend)
        let last = store.messages(for: node).last
        #expect(last?.role == .assistant)
        // LLMError friendlyMessage：❌ 前缀 + 中文/英文 API Key 提示
        #expect(last?.content.hasPrefix("❌") == true)
        #expect(last?.content.lowercased().contains("api key") == true)
    }

    @Test func unsupportedProviderShowsHint() async {
        let store = NodeChatStore()
        let node = UUID()
        let backend = NodeBackendConfig(
            providerType: .cloud, providerID: "kling", modelID: "kling-v2"
        )
        #expect(store.configurationStatus(nodeID: node, backend: backend) == .unsupported)
    }

    @Test func inputDraftIsPerNode() async {
        let client = MockNodeChatClient()
        let store = NodeChatStore(client: client)
        let nodeA = UUID()
        let nodeB = UUID()

        store.setInput("草稿 A", for: nodeA)
        store.setInput("草稿 B", for: nodeB)

        #expect(store.input(for: nodeA) == "草稿 A")
        #expect(store.input(for: nodeB) == "草稿 B")

        // 发送后清空该节点草稿，不影响其他节点
        await store.sendNodeChat(nodeID: nodeA, message: store.input(for: nodeA), backend: nil)
        #expect(store.input(for: nodeA).isEmpty)
        #expect(store.input(for: nodeB) == "草稿 B")
    }
}
