import XCTest
import Foundation
import AppKit
import MinisCore
@testable import MinisCanvasApp

// MARK: - P3-P1-03 consumer：storage.memoryLimitMB 驱动进程内解码缓存预算
//
// 被钉住的行为（QA/BUG-REPORT.md P3-P1-03 影子配置；Canonical 总表 P3-SET-01 consumer 列）：
//  1. 预算规则本身：配置值只向下封顶，nil / 0 / 负数 / 溢出量级一律保持各自基线
//     （`NSCache.totalCostLimit == 0` 的框架语义是「无上限」，透传 0 会反向放大）。
//  2. 默认（未配置）= 引入本 consumer 前逐位一致：四个缓存各自停在 30 / 128 / 64 / 48 MB 基线，
//     且 attributed 缓存仍照常命中复用同一实例。
//  3. 配置后真的生效：走各自生产入口（build / previewImage / image / applyConfiguredMemoryLimit）
//     后，生效预算变成配置值。
//  4. 规范值只有一份：读的是 App 组合根安装的唯一 `SettingsCenter.active`；清空后回到基线，
//     说明本层没有第二份存储副本。
//
// 纪律：全程临时目录注入，绝不读写真实 settings.json；不使用 async 测试、不使用锁、
// 不使用定时器（同步 @MainActor XCTestCase 先例：SettingsCenterTests.swift:10-31）。
// `SettingsCenter.active` 由 init 安装（SettingsCenter.swift:820，private(set)），
// scripts/run_tests.sh 的所有 `swift test` 调用都带 `--no-parallel`（:652/:894/:1244/:1425），
// 故用例内 active 就是本用例刚创建的 center（第 5 项用例把该前提显式钉住，
// 若将来改成并行执行会直接失败报出，而不是静默误判）。
@MainActor
final class StorageMemoryLimitCacheConsumerTests: XCTestCase {

    private let mb = 1024 * 1024

    /// 临时目录注入的 center（init 会把它装成 `SettingsCenter.active`）。
    private func makeCenter() -> (SettingsCenter, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemLimit076Tests-\(UUID().uuidString)", isDirectory: true)
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

    /// 一张真实的 1×1 PNG 字节（与 M6AssetPanelTests.swift:120-126 同一构造方式）。
    private func tinyPNGData() -> Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!
    }

