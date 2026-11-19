import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

// MARK: - P3-COMP-04 附件两阶段状态可见

/// 覆盖差额契约的三层：
/// 1. ChatAttachment.status 三态（pending/ready/failed）与行内状态文案 statusText；
/// 2. 生产路径置态：addAttachments 占位即 .pending，后台解析完成原位升级
///    .ready（读取成功）/ .failed（读取失败降级文件引用）；无需读取的类型直接 .ready；
/// 3. Codable 向后兼容：旧持久化 JSON 无 status 键按 decode 先例缺省 .ready。
@Suite("P3-COMP-04 附件两阶段状态")
@MainActor
struct Composer04AttachmentStatusTests {
    private func writeTempFile(name: String, data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("composer04-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// 等待后台读取回主线程原位升级（复用 E11 既有轮询等待模式，上限 5s）。
    private func awaitSettled(chat: ChatStore) async throws -> ChatAttachment {
        var waited: TimeInterval = 0
        while chat.pendingAttachments.first?.status == .pending && waited < 5 {
            try await Task.sleep(for: .milliseconds(50))
            waited += 0.05
        }
        return try #require(chat.pendingAttachments.first)
    }

    // MARK: 生产路径置态

    @Test func textPlaceholderIsPendingThenResolvesToReady() async throws {
        let chat = ChatStore()
        let txtURL = try writeTempFile(name: "notes.txt", data: Data("附件状态正文".utf8))
        defer { try? FileManager.default.removeItem(at: txtURL.deletingLastPathComponent()) }

        let added = chat.addAttachments(urls: [txtURL])
        // 主线程同步返回即占位快照：后台读取尚未回跳，状态必须可见为 pending。
        #expect(added.count == 1)
        #expect(added[0].status == .pending)
        #expect(chat.pendingAttachments.first?.status == .pending)
        #expect(chat.pendingAttachments.first?.statusText != nil)

        let settled = try await awaitSettled(chat: chat)
        #expect(settled.status == .ready)
        #expect(settled.statusText == nil)
        #expect(settled.kind == .text)
        #expect(String(data: settled.data ?? Data(), encoding: .utf8) == "附件状态正文")
    }

    @Test func unreadableTextPayloadDowngradesToFailedFileReference() async throws {
        let chat = ChatStore()
        // 非 UTF-8 字节流：文本类型读取解析失败 → 降级文件引用，状态置 failed。
        let brokenURL = try writeTempFile(name: "broken.txt", data: Data([0xFF, 0xFF, 0xFE, 0xFE]))
        defer { try? FileManager.default.removeItem(at: brokenURL.deletingLastPathComponent()) }

        chat.addAttachments(urls: [brokenURL])
        #expect(chat.pendingAttachments.first?.status == .pending)

        let settled = try await awaitSettled(chat: chat)
        #expect(settled.status == .failed)
        #expect(settled.kind == .file)
        #expect(settled.data == nil)
        // Composer 行内可见性契约：failed 必须有非空状态文案。
        #expect(settled.statusText?.isEmpty == false)
    }

    @Test func directFileReferenceAttachmentsStartReadyWithoutPending() throws {
        let chat = ChatStore()
        // 未知二进制不进入后台读取：直接以 ready 文件引用落地（与 E11 既有语义一致）。
        let binURL = try writeTempFile(name: "blob.bin", data: Data([0x00, 0x01]))
        defer { try? FileManager.default.removeItem(at: binURL.deletingLastPathComponent()) }

        let added = chat.addAttachments(urls: [binURL])
        #expect(added[0].status == .ready)
        #expect(chat.pendingAttachments.first?.status == .ready)
        #expect(chat.pendingAttachments.first?.statusText == nil)
    }

    // MARK: statusText 行内文案契约

    @Test func statusTextIsOnlyNonNilForNonReadyStates() {
        let pending = ChatAttachment(kind: .image, fileName: "a.png", fileType: .image, status: .pending)
        let failed = ChatAttachment(kind: .file, fileName: "b.txt", fileType: .text, status: .failed)
        let ready = ChatAttachment(kind: .file, fileName: "c.bin", fileType: .unknown, status: .ready)
        #expect(pending.statusText?.isEmpty == false)
        #expect(failed.statusText?.isEmpty == false)
        #expect(ready.statusText == nil)
    }

    // MARK: Codable 向后兼容（decode 先例缺省 ready）

    @Test func legacyJSONWithoutStatusKeyDecodesAsReady() throws {
        let attachment = ChatAttachment(kind: .text, fileName: "doc.md", fileType: .markdown,
                                        mimeType: "text/markdown", size: 9,
                                        data: Data("payload".utf8), fileURL: "/tmp/doc.md")
        var json = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(attachment)
        ) as! [String: Any]
        // 旧版本持久化 JSON 没有 status 键。
        json.removeValue(forKey: "status")
        #expect(json["fileName"] != nil)
        let legacy = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(ChatAttachment.self, from: legacy)
        #expect(decoded.status == .ready)
        #expect(decoded.id == attachment.id)
        #expect(decoded.kind == .text)
        #expect(decoded.fileName == "doc.md")
        #expect(decoded.data == Data("payload".utf8))
        #expect(decoded.fileURL == "/tmp/doc.md")
    }

    @Test func statusSurvivesEncodeDecodeRoundTrip() throws {
        for status in [ChatAttachment.Status.pending, .ready, .failed] {
            let attachment = ChatAttachment(kind: .file, fileName: "x.bin", fileType: .unknown,
                                            size: 2, status: status)
            let decoded = try JSONDecoder().decode(
                ChatAttachment.self, from: try JSONEncoder().encode(attachment))
            #expect(decoded == attachment)
            #expect(decoded.status == status)
        }
    }

    @Test func messageLevelPersistenceKeepsAttachmentStatusRoundTrip() throws {
        let failed = ChatAttachment(kind: .file, fileName: "y.txt", fileType: .text,
                                    fileURL: "/tmp/y.txt", status: .failed)
        let message = ChatMessageUI(role: .user, content: "hi", attachments: [failed])
        let decoded = try JSONDecoder().decode(
            ChatMessageUI.self, from: try JSONEncoder().encode(message))
        #expect(decoded.attachments.count == 1)
        #expect(decoded.attachments[0].status == .failed)
    }
}
