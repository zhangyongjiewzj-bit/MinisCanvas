import Testing
import Foundation
@testable import CanvasCore

// MARK: - P2-3 W-6：提示词节点 BLOCKED 闸口（铁律7 产出点约束）

/// LLM 节点执行器结构闸口测试：
/// - imagePrompt/videoPrompt 输出缺 8/9 槽 → BLOCKED + 缺哪些槽，status = "blocked"
/// - 输出无 8/9 槽结构标记 → BLOCKED（未检测到模板标记）
/// - 完整槽位输出 → 正常 succeeded，不改写
/// - 无 key / provider 引导文本（LLMNodeGuidance）→ 跳过闸口，不误伤 key 配置引导
/// - 非提示词 LLM 节点（plotOutline 等）→ 不参与闸口
struct NodeExecutorsBlockedGateTests {

    // MARK: - 测试数据

    /// 完整 8 槽图片提示词（结构闸口通过；审美闸口与本闸口无关）
    static let completeImagePrompt = """
    [TYPE]
    9:16 竖屏定妆图，危险但美（美感70%/危险30%）。

    [REFERENCE]
    参考图：asset://weixian-face-8angle。魏衔 定妆图只继承：脸、五官、眼型、骨相、肤色。

    [LAYOUT]
    主体居中偏右、留白在左，有主次关系和视觉动线。

    [STRUCTURE]
    粗麻织纹、袖口磨损起毛、厚垂坠。

    [MATERIAL]
    粗麻、磨损、垂坠。

    [COLOR]
    玄青(#1F2A33) 70%、灰褐(#6B5D4F) 20%、暗金(#B08D3E) 8%、朱砂(#C2452D) 2%。

    [LIGHT]
    侧逆光、轮廓光、斑驳树影。

    [FORBID]
    现代鞋、高跟鞋、换脸。
    """

    /// 缺 FORBID / LIGHT 槽的图片提示词（结构闸口应 BLOCKED）
    static let incompleteImagePrompt = Self.completeImagePrompt
        .replacingOccurrences(of: "\n[LIGHT]\n侧逆光、轮廓光、斑驳树影。\n", with: "\n")
        .replacingOccurrences(of: "\n[FORBID]\n现代鞋、高跟鞋、换脸。", with: "")

    /// 无槽位结构标记的自由文本（模板识别失败 → BLOCKED）
    static let noStructureText = "一段完全没有槽位结构的自由文本"

    /// 无 key 引导输出（App 层 MinisCanvasLLMInvoker 同款前缀）
    static let guidanceText = """
    【未配置 API Key】 未配置 API Key：请在设置中配置，或检查环境变量

    节点：bailian / qwen3.8-max-preview

    ── 本次请求输入摘要（配置后自动真实执行）──
    （无输入）
    """

    // MARK: - 测试替身

    private struct StubLLMInvoker: LLMInvoker {
        let text: String
        func invoke(prompt: String, backend: NodeBackendConfig) async throws -> String { text }
    }

    private static let testBackend = NodeBackendConfig(
        providerID: "bailian", modelID: "qwen3.8-max-preview"
    )

    private func makePromptNode(type: String) -> CanvasNode {
        CanvasNode(
            type: type,
            title: type,
            inputs: [Port(name: "text", direction: .input, dataType: "string")],
            outputs: [Port(name: "text", direction: .output, dataType: "string")]
        )
    }

    private func runExecutor(node: CanvasNode, stubText: String) async throws -> [String: AnyHashable] {
        let executor = LLMNodeExecutor(llmInvoker: StubLLMInvoker(text: stubText))
        return try await executor.execute(
            node: node, inputs: nil, backend: Self.testBackend
        )
    }

    // MARK: - 闸口：缺槽 → BLOCKED

