import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

// MARK: - D-CHAT-03 增量流式接线：取消语义补位回归
//
// 引擎事件流的正/反向回归（首段先于终态、多段、终态 dedupe、缓冲零变化）
// 由 DChat03AssistantStreamingEngineTests 固定；「生成中」占位渲染纯净性由
// DChat03StreamingPlaceholderTests 固定；本文件补一条不重复的缺口：
// · 取消：流中途取消后不得再向消费端投递迟到 textDelta。

/// 首段由消费者确认后才放行迟到事件；超时只负责报告卡住，不参与排序。
private actor DChat03CancellationProbe {
    enum Failure: Equatable, Sendable {
        case executionIdentityMismatch
        case cancelled
        case other(String)
    }

    enum FirstResult: Equatable, Sendable {
        case delta(String)
        case failure(Failure)
        case ended
        case timedOut
    }

    struct Observation: Sendable {
        let deltas: [String]
        let sawDone: Bool
        let terminated: Bool
        let error: Failure?
        let streamCalls: Int
        let bufferedCalls: Int
        let providerCancelled: Bool
        let lateAttempted: Bool
    }

    private var deltas: [String] = []
    private var sawDone = false
    private var terminated = false
    private var terminationTimedOut = false
    private var terminationWaiter: CheckedContinuation<Bool, Never>?
    private var error: Failure?
    private var streamCalls = 0
    private var bufferedCalls = 0
    private var firstResult: FirstResult?
    private var firstWaiter: CheckedContinuation<FirstResult, Never>?
    private var lateReleased = false
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var providerCancelled = false
    private var cancellationTimedOut = false
    private var cancellationWaiter: CheckedContinuation<Bool, Never>?
    private var lateAttempted = false
    private var lateTimedOut = false
    private var lateWaiter: CheckedContinuation<Bool, Never>?

    func recordStreamCall() { streamCalls += 1 }
    func recordBufferedCall() { bufferedCalls += 1 }

    func recordDelta(_ delta: String) {
        deltas.append(delta)
        resolveFirst(.delta(delta))
    }

    func recordDone() {
        sawDone = true
        resolveFirst(.ended)
    }

    func finish(_ failure: Failure? = nil) {
        error = failure
        terminated = true
        resolveFirst(failure.map(FirstResult.failure) ?? .ended)
        terminationWaiter?.resume(returning: true)
        terminationWaiter = nil
    }

    func timeOutTermination() {
        guard !terminated else { return }
        terminationTimedOut = true
        terminationWaiter?.resume(returning: false)
        terminationWaiter = nil
    }

    func waitForTermination() async -> Bool {
        if terminated { return true }
        if terminationTimedOut { return false }
        return await withCheckedContinuation { terminationWaiter = $0 }
    }

    private func resolveFirst(_ result: FirstResult) {
        guard firstResult == nil else { return }
        firstResult = result
        firstWaiter?.resume(returning: result)
        firstWaiter = nil
    }

    func timeOutFirst() { resolveFirst(.timedOut) }

    func waitForFirst() async -> FirstResult {
        if let firstResult { return firstResult }
        return await withCheckedContinuation { firstWaiter = $0 }
    }

    func waitForLateRelease() async {
        if lateReleased { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func releaseLate() {
        lateReleased = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func recordProviderCancellation() {
        providerCancelled = true
        cancellationWaiter?.resume(returning: true)
        cancellationWaiter = nil
    }

    func timeOutProviderCancellation() {
        guard !providerCancelled else { return }
        cancellationTimedOut = true
        cancellationWaiter?.resume(returning: false)
        cancellationWaiter = nil
    }

    func waitForProviderCancellation() async -> Bool {
        if providerCancelled { return true }
        if cancellationTimedOut { return false }
        return await withCheckedContinuation { cancellationWaiter = $0 }
    }

    func recordLateAttempt() {
        lateAttempted = true
        lateWaiter?.resume(returning: true)
        lateWaiter = nil
    }

    func timeOutLateAttempt() {
        guard !lateAttempted else { return }
        lateTimedOut = true
        lateWaiter?.resume(returning: false)
        lateWaiter = nil
    }

    func waitForLateAttempt() async -> Bool {
        if lateAttempted { return true }
        if lateTimedOut { return false }
        return await withCheckedContinuation { lateWaiter = $0 }
    }

    func observation() -> Observation {
        Observation(
            deltas: deltas, sawDone: sawDone, terminated: terminated, error: error,
            streamCalls: streamCalls, bufferedCalls: bufferedCalls,
            providerCancelled: providerCancelled,
            lateAttempted: lateAttempted
        )
    }
}

/// 流出首段后等待测试取消，再尝试投递一个迟到增量和终态。
private final class DChat03HangingAfterFirstChunkProvider: LLMProvider,
    AssistantStreamingLLMProvider, @unchecked Sendable {
    let probe: DChat03CancellationProbe
    var name: String { "DChat03Hanging" }
    var model = LLMModel(
        id: "d-chat-03-hang", displayName: "D-CHAT-03 Hang", provider: "Test"
    )
    var capabilities: Set<ProviderCapability> { [.tools] }

    init(probe: DChat03CancellationProbe) { self.probe = probe }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        await probe.recordBufferedCall()
        return LLMResponse(text: "永远不该整文到达", stopReason: "end_turn", usage: nil)
    }

    func streamMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func streamAssistantMessage(
        messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
        maxTokens: Int, temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMAssistantStreamEvent, Error> {
        await probe.recordStreamCall()
        let probe = self.probe
        return AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.textDelta("首段已流出"))
                await probe.waitForLateRelease()
                continuation.yield(.textDelta("取消后迟到增量"))
                continuation.yield(.completed(LLMResponse(
                    text: "首段已流出取消后迟到增量", stopReason: "end_turn", usage: nil
                )))
                await probe.recordLateAttempt()
                continuation.finish()
            }
            continuation.onTermination = { termination in
                guard case .cancelled = termination else { return }
                task.cancel()
                Task { await probe.recordProviderCancellation() }
            }
        }
    }
}

