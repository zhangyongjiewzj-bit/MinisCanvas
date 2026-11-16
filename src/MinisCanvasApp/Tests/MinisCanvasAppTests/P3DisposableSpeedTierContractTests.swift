import Foundation
import Testing

@Suite("P3 disposable profile model restoration")
struct P3DisposableSpeedTierContractTests {
    private func appSource() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "src/MinisCanvasApp/Sources/MinisCanvasApp/MinisCanvasApp.swift"
            ),
            encoding: .utf8
        )
    }

    @Test("production keeps restoring the persisted speed-tier default")
    func productionRestoresSpeedTier() throws {
        let source = try appSource()
        let guardStart = try #require(source.range(of: "if !runtimeProfile.isDisposable {"))
        let restore = try #require(source.range(of: "bridge.chat.restoreSpeedTier(settingsCenter.modelSpeedTier)"))
        #expect(guardStart.lowerBound < restore.lowerBound)
        let guardedRegion = String(source[guardStart.lowerBound...])
        #expect(guardedRegion.hasPrefix("if !runtimeProfile.isDisposable {"))
        #expect(guardedRegion.contains("bridge.chat.restoreSpeedTier(settingsCenter.modelSpeedTier)"))
    }

    @Test("fresh disposable profiles do not infer a provider from speed tier")
    func disposableFreshProfileStaysUnselected() throws {
        let source = try appSource()
        let explicitDefault = try #require(
            source.range(of: "bridge.chat.applyDefaultProviderModel(general: settingsCenter.settings.general)")
        )
        let disposableGuard = try #require(source.range(of: "if !runtimeProfile.isDisposable {"))
        #expect(explicitDefault.lowerBound < disposableGuard.lowerBound)
        #expect(source.contains("Disposable/isolated profiles must not infer a user Provider"))
    }

    @Test("explicit profile-local defaults retain the existing readiness fail-closed path")
    func explicitDefaultsRemainOnExistingConsumer() throws {
        let source = try appSource()
        let restoreRange = try #require(source.range(of: "bridge.chat.restoreSpeedTier(settingsCenter.modelSpeedTier)"))
        let defaultRange = try #require(
            source.range(of: "bridge.chat.applyDefaultProviderModel(general: settingsCenter.settings.general)")
        )
        #expect(defaultRange.lowerBound < restoreRange.lowerBound)
        #expect(source.contains("explicit profile-local"))
        #expect(source.contains("readiness gate"))
    }
}
