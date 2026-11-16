import AppKit
import Darwin
import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

@Suite("bootstrap witness and terminal window behavior")
struct BootstrapWitnessAndTerminationTests {
    private let process = RuntimeIsolationProfile.FieldWitnessProcessIdentity(
        pid: 4242, uid: geteuid(), startSeconds: 1_700_000_000, startMicroseconds: 123_456
    )

    @Test("field witness reports the actual namespaced in-memory factory descriptor")
    func validFieldWitnessUsesActualBacking() throws {
        let profile = try fieldProfile()
        defer { try? profile.cleanupDisposableRoots() }
        let store = profile.makeKeychainStore()
        #expect(store.backingKind == .injected)
        #expect(profile.matchesKeychainBacking(store.backingKind))
        let receipt = try witness(for: profile, backing: store.backingKind)
        #expect(receipt.schema == "miniscanvas.field-root-witness/v2")
        #expect(receipt.keychainBackingKind == "injected")
        #expect(receipt.keychainBackingService == nil)
        #expect(receipt.keychainService == profile.keychainService)
        try profile.writeFieldWitness(receipt)
        let directory = profile.rootDirectory.appendingPathComponent(".miniscanvas-field-witness")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let data = try Data(contentsOf: #require(files.first))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["keychain_backing_kind"] as? String == "injected")
        #expect(json["keychain_backing_service"] == nil)
        #expect(throws: RuntimeIsolationProfile.FieldWitnessError.self) {
            try witness(for: profile, backing: .secItem(service: profile.keychainService))
        }
    }

    @Test("blocked and malformed field launches cannot issue a composition-ready witness")
    func blockedWitnessRefuses() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCanvasWitness-malformed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let invalidRoot = parent.appendingPathComponent("regular-file")
        try Data("synthetic-invalid-root".utf8).write(to: invalidRoot)
        let resolution = RuntimeIsolationProfile.launchProfileResolution(
            processEnvironment: [
                RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                RuntimeIsolationProfile.fieldActivationRootKey: invalidRoot.path
            ],
            processArguments: ["MinisCanvas", RuntimeIsolationProfile.fieldActivationArgument]
        )
        guard case .blocked(let failure) = resolution else {
            Issue.record("regular-file field root must return a typed blocker")
            return
        }
        let profile = MinisCanvasAppMain.failClosedProfile(
            requestedProfile: .production, bootstrapFailure: failure
        )
        defer { try? profile.cleanupDisposableRoots() }
        #expect(profile.mode == .blocked)
        let store = profile.makeKeychainStore()
        #expect(profile.matchesKeychainBacking(store.backingKind))
        #expect(throws: RuntimeIsolationProfile.FieldWitnessError.self) {
            try witness(for: profile, backing: store.backingKind)
        }
        #expect(!FileManager.default.fileExists(
            atPath: profile.rootDirectory.appendingPathComponent(".miniscanvas-field-witness").path
        ))
    }

    @Test("production backing still requires its exact SecItem service and cannot issue a field witness")
    func productionBackingRemainsExact() throws {
        let profile = RuntimeIsolationProfile.production
        // Construction observes only the descriptor; no credential operation.
        let store = profile.makeProductionKeychainStore()
        #expect(store.backingKind == .secItem(service: profile.keychainService))
        #expect(profile.matchesKeychainBacking(store.backingKind))
        #expect(!profile.matchesKeychainBacking(.secItem(service: "synthetic-wrong-service")))
        #expect(!profile.matchesKeychainBacking(.injected))
        #expect(!profile.matchesKeychainBacking(.inMemory))
        #expect(throws: RuntimeIsolationProfile.FieldWitnessError.self) {
            try witness(for: profile, backing: store.backingKind)
        }
    }

    @MainActor
    @Test("direct production-profile constructor with a failure installs only a blocked composition and terminal close policy")
    func directConstructorFailsClosed() throws {
        let failure = RuntimeIsolationProfile.BootstrapFailure.unexpectedProfileResolution
        let app = MinisCanvasAppMain(profile: .production, bootstrapFailure: failure)
        let profile = app.runtimeProfile
        defer { try? profile.cleanupDisposableRoots() }
        #expect(app.bootstrapFailure == failure)
        #expect(profile.mode == .blocked)
        #expect(profile.isDisposable)
        #expect(profile.canvasRuntimeState == .disabled)
        #expect(profile.keychainComposition == .testNamespacedInMemory(namespace: profile.keychainService))
        // Exact profile suite: proves the real constructor's lifecycle write
        // went to its blocked preferences, without reading standard defaults.
        #expect(profile.makeUserDefaults().object(forKey: AppLifecycleGuard.cleanExitDefaultsKey) as? Bool == false)
        let delegate = app.bootstrapTerminationDelegate
        #expect(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
        #expect(delegate.onWillTerminate == nil)
    }

    @MainActor
    @Test("normal delegate keeps the ordinary last-window-close behavior")
    func normalWindowCloseBehaviorRemains() {
        let delegate = MinisCanvasAppDelegate()
        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
        #expect(delegate.onWillTerminate == nil)
    }

    private func fieldProfile() throws -> RuntimeIsolationProfile {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCanvasWitness-actual-\(UUID().uuidString)", isDirectory: true)
        return try RuntimeIsolationProfile.makePackagedField(
            processEnvironment: [
                RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                RuntimeIsolationProfile.fieldActivationRootKey: root.path
            ],
            processArguments: ["MinisCanvas", RuntimeIsolationProfile.fieldActivationArgument]
        )
    }

    private func witness(
        for profile: RuntimeIsolationProfile, backing: KeychainStore.BackingKind
    ) throws -> RuntimeIsolationProfile.FieldWitnessReceipt {
        try profile.makeFieldWitnessReceipt(
            process: process, instanceID: UUID(), createdAt: "2026-10-14T00:00:00Z",
            actualKeychainBacking: backing,
            actualSettingsDirectory: profile.settingsDirectory,
            actualSessionDirectory: profile.sessionDirectory
        )
    }
}
