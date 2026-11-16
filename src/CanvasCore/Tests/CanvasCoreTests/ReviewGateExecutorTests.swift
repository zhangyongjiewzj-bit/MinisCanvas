import Testing
import Foundation
@testable import CanvasCore

// MARK: - reviewGate 审核节点执行器测试

/// ReviewGateExecutor 测试（确定性本地判定，不依赖 LLM）：
/// - PASS：正常文本 → status="PASS" 且 pass=原文（放行给下游）
/// - REJECT：文本含 "BLOCKED" / "（待填）" → status="REJECT" + reasons（打回原因）
/// - PENDING：空 / 全空白 / 无输入 → status="PENDING"（待审，不产出 pass）
/// - executor(for:) 路由：reviewGate → ReviewGateExecutor；未知类型 → nil
struct ReviewGateExecutorTests {

    // MARK: - 测试替身

    private func makeNode() -> CanvasNode {
        CanvasNode(
            type: ManjuNodeType.reviewGate.rawValue,
            title: "审核",
            inputs: [Port(name: "text", direction: .input, dataType: "string")],
            outputs: [
                Port(name: "pass", direction: .output, dataType: "string"),
                Port(name: "status", direction: .output, dataType: "string"),
            ]
        )
    }

    private func run(text: String?) async throws -> [String: AnyHashable] {
        let executor = ReviewGateExecutor()
        let node = makeNode()
        let inputs = text.map { ["text": AnyHashable($0)] }
        return try await executor.execute(node: node, inputs: inputs, backend: nil)
    }

    // MARK: - PASS：放行含原文

    @Test func passForwardsOriginalText() async throws {
        let original = "镜头1：危险但美，火光冲天。\n镜头2：雨夜巷战，慢动作。"
        let output = try await run(text: original)
        #expect(output["status"] as? String == "PASS")
        #expect(output["pass"] as? String == original)
        #expect(output["reasons"] == nil)
    }

    @Test func passKeepsTextUnchanged() async throws {
        let original = "  前后带空白的正常文本  "
        let output = try await run(text: original)
        #expect(output["status"] as? String == "PASS")
        // 放行的是原文，不做任何改写
        #expect(output["pass"] as? String == original)
    }

    // MARK: - REJECT：含 BLOCKED / （待填）

    @Test func rejectWhenContainsBlocked() async throws {
        let output = try await run(text: "【BLOCKED】提示词结构闸口未通过（铁律7）")
        #expect(output["status"] as? String == "REJECT")
        let reasons = try #require(output["reasons"])
        #expect(String(describing: reasons).contains("BLOCKED"))
    }

    @Test func rejectWhenContainsPendingPlaceholder() async throws {
        let output = try await run(text: "台词：（待填）")
        #expect(output["status"] as? String == "REJECT")
        let reasons = try #require(output["reasons"])
        #expect(String(describing: reasons).contains("（待填）"))
    }

    @Test func rejectListsBothReasonsWhenBothMarkersPresent() async throws {
        let output = try await run(text: "【BLOCKED】对白：（待填）")
        #expect(output["status"] as? String == "REJECT")
        let reasons = try #require(output["reasons"])
        let text = String(describing: reasons)
        #expect(text.contains("BLOCKED"))
        #expect(text.contains("（待填）"))
    }

    // MARK: - PENDING：空 / 全空白 / 无输入

    @Test func pendingWhenTextIsEmpty() async throws {
        let output = try await run(text: "")
        #expect(output["status"] as? String == "PENDING")
        #expect(output["pass"] == nil)
    }

    @Test func pendingWhenTextIsWhitespaceOnly() async throws {
        let output = try await run(text: "   \n\t  ")
        #expect(output["status"] as? String == "PENDING")
        #expect(output["pass"] == nil)
    }

    @Test func pendingWhenNoInputs() async throws {
        let executor = ReviewGateExecutor()
        let node = makeNode()
        let output = try await executor.execute(node: node, inputs: nil, backend: nil)
        #expect(output["status"] as? String == "PENDING")
    }

    // MARK: - 输入回退：text 缺失时回退 prompt

    @Test func fallsBackToPromptInputWhenTextMissing() async throws {
        let executor = ReviewGateExecutor()
        let node = makeNode()
        let output = try await executor.execute(
            node: node,
            inputs: ["prompt": AnyHashable("提示词内容")],
            backend: nil
        )
        #expect(output["status"] as? String == "PASS")
        #expect(output["pass"] as? String == "提示词内容")
    }

    // MARK: - 路由

    @Test func routeExistsForReviewGate() {
        let executor = NodeExecutors().executor(for: ManjuNodeType.reviewGate.rawValue)
        #expect(executor != nil)
        #expect(executor is ReviewGateExecutor)
    }

    @Test func staticRouteExistsForReviewGate() {
        let executor = NodeExecutors.executor(for: ManjuNodeType.reviewGate.rawValue)
        #expect(executor != nil)
        #expect(executor is ReviewGateExecutor)
    }

    @Test func routeReturnsNilForUnknownType() {
        #expect(NodeExecutors().executor(for: "no_such_type") == nil)
    }
}