@Suite("D-CHAT-03 增量流取消与生成中可见性")
struct DChat03CancellationAndPlaceholderTests {

    /// 消费端确认首段后取消；provider 确实尝试迟到回调，但消费者不得接收。
    @Test func cancellationMidStreamStopsFurtherDeltas() async throws {
        let probe = DChat03CancellationProbe()
        let provider = DChat03HangingAfterFirstChunkProvider(probe: probe)
        let engine = AgentLoopChatEngine()
        let stream = try await engine.streamReply(
            provider: provider,
            history: [ChatMessageUI(role: .user, content: "长回复然后取消")],
            systemPrompt: "test",
            maxTokens: 128,
            conversationID: "d-chat-03-cancel",
            authorizedSessionReadSessionID: nil,
            turnID: 1 // Fresh legacy engine: local TurnController first handle is 1.
        )
        let consumer = Task {
            do {
                for try await event in stream {
                    switch event {
                    case .textDelta(let text):
                        await probe.recordDelta(text)
                    case .done:
                        await probe.recordDone()
                    default:
                        break
                    }
                }
            } catch let error as AgentLoopError {
                await probe.finish(error == .executionIdentityMismatch
                    ? .executionIdentityMismatch : .other(String(reflecting: error)))
                return
            } catch is CancellationError {
                await probe.finish(.cancelled)
                return
            } catch {
                await probe.finish(.other(String(reflecting: error)))
                return
            }
            await probe.finish()
        }
        func awaitConsumerTermination() async -> Bool {
            let watchdog = Task {
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
                await probe.timeOutTermination()
            }
            let terminated = await probe.waitForTermination()
            watchdog.cancel()
            return terminated
        }
        let firstWatchdog = Task {
            do { try await Task.sleep(for: .seconds(5)) }
            catch { return }
            await probe.timeOutFirst()
        }
        let first = await probe.waitForFirst()
        firstWatchdog.cancel()
        guard first == .delta("首段已流出") else {
            consumer.cancel()
            await probe.releaseLate()
            #expect(await awaitConsumerTermination(), "首段前失败后消费者必须有界退出")
            #expect(first == .delta("首段已流出"), "首段前失败/超时：\(first)")
            return
        }
        let beforeCancel = await probe.observation()
        #expect(beforeCancel.deltas == ["首段已流出"])
        #expect(beforeCancel.streamCalls == 1)
        #expect(beforeCancel.bufferedCalls == 0)
        #expect(!beforeCancel.sawDone)
        consumer.cancel()
        let cancelWatchdog = Task {
            do { try await Task.sleep(for: .seconds(5)) }
            catch { return }
            await probe.timeOutProviderCancellation()
        }
        let cancelledProvider = await probe.waitForProviderCancellation()
        cancelWatchdog.cancel()
        #expect(cancelledProvider, "取消必须传递到正在等待的 provider 流")
        await probe.releaseLate()
        let lateWatchdog = Task {
            do { try await Task.sleep(for: .seconds(5)) }
            catch { return }
            await probe.timeOutLateAttempt()
        }
        let attemptedLate = await probe.waitForLateAttempt()
        lateWatchdog.cancel()
        let consumerTerminated = await awaitConsumerTermination()
        let afterCancel = await probe.observation()
        #expect(attemptedLate && afterCancel.lateAttempted)
        #expect(afterCancel.deltas == ["首段已流出"])
        #expect(!afterCancel.sawDone)
        #expect(consumerTerminated && afterCancel.terminated,
                "取消后消费者必须在期限内真实退出")
        #expect(afterCancel.providerCancelled)
        #expect(afterCancel.error == nil || afterCancel.error == .cancelled)
        #expect(afterCancel.bufferedCalls == 0)
    }
}
