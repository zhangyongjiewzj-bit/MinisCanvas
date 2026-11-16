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

    public init(
        store: HookConfigStore,
        runner: any HookCommandRunning = HookProcessRunner(),
        environment: @escaping @Sendable () throws -> [String: String] = { try ChildProcessEnvironment.values() }
    ) {
        self.store = store
        self.runner = runner
        self.environmentProvider = environment
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
        return resolved
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
        if let root = hook.projectRoot { environment["MINISCANVAS_PROJECT_DIR"] = root.path }

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
        if result.exitCode == 2, definition.event == .preToolUse || definition.event == .userPromptSubmit {
            let reason = HookOutputParser.clean(String(decoding: result.stderr, as: UTF8.self),
                limit: HookOutputParser.maximumReasonLength) ?? "Hook 退出码 2：阻止本次调用"
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
        guard !hooks.isEmpty else { return neutral }

        var object: [String: Any] = [
            "hook_event_name": HookEvent.preToolUse.rawValue,
            "session_id": invocation.sessionID,
            "tool_name": invocation.capability,
            "tool_call_id": invocation.callID,
            "tool_input": HookPayload.toolInput(invocation.input),
        ]
        if let projectRoot { object["cwd"] = projectRoot.path }

        var verdicts: [HookLayerVerdict] = []
        var denyReason: String?
        var askReason: String?
        for hook in hooks {
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
            "tool_name": invocation.capability,
            "tool_call_id": invocation.callID,
            "tool_input": HookPayload.toolInput(invocation.input),
        ]
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

    public func stop(sessionID: String, reason: String, projectRoot: URL?) async {
        let hooks = resolveHooks(event: .stop, toolName: nil, projectRoot: projectRoot)
        guard !hooks.isEmpty else { return }
        var object: [String: Any] = [
            "hook_event_name": HookEvent.stop.rawValue,
            "session_id": sessionID,
            "stop_reason": reason,
        ]
        if let projectRoot { object["cwd"] = projectRoot.path }
        for hook in hooks {
            _ = await execute(hook, payloadObject: object)
        }
    }
}
