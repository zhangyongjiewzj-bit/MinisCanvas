import Foundation

// 上下文面板「真终端」的纯逻辑层（不依赖 SwiftTerm、不碰真实 PTY，便于单测）：
// shell 选择与登录参数、环境变量、起始目录、禁用开关、尺寸换算、进程生命周期状态机。
// 与 Claude Code 桌面版终端面板对齐：用户在面板里亲手敲的命令不再逐条审批，
// 但「浏览器与终端副作用」安全开关关闭时面板不启动 shell。

// MARK: - 身份

/// 一个终端会话的身份：同一对话 + 同一工作目录复用同一个 shell。
/// 刻意不含 turnID/taskID（它们每个回合都变，会误杀用户的 shell）。
struct TerminalPTYIdentity: Equatable, Hashable, Sendable {
    let sessionID: String
    let workdir: String
}

// MARK: - 启动决策

enum TerminalPTYBlockReason: Equatable, Sendable {
    case sideEffectsDisabled
    case missingWorkingDirectory
    case workingDirectoryUnavailable(String)

    var message: String {
        switch self {
        case .sideEffectsDisabled:
            return "终端已被当前安全设置禁用（“浏览器与终端副作用”已关闭），未启动 shell。"
        case .missingWorkingDirectory:
            return "找不到可用的起始目录，未启动终端。"
        case .workingDirectoryUnavailable(let path):
            return "项目目录不可用（已不存在或不是文件夹）：\(path)。终端不会自动改到其他目录。"
        }
    }

    /// 只有安全开关关闭才结束全部终端；目录不可用只影响“新开终端”，
    /// 已在运行的终端（含其他会话的）不受目录检查结果影响。
    var retiresAllTerminals: Bool {
        if case .sideEffectsDisabled = self { return true }
        return false
    }
}

struct TerminalPTYLaunchPlan: Equatable, Sendable {
    let executable: String
    let arguments: [String]
    /// `KEY=VALUE` 列表，直接传给 SwiftTerm `startProcess(environment:)`。
    let environment: [String]
    let currentDirectory: String
}

enum TerminalPTYDecision: Equatable, Sendable {
    case launch(TerminalPTYLaunchPlan)
    case blocked(TerminalPTYBlockReason)
}

enum TerminalPTYPlanner {
    static let fallbackShell = "/bin/zsh"
    static let termName = "xterm-256color"
    static let termProgram = "MinisCanvas"
    /// 不应从 App 进程继承给交互 shell 的变量（终端自身的标识、GUI 启动器内部变量、过期的 PWD）。
    static let droppedEnvironmentKeys: Set<String> = [
        "TERM", "COLORTERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID",
        "SHELL", "PWD", "OLDPWD", "NSUnbufferedIO", "OS_ACTIVITY_DT_MODE", "__CFBundleIdentifier"
    ]
    private static let unusableShellNames: Set<String> = ["nologin", "false", "true"]

    /// 用户默认 shell：按顺序取第一个「绝对路径 + 可执行 + 不是 nologin」的候选，否则 /bin/zsh。
    static func resolveShell(
        candidates: [String?],
        isExecutable: (String) -> Bool
    ) -> String {
        for candidate in candidates {
            guard let raw = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  raw.hasPrefix("/"),
                  !unusableShellNames.contains((raw as NSString).lastPathComponent),
                  isExecutable(raw) else { continue }
            return raw
        }
        return fallbackShell
    }

    /// 登录 shell：`-l`（交互性由 PTY 自动决定）。
    static func loginArguments(for shell: String) -> [String] {
        ["-l"]
    }

    /// 继承 App 环境（真实动作继承用户环境），仅叠加终端必需项；结果按键排序，确定性。
    static func environment(base: [String: String], shell: String) -> [String] {
        var env = base.filter { !droppedEnvironmentKeys.contains($0.key) }
        env["TERM"] = termName
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = termProgram
        env["SHELL"] = shell
        let hasLocale = (env["LANG"]?.isEmpty == false) || (env["LC_ALL"]?.isEmpty == false)
        if !hasLocale { env["LANG"] = "en_US.UTF-8" }
        return env.keys.sorted().map { "\($0)=\(env[$0] ?? "")" }
    }

