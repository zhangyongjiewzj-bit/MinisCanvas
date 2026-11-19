import Foundation

// MARK: - Goal18 Hooks: runtime

/// One finished tool call presented to PostToolUse hooks (observation only).
public struct ComposerPostToolInvocation: Sendable {
    public let callID: String
    public let capability: String
    public let input: ComposerToolInput
    public let output: String
    public let sessionID: String

    public init(callID: String, capability: String, input: ComposerToolInput, output: String, sessionID: String) {
        self.callID = callID
        self.capability = capability
        self.input = input
        self.output = output
        self.sessionID = sessionID
    }
}

public struct HookTurnStartResult: Sendable, Equatable {
    /// Non-nil: a UserPromptSubmit hook refused this message.
    public let denialReason: String?
    /// SessionStart / UserPromptSubmit context to add to this turn's system prompt.
    public let additionalContext: String?

    public init(denialReason: String?, additionalContext: String?) {
        self.denialReason = denialReason
        self.additionalContext = additionalContext
    }
}

private final class HookRuntimeInstallBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: HookRuntime?

    var value: HookRuntime? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            stored = newValue
        }
    }
}

/// Resolves, runs and records hooks. It never decides on its own: PreToolUse
/// answers flow back through `ComposerHookResult` into the existing
/// `HookDecisionReducer` merge in `ComposerPolicyEnforcedToolExecutor`.
public final class HookRuntime: @unchecked Sendable {
    private static let installBox = HookRuntimeInstallBox()
    public static let maximumRecords = 100

    /// The process-wide runtime, installed once by the App at launch. Nil (the
    /// default, and always in unit tests that do not install one) means "no hooks".
    public static var installed: HookRuntime? { installBox.value }

    public static func install(_ runtime: HookRuntime?) {
        installBox.value = runtime
    }

    public let store: HookConfigStore
    private let runner: any HookCommandRunning
    private let environmentProvider: @Sendable () throws -> [String: String]
    private let stateLock = NSLock()
    private var sessionRoots: [String: URL] = [:]
    private var startedSessions: Set<String> = []
    private var records: [HookRunRecord] = []
    /// Claude Code 格式 settings.json 的家目录；nil 表示不读这类配置。
    private let claudeSettingsHome: URL?

    public init(
        store: HookConfigStore,
        runner: any HookCommandRunning = HookProcessRunner(),
        environment: @escaping @Sendable () throws -> [String: String] = { try HookRuntime.defaultEnvironment() },
        claudeSettingsHome: URL? = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.store = store
        self.runner = runner
        self.environmentProvider = environment
        self.claudeSettingsHome = claudeSettingsHome
    }

    /// 钩子子进程的默认环境：其余变量仍走隔离环境，只有 PATH 用登录 shell 的搜索路径
    /// （对齐 Claude Code），这样 nvm / bun / volta 等装的工具不会报 127。
    public static func defaultEnvironment() throws -> [String: String] {
        var result = try ChildProcessEnvironment.values()
        result["PATH"] = ChildProcessEnvironment.mcpSearchPath(
            loginPath: (try? ModelShellEnvironment.values())?["PATH"],
            home: result["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path)
        return result
    }

    // MARK: Handlers wired into ComposerPolicyEnforcedToolExecutor

    public var composerHookHandler: @Sendable (ComposerHookInvocation) async throws -> ComposerHookResult {
        return { [self] invocation in try await self.preToolUse(invocation) }
    }

    public var postToolHandler: @Sendable (ComposerPostToolInvocation) async -> String? {
        return { [self] invocation in await self.postToolUse(invocation) }
    }

    // MARK: Diagnostics

    public func recentRuns() -> [HookRunRecord] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return records
    }

    public func lastRun(key: String) -> HookRunRecord? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return records.last { $0.key == key }
    }

