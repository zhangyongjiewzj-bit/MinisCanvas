import Testing
import Foundation
@testable import MinisCanvasApp

@Suite("Stream display frame budget")
@MainActor
struct ChatStreamFrameCoalescerTests {
    @Test func burstRendersFirstTextImmediatelyAndMergesLaterDeltas() {
        var rendered: [String] = []
        let display = ChatStreamFrameCoalescer { rendered.append($0); return true }
        #expect(display.append(""))
        #expect(rendered.isEmpty)
        #expect(display.append("首"))
        #expect(rendered == ["首"])
        let deltas = (0..<128).map { _ in "e\u{301}🙂" }
        for delta in deltas { #expect(display.append(delta)) }
        #expect(rendered.count == 1, "微分片不能逐事件重建正文")
        #expect(display.flush())
        #expect(rendered == ["首", deltas.joined()])
        print("SYNTHETIC_STREAM render_updates=\(rendered.count) buffered_deltas=128 unicode_preserved=true")
        display.cancel()
    }

    @Test func quietProducerStillFlushesThePendingFrame() async throws {
        var rendered: [String] = []
        let display = ChatStreamFrameCoalescer { rendered.append($0); return true }
        display.append("首")
        display.append("尾")
        let deadline = ContinuousClock.now + .seconds(1)
        while rendered.count < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(rendered == ["首", "尾"])
        display.cancel()
    }

    @Test func cancellationDiscardsThePendingFrameSynchronously() async throws {
        var rendered: [String] = []
        let display = ChatStreamFrameCoalescer { rendered.append($0); return true }
        display.append("首")
        display.append("不得补回")
        display.cancel()
        #expect(!display.flush())
        #expect(!display.append("迟到"))
        try await Task.sleep(for: .milliseconds(50))
        #expect(rendered == ["首"])
    }

    @Test func retiredWritebackGateRejectsAnAlreadyScheduledFrame() async throws {
        var acceptsWriteback = true
        var rendered: [String] = []
        let display = ChatStreamFrameCoalescer { text in
            guard acceptsWriteback else { return false }
            rendered.append(text)
            return true
        }
        display.append("首")
        display.append("待显")
        acceptsWriteback = false
        try await Task.sleep(for: ChatStreamFrameCoalescer.frameInterval + .milliseconds(150))
        #expect(rendered == ["首"])
        #expect(!display.append("迟到"))
    }
}
