import SwiftUI
import MinisCore

/// Goal18 Hooks：设置页「Hooks」分区的数据层。只读写 HookConfigStore；
/// 信任只能由本分区的按钮建立。
@MainActor
@Observable
final class HooksSettingsController {
    struct UserRow: Identifiable, Equatable {
        let definition: HookDefinition
        let lastRun: HookRunRecord?
        var id: String { definition.id }
    }

    struct ProjectRow: Identifiable, Equatable {
        let snapshot: ProjectHooksSnapshot
        var id: String { snapshot.projectRoot }
    }

    private(set) var userRows: [UserRow] = []
    private(set) var projectRows: [ProjectRow] = []
    private(set) var userSnapshot: ProjectHooksSnapshot?
    private(set) var userConfigError: String?
    private(set) var message: String?
    private let runtime: HookRuntime?

    init(runtime: HookRuntime? = MinisCore.HookRuntime.installed) {
        self.runtime = runtime
    }

    var isAvailable: Bool { runtime != nil }

    func refresh() {
        guard let runtime else {
            userRows = []
            projectRows = []
            return
        }
        userSnapshot = runtime.store.userHooksSnapshot()
        let loaded = runtime.store.loadUserHooks()
        userConfigError = loaded.error
        userRows = loaded.hooks.map { definition in
            UserRow(definition: definition,
                    lastRun: runtime.lastRun(key: hookKey(source: .user, id: definition.id)))
        }
        projectRows = runtime.knownProjectRoots().compactMap { root in
            let snapshot = runtime.store.projectSnapshot(projectRoot: root)
            if case .noFile = snapshot.trust { return nil }
            return ProjectRow(snapshot: snapshot)
        }
    }

    func setEnabled(id: String, enabled: Bool) {
        perform { try $0.store.setUserHookEnabled(id: id, enabled: enabled) }
    }

    func remove(id: String) {
        perform { try $0.store.removeUserHook(id: id) }
    }

    @discardableResult
    func add(event: HookEvent, matcher: String, command: String, timeoutText: String) -> Bool {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTimeout = timeoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        let timeout = trimmedTimeout.isEmpty ? nil : Double(trimmedTimeout)
        guard !trimmedCommand.isEmpty, trimmedTimeout.isEmpty || timeout != nil else {
            message = "命令不能为空，超时必须是数字（秒）"
            return false
        }
        let trimmedMatcher = matcher.trimmingCharacters(in: .whitespacesAndNewlines)
        let definition = HookDefinition(
            event: event,
            matcher: event.usesToolMatcher && !trimmedMatcher.isEmpty ? trimmedMatcher : nil,
            command: trimmedCommand,
            timeoutSeconds: timeout
        )
        return perform { try $0.store.addUserHook(definition) }
    }

    /// `snapshot.contentHash` is the hash the user is looking at; the store refuses
    /// to trust if the file changed after this review.
    func trust(_ snapshot: ProjectHooksSnapshot, userLevel: Bool = false) {
        guard let hash = snapshot.contentHash else { return }
        perform {
            if userLevel { try $0.store.trustUserHooks(expectedHash: hash); return }
            try $0.store.trustProjectHooks(
                projectRoot: URL(fileURLWithPath: snapshot.projectRoot, isDirectory: true),
                expectedHash: hash)
        }
    }

    func revoke(_ snapshot: ProjectHooksSnapshot, userLevel: Bool = false) {
        perform {
            if userLevel { try $0.store.revokeUserTrust(); return }
            try $0.store.revokeProjectTrust(
                projectRoot: URL(fileURLWithPath: snapshot.projectRoot, isDirectory: true))
        }
    }

    @discardableResult
    private func perform(_ operation: (HookRuntime) throws -> Void) -> Bool {
        guard let runtime else { return false }
        do {
            try operation(runtime)
            message = nil
            refresh()
            return true
        } catch HookConfigStoreError.contentChangedSinceReview {
            message = "项目 Hook 文件在你查看后发生了变化，未信任；请重新查看。"
        } catch {
            message = "Hook 配置未能保存"
        }
        refresh()
        return false
    }

    nonisolated static func statusText(_ record: HookRunRecord) -> String {
        let label: String
        switch record.status {
        case .completed: label = "已运行"
        case .nonZeroExit: label = record.decision == "deny" ? "已拦截（非零退出）" : "非零退出（未影响决策）"
        case .timedOut: label = record.decision == "deny" ? "已拦截（超时）" : "超时（未影响决策）"
        case .launchFailed: label = "未能启动（未影响决策）"
        case .invalidOutput: label = "输出无效（未影响决策）"
        case .cancelled: label = "调用已取消，已终止（未影响决策）"
        }
        var text = "最近一次：" + label + "，" + String(record.durationMilliseconds) + " 毫秒"
        if let decision = record.decision { text += "，返回 " + decision }
        if !record.summary.isEmpty { text += "，" + record.summary }
        return text
    }

    /// Red warning lines for project hooks whose command runs a script outside
    /// `.miniscanvas/hooks/`: editing such a script would not change the trust
    /// hash, so these hooks are never run. One line per hook, in file order.
    nonisolated static func outsideScriptWarnings(_ snapshot: ProjectHooksSnapshot) -> [String] {
        snapshot.hooks.compactMap { hook in
            guard let paths = snapshot.outsideReferences[hook.id], !paths.isEmpty else { return nil }
            return "Hook " + hook.id + " 引用了受保护目录之外的脚本（" + paths.joined(separator: "、")
                + "）：这些脚本的改动不会触发重新确认，所以该 Hook 不会运行。请把脚本放进 .miniscanvas/hooks/。"
        }
    }

    nonisolated static func trustReviewText(_ snapshot: ProjectHooksSnapshot) -> String {
        var lines = [snapshot.projectRoot]
        lines += snapshot.hooks.map { $0.event.rawValue + "：" + $0.command }
        let scripts = snapshot.protectedScriptFiles
        lines.append(scripts.isEmpty
            ? "受保护脚本目录 .miniscanvas/hooks/：无文件"
            : "受保护脚本目录 .miniscanvas/hooks/ 内的 \(scripts.count) 个文件的内容都计入信任："
                + scripts.prefix(10).joined(separator: "、") + (scripts.count > 10 ? " …" : ""))
        lines += outsideScriptWarnings(snapshot).map { "【警告】" + $0 }
        return lines.joined(separator: "\n")
    }

    nonisolated static func trustText(_ trust: ProjectHooksSnapshot.Trust) -> String {
        switch trust {
        case .noFile: return "无 Hook 文件"
        case .invalid(let reason): return "无法使用：" + reason
        case .untrusted(let changed): return changed ? "文件已变化，需要重新信任，当前不运行" : "首次发现，信任前不运行"
        case .trusted: return "已信任"
        }
    }
}

struct HooksSettingsSection: View {
    @State private var controller = HooksSettingsController()
    @State private var draftEvent: HookEvent = .preToolUse
    @State private var draftMatcher = ""
    @State private var draftCommand = ""
    @State private var draftTimeout = ""
    private enum DraftField: Hashable { case matcher, command, timeout }
    @FocusState private var draftFocus: DraftField?
    @State private var reviewing: ProjectHooksSnapshot?
    @State private var showsTrustReview = false
    @State private var reviewingUser = false

    var body: some View {
        Section("Hooks") {
            Text("Hook 在工具调用前后、提交消息、会话开始与结束时运行你配置的命令，可放行、拒绝或要求确认工具调用。默认没有任何 Hook；Hook 不能放行产品已拒绝的操作。")
                .foregroundStyle(.secondary)
            if !controller.isAvailable {
                Text("Hooks 当前不可用").foregroundStyle(.secondary)
            }
            if let error = controller.userConfigError {
                Text(error).modifier(ReadableStatusForeground(status: .danger))
            }
            if let snapshot = controller.userSnapshot, snapshot.trust != .noFile {
                Text("用户 Hooks：" + HooksSettingsController.trustText(snapshot.trust))
                    .font(.caption).foregroundStyle(.secondary)
                Text("新增、启用或内容变化后须确认一次；用户 Hook 相对脚本以配置目录为基准，仅 .miniscanvas/hooks/ 内的脚本受哈希覆盖；引用动态项目目录的脚本不执行。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("查看并信任用户 Hooks…") {
                    reviewingUser = true; reviewing = snapshot; showsTrustReview = true
                }.disabled(snapshot.contentHash == nil)
                if snapshot.trust == .trusted {
                    Button("撤销用户 Hooks 信任") { controller.revoke(snapshot, userLevel: true) }
                }
            }
            ForEach(controller.userRows) { row in
                userRow(row)
            }
            if controller.isAvailable {
                addForm
            }
            ForEach(controller.projectRows) { row in
                projectRow(row.snapshot)
            }
            if let message = controller.message {
                Text(message).foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.hooks.message")
            }
        }
        .onAppear { controller.refresh() }
        .confirmationDialog(
            reviewingUser ? "信任这些用户 Hooks？" : "信任此项目的 Hooks？",
            isPresented: $showsTrustReview,
            presenting: reviewing
        ) { snapshot in
            Button("信任并启用") { controller.trust(snapshot, userLevel: reviewingUser) }
            Button("取消", role: .cancel) {}
        } message: { snapshot in
            Text(HooksSettingsController.trustReviewText(snapshot))
        }
    }

    @ViewBuilder
    private func userRow(_ row: HooksSettingsController.UserRow) -> some View {
        let definition = row.definition
        HStack(alignment: .top) {
            Toggle(isOn: Binding(
                get: { definition.enabled },
                set: { controller.setEnabled(id: definition.id, enabled: $0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(definition.event.rawValue
                         + (definition.event.usesToolMatcher ? " · " + (definition.matcher ?? "全部工具") : ""))
                    Text(definition.command)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if let record = row.lastRun {
                        Text(HooksSettingsController.statusText(record))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityIdentifier("settings.hooks.user." + definition.id)
            Button("删除", role: .destructive) { controller.remove(id: definition.id) }
                .accessibilityIdentifier("settings.hooks.remove." + definition.id)
        }
    }

    @ViewBuilder
    private var addForm: some View {
        Picker("事件", selection: $draftEvent) {
            ForEach(HookEvent.allCases, id: \.self) { event in
                Text(event.rawValue).tag(event)
            }
        }
        .accessibilityIdentifier("settings.hooks.draft.event")
        if draftEvent.usesToolMatcher {
            TextField("工具名（可用 | 分隔，留空表示全部）", text: $draftMatcher)
                .accessibilityIdentifier("settings.hooks.draft.matcher")
                .focused($draftFocus, equals: .matcher)
        }
        TextField("命令（从 stdin 读取事件 JSON，从 stdout 输出决策 JSON）", text: $draftCommand)
            .accessibilityIdentifier("settings.hooks.draft.command")
            .focused($draftFocus, equals: .command)
        TextField("超时秒数（默认 10）", text: $draftTimeout)
            .accessibilityIdentifier("settings.hooks.draft.timeout")
            .focused($draftFocus, equals: .timeout)
        Button("添加 Hook") {
            if controller.add(event: draftEvent, matcher: draftMatcher,
                              command: draftCommand, timeoutText: draftTimeout) {
                draftMatcher = ""
                draftCommand = ""
                draftTimeout = ""
            }
        }
        .disabled(draftCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityIdentifier("settings.hooks.draft.add")
    }

    @ViewBuilder
    private func projectRow(_ snapshot: ProjectHooksSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("项目 Hooks：" + snapshot.projectRoot)
            Text(HooksSettingsController.trustText(snapshot.trust))
                .font(.caption)
                .foregroundStyle(snapshot.needsTrustDecision ? Color.orange : Color.secondary)
            ForEach(HooksSettingsController.outsideScriptWarnings(snapshot), id: \.self) { warning in
                Text(warning)
                    .font(.caption)
                    .modifier(ReadableStatusForeground(status: .danger))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.hooks.project.outside-warning")
            }
            if snapshot.needsTrustDecision {
                Button("查看并信任…") {
                    reviewingUser = false
                    reviewing = snapshot
                    showsTrustReview = true
                }
                .accessibilityIdentifier("settings.hooks.project.review")
            } else if snapshot.trust == .trusted {
                Button("撤销信任") { controller.revoke(snapshot) }
                    .accessibilityIdentifier("settings.hooks.project.revoke")
            }
        }
    }
}
