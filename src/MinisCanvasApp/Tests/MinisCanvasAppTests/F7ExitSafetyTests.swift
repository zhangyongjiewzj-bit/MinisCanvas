import Testing
import Foundation
import CanvasCore
import MinisCore
@testable import MinisCanvasApp

// MARK: - F7 退出/崩溃数据保全（P0-4 clean-exit 标记 + 退出 flush + 启动自动恢复；
//         2026-08-06 工作板块移除：P1-3 文档未保存修改保护随 DocumentStore 一并删除）

/// 测试用 UserDefaults 套件（隔离 .standard，defer 清理）
private func makeTestDefaults() -> (UserDefaults, String) {
    let suite = "f7-tests-\(UUID().uuidString)"
    return (UserDefaults(suiteName: suite)!, suite)
}

/// 临时草稿存储：临时目录 + 300ms 防抖（保证退出 flush 时「仍在防抖窗口内」，
/// 断言 flushAll 兜底语义；窗口 ≫ 单测耗时，无时序竞态）
private func makeDraftStore() -> (DraftStore, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("f7-tests-\(UUID().uuidString)", isDirectory: true)
    let store = DraftStore(directory: dir)
    store.debounceInterval = .milliseconds(300)
    return (store, dir)
}

// MARK: - P0-4 clean-exit 标记（AppLifecycleGuard）

@Suite("F7 P0-4 clean-exit 标记与退出 flush")
@MainActor
struct F7CleanExitTests {

    @Test func firstLaunchWithoutKeyTreatedAsCleanThenDirtyFlagWritten() {
        let (defaults, suite) = makeTestDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let guard1 = AppLifecycleGuard(defaults: defaults)

        // 键不存在（首次安装/升级）→ 按干净处理（不弹误报崩溃提示）
        #expect(guard1.beginSession() == true)
        // beginSession 后立即写脏标记：正常退出才重写 true
        #expect(defaults.bool(forKey: AppLifecycleGuard.cleanExitDefaultsKey) == false)
    }

    @Test func dirtyFlagFromPriorCrashGatesRecoveryPrompt() {
        let (defaults, suite) = makeTestDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: AppLifecycleGuard.cleanExitDefaultsKey)   // 上次崩溃残留脏标记

