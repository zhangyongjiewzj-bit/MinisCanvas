import SwiftUI
import UniformTypeIdentifiers
import CanvasCore
import MinisCore

// MARK: - C3-1 全局命令面板：注册制唯一命令源
//
// ComfyUI searchbox v2（输入 + 过滤栏 + 分类侧栏 + 结果、收藏）的 Swift 落地：
// 面板 / 菜单全部以 `CommandRegistry` 为唯一命令源（E9 quickaction 走
// DeepLinkRouter → DeepLinkHandler 深链执行路径，不经本文件）。
// App 层只补充「展示元数据」（图标 / 快捷键徽标）与「收藏」，命令本体一律注册进 Registry：
//
//     CommandRegistry（唯一命令源）
//       ├─ PresetCommands.all(dependencies:)   核心预置命令（env/log/backend/session/…）
//       └─ AppCommandCatalog.specs(bridge:)    App UI 命令（新建会话/布局/执行画布/建节点/…）
//               │
//               ├─ CommandPaletteView    ⌘K / Ctrl+Space 面板（本文件模型驱动）
//               └─ AppCommandMenuBuilder 应用菜单（同一数据源生成）

// MARK: - 展示元数据

/// 命令的展示信息（图标 + 快捷键徽标）。命令本体在 Registry，这里只管「长什么样」。
struct PaletteDisplayInfo: Equatable, Sendable {
    let icon: String
    let shortcut: String?
}

/// 一条待注册命令与其展示元数据的组合（catalog 的构建产物）。
struct AppCommandSpec: Sendable {
    let definition: CommandDefinition
    let icon: String
    let shortcut: String?
}

/// A registered open request. Repeated next-task commands use a counter so
/// SwiftUI's coalesced updates cannot lose rapid keyboard presses.
struct TaskCenterOpenIntent: Equatable, Sendable {
    let id: UUID
    let toolbarOpener: Bool
    let initialTaskStableID: String?

    init(toolbarOpener: Bool, initialTaskStableID: String? = nil) {
        self.id = UUID()
        self.toolbarOpener = toolbarOpener
        self.initialTaskStableID = initialTaskStableID
    }
}

/// Command availability can be queried off the main actor. Keep only an
/// immutable value projection of the current layout behind the lock; the
/// execution body rechecks the live layout on the main actor.
final class SplitLayoutCommandAvailability: @unchecked Sendable {
    private let lock = NSLock()
    private var split = true

    var isSplit: Bool { lock.withLock { split } }

    func update(isSplit: Bool) {
        lock.withLock { split = isSplit }
    }
}

// MARK: - AppCommandCatalog

/// 应用命令目录：把 App UI 动作注册成命令（注册制唯一命令源）。
enum AppCommandCatalog {
    static let commandPaletteID = "ui.command.palette"

    /// Metadata-only scope for the original three Canvas slash declarations.
    /// This does not register any Canvas UI action or preset executor.
    static let phase3DisabledCanvasSlashIDs: Set<String> = [
        "canvas.run", "canvas.cancel", "canvas.minimap"
    ]

    /// 一次性构建「注册表 + 展示元数据表」（避免 specs 重复展开）。
    /// - Parameter dependencies: 预置命令依赖；测试传入临时目录 store，避免磁盘污染。
    @MainActor
    static func assembled(
        bridge: BridgeStore,
        dependencies: CommandDependencies = CommandDependencies()
    ) -> (registry: CommandRegistry, display: [String: PaletteDisplayInfo]) {
        let presets = PresetCommands.all(dependencies: dependencies).filter {
            bridge.canvasFeatureLane == .phase4OptIn || !isCanvasCommand($0)
        }
        let registry = CommandRegistry(commands: presets)
        registry.register(CommandDefinition(
            id: "goal", title: "会话目标",
            keywords: ["会话目标", "Goal", "设定目标；不带参数时显示当前目标", "Set a goal, or show the current one"],
            category: .session,
            argumentSpecs: [CommandArgumentSpec(name: "objective", label: "目标内容 / objective", required: false, kind: .rest)]
        ) { _ in
            .failure("请在当前会话输入 /goal 和目标内容")
        })
        // The original Canvas slash declarations remain discoverable as
        // disabled metadata. Phase 3 still registers no Canvas executors.
        for metadata in CommandRegistry.composerCommandMetadata {
            let deferred = bridge.canvasFeatureLane == .phase3NonCanvas
                && phase3DisabledCanvasSlashIDs.contains(metadata.id)
            if bridge.canvasFeatureLane == .phase3NonCanvas,
               metadata.category == .canvas, !deferred { continue }
            let availability: CommandAvailability = deferred
                ? .disabled(reason: ComposerCommandAdjudicationCenter
                    .missingExecutorReason(for: metadata.id) ?? "Canvas 当前不可用")
                : .enabled
            registry.register(CommandDefinition(
                id: metadata.id, title: metadata.zhTitle,
                keywords: [metadata.zhTitle, metadata.enTitle, metadata.zhSummary, metadata.enSummary],
                aliases: metadata.aliases, category: metadata.category,
                requiresConfirmation: metadata.requiresPolicyApproval,
                argumentSpecs: metadata.argumentSpecs,
                availability: { availability },
                customParse: CommandRegistry.composerArgumentParser(for: metadata.id)
            ) { _ in .failure("Composer 命令必须先创建 pending request") })
        }
        var display: [String: PaletteDisplayInfo] = [:]
        for spec in specs(bridge: bridge, dependencies: dependencies) {
            registry.register(spec.definition)
            display[spec.definition.id] = PaletteDisplayInfo(
                icon: spec.icon,
                shortcut: effectiveShortcut(
                    forCommandID: spec.definition.id,
                    bridge: bridge
                ) ?? spec.shortcut
            )
        }
        return (registry, display)
    }

