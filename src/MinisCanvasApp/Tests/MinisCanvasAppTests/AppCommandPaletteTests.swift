import Testing
import Foundation
import CanvasCore
import MinisCore
@testable import MinisCanvasApp

// MARK: - AppCommandPalette 缺口补写（swift-testing）
//
// C3_1CommandPaletteTests 已覆盖：目录/搜索/兜底/快捷动作/收藏置顶/持久化/菜单同源。
// 本文件补 C3_1 未细化的缺口：
//   ① FavoriteCommandsStore.toggle 的追加顺序语义（多次 toggle 的顺序稳定性）
//   ② CommandPaletteModel 空输入收藏置顶 + 分类过滤叠加（收藏也应用分类过滤）
//   ③ CategoryCounts 精确逐分类计数 / 空分类跳过 / 总数一致
//   ④ AppCommandMenuBuilder.sections 分类声明序 / 无收藏节 / isFavorite 恒 false

@Suite("C3-1 补：收藏顺序 / 空输入分组 / 分类计数 / 菜单构建")
@MainActor
struct AppCommandPaletteEdgeTests {

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "C3-1-edge-\(UUID().uuidString)")!
    }

    /// 轻量命令定义（execute 恒成功，不触发任何副作用）。
    private func makeCommand(_ id: String, _ category: CommandCategory) -> CommandDefinition {
        CommandDefinition(id: id, title: id, category: category) { _ in .success("") }
    }

    /// 小型注册表 + 面板模型（不碰 BridgeStore / 磁盘，纯数据层）。
    private func makeModel(
        commands: [CommandDefinition],
        favorites: FavoriteCommandsStore? = nil
    ) -> CommandPaletteModel {
        let registry = CommandRegistry(commands: commands)
        return CommandPaletteModel(
            registry: registry,
            display: [:],
            favorites: favorites ?? FavoriteCommandsStore(defaults: makeDefaults()),
            debounceInterval: .milliseconds(10)
        )
    }

    // MARK: ① FavoriteCommandsStore.toggle 顺序语义

    /// 菜单给带参命令预填 "/provider.use "：面板要能找到这条命令，而不是"无匹配命令"。
    @Test func slashPrefilledQueryFindsTheCommand() {
        let model = makeModel(commands: [makeCommand("provider.use", .backend), makeCommand("model", .backend)])
        model.updateQuery("/provider.use ")
        model.refresh()
        let ids = model.sections.flatMap(\.commands).map(\.id)
        #expect(ids == ["provider.use"])
    }

    /// MC4-035：切分类立即重算，不用再输入一次。
    @Test func switchingCategoryRecomputesSectionsImmediately() {
        let model = makeModel(commands: [makeCommand("env.a", .environment), makeCommand("be.b", .backend)])
        model.updateQuery("")
        model.refresh()
        model.selectedCategory = .backend
        let ids = model.sections.flatMap(\.commands).map(\.id)
        #expect(ids == ["be.b"])
    }

    /// MC4-036：回车提交前必须先同步 refresh()，源码守卫。
    @Test func submitRefreshesBeforeReadingFirstResult() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MinisCanvasApp/CommandPaletteView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let start = try #require(source.range(of: "private func runSubmittedQuery() {"))
        let tail = String(source[start.upperBound...].prefix(400))
        let refreshAt = try #require(tail.range(of: "model.refresh()"))
        let firstAt = try #require(tail.range(of: "resolveSubmission("))
        #expect(refreshAt.lowerBound < firstAt.lowerBound)
    }

    @Test func favoriteToggleAppendsInOrderAndRemovesExactlyOnce() {
        let store = FavoriteCommandsStore(defaults: makeDefaults())
        #expect(store.favoriteIDs().isEmpty, "初始无收藏")
        store.toggle("b")
        store.toggle("a")
        #expect(store.favoriteIDs() == ["b", "a"], "新收藏追加到末尾，保持加入顺序")
        store.toggle("b")
        #expect(store.favoriteIDs() == ["a"], "再点一次精确移除，不留残留")
        #expect(!store.isFavorite("b"))
        store.toggle("b")
        #expect(store.favoriteIDs() == ["a", "b"], "重新收藏 → 追加到末尾（顺序 = 最近收藏在后）")
        #expect(store.isFavorite("a") && store.isFavorite("b"))
    }

    // MARK: ② 空输入收藏置顶 + 分类过滤叠加

    @Test func emptyQueryFavoritesSectionRespectsSelectedCategory() {
        let registry = CommandRegistry(commands: [
            makeCommand("env.a", .environment),
            makeCommand("env.b", .environment),
            makeCommand("canvas.a", .canvas),
        ])
        let favs = FavoriteCommandsStore(defaults: makeDefaults())
        favs.toggle("env.a")
        favs.toggle("canvas.a")
        let model = makeModel(commands: registry.allCommands(), favorites: favs)

        // 未选分类：两个收藏都置顶，按收藏顺序
        model.refresh()
        #expect(model.sections.first?.id == PaletteSection.favoritesID)
        #expect(model.sections.first?.commands.map(\.id) == ["env.a", "canvas.a"])

        // 选中 .environment：收藏节只含该分类收藏；canvas 整类（含其收藏）不出现
        model.selectedCategory = .environment
        model.refresh()
        #expect(model.sections.first?.id == PaletteSection.favoritesID)
        #expect(model.sections.first?.commands.map(\.id) == ["env.a"],
                "收藏也应用分类过滤：只显示选中分类的收藏")
        let ids = model.sections.flatMap { $0.commands.map(\.id) }
        #expect(!ids.contains("canvas.a"))
        #expect(ids.allSatisfy { model.registry.command(id: $0)?.category == .environment })
    }

    // MARK: ③ CategoryCounts 精确计数

    @Test func categoryCountsMatchRegistryPerCategoryExactly() {
        let model = makeModel(commands: [
            makeCommand("env.a", .environment),
            makeCommand("env.b", .environment),
            makeCommand("canvas.a", .canvas),
            makeCommand("canvas.b", .canvas),
            makeCommand("canvas.c", .canvas),
        ])
        let counts = model.categoryCounts
        #expect(counts.first { $0.category == .environment }?.count == 2)
        #expect(counts.first { $0.category == .canvas }?.count == 3)
        // 空分类（未注册命令）不出现
        #expect(!counts.contains { $0.category == .agent })
        #expect(!counts.contains { $0.category == .workflow })
        // 计数总和 = 全部命令数
        #expect(counts.map(\.count).reduce(0, +) == model.totalCount)
        #expect(model.totalCount == model.registry.count)
    }

    // MARK: ④ AppCommandMenuBuilder.sections

    @Test func menuBuilderSectionsFollowCategoryOrderWithoutFavorites() {
        let registry = CommandRegistry(commands: [
            makeCommand("canvas.a", .canvas),
            makeCommand("canvas.b", .canvas),
            makeCommand("agent.a", .agent),
            makeCommand("env.a", .environment),
        ])
        let sections = AppCommandMenuBuilder.sections(registry: registry, display: [:])
        // 分类顺序 = CommandCategory.allCases 声明序（environment 先于 canvas/agent）
        #expect(sections.map(\.id) == ["environment", "canvas", "agent"])
        #expect(!sections.contains { $0.id == PaletteSection.favoritesID }, "菜单不含收藏节")
        let all = sections.flatMap { $0.commands }
        #expect(all.count == registry.count, "菜单覆盖注册表全量且无重复")
        #expect(Set(all.map(\.id)) == Set(registry.allCommands().map(\.id)))
        #expect(all.allSatisfy { !$0.isFavorite }, "菜单行不标记收藏")
        for section in sections {
            for command in section.commands {
                #expect(command.category.rawValue == section.id, "节内命令必属该分类")
            }
        }
    }

    @Test func menuKeepsDisabledCommandDiscoverableWithRecoveryReason() {
        let reason = "提供商授权已失效"
        let disabled = CommandDefinition(
            id: " Provider.Reconnect ",
            title: "重新连接提供商",
            category: .backend,
            availability: { .disabled(reason: reason) }
        ) { _ in
            .success("")
        }
        let registry = CommandRegistry(commands: [disabled])

        let command = AppCommandMenuBuilder.sections(registry: registry, display: [:])
            .flatMap(\.commands)
            .first

        #expect(command?.id == "provider.reconnect")
        #expect(command?.isEnabled == false)
        #expect(command?.disabledReason == reason)
    }

    @Test func mappedCommandMetadataAndMenuShortcutsUseCanonicalBindings() throws {
        let defaults = makeDefaults()
        let shortcuts = ShortcutStore(defaults: defaults)
        _ = shortcuts.setBinding(
            ShortcutBinding(key: "x", modifiers: ShortcutModifiers.command),
            for: .commandPalette
        )
        // Shift-Command-M belongs to composerMode; use an unoccupied binding
        // and require admission before asserting the effective palette badge.
        try #require(shortcuts.setBinding(
            ShortcutBinding(key: "8", modifiers: .commandShift),
            for: .newSession
        ) == nil)
        _ = shortcuts.setBinding(
            ShortcutBinding(key: "g", modifiers: ShortcutModifiers.command),
            for: .createPipeline
        )
        _ = shortcuts.setBinding(
            ShortcutBinding(key: "o", modifiers: ShortcutModifiers.command),
            for: .openSettings
        )
        _ = shortcuts.setBinding(
            ShortcutBinding(key: "s", modifiers: ShortcutModifiers.command),
            for: .stopGeneration
        )

        let bridge = BridgeStore(shortcutStore: shortcuts)
        let display = bridge.paletteDisplay
        #expect(display["session.new"]?.shortcut == "⇧⌘8")
        #expect(display["settings.open"]?.shortcut == "⌘O")
        #expect(display["ui.pipeline"]?.shortcut == "⌘G")
        #expect(display["ui.chat.stop"]?.shortcut == "⌘S")

        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSource = try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/MinisCanvasApp/MinisCanvasApp.swift"),
            encoding: .utf8
        )
        #expect(appSource.contains(
            ".shortcutKey(bridge.shortcutStore.binding(for: .commandPalette))"
        ))
        #expect(appSource.contains(
            ".shortcutKey(bridge.shortcutStore.binding(for: .newSession))"
        ))
        #expect(!appSource.contains(
            ".keyboardShortcut(\"k\", modifiers: .command)"
        ))
        #expect(!appSource.contains(
            ".keyboardShortcut(\"n\", modifiers: [.command, .shift])"
        ))

        let paletteSource = try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/MinisCanvasApp/AppCommandPalette.swift"),
            encoding: .utf8
        )
        for staleMetadata in [
            "shortcut: \"⌘N\"",
            "shortcut: \"⌘,\"",
            "shortcut: \"⌘P\"",
            "shortcut: \"⌘.\""
        ] {
            #expect(!paletteSource.contains(staleMetadata))
        }
    }
}
