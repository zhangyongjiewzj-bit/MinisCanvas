import Foundation
import CanvasCore

// MARK: - 占位 LLM 调用器（A2-v04）

// 无 key 降级用本地占位实现（I7 P0-2）：真实 CanvasLLMInvoker（M2l）未配置
// 环境变量时，经 FallbackLLMInvoker 降级到此处——不联网，直接返回
// 「【LLM 待接入】+ 输入摘要」，保证画布执行链路（调度 → 执行器 → 状态回写）无 key 也能跑通。
//
// 注：真实执行链（GraphExecutionContext / 同步桥接）已下沉 CanvasCore（I6 P0-1），
// 本文件仅保留 CanvasApp 自己的注入实现。

struct PlaceholderLLMInvoker: LLMInvoker {
    func invoke(prompt: String, backend: NodeBackendConfig) async throws -> String {
        // 输入摘要：取提示词中最后一段「端口名: 值」行（最多 3 行），过长截断
        let lines = prompt.split(separator: "\n")
        let summaryLines = lines.suffix(3).map { $0.count > 60 ? "\($0.prefix(60))…" : String($0) }
        let summary = summaryLines.isEmpty ? "（无输入）" : summaryLines.joined(separator: "\n")
        let modelTag = backend.modelID.isEmpty ? "默认模型" : backend.modelID
        return "【LLM 待接入】模型=\(modelTag)\n\(summary)"
    }
}