    /// 构建应用级注册表：核心预置命令 + App UI 命令（同 id 覆盖预置实现，
    /// 例如 `session.new` 覆盖为「UI 新建会话」——面板/菜单/NL 解析同一语义）。
    @MainActor
    static func makeRegistry(
        bridge: BridgeStore,
        dependencies: CommandDependencies = CommandDependencies()
    ) -> CommandRegistry {
        assembled(bridge: bridge, dependencies: dependencies).registry
    }

    /// 展示元数据表（命令 id → 图标/快捷键）。未显式声明的命令回落到分类图标。
    @MainActor
    static func displayMap(bridge: BridgeStore) -> [String: PaletteDisplayInfo] {
        assembled(bridge: bridge).display
    }

    /// AJ-57：命令 id → 可配置快捷键动作 的映射（命令面板徽标据此同步用户改后的绑定）。
    static let shortcutCommandMap: [String: ShortcutAction] = [
        commandPaletteID: .commandPalette,
        "ui.pipeline": .createPipeline,
        "ui.canvas.run": .runCanvas,
        "ui.chat.stop": .stopGeneration,
        "ui.chat.compact": .compactContext,
        "ui.agent.approve": .approveRequest,
        "ui.agent.reject": .rejectRequest,
        "session.new": .newSession,
        "settings.open": .openSettings,
        "ui.taskcenter.next": .nextTask,
        "ui.sidebar.toggle": .toggleSessionSidebar,
        "ui.context.toggle": .toggleContextPanel,
    ]

    private struct ShortcutCommandPresentation: Sendable {
        let title: String
        let aliases: [String]
        init(_ title: String, aliases: [String] = []) {
            self.title = title
            self.aliases = aliases
        }
    }

    // Shared by the actual App command registrations below and the Settings
    // shortcut rows. The action association remains shortcutCommandMap.
    private static let shortcutCommandPresentations: [String: ShortcutCommandPresentation] = [
        commandPaletteID: .init("命令面板…"),
        "ui.pipeline": .init("一键漫剧流水线"),
        "ui.canvas.run": .init("执行画布"),
        "ui.chat.stop": .init("停止生成"),
        "ui.chat.compact": .init("压缩上下文", aliases: ["compact"]),
        "ui.agent.approve": .init("批准当前工具请求"),
        "ui.agent.reject": .init("拒绝当前工具请求"),
        "session.new": .init("新建会话"),
        "settings.open": .init("打开设置面板"),
        "ui.taskcenter.next": .init("查看下一个任务"),
        "ui.sidebar.toggle": .init("折叠或展开会话侧栏"),
        "ui.context.toggle": .init("折叠或展开上下文面板"),
    ]

    private static func shortcutCommandTitle(_ id: String) -> String {
        shortcutCommandPresentations[id]?.title ?? id
    }

    private static func shortcutCommandAliases(_ id: String) -> [String] {
        shortcutCommandPresentations[id]?.aliases ?? []
    }

