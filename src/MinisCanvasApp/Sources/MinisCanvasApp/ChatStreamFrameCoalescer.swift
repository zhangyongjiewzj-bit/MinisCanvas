import Foundation

/// A turn-local MainActor display buffer. Reading provider events never waits
/// for animation: the first delta renders immediately, later text merges at
/// most once per 16ms frame, and semantic barriers/termination flush the tail.
/// Thinking deltas share the same frame timer through their own channel, so a
/// reasoning model's many tiny fragments cost one session write per frame too.
@MainActor
final class ChatStreamFrameCoalescer {
    /// 流畅度第四轮：真实 App 实测流式输出时主线程约 55% 在重排版/视图更新（每帧重排尾段）。
    /// 16ms（约 60 帧/秒）→ 50ms（约 20 帧/秒）：首个字仍立即上屏，后续合并上屏，
    /// 每秒重排次数降到约 1/3；文字流视觉上仍连续。
    static let frameInterval: Duration = .milliseconds(50)

    private var pendingText = ""
    private var pendingThinking = ""
    private var hasDisplayedText = false
    private var hasDisplayedThinking = false
    private var isCancelled = false
    private var frameTask: Task<Void, Never>?
    private let render: (String) -> Bool
    private let renderThinking: (String) -> Bool

    init(render: @escaping (String) -> Bool,
         renderThinking: @escaping (String) -> Bool = { _ in true }) {
        self.render = render
        self.renderThinking = renderThinking
    }

    @discardableResult
    func append(_ text: String) -> Bool {
        guard !isCancelled else { return false }
        guard !text.isEmpty else { return true }
        pendingText.append(contentsOf: text)
        if !hasDisplayedText {
            hasDisplayedText = true
            return flush()
        }
        scheduleFrame()
        return true
    }

    @discardableResult
    func appendThinking(_ text: String) -> Bool {
        guard !isCancelled else { return false }
        guard !text.isEmpty else { return true }
        pendingThinking.append(contentsOf: text)
        if !hasDisplayedThinking {
            hasDisplayedThinking = true
            return flush()
        }
        scheduleFrame()
        return true
    }

    private func scheduleFrame() {
        if frameTask == nil {
            frameTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: Self.frameInterval) }
                catch { return }
                guard !Task.isCancelled, let self else { return }
                self.frameTask = nil
                self.flush()
            }
        }
    }

    /// Called synchronously before a tool/notice event. Cancelling the timer
    /// before draining prevents it from reentering an async tool ingestion.
    /// Thinking drains first: it always precedes the answer it led to.
    @discardableResult
    func flush() -> Bool {
        frameTask?.cancel()
        frameTask = nil
        guard !isCancelled else { return false }
        if !pendingThinking.isEmpty {
            let thinking = pendingThinking
            pendingThinking = ""
            guard renderThinking(thinking) else {
                cancel()
                return false
            }
        }
        guard !pendingText.isEmpty else { return true }
        let text = pendingText
        pendingText = ""
        guard render(text) else {
            cancel()
            return false
        }
        return true
    }

    /// Cancel discards pending text. Stop must never flush an unrendered tail.
    func cancel() {
        isCancelled = true
        frameTask?.cancel()
        frameTask = nil
        pendingText = ""
        pendingThinking = ""
    }
}