    private func makePNGFile() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("memlimit076-\(UUID().uuidString).png")
        try? tinyPNGData().write(to: url)
        return url
    }

    /// 走四个缓存的生产入口各一次（每次用唯一键，保证是未命中→入缓存路径）。
    private func driveAllCaches() {
        _ = AttributedCache.build(
            content: "memlimit076-\(UUID().uuidString)",
            isMarkdown: false,
            baseSize: 13,
            baseColor: .labelColor
        )
        let png = makePNGFile()
        defer { try? FileManager.default.removeItem(at: png) }
        _ = AssetImageLoader.previewImage(path: png.path)
        _ = FileTreePreviewCache.image(from: tinyPNGData(), key: png.path)
        VideoThumbnailView.applyConfiguredMemoryLimit()
    }

    // MARK: - 1) 预算规则（纯函数，不依赖全局设置）

    func testBudgetRuleOnlyEverCapsDownwardAndKeepsBaselineWhenUnconfigured() {
        // nil = 不限制（默认）→ 基线
        XCTAssertEqual(
            MemoryLimitCachePolicy.effectiveTotalCostBytes(baseline: 128 * mb, memoryLimitMB: nil),
            128 * mb
        )
        // 配置值小于基线 → 配置值
        XCTAssertEqual(
            MemoryLimitCachePolicy.effectiveTotalCostBytes(baseline: 128 * mb, memoryLimitMB: 8),
            8 * mb
        )
        // 配置值大于基线 → 仍停在基线（上限永不上调，卡顿/内存专项基线不被用户配置放大）
        XCTAssertEqual(
            MemoryLimitCachePolicy.effectiveTotalCostBytes(baseline: 30 * mb, memoryLimitMB: 4096),
            30 * mb
        )
        // 恰好等于基线
        XCTAssertEqual(
            MemoryLimitCachePolicy.effectiveTotalCostBytes(baseline: 48 * mb, memoryLimitMB: 48),
            48 * mb
        )
        // UI 允许输入 0（"0 或留空"）：0 必须按未配置处理，
        // 否则透传给 NSCache 会变成「无上限」，把压小反向放大成不封顶。
        XCTAssertEqual(
            MemoryLimitCachePolicy.effectiveTotalCostBytes(baseline: 64 * mb, memoryLimitMB: 0),
            64 * mb
        )
        XCTAssertEqual(
            MemoryLimitCachePolicy.effectiveTotalCostBytes(baseline: 64 * mb, memoryLimitMB: -5),
            64 * mb
        )
        // MB→字节乘法溢出量级 → 按未配置回落基线（不得 trap，也不得放大）
        XCTAssertEqual(
            MemoryLimitCachePolicy.effectiveTotalCostBytes(baseline: 30 * mb, memoryLimitMB: Int.max),
            30 * mb
        )
        // 基线本身非正 → 原样返回（本 lane 的四个缓存基线都是正数，此分支只保证不制造 0/负预算）
        XCTAssertEqual(
            MemoryLimitCachePolicy.effectiveTotalCostBytes(baseline: 0, memoryLimitMB: 8),
            0
        )
    }

    // MARK: - 2) 默认配置 = 行为不变

    func testDefaultLeavesEveryDrivenCacheOnItsOwnBaseline() {
        let (center, dir) = makeCenter()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(center.memoryLimitMB, "AppSettings.storage.memoryLimitMB 默认必须是 nil（不限制）")

        driveAllCaches()

        XCTAssertEqual(AttributedCache.currentTotalCostLimitBytes, 30 * mb)
        XCTAssertEqual(AssetImageLoader.currentTotalCostLimitBytes, 128 * mb)
        XCTAssertEqual(FileTreePreviewCache.currentTotalCostLimitBytes, 48 * mb)
        XCTAssertEqual(VideoThumbnailView.currentTotalCostLimitBytes, 64 * mb)

        // 默认路径的既有缓存语义不变：同内容二次构建命中同一实例。
        AttributedCache.clear()
        let content = "default-path-reuse-\(UUID().uuidString)"
        let first = AttributedCache.build(content: content, isMarkdown: false, baseSize: 13, baseColor: .labelColor)
        let second = AttributedCache.build(content: content, isMarkdown: false, baseSize: 13, baseColor: .labelColor)
        XCTAssertTrue(first === second, "默认配置下 attributed 缓存仍必须复用同一实例（防 body 重算重复解析）")
        XCTAssertEqual(AttributedCache.count, 1)
        XCTAssertEqual(AttributedCache.currentTotalCostLimitBytes, 30 * mb)
    }

    // MARK: - 3) 配置值真的驱动四个缓存

    func testConfiguredLimitDrivesEveryInSetCacheThroughItsProductionEntryPoint() {
        let (center, dir) = makeCenter()
        defer {
            center.memoryLimitMB = nil
            try? FileManager.default.removeItem(at: dir)
        }
        center.memoryLimitMB = 8
        XCTAssertEqual(MemoryLimitCachePolicy.configuredMemoryLimitMB, 8)

        driveAllCaches()

        XCTAssertEqual(AttributedCache.currentTotalCostLimitBytes, 8 * mb)
        XCTAssertEqual(AssetImageLoader.currentTotalCostLimitBytes, 8 * mb)
        XCTAssertEqual(FileTreePreviewCache.currentTotalCostLimitBytes, 8 * mb)
        XCTAssertEqual(VideoThumbnailView.currentTotalCostLimitBytes, 8 * mb)

        // 大于所有基线的配置值不得放大任何缓存（上面 8MB 生效、这里 4096MB 仍停在基线）。
        center.memoryLimitMB = 4096
        driveAllCaches()
        XCTAssertEqual(AttributedCache.currentTotalCostLimitBytes, 30 * mb)
        XCTAssertEqual(AssetImageLoader.currentTotalCostLimitBytes, 128 * mb)
        XCTAssertEqual(FileTreePreviewCache.currentTotalCostLimitBytes, 48 * mb)
        XCTAssertEqual(VideoThumbnailView.currentTotalCostLimitBytes, 64 * mb)
    }

    // MARK: - 4) 清空配置后回到基线（无第二份副本）

    func testClearingTheSettingRestoresBaselinesWithoutStickyState() {
        let (center, dir) = makeCenter()
        defer { try? FileManager.default.removeItem(at: dir) }
        center.memoryLimitMB = 1
        driveAllCaches()
        XCTAssertEqual(AttributedCache.currentTotalCostLimitBytes, 1 * mb)
        XCTAssertEqual(AssetImageLoader.currentTotalCostLimitBytes, 1 * mb)

        center.memoryLimitMB = nil
        driveAllCaches()
        XCTAssertEqual(AttributedCache.currentTotalCostLimitBytes, 30 * mb)
        XCTAssertEqual(AssetImageLoader.currentTotalCostLimitBytes, 128 * mb)
        XCTAssertEqual(FileTreePreviewCache.currentTotalCostLimitBytes, 48 * mb)
        XCTAssertEqual(VideoThumbnailView.currentTotalCostLimitBytes, 64 * mb)
    }

    // MARK: - 5) 规范来源唯一性（含持久化往返）

    func testCanonicalValueComesFromTheActiveSettingsCenterOnly() {
        let (center, dir) = makeCenter()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 本用例依赖「active == 刚创建的 center」（串行执行前提，见文件头注释）。
        XCTAssertTrue(
            SettingsCenter.active === center,
            "App 组合根/构造应安装唯一设置中心；若测试改为并行执行，此断言会直接报出而不是误判 consumer"
        )
        center.memoryLimitMB = 12
        XCTAssertEqual(MemoryLimitCachePolicy.configuredMemoryLimitMB, 12)
        XCTAssertEqual(MemoryLimitCachePolicy.configuredMemoryLimitMB, center.memoryLimitMB)

        // 配置经 store 落盘后仍是同一个规范值（不新增 settings_key、不改声明）。
        let reloaded = SettingsCenter(
            settingsStore: SettingsStore(directory: dir),
            envStore: EnvVarStore(directory: dir),
            memoryStore: MemoryStore(directory: dir),
            sessionStore: SessionStore(directory: dir),
            logManager: LogManager(directory: dir, ringCapacity: 50)
        )
        XCTAssertEqual(reloaded.memoryLimitMB, 12)
        XCTAssertEqual(MemoryLimitCachePolicy.configuredMemoryLimitMB, 12)
        driveAllCaches()
        XCTAssertEqual(AttributedCache.currentTotalCostLimitBytes, 12 * mb)

        // 复位：`reloaded` 才是当前 active 安装者，清理必须落在它身上，
        // 否则同进程后续用例会停在 12MB。
        reloaded.memoryLimitMB = nil
        center.memoryLimitMB = nil
        driveAllCaches()
        XCTAssertEqual(AttributedCache.currentTotalCostLimitBytes, 30 * mb)
    }

    // MARK: - 6) 声明未漂移：本 consumer 读的就是被声明的那个键

    func testDrivenCachesReadTheDeclaredStorageKeyAndNothingElse() {
        let (center, dir) = makeCenter()
        defer {
            center.memoryLimitMB = nil
            try? FileManager.default.removeItem(at: dir)
        }
        // 只改兄弟键不应影响预算（证明读取的是 memoryLimitMB，而不是整组 storage 的副产物）。
        center.sessionRetentionDays = 7
        center.autoDeleteOldSessions = true
        XCTAssertNil(center.memoryLimitMB)
        driveAllCaches()
        XCTAssertEqual(AttributedCache.currentTotalCostLimitBytes, 30 * mb)
        XCTAssertEqual(AssetImageLoader.currentTotalCostLimitBytes, 128 * mb)
        XCTAssertEqual(FileTreePreviewCache.currentTotalCostLimitBytes, 48 * mb)
        XCTAssertEqual(VideoThumbnailView.currentTotalCostLimitBytes, 64 * mb)
    }
}