    static func shortcutSettingsLabels(for action: ShortcutAction) -> (slash: String, palette: String) {
        if action == .inputHistorySearch {
            return ("slash：仅输入框上下文", "命令面板：无（输入框上下文入口）")
        }
        // These shortcuts operate on an existing UI context. Related command
        // names are not aliases for the same action and must not be executed
        // merely to fill the Settings command columns.
        switch action {
        case .mainPaneChat:
            return ("slash：无（主区聊天导航，不等同布局命令）",
                    "命令面板：无（“布局：聊天独占”是不同动作）")
        case .sendMessage:
            return ("slash：无（发送当前输入框内容）",
                    "命令面板：无（需当前输入框内容与发送条件）")
        case .focusComposer:
            return ("slash：无（聚焦当前输入框）",
                    "命令面板：无（当前输入框焦点操作）")
        case .composerMode:
            return ("slash：无（打开当前 Composer 权限模式菜单）",
                    "命令面板：无（打开模式菜单，不等同 /plan）")
        case .openShortcutReference:
            return ("slash：/shortcuts",
                    "命令面板：快捷键；设置菜单：查看快捷键…")
        case .escape:
            return ("slash：无（取消或关闭当前弹窗、输入上下文）",
                    "命令面板：无（仅操作当前已挂载的取消/关闭入口）")
        default:
            break
        }
        let ids = shortcutCommandMap.filter { $0.value == action }.map(\.key).sorted()
        // Exact App IDs name these registered handlers. A Core alias with the
        // same words can belong to a different command and approval route.
        let slash: String
        if ids.contains("ui.agent.approve") || ids.contains("ui.agent.reject") {
            slash = "仅审批上下文，不能从 slash 执行"
        } else {
            slash = ids.isEmpty ? "未登记对应命令" : ids.map { "/" + $0 }.joined(separator: "、")
        }
        let names = ids.map(shortcutCommandTitle)
        return (
            "slash：" + slash,
            "命令面板：" + (names.isEmpty ? "未登记对应命令" : names.joined(separator: "、"))
        )
    }

    /// Preset commands with a confirmation requirement have no App-side
    /// confirmation consumer. Keep every registry projection visibly blocked
    /// until a real confirmation route exists; `execute` also rejects them.
    static func missingConfirmationReason(for command: CommandDefinition) -> String? {
        guard !CommandRegistry.composerCommandIDs.contains(command.id),
              command.requiresConfirmation else { return nil }
        return "此命令当前没有确认执行入口"
    }

    /// 命令 id → ShortcutAction 的反向解析；菜单对未在其它入口占用的动作
    /// 挂载加速键，其他入口共用同一映射与展示绑定。
    static func shortcutAction(forCommandID id: String) -> ShortcutAction? {
        shortcutCommandMap[id]
    }

    /// Resolve the canonical effective display value from the shared shortcut
    /// store. Command metadata must not shadow a user-customized binding.
    @MainActor
    static func effectiveShortcut(
        forCommandID id: String,
        bridge: BridgeStore
    ) -> String? {
        guard let action = shortcutCommandMap[id] else { return nil }
        return bridge.shortcutStore.binding(for: action).displayString
    }

    /// 分类缺省图标（预置命令未声明图标时使用）。
    static func fallbackIcon(for category: CommandCategory) -> String {
        switch category {
        case .environment: "gearshape.2"
        case .logging: "doc.text"
        case .backend: "server.rack"
        case .session: "bubble.left.and.bubble.right"
        case .memory: "brain"
        case .workflow: "flowchart"
        case .settings: "gearshape"
        case .canvas: "square.grid.2x2"
        case .agent: "wand.and.rays"
        }
    }

    // F22④（Q8-r4 P2-2）：删除 quickaction → commandID 死代码映射。
    // `AppCommandCatalog.commandID(for: DeepLinkAction)` 在生产代码中零消费：
    // E9 quickaction 的真实执行路径是 DeepLinkRouter → DeepLinkHandler.handle
    //（MinisCanvasApp.swift 启动时注册，见 DeepLinkHandler.swift 头注释），
    // 该映射从未参与任何触发链路，仅被旧测试自证存在 → 属死代码，直接删除。
    // 深链动作 ↔ 命令的覆盖关系改由 C3_1CommandPaletteTests 断言
    //「每个默认 quickaction 深链可解析」+ E9 执行测试保障。

    // MARK: - 命令规格

