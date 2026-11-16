import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

// MARK: - C3-1 全局命令面板测试
//
// 覆盖：① 输入即过滤（250ms 防抖后结果正确）② 分类分组（侧栏 + 结果节）
// ③ 注册制一致性（面板 / 菜单同一 CommandRegistry 数据源；E9 quickaction 走
// DeepLinkRouter → DeepLinkHandler 深链执行路径，不经命令注册表）
// ④ 收藏置顶（⭐ 置顶显示）。

@Suite("C3-1 全局命令面板")
@MainActor
struct C3_1CommandPaletteTests {

    // MARK: 测试装配

    /// 每个测试独立的临时目录（绝不共享路径 / 不碰真实 Application Support）。
    private func makeTempDir(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("C3-1-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 全部后端禁用（不触发任何网络探测）。
    private func offlineBackends() -> LocalBackends {
        let configs: [LocalBackendKind: LocalBackendConfig] = Dictionary(
            uniqueKeysWithValues: LocalBackendKind.allCases.map {
                ($0, LocalBackendConfig(kind: $0, baseURL: $0.defaultBaseURL, enabled: false))
            }
        )
        return LocalBackends(configs: configs)
    }

    /// 临时目录依赖的应用注册表 + 展示元数据表（预置命令 + App UI 命令）。
    private func makeAssembled(
        _ name: String, shortcutStore: ShortcutStore? = nil
    ) throws -> (bridge: BridgeStore, registry: CommandRegistry, display: [String: PaletteDisplayInfo]) {
        let dir = try makeTempDir(name)
        let deps = CommandDependencies(
            env: EnvVarStore(directory: dir),
            log: LogManager(directory: dir),
            backends: offlineBackends(),
            sessions: SessionStore(directory: dir),
            memory: MemoryStore(directory: dir),
            workflows: WorkflowStore(storeDirectory: dir.appendingPathComponent("Workflows", isDirectory: true))
        )
        let bridge = BridgeStore(shortcutStore: shortcutStore)
        let assembled = AppCommandCatalog.assembled(bridge: bridge, dependencies: deps)
        return (bridge, assembled.registry, assembled.display)
    }

    private func makeModel(
        _ name: String,
        favorites: FavoriteCommandsStore? = nil,
        debounce: Duration = .milliseconds(250)
    ) throws -> (model: CommandPaletteModel, registry: CommandRegistry, display: [String: PaletteDisplayInfo]) {
        let (bridge, registry, display) = try makeAssembled(name)
        defer { withExtendedLifetime(bridge) {} }
        let model = CommandPaletteModel(
            registry: registry,
            display: display,
            favorites: favorites ?? FavoriteCommandsStore(defaults: makeDefaults()),
            debounceInterval: debounce
        )
        return (model, registry, display)
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "C3-1-\(UUID().uuidString)")!
    }

    /// 面板当前展示的全部命令 id（全部节合并）。
    private func allDisplayedIDs(_ model: CommandPaletteModel) -> [String] {
        model.sections.flatMap { $0.commands.map(\.id) }
    }

    // MARK: ① 输入即过滤（防抖）

    @Test func debouncedSearchAppliesOnlyLastQuery() async throws {
        let (model, _, _) = try makeModel("debounce")
        // 快速连续输入两次：只应应用最后一次（250ms 防抖合并）
        model.updateQuery("环境变量")
        model.updateQuery("env.list")
        // 用同步 refresh() 消除防抖时序依赖（全仓高负载下 250ms 防抖不可靠）
        model.refresh()
        let ids = allDisplayedIDs(model)
        #expect(ids.contains("env.list"))
        // 「环境变量」能命中 env.set/env.delete，但最后一次输入是 env.list → 不应出现
        #expect(!ids.contains("env.set"))
    }

    @Test func searchFilterMatchesIdTitleKeyword() throws {
        let (model, _, _) = try makeModel("filter")
        model.updateQuery("日志级别")
        model.refresh() // 同步路径（防抖不等待）
        let ids = allDisplayedIDs(model)
        #expect(ids.first == "log.level")
        // 分类过滤与搜索叠加
        model.selectedCategory = .environment
        model.updateQuery("设置")
        model.refresh()
        let envIDs = allDisplayedIDs(model)
        #expect(envIDs.contains("env.set"))
        #expect(!envIDs.contains("settings.open"))
        // 无匹配 → 空
        model.selectedCategory = nil
        model.updateQuery("zzz-no-such-command")
        model.refresh()
        #expect(allDisplayedIDs(model).isEmpty)
    }

    @Test func emptyQueryShowsAllGrouped() throws {
        let (model, registry, _) = try makeModel("grouped")
        model.refresh()
        let ids = allDisplayedIDs(model)
        // 空输入展示全部注册命令
        #expect(Set(ids) == Set(registry.allCommands().map(\.id)))
        #expect(ids.count == registry.count)
    }

    // MARK: ② 分类分组（侧栏 + 结果节）

    @Test func categorySidebarListsNonEmptyCategories() throws {
        let (model, _, _) = try makeModel("sidebar")
        let counts = model.categoryCounts
        let categories = counts.map(\.category)
        // C3-1 新增分类存在（画布 / Agent 都有注册命令）
        // 2026-08-06：工作板块移除 → documents 分类已从枚举删除
        #expect(categories.contains(.canvas))
        #expect(categories.contains(.agent))
        #expect(categories.contains(.session))
        // 计数与注册表一致
        #expect(counts.map(\.count).reduce(0, +) == model.totalCount)
        #expect(model.totalCount == model.registry.count)
    }

    @Test func emptyQueryGroupsByCategoryWithFavoritesFirst() throws {
        let favs = FavoriteCommandsStore(defaults: makeDefaults())
        let (model, _, _) = try makeModel("sections", favorites: favs)
        favs.toggle("env.list")
        model.refresh()
        // 第一节 = 收藏
        #expect(model.sections.first?.id == PaletteSection.favoritesID)
        #expect(model.sections.first?.commands.map(\.id) == ["env.list"])
        // 后续节按分类出现，且每节内命令属于该分类
        for section in model.sections.dropFirst() {
            let category = CommandCategory(rawValue: section.id)
            #expect(category != nil, "节 id 应为分类 rawValue")
            for command in section.commands {
                #expect(command.category == category)
            }
        }
        // 选中分类后只显示该分类
        model.selectedCategory = .canvas
        model.refresh()
        let ids = allDisplayedIDs(model)
        #expect(!ids.isEmpty)
        #expect(ids.allSatisfy { model.registry.command(id: $0)?.category == .canvas })
    }

    // MARK: ③ 注册制一致性（面板 / 菜单 / E9 quickaction 同一数据源）

    @Test func paletteAndMenuShareRegistry() throws {
        let (model, registry, display) = try makeModel("consistency")
        // 菜单节 = 注册表全量（按分类分组）
        let menuIDs = AppCommandMenuBuilder.sections(registry: registry, display: display)
            .flatMap { $0.commands.map(\.id) }
        #expect(Set(menuIDs) == Set(registry.allCommands().map(\.id)))
        #expect(menuIDs.count == registry.count)
        // 面板展示的命令全部来自同一注册表
        model.refresh()
        #expect(Set(allDisplayedIDs(model)).isSubset(of: Set(registry.allCommands().map(\.id))))
        // BridgeStore 暴露的注册表与 catalog 一致（面板/菜单共用的正是它）
        #expect(model.registry === registry)
    }

    @Test func registryHasNoHardcodedPaletteActions() throws {
        // C3-1：面板命令必须全部来自注册表——预置命令 + App UI 命令都在其中
        let (_, registry, _) = try makeAssembled("no-hardcode")
        let ids = Set(registry.allCommands().map(\.id))
        // 预置命令
        #expect(ids.contains("env.list"))
        #expect(ids.contains("workflow.run"))
        // App UI 命令
        #expect(ids.contains("session.new"))
        #expect(ids.contains("ui.canvas.run"))
        #expect(ids.contains("ui.layout.split"))
        #expect(ids.contains("ui.pipeline"))
        // 2026-08-06：ui.documents.open 随工作板块移除
        #expect(ids.contains("ui.agent.approve"))
        #expect(ids.contains("ui.agent.reject"))
        // 动态展开：建节点命令（Phase B：只展开 creatableSpecs 7 类生成类；id 统一小写，见 AppCommandCatalog）
        for spec in NodeTypeRegistry.creatableSpecs {
            #expect(ids.contains("ui.add-node." + spec.type.lowercased()),
                    "缺少建节点命令 \(spec.type)")
        }
        // Phase B：文本创作类不再注册建节点命令
        for spec in NodeTypeRegistry.specs where NodeTypeRegistry.textCreativeTypes.contains(spec.type) {
            #expect(!ids.contains("ui.add-node." + spec.type.lowercased()),
                    "文本创作类 \(spec.type) 不应注册建节点命令")
        }
    }

    @Test func quickActionsParseToSupportedDeepLinks() throws {
        // E9 quickaction 同一来源：每个预置快捷动作的深链都可解析为受支持动作。
        // F22④（P2-2）：旧 `AppCommandCatalog.commandID(for:)` quickaction→commandID
        // 映射已确认为生产零消费死代码并删除——quickaction 的真实执行路径是
        // DeepLinkRouter → DeepLinkHandler（见 E9Tests 执行断言），不经命令注册表。
        let (_, registry, _) = try makeAssembled("quickaction")
        for action in QuickActionStore.defaultActions {
            let url = URL(string: action.deepLinkURL)!
            let parsed = DeepLinkRouter.parse(url: url)
            #expect(parsed != nil, "\(action.id) 的深链应可解析")
        }
        // 注册表侧仍保有深链动作对应的命令语义（session.new / ui.pipeline / settings.open）
        for id in ["session.new", "ui.pipeline", "settings.open"] {
            #expect(registry.command(id: id) != nil, "命令 \(id) 应已注册")
        }
    }

    // MARK: ③b 注册命令可执行（UI 覆盖语义）

    @Test func sessionNewOverrideCreatesUiSession() async throws {
        let (bridge, registry, _) = try makeAssembled("session-new")
        let before = bridge.chat.sessions.count
        let result = try await registry.execute(id: "session.new")
        #expect(result.ok)
        #expect(bridge.chat.sessions.count == before + 1, "session.new 应走 UI 新建会话")
    }

    @Test func settingsOpenOverrideRoutesThroughDeepLink() async throws {
        let (bridge, registry, _) = try makeAssembled("settings-open")
        var opened: String? = "unset"
        bridge.deepLinkHandler.onOpenSettings = { opened = $0 }
        let result = try await registry.execute(id: "settings.open")
        #expect(result.ok)
        #expect(opened == nil, "settings.open 应经深链执行路径触发 onOpenSettings")
    }

    @Test func taskCenterCommandsUseOneRegistryOccurrenceAndLiveShortcut() async throws {
        let (bridge, registry, display) = try makeAssembled("task-center-commands")
        let open = try #require(AppCommandMenuBuilder.command(
            id: "ui.taskcenter.open", registry: registry, display: display
        ))
        let next = try #require(AppCommandMenuBuilder.command(
            id: "ui.taskcenter.next", registry: registry, display: display
        ))
        #expect(open.isEnabled && next.isEnabled)
        #expect(AppCommandCatalog.shortcutAction(forCommandID: next.id) == .nextTask)

        let openResult = try await registry.execute(id: open.id)
        #expect(openResult.ok)
        let openOccurrence = try #require(bridge.taskCenterOpenIntent)
        #expect(!openOccurrence.toolbarOpener)
        let toolbarResult = try await registry.execute(
            id: open.id, args: ["opener": "toolbar"]
        )
        #expect(toolbarResult.ok)
        let toolbarOccurrence = try #require(bridge.taskCenterOpenIntent)
        #expect(toolbarOccurrence.toolbarOpener)
        #expect(toolbarOccurrence.id != openOccurrence.id)
        let beforeNext = bridge.taskCenterNextCommandCount
        let firstResult = try await registry.execute(id: next.id)
        #expect(firstResult.ok)
        let secondResult = try await registry.execute(id: next.id)
        #expect(secondResult.ok)
        #expect(bridge.taskCenterNextCommandCount == beforeNext + 2,
                "重复快捷键在合并 UI 更新前也必须保留两次导航")
    }

    @Test func splitSidebarButtonsAndShortcutsShareLiveRegisteredAvailability() async throws {
        let (bridge, registry, display) = try makeAssembled("split-sidebar-commands")
        let actions: [(String, ShortcutAction)] = [
            ("ui.sidebar.toggle", .toggleSessionSidebar),
            ("ui.context.toggle", .toggleContextPanel),
        ]
        for (id, action) in actions {
            let row = try #require(AppCommandMenuBuilder.command(
                id: id, registry: registry, display: display
            ))
            #expect(row.isEnabled)
            #expect(AppCommandCatalog.shortcutAction(forCommandID: id) == action)
        }

        _ = try await registry.execute(id: "ui.sidebar.toggle")
        _ = try await registry.execute(id: "ui.context.toggle")
        #expect(bridge.sidebarToggleCommandCount == 1)
        #expect(bridge.contextToggleCommandCount == 1)

        bridge.layoutMode = .chat
        for (id, _) in actions {
            let row = try #require(AppCommandMenuBuilder.command(
                id: id, registry: registry, display: display
            ))
            #expect(!row.isEnabled)
            #expect(row.disabledReason == "仅三栏布局可用")
            do {
                _ = try await registry.execute(id: id)
                Issue.record("非三栏布局不应执行 \(id)")
            } catch let error as CommandExecutionError {
                #expect(error == .disabled(commandID: id, reason: "仅三栏布局可用"))
            }
        }
        #expect(bridge.sidebarToggleCommandCount == 1)
        #expect(bridge.contextToggleCommandCount == 1)

        bridge.layoutMode = .split
        _ = try await registry.execute(id: "ui.sidebar.toggle")
        _ = try await registry.execute(id: "ui.context.toggle")
        #expect(bridge.sidebarToggleCommandCount == 2)
        #expect(bridge.contextToggleCommandCount == 2)
    }

    @Test func nativeTopLevelMenusConsumeRegisteredCommands() async throws {
        let (bridge, registry, display) = try makeAssembled("native-menu-registry")
        var opened: String? = "unset"
        bridge.deepLinkHandler.onOpenSettings = { opened = $0 }

        let newSession = try #require(AppCommandMenuBuilder.command(
            id: "session.new", registry: registry, display: display
        ))
        let openSettings = try #require(AppCommandMenuBuilder.command(
            id: "settings.open", registry: registry, display: display
        ))
        #expect(newSession.isEnabled && openSettings.isEnabled)
        let before = bridge.chat.sessions.count
        let sessionResult = try await registry.execute(id: newSession.id)
        #expect(sessionResult.ok)
        #expect(bridge.chat.sessions.count == before + 1)
        let settingsResult = try await registry.execute(id: openSettings.id)
        #expect(settingsResult.ok)
        #expect(opened == nil)

        // The two native command groups must consume these projected rows and
        // dispatch their IDs. Otherwise this executor check could pass while
        // the actual menu still bypasses the registry with a direct action.
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let appSource = try String(contentsOf: packageRoot.appendingPathComponent(
            "Sources/MinisCanvasApp/MinisCanvasApp.swift"
        ), encoding: .utf8)
        let settingsGroup = try #require(appSource.components(separatedBy:
            "CommandGroup(replacing: .appSettings) {").dropFirst().first?
            .components(separatedBy: "CommandGroup(replacing: .newItem) {").first)
        let newItemGroup = try #require(appSource.components(separatedBy:
            "CommandGroup(replacing: .newItem) {").dropFirst().first?
            .components(separatedBy: "SessionCommands(").first)
        for group in [settingsGroup, newItemGroup] {
            #expect(group.contains("AppCommandMenuBuilder.command("))
            #expect(group.contains("bridge.runCommand(id: command.id)"))
        }
        #expect(!settingsGroup.contains("isSettingsPresented = true"))
        #expect(!newItemGroup.contains("bridge.chat.newSession()"))
    }

    @Test func presetCommandsStillExecutable() async throws {
        let (_, registry, _) = try makeAssembled("presets")
        let list = try await registry.execute(id: "env.list")
        #expect(list.ok)
        #expect(list.text.contains("环境变量"))
    }

    // MARK: ④ 收藏置顶

    @Test func favoritesPinnedOnTop() throws {
        let favs = FavoriteCommandsStore(defaults: makeDefaults())
        let (model, _, _) = try makeModel("fav-pin", favorites: favs)
        favs.toggle("env.list")
        favs.toggle("ui.canvas.run")
        model.refresh()
        // 空输入：收藏节置顶，且按收藏顺序
        let favSection = model.sections.first
        #expect(favSection?.id == PaletteSection.favoritesID)
        #expect(favSection?.commands.map(\.id) == ["env.list", "ui.canvas.run"])
        // 收藏行带 ⭐ 标记
        #expect(favSection?.commands.allSatisfy(\.isFavorite) == true)
        // 有输入：命中的收藏仍置顶
        model.updateQuery("env")
        model.refresh()
        #expect(model.sections.first?.id == PaletteSection.favoritesID)
        #expect(model.sections.first?.commands.map(\.id) == ["env.list"])
        // 取消收藏后不再置顶
        model.toggleFavorite("env.list")
        model.refresh()
        #expect(model.sections.first?.id != PaletteSection.favoritesID)
        #expect(!model.isFavorite("env.list"))
    }

    @Test func favoritesPersistAcrossModels() {
        let defaults = makeDefaults()
        let store = FavoriteCommandsStore(defaults: defaults)
        store.toggle("env.list")
        store.toggle("ui.canvas.run")
        store.toggle("env.list") // 再点一次 → 取消
        #expect(store.isFavorite("ui.canvas.run"))
        #expect(!store.isFavorite("env.list"))
        #expect(store.favoriteIDs() == ["ui.canvas.run"])
        // 新实例（同一 UserDefaults suite）读到同一份收藏
        let reloaded = FavoriteCommandsStore(defaults: defaults)
        #expect(reloaded.favoriteIDs() == ["ui.canvas.run"])
    }

    // MARK: 快捷键徽标（展示元数据）

    @Test func displayInfoCarriesShortcutBadges() throws {
        // Canvas defaults are unbound; this badge checks an isolated saved user choice.
        let shortcutStore = ShortcutStore(defaults: makeDefaults())
        try #require(shortcutStore.setBinding(.init(key: "p", modifiers: ShortcutModifiers.command), for: .createPipeline) == nil)
        let (_, registry, display) = try makeAssembled("badges", shortcutStore: shortcutStore)
        #expect(display["session.new"]?.shortcut == "⌘N")
        #expect(display["settings.open"]?.shortcut == "⌘,")
        #expect(display["ui.pipeline"]?.shortcut == "⌘P")
        #expect(display["ui.canvas.run"]?.icon == "play.fill")
        // 未声明的预置命令回落到分类图标
        let envList = registry.command(id: "env.list")!
        let fallback = display["env.list"]?.icon ?? AppCommandCatalog.fallbackIcon(for: envList.category)
        #expect(!fallback.isEmpty)
    }
}
