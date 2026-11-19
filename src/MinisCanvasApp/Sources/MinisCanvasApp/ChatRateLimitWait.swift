import Foundation
import Observation
import SwiftUI
import MinisCore

@MainActor @Observable
final class ChatRateLimitWaitController {
    struct Pending {
        let id: UUID
        let sessionID: UUID?
        let deadline: Date
        let reason: LLMRateLimitWaitRequest.Reason
    }
    private(set) var pending: [UUID: Pending] = [:]
    @ObservationIgnored private var continuations: [UUID: CheckedContinuation<Void, any Error>] = [:]
    @ObservationIgnored private var sleeps: [UUID: Task<Void, Never>] = [:]

    func wait(_ request: LLMRateLimitWaitRequest, sessionID: UUID?) async throws {
        let id = UUID()
        let components = request.delay.components
        let seconds = max(0, Double(components.seconds) + Double(components.attoseconds) / 1e18)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                continuations[id] = continuation
                pending[id] = Pending(id: id, sessionID: sessionID,
                    deadline: Date().addingTimeInterval(seconds), reason: request.reason)
                sleeps[id] = Task { [weak self] in
                    do {
                        try await request.sleep(request.delay)
                        self?.finish(id, cancelled: false)
                    } catch {
                        self?.finish(id, cancelled: true)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id, cancelled: true) }
        }
    }

    func current(sessionID: UUID?) -> Pending? {
        pending.values.filter { $0.sessionID == sessionID }.sorted { $0.deadline < $1.deadline }.first
    }

    func finish(_ id: UUID, cancelled: Bool) {
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        pending.removeValue(forKey: id)
        sleeps.removeValue(forKey: id)?.cancel()
        if cancelled { continuation.resume(throwing: CancellationError()) }
        else { continuation.resume() }
    }
}

struct ChatRateLimitWaitCard: View {
    let controller: ChatRateLimitWaitController
    let sessionID: UUID?
    let onCancel: () -> Void

    static func message(for reason: LLMRateLimitWaitRequest.Reason, seconds: Int) -> String {
        switch reason {
        case .rateLimited: "请求限流，等待 \(seconds) 秒后重试"
        case .serviceUnavailable: "服务暂时不可用，等待 \(seconds) 秒后重试"
        }
    }

    var body: some View {
        if let pending = controller.current(sessionID: sessionID) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 10) {
                    MinisIconView(.retry, size: 12)
                    Text(Self.message(for: pending.reason,
                        seconds: max(0, Int(ceil(pending.deadline.timeIntervalSince(context.date))))))
                    Spacer()
                    Button("立即重试") { controller.finish(pending.id, cancelled: false) }
                    Button("取消", action: onCancel)
                }
                .font(.caption)
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("chat.rate-limit.wait")
                .onKeyPress(.escape) {
                    onCancel()
                    return .handled
                }
            }
        }
    }
}

struct ChatProviderRetryExhaustionCard: View {
    let chat: ChatStore

    let identity: AgentExecutionIdentity
    let messageID: UUID

    var body: some View {
        if chat.activeProviderRetryExhaustion?.identity == identity {
            VStack(alignment: .leading, spacing: 6) {
                Text("服务暂不可用，已用完自动重试。可以换模型或稍后再试。")
                HStack {
                    ModelMenuButton(chat: chat)
                    Button("稍后") { chat.dismissProviderRetryExhaustion(identity) }
                }
            }
            .font(.caption)
            .padding(10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("chat.rate-limit.exhausted")
        }
    }
}
