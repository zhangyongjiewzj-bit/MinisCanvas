import MinisCore
import Testing
@testable import MinisCanvasApp

@Suite("Batch2E chat output cap function")
struct Batch2E_OutputCapFunctionTests {
    @Test func capIsCatalogLimitOrThirtyTwoK() {
        #expect(ChatStore.chatMaxOutputTokens(model: LLMModel(id: "m", displayName: "m", provider: "p", maxOutputTokens: 8_192)) == 8_192)
        #expect(ChatStore.chatMaxOutputTokens(model: LLMModel(id: "m", displayName: "m", provider: "p", maxOutputTokens: 64_000)) == 64_000)
        #expect(ChatStore.chatMaxOutputTokens(model: LLMModel(id: "m", displayName: "m", provider: "p")) == 32_000)
    }

    /// R3-08：内置 gpt-4o 系列声明了官方上限 16384，聊天请求不会超过它。
    @Test func builtInGpt4oSeriesRequestNoMoreThanTheirLimit() {
        #expect(ChatStore.chatMaxOutputTokens(model: .gpt4o) == 16_384)
        #expect(ChatStore.chatMaxOutputTokens(model: .gpt4oMini) == 16_384)
        #expect(ChatStore.chatMaxOutputTokens(model: .orGPT4o) == 16_384)
    }

    /// R3-08：自定义服务商里没声明上限、但模型 ID 在内置清单里有已知上限时，默认的 32000 取小，不超过已知上限。
    @Test func undeclaredModelNeverExceedsTheCatalogLimitForTheSameID() {
        let custom = LLMModel(id: "gpt-4o", displayName: "gpt-4o", provider: "自定义")
        #expect(custom.maxOutputTokens == nil)
        #expect(ChatStore.chatMaxOutputTokens(model: custom) == 16_384)
        // 清单里的上限高于默认值时，仍按默认 32000（只取小，不放大）。
        let larger = LLMModel(id: "claude-opus-4-8", displayName: "x", provider: "自定义")
        #expect(ChatStore.chatMaxOutputTokens(model: larger) == 32_000)
        // 用户填的值优先，哪怕比清单里的高。
        let entered = LLMModel(id: "gpt-4o", displayName: "gpt-4o", provider: "自定义", maxOutputTokens: 4_096)
        #expect(ChatStore.chatMaxOutputTokens(model: entered) == 4_096)
    }
}