    /// App UI 命令规格列表（静态命令 + 动态命令：按节点类型/快捷动作展开）。
    @MainActor
    static func specs(bridge: BridgeStore, dependencies: CommandDependencies) -> [AppCommandSpec] {
        let chatOnlyLane = bridge.canvasFeatureLane == .phase3NonCanvas
        var specs: [AppCommandSpec] = [
            appSpec(bridge, id: commandPaletteID, title: shortcutCommandTitle(commandPaletteID), category: .session,
                    icon: "command", keywords: ["命令面板", "打开命令面板", "command palette"]) { b in
                b.isCommandPalettePresented = true
            },
            // ── 会话（覆盖预置 session.new：UI 新建会话取代 store 直建）──
            appSpec(bridge,
                    id: "session.new", title: shortcutCommandTitle("session.new"), category: .session,
                    icon: "plus.square",
                    keywords: ["新建会话", "新会话", "session new", "新对话"]) { b in
                b.chat.newSession()
            },
            // ── 设置（覆盖预置 settings.open：走深链执行路径 → 打开设置窗口）──
            appSpec(bridge,
                    id: "settings.open", title: shortcutCommandTitle("settings.open"), category: .settings,
                    icon: "gearshape",
                    keywords: ["打开设置", "设置面板", "设置", "偏好设置"]) { b in
                b.deepLinkHandler.handle(.openSettings(id: nil))
            },
            taskCenterOpenSpec(bridge),
            appSpec(bridge,
                    id: "ui.taskcenter.next", title: shortcutCommandTitle("ui.taskcenter.next"), category: .session,
                    icon: "arrow.down.to.line",
                    keywords: ["下一个任务", "任务导航", "next task"]) { b in
                b.taskCenterNextCommandCount &+= 1
            },
            splitLayoutToggleSpec(
                bridge, id: "ui.sidebar.toggle", title: shortcutCommandTitle("ui.sidebar.toggle"),
                icon: "sidebar.left", keywords: ["会话侧栏", "折叠侧栏", "展开侧栏"],
                toggle: { $0.sidebarToggleCommandCount &+= 1 }
            ),
            splitLayoutToggleSpec(
                bridge, id: "ui.context.toggle", title: shortcutCommandTitle("ui.context.toggle"),
                icon: "sidebar.right", keywords: ["上下文面板", "折叠右栏", "展开右栏"],
                toggle: { $0.contextToggleCommandCount &+= 1 }
            ),
            // ── 布局 ──
            appSpec(bridge, id: "ui.layout.split",
                    title: chatOnlyLane ? "布局：聊天三栏" : "布局：并排（画布 + 聊天）",
                    category: chatOnlyLane ? .session : .canvas,
                    icon: "rectangle.split.2x1") { b in
                b.layoutMode = .split
                if chatOnlyLane {
                    b.chatThreeColumnCommandCount &+= 1
                }
            },
            appSpec(bridge, id: "ui.layout.canvas", title: "布局：画布独占",
                    category: .canvas, icon: "square.grid.2x2") { b in
                b.layoutMode = .canvas
            },
            appSpec(bridge, id: "ui.layout.chat", title: "布局：聊天独占",
                    category: chatOnlyLane ? .session : .canvas,
                    icon: "bubble.left.and.bubble.right") { b in
                b.layoutMode = .chat
            },
            // ── 画布 ──
            appSpec(bridge, id: "ui.canvas.run", title: shortcutCommandTitle("ui.canvas.run"),
                    category: .canvas, icon: "play.fill") { b in
                b.dispatchCanvasMutation(.runGraph(nodeIDs: nil))
            },
            appSpec(bridge, id: "ui.canvas.autolayout", title: "自动布局",
                    category: .canvas, icon: "square.grid.3x3.topleft.filled") { b in
                b.dispatchCanvasMutation(.autoLayout)
            },
            appSpec(bridge, id: "ui.canvas.reset", title: "重置节点状态",
                    category: .canvas, icon: "arrow.counterclockwise") { b in
                b.dispatchCanvasMutation(.resetStatuses)
            },
            appSpec(bridge, id: "ui.canvas.help", title: "画布指令帮助",
                    category: .canvas, icon: "questionmark.circle") { b in
                b.chat.appendAssistant(BridgeStore.helpText)
            },
            // ── 工作流 ──
            appSpec(bridge, id: "ui.pipeline", title: shortcutCommandTitle("ui.pipeline"),
                    category: .workflow, icon: "wand.and.stars",
                    keywords: ["一键流水线", "漫剧流水线", "生成流水线"]) { b in
                b.createManjuPipeline()
            },
            // ── 会话：停止生成 ──
            stopGenerationSpec(
                activeSessionID: { [weak bridge] in
                    guard let bridge else {
                        throw CommandExecutionError.disabled(
                            commandID: "ui.chat.stop", reason: "命令宿主已释放"
                        )
                    }
                    return bridge.chat.activeSessionID
                },
                stopStreaming: { [weak bridge] in
                    guard let bridge else {
                        throw CommandExecutionError.disabled(
                            commandID: "ui.chat.stop", reason: "命令宿主已释放"
                        )
                    }
                    bridge.chat.stopStreaming()
                },
                userStopStreaming: { [weak bridge] in
                    guard let bridge else {
                        throw CommandExecutionError.disabled(commandID: "ui.chat.stop", reason: "命令宿主已释放")
                    }
                    bridge.chat.stopStreaming(returnQueuedToDraft: true)
                }
            ),
            // ── 会话：压缩上下文（C4-3 Top4 compact-thread；右栏按钮共用 ChatStore.compactContext）──
            appSpec(bridge, id: "ui.chat.compact", title: shortcutCommandTitle("ui.chat.compact"),
                    category: .session, icon: "arrow.down.right.and.arrow.up.left",
                    keywords: ["压缩上下文", "compact", "压缩", "清理上下文"],
                    aliases: shortcutCommandAliases("ui.chat.compact")) { b in
                guard let sessionID = b.chat.activeSessionID,
                      (BridgeStore.compactInvocationSessionID ?? sessionID) == sessionID else {
                    throw CommandExecutionError.invalidArgument(
                        commandID: "ui.chat.compact", argument: "session_id",
                        reason: "压缩操作所属会话已切换或不可用"
                    )
                }
                b.chat.compactContext()
            },
            // ── Agent ──
            approvalSheetOnlySpec(id: "ui.agent.approve", title: shortcutCommandTitle("ui.agent.approve"),
                                  icon: "checkmark.shield", keywords: ["批准", "允许工具", "审批"]),
            approvalSheetOnlySpec(id: "ui.agent.reject", title: shortcutCommandTitle("ui.agent.reject"),
                                  icon: "xmark.shield", keywords: ["拒绝", "拒绝工具", "审批"]),
        ]

        // 动态命令：按节点类型展开（画布 → 建节点）
        // 注意：id 一律 lowercased —— CommandRegistry.command(id:) 按小写索引查找
        // （大小写不敏感契约），混合大小写 id（如 novelImport）会查不到 → 面板无法执行。
        // Phase B 瘦身：只展开 7 类生成类节点（文本创作类保留定义，不进建节点入口）
        for spec in NodeTypeRegistry.creatableSpecs {
            specs.append(appSpec(
                bridge,
                id: "ui.add-node." + spec.type.lowercased(),
                title: "建节点：" + spec.title,
                category: .canvas,
                icon: "plus.square.on.square",
                keywords: ["建节点", "添加节点", spec.title]
            ) { b in
                b.dispatchCanvasMutation(.addNode(type: spec.type, position: nil))
            })
        }
        if bridge.canvasFeatureLane == .phase3NonCanvas {
            specs.removeAll { isCanvasCommand($0.definition) }
        }
        return specs
    }