    /// Project roots seen this run plus roots that already carry a trust record.
    public func knownProjectRoots() -> [URL] {
        stateLock.lock()
        let seen = sessionRoots.values.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        stateLock.unlock()
        var paths: [String] = []
        for path in seen + store.trustedProjectRoots() where !paths.contains(path) {
            paths.append(path)
        }
        return paths.sorted().map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private func record(_ entry: HookRunRecord) {
        stateLock.lock()
        defer { stateLock.unlock() }
        records.append(entry)
        if records.count > Self.maximumRecords {
            records.removeFirst(records.count - Self.maximumRecords)
        }
    }

    /// Binds a trusted project root for a lifecycle that does not execute
    /// UserPromptSubmit. Scheduled work uses the same session-root map as
    /// interactive turns, while SessionStart and prompt hooks remain idle.
    public func registerSessionRoot(sessionID: String, projectRoot: URL?) {
        stateLock.lock()
        sessionRoots[sessionID] = projectRoot
        stateLock.unlock()
    }

    /// Remembers the session's project root and reports whether this is its first turn.
    private func markTurnStart(sessionID: String, projectRoot: URL?) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        sessionRoots[sessionID] = projectRoot
        return startedSessions.insert(sessionID).inserted
    }

    /// A sub-agent task runs in session "<parentSessionID>:child:<executionID>"
    /// (AgentOrchestrator.makeChildRuntimeIdentity). It has no root of its own;
    /// it uses the project root registered for the session that spawned it,
    /// which is the text before the first ":child:" (nested children keep the
    /// root session as their prefix). Nothing is registered per child, so
    /// there is nothing to clean up when the task ends.
    private func root(forSession sessionID: String) -> URL? {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let root = sessionRoots[sessionID] { return root }
        guard let separator = sessionID.range(of: ":child:") else { return nil }
        return sessionRoots[String(sessionID[..<separator.lowerBound])]
    }

    // MARK: Resolution and execution

    private struct ResolvedHook {
        let source: HookSource
        let definition: HookDefinition
        let projectRoot: URL?
        let workingDirectory: URL?
    }

    private func resolveHooks(event: HookEvent, toolName: String?, projectRoot: URL?) -> [ResolvedHook] {
        var resolved: [ResolvedHook] = []
        for hook in store.userHooksSnapshot().executableHooks
        where hook.event == event && hook.matches(toolName: toolName) {
            resolved.append(ResolvedHook(source: .user, definition: hook, projectRoot: projectRoot,
                workingDirectory: store.directory))
        }
        if let projectRoot {
            // Untrusted or changed project hooks yield an empty executable list.
            for hook in store.projectSnapshot(projectRoot: projectRoot).executableHooks
            where hook.event == event && hook.matches(toolName: toolName) {
                resolved.append(ResolvedHook(source: .project, definition: hook, projectRoot: projectRoot, workingDirectory: projectRoot))
            }
        }
        resolved += claudeSettingsHooks(event: event, toolName: toolName, projectRoot: projectRoot)
        return resolved
    }

    /// Claude Code 格式 settings.json 里已被用户信任的钩子。未信任或已变化的不执行、
    /// 也不像未信任的 PreToolUse 项目 Hook 那样拒绝工具调用：它们只是额外的收紧手段，
    /// 不运行不会放宽任何已有检查。
    private func claudeSettingsHooks(event: HookEvent, toolName: String?, projectRoot: URL?) -> [ResolvedHook] {
        guard let home = claudeSettingsHome else { return [] }
        return store.claudeSettingsSnapshots(projectRoot: projectRoot, homeDirectory: home).flatMap { entry in
            entry.snapshot.executableHooks
                .filter { $0.event == event && $0.matches(toolName: toolName) }
                .map { ResolvedHook(source: .claudeSettings, definition: $0, projectRoot: projectRoot,
                                    workingDirectory: projectRoot ?? home) }
        }
    }

    /// Runs one hook. Every failure mode (launch error, timeout, non-zero exit,
    /// unparsable stdout) returns nil: the hook then has no effect on the decision.
    private func execute(_ hook: ResolvedHook, payloadObject: [String: Any]) async -> HookParsedOutput? {
        let started = Date()
        let definition = hook.definition
        let key = hookKey(source: hook.source, id: definition.id)

        func finish(
            _ status: HookRunStatus, exitCode: Int32?, decision: HookLayerVerdict?, summary: String
        ) {
            record(HookRunRecord(
                key: key, source: hook.source, hookID: definition.id, event: definition.event,
                startedAt: started,
                durationMilliseconds: Int(Date().timeIntervalSince(started) * 1000),
                status: status, exitCode: exitCode, decision: decision?.rawValue,
                summary: HookOutputParser.clean(summary, limit: 200) ?? ""
            ))
        }

        func launchFailure(_ summary: String,
                           preToolReason: String = "PreToolUse 启动失败，本次工具调用已拒绝") -> HookParsedOutput? {
            let reason = definition.event == .preToolUse ? preToolReason : summary
            finish(.launchFailed, exitCode: nil,
                   decision: definition.event == .preToolUse ? .deny : nil, summary: reason)
            return definition.event == .preToolUse
                ? HookParsedOutput(verdict: .deny, reason: reason, additionalContext: nil) : nil
        }

        let payload: Data
        do {
            payload = try HookPayload.data(payloadObject)
        } catch {
            return launchFailure("Hook 输入 JSON 编码失败，未执行",
                preToolReason: "PreToolUse 输入 JSON 编码失败，本次工具调用已拒绝")
        }

        var environment: [String: String]
        do {
            environment = try environmentProvider()
        } catch {
            return launchFailure("子进程环境不可用")
        }
        environment["MINISCANVAS_HOOK_EVENT"] = definition.event.rawValue
        if let root = hook.projectRoot {
            environment["MINISCANVAS_PROJECT_DIR"] = root.path
            // Claude Code 格式的钩子脚本习惯用这个变量。
            environment["CLAUDE_PROJECT_DIR"] = root.path
        }

        let result = await runner.run(HookCommandRequest(
            command: definition.command,
            stdin: payload,
            environment: environment,
            workingDirectory: hook.workingDirectory,
            timeout: definition.effectiveTimeout
        ))
        if let launchError = result.launchError {
            return launchFailure(launchError)
        }
        if result.cancelled {
            finish(.cancelled, exitCode: result.exitCode, decision: nil,
                   summary: "调用已取消，Hook 进程组已终止，不影响决策")
            return nil
        }
        if result.timedOut {
            let reason = definition.event == .preToolUse
                ? "PreToolUse 超时，本次工具调用已拒绝"
                : "超过 \(Int(definition.effectiveTimeout)) 秒，已终止，不影响决策"
            finish(.timedOut, exitCode: result.exitCode,
                   decision: definition.event == .preToolUse ? .deny : nil, summary: reason)
            return definition.event == .preToolUse
                ? HookParsedOutput(verdict: .deny, reason: reason, additionalContext: nil) : nil
        }
        // 对齐 Claude Code：Stop 钩子退出码 2 表示"要求继续"，stderr 是给模型的下一步指示。
        if result.exitCode == 2,
           definition.event == .preToolUse || definition.event == .userPromptSubmit || definition.event == .stop {
            let fallback = definition.event == .stop ? "Stop 钩子要求继续" : "Hook 退出码 2：阻止本次调用"
            let reason = HookOutputParser.clean(String(decoding: result.stderr, as: UTF8.self),
                limit: HookOutputParser.maximumReasonLength) ?? fallback
            finish(.nonZeroExit, exitCode: 2, decision: .deny, summary: reason)
            return HookParsedOutput(verdict: .deny, reason: reason, additionalContext: nil)
        }
        guard result.exitCode == 0 else {
            let firstLine = String(decoding: result.stderr, as: UTF8.self)
                .split(whereSeparator: { $0.isNewline }).first.map { String($0) } ?? ""
            finish(.nonZeroExit, exitCode: result.exitCode, decision: nil,
                   summary: "退出码 \(result.exitCode ?? -1)，不影响决策。" + firstLine)
            return nil
        }
        switch HookOutputParser.parse(stdout: result.stdout, event: definition.event) {
        case .invalid(let message):
            finish(.invalidOutput, exitCode: 0, decision: nil, summary: message + "，不影响决策")
            return nil
        case .parsed(let output):
            finish(.completed, exitCode: 0, decision: output.verdict,
                   summary: output.reason ?? output.additionalContext ?? "")
            return output
        }
    }

