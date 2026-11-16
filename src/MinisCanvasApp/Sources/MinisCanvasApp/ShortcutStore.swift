import SwiftUI
import Foundation
import AppKit
import MinisCore
import CryptoKit

// MARK: - AJ-57 快捷键设置：可配置按键绑定
//
// 参照 Minis 桌面版：把原本硬编码的键盘快捷键（命令面板现默认 ⌘K、⌘1/2/3 主区切换、
// ⌘P 流水线、⌘⇧C 侧栏、⌥⌘→ 上下文面板、⌘⏎/⌘. 发送停止、⌘,/⌘N 设置与会话等）
// 收进 ShortcutStore，UserDefaults 持久化 + 默认值表，设置页可录制/冲突检测/恢复默认，
// ContentView / 命令面板 / 全局对话条 / 上下文面板的 keyboardShortcut 动态读 Store。

// MARK: - 修饰键（Codable 标志位，避免 EventModifiers 的 Codable 兼容问题）

/// 快捷键修饰键组合（⌘/⌃/⌥/⇧ 四枚布尔标志）。
struct ShortcutModifiers: Codable, Equatable, Hashable, Sendable {
    var command = false
    var control = false
    var option = false
    var shift = false

    static let none = ShortcutModifiers()
    static let command = ShortcutModifiers(command: true)
    static let control = ShortcutModifiers(control: true)
    static let optionCommand = ShortcutModifiers(command: true, option: true)
    static let commandShift = ShortcutModifiers(command: true, shift: true)
    static let commandControl = ShortcutModifiers(command: true, control: true)

    /// SwiftUI EventModifiers（用于 .keyboardShortcut(_:modifiers:)）。
    var eventModifiers: EventModifiers {
        var m: EventModifiers = []
        if command { m.insert(.command) }
        if control { m.insert(.control) }
        if option { m.insert(.option) }
        if shift { m.insert(.shift) }
        return m
    }

    /// 展示字符串（⌃⌥⇧⌘ 顺序，与 macOS 惯例一致）。
    var displayString: String {
        var s = ""
        if control { s += "⌃" }
        if option { s += "⌥" }
        if shift { s += "⇧" }
        if command { s += "⌘" }
        return s
    }
}

// MARK: - 绑定模型

/// 一个可配置的按键绑定：key（字符或特殊键名）+ 修饰键。
struct ShortcutBinding: Codable, Equatable, Hashable, Sendable {
    /// 键名：单字符（字母小写）或特殊键名（space/return/upArrow/…/escape/tab/delete）。
    var key: String
    var modifiers: ShortcutModifiers

    /// 是否为空（无修饰键 + 无 key）→ 表示禁用该快捷键。
    var isEmpty: Bool { key.isEmpty && modifiers == .none }

    /// 从 NSEvent 规范化构造（录音用；特殊键经 keyCode 映射，普通键取小写字符）。
    init(key: String, modifiers: EventModifiers) {
        self.key = Self.canonicalKey(key)
        self.modifiers = ShortcutModifiers(
            command: modifiers.contains(.command),
            control: modifiers.contains(.control),
            option: modifiers.contains(.option),
            shift: modifiers.contains(.shift)
        )
    }

    init(key: String, modifiers: ShortcutModifiers) {
        self.key = Self.canonicalKey(key)
        self.modifiers = modifiers
    }

    /// 与 keyEquivalent 的首字符语义一致，旧持久化键也按此身份比较。
    private static func canonicalKey(_ raw: String) -> String {
        if ["\r", "\n", "\r\n", "\u{3}"].contains(raw) { return "return" }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch key {
        case "space": return "space"
        case "return", "enter", "keypadenter", "keypad enter", "numpadenter", "numpad enter", "↩", "↵", "⏎", "⌤": return "return"
        case "uparrow": return "upArrow"
        case "downarrow": return "downArrow"
        case "leftarrow": return "leftArrow"
        case "rightarrow": return "rightArrow"
        case "delete": return "delete"
        case "escape": return "escape"
        case "tab": return "tab"
        default: return key.isEmpty ? "" : String(key.first!)
        }
    }

    /// 展示字符串（⌘⇧⏎ 等）。
    var displayString: String {
        guard !isEmpty else { return "无" }
        return modifiers.displayString + keyDisplay
    }

    /// key 的展示（特殊键名 → 符号）。
    private var keyDisplay: String {
        switch key {
        case "space": return "空格"
        case "return": return "⏎"
        case "upArrow": return "↑"
        case "downArrow": return "↓"
        case "leftArrow": return "←"
        case "rightArrow": return "→"
        case "delete": return "⌫"
        case "escape": return "⎋"
        case "tab": return "⇥"
        default: return key.uppercased()
        }
    }

    /// SwiftUI KeyEquivalent（用于 .keyboardShortcut）。
    var keyEquivalent: KeyEquivalent {
        switch key {
        case "space": return " "
        case "return": return .return
        case "upArrow": return .upArrow
        case "downArrow": return .downArrow
        case "leftArrow": return .leftArrow
        case "rightArrow": return .rightArrow
        case "delete": return .delete
        case "escape": return .escape
        case "tab": return .tab
        default:
            let c = key.first ?? "?"
            return KeyEquivalent(c)
        }
    }

