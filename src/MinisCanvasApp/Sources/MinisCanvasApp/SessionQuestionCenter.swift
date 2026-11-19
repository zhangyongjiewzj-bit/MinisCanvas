import Foundation
import Observation
import MinisCore

/// Owns only question data and waiters, never approval grants or tool actions.
/// Requests survive focus/session switches while the actual model call waits.
@MainActor @Observable
final class SessionQuestionCenter {
    struct Pending: Identifiable {
        let id: UUID
        let sessionID: UUID
        let request: UserQuestionRequest
        var selections: [String: [String]] = [:]
        var otherText: [String: String] = [:]
        var usesOther: Set<String> = []
        var feedback: String?

        var answers: [String: [String]] {
            var result = selections
            for question in usesOther {
                let text = (otherText[question] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let isMultiple = request.questions.first(where: { $0.question == question })?.multiSelect == true
                result[question] = (isMultiple ? (result[question] ?? []) : []) + (text.isEmpty ? [] : [text])
            }
            return result.filter { !$0.value.isEmpty }
        }
        var isComplete: Bool { feedback == nil && request.questions.allSatisfy { answers[$0.question]?.isEmpty == false } }
    }
    private(set) var pending: [UUID: Pending] = [:]
    var onPendingRequestsChanged: (@MainActor () -> Void)?
    @ObservationIgnored private var continuations: [UUID: CheckedContinuation<UserQuestionResult, any Error>] = [:]

    func pending(for sessionID: UUID?) -> Pending? { sessionID.flatMap { pending[$0] } }
    func matches(requestID: String, lifecycleID: UUID) -> Bool {
        pending.values.contains { $0.id == lifecycleID && requestID == notificationID($0.id) }
    }
    func notificationID(_ id: UUID) -> String { "question:" + id.uuidString }

    func present(_ request: UserQuestionRequest, sessionID: UUID) async throws -> UserQuestionResult {
        try request.validate()
        guard pending[sessionID] == nil else { throw AskUserQuestionTool.InputError.alreadyPending }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                continuations[id] = continuation
                pending[sessionID] = Pending(id: id, sessionID: sessionID, request: request)
                onPendingRequestsChanged?()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelWaiter(id: id) }
        }
    }

    func select(sessionID: UUID, id: UUID, question: String, label: String) {
        guard var value = pending[sessionID], value.id == id,
              let definition = value.request.questions.first(where: { $0.question == question }),
              definition.options.contains(where: { $0.label == label }) else { return }
        if !definition.multiSelect { value.usesOther.remove(question) }
        if definition.multiSelect {
            var labels = value.selections[question] ?? []
            if labels.contains(label) { labels.removeAll { $0 == label } } else { labels.append(label) }
            value.selections[question] = definition.options.map(\.label).filter { labels.contains($0) }
        } else { value.selections[question] = [label] }
        value.feedback = nil
        pending[sessionID] = value
    }
    func setOther(sessionID: UUID, id: UUID, question: String, text: String) {
        guard var value = pending[sessionID], value.id == id,
              value.request.questions.contains(where: { $0.question == question }) else { return }
        guard text.count <= UserQuestionRequest.maxOtherCharacters else {
            value.feedback = "其他回答最多1000字；超出部分未接受，请缩短后重新输入。"
            pending[sessionID] = value
            return
        }
        value.usesOther.insert(question)
        value.otherText[question] = text
        value.feedback = nil
        pending[sessionID] = value
    }
    func resolve(sessionID: UUID, id: UUID, status: UserQuestionResult.Status) {
        guard let value = pending[sessionID], value.id == id,
              status == .answered || status == .cancelled,
              status != .answered || value.isComplete else { return }
        let result = UserQuestionResult(status: status, request: value.request, answers: value.answers,
            reason: status == .cancelled ? "用户取消澄清；未授权选项中提到的任何操作。" : nil)
        do { _ = try result.encoded() } catch {
            pending[sessionID]?.feedback = UserFacingErrorText.describe(error)
            return
        }
        finish(value, result: result)
    }
    private func finish(_ value: Pending, result: UserQuestionResult) {
        let sessionID = value.sessionID
        let id = value.id
        pending.removeValue(forKey: sessionID)
        let continuation = continuations.removeValue(forKey: id)
        onPendingRequestsChanged?()
        continuation?.resume(returning: result)
    }
    func cancel(sessionID: UUID) {
        if let value = pending[sessionID] { cancelWaiter(id: value.id) }
    }

    private func cancelWaiter(id: UUID) {
        guard let value = pending.values.first(where: { $0.id == id }) else { return }
        pending.removeValue(forKey: value.sessionID)
        let continuation = continuations.removeValue(forKey: id)
        onPendingRequestsChanged?()
        continuation?.resume(throwing: CancellationError())
    }
}
