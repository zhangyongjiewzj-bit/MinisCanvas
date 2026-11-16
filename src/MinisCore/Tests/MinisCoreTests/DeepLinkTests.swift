import Foundation
import Testing
@testable import MinisCore

/// Unique temp directory per test (tests run in parallel; never share paths).
private func makeTempDir(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MinisCore-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - DeepLinkRouter parsing

struct DeepLinkRouterTests {

    @Test func parsesOpenSession() throws {
        #expect(DeepLinkRouter.parse(url: URL(string: "miniscanvas://session/abc-123")!) == .openSession(id: "abc-123"))
        // Canonical alias + path-only fallback
        #expect(DeepLinkRouter.parse(url: URL(string: "miniscanvas://sessions/xyz")!) == .openSession(id: "xyz"))
        #expect(DeepLinkRouter.parse(url: URL(string: "miniscanvas:///session/fallback")!) == .openSession(id: "fallback"))
    }

    @Test func parsesNewSession() throws {
        #expect(DeepLinkRouter.parse(url: URL(string: "miniscanvas://new-session")!) == .newSession)
        #expect(DeepLinkRouter.parse(url: URL(string: "miniscanvas://newSession")!) == .newSession)
        #expect(DeepLinkRouter.parse(url: URL(string: "miniscanvas://new")!) == .newSession)
    }

    @Test func parsesCreatePipeline() throws {
        #expect(DeepLinkRouter.parse(url: URL(string: "miniscanvas://pipeline")!) == .createPipeline)
        #expect(DeepLinkRouter.parse(url: URL(string: "miniscanvas://create-pipeline")!) == .createPipeline)
        #expect(DeepLinkRouter.parse(url: URL(string: "miniscanvas://createPipeline")!) == .createPipeline)
    }

    @Test func parsesOpenSettings() throws {
        #expect(DeepLinkRouter.parse(url: URL(string: "miniscanvas://settings")!) == .openSettings(id: nil))
        #expect(DeepLinkRouter.parse(url: URL(string: "miniscanvas://settings/providers")!) == .openSettings(id: "providers"))
    }

    @Test func parsesRunWorkflow() throws {
        #expect(DeepLinkRouter.parse(url: URL(string: "miniscanvas://run/视频流水线")!) == .runWorkflow(name: "视频流水线", input: nil))
        #expect(DeepLinkRouter.parse(url: URL(string: "miniscanvas://workflow/a/b")!) == .runWorkflow(name: "a/b", input: nil))
        #expect(DeepLinkRouter.parse(url: URL(string: "miniscanvas://run")!) == nil) // missing name
    }

    @Test func parsesSendPrompt() throws {
        #expect(DeepLinkRouter.parse(url: URL(string: "miniscanvas://prompt/你好")!) == .sendPrompt(text: "你好", session: nil))
        // Percent-encoded text is decoded by URL.path
        let encoded = "miniscanvas://prompt/hello%20world".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        _ = encoded
        #expect(DeepLinkRouter.parse(url: URL(string: "miniscanvas://prompt/hello%20world")!) == .sendPrompt(text: "hello world", session: nil))
        #expect(DeepLinkRouter.parse(url: URL(string: "miniscanvas://prompt/")!) == nil) // empty text
    }

    @Test func rejectsNonMiniscanvasURLs() throws {
        #expect(DeepLinkRouter.parse(url: URL(string: "https://example.com/session/1")!) == nil)
        #expect(DeepLinkRouter.parse(url: URL(string: "miniscanvas://unknown-route")!) == nil)
    }

    @Test func parsesLegacyMinisScheme() throws {
        // D1-fix：旧链接用 minis:// 前缀（minis://run/manju-full 曾触发
        // macOS「未设定应用程序」弹窗），解析时兜底接受，路由不变。
        #expect(DeepLinkRouter.parse(url: URL(string: "minis://run/manju-full")!) == .runWorkflow(name: "manju-full", input: nil))
        #expect(DeepLinkRouter.parse(url: URL(string: "minis://session/1")!) == .openSession(id: "1"))
        #expect(DeepLinkRouter.parse(url: URL(string: "minis://new-session")!) == .newSession)
        #expect(DeepLinkRouter.parse(url: URL(string: "MINIS://pipeline")!) == .createPipeline)
    }

    @Test func parsesRunManjuFull() throws {
        // run/manju-full → 漫剧全流程工作流动作（DeepLinkHandler.runWorkflow 接线）
        #expect(DeepLinkRouter.parse(url: URL(string: "miniscanvas://run/manju-full")!) == .runWorkflow(name: "manju-full", input: nil))
        #expect(DeepLinkRouter.parse(url: URL(string: "minis://run/manju-full")!) == .runWorkflow(name: "manju-full", input: nil))
    }

    @Test func handlesMalformedAndEdgeURLs() throws {
        // 无 scheme / 无 host / 空路径 → 容错返回 nil，不崩
        #expect(DeepLinkRouter.parse(url: URL(string: "notaurl")!) == nil)
        #expect(DeepLinkRouter.parse(url: URL(string: "miniscanvas:")!) == nil)
        #expect(DeepLinkRouter.parse(url: URL(string: "miniscanvas://")!) == nil)
        // scheme 大小写不敏感
        #expect(DeepLinkRouter.parse(url: URL(string: "MINISCANVAS://session/abc")!) == .openSession(id: "abc"))
        // 百分号编码 id 自动解码
        #expect(DeepLinkRouter.parse(url: URL(string: "miniscanvas://session/a%20b")!) == .openSession(id: "a b"))
        // 未知 host 与多余路径段均严格拒绝。
        #expect(DeepLinkRouter.parse(url: URL(string: "miniscanvas://garbage/x")!) == nil)
        #expect(DeepLinkRouter.parse(url: URL(string: "miniscanvas://session/a/b")!) == nil)
    }

    @Test func resolveWorkflow_unknownNameReturnsNil() throws {
        let router = DeepLinkRouter()
        let storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeepLinkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storeDir) }
        let store = WorkflowStore(storeDirectory: storeDir)
        // 未知模板名 / 非 runWorkflow action → nil（不崩）
        #expect(router.resolveWorkflow(.runWorkflow(name: "不存在的模板", input: nil), store: store) == nil)
        #expect(router.resolveWorkflow(.newSession, store: store) == nil)
    }
}

