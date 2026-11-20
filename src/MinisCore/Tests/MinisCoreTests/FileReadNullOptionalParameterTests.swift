import Foundation
import Testing
@testable import MinisCore

/// 用户 11/20 会话 893B52D5：ChatGPT 模型把未用的可选参数填成 null，
/// 文本文件因 page_start/page_count 为 null 被判“仅适用于 PDF”而连续失败。
struct FileReadNullOptionalParameterTests {
    private func makeTextFile() throws -> (BuiltinToolExecutor, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileReadNullOptional-\(UUID().uuidString)/GO手测", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("pelican-ride.html")
        try String(repeating: "<p>鹈鹕</p>\n", count: 50).write(to: file, atomically: true, encoding: .utf8)
        return (BuiltinToolExecutor(allowedRoot: root), file)
    }

    @Test func nullOptionalParametersReadLikeAbsentOnes() async throws {
        let (executor, file) = try makeTextFile()
        let plain = try await executor.execute(name: "file_read", input: ["path": file.path])
        let withNulls = try await executor.execute(name: "file_read", input: [
            "path": file.path, "offset": NSNull(), "lines": NSNull(), "max_length": NSNull(),
            "direction": NSNull(), "page_start": NSNull(), "page_count": NSNull(), "as_images": NSNull(),
        ])
        #expect(withNulls == plain)
        #expect(withNulls.contains("鹈鹕"))
    }

    @Test func explicitPageParametersOnTextFileStillExplainTheyArePDFOnly() async throws {
        let (executor, file) = try makeTextFile()
        await #expect(throws: ToolExecutorError.self) {
            _ = try await executor.execute(name: "file_read", input: ["path": file.path, "page_start": 2])
        }
    }
}
