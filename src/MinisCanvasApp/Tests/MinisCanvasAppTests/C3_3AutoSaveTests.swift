import Testing
import Foundation
import CanvasCore
import MinisCore
@testable import MinisCanvasApp

// MARK: - C3-3 会话自动保存（512ms 防抖落盘）+ Agent 可撤销（操作历史栈）+ 崩溃恢复

@Suite("C3-3 会话自动保存")
@MainActor
struct C3_3AutoSaveTests {

    /// 测试用草稿存储：临时目录 + 30ms 防抖（加速等待）
    private func makeDraftStore() -> DraftStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("c3-3-tests-\(UUID().uuidString)", isDirectory: true)
        let store = DraftStore(directory: dir)
        store.debounceInterval = .milliseconds(30)
        return store
    }

    // MARK: 画布 512ms 防抖落盘

    @Test func debouncedCanvasSavePersistsAfterDebounceAndRestores() async throws {
        let store = makeDraftStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let canvas = CanvasStore()
        canvas.attachDraftStore(store)

        canvas.addNode(ofType: "llm")
        canvas.addNode(ofType: "image")
        // 防抖窗口内：内存已记录最新 payload，但磁盘未落盘
        #expect(store.latestPayload(for: DraftStore.canvasKey) != nil)
        #expect(!store.hasDraft(key: DraftStore.canvasKey))
        // 等待防抖（30ms）后：已落盘
        try await Task.sleep(for: .milliseconds(150))
        #expect(store.hasDraft(key: DraftStore.canvasKey))

        // 崩溃恢复：新实例（模拟重启）检测到草稿 → 恢复重建节点图
        let fresh = CanvasStore()
        fresh.attachDraftStore(store)
        let draft = fresh.recoverableCanvasDraft()
        #expect(draft != nil)
        #expect(draft?.nodes.count == 2)
        #expect(fresh.restoreCanvas(from: draft!) == true)
        #expect(fresh.graph.nodes.count == 2)
        #expect(fresh.graph.nodes.contains { $0.type == "llm" })
        #expect(fresh.graph.nodes.contains { $0.type == "image" })
    }

    @Test func debounceCoalescesRapidChangesToLastWrite() async throws {
        let store = makeDraftStore()
        // F4：防抖合并——快速连续改动只落盘一次，且节点数完整（不丢数据）。
        // 注意：不断言「防抖窗口内未落盘」——该断言在并发负载下受 addNode 开销
        // 影响成为时序竞态（窗口可能被循环耗时干超）。只验证最终落盘且数据完整。
        store.debounceInterval = .milliseconds(500)
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let canvas = CanvasStore()
        canvas.attachDraftStore(store)

        // 快速连续改动（防抖窗口内）→ 只落盘最后一次，且节点数完整（不丢数据）
        for _ in 0..<5 {
            canvas.addNode(ofType: "text")
            try await Task.sleep(for: .milliseconds(1))
        }
        // 等待防抖窗口结束 → 落盘，且 5 个节点完整（防抖合并不丢数据）
        try await Task.sleep(for: .milliseconds(700))
        #expect(store.hasDraft(key: DraftStore.canvasKey))
        #expect(canvas.recoverableCanvasDraft()?.nodes.count == 5)
    }

    @Test func flushCanvasDraftPersistsImmediately() throws {
        let store = makeDraftStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let canvas = CanvasStore()
        canvas.attachDraftStore(store)

        canvas.addNode(ofType: "llm")
        #expect(!store.hasDraft(key: DraftStore.canvasKey))
        canvas.flushCanvasDraft() // App 退出前 flush：不等防抖
        #expect(store.hasDraft(key: DraftStore.canvasKey))
    }

    // MARK: 画布草稿 DTO 往返（内容 / 连线 / 模型配置）

    @Test func canvasDraftRoundTripsContentEdgesAndBackend() throws {
        let canvas = CanvasStore()
        guard let a = canvas.addNode(ofType: "llm"),
              let b = canvas.addNode(ofType: "image") else {
            Issue.record("建节点失败"); return
        }
        canvas.updateNodeContent("你好世界", for: a.id)
        canvas.updateBackendConfig(
            NodeBackendConfig(providerType: .cloud, providerID: "bailian",
                              modelID: "qwen3.8-max-preview", params: ["temperature": "0.7"]),
            for: b.id
        )
        #expect(canvas.connectNodes(fromID: a.id, toID: b.id))

        let draft = CanvasDraft(graph: canvas.graph, savedAt: Date())
        let data = try JSONEncoder().encode(draft)
        let decoded = try JSONDecoder().decode(CanvasDraft.self, from: data)
        #expect(decoded.nodes.count == 2)
        #expect(decoded.edges.count == 1)

        let restored = decoded.toGraph()
        #expect(restored.node(id: a.id)?.backendConfig?.params["content"] == "你好世界")
        #expect(restored.node(id: b.id)?.backendConfig?.modelID == "qwen3.8-max-preview")
        #expect(restored.edges.first?.fromNode == a.id)
        #expect(restored.edges.first?.toNode == b.id)
        #expect(restored.node(id: a.id)?.position == canvas.graph.node(id: a.id)?.position)
    }

    // MARK: 会话输入草稿（draftText 防抖 + 按会话指针恢复）

    @Test func chatDraftDebouncePerSessionAndRestoresOnSwitch() async throws {
        let store = makeDraftStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let chat = ChatStore()
        chat.attachDraftStore(store)
        let s1 = chat.activeSessionID!

        // 键入草稿 → 防抖落盘（按会话隔离 key）
        chat.draftText = "未发送的草稿"
        #expect(store.latestPayload(for: DraftStore.chatDraftKey(sessionID: s1)) != nil)
        #expect(!store.hasDraft(key: DraftStore.chatDraftKey(sessionID: s1)))
        try await Task.sleep(for: .milliseconds(150))
        #expect(store.hasDraft(key: DraftStore.chatDraftKey(sessionID: s1)))

        // 新建会话：旧会话草稿 flush 落盘，新会话草稿为空
        chat.newSession()
        let s2 = chat.activeSessionID!
        #expect(s2 != s1)
        #expect(chat.draftText.isEmpty)
        #expect(store.hasDraft(key: DraftStore.chatDraftKey(sessionID: s1)))

        // 切回旧会话：草稿恢复（会话指针恢复）
        chat.switchSession(id: s1)
        #expect(chat.draftText == "未发送的草稿")
    }

    @Test func sendDraftClearsPersistedDraft() async throws {
        let store = makeDraftStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let chat = ChatStore()
        chat.attachDraftStore(store)
        let s1 = chat.activeSessionID!

        chat.draftText = "要发送的内容"
        try await Task.sleep(for: .milliseconds(150))
        #expect(store.hasDraft(key: DraftStore.chatDraftKey(sessionID: s1)))

        chat.sendDraft() // Mock 回复流式进行中
        // 发送后草稿已清理（已发送内容不残留）
        #expect(!store.hasDraft(key: DraftStore.chatDraftKey(sessionID: s1)))
        chat.stopStreaming()
    }

    // MARK: 崩溃恢复提示（检测 + 恢复 + 丢弃）

    @Test func crashRecoveryDetectsRestoresAndDiscards() throws {
        let store = makeDraftStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }

        // 上次会话留下未保存画布（模拟崩溃前）
        let canvas = CanvasStore()
        canvas.attachDraftStore(store)
        canvas.addNode(ofType: "llm")
        canvas.addNode(ofType: "video")
        canvas.flushCanvasDraft()
        #expect(store.hasDraft(key: DraftStore.canvasKey))

        // 模拟重启：新实例检测到草稿（崩溃恢复提示数据源）
        let fresh = CanvasStore()
        fresh.attachDraftStore(store)
        let draft = fresh.recoverableCanvasDraft()
        #expect(draft != nil)
        #expect(draft?.nodes.count == 2)
        #expect(fresh.graph.nodes.isEmpty) // 未恢复前画布为空

        // 恢复 → 节点图重建；丢弃 → 草稿清除
        #expect(fresh.restoreCanvas(from: draft!) == true)
        #expect(fresh.graph.nodes.count == 2)
        fresh.discardCanvasDraft()
        #expect(fresh.recoverableCanvasDraft() == nil)
    }

    // MARK: DraftStore 版本迁移

    /// 测试辅助：手工在磁盘写入指定版本信封，模拟旧/新格式草稿
    private func writeEnvelope(_ store: DraftStore, key: String, schemaVersion: Int, payload: Data) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: store.draftsDirectory, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.directory.path)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.draftsDirectory.path)
        let envelope = DraftEnvelope(schemaVersion: schemaVersion, savedAt: Date(), payload: payload)
        let data = try JSONEncoder().encode(envelope)
        let url = store.draftsDirectory.appendingPathComponent("\(key).json")
        try data.write(to: url)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    @Test func draftVersionMigrationUpgradesOldPayload() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("c3-3-migrate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DraftStore(directory: dir)

        // 手工写入旧版本（v0）信封，模拟磁盘上的旧草稿
        try writeEnvelope(store, key: "k", schemaVersion: 0, payload: Data("v0".utf8))

        // F4：未配迁移钩子 → 明确拒绝 + 隔离备份，不静默接受旧格式
        #expect(store.load(key: "k") == nil)
        #expect(store.lastLoadError(for: "k") == .unmigratableVersion(
            found: 0, current: DraftStore.currentSchemaVersion))

        // 重写旧版信封 + 配迁移钩子：v0 → v1 逐级升级
        try writeEnvelope(store, key: "k", schemaVersion: 0, payload: Data("v0".utf8))
        store.migration = { payload, from in
            from == 0 ? Data("v1:".utf8) + payload : nil
        }
        #expect(store.load(key: "k") == Data("v1:v0".utf8))
        #expect(store.lastLoadError(for: "k") == nil)
    }

    // MARK: F4 版本安全 —— 旧版无迁移 / 未来版 / 损坏 JSON 三种拒绝路径

    /// 旧版本草稿 + 无迁移钩子：拒绝加载 + 可读错误 + 原文隔离备份（不静默接受）
    @Test func draftOldVersionWithoutMigrationIsRejectedAndQuarantined() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("c3-3-oldver-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DraftStore(directory: dir)
        try writeEnvelope(store, key: "k", schemaVersion: 0, payload: Data("legacy".utf8))

        #expect(store.load(key: "k") == nil)
        #expect(store.lastLoadError(for: "k") == .unmigratableVersion(
            found: 0, current: DraftStore.currentSchemaVersion))
        // 隔离备份：原文件移出 drafts/，quarantine/ 保留原文（不丢数据）
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: store.draftsDirectory.appendingPathComponent("k.json").path))
        let quarantined = store.quarantineDirectory.appendingPathComponent("k.json")
        #expect(fm.fileExists(atPath: quarantined.path))
        let envelope = try JSONDecoder().decode(DraftEnvelope.self, from: Data(contentsOf: quarantined))
        #expect(envelope.schemaVersion == 0)
        #expect(envelope.payload == Data("legacy".utf8))
    }

    /// 未来版本草稿（更新版 App 写入）：拒绝加载 + 可读错误 + 隔离备份
    @Test func draftFutureVersionIsRejectedAndQuarantined() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("c3-3-future-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DraftStore(directory: dir)
        let future = DraftStore.currentSchemaVersion + 3
        try writeEnvelope(store, key: "k", schemaVersion: future, payload: Data("future".utf8))

        // 即使配了迁移钩子，未来版也不走迁移 —— 直接拒绝（钩子只负责升级，不负责降级猜测）
        store.migration = { payload, _ in payload }
        #expect(store.load(key: "k") == nil)
        #expect(store.lastLoadError(for: "k") == .futureVersion(
            found: future, current: DraftStore.currentSchemaVersion))
        #expect(FileManager.default.fileExists(
            atPath: store.quarantineDirectory.appendingPathComponent("k.json").path))
    }

    /// 损坏 JSON（非草稿信封）：拒绝加载 + decodeFailed + 隔离备份
    @Test func draftCorruptedJSONIsRejectedAndQuarantined() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("c3-3-corrupt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DraftStore(directory: dir)
        let fm = FileManager.default
        try fm.createDirectory(at: store.draftsDirectory, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.directory.path)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.draftsDirectory.path)
        let corruptURL = store.draftsDirectory.appendingPathComponent("k.json")
        try Data("{this is not a draft envelope".utf8).write(to: corruptURL)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: corruptURL.path)

        #expect(store.load(key: "k") == nil)
        #expect(store.lastLoadError(for: "k") == .decodeFailed)
        #expect(!fm.fileExists(atPath: corruptURL.path))
        #expect(fm.fileExists(atPath: store.quarantineDirectory.appendingPathComponent("k.json").path))
    }
}

