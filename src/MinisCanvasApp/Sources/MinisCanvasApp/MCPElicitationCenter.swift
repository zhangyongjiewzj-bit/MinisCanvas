import Foundation
import Observation
import MinisCore

/// One waiter belongs to one real server request and one chat turn. This
/// center owns input only; it cannot approve tools or execute server content.
@MainActor @Observable
final class MCPElicitationCenter {
    struct Pending: Identifiable {
        var id: UUID { context.oneShotID }
        let sessionID: UUID
        let context: MCPElicitationContext
        let form: MCPElicitationForm
        var texts: [String: String]
        var feedback: String?
    }
    private(set) var pending: [UUID: Pending] = [:]
    var onPendingRequestsChanged: (@MainActor () -> Void)?
    @ObservationIgnored private var continuations: [UUID: CheckedContinuation<MCPElicitationResult, any Error>] = [:]

    func pending(for sessionID: UUID?) -> Pending? { sessionID.flatMap { pending[$0] } }
    func notificationID(_ id: UUID) -> String { "mcp-elicitation:" + id.uuidString }
    func matches(requestID: String, lifecycleID: UUID) -> Bool {
        pending.values.contains { $0.id == lifecycleID && requestID == notificationID($0.id) }
    }

    func present(_ form: MCPElicitationForm, context: MCPElicitationContext, sessionID: UUID) async throws -> MCPElicitationResult {
        guard context.invocation.isValid, context.serverID.count <= 256,
              context.serverName.count <= 256, pending[sessionID] == nil else {
            return MCPElicitationResult(action: .decline)
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                continuations[context.oneShotID] = continuation
                pending[sessionID] = Pending(sessionID: sessionID, context: context, form: form,
                    texts: Dictionary(uniqueKeysWithValues: form.fields.map { ($0.id, $0.initialText) }))
                onPendingRequestsChanged?()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelWaiter(id: context.oneShotID) }
        }
    }
    func setText(sessionID: UUID, id: UUID, field: String, text: String) {
        guard var value = pending[sessionID], value.id == id,
              value.form.fields.contains(where: { $0.id == field }) else { return }
        guard text.count <= MCPElicitationForm.maximumInputCharacters else {
            value.feedback = "输入最多4000字，超出内容未接受，请缩短。"
            pending[sessionID] = value
            return
        }
        value.texts[field] = text
        value.feedback = nil
        pending[sessionID] = value
    }
    func resolve(sessionID: UUID, id: UUID, action: MCPElicitationResult.Action) {
        guard let value = pending[sessionID], value.id == id else { return }
        do {
            let result = action == .accept ? try value.form.response(texts: value.texts) : MCPElicitationResult(action: action)
            pending.removeValue(forKey: sessionID)
            let continuation = continuations.removeValue(forKey: id)
            onPendingRequestsChanged?()
            continuation?.resume(returning: result)
        } catch {
            pending[sessionID]?.feedback = "回答不符合字段要求或超过限长，请修改后提交。"
        }
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