    /// The packaged Chat lane omits Canvas UI/preset executors; its three
    /// slash declarations are disabled metadata. The Bridge boundary also
    /// rejects direct/stale Canvas calls.
    private static func isCanvasCommand(_ command: CommandDefinition) -> Bool {
        command.category == .canvas || command.id == "ui.pipeline"
    }

    /// The existing stop consumer keeps menu calls unscoped. Composer buttons
    /// snapshot their session before Bridge's asynchronous registry dispatch.
    @MainActor
    static func stopGenerationSpec(
        activeSessionID: @escaping @MainActor @Sendable () throws -> UUID?,
        stopStreaming: @escaping @MainActor @Sendable () throws -> Void,
        userStopStreaming: (@MainActor @Sendable () throws -> Void)? = nil
    ) -> AppCommandSpec {
        let definition = CommandDefinition(
            id: "ui.chat.stop", title: shortcutCommandTitle("ui.chat.stop"), category: .session,
            argumentSpecs: [CommandArgumentSpec(
                name: "session_id", label: "点击时会话 ID", required: false
            )]
        ) { args in
            try await MainActor.run {
                let currentSessionID = try activeSessionID()
                if let expectedSession = args["session_id"],
                   expectedSession != (currentSessionID?.uuidString ?? "") {
                    throw CommandExecutionError.invalidArgument(
                        commandID: "ui.chat.stop", argument: "session_id",
                        reason: "停止操作所属会话已切换，未停止当前会话"
                    )
                }
                if args["return_queued_to_draft"] == "true", let userStopStreaming {
                    try userStopStreaming()
                } else {
                    try stopStreaming()
                }
            }
            return .success("")
        }
        return AppCommandSpec(definition: definition, icon: "stop.circle.fill", shortcut: nil)
    }

