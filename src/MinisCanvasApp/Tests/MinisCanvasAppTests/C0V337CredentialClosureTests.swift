import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

@Suite("C0 v337 credential/profile closure")
struct C0V337CredentialClosureTests {
    private let appArguments = [
        "/Applications/MinisCanvas.app/Contents/MacOS/MinisCanvas",
        RuntimeIsolationProfile.fieldActivationArgument
    ]

    @Test("field launch accepts HOME plus the complete explicit contract and survives root recreation")
    func completeFieldLaunchContractIsStableAcrossRootRecreation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCanvas-C0-v337-field-\(UUID().uuidString)", isDirectory: true)
        let environment = [
            "HOME": "/Users/alice",
            RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
            RuntimeIsolationProfile.fieldActivationRootKey: root.path
        ]
        #expect(!FileManager.default.fileExists(atPath: root.path))
        let first = try RuntimeIsolationProfile.resolveLaunchProfile(
            processEnvironment: environment,
            processArguments: appArguments
        )
        guard case .resolved(let resolvedRoot) = DarwinSystemPathResolver.resolveOutcome(root) else {
            Issue.record("field root did not resolve through the stable Darwin alias contract")
            return
        }
        var resolvedEnvironment = environment
        resolvedEnvironment[RuntimeIsolationProfile.fieldActivationRootKey] = resolvedRoot
        let second = try RuntimeIsolationProfile.resolveLaunchProfile(
            processEnvironment: resolvedEnvironment,
            processArguments: appArguments
        )
        defer {
            if first.isDisposableRootIntact {
                try? first.cleanupDisposableRoots()
            }
        }

        #expect(first.mode == .packagedField)
        #expect(first.rootDirectory.path == resolvedRoot)
        #expect(first.rootDirectory == second.rootDirectory)
        #expect(first.keychainService == second.keychainService)
        #expect(first.userDefaultsSuiteName == second.userDefaultsSuiteName)
        #expect(first.environment["HOME"] == nil)

        // SwiftPM uses the synthetic in-memory backing; its namespaced shared
        // store models the same service surviving a profile reconstruction.
        let key = "C0_V337_SYNTHETIC_API_KEY"
        #expect(first.makeKeychainStore().set("synthetic-value", forKey: key))
        #expect(second.makeKeychainStore().get(key) == "synthetic-value")

        let firstIdentity = try #require(first.disposableRootIdentity)
        #expect(second.disposableRootIdentity == firstIdentity)
        try first.cleanupDisposableRoots()
        #expect(!FileManager.default.fileExists(atPath: resolvedRoot))
        let recreated = try RuntimeIsolationProfile.resolveLaunchProfile(
            processEnvironment: resolvedEnvironment,
            processArguments: appArguments
        )
        defer { try? recreated.cleanupDisposableRoots() }
        #expect(recreated.rootDirectory.path == resolvedRoot)
        #expect(recreated.keychainService == first.keychainService)
        #expect(recreated.userDefaultsSuiteName == first.userDefaultsSuiteName)
        #expect(recreated.environment[RuntimeIsolationProfile.profileDirectoryKey] == resolvedRoot)
        #expect(recreated.makeKeychainStore().get(key) == "synthetic-value")
        #expect(recreated.isDisposableRootIntact)
    }

    @Test("packaged-field composition is namespaced in-memory and credential-operation-free")
    func packagedFieldProductionCompositionIsExplicitAndSideEffectFree() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCanvas-C0-v337-composition-\(UUID().uuidString)", isDirectory: true)
        let profile = try RuntimeIsolationProfile.makePackagedField(
            processEnvironment: [
                RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                RuntimeIsolationProfile.fieldActivationRootKey: root.path
            ],
            processArguments: appArguments
        )
        defer { try? profile.cleanupDisposableRoots() }

        #expect(profile.keychainComposition == .testNamespacedInMemory(namespace: profile.keychainService))
        let store = profile.makeKeychainStore()
        #expect(store.backingKind == .injected)
        // Construction verifies the disposable profile descriptor and injected
        // in-memory factory; no credential operation is performed.
    }

    @Test("HOME-only field launch input rejects closed without activation")
    func homeOnlyFieldInputFailsClosed() {
        do {
            _ = try RuntimeIsolationProfile.makePackagedField(
                processEnvironment: ["HOME": "/Users/alice"],
                processArguments: ["/Applications/MinisCanvas.app/Contents/MacOS/MinisCanvas"]
            )
            Issue.record("HOME-only input unexpectedly activated a packaged profile")
        } catch let error as RuntimeIsolationProfile.IsolationError {
            #expect(error == .missingFieldActivationArgument)
        } catch {
            Issue.record("unexpected HOME-only rejection: \(error)")
        }
    }

    @Test("old UUID namespace and missing key never revive a credential")
    func oldUUIDAndMissingKeyFailClosed() throws {
        let oldProfile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "legacy-uuid",
            processEnvironment: [:],
            processArguments: ["/tmp/C0V337.xctest"]
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCanvas-C0-v337-migration-\(UUID().uuidString)", isDirectory: true)
        let field = try RuntimeIsolationProfile.makePackagedField(
            processEnvironment: [
                RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                RuntimeIsolationProfile.fieldActivationRootKey: root.path
            ],
            processArguments: appArguments
        )
        defer {
            try? oldProfile.cleanupDisposableRoots()
            try? field.cleanupDisposableRoots()
        }

        let key = "LEGACY_API_KEY"
        #expect(oldProfile.makeKeychainStore().set("legacy-only", forKey: key))
        #expect(oldProfile.keychainService != field.keychainService)
        #expect(field.makeKeychainStore().get(key) == nil)

        let metadataURL = field.providerConfigurationDirectory
            .appendingPathComponent(EnvVarStore.fileName)
        let metadataEntry = EnvVarEntry(
            name: key,
            value: "",
            isSecret: true,
            valueInKeychain: true,
            baseURL: "https://example.invalid/v1",
            modelNames: ["legacy-model"]
        )
        try FileManager.default.createDirectory(
            at: metadataURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode([metadataEntry]).write(to: metadataURL, options: .atomic)
        let reloaded = EnvVarStore(
            directory: field.providerConfigurationDirectory,
            keychain: KeychainStore(backing: InMemoryKeychainBacking())
        )
        #expect(reloaded.providerRecords.count == 1)
        #expect(reloaded.getEnvVar(name: key) == nil)
        #expect(reloaded.entry(name: key)?.value == "")
    }
}
