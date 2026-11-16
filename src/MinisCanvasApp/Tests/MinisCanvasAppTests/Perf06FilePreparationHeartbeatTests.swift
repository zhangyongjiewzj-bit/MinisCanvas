import Darwin
import Dispatch
import Foundation
import CoreGraphics
import CoreText
import Testing
import MinisCore
@testable import MinisCanvasApp

/// A FIFO makes the production attachment reader wait for bytes. The only
/// writer release comes from a MainActor heartbeat after addAttachments.
/// A synchronous UI-thread read therefore times out before the heartbeat can
/// run; a detached read permits the heartbeat and still reaches the real
/// attachment resolution consumer.
private final class Perf06FIFOProducer: @unchecked Sendable {
    struct Result: Sendable {
        let opened: Bool
        let heartbeatTimedOut: Bool
        let wroteAllBytes: Bool
    }

    private let heartbeat = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var readerOpened = false

    var hasReaderOpened: Bool {
        lock.lock(); defer { lock.unlock() }
        return readerOpened
    }

    func signalMainActorHeartbeat() { heartbeat.signal() }

    func write(_ bytes: Data, to path: String) -> Result {
        var descriptor: Int32 = -1
        for _ in 0..<2_000 {
            descriptor = Darwin.open(path, O_WRONLY | O_NONBLOCK)
            if descriptor >= 0 { break }
            if errno != ENXIO && errno != EINTR {
                return Result(opened: false, heartbeatTimedOut: false, wroteAllBytes: false)
            }
            usleep(1_000)
        }
        guard descriptor >= 0 else {
            return Result(opened: false, heartbeatTimedOut: false, wroteAllBytes: false)
        }
        lock.lock()
        readerOpened = true
        lock.unlock()
        defer { _ = Darwin.close(descriptor) }
        let timedOut = heartbeat.wait(timeout: .now() + .seconds(1)) == .timedOut
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) }
        let wrote = bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return false }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if count == 0 { return false }
                offset += count
            }
            return true
        }
        return Result(opened: true, heartbeatTimedOut: timedOut, wroteAllBytes: wrote)
    }
}

@Suite("PERF06 actual attachment file worker")
@MainActor
struct Perf06FilePreparationHeartbeatTests {
    @Test("a blocked synthetic PDF read leaves MainActor responsive and resolves the owned draft slot")
    func pdfAttachmentReadDoesNotBlockMainActor() async throws {
        let formal = try #require(ProcessInfo.processInfo.environment["MINISCANVAS_TEST_DIRECTORY"])
        let root = URL(fileURLWithPath: formal, isDirectory: true)
            .appendingPathComponent("perf06-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let pipe = root.appendingPathComponent("synthetic-page.pdf")
        try #require(Darwin.mkfifo(pipe.path, 0o600) == 0)

        let producer = Perf06FIFOProducer()
        let bytes = try syntheticPDF()
        let writer = Task.detached { producer.write(bytes, to: pipe.path) }
        let chat = ChatStore()
        let sessionID = try #require(chat.activeSessionID)
        let staged = try #require(chat.addAttachments(urls: [pipe]).first)
        #expect(staged.status == .pending)
        for _ in 0..<100 where !producer.hasReaderOpened {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(producer.hasReaderOpened, "the production worker must actually open the FIFO")
        let heartbeat = Task { @MainActor in producer.signalMainActorHeartbeat() }
        await heartbeat.value
        let write = await writer.value
        #expect(write.opened && write.wroteAllBytes, "the real file reader must consume the synthetic FIFO")
        #expect(!write.heartbeatTimedOut, "attachment I/O held the UI actor before its heartbeat")

        for _ in 0..<300 where chat.pendingAttachments.first?.status == .pending {
            try await Task.sleep(for: .milliseconds(10))
        }
        let resolved = try #require(chat.pendingAttachments.first)
        #expect(chat.activeSessionID == sessionID)
        #expect(resolved.id == staged.id && resolved.status == .ready && resolved.kind == .text)
        #expect(String(data: resolved.data ?? Data(), encoding: .utf8)?
            .contains("PERF06 synthetic PDF text layer") == true)
    }

    private func syntheticPDF() throws -> Data {
        let output = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: output))
        var bounds = CGRect(x: 0, y: 0, width: 300, height: 100)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: "PERF06 synthetic PDF text layer",
            attributes: [NSAttributedString.Key(rawValue: kCTFontAttributeName as String): font]
        ))
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 20, y: 45)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
        return output as Data
    }
}
