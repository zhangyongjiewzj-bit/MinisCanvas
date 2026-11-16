import Foundation
import Testing
@testable import MinisCanvasApp

/// P3-P1-03 证据（A）· 会话侧栏宽度统一设置合同回归。
///
/// 同步 @MainActor swift-testing 风格与 UserDefaults 注入/清理习惯复制自
/// AutomationDurableRunTests.swift:11-19（makeDefaults）与
/// AdaptiveLayoutPolicyTests.swift:14-27（源码扫描），无 async、无锁。
@Suite("P3-P1-03 会话侧栏宽度设置合同")
@MainActor
struct SessionSidebarWidthContractTests {

    private func makeDefaults() -> (UserDefaults, () -> Void) {
        let suiteName = "sidebar-width-contract-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    private func appSourcesDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MinisCanvasAppTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // MinisCanvasApp
            .appendingPathComponent("Sources/MinisCanvasApp", isDirectory: true)
    }

    @Test("旧持久化值免迁移可读且直接成为生效值")
    func legacyPersistedValueRemainsReadable() {
        let (defaults, cleanup) = makeDefaults()
        defer { cleanup() }
        // 历史 @AppStorage(Double) 写入的同键同域值——合同必须先读懂它再谈收敛。
        defaults.set(321.0, forKey: SessionSidebarWidthContract.settingsKey)

        let setting = SessionSidebarWidthSetting(defaults: defaults)
        #expect(setting.storedWidth == 321.0)
        #expect(setting.effectiveWidth == 321.0)
    }

    @Test("plist 整型表示的历史值也按 Double 读出")
    func integerBackedLegacyValueReads() {
        let (defaults, cleanup) = makeDefaults()
        defer { cleanup() }
        defaults.set(280, forKey: SessionSidebarWidthContract.settingsKey)

        let setting = SessionSidebarWidthSetting(defaults: defaults)
        #expect(setting.storedWidth == 280.0)
    }

    @Test("验证只认合同入口：缺省回默认、非有限回默认、低于最小抬到最小")
    func validationIsSingleGateway() {
        #expect(SessionSidebarWidthContract.validate(nil) == SessionSidebarWidthContract.defaultValue)
        #expect(SessionSidebarWidthContract.validate(.nan) == SessionSidebarWidthContract.defaultValue)
        #expect(SessionSidebarWidthContract.validate(.infinity) == SessionSidebarWidthContract.defaultValue)
        #expect(SessionSidebarWidthContract.validate(10) == SidebarWidthMemory.minWidth)
        #expect(SessionSidebarWidthContract.validate(-5) == SidebarWidthMemory.minWidth)
        #expect(SessionSidebarWidthContract.validate(480) == 480)
        // 合同默认/最小值与 SidebarWidthMemory 同源，不允许第二套数值。
        #expect(SessionSidebarWidthContract.defaultValue == SidebarWidthMemory.defaultWidth)
        #expect(SessionSidebarWidthContract.minWidth == SidebarWidthMemory.minWidth)
    }

    @Test("写入即持久化；新实例读回=重启语义；reset 覆写为默认")
    func writePersistsAndRestartReadsBack() {
        let (defaults, cleanup) = makeDefaults()
        defer { cleanup() }
        let setting = SessionSidebarWidthSetting(defaults: defaults)

        setting.write(288)
        #expect(setting.storedWidth == 288)
        #expect(SessionSidebarWidthContract.persistedRawValue(in: defaults) == 288)

        // 模拟重启：另建实例读取同一 suite 同一键。
        let relaunched = SessionSidebarWidthSetting(defaults: defaults)
        #expect(relaunched.effectiveWidth == 288)

        // 越界写入必须经验证落盘，影子脏值不得进入持久域。
        relaunched.write(-100)
        #expect(SessionSidebarWidthContract.persistedRawValue(in: defaults) == SidebarWidthMemory.minWidth)

        relaunched.resetToDefault()
        #expect(relaunched.effectiveWidth == SessionSidebarWidthContract.defaultValue)
        #expect(SessionSidebarWidthContract.persistedRawValue(in: defaults) == SessionSidebarWidthContract.defaultValue)

        // suite 被外部整体重置后显式刷新回落默认（不复活脏值、不崩溃）。
        defaults.removeObject(forKey: SessionSidebarWidthContract.settingsKey)
        #expect(relaunched.effectiveWidth == SessionSidebarWidthContract.defaultValue)
        relaunched.reload()
        #expect(relaunched.effectiveWidth == SessionSidebarWidthContract.defaultValue)
    }

