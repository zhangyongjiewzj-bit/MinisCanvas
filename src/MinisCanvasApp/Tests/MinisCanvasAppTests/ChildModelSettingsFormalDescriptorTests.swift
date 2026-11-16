import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Child model settings formal descriptors")
struct ChildModelSettingsFormalDescriptorTests {
    @Test @MainActor
    func userOnlyChildControlsHaveLiveDescriptorsAndFeedFrozenPolicy() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChildModelDescriptors-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: directory),
            envStore: EnvVarStore(directory: directory),
            memoryStore: MemoryStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            logManager: LogManager(directory: directory, ringCapacity: 10)
        )
        center.childModelOverridesEnabled = true
        center.childModelThinkingLevelCeiling = .low
        let policy = ChildModelBindingPolicy(settings: center.settings.agent)
        #expect(policy.allowsOverrides)
        #expect(policy.thinkingLevelCeiling == .low)
        for (key, binding) in [
            ("agent.childModelOverridesEnabled", "childModelOverridesEnabled"),
            ("agent.childModelThinkingLevelCeiling", "childModelThinkingLevelCeiling")
        ] {
            let descriptor = try #require(SettingsStateClassification.canonicalDescriptor(for: key))
            #expect(descriptor.stateClass == .canonicalSetting)
            #expect(descriptor.settingsKey?.split(separator: ".").last.map(String.init) == binding)
            #expect(!descriptor.mayOverrideEffectiveValue)
            #expect(SettingsStateClassification.applyState(for: descriptor) == .liveApplied)
            #expect(center.settingsAppliedStateProjection.liveAppliedSettingKeys.contains(key))
            #expect(BL6SettingsCatalog.production.entries.first(where: { $0.id == key }) == nil)
        }
        center.childModelOverridesEnabled = false
        let disabled = ChildModelBindingPolicy(settings: center.settings.agent)
        #expect(!disabled.allowsOverrides)
        #expect(policy.allowsOverrides) // Existing task snapshots keep their policy.
    }
}
