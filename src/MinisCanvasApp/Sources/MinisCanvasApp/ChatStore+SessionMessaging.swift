import Foundation
import MinisCore

/// `session_send` / `task_board` 在 App 侧的实现：解析目标会话、投递消息、让目标会话开始一轮。
/// 所有对 ChatStore 的读写都回到主线程；目标会话沿用它自己的模式、权限与审批。
final class ChatStoreSessionMessagingBridge: SessionMessagingBridge, @unchecked Sendable {
    private weak var store: ChatStore?

    init(store: ChatStore) { self.store = store }

    func resolveTarget(_ raw: String, excluding sourceSessionID: String) async -> SessionMessagingResolution {
        await MainActor.run { () -> SessionMessagingResolution in
            guard let store else { return .unavailable("应用状态不可用，不能发送。") }
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let id = UUID(uuidString: key) {
                if let thread = store.sessions.first(where: { $0.id == id }) {
                    return .found(SessionMessagingTarget(id: thread.id.uuidString, title: thread.title))
                }
                if store.archivedSessions.contains(where: { $0.id == id }) {
                    return .unavailable("目标会话已归档，不能发送。")
                }
                return .unavailable("目标会话不存在或已删除，不能发送。")
            }
            let lowered = key.lowercased()
            let matches = store.sessions.filter {
                $0.title.lowercased() == lowered && $0.id.uuidString != sourceSessionID
            }
            switch matches.count {
            case 0: return .notFound
            case 1: return .found(SessionMessagingTarget(id: matches[0].id.uuidString, title: matches[0].title))
            default:
                return .ambiguous(matches.map { SessionMessagingTarget(id: $0.id.uuidString, title: $0.title) })
            }
        }
    }

    func title(ofSession id: String) async -> String {
        await MainActor.run { () -> String in
            guard let store, let uuid = UUID(uuidString: id) else { return "" }
            return store.sessions.first(where: { $0.id == uuid })?.title
                ?? store.archivedSessions.first(where: { $0.id == uuid })?.title ?? ""
        }
    }

    /// 当前这一轮由哪条消息触发：最近一条用户消息若是其它会话的信封，就继承它的 hop。
    func currentHop(ofSession id: String) async -> Int {
        await MainActor.run { () -> Int in
            guard let store, let uuid = UUID(uuidString: id),
                  let thread = store.sessions.first(where: { $0.id == uuid }),
                  let last = thread.messages.last(where: { $0.role == .user }) else { return 0 }
            if let envelope = SessionMessageEnvelope.parse(last.content) { return envelope.hop }
            // Stop 钩子续跑那一轮：沿用触发它的那一轮的层数，不能归零。
            if last.content.hasPrefix(ChatStore.stopContinuationPrefix) {
                return store.stopContinuationHops[uuid] ?? 0
            }
            return 0
        }
    }

    func projectID(ofSession id: String) async -> String? {
        await MainActor.run { () -> String? in
            guard let store, let uuid = UUID(uuidString: id) else { return nil }
            return store.sessions.first(where: { $0.id == uuid })?.projectID
        }
    }

    func deliver(_ message: SessionMessageDelivery, to targetID: String) async throws {
        let ok = await MainActor.run { () -> Bool in
            guard let store, let uuid = UUID(uuidString: targetID) else { return false }
            return store.deliverSessionMessage(message.envelopeText, toSession: uuid)
        }
        guard ok else {
            throw SessionMessagingError.rejected("目标会话正在生成或已不可用，没有投递；请稍后再试，或改用 run 模式排队。")
        }
    }

    func startRun(_ message: SessionMessageDelivery, in targetID: String) async throws -> SessionRunStart {
        let result = await MainActor.run { () -> SessionRunStart? in
            guard let store, let uuid = UUID(uuidString: targetID),
                  store.sessions.contains(where: { $0.id == uuid }) else { return nil }
            return store.startSessionMessageRun(message.envelopeText, inSession: uuid)
        }
        guard let result else { throw SessionMessagingError.rejected("目标会话已不可用，不能发送。") }
        return result
    }
}
