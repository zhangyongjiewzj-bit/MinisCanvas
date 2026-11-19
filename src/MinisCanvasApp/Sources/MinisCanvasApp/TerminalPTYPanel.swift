import AppKit
import Foundation
import Observation
import SwiftTerm
import SwiftUI

// 真交互终端：SwiftTerm LocalProcessTerminalView（PTY + VT100/xterm）包进上下文面板。
// 注意：本文件同时 import SwiftUI 与 SwiftTerm，SwiftTerm 有同名 `Color`，故此处只用 NSColor。

/// 一个持久 shell 会话：拥有 NSView 与子进程，生命周期由 `TerminalPTYSessionOwner` 管理。
@MainActor
@Observable
final class TerminalPTYSession: LocalProcessTerminalViewDelegate {
    private(set) var lifecycle = TerminalPTYLifecycle()
    private(set) var size = TerminalPTYSize(columns: 80, rows: 24)
    private(set) var title = ""
    @ObservationIgnored let identity: TerminalPTYIdentity
    @ObservationIgnored let view: LocalProcessTerminalView
    @ObservationIgnored private var plan: TerminalPTYLaunchPlan
    @ObservationIgnored private var appliedForeground: NSColor?
    @ObservationIgnored private var appliedBackground: NSColor?
    @ObservationIgnored private var appliedCaret: NSColor?

    static let forceKillGrace: Duration = .seconds(2)

    // MARK: 字号（⌘+ / ⌘- / ⌘0，所有终端共用并记住）

    static let defaultFontSize: CGFloat = 12
    static let fontSizeRange: ClosedRange<CGFloat> = 9...28
    private static let fontSizeKey = "terminal.pty.fontSize"

    static var storedFontSize: CGFloat {
        let value = UserDefaults.standard.double(forKey: fontSizeKey)
        guard value > 0 else { return defaultFontSize }
        return min(max(CGFloat(value), fontSizeRange.lowerBound), fontSizeRange.upperBound)
    }

