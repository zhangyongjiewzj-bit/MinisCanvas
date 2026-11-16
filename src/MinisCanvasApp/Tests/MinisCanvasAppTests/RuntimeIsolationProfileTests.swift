import Foundation
import Darwin
@testable import MinisCore
import Testing
@testable import MinisCanvasApp

private final class ProfileServiceSpyBacking: KeychainBacking, KeychainReadReporting, @unchecked Sendable {
    private let lock = NSLock()
    private let result: KeychainReadResult
    private var readKeys: [String] = []

    init(result: KeychainReadResult) {
        self.result = result
    }

    func set(_ value: String, forKey key: String) -> Bool { false }
    func get(_ key: String) -> String? {
        if case .found(let value) = readResult(forKey: key) { return value }
        return nil
    }
    func delete(_ key: String) -> Bool { false }

    func readResult(forKey key: String) -> KeychainReadResult {
        lock.lock()
        defer { lock.unlock() }
        readKeys.append(key)
        return result
    }

    var queriedKeys: [String] {
        lock.lock()
        defer { lock.unlock() }
        return readKeys
    }
}

@Suite("runtime isolation profile")
struct RuntimeIsolationProfileTests {
    @Test("field Chat root is private before read-only draft recovery and legacy restart preserves bytes")
    func fieldSessionRootIsPrivateBeforeDraftRecovery() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCanvasField-private-chat-\(UUID().uuidString)")
        let environment = [RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                           RuntimeIsolationProfile.fieldActivationRootKey: root.path]
        let first = try RuntimeIsolationProfile.makePackagedField(
            processEnvironment: environment, processArguments: fieldArguments)
        defer { try? first.cleanupDisposableRoots() }
        let drafts = DraftStore(directory: first.sessionDirectory)
        #expect(drafts.load(key: "composer-queue") == nil)
        #expect(drafts.lastLoadError(for: "composer-queue") == nil)
        #expect(drafts.lastIOError(for: "composer-queue") == nil)
        let marker = first.sessionDirectory.appendingPathComponent("owned-marker.txt")
        let bytes = Data("owned unchanged".utf8)
        try bytes.write(to: marker)
        #expect(chmod(first.sessionDirectory.path, mode_t(0o755)) == 0)
        let restarted = try RuntimeIsolationProfile.makePackagedField(
            processEnvironment: environment, processArguments: fieldArguments)
        var info = stat()
        #expect(lstat(restarted.sessionDirectory.path, &info) == 0)
        #expect((info.st_mode & mode_t(0o7777)) == 0o700)
        #expect(try Data(contentsOf: marker) == bytes)
        let reopened = DraftStore(directory: restarted.sessionDirectory)
        #expect(reopened.load(key: "composer-queue") == nil)
        #expect(reopened.lastIOError(for: "composer-queue") == nil)
    }

    @Test("field profile refuses linked Chat root without changing its target")
    func fieldSessionRootRefusesLink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCanvasField-linked-chat-\(UUID().uuidString)")
        let parent = root.appendingPathComponent("Application Support")
        let target = root.appendingPathComponent("owned-target")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = parent.appendingPathComponent("Chat")
        try FileManager.default.createSymbolicLink(at: chat, withDestinationURL: target)
        #expect(throws: RuntimeIsolationProfile.IsolationError.invalidDisposableRoot) {
            _ = try RuntimeIsolationProfile.makePackagedField(
                processEnvironment: [RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                                     RuntimeIsolationProfile.fieldActivationRootKey: root.path],
                processArguments: fieldArguments)
        }
        var info = stat()
        #expect(lstat(target.path, &info) == 0)
        #expect((info.st_mode & mode_t(0o7777)) == 0o755)
    }

    private func mappedPath(_ url: URL) throws -> String {
        let result: String? = if case .resolved(let path) =
            DarwinSystemPathResolver.resolveOutcome(url) { path } else { nil }
        return try #require(result)
    }

    private let testArguments = ["/tmp/MinisCanvasAppTests.xctest"]
    private let fieldArguments = ["/Applications/MinisCanvas.app/Contents/MacOS/MinisCanvas", RuntimeIsolationProfile.fieldActivationArgument]

    private struct FormalTestFixture {
        let parent: URL
        let environment: [String: String]
        let arguments = ["/tmp/MinisCanvasAppTests.xctest/Contents/MacOS/MinisCanvasAppTests"]

        init() throws {
            // Match the Core contract fixture: Foundation can normalize
            // /private/var back to the symlink /var, which the real root
            // validator must reject. Keep this synthetic root in package scratch.
            let packageRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            // Formal hosts already own a canonical, validated disposable root.
            // Reuse it so a checkout's /private/tmp alias cannot redirect this fixture.
            let fixtureBase = try FormalTestIsolationPaths.resolveCurrentProcess()?.rootDirectory
                ?? packageRoot.appendingPathComponent(".build", isDirectory: true)
            parent = fixtureBase.appendingPathComponent("formal-app-\(UUID().uuidString)", isDirectory: true)
            let scratch = parent.appendingPathComponent("MinisCanvasApp", isDirectory: true)
            let root = scratch.appendingPathComponent("formal-test-root", isDirectory: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            var info = stat()
            guard lstat(root.path, &info) == 0 else {
                throw NSError(domain: "FormalTestFixture", code: 1)
            }
            let runID = "app-\(UUID().uuidString)"
            let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            environment = [
                "MINISCANVAS_TEST_PROFILE": "1",
                "MINISCANVAS_TEST_DIRECTORY": root.path,
                "MINISCANVAS_PROFILE_IDENTITY": "formal-test:\(runID):MinisCanvasApp:\(nonce)",
                "MINISCANVAS_TEST_RUN_ID": runID,
                "MINISCANVAS_TEST_PACKAGE": "MinisCanvasApp",
                "MINISCANVAS_TEST_SCRATCH_DIRECTORY": scratch.path,
                "MINISCANVAS_TEST_ROOT_DEVICE": String(UInt64(info.st_dev)),
                "MINISCANVAS_TEST_ROOT_INODE": String(UInt64(info.st_ino)),
                "MINISCANVAS_TEST_ROOT_OWNER": String(UInt32(info.st_uid))
            ]
        }
    }

    @Test("formal App profile projects one Core root, suite and in-memory Keychain")
    func formalProfileUsesCoreContract() throws {
        let fixture = try FormalTestFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let resolvedPaths = try FormalTestIsolationPaths.resolve(
            environment: fixture.environment,
            arguments: fixture.arguments,
            processName: "xctest"
        )
        let paths = try #require(resolvedPaths)
        let profile = try RuntimeIsolationProfile.resolveLaunchProfile(
            processEnvironment: fixture.environment,
            processArguments: fixture.arguments,
            processName: "xctest"
        )
        #expect(profile.mode == .isolatedTest)
        #expect(profile.rootDirectory == paths.rootDirectory)
        #expect(profile.settingsDirectory == paths.settingsDirectory)
        #expect(profile.sessionDirectory == paths.sessionDirectory)
        #expect(profile.mcpConfigurationURL == paths.mcpFileURL)
        #expect(profile.userDefaultsSuiteName == paths.userDefaultsSuiteName)
        #expect(profile.keychainComposition == .testNamespacedInMemory(namespace: paths.keychainService))
        #expect(profile.makeKeychainStore().configuredLegacyServiceNames.isEmpty)
    }

    @Test("video and scheduler defaults consume the live formal root and suite")
    @MainActor
    func formalDefaultStoresUseCoreContract() throws {
        let resolvedPaths = try FormalTestIsolationPaths.resolveCurrentProcess()
        let paths = try #require(resolvedPaths)
        #expect(VideoTaskStore.defaultDirectory() == paths.minisCoreDirectory)
        #expect(VideoTaskStore.shared.directory == paths.minisCoreDirectory)

        let probeKey = "formal-scheduler-probe-\(UUID().uuidString)"
        let probeValue = UUID().uuidString
        let suite = try #require(UserDefaults(suiteName: paths.userDefaultsSuiteName))
        suite.set(probeValue, forKey: probeKey)
        defer { suite.removeObject(forKey: probeKey) }

        let scheduler = SchedulerTaskStore()
        #expect(scheduler.occurrenceLedgerURL == paths.minisCanvasDirectory
            .appendingPathComponent("scheduler-occurrences-v1.json"))
        #expect(scheduler.defaults.string(forKey: probeKey) == probeValue)

        let explicitLedger = paths.temporaryDirectory
            .appendingPathComponent("explicit-scheduler-\(UUID().uuidString).json")
        let explicitlyBound = SchedulerTaskStore(
            defaults: suite, occurrenceLedgerURL: explicitLedger
        )
        #expect(explicitlyBound.defaults === suite)
        #expect(explicitlyBound.occurrenceLedgerURL == explicitLedger)
    }

    @Test("missing or forged formal contract cannot resolve production")
    func malformedFormalContractIsRejected() throws {
        let fixture = try FormalTestFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        for key in ["MINISCANVAS_TEST_PROFILE", "MINISCANVAS_TEST_DIRECTORY",
                    "MINISCANVAS_PROFILE_IDENTITY", "MINISCANVAS_TEST_ROOT_INODE"] {
            var missing = fixture.environment
            missing.removeValue(forKey: key)
            do {
                _ = try RuntimeIsolationProfile.resolveLaunchProfile(
                    processEnvironment: missing,
                    processArguments: fixture.arguments,
                    processName: "xctest"
                )
                Issue.record("missing formal field resolved: \(key)")
            } catch { }
        }
        var forged = fixture.environment
        forged["MINISCANVAS_TEST_ROOT_INODE"] = "0"
        do {
            _ = try RuntimeIsolationProfile.resolveLaunchProfile(
                processEnvironment: forged,
                processArguments: fixture.arguments,
                processName: "xctest"
            )
            Issue.record("forged root identity resolved")
        } catch { }
        var unsafe = fixture.environment
        unsafe["MINISCANVAS_TEST_DIRECTORY"] = fixture.parent
            .appendingPathComponent("wrong-root", isDirectory: true).path
        do {
            _ = try RuntimeIsolationProfile.resolveLaunchProfile(
                processEnvironment: unsafe,
                processArguments: fixture.arguments,
                processName: "xctest"
            )
            Issue.record("unsafe formal root resolved")
        } catch { }
        do {
            _ = try RuntimeIsolationProfile.resolveLaunchProfile(
                processEnvironment: fixture.environment,
                processArguments: ["/Applications/MinisCanvas.app/Contents/MacOS/MinisCanvas"],
                processName: "MinisCanvas"
            )
            Issue.record("non-test process accepted a formal contract")
        } catch { }
    }

    private func syntheticFieldWitness(
        for profile: RuntimeIsolationProfile,
        instanceID: UUID = UUID(),
        startSeconds: UInt64 = 1_700_000_000
    ) throws -> RuntimeIsolationProfile.FieldWitnessReceipt {
        try profile.makeFieldWitnessReceipt(
            process: .init(pid: 4242, uid: geteuid(),
                           startSeconds: startSeconds, startMicroseconds: 123_456),
            instanceID: instanceID,
            createdAt: "2026-09-26T00:00:00Z",
            actualKeychainBacking: profile.makeKeychainStore().backingKind,
            actualSettingsDirectory: profile.settingsDirectory,
            actualSessionDirectory: profile.sessionDirectory
        )
    }

    @Test("production profile preserves existing durable defaults")
    func productionDefaultsRemainStable() {
        let profile = RuntimeIsolationProfile.production

        #expect(profile.mode == .production)
        #expect(profile.isDisposable == false)
        #expect(profile.sessionDirectory == SessionStore.defaultDirectory)
        #expect(profile.memoryDirectory == SessionStore.defaultDirectory)
        #expect(profile.agentTaskStorePersistenceURL
            == SessionStore.defaultDirectory.appendingPathComponent("agent-tasks-v1.json"))
        #expect(profile.mcpConfigurationURL == MCPServerManager.defaultFileURL())
        #expect(profile.keychainService == KeychainStore.defaultService)
        #expect(profile.keychainComposition
            == .productionSecItem(service: profile.keychainService))
        #expect(profile.allowsExternalNetwork)
        #expect(profile.environment.isEmpty)
        #expect(profile.keychainLegacyServices.isEmpty)
        let store = profile.makeProductionKeychainStore()
        #expect(store.backingKind == .secItem(service: KeychainStore.defaultService))
        #expect(store.configuredLegacyServiceNames.isEmpty)
    }

    @Test("packaged field credential lookup never inherits the production service")
    func packagedFieldNeverQueriesProductionCredentials() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCanvasField-keychain-rebind-\(UUID().uuidString)")
        let profile = try RuntimeIsolationProfile.makePackagedField(
            label: "keychain-rebind",
            processEnvironment: [
                RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                RuntimeIsolationProfile.fieldActivationRootKey: root.path
            ],
            processArguments: fieldArguments
        )
        defer { try? profile.cleanupDisposableRoots() }

        #expect(profile.keychainService != KeychainStore.defaultService)
        #expect(profile.keychainLegacyServices.isEmpty)
        #expect(profile.keychainComposition
            == .testNamespacedInMemory(namespace: profile.keychainService))

        let store = profile.makeKeychainStore()
        let key = "OPENAI_API_KEY"
        #expect(store.readResult(forKey: key) == .missing)
        // NamespacedKeychainBacking wraps the in-memory backing so the store
        // reports an injected backing while remaining entirely non-SecItem.
        #expect(store.backingKind == .injected)
        #expect(store.configuredLegacyServiceNames.isEmpty)
    }

    @Test("diagnostic blocker cannot acquire a production Keychain alias")
    func diagnosticBlockerHasNoProductionCredentialSource() {
        let profile = RuntimeIsolationProfile.blockedProfile()
        defer { try? profile.cleanupDisposableRoots() }

        #expect(profile.mode == .blocked)
        #expect(profile.keychainService != KeychainStore.defaultService)
        #expect(profile.keychainLegacyServices.isEmpty)
        #expect(profile.keychainComposition
            == .testNamespacedInMemory(namespace: profile.keychainService))
    }

    @Test("field witness request cannot silently select production")
    func fieldWitnessRequiresCompleteFieldActivation() throws {
        let witness = RuntimeIsolationProfile.fieldWitnessArgument
        #expect(RuntimeIsolationProfile.fieldWitnessRequested(
            processArguments: [testArguments[0], witness]))
        do {
            _ = try RuntimeIsolationProfile.resolveLaunchProfile(
                processEnvironment: [:], processArguments: [testArguments[0], witness]
            )
            Issue.record("witness-only launch unexpectedly selected production")
        } catch let error as RuntimeIsolationProfile.IsolationError {
            #expect(error == .missingFieldActivationArgument)
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCanvasField-witness-\(UUID().uuidString)")
        let environment = [
            RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
            RuntimeIsolationProfile.fieldActivationRootKey: root.path
        ]
        let arguments = fieldArguments + [witness]
        let profile = try RuntimeIsolationProfile.resolveLaunchProfile(
            processEnvironment: environment, processArguments: arguments
        )
        defer { try? profile.cleanupDisposableRoots() }
        #expect(profile.mode == .packagedField)
        do {
            _ = try RuntimeIsolationProfile.resolveLaunchProfile(
                processEnvironment: environment,
                processArguments: arguments + [witness]
            )
            Issue.record("duplicate field witness request unexpectedly passed")
        } catch let error as RuntimeIsolationProfile.IsolationError {
            #expect(error == .invalidFieldWitnessRequest)
        }
    }

    @Test("field witness is derived from the initialized profile and actual stores")
    func fieldWitnessRejectsMismatchedStores() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCanvasField-witness-values-\(UUID().uuidString)")
        let profile = try RuntimeIsolationProfile.makePackagedField(
            processEnvironment: [
                RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                RuntimeIsolationProfile.fieldActivationRootKey: root.path
            ],
            processArguments: fieldArguments
        )
        defer { try? profile.cleanupDisposableRoots() }

        let receipt = try syntheticFieldWitness(for: profile)
        #expect(receipt.phase == "COMPOSITION_READY")
        #expect(receipt.mode == "packagedField")
        #expect(receipt.rootPath == profile.rootDirectory.path)
        #expect(receipt.rootDevice == profile.disposableRootIdentity?.device)
        #expect(receipt.rootInode == profile.disposableRootIdentity?.inode)
        #expect(receipt.profileIdentity == profile.launchIdentity)
        #expect(receipt.userDefaultsSuite == profile.userDefaultsSuiteName)
        #expect(receipt.keychainService == profile.keychainService)
        #expect(receipt.keychainLegacyServices.isEmpty)
        #expect(receipt.keychainBackingKind == "injected")
        #expect(receipt.keychainBackingService == nil)
        #expect(receipt.settingsDirectory == profile.settingsDirectory.path)
        #expect(receipt.sessionDirectory == profile.sessionDirectory.path)

        do {
            _ = try profile.makeFieldWitnessReceipt(
                process: .init(pid: 4242, uid: geteuid(),
                               startSeconds: 1_700_000_000, startMicroseconds: 123_456),
                instanceID: UUID(), createdAt: "2026-09-26T00:00:00Z",
                actualKeychainBacking: .secItem(service: KeychainStore.defaultService),
                actualSettingsDirectory: profile.settingsDirectory,
                actualSessionDirectory: profile.sessionDirectory
            )
            Issue.record("production Keychain service unexpectedly produced a field witness")
        } catch is RuntimeIsolationProfile.FieldWitnessError {
            // An actual store mismatch must fail before a receipt is written.
        }
        do {
            _ = try profile.makeFieldWitnessReceipt(
                process: .init(pid: 4242, uid: geteuid(),
                               startSeconds: 1_700_000_000, startMicroseconds: 123_456),
                instanceID: UUID(), createdAt: "2026-09-26T00:00:00Z",
                actualKeychainBacking: profile.makeKeychainStore().backingKind,
                actualSettingsDirectory: profile.rootDirectory.appendingPathComponent("wrong-settings"),
                actualSessionDirectory: profile.sessionDirectory
            )
            Issue.record("mismatched settings directory unexpectedly produced a field witness")
        } catch is RuntimeIsolationProfile.FieldWitnessError {
            // The receipt must reflect the constructed store directory.
        }
    }

    @Test("field witness generations are exclusive owner-only files")
    func fieldWitnessWriterDoesNotOverwriteEarlierGeneration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCanvasField-witness-file-\(UUID().uuidString)")
        let profile = try RuntimeIsolationProfile.makePackagedField(
            processEnvironment: [
                RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                RuntimeIsolationProfile.fieldActivationRootKey: root.path
            ],
            processArguments: fieldArguments
        )
        defer { try? profile.cleanupDisposableRoots() }
        let first = try syntheticFieldWitness(for: profile)
        try profile.writeFieldWitness(first)
        let directory = profile.rootDirectory.appendingPathComponent(
            ".miniscanvas-field-witness", isDirectory: true)
        let firstFile = directory.appendingPathComponent(
            "\(first.pid)-\(first.startSeconds)-\(first.startMicroseconds)-\(first.instanceId).json")
        let original = try Data(contentsOf: firstFile)
        let serialized = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        #expect(serialized["phase"] as? String == "COMPOSITION_READY")
        #expect(serialized["instance_id"] as? String == first.instanceId)
        #expect((serialized["root_device"] as? NSNumber)?.uint64Value == first.rootDevice)
        #expect(serialized["keychain_legacy_services"] as? [String] == [])
        var info = stat()
        #expect(lstat(firstFile.path, &info) == 0)
        #expect((info.st_mode & S_IFMT) == S_IFREG)
        #expect((info.st_mode & mode_t(0o077)) == 0)
        #expect(info.st_nlink == 1)
        do {
            try profile.writeFieldWitness(first)
            Issue.record("same-generation witness unexpectedly overwrote prior file")
        } catch is RuntimeIsolationProfile.FieldWitnessError {
            #expect(try Data(contentsOf: firstFile) == original)
        }
        let restarted = try syntheticFieldWitness(
            for: profile, startSeconds: first.startSeconds + 1)
        try profile.writeFieldWitness(restarted)
        #expect(try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil).count == 2)

        var forged = first
        forged = .init(
            schema: forged.schema, phase: forged.phase, instanceId: "../escape",
            pid: forged.pid, uid: forged.uid,
            startSeconds: forged.startSeconds, startMicroseconds: forged.startMicroseconds,
            createdAt: forged.createdAt, mode: forged.mode,
            rootPath: forged.rootPath, rootDevice: forged.rootDevice,
            rootInode: forged.rootInode, profileIdentity: forged.profileIdentity,
            userDefaultsSuite: forged.userDefaultsSuite,
            keychainService: forged.keychainService,
            keychainLegacyServices: forged.keychainLegacyServices,
            keychainBackingKind: forged.keychainBackingKind,
            keychainBackingService: forged.keychainBackingService,
            settingsDirectory: forged.settingsDirectory,
            sessionDirectory: forged.sessionDirectory
        )
        do {
            try profile.writeFieldWitness(forged)
            Issue.record("non-UUID witness filename unexpectedly passed")
        } catch is RuntimeIsolationProfile.FieldWitnessError {
            #expect(try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil).count == 2)
        }
    }

    @Test("isolated profile derives every required root under one disposable root")
    func isolatedProfileDerivesRequiredRoots() throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "roots",
            processEnvironment: [:],
            processArguments: testArguments
        )
        defer { try? profile.cleanupDisposableRoots() }

        let root = profile.rootDirectory.path
        for path in profile.disposableRoots {
            #expect(
                path.path == root || path.path.hasPrefix(root + "/")
            )
        }
        #expect(profile.applicationSupportDirectory != profile.rootDirectory)
        #expect(profile.keychainLegacyServices.isEmpty)
        #expect(profile.sessionDirectory != RuntimeIsolationProfile.production.sessionDirectory)
        #expect(profile.minisCanvasDirectory != profile.sessionDirectory)
        #expect(profile.canvasRuntimeDirectory == profile.minisCanvasDirectory)
        #expect(profile.allowsExternalNetwork == false)
        #expect(profile.mcpConfigurationURL.path.hasPrefix(root + "/"))
        #expect(profile.providerReadinessURL.path.hasPrefix(root + "/"))
        #expect(profile.logDirectory.path.hasPrefix(root + "/"))
        #expect(profile.hermesSkillsDirectory.path.hasPrefix(root + "/"))
        #expect(profile.skillStateURL.path.hasPrefix(root + "/"))
        #expect(profile.environment[RuntimeIsolationProfile.profileMarkerKey] == "1")
        #expect(
            profile.environment[RuntimeIsolationProfile.profileDirectoryKey]
                == profile.rootDirectory.path
        )
    }

    @Test("packaged field logger stays inside the disposable profile")
    func packagedFieldLoggerStaysOutsideProductionSupport() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCanvasField-logger-\(UUID().uuidString)")
        let profile = try RuntimeIsolationProfile.makePackagedField(
            label: "logger",
            processEnvironment: [
                RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                RuntimeIsolationProfile.fieldActivationRootKey: root.path
            ],
            processArguments: fieldArguments
        )
        defer { try? profile.cleanupDisposableRoots() }

        let logger = profile.makeLogManager()
        logger.info("field-only", category: "Isolation")
        let file = try #require(logger.logFileURL())
        #expect(file.path == profile.logDirectory.appendingPathComponent("app.log").path)
        #expect(file.path.hasPrefix(profile.rootDirectory.path + "/"))
        #expect(
            file.standardizedFileURL
                != RuntimeIsolationProfile.production.logDirectory
                    .appendingPathComponent("app.log")
                    .standardizedFileURL
        )
    }

    @Test("isolated keychain uses a profile-scoped namespace")
    func isolatedKeychainNamespacesDoNotCrossRead() throws {
        let first = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "keychain-a",
            processEnvironment: [:],
            processArguments: testArguments
        )
        let second = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "keychain-b",
            processEnvironment: [:],
            processArguments: testArguments
        )
        defer {
            try? first.cleanupDisposableRoots()
            try? second.cleanupDisposableRoots()
        }

        #expect(first.keychainService != second.keychainService)
        let firstStore = first.makeKeychainStore()
        let secondStore = second.makeKeychainStore()
        #expect(firstStore.set("redacted-test-value", forKey: "OPENAI_API_KEY"))
        #expect(firstStore.get("OPENAI_API_KEY") == "redacted-test-value")
        #expect(secondStore.get("OPENAI_API_KEY") == nil)
    }

    @Test("packaged field defaults stay outside an independent preferences domain")
    func packagedFieldUserDefaultsStayOutsideProductionDomain() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCanvasField-defaults-\(UUID().uuidString)")
        let profile = try RuntimeIsolationProfile.makePackagedField(
            label: "defaults-domain",
            processEnvironment: [
                RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                RuntimeIsolationProfile.fieldActivationRootKey: root.path
            ],
            processArguments: fieldArguments
        )
        let key = "miniscanvas.field.sentinel.\(UUID().uuidString)"
        let controlSuiteName = "com.miniscanvas.test.field-control.\(UUID().uuidString)"
        guard let controlDefaults = UserDefaults(suiteName: controlSuiteName),
              let fieldSuiteName = profile.userDefaultsSuiteName else {
            Issue.record("Synthetic preferences suite is unavailable")
            try? profile.cleanupDisposableRoots()
            return
        }
        let fieldDefaults = profile.makeUserDefaults()
        controlDefaults.set("control", forKey: key)
        defer {
            controlDefaults.removePersistentDomain(forName: controlSuiteName)
            fieldDefaults.removePersistentDomain(forName: fieldSuiteName)
            try? profile.cleanupDisposableRoots()
        }

        #expect(fieldDefaults.string(forKey: key) == nil)
        fieldDefaults.set("field", forKey: key)
        #expect(controlDefaults.string(forKey: key) == "control")
        #expect(profile.makeUserDefaults().string(forKey: key) == "field")
        #expect(profile.userDefaultsSuiteName != nil)
    }

    @Test("packaged field defaults reach every production preference consumer")
    @MainActor
    func packagedFieldDefaultsReachAllProductionPreferenceConsumers() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCanvasField-consumers-\(UUID().uuidString)")
        let profile = try RuntimeIsolationProfile.makePackagedField(
            label: "preference-consumers",
            processEnvironment: [
                RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                RuntimeIsolationProfile.fieldActivationRootKey: root.path
            ],
            processArguments: fieldArguments
        )
        defer { try? profile.cleanupDisposableRoots() }
        let defaults = profile.makeUserDefaults()
        defaults.set(444.0, forKey: "canvas.textInspectorWidth")

        let bridge = BridgeStore(
            preferencesDefaults: defaults,
            sessionDocumentStore: SessionDocumentStore(directory: profile.sessionDirectory),
            memoryStore: MemoryStore(directory: profile.memoryDirectory)
        )
        #expect(bridge.preferencesDefaults === defaults)
        #expect(bridge.chat.preferencesDefaults === defaults)
        #expect(bridge.canvas.textInspectorWidth == 444.0)

        bridge.chat.loadGroups()
        #expect(bridge.chat.groups.isEmpty)
        _ = try #require(bridge.chat.createGroup(named: "field-only"))
        let reloaded = ChatStore(preferencesDefaults: defaults)
        reloaded.loadGroups()
        #expect(reloaded.groups.map(\.name) == ["field-only"])

        _ = ContentView(bridge: bridge)
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = packageRoot.appendingPathComponent("Sources/MinisCanvasApp")
        let directStandardConsumers = [
            "ChatStore.swift",
            "ModelMenuButton.swift",
            "CanvasStore.swift"
        ]
        for file in directStandardConsumers {
            let source = try String(
                contentsOf: sourceRoot.appendingPathComponent(file),
                encoding: .utf8
            )
            #expect(source.contains("UserDefaults.standard") == false)
        }
        let contentViewSource = try String(
            contentsOf: sourceRoot.appendingPathComponent("ContentView.swift"),
            encoding: .utf8
        )
        let expectedPreferenceConsumers = [
            "storedSessionSidebarCollapsed": "minisCanvas.sessionSidebarCollapsed",
            "storedCompanionWidth": "minisCanvas.companionWidth",
            "storedContextPanelWidth": "minisCanvas.contextPanelWidth",
            "storedContextPanelCollapsed": "minisCanvas.contextPanelCollapsed",
            "storedMainPaneRawValue": "minisCanvas.mainPane"
        ]
        let actualPreferenceConsumers = Set(
            contentViewSource
                .split(separator: "\n")
                .compactMap { line -> String? in
                    let trimmed = String(line).trimmingCharacters(in: .whitespaces)
                    guard trimmed.hasPrefix("_"), trimmed.contains(" = AppStorage(") else {
                        return nil
                    }
                    return trimmed.split(separator: " ", maxSplits: 1).first.map {
                        String($0.dropFirst())
                    }
                }
        )
        #expect(actualPreferenceConsumers == Set(expectedPreferenceConsumers.keys))
        for (consumer, key) in expectedPreferenceConsumers {
            let marker = "_\(consumer) = AppStorage("
            guard let start = contentViewSource.range(of: marker),
                  let end = contentViewSource.range(
                      of: "\n        )",
                      range: start.upperBound..<contentViewSource.endIndex
                  ) else {
                Issue.record("missing AppStorage initializer for ContentView.\(consumer)")
                continue
            }
            let initializer = contentViewSource[start.lowerBound..<end.upperBound]
            #expect(initializer.contains("\"\(key)\""))
            #expect(initializer.contains("store: defaults"))
        }
        let gatewayDefaultsBinding = contentViewSource.range(
            of: "let defaults = bridge.preferencesDefaults"
        )?.lowerBound
        let gatewayInjection = contentViewSource.range(
            of: "initialValue: bridge.sidebarWidthSetting"
        )?.lowerBound
        #expect(gatewayDefaultsBinding != nil && gatewayInjection != nil)
        if let gatewayDefaultsBinding, let gatewayInjection {
            #expect(gatewayDefaultsBinding < gatewayInjection)
        }
        let sidebarWidthContractSource = try String(
            contentsOf: sourceRoot.appendingPathComponent("SessionSidebarWidthContract.swift"),
            encoding: .utf8
        )
        let settingsKeyMarker = "static let settingsKey = \"minisCanvas.sidebarWidth\""
        #expect(sidebarWidthContractSource.contains(settingsKeyMarker))
    }

    @Test("isolated environment does not inherit credentials")
    func isolatedEnvironmentDoesNotInheritCredentials() throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "credentials",
            processEnvironment: [
                "OPENAI_API_KEY": "must-not-copy",
                "HOME": "/Users/should-not-copy"
            ],
            processArguments: testArguments
        )
        defer { try? profile.cleanupDisposableRoots() }

        #expect(profile.environment["OPENAI_API_KEY"] == nil)
        #expect(profile.environment["HOME"] == nil)
        #expect(profile.environment.count == 2)
    }

    @Test("non-test activation fails closed")
    func nonTestActivationFailsClosed() {
        do {
            _ = try RuntimeIsolationProfile.makeIsolatedTest(
                label: "production-process",
                processEnvironment: [
                    RuntimeIsolationProfile.profileMarkerKey: "1"
                ],
                processArguments: [
                    "/Applications/MinisCanvasApp.app/Contents/MacOS/MinisCanvasApp"
                ]
            )
            Issue.record("non-test process unexpectedly received an isolated profile")
        } catch let error as RuntimeIsolationProfile.IsolationError {
            #expect(error == .notRunningInTestProcess)
        } catch {
            Issue.record("unexpected isolation error: \(error)")
        }
    }

    @Test("cleanup removes only the disposable profile root")
    func cleanupDoesNotTouchSiblingData() throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "cleanup",
            processEnvironment: [:],
            processArguments: testArguments
        )
        let sibling = profile.rootDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("MinisCanvasAppTests-sibling-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sibling) }

        try profile.cleanupDisposableRoots()

        #expect(FileManager.default.fileExists(atPath: profile.rootDirectory.path) == false)
        #expect(FileManager.default.fileExists(atPath: sibling.path))
    }

    @Test("launch without field activation preserves production defaults")
    func launchWithoutFieldActivationRemainsProduction() throws {
        let profile = try RuntimeIsolationProfile.resolveLaunchProfile(
            processEnvironment: [
                "HOME": "/Users/production",
                "TMPDIR": "/tmp/legacy-only",
                "XDG_CONFIG_HOME": "/tmp/legacy-config"
            ],
            processArguments: ["/Applications/MinisCanvas.app/Contents/MacOS/MinisCanvas"]
        )

        #expect(profile == .production)
    }

    @Test("packaged field activation requires the explicit flag and environment")
    func packagedFieldActivationUsesExactContract() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCanvasField-\(UUID().uuidString)", isDirectory: true)
        let profile = try RuntimeIsolationProfile.makePackagedField(
            processEnvironment: [
                RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                RuntimeIsolationProfile.fieldActivationRootKey: root.path
            ],
            processArguments: fieldArguments
        )
        defer { try? profile.cleanupDisposableRoots() }

        #expect(profile.mode == .packagedField)
        #expect(profile.isDisposable)
        #expect(profile.allowsExternalNetwork == false)
        #expect(profile.environment[RuntimeIsolationProfile.fieldActivationMarkerKey] == "1")
        #expect(
            profile.environment[RuntimeIsolationProfile.fieldActivationRootKey]
                == profile.rootDirectory.path
        )
        #expect(
            profile.environment[RuntimeIsolationProfile.profileIdentityKey]
                == profile.launchIdentity
        )
    }

    @Test("failed Canvas states expose no runtime path")
    func failedCanvasStatesFailClosedAtProfileBoundary() throws {
        for state in [
            RuntimeIsolationProfile.CanvasRuntimeState.absent,
            .disabled,
            .corrupt
        ] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "MinisCanvasField-canvas-\(state.rawValue)-\(UUID().uuidString)",
                    isDirectory: true
                )
            let profile = try RuntimeIsolationProfile.makePackagedField(
                label: "canvas-\(state.rawValue)",
                processEnvironment: [
                    RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                    RuntimeIsolationProfile.fieldActivationRootKey: root.path
                ],
                processArguments: fieldArguments,
                canvasRuntimeState: state
            )
            defer { try? profile.cleanupDisposableRoots() }

            #expect(profile.canvasRuntimeState == state)
            #expect(profile.canvasRuntimeDirectory == nil)
            #expect(profile.minisCanvasDirectory != profile.sessionDirectory)
            #expect(profile.applicationSupportDirectory != profile.minisCanvasDirectory)
            #expect(profile.temporaryDirectory != profile.minisCanvasDirectory)
        }
    }

    @Test("field profile identity is stable across native temp path aliases")
    func fieldProfileIdentitySurvivesRestartPathAlias() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL.path
        let aliasBase: String?
        if temporaryRoot.hasPrefix("/private/var/") {
            aliasBase = String(temporaryRoot.dropFirst("/private".count))
        } else if temporaryRoot.hasPrefix("/var/") {
            aliasBase = "/private" + temporaryRoot
        } else {
            aliasBase = nil
        }
        #expect(aliasBase != nil)
        guard let aliasBase else { return }

        let canonicalRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MinisCanvasField-restart-alias-\(UUID().uuidString)",
                isDirectory: true
            )
        let aliasedRoot = URL(fileURLWithPath: aliasBase, isDirectory: true)
            .appendingPathComponent(canonicalRoot.lastPathComponent, isDirectory: true)
        let canonical = try RuntimeIsolationProfile.makePackagedField(
            label: "restart-alias",
            processEnvironment: [
                RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                RuntimeIsolationProfile.fieldActivationRootKey: canonicalRoot.path
            ],
            processArguments: fieldArguments
        )
        let restarted = try RuntimeIsolationProfile.makePackagedField(
            label: "restart-alias",
            processEnvironment: [
                RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                RuntimeIsolationProfile.fieldActivationRootKey: aliasedRoot.path
            ],
            processArguments: fieldArguments
        )
        defer {
            try? canonical.cleanupDisposableRoots()
            try? restarted.cleanupDisposableRoots()
        }

        #expect(canonical.rootDirectory == restarted.rootDirectory)
        #expect(canonical.launchIdentity == restarted.launchIdentity)
        #expect(canonical.keychainService == restarted.keychainService)
        #expect(canonical.userDefaultsSuiteName == restarted.userDefaultsSuiteName)
        #expect(
            canonical.environment[RuntimeIsolationProfile.profileIdentityKey]
                == restarted.environment[RuntimeIsolationProfile.profileIdentityKey]
        )
    }

    @Test("profile reload rejects a symlink identity collision")
    func profileReloadRejectsSymlinkIdentityCollision() throws {
        let targetRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MinisCanvasField-reload-target-\(UUID().uuidString)",
                isDirectory: true
            )
        let symlinkRoot = targetRoot.deletingLastPathComponent()
            .appendingPathComponent(
                "MinisCanvasField-reload-symlink-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: targetRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: symlinkRoot,
            withDestinationURL: targetRoot
        )
        defer { try? FileManager.default.removeItem(at: symlinkRoot) }

        let first = try RuntimeIsolationProfile.makePackagedField(
            label: "reload-collision",
            processEnvironment: [
                RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                RuntimeIsolationProfile.fieldActivationRootKey: targetRoot.path
            ],
            processArguments: fieldArguments
        )
        defer { try? first.cleanupDisposableRoots() }

        do {
            _ = try RuntimeIsolationProfile.makePackagedField(
                label: "reload-collision",
                processEnvironment: [
                    RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                    RuntimeIsolationProfile.fieldActivationRootKey: symlinkRoot.path
                ],
                processArguments: fieldArguments
            )
            Issue.record("symlinked profile reload unexpectedly succeeded")
        } catch let error as RuntimeIsolationProfile.IsolationError {
            #expect(error == .invalidDisposableRoot)
        } catch {
            Issue.record("unexpected symlink collision error: \(error)")
        }
    }

    @Test("profile root replacement trips the inode fence")
    func profileRootReplacementFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MinisCanvasField-inode-fence-\(UUID().uuidString)",
                isDirectory: true
            )
        let displacedRoot = root.deletingLastPathComponent()
            .appendingPathComponent(
                "MinisCanvasField-inode-displaced-\(UUID().uuidString)",
                isDirectory: true
            )
        let replacementRoot = root.deletingLastPathComponent()
            .appendingPathComponent(
                "MinisCanvasField-inode-replacement-\(UUID().uuidString)",
                isDirectory: true
            )
        let profile = try RuntimeIsolationProfile.makePackagedField(
            label: "inode-fence",
            processEnvironment: [
                RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                RuntimeIsolationProfile.fieldActivationRootKey: root.path
            ],
            processArguments: fieldArguments
        )
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: displacedRoot)
            try? FileManager.default.removeItem(at: replacementRoot)
        }

        try FileManager.default.createDirectory(
            at: replacementRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: root, to: displacedRoot)
        try FileManager.default.moveItem(at: replacementRoot, to: root)

        #expect(profile.isDisposableRootIntact == false)
        #expect(profile.canvasRuntimeDirectory == nil)
        do {
            try profile.validateDisposableRootIdentity()
            Issue.record("replaced profile root unexpectedly passed inode fence")
        } catch let error as RuntimeIsolationProfile.IsolationError {
            #expect(error == .invalidDisposableRoot)
        } catch {
            Issue.record("unexpected inode fence error: \(error)")
        }
        do {
            try profile.cleanupDisposableRoots()
            Issue.record("cleanup unexpectedly consumed replaced profile root")
        } catch let error as RuntimeIsolationProfile.IsolationError {
            #expect(error == .invalidDisposableRoot)
        } catch {
            Issue.record("unexpected cleanup fence error: \(error)")
        }
        #expect(FileManager.default.fileExists(atPath: root.path))
        #expect(FileManager.default.fileExists(atPath: displacedRoot.path))
    }

    @Test("cleanup rejects nested symlink escape")
    func cleanupRejectsNestedSymlinkEscape() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MinisCanvasField-nested-symlink-\(UUID().uuidString)",
                isDirectory: true
            )
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent(
                "MinisCanvasField-outside-symlink-\(UUID().uuidString)",
                isDirectory: true
            )
        let profile = try RuntimeIsolationProfile.makePackagedField(
            label: "nested-symlink",
            processEnvironment: [
                RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                RuntimeIsolationProfile.fieldActivationRootKey: root.path
            ],
            processArguments: fieldArguments
        )
        let link = profile.sessionDirectory
            .appendingPathComponent("escape", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: link)
            try? profile.cleanupDisposableRoots()
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: outside
        )

        do {
            try profile.cleanupDisposableRoots()
            Issue.record("nested symlink unexpectedly passed cleanup admission")
        } catch let error as RuntimeIsolationProfile.IsolationError {
            #expect(error == .invalidDisposableRoot)
        } catch {
            Issue.record("unexpected nested symlink error: \(error)")
        }
        #expect(profile.canvasRuntimeDirectory != nil)
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test("cleanup rejects hardlink escape")
    func cleanupRejectsHardlinkEscape() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MinisCanvasField-hardlink-\(UUID().uuidString)",
                isDirectory: true
            )
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent(
                "MinisCanvasField-outside-hardlink-\(UUID().uuidString)",
                isDirectory: false
            )
        let profile = try RuntimeIsolationProfile.makePackagedField(
            label: "hardlink",
            processEnvironment: [
                RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                RuntimeIsolationProfile.fieldActivationRootKey: root.path
            ],
            processArguments: fieldArguments
        )
        let link = profile.sessionDirectory
            .appendingPathComponent("shared.json", isDirectory: false)
        defer {
            try? FileManager.default.removeItem(at: link)
            try? profile.cleanupDisposableRoots()
            try? FileManager.default.removeItem(at: outside)
        }
        try Data("outside".utf8).write(to: outside, options: .atomic)
        try FileManager.default.linkItem(at: outside, to: link)

        do {
            try profile.cleanupDisposableRoots()
            Issue.record("hardlink unexpectedly passed cleanup admission")
        } catch let error as RuntimeIsolationProfile.IsolationError {
            #expect(error == .invalidDisposableRoot)
        } catch {
            Issue.record("unexpected hardlink error: \(error)")
        }
        #expect(profile.canvasRuntimeDirectory != nil)
        #expect(String(data: try Data(contentsOf: outside), encoding: .utf8) == "outside")
    }

    @Test("field activation rejects a missing explicit flag")
    func fieldActivationRequiresArgument() {
        do {
            _ = try RuntimeIsolationProfile.resolveLaunchProfile(
                processEnvironment: [
                    RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                    RuntimeIsolationProfile.fieldActivationRootKey: "/tmp/miniscanvas-field"
                ],
                processArguments: ["/Applications/MinisCanvas.app/Contents/MacOS/MinisCanvas"]
            )
            Issue.record("field activation without the explicit argument unexpectedly succeeded")
        } catch let error as RuntimeIsolationProfile.IsolationError {
            #expect(error == .missingFieldActivationArgument)
        } catch {
            Issue.record("unexpected field activation error: \(error)")
        }
    }

    @Test("field activation rejects missing or malformed environment")
    func fieldActivationRequiresExactEnvironment() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCanvasField-\(UUID().uuidString)", isDirectory: true)
        do {
            _ = try RuntimeIsolationProfile.resolveLaunchProfile(
                processEnvironment: [
                    RuntimeIsolationProfile.fieldActivationRootKey: root.path
                ],
                processArguments: fieldArguments
            )
            Issue.record("field activation without marker unexpectedly succeeded")
        } catch let error as RuntimeIsolationProfile.IsolationError {
            #expect(error == .invalidFieldActivationEnvironment)
        } catch {
            Issue.record("unexpected missing-marker error: \(error)")
        }

        do {
            _ = try RuntimeIsolationProfile.resolveLaunchProfile(
                processEnvironment: [
                    RuntimeIsolationProfile.fieldActivationMarkerKey: "1"
                ],
                processArguments: fieldArguments
            )
            Issue.record("field activation without root unexpectedly succeeded")
        } catch let error as RuntimeIsolationProfile.IsolationError {
            #expect(error == .missingFieldActivationEnvironment)
        } catch {
            Issue.record("unexpected missing-root error: \(error)")
        }

        do {
            _ = try RuntimeIsolationProfile.resolveLaunchProfile(
                processEnvironment: [
                    RuntimeIsolationProfile.fieldActivationMarkerKey: "true",
                    RuntimeIsolationProfile.fieldActivationRootKey: root.path
                ],
                processArguments: fieldArguments
            )
            Issue.record("malformed field marker unexpectedly succeeded")
        } catch let error as RuntimeIsolationProfile.IsolationError {
            #expect(error == .invalidFieldActivationEnvironment)
        } catch {
            Issue.record("unexpected malformed-marker error: \(error)")
        }
    }

    @Test("field root must be absolute normalized and inside system temp")
    func fieldRootValidationFailsClosed() {
        let temporaryRoot = FileManager.default.temporaryDirectory.path
        let invalidRoots = [
            "relative-field-root",
            "/tmp/miniscanvas-field-outside",
            temporaryRoot + "/../miniscanvas-field-escape"
        ]

        for root in invalidRoots {
            do {
                _ = try RuntimeIsolationProfile.makePackagedField(
                    processEnvironment: [
                        RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                        RuntimeIsolationProfile.fieldActivationRootKey: root
                    ],
                    processArguments: fieldArguments
                )
                Issue.record("invalid field root unexpectedly accepted: \(root)")
            } catch let error as RuntimeIsolationProfile.IsolationError {
                #expect(error == .invalidDisposableRoot)
            } catch {
                Issue.record("unexpected invalid-root error: \(error)")
            }
        }
    }

    @Test("field root accepts the native temp /var alias after resolved containment")
    func fieldRootAcceptsNativeTempAlias() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL.path
        let aliasBase: String?
        if temporaryRoot.hasPrefix("/private/var/") {
            aliasBase = String(temporaryRoot.dropFirst("/private".count))
        } else if temporaryRoot.hasPrefix("/var/") {
            aliasBase = "/private" + temporaryRoot
        } else {
            aliasBase = nil
        }
        #expect(aliasBase != nil)
        guard let aliasBase else { return }

        let aliasedRoot = URL(fileURLWithPath: aliasBase, isDirectory: true)
            .appendingPathComponent(
                "MinisCanvasField-native-temp-alias-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: aliasedRoot,
            withIntermediateDirectories: true
        )
        let profile = try RuntimeIsolationProfile.makePackagedField(
            processEnvironment: [
                RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                RuntimeIsolationProfile.fieldActivationRootKey: aliasedRoot.path
            ],
            processArguments: fieldArguments
        )
        defer { try? profile.cleanupDisposableRoots() }

        let resolvedTemporaryRoot = FileManager.default.temporaryDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let resolvedProfileRoot = profile.rootDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
        #expect(
            resolvedProfileRoot.path.hasPrefix(resolvedTemporaryRoot.path + "/")
        )
        #expect(profile.mode == .packagedField)
        #expect(profile.rootDirectory.path == (try mappedPath(resolvedProfileRoot)))
    }

    @Test("field profile exposes one identity and derives every required root")
    func fieldProfileDerivesAllRequiredRootsAndIdentity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCanvasField-\(UUID().uuidString)", isDirectory: true)
        let profile = try RuntimeIsolationProfile.makePackagedField(
            label: "preview",
            processEnvironment: [
                RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                RuntimeIsolationProfile.fieldActivationRootKey: root.path
            ],
            processArguments: fieldArguments
        )
        defer { try? profile.cleanupDisposableRoots() }

        let normalizedRoot = try mappedPath(root)
        #expect(profile.launchIdentity.hasPrefix("packagedField:preview:"))
        for path in profile.disposableRoots {
            let candidate = path.path
            #expect(candidate == normalizedRoot || candidate.hasPrefix(normalizedRoot + "/"))
        }
        #expect(profile.agentTaskStorePersistenceURL.path.hasPrefix(normalizedRoot + "/"))
        #expect(profile.mcpConfigurationURL.path.hasPrefix(normalizedRoot + "/"))
        #expect(profile.providerReadinessURL.path.hasPrefix(normalizedRoot + "/"))
    }

    @Test("field keychain is namespaced and never reads production")
    func fieldKeychainDoesNotReadProductionCredentials() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCanvasField-\(UUID().uuidString)", isDirectory: true)
        let profile = try RuntimeIsolationProfile.makePackagedField(
            processEnvironment: [
                RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                RuntimeIsolationProfile.fieldActivationRootKey: root.path
            ],
            processArguments: fieldArguments
        )
        defer { try? profile.cleanupDisposableRoots() }

        let fieldStore = profile.makeKeychainStore()
        #expect(fieldStore.get("OPENAI_API_KEY") == nil)
        #expect(fieldStore.set("field-only", forKey: "OPENAI_API_KEY"))
        #expect(fieldStore.get("OPENAI_API_KEY") == "field-only")
        #expect(profile.keychainService != KeychainStore.defaultService)
    }

    @Test("field cleanup removes only the validated disposable root")
    func fieldCleanupDoesNotTouchSiblingRoots() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCanvasField-\(UUID().uuidString)", isDirectory: true)
        let profile = try RuntimeIsolationProfile.makePackagedField(
            processEnvironment: [
                RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                RuntimeIsolationProfile.fieldActivationRootKey: root.path
            ],
            processArguments: fieldArguments
        )
        let sibling = root.deletingLastPathComponent()
            .appendingPathComponent("MinisCanvasField-sibling-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sibling) }

        try profile.cleanupDisposableRoots()

        #expect(FileManager.default.fileExists(atPath: root.path) == false)
        #expect(FileManager.default.fileExists(atPath: sibling.path))
    }

    @Test("deterministic 50k and 100k transcripts stay inside an isolated profile")
    func longTranscriptFixtureBindsToIsolatedProfileContainment() throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "performance-transcript",
            processEnvironment: [:],
            processArguments: testArguments
        )
        defer { try? profile.cleanupDisposableRoots() }

        let fixtureDirectory = profile.sessionDirectory
            .appendingPathComponent("performance-transcripts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: fixtureDirectory,
            withIntermediateDirectories: true
        )

        let rootPath = profile.rootDirectory.standardizedFileURL.path
        let sessionPath = profile.sessionDirectory.standardizedFileURL.path
        #expect(sessionPath.hasPrefix(rootPath + "/"))

        let messageID = UUID(uuidString: "00000000-0000-4000-8000-000000000979")!
        let timestamp = Date(timeIntervalSince1970: 0)
        for characterCount in [50_000, 100_000] {
            let content = String(repeating: "x", count: characterCount)
            let message = ChatMessageUI(
                id: messageID,
                role: .assistant,
                content: content,
                timestamp: timestamp
            )
            let encoded = try JSONEncoder().encode([message])
            let fixtureURL = fixtureDirectory.appendingPathComponent(
                "transcript-\(characterCount).json",
                isDirectory: false
            )
            try encoded.write(to: fixtureURL, options: .atomic)

            let loaded = try JSONDecoder().decode(
                [ChatMessageUI].self,
                from: Data(contentsOf: fixtureURL)
            )
            let rendered = ChatTranscriptFormatter.plainText(loaded)

            #expect(loaded.count == 1)
            #expect(loaded[0].id == messageID)
            #expect(loaded[0].timestamp == timestamp)
            #expect(loaded[0].content.count == characterCount)
            #expect(loaded[0].content.utf8.count == characterCount)
            #expect(rendered == "【助手】\n\(content)")
            #expect(fixtureURL.standardizedFileURL.path.hasPrefix(rootPath + "/"))
            #expect(fixtureURL.standardizedFileURL.path.hasPrefix(sessionPath + "/"))
        }
    }

    @Test("MM01 launcher legacy triplet is parsed by the production Core and App resolvers")
    func mm01LauncherLegacyTripletUsesProductionResolvers() throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let temporary = FileManager.default.temporaryDirectory
        // Qualify the physical Foundation temp directory. It need not equal
        // formal.temporaryDirectory; the production field validator requires
        // a child of this physical temp directory, not that formal projection.
        var temporaryInfo = stat()
        try #require(lstat(temporary.path, &temporaryInfo) == 0)
        try #require((temporaryInfo.st_mode & S_IFMT) == S_IFDIR)
        try #require((temporaryInfo.st_mode & 0o777) == 0o700)
        try #require(temporaryInfo.st_uid == geteuid()
            && temporaryInfo.st_uid == formal.rootOwner)
        try #require(UInt64(temporaryInfo.st_dev) == formal.rootDevice)

        let root = temporary.appendingPathComponent(
            "MM01-launcher-triplet-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        var created = stat()
        var capturedCreatedIdentity = false
        // Install cleanup before any throwing qualification of the new root.
        defer {
            var current = stat()
            if capturedCreatedIdentity,
               lstat(root.path, &current) == 0,
               current.st_dev == created.st_dev, current.st_ino == created.st_ino,
               current.st_uid == created.st_uid,
               (current.st_mode & S_IFMT) == S_IFDIR {
                do {
                    try FileManager.default.removeItem(at: root)
                    var removed = stat()
                    let removalResult = lstat(root.path, &removed)
                    let removalErrno = errno
                    #expect(removalResult == -1 && removalErrno == ENOENT)
                    print("MM01_TRIPLET_CLEANUP root=\(root.path) device=\(created.st_dev) inode=\(created.st_ino) uid=\(created.st_uid) removal=\(removalResult) errno=\(removalErrno) absent=\(removalResult == -1 && removalErrno == ENOENT)")
                } catch {
                    Issue.record("Owned MM01 triplet root cleanup failed: \(error)")
                }
            } else {
                Issue.record("Owned MM01 triplet root identity unavailable or changed; refusing cleanup")
            }
        }
        let captureResult = lstat(root.path, &created)
        capturedCreatedIdentity = captureResult == 0
        try #require(captureResult == 0)
        try #require((created.st_mode & S_IFMT) == S_IFDIR)
        try #require((created.st_mode & 0o777) == 0o700)
        try #require(created.st_uid == geteuid() && created.st_uid == formal.rootOwner)
        try #require(UInt64(created.st_dev) == formal.rootDevice)
        try #require(UInt64(created.st_ino) != formal.rootInode)
        print("MM01_TRIPLET_ROOT root=\(root.path) parent=\(temporary.path) device=\(created.st_dev) inode=\(created.st_ino) uid=\(created.st_uid) mode=\(String(created.st_mode & 0o777, radix: 8)) parentDevice=\(temporaryInfo.st_dev) parentInode=\(temporaryInfo.st_ino) parentUID=\(temporaryInfo.st_uid) parentMode=\(String(temporaryInfo.st_mode & 0o777, radix: 8))")
        let canonicalRootPath = try mappedPath(root)
        let identity = "packagedField:packaged-field:\(canonicalRootPath)"
        let arguments = [
            "MinisCanvas", RuntimeIsolationProfile.fieldActivationArgument,
            RuntimeIsolationProfile.fieldWitnessArgument,
            "--deepseek-env-field-bootstrap",
            "--mm01-deepseek-flash-visual"
        ]
        // These are only the actual launcher's non-secret isolation inputs.
        // Only the formal runner fixture is read above; no credential values,
        // inherited child environment, App constructor or network is used.
        let original: [String: String] = [
            RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
            RuntimeIsolationProfile.fieldActivationRootKey: canonicalRootPath,
            RuntimeIsolationProfile.profileIdentityKey: identity
        ]
        var corrected = original
        corrected[FormalTestIsolationPaths.profileMarkerKey] = "1"
        corrected[FormalTestIsolationPaths.profileDirectoryKey] = canonicalRootPath
        var cases: [(name: String, environment: [String: String], accepted: Bool)] = [
            ("original-identity-only", original, false),
            ("corrected-complete-triplet", corrected, true)
        ]
        for key in [FormalTestIsolationPaths.profileMarkerKey,
                    FormalTestIsolationPaths.profileDirectoryKey,
                    FormalTestIsolationPaths.profileIdentityKey] {
            var incomplete = corrected
            incomplete.removeValue(forKey: key)
            cases.append(("missing-\(key)", incomplete, false))
        }
        var wrongDirectory = corrected
        wrongDirectory[FormalTestIsolationPaths.profileDirectoryKey] =
            root.appendingPathComponent("different-owned-path").path
        cases.append(("wrong-legacy-directory", wrongDirectory, false))
        var wrongMarker = corrected
        wrongMarker[FormalTestIsolationPaths.profileMarkerKey] = "true"
        cases.append(("wrong-legacy-marker", wrongMarker, false))
        var wrongIdentity = corrected
        wrongIdentity[FormalTestIsolationPaths.profileIdentityKey] =
            "formal-test:synthetic:MinisCanvas:nonce"
        cases.append(("wrong-legacy-identity-prefix", wrongIdentity, false))
        var mixedFormal = corrected
        mixedFormal[FormalTestIsolationPaths.runIDKey] = "synthetic-forbidden-run"
        cases.append(("mixed-formal-only-key", mixedFormal, false))

        for testCase in cases {
            print("MM01_LAUNCHER_ENV_CASE=\(testCase.name)")
            if testCase.accepted {
                // nil means a recognized non-test field handoff to App, not
                // a production profile and not a COMPOSITION_READY witness.
                let core = try FormalTestIsolationPaths.resolve(
                    environment: testCase.environment, arguments: arguments,
                    processName: "MinisCanvas"
                )
                #expect(core == nil)
                let profile = try RuntimeIsolationProfile.resolveLaunchProfile(
                    processEnvironment: testCase.environment,
                    processArguments: arguments, processName: "MinisCanvas"
                )
                #expect(profile.mode == .packagedField)
                #expect(profile.isDisposable && profile.isDisposableRootIntact)
                #expect(!profile.allowsExternalNetwork)
                #expect(profile.rootDirectory.path == canonicalRootPath)
                #expect(profile.launchIdentity == identity)
                #expect(profile.environment[RuntimeIsolationProfile.profileIdentityKey] == identity)
                #expect(profile.keychainLegacyServices.isEmpty)
                #expect(profile.keychainComposition
                    == .testNamespacedInMemory(namespace: profile.keychainService))
                let captured = try #require(profile.disposableRootIdentity)
                #expect(captured.device == UInt64(created.st_dev))
                #expect(captured.inode == UInt64(created.st_ino))
            } else {
                #expect(throws: FormalTestIsolationPaths.IsolationError.invalidContract) {
                    _ = try FormalTestIsolationPaths.resolve(
                        environment: testCase.environment, arguments: arguments,
                        processName: "MinisCanvas"
                    )
                }
                #expect(throws: FormalTestIsolationPaths.IsolationError.invalidContract) {
                    _ = try RuntimeIsolationProfile.resolveLaunchProfile(
                        processEnvironment: testCase.environment,
                        processArguments: arguments, processName: "MinisCanvas"
                    )
                }
            }
            var after = stat()
            try #require(lstat(root.path, &after) == 0)
            #expect(after.st_dev == created.st_dev && after.st_ino == created.st_ino)
            #expect(after.st_uid == created.st_uid && (after.st_mode & 0o777) == 0o700)
            #expect(!FileManager.default.fileExists(
                atPath: root.appendingPathComponent(".miniscanvas-field-witness").path
            ))
        }
    }
}
