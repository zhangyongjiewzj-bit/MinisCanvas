import Foundation
import Testing
@testable import MinisCore

/// 2026-11-16 内置工具修复：file_read 窗口与续读提示、相对路径、web_fetch 全文落盘、
/// 输出上限按字符计、轮询类工具不被误判循环、后台命令默认不限时。
struct BuiltinToolFixes20261116W4Tests {
    private func withRoot(_ operation: (URL) async throws -> Void) async throws {
        let root = try minisCoreToolContractRoot("w4-tools").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        try await operation(root)
    }

    // MARK: file_read

    @Test func fileReadOffsetPastEndSaysHowManyLinesExist() async throws {
        try await withRoot { root in
            try "a\nb\n".write(to: root.appendingPathComponent("short.txt"), atomically: true, encoding: .utf8)
            let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
            let output = try await executor.execute(name: "file_read",
                input: ["path": root.appendingPathComponent("short.txt").path, "offset": 10])
            #expect(output.contains("past the end") && output.contains("2 line"))
        }
    }

    @Test func fileReadHandlesCRLFAndLegacyChineseEncoding() async throws {
        try await withRoot { root in
            try "l1\r\nl2\r\nl3".write(to: root.appendingPathComponent("crlf.txt"), atomically: true, encoding: .utf8)
            let gb18030 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
            try #require("中文内容".data(using: String.Encoding(rawValue: gb18030))).write(to: root.appendingPathComponent("gbk.txt"))
            let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
            let crlf = try await executor.execute(name: "file_read", input: ["path": root.appendingPathComponent("crlf.txt").path, "offset": 2, "lines": 1])
            #expect(crlf == "     2\tl2")
            let gbk = try await executor.execute(name: "file_read", input: ["path": root.appendingPathComponent("gbk.txt").path])
            #expect(gbk == "     1\t中文内容")
        }
    }

