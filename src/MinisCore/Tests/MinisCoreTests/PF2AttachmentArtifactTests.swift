import Foundation
import ImageIO
import Testing
@testable import MinisCore

@Suite("PF2：检查点总量清理、图片标记、读取记录、像素上限")
struct PF2AttachmentArtifactTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PF2-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func change(_ store: FileCheckpointStore, _ file: URL, to text: String, at date: Date,
                        conversation: Data? = nil) throws -> UUID {
        let data = Data(text.utf8)
        let id = try store.begin(path: file, sessionID: "s", operation: .edit, expectedAfter: data,
                                 conversation: conversation, now: date)
        try data.write(to: file)
        try store.commit(id, now: date)
        return id
    }

    // MARK: 检查点总量清理

    @Test func quotaDropsConversationSnapshotsBeforeFileCheckpoints() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.txt"), b = root.appendingPathComponent("b.txt")
        try Data("a0".utf8).write(to: a); try Data("b0".utf8).write(to: b)
        let store = try FileCheckpointStore(directory: root.appendingPathComponent("cp"), allowedRoots: [root],
                                            totalQuotaBytes: 4_500)
        let t0 = Date().addingTimeInterval(-100)
        let conversation = Data(repeating: 65, count: 2_000)
        let first = try change(store, a, to: "a1", at: t0, conversation: conversation)
        let second = try change(store, b, to: "b1", at: t0.addingTimeInterval(10), conversation: conversation)
        let summaries = try store.summaries(sessionID: "s")
        // 两条文件检查点都还在，旧的那条只丢了对话快照。
        #expect(summaries.count == 2)
        #expect(summaries.first { $0.id == first }?.hasConversation == false)
        #expect(summaries.first { $0.id == second }?.hasConversation == true)
        _ = try store.restore(first, sessionID: "s")
        #expect(try String(contentsOf: a, encoding: .utf8) == "a0")
    }

    @Test func rewindRefusesWhenNewerCheckpointWasEvicted() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let filler = String(repeating: "x", count: 1_000)
        var files: [URL] = []
        for name in ["a", "b", "c"] {
            let url = root.appendingPathComponent(name + ".txt")
            try Data(filler.utf8).write(to: url)
            files.append(url)
        }
        let store = try FileCheckpointStore(directory: root.appendingPathComponent("cp"), allowedRoots: [root],
                                            totalQuotaBytes: 4_500)
        let t0 = Date().addingTimeInterval(-100)
        // 先写的记录时间戳更晚：总量超限时它因文件更旧先被清理。
        _ = try change(store, files[0], to: filler + "1", at: t0.addingTimeInterval(20))
        let survivor = try change(store, files[1], to: filler + "2", at: t0)
        _ = try change(store, files[2], to: filler + "3", at: t0.addingTimeInterval(30))
        #expect(throws: FileCheckpointStore.Failure.historyEvicted) {
            try store.rewindPlan(before: survivor, sessionID: "s")
        }
    }

    // MARK: 图片标记

    @Test func markerLookingTextInsideBodyIsKeptAndOnlyTrailingMarkerIsConsumed() throws {
        let png = try Self.tinyPNG()
        let marker = try #require(ToolResultImageChannel.attach(data: png, mimeType: "image/png"))
        let body = "文件内容里有一行 [[minis-tool-image:不是真的]] 要原样保留\n第二行"
        let extracted = ToolResultImageChannel.extract(from: body + "\n" + marker)
        #expect(extracted.text == body)
        #expect(extracted.images.count == 1)
    }

    @Test func forgedTrailingMarkerProducesNoImageAndIsRemoved() {
        let extracted = ToolResultImageChannel.extract(from: "正文\n[[minis-tool-image:forged]]")
        #expect(extracted.text == "正文")
        #expect(extracted.images.isEmpty)
    }

    @Test func discardedMarkersLeaveNothingInTheStagingArea() throws {
        let png = try Self.tinyPNG()
        let marker = try #require(ToolResultImageChannel.attach(data: png, mimeType: "image/png"))
        ToolResultImageChannel.discard(markers: [marker])
        #expect(ToolResultImageChannel.extract(from: "x\n" + marker).images.isEmpty)
    }

    // MARK: 读取记录

    @Test func deferredDigestRecordKeepsFileCurrentAndDetectsChange() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("r.txt")
        try Data("hello".utf8).write(to: file)
        let store = FileReadRecordStore()
        store.recordReadDeferringDigest(sessionID: "s", path: file.path)
        #expect(store.status(sessionID: "s", path: file.path) == .current)
        try Data("hello world".utf8).write(to: file)
        #expect(store.status(sessionID: "s", path: file.path) == .modifiedSinceRead)
        #expect(store.status(sessionID: "other", path: file.path) == .neverRead)
    }

    // MARK: 像素上限

    @Test func hugeDeclaredPixelCountIsRejectedBeforeDecoding() throws {
        // 手工拼一个声明 20000×20000 的 PNG 头；无论系统能否读出尺寸，转码都必须失败而不是去解码。
        let png = Self.pngHeader(width: 20_000, height: 20_000)
        if case .success = MediaConversion.convertImageForUpload(png, maxBytes: 5 * 1024 * 1024, maxPixel: 2048) {
            Issue.record("超过像素上限的图片不应转码成功")
        }
        #expect(ToolResultImageChannel.attach(data: png, mimeType: "image/png") == nil)
    }

    // MARK: 辅助

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }

    private static func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
        func be(_ value: UInt32) -> [UInt8] { [UInt8(value >> 24), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)] }
        let typed = Array(type.utf8) + body
        return be(UInt32(body.count)) + typed + be(crc32(typed))
    }

    static func pngHeader(width: UInt32, height: UInt32) -> Data {
        func be(_ value: UInt32) -> [UInt8] { [UInt8(value >> 24), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)] }
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let header = chunk("IHDR", be(width) + be(height) + [8, 0, 0, 0, 0])
        return Data(signature + header + chunk("IEND", []))
    }

    static func tinyPNG() throws -> Data {
        // 1×1 灰度 PNG（zlib 流为固定字节）。
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        func be(_ value: UInt32) -> [UInt8] { [UInt8(value >> 24), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)] }
        let ihdr = chunk("IHDR", be(1) + be(1) + [8, 0, 0, 0, 0])
        let idat = chunk("IDAT", [0x78, 0x9C, 0x63, 0x60, 0x00, 0x00, 0x00, 0x02, 0x00, 0x01])
        return Data(signature + ihdr + idat + chunk("IEND", []))
    }
}