// MARK: - Agent 工具调用历史栈（记录 + 展示 + 撤销留接口）

@Suite("C3-3 Agent 可撤销（操作历史）")
@MainActor
struct C3_3ActionHistoryTests {

    @Test func actionHistoryRecordsAndDisplays() {
        let history = ActionHistoryStore()
        history.record(ActionRecord(toolName: "shell_execute",
                                    argsSummary: "{\"command\":\"echo hi\"}",
                                    resultSummary: "exit 0"))
        history.record(ActionRecord(toolName: "file_write",
                                    argsSummary: "{\"path\":\"/tmp/a.txt\"}",
                                    resultSummary: "ok", succeeded: true))
        history.record(ActionRecord(toolName: "web_search",
                                    argsSummary: "{\"query\":\"swift\"}",
                                    resultSummary: "timeout", succeeded: false))

        #expect(history.records.count == 3)
        #expect(history.latest?.toolName == "web_search")
        #expect(history.latest?.succeeded == false)

        // 展示层：dump 含全部条目（工具名 + 参数摘要 + 结果摘要）
        let dump = history.records.enumerated().map { "\($0.offset + 1). `\($0.element.toolName)` \($0.element.argsSummary) → \($0.element.resultSummary)" }
            .joined(separator: "\n")
        #expect(dump.contains("shell_execute"))
        #expect(dump.contains("echo hi"))
        #expect(dump.contains("file_write"))
        #expect(dump.contains("web_search"))
        #expect(dump.contains("timeout"))
    }