    /// 把 NSEvent 的 keyCode 规范化成 key 名（特殊键 keyCode → 命名字符串）。
    static func keyName(fromKeyCode keyCode: UInt16, charactersIgnoringModifiers: String?) -> String {
        switch keyCode {
        case 36, 76: return "return"
        case 48: return "tab"
        case 49: return "space"
        case 53: return "escape"
        case 51: return "delete"
        case 123: return "leftArrow"
        case 124: return "rightArrow"
        case 125: return "downArrow"
        case 126: return "upArrow"
        default:
            let chars = charactersIgnoringModifiers?.lowercased() ?? ""
            return chars.isEmpty ? "?" : String(chars.first!)
        }
    }
}

// MARK: - 分组与动作目录

/// 快捷键分组（设置页分区）。
enum ShortcutGroup: String, CaseIterable, Identifiable, Sendable {
    case palette = "面板"
    case main = "主区"
    case session = "会话"
    case canvas = "画布"
    case general = "通用"

    var id: String { rawValue }
}

/// 可配置的快捷键动作（默认值表 = 现有硬编码快捷键）。
enum ShortcutAction: String, CaseIterable, Identifiable, Equatable, Sendable {
    case commandPalette = "commandPalette"
    case mainPaneChat = "mainPaneChat"
    case mainPaneCanvas = "mainPaneCanvas"
    // 2026-08-06：mainPaneDocuments（⌘3 主区：工作）随工作板块整体移除
    case toggleSessionSidebar = "toggleSessionSidebar"
    case toggleContextPanel = "toggleContextPanel"
    case sendMessage = "sendMessage"
    case stopGeneration = "stopGeneration"
    case createPipeline = "createPipeline"
    case openSettings = "openSettings"
    case openShortcutReference = "openShortcutReference"
    case newSession = "newSession"
    case compactContext = "compactContext"
    // D-COMMAND-04：47 号日常快捷键目录中的画布/会话/审批动作。
    // 这些动作先进入统一 ShortcutStore，实际执行入口仍由各自 producer/consumer 决定。
    case runCanvas = "runCanvas"
    case cancelCanvas = "cancelCanvas"
    case toggleMiniMap = "toggleMiniMap"
    case focusComposer = "focusComposer"
    case composerMode = "composerMode"
    case nextTask = "nextTask"
    case approveRequest = "approveRequest"
    case rejectRequest = "rejectRequest"
    case escape = "escape"
    case inputHistorySearch = "inputHistorySearch"

    var id: String { rawValue }

    /// 用户可读标题。
    var title: String {
        switch self {
        case .commandPalette: return "打开命令面板"
        case .mainPaneChat: return "主区：聊天"
        case .mainPaneCanvas: return "主区：画布"
        // 2026-08-06：主区：工作（⌘3）随工作板块移除
        case .toggleSessionSidebar: return "折叠/展开会话侧栏"
        case .toggleContextPanel: return "折叠/展开上下文面板"
        case .sendMessage: return "发送消息"
        case .stopGeneration: return "停止生成"
        case .createPipeline: return "一键漫剧流水线"
        case .openSettings: return "打开设置"
        case .openShortcutReference: return "查看快捷键"
        case .newSession: return "新建会话"
        case .compactContext: return "压缩当前会话"
        case .runCanvas: return "执行画布"
        case .cancelCanvas: return "取消画布执行"
        case .toggleMiniMap: return "显示/隐藏小地图"
        case .focusComposer: return "聚焦输入框"
        case .composerMode: return "选择任务模式"
        case .nextTask: return "查看下一个任务"
        case .approveRequest: return "批准当前请求"
        case .rejectRequest: return "拒绝当前请求"
        case .escape: return "取消/关闭当前弹窗"
        case .inputHistorySearch: return "输入历史搜索"
        }
    }

    var group: ShortcutGroup {
        switch self {
        case .commandPalette: return .palette
        case .mainPaneChat, .mainPaneCanvas, .toggleSessionSidebar, .toggleContextPanel: return .main
        case .sendMessage, .stopGeneration, .newSession, .compactContext,
             .focusComposer, .composerMode, .nextTask, .inputHistorySearch: return .session
        case .createPipeline, .runCanvas, .cancelCanvas, .toggleMiniMap: return .canvas
        case .openSettings, .openShortcutReference, .approveRequest, .rejectRequest, .escape: return .general
        }
    }

    /// Scoped Escape uses existing dismissal outlets; native Escape and the
    /// Canvas execution lane keep their existing behavior.
    var unavailableReason: String? { nil }

