import Foundation
import Observation

/// 单个工具调用的实时输出尾部。每个调用独立可观察：
/// 一个调用的输出变化只会让读取它的那张卡片重绘，不波及其它调用。
@MainActor
@Observable
final class ShellLiveOutputTail {
    fileprivate(set) var text: String = ""
}

/// 来源线程侧的待投递缓冲：按调用累积文本，约 50ms 合并成一次主线程更新。
/// 只在锁内改状态；同一时刻最多有一个等待中的投递任务。
private final class ShellLiveOutputPending: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [String: String] = [:]
    private var order: [String] = []
    private var flushScheduled = false

    /// 返回 true 表示调用方需要安排一次投递。
    func add(callID: String, text: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if chunks[callID] == nil { order.append(callID) }
        chunks[callID, default: ""] += text
        if flushScheduled { return false }
        flushScheduled = true
        return true
    }

    func drain() -> [(callID: String, text: String)] {
        lock.lock(); defer { lock.unlock() }
        let result = order.compactMap { id in chunks[id].map { (callID: id, text: $0) } }
        chunks.removeAll()
        order.removeAll()
        flushScheduled = false
        return result
    }
}

private let shellLiveOutputPending = ShellLiveOutputPending()

/// 前台命令的实时输出看板：只给界面显示，不进入工具结果和模型历史。
/// 每个工具调用只保留最近一段（尾部），命令结束后由结果卡片接管显示。
@MainActor
final class ShellLiveOutputBoard {
    static let shared = ShellLiveOutputBoard()
    static let tailLimit = 6_000
    static let coalesceInterval: Duration = .milliseconds(50)
    private static let maxTrackedCalls = 40

    private var tails: [String: ShellLiveOutputTail] = [:]
    private var order: [String] = []

    /// 读取某个调用的尾部；没有输出时返回 nil。
    /// 读到的是该调用自己的可观察对象，只订阅这一个调用。
    func tail(for callID: String?) -> String? {
        guard let callID else { return nil }
        let value = tailObject(for: callID).text
        return value.isEmpty ? nil : value
    }

    func append(callID: String, text: String) {
        guard !callID.isEmpty, !text.isEmpty else { return }
        let tail = tailObject(for: callID)
        var current = tail.text + text
        if current.count > Self.tailLimit { current = "…\n" + String(current.suffix(Self.tailLimit)) }
        tail.text = current
    }

    func clear(callID: String) {
        tails.removeValue(forKey: callID)?.text = ""
        order.removeAll { $0 == callID }
    }

    /// 取（或建）调用自己的尾部对象；字典本身不参与观察，
    /// 所以新调用的出现不会让所有读取者失效。
    private func tailObject(for callID: String) -> ShellLiveOutputTail {
        if let existing = tails[callID] { return existing }
        let created = ShellLiveOutputTail()
        tails[callID] = created
        order.append(callID)
        if order.count > Self.maxTrackedCalls {
            tails.removeValue(forKey: order.removeFirst())
        }
        return created
    }

    fileprivate func flushPending() {
        for item in shellLiveOutputPending.drain() {
            append(callID: item.callID, text: item.text)
        }
    }

    /// 可从任意线程调用（AgentLoop 的进度回调）。
    /// 输出块先在来源处累积，约 50ms 合并成一次主线程更新，而不是每块起一个任务。
    nonisolated static func receive(callID: String, text: String) {
        guard !callID.isEmpty, !text.isEmpty else { return }
        guard shellLiveOutputPending.add(callID: callID, text: text) else { return }
        Task { @MainActor in
            try? await Task.sleep(for: coalesceInterval)
            shared.flushPending()
        }
    }
}
