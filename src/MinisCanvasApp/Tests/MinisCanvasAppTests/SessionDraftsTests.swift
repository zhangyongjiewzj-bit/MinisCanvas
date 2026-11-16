import Testing
import Foundation
@testable import MinisCanvasApp

// MARK: - SessionDrafts 边界补写（swift-testing）
//
// C3_3AutoSaveTests 已覆盖：DraftStore 持久化/恢复/防抖/多会话隔离。
// 本文件补 C3_3 未覆盖的边界：
//   ① lastLoadError 生命周期：无文件≠错误 / 损坏→decodeFailed / 成功加载后清除
//   ② 版本迁移拒绝路径：迁移钩子返回 nil → unmigratableVersion 报错 + 隔离备份保留原文
//   ③ cancelPending：取消防抖写盘但内存最新载荷仍可读（发送后清空草稿语义）
//   ④ flushNow/flushAll 绕过防抖立即落盘 + draftKeys 全量
//   ⑤ clear 同时清内存与磁盘

@Suite("C3-3 补：lastLoadError / 迁移拒绝 / 隔离备份 / 边界清空")
final class SessionDraftsEdgeTests {

    private var tempDir: URL
    private var store: DraftStore

    init() {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("C3-3-edge-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tempDir.path)
        let draftStore = DraftStore(directory: tempDir)
        draftStore.debounceInterval = .milliseconds(30)
        store = draftStore
        // 测试直接写 drafts/k.json（绕过 persist 的自动建目录），须先建子目录
        try? FileManager.default.createDirectory(
            at: store.draftsDirectory, withIntermediateDirectories: true
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: store.draftsDirectory.path
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// 与 C3_3AutoSaveTests 相同的信封写入方式（当前版本直接 JSON 落盘）。
    private func writeEnvelope(
        key: String,
        schemaVersion: Int,
        payload: Data
    ) throws {
        let envelope = DraftEnvelope(
            schemaVersion: schemaVersion,
            savedAt: Date(),
            payload: payload
        )
        let data = try JSONEncoder().encode(envelope)
        let url = store.draftsDirectory.appendingPathComponent("\(key).json")
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: ① lastLoadError 生命周期

    @Test func lastLoadErrorLifecycleClearsOnSuccessAndMissingFile() throws {
        // 无文件：nil 载荷且不算错误
        #expect(store.load(key: "k") == nil)
        #expect(store.lastLoadError(for: "k") == nil)

        // 损坏 JSON → decodeFailed
        let corruptURL = store.draftsDirectory.appendingPathComponent("k.json")
        try Data("not-json{{".utf8).write(to: corruptURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: corruptURL.path)
        #expect(store.load(key: "k") == nil)
        #expect(store.lastLoadError(for: "k") == .decodeFailed)

        // 写回合法当前版本 → 加载成功且错误清除
        try writeEnvelope(key: "k", schemaVersion: DraftStore.currentSchemaVersion, payload: Data("ok".utf8))
        #expect(store.load(key: "k") == Data("ok".utf8))
        #expect(store.lastLoadError(for: "k") == nil, "成功加载后错误必须清除")
    }

    // MARK: ② 版本迁移拒绝路径 + 隔离备份

    @Test func migrationHookRejectingVersionIsReportedAndQuarantined() throws {
        try writeEnvelope(key: "k", schemaVersion: 0, payload: Data("legacy".utf8))
        store.migration = { _, _ in nil } // 迁移钩子拒绝（如版本跨度不支持）

        #expect(store.load(key: "k") == nil)
        #expect(store.lastLoadError(for: "k") == .unmigratableVersion(
            found: 0, current: DraftStore.currentSchemaVersion
        ), "迁移拒绝必须上报 unmigratableVersion")

        // 隔离备份保留原文，可人工恢复
        let quarantineURL = store.quarantineDirectory.appendingPathComponent("k.json")
        #expect(FileManager.default.fileExists(atPath: quarantineURL.path), "被拒版本应隔离备份")
        let envelope = try JSONDecoder().decode(
            DraftEnvelope.self, from: Data(contentsOf: quarantineURL)
        )
        #expect(envelope.payload == Data("legacy".utf8), "隔离备份内容与原文一致")
        #expect(envelope.schemaVersion == 0)
    }

    // MARK: ③ cancelPending：取消防抖写盘

    @Test func cancelPendingSuppressesDebouncedWriteButKeepsMemoryPayload() async throws {
        store.scheduleSave(key: "k", payload: Data("draft".utf8))
        store.cancelPending(key: "k")
        #expect(store.latestPayload(for: "k") == Data("draft".utf8),
                "取消后内存最新载荷仍可读（发送后清空草稿场景）")
        try await Task.sleep(for: .milliseconds(150))
        #expect(!store.hasDraft(key: "k"), "取消后防抖到期也不落盘")
    }

    // MARK: ④ flushNow / flushAll 绕过防抖立即落盘

    @Test func flushNowAndFlushAllPersistWithoutDebounce() throws {
        store.debounceInterval = .milliseconds(500) // 长防抖证明“立即”语义
        store.scheduleSave(key: "canvas", payload: Data("a".utf8))
        store.scheduleSave(key: "chatDraft.x", payload: Data("b".utf8))
        #expect(!store.hasDraft(key: "canvas"), "防抖窗口内未落盘")
        store.flushNow(key: "canvas")
        #expect(store.hasDraft(key: "canvas"), "flushNow 绕过防抖立即落盘")
        #expect(store.load(key: "canvas") == Data("a".utf8))
        store.flushAll()
        #expect(store.hasDraft(key: "chatDraft.x"))
        #expect(Set(store.draftKeys()) == Set(["canvas", "chatDraft.x"]), "draftKeys 全量列出")
    }

    // MARK: ⑤ clear 同时清内存与磁盘

    @Test func clearRemovesDraftFromMemoryAndDisk() throws {
        store.scheduleSave(key: "k", payload: Data("x".utf8))
        store.flushNow(key: "k")
        #expect(store.hasDraft(key: "k"))
        store.clear(key: "k")
        #expect(!store.hasDraft(key: "k"))
        #expect(store.latestPayload(for: "k") == nil)
        #expect(store.draftKeys().isEmpty)
        #expect(store.lastLoadError(for: "k") == nil)
        #expect(!FileManager.default.fileExists(
            atPath: store.draftsDirectory.appendingPathComponent("k.json").path
        ), "磁盘草稿一并删除")
    }
}