    /// 构造一条 App UI 命令：execute 在 MainActor 上执行 UI 动作并返回空文本
    /// （结果文本为空 → 面板/菜单执行后不刷聊天流；预置命令的文本结果照常展示）。
    private static func appSpec(
        _ bridge: BridgeStore,
        id: String,
        title: String,
        category: CommandCategory,
        icon: String,
        shortcut: String? = nil,
        keywords: [String] = [],
        aliases: [String] = [],
        requiresConfirmation: Bool = false,
        action: @escaping @MainActor (BridgeStore) throws -> Void
    ) -> AppCommandSpec {
        let definition = CommandDefinition(
            id: id,
            title: title,
            keywords: keywords,
            aliases: aliases,
            category: category,
            requiresConfirmation: requiresConfirmation
        ) { [weak bridge] _ in
            guard let bridge else {
                throw CommandExecutionError.disabled(commandID: id, reason: "命令宿主已释放")
            }
            try await MainActor.run { try action(bridge) }
            return .success("")
        }
        return AppCommandSpec(definition: definition, icon: icon, shortcut: shortcut)
    }

    /// Toolbar origin is presentation state, not authority. Keep the previous
    /// focus restoration only for the actual toolbar button.
    private static func taskCenterOpenSpec(_ bridge: BridgeStore) -> AppCommandSpec {
        let id = "ui.taskcenter.open"
        let definition = CommandDefinition(
            id: id, title: "打开任务中心", keywords: ["任务中心", "查看任务", "task center"],
            category: .session,
            argumentSpecs: [CommandArgumentSpec(
                name: "opener", label: "打开来源", required: false,
                choices: ["toolbar"]
            )]
        ) { [weak bridge] args in
            if let opener = args["opener"], opener != "toolbar" {
                throw CommandExecutionError.invalidArgument(
                    commandID: id, argument: "opener", reason: "未知的任务中心打开来源"
                )
            }
            guard let bridge else {
                throw CommandExecutionError.disabled(commandID: id, reason: "命令宿主已释放")
            }
            await MainActor.run {
                bridge.taskCenterOpenIntent = TaskCenterOpenIntent(
                    toolbarOpener: args["opener"] == "toolbar"
                )
            }
            return .success("")
        }
        return AppCommandSpec(definition: definition, icon: "checklist", shortcut: nil)
    }

    private static func splitLayoutToggleSpec(
        _ bridge: BridgeStore,
        id: String,
        title: String,
        icon: String,
        keywords: [String],
        toggle: @escaping @MainActor (BridgeStore) -> Void
    ) -> AppCommandSpec {
        let reason = "仅三栏布局可用"
        let layout = bridge.splitLayoutCommandAvailability
        let definition = CommandDefinition(
            id: id, title: title, keywords: keywords, category: .session,
            availability: { layout.isSplit ? .enabled : .disabled(reason: reason) }
        ) { [weak bridge] _ in
            guard let bridge else {
                throw CommandExecutionError.disabled(commandID: id, reason: "命令宿主已释放")
            }
            try await MainActor.run {
                guard bridge.layoutMode == .split else {
                    throw CommandExecutionError.disabled(commandID: id, reason: reason)
                }
                toggle(bridge)
            }
            return .success("")
        }
        return AppCommandSpec(definition: definition, icon: icon, shortcut: nil)
    }

    /// The approval sheet owns the rendered request and its L3 confirmation
    /// step. A palette/menu command has no captured card identity, so it stays
    /// discoverable but cannot claim to approve or reject a tool call.
    private static func approvalSheetOnlySpec(
        id: String, title: String, icon: String, keywords: [String]
    ) -> AppCommandSpec {
        let reason = "请在当前工具审批弹窗操作"
        let definition = CommandDefinition(
            id: id, title: title, keywords: keywords, category: .agent,
            availability: { .disabled(reason: reason) }
        ) { _ in
            throw CommandExecutionError.disabled(commandID: id, reason: reason)
        }
        return AppCommandSpec(definition: definition, icon: icon, shortcut: nil)
    }
}