    /// 默认绑定。命令面板按 D-APP-08 用户决定默认 ⌘K；已有用户改绑仍优先。
    var defaultBinding: ShortcutBinding {
        switch self {
        case .commandPalette: return ShortcutBinding(key: "k", modifiers: ShortcutModifiers.command)
        case .mainPaneChat: return ShortcutBinding(key: "1", modifiers: ShortcutModifiers.command)
        case .mainPaneCanvas: return ShortcutBinding(key: "2", modifiers: ShortcutModifiers.command)
        case .toggleSessionSidebar: return ShortcutBinding(key: "c", modifiers: ShortcutModifiers.commandShift)
        case .toggleContextPanel: return ShortcutBinding(key: "rightArrow", modifiers: ShortcutModifiers.optionCommand)
        case .sendMessage: return ShortcutBinding(key: "return", modifiers: ShortcutModifiers.command)
        case .stopGeneration: return ShortcutBinding(key: ".", modifiers: ShortcutModifiers.command)
        case .createPipeline: return ShortcutBinding(key: "", modifiers: ShortcutModifiers.none)
        case .openSettings: return ShortcutBinding(key: ",", modifiers: ShortcutModifiers.command)
        case .openShortcutReference: return ShortcutBinding(key: "/", modifiers: ShortcutModifiers.command)
        case .newSession: return ShortcutBinding(key: "n", modifiers: ShortcutModifiers.command)
        case .compactContext: return ShortcutBinding(key: "", modifiers: ShortcutModifiers.none)
        case .runCanvas: return ShortcutBinding(key: "", modifiers: ShortcutModifiers.none)
        case .cancelCanvas: return ShortcutBinding(key: ".", modifiers: ShortcutModifiers.commandShift)
        // ⌘M is macOS Minimize and is rejected by systemReserved. Canvas is
        // deferred in the current lane, so do not advertise an unusable default.
        case .toggleMiniMap: return ShortcutBinding(key: "", modifiers: ShortcutModifiers.none)
        case .focusComposer: return ShortcutBinding(key: "l", modifiers: ShortcutModifiers.command)
        case .composerMode: return ShortcutBinding(key: "m", modifiers: ShortcutModifiers.commandShift)
        case .nextTask: return ShortcutBinding(key: "j", modifiers: ShortcutModifiers.command)
        case .inputHistorySearch: return ShortcutBinding(key: "r", modifiers: ShortcutModifiers.commandShift)
        case .approveRequest: return ShortcutBinding(key: "y", modifiers: ShortcutModifiers.command)
        case .rejectRequest: return ShortcutBinding(key: "y", modifiers: ShortcutModifiers.commandShift)
        // Native Esc continues to cancel its owning sheet/text field; no
        // configurable app-wide consumer exists for this catalog entry.
        case .escape: return ShortcutBinding(key: "", modifiers: ShortcutModifiers.none)
        }
    }
}

// MARK: - 冲突

/// 录制/设置绑定时的冲突原因。
enum ShortcutConflict: Equatable, Sendable {
    /// 与另一个动作撞键。
    case action(ShortcutAction)
    /// 与系统保留快捷键撞键。
    case system
    case approvalSafety
    case persistence
}

extension ShortcutConflict: Identifiable {
    var id: String {
        switch self {
        case .action(let other): return "action-\(other.rawValue)"
        case .system: return "system"
        case .approvalSafety: return "approval-safety"
        case .persistence: return "persistence"
        }
    }

    /// 用户可读的冲突提示（设置页 alert 用）。
    var message: String {
        switch self {
        case .action(let other): return "“\(other.title)”已占用该按键，请换一个组合。"
        case .system: return "该按键与系统保留快捷键冲突，请换一个组合。"
        case .approvalSafety: return "审批快捷键必须包含 ⌘，且不能使用 Return/Enter（包括 ⌘↩）；默认允许为 ⌘Y，拒绝为 ⌘⇧Y。"
        case .persistence: return "快捷键未能保存，请重新打开设置后再试。"
        }
    }
}

// MARK: - Store

/// 快捷键存储：操作 id → 按键组合，UserDefaults 持久化 + 默认值表。
/// @Observable 让设置页 / ContentView / 命令面板在绑定变更时自动刷新动态绑定。
@MainActor
@Observable
final class ShortcutStore {

    private static let defaultsKey = SettingsRecoveryAttachment.shortcutDefaultsKey
    private static let formerPaletteDefault = ShortcutBinding(
        key: "space", modifiers: ShortcutModifiers.control
    )
    private static let unbound = ShortcutBinding(key: "", modifiers: ShortcutModifiers.none)

    private struct CompletedShortcutEffect: Codable, Equatable {
        let record: BL6SettingsReplayRecord
        let previousOverrides: [String: ShortcutBinding]
    }

    /// One preferences value contains the bindings and their completion/undo
    /// evidence. This is a UserDefaults reopen contract, not an fsync promise.
    private struct TransactionValue: Codable {
        let version: Int
        var overrides: [String: ShortcutBinding]
        var revision: String
        var profileID: String
        var completed: [String: CompletedShortcutEffect]
    }

    private let defaults: UserDefaults
    private let recoverySuiteName: String?
    private(set) var lastPersistenceError: SettingsPersistenceError?
    /// 用户覆盖表（仅存「改过的」动作；未覆盖动作回落默认值表）。
    /// 被 @Observable 追踪 → 每次变更触发视图刷新。
    private var overrides: [String: ShortcutBinding]

