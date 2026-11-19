import Foundation
import Testing

@testable import MinisCore

@Suite("外部技能根（只读、实时哈希、需确认）")
struct ExternalSkillCatalogTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExternalSkillCatalogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeSkill(_ text: String, home: URL, dir: String, root: String = ".claude/skills") throws {
        let url = home.appendingPathComponent("\(root)/\(dir)/SKILL.md")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test("首次出现待确认；确认后可提供给模型；磁盘内容一变就回到需重新确认")
    func confirmThenChange() throws {
        let tmp = try makeRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let home = tmp.appendingPathComponent("home")
        try writeSkill("---\nname: pdf-helper\ndescription: 处理 PDF\n---\n先检查页数", home: home, dir: "pdf-helper")
        let catalog = ExternalSkillCatalog(
            confirmationsURL: tmp.appendingPathComponent("confirm.json"), homeDirectory: home)

        let first = try #require(catalog.scan(projectRoot: nil).first)
        #expect(first.status == .needsConfirmation)
        #expect(catalog.promptFragment(projectRoot: nil, userMessage: "pdf-helper") == nil)

        try catalog.confirm(first, projectRoot: nil)
        let confirmed = try #require(catalog.scan(projectRoot: nil).first)
        #expect(confirmed.status == .confirmed)
        let fragment = try #require(catalog.promptFragment(projectRoot: nil, userMessage: "用 pdf-helper 看看"))
        #expect(fragment.contains("外部技能") && fragment.contains("先检查页数"))

        try writeSkill("---\nname: pdf-helper\ndescription: 处理 PDF\n---\n改过的内容", home: home, dir: "pdf-helper")
        let changed = try #require(catalog.scan(projectRoot: nil).first)
        #expect(changed.status == .changedSinceConfirmation)
        #expect(catalog.promptFragment(projectRoot: nil, userMessage: "pdf-helper") == nil)
    }

    @Test("等大小且保留修改时间的改写，读取和注入前也能发现内容已变")
    func sameSizeSameMtimeRewriteIsDetected() throws {
        let tmp = try makeRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let home = tmp.appendingPathComponent("home")
        try writeSkill("---\nname: pdf-helper\ndescription: 处理 PDF\n---\n先检查页数", home: home, dir: "pdf-helper")
        let catalog = ExternalSkillCatalog(
            confirmationsURL: tmp.appendingPathComponent("confirm.json"), homeDirectory: home)
        let first = try #require(catalog.scan(projectRoot: nil).first)
        try catalog.confirm(first, projectRoot: nil)
        #expect(catalog.readConfirmed(name: "pdf-helper", projectRoot: nil)?.contains("先检查页数") == true)

        let file = home.appendingPathComponent(".claude/skills/pdf-helper/SKILL.md")
        let mtime = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        try "---\nname: pdf-helper\ndescription: 处理 PDF\n---\n先检查页面".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)

        #expect(catalog.readConfirmed(name: "pdf-helper", projectRoot: nil) == nil)
        #expect(catalog.scan(projectRoot: nil).first?.status == .changedSinceConfirmation)
        #expect(catalog.promptFragment(projectRoot: nil, userMessage: "pdf-helper") == nil)
    }

    @Test("指向技能根之外的符号链接不读取")
    func symlinkOutsideRootIgnored() throws {
        let tmp = try makeRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let home = tmp.appendingPathComponent("home")
        let outside = tmp.appendingPathComponent("outside/SKILL.md")
        try FileManager.default.createDirectory(at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "外部内容".write(to: outside, atomically: true, encoding: .utf8)
        let skillDir = home.appendingPathComponent(".claude/skills/leak")
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: skillDir.appendingPathComponent("SKILL.md"), withDestinationURL: outside)
        let catalog = ExternalSkillCatalog(
            confirmationsURL: tmp.appendingPathComponent("confirm.json"), homeDirectory: home)
        #expect(catalog.scan(projectRoot: nil).isEmpty)
    }
}