    /// delta 为 0 表示恢复默认字号。
    func adjustFontSize(by delta: CGFloat) {
        let next = delta == 0
            ? Self.defaultFontSize
            : min(max(Self.storedFontSize + delta, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
        UserDefaults.standard.set(Double(next), forKey: Self.fontSizeKey)
        syncFontSize()
    }

    /// 把共用字号应用到本终端（切换会话回来、其他终端改了字号后）。
    func syncFontSize() {
        let size = Self.storedFontSize
        guard abs(view.font.pointSize - size) > 0.01 else { return }
        view.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    init(identity: TerminalPTYIdentity, plan: TerminalPTYLaunchPlan) {
        self.identity = identity
        self.plan = plan
        let terminalView = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        terminalView.font = NSFont.monospacedSystemFont(ofSize: Self.storedFontSize, weight: .regular)
        terminalView.setAccessibilityIdentifier("terminal.pty.view")
        terminalView.setAccessibilityLabel("终端")
        view = terminalView
        terminalView.processDelegate = self
    }

    var isAlive: Bool { lifecycle.isAlive }

    // MARK: 启动 / 重启 / 结束

    func start() {
        guard lifecycle.beginStart() else { return }
        title = ""
        view.startProcess(
            executable: plan.executable,
            args: plan.arguments,
            environment: plan.environment,
            currentDirectory: plan.currentDirectory
        )
        lifecycle.started()
    }

    func restart() {
        guard !lifecycle.isAlive else { return }
        view.feed(text: "\u{1b}[2J\u{1b}[3J\u{1b}[H")
        start()
    }

    /// 面板关闭/会话切换：SIGTERM，宽限后仍未退出则 SIGKILL。
    /// 交互 shell 可能忽略 SIGTERM；PTY 主端随 view 释放而关闭会再向前台进程组发 SIGHUP。
    func shutdown() {
        guard lifecycle.requestTerminate() else { return }
        let generation = lifecycle.generation
        view.terminate()
        Task { @MainActor [self] in
            try? await Task.sleep(for: Self.forceKillGrace)
            guard lifecycle.needsForceKill(generation: generation) else { return }
            let pid = view.process.shellPid
            if pid > 0 { kill(pid, SIGKILL) }
        }
    }

    // MARK: 用户动作

    /// 清屏：先清模拟器的屏幕与回滚，再给 shell 发 Ctrl-L 让它重绘提示符。
    func clearScreen() {
        view.feed(text: "\u{1b}[2J\u{1b}[3J\u{1b}[H")
        if lifecycle.phase == .running {
            let ctrlL: [UInt8] = [0x0c]
            view.process.send(data: ctrlL[...])
        }
    }

    func copySelection() { view.copy(self) }
    func pasteFromClipboard() { view.paste(self) }

    func focus() {
        guard let window = view.window else { return }
        window.makeFirstResponder(view)
    }

    // MARK: 主题

    func applyColors(foreground: NSColor, background: NSColor, caret: NSColor) {
        if appliedForeground != foreground {
            appliedForeground = foreground
            view.nativeForegroundColor = foreground
        }
        if appliedBackground != background {
            appliedBackground = background
            view.nativeBackgroundColor = background
        }
        if appliedCaret != caret {
            appliedCaret = caret
            view.caretColor = caret
        }
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        let next = TerminalPTYSize(columns: newCols, rows: newRows)
        if next != size { size = next }
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        self.title = title
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        lifecycle.processExited(code: exitCode)
    }

    func processFailedToStart(source: TerminalView, error: LocalProcessError) {
        lifecycle.startFailed("shell 启动失败：\(error)")
    }
}

/// 终端持有者：每个会话保留一组终端标签（最多 `TerminalPTYTabList.maxTabs` 个 shell）。
/// 切换会话、关闭面板、切换标签只是隐藏，不结束进程；
/// 用户关闭标签结束该 shell；会话被删除或同一会话的工作目录变了结束该会话的全部终端。
@MainActor
final class TerminalPTYSessionOwner {
    /// 面板共用的持有者：面板视图被销毁后 shell 仍保留。
    static let shared = TerminalPTYSessionOwner()

    private struct Group {
        let identity: TerminalPTYIdentity
        var tabs = TerminalPTYTabList()
        var sessions: [Int: TerminalPTYSession] = [:]
    }

    private var groups: [String: Group] = [:]
    private var currentID: String?

    /// 当前会话选中的终端；没有标签（全部关闭）时为 nil。
    var session: TerminalPTYSession? {
        guard let id = currentID, let group = groups[id], let selected = group.tabs.selected else { return nil }
        return group.sessions[selected]
    }

    var identity: TerminalPTYIdentity? { currentID.flatMap { groups[$0]?.identity } }
    /// 所有会话的存活终端总数。
    var liveSessionCount: Int { groups.values.reduce(0) { $0 + $1.sessions.count } }

    /// 当前会话的标签条内容与选中编号。
    var tabItems: [TerminalPTYTabItem] {
        guard let id = currentID, let group = groups[id] else { return [] }
        return group.tabs.tabs.compactMap { number in
            group.sessions[number].map { TerminalPTYTabItem(number: number, session: $0) }
        }
    }
    var selectedTabNumber: Int? { currentID.flatMap { groups[$0]?.tabs.selected } }
    var canAddTab: Bool { currentID.flatMap { groups[$0]?.tabs.canAddTab } ?? false }

    /// 取得身份对应的会话组并设为当前；同一会话的目录变了先结束旧组的全部 shell。
    /// 新建的组带一个已启动的终端；已存在的组保持用户当前的标签状态（可能为空）。
    @discardableResult
    func acquire(identity: TerminalPTYIdentity, plan: TerminalPTYLaunchPlan) -> TerminalPTYSession? {
        if let existing = groups[identity.sessionID] {
            if existing.identity == identity {
                currentID = identity.sessionID
                session?.syncFontSize()
                return session
            }
            existing.sessions.values.forEach { $0.shutdown() }
            groups[identity.sessionID] = nil
        }
        groups[identity.sessionID] = Group(identity: identity)
        currentID = identity.sessionID
        return appendTab(plan: plan)
    }

    /// 启动被拦截（如目录不可用）时：只在该会话已有同身份的终端组时把它设为当前，
    /// 不结束任何进程；否则当前置空。返回是否有可显示的组。
    @discardableResult
    func activateExisting(identity: TerminalPTYIdentity) -> Bool {
        if let existing = groups[identity.sessionID], existing.identity == identity {
            currentID = identity.sessionID
            return true
        }
        currentID = nil
        return false
    }

    /// 在身份对应的会话新开一个终端并切过去；到上限返回 nil。
    /// 身份（会话 + 目录）与现有组不一致时按 `acquire` 处理（重建该会话的终端组），
    /// 保证新标签的身份与实际启动目录一致。
    @discardableResult
    func addTab(identity: TerminalPTYIdentity, plan: TerminalPTYLaunchPlan) -> TerminalPTYSession? {
        let id = identity.sessionID
        guard let existing = groups[id], existing.identity == identity else {
            return acquire(identity: identity, plan: plan)
        }
        currentID = id
        return appendTab(plan: plan)
    }

    private func appendTab(plan: TerminalPTYLaunchPlan) -> TerminalPTYSession? {
        guard let id = currentID, var group = groups[id], let number = group.tabs.add() else { return nil }
        let created = TerminalPTYSession(identity: group.identity, plan: plan)
        group.sessions[number] = created
        groups[id] = group
        created.start()
        return created
    }

    /// 只切换当前会话的选中标签，不结束任何进程。
    func selectTab(_ number: Int) {
        guard let id = currentID, var group = groups[id] else { return }
        group.tabs.select(number)
        groups[id] = group
        group.tabs.selected.flatMap { group.sessions[$0] }?.syncFontSize()
    }

    /// 关闭当前会话的一个终端：结束其 shell 并移出标签列表。
    func closeTab(_ number: Int) {
        guard let id = currentID, var group = groups[id] else { return }
        group.tabs.close(number)
        let closed = group.sessions.removeValue(forKey: number)
        groups[id] = group
        closed?.shutdown()
    }

    /// 只保留仍存在的会话的终端，其余会话的全部终端结束。
    func retain(sessionIDs: Set<String>) {
        for id in TerminalPTYPlanner.sessionIDsToRetire(live: Array(groups.keys), keeping: sessionIDs) {
            groups[id]?.sessions.values.forEach { $0.shutdown() }
            groups[id] = nil
            if currentID == id { currentID = nil }
        }
    }

    /// 结束所有终端（只在需要彻底清理时使用，关闭面板不调用）。
    func retire() {
        let previous = groups.values.flatMap { $0.sessions.values }
        groups.removeAll()
        currentID = nil
        previous.forEach { $0.shutdown() }
    }
}

/// 把会话拥有的 NSView 放进 SwiftUI；本身不启动也不结束进程。
struct TerminalPTYHostView: NSViewRepresentable {
    let session: TerminalPTYSession
    let foreground: NSColor
    let background: NSColor
    let caret: NSColor

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        session.applyColors(foreground: foreground, background: background, caret: caret)
        let view = session.view
        DispatchQueue.main.async { session.focus() }
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        session.syncFontSize()
        session.applyColors(foreground: foreground, background: background, caret: caret)
    }
}
