import Foundation
import Testing
@testable import MinisCore

@Suite("Memory Markdown codec")
struct MemoryMarkdownCodecTests {
    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryMarkdown-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    @Test("categories and ordinary bullets parse without executing comments")
    func parsesCategoriesAndIgnoresInstructions() throws {
        let markdown = """
        # 可编辑记忆

        <!-- 这里的文字只是注释，不应被执行 -->
        ## 用户偏好
        - 喜欢深色界面

        ## 经验教训
        - 先验证输入再写入

        ## 安全
        - 不把密钥写入记忆

        ## 一般事实
        - 当前项目使用 Swift
        """

        let document = try MemoryMarkdownCodec.decode(markdown: markdown)
        #expect(document.facts.map(\.category) == [
            .userPref, .lesson, .security, .fact
        ])
        #expect(document.facts.map(\.text) == [
            "喜欢深色界面", "先验证输入再写入", "不把密钥写入记忆", "当前项目使用 Swift"
        ])
        #expect(document.categoryCounts[.userPref] == 1)
        #expect(document.categoryCounts[.security] == 1)
    }

    @Test("export and parse preserve stable fact metadata")
    func roundTripsFacts() throws {
        let scope = MemoryScope(sessionID: "session-1", projectID: "project-1")
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let facts = [
            MemoryFact(
                id: "fact-preference",
                text: "喜欢深色界面",
                sourceSessionID: "source-1",
                createdAt: createdAt,
                category: .userPref,
                memoryScope: scope,
                ownerUserID: "user-1",
                sourceProposalID: "proposal-1",
                sourceRef: "chat://session-1/turn-1",
                contentDigest: MemoryStore.contentDigest(for: "喜欢深色界面")
            ),
            MemoryFact(
                id: "fact-lesson",
                text: "先验证输入再写入",
                sourceSessionID: "source-2",
                createdAt: createdAt.addingTimeInterval(1),
                category: .lesson,
                memoryScope: scope
            )
        ]

        let encoded = try MemoryMarkdownCodec.encode(facts)
        let restored = try MemoryMarkdownCodec.decode(encoded).facts
        #expect(restored == facts)
        #expect(String(decoding: encoded, as: UTF8.self).contains("## 用户偏好"))
        #expect(String(decoding: encoded, as: UTF8.self).contains("喜欢深色界面"))
    }

    @Test("plain Markdown gets deterministic IDs for idempotent re-import")
    func plainMarkdownUsesDeterministicIDs() throws {
        let markdown = "## 一般事实\n\n- 一个可重复导入的事实\n"
        let first = try MemoryMarkdownCodec.decode(markdown: markdown).facts
        let second = try MemoryMarkdownCodec.decode(markdown: markdown).facts
        #expect(first == second)
        #expect(!first[0].id.isEmpty)
        #expect(first[0].createdAt == Date(timeIntervalSince1970: 0))
    }

    @Test("empty, duplicate, malformed, and unsupported input fail closed")
    func rejectsUnsafeInput() throws {
        #expect(throws: MemoryMarkdownCodec.Error.emptyDocument) {
            try MemoryMarkdownCodec.decode(markdown: "# 没有条目\n")
        }
        #expect(throws: MemoryMarkdownCodec.Error.self) {
            try MemoryMarkdownCodec.decode(markdown: "## 一般事实\n- 重复\n- 重复\n")
        }
        #expect(throws: MemoryMarkdownCodec.Error.malformedMetadata(2)) {
            try MemoryMarkdownCodec.decode(markdown: "## 一般事实\n<!-- miniscanvas-memory-fact: broken -->\n- 事实\n")
        }
        #expect(throws: MemoryMarkdownCodec.Error.unsupportedVersion(99)) {
            try MemoryMarkdownCodec.decode(markdown: "<!-- miniscanvas-memory-format: 99 -->\n## 一般事实\n- 事实\n")
        }
        #expect(throws: MemoryMarkdownCodec.Error.malformedVersion(1)) {
            try MemoryMarkdownCodec.decode(markdown: "<!-- miniscanvas-memory-format: nope -->\n## 一般事实\n- 事实\n")
        }
    }

    @Test("MemoryManager Markdown import uses scoped restore and preserves existing facts on conflict")
    func managerUsesScopedRestore() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = MemoryScope(sessionID: "session-1", projectID: "project-1")
        let store = MemoryStore(directory: directory)
        let manager = MemoryManager(store: store)
        let data = Data("## 一般事实\n- 导入事实\n".utf8)

        #expect(try manager.importMarkdown(data, within: scope) == 1)
        #expect(try manager.importMarkdown(data, within: scope) == 0)
        #expect(try store.facts().count == 1)
        #expect(try store.facts().first?.memoryScope == scope)

        let conflictingID = try MemoryMarkdownCodec.decode(data).facts[0].id
        let conflicting = """
        <!-- miniscanvas-memory-format: 1 -->
        ## 一般事实
        <!-- miniscanvas-memory-fact: {"id":"\(conflictingID)","sourceSessionID":"","createdAt":"1970-01-01T00:00:00Z","category":"fact","revision":1,"lifecycleState":"active"} -->
        - 另一条内容
        """
        #expect(throws: MemoryProposalConsumerError.restoreConflict) {
            try manager.importMarkdown(Data(conflicting.utf8), within: scope)
        }
        #expect(try store.facts().map(\.text) == ["导入事实"])
    }
}
