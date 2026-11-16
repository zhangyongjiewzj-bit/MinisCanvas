import Foundation
import Testing
@testable import MinisCore

// D-MEMORY-02（现场缺陷 F04）/ 验收清单 MEMORY-02：
//   「自动压缩阈值可以调整并持久化。」
// 本文件只锁定 MinisCore canonical 设置模型的 agent.autoCompactThreshold
// 持久化合同（调整→落盘→重开读取、越界/非有限值收敛、落盘字节幂等）。
// 阈值 UI（SettingsCenter.swift / SettingsView.swift）在 wave-2 lane 011
// 独占写集内，属被阻塞的 settings lane，不在本 lane 写集。

/// Unique temp directory per test (tests run in parallel; never share paths).
private func makeTempDir(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MinisCore-CompactThreshold-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func diskThreshold(in store: SettingsStore) throws -> Double? {
    let data = try Data(contentsOf: store.fileURL)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let agent = object["agent"] as? [String: Any] else {
        return nil
    }
    return agent["autoCompactThreshold"] as? Double
}

struct AgentCompactThresholdPersistenceTests {

    // MARK: - 调整并持久化（MEMORY-02 正向合同）

    @Test(arguments: [0.65, 0.5, 0.99, 1.0, 0.0])
    func adjustedThresholdPersistsAcrossStoreReopen(_ value: Double) throws {
        let dir = try makeTempDir("persist")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SettingsStore(directory: dir)
        #expect(store.update(\.agent.autoCompactThreshold, to: value) == .success(.persisted))

        // 模拟「保存/重开」：全新实例必须从磁盘读回同一值。
        let reloaded = SettingsStore(directory: dir)
        #expect(reloaded.settings.agent.autoCompactThreshold == value)
        #expect(try diskThreshold(in: reloaded) == value)
    }

    @Test func validBoundaryZeroAndOneAreNotCoercedToDefault() throws {
        // 0 是消费方（ChatStore.configureBudget）识别的合法特例，
        // BL6 命令面 guard 域同为 0...1；normalize 只收敛域外值。
        #expect(AgentSettings.normalizedAutoCompactThreshold(0) == 0)
        #expect(AgentSettings.normalizedAutoCompactThreshold(1) == 1)
        #expect(AgentSettings.normalizedAutoCompactThreshold(0.8) == 0.8)
    }

    // MARK: - 越界/非有限值收敛（持久化正确性）

    @Test(arguments: [-0.2, 1.5, 42.0, Double.infinity, Double.nan, -Double.infinity])
    func invalidInMemoryCandidateNeverReachesDisk(_ poison: Double) throws {
        let dir = try makeTempDir("poison")
        defer { try? FileManager.default.removeItem(at: dir) }

        var candidate = AppSettings.defaults
        // keyPath 直写模拟被污染的镜像值；持久化边界的 encode 收敛是最后防线。
        candidate.agent.autoCompactThreshold = poison
        let store = SettingsStore(directory: dir)
        #expect(store.replace(with: candidate) == .success(.persisted))

        #expect(try diskThreshold(in: store) == AgentSettings.autoCompactThresholdFallback)
        let reloaded = SettingsStore(directory: dir)
        #expect(reloaded.settings.agent.autoCompactThreshold
                == AgentSettings.autoCompactThresholdFallback)
    }

    @Test func nonFiniteThresholdDoesNotPoisonEntireSettingsFile() throws {
        // 回归锁定：修复前 NaN 会让 JSONEncoder 抛错，整份 settings.json
        // 全部字段的持久化一起失败（.encodingFailed），殃及无关设置。
        let dir = try makeTempDir("nan-group")
        defer { try? FileManager.default.removeItem(at: dir) }

        var candidate = AppSettings.defaults
        candidate.agent.autoCompactThreshold = Double.nan
        candidate.agent.maxLoopIterations = 12
        candidate.privacy.logLevel = .warn
        let store = SettingsStore(directory: dir)
        #expect(store.replace(with: candidate) == .success(.persisted))

        let reloaded = SettingsStore(directory: dir)
        #expect(reloaded.settings.agent.autoCompactThreshold
                == AgentSettings.autoCompactThresholdFallback)
        #expect(reloaded.settings.agent.maxLoopIterations == 12)
        #expect(reloaded.settings.privacy.logLevel == .warn)
    }

    @Test(arguments: [1.5, -0.2, 100.0])
    func tamperedDiskValueIsNormalizedOnLoad(_ poison: Double) throws {
        let dir = try makeTempDir("tamper")
        defer { try? FileManager.default.removeItem(at: dir) }

        // 先物化合法文件，再外部篡改阈值，模拟损坏/手改的 settings.json。
        _ = SettingsStore(directory: dir)
        var object = try JSONSerialization.jsonObject(
            with: Data(contentsOf: dir.appendingPathComponent(SettingsStore.fileName))
        ) as! [String: Any]
        var agent = object["agent"] as! [String: Any]
        agent["autoCompactThreshold"] = poison
        object["agent"] = agent
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: dir.appendingPathComponent(SettingsStore.fileName), options: .atomic)

        let store = SettingsStore(directory: dir)
        #expect(store.settings.agent.autoCompactThreshold
                == AgentSettings.autoCompactThresholdFallback)
        // 其余设置不因单字段越界而被整体重置。
        #expect(store.settings.settingsVersion == AppSettings.currentVersion)
    }

    // MARK: - 构造 / 解码边界

    @Test func initializerAndDecoderConvergeIdentically() throws {
        let direct = AgentSettings(autoCompactThreshold: 2.5)
        let decoded = try JSONDecoder().decode(
            AgentSettings.self,
            from: Data(#"{"autoCompactThreshold":2.5}"#.utf8)
        )
        #expect(direct.autoCompactThreshold == AgentSettings.autoCompactThresholdFallback)
        #expect(decoded == direct)
        #expect(AgentSettings.default.autoCompactThreshold == 0.8)
    }

    @Test func persistenceRoundTripIsByteIdempotent() throws {
        let dir = try makeTempDir("idempotent")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SettingsStore(directory: dir)
        #expect(store.update(\.agent.autoCompactThreshold, to: 0.7) == .success(.persisted))
        let firstBytes = try Data(contentsOf: store.fileURL)
        // 用已收敛的磁盘状态再走一次写入，不应产生新的字节漂移。
        let reopened = SettingsStore(directory: dir)
        #expect(reopened.replace(with: reopened.settings) == .success(.persisted))
        let secondBytes = try Data(contentsOf: reopened.fileURL)
        #expect(firstBytes == secondBytes)
    }
}
