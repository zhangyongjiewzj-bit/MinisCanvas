import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

struct Submodel2777Case: Sendable {
    let provider: ProviderType
    let primary: String
    let auxiliary: String
    let foreignProvider: ProviderType
    let foreignAuxiliary: String
}

/// D-SETA: the canonical general.subModelID binding must survive a real
/// SettingsStore reopen before ChatStore's lightweight-task route consumes it.
@Suite("D-SETA persisted submodel reaches lightweight task provider")
@MainActor
struct SettingsCanonicalSubmodelConsumer2777Tests {
    @Test(arguments: [
        Submodel2777Case(provider: .openAI, primary: "gpt-5.4", auxiliary: "gpt-4o-mini",
                         foreignProvider: .anthropic, foreignAuxiliary: "claude-haiku-4-5"),
        Submodel2777Case(provider: .anthropic, primary: "claude-opus-4-6", auxiliary: "claude-haiku-4-5",
                         foreignProvider: .openAI, foreignAuxiliary: "gpt-4o-mini")
    ])
    func savedProviderScopedSubmodelSurvivesReopenAndReset(_ sample: Submodel2777Case) throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("seta2777-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "seta2777-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let settingsDirectory = root.appendingPathComponent("settings", isDirectory: true)
        func center() -> SettingsCenter {
            SettingsCenter(
                settingsStore: SettingsStore(directory: settingsDirectory),
                envStore: EnvVarStore(directory: root.appendingPathComponent("providers"), keychain: keychain),
                memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
                sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
                logManager: LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 10),
                mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain),
                skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
                usageStore: UsageStore(domain: .suite(suiteName))
            )
        }
        let original = center()
        let chat = ChatStore(
            preferencesDefaults: defaults,
            logManager: LogManager(directory: root.appendingPathComponent("chat-logs"), ringCapacity: 10)
        )
        chat.setProvider(sample.provider)
        #expect(chat.applyPickedModel(modelID: sample.primary))
        chat.lightweightModelReferenceSource = { [weak original] in
            original?.settings.general.subModelReference
        }

        // Invalid blank input from the canonical setting cannot become a
        // routable auxiliary model or displace the selected primary model.
        original.defaultProviderID = sample.provider.rawValue
        original.subModelID = "   "
        #expect(original.settings.general.subModelReference == nil)
        #expect(try chat.lightweightTaskProvider().model.id == sample.primary)

        original.subModelID = sample.auxiliary
        let reference = try #require(original.settings.general.subModelReference)
        #expect(reference.providerID == ProviderModelReference.canonicalProviderID(sample.provider.rawValue))
        #expect(reference.modelID == sample.auxiliary)
        #expect(SettingsStore(directory: settingsDirectory).settings.general.subModelReference == reference)
        #expect(try chat.lightweightTaskProvider().model.id == sample.auxiliary)
        #expect(chat.selectedModelID == sample.primary)

        // A fresh SettingsCenter reads the same durable owner; the production
        // lightweight provider route sees that reopened value on its next call.
        let reopened = center()
        chat.lightweightModelReferenceSource = { [weak reopened] in
            reopened?.settings.general.subModelReference
        }
        #expect(reopened.subModelID == sample.auxiliary)
        #expect(try chat.lightweightTaskProvider().model.id == sample.auxiliary)

        // A provider-scoped reference for another provider can remain a
        // valid durable setting, but cannot cross the active chat namespace.
        reopened.subModelID = nil
        reopened.defaultProviderID = sample.foreignProvider.rawValue
        reopened.subModelID = sample.foreignAuxiliary
        #expect(reopened.settings.general.subModelReference?.providerID
                == ProviderModelReference.canonicalProviderID(sample.foreignProvider.rawValue))
        #expect(try chat.lightweightTaskProvider().model.id == sample.primary)

        reopened.resetToDefaults()
        #expect(reopened.settings.general.subModelReference == nil)
        #expect(SettingsStore(directory: settingsDirectory).settings.general.subModelReference == nil)
        #expect(try chat.lightweightTaskProvider().model.id == sample.primary)
    }
}
