import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

// MARK: - AJ-28 文件访问权限设置（隐私区入口数据层）
//
// 纪律：
//  · 全程临时目录（绝不读写真实 settings.json）；
//  · 只验证 SettingsCenter 权限逻辑与持久化，不触碰真实文件系统。

@Suite("AJ-28 文件访问权限设置", .serialized)
@MainActor
struct AJ28FileAccessSettingsTests {

    // MARK: 工具

    private func makeCenter() throws -> (SettingsCenter, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AJ28Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: dir),
            envStore: EnvVarStore(directory: dir),
            memoryStore: MemoryStore(directory: dir),
            sessionStore: SessionStore(directory: dir),
            logManager: LogManager(directory: dir, ringCapacity: 50)
        )
        return (center, dir)
    }

    // MARK: 默认值 / 生效值

    /// 未显式配置时：生效授权根 = 当前会话项目目录，生效拒绝目录 = 默认（Application Support）。
    @Test func effectiveDefaultsMatchToolExecutor() throws {
        let (center, _) = try makeCenter()
        #expect(center.fileAccessAllowedRoot == nil)
        #expect(center.fileAccessDeniedRoots.isEmpty)
        #expect(center.effectiveAllowedRoot == "当前会话项目目录")
        #expect(center.effectiveDeniedRoots == BuiltinToolExecutor.defaultDeniedRoots().map { $0.path })
    }

    // MARK: 授权根目录

    /// 设置授权根目录：立即生效并持久化，重载后仍保留。
    @Test func allowedRootPersistsAcrossReload() throws {
        let (center, dir) = try makeCenter()
        let target = "/tmp/AJ28-allowed-root"
        #expect(center.setFileAccessAllowedRoot(target))
        #expect(center.fileAccessAllowedRoot == target)
        #expect(center.effectiveAllowedRoot == target)

        let reloaded = SettingsCenter(
            settingsStore: SettingsStore(directory: dir),
            envStore: EnvVarStore(directory: dir),
            memoryStore: MemoryStore(directory: dir),
            sessionStore: SessionStore(directory: dir),
            logManager: LogManager(directory: dir, ringCapacity: 50)
        )
        #expect(reloaded.fileAccessAllowedRoot == target)
        #expect(reloaded.effectiveAllowedRoot == target)
    }

    /// 设置空字符串 / nil = 恢复默认（会话项目目录）。
    @Test func emptyAllowedRootResetsToSessionProject() throws {
        let (center, _) = try makeCenter()
        center.setFileAccessAllowedRoot("/tmp/some-root")
        #expect(center.effectiveAllowedRoot == "/tmp/some-root")
        center.setFileAccessAllowedRoot("   ")
        #expect(center.fileAccessAllowedRoot == nil)
        #expect(center.effectiveAllowedRoot == "当前会话项目目录")
    }

    /// 相对路径 / 非 / 开头路径被拒绝。
    @Test func invalidAllowedRootRejected() throws {
        let (center, _) = try makeCenter()
        #expect(!center.setFileAccessAllowedRoot("relative/path"))
        #expect(!center.setFileAccessAllowedRoot("~/Documents"))
        #expect(center.fileAccessAllowedRoot == nil)
    }

    // MARK: 被拒绝目录

    /// 添加/移除被拒绝目录，重复添加去重。
    @Test func deniedRootsAddAndRemove() throws {
        let (center, _) = try makeCenter()
        #expect(center.addFileAccessDeniedRoot("/tmp/secret"))
        #expect(center.addFileAccessDeniedRoot("/tmp/secret"))   // 去重
        #expect(center.addFileAccessDeniedRoot("/tmp/other"))
        #expect(center.fileAccessDeniedRoots == ["/tmp/secret", "/tmp/other"])
        #expect(center.effectiveDeniedRoots == ["/tmp/secret", "/tmp/other"])

        center.removeFileAccessDeniedRoot("/tmp/secret")
        #expect(center.fileAccessDeniedRoots == ["/tmp/other"])
    }

    /// 非法被拒绝目录路径（相对路径）被拒绝。
    @Test func invalidDeniedRootRejected() throws {
        let (center, _) = try makeCenter()
        #expect(!center.addFileAccessDeniedRoot("relative/path"))
        #expect(center.fileAccessDeniedRoots.isEmpty)
    }

    // MARK: 重置

    /// 重置恢复默认：授权根回会话项目目录、清空额外拒绝目录。
    @Test func resetRestoresDefaults() throws {
        let (center, _) = try makeCenter()
        center.setFileAccessAllowedRoot("/tmp/custom-root")
        center.addFileAccessDeniedRoot("/tmp/secret")
        center.resetFileAccessRoots()
        #expect(center.fileAccessAllowedRoot == nil)
        #expect(center.fileAccessDeniedRoots.isEmpty)
        #expect(center.effectiveAllowedRoot == "当前会话项目目录")
        #expect(center.effectiveDeniedRoots == BuiltinToolExecutor.defaultDeniedRoots().map { $0.path })
    }

    // MARK: 持久化兼容（老 settings.json 无新字段）

    /// 旧版 settings.json（无 allowedRootPath/deniedRootPaths）解码不炸，回落默认。
    @Test func legacyJsonDecodesWithDefaults() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AJ28Legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let legacyJSON = """
        {"settingsVersion": 2, "privacy": {"redactEnvValues": true, "logLevel": "info", "collectAnalytics": false}}
        """
        let fileURL = dir.appendingPathComponent(SettingsStore.fileName)
        try legacyJSON.data(using: .utf8)!.write(to: fileURL)
        let store = SettingsStore(directory: dir)
        #expect(store.settings.privacy.allowedRootPath == nil)
        #expect(store.settings.privacy.deniedRootPaths.isEmpty)
    }

    // MARK: 联动 ToolExecutor（BridgeStore 装配）

    /// 权限设置经 attachProductionServices 注入执行器：不抛错、引擎装配完成。
    /// （executorBox 为 private，无法直接取内置执行器；此处验证参数接线编译/装配链路成立。）
    @Test func fileAccessParamsSmokeThroughBridge() throws {
        let bridge = BridgeStore()
        let allowed = URL(fileURLWithPath: "/tmp/AJ28-engine-root")
        let denied = [URL(fileURLWithPath: "/tmp/AJ28-denied")]
        bridge.attachProductionServices(
            agentSettings: .default,
            fileAccessAllowedRoot: allowed,
            fileAccessDeniedRoots: denied
        )
        // 装配后引擎可用（Executor 已注入）。
        #expect(bridge.chat.agentEngine.isAvailable)
        // 不传 fileAccess 参数时仍可用默认装配（回归：旧签名行为不变）。
        let bridge2 = BridgeStore()
        bridge2.attachProductionServices(agentSettings: .default)
        #expect(bridge2.chat.agentEngine.isAvailable)
    }
}