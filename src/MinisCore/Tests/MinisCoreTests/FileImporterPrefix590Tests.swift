import Darwin
import Foundation
import Testing
@testable import MinisCore

private final class Prefix590Result: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    let completed = DispatchSemaphore(value: 0)
    func publish(_ mime: String?) {
        lock.lock(); value = mime; lock.unlock()
        completed.signal()
    }
    func read() -> String? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

@Suite("D-PERF-06 bounded MIME discovery")
struct FileImporterPrefix590Tests {
    @Test("discovery consumes the available header without requiring payload EOF")
    func prefixDoesNotWaitForRemainingPayload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("perf590-prefix-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("owned-header")
        #expect(Darwin.mkfifo(url.path, 0o600) == 0)
        let writer = Darwin.open(url.path, O_RDWR | O_NONBLOCK)
        #expect(writer >= 0)
        guard writer >= 0 else { return }
        defer { Darwin.close(writer) }
        let header: [UInt8] = [0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10, 0, 0, 0, 0]
        let written = header.withUnsafeBytes { Darwin.write(writer, $0.baseAddress, $0.count) }
        #expect(written == header.count)
        let result = Prefix590Result()
        DispatchQueue.global().async {
            result.publish(FileImporter.mimeType(of: url))
        }
        // This is an I/O completion bound, not a throughput requirement.
        // The owned writer remains open, so a whole-stream read cannot use EOF.
        let completed = try await runBlockingTestWork {
            result.completed.wait(timeout: .now() + 5) == .success
        }
        #expect(completed)
        #expect(result.read() == "image/png")
    }

    @Test("an empty owned pipe cannot wait for future input during discovery")
    func emptySpecialFileReturnsWithoutWaiting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("perf590-empty-prefix-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("owned-empty-header")
        #expect(Darwin.mkfifo(url.path, 0o600) == 0)
        let writer = Darwin.open(url.path, O_RDWR | O_NONBLOCK)
        #expect(writer >= 0)
        guard writer >= 0 else { return }
        defer { Darwin.close(writer) }
        let result = Prefix590Result()
        DispatchQueue.global().async { result.publish(FileImporter.mimeType(of: url)) }
        let completed = try await runBlockingTestWork {
            result.completed.wait(timeout: .now() + 5) == .success
        }
        #expect(completed)
        #expect(result.read() == nil)
    }

    @Test("trailing payload cannot change the original magic-byte classification",
          arguments: ["png", "pdf", "mp4"])
    func largePayloadRetainsMagicClassification(format: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("perf590-magic-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let headers: [String: [UInt8]] = [
            "png": [0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10, 0, 0, 0, 0],
            "pdf": Array("%PDF-1.4\nxxx".utf8),
            "mp4": [0, 0, 0, 20, 0x66, 0x74, 0x79, 0x70, 0, 0, 0, 0]
        ]
        let url = root.appendingPathComponent("owned-extensionless")
        var bytes = Data(try #require(headers[format]))
        bytes.append(Data(repeating: 0x61, count: 4 * 1024 * 1024))
        try bytes.write(to: url)
        let expected = ["png": "image/png", "pdf": "application/pdf", "mp4": "video/mp4"]
        #expect(FileImporter.mimeType(of: url) == expected[format])
        #expect(try Data(contentsOf: url) == bytes)
    }
}
