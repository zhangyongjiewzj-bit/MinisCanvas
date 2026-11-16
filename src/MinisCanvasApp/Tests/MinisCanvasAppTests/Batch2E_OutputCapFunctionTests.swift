import MinisCore
import Testing
@testable import MinisCanvasApp

@Suite("Batch2E chat output cap function")
struct Batch2E_OutputCapFunctionTests {
    @Test func capIsMinOfSixteenKAndCatalogLimit() {
        #expect(ChatStore.chatMaxOutputTokens(model: LLMModel(id: "m", displayName: "m", provider: "p", maxOutputTokens: 8_192)) == 8_192)
        #expect(ChatStore.chatMaxOutputTokens(model: LLMModel(id: "m", displayName: "m", provider: "p", maxOutputTokens: 32_000)) == 16_384)
        #expect(ChatStore.chatMaxOutputTokens(model: LLMModel(id: "m", displayName: "m", provider: "p")) == 16_384)
    }
}