// MARK: - 收藏

/// 收藏命令存储（UserDefaults 持久化，id 有序）。
/// 测试注入独立 suite 避免污染真实偏好。
final class FavoriteCommandsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "favoriteCommandIDs"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isFavorite(_ id: String) -> Bool {
        favoriteIDs().contains(id)
    }

    /// 有序收藏列表（新收藏追加到末尾）。
    func favoriteIDs() -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    func toggle(_ id: String) {
        var ids = favoriteIDs()
        if let idx = ids.firstIndex(of: id) {
            ids.remove(at: idx)
        } else {
            ids.append(id)
        }
        defaults.set(ids, forKey: key)
    }
}

// MARK: - 面板数据模型

/// 面板展示行：命令 + 展示元数据 + 收藏态。
struct PaletteCommand: Identifiable, Equatable {
    let id: String
    let title: String
    let icon: String
    let shortcut: String?
    let category: CommandCategory
    let isFavorite: Bool
    let isEnabled: Bool
    let disabledReason: String?
}

/// 结果分组（ComfyUI searchbox v2 的「分类侧栏 + 结果列表」中的一节）。
struct PaletteSection: Identifiable, Equatable {
    let id: String
    let title: String
    let commands: [PaletteCommand]

    static let favoritesID = "favorites"
}

/// 面板逻辑模型：输入即过滤（250ms 防抖）+ 分类分组 + 收藏置顶。
/// 纯数据层，不持有 View/Bridge——执行由 View 调 `BridgeStore.runCommand`。
@MainActor
@Observable
final class CommandPaletteModel {

    let registry: CommandRegistry
    private let display: [String: PaletteDisplayInfo]
    private let favorites: FavoriteCommandsStore
    /// 防抖间隔（测试注入更小值或直接调 `refresh()` 同步计算）。
    let debounceInterval: Duration

    /// 当前输入（经 `updateQuery` 修改才会触发防抖重算）。
    private(set) var query: String = ""
    /// 侧栏选中分类；nil = 全部。
    var selectedCategory: CommandCategory?
    /// 当前展示的分组结果。
    private(set) var sections: [PaletteSection] = []

    private var debounceTask: Task<Void, Never>?

    init(
        registry: CommandRegistry,
        display: [String: PaletteDisplayInfo],
        favorites: FavoriteCommandsStore,
        debounceInterval: Duration = .milliseconds(250)
    ) {
        self.registry = registry
        self.display = display
        self.favorites = favorites
        self.debounceInterval = debounceInterval
        refresh()
    }

    // MARK: 输入与防抖

    /// 更新输入并调度 250ms 防抖重算（连续输入只应用最后一次）。
    func updateQuery(_ q: String) {
        query = q
        debounceTask?.cancel()
        let snapshot = q
        debounceTask = Task { [debounceInterval] in
            try? await Task.sleep(for: debounceInterval)
            guard !Task.isCancelled else { return }
            self.apply(snapshot)
        }
    }

    /// 立即重算（回车 / 测试用）。
    func refresh() {
        debounceTask?.cancel()
        apply(query)
    }

