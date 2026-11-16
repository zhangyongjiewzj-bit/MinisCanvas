import Foundation
import CryptoKit
import MinisCore

/// A fixed, synthetic, tool-free field scenario. Only the MM01 lane mints it
/// after actual Apply and a fresh owned empty session. Capturing arbitrary
/// prompt bytes is deliberately not an authority constructor.
struct MM01AgentScenarioContract: Sendable {
    static let approvedSystemPrompt = "你是 MinisCanvas 的 MM01 合成图片验证助手。仅根据本回合附加图片回答用户问题。若无法读取图片，明确说明无法读取，不要猜测。本回合不支持工具调用，不访问文件、网络或其他会话。"
    static let approvedPromptUTF8Length = approvedSystemPrompt.utf8.count
    static let approvedPromptSHA256 = SHA256.hash(data: Data(approvedSystemPrompt.utf8))
        .map { String(format: "%02x", $0) }.joined()

    enum Refusal: Error { case identity, prompt, tools, budget }
    let nonce: UUID
    let sessionID: String
    let applyReceiptID: String
    let executionIdentity: AgentExecutionIdentity
    let bindPrepared: @MainActor @Sendable (String, AgentExecutionIdentity) throws -> Void

    func validateIdentity(_ actual: AgentExecutionIdentity) throws {
        guard actual == executionIdentity, actual.isValid,
              actual.turn.sessionID == sessionID, actual.attempt == 1,
              !applyReceiptID.isEmpty else { throw Refusal.identity }
    }

    func validateFinalPrompt(_ actual: String) throws {
        guard Data(actual.utf8) == Data(Self.approvedSystemPrompt.utf8),
              actual.utf8.count == Self.approvedPromptUTF8Length,
              SHA256.hash(data: Data(actual.utf8)).map({ String(format: "%02x", $0) }).joined()
                == Self.approvedPromptSHA256 else { throw Refusal.prompt }
    }

    func bindFinalPrompt(_ actual: String, identity: AgentExecutionIdentity) async throws {
        try validateIdentity(identity)
        try validateFinalPrompt(actual)
        try await bindPrepared(actual, identity)
    }
}