    /// Bridge may expose this Store's live projection only when its UI and
    /// command consumers share the same injected preference domain.
    func usesPreferencesDomain(_ candidate: UserDefaults) -> Bool {
        defaults === candidate
    }

    init(defaults: UserDefaults? = nil, recoverySuiteName: String? = nil) {
        let defaultProfile = defaults == nil
            ? RuntimeIsolationProfile.formalTestProfileForDefaultConsumer() : nil
        if defaults == nil, defaultProfile == nil,
           RuntimeIsolationProfile.isRunningInTestProcess() {
            preconditionFailure("Formal test profile required for ShortcutStore defaults")
        }
        let defaults = defaults ?? defaultProfile?.makeUserDefaults() ?? .standard
        self.defaults = defaults
        self.recoverySuiteName = recoverySuiteName ?? defaultProfile?.userDefaultsSuiteName
        let data = defaults.data(forKey: Self.defaultsKey)
        if let value = try? Self.readValue(data) {
            let sanitized = Self.sanitizeOverrides(value.overrides)
            self.overrides = sanitized
            // Retain legacy migration, but never rewrite transaction evidence
            // whose values no longer satisfy the canonical shortcut rules.
            if sanitized != value.overrides, value.profileID.isEmpty {
                persist()
            }
        } else {
            self.overrides = [:]
            self.lastPersistenceError = .transactionRecoveryRequired
        }
    }

    private static func approvalBindingIsAllowed(_ binding: ShortcutBinding, for action: ShortcutAction) -> Bool {
        guard action == .approveRequest || action == .rejectRequest else { return true }
        let canonical = ShortcutBinding(key: binding.key, modifiers: binding.modifiers)
        return canonical.modifiers.command && !canonical.key.isEmpty && canonical.key != "return"
    }

    /// 旧持久化值绕过绑定构造器；重建键身份，丢弃未知/系统保留/冲突覆盖。
    /// 冲突覆盖回落默认值后可能出现第二轮碰撞，因此迭代到稳定态。
    private static func sanitizeOverrides(
        _ decoded: [String: ShortcutBinding]
    ) -> [String: ShortcutBinding] {
        var recognized: [String: ShortcutBinding] = [:]
        for action in ShortcutAction.allCases {
            guard let decodedBinding = decoded[action.id] else { continue }
            let binding = ShortcutBinding(
                key: decodedBinding.key,
                modifiers: decodedBinding.modifiers
            )
            guard approvalBindingIsAllowed(binding, for: action),
                  !systemReserved.contains(binding) else { continue }
            recognized[action.id] = binding
        }

        while true {
            var owners: [ShortcutBinding: [ShortcutAction]] = [:]
            for action in ShortcutAction.allCases {
                let binding = effectiveBinding(for: action, overrides: recognized)
                guard !binding.isEmpty else { continue }
                owners[binding, default: []].append(action)
            }

            let conflictingOverrides = Set(owners.values
                .filter { $0.count > 1 }
                .flatMap { $0.map(\.id) })
            guard !conflictingOverrides.isEmpty else { break }
            var removed = false
            for action in ShortcutAction.allCases where conflictingOverrides.contains(action.id) {
                if recognized.removeValue(forKey: action.id) != nil {
                    removed = true
                }
            }
            if !removed { break } // 默认绑定不由持久化值改写。
        }
        return recognized
    }

    /// 某动作的有效绑定（覆盖值 ?? 默认值）。
    func binding(for action: ShortcutAction) -> ShortcutBinding {
        Self.effectiveBinding(for: action, overrides: overrides)
    }

    /// Export only known user overrides. The target's private transaction
    /// records, revision and suite identity never enter a backup.
    func recoveryOverrides() throws -> [ShortcutRecoveryOverride] {
        guard let value = try? Self.readValue(defaults.data(forKey: Self.defaultsKey)),
              Self.sanitizeOverrides(value.overrides) == value.overrides else {
            throw SettingsRecoveryAttachmentError.invalidShortcut
        }
        return try value.overrides.keys.sorted().map { id in
            guard ShortcutAction(rawValue: id) != nil, let binding = value.overrides[id] else {
                throw SettingsRecoveryAttachmentError.invalidShortcut
            }
            return ShortcutRecoveryOverride(
                actionID: id, key: binding.key,
                command: binding.modifiers.command, control: binding.modifiers.control,
                option: binding.modifiers.option, shift: binding.modifiers.shift
            )
        }
    }

