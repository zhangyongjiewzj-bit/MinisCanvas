import XCTest
import Foundation
import MinisCore
@testable import MinisCanvasApp

// MARK: - storage.autoDeleteOldSessions 影子设置消费者测试（QODER-DEV-W5-STORAGE-SHADOW-SETTINGS-068）
//
// 目的：证明该开关不再是"有写无读"的影子设置——它驱动 SettingsCenter 上真实的
// 行为消费者 pendingAutoCleanupCount / previewAutoCleanupIntentIfEnabled，且默认关闭
// 时不产生任何自动、静默或不可逆的删除。全部用临时目录注入，不触碰真实数据。
//
// 本文件是同步测试（无 async / 无锁 / 无定时器），沿用同 target 已编译通过的
// SettingsCenterTests.swift 惯用法（@MainActor XCTestCase + 临时目录 makeCenter）。

@MainActor
final class SettingsCenterAutoDeleteConsumerTests: XCTestCase {

    private func makeCenter() -> (SettingsCenter, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoDeleteConsumer-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: dir),
            envStore: EnvVarStore(directory: dir),
            memoryStore: MemoryStore(directory: dir),
            sessionStore: SessionStore(directory: dir),
            logManager: LogManager(directory: dir, ringCapacity: 50)
        )
        return (center, dir)
    }

    /// 创建一个 updatedAt 早于 (now - days) 的会话。
    private func makeAgedSession(in store: SessionStore, title: String, daysAgo: Int) throws {
        var session = try store.createSession(title: title)
        session.updatedAt = Date().addingTimeInterval(-TimeInterval(daysAgo) * 86_400)
        try store.updateSession(session)
    }

    // 1) 安全默认：开关默认关闭时，消费者不排期任何会话，读取也不删除任何数据。
    func testAutoDeleteDisabledByDefaultProducesNoConsumerBehavior() throws {
        let (center, _) = makeCenter()
        let store = center.sessionStore

        try makeAgedSession(in: store, title: "old-1", daysAgo: 90)
        try makeAgedSession(in: store, title: "old-2", daysAgo: 45)
        _ = try store.createSession(title: "fresh")

        center.sessionRetentionDays = 30
        center.reloadStorage()
        XCTAssertEqual(center.sessions.count, 3)

        // 默认值必须是关闭（与 StorageSettings.default 一致）。
        XCTAssertFalse(center.autoDeleteOldSessions, "safe default: 自动删除默认必须关闭")

        // 消费者在关闭时恒为 0，即使存在超期会话。
        XCTAssertEqual(center.pendingAutoCleanupCount, 0)
        XCTAssertNil(try center.previewAutoCleanupIntentIfEnabled())

        // 仅读取设置/消费者绝不删除数据：全部会话仍在，回收站未被写入。
        XCTAssertEqual(center.sessions.count, 3)
        XCTAssertEqual(store.listSessions().count, 3)
    }

    // 2) 开启后：消费者给出有界、可恢复、经门禁确认的清理意向，但读取本身仍不删除。
    func testEnablingAutoDeleteSurfacesBoundedReversibleIntent() throws {
        let (center, _) = makeCenter()
        let store = center.sessionStore

        try makeAgedSession(in: store, title: "old-1", daysAgo: 90)
        try makeAgedSession(in: store, title: "old-2", daysAgo: 45)
        try makeAgedSession(in: store, title: "near-cutoff", daysAgo: 29)
        _ = try store.createSession(title: "fresh")

        center.sessionRetentionDays = 30
        center.autoDeleteOldSessions = true
        center.reloadStorage()
        XCTAssertEqual(center.sessions.count, 4)

        // 有界：只有超过保留期(30天)的两个会话进入待清理队列。
        XCTAssertEqual(center.pendingAutoCleanupCount, 2)

        // 生成的意向是可审阅、经门禁的预览（非 nil），affectedCount 与待清理数一致。
        let intent = try XCTUnwrap(center.previewAutoCleanupIntentIfEnabled())
        XCTAssertEqual(intent.affectedCount, 2)

        // 读取/生成意向本身绝不删除：会话总数不变（仍需用户在门禁里确认后才移入回收站）。
        XCTAssertEqual(center.sessions.count, 4)
        XCTAssertEqual(store.listSessions().count, 4)
    }

    // 3) 单一事实源：通过 canonical Settings 入口写入的开关跨 store 重载持久生效，
    //    并据此重算消费者（关闭 → 0；开启 → 有界计数）。
    func testAutoDeleteConsumerReadsCanonicalPersistedSetting() throws {
        let (center, dir) = makeCenter()
        let store = center.sessionStore

        try makeAgedSession(in: store, title: "old", daysAgo: 60)
        center.sessionRetentionDays = 30
        center.autoDeleteOldSessions = true
        center.reloadStorage()
        XCTAssertEqual(center.pendingAutoCleanupCount, 1)

        // 由独立的 SettingsStore 重新读取同一目录，证明写入的是唯一持久事实源。
        let reloaded = SettingsStore(directory: dir).settings.storage
        XCTAssertTrue(reloaded.autoDeleteOldSessions)
        XCTAssertEqual(reloaded.sessionRetentionDays, 30)

        // 关闭后同一消费者立刻回到 0（默认安全态）。
        center.autoDeleteOldSessions = false
        XCTAssertEqual(center.pendingAutoCleanupCount, 0)
        XCTAssertNil(try center.previewAutoCleanupIntentIfEnabled())
    }
}