        let guard1 = AppLifecycleGuard(defaults: defaults)
        // 上次异常退出 → beginSession 返回 false → 崩溃恢复提示仅此路径触发（消除误报）
        #expect(guard1.beginSession() == false)
        #expect(guard1.lastExitWasClean == false)
    }

    @Test func cleanFlagFromPriorNormalExitAllowsSilentAutoRestore() {
        let (defaults, suite) = makeTestDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AppLifecycleGuard.cleanExitDefaultsKey)   // 上次正常退出

        let guard1 = AppLifecycleGuard(defaults: defaults)
        #expect(guard1.beginSession() == true)
    }

    @Test func beginSessionIsIdempotentPerProcess() {
        let (defaults, suite) = makeTestDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let guard1 = AppLifecycleGuard(defaults: defaults)

        #expect(guard1.beginSession() == true)
        // 窗口重建导致 .task 重跑：重复调用返回首次结果，不重复判定
        defaults.set(false, forKey: AppLifecycleGuard.cleanExitDefaultsKey)
        #expect(guard1.beginSession() == true)
    }

    /// D-RECOVERY-09 缺口回归：脏标记必须随进程构造点（beginAtLaunch）即刻写入，
    /// 而不是等到 SwiftUI .task（首帧之后）。启动早期崩溃/强退——willTerminate 与
    /// .task 都没执行——下次启动绝不能把该失败分类成正常 clean exit。
    @Test func beginAtLaunchMarksDirtyBeforeFirstFrameAndSurvivesEarlyCrash() {
        let (defaults, suite) = makeTestDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        // —— 进程 A：正常退出 → 磁盘标记为 clean ——
        let lifecycleA = AppLifecycleGuard(defaults: defaults)
        #expect(lifecycleA.beginSession() == true)
        lifecycleA.handleWillTerminate(bridge: nil)   // 无 bridge 也按 flush 成功处理
        #expect(defaults.bool(forKey: AppLifecycleGuard.cleanExitDefaultsKey) == true)

        // —— 进程 B：仅完成构造（App init 时点），首帧 .task 未跑、随后崩溃强退 ——
        let lifecycleB = AppLifecycleGuard.beginAtLaunch(defaults: defaults)
        // beginAtLaunch 返回前脏标记必须已落：不存在「上次 clean」裸露窗口
        #expect(
            defaults.bool(forKey: AppLifecycleGuard.cleanExitDefaultsKey) == false,
            "process start must dirty the flag at construction, before any first-frame work"
        )
        // B 读到的是 A 的真实分类（clean），自身退出状态不受 beginSession 消费点影响
        #expect(lifecycleB.lastExitWasClean == true)
        // 进程 B 崩溃：不调用 handleWillTerminate

        // —— 进程 C：下次启动必须把 B 的启动即死记成异常退出，不写成 clean ——
        let lifecycleC = AppLifecycleGuard(defaults: defaults)
        #expect(lifecycleC.beginSession() == false)
        #expect(lifecycleC.lastExitWasClean == false)
    }

    @Test func willTerminateFlushesAllDebouncedDraftsAndMarksClean() throws {
        let (defaults, suite) = makeTestDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let (drafts, dir) = makeDraftStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bridge = BridgeStore()
        bridge.canvas.attachDraftStore(drafts)
        bridge.chat.attachDraftStore(drafts)

        let lifecycle = AppLifecycleGuard(defaults: defaults)
        #expect(lifecycle.beginSession() == true)

        // 防抖窗口内的画布草稿 + 会话输入草稿（共用同一 DraftStore，均未落盘）
        bridge.canvas.addNode(ofType: "llm")
        drafts.scheduleSave(key: DraftStore.chatDraftKey(sessionID: UUID()), payload: Data("打了一半".utf8))
        #expect(!drafts.hasDraft(key: DraftStore.canvasKey))

        // willTerminate（仅正常退出触发）：flushAll 兜底 → 全部落盘 + clean 标记
        lifecycle.handleWillTerminate(bridge: bridge)
        #expect(drafts.hasDraft(key: DraftStore.canvasKey))
        #expect(defaults.bool(forKey: AppLifecycleGuard.cleanExitDefaultsKey) == true)
    }

    @Test func willTerminateDoesNotMarkCleanWhenDraftFlushFails() throws {
        let (defaults, suite) = makeTestDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let blockedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("f7-blocked-root-\(UUID().uuidString)")
        #expect(
            FileManager.default.createFile(
                atPath: blockedRoot.path,
                contents: Data("not-a-directory".utf8)
            )
        )
        defer { try? FileManager.default.removeItem(at: blockedRoot) }

        let drafts = DraftStore(directory: blockedRoot)
        let bridge = BridgeStore()
        bridge.canvas.attachDraftStore(drafts)
        bridge.chat.attachDraftStore(drafts)
        _ = bridge.canvas.addNode(ofType: "llm")

        let lifecycle = AppLifecycleGuard(defaults: defaults)
        #expect(lifecycle.beginSession() == true)
        lifecycle.handleWillTerminate(bridge: bridge)

        #expect(drafts.latestPayload(for: DraftStore.canvasKey) != nil)
        #expect(
            defaults.bool(forKey: AppLifecycleGuard.cleanExitDefaultsKey) == false,
            "a failed flush must leave the session dirty for crash recovery"
        )
    }

    @Test func normalExitThenRestartSilentlyAutoRestoresCanvas() throws {
        let (defaults, suite) = makeTestDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let (drafts, dir) = makeDraftStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // —— 第一次会话：加节点（防抖未落盘）→ 正常退出 flush ——
        let bridge = BridgeStore()
        bridge.canvas.attachDraftStore(drafts)
        bridge.chat.attachDraftStore(drafts)
        bridge.canvas.addNode(ofType: "llm")
        bridge.canvas.addNode(ofType: "image")
        let lifecycle = AppLifecycleGuard(defaults: defaults)
        #expect(lifecycle.beginSession() == true)
        lifecycle.handleWillTerminate(bridge: bridge)

        // —— 重启：clean 标记 → 静默自动恢复（不弹崩溃提示）——
        let restart = AppLifecycleGuard(defaults: defaults)
        let clean = restart.beginSession()
        #expect(clean == true)
        let freshCanvas = CanvasStore()
        #expect(clean && AppLifecycleGuard.autoRestoreCanvasDraft(into: freshCanvas, directory: dir))
        #expect(freshCanvas.graph.nodes.count == 2)
        #expect(freshCanvas.graph.nodes.contains { $0.type == "image" })

        // 草稿已被消费（避免崩溃提示误报；后续变更重新防抖落盘）
        let probe = DraftStore(directory: dir)
        #expect(!probe.hasDraft(key: DraftStore.canvasKey))
    }

    @Test func crashThenRestartShowsPromptInsteadOfAutoRestore() throws {
        let (defaults, suite) = makeTestDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let (drafts, dir) = makeDraftStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // —— 第一次会话：防抖未落盘的草稿被显式 flush（等价退出落盘）+ 崩溃
        //    （willTerminate 不执行，clean-exit 脏标记残留）——
        let bridge = BridgeStore()
        bridge.canvas.attachDraftStore(drafts)
        bridge.chat.attachDraftStore(drafts)
        bridge.canvas.addNode(ofType: "llm")
        #expect(!drafts.hasDraft(key: DraftStore.canvasKey))
        bridge.canvas.flushCanvasDraft()   // 已有退出落盘入口（CanvasStore.swift:417）
        #expect(drafts.hasDraft(key: DraftStore.canvasKey))
        let lifecycle = AppLifecycleGuard(defaults: defaults)
        #expect(lifecycle.beginSession() == true)
        // （模拟 kill -9：不调 handleWillTerminate）

        // —— 重启：脏标记 → 调用方决策不自动恢复，走崩溃提示路径 ——
        let restart = AppLifecycleGuard(defaults: defaults)
        let clean = restart.beginSession()
        #expect(clean == false)
        // 调用方门控（MinisCanvasApp.swift .task）：lastExitClean == false 时跳过自动恢复
        let freshCanvas = CanvasStore()
        if clean {
            _ = AppLifecycleGuard.autoRestoreCanvasDraft(into: freshCanvas, directory: dir)
        }
        #expect(freshCanvas.graph.nodes.isEmpty)
        // 草稿保留在磁盘（attachProductionServices 的崩溃提示 + 「恢复画布」指令消费）
        #expect(DraftStore(directory: dir).hasDraft(key: DraftStore.canvasKey))
    }

    @Test func autoRestoreReturnsFalseWithoutDraft() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("f7-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let canvas = CanvasStore()
        #expect(!AppLifecycleGuard.autoRestoreCanvasDraft(into: canvas, directory: dir))
        #expect(canvas.graph.nodes.isEmpty)
    }

    @Test func autoRestoreConsumesEmptyDraftWithoutRestoring() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("f7-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // 空草稿（0 节点）落盘：干净退出后不应残留触发下次误报
        let drafts = DraftStore(directory: dir)
        let empty = CanvasDraft(savedAt: Date(), nodes: [], edges: [], groups: [])
        drafts.scheduleSave(key: DraftStore.canvasKey, payload: try JSONEncoder().encode(empty))
        drafts.flushNow(key: DraftStore.canvasKey)
        #expect(drafts.hasDraft(key: DraftStore.canvasKey))

        let canvas = CanvasStore()
        #expect(!AppLifecycleGuard.autoRestoreCanvasDraft(into: canvas, directory: dir))
        #expect(!DraftStore(directory: dir).hasDraft(key: DraftStore.canvasKey))   // 已消费
    }
}
