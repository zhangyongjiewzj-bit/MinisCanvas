import Foundation

extension LLMUsage {
    /// 总输入 = 未缓存 + 缓存读 + 缓存写。三家 Provider 已把校验过的“全部输入”写入
    /// `cacheHitInputTokens`；它为 nil（无明细或校验失败）时退回 `inputTokens`，
    /// 不叠加缓存字段，避免重复计数或编造未知数。`inputTokens` 语义不变。
    public var totalInputTokens: Int { cacheHitInputTokens ?? inputTokens }
}