    // MARK: PreToolUse

    public func preToolUse(_ invocation: ComposerHookInvocation) async throws -> ComposerHookResult {
        let neutral = ComposerHookResult(verdict: .allow, invocationIdentityDigest: invocation.identityDigest, hasDecision: false)
        let projectRoot = root(forSession: invocation.sessionID)
        // An applicable configured precondition is not equivalent to no hook
        // when its reviewed bytes are no longer trusted. Keep this refusal on
        // the existing identity-bound decision path, before any tool effect.
        var snapshots: [(HookSource, ProjectHooksSnapshot)] = [(.user, store.userHooksSnapshot())]
        if let projectRoot { snapshots.append((.project, store.projectSnapshot(projectRoot: projectRoot))) }
        for (source, snapshot) in snapshots where snapshot.trust != .trusted {
            guard let definition = snapshot.hooks.first(where: {
                $0.enabled && $0.isRunnable && $0.event == .preToolUse && $0.matches(toolName: invocation.capability)
            }) else { continue }
            let reason = "PreToolUse 配置未受信任或已变化；请在设置中重新查看并信任，本次工具调用已拒绝"
            record(HookRunRecord(key: hookKey(source: source, id: definition.id), source: source,
                hookID: definition.id, event: .preToolUse, startedAt: Date(), durationMilliseconds: 0,
                status: .launchFailed, exitCode: nil, decision: HookLayerVerdict.deny.rawValue, summary: reason))
            return ComposerHookResult(verdict: .deny, invocationIdentityDigest: invocation.identityDigest,
                reason: reason)
        }
        let hooks = snapshots.flatMap { source, snapshot in
            snapshot.executableHooks.filter { $0.event == .preToolUse && $0.matches(toolName: invocation.capability) }
                .map { ResolvedHook(source: source, definition: $0, projectRoot: projectRoot,
                    workingDirectory: source == .user ? store.directory : projectRoot) }
        }
        let allHooks = hooks + claudeSettingsHooks(
            event: .preToolUse, toolName: invocation.capability, projectRoot: projectRoot)
        guard !allHooks.isEmpty else { return neutral }

        var object: [String: Any] = [
            "hook_event_name": HookEvent.preToolUse.rawValue,
            "session_id": invocation.sessionID,
            "tool_call_id": invocation.callID,
            "tool_input": HookPayload.toolInput(invocation.input),
        ]
        HookPayload.addToolNames(&object, appName: invocation.capability)
        if let projectRoot { object["cwd"] = projectRoot.path }

        var verdicts: [HookLayerVerdict] = []
        var denyReason: String?
        var askReason: String?
        for hook in allHooks {
            guard let output = await execute(hook, payloadObject: object), let verdict = output.verdict else { continue }
            verdicts.append(verdict)
            if verdict == .deny {
                denyReason = output.reason
                break // deny can never be re-opened; stop spending time.
            }
            if verdict == .ask, askReason == nil { askReason = output.reason }
        }
        let merged = HookVerdictMerge.merge(verdicts)
        return ComposerHookResult(
            verdict: merged,
            invocationIdentityDigest: invocation.identityDigest,
            reason: merged == .deny ? denyReason : (merged == .ask ? askReason : nil),
            hasDecision: !verdicts.isEmpty
        )
    }

    // MARK: PostToolUse

