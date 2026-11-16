import Foundation

/// A turn-local MainActor display buffer. Reading provider events never waits
/// for animation: the first delta renders immediately, later text merges at
/// most once per 16ms frame, and semantic barriers/termination flush the tail.
@MainActor
final class ChatStreamFrameCoalescer {
    private var pendingText = ""
    private var hasDisplayedText = false
    private var isCancelled = false
    private var frameTask: Task<Void, Never>?
    private let render: (String) -> Bool

    init(render: @escaping (String) -> Bool) {
        self.render = render
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
        if frameTask == nil {
            frameTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(16)) }
                catch { return }
                guard !Task.isCancelled, let self else { return }
                self.frameTask = nil
                self.flush()
            }
        }
        return true
    }

    /// Called synchronously before a tool/notice event. Cancelling the timer
    /// before draining prevents it from reentering an async tool ingestion.
    @discardableResult
    func flush() -> Bool {
        frameTask?.cancel()
        frameTask = nil
        guard !isCancelled else { return false }
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
    }
}