    /// Read-only preparation of one target UserDefaults value. It reuses the
    /// canonical key, system-reserved and collision rules before the Core
    /// journal may write. Source-side approval history is never imported.
    func prepareRecovery(_ incoming: [ShortcutRecoveryOverride]) throws -> ShortcutRecoveryPlan {
        if recoverySuiteName == nil && defaults !== UserDefaults.standard {
            throw SettingsRecoveryAttachmentError.invalidShortcut
        }
        let beforeData = defaults.data(forKey: Self.defaultsKey)
        guard var current = try? Self.readValue(beforeData),
              Self.sanitizeOverrides(current.overrides) == current.overrides else {
            throw SettingsRecoveryAttachmentError.invalidShortcut
        }
        var candidate: [String: ShortcutBinding] = [:]
        for entry in incoming {
            try entry.validateShape()
            guard ShortcutAction(rawValue: entry.actionID) != nil,
                  candidate[entry.actionID] == nil else {
                throw SettingsRecoveryAttachmentError.invalidShortcut
            }
            let modifiers = ShortcutModifiers(
                command: entry.command, control: entry.control,
                option: entry.option, shift: entry.shift
            )
            let binding = ShortcutBinding(key: entry.key, modifiers: modifiers)
            guard binding.key == entry.key,
                  !entry.key.isEmpty || modifiers == .none else {
                throw SettingsRecoveryAttachmentError.invalidShortcut
            }
            candidate[entry.actionID] = binding
        }
        guard Self.sanitizeOverrides(candidate) == candidate else {
            throw SettingsRecoveryAttachmentError.invalidShortcut
        }
        current.overrides = candidate
        current.revision = UUID().uuidString
        // Old target completion/undo records refer to the pre-import table.
        // Neither those nor source-side approval history may authorize a
        // mutation of the restored bindings after reopen.
        current.completed = [:]
        let afterData: Data
        if current.profileID.isEmpty {
            afterData = try JSONEncoder().encode(candidate)
        } else {
            afterData = try JSONEncoder().encode(current)
        }
        return ShortcutRecoveryPlan(
            suiteName: recoverySuiteName, beforeData: beforeData, afterData: afterData
        )
    }

    func recoveryTarget() throws -> ShortcutRecoveryTarget {
        if recoverySuiteName == nil && defaults !== UserDefaults.standard {
            throw SettingsRecoveryAttachmentError.invalidShortcut
        }
        return ShortcutRecoveryTarget(defaults: defaults, suiteName: recoverySuiteName)
    }

    /// 旧版本允许其他动作显式占用 ⌘K。升级后不丢弃这种用户改绑：
    /// 无面板显式覆盖时，面板退回旧 ⌃Space；若它也被显式占用，则保持未绑定。
    /// 新安装及无冲突配置仍默认 ⌘K，resetAll 清除覆盖后亦然。
    private static func effectiveBinding(
        for action: ShortcutAction,
        overrides: [String: ShortcutBinding]
    ) -> ShortcutBinding {
        if let override = overrides[action.id] { return override }
        if action == .inputHistorySearch,
           ShortcutAction.allCases.contains(where: { $0 != action && overrides[$0.id] == action.defaultBinding }) {
            return unbound // New defaults never displace an existing manual binding.
        }
        guard action == .commandPalette else { return action.defaultBinding }

        let claimedByOtherAction = ShortcutAction.allCases.contains {
            $0 != .commandPalette && overrides[$0.id] == action.defaultBinding
        }
        guard claimedByOtherAction else { return action.defaultBinding }

        let formerDefaultClaimed = ShortcutAction.allCases.contains {
            $0 != .commandPalette && overrides[$0.id] == formerPaletteDefault
        }
        return formerDefaultClaimed ? unbound : formerPaletteDefault
    }

    /// 尝试设置绑定；冲突时返回冲突原因且不写入（冲突检测）。
    /// - Returns: nil = 成功；否则返回冲突原因。
    @discardableResult
    func setBinding(_ binding: ShortcutBinding, for action: ShortcutAction) -> ShortcutConflict? {
        let binding = action == .approveRequest || action == .rejectRequest
            ? ShortcutBinding(key: binding.key, modifiers: binding.modifiers) : binding
        if let conflict = conflict(for: action, to: binding) {
            return conflict
        }
        var candidate = overrides
        candidate[action.id] = binding
        guard persist(candidate: candidate) else { return .persistence }
        overrides = candidate
        return nil
    }

    /// 恢复某动作默认绑定；默认键已被用户改绑占用时保留双方当前绑定。
    /// 候选表也用于计算命令面板的兼容回落，避免误判合法的旧改绑。
    @discardableResult
    func reset(for action: ShortcutAction) -> ShortcutConflict? {
        var candidate = overrides
        candidate.removeValue(forKey: action.id)
        let target = Self.effectiveBinding(for: action, overrides: candidate)
        if !target.isEmpty {
            for other in ShortcutAction.allCases where other != action {
                if Self.effectiveBinding(for: other, overrides: candidate) == target {
                    return .action(other)
                }
            }
        }
        guard persist(candidate: candidate) else { return .persistence }
        overrides = candidate
        return nil
    }

    /// 恢复全部默认绑定。
    func resetAll() {
        if persist(candidate: [:]) { overrides = [:] }
    }

