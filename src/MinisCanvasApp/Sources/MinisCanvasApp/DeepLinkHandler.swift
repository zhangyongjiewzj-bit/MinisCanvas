import Foundation
import CanvasCore
import MinisCore

// MARK: - E9 深链 / 快捷动作接线
//
// `DeepLinkHandler` 把 `DeepLinkRouter` 解析出的 `DeepLinkAction` 映射到
// App 具体行为（新会话 / 一键流水线 / 设置 / 工作流 / 提示词）。它是
// `DeepLinkRouter.shared` 注册 handler 与命令面板 quickaction 共用的执行路径：
//
//     miniscanvas:// URL ─┐
//     QuickActionStore    ├─► DeepLinkRouter.handle ─► DeepLinkHandler.handle ─► App 动作
//     命令面板 quickaction┘
//
// 断链/失败处理：所有分支都收敛到聊天流提示（system 消息），不抛错不崩溃。

@MainActor
final class DeepLinkHandler {

    /// 打开设置面板（sheet）的回调，由 App 层注入（AJ-61：设置改 .sheet 呈现，
    /// 注入侧置 `isSettingsPresented = true`；工具栏齿轮 / ⌘, / 深链共用此路径）。
    /// 测试可替换为记录闭包。
    var onOpenSettings: ((String?) -> Void)?

    private weak var bridge: BridgeStore?
    /// 工作流模板解析（注入以便测试用临时目录，默认 App 共享实例）。
    private let workflowStore: WorkflowStore

    init(workflowStore: WorkflowStore = .shared) {
        self.workflowStore = workflowStore
    }

    /// BridgeStore.init 里调用（避免初始化期把 self 作为参数传出）。
    func attach(bridge: BridgeStore) {
        self.bridge = bridge
    }

    /// 测试便捷入口：bridge 已完全初始化后可一次性构造。
    convenience init(bridge: BridgeStore, workflowStore: WorkflowStore = .shared) {
        self.init(workflowStore: workflowStore)
        self.bridge = bridge
    }

    /// 处理一个深链动作；未知/失败 → 聊天提示，不崩。
    func handle(_ action: DeepLinkAction) {
        guard let bridge else { return }
        switch action {
        case .newSession:
            bridge.chat.newSession()
            bridge.chat.appendCanvasNotice("🔗 深链：已新建会话")

        case .createPipeline:
            createPipeline()

        case .openSettings(let id):
            // Settings navigation is not a conversation event: keep messages,
            // preview ordering and updatedAt unchanged.
            onOpenSettings?(id)

        case .runWorkflow(let name, let input):
            // F22（P1-2）：透传 ?input= —— 工作流首个必需输入
            runWorkflow(name: name, input: input)

        case .sendPrompt(let text, let session):
            // A session-directed prompt is another path to the same target as
            // a copied backlink. Check canonical target and current native
            // grant before switching; an unknown or rejected ID must not send
            // the prompt into whichever session happened to be active.
            if let session {
                guard let target = bridge.chat.sessions.first(where: { $0.id.uuidString == session }),
                      bridge.chat.canOpenDeepLinkedSession(id: target.id) else {
                    bridge.chat.appendCanvasNotice("⚠️ 深链：目标会话或项目授权当前不可用。")
                    return
                }
                bridge.chat.switchSession(id: target.id)
                guard bridge.chat.activeSessionID == target.id else {
                    bridge.chat.appendCanvasNotice("⚠️ 深链：目标会话或项目授权当前不可用。")
                    return
                }
            }
            // 复用聊天发送路径：画布指令优先，普通文本走 LLM
            bridge.chat.draftText = text
            bridge.chat.submitComposer()

        case .openSession(let id):
            openSession(id: id)
        }
    }

    // MARK: - 各动作实现

    /// 一键流水线（P2-1）：生成完整漫剧 12 节点全流程骨架图（ManjuPipelineTemplate，
    /// 主链 小说导入→剧情拆解→脚本生成→分镜生成→图片提示词→视频提示词→生图→生视频→QC检查，
    /// 另含 资产引用 + Blender 预演，资产锁定注入提示词节点），替代旧 4 节点链。
    /// 回执由 BridgeStore.createManjuPipeline 统一写聊天流。
    private func createPipeline() {
        guard let bridge else { return }
        bridge.createManjuPipeline()
    }