    @Test func imagePromptIncompleteOutputIsBlocked() async throws {
        let output = try await runExecutor(node: makePromptNode(type: "imagePrompt"),
                                           stubText: Self.incompleteImagePrompt)
        #expect(output["status"] as? String == "blocked")
        #expect(output["blocked"] as? String == "1")
        let text = output["text"] as? String ?? ""
        #expect(text.contains("【BLOCKED】"), "应输出 BLOCKED 标记")
        #expect(text.contains("铁律7"), "应引用铁律7（缺字段 = BLOCKED）")
        #expect(text.contains("FORBID"), "应列出缺的槽位 FORBID")
        #expect(text.contains("LIGHT"), "应列出缺的槽位 LIGHT")
        let missing = output["missing_slots"] as? String ?? ""
        #expect(missing.contains("FORBID") && missing.contains("LIGHT"))
    }

    @Test func videoPromptWithoutTemplateMarkersIsBlocked() async throws {
        let output = try await runExecutor(node: makePromptNode(type: "videoPrompt"),
                                           stubText: Self.noStructureText)
        #expect(output["status"] as? String == "blocked")
        let text = output["text"] as? String ?? ""
        #expect(text.contains("【BLOCKED】"))
        #expect(text.contains("未检测到 8/9 槽结构标记"), "无模板标记应明确提示")
    }

    @Test func imagePromptWithoutForbidSlotIsBlocked() async throws {
        // 只缺 FORBID 一个槽：应列出且只列出该槽
        let output = try await runExecutor(node: makePromptNode(type: "imagePrompt"),
                                           stubText: Self.completeImagePrompt
                                               .replacingOccurrences(of: "\n[FORBID]\n现代鞋、高跟鞋、换脸。", with: ""))
        #expect(output["status"] as? String == "blocked")
        #expect((output["missing_slots"] as? String) == "FORBID")
    }

    // MARK: - 闸口：完整输出通过

    @Test func imagePromptCompleteOutputPassesGate() async throws {
        let output = try await runExecutor(node: makePromptNode(type: "imagePrompt"),
                                           stubText: Self.completeImagePrompt)
        #expect(output["status"] as? String == "succeeded")
        #expect(output["blocked"] == nil)
        #expect(output["text"] as? String == Self.completeImagePrompt, "完整提示词应原样输出")
    }

    // MARK: - 闸口：引导文本跳过（不误伤 key 配置引导）

    @Test func guidanceTextSkipsBlockedGate() async throws {
        let output = try await runExecutor(node: makePromptNode(type: "imagePrompt"),
                                           stubText: Self.guidanceText)
        #expect(output["status"] as? String == "succeeded", "无 key 引导不是 LLM 产物，不参与结构闸口")
        #expect(output["text"] as? String == Self.guidanceText)
    }

    @Test func guidancePrefixDetection() {
        #expect(LLMNodeGuidance.isGuidance(Self.guidanceText))
        #expect(LLMNodeGuidance.isGuidance("【未接入 Provider】 provider 未配置"))
        #expect(!LLMNodeGuidance.isGuidance(Self.completeImagePrompt))
        #expect(!LLMNodeGuidance.isGuidance("普通文本"))
    }

    // MARK: - 闸口：仅提示词节点参与

    @Test func nonPromptLLMNodeSkipsGate() async throws {
        // plotOutline 输出自由文本不触发 BLOCKED（只有 imagePrompt/videoPrompt 走结构闸口）
        let output = try await runExecutor(node: makePromptNode(type: "plotOutline"),
                                           stubText: Self.noStructureText)
        #expect(output["status"] as? String == "succeeded")
        #expect(output["text"] as? String == Self.noStructureText)
    }

    @Test func promptTemplateNodeDetection() {
        #expect(LLMNodeExecutor.isPromptTemplateNode("imagePrompt"))
        #expect(LLMNodeExecutor.isPromptTemplateNode("videoPrompt"))
        #expect(!LLMNodeExecutor.isPromptTemplateNode("plotOutline"))
        #expect(!LLMNodeExecutor.isPromptTemplateNode("llm"))
        #expect(!LLMNodeExecutor.isPromptTemplateNode("qcCheck"))
    }
}