    /// 冲突检测：与其它动作撞键 → .action；与系统保留 → .system。
    func conflict(for action: ShortcutAction, to targetBinding: ShortcutBinding) -> ShortcutConflict? {
        let targetBinding = action == .approveRequest || action == .rejectRequest
            ? ShortcutBinding(key: targetBinding.key, modifiers: targetBinding.modifiers) : targetBinding
        guard Self.approvalBindingIsAllowed(targetBinding, for: action) else { return .approvalSafety }
        guard !targetBinding.isEmpty else { return nil }
        for other in ShortcutAction.allCases where other != action {
            if binding(for: other) == targetBinding {
                return .action(other)
            }
        }
        if Self.systemReserved.contains(targetBinding) {
            return .system
        }
        return nil
    }

    @discardableResult
    private func persist(candidate: [String: ShortcutBinding]? = nil) -> Bool {
        let candidate = candidate ?? overrides
        guard var value = try? Self.readValue(defaults.data(forKey: Self.defaultsKey)) else {
            lastPersistenceError = .transactionRecoveryRequired
            return false
        }
        value.overrides = candidate
        value.revision = UUID().uuidString
        // Existing UI-only domains keep their legacy dictionary representation.
        let data: Data?
        if value.profileID.isEmpty {
            data = try? JSONEncoder().encode(candidate)
        } else {
            data = try? JSONEncoder().encode(value)
        }
        guard let data else { lastPersistenceError = .encodingFailed; return false }
        defaults.set(data, forKey: Self.defaultsKey)
        lastPersistenceError = defaults.data(forKey: Self.defaultsKey) == data ? nil : .writeFailed
        return lastPersistenceError == nil
    }

    /// The caller supplies the admitted canonical profile, not model input.
    /// Approval consumption and all four scope fences remain with SettingsCenter.
    func bl6Snapshot(profileID: String) -> Result<(revision: String, values: [String: BL6SettingValue]), BL6SettingsReplayCommitError> {
        switch transactionValue(profileID: profileID) {
        case .failure(let error): return .failure(error)
        case .success(let value):
            return .success((value.revision, Self.typedValues(value.overrides)))
        }
    }

    func bl6ReplayRecord(for requestID: String, profileID: String) -> Result<BL6SettingsReplayRecord?, BL6SettingsReplayCommitError> {
        transactionValue(profileID: profileID).map { $0.completed[requestID]?.record }
    }

    func bl6ReplayRecord(receiptID: String, profileID: String) -> Result<BL6SettingsReplayRecord?, BL6SettingsReplayCommitError> {
        transactionValue(profileID: profileID).map {
            $0.completed.values.first { $0.record.receipt.receiptID == receiptID }?.record
        }
    }

    struct BL6Preparation {
        let previousRevision: String
        let changedKeys: [String]
        let rollbackValues: [String: BL6SettingValue]
    }

    /// The Store computes effective changed keys, including the legacy
    /// command-palette fallback. This is a read-only proposal; the caller
    /// still needs the original bound approval and a fresh commit CAS.
    func prepareBL6Replay(
        _ input: BL6SettingsApprovedInput,
        profileID: String
    ) -> Result<BL6Preparation, BL6SettingsReplayCommitError> {
        let current: TransactionValue
        switch transactionValue(profileID: profileID) {
        case .failure(let error): return .failure(error)
        case .success(let value): current = value
        }
        guard input.expectedRevision == current.revision else { return .failure(.staleRevision) }
        let candidate: [String: ShortcutBinding]
        switch Self.candidateOverrides(for: input, current: current) {
        case .failure(let error): return .failure(error)
        case .success(let value): candidate = value
        }
        guard Self.sanitizeOverrides(candidate) == candidate else { return .failure(.conflict) }
        let before = Self.typedValues(current.overrides)
        let after = Self.typedValues(candidate)
        return .success(BL6Preparation(
            previousRevision: current.revision,
            changedKeys: before.keys.filter { before[$0] != after[$0] }.sorted(),
            rollbackValues: before
        ))
    }