    /// 运行命名工作流（id 或模板名）。模板缺失 / 缺必需输入 → 提示；执行异步跑
    /// WorkflowRunner（LLM 走当前聊天 Provider，未配置则 Mock），结果写回聊天流。
    ///
    /// F15 P2-5：复用 `bridge.workflowChat.sharedRunner`（与聊天同一 runner 实例），
    /// 不再每次新建 —— 深链执行失败会留下断点，后续从聊天或深链重发同模板指令
    /// 都能断点续跑（断点按模板 id 隔离，见 WorkflowRunner）。
    ///
    /// F22（P1-2）：`input` 为 `?input=<text>` query 透传 —— 映射模板首个必需输入。
    /// F22（③ F3 残留回执）：入口捕获发起会话 ID，Task 内回执写回该会话 ——
    /// 执行期间用户切走会话，回执不再串到活跃会话。
    private func runWorkflow(name: String, input: String? = nil) {
        guard let bridge else { return }
        // F22（③）：发起时刻的会话 —— Task 回执按此写回，不追活跃会话
        let originSessionID = bridge.chat.activeSessionID

        guard let template = workflowStore.template(id: name) else {
            let available = workflowStore.listTemplates()
                .map { "\($0.id)（\($0.name)）" }
                .joined(separator: " / ")
            bridge.chat.appendAssistant(
                "⚠️ 深链：未找到工作流「\(name)」。可用：\(available.isEmpty ? "无" : available)",
                toSession: originSessionID
            )
            return
        }
        // F22（P1-2）：?input= 映射首个必需输入；仍缺则提示（不静默失败）
        var inputs: [String: String] = [:]
        if let input, let firstRequired = template.requiredInputs.first {
            inputs[firstRequired] = input
        }
        let missing = template.requiredInputs.filter { inputs[$0] == nil }
        guard missing.isEmpty else {
            bridge.chat.appendAssistant(
                "⚠️ 深链：工作流「\(template.name)」需要输入：\(missing.joined(separator: "、"))。可用 ?input= 传入或先在聊天里提供。",
                toSession: originSessionID
            )
            return
        }
        let selectedOverride = bridge.workflowChat.providerOverride
        let providerPreparation: ChatStore.WorkflowProviderPreparation?
        do {
            if selectedOverride == nil {
                providerPreparation = try bridge.chat.freezeWorkflowProviderSelection()
            } else {
                providerPreparation = nil
            }
        } catch {
            bridge.chat.appendAssistant(
                "❌ 深链：无法连接模型：\(ChatStore.userErrorMessage(error))",
                toSession: originSessionID
            )
            return
        }
        bridge.chat.appendAssistant("▶️ 深链：开始执行工作流「\(template.name)」…", toSession: originSessionID)

        Task { [weak bridge] in
            guard let bridge else { return }
            do {
                // providerOverride 为测试注入点（生产恒 nil）；与聊天路径一致
                let provider: any LLMProvider
                if let override = selectedOverride {
                    provider = override
                } else {
                    provider = try await bridge.chat.prepareWorkflowProvider(from: providerPreparation)
                }
                try Task.checkCancellation()
                let result = try await bridge.workflowChat.sharedRunner.run(
                    template: template,
                    inputs: inputs,
                    provider: LLMWorkflowProvider(provider: provider)
                )
                // F22（③）：写回发起会话，不串活跃会话
                bridge.chat.appendAssistant(
                    "🏁 工作流「\(template.name)」完成：\(result.outputs.count) 个输出，\(result.cachedStepIDs.count) 步命中缓存。",
                    toSession: originSessionID
                )
                bridge.chat.touchSession(originSessionID)
            } catch {
                bridge.chat.appendAssistant(
                    "❌ 工作流「\(template.name)」失败：\(ChatStore.userErrorMessage(error))",
                    toSession: originSessionID
                )
                bridge.chat.touchSession(originSessionID)
            }
        }
    }

    /// 打开既有会话（按 UUID 字符串匹配）；找不到 → 提示。
    private func openSession(id: String) {
        guard let bridge else { return }
        guard let sessionID = UUID(uuidString: id) else {
            bridge.chat.appendCanvasNotice("⚠️ 深链：未找到会话。")
            return
        }
        let activeSession = bridge.chat.sessions.first(where: { $0.id == sessionID })
        let archivedSession = bridge.chat.archivedSessions.first(where: { $0.id == sessionID })
        guard activeSession != nil || archivedSession != nil else {
            bridge.chat.appendCanvasNotice("⚠️ 深链：未找到会话。")
            return
        }
        guard bridge.chat.canOpenDeepLinkedSession(id: sessionID) else {
            bridge.chat.appendCanvasNotice("⚠️ 深链：目标会话或项目授权当前不可用。")
            return
        }
        if let session = activeSession {
            bridge.chat.switchSession(id: sessionID)
            if bridge.chat.activeSessionID == sessionID {
                bridge.chat.appendCanvasNotice("🔗 深链：已切换到会话「\(session.title)」")
            } else {
                bridge.chat.appendCanvasNotice("⚠️ 深链：目标会话或项目授权当前不可用。")
            }
        } else if let session = archivedSession {
            bridge.chat.restoreSession(id: sessionID)
            if bridge.chat.activeSessionID == sessionID {
                bridge.chat.appendCanvasNotice("🔗 深链：已切换到会话「\(session.title)」")
            } else {
                bridge.chat.appendCanvasNotice("⚠️ 深链：目标会话或项目授权当前不可用。")
            }
        } else {
            bridge.chat.appendCanvasNotice("⚠️ 深链：目标会话或项目授权当前不可用。")
        }
    }
}