    @Test func undoLatestOnlySucceedsWithInstalledHandler() {
        let history = ActionHistoryStore()
        history.record(ActionRecord(toolName: "file_write", argsSummary: "x", resultSummary: "ok"))

        // 撤销执行留接口：未装配 undoHandler → 记录模式（返回 false，条目保留）
        #expect(history.undoLatest() == false)
        #expect(history.records.count == 1)

        // 装配真实撤销 → 撤销成功并出栈
        var undone: ActionRecord?
        history.undoHandler = { record in
            undone = record
            return true
        }
        #expect(history.undoLatest() == true)
        #expect(undone?.toolName == "file_write")
        #expect(history.records.isEmpty)
    }

    @Test func recordingExecutorRecordsEachExecutedCall() async throws {
        let history = ActionHistoryStore()
        let recorder = RecordingToolExecutor(
            base: EchoExecutor(),
            onRecorded: { record in
                Task { @MainActor in history.record(record) }
            }
        )

        let output = try await recorder.execute(name: "shell_execute", input: ["command": "echo hi"])
        #expect(output == "echoed")
        // 等待 MainActor hop 入栈
        try await Task.sleep(for: .milliseconds(80))
        #expect(history.records.count == 1)
        #expect(history.records.first?.toolName == "shell_execute")
        #expect(history.records.first?.argsSummary.contains("echo hi") == true)
        #expect(history.records.first?.succeeded == true)

        // 失败调用也入栈（带失败标记）
        let failing = RecordingToolExecutor(
            base: FailingExecutor(),
            onRecorded: { record in
                Task { @MainActor in history.record(record) }
            }
        )
        do {
            _ = try await failing.execute(name: "file_read", input: ["path": "/nonexistent"])
            Issue.record("应抛出 ToolExecutorError")
        } catch {
            #expect(error is ToolExecutorError)
        }
        try await Task.sleep(for: .milliseconds(80))
        #expect(history.records.count == 2)
        #expect(history.records.last?.toolName == "file_read")
        #expect(history.records.last?.succeeded == false)
    }

    @Test func recordingExecutorSummariesAreTruncated() {
        let long = String(repeating: "a", count: 500)
        let summary = RecordingToolExecutor.summarizeResult(long)
        #expect(summary.count <= 81)
        #expect(summary.hasSuffix("…"))
    }

    // MARK: P3 live-security slice — ActionRecord 摘要内容级脱敏
    // 参数摘要 / 结果摘要 / 工具错误文本不得泄露内嵌的
    // Bearer / API-key / cookie / userinfo secret 值；非敏感文本原样保留。

    @Test func recordingExecutorArgsSummaryRedactsEmbeddedBearer() {
        let input: [String: Any] = [
            "command": "curl -H 'Authorization: Bearer sk-test1234567890abcdef' https://api.example.com/v1",
        ]
        let summary = RecordingToolExecutor.summarize(input)
        #expect(!summary.contains("sk-test1234567890abcdef"))
        #expect(summary.contains("curl"))
        // JSON 序列化会把 / 转义为 \/；断言不依赖转义形态的域名片段
        #expect(summary.contains("api.example.com"))
    }

    @Test func recordingExecutorResultSummaryRedactsEmbeddedSecret() {
        let output = "done with token sk-test1234567890abcdef now"
        let summary = RecordingToolExecutor.summarizeResult(output)
        #expect(!summary.contains("sk-test1234567890abcdef"))
        #expect(summary.contains("done with token"))
        #expect(summary.contains("now"))
    }

    @Test func recordingExecutorKnownSecretsMaskedInArgsSummary() {
        let input: [String: Any] = ["command": "echo SECRET_TOKEN_XYZ"]
        let summary = RecordingToolExecutor.summarize(input, knownSecretValues: ["SECRET_TOKEN_XYZ"])
        #expect(!summary.contains("SECRET_TOKEN_XYZ"))
        #expect(summary.contains("echo"))
    }

    @Test func recordingExecutorErrorTextRedactsEmbeddedSecret() async throws {
        let box = ActionRecordBox()
        let recorder = RecordingToolExecutor(
            base: SecretEchoingExecutor(),
            onRecorded: { box.add($0) }
        )
        do {
            _ = try await recorder.execute(name: "shell_execute", input: ["command": "curl -s https://example.com"])
            Issue.record("应抛出 SecretEchoingError")
        } catch {
            // expected
        }
        let record = try #require(box.records.first)
        #expect(record.succeeded == false)
        #expect(!record.resultSummary.contains("sk-test1234567890abcdef"))
    }
}

// MARK: - 测试替身

/// 成功执行器（测试替身；无状态 → Sendable）
struct EchoExecutor: ToolExecutor, Sendable {
    func execute(name: String, input: [String: Any]) async throws -> String {
        "echoed"
    }
}

/// 失败执行器（测试替身；无状态 → Sendable）
struct FailingExecutor: ToolExecutor, Sendable {
    func execute(name: String, input: [String: Any]) async throws -> String {
        throw ToolExecutorError.fileNotFound(input["path"] as? String ?? "?")
    }
}

/// 线程安全 ActionRecord 收集盒（onRecorded 在后台线程回调，测试在主线程断言）
final class ActionRecordBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ActionRecord] = []
    var records: [ActionRecord] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
    func add(_ record: ActionRecord) {
        lock.lock(); defer { lock.unlock() }
        storage.append(record)
    }
}

/// 抛错文本内嵌 Bearer secret 的执行器（测试替身；验证错误文本被脱敏）
struct SecretEchoingError: Error, LocalizedError {
    var errorDescription: String? { "failed near 'Bearer sk-test1234567890abcdef' upstream" }
}

struct SecretEchoingExecutor: ToolExecutor, Sendable {
    func execute(name: String, input: [String: Any]) async throws -> String {
        throw SecretEchoingError()
    }
}