    /// Called only after the existing approved-call owner has checked and
    /// consumed fresh authorization. No authorization is minted by this Store.
    /// On failure no memory or completed receipt is published.
    func commitBL6Replay(_ record: BL6SettingsReplayRecord, profileID: String) -> Result<BL6SettingsReceipt, BL6SettingsReplayCommitError> {
        guard record.profileID == profileID else { return .failure(.conflict) }
        let beforeData = defaults.data(forKey: Self.defaultsKey)
        let current: TransactionValue
        switch transactionValue(profileID: profileID) {
        case .failure(let error): return .failure(error)
        case .success(let value): current = value
        }
        guard Self.validRecord(record), Date() < record.approvalExpiresAt else { return .failure(.conflict) }
        if let existing = current.completed[record.requestID] {
            // An exact identity retry never applies values again, including
            // when a subsequent UI edit has advanced the revision.
            return existing.record == record ? .success(existing.record.receipt) : .failure(.conflict)
        }
        guard record.frozenInput.expectedRevision == current.revision,
              record.receipt.previousRevision == current.revision else { return .failure(.staleRevision) }
        guard !current.completed.values.contains(where: {
            $0.record.receipt.receiptID == record.receipt.receiptID
                || $0.record.receipt.effectiveRevision == record.receipt.effectiveRevision
        }), record.receipt.effectiveRevision != current.revision else { return .failure(.conflict) }
        let candidate: [String: ShortcutBinding]
        switch Self.candidateOverrides(for: record.frozenInput, current: current) {
        case .failure(let error): return .failure(error)
        case .success(let value): candidate = value
        }
        guard Self.sanitizeOverrides(candidate) == candidate else { return .failure(.conflict) }
        let before = Self.typedValues(current.overrides)
        let after = Self.typedValues(candidate)
        let changed = before.keys.filter { before[$0] != after[$0] }.sorted()
        guard record.receipt.changedKeys == changed, record.rollbackValues == before else { return .failure(.conflict) }
        var next = current
        next.overrides = candidate
        next.revision = record.receipt.effectiveRevision
        next.profileID = record.profileID
        next.completed[record.requestID] = CompletedShortcutEffect(record: record, previousOverrides: current.overrides)
        guard let data = try? JSONEncoder().encode(next) else { return .failure(.persistence(.encodingFailed)) }
        // No suspension separates the live CAS, single-value write and readback.
        // This serializes the canonical MainActor owner; UserDefaults provides
        // no cross-process atomic CAS, so no such guarantee is claimed here.
        guard defaults.data(forKey: Self.defaultsKey) == beforeData else { return .failure(.staleRevision) }
        defaults.set(data, forKey: Self.defaultsKey)
        guard defaults.data(forKey: Self.defaultsKey) == data else {
            lastPersistenceError = .writeFailed
            return .failure(.persistence(.writeFailed))
        }
        overrides = candidate
        lastPersistenceError = nil
        return .success(record.receipt)
    }

    private static func candidateOverrides(
        for input: BL6SettingsApprovedInput,
        current: TransactionValue
    ) -> Result<[String: ShortcutBinding], BL6SettingsReplayCommitError> {
        var candidate = current.overrides
        switch input.operation {
        case .apply:
            for (id, value) in input.changes {
                guard let action = ShortcutAction.allCases.first(where: { "shortcuts." + $0.rawValue == id }),
                      let binding = typedBinding(value) else { return .failure(.conflict) }
                // Reuse the UI Store's existing collision rule: a model
                // proposal cannot claim another action's current binding,
                // even when the palette compatibility fallback would later
                // make the candidate table internally conflict-free.
                if !binding.isEmpty {
                    guard !systemReserved.contains(binding),
                          !ShortcutAction.allCases.contains(where: { other in
                              other != action
                                  && effectiveBinding(for: other, overrides: current.overrides) == binding
                          }) else { return .failure(.conflict) }
                }
                candidate[action.id] = binding
            }
        case .reset:
            candidate = [:]
        case .rollback:
            guard let undoID = input.undoReceiptID,
                  let original = current.completed.values.first(where: { $0.record.receipt.receiptID == undoID }) else {
                return .failure(.conflict)
            }
            guard original.record.receipt.effectiveRevision == current.revision else {
                return .failure(.staleRevision)
            }
            // Restore the exact prior override table, not only effective keys.
            candidate = original.previousOverrides
        case .configureProvider:
            return .failure(.conflict)
        }
        return .success(candidate)
    }

