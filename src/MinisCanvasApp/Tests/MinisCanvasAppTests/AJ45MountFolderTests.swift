import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

// MARK: - AJ-45 挂载外部文件夹（设置中心数据层）
//
// 纪律：
//  · 全程临时目录（绝不读写真实 settings.json）；
//  · 只验证 SettingsCenter 挂载逻辑与持久化，不触碰真实文件系统。

@Suite("AJ-45 挂载外部文件夹", .serialized)
@MainActor
struct AJ45MountFolderTests {

    private func makeCenter() throws -> (SettingsCenter, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AJ45Tests-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: 默认值

    @Test func defaultMountedFoldersEmpty() throws {
        let (center, _) = try makeCenter()
        #expect(center.mountedFolderPaths.isEmpty)
        #expect(center.effectiveMountedFolders.isEmpty)
        #expect(center.canMountMoreFolders)
    }

    // MARK: 挂载 / 取消挂载

    @Test func mountAddsToWhitelistAndPersists() throws {
        let (center, dir) = try makeCenter()
        #expect(center.mountFolder("/tmp/AJ45-mount"))
        #expect(center.effectiveMountedFolders == ["/tmp/AJ45-mount"])
        #expect(center.mountedFolderPaths == ["/tmp/AJ45-mount"])

        let reloaded = SettingsCenter(
            settingsStore: SettingsStore(directory: dir),
            envStore: EnvVarStore(directory: dir),
            memoryStore: MemoryStore(directory: dir),
            sessionStore: SessionStore(directory: dir),
            logManager: LogManager(directory: dir, ringCapacity: 50)
        )
        #expect(reloaded.effectiveMountedFolders == ["/tmp/AJ45-mount"])
    }

    @Test func unmountRemovesFromWhitelist() throws {
        let (center, _) = try makeCenter()
        center.mountFolder("/tmp/A")
        center.mountFolder("/tmp/B")
        center.unmountFolder("/tmp/A")
        #expect(center.effectiveMountedFolders == ["/tmp/B"])
    }

    @Test func duplicateMountRejected() throws {
        let (center, _) = try makeCenter()
        #expect(center.mountFolder("/tmp/A"))
        #expect(!center.mountFolder("/tmp/A"))
        #expect(center.effectiveMountedFolders == ["/tmp/A"])
    }

    @Test func invalidPathRejected() throws {
        let (center, _) = try makeCenter()
        #expect(!center.mountFolder("relative/path"))
        #expect(!center.mountFolder("~/Documents"))
        #expect(!center.mountFolder("   "))
        #expect(center.effectiveMountedFolders.isEmpty)
    }

    // MARK: 上限 10

    @Test func limitOfTenEnforced() throws {
        let (center, _) = try makeCenter()
        for i in 0..<PrivacySettings.maxMountedFolders {
            #expect(center.mountFolder("/tmp/mount-\(i)"))
        }
        #expect(center.effectiveMountedFolders.count == PrivacySettings.maxMountedFolders)
        #expect(!center.canMountMoreFolders)
        // 第 11 个被拒绝。
        #expect(!center.mountFolder("/tmp/mount-11th"))
        #expect(center.effectiveMountedFolders.count == PrivacySettings.maxMountedFolders)
        // 取消一个后可再挂载。
        center.unmountFolder("/tmp/mount-0")
        #expect(center.canMountMoreFolders)
        #expect(center.mountFolder("/tmp/mount-11th"))
    }

    @Test func maxMountedFoldersConstantIsTen() {
        #expect(PrivacySettings.maxMountedFolders == 10)
    }

    // MARK: 与 allowedRoot 联动（独立字段）

    @Test func mountedFoldersIndependentOfAllowedRoot() throws {
        let (center, _) = try makeCenter()
        center.setFileAccessAllowedRoot("/tmp/root")
        center.mountFolder("/tmp/mount")
        // 两者互不覆盖：allowedRoot 仍是 /tmp/root，挂载目录独立存在。
        #expect(center.fileAccessAllowedRoot == "/tmp/root")
        #expect(center.effectiveMountedFolders == ["/tmp/mount"])
        // 重置权限只影响 allowedRoot / deniedRoots，不影响挂载目录。
        center.resetFileAccessRoots()
        #expect(center.fileAccessAllowedRoot == nil)
        #expect(center.effectiveMountedFolders == ["/tmp/mount"])
    }
}