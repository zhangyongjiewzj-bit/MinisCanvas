import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

// MARK: - AJ-58 会话归档搜索（内容 / 标题 / 日期 + 恢复）

@Suite("AJ-58 会话归档搜索")
@MainActor
struct AJ58ArchiveSearchTests {

    // MARK: 归档搜索：全文内容（非仅最后一条预览）

    @Test func archiveSearchMatchesFullContent() {
        let chat = ChatStore()
        let id = chat.activeSessionID!
        chat.appendUser("早期内容关键词XYZ")   // 自动标题 = 首条用户消息
        chat.appendUser("中间内容隐藏词ABC")    // 非标题、非预览 → 全文搜索命中
        chat.appendAssistant("最后一条回复，不含关键词")
        chat.archiveSession(id: id)

        // 全文命中：关键词在中间消息（不在标题、也不在最后一条预览）
        chat.searchText = "隐藏词ABC"
        #expect(chat.archivedList.first?.session.id == id)
        #expect(chat.archivedList.count == 1)

        // 标题命中
        chat.searchText = "早期内容"
        #expect(chat.archivedList.first?.session.id == id)

        // 预览命中（最后一条消息）
        chat.searchText = "最后一条回复"
        #expect(chat.archivedList.first?.session.id == id)

        // 无匹配
        chat.searchText = "完全不存在"
        #expect(chat.archivedList.isEmpty)

        // 清空恢复全部
        chat.searchText = ""
        #expect(chat.archivedList.count == 1)
    }

    // MARK: 归档搜索：按日期

    @Test func archiveSearchByDate() {
        let chat = ChatStore()
        let id = chat.activeSessionID!
        chat.appendUser("归档日期内容")
        chat.archiveSession(id: id)

        // 今天（createdAt/updatedAt 均为今天）→ 命中
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        chat.searchText = fmt.string(from: Date())
        #expect(chat.archivedList.first?.session.id == id)

        // 远古日期 → 无匹配
        chat.searchText = "1999-01-01"
        #expect(chat.archivedList.isEmpty)
    }

    @Test func archiveSearchByDateSlashFormat() {
        let chat = ChatStore()
        let id = chat.activeSessionID!
        chat.appendUser("斜杠日期内容")
        chat.archiveSession(id: id)

        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy/MM/dd"
        chat.searchText = fmt.string(from: Date())
        #expect(chat.archivedList.first?.session.id == id)
    }

    // MARK: 归档搜索 + 恢复

    @Test func archiveSearchThenRestore() {
        let chat = ChatStore()
        let id = chat.activeSessionID!
        chat.appendUser("要恢复的归档内容")
        chat.archiveSession(id: id)
        chat.searchText = "要恢复的归档内容"
        #expect(chat.archivedList.count == 1)

        // 从搜索结果恢复 → 移回活动列表并切换过去
        chat.restoreSession(id: id)
        #expect(chat.archivedList.isEmpty)
        #expect(chat.activeSessionID == id)
        #expect(chat.messages.contains { $0.content == "要恢复的归档内容" })
    }
}