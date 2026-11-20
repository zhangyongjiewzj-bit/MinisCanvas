import SwiftUI
import AppKit
import Darwin
import MinisCore
import CryptoKit

/// The App process credential is the only production source for Personal memory.
/// The injected reader is internal and exists solely for synthetic boundary tests;
/// settings, environment variables, imported owner text, and model output never
/// participate in principal construction.
struct ProcessUIDMemoryPrincipalSource: Sendable {
    private let readUID: @Sendable () -> uid_t?

    init(readUID: @escaping @Sendable () -> uid_t?) {
        self.readUID = readUID
    }

    static var production: Self {
        Self(readUID: { getuid() })
    }

    func trustedPrincipal() -> MemoryTrustedPrincipal? {
        guard let uid = readUID() else { return nil }
        let userID = "macos-uid:\(uid)"
        return MemoryTrustedPrincipal.validated(userID: userID) { candidate in
            guard let currentUID = readUID() else { return false }
            return candidate == "macos-uid:\(currentUID)"
        }
    }
}

// B0324: field-only nonsecret first-gate projection. The caller supplies actual
// composition/lane identity facts; this helper neither constructs nor admits them.
enum MM01CompositionReadyMarker {
    static func emit(arguments: [String], mode: RuntimeIsolationProfile.Mode,
                     pid: Int32, profileIdentity: String, windowNonce: String?,
                     compositionPresent: Bool, laneInstalled: Bool, actionLedgerInstalled: Bool,
                     budgetCounts: (installed: Bool, limit: Int, reserved: Int, refused: Int),
                     monotonicNanoseconds: UInt64,
                     sink: (Data) throws -> Void = { try FileHandle.standardOutput.write(contentsOf: $0) }) -> Bool {
        guard arguments.filter({ $0 == DeepSeekMM01FieldLane.activationArgument }).count == 1,
              mode == .packagedField else { return false }
        let row: [String: Any] = [
            "schema": "MM01_TYPED_COMPOSITION_READY_V1", "pid": pid,
            "profile_identity": profileIdentity,
            "window_nonce": windowNonce.map { $0 as Any } ?? NSNull(),
            "monotonic_nanoseconds": monotonicNanoseconds,
            "composition_present": compositionPresent, "lane_installed": laneInstalled,
            "action_ledger_installed": actionLedgerInstalled,
            "read_budget_installed": budgetCounts.installed, "read_budget_limit": budgetCounts.limit,
            "read_budget_reserved": budgetCounts.reserved, "read_budget_refused": budgetCounts.refused
        ]
        do {
            var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            data.append(10)
            try sink(data)
            return true
        } catch {
            // A missing/failed record makes the external first gate stop before
            // any UI button or request. Never serialize an Error or secret here.
            return false
        }
    }
}

// MARK: - F7 P0-4 退出/崩溃数据保全（willTerminate flush + clean-exit 标记 + 启动自动恢复）
//
// macOS 无 beforeunload —— SessionDrafts.swift 注释把 DraftStore.flushAll 自比 ComfyUI
// beforeunload 兜底，但此前全仓库零接线。本层完成接线：
//   · NSApplicationDelegate.applicationWillTerminate → DraftStore.flushAll()（画布图 +
//     全部会话输入草稿共用同一 DraftStore，一次 flush 全覆盖）；
//   · UserDefaults clean-exit 标记区分正常退出 / 崩溃（kill -9、强退不走 willTerminate）；
//   · 上次正常退出 → 启动静默自动恢复画布草稿（ComfyUI 工作流持久化语义）；
//     上次异常退出 → 不自动恢复，走 attachProductionServices 内既有崩溃提示（脏标记
//     保证该提示只在真崩溃时触发，消除误报）。

/// App 退出/崩溃数据保全守卫（F7 P0-4）。
///
/// clean-exit 标记（UserDefaults `miniscanvas.app.lastExitClean`）生命周期：
/// - 启动 `beginSession()`：读上次退出状态（键不存在 = 首次安装/升级，按 clean 处理，
///   不误报崩溃提示），随即写脏标记（false）；
/// - 正常退出 `handleWillTerminate(bridge:)`：flushAll 落盘全部防抖草稿 → 重写干净标记（true）；
/// - 崩溃 / kill -9 / 强制退出：willTerminate 不执行 → 脏标记残留 → 下次启动
///   `lastExitWasClean == false`，崩溃恢复提示仅此时出现。
@MainActor
final class AppLifecycleGuard {
    /// clean-exit 标记的 UserDefaults key
    static let cleanExitDefaultsKey = "miniscanvas.app.lastExitClean"

    private let defaults: UserDefaults
    /// 上次会话的退出状态（beginSession 后有效；键不存在按 clean）
    private(set) var lastExitWasClean = true
    /// 防止窗口重建重复触发 .task 时重复执行（每进程一次）
    private var sessionStarted = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 进程启动入口（D-RECOVERY-09）：构造守卫并立即 beginSession，把「读上次退出
    /// 状态 + 写脏标记」从 SwiftUI `.task`（首帧之后）前移到 App init（进程启动）。
    /// 消除启动早期崩溃 / 白屏强退时脏标记尚未写入、上次 clean 标记被误当成
    /// 本次退出分类的窗口——启动即死也绝不会记成正常 clean exit。
    /// `.task` 中的 beginSession 消费点经 sessionStarted 幂等保护，返回同一结果。
    static func beginAtLaunch(defaults: UserDefaults = .standard) -> AppLifecycleGuard {
        let lifecycle = AppLifecycleGuard(defaults: defaults)
        lifecycle.beginSession()
        return lifecycle
    }

    /// 启动：读上次退出状态 → 立即写脏标记。返回上次是否干净退出。
    /// 同一进程内重复调用（窗口重建导致 .task 重跑）返回首次结果，不重复判定。
    @discardableResult
    func beginSession() -> Bool {
        if sessionStarted { return lastExitWasClean }
        sessionStarted = true
        if let value = defaults.object(forKey: Self.cleanExitDefaultsKey) as? Bool {
            lastExitWasClean = value
        } else {
            lastExitWasClean = true   // 首次安装/升级：按干净处理（不弹误报崩溃提示）
        }
        defaults.set(false, forKey: Self.cleanExitDefaultsKey)   // 脏标记：正常退出才重写 true
        return lastExitWasClean
    }

    /// 绑定退出 flush：AppDelegate 的 willTerminate → flushAll + 干净标记
    func bind(appDelegate: MinisCanvasAppDelegate, bridge: BridgeStore?) {
        appDelegate.onWillTerminate = { [weak bridge] in
            self.handleWillTerminate(bridge: bridge)
        }
    }

    /// willTerminate（仅正常退出时系统调用）：全部防抖草稿立即落盘 → 置 clean-exit 标记。
    /// 画布与会话输入草稿共用同一 DraftStore（attachProductionServices 装配），
    /// flushAll 一次覆盖画布草稿 + 全部会话输入草稿（等价 ComfyUI beforeunload flush）。
    func handleWillTerminate(bridge: BridgeStore?) {
        // Quit rejects the same pending approval shown by the production UI.
        // Resume its existing waiter before the process leaves the actor;
        // no permission or successful tool execution is implied by shutdown.
        bridge?.approvalCenter.rejectForApplicationExit()
        // Revoke the recording generation before flushing. Delayed permission
        // or transcription callbacks must not start audio or edit a saved draft
        // while the normal termination callback is completing.
        bridge?.cancelComposerSpeechInput()
        bridge?.stopProductionSpeechOutput()
        // Chat owns the shared DraftStore in the packaged Phase 3 lane;
        // reading `bridge.canvas` here would construct or require Canvas on exit.
        // 会话写盘在后台串行队列；退出前等它写完，避免丢最后一次变更。
        bridge?.chat.flushPendingSessionPersistence()
        let didFlushLongDrafts = bridge?.chat.flushPendingDraftForTermination() ?? true
        let didFlush = (bridge?.chat.draftStore?.flushAll() ?? true) && didFlushLongDrafts
        if didFlush {
            defaults.set(true, forKey: Self.cleanExitDefaultsKey)
        }
    }

    /// 启动自动恢复（上次干净退出路径，ComfyUI 工作流持久化语义）：
    /// 读磁盘画布草稿 → 重建节点图 → 消费（清除）草稿文件，
    /// 避免 attachProductionServices 内崩溃提示对「正常退出」误报。
    /// 返回是否发生恢复（空草稿/不可解返回 false，但可解草稿一律消费不留残）；
    /// 调用方需在 draft store 装配后调 canvas.noteGraphChanged()
    /// 重新挂上防抖落盘（否则本次会话退出 flush 无 payload 可写，画布状态会丢）。
    @discardableResult
    static func autoRestoreCanvasDraft(
        into canvas: CanvasStore,
        directory: URL,
        preloadedData: Data? = nil,
        expectedMutationGeneration: UInt64? = nil
    ) -> Bool {
        // M4：多画布模式（集合文件存在）走 attachDraftStore 的 restoreCollectionIfPresent，
        // 此处跳过单画布自动恢复，避免误清首画布草稿。
        guard !CanvasStore.collectionFileExists(at: directory) else { return false }
        let drafts = DraftStore(directory: directory)
        // B2: clean-exit auto-restore runs before attachDraftStore, so it must use
        // the same startup migration seam before reading the canonical snapshot.
        _ = LegacyCanvasAssetMigration.migrateIfNeeded(
            legacyDirectory: directory,
            currentDirectory: canvas.assetPersistenceDirectory
        )
        if let snapshot = CanvasAssetStore.loadSnapshot(from: canvas.assetPersistenceDirectory) {
            canvas.restoreAssetSnapshot(snapshot)
        }
        // R9 卡顿专项：preloadedData 由调用方在后台线程完成磁盘读取（Data(contentsOf:)），
        // 避免启动时主线程同步读画布草稿卡首帧；传 nil（默认，测试/兼容路径）
        // 仍由本函数同步读取，语义不变。
        guard let data = preloadedData ?? drafts.load(key: DraftStore.canvasKey),
              let draft = try? JSONDecoder().decode(CanvasDraft.self, from: data) else { return false }
        // The caller may have loaded this payload off-main-thread. Keep a
        // startup edit made while that read was in flight and leave the draft
        // available for an explicit recovery decision.
        if let expectedMutationGeneration,
           expectedMutationGeneration != canvas.mutationGeneration {
            return false
        }
        drafts.clear(key: DraftStore.canvasKey)   // 可解即消费（空草稿也不留残，防下次误报）
        return canvas.restoreCanvas(
            from: draft,
            expectedMutationGeneration: expectedMutationGeneration
        )
    }
}

/// App composition root defaults. BridgeStore keeps orchestration opt-in for
/// offline/test construction; the real app enables the production capability.
@MainActor
enum ProductionOrchestrationDefaults {
    @discardableResult
    static func attachProductionServices(
        to bridge: BridgeStore,
        agentSettings: AgentSettings = .default,
        speechGeneralLanguage: String? = nil,
        fileAccessAllowedRoot: URL? = nil,
        fileAccessDeniedRoots: [URL]? = nil,
        fileAccessDefaultPrivateDataRoots: [URL]? = nil,
        fileAccessMountedRoots: [URL] = [],
        localAgentSessionHome: URL? = nil,
        sessionDirectory: URL = SessionStore.defaultDirectory,
        mcpManager: MCPServerManager? = nil,
        skillStore: SkillStore? = nil,
        childDeletionReviewConfiguration: ChildDeletionReviewConfiguration = .init(),
        canvasRuntimeState: RuntimeIsolationProfile.CanvasRuntimeState = .enabled,
        childConcurrencySelection: ChildConcurrencySelection = .default,
        externalNetworkAllowed: Bool = true,
        controlledFieldLoopbackAllowed: Bool = false,
        sessionReadSecretStore: EnvVarStore? = nil,
        preserveChildGovernorOnSafetyLift: Bool = false
    ) -> Task<Void, Never> {
        return bridge.attachProductionServices(
            agentSettings: agentSettings,
            speechGeneralLanguage: speechGeneralLanguage,
            fileAccessAllowedRoot: fileAccessAllowedRoot,
            fileAccessDeniedRoots: fileAccessDeniedRoots,
            fileAccessDefaultPrivateDataRoots: fileAccessDefaultPrivateDataRoots,
            fileAccessMountedRoots: fileAccessMountedRoots,
            localAgentSessionHome: localAgentSessionHome,
            sessionDirectory: sessionDirectory,
            mcpManager: mcpManager,
            skillStore: skillStore,
            childDeletionReviewConfiguration: childDeletionReviewConfiguration,
            policyDefaults: agentSettings.policyRuntimeDefaults,
            enableOrchestration: true,
            childConcurrencySelection: childConcurrencySelection,
            canvasRuntimeState: canvasRuntimeState,
            externalNetworkAllowed: externalNetworkAllowed,
            controlledFieldLoopbackAllowed: controlledFieldLoopbackAllowed,
            sessionReadSecretStore: sessionReadSecretStore,
            preserveChildGovernorOnSafetyLift: preserveChildGovernorOnSafetyLift
        )
    }

    /// P3-CHILD-40: connect the SettingsCenter projection to the one
    /// production composition seam.  The callback receives the already
    /// validated user-selected/recommended/effective snapshot, so the
    /// composition root never rewrites the user's selection or bypasses
    /// the hard ceiling.  Re-attaching the existing production seam keeps the
    /// live runtime consumer in one place. Existing resource actors commit the
    /// new effective policy before the replacement execution wrappers publish.
    static func bindChildConcurrencySelection(
        to bridge: BridgeStore,
        settings: SettingsCenter,
        profile: RuntimeIsolationProfile,
        controlledFieldLoopbackAllowed: Bool = false
    ) {
        settings.onChildConcurrencySelectionChanged = { [weak bridge, weak settings] selection in
            guard let bridge, let settings else { return }
            attachCurrentProductionConfiguration(
                to: bridge,
                settings: settings,
                profile: profile,
                childConcurrencySelection: selection,
                controlledFieldLoopbackAllowed: controlledFieldLoopbackAllowed
            )
        }
    }

    /// D-PRIVACY-01/02: only a durable SettingsCenter file-root commit
    /// reattaches the existing production composition for the next request.
    /// Disposable profiles rebind only their own settings; their fixed file root
    /// never consumes production privacy settings; the only mounts they carry are
    /// their own settings' qualifying external-session mounts inside their own root.
    static func bindFileAccessSettings(
        to bridge: BridgeStore,
        settings: SettingsCenter,
        profile: RuntimeIsolationProfile,
        arguments: [String] = CommandLine.arguments,
        controlledFieldLoopbackAllowed: Bool = false
    ) {
        guard !profile.isDisposable || isolatedDeletionSettingsAreOwned(settings, profile: profile) else { return }
        settings.onFileAccessSettingsChanged = { [weak bridge, weak settings] in
            guard let bridge, let settings else { return }
            settings.pendingFileAccessAttachment = attachCurrentProductionConfiguration(
                to: bridge,
                settings: settings,
                profile: profile,
                childConcurrencySelection: settings.childConcurrencySelection,
                controlledFieldLoopbackAllowed: controlledFieldLoopbackAllowed,
                arguments: arguments
            )
        }
    }

    /// Reuse the startup composition after a durable user ceiling change.
    /// In-flight turns keep their captured engine and immutable snapshot.
    static func bindPolicyRuntimeDefaults(
        to bridge: BridgeStore,
        settings: SettingsCenter,
        profile: RuntimeIsolationProfile,
        controlledFieldLoopbackAllowed: Bool = false
    ) {
        bridge.chat.persistComposerCeiling = { [weak bridge, weak settings] expected, required in
            guard let bridge, let settings, settings.policyRuntimeDefaults.autonomyLevel == expected else { return false }
            var value = settings.policyRuntimeDefaults
            value.autonomyLevel = required
            guard settings.updatePolicyRuntimeDefaults(value) else { return false }
            await bridge.lastChildGovernorSafetyTask?.value
            return settings.policyRuntimeDefaults.autonomyLevel == required
        }
        settings.onPolicyRuntimeDefaultsChanged = { [weak bridge, weak settings] value in
            guard let bridge, let settings,
                  settings.policyRuntimeDefaults == value else { return }
            if bridge.chat.composerPolicyFacts.autonomyCeiling != value.autonomyLevel {
                bridge.chat.onSessionPermissionContextChanged?()
            }
            attachCurrentProductionConfiguration(
                to: bridge,
                settings: settings,
                profile: profile,
                childConcurrencySelection: settings.childConcurrencySelection,
                controlledFieldLoopbackAllowed: controlledFieldLoopbackAllowed
            )
            // 下调上限后，超限的默认模式（落盘）与会话已选模式一并降为手动审批。
            var defaultDowngraded = false
            if settings.composerPolicy.mode.requiredAutonomyLevel > value.autonomyLevel {
                var downgraded = settings.composerPolicy
                downgraded.mode = .manual
                downgraded.bypassModeConfirmed = false
                settings.composerPolicy = downgraded
                defaultDowngraded = true
            }
            bridge.chat.lowerComposerModeForCeiling(value.autonomyLevel, defaultDowngraded: defaultDowngraded)
        }
    }

    /// Isolated settings must belong to this intact profile. Never derive an
    /// isolated opt-in from a production SettingsCenter or a replaced root.
    static func isolatedDeletionSettingsAreOwned(
        _ settings: SettingsCenter, profile: RuntimeIsolationProfile
    ) -> Bool {
        profile.isDisposable && profile.mode != .blocked && profile.isDisposableRootIntact
            && settings.settingsStore.directory.standardizedFileURL.path == profile.settingsDirectory.standardizedFileURL.path
            && settings.sessionStore.directory.standardizedFileURL.path == profile.sessionDirectory.standardizedFileURL.path
    }

    /// Only a committed user setting enables review. For a disposable profile,
    /// the caller must first prove ownership and supply its existing execution
    /// root. No root means off, preserving the former fail-closed call contract.
    static func childDeletionReviewConfiguration(
        agent: AgentSettings,
        profileIsDisposable: Bool,
        isolatedExecutionRoot: URL? = nil
    ) -> ChildDeletionReviewConfiguration {
        var scopedAgent = agent
        if profileIsDisposable {
            guard let root = isolatedExecutionRoot,
                  root.standardizedFileURL.path == root.resolvingSymlinksInPath().standardizedFileURL.path else {
                return ChildDeletionReviewConfiguration()
            }
            let path = root.standardizedFileURL.path
            // Filter before filesystem validation, so foreign whitelist paths
            // are neither inspected nor resolved in an isolated profile.
            scopedAgent.childDeletionAutoReviewWhitelist = agent.childDeletionAutoReviewWhitelist.filter {
                $0 == path || $0.hasPrefix(path + "/")
            }
        }
        return ChildDeletionReviewSettings.configuration(from: scopedAgent, onDropped: { reason in
            AppLogger(category: "ChildDeletionReview").warning(
                "whitelist entry dropped at attach: \(reason)")
        })
    }

    /// R10: a disposable profile carries only the external-session mounts from
    /// its own settings that qualify (`.codex/sessions` / `.claude/projects`)
    /// and whose realpath lies strictly inside `container` (the profile root,
    /// or its workspace for the isolated journey) and outside every denied root.
    static func disposableExternalSessionMountedRoots(
        mountedFolderPaths: [String],
        container: URL,
        deniedRoots: [URL]
    ) -> [URL] {
        func real(_ path: String) -> String? {
            guard let resolved = realpath(path, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        func isWithin(_ path: String, _ base: String) -> Bool {
            path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
        }
        guard let containerReal = real(container.path) else { return [] }
        let deniedReal = deniedRoots.map { real($0.path) ?? $0.standardizedFileURL.path }
        return mountedFolderPaths.compactMap { path -> URL? in
            guard path.hasPrefix("/"),
                  ExternalSessionMountQualification.isQualifyingMount(path),
                  let target = real(path),
                  target != containerReal,
                  isWithin(target, containerReal),
                  !deniedReal.contains(where: { isWithin(target, $0) }) else { return nil }
            return URL(fileURLWithPath: target, isDirectory: true)
        }
    }

    /// P3-P1-03(a): one derivation from the live SettingsCenter projection to
    /// the production attach arguments.  The startup composition, the
    /// P3-CHILD-40 re-binding, and the runtime file-access re-attach all flow
    /// through this exact function, so a committed setting rebuilds the same
    /// composition root without hand-copied arguments.  The child-concurrency
    /// selection is passed explicitly because the P3-CHILD-40 callback carries
    /// the freshly validated value.
    @discardableResult
    static func attachCurrentProductionConfiguration(
        to bridge: BridgeStore,
        settings: SettingsCenter,
        profile: RuntimeIsolationProfile,
        childConcurrencySelection: ChildConcurrencySelection,
        controlledFieldLoopbackAllowed: Bool = false,
        preserveChildGovernorOnSafetyLift: Bool = false,
        arguments: [String] = CommandLine.arguments
    ) -> Task<Void, Never> {
        bridge.webFetchPinnedRouteProvider = { url in
            H05SystemWebFetchRoute.route(for: url)
        }
        bridge.webFetchNetworkConfigurationProvider = { @MainActor [settings] expected in
            settings.networkDomainConfigurationSnapshot(expectedDefaults: expected)
        }
        bridge.p03CleanupAppController.enablePersistence(
            at: profile.rootDirectory.appendingPathComponent("child-worktree-residuals-v1.json"))
        bridge.childWorktreeRootProvider = {
            let root = try GitChildWorktreeRoot.appManaged(
                profile: P03RuntimeWorktreeProfile(profile: profile)
            )
            return (root: root, isDisposable: profile.isDisposable)
        }
        let privacy = settings.settings.privacy
        let isIsolatedJourney = profile.mode == .packagedField
            && arguments.filter {
                $0 == DeepSeekEnvironmentPackageFieldBootstrap.journeyArgument
            }.count == 1
        let journeyWorkspace = isIsolatedJourney
            ? try? DeepSeekEnvironmentPackageFieldBootstrap.validatedJourneyWorkspace(profile: profile)
            : nil
        let allowedRoot = isIsolatedJourney
            ? profile.rootDirectory.appendingPathComponent("workspace", isDirectory: true)
            : (profile.isDisposable ? profile.rootDirectory
                : privacy.allowedRootPath.map { URL(fileURLWithPath: $0) })
        var deniedRoots: [URL]? = profile.isDisposable
            ? [URL(fileURLWithPath: NSHomeDirectory())]
            : settings.fileAccessDeniedRoots.map { URL(fileURLWithPath: $0) }
        if !profile.isDisposable {
            deniedRoots = (deniedRoots ?? []) + [MinisCore.HookConfigStore.defaultDirectory()]
        }
        if isIsolatedJourney,
           journeyWorkspace == nil,
           let allowedRoot {
            // Initial bootstrap refuses this state. If a later re-attach sees
            // replacement, use the existing deny-root mechanism to deny every
            // path admitted by this root instead of falling back or widening.
            deniedRoots = (deniedRoots ?? []) + [allowedRoot]
        }
        let fieldLoopbackIsStillAllowed = controlledFieldLoopbackAllowed
            && profile.mode == .packagedField
            && profile.isDisposableRootIntact
        let childDeletionReview: ChildDeletionReviewConfiguration
        if profile.isDisposable && (!isolatedDeletionSettingsAreOwned(settings, profile: profile)
            || journeyWorkspace == nil) {
            childDeletionReview = .init()
        } else {
            childDeletionReview = childDeletionReviewConfiguration(
                agent: settings.settings.agent, profileIsDisposable: profile.isDisposable,
                isolatedExecutionRoot: profile.isDisposable ? journeyWorkspace : nil)
        }
        return attachProductionServices(
            to: bridge,
            agentSettings: settings.settings.agent,
            speechGeneralLanguage: settings.language,
            fileAccessAllowedRoot: allowedRoot,
            fileAccessDeniedRoots: deniedRoots,
            fileAccessDefaultPrivateDataRoots: profile.isDisposable
                ? nil : BuiltinToolExecutor.defaultDeniedRoots(),
            fileAccessMountedRoots: profile.isDisposable
                ? disposableExternalSessionMountedRoots(
                    mountedFolderPaths: privacy.mountedFolderPaths,
                    container: isIsolatedJourney
                        ? profile.rootDirectory.appendingPathComponent("workspace", isDirectory: true)
                        : profile.rootDirectory,
                    deniedRoots: deniedRoots ?? [])
                : privacy.mountedFolderPaths.map { URL(fileURLWithPath: $0) },
            localAgentSessionHome: !profile.isDisposable && privacy.allowLocalAgentSessionRead
                ? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true) : nil,
            sessionDirectory: profile.sessionDirectory,
            mcpManager: settings.mcpManager,
            skillStore: settings.skillStore,
            childDeletionReviewConfiguration: childDeletionReview,
            canvasRuntimeState: profile.canvasRuntimeState,
            childConcurrencySelection: childConcurrencySelection,
            externalNetworkAllowed: profile.allowsExternalNetwork,
            controlledFieldLoopbackAllowed: fieldLoopbackIsStillAllowed,
            sessionReadSecretStore: settings.envStore,
            preserveChildGovernorOnSafetyLift: preserveChildGovernorOnSafetyLift
        )
    }

    /// The persisted safety snapshot is installed before startup composition.
    /// A locked attach intentionally has no child governor; when all locks are
    /// lifted later, rebuild from current settings and profile rather than
    /// reviving an old runner, lease, or file permission snapshot.
    static func bindSafetyRuntimeSnapshot(
        to bridge: BridgeStore,
        settings: SettingsCenter,
        profile: RuntimeIsolationProfile,
        controlledFieldLoopbackAllowed: Bool = false
    ) {
        settings.onSafetyRuntimeSnapshotChanged = { [weak bridge, weak settings] snapshot in
            guard let bridge else { return }
            let wasLocked = bridge.safetyRuntimeSnapshot.isOptionalModuleLockActive
            bridge.updateSafetyRuntimeSnapshot(snapshot)
            guard wasLocked,
                  !snapshot.isOptionalModuleLockActive,
                  bridge.productionBuiltinToolExecutor != nil,
                  bridge.isSafetyFeatureEnabled(.externalAgents),
                  bridge.isSafetyFeatureEnabled(.childOrchestration),
                  let settings else { return }
            attachCurrentProductionConfiguration(
                to: bridge,
                settings: settings,
                profile: profile,
                childConcurrencySelection: settings.childConcurrencySelection,
                controlledFieldLoopbackAllowed: controlledFieldLoopbackAllowed,
                preserveChildGovernorOnSafetyLift: true
            )
        }
    }

    /// P3-EXT-01/02 authorization boundary (lane 139): the composition root owns
    /// exactly one external-session authorization ledger, and Task Center stays
    /// the only consumer of its read-only runtime projection.
    ///
    /// Launch registers the machine-local SessionStore reader. Task Center can
    /// subsequently register a user-selected Codex/Claude directory through
    /// this same owner. Neither launch nor registration mints a grant or reads
    /// an external directory; the only app-side factory injects the ledger.
    static func makeExternalSessionAuthorization(
        runtimeConsumer: TaskCenterControlConsumer?
    ) -> ExternalSessionAuthorizationComposition {
        ExternalSessionAuthorizationComposition(runtimeConsumer: runtimeConsumer)
    }

    /// Stable identity labels for the machine-local session store source
    /// registered at launch (P3-EXT-01, N-EXT01-REG). These are names, not
    /// policies: every authorization rule lives in the ledger and adapter
    /// already on head, and the local store has exactly one profile.
    static let localSessionStoreSourceID = ExternalSessionSourceID(rawValue: "minis-local-store")
    static let localSessionStoreProfileID = ExternalSessionProfileID(rawValue: "local")

    /// The disposable field profile may inject an isolated Codex home and an
    /// explicit app-server executable. A normal launch never consumes these
    /// values. This registers only the read root and a dormant control config;
    /// Task Center still requires separate grants and a user activation.
    @discardableResult
    static func registerSyntheticExternalCodexIfConfigured(
        composition: ExternalSessionAuthorizationComposition,
        profile: RuntimeIsolationProfile,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ExternalSessionSourceID? {
        guard profile.isDisposable,
              let homePath = environment["MINISCANVAS_EXT_SYNTHETIC_CODEX_HOME"],
              let executablePath = environment["MINISCANVAS_EXT_SYNTHETIC_CODEX_EXECUTABLE"] else {
            return nil
        }
        let homeURL = URL(fileURLWithPath: homePath, isDirectory: true).standardizedFileURL
        let executableURL = URL(fileURLWithPath: executablePath).standardizedFileURL
        // The disposable root may be exposed as /private/var while Foundation
        // canonicalizes an existing parent to /var. Compare the resolved parent
        // itself so a lexical prefix or an alias cannot escape this profile.
        guard homeURL.deletingLastPathComponent().resolvingSymlinksInPath().path
                == profile.rootDirectory.resolvingSymlinksInPath().path,
              executableURL.isFileURL,
              executableURL.path.hasPrefix("/") else { return nil }
        do {
            let sourceID = try composition.registerSelectedReadRoot(
                kind: .codex,
                rootURL: homeURL.appendingPathComponent("sessions", isDirectory: true)
            )
            try composition.configureSyntheticCodexControl(
                sourceID: sourceID,
                executableURL: executableURL,
                homeURL: homeURL,
                runtimeDirectory: profile.rootDirectory.appendingPathComponent(
                    "external-session-runtime", isDirectory: true
                )
            )
            return sourceID
        } catch {
            return nil
        }
    }
}

/// NSApplicationDelegate 适配器：把 willTerminate 转发给 AppLifecycleGuard（F7 P0-4）。
/// SwiftUI App 经 @NSApplicationDelegateAdaptor 注入。
@MainActor
final class MinisCanvasAppDelegate: NSObject, NSApplicationDelegate {
    var onUserQuit: (@MainActor () -> Void)?
    var onSystemTermination: (@MainActor () -> Void)?
    var prepareToolTermination: (@MainActor () -> Task<Void, Never>?)?
    /// 正在进行的工作项数量（回复、后台命令、运行中的定时任务）；大于 0 时退出前先确认。
    var activeWorkCount: (@MainActor () -> Int)?
    private var systemQuitInProgress = false
    private let toolTerminationDrain = AppToolTerminationDrain()
    private var quitAppleEventRouter: AppQuitAppleEventRouter?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let router = AppQuitAppleEventRouter(
            onUserQuit: { [weak self] in
                if let action = self?.onUserQuit { action() }
                else { NSApplication.shared.terminate(nil) }
            },
            onSystemQuit: { [weak self] in
                self?.systemQuitInProgress = true
                self?.onSystemTermination?()
                NSApplication.shared.terminate(nil)
            }
        )
        quitAppleEventRouter = router
        router.install()
        // 上次转写时退出或崩溃留下的音频临时目录（里面是用户音频原文）。
        Task.detached(priority: .utility) { AudioTranscriber.removeLeftoverTemporaryDirectories() }
    }
    /// 正常退出回调（willTerminate 恒在主线程投递，调用侧经 assumeIsolated 回 MainActor）
    var onWillTerminate: (@MainActor () -> Void)?
    /// Only a terminal bootstrap blocker changes macOS's usual window-close
    /// behavior. Normal launches keep running after their last window closes.
    var terminateAfterLastWindowClosed = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        terminateAfterLastWindowClosed
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if toolTerminationDrain.isWaiting { return .terminateLater }
        // 对齐 Claude Code：有进行中的工作时，退出前确认；关机、注销等系统退出不拦。
        if !systemQuitInProgress, let count = activeWorkCount?(), count > 0 {
            NSApplication.shared.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "有 \(count) 项正在进行，确定退出吗？"
            alert.informativeText = "退出会中止正在进行的回复、后台命令和定时任务。取消后可等它们结束再退出。"
            alert.addButton(withTitle: "退出")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        guard let work = prepareToolTermination?() else { return .terminateNow }
        toolTerminationDrain.request(start: { completed in
            Task { await work.value; completed() }
        }, reply: { sender.reply(toApplicationShouldTerminate: true) })
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        ResidentLifecycleController.shared.shutdown()
        quitAppleEventRouter?.uninstall()
        quitAppleEventRouter = nil
        onSystemTermination?()
        onUserQuit = nil
        onSystemTermination = nil
        prepareToolTermination = nil
        activeWorkCount = nil
        MainActor.assumeIsolated {
            onWillTerminate?()
        }
    }
}

// MARK: - 波3-4线：窗口 minSize + 边缘钳制（窗口不能完全拖出可视区，标题栏至少可见）

/// SwiftUI → NSWindow 桥：默认主窗 minSize/边缘钳制；设置 sheet 使用独立尺寸绑定。
/// （SwiftUI WindowGroup 无 minSize 环境、也无「拖出屏幕钳制」API；macOS 14 部署
/// 目标下 AppKit 侧设置 window.minSize + windowDidMove 钳位是最小可行改法。）
struct WindowAccessor: NSViewRepresentable {
    enum Purpose: Equatable {
        case mainWindow
        case settingsSheet
        case passiveWindowAccess
    }

    let purpose: Purpose
    let onWindowReady: (@MainActor (NSWindow) -> Void)?
    let canReceiveUnclaimedCancel: (@MainActor (NSWindow) -> Bool)?
    let onUnclaimedCancel: (@MainActor () -> Void)?

    init(
        purpose: Purpose = .mainWindow,
        canReceiveUnclaimedCancel: (@MainActor (NSWindow) -> Bool)? = nil,
        onUnclaimedCancel: (@MainActor () -> Void)? = nil,
        onWindowReady: (@MainActor (NSWindow) -> Void)? = nil
    ) {
        self.purpose = purpose
        self.onWindowReady = onWindowReady
        self.canReceiveUnclaimedCancel = canReceiveUnclaimedCancel
        self.onUnclaimedCancel = onUnclaimedCancel
    }

    /// 承载视图：强持有钳制 delegate（delegate 弱引用 window，无循环；
    /// 窗口关闭时随视图一起释放）。
    final class AccessorView: NSView {
        var edgeClamp: WindowEdgeClamp?
        var sheetSizing: SettingsSheetWindowSizing?
        var canReceiveUnclaimedCancel: (@MainActor (NSWindow) -> Bool)?
        var onUnclaimedCancel: (@MainActor () -> Void)?

        override var acceptsFirstResponder: Bool { onUnclaimedCancel != nil }

        override func keyDown(with event: NSEvent) {
            let modifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
            if event.keyCode == 53, event.modifierFlags.intersection(modifiers).isEmpty {
                interpretKeyEvents([event])
            } else if event.keyCode == 48,
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                      let window {
                if event.modifierFlags.contains(.shift) {
                    window.selectPreviousKeyView(self)
                } else {
                    window.selectNextKeyView(self)
                }
            } else {
                super.keyDown(with: event)
            }
        }

        override func cancelOperation(_ sender: Any?) {
            guard let window, window.firstResponder === self,
                  canReceiveUnclaimedCancel?(window) == true,
                  let onUnclaimedCancel else {
                super.cancelOperation(sender)
                return
            }
            onUnclaimedCancel()
        }

        func claimUnclaimedCancelResponder() {
            guard let window, window.firstResponder === window,
                  onUnclaimedCancel != nil,
                  canReceiveUnclaimedCancel?(window) == true else { return }
            _ = window.makeFirstResponder(self)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            sheetSizing?.bind(to: window)
            claimUnclaimedCancelResponder()
        }
    }

    func makeNSView(context: Context) -> AccessorView {
        let view = AccessorView()
        view.canReceiveUnclaimedCancel = canReceiveUnclaimedCancel
        view.onUnclaimedCancel = onUnclaimedCancel
        if purpose == .settingsSheet {
            view.sheetSizing = SettingsSheetWindowSizing()
            view.sheetSizing?.bind(to: view.window)
            return view
        }
        // makeNSView 期间 view.window 尚为 nil，延后到下一 runloop 再取
        // （此时视图已在窗口层级中，view.window 可靠非 nil）。
        Task { @MainActor [weak view] in
            guard let view = view, let window = view.window else { return }
            if purpose == .mainWindow {
                let clamp = WindowEdgeClamp()
                clamp.window = window
                WindowEdgeClamp.applyMinimumContentSize(to: window)
                window.delegate = clamp
                view.edgeClamp = clamp
                clamp.clampFrame()   // 启动即钳一次（兜底恢复上次会话的越界位置）
            }
            onWindowReady?(window)
            // Only the mounted local outlet may claim a window with no control
            // responder. An editor, IME, sheet, or focused SwiftUI control keeps
            // its existing key handling and cancellation priority.
            view.claimUnclaimedCancelResponder()
        }
        return view
    }

    func updateNSView(_ nsView: AccessorView, context: Context) {
        nsView.canReceiveUnclaimedCancel = canReceiveUnclaimedCancel
        nsView.onUnclaimedCancel = onUnclaimedCancel
        nsView.claimUnclaimedCancelResponder()
        if purpose == .settingsSheet {
            nsView.sheetSizing?.bind(to: nsView.window)
        }
    }

    static func dismantleNSView(_ nsView: AccessorView, coordinator: ()) {
        nsView.canReceiveUnclaimedCancel = nil
        nsView.onUnclaimedCancel = nil
        if let window = nsView.window, window.firstResponder === nsView {
            _ = window.makeFirstResponder(nil)
        }
    }
}

/// 窗口边缘钳制：拖动时把窗口 frame 钳回「全部屏幕可视区并集」内。
/// 并集 = 跨屏可拖动范围（拖到另一块屏幕不受阻），但不能完全拖出所有屏幕
/// —— 标题栏至少露出一截可抓取（任务红线：至少标题栏可见）。
@MainActor
final class WindowEdgeClamp: NSObject, NSWindowDelegate {
    /// D-APP-21 包含 600pt 主窗。约束内容区而非带标题栏的 frame，
    /// 与 ContentView 的 600×620 下界一致，允许原尺寸矩阵真的进入生产布局。
    static let minimumContentSize = NSSize(
        width: CGFloat(AdaptiveLayoutPolicy.minimumSupportedWidth), height: 620
    )

    static func applyMinimumContentSize(to window: NSWindow) {
        window.contentMinSize = minimumContentSize
    }
    /// 标题栏估算高度（标准 ~28pt）：窗口顶边最低允许位置 = 并集底边 + 该值
    private static let titleBarVisibleInset: CGFloat = 28
    /// 水平方向至少露出一段可抓取宽度，避免整窗滑出屏幕左右边缘
    private static let horizontalSliver: CGFloat = 80

    weak var window: NSWindow?

    func windowDidMove(_ notification: Notification) {
        clampFrame()
    }

    /// 把窗口 frame 钳回可视区并集内；全屏态跳过（全屏 frame 覆盖菜单栏区，会误钳）。
    fileprivate func clampFrame() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        let union = NSScreen.screens.reduce(CGRect.null) { $0.union($1.visibleFrame) }
        guard !union.isNull else { return }
        var frame = window.frame
        // 垂直：标题栏（窗口顶部 strip）至少露出 —— 顶边不低于并集底边 + 标题栏高
        if frame.maxY < union.minY + Self.titleBarVisibleInset {
            frame.origin.y = union.minY + Self.titleBarVisibleInset - frame.height
        }
        if frame.maxY > union.maxY {
            frame.origin.y = union.maxY - frame.height
        }
        // 水平：至少露出一段可抓取区，防整窗滑出左右边缘
        if frame.maxX < union.minX + Self.horizontalSliver {
            frame.origin.x = union.minX + Self.horizontalSliver - frame.width
        }
        if frame.minX > union.maxX - Self.horizontalSliver {
            frame.origin.x = union.maxX - Self.horizontalSliver
        }
        if frame != window.frame {
            window.setFrame(frame, display: false)
        }
    }
}

// MARK: - MinisCanvasApp 入口
//
// I1 集成：画布（主界面）+ 聊天（右侧可折叠侧栏），单窗口。
// E9 深链：miniscanvas:// URL（onOpenURL / 启动参数 --open-url）→ DeepLinkRouter
// → DeepLinkHandler → App 动作；命令面板 quickaction 走同一路径。

/// One source for menu, palette, Composer parser and help. Installation only
/// binds identity; restored approvals are adopted later without execution.
@MainActor
enum ProductionCommandRegistryWiring {
    @discardableResult
    static func bind(bridge: BridgeStore, center: ComposerCommandAdjudicationCenter) -> Bool {
        guard bind(registry: bridge.commandRegistry, chat: bridge.chat, center: center) else {
            return false
        }
        bridge.chat.onRegisteredNonComposerSlashCommand = { [weak bridge] id, args, completion in
            guard let bridge,
                  bridge.chat.registeredComposerCommandRegistry === bridge.commandRegistry,
                  let command = bridge.commandRegistry.command(id: id),
                  command.id == id,
                  !CommandRegistry.composerCommandIDs.contains(id) else { return false }
            bridge.runCommand(id: id, args: args, completion: completion)
            return true
        }
        return true
    }

    @discardableResult
    static func bind(
        registry: CommandRegistry,
        chat: ChatStore,
        center: ComposerCommandAdjudicationCenter
    ) -> Bool {
        guard chat.installComposerCommandRegistry(registry),
              center.installCommandRegistry(registry) else { return false }
        return chat.registeredComposerCommandRegistry === registry
            && center.commandRegistry === registry
    }

    /// The existing non-Canvas workflow runner is reached only after the
    /// Composer command's own pending Policy/Approval transition. The same
    /// binder is used by the App root and its focused consumer tests.
    static func bindWorkflow(bridge: BridgeStore, center: ComposerCommandAdjudicationCenter) {
        center.prepareWorkflow = { [weak bridge] request, snapshot, facts in
            guard let bridge else {
                throw CommandExecutionError.disabled(commandID: "workflow", reason: "命令所属会话不可用")
            }
            return try prepareWorkflow(bridge: bridge, request: request, snapshot: snapshot, facts: facts)
        }
        center.applyApprovedWorkflow = { [weak bridge] context in
            guard let bridge else {
                throw CommandExecutionError.disabled(commandID: "workflow", reason: "命令所属会话不可用")
            }
            try applyWorkflow(bridge: bridge, context: context)
        }
    }

    private static func prepareWorkflow(
        bridge: BridgeStore, request: PendingCommandRequest,
        snapshot: ComposerSubmissionSnapshot, facts: ComposerPolicyFactSource
    ) throws -> ComposerCommandAdjudicationCenter.WorkflowApprovalContext {
        guard request.commandID == "workflow", request.requiresPolicyApproval else {
            throw CommandExecutionError.disabled(commandID: "workflow", reason: "工作流须经本回合批准")
        }
        guard bridge.chat.pendingComposerCommand == request,
              bridge.chat.activeSessionID?.uuidString == snapshot.sessionID,
              bridge.chat.composerWorkspaceID == snapshot.workspaceID,
              bridge.chat.composerPolicyFacts == facts else {
            throw CommandExecutionError.disabled(commandID: "workflow", reason: "当前会话与提交策略不匹配")
        }
        guard let name = request.args["template"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            throw CommandExecutionError.missingArgument(commandID: "workflow", argument: "template")
        }
        let arguments = request.args["args"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = "/workflow \(name)" + (arguments.isEmpty ? "" : " \(arguments)")
        guard let parsed = WorkflowChatController.parse(text), parsed.templateName == name,
              !parsed.templateName.contains("重置"), !parsed.templateName.contains("重新"),
              let template = bridge.workflowChat.workflowStore.template(id: parsed.templateName),
              !bridge.workflowChat.isRunning else {
            throw CommandExecutionError.disabled(commandID: "workflow", reason: "工作流模板或运行器不可用")
        }
        try template.validate()
        var inputs = parsed.inputs
        if let leftover = parsed.leftover,
           let missing = template.requiredInputs.first(where: { inputs[$0] == nil }) {
            inputs[missing] = leftover
        }
        guard template.requiredInputs.allSatisfy({ inputs[$0] != nil }) else {
            throw CommandExecutionError.missingArgument(commandID: "workflow", argument: "args")
        }
        if bridge.workflowChat.providerOverride == nil {
            try bridge.chat.preflightWorkflowProviderSelection()
        }
        return .init(request: request, snapshot: snapshot, facts: facts,
            commandText: text, parsed: parsed, template: template)
    }

    private static func applyWorkflow(
        bridge: BridgeStore, context: ComposerCommandAdjudicationCenter.WorkflowApprovalContext
    ) throws {
        let chat = bridge.chat
        let snapshot = context.snapshot
        let facts = chat.composerPolicyFacts
        guard context.request.commandID == "workflow", context.request.requiresPolicyApproval,
              chat.pendingComposerCommand == context.request,
              facts == context.facts, !facts.revoked, facts.expiresAt > Date(), !facts.leaseID.isEmpty,
              snapshot.workspaceID == chat.composerWorkspaceID,
              snapshot.workspaceID == facts.workspaceID,
              snapshot.policyRevision == facts.revision,
              snapshot.grantEpoch == facts.grantEpoch,
              snapshot.sessionID == chat.activeSessionID?.uuidString,
              WorkflowChatController.parse(context.commandText) == context.parsed,
              bridge.workflowChat.workflowStore.template(id: context.parsed.templateName) == context.template,
              !bridge.workflowChat.isRunning else {
            throw CommandExecutionError.disabled(commandID: "workflow", reason: "原提交策略、会话或模板已改变")
        }
        if bridge.workflowChat.providerOverride == nil {
            try chat.preflightWorkflowProviderSelection()
        }
        bridge.workflowChat.run(
            text: context.commandText,
            chat: chat,
            occurrenceID: context.request.id
        )
        guard bridge.workflowChat.isRunning else {
            throw CommandExecutionError.disabled(commandID: "workflow", reason: "工作流未由规范运行器启动")
        }
    }
}

/// Validates the existing packaged-field bootstrap guard before any profile or
/// durable store is constructed. PERF07, scroll, and Task require the base
/// session journey; media and responsive each launch alone. Exit safety is
/// the sole paired optional producer: it composes the Task approval journey
/// with an owned stdio child. Task cannot share the approval center with the
/// older theme approval fixture.
enum PackageFieldFixtureArguments {
    static func areValid(
        _ arguments: [String], environment: [String: String]
    ) -> Bool {
        let sessionCount = arguments.filter {
            $0 == SessionPackageFieldFixture.activationArgument
        }.count
        let sessionDependentArguments = [
            SessionPackageFieldFixture.performanceArgument,
            ChatScrollAsyncFieldFixture.activationArgument,
            TaskPackageFieldFixture.activationArgument,
            OutputPackageFieldFixture.activationArgument,
            ExitSafetyPackageFieldFixture.activationArgument
        ]
        let independentArguments = [
            MultimediaPackageFieldFixture.activationArgument,
            ResponsiveFieldScenario.activationArgument
        ]
        let sessionDependentCounts = sessionDependentArguments.map { argument in
            arguments.filter { $0 == argument }.count
        }
        let independentCounts = independentArguments.map { argument in
            arguments.filter { $0 == argument }.count
        }
        let optionalCounts = sessionDependentCounts + independentCounts
        let taskCount = arguments.filter {
            $0 == TaskPackageFieldFixture.activationArgument
        }.count
        let exitCount = arguments.filter {
            $0 == ExitSafetyPackageFieldFixture.activationArgument
        }.count
        let hasKnownFieldArgument = sessionCount > 0 || optionalCounts.contains { $0 > 0 }
        guard hasKnownFieldArgument else { return true }
        let profileActivationCount = arguments.filter {
            $0 == RuntimeIsolationProfile.fieldActivationArgument
        }.count
        let needsSession = sessionDependentCounts.contains { $0 > 0 }
        let needsIndependentProfile = independentCounts.contains { $0 > 0 }
        let activeOptionalCount = optionalCounts.filter { $0 > 0 }.count
        let pairedExitSafety = exitCount == 1 && taskCount == 1
            && activeOptionalCount == 2
        let competingApprovalFixture = arguments.contains(
            TaskPackageFieldFixture.activationArgument
        ) && arguments.contains(ThemeApprovalPackageFieldFixture.activationArgument)
        return environment[RuntimeIsolationProfile.fieldActivationMarkerKey] == "1"
            && profileActivationCount == 1
            && sessionCount <= 1 && optionalCounts.allSatisfy { $0 <= 1 }
            && (activeOptionalCount <= 1 || pairedExitSafety)
            && (exitCount == 0 || pairedExitSafety)
            && (!needsSession || sessionCount == 1)
            && (!needsIndependentProfile || sessionCount == 0)
            && !competingApprovalFixture
    }
}

/// Non-secret Root plan. This runs before any store construction in App.init.
/// A dedicated MM process is already deny-by-default at the Core read boundary.
@MainActor
private enum MMOwnedCredentialReadBudgetInstallation {
    private struct Plan: Decodable {
        let schema: String
        let role: String
        let root_authorized_read_budget: Bool
        let root_path: String
        let root_device: UInt64
        let root_inode: UInt64
        let profile_identity: String
        let window_nonce: String
        let max_backing_read_attempts: Int
        let binary_sha256: String
        let not_before_utc: String
        let deadline_utc: String
    }

    private static func physical(_ path: String) -> String? {
        guard let p = realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    static func install(profile: RuntimeIsolationProfile, arguments: [String]) -> Bool {
        guard arguments.contains(DeepSeekMM01FieldLane.activationArgument) else { return true }
        guard KeychainStore.armOwnedMMCredentialReadBudget() else { return false }
        var installed = false
        defer { if !installed { KeychainStore.rejectOwnedMMCredentialReadBudgetPlan() } }
        guard arguments.filter({ $0 == DeepSeekMM01FieldLane.activationArgument }).count == 1,
              arguments.filter({ $0 == DeepSeekEnvironmentPackageFieldBootstrap.activationArgument }).count == 1,
              arguments.filter({ $0 == RuntimeIsolationProfile.fieldActivationArgument }).count == 1,
              profile.mode == .packagedField, profile.isDisposableRootIntact,
              ThemeApprovalPackageFieldFixture.rootIsSafe(profile), profile.keychainLegacyServices.isEmpty,
              let root = physical(profile.rootDirectory.path) else { return false }
        var rootStat = stat()
        guard lstat(root, &rootStat) == 0, rootStat.st_uid == geteuid(),
              rootStat.st_mode & S_IFMT == S_IFDIR, rootStat.st_mode & 0o777 == 0o700 else { return false }
        let path = root + "/mm01-owned-window-read-budget.json"
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == geteuid(), before.st_nlink == 1, before.st_mode & 0o777 == 0o600,
              before.st_size > 0, before.st_size <= 16_384 else { return false }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &bytes, 4096)
            guard n >= 0 else { return false }
            if n == 0 { break }
            data.append(contentsOf: bytes.prefix(n))
            guard data.count <= 16_384 else { return false }
        }
        var after = stat(), named = stat(), rootAfter = stat()
        guard fstat(fd, &after) == 0, lstat(path, &named) == 0, lstat(root, &rootAfter) == 0,
              (before.st_dev, before.st_ino, before.st_size, before.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec)
                == (after.st_dev, after.st_ino, after.st_size, after.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec),
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              after.st_dev == named.st_dev, after.st_ino == named.st_ino,
              named.st_mode & S_IFMT == S_IFREG, named.st_mode & 0o777 == 0o600,
              named.st_uid == geteuid(), named.st_nlink == 1,
              rootAfter.st_dev == rootStat.st_dev, rootAfter.st_ino == rootStat.st_ino,
              rootAfter.st_uid == geteuid(), rootAfter.st_mode & 0o777 == 0o700,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["schema", "role", "root_authorized_read_budget", "root_path",
                "root_device", "root_inode", "profile_identity", "window_nonce", "max_backing_read_attempts",
                "binary_sha256", "not_before_utc", "deadline_utc"]),
              let plan = try? JSONDecoder().decode(Plan.self, from: data),
              plan.schema == "MM01_OWNED_WINDOW_RAM_READ_BUDGET_V1", plan.role == "MM01",
              plan.root_authorized_read_budget, plan.max_backing_read_attempts > 0,
              physical(plan.root_path) == root,
              plan.root_device == UInt64(rootStat.st_dev), plan.root_inode == UInt64(rootStat.st_ino),
              plan.profile_identity == profile.launchIdentity else { return false }
        let formatter = ISO8601DateFormatter()
        guard plan.not_before_utc.count == 20, plan.deadline_utc.count == 20,
              plan.not_before_utc.hasSuffix("Z"), plan.deadline_utc.hasSuffix("Z"),
              let start = formatter.date(from: plan.not_before_utc),
              let end = formatter.date(from: plan.deadline_utc), start <= Date(), Date() < end else { return false }
        var executable = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(getpid(), &executable, 4096) > 0,
              let terminator = executable.firstIndex(of: 0), terminator > 0,
              let executablePath = String(bytes: executable[..<terminator].map { UInt8(bitPattern: $0) }, encoding: .utf8),
              let binary = try? Data(contentsOf: URL(fileURLWithPath: executablePath)),
              SHA256.hash(data: binary).map({ String(format: "%02x", $0) }).joined() == plan.binary_sha256 else { return false }
        installed = KeychainStore.installOwnedMMCredentialReadBudget(
            nonce: plan.window_nonce, limit: plan.max_backing_read_attempts, deadline: end)
        return installed
    }
}

@main
struct MinisCanvasAppMain: App {
    /// F7 P0-4：NSApplicationDelegate 适配器（willTerminate → flushAll + clean-exit 标记）
    @NSApplicationDelegateAdaptor(MinisCanvasAppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var bridge: BridgeStore
    @State private var settingsCenter: SettingsCenter
    /// 流畅度第四轮：主题 token 提供者只建一次（原先根视图每次求值都新建，
    /// 环境值身份变化会让所有读主题的视图重算，且每次构造都注册系统外观观察）。
    @State private var themeProvider: ThemeTokenProvider
    /// AJ-57：共享快捷键 Store（Canvas 与设置窗口用同一实例，避免内存不同步）。
    @State private var shortcutStore: ShortcutStore
    /// 波4：技能管理 Store（设置窗口「技能」分区数据源）。
    @State private var skillsStore: SkillsStore
    /// 波4：定时任务管理 Store（设置窗口「定时任务」分区数据源）。
    @State private var schedulerStore: SchedulerTaskStore
    /// 波4：唯一生产调度器，消费上面的持久化任务 Store。
    @State private var schedulerRuntime: SchedulerTaskRuntime
    /// F7 P0-4：退出/崩溃数据保全守卫（clean-exit 标记 + 启动自动恢复判定）
    @State private var lifecycle: AppLifecycleGuard
    /// AJ-61：设置中心 sheet 开关（工具栏齿轮 / ⌘, / 深链 settings 三入口统一触发同一 state）。
    @State private var isSettingsPresented = false
    @State private var settingsInitialPageID: String?
    @State private var terminationRequest = AppTerminationRequest()
    /// RECOVERY-08：损坏/不兼容数据隔离提示的纯显示态（本进程内点「知道了」后收起
    /// 横幅）。不复制诊断内容：事实源始终是 `bridge.recoveryNotices` 的投影。
    @State private var isRecoveryNoticeDismissed = false
    /// P3-OBS-01/D-OBSB/C：仅显式按钮可运行的隔离健康快照 owner。
    @State private var diagnosticHealthRunController: DiagnosticHealthRunController
    /// P3-OBS-01/D-OBSB：独立本地脱敏诊断包导出 consumer。
    @State private var diagnosticExportController: DiagnosticExportController
    @State private var isDiagnosticExportPresented = false
    @State private var diagnosticSettingsDestination: String?
    /// WindowGroup keeps this task alive while its field loading state changes.
    @State private var productionBootstrapStarted = false
    /// D-ICONB: one passive render observer shared by all production surfaces.
    /// Its snapshot is a semantic appearance sample, not the K0 acceptance ratio.
    @State private var iconRenderTelemetry = MinisIconRenderTelemetry()
    @State private var multimediaFieldReady = false
    @State private var asynchronousFieldError: String?
    /// W5-COMPOSER-CMD-POLICY-WIRE-059：Composer 斜杠命令策略钩子的生产裁决
    /// 中心（组合根唯一接线点；卡片视图经根 overlay 投影终态与回执）。
    @State private var composerCommandAdjudication: ComposerCommandAdjudicationCenter
    @State private var desktopCommandConsumer: N05DesktopCommandConsumer?
    @State private var isDesktopModelPickerPresented = false
    /// P3-EXT-01/02（lane 139）：外部会话授权账本的组合根唯一 owner。`let` 是有意的：
    /// 本进程只有这一个 ledger，视图层不复制、不另建，也不经全局单例访问。
    private let externalSessionAuthorization: ExternalSessionAuthorizationComposition
    /// All durable app services are assembled from this immutable profile.
    let runtimeProfile: RuntimeIsolationProfile
    /// Non-nil only when launch profile validation failed. The app then uses
    /// a disposable blocked profile and renders a safe bootstrap blocker.
    let bootstrapFailure: RuntimeIsolationProfile.BootstrapFailure?
    /// Exposes the installed delegate to non-window composition tests.
    var bootstrapTerminationDelegate: MinisCanvasAppDelegate { appDelegate }
    private let atomicImportRecoveryFailed: Bool
    /// 2026-11-15 第七版：记录内置技能已自动安装到哪个版本（与本次运行档案同一个 UserDefaults）。
    private let builtinSkillMarkerDefaults: UserDefaults
    /// Explicit packaged-field-only executable journey. Nil for every normal launch.
    private let typographyFieldJourney: TypographyPackageFieldJourneyConfiguration?
    /// Exact native-AX diagnostic journey. It is available only to a packaged-field launch.
    private let nativeAccessibilityFieldJourney: NativeAccessibilityPackageFieldJourneyConfiguration?
    /// The session journey presents the ordinary production ContentView with
    /// synthetic initial sessions in the explicitly selected field profile.
    private let sessionFieldJourney: Bool
    private let controlledFieldLoopbackAllowed: Bool
    private let chatScrollFieldFixture: Bool
    private let taskFieldFixture: Bool
    private let outputFieldFixture: Bool
    private let exitSafetyFieldFixture: Bool
    private let multimediaFieldFixture: Bool
    private let sessionFieldFixtureError: String?
    /// D-APP-21 uses the normal ContentView and its live settings consumers.
    private let responsiveFieldScenario: ResponsiveFieldScenario?

    init() {
        SafeModeRelaunch.runRelayIfRequested()
        if !PackageFieldFixtureArguments.areValid(
            CommandLine.arguments, environment: ProcessInfo.processInfo.environment
        ) {
            self.init(
                profile: RuntimeIsolationProfile.blockedProfile(),
                bootstrapFailure: .unexpectedProfileResolution
            )
            return
        }
        switch RuntimeIsolationProfile.launchProfileResolution() {
        case .ready(let profile):
            self.init(profile: profile)
        case .blocked(let failure):
            self.init(
                profile: RuntimeIsolationProfile.blockedProfile(),
                bootstrapFailure: failure
            )
        }
    }

    init(
        profile requestedProfile: RuntimeIsolationProfile,
        bootstrapFailure requestedBootstrapFailure: RuntimeIsolationProfile.BootstrapFailure? = nil
    ) {
        // A bootstrap failure is terminal for this process. Normalize the
        // profile before constructing any durable store so a caller cannot
        // pair a production profile with the blocker and then expose the
        // user's real sessions behind the error surface.
        var profile = Self.failClosedProfile(
            requestedProfile: requestedProfile,
            bootstrapFailure: requestedBootstrapFailure
        )
        var bootstrapFailure = requestedBootstrapFailure
        // No durable store, provider bootstrap, Keychain facade or credential
        // consumer above this point. Missing/invalid MM plan remains blocked.
        if !MMOwnedCredentialReadBudgetInstallation.install(profile: profile, arguments: CommandLine.arguments) {
            profile = RuntimeIsolationProfile.blockedProfile()
            bootstrapFailure = .unexpectedProfileResolution
        }
        var recoveryFailed = false
        if bootstrapFailure == nil {
            do {
                if let formal = try FormalTestIsolationPaths.resolveCurrentProcess(),
                   (profile.mode != .isolatedTest
                    || profile.rootDirectory != formal.rootDirectory
                    || profile.userDefaultsSuiteName != formal.userDefaultsSuiteName
                    || profile.keychainService != formal.keychainService) {
                    // An explicit profile cannot route a native test process
                    // back to production stores or SecItem.
                    profile = RuntimeIsolationProfile.blockedProfile()
                    bootstrapFailure = .unexpectedProfileResolution
                }
            } catch {
                profile = RuntimeIsolationProfile.blockedProfile()
                bootstrapFailure = .unexpectedProfileResolution
            }
        }
        if bootstrapFailure == nil {
            do {
                let layout = try SyncAtomicImport.Layout(
                    sessionDirectory: profile.sessionDirectory, memoryDirectory: profile.memoryDirectory,
                    settingsDirectory: profile.settingsDirectory,
                    skillsRoot: profile.minisCoreDirectory.appendingPathComponent("skills", isDirectory: true),
                    providerConfigurationDirectory: profile.providerConfigurationDirectory,
                    shortcutSuiteName: profile.userDefaultsSuiteName)
                try SyncAtomicImport.recoverBeforeStores(layout: layout)
            } catch {
                recoveryFailed = true
                // Preserve the failed profile byte-for-byte. All services below
                // are composed against the existing disposable blocker profile.
                profile = RuntimeIsolationProfile.blockedProfile()
                bootstrapFailure = .unexpectedProfileResolution
            }
        }
        let deepSeekFieldComposition = DeepSeekEnvironmentPackageFieldBootstrap.prepare(
            profile: profile, bootstrapFailed: bootstrapFailure != nil
        )
        if CommandLine.arguments.contains(DeepSeekEnvironmentPackageFieldBootstrap.journeyArgument),
           deepSeekFieldComposition == nil {
            profile = RuntimeIsolationProfile.blockedProfile()
            bootstrapFailure = .isolatedJourneyCredentialUnavailable
        }
        self.atomicImportRecoveryFailed = recoveryFailed
        self.runtimeProfile = profile
        self.bootstrapFailure = bootstrapFailure
        self.typographyFieldJourney = bootstrapFailure == nil
            ? TypographyPackageFieldJourneyConfiguration.resolveOrFail(profile: profile)
            : nil
        self.nativeAccessibilityFieldJourney = bootstrapFailure == nil
            ? NativeAccessibilityPackageFieldJourneyConfiguration.resolveOrFail(profile: profile)
            : nil
        let sessionJourney = bootstrapFailure == nil
            ? SessionPackageFieldFixture.isRequested(profile: profile)
            : false
        self.sessionFieldJourney = sessionJourney
        self.chatScrollFieldFixture = bootstrapFailure == nil
            ? ChatScrollAsyncFieldFixture.isRequested(
                profile: profile, sessionFieldJourney: sessionJourney
            )
            : false
        let taskField = bootstrapFailure == nil
            ? TaskPackageFieldFixture.isRequested(
                profile: profile, sessionFieldJourney: sessionJourney
            )
            : false
        self.taskFieldFixture = taskField
        self.outputFieldFixture = bootstrapFailure == nil
            ? OutputPackageFieldFixture.isRequested(
                profile: profile, sessionFieldJourney: sessionJourney
            )
            : false
        self.exitSafetyFieldFixture = bootstrapFailure == nil
            ? ExitSafetyPackageFieldFixture.isRequested(
                profile: profile, sessionFieldJourney: sessionJourney,
                taskFieldJourney: taskField
            )
            : false
        self.multimediaFieldFixture = bootstrapFailure == nil
            ? MultimediaPackageFieldFixture.isRequested(profile: profile)
            : false
        self.responsiveFieldScenario = bootstrapFailure == nil
            ? ResponsiveFieldScenario.resolveOrFail(profile: profile)
            : nil
        precondition(
            [typographyFieldJourney != nil, nativeAccessibilityFieldJourney != nil,
             sessionFieldJourney || responsiveFieldScenario != nil
                || multimediaFieldFixture].filter { $0 }.count <= 1,
            "Specialized package field journeys cannot replace the production ContentView"
        )
        // 右键菜单全局 Monitor（修复 SwiftUI hitTest 盲区导致的「右键菜单打不开」，探针实证）。
        if bootstrapFailure == nil {
            FloatingMenuHost.installRightClickMonitor()
        }
        let defaults = profile.makeUserDefaults()
        let store = ShortcutStore(defaults: defaults, recoverySuiteName: profile.userDefaultsSuiteName)
        let providerReadinessStore = ProviderReadinessStore(
            directory: profile.providerConfigurationDirectory
        )
        let mm01Requested = deepSeekFieldComposition?.prepareMM01() == true
        let keychain = deepSeekFieldComposition?.keychain ?? (bootstrapFailure == nil && profile.mode == .production
            ? profile.makeProductionKeychainStore()
            : profile.makeKeychainStore())
        // ChatGPT account sign-in shares the app's Keychain; the provider and readiness
        // probes fetch the live access token from this session.
        ChatGPTAccountSessions.install(ChatGPTAccountSession(keychain: keychain))
        let logManager = profile.makeLogManager()
        // Explicit disposable field fixture only, before sharing this logger with any consumer.
        // Existing file bytes are established by a normal append; synthetic severity samples
        // then enter the same live process ring with file persistence temporarily disabled.
        if bootstrapFailure == nil, profile.mode == .packagedField,
           ProcessInfo.processInfo.environment["MINISCANVAS_FIELD_LOG_LEVEL_SAMPLES"] == "1" {
            do {
                try profile.validateDisposableRootIdentity()
                let previousLevel = logManager.minimumLevel
                let previousFileLogging = logManager.isFileLoggingEnabled
                logManager.minimumLevel = .debug
                logManager.isFileLoggingEnabled = true
                logManager.info("owned field log baseline", category: "OwnedFieldLogs",
                                eventID: "field.logs.baseline")
                logManager.isFileLoggingEnabled = false
                for group in 1...12 {
                    logManager.debug("owned debug sample \(group)", category: "OwnedFieldLogs",
                                     eventID: "field.logs.debug")
                    logManager.info("owned info sample \(group)", category: "OwnedFieldLogs",
                                    eventID: "field.logs.info")
                    logManager.warn("owned warn sample \(group)", category: "OwnedFieldLogs",
                                    eventID: "field.logs.warn")
                    logManager.error("owned error sample \(group)", category: "OwnedFieldLogs",
                                     eventID: "field.logs.error")
                }
                logManager.isFileLoggingEnabled = previousFileLogging
                logManager.minimumLevel = previousLevel
            } catch {
                // No sample and no logger write on refused owned-root identity.
                print("OWNED_FIELD_LOG_SAMPLES_REFUSED")
            }
        }
        // P3-EXT-01 (N-EXT01-REG): the canonical session store is built once
        // here and shared by reference — SettingsCenter owns the same instance
        // the external-session read-side adapter will project. There is no
        // second store behind the registration.
        let sessionStore = SessionStore(directory: profile.sessionDirectory)
        var sessionFieldPreparationError: String?
        if sessionFieldJourney {
            do {
                try SessionPackageFieldFixture.prepare(
                    profile: profile, store: sessionStore,
                    arguments: CommandLine.arguments
                )
            } catch {
                sessionFieldPreparationError = UserFacingErrorText.describe(error)
            }
        }
        let journeyReadinessTransport = DeepSeekEnvironmentPackageFieldBootstrap.journeyReadinessTransport(
            for: deepSeekFieldComposition)
        let ordinaryReadinessTransport = ProviderReadinessTransportComposition.make(
            profile: profile,
            sessionFieldJourney: sessionFieldJourney,
            sessionFieldPreparationSucceeded: bootstrapFailure == nil
                && sessionFieldPreparationError == nil
        )
        let sessionBadgeStore = SessionBadgeStore(directory: profile.minisCanvasDirectory)
        let workflowStore = WorkflowStore.startForAppBootstrap(
            storeDirectory: profile.minisCanvasDirectory.appendingPathComponent("Workflows", isDirectory: true)
        )
        let settings = ProductionDomainAssembly.makeSettings(
            profile: profile, keychain: keychain, sessionStore: sessionStore,
            sessionBadgeStore: sessionBadgeStore, logManager: logManager,
            store: store, readinessTransport: (mm01Requested ? deepSeekFieldComposition?.mm01ReadinessTransport : nil) ?? journeyReadinessTransport ?? ordinaryReadinessTransport,
            providerReadinessStore: providerReadinessStore,
            fieldEnvironmentStore: deepSeekFieldComposition?.environmentStore
        )
        settings.systemNotifications = SystemNotificationController(
            defaults: defaults, canUseSystemNotifications: profile.mode == .production)
        settings.residentLifecycle = .shared
        responsiveFieldScenario?.apply(to: settings, defaults: defaults)
        // User-initiated built-in memory producers start enabled. The
        // composition owner inserts only missing grants, preserving explicit
        // revocations; external sources remain disabled until user-enabled.
        if bootstrapFailure == nil {
            do {
                _ = try settings.provisionBuiltInMemoryCandidateSubmissions()
            } catch {
                logManager.error(
                    "SettingsCenter 记忆候选授权接线失败，已保持 fail-closed：\(error)",
                    category: "Memory"
                )
            }
        }
        _settingsCenter = State(initialValue: settings)
        _themeProvider = State(initialValue: ThemeTokenProvider(center: settings))
        _shortcutStore = State(initialValue: store)
        let skillsStore = SkillsStore(

            appStore: settings.skillStore,
            stateFileURL: profile.skillStateURL,
            loadImmediately: false
        )
        _skillsStore = State(initialValue: skillsStore)
        builtinSkillMarkerDefaults = defaults
        let schedulerLedgerURL = profile.isDisposable
            ? profile.minisCanvasDirectory.appendingPathComponent(
                "scheduler-occurrences-v1.json", isDirectory: false
            ) : nil
        let schedulerStore = SchedulerTaskStore(
            defaults: defaults,
            occurrenceLedgerURL: schedulerLedgerURL
        )
        _schedulerStore = State(initialValue: schedulerStore)
        // D-RECOVERY-09：脏标记在进程构造点即写（beginAtLaunch），不等到 .task 首帧；
        // 启动早期崩溃/强退不会再残留上次 clean 标记被误分类为正常退出。
        _lifecycle = State(
            initialValue: AppLifecycleGuard.beginAtLaunch(defaults: defaults)
        )
        let bridge = ProductionDomainAssembly.makeBridge(
            profile: profile, bootstrapFailure: bootstrapFailure, settings: settings,
            store: store, defaults: defaults, skillsStore: skillsStore,
            schedulerStore: schedulerStore, logManager: logManager,
            workflowStore: workflowStore, sessionBadgeStore: sessionBadgeStore,
            sessionStore: sessionStore,
            onPrimaryComposed: {
                _ = deepSeekFieldComposition?.install(
                    settings: settings, actualKeychain: keychain,
                    primaryCompositionSucceeded: true
                )
            }
        )
        deepSeekFieldComposition?.activateJourneyProviders(chat: bridge.chat)
        // MM01 binds once to the canonical session store during activation.
        // Attach that existing store first; the later session-journey branch
        // stays exclusive so a combined request never attaches twice.
        if mm01Requested && sessionFieldPreparationError == nil,
           !bridge.chat.attachPersistence(settings.sessionStore, badgeStore: sessionBadgeStore) {
            sessionFieldPreparationError = "生产会话持久化装配失败；拒绝继续现场旅程"
        }
        if let mm01 = deepSeekFieldComposition?.activateMM01(settings: settings, actualKeychain: keychain, chat: bridge.chat) {
            bridge.mm01FieldLane = mm01
        }
        if CommandLine.arguments.filter({ $0 == DeepSeekMM01FieldLane.activationArgument }).count == 1,
           profile.mode == .packagedField {
            let laneInstalled = bridge.mm01FieldLane.map {
                settings.mm01FieldLane === $0 && bridge.chat.mm01FieldLane === $0
            } ?? false
            _ = MM01CompositionReadyMarker.emit(
                arguments: CommandLine.arguments, mode: profile.mode, pid: getpid(),
                profileIdentity: profile.launchIdentity,
                windowNonce: KeychainStore.ownedMMCredentialReadWindow?.nonce,
                compositionPresent: deepSeekFieldComposition != nil,
                laneInstalled: laneInstalled,
                actionLedgerInstalled: bridge.mm01FieldLane?.requiresOwnedOutboundAudit == true,
                budgetCounts: KeychainStore.ownedMMCredentialReadCounts,
                monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds
            )
        }
        _ = bridge.bindConfirmedSessionDeletionProjection(to: settings)
        _ = ProductionPickerCatalogWiring.bind(
            chat: bridge.chat, center: settings, profile: profile
        )
        if !mm01Requested && sessionFieldJourney && sessionFieldPreparationError == nil,
           !bridge.chat.attachPersistence(sessionStore, badgeStore: sessionBadgeStore) {
            sessionFieldPreparationError = "生产会话持久化装配失败；拒绝继续现场旅程"
        }
        self.sessionFieldFixtureError = sessionFieldPreparationError
        self.controlledFieldLoopbackAllowed = profile.mode == .packagedField
            && sessionFieldJourney
            && bootstrapFailure == nil
            && sessionFieldPreparationError == nil
            && profile.isDisposableRootIntact
        // SKILL-03: a committed settings toggle invalidates the picker
        // projection and refreshes the next request's available catalog. The
        // ChatStore captures its picker/runtime values before each turn, so an
        // inflight request remains bound to its original immutable snapshot.
        skillsStore.onEnablementChanged = { [weak bridge] in
            bridge?.chat.refreshPickerCatalogInBackground()
        }
        // Bind the live settings directory before scheduler preview/confirmation
        // can ask for a provider credential revision. The closure returns only
        // opaque binding metadata; it never crosses a secret into the ledger.
        bridge.chat.providerRecordsSource = { settings.providerRecords }
        bridge.chat.providerCredentialPreflightSource = { [weak settings] recordID, name, revision in
            guard let settings,
                  let record = settings.providerRecords.first(where: {
                      $0.id == recordID && $0.name == name
                  }),
                  record.valueInKeychain,
                  settings.providerCredentialBinding(recordID: recordID)?.revision == revision,
                  case .success(let value) = await settings.providerCredentialReadAsync(named: name),
                  !value.isEmpty else { return false }
            // The async read populates EnvVarStore's in-memory value. Publish
            // that same profile-scoped record used by readiness and chat; no
            // credential bytes enter the Composer's preflight result.
            settings.reloadEnv()
            guard let current = settings.providerRecords.first(where: {
                $0.id == recordID && $0.name == name
            }),
                  current.baseURL == record.baseURL,
                  current.protocolType == record.protocolType,
                  current.modelNames == record.modelNames,
                  settings.providerCredentialBinding(recordID: recordID)?.revision == revision else {
                return false
            }
            return true
        }
        bridge.chat.providerCredentialMetadataSource = { [weak settings] recordID, name in
            guard let settings,
                  let record = settings.providerRecords.first(where: {
                      $0.id == recordID && $0.name == name
                  }),
                  let binding = await settings.providerCredentialBindingAsync(recordID: record.id),
                  binding.credentialName == name else { return nil }
            return binding.revision
        }
        bridge.chat.schedulerCredentialVersionSource = { [weak settings] providerID in
            guard let settings else { return nil }
            if let record = settings.providerRecords.first(where: {
                $0.name.caseInsensitiveCompare(providerID) == .orderedSame
            }) {
                if let binding = settings.providerCredentialBinding(recordID: record.id) {
                    return binding.revision
                }
                // A directly configured record still gets a secret-free
                // identity; the normal SettingsCenter binding path supersedes
                // this fallback.
                return record.value.isEmpty ? nil : "record:\(record.id)"
            }
            let normalized = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let credentialNames: [String]
            switch normalized {
            case "openai", "openairesponses":
                credentialNames = ["OPENAI_API_KEY"]
            case "anthropic":
                credentialNames = ["ANTHROPIC_API_KEY"]
            case "google gemini", "gemini":
                credentialNames = ["GEMINI_API_KEY"]
            case "openrouter":
                credentialNames = ["OPENROUTER_API_KEY"]
            case "deepseek":
                credentialNames = ["HERMES_CUSTOM_DEEPSEEK_API_KEY", "DEEPSEEK_API_KEY"]
            case "dashscope":
                credentialNames = ["HERMES_CUSTOM_QWEN38_API_KEY", "BAILIAN_TOKEN_PLAN_API_KEY", "DASHSCOPE_API_KEY"]
            default:
                credentialNames = []
            }
            for name in credentialNames {
                if let binding = settings.envStore.credentialBinding(name: name) {
                    return binding.revision
                }
            }
            return nil
        }
        _schedulerRuntime = State(
            initialValue: ProductionDomainAssembly.makeSchedulerRuntime(
                store: schedulerStore, bridge: bridge, settings: settings
            )
        )
        // 新建定时任务时从列表选会话：会话列表与当前会话由这里注入，回合号自动取最新。
        SchedulerTaskPrefillInbox.shared.sessionOptions = { [weak bridge] in
            guard let chat = bridge?.chat else { return [] }
            return chat.sessions.map { session in
                let scope = session.projectID.map { MemoryScope(sessionID: session.id.uuidString, projectID: $0) }
                return SchedulerSessionOption(
                    id: session.id, title: session.title, projectID: session.projectID,
                    projectName: session.projectName,
                    userTurnCount: session.messages.filter { $0.role == .user }.count,
                    projectRoot: scope.flatMap { $0.isValid ? chat.trustedProjectRootProvider?($0) : nil })
            }
        }
        SchedulerTaskPrefillInbox.shared.currentSessionID = { [weak bridge] in bridge?.chat.activeSessionID }
        // The same readiness store remains the sole chat readiness fact source.
        bridge.chat.onProviderLaunchSnapshotChanged = { [weak settings] snapshot in
            settings?.updateProviderLaunchSnapshot(snapshot)
        }
        // AJ-40/P3-SET-01：轻量任务实时读取 provider-scoped 辅助模型；
        // 空/无效/与当前会话 Provider 不匹配时由 ChatStore 继承主模型。
        bridge.chat.lightweightModelReferenceSource = {
            settings.settings.general.subModelReference
        }
        // P3 model allowlist: keep the request boundary on ChatStore while
        // reading the same live profile projection used by SettingsView.
        bridge.chat.modelAllowlistProvider = { [weak settings] in
            settings?.availableModelWhitelist ?? []
        }
        settings.onApprovalPolicyChanged = { [weak bridge, weak settings] policy in
            bridge?.updateApprovalPolicy(policy, legacyAutomaticCompatibility:
                settings?.legacyAutomaticApprovalCompatibilityActive == true)
        }
        settings.onComposerPolicyChanged = { [weak bridge] policy in
            bridge?.chat.restoreComposerPolicy(policy)
        }
        ProductionOrchestrationDefaults.bindSafetyRuntimeSnapshot(
            to: bridge,
            settings: settings,
            profile: profile,
            controlledFieldLoopbackAllowed: controlledFieldLoopbackAllowed
        )
        ProductionOrchestrationDefaults.bindChildConcurrencySelection(
            to: bridge,
            settings: settings,
            profile: profile,
            controlledFieldLoopbackAllowed: controlledFieldLoopbackAllowed
        )
        ProductionOrchestrationDefaults.bindFileAccessSettings(
            to: bridge,
            settings: settings,
            profile: profile,
            controlledFieldLoopbackAllowed: controlledFieldLoopbackAllowed
        )
        ProductionOrchestrationDefaults.bindPolicyRuntimeDefaults(
            to: bridge,
            settings: settings,
            profile: profile,
            controlledFieldLoopbackAllowed: controlledFieldLoopbackAllowed
        )
        // 外部会话授权账本由组合根唯一持有。启动时不连接外部来源。
        self.externalSessionAuthorization =
            ProductionOrchestrationDefaults.makeExternalSessionAuthorization(
                runtimeConsumer: bridge.taskCenterControlConsumer
            )
        self.externalSessionAuthorization.configureDirectorySelectionSuggestions(profile: profile)
        self.externalSessionAuthorization.configureMemoryProposalConsumer(
            settings.memoryProposalConsumer
        )
        try? self.externalSessionAuthorization.configureControlledMemoryRuntimeDirectory(
            profile.rootDirectory.appendingPathComponent("external-session-runtime", isDirectory: true)
        )
        // External sources enter only after the user chooses their directory
        // in Task Center. Supplying the production host here creates no
        // adapter, grant, filesystem read or app-server connection at launch.
        self.externalSessionAuthorization.configureExternalSourceRegistration(
            hostID: ProcessInfo.processInfo.hostName
        )
        // P3-EXT-01 (N-EXT01-REG)：把已落头的只读本机存储适配器注册进上述唯一
        // owner——本机既有会话的 list/read/status 由此进入 shipped 路径（Task
        // Center 既有只读投影开始发布快照）。本行不 mint 任何 grant、不启动任何
        // transport：授权前读取照旧 fail-closed，控制半侧仍是适配器终态
        // unsupported 收据（EXT-02 另有 HOLD，不属本线）。
        self.externalSessionAuthorization.registerLocalStoreReadSide(
            store: sessionStore,
            sourceID: ProductionOrchestrationDefaults.localSessionStoreSourceID,
            profileID: ProductionOrchestrationDefaults.localSessionStoreProfileID,
            hostID: ProcessInfo.processInfo.hostName
        )
        _ = ProductionOrchestrationDefaults.registerSyntheticExternalCodexIfConfigured(
            composition: externalSessionAuthorization,
            profile: profile
        )
        bridge.updateSafetyRuntimeSnapshot(settings.safetyRuntimeSnapshot)
        _bridge = State(initialValue: bridge)

        let diagnosticAppState: DiagnosticRuntimeState = bootstrapFailure == nil ? .ready : .degraded
        let diagnosticHealth = DiagnosticHealthRunController(
            profile: profile,
            checker: DiagnosticIsolatedStorageProbe.check,
            localStatusProvider: { [weak settings, weak skillsStore, weak bridge] in
                guard let settings, let skillsStore, let bridge else { return [] }
                var rows: [DiagnosticLocalStatus] = []
                if settings.providerRecords.isEmpty {
                    rows.append(.init(id: "providers", title: "供应商", message: "没有供应商本地状态；未检查凭据或连接。",
                        nextStep: "在环境变量设置中选择供应商；就绪检查须由你另行发起。", settingsPageID: "settings-tab-environment"))
                }
                for (index, record) in settings.providerRecords.enumerated() {
                    let report = settings.providerReadinessReports[record.id]
                    let summary = settings.providerLocalReadinessSummary(for: record)
                    rows.append(.init(id: "provider-\(index)", title: "供应商 \(index + 1)",
                        message: "已有本地状态（非实时检查）：" + summary.message,
                        nextStep: "在供应商设置查看对应名称与状态，必要时明确发起就绪检查。",
                        settingsPageID: "settings-tab-environment", checkedAt: report?.checkedAt))
                }
                let reports = Array(settings.providerReadinessReports.values)
                let reached = reports.filter { $0.reachability.status == .passed }.count
                let unreachable = reports.filter { $0.reachability.status == .failed }.count
                rows.append(.init(id: "network", title: "网络", message: reports.isEmpty
                    ? "未知：没有已有供应商连接检查；未发起网络请求。"
                    : "已有连接检查缓存：通过 \(reached) 项，失败 \(unreachable) 项；不代表当前网络连通。",
                    nextStep: "到供应商设置核对连接地址；需要时明确运行连接检查。", settingsPageID: "settings-tab-environment",
                    checkedAt: reports.map(\.checkedAt).max()))
                let servers = settings.mcpManager.listServers()
                if servers.isEmpty {
                    rows.append(.init(id: "mcp", title: "MCP", message: "未配置服务器；未启动连接或发现工具。",
                        nextStep: "在 MCP 设置查看配置与连接状态。", settingsPageID: "settings-tab-mcp"))
                }
                for (index, server) in servers.enumerated() {
                    let connection: String
                    switch settings.mcpManager.runtimeState(serverID: server.id) {
                    case .connected: connection = "已连接"
                    case .connecting: connection = "连接中"
                    case .disconnected: connection = "未连接"
                    case .failed: connection = "连接失败；请在 MCP 设置查看详情"
                    }
                    let tools = settings.mcpManager.cachedTools(serverID: server.id).count
                    rows.append(.init(id: "mcp-\(index)", title: "MCP 服务器 \(index + 1)",
                        message: "已有运行状态：" + connection + "；已发现工具 \(tools) 个。没有刷新连接。",
                        nextStep: "在 MCP 设置查看服务器名称、最近错误与工具授权，再明确选择测试或重连。",
                        settingsPageID: "settings-tab-mcp"))
                }
                rows.append(.init(id: "skills", title: "技能", message: "已有目录快照：\(skillsStore.localSkillRoots.count) 个本地目录，\(skillsStore.entries.count) 个技能。" + skillsStore.catalogDiagnostics.stableSummary,
                    nextStep: "在技能设置查看目录及拒绝原因；本页不扫描或启用技能。", settingsPageID: "settings-tab-skills"))
                rows.append(.init(id: "storage", title: "存储", message: "只读状态不检测写入能力；隔离目录检查结果见下方。",
                    nextStep: "在存储设置查看会话与备份；隔离临时目录写入测试必须另行确认。", settingsPageID: "settings-tab-storage"))
                let projects = bridge.approvalCenter.permissionProjects?()
                let directories = bridge.approvalCenter.permissionDirectories?()
                rows.append(.init(id: "permissions", title: "权限", message: projects == nil || directories == nil
                    ? "目录授权状态未知。"
                    : "已有授权列表：项目 \(projects?.count ?? 0) 个，目录 \(directories?.count ?? 0) 个。",
                    nextStep: "在权限设置核对目录授权；供应商凭据须由你在对应设置中处理。", settingsPageID: "settings-tab-permissions"))
                return rows
            },
            cachedFailureReportProvider: { [weak settings] in settings?.diagnosticCachedFailures() }
        )
        _diagnosticHealthRunController = State(initialValue: diagnosticHealth)
        let commandAdjudication = ComposerCommandAdjudicationCenter()
        precondition(
            ProductionCommandRegistryWiring.bind(bridge: bridge, center: commandAdjudication),
            "Composer command registry must be bound before submission"
        )
        _composerCommandAdjudication = State(initialValue: commandAdjudication)
        _diagnosticExportController = State(initialValue: DiagnosticExportController(
            // Export only reads a completed, fresh isolated report. It never
            // starts a check; unmeasured modules remain explicitly unknown.
            healthReportProvider: { [weak diagnosticHealth] in
                diagnosticHealth?.reportForExport()
            },
            runtimeSummaryProvider: { [weak bridge] in
                DiagnosticRuntimeSummary(
                    appState: diagnosticAppState,
                    activeSessionPresent: bridge?.chat.activeSessionID != nil,
                    activeSessionStreaming: bridge?.chat.isActiveSessionStreaming ?? false
                )
            }
        ))
        // Only an explicitly requested packaged-field launch may publish this
        // observation. The external launcher and package still need separate
        // verification by the L06 consumer.
        // Publish after the same profile has initialized the actual settings,
        // session, Keychain and bridge stores; this does not assert that the
        // asynchronous bootstrap or any window/AX journey has passed.
        if RuntimeIsolationProfile.fieldWitnessRequested() {
            do {
                try profile.publishFieldWitness(
                    actualKeychainBacking: keychain.backingKind,
                    actualSettingsDirectory: settings.settingsDirectory,
                    actualSessionDirectory: sessionStore.directory
                )
            } catch {
                fputs("FIELD_WITNESS_REFUSED\n", stderr)
                Darwin.exit(EXIT_FAILURE)
            }
        }
        appDelegate.terminateAfterLastWindowClosed = bootstrapFailure != nil
    }

    /// Keep a failed launch on a disposable root even when a caller supplies
    /// an inconsistent production profile alongside a typed bootstrap error.
    /// Durable stores are assembled only after this gate has run.
    nonisolated static func failClosedProfile(
        requestedProfile: RuntimeIsolationProfile,
        bootstrapFailure: RuntimeIsolationProfile.BootstrapFailure?
    ) -> RuntimeIsolationProfile {
        bootstrapFailure == nil
            ? requestedProfile
            : RuntimeIsolationProfile.blockedProfile()
    }

    @MainActor private func runProductionBootstrap() async {
        guard !atomicImportRecoveryFailed, bootstrapFailure == nil,
              typographyFieldJourney == nil, nativeAccessibilityFieldJourney == nil,
              sessionFieldFixtureError == nil,
              !productionBootstrapStarted else { return }
        productionBootstrapStarted = true
        // The same Core skill authority is loaded before any production turn
        // factory or UI catalog refresh can consume its initial projection.
        await settingsCenter.skillStore.waitForInitialLoad()
        guard settingsCenter.skillStore.isInitialLoadComplete, !Task.isCancelled else {
            productionBootstrapStarted = false
            return
        }
        if multimediaFieldFixture {
            guard case nil = bridge.chat.sessionStore else {
                asynchronousFieldError = "多媒体现场启动前会话已经提前装配"
                return
            }
            do {
                // The fixture's nonisolated async producer performs media IO
                // before this same store is attached to the production chat.
                _ = try await MultimediaPackageFieldFixture.prepare(
                    profile: runtimeProfile, store: settingsCenter.sessionStore
                )
                try Task.checkCancellation()
            } catch is CancellationError {
                productionBootstrapStarted = false
                return
            } catch {
                asynchronousFieldError = UserFacingErrorText.describe(error)
                return
            }
        }
        // 波4：启动唯一生产调度器，消费设置页持久化的启用任务。
        ModelShellEnvironment.startSnapshot()
        schedulerRuntime.onCatchUpReserved = { occurrence in
            guard let sessionID = occurrence.targetSessionID else { return }
            _ = settingsCenter.systemNotifications?.record(.init(
                key: "scheduler-catch-up:" + occurrence.id.uuidString,
                category: .tasks, target: .session(sessionID: sessionID.uuidString),
                outcome: .caughtUp
            ))
        }
        do { _ = try BackgroundShellRegistry.shared.recoverInterruptedJobs() }
        catch { ResidentLifecycleController.shared.reportStartupFailure(error) }
        schedulerRuntime.onExecutionActivityChanged = { isRunning in
            ResidentLifecycleController.shared.schedulerExecutionChanged(isRunning: isRunning)
        }
        schedulerRuntime.start()
        ResidentLifecycleController.shared.start(openMainWindow: {
            // 菜单栏“打开 MinisCanvas”：已有主窗口就激活它，不再多开一个窗口。
            if let window = NSApplication.shared.windows.first(where: {
                $0.identifier?.rawValue.hasPrefix("miniscanvas.main") == true
            }) {
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.makeKeyAndOrderFront(nil)
            } else {
                openWindow(id: "miniscanvas.main")
            }
            NSApplication.shared.activate(ignoringOtherApps: true)
        }, onWake: {
            schedulerRuntime.resumeAfterWake()
        }, workload: {
            // Enabled future schedules do not keep an idle computer awake.
            // Wake/start catch-up handles occurrences missed during sleep.
            bridge.chat.hasStreamingTasksForSafety || bridge.hasActiveChildExecutions
        })
        // F7 P0-4：启动 clean-exit 判定（读上次退出状态 → 写脏标记）。
        // 上次干净退出 → 静默自动恢复画布草稿（ComfyUI 工作流持久化语义）；
        // 上次异常退出（崩溃 / kill -9）→ 不自动恢复，走 attachProductionServices
        // 内既有崩溃提示（脏标记保证该提示只在真崩溃时出现，消除误报）。
        let lastExitClean = lifecycle.beginSession()
        let didAutoRestoreCanvas: Bool
        if let canvas = bridge.canvasIfAvailable {
            let startupMutationGeneration = canvas.mutationGeneration
            // R9 卡顿专项：画布草稿磁盘读取（Data(contentsOf:)）移后台线程，
            // 避免启动时主线程同步读草稿卡首帧；解码 + 恢复画布仍在主线程执行。
            let canvasDraftDirectory = runtimeProfile.minisCanvasDirectory
            let preloadedCanvasDraft = await Task.detached(priority: .userInitiated) {
                DraftStore(directory: canvasDraftDirectory).load(key: DraftStore.canvasKey)
            }.value
            didAutoRestoreCanvas = lastExitClean
                && AppLifecycleGuard.autoRestoreCanvasDraft(
                    into: canvas,
                    directory: canvasDraftDirectory,
                    preloadedData: preloadedCanvasDraft,
                    expectedMutationGeneration: startupMutationGeneration
                )
        } else {
            didAutoRestoreCanvas = false
        }
        // 2026-11-15 第七版：内置技能默认启用（每个内置库版本只装一次）。
        skillsStore.installBuiltinSkillsIfNeeded(markerStore: builtinSkillMarkerDefaults)
        // Load the canonical App catalog outside the initial UI frame.
        skillsStore.reloadInBackground()
        let pickerCatalogPrewarm = bridge.chat.pickerCatalogLoader
        Task.detached(priority: .utility) {
            _ = pickerCatalogPrewarm()
        }
        // F7 P0-4：绑定正常退出钩子（willTerminate → flushAll + clean-exit 标记）
        lifecycle.bind(appDelegate: appDelegate, bridge: bridge)

        // F6（P0-3 + 用户实时反馈）：把设置中心 EnvVarStore 接为 Provider
        // 凭据补充源 —— 必须在任何 Provider 构造之前执行。
        // 病根：GUI 启动的 App 进程环境为空（launchctl getenv 全空），
        // 用户在设置「环境变量」页填的 key 只落在 envvars.json；
        // 此前全仓无一处把 store 接进 EnvCredentials → key「存了但不生效」
        // → 百炼 401 Invalid API key。绑定 settingsCenter.envStore 同一实例，
        // 设置页保存后无需重启即生效（闭包读同一内存表）。
        F6EnvStoreSource.bind(store: settingsCenter.envStore)
        let hookDirectory = runtimeProfile.mode == .packagedField
            ? runtimeProfile.settingsDirectory.appendingPathComponent("hooks", isDirectory: true)
            : MinisCore.HookConfigStore.defaultDirectory()
        let hookStore = MinisCore.HookConfigStore(directory: hookDirectory)
        settingsCenter.conversationHookStore = hookStore
        MinisCore.HookRuntime.install(MinisCore.HookRuntime(store: hookStore))
        bridge.chat.credentialBroker.attach(
            center: settingsCenter,
            externalNetworkAllowed: runtimeProfile.allowsExternalNetwork
        )

        // I4：App 启动装配 Agent 引擎 / 会话持久化 / Skill 注入；
        // E8：同时把 AppSettings.agent 组（预算上限/警告阈值）注入会话预算。
        // F6（P1-5）：Agent 四项设置（迭代上限/工具超时/并发上限/fallback）
        // 经 attachProductionServices 注入引擎与执行器。
        // AJ-28：文件访问权限（授权根目录/被拒绝目录）联动注入 ToolExecutor。
        // L2：从同一快照注入 AgentSettings 与 PolicyRuntime defaults，避免
        // 启动组合根在不同读取时刻拼出不一致的生产边界。
        // P3-P1-03(a)：与运行时 re-attach / P3-CHILD-40 re-binding 共用同一
        // 派生函数，杜绝启动/刷新两处手抄参数造成的双源漂移。
        let agentSettings = settingsCenter.settings.agent
        await ProductionOrchestrationDefaults.attachCurrentProductionConfiguration(
            to: bridge,
            settings: settingsCenter,
            profile: runtimeProfile,
            childConcurrencySelection: settingsCenter.childConcurrencySelection,
            controlledFieldLoopbackAllowed: controlledFieldLoopbackAllowed
        ).value
        if multimediaFieldFixture {
            guard let attached = bridge.chat.sessionStore,
                  attached === settingsCenter.sessionStore else {
                asynchronousFieldError = "多媒体现场会话未装配到生产视图"
                return
            }
            multimediaFieldReady = true
        }
        let featureLane: RuntimeIsolationProfile.CanvasFeatureLane = bridge.canvasFeatureLane
        if featureLane == .phase4OptIn, bridge.canvasIfAvailable != nil {
            _ = await bridge.recoverPendingCanvasMediaTasks()
        }
        // 波4：用量统计接线 —— 聊天流式回复的 usage 事件写入设置中心 UsageStore。
        bridge.chat.usageStore = settingsCenter.usageStore
        // F7 P0-4：自动恢复后立即重挂防抖落盘 —— 否则本会话零改动时退出 flush
        // 无 payload 可写，自动恢复的画布会再次丢失。
        if didAutoRestoreCanvas {
            bridge.canvasIfAvailable?.noteGraphChanged()
        }
        // F6（P1-2）：应用设置中心「默认 Provider / 默认模型」到聊天
        // （仅当尚无显式选择时生效；先于档位恢复 —— 显式默认 > 档位默认）。
        bridge.chat.applyDefaultProviderModel(general: settingsCenter.settings.general)
        // E19：恢复持久化的模型速度档位（默认均衡），档位变更回写设置中心。
        // Disposable/isolated profiles must not infer a user Provider
        // from a fresh profile's tier. An explicit profile-local
        // default was already handled above through the readiness gate.
        if !runtimeProfile.isDisposable {
            bridge.chat.restoreSpeedTier(settingsCenter.modelSpeedTier)
        }
        if let notifications = settingsCenter.systemNotifications {
            SystemNotificationAppBindings.bind(notifications, bridge: bridge,
                isSettingsVisible: { isSettingsPresented }, closeSettings: { isSettingsPresented = false })
        }
        bridge.chat.onSpeedTierChanged = { tier in
            settingsCenter.modelSpeedTier = tier
        }
        // AJ-52 / D-SETB：提交成功才发布到会话运行态；写失败回落旧值。
        settingsCenter.bindChatOutputMode(to: bridge.chat)
        // 波4：恢复持久化的人格（启用状态 + 内容），变更回写设置中心。
        let agent = agentSettings
        bridge.chat.restorePersona(agent.persona, enabled: agent.personaEnabled)
        bridge.chat.onPersonaChanged = { persona, enabled in
            settingsCenter.persona = persona ?? .init()
            settingsCenter.personaEnabled = enabled
        }
        let personaChat = bridge.chat
        settingsCenter.onPersonaSettingsChanged = { [weak personaChat] persona, enabled in
            personaChat?.restorePersona(persona, enabled: enabled)
        }
        // F1-01 / F1-09：供应商改名迁移会话绑定；删除前列出仍在使用它的会话。
        settingsCenter.onProviderRenamed = { [weak personaChat] oldName, newName in
            personaChat?.migrateSessionProviderBindings(fromProviderName: oldName, to: newName)
        }
        settingsCenter.providerDependentSessionTitles = { [weak personaChat] name in
            personaChat?.sessionTitlesBound(toProviderName: name) ?? []
        }
        // Saved Composer defaults come from SettingsCenter. The active
        // Composer selection is temporary.
        bridge.chat.restoreComposerPolicy(agent.composerPolicy)
        // D-SETE: SettingsCenter is the sole applied-settings owner. ChatStore
        // captures this exact nullable value at the submission boundary; a
        // failed or uncertain settings transaction stays nil and blocks the
        // turn before draft or transcript mutation.
        bridge.bindProductionEffectiveSettingsSource { [weak settingsCenter] in
            settingsCenter?.bl6EffectiveSettingsSnapshot
        }
        // W5-COMPOSER-CMD-POLICY-WIRE-059：生产接线 ChatStore 的
        // Composer 命令策略钩子（此前全仓仅测试赋值，斜杠命令在
        // 生产里死 pend）。评估读取 ChatStore 同一份不可变事实源；
        // 待批准/终态/回执由 ComposerCommandAdjudicationCenter 持有。
        bridge.chat.onComposerCommandPolicy = { [weak bridge] request, snapshot in
            guard let bridge else { return .reject }
            return composerCommandAdjudication.evaluate(
                request: request,
                snapshot: snapshot,
                facts: bridge.chat.composerPolicyFacts
            )
        }
        composerCommandAdjudication.canReplayIntoComposer = { [weak bridge] in
            guard let bridge else { return false }
            return bridge.chat.draftText
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && bridge.chat.pendingAttachments.isEmpty
        }
        composerCommandAdjudication.replaySubmittedCommand = { [weak bridge] text in
            guard let bridge else { return }
            // 规范重放：经 composer 提交入口重新路由，由 ChatStore
            // 自己的 .execute 分支清 pending 并执行唯一入口。
            bridge.chat.draftText = text
            bridge.chat.submitComposer()
        }
        composerCommandAdjudication.memoryProposalScopeProvider = { [weak bridge] in
            bridge?.chat.activeMemoryScope
        }
        composerCommandAdjudication.submitApprovedMemoryProposal = { [weak bridge] context in
            guard let bridge else {
                throw CommandExecutionError.disabled(commandID: "memory.propose", reason: "命令所属会话不可用")
            }
            return try bridge.submitApprovedComposerMemoryProposal(context)
        }
        composerCommandAdjudication.prepareProviderSelection = { [weak bridge] request, snapshot, facts in
            guard let bridge else {
                throw CommandExecutionError.disabled(commandID: "provider.use", reason: "命令所属会话不可用")
            }
            return try bridge.prepareComposerProviderSelection(request: request, snapshot: snapshot, facts: facts)
        }
        composerCommandAdjudication.applyApprovedProviderSelection = { [weak bridge] context in
            guard let bridge else {
                throw CommandExecutionError.disabled(commandID: "provider.use", reason: "命令所属会话不可用")
            }
            return try bridge.applyApprovedComposerProviderSelection(context)
        }
        composerCommandAdjudication.preparePresentedToolApproval = { [weak bridge] request, snapshot, facts in
            guard let bridge else {
                throw CommandExecutionError.disabled(commandID: "approve", reason: "命令所属会话不可用")
            }
            return try bridge.prepareComposerPresentedToolApproval(request: request, snapshot: snapshot, facts: facts)
        }
        composerCommandAdjudication.applyPresentedToolApproval = { [weak bridge] context in
            guard let bridge else {
                throw CommandExecutionError.disabled(commandID: "approve", reason: "命令所属会话不可用")
            }
            return try bridge.applyComposerPresentedToolApproval(context)
        }
        composerCommandAdjudication.prepareAdditionalDirectory = { [weak bridge] request, snapshot, facts in
            guard let bridge else {
                throw CommandExecutionError.disabled(commandID: "add-dir", reason: "命令所属会话不可用")
            }
            return try bridge.prepareComposerAdditionalDirectory(
                request: request, snapshot: snapshot, facts: facts
            )
        }
        composerCommandAdjudication.applyApprovedAdditionalDirectory = { [weak bridge] context in
            guard let bridge else {
                throw CommandExecutionError.disabled(commandID: "add-dir", reason: "命令所属会话不可用")
            }
            return try bridge.applyApprovedComposerAdditionalDirectory(context)
        }
        ProductionCommandRegistryWiring.bindWorkflow(
            bridge: bridge, center: composerCommandAdjudication
        )
        composerCommandAdjudication.openCanonicalSettings = {
            // AJ-61：与工具栏齿轮 / ⌘, / 深链共用同一设置中心入口。
            isSettingsPresented = true
        }
        composerCommandAdjudication.onPendingTerminalResolution = { [weak bridge] resolution in
            guard let bridge else { return }
            let disposition: ComposerCommandPolicyDecision
            switch resolution.outcome {
            case .approvedExecuted, .handedToCanonicalSettings:
                disposition = .execute
            case .deniedByUser, .expiredUnanswered, .supersededByNewCommand,
                 .rejectedByPolicy(_), .unavailableExecutor(_):
                disposition = .reject
            }
            bridge.chat.resolvePendingComposerCommand(
                requestID: resolution.id,
                disposition: disposition
            )
        }
        let openDiagnostics = { isDiagnosticExportPresented = true }
        composerCommandAdjudication.statusProjection = { [weak bridge] snapshot in
            guard let bridge else { return "会话状态源不可用" }
            if snapshot.sessionID == bridge.chat.activeSessionID?.uuidString {
                openDiagnostics()
            }
            let busy: String = bridge.chat.isActiveSessionStreaming ? "生成中" : "空闲"
            let text: String = "会话：" + busy
            return text + "\n" + bridge.webFetchAvailabilityDescription
        }
        composerCommandAdjudication.boundaryProjection = { [weak bridge] snapshot in
            bridge?.composerBoundaryProjection(for: snapshot)
        }
        composerCommandAdjudication.commandAvailabilityReason = { [weak bridge] id in
            guard let bridge else { return nil }
            return GlobalComposer.commandReadinessReasons(
                registry: bridge.chat.registeredComposerCommandRegistry,
                bridge: bridge
            )[id]
        }
        composerCommandAdjudication.providerProjection = { [weak bridge] snapshot in
            bridge?.composerProviderProjection(for: snapshot)
        }
        let desktop = N05DesktopCommandConsumer(chat: bridge.chat,
            openSettings: { page in
                settingsInitialPageID = page
                isSettingsPresented = true
            },
            openModelPicker: { isDesktopModelPickerPresented = true },
            openContext: { bridge.contextOpenCommandCount &+= 1 },
            openDoctor: openDiagnostics,
            enterPlanMode: { bridge.chat.enterPlanMode(description: $0) },
            redactor: { ChatTranscriptRedactor(store: settingsCenter.envStore) })
        desktop.rejectToolApproval = { [weak bridge] snapshot in
            guard let bridge else {
                throw CommandExecutionError.disabled(commandID: "reject", reason: "命令所属会话不可用")
            }
            return try N05DesktopCommandConsumer.denyPresentedToolApproval(bridge.approvalCenter, snapshot: snapshot)
        }
        desktopCommandConsumer = desktop
        composerCommandAdjudication.desktopCommandAction = { request, snapshot in
            try desktop.execute(request, snapshot: snapshot)
        }
        composerCommandAdjudication.copyReply = { [weak bridge, weak settingsCenter] n, snapshot in
            guard let chat = bridge?.chat, let settingsCenter,
                  chat.activeSessionID?.uuidString == snapshot.sessionID else {
                return "会话已变化，未更改剪贴板。"
            }
            let redactor = ChatTranscriptRedactor(store: settingsCenter.envStore)
            guard let text = SessionMarkdownExport.replyText(nth: n, messages: chat.messages, redactor: redactor) else {
                return "没有倒数第 \(n) 条已完成回复，未更改剪贴板。"
            }
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.setString(text, forType: .string)
                ? "已复制倒数第 \(n) 条回复。" : "复制失败，请重试。"
        }
        composerCommandAdjudication.tasksProjection = { [weak bridge] in
            guard let bridge else { return "任务中心不可用。" }
            bridge.taskCenterOpenIntent = TaskCenterOpenIntent(toolbarOpener: false)
            return "已打开任务中心。"
        }
        composerCommandAdjudication.eventLogger = { [weak settingsCenter] message in
            settingsCenter?.logManager.error(message, category: "ComposerCommand")
        }
        // 启动/重挂恢复：envelope 持久化恢复的 pendingComposerCommand
        // （ChatStore loadComposerCommandState）也必须进入可见裁决层，
        // 不允许重启后回到无人消费的死 pend。
        if let restoredComposerCommand = bridge.chat.pendingComposerCommand {
            composerCommandAdjudication.adoptRestoredPending(
                restoredComposerCommand,
                sessionID: bridge.chat.activeSessionID?.uuidString ?? ""
            )
        }
        // M1：持久记忆注入 —— MemoryInjector（会话过滤）+ memoryEnabled 门禁。
        // 每回合只注入当前 session/project scope 捕获的事实；
        // SettingsCenter 的新增/导入也复用同一 active scope provider。
        settingsCenter.memoryScopeProvider = {
            bridge.chat.activeMemoryScope
        }
        bridge.chat.memoryInjector = MemoryInjector(store: settingsCenter.memoryStore, fileStore: settingsCenter.memoryFileStore)
        bridge.chat.memoryEnabledProvider = { settingsCenter.memoryEnabled }
        bridge.chat.globalInstructionsEnabledProvider = { settingsCenter.globalInstructionsEnabled }
        bridge.chat.backgroundAutoContinueEnabledProvider = { settingsCenter.backgroundAutoContinueEnabled }
        let processMemoryPrincipal = ProcessUIDMemoryPrincipalSource.production
        bridge.chat.memoryTrustedPrincipalProvider = {
            processMemoryPrincipal.trustedPrincipal()
        }
        settingsCenter.memoryTrustedPrincipalProvider = {
            processMemoryPrincipal.trustedPrincipal()
        }
        settingsCenter.memoryOwnerUserIDProvider = {
            processMemoryPrincipal.trustedPrincipal()?.userID
        }
        // Temporary defaults to the current session identity; no auto deletion.
        // R8：对话执行阶段新输入优先级——接线打断开关（生成中发送新消息即中断旧任务）。
        bridge.chat.newMessageInterruptsGeneration = {
            settingsCenter.newMessageInterruptsGeneration
        }
        bridge.chat.providerReadinessPreflight = { name, modelID in
            let requiresDiscovery = ChatStore.chatProviderTypes.contains {
                $0.rawValue.caseInsensitiveCompare(name) == .orderedSame
                    && ChatStore.BuiltinReadinessBinding.route(for: $0) != nil
            }
            if requiresDiscovery {
                let check = settingsCenter.startProviderReadinessAfterSave(forProviderName: name)
                await withTaskCancellationHandler {
                    _ = await check.value
                } onCancel: {
                    check.cancel()
                }
            } else {
                let check = settingsCenter.startProviderModelReadiness(
                    forProviderName: name, modelID: modelID
                )
                await withTaskCancellationHandler {
                    await check.value
                } onCancel: {
                    check.cancel()
                }
            }
        }
        // E9：注册深链 handler（URL / 启动参数 / quickaction 共用执行路径）
        bridge.deepLinkHandler.onOpenSettings = { id in
            settingsInitialPageID = id
            // AJ-61：深链 settings 与工具栏/⌘, 统一走同一 sheet（同一 state）。
            isSettingsPresented = true
        }
        DeepLinkRouter.shared.register { action in
            Task { @MainActor in
                bridge.deepLinkHandler.handle(action)
            }
        }
        // E9：冷启动命令行参数 miniscanvas --open-url <url>（调试/CI 用）
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--open-url"),
           args.indices.contains(idx + 1),
           let url = URL(string: args[idx + 1]) {
            bridge.deepLinkHandler.handleExternal(url: url)
        }
        if chatScrollFieldFixture {
            await ChatScrollAsyncFieldFixture.run(profile: runtimeProfile, chat: bridge.chat)
        }
        if taskFieldFixture {
            guard let attached = bridge.chat.sessionStore,
                  attached === settingsCenter.sessionStore else {
                asynchronousFieldError = "任务现场会话存储与生产视图不一致"
                return
            }
            do {
                if exitSafetyFieldFixture {
                    try await ExitSafetyPackageFieldFixture.run(
                        profile: runtimeProfile, bridge: bridge,
                        sessionStore: settingsCenter.sessionStore
                    )
                } else {
                    try await TaskPackageFieldFixture.run(
                        profile: runtimeProfile, bridge: bridge,
                        sessionStore: settingsCenter.sessionStore
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                asynchronousFieldError = UserFacingErrorText.describe(error)
            }
        }
        if outputFieldFixture {
            guard let attached = bridge.chat.sessionStore,
                  attached === settingsCenter.sessionStore else {
                asynchronousFieldError = "输出现场会话存储与生产视图不一致"
                return
            }
            do {
                try await OutputPackageFieldFixture.run(
                    profile: runtimeProfile, bridge: bridge,
                    sessionFieldJourney: sessionFieldJourney,
                    settingsCenter: settingsCenter
                )
            } catch is CancellationError {
                return
            } catch {
                asynchronousFieldError = UserFacingErrorText.describe(error)
            }
        }
    }

    var body: some Scene {
        WindowGroup("MinisCanvas", id: "miniscanvas.main") {
          ZStack {
            if atomicImportRecoveryFailed {
                VStack(alignment: .leading, spacing: 16) {
                    Text("备份导入恢复未完成").font(.title)
                    Text("数据尚未打开，原始备份和恢复日志已保留。请保留这些文件，完成恢复后再重新打开应用。")
                    Button("退出应用") { NSApplication.shared.terminate(nil) }
                }
                .padding(32)
            } else if let bootstrapFailure {
                RuntimeBootstrapFailureView(failure: bootstrapFailure)
            } else if let fieldFixtureError = sessionFieldFixtureError ?? asynchronousFieldError {
                VStack(alignment: .leading, spacing: 12) {
                    Text("隔离现场准备失败").font(.title)
                    Text(fieldFixtureError)
                    Text("请保留此现场根供诊断；修复后用新的隔离根重试。")
                }
                .padding(32)
            } else if multimediaFieldFixture && !multimediaFieldReady {
                VStack(alignment: .leading, spacing: 12) {
                    ProgressView("正在准备隔离多媒体现场素材")
                    Text("完成实际抽帧、音轨和字幕提取后打开生产会话。")
                }
                .padding(32)
            } else if let typographyFieldJourney {
                TypographyPackageFieldJourneyView(
                    configuration: typographyFieldJourney,
                    bridge: bridge,
                    settingsCenter: settingsCenter,
                    shortcutStore: shortcutStore,
                    skillsStore: skillsStore,
                    schedulerStore: schedulerStore
                )
            } else if let nativeAccessibilityFieldJourney {
                NativeAccessibilityPackageFieldJourneyView(
                    configuration: nativeAccessibilityFieldJourney,
                    bridge: bridge,
                    settingsCenter: settingsCenter
                )
            } else {
                ContentView(bridge: bridge, transcriptEnvStore: settingsCenter.envStore, openSettings: {
                    bridge.runCommand(id: "settings.open")
                })
                .environment(settingsCenter)
                .environment(\.minisOpenSettingsPage) { id in
                    bridge.deepLinkHandler.handle(.openSettings(id: id))
                }
                .environment(\.browserFieldInitialURL,
                             BrowserLocalPackageFieldFixture.initialURL(profile: runtimeProfile))
                .task {
                    _ = await ThemeApprovalPackageFieldFixture.runIfRequested(
                        profile: runtimeProfile, center: bridge.approvalCenter
                    )
                }
                // 077-A（DEV-326）：把组合根唯一 owner 透传给任务中心授权台账卡片。
                // 只传引用，不复制 ledger；视图层无任何本地台账状态。
                .environment(\.externalSessionAuthorizationComposition, externalSessionAuthorization)
                .font(TypographyTokenProvider(center: settingsCenter).body)
                // 波3-4线：取 NSWindow 设 minSize + 边缘钳制（窗口不能完全拖出可视区）
                .background(WindowAccessor(onWindowReady: { window in
                    responsiveFieldScenario?.apply(to: window)
                }))
                // W5-COMPOSER-CMD-POLICY-WIRE-059：Composer 命令裁决/回执卡。
                // 无待裁决命令且无未确认投影时该视图自行渲染为空。
                .overlay(alignment: .bottomTrailing) {
                    ComposerCommandAdjudicationCard(
                        chat: bridge.chat,
                        center: composerCommandAdjudication
                    )
                    .padding(20)
                }
                // RECOVERY-08：生产消费端——读取 bridge 发布的恢复提示投影，把此前
                // 只写不读的隔离事实（provider-runtime 观察日志损坏隔离、任务账本
                // 恢复诊断）以非阻断横幅呈现给主界面用户。无提示时该视图自行渲染
                // 为空；有提示也不拦截启动、不弹窗、不夺焦，用户可收起。
                .overlay(alignment: .top) {
                    VStack(spacing: 8) {
                        if settingsCenter.safeModeEnabled {
                            HStack(spacing: 6) {
                                MinisIconView(.warning, size: 12)
                                Text("安全模式已开启")
                                    .font(.callout.weight(.semibold))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("main-window.safe-mode")
                            .allowsHitTesting(false)
                        }
                        RecoveryNoticeBanner(
                            notices: bridge.recoveryNotices,
                            isDismissed: isRecoveryNoticeDismissed,
                            onDismiss: { isRecoveryNoticeDismissed = true }
                        )
                    }
                    .padding(20)
                }
                .environment(bridge)
                // E13：外观跟随设置（去掉写死 .dark）；nil = 跟随系统。
                .environment(shortcutStore)
                .preferredColorScheme(settingsCenter.colorSchemePreference)
                // E13：主题色实时生效（改设置即变，@Observable 联动）。
                .tint(settingsCenter.effectiveThemeAccentColor)
                // C3-2：两层主题 token（palette → semantic）注入；Provider 无状态，
                // 直接读 settingsCenter 的 @Observable 属性，改主题/外观即刷新。
                .environment(\.themeTokens, themeProvider)
                .environment(\.typographyTokens, TypographyTokenProvider(center: settingsCenter))
                // FONTPARITY-012：机制级字号比例随 token 一起注入，布局预留宽度
                // 通过该环境值消费，不在各表面重复推导 base/14。
                .environment(\.typographyContentScale, TypographyTokenProvider(center: settingsCenter).contentScale)
                // E9：应用已运行时收到 miniscanvas:// URL
                .onOpenURL { url in
                    Task { @MainActor in
                        bridge.deepLinkHandler.handleExternal(url: url)
                    }
                }
                // AJ-61：设置中心改 .sheet 呈现（替代独立设置窗口：全屏空间下不再退全屏；
                // 工具栏齿轮 / ⌘, / 深链 settings 三入口统一触发同一 isSettingsPresented state）。
                .sheet(isPresented: $isDesktopModelPickerPresented) {
                    // Same readiness-backed picker and Apply consumer as the Composer button.
                    ModelPickerPanel(chat: bridge.chat, isPresented: $isDesktopModelPickerPresented)
                }
                .sheet(item: Binding(
                    get: { desktopCommandConsumer?.presentation },
                    set: { desktopCommandConsumer?.presentation = $0 })) { presentation in
                    if let desktopCommandConsumer {
                        N05DesktopCommandPanel(consumer: desktopCommandConsumer, presentation: presentation)
                    }
                }
                .sheet(isPresented: $isSettingsPresented, onDismiss: {
                    settingsInitialPageID = nil
                    settingsCenter.pendingMemorySearchQuery = nil
                }) {
                    SettingsView(center: settingsCenter, shortcutStore: shortcutStore, skillsStore: skillsStore, schedulerStore: schedulerStore, schedulerRuntime: schedulerRuntime, initialPageID: settingsInitialPageID, chatStore: bridge.chat, approvalCenter: bridge.approvalCenter)
                        .observingMinisIconRenders(using: iconRenderTelemetry, scene: .settingsSheet)
                        // F3-01：命令超时只在设置里改；改了立即作用于执行器（下一次命令起生效），不用重启。
                        .onChange(of: settingsCenter.shellCommandTimeoutSeconds) { _, _ in
                            bridge.refreshProductionAgentSettings(settingsCenter.settings.agent)
                        }
                        .environment(\.externalSessionAuthorizationComposition, externalSessionAuthorization)
                        .environment(shortcutStore)
                        .font(TypographyTokenProvider(center: settingsCenter).body)
                        .environment(settingsCenter)
                        // C3-2：设置面板同样注入 token provider（主题 Picker 预览等可引用）。
                        .environment(\.themeTokens, themeProvider)
                        .environment(\.typographyTokens, TypographyTokenProvider(center: settingsCenter))
                        .environment(\.typographyContentScale, TypographyTokenProvider(center: settingsCenter).contentScale)
                        // D-SETTINGS-17（可调整尺寸）：设置入口呈现不得用固定宽高钉死
                        // 面板。原 720×520 固定 frame 使 sheet 尺寸不可调、新增分类/
                        // 内容只会被裁切（现场缺陷行「设置窗口尺寸固定且无扩展余量」）。
                        // 改为弹性 frame：ideal 720×520 保持既有初始尺寸，
                        // min 600×520 允许原合同窄窗；ideal 720×520 仍是宽主窗
                        // 初始姿态。原生 sheet 在窄父窗下按父内容宽度收敛。
                        .frame(minWidth: 600, idealWidth: 720, maxWidth: .infinity,
                               minHeight: 520, idealHeight: 520, maxHeight: .infinity)
                        // 弹性内容布局之外，只为此设置 sheet 开启原生双轴调整。
                        .background(WindowAccessor(purpose: .settingsSheet))
                }
                .sheet(isPresented: $isDiagnosticExportPresented, onDismiss: {
                    if let page = diagnosticSettingsDestination {
                        diagnosticSettingsDestination = nil
                        settingsInitialPageID = page
                        isSettingsPresented = true
                    }
                }) {
                    DiagnosticExportView(
                        controller: diagnosticExportController,
                        healthController: diagnosticHealthRunController,
                        restartInSafeMode: {
                            diagnosticHealthRunController.restartInSafeMode(settings: settingsCenter, requestQuit: requestAppTermination)
                        },
                        openSettings: { page in
                            diagnosticSettingsDestination = page
                            isDiagnosticExportPresented = false
                        }
                    )
                }
                // W5-059：pendingComposerCommand 在窗口存活期内被恢复/替换时
                // （含磁盘 envelope 恢复路径）补挂到裁决层。正常提交流程由
                // onComposerCommandPolicy 接线覆盖；adopt 对同一 request ID 幂等。
                .onChange(of: bridge.chat.pendingComposerCommand?.id) { _, _ in
                    if let pendingComposerCommand = bridge.chat.pendingComposerCommand {
                        composerCommandAdjudication.adoptRestoredPending(
                            pendingComposerCommand,
                            sessionID: bridge.chat.activeSessionID?.uuidString ?? ""
                        )
                    }
                }
                // P3-P1-03(a)：运行中提交的生产 Agent 设置必须真正生效，不要求
                // 重启。数值/开关走就地刷新缝（下一轮生效，进行中的轮次保持
                // 冻结快照）；文件访问边界改的是 executor 身份（allowedRoot 按
                // 设计是不可变 let），复用既有生产组合缝重建；默认 Provider/
                // 模型经 ChatStore 既有守卫重放（显式选择仍然优先于全局默认）。
                .onChange(of: [settingsCenter.maxTokensPerSession, settingsCenter.tokenBudgetUnlimited ? 1 : 0]) { _, _ in
                    bridge.refreshProductionAgentSettings(settingsCenter.settings.agent)
                }
                .onChange(of: [settingsCenter.maxLoopIterations, settingsCenter.loopIterationsUnlimited ? 1 : 0]) { _, _ in
                    bridge.refreshProductionAgentSettings(settingsCenter.settings.agent)
                }
                .onChange(of: settingsCenter.toolTimeoutSeconds) { _, _ in
                    bridge.refreshProductionAgentSettings(settingsCenter.settings.agent)
                }
                .onChange(of: settingsCenter.concurrentToolLimit) { _, _ in
                    bridge.refreshProductionAgentSettings(settingsCenter.settings.agent)
                }
                .onChange(of: settingsCenter.fallbackEnabled) { _, _ in
                    bridge.refreshProductionAgentSettings(settingsCenter.settings.agent)
                }
                .onChange(of: settingsCenter.childModelOverridesEnabled) { _, _ in
                    bridge.refreshProductionAgentSettings(settingsCenter.settings.agent)
                }
                .onChange(of: settingsCenter.childModelThinkingLevelCeiling) { _, _ in
                    bridge.refreshProductionAgentSettings(settingsCenter.settings.agent)
                }
                .onChange(of: settingsCenter.childMutationsEnabled) { _, _ in
                    bridge.refreshProductionAgentSettings(settingsCenter.settings.agent)
                }
                .onChange(of: settingsCenter.browserWriteEnabled) { _, _ in
                    bridge.refreshProductionAgentSettings(settingsCenter.settings.agent)
                }
                .onChange(of: settingsCenter.defaultProviderID) { _, _ in
                    _ = bridge.chat.applyDefaultProviderModel(
                        general: settingsCenter.settings.general
                    )
                }
                .onChange(of: settingsCenter.defaultModelID) { _, _ in
                    _ = bridge.chat.applyDefaultProviderModel(
                        general: settingsCenter.settings.general
                    )
                }
                // 连接检查通过后，演示模式自动切到第一个已就绪的模型。
                .onChange(of: bridge.chat.hasReadyChatModel) { _, ready in
                    if ready { _ = bridge.chat.adoptFirstReadyChatModelIfDemo() }
                }
            }
          }
          .task(id: settingsCenter.systemNotifications?.canDeliverGoalReminders == true
                ? bridge.chat.conversationGoalReminderDates : [:]) {
              guard let notifications = settingsCenter.systemNotifications,
                    notifications.canDeliverGoalReminders else { return }
              await SystemNotificationAppBindings.deliverNextGoalReminder(notifications, chat: bridge.chat)
          }
          .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
              settingsCenter.systemNotifications?.applicationBecameActive()
          }
          .onChange(of: bridge.chat.activeSessionID) { _, _ in
              settingsCenter.systemNotifications?.applicationBecameActive()
          }
          .onChange(of: isSettingsPresented) { _, _ in
              settingsCenter.systemNotifications?.applicationBecameActive()
          }
          .observingMinisIconRenders(using: iconRenderTelemetry, scene: .mainWindow)
          .onAppear {
              appDelegate.onUserQuit = requestAppTermination
              appDelegate.onSystemTermination = {
                  _ = settingsCenter.systemNotifications?.cancelForApplicationExit()
                  terminationRequest.cancelForSystemTermination()
              }
              // 自定义子智能体（.claude/agents）：按当前会话已信任的项目目录读取。
              let subagentChat = bridge.chat
              if subagentChat.externalSkillCatalog == nil {
                  // 外部技能根（~/.claude/skills 等）：只读；确认记录放在 App 技能库目录的旁边。
                  subagentChat.externalSkillCatalog = MinisCore.ExternalSkillCatalog(
                      confirmationsURL: MinisCore.SkillStore.defaultSkillsRoot()
                          .deletingLastPathComponent()
                          .appendingPathComponent("external-skill-confirmations.json"))
              }
              if subagentChat.customSubagentConfirmations == nil {
                  // 项目 .claude/agents 里的子智能体：内容经用户确认后才可用，记录放在技能库目录旁边。
                  subagentChat.customSubagentConfirmations = MinisCore.CustomSubagentConfirmationStore(
                      url: MinisCore.SkillStore.defaultSkillsRoot()
                          .deletingLastPathComponent()
                          .appendingPathComponent("custom-subagent-confirmations.json"))
              }
              // 项目 .mcp.json 的批准记录文件：启动时就建常驻实例，让它从一开始受保护。
              _ = MinisCore.MCPProjectConfigStore.resident(
                  directory: settingsCenter.mcpManager.fileURL.deletingLastPathComponent())
              MinisCore.ExternalSkillReader.install { sessionID in
                  await MainActor.run { subagentChat.externalSkillReadContext(forSession: sessionID) }
              }
              MinisCore.CustomSubagentCatalog.install {
                  // 按发起派发的会话找项目，不看界面上当前打开的会话。
                  let sessionID = MinisCore.AgentExecutionContext.current?.currentConversationID
                  return await MainActor.run { subagentChat.customSubagentDefinitions(forSession: sessionID) }
              }
              appDelegate.activeWorkCount = {
                  var count = 0
                  if bridge.chat.hasStreamingTasksForSafety { count += 1 }
                  if bridge.hasActiveChildExecutions { count += 1 }
                  count += BackgroundShellRegistry.shared.runningCount
                  if ResidentLifecycleController.shared.isSchedulerExecuting { count += 1 }
                  return count
              }
              appDelegate.prepareToolTermination = {
                  let notificationDrain = settingsCenter.systemNotifications?.cancelForApplicationExit()
                  let toolDrain = bridge.prepareProductionToolsForApplicationExit()
                  let hookRuntime = MinisCore.HookRuntime.installed
                  guard notificationDrain != nil || toolDrain != nil || BackgroundShellRegistry.shared.hasRunning
                        || hookRuntime?.knownSessionIDs().isEmpty == false else { return nil }
                  return Task {
                      // 对齐 Claude Code：退出时同步等待 SessionEnd 钩子，最多约 5 秒。
                      await hookRuntime?.fireSessionEndAtExit(timeout: 5)
                      _ = await notificationDrain?.value
                      _ = await toolDrain?.value
                      _ = await BackgroundShellRegistry.shared.terminateAll(reason: .applicationExit, waitSeconds: 3)
                  }
              }
          }
          .task {
              await runProductionBootstrap()
          }
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            AppTerminationCommands(onQuit: requestAppTermination)
            // 应用菜单：设置中心（D5，Cmd+,）
            CommandGroup(replacing: .appSettings) {
                if let command = AppCommandMenuBuilder.command(
                    id: "settings.open", registry: bridge.commandRegistry,
                    display: bridge.paletteDisplay
                ) {
                    Button(command.title) {
                        bridge.runCommand(id: command.id)
                    }
                    // AJ-57：绑定读 Store（默认 ⌘,）
                    .shortcutKey(bridge.shortcutStore.binding(for: .openSettings))
                    .help(command.disabledReason ?? command.title)
                    .disabled(bootstrapFailure != nil || !command.isEnabled)
                }
            }
            CommandGroup(after: .appSettings) {
                Button("查看快捷键…") {
                    bridge.deepLinkHandler.handle(.openSettings(id: "快捷键"))
                }
                .shortcutKey(bridge.shortcutStore.binding(for: .openShortcutReference))
                .disabled(bootstrapFailure != nil)
            }
            // 文件菜单：新建会话取代新建窗口
            CommandGroup(replacing: .newItem) {
                if let command = AppCommandMenuBuilder.command(
                    id: "session.new", registry: bridge.commandRegistry,
                    display: bridge.paletteDisplay
                ) {
                    Button(command.title) {
                        bridge.runCommand(id: command.id)
                    }
                    // AJ-57：绑定读 Store（默认 ⌘N）
                    .shortcutKey(bridge.shortcutStore.binding(for: .newSession))
                    .help(command.disabledReason ?? "新建聊天会话")
                    .disabled(bootstrapFailure != nil || !command.isEnabled)
                }
            }
            // DEV-FIX-202: CommandMenu("会话") extracted into independent Commands type.
            SessionCommands(bridge: bridge, bootstrapFailure: bootstrapFailure)

            // C3-1 命令菜单：注册制生成（与命令面板同一 CommandRegistry 数据源）
            // PKG APPLY-K (R22GATE8)：`CommandMenu("命令"){ … }` 整体抽出为独立具名
            // Commands 成员 RegistryCommandMenu（判别对照：已收敛的 SessionCommands），
            // 使 .commands 联合成为四个独立具名 Commands 成员的合并。菜单内容逐条不变。
            RegistryCommandMenu(
                bridge: bridge,
                bootstrapFailure: bootstrapFailure,
                registryCommandSections: registryCommandSections,
                isDiagnosticExportPresented: $isDiagnosticExportPresented
            )
        }

    }

    /// PKG APPLY-I STEP B：`AppCommandMenuBuilder.sections(...)` 的 hoist 结果，
    private func requestAppTermination() {
        terminationRequest.request {
            let hasPendingApproval = bridge.approvalCenter.pendingRequest != nil
            let hasSettingsSheet = isSettingsPresented
            let hasDiagnosticSheet = isDiagnosticExportPresented
            // Reject the same production waiter before asking Cocoa to quit;
            // willTerminate is too late when Cocoa blocks a modal sheet.
            if hasPendingApproval { bridge.approvalCenter.rejectForApplicationExit() }
            isSettingsPresented = false
            diagnosticSettingsDestination = nil
            isDiagnosticExportPresented = false
            return hasPendingApproval || hasSettingsSheet || hasDiagnosticSheet
        }
    }

    /// 显式返回类型 `[PaletteSection]`，使 `.commands` 联合表达式内不再内联该调用。
    private var registryCommandSections: [PaletteSection] {
        AppCommandMenuBuilder.sections(
            registry: bridge.commandRegistry,
            display: bridge.paletteDisplay
        )
    }
}

/// PKG APPLY-I STEP B（换轴，单变量 2）：「命令」菜单单条按钮的**顶层具体类型**。
/// 与替换掉的 `commandMenuButton` 助手段逐字等价（同一 `runCommand` 动作、同一
/// `Label(command.title, systemImage: command.icon)`、同一 help 文案、同一加速键
/// modifier、同一 disabled 判定）；唯一区别是 `.commands` 联合表达式现在引用一个
/// 具名类型，而不是就地展开 `some View` 不透明链，从而使 type-check 规模实际变小。
private struct AppCommandsMenuItem: View {
    let command: PaletteCommand
    let bridge: BridgeStore
    let disabled: Bool

    var body: some View {
        Button {
            if command.id == "ui.chat.stop" {
                bridge.runCommand(id: command.id, args: [
                    "session_id": bridge.chat.activeSessionID?.uuidString ?? "",
                    "return_queued_to_draft": "true"
                ])
            } else {
                bridge.activateCommandRow(id: command.id)
            }
        } label: {
            Label(command.title, systemImage: command.icon)
        }
        .help(command.disabledReason ?? command.shortcut.map { "快捷键 \($0)" } ?? command.title)
        .modifier(AppCommandsMenuShortcutModifier(commandID: command.id, bridge: bridge))
        .disabled(disabled || !command.isEnabled)
    }
}

/// 与既有嵌套 `CommandMenuShortcutModifier` 等价的顶层私有类型（仅位置改变，
/// 逻辑逐字保留：对已在命令目录映射且没有独立菜单注册的动作挂可配置加速键。
/// （受 JS-57 约束：⌘N/⌘, 已在「文件」「应用」菜单组注册为加速键，此处
/// 若重复挂载会触发 duplicate-accelerator 冲突，故仅对未独立注册的
/// ui.pipeline(⌘P) / ui.canvas.run(⌘R) / ui.chat.stop(⌘.) 挂实时可配置加速键。
/// Approval shortcuts belong to the rendered approval sheet, whose actions
/// retain the original waiter and confirmation step.
private struct AppCommandsMenuShortcutModifier: ViewModifier {
    let commandID: String
    let bridge: BridgeStore

    func body(content: Content) -> some View {
        if let action = AppCommandCatalog.shortcutAction(forCommandID: commandID),
           [.createPipeline, .runCanvas, .stopGeneration]
            .contains(action) {
            content.shortcutKey(bridge.shortcutStore.binding(for: action))
        } else {
            content
        }
    }
}

// DEV-FIX-202: Extracted CommandMenu("会话") into an independent Commands struct so the
// Button previously at line 1056 leaves the original .commands { … } joint type-solution
// expression tree entirely.  Semantics unchanged: same menu placement, labels, shortcuts,
// disabled states, actions, and conditional structure.
private struct SessionCommands: Commands {
    let bridge: BridgeStore
    let bootstrapFailure: RuntimeIsolationProfile.BootstrapFailure?

    var body: some Commands {
        CommandMenu("会话") {
            if let command = AppCommandMenuBuilder.command(
                id: AppCommandCatalog.commandPaletteID, registry: bridge.commandRegistry,
                display: bridge.paletteDisplay
            ) {
                Button(command.title) { bridge.runCommand(id: command.id) }
                    .shortcutKey(bridge.shortcutStore.binding(for: .commandPalette))
                    .help(command.disabledReason ?? "\(command.title)（\(bridge.shortcutStore.binding(for: .commandPalette).displayString)）")
                    .disabled(bootstrapFailure != nil || !command.isEnabled)
            }

            Divider()

            if let newSessionCommand = AppCommandMenuBuilder.command(
                id: "session.new", registry: bridge.commandRegistry,
                display: bridge.paletteDisplay
            ) {
                Button(newSessionCommand.title) {
                    bridge.runCommand(id: newSessionCommand.id)
                }
                .shortcutKey(bridge.shortcutStore.binding(for: .newSession))
                .help(newSessionCommand.disabledReason ?? "\(newSessionCommand.title)（\(bridge.shortcutStore.binding(for: .newSession).displayString)）")
                .disabled(bootstrapFailure != nil || !newSessionCommand.isEnabled)
            }

            if bridge.chat.isActiveSessionStreaming {
                if let stopCommand = AppCommandMenuBuilder.command(
                    id: "ui.chat.stop", registry: bridge.commandRegistry,
                    display: bridge.paletteDisplay
                ) {
                    Button(stopCommand.title, action: handleSessionCommandTap)
                        .help(stopCommand.disabledReason ?? stopCommand.title)
                        .disabled(bootstrapFailure != nil || !stopCommand.isEnabled)
                }
            } else {
                Button("发送消息", action: handleSessionCommandTap)
                    .disabled(
                        bootstrapFailure != nil
                            || !bridge.chat.hasNonBlankDraft
                    )
            }
        }
    }

    /// 「会话」菜单「停止生成 / 发送消息」按钮的动作体。
    /// 条件在点击时刻求值：流式中停止，否则提交输入框。
    private func handleSessionCommandTap() {
        if bridge.chat.isActiveSessionStreaming {
            // The registry runner is asynchronous; bind this click to its
            // current session using the existing stop consumer's argument.
            let sessionID = bridge.chat.activeSessionID?.uuidString ?? ""
            bridge.runCommand(id: "ui.chat.stop", args: ["session_id": sessionID, "return_queued_to_draft": "true"])
        } else {
            bridge.chat.submitComposer()
        }
    }
}

// PKG APPLY-K (R22GATE8, 单变量)：「命令」菜单从 `.commands` result-builder 联合中
// 整体抽出为顶层具名 Commands 成员（与 SessionCommands 同一已收敛模式；依据
// PKG-MAIN_APPLY-J_R22DIAG_attribution.raw.log 段 F/G 的联合类型归因）。
// 搬入的 CommandMenu 内容——标题、顺序、help 文案、disabled 判定、Divider、
// ForEach(registryCommandSections) 数据源、AppCommandsMenuItem 具体 item 类型与
// 显式类型标注的闭包参数——逐条与搬迁前等价，未增删改。
// isDiagnosticExportPresented 以 @Binding 传入，使按钮动作体仍逐字为
// `isDiagnosticExportPresented = true`；registryCommandSections 仍由 App 侧同名
// 计算属性生产（FIX-202/STEP B 生产逻辑未动），此处只消费其结果。
private struct RegistryCommandMenu: Commands {
    let bridge: BridgeStore
    let bootstrapFailure: RuntimeIsolationProfile.BootstrapFailure?
    let registryCommandSections: [PaletteSection]
    @Binding var isDiagnosticExportPresented: Bool

    var body: some Commands {
        CommandMenu("命令") {
            Button("导出脱敏诊断包…") {
                isDiagnosticExportPresented = true
            }
            .help("选择本地位置导出不含凭据和完整对话的诊断包")
            .disabled(bootstrapFailure != nil)

            Divider()

            // PKG APPLY-I STEP B（换轴）：sections 计算 hoist 到显式类型成员，
            // ForEach 只消费一个具名值；单条按钮改为顶层具体类型。
            ForEach(registryCommandSections) { (section: PaletteSection) in
                Section(section.title) {
                    ForEach(section.commands) { (command: PaletteCommand) in
                        AppCommandsMenuItem(
                            command: command,
                            bridge: bridge,
                            disabled: bootstrapFailure != nil
                        )
                    }
                }
            }
        }
    }
}

/// Safe launch-time blocker. It intentionally exposes only a stable code and
/// remediation guidance; profile paths, environment values, and credentials
/// never enter the view hierarchy.
private struct RuntimeBootstrapFailureView: View {
    let failure: RuntimeIsolationProfile.BootstrapFailure

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("无法安全启动")
                .font(.title2.weight(.semibold))
            Text(failure.userMessage)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text(failure.safeCode)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("请移除无效的隔离启动参数或环境配置后重新打开应用。应用未读取用户数据或凭据。")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("退出应用") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(32)
        .frame(minWidth: 520, minHeight: 300)
    }
}

/// RECOVERY-08 消费端横幅：渲染 `BridgeStore.recoveryNotices` 发布的恢复提示。
/// 只复用本文件既有提示词汇（`.callout`/`.secondary` 文本、普通 `Button`、既有
/// `regularMaterial` 圆角容器）——无新颜色、无新间距体系、无新调色板（A7-A）。
/// 无提示时自行渲染为空：绝不阻断启动、不模态抢焦；用户点「知道了」即本进程
/// 收起（仅显示态；隔离事实源仍在 `bridge.recoveryNotices`，不在此复制）。
private struct RecoveryNoticeBanner: View {
    let notices: [String]
    let isDismissed: Bool
    let onDismiss: () -> Void

    var body: some View {
        if !isDismissed && !notices.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("数据恢复提示")
                    .font(.callout.weight(.semibold))
                ForEach(notices, id: \.self) { notice in
                    Text(notice)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button("知道了", action: onDismiss)
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// A genuine user Quit/Cmd-Q action. The tool still presses this named item
/// while approval is visible; only the product prepares its own presentation.
private struct AppTerminationCommands: Commands {
    let onQuit: @MainActor () -> Void

    var body: some Commands {
        CommandGroup(replacing: .appTermination) {
            Button("退出MinisCanvas", action: onQuit)
                .keyboardShortcut("q", modifiers: .command)
        }
    }
}