    public func postToolUse(_ invocation: ComposerPostToolInvocation) async -> String? {
        let projectRoot = root(forSession: invocation.sessionID)
        let hooks = resolveHooks(event: .postToolUse, toolName: invocation.capability, projectRoot: projectRoot)
        guard !hooks.isEmpty else { return nil }

        var object: [String: Any] = [
            "hook_event_name": HookEvent.postToolUse.rawValue,
            "session_id": invocation.sessionID,
            "tool_call_id": invocation.callID,
            "tool_input": HookPayload.toolInput(invocation.input),
        ]
        HookPayload.addToolNames(&object, appName: invocation.capability)
        if HookPayload.touchesSensitivePath(invocation.input) {
            object["tool_response_omitted"] = "sensitive_path"
        } else {
            object["tool_response"] = HookPayload.sanitize(
                invocation.output, limit: HookPayload.maximumToolResponseLength)
        }
        if let projectRoot { object["cwd"] = projectRoot.path }

        var contexts: [String] = []
        for hook in hooks {
            if let context = await execute(hook, payloadObject: object)?.additionalContext {
                contexts.append(context)
            }
        }
        guard !contexts.isEmpty else { return nil }
        let joined = contexts.joined(separator: "\n")
        return joined.count > HookOutputParser.maximumContextLength
            ? String(joined.prefix(HookOutputParser.maximumContextLength)) + "…"
            : joined
    }

    // MARK: SessionStart + UserPromptSubmit

    /// Runs at the start of a turn, before the provider is called. SessionStart
    /// fires once per session per app run (on its first turn).
    public func beginTurn(sessionID: String, prompt: String, projectRoot: URL?) async -> HookTurnStartResult {
        let isFirstTurn = markTurnStart(sessionID: sessionID, projectRoot: projectRoot)
        let effectiveRoot = projectRoot

        var contexts: [String] = []
        if isFirstTurn {
            let hooks = resolveHooks(event: .sessionStart, toolName: nil, projectRoot: effectiveRoot)
            if !hooks.isEmpty {
                var object: [String: Any] = [
                    "hook_event_name": HookEvent.sessionStart.rawValue,
                    "session_id": sessionID,
                    "source": "startup",
                ]
                if let effectiveRoot { object["cwd"] = effectiveRoot.path }
                for hook in hooks {
                    if let context = await execute(hook, payloadObject: object)?.additionalContext {
                        contexts.append(context)
                    }
                }
            }
        }

        var denial: String?
        let promptHooks = resolveHooks(event: .userPromptSubmit, toolName: nil, projectRoot: effectiveRoot)
        if !promptHooks.isEmpty {
            var object: [String: Any] = [
                "hook_event_name": HookEvent.userPromptSubmit.rawValue,
                "session_id": sessionID,
                "prompt": HookPayload.sanitize(prompt, limit: HookPayload.maximumToolResponseLength),
            ]
            if let effectiveRoot { object["cwd"] = effectiveRoot.path }
            for hook in promptHooks {
                guard let output = await execute(hook, payloadObject: object) else { continue }
                if output.verdict == .deny {
                    denial = output.reason ?? "被 Hook 拒绝"
                    break
                }
                if let context = output.additionalContext { contexts.append(context) }
            }
        }

        let joined = contexts.joined(separator: "\n")
        let capped = joined.count > HookOutputParser.maximumContextLength
            ? String(joined.prefix(HookOutputParser.maximumContextLength)) + "…"
            : joined
        return HookTurnStartResult(denialReason: denial, additionalContext: capped.isEmpty ? nil : capped)
    }

    // MARK: Stop (observation only)

    /// Fire-and-forget: a Stop hook can never delay or alter the turn that ended.
    public func notifyStop(sessionID: String, reason: String) {
        let projectRoot = root(forSession: sessionID)
        Task.detached(priority: .utility) { [self] in
            await self.stop(sessionID: sessionID, reason: reason, projectRoot: projectRoot)
        }
    }

    /// 返回非 nil 表示有 Stop 钩子要求继续（{"decision":"block","reason":"…"}），内容是
    /// 给模型的下一步指示。调用方负责"每回合最多续跑一次"：续跑那一轮再调用时传
    /// `stopHookActive: true`，并忽略这一轮返回的 block。
    @discardableResult
    public func stop(sessionID: String, reason: String, projectRoot: URL?,
                     stopHookActive: Bool = false) async -> String? {
        let hooks = resolveHooks(event: .stop, toolName: nil, projectRoot: projectRoot)
        guard !hooks.isEmpty else { return nil }
        var object: [String: Any] = [
            "hook_event_name": HookEvent.stop.rawValue,
            "session_id": sessionID,
            "stop_reason": reason,
            "stop_hook_active": stopHookActive,
        ]
        if let projectRoot { object["cwd"] = projectRoot.path }
        var blockReason: String?
        for hook in hooks {
            guard let output = await execute(hook, payloadObject: object) else { continue }
            if output.verdict == .deny, blockReason == nil {
                blockReason = output.reason ?? "Stop 钩子要求继续"
            }
        }
        return blockReason
    }

