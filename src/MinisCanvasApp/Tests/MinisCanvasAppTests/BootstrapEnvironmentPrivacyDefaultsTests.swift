import Foundation
import Testing
@testable import MinisCanvasApp

@Suite("bootstrap environment privacy preferences")
struct BootstrapEnvironmentPrivacyDefaultsTests {
    @Test("blocked bootstrap consumes only its synthetic privacy markings")
    func blockedPrivacyPreferences() throws {
        try assertPrivacyPreferences(in: RuntimeIsolationProfile.blockedProfile())
    }

    @Test("packaged field consumes its profile privacy markings")
    func fieldPrivacyPreferences() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCanvasPrivacyField-\(UUID().uuidString)", isDirectory: true)
        let profile = try RuntimeIsolationProfile.makePackagedField(
            processEnvironment: [
                RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                RuntimeIsolationProfile.fieldActivationRootKey: root.path
            ],
            processArguments: ["MinisCanvas", RuntimeIsolationProfile.fieldActivationArgument]
        )
        try assertPrivacyPreferences(in: profile)
    }

    private func assertPrivacyPreferences(in profile: RuntimeIsolationProfile) throws {
        defer { try? profile.cleanupDisposableRoots() }
        #expect(profile.isDisposable)
        let suiteName = try #require(profile.userDefaultsSuiteName)
        let defaults = profile.makeUserDefaults()
        let markedName = "BOOTSTRAP_PRIVACY_PROBE"
        let unmarkedName = "BOOTSTRAP_PRIVACY_API_KEY"
        defaults.set([markedName], forKey: "envvar.secret_names")
        defaults.set([unmarkedName], forKey: "envvar.nonsecret_names")
        let before = try #require(defaults.persistentDomain(forName: suiteName))

        // This is the same factory used by the production Settings assembly.
        // Opposite-to-default classifications prove it consumes the profile's
        // preferences; no real defaults, credential store or App UI is used.
        let store = profile.makeEnvironmentStore(keychain: profile.makeKeychainStore())
        #expect(store.setEnvVar(name: markedName, value: "synthetic-marked"))
        #expect(store.setEnvVar(name: unmarkedName, value: "synthetic-unmarked"))
        #expect(store.entry(name: markedName)?.isSecret == true)
        #expect(store.entry(name: unmarkedName)?.isSecret == false)
        let after = try #require(defaults.persistentDomain(forName: suiteName))
        #expect(NSDictionary(dictionary: before).isEqual(to: after))
    }
}
