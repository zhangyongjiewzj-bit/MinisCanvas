import Foundation
import Testing

@testable import MinisCore

private func makeStore() throws -> (SkillStore, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("SkillCatalogAndTruncationTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return (SkillStore(skillsRoot: dir), dir)
}

@Suite("技能目录与长技能注入（对齐 Claude Code）")
struct SkillCatalogAndTruncationTests {
    @Test("超出总预算的长技能不再整篇丢弃：注入开头并提示用 skill_read 读全文")
    func oversizedSkillIsTruncatedNotDropped() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try store.importSkill(content: """
        ---
        name: long-skill
        description: longkey alpha
        ---

        HEAD-MARK \(String(repeating: "x", count: 3000)) TAIL-MARK
        """)
        let injector = SkillInjector(store: store, maxInjectedCharacters: 1500)
        let result = injector.buildInjection(for: "longkey alpha")
        let fragment = try #require(result.fragment)
        #expect(fragment.count <= 1500)
        #expect(fragment.contains("HEAD-MARK"))
        #expect(!fragment.contains("TAIL-MARK"))
        #expect(fragment.contains("skill_read") && fragment.contains("long-skill"))
        #expect(fragment.hasSuffix("</injected_skills>"))
        #expect(result.receipts.first?.injected == true)
    }

    @Test("目录告诉模型可以用 skill_read；超出预算时相关技能排前并注明另有几个")
    func catalogMentionsSkillReadAndKeepsRelevantFirst() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 1...6 {
            _ = try store.importSkill(content: """
            ---
            name: cat-skill-\(index)
            description: catalog entry
            ---

            body \(index)
            """)
        }
        let injector = SkillInjector(store: store)
        let full = try #require(injector.catalogFragment())
        #expect(full.contains("skill_read"))
        for index in 1...6 { #expect(full.contains("cat-skill-\(index)")) }
        #expect(!full.contains("未列出"))

        let tight = try #require(injector.catalogFragment(maxCharacters: 260, userMessage: "cat-skill-6 please"))
        #expect(tight.count <= 260)
        #expect(tight.contains("cat-skill-6"))
        #expect(tight.contains("未列出") && tight.contains("skill_read"))
    }
}