// MARK: - DeepLinkRouter dispatch

struct DeepLinkRouterDispatchTests {

    @Test func handleDispatchesToRegisteredHandler() throws {
        let router = DeepLinkRouter()
        var received: [DeepLinkAction] = []
        router.register { received.append($0) }

        #expect(router.handle(url: URL(string: "miniscanvas://new-session")!))
        #expect(router.handle(url: URL(string: "miniscanvas://session/s1")!))
        #expect(received == [.newSession, .openSession(id: "s1")])
    }

    @Test func handleReturnsFalseForUnknownURL() throws {
        let router = DeepLinkRouter()
        var received: [DeepLinkAction] = []
        router.register { received.append($0) }

        #expect(!router.handle(url: URL(string: "https://example.com")!))
        #expect(received.isEmpty) // nothing dispatched
    }

    @Test func registerReplacesPreviousHandler() throws {
        let router = DeepLinkRouter()
        var first = 0
        var second = 0
        router.register { _ in first += 1 }
        router.register { _ in second += 1 }

        _ = router.handle(url: URL(string: "miniscanvas://new-session")!)
        #expect(first == 0)
        #expect(second == 1)
    }
}

// MARK: - QuickActionStore

struct QuickActionStoreTests {

    @Test func presetsAreListedInOrder() throws {
        let store = QuickActionStore()
        let actions = store.listActions()
        #expect(actions.map(\.id) == ["new-chat", "quick-pipeline", "open-settings"])
        #expect(actions.allSatisfy { !$0.title.isEmpty && !$0.icon.isEmpty })
    }

    @Test func presetDeepLinksUseCanonicalScheme() throws {
        // D1-fix：协议统一 —— 所有 QuickAction deepLinkURL 必须是
        // miniscanvas://（不得再出现 minis:// 混用）。
        let actions = QuickActionStore.defaultActions
        #expect(actions.allSatisfy { $0.deepLinkURL.hasPrefix("miniscanvas://") })
        #expect(!actions.contains { $0.deepLinkURL.hasPrefix("minis://") })
    }

    @Test func performRoutesThroughRouter() throws {
        let router = DeepLinkRouter()
        var received: [DeepLinkAction] = []
        router.register { received.append($0) }

        let store = QuickActionStore()
        #expect(store.perform(actionID: "new-chat", using: router))
        #expect(!store.perform(actionID: "quick-pipeline", using: router))
        #expect(store.resolution(id: "quick-pipeline")?.disposition == .authorizationRequired)
        #expect(store.perform(actionID: "open-settings", using: router))
        #expect(received == [.newSession, .openSettings(id: nil)])
    }

    @Test func performUnknownIDReturnsFalse() throws {
        let router = DeepLinkRouter()
        router.register { _ in }
        let store = QuickActionStore()
        #expect(!store.perform(actionID: "does-not-exist", using: router))
    }

    @Test func customActionsAreSupported() throws {
        let custom = QuickAction(id: "custom", title: "自定义", icon: "star", deepLinkURL: "miniscanvas://run/自定义流程")
        let store = QuickActionStore(actions: [custom])
        let router = DeepLinkRouter()
        var received: [DeepLinkAction] = []
        router.register { received.append($0) }

        #expect(store.listActions() == [custom])
        #expect(!store.perform(actionID: "custom", using: router))
        #expect(store.resolution(id: "custom")?.disposition == .authorizationRequired)
        #expect(received.isEmpty)
    }
}

// MARK: - SoulStore

struct SoulStoreTests {

    @Test func seedsDefaultSoulOnFirstAccess() throws {
        let dir = try makeTempDir("SoulStore")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SoulStore(directory: dir)
        let souls = store.listSouls()
        #expect(souls == [SoulStore.defaultSoul])
        #expect(store.activeSoul()?.id == SoulStore.defaultSoul.id)
        #expect(FileManager.default.fileExists(atPath: store.soulsFileURL.path))
    }

    @Test func setActiveSwitchesAndPersistsAcrossInstances() throws {
        let dir = try makeTempDir("SoulStore")
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = SoulStore(directory: dir)
        let second = Soul(id: "second", name: "第二人格", systemPrompt: "你是第二人格。")
        try writer.upsert(second)

        let activated = try writer.setActive("second")
        #expect(activated.id == "second")
        #expect(writer.activeSoul()?.id == "second")

        // Fresh store instance reads from disk — proves real persistence.
        let reader = SoulStore(directory: dir)
        #expect(reader.activeSoul()?.id == "second")
        #expect(reader.listSouls().filter(\.isActive).count == 1)
        #expect(reader.listSouls().first { $0.id == SoulStore.defaultSoul.id }?.isActive == false)
    }

    @Test func setActiveUnknownIDThrows() throws {
        let dir = try makeTempDir("SoulStore")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SoulStore(directory: dir)
        #expect(throws: SoulStoreError.soulNotFound("nope")) {
            try store.setActive("nope")
        }
    }

    @Test func upsertActiveSoulDeactivatesOthers() throws {
        let dir = try makeTempDir("SoulStore")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SoulStore(directory: dir)
        try store.upsert(Soul(id: "a", name: "A", systemPrompt: "A 人格", isActive: true))
        try store.upsert(Soul(id: "b", name: "B", systemPrompt: "B 人格", isActive: true))

        #expect(store.activeSoul()?.id == "b")
        #expect(store.listSouls().filter(\.isActive).count == 1)
    }

    @Test func upsertReplacesExistingSoul() throws {
        let dir = try makeTempDir("SoulStore")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SoulStore(directory: dir)
        try store.upsert(Soul(id: "a", name: "旧名字", systemPrompt: "旧提示词"))
        try store.upsert(Soul(id: "a", name: "新名字", systemPrompt: "新提示词", isActive: true))

        let souls = store.listSouls()
        #expect(souls.count == 2) // default + one "a", not duplicated
        #expect(store.activeSoul()?.name == "新名字")
        #expect(store.activeSoul()?.systemPrompt == "新提示词")
    }

    @Test func deleteRemovesNonDefaultSoul() throws {
        let dir = try makeTempDir("SoulStore")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SoulStore(directory: dir)
        try store.upsert(Soul(id: "a", name: "A", systemPrompt: "A 人格"))
        try store.delete(id: "a")
        #expect(store.listSouls().allSatisfy { $0.id != "a" })

        // Default soul is protected from deletion.
        try store.delete(id: SoulStore.defaultSoul.id)
        #expect(store.listSouls().contains { $0.id == SoulStore.defaultSoul.id })
    }
}