    /// T-06：带 BOM 的 UTF-16 文本按文本读出（file_read、file_grep），不再当二进制拒读；无 BOM 的含 0 字节文件仍拒读。
    @Test func fileReadAndGrepDecodeBOMUTF16TextButStillRejectBinary() async throws {
        try await withRoot { root in
            let utf16 = try #require("hello 世界\nsecond line".data(using: .utf16))  // 带 BOM（小端）
            #expect(utf16.starts(with: [0xFF, 0xFE]) || utf16.starts(with: [0xFE, 0xFF]))
            try utf16.write(to: root.appendingPathComponent("win.txt"))
            try Data([0, 110, 101, 101, 100, 108, 101]).write(to: root.appendingPathComponent("real.bin"))
            let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
            let read = try await executor.execute(name: "file_read", input: ["path": root.appendingPathComponent("win.txt").path])
            #expect(read == "     1\thello 世界\n     2\tsecond line")
            let grep = try await executor.execute(name: "file_grep", input: ["path": root.path, "pattern": "second"])
            #expect(grep.contains("win.txt") && grep.contains("second line"))
            await #expect(throws: ToolExecutorError.self) {
                _ = try await executor.execute(name: "file_read", input: ["path": root.appendingPathComponent("real.bin").path])
            }
        }
    }

    @Test func fileReadTruncationTellsWhereToContinue() async throws {
        try await withRoot { root in
            let text = (1...100).map { "line \($0)" }.joined(separator: "\n")
            try text.write(to: root.appendingPathComponent("long.txt"), atomically: true, encoding: .utf8)
            let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
            let output = try await executor.execute(name: "file_read",
                input: ["path": root.appendingPathComponent("long.txt").path, "max_length": 40])
            #expect(output.hasPrefix("     1\tline 1\n     2\tline 2"))
            #expect(output.contains("showing lines 1-") && output.contains("of 100") && output.contains("continue with offset="))
        }
    }

    @Test func fileReadExplainsImagesInsteadOfFailing() async throws {
        try await withRoot { root in
            let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0])
            try png.write(to: root.appendingPathComponent("pic.png"))
            let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
            let output = try await executor.execute(name: "file_read", input: ["path": root.appendingPathComponent("pic.png").path])
            #expect(output.contains("这是图片文件") && output.contains("png"))
        }
    }

    @Test func fileReadResolvesRelativeAndHomePathsAndExplainsDotDot() async throws {
        try await withRoot { root in
            try "hello".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
            let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
            #expect(try await executor.execute(name: "file_read", input: ["path": "notes.txt"]) == "     1\thello")
            #expect(try await executor.execute(name: "file_read", input: ["path": "./notes.txt"]) == "     1\thello")
            await #expect(throws: ToolExecutorError.invalidParameter("path 需要绝对路径（不能含 ..）：../x")) {
                _ = try await executor.execute(name: "file_read", input: ["path": "../x"])
            }
        }
        #expect(ToolPathResolution.absolutePath(for: "~/a/b", workingDirectory: "/w") == NSHomeDirectory() + "/a/b")
        #expect(ToolPathResolution.absolutePath(for: "src/./a", workingDirectory: "/w") == "/w/src/a")
        #expect(ToolPathResolution.absolutePath(for: "~bob/a", workingDirectory: "/w") == nil)
        #expect(ToolPathResolution.absolutePath(for: "/abs", workingDirectory: "/w") == nil)
    }

    @Test func largeFileHeadAndTailReadWithoutLoadingEverything() async throws {
        try await withRoot { root in
            let file = root.appendingPathComponent("big.log")
            var body = ""
            body.reserveCapacity(14_000_000)
            for index in 1...1_200_000 { body += "row \(index)\n" }
            try body.write(to: file, atomically: true, encoding: .utf8)
            let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
            let head = try await executor.execute(name: "file_read", input: ["path": file.path, "offset": 1_199_999, "lines": 2])
            #expect(head.hasPrefix("1199999\trow 1199999\n1200000\trow 1200000"))
            let tail = try await executor.execute(name: "file_read", input: ["path": file.path, "direction": "tail", "lines": 2])
            #expect(tail.hasPrefix("row 1199999\nrow 1200000"))
        }
    }

    // MARK: file_edit

    @Test func fileEditRefusesPDFAndEditsCRLFFilesKeepingLineEndings() async throws {
        try await withRoot { root in
            let pdf = root.appendingPathComponent("doc.pdf")
            try Data("%PDF-1.4\n%%EOF\n".utf8).write(to: pdf)
            let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
            do {
                _ = try await executor.execute(name: "file_edit", input: ["path": pdf.path, "old_string": "x", "new_string": "y"])
                Issue.record("editing a PDF must fail")
            } catch {
                #expect(error.localizedDescription.contains("PDF 无法编辑"))
            }
            let file = root.appendingPathComponent("crlf.txt")
            try Data("a\r\nb\r\nc\r\n".utf8).write(to: file)
            _ = try await executor.execute(name: "file_edit", input: ["path": file.path, "old_string": "a\nb", "new_string": "x\ny"])
            #expect(try Data(contentsOf: file) == Data("x\r\ny\r\nc\r\n".utf8))
        }
    }

    @Test func fileEditSingleLineToMultilineOnCRLFFileKeepsCRLF() async throws {
        try await withRoot { root in
            let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
            let file = root.appendingPathComponent("single.bat")
            try Data("A\r\nB\r\n".utf8).write(to: file)
            _ = try await executor.execute(name: "file_edit", input: ["path": file.path, "old_string": "B", "new_string": "x\ny"])
            #expect(try Data(contentsOf: file) == Data("A\r\nx\r\ny\r\n".utf8))
        }
    }

    @Test func fileEditMixedLineEndingsCountsAndReplacesBothForms() async throws {
        try await withRoot { root in
            let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
            let file = root.appendingPathComponent("mixed.txt")
            try Data("A\nB\r\nA\r\nB\r\n".utf8).write(to: file)
            do {
                _ = try await executor.execute(name: "file_edit", input: ["path": file.path, "old_string": "A\nB", "new_string": "Z"])
                Issue.record("two matches without replace_all must be reported as ambiguous")
            } catch {
                #expect(error.localizedDescription.contains("2 locations"))
            }
            _ = try await executor.execute(name: "file_edit", input: ["path": file.path, "old_string": "A\nB", "new_string": "Z", "replace_all": true])
            #expect(try Data(contentsOf: file) == Data("Z\r\nZ\r\n".utf8))
        }
    }

    @Test func fileEditMultilineOnCRLFFileWorksWithCheckpointsEnabledAndRestores() async throws {
        try await withRoot { root in
            let store = try FileCheckpointStore(directory: root.appendingPathComponent("cp"), allowedRoots: [root])
            let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
            executor.fileCheckpointsEnabled = true
            executor.fileCheckpointStore = store
            executor.fileChangeSessionID = "s"
            let file = root.appendingPathComponent("crlf.txt")
            try Data("a\r\nb\r\nc\r\n".utf8).write(to: file)
            _ = try await executor.execute(name: "file_edit", input: ["path": file.path, "old_string": "a\nb", "new_string": "x\ny"])
            #expect(try Data(contentsOf: file) == Data("x\r\ny\r\nc\r\n".utf8))
            let summary = try #require(store.summaries(sessionID: "s").first)
            _ = try store.restore(summary.id, sessionID: "s")
            #expect(try Data(contentsOf: file) == Data("a\r\nb\r\nc\r\n".utf8))
        }
    }

    @Test func fileWriteRefusesToOverwriteNonUTF8TextFile() async throws {
        try await withRoot { root in
            let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
            let file = root.appendingPathComponent("gbk.txt")
            let gbk = Data([0xC4, 0xE3, 0xBA, 0xC3]) // GBK「你好」
            try gbk.write(to: file)
            executor.markFileRead(path: file.path)
            do {
                _ = try await executor.execute(name: "file_write", input: ["path": file.path, "content": "新内容"])
                Issue.record("overwriting a non-UTF-8 file must be refused")
            } catch {
                #expect(error.localizedDescription.contains("UTF-8"))
            }
            #expect(try Data(contentsOf: file) == gbk)
        }
    }

    /// F-09：file_read 能读出带 BOM 的 UTF-16 正文后，"读完整份写回"不能悄悄把文件改成 UTF-8；
    /// 和 GBK 一样拒绝并说明，文件字节不变（覆盖写与追加都拒绝）。
    @Test func fileWriteRefusesToOverwriteBOMUTF16File() async throws {
        try await withRoot { root in
            let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
            let little = try #require("hello 世界\nsecond line".data(using: .utf16LittleEndian))
            let big = try #require("hello 世界".data(using: .utf16BigEndian))
            for (name, body) in [("le.txt", Data([0xFF, 0xFE]) + little), ("be.txt", Data([0xFE, 0xFF]) + big)] {
                let file = root.appendingPathComponent(name)
                try body.write(to: file)
                let read = try await executor.execute(name: "file_read", input: ["path": file.path])
                #expect(read.contains("hello 世界"))
                for append in [false, true] {
                    do {
                        _ = try await executor.execute(name: "file_write",
                            input: ["path": file.path, "content": "新内容", "append": append])
                        Issue.record("\(name): overwriting a UTF-16 file must be refused (append=\(append))")
                    } catch {
                        #expect(error.localizedDescription.contains("UTF-16"))
                    }
                    #expect(try Data(contentsOf: file) == body)
                }
            }
        }
    }

    // MARK: shell

    @Test func shellOutputWithInvalidUTF8KeepsTheReadableText() async throws {
        try await withRoot { root in
            let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
            let input: [String: Any] = ["command": #"printf 'caf\351 ok\n'"#, "cwd": root.path]
            let result = try await withFreshShellApprovalForTest(input: input) {
                try await executor.execute(name: "shell_execute", input: input)
            }
            let object = try #require(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
            let stdout = try #require(object["stdout"] as? String)
            #expect(stdout.hasPrefix("caf") && stdout.contains("ok"))
        }
    }

    // MARK: web_fetch

    @Test func webFetchKeepsLinksAndDecodesGBKAndJSON() throws {
        let html = ##"<html><body><p>看 <a href="/doc">文档</a> 和 <a href="#top">顶部</a></p></body></html>"##
        let text = try WebFetchRenderer.text(from: Data(html.utf8), mimeType: "text/html", characterEncoding: "utf-8")
        #expect(text.contains("[文档](/doc)") && !text.contains("](#top)"))
        let gb18030 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        let gbk = try #require("<html><body>你好</body></html>".data(using: String.Encoding(rawValue: gb18030)))
        #expect(try WebFetchRenderer.text(from: gbk, mimeType: "text/html", characterEncoding: "gbk") == "你好")
        #expect(try WebFetchRenderer.text(from: Data(#"{"a":1}"#.utf8), mimeType: "application/json", characterEncoding: nil) == #"{"a":1}"#)
        #expect(try WebFetchRenderer.text(from: Data("<rss/>".utf8), mimeType: "application/rss+xml", characterEncoding: nil) == "<rss/>")
        #expect(try WebFetchRenderer.text(from: Data(), mimeType: "application/pdf", characterEncoding: nil).contains("file_read"))
    }

    @Test func webFetchSavesFullTextWhenLongAndGivesItsPath() async throws {
        try await withRoot { root in
            let storage = root.appendingPathComponent("session-storage")
            let project = root.appendingPathComponent("project")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let page = String(repeating: "字", count: 60_000)
            let transport = WebFetchTransport(allowedDomains: ["example.test"], load: { url in
                WebFetchHop(response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/plain; charset=utf-8"])!, body: Data(page.utf8))
            })
            let executor = BuiltinToolExecutor(allowedRoot: project, deniedRoots: [storage],
                appPrivateDeniedRoots: [storage], webFetch: transport)
            let scope = ToolOutputArtifactSessionScope(sessionStorageRoot: storage, sessionID: UUID())
            let result = try await ToolOutputArtifactSessionScope.$current.withValue(scope) {
                try await executor.execute(name: "web_fetch", input: ["url": "https://example.test/"])
            }
            let object = try #require(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
            #expect(object["content_truncated"] as? Bool == true)
            #expect(object["total_characters"] as? Int == 60_000)
            #expect((object["untrustedPageContent"] as? String)?.count == 40_000)
            let saved = try #require(object["full_content_path"] as? String)
            #expect(try String(contentsOfFile: saved, encoding: .utf8) == page)
        }
    }

    // MARK: output limit counts characters

    @Test func outputLimitKeepsChineseAtFullLengthAndExplainsTruncation() {
        let chinese = String(repeating: "字", count: 90_000)
        #expect(MCPOutputLimiter.project(chinese) == chinese)
        let cut = MCPOutputLimiter.limit([String(repeating: "x", count: 5_000)], to: 2_000)
        #expect(cut.count <= 2_000 && cut.hasPrefix("xxxx") && cut.contains("输出过长") && cut.hasSuffix(MCPOutputLimiter.truncationMarker))
    }

    @Test func oversizedJSONKeepsItsBeginningAndNeverCollapsesToEmptyObject() throws {
        let entries = (1...400).map { #"{"id":\#($0),"name":"item-\#($0)","token":"SECRETVALUE\#($0)"}"# }
        let document = "[" + entries.joined(separator: ",") + "]"
        let streamed = MCPOutputLimiter.limit([document], to: 2_000)
        #expect(streamed != "{}" && streamed.contains(#""id":1"#) && !streamed.contains("SECRETVALUE"))
        let parsed = MCPOutputLimiter.project(document, to: 2_000)
        let object = try #require(JSONSerialization.jsonObject(with: Data(parsed.utf8)) as? [String: Any])
        #expect(object["truncated"] as? Bool == true && object["total_characters"] is Int)
        #expect((object["preview"] as? String)?.hasPrefix("[") == true)
    }

    // MARK: loop detector and background commands

    @Test func pollingAndReadOnlyToolsGetMoreRoomBeforeLoopDetection() {
        let polling = ToolLoopDetector()
        for _ in 0..<11 { polling.recordInvocation(tool: "shell_output", input: ["task_id": "t1"]) }
        #expect(!polling.isLooping())
        polling.recordInvocation(tool: "shell_output", input: ["task_id": "t1"])
        #expect(polling.isLooping())

        let reads = ToolLoopDetector()
        for _ in 0..<5 { reads.recordInvocation(tool: "file_read", input: ["path": "/a"]) }
        #expect(!reads.isLooping())
        reads.recordInvocation(tool: "file_read", input: ["path": "/a"])
        #expect(reads.isLooping())

        let shell = ToolLoopDetector()
        for _ in 0..<3 { shell.recordInvocation(tool: "shell_execute", input: ["command": "x"]) }
        #expect(shell.isLooping())
    }

    @Test func backgroundCommandsHaveNoDefaultTimeLimit() {
        let registry = BackgroundShellRegistry(storageRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent("w4-bg-\(UUID().uuidString)"))
        #expect(registry.resolveTimeout(nil) == 0)
        #expect(registry.resolveTimeout(NSNumber(value: 90)) == 90)
        #expect(registry.resolveTimeout(NSNumber(value: 1_000_000)) == BackgroundShellRegistry.defaultMaximumTimeoutSeconds)
    }
}