    /// 等待 Stop 钩子结果的入口：会话还没有注册项目根时用已知根。
    public func stopAwaiting(sessionID: String, reason: String,
                             stopHookActive: Bool) async -> String? {
        await stop(sessionID: sessionID, reason: reason, projectRoot: root(forSession: sessionID),
                   stopHookActive: stopHookActive)
    }

    /// 退出 App 时同步等待 SessionEnd 钩子，最多 `timeout` 秒（默认 5 秒），超时就放弃。
    public func fireAndWait(_ event: HookEvent, sessionID: String, fields: [String: String] = [:],
                            timeout: TimeInterval = 5) async {
        let projectRoot = root(forSession: sessionID)
        let work = Task { [self] in
            await self.fire(event, sessionID: sessionID, fields: fields, projectRoot: projectRoot)
        }
        let limit = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            work.cancel()
        }
        await work.value
        limit.cancel()
    }

    /// 退出 App 时给本次运行见过的每个会话发 SessionEnd，并行执行，总共最多等 `timeout` 秒。
    public func fireSessionEndAtExit(timeout: TimeInterval = 5) async {
        let ids = knownSessionIDs()
        guard !ids.isEmpty else { return }
        let work = Task { [self] in
            await withTaskGroup(of: Void.self) { group in
                for id in ids {
                    group.addTask {
                        await self.fire(.sessionEnd, sessionID: id, fields: ["reason": "exit"],
                                        projectRoot: self.root(forSession: id))
                    }
                }
            }
        }
        let limit = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            work.cancel()
        }
        await work.value
        limit.cancel()
    }

    /// 已知（本次运行见过）的会话 ID，用于退出时给每个会话发 SessionEnd。
    public func knownSessionIDs() -> [String] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return Array(startedSessions).sorted()
    }

    // MARK: Notification / SubagentStop / PreCompact / SessionEnd (observation only)

    /// 对齐 Claude Code 的四个只观察事件。钩子不能延迟或改变触发它的流程，所以
    /// App 侧用 `notifyEvent` 即发即弃；`fire` 供测试和需要等待结果的调用方使用。
    /// `fields` 会原样（脱敏并截断后）写进钩子的 stdin JSON，例如
    /// Notification: ["message": …]、PreCompact: ["trigger": "manual" | "auto"]、
    /// SessionEnd: ["reason": …]、SubagentStop: ["stop_reason": …]。
    public func notifyEvent(_ event: HookEvent, sessionID: String, fields: [String: String] = [:]) {
        let projectRoot = root(forSession: sessionID)
        Task.detached(priority: .utility) { [self] in
            await self.fire(event, sessionID: sessionID, fields: fields, projectRoot: projectRoot)
        }
    }

    private func forgetStartedSession(_ sessionID: String) {
        stateLock.lock()
        defer { stateLock.unlock() }
        startedSessions.remove(sessionID)
    }

    public func fire(
        _ event: HookEvent, sessionID: String, fields: [String: String] = [:], projectRoot: URL?
    ) async {
        let hooks = resolveHooks(event: event, toolName: nil, projectRoot: projectRoot)
        if event == .sessionEnd {
            // 会话结束后再次进入同一会话，应当重新触发 SessionStart。
            forgetStartedSession(sessionID)
        }
        guard !hooks.isEmpty else { return }
        var object: [String: Any] = [
            "hook_event_name": event.rawValue,
            "session_id": sessionID,
        ]
        for (key, value) in fields where object[key] == nil {
            object[key] = HookPayload.sanitize(value, limit: HookPayload.maximumToolResponseLength)
        }
        if let projectRoot { object["cwd"] = projectRoot.path }
        for hook in hooks {
            _ = await execute(hook, payloadObject: object)
        }
    }
}