    private func apply(_ q: String) {
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let favoriteIDs = Set(favorites.favoriteIDs())
        let commands = allCommands()
        let iconOf = icon(for:)

        func paletteCommand(_ def: CommandDefinition) -> PaletteCommand {
            let availability = def.currentAvailability
            let confirmationReason = AppCommandCatalog.missingConfirmationReason(for: def)
            return PaletteCommand(
                id: def.id,
                title: def.title,
                icon: iconOf(def),
                shortcut: display[def.id]?.shortcut,
                category: def.category,
                isFavorite: favoriteIDs.contains(def.id),
                isEnabled: availability == .enabled && confirmationReason == nil
                    && ComposerCommandAdjudicationCenter.missingExecutorReason(for: def.id) == nil,
                disabledReason: availability.disabledReason ?? confirmationReason ?? ComposerCommandAdjudicationCenter.missingExecutorReason(for: def.id)
            )
        }

        let categoryFilter: (CommandDefinition) -> Bool = { [selectedCategory] def in
            selectedCategory == nil || def.category == selectedCategory
        }

        if trimmed.isEmpty {
            // 空输入：收藏置顶 + 按分类分组（分类顺序 = allCases 声明序，空分类跳过）
            // 收藏也应用分类过滤：选中某分类时只显示该分类的收藏（与搜索分支一致）
            var result: [PaletteSection] = []
            let favs = commands
                .filter { favoriteIDs.contains($0.id) && categoryFilter($0) }
                .map(paletteCommand)
            if !favs.isEmpty {
                result.append(PaletteSection(id: PaletteSection.favoritesID, title: "收藏 ⭐", commands: favs))
            }
            for category in CommandCategory.allCases {
                let items = commands
                    .filter { $0.category == category && categoryFilter($0) }
                    .map(paletteCommand)
                if !items.isEmpty {
                    result.append(PaletteSection(id: category.rawValue, title: category.displayName, commands: items))
                }
            }
            sections = result
        } else {
            // 有输入：注册表检索（相关度排序）→ 分类过滤 → 收藏置顶
            let hits = registry.search(trimmed, limit: 50).filter(categoryFilter)
            let favs = hits.filter { favoriteIDs.contains($0.id) }.map(paletteCommand)
            let rest = hits.filter { !favoriteIDs.contains($0.id) }.map(paletteCommand)
            var result: [PaletteSection] = []
            if !favs.isEmpty {
                result.append(PaletteSection(id: PaletteSection.favoritesID, title: "收藏 ⭐", commands: favs))
            }
            result.append(PaletteSection(id: "results", title: "结果（\(hits.count)）", commands: rest))
            sections = result
        }
    }

    // MARK: 查询

    /// 全部命令（注册顺序）——面板展示的唯一数据源。
    func allCommands() -> [CommandDefinition] {
        registry.allCommands()
    }

    /// 侧栏分类计数（按全部命令统计，不随输入变化）。
    var categoryCounts: [(category: CommandCategory, count: Int)] {
        var counts: [CommandCategory: Int] = [:]
        for def in allCommands() {
            counts[def.category, default: 0] += 1
        }
        return CommandCategory.allCases.compactMap { category in
            guard let count = counts[category], count > 0 else { return nil }
            return (category, count)
        }
    }

    /// 全部命令数（侧栏「全部」计数）。
    var totalCount: Int { allCommands().count }

    func toggleFavorite(_ id: String) {
        favorites.toggle(id)
        apply(query)
    }

    func isFavorite(_ id: String) -> Bool {
        favorites.isFavorite(id)
    }

    private func icon(for def: CommandDefinition) -> String {
        display[def.id]?.icon ?? AppCommandCatalog.fallbackIcon(for: def.category)
    }
}

// MARK: - 菜单构建（与面板同一数据源）

/// 从 Registry 生成应用菜单分组——面板 / 菜单同一命令源。
enum AppCommandMenuBuilder {
    /// Visible command buttons consume the same registered facts as menus.
    /// Execution remains at BridgeStore.runCommand and CommandRegistry.execute.
    @MainActor
    static func command(
        id: String,
        registry: CommandRegistry,
        display: [String: PaletteDisplayInfo]
    ) -> PaletteCommand? {
        registry.command(id: id).map { project($0, display: display) }
    }

    @MainActor
    private static func project(
        _ def: CommandDefinition,
        display: [String: PaletteDisplayInfo]
    ) -> PaletteCommand {
        let availability = def.currentAvailability
        let confirmationReason = AppCommandCatalog.missingConfirmationReason(for: def)
        return PaletteCommand(
            id: def.id,
            title: def.title,
            icon: display[def.id]?.icon ?? AppCommandCatalog.fallbackIcon(for: def.category),
            shortcut: display[def.id]?.shortcut,
            category: def.category,
            isFavorite: false,
            isEnabled: availability == .enabled && confirmationReason == nil
                    && ComposerCommandAdjudicationCenter.missingExecutorReason(for: def.id) == nil,
            disabledReason: availability.disabledReason ?? confirmationReason ?? ComposerCommandAdjudicationCenter.missingExecutorReason(for: def.id)
        )
    }

    /// 按分类分组的菜单节（不含收藏节；收藏是面板交互，菜单展示全量）。
    @MainActor
    static func sections(
        registry: CommandRegistry,
        display: [String: PaletteDisplayInfo]
    ) -> [PaletteSection] {
        var result: [PaletteSection] = []
        for category in CommandCategory.allCases {
            let items = registry.commands(category: category).map { def in
                project(def, display: display)
            }
            if !items.isEmpty {
                result.append(PaletteSection(id: category.rawValue, title: category.displayName, commands: items))
            }
        }
        return result
    }
}
