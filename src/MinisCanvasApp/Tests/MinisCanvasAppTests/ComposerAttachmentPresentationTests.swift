import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

// MARK: - D-COMPOSER-04（COMPOSER-04/08）附件状态视图模型合同
//
// 锁住三件事：
//   1. chip 状态只从附件既有事实投影，未成功态不得冒充成功；
//   2. 类型副标题来自 FileType 分类事实源，占位符期间类型不丢失；
//   3. 无障碍值同时含文件名、类型和状态（清单 L193/L197）。
@Suite("Composer attachment presentation state (D-COMPOSER-04)")
@MainActor
struct ComposerAttachmentPresentationTests {

    private func attachment(
        kind: ChatAttachment.Kind,
        fileType: FileType,
        data: Data?,
        size: Int64? = nil
    ) -> ChatAttachment {
        ChatAttachment(
            kind: kind,
            fileName: "sample.\(fileType.rawValue)",
            fileType: fileType,
            mimeType: nil,
            size: size ?? Int64(data?.count ?? 0),
            data: data,
            fileURL: "/tmp/sample"
        )
    }

    @Test("Goal18 text range uses the actual original character count")
    func exactOriginalCountControlsTruncationNotice() {
        let capped = ChatAttachment(kind: .text, fileName: "long.txt", fileType: .text,
            data: Data(String(repeating: "字", count: 4_000).utf8), originalTextCharacterCount: 12_345)
        #expect(ComposerAttachmentPresentation.status(for: capped) == .injectedAtCap)
        #expect(ComposerAttachmentPresentation.truncationNotice(for: capped, sent: true) == "已发送前 4000 字 / 共 12345 字，其余可让模型读取原文件")
        let exact = ChatAttachment(kind: .text, fileName: "exact.txt", fileType: .text,
            data: Data(String(repeating: "字", count: 4_000).utf8), originalTextCharacterCount: 4_000)
        #expect(ComposerAttachmentPresentation.status(for: exact) == .ready)
        #expect(ComposerAttachmentPresentation.truncationNotice(for: exact, sent: true) == nil)
        let unknown = ChatAttachment(kind: .text, fileName: "old.txt", fileType: .text,
            data: Data(String(repeating: "字", count: 4_000).utf8))
        #expect(ComposerAttachmentPresentation.truncationNotice(for: unknown, sent: true) == nil)
        let unicode = ChatAttachment(kind: .text, fileName: "unicode.txt", fileType: .text,
            data: Data("e\u{301}🙂".utf8), originalTextCharacterCount: 3)
        #expect(ComposerAttachmentPresentation.truncationNotice(for: unicode, sent: false)?.contains("前 2 字 / 共 3 字") == true)
    }

    @Test("loaded image and audio project ready")
    func readyBinaryAttachments() {
        let image = attachment(kind: .image, fileType: .image, data: Data([0xFF, 0xD8]))
        #expect(ComposerAttachmentPresentation.status(for: image) == .ready)
        let audio = attachment(kind: .audio, fileType: .audio, data: Data("caf".utf8))
        #expect(ComposerAttachmentPresentation.status(for: audio) == .ready)
    }

    @Test("unresolved placeholders never claim success")
    func pendingPlaceholdersAreNotSuccess() {
        // addAttachments 先落的占位符：kind == .file，类型信息保留在 fileType。
        for fileType in [FileType.image, .audio, .text, .markdown, .json] {
            let placeholder = attachment(kind: .file, fileType: fileType, data: nil)
            let status = ComposerAttachmentPresentation.status(for: placeholder)
            #expect(status == .resolvingOrDegraded, "placeholder \(fileType) must stay unresolved")
            #expect(!status.claimsSuccess)
            // 占位符期间类型信息不丢失：类型来自 fileType，与升级后的同类附件一致。
            let resolvedSibling = attachment(
                kind: fileType == .text || fileType == .markdown || fileType == .json ? .text : (fileType == .audio ? .audio : .image),
                fileType: fileType,
                data: Data([0x00])
            )
            #expect(ComposerAttachmentPresentation.typeLabel(for: placeholder)
                    == ComposerAttachmentPresentation.typeLabel(for: resolvedSibling))
        }
    }

    @Test("read-failure degraded attachment keeps the same honest state as in-flight")
    func degradedReadIsNotSuccess() {
        // 读取失败/超限终态与在途占位符同形状（候选源码无完成信号）——都不得投影为成功。
        let degraded = attachment(kind: .file, fileType: .image, data: nil, size: 30 * 1024 * 1024)
        #expect(ComposerAttachmentPresentation.status(for: degraded) == .resolvingOrDegraded)
        #expect(!ComposerAttachmentPresentation.status(for: degraded).claimsSuccess)
    }

    @Test("video and unknown types are terminal file references, not pending reads")
    func terminalReferenceOnlyTypes() {
        let video = attachment(kind: .file, fileType: .video, data: nil)
        #expect(ComposerAttachmentPresentation.status(for: video) == .referenceOnly)
        let unknown = attachment(kind: .file, fileType: .unknown, data: nil)
        #expect(ComposerAttachmentPresentation.status(for: unknown) == .referenceOnly)
    }

    @Test("cap equality alone does not claim truncation")
    func textInjectionCap() {
        let short = attachment(
            kind: .text, fileType: .text,
            data: Data(String(repeating: "字", count: 10).utf8)
        )
        #expect(ComposerAttachmentPresentation.status(for: short) == .ready)

        let capped = attachment(
            kind: .text, fileType: .text,
            data: Data(String(repeating: "a", count: ChatStore.maxTextAttachmentChars).utf8)
        )
        #expect(ComposerAttachmentPresentation.status(for: capped) == .ready)
        #expect(ComposerAttachmentPresentation.status(for: capped).claimsSuccess)

        let undecodable = attachment(kind: .file, fileType: .text, data: nil)
        #expect(ComposerAttachmentPresentation.status(for: undecodable) == .resolvingOrDegraded)
    }

    @Test("type labels come from the classification source, not the coarse kind")
    func typeLabels() {
        let cases: [(FileType, String)] = [
            (.text, "文本"), (.markdown, "Markdown"), (.json, "JSON"),
            (.image, "图片"), (.audio, "音频"), (.video, "视频"), (.unknown, "未知类型"),
        ]
        for (fileType, label) in cases {
            let att = attachment(kind: .file, fileType: fileType, data: nil)
            #expect(ComposerAttachmentPresentation.typeLabel(for: att) == label)
        }
    }

    @Test("accessibility value carries name, type and status together")
    func accessibilityValueCompleteness() {
        let placeholder = attachment(kind: .file, fileType: .image, data: nil, size: 1234)
        let value = ComposerAttachmentPresentation.accessibilityValue(for: placeholder)
        #expect(value.contains(placeholder.fileName))
        #expect(value.contains("图片"))
        #expect(value.contains("读取中或已降级为文件引用"))

        let ready = attachment(kind: .image, fileType: .image, data: Data([0x01]), size: 1)
        let readyValue = ComposerAttachmentPresentation.accessibilityValue(for: ready)
        #expect(readyValue.contains("就绪"))
        #expect(!readyValue.contains("失败"))
    }
}
