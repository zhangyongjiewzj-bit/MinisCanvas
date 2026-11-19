import AppKit
import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

@Suite("Transcript local file links")
struct TranscriptLocalFileLinkTests {
    private func makeDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptLocalFileLinkTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeFile(_ name: String, in dir: URL, mode: Int = 0o644) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        return url
    }

    @Test("file URL, absolute path and ~/ path resolve to local files")
    func resolvesAllowedForms() throws {
        let home = URL(fileURLWithPath: "/Users/synthetic", isDirectory: true)
        #expect(TranscriptLocalFileLink.resolve(URL(string: "file:///tmp/a.png")!, homeDirectory: home)?.path == "/tmp/a.png")
        #expect(TranscriptLocalFileLink.resolve(URL(string: "file://localhost/tmp/a.png")!, homeDirectory: home)?.path == "/tmp/a.png")
        #expect(TranscriptLocalFileLink.resolve("/tmp/doc.pdf", homeDirectory: home)?.path == "/tmp/doc.pdf")
        #expect(TranscriptLocalFileLink.resolve("~/Desktop/a.txt", homeDirectory: home)?.path == "/Users/synthetic/Desktop/a.txt")
        #expect(TranscriptLocalFileLink.resolve("/tmp/%E4%B8%AD%E6%96%87.txt", homeDirectory: home)?.lastPathComponent == "中文.txt")
    }

    @Test("other schemes, remote file hosts, relative and network-path targets are rejected")
    func rejectsOthers() {
        let home = URL(fileURLWithPath: "/Users/synthetic", isDirectory: true)
        for raw in ["javascript:alert(1)", "ftp://example.com/a", "x-custom://open/1", "tel:123",
                    "file://remote.example/etc/passwd", "relative/path.txt", "//host/share/a", "~other/a"] {
            #expect(TranscriptLocalFileLink.resolve(raw, homeDirectory: home) == nil, "\(raw)")
        }
        #expect(TranscriptLocalFileLink.resolve(nil, homeDirectory: home) == nil)
    }

    @Test("http and https keep the original web rule and are not local")
    func webRuleUnchanged() {
        #expect(TranscriptExternalLink.allowedURL("https://example.com/a") != nil)
        #expect(TranscriptExternalLink.allowedURL("http://example.com/a") != nil)
        #expect(TranscriptExternalLink.allowedURL("https://user:pw@example.com") == nil)
        #expect(TranscriptExternalLink.allowedURL("file:///tmp/a") == nil)
        #expect(TranscriptLocalFileLink.resolve("https://example.com/a") == nil)
    }

    @Test("ordinary files open and folders are revealed")
    func opensOrdinaryTargets() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = try makeFile("picture.png", in: dir)
        let note = try makeFile("notes.txt", in: dir)
        #expect(TranscriptLocalFileLink.action(for: image) == .open(image))
        #expect(TranscriptLocalFileLink.action(for: note) == .open(note))
        #expect(TranscriptLocalFileLink.action(for: dir) == .revealFolder(dir))
    }

    @Test("executable and auto-running extensions are revealed, never opened")
    func blocksExecutableExtensions() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        for ext in TranscriptLocalFileLink.blockedExtensions.sorted() {
            let file = try makeFile("sample.\(ext.uppercased())", in: dir)
            guard case .revealBlocked(let url, _) = TranscriptLocalFileLink.action(for: file) else {
                Issue.record("扩展名 \(ext) 未被拦截")
                continue
            }
            #expect(url == file)
        }
        let bundle = dir.appendingPathComponent("Tool.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        guard case .revealBlocked = TranscriptLocalFileLink.action(for: bundle) else {
            Issue.record(".app 目录未被拦截")
            return
        }
    }

    @Test("a symlink to a blocked type is blocked")
    func blocksSymlinkToScript() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = try makeFile("run.sh", in: dir)
        let link = dir.appendingPathComponent("harmless.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: script)
        guard case .revealBlocked = TranscriptLocalFileLink.action(for: link) else {
            Issue.record("符号链接指向脚本时未被拦截")
            return
        }
    }

    @Test("an ordinary-looking file with an execute bit is blocked")
    func blocksExecuteBit() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let plain = try makeFile("binary-without-extension", in: dir, mode: 0o755)
        guard case .revealBlocked(_, let reason) = TranscriptLocalFileLink.action(for: plain) else {
            Issue.record("执行位未被拦截")
            return
        }
        #expect(reason.contains("执行"))
    }

    @Test("a missing path is reported as missing")
    func missingPath() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ghost = dir.appendingPathComponent("not-there.png")
        #expect(TranscriptLocalFileLink.action(for: ghost) == .missing(ghost))
    }

    @Test("markdown local links keep a destination and sanitization preserves it; remote schemes do not")
    func markdownRoundTrip() {
        let rendered = MarkdownAttributedTextBuilder.build(
            content: "[本地](file:///tmp/a.png) [绝对](/tmp/b.pdf) [怪](x-custom://open) [网页](https://example.com)",
            isMarkdown: true)
        let safe = ReadOnlyAttributedTextView.sanitized(rendered)
        func link(_ text: String) -> URL? {
            let range = (safe.string as NSString).range(of: text)
            return safe.attribute(.link, at: range.location, effectiveRange: nil) as? URL
        }
        #expect(link("本地")?.path == "/tmp/a.png")
        #expect(link("绝对")?.path == "/tmp/b.pdf")
        #expect(link("怪") == nil)
        #expect(link("网页")?.scheme == "https")
    }

    // MC4-029：数据行比表头多的单元格在完成态也要显示。
    @Test("a table row wider than the header keeps its extra cell in the finished rendering")
    func tableRowWiderThanHeaderKeepsExtraCell() {
        let rendered = MarkdownAttributedTextBuilder.build(
            content: "|姓名|状态|\n|---|---|\n|甲|正常|补充信息|", isMarkdown: true)
        #expect(rendered.string.contains("补充信息"))
        #expect(MarkdownAttributedTextBuilder.tableColumnCount([["姓名", "状态"], ["甲", "正常", "补充信息"]]) == 3)
    }

    @Test("path confirmation is remembered per session only")
    @MainActor
    func confirmationIsSessionScoped() {
        let session = UUID()
        #expect(!TranscriptLocalFileLink.isConfirmed(path: "/tmp/a.png", sessionID: session))
        TranscriptLocalFileLink.confirm(path: "/tmp/a.png", sessionID: session)
        #expect(TranscriptLocalFileLink.isConfirmed(path: "/tmp/a.png", sessionID: session))
        #expect(!TranscriptLocalFileLink.isConfirmed(path: "/tmp/b.png", sessionID: session))
        #expect(!TranscriptLocalFileLink.isConfirmed(path: "/tmp/a.png", sessionID: UUID()))
        #expect(!TranscriptLocalFileLink.isConfirmed(path: "/tmp/a.png", sessionID: nil))
    }

    @Test("open disposition: scripts go to the text editor, link files are reveal-only, plain files open")
    func openDispositionByType() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(TranscriptLocalFileLink.openDisposition(for: try makeFile("run.sh", in: dir)) == .textEditor)
        #expect(TranscriptLocalFileLink.openDisposition(for: try makeFile("site.webloc", in: dir)) == .revealOnly)
        #expect(TranscriptLocalFileLink.openDisposition(for: try makeFile("note.txt", in: dir)) == .systemOpen)
    }

    @Test("guarded system open reveals executable types instead of opening them")
    @MainActor
    func guardedSystemOpenRevealsExecutableTypes() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = try makeFile("x.terminal", in: dir)
        var opened = 0, revealed = 0
        let ok = AgentFileOutputActionConsumer.guardedSystemOpen(
            link, open: { _ in opened += 1; return true }, reveal: { _ in revealed += 1; return true }, openText: nil)
        #expect(ok)
        #expect(opened == 0)
        #expect(revealed == 1)
    }

    @Test("inline images: only existing local images inside the project, never remote or sensitive")
    func inlineImagesOnlyLocalInsideProject() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let shot = try makeFile("shot.png", in: root)
        _ = try makeFile("notes.txt", in: root)
        let text = """
        结果如下 ![图](shot.png) 和远程 ![x](https://example.com/a.png)
        \(shot.path)
        notes.txt
        ![不存在](missing.png)
        """
        let urls = TranscriptInlineImages.imageURLs(
            in: text, projectRoot: root, home: URL(fileURLWithPath: "/Users/synthetic"))
        #expect(urls == [shot.resolvingSymlinksInPath()])
        #expect(TranscriptInlineImages.imageURLs(in: "![a](shot.png)", projectRoot: nil).isEmpty)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString).png")
        try Data("x".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        #expect(TranscriptInlineImages.imageURLs(in: "![a](\(outside.path))", projectRoot: root).isEmpty)
    }

    @Test("inline images: bullet lines and browser screenshots in the temp folder show thumbnails")
    func inlineImagesAcceptBulletsAndBrowserShots() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let shot = try makeFile("shot.png", in: root)
        let browserShot = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser_\(UUID().uuidString).png")
        try Data("x".utf8).write(to: browserShot)
        defer { try? FileManager.default.removeItem(at: browserShot) }
        let text = "- \(shot.path)\n* \(browserShot.path)"
        let urls = TranscriptInlineImages.imageURLs(
            in: text, projectRoot: root, home: URL(fileURLWithPath: "/Users/synthetic"))
        #expect(urls.contains(shot.resolvingSymlinksInPath()))
        #expect(urls.contains(browserShot.resolvingSymlinksInPath()))
    }
}