    @Test("中档窗口实际消费拖拽宽度且新实例恢复同宽")
    func mediumLayoutConsumesPersistedDragWidthAfterRestart() {
        let (defaults, cleanup) = makeDefaults()
        defer { cleanup() }
        let setting = SessionSidebarWidthSetting(defaults: defaults)
        let windowWidth = 1_000.0
        let initial = AdaptiveLayoutPolicy.decision(
            for: windowWidth,
            preferredLeftWidth: setting.effectiveWidth,
            preferredRightWidth: 300
        )
        #expect(initial.leftWidth == 240)

        setting.write(360)
        let resized = AdaptiveLayoutPolicy.decision(
            for: windowWidth,
            preferredLeftWidth: setting.effectiveWidth,
            preferredRightWidth: 300
        )
        #expect(resized.leftWidth == 360)

        let relaunched = SessionSidebarWidthSetting(defaults: defaults)
        let restored = AdaptiveLayoutPolicy.decision(
            for: windowWidth,
            preferredLeftWidth: relaunched.effectiveWidth,
            preferredRightWidth: 300
        )
        #expect(restored.leftWidth == 360)
    }

    @Test("矩阵条目与实现逐字段同源")
    func descriptorMirrorsImplementation() throws {
        let descriptor = SessionSidebarWidthContract.descriptor
        #expect(descriptor.stateClass == .canonicalSetting)
        #expect(descriptor.settingsKey == SessionSidebarWidthContract.settingsKey)
        #expect(descriptor.effectiveSource == "SessionSidebarWidthSetting.storedWidth")
        #expect(descriptor.consumer.contains("ContentView"))
        #expect(descriptor.persistence.contains("preferencesDefaults"))
        #expect(descriptor.defaultValue.contains("240"))
        #expect(descriptor.validation.contains("56"))
        #expect(!descriptor.mayOverrideEffectiveValue)
        // 声明的键即实现的键：写入落点与 descriptor.settingsKey 只有一个字符串来源。
        let declaredKey = try #require(descriptor.settingsKey)
        let (defaults, cleanup) = makeDefaults()
        defer { cleanup() }
        let setting = SessionSidebarWidthSetting(defaults: defaults)
        setting.write(297)
        #expect(defaults.object(forKey: declaredKey) != nil)
    }

    @Test("孤儿闸口：键字面量与 @AppStorage 绑定只允许存在于合同文件")
    func keyLiteralHasSingleOwnerInProductionSources() throws {
        let contractFile = "SessionSidebarWidthContract.swift"
        let sourceURLs = FileManager.default.enumerator(
            at: appSourcesDirectory(),
            includingPropertiesForKeys: nil
        )!
        var offenders: [String] = []
        for case let url as URL in sourceURLs where url.pathExtension == "swift" {
            guard url.lastPathComponent != contractFile else { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            if source.contains("minisCanvas.sidebarWidth") {
                offenders.append(url.lastPathComponent)
            }
        }
        #expect(offenders.isEmpty, "影子配置键又出现了第二持有者: \(offenders)")

        // 前端不得再持有该键的私有 @AppStorage 声明。
        let contentViewSource = try String(
            contentsOf: appSourcesDirectory()
                .appendingPathComponent("ContentView.swift"),
            encoding: .utf8
        )
        #expect(!contentViewSource.contains("@AppStorage(\"minisCanvas.sidebarWidth\")"))
        #expect(contentViewSource.contains("sidebarWidthSetting.write("))
    }
}
