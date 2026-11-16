import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

// MARK: - D-SKILL-02 技能列表呈现合同测试
//
// 需求原文（验收清单 SKILL-02，第 345 行）：技能列表显示来源、路径、
// 版本/状态等必要信息。
//
// 本套件只锁定「呈现合同」，不重复实现展示逻辑：
//   · canonical 设置页技能 tab 的同一行必须同时渲染来源 displayName、
//     实际路径、版本行与启用状态（含稳定 accessibility 标识）；
//   · 每个来源的 displayName 非空且稳定，来源永远不会显示为空白；
//   · 空列表使用显式占位（ContentUnavailableView「暂无技能」），不空白；
//   · 版本非法的条目在扫描层被拒绝，不会以空白版本行进入列表；
//     进入列表的条目恒有非空 version、非空来源与真实路径。
// 冻结 donor 69b4098 的呈现裁决（空版本不伪造、保持缺省）在此仅被引用，
// 未改动 SettingsView 或 SkillsStore 的任何生产代码。

@Suite("D-SKILL-02 技能列表呈现合同")
struct SkillListPresentationContractTests {

    private func settingsSource() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MinisCanvasAppTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // MinisCanvasApp
            .deletingLastPathComponent() // src
            .deletingLastPathComponent() // repository
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "src/MinisCanvasApp/Sources/MinisCanvasApp/SettingsView.swift"
            ),
            encoding: .utf8
        )
    }

    /// 技能 tab 的完整源码切片：从 `SkillsSettingsTab` 声明到同文件下一处
    /// `// MARK: -` 分节，确保断言只针对技能列表视图本体。
    private func skillsTabSourceSlice(_ source: String) throws -> String {
        guard let start = source.range(of: "private struct SkillsSettingsTab: View {") else {
            Issue.record("SettingsView.swift 缺少 SkillsSettingsTab（canonical 技能列表视图）")
            return ""
        }
        let afterStart = source[start.upperBound...]
        let end = afterStart.range(of: "// MARK: -")?.lowerBound ?? afterStart.endIndex
        return String(source[start.lowerBound..<end])
    }

    @Test("技能页通过 canonical 设置视图挂载")
    func skillListUsesCanonicalSettingsEntry() throws {
        let source = try settingsSource()
        #expect(source.contains("SkillsSettingsTab(store: skillsStore, chat: chatStore)"))
    }

    @Test("技能行同时呈现来源、路径、版本与启用状态")
    func skillRowPresentsSourcePathVersionAndStatus() throws {
        let slice = try skillsTabSourceSlice(try settingsSource())
        #expect(!slice.isEmpty)

        // 来源 + 实际路径同行渲染。
        #expect(slice.contains(#""来源：\(entry.source.displayName) · \(entry.path.path)""#))

        // 版本行：使用「版本：」前缀并暴露稳定标识；
        // 兼容内联实现与 donor 69b4098 的 SkillVersionPresentation 形态，
        // 但不允许二者同时缺位。
        #expect(slice.contains("版本："))
        #expect(slice.contains("settings.skills.version.\\(entry.id)"))

        // 状态：启用开关携带可见的已启用/已停用无障碍值与稳定标识。
        #expect(slice.contains("\"已启用\" : \"已停用\""))
        #expect(slice.contains("settings.skills.toggle.\\(entry.id)"))
    }

    @Test("空技能列表使用显式占位而非空白")
    func emptySkillListUsesExplicitPlaceholder() throws {
        let slice = try skillsTabSourceSlice(try settingsSource())
        #expect(slice.contains("ContentUnavailableView("))
        #expect(slice.contains("\"暂无技能\""))
    }
}

// MARK: - 模型不变量与扫描层「缺失不空白」保证

@Suite("D-SKILL-02 技能元数据不变量")
struct SkillListPresentationModelContractTests {

    @Test("每个技能来源都有非空且互不相同的显示名")
    func everySourceHasStableNonEmptyDisplayName() {
        let hermes = SkillSource.localDirectory.displayName
        let app = SkillSource.app.displayName
        #expect(!hermes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(!app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(hermes != app)
    }

    @Test("进入列表的条目恒有可呈现的版本、来源与真实路径")
    func listedEntriesAlwaysCarryPresentableMetadata() throws {
        let root = try Self.makeTempDir("metadata-ok")
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeSkillMD(
            at: root.appendingPathComponent("creative/presentable"),
            content: """
            ---
            name: presentable
            description: 元数据完整的技能。
            version: 1.2.0
            ---
            正文
            """
        )
        let entries = SkillsScanner.scanLocalDirectory(root: root)
        #expect(entries.count == 1)
        for entry in entries {
            #expect(!entry.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(!entry.source.displayName.isEmpty)
            #expect(entry.path.lastPathComponent == "SKILL.md")
        }
    }

    @Test("非法版本的技能在扫描层被拒绝而不是以空白版本进入列表")
    func invalidVersionEntryIsRejectedInsteadOfRenderedBlank() throws {
        let root = try Self.makeTempDir("metadata-reject")
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeSkillMD(
            at: root.appendingPathComponent("creative/bad-version"),
            content: """
            ---
            name: bad-version
            description: 版本字段含路径分隔符。
            version: 1/2
            ---
            正文
            """
        )
        let (entries, diagnostics) = SkillsScanner.scanLocalDirectoryWithDiagnostics(root: root)
        #expect(entries.isEmpty)
        #expect(diagnostics.samples.contains { sample in
            sample.source == .localDirectory && sample.code == .identityRejected
        })
    }

    // MARK: helpers（自包含，避免与其它套件的私有 helper 耦合）

    private static func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SK02-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func writeSkillMD(at dir: URL, content: String) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try content.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }
}