    /// 终端起始目录：会话绑定了项目目录就用它（即使它已不存在，由 `decide` 拦截并提示，不回落家目录）；
    /// 会话本来没有项目目录才用家目录。
    static func resolveWorkdir(bound: String?, home: String) -> String {
        let trimmed = bound?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? home : trimmed
    }

    /// 已存在的终端会话里，哪些会话已不在有效会话集合中（应结束其全部终端）。
    static func sessionIDsToRetire(live: [String], keeping valid: Set<String>) -> [String] {
        live.filter { !valid.contains($0) }
    }

    static func decide(
        workdir: String?,
        homeDirectory: String = NSHomeDirectory(),
        sideEffectsEnabled: Bool,
        shellCandidates: [String?],
        baseEnvironment: [String: String],
        directoryExists: (String) -> Bool,
        isExecutable: (String) -> Bool
    ) -> TerminalPTYDecision {
        guard sideEffectsEnabled else { return .blocked(.sideEffectsDisabled) }
        // 会话没有项目目录时在家目录启动终端（对齐 Claude Code：随处可开）。
        var trimmed = workdir?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { trimmed = homeDirectory.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !trimmed.isEmpty else { return .blocked(.missingWorkingDirectory) }
        guard directoryExists(trimmed) else { return .blocked(.workingDirectoryUnavailable(trimmed)) }
        let shell = resolveShell(candidates: shellCandidates, isExecutable: isExecutable)
        return .launch(TerminalPTYLaunchPlan(
            executable: shell,
            arguments: loginArguments(for: shell),
            environment: environment(base: baseEnvironment, shell: shell),
            currentDirectory: trimmed
        ))
    }
}

// MARK: - 尺寸

struct TerminalPTYSize: Equatable, Sendable {
    static let minimumColumns = 2
    static let minimumRows = 1
    static let maximumDimension = Int(UInt16.max)

    let columns: Int
    let rows: Int

    /// 夹到 PTY `winsize` 可表示且合理的范围（0 列/行会让部分程序崩溃）。
    init(columns: Int, rows: Int) {
        self.columns = min(max(columns, Self.minimumColumns), Self.maximumDimension)
        self.rows = min(max(rows, Self.minimumRows), Self.maximumDimension)
    }

    var label: String { "\(columns)×\(rows)" }

    /// `winsize.ws_xpixel/ws_ypixel`：单元格像素 × 行列数 × 缩放，夹到 UInt16。
    func pixelSize(cellWidth: Double, cellHeight: Double, scale: Double) -> (width: UInt16, height: UInt16) {
        func clamp(_ value: Double) -> UInt16 {
            guard value.isFinite, value > 0 else { return 0 }
            return UInt16(min(value, Double(UInt16.max)))
        }
        return (clamp(cellWidth * Double(columns) * scale), clamp(cellHeight * Double(rows) * scale))
    }
}

// MARK: - 生命周期状态机

struct TerminalPTYLifecycle: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        case starting
        case running
        case terminating
        case exited(code: Int32?)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// 每次成功 `beginStart` 加 1；用于让过期的强杀定时器失效。
    private(set) var generation: UInt64 = 0

    var isAlive: Bool {
        switch phase {
        case .starting, .running, .terminating: return true
        case .idle, .exited, .failed: return false
        }
    }

    /// idle/exited/failed 才允许（重复启动会被忽略，不会产生第二个 shell）。
    mutating func beginStart() -> Bool {
        guard !isAlive else { return false }
        generation &+= 1
        phase = .starting
        return true
    }

    mutating func started() {
        if phase == .starting { phase = .running }
    }

    mutating func startFailed(_ message: String) {
        guard phase == .starting || phase == .running else { return }
        phase = .failed(message)
    }

    /// 返回是否需要向子进程发送终止信号（starting/running 才需要；已在终止/已结束则不重复发）。
    mutating func requestTerminate() -> Bool {
        switch phase {
        case .starting, .running:
            phase = .terminating
            return true
        case .idle, .terminating, .exited, .failed:
            return false
        }
    }

    mutating func processExited(code: Int32?) {
        switch phase {
        case .starting, .running, .terminating: phase = .exited(code: code)
        case .idle, .exited, .failed: break
        }
    }

    /// 宽限期后仍处于 terminating 且仍是同一代进程，才强杀。
    func needsForceKill(generation expected: UInt64) -> Bool {
        phase == .terminating && generation == expected
    }
}