    private func transactionValue(profileID: String) -> Result<TransactionValue, BL6SettingsReplayCommitError> {
        guard !profileID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure(.conflict) }
        guard let value = try? Self.readValue(defaults.data(forKey: Self.defaultsKey)),
              Self.sanitizeOverrides(value.overrides) == value.overrides else {
            return .failure(.persistence(.transactionRecoveryRequired))
        }
        guard value.profileID.isEmpty || value.profileID == profileID else { return .failure(.conflict) }
        return .success(value)
    }

    private static func readValue(_ data: Data?) throws -> TransactionValue {
        guard let data else {
            return TransactionValue(version: 1, overrides: [:], revision: "shortcuts-empty-v1", profileID: "", completed: [:])
        }
        if let value = try? JSONDecoder().decode(TransactionValue.self, from: data) {
            guard let roundTrip = try? JSONEncoder().encode(value),
                  let originalObject = (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary,
                  let canonicalObject = try? JSONSerialization.jsonObject(with: roundTrip),
                  originalObject.isEqual(canonicalObject),
                  value.version == 1, !value.revision.isEmpty, !value.profileID.isEmpty,
                  value.completed.allSatisfy({ $0.key == $0.value.record.requestID && validRecord($0.value.record)
                      && $0.value.record.profileID == value.profileID
                      && sanitizeOverrides($0.value.previousOverrides) == $0.value.previousOverrides
                      && $0.value.record.rollbackValues == typedValues($0.value.previousOverrides) }),
                  Set(value.completed.values.map { $0.record.receipt.receiptID }).count == value.completed.count,
                  Set(value.completed.values.map { $0.record.receipt.effectiveRevision }).count == value.completed.count else {
                throw SettingsPersistenceError.transactionRecoveryRequired
            }
            return value
        }
        let legacy = try JSONDecoder().decode([String: ShortcutBinding].self, from: data)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return TransactionValue(version: 1, overrides: legacy, revision: digest, profileID: "", completed: [:])
    }

    private static func validRecord(_ record: BL6SettingsReplayRecord) -> Bool {
        guard let data = try? JSONEncoder().encode(record.frozenInput),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              ApprovalAuthorizationContext.payloadDigest(for: object) == record.payloadDigest else { return false }
        return !record.requestID.isEmpty && record.requestID == record.receipt.requestID
            && !record.payloadDigest.isEmpty && !record.approvalBindingDigest.isEmpty
            && !record.profileID.isEmpty && !record.sessionID.isEmpty
            && !record.policyRevision.isEmpty && !record.grantEpoch.isEmpty
            && ["request", "turn", "session", "workspace"].contains(record.scope)
            && record.operation == record.frozenInput.operation && record.operation == record.receipt.operation
            && !record.receipt.receiptID.isEmpty && !record.receipt.previousRevision.isEmpty
            && !record.receipt.effectiveRevision.isEmpty && record.receipt.rollbackValues.isEmpty
            && record.approvalExpiresAt.timeIntervalSinceReferenceDate.isFinite
            && record.frozenInput.expectedRevision == record.receipt.previousRevision
            && record.receipt.visibleOnNextTurn && !record.receipt.secretValuesExposed
            && (try? record.frozenInput.validateForApprovedEffect()) != nil
    }

    private static func typedValues(_ overrides: [String: ShortcutBinding]) -> [String: BL6SettingValue] {
        Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { action in
            let binding = effectiveBinding(for: action, overrides: overrides)
            return ("shortcuts." + action.rawValue, .object([
                "key": .text(binding.key), "modifiers": .object([
                    "command": .toggle(binding.modifiers.command), "control": .toggle(binding.modifiers.control),
                    "option": .toggle(binding.modifiers.option), "shift": .toggle(binding.modifiers.shift)
                ])
            ]))
        })
    }

    private static func typedBinding(_ value: BL6SettingValue) -> ShortcutBinding? {
        guard case .object(let fields) = value, Set(fields.keys) == ["key", "modifiers"],
              case .text(let key)? = fields["key"], case .object(let flags)? = fields["modifiers"],
              Set(flags.keys) == ["command", "control", "option", "shift"],
              case .toggle(let command)? = flags["command"], case .toggle(let control)? = flags["control"],
              case .toggle(let option)? = flags["option"], case .toggle(let shift)? = flags["shift"] else { return nil }
        let modifiers = ShortcutModifiers(command: command, control: control, option: option, shift: shift)
        let binding = ShortcutBinding(key: key, modifiers: modifiers)
        guard binding.key == key, !key.isEmpty || modifiers == .none else { return nil }
        return binding
    }

    /// 系统保留快捷键（macOS 全局不可覆盖）集合。
    /// 注意：不含当前默认值（⌃Space / ⌘1/2/3 / ⌘P / ⌘, / ⌘N 等），避免默认态误报冲突。
    static let systemReserved: Set<ShortcutBinding> = [
        ShortcutBinding(key: "space", modifiers: ShortcutModifiers.command),       // Spotlight
        ShortcutBinding(key: "space", modifiers: ShortcutModifiers.optionCommand), // Spotlight 文件搜索
        ShortcutBinding(key: "q", modifiers: ShortcutModifiers.command),           // 退出
        ShortcutBinding(key: "w", modifiers: ShortcutModifiers.command),           // 关闭窗口
        ShortcutBinding(key: "m", modifiers: ShortcutModifiers.command),           // 最小化
        ShortcutBinding(key: "h", modifiers: ShortcutModifiers.command),           // 隐藏
        ShortcutBinding(key: "c", modifiers: ShortcutModifiers.command),           // 复制
        ShortcutBinding(key: "v", modifiers: ShortcutModifiers.command),           // 粘贴
        ShortcutBinding(key: "x", modifiers: ShortcutModifiers.command),           // 剪切
        ShortcutBinding(key: "a", modifiers: ShortcutModifiers.command),           // 全选
        ShortcutBinding(key: "z", modifiers: ShortcutModifiers.command),           // 撤销
        ShortcutBinding(key: "tab", modifiers: ShortcutModifiers.command),         // App 切换
        ShortcutBinding(key: "f", modifiers: ShortcutModifiers.commandControl),    // 全屏
    ]
}

// MARK: - SwiftUI 辅助

/// 按绑定挂 keyboardShortcut；绑定为空（禁用）时静默跳过，避免空 KeyEquivalent 崩溃。
private struct ShortcutKeyModifier: ViewModifier {
    let binding: ShortcutBinding

    func body(content: Content) -> some View {
        if binding.isEmpty {
            content
        } else {
            content.keyboardShortcut(binding.keyEquivalent, modifiers: binding.modifiers.eventModifiers)
        }
    }
}

extension View {
    /// 把 keyboardShortcut 挂到 ShortcutStore 的可配置绑定上（空绑定 = 禁用该快捷键）。
    func shortcutKey(_ binding: ShortcutBinding) -> some View {
        modifier(ShortcutKeyModifier(binding: binding))
    }
}
