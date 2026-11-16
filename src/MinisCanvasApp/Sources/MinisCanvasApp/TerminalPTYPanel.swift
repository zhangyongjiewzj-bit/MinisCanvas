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

    init(identity: TerminalPTYIdentity, plan: TerminalPTYLaunchPlan) {
        self.identity = identity
        self.plan = plan
        let terminalView = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        terminalView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
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

/// 面板级持有者（类比 BrowserTabSessionOwner）：切 tab 不杀 shell，换会话/关面板才结束。
@MainActor
final class TerminalPTYSessionOwner {
    private(set) var session: TerminalPTYSession?

    var identity: TerminalPTYIdentity? { session?.identity }

    /// 取得身份对应的会话；身份变化先结束旧 shell。新建的会话已启动。
    func acquire(identity: TerminalPTYIdentity, plan: TerminalPTYLaunchPlan) -> TerminalPTYSession {
        if let session, session.identity == identity { return session }
        retire()
        let created = TerminalPTYSession(identity: identity, plan: plan)
        session = created
        created.start()
        return created
    }

    func retire(ifDifferentFrom identity: TerminalPTYIdentity?) {
        guard let current = session?.identity, current != identity else { return }
        retire()
    }

    func retire() {
        let previous = session
        session = nil
        previous?.shutdown()
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
        session.applyColors(foreground: foreground, background: background, caret: caret)
    }
}