// PF2：附件草稿形态、凭据预览、路径存在性缓存、产物摘要缓存。
@Suite("PF2 附件与产出物")
struct PF2AttachmentArtifactAppTests {
    @Test("草稿附件持久化记录引用形态，旧格式（纯路径数组）仍可读")
    func draftEntriesKeepReferenceShape() throws {
        let reference = ChatAttachment(kind: .file, fileName: "big.log", fileType: .unknown, fileURL: "/tmp/big.log")
        let text = ChatAttachment(kind: .text, fileName: "a.txt", fileType: .text, data: Data("hi".utf8), fileURL: "/tmp/a.txt")
        let failed = ChatAttachment(kind: .file, fileName: "f", fileType: .unknown, fileURL: "/tmp/f", status: .failed)
        let entries = ChatStore.pendingAttachmentDraftEntries(for: [reference, text, failed, reference])
        #expect(entries == [
            ChatStore.PendingAttachmentDraftEntry(path: "/tmp/big.log", asReference: true),
            ChatStore.PendingAttachmentDraftEntry(path: "/tmp/a.txt", asReference: false),
        ])
        let roundTrip = ChatStore.decodePendingAttachmentDraftEntries(try JSONEncoder().encode(entries))
        #expect(roundTrip == entries)
        let legacy = ChatStore.decodePendingAttachmentDraftEntries(try JSONEncoder().encode(["/tmp/x"]))
        #expect(legacy == [ChatStore.PendingAttachmentDraftEntry(path: "/tmp/x", asReference: false)])
    }

    @Test("E-8 草稿条目带上音频转写文字，重启后可按路径接回；旧条目没有该字段仍可读")
    func draftEntriesKeepAudioTranscript() throws {
        let transcript = AudioTranscript(text: "你好，世界", localeIdentifier: "zh-CN",
                                         durationSeconds: 3, onDevice: true, edited: true)
        var audio = ChatAttachment(kind: .audio, fileName: "a.wav", fileType: .audio,
                                   mimeType: "audio/wav", data: Data([0]), fileURL: "/tmp/a.wav")
        audio.audioTranscript = transcript
        let entries = ChatStore.pendingAttachmentDraftEntries(for: [audio])
        #expect(entries.first?.audioTranscript == transcript)
        let roundTrip = ChatStore.decodePendingAttachmentDraftEntries(try JSONEncoder().encode(entries))
        #expect(roundTrip.first?.audioTranscript == transcript)
        let oldJSON = Data(#"[{"path":"/tmp/a.wav","asReference":false}]"#.utf8)
        #expect(ChatStore.decodePendingAttachmentDraftEntries(oldJSON).first?.audioTranscript == nil)
    }

    @Test("无法识别为音频的附件不会被当成可绑回的摘要槽位")
    func invalidAudioKeepsItsBytesInSidecar() {
        let bogus = ChatAttachment(kind: .audio, fileName: "x.mp3", fileType: .audio, mimeType: "audio/mpeg",
                                   data: Data("not audio".utf8))
        let projection = bogus.sidecarProjection
        #expect(projection.payloadDigest == nil)
        #expect(projection.data != nil)
    }

    @Test("文件树不预览 .env 这类凭据文件")
    func fileTreeRefusesCredentialPreview() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pf2-env-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let env = dir.appendingPathComponent(".env")
        try Data("TOKEN=secret-value".utf8).write(to: env)
        let preview = FilePreview.load(url: env)
        #expect(preview.error == "可能含密钥，未读取")
        #expect(preview.text == nil)
    }

    @Test("路径存在性检查在缓存期内不重复访问磁盘")
    func pathExistenceIsCached() {
        TranscriptPathExistenceCache.resetForTesting()
        var calls = 0
        let path = "/synthetic/pf2/\(UUID().uuidString)"
        let now = Date()
        #expect(!TranscriptPathExistenceCache.exists(path, now: now, check: { _ in calls += 1; return false }))
        #expect(!TranscriptPathExistenceCache.exists(path, now: now.addingTimeInterval(5), check: { _ in calls += 1; return true }))
        #expect(calls == 1)
        #expect(TranscriptPathExistenceCache.exists(path, now: now.addingTimeInterval(60), check: { _ in calls += 1; return true }))
        #expect(calls == 2)
    }

    @Test("产出物摘要：小文件同步核验，内容一变摘要随之改变")
    func generatedDigestFollowsContent() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pf2-digest-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("out.txt")
        try Data("one".utf8).write(to: file)
        let first = try #require(AgentFileOutputTargetResolver.generatedFileDigestDeferringLarge(file))
        #expect(AgentFileOutputTargetResolver.generatedFileDigestDeferringLarge(file) == first)
        try Data("two!".utf8).write(to: file)
        let second = try #require(AgentFileOutputTargetResolver.generatedFileDigestDeferringLarge(file))
        #expect(second != first)
    }
}
