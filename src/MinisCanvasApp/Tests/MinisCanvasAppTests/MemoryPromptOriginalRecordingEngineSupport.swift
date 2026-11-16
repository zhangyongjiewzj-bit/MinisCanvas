import Foundation
import MinisCore
@testable import MinisCanvasApp

// Exact original U4 recording engine body; selected-target dependency only.
final class TESTREG613MemoryPromptRecordingEngine: ComposerSnapshotForwardingTestEngine, @unchecked Sendable {
    var isAvailable: Bool { true }

    private let lock = NSLock()
    private var _systemPrompts: [String] = []
    var systemPrompts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _systemPrompts
    }

    /// NSLock 不能在 async 上下文直接 lock/unlock（Swift 并发隔离）——
    /// 包装进同步 helper，供 streamReply（async）调用。
    private func record(_ prompt: String) {
        lock.lock()
        _systemPrompts.append(prompt)
        lock.unlock()
    }

    func interrupt() {}

    func streamReply(
        provider: any LLMProvider,
        history: [ChatMessageUI],
        systemPrompt: String,
        maxTokens: Int
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        record(systemPrompt)
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("ok"))
            continuation.finish()
        }
    }

    func compactContext(
        provider: any LLMProvider,
        history: [ChatMessageUI],
        systemPrompt: String,
        keepRecent: Int
    ) async -> CompactionResult {
        CompactionResult(messages: [], summary: nil, compactedCount: 0)
    }
}
