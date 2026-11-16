import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

private actor ConfigurationOnlyReadinessSpy: SettingsProviderReadinessTransport {
    nonisolated let canProduceLiveEvidence = false
    private(set) var calls = 0
    func send(_ request: ProviderReadinessTransportRequest) async throws -> ProviderReadinessTransportResponse {
        calls += 1
        throw SettingsProviderReadinessTransportError.unavailable
    }
}

@Suite("DeepSeek field environment configuration only")
@MainActor
struct DeepSeekEnvironmentPackageFieldBootstrapTests {
    private func profile() throws -> RuntimeIsolationProfile {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "deepseek-env-field-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        return try RuntimeIsolationProfile.makePackagedField(label: "deepseek-env-field",
            processEnvironment: [RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                                 RuntimeIsolationProfile.fieldActivationRootKey: root.path],
            processArguments: arguments)
    }
    private var arguments: [String] {
        ["MinisCanvas", RuntimeIsolationProfile.fieldActivationArgument,
         DeepSeekEnvironmentPackageFieldBootstrap.activationArgument]
    }
    private func environment(_ profile: RuntimeIsolationProfile, sentinel: String) -> [String: String] {
        [RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
         RuntimeIsolationProfile.fieldActivationRootKey: profile.rootDirectory.path,
         "DEEPSEEK_BASE_URL": DeepSeekProviderContract.baseURL, "DEEPSEEK_API_KEY": sentinel]
    }
    private func settings(_ profile: RuntimeIsolationProfile, keychain: KeychainStore,
                          environmentStore: EnvVarStore? = nil,
                          transport: any SettingsProviderReadinessTransport = FailClosedProviderReadinessTransport()) -> SettingsCenter {
        let defaults = profile.makeUserDefaults()
        return SettingsCenter(settingsStore: SettingsStore(directory: profile.settingsDirectory),
            envStore: environmentStore ?? profile.makeEnvironmentStore(keychain: keychain),
            memoryStore: MemoryStore(directory: profile.memoryDirectory),
            memoryFileStore: MemoryFileStore(directory: profile.memoryDirectory),
            sessionStore: SessionStore(directory: profile.sessionDirectory),
            sessionBadgeStore: SessionBadgeStore(directory: profile.minisCanvasDirectory),
            logManager: profile.makeLogManager(),
            mcpManager: MCPServerManager(fileURL: profile.mcpConfigurationURL, keychain: keychain),
            skillStore: SkillStore(skillsRoot: profile.hermesSkillsDirectory),
            usageStore: UsageStore(domain: profile.usageStoreDefaultsDomain),
            shortcutStore: ShortcutStore(defaults: defaults),
            providerReadinessTransport: transport,
            providerReadinessDeployment: .mock,
            providerReadinessStore: ProviderReadinessStore(directory: profile.providerConfigurationDirectory))
    }

    /// DirectoryEnumerator.makeIterator is unavailable in async contexts.
    /// Collect one boolean fact for every owned regular file synchronously;
    /// retain no file bytes or credential text in assertion diagnostics.
    private func ownedFileSentinelFacts(in root: URL, sentinel: String) throws -> [Bool] {
        let enumerator = try #require(FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey]))
        var facts: [Bool] = []
        for case let url as URL in enumerator {
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            let containsSynthetic = (try Data(contentsOf: url)).range(of: Data(sentinel.utf8)) != nil
            facts.append(containsSynthetic)
        }
        return facts
    }

    @Test("field env populates the actual opaque credential binding but never ready or network")
    func configuresOpaqueBindingWithoutReadyClaim() async throws {
        let p = try profile(); defer { try? p.cleanupDisposableRoots() }
        let sentinel = "synthetic-" + UUID().uuidString
        let c = try #require(DeepSeekEnvironmentPackageFieldBootstrap.prepare(
            profile: p, bootstrapFailed: false, arguments: arguments,
            environment: environment(p, sentinel: sentinel)))
        let transport = ConfigurationOnlyReadinessSpy()
        let s = settings(p, keychain: c.keychain, environmentStore: c.environmentStore, transport: transport)
        #expect(c.install(settings: s, actualKeychain: c.keychain,
                          primaryCompositionSucceeded: true) == .configured)
        let record = try #require(s.providerRecords.first)
        #expect(record.name == DeepSeekProviderContract.apiKeyEnvironmentVariable)
        #expect(record.baseURL == DeepSeekProviderContract.baseURL)
        #expect(record.modelNames == ["deepseek-flash"])
        #expect(record.valueInKeychain && record.isSecret)
        let binding = try #require(s.providerCredentialBinding(recordID: record.id))
        #expect(!binding.revision.isEmpty)
        #expect(binding.credentialName == record.name)
        let read = await s.providerCredentialReadAsync(named: record.name)
        let matchesSynthetic: Bool
        if case .success(let value) = read { matchesSynthetic = value == sentinel }
        else { matchesSynthetic = false }
        #expect(matchesSynthetic) // Never include the credential in assertion diagnostics.
        #expect(!s.providerReadinessStore.records.isEmpty)
        #expect(s.providerReadinessStore.records.allSatisfy { $0.readinessState == .unverified })
        let transportCalls = await transport.calls
        #expect(transportCalls == 0)
        #expect(c.install(settings: s, actualKeychain: c.keychain,
                          primaryCompositionSucceeded: true) == .alreadyConsumed)
        s.logManager.info("Synthetic redaction verification: " + sentinel, category: "FieldBootstrapTest")
        let logsContainSynthetic = s.logManager.recentLogsText().contains(sentinel)
        #expect(!logsContainSynthetic)
        let data = try JSONEncoder().encode(record)
        let encodedContainsSynthetic = String(decoding: data, as: UTF8.self).contains(sentinel)
        #expect(!encodedContainsSynthetic)
        for containsSynthetic in try ownedFileSentinelFacts(in: p.rootDirectory, sentinel: sentinel) {
            #expect(!containsSynthetic)
        }
    }

    @Test(arguments: ["no-flag", "duplicate", "no-field", "no-marker", "wrong-root", "no-key", "foreign-url", "bootstrap-failed"])
    func rejectsAdmissionBeforeProviderEffects(_ failure: String) throws {
        let p = try profile(); defer { try? p.cleanupDisposableRoots() }
        var args = arguments; var env = environment(p, sentinel: "synthetic-unused")
        switch failure {
        case "no-flag": args.removeLast()
        case "duplicate": args.append(DeepSeekEnvironmentPackageFieldBootstrap.activationArgument)
        case "no-field": args.removeAll { $0 == RuntimeIsolationProfile.fieldActivationArgument }
        case "no-marker": env.removeValue(forKey: RuntimeIsolationProfile.fieldActivationMarkerKey)
        case "wrong-root": env[RuntimeIsolationProfile.fieldActivationRootKey] = p.rootDirectory.path + "-other"
        case "no-key": env.removeValue(forKey: "DEEPSEEK_API_KEY")
        case "foreign-url": env["DEEPSEEK_BASE_URL"] = "https://invalid.example"
        default: break
        }
        let c = DeepSeekEnvironmentPackageFieldBootstrap.prepare(profile: p,
            bootstrapFailed: failure == "bootstrap-failed", arguments: args, environment: env)
        #expect(c == nil)
        let keychain = p.makeKeychainStore()
        let s = settings(p, keychain: keychain)
        #expect(s.providerRecords.isEmpty)
        #expect(keychain.get("DEEPSEEK_API_KEY") == nil)
        #expect(s.providerReadinessStore.records.isEmpty)
    }

    @Test("normal, blocked and isolated profiles cannot consume field environment")
    func refusesOtherProfiles() throws {
        let isolated = try RuntimeIsolationProfile.makeIsolatedTest(label: "deepseek-refusal",
            processEnvironment: [:], processArguments: ["MinisCanvasAppTests.xctest"],
            canvasRuntimeState: .disabled)
        defer { try? isolated.cleanupDisposableRoots() }
        let blocked = RuntimeIsolationProfile.blockedProfile()
        defer { try? blocked.cleanupDisposableRoots() }
        for p in [RuntimeIsolationProfile.production, blocked, isolated] {
            #expect(DeepSeekEnvironmentPackageFieldBootstrap.prepare(profile: p,
                bootstrapFailed: false, arguments: arguments,
                environment: environment(p, sentinel: "synthetic-unused")) == nil)
        }
    }

    @Test("changed unsafe owned root rejects without credential or provider writes")
    func refusesChangedRoot() throws {
        let p = try profile(); defer { try? p.cleanupDisposableRoots() }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: p.rootDirectory.path)
        #expect(DeepSeekEnvironmentPackageFieldBootstrap.prepare(profile: p,
            bootstrapFailed: false, arguments: arguments,
            environment: environment(p, sentinel: "synthetic-unused")) == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: p.rootDirectory.path)
    }

    @Test("existing provider metadata is refused unchanged before any credential consumer")
    func refusesExistingMetadata() throws {
        let p = try profile(); defer { try? p.cleanupDisposableRoots() }
        try FileManager.default.createDirectory(at: p.providerConfigurationDirectory,
            withIntermediateDirectories: true)
        let file = p.providerConfigurationDirectory.appendingPathComponent(EnvVarStore.fileName)
        let original = Data("[]".utf8)
        try original.write(to: file)
        #expect(DeepSeekEnvironmentPackageFieldBootstrap.prepare(profile: p,
            bootstrapFailed: false, arguments: arguments,
            environment: environment(p, sentinel: "synthetic-unused")) == nil)
        #expect(try Data(contentsOf: file) == original)
    }

    @Test("degraded and substituted injected or SecItem backings cannot install")
    func refusesDegradedOrSubstitutedBacking() throws {
        let p = try profile(); defer { try? p.cleanupDisposableRoots() }
        let c = try #require(DeepSeekEnvironmentPackageFieldBootstrap.prepare(profile: p,
            bootstrapFailed: false, arguments: arguments,
            environment: environment(p, sentinel: "synthetic-unused")))
        let s = settings(p, keychain: c.keychain, environmentStore: c.environmentStore)
        #expect(c.install(settings: s, actualKeychain: c.keychain,
                          primaryCompositionSucceeded: false) == .refused)
        let otherInjected = p.makeKeychainStore()
        let substitutedSettings = settings(p, keychain: otherInjected)
        #expect(c.install(settings: substitutedSettings, actualKeychain: c.keychain,
                          primaryCompositionSucceeded: true) == .refused)
        #expect(c.install(settings: s, actualKeychain: otherInjected,
                          primaryCompositionSucceeded: true) == .refused)
        // Construction alone performs no SecItem operation; identity guard rejects it.
        let secItem = KeychainStore(secItemService: "field-test-never-accessed")
        #expect(c.install(settings: s, actualKeychain: secItem,
                          primaryCompositionSucceeded: true) == .refused)
        #expect(s.providerRecords.isEmpty)
        #expect(s.providerReadinessStore.records.isEmpty)
        #expect(c.keychain.get("DEEPSEEK_API_KEY") == nil)
    }

    @Test("text-only DeepSeek models (deepseek-chat) still fail the image capability gate")
    func doesNotBypassImageCapabilityGate() {
        let model = LLMModel(id: "deepseek-chat", displayName: "deepseek-chat", provider: "DeepSeek")
        #expect(!MediaCapabilityGate.decide(mimeType: "image/png", capabilities: model.capabilities).isAllowed)
    }
}

extension DeepSeekEnvironmentPackageFieldBootstrapTests {
    @Test("explicit journey loads only owned 0600 file and rebinds RAM after cold start")
    func journeyColdStartReinstallsRAMCredential() async throws {
        let p = try profile(); defer { try? p.cleanupDisposableRoots() }
        try FileManager.default.createDirectory(at: p.rootDirectory.appendingPathComponent("workspace"),
            withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let keyURL = p.rootDirectory.appendingPathComponent(DeepSeekEnvironmentPackageFieldBootstrap.journeyKeyFileName)
        let sentinel = "fake-journey-" + UUID().uuidString
        try Data(sentinel.utf8).write(to: keyURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        let args = ["MinisCanvas", RuntimeIsolationProfile.fieldActivationArgument,
                    DeepSeekEnvironmentPackageFieldBootstrap.journeyArgument]
        let env = [RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                   RuntimeIsolationProfile.fieldActivationRootKey: p.rootDirectory.path]
        for _ in 0..<2 {
            let c = try #require(DeepSeekEnvironmentPackageFieldBootstrap.prepare(profile: p,
                bootstrapFailed: false, arguments: args, environment: env))
            let s = settings(p, keychain: c.keychain, environmentStore: c.environmentStore)
            #expect(c.install(settings: s, actualKeychain: c.keychain,
                              primaryCompositionSucceeded: true) == .configured)
            let read = await s.providerCredentialReadAsync(named: DeepSeekEnvironmentPackageFieldBootstrap.journeyProviderName)
            let matches: Bool
            if case .success(let value) = read { matches = value == sentinel } else { matches = false }
            #expect(matches)
            #expect(s.providerRecords.first?.modelNames == ["deepseek-flash"])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: keyURL.path)
        #expect(DeepSeekEnvironmentPackageFieldBootstrap.prepare(profile: p,
            bootstrapFailed: false, arguments: args, environment: env) == nil)
        try FileManager.default.removeItem(at: keyURL)
        let other = p.rootDirectory.appendingPathComponent("other")
        try Data(sentinel.utf8).write(to: other)
        try FileManager.default.createSymbolicLink(at: keyURL, withDestinationURL: other)
        #expect(DeepSeekEnvironmentPackageFieldBootstrap.prepare(profile: p,
            bootstrapFailed: false, arguments: args, environment: env) == nil)
    }
}

extension DeepSeekEnvironmentPackageFieldBootstrapTests {
    @Test("journey native vision declaration is scoped to the exact official custom model")
    func journeyVisionDeclarationLeavesOrdinaryDefaultsUnchanged() throws {
        let chat = ChatStore()
        let record = EnvVarEntry(name: DeepSeekEnvironmentPackageFieldBootstrap.journeyProviderName,
            value: "synthetic-journey-fixture", isSecret: true, baseURL: DeepSeekProviderContract.baseURL,
            modelNames: ["deepseek-flash"], protocolType: .openaiCompatible)
        #expect(chat.isolatedDeepSeekJourneyModel(record: record, modelID: "deepseek-flash") == nil)
        chat.isolatedDeepSeekJourneyConfigured = true
        let declared = chat.isolatedDeepSeekJourneyModel(record: record, modelID: "deepseek-flash")
        #expect(declared?.modalityOverride == .vision)
        #expect(declared?.contextWindow == 1_000_000)
        // Exercise the actual custom selection and frozen construction with
        // a fake inline credential. Constructing the provider never sends.
        chat.setCustomProvider(record)
        #expect(chat.selectedCustomProvider?.name == DeepSeekEnvironmentPackageFieldBootstrap.journeyProviderName)
        #expect(chat.selectedProviderType == nil)
        #expect(chat.selectedModelID == "deepseek-flash")
        let frozen = try chat.frozenCustomProviderConstruction(record: record, modelID: chat.selectedModelID)
        #expect(frozen.model?.modalityOverride == .vision)
        #expect(frozen.config.customBaseURL == DeepSeekProviderContract.baseURL)
        #expect(frozen.config.appendV1Suffix == false)
        let provider = try frozen.makeProvider()
        #expect(provider.model.modalityOverride == .vision)
        #expect(chat.isolatedDeepSeekJourneyModel(record: record, modelID: "deepseek-chat") == nil)
        var foreign = record; foreign.baseURL = "https://example.com"
        #expect(chat.isolatedDeepSeekJourneyModel(record: foreign, modelID: "deepseek-flash") == nil)
        #expect(LLMModel.deepSeekV4Flash.capabilities.supportedModalities == .textOnly)
    }
}


extension DeepSeekEnvironmentPackageFieldBootstrapTests {
    @Test("journey network switch admits only the exact official provider")
    func journeyNetworkGateIsExplicitAndDeepSeekOnly() throws {
        let p = try profile(); defer { try? p.cleanupDisposableRoots() }
        let workspace = p.rootDirectory.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        #expect(try DeepSeekEnvironmentPackageFieldBootstrap.validatedJourneyWorkspace(profile: p) == workspace)
        try FileManager.default.removeItem(at: workspace)
        try FileManager.default.createSymbolicLink(at: workspace, withDestinationURL: p.rootDirectory)
        #expect(throws: DeepSeekEnvironmentPackageFieldBootstrap.JourneyRefusal.self) {
            _ = try DeepSeekEnvironmentPackageFieldBootstrap.validatedJourneyWorkspace(profile: p)
        }
        try FileManager.default.removeItem(at: workspace)

        let name = DeepSeekEnvironmentPackageFieldBootstrap.journeyProviderName
        let official = DeepSeekProviderContract.baseURL
        #expect(!DeepSeekEnvironmentPackageFieldBootstrap.admitsJourneyProvider(
            configured: false, providerName: name, baseURL: official))
        #expect(DeepSeekEnvironmentPackageFieldBootstrap.admitsJourneyProvider(
            configured: true, providerName: name, baseURL: official))
        #expect(!DeepSeekEnvironmentPackageFieldBootstrap.admitsJourneyProvider(
            configured: true, providerName: name, baseURL: "https://example.com"))
        #expect(!DeepSeekEnvironmentPackageFieldBootstrap.admitsJourneyProvider(
            configured: true, providerName: "OTHER_API_KEY", baseURL: official))
        for rejected in ["http://api.deepseek.com", "https://api.deepseek.com.evil.example",
                         "https://api.deepseek.com:443", "https://user@api.deepseek.com",
                         "https://api.deepseek.com/chat/completions?redirect=example.com"] {
            #expect(!DeepSeekEnvironmentPackageFieldBootstrap.acceptsJourneyURL(URL(string: rejected)!))
        }
    }
}


extension DeepSeekEnvironmentPackageFieldBootstrapTests {
    @Test("explicit journey plus one env-bootstrap consumes opaque injected credential without file fallback")
    func journeyExplicitEnvironmentBootstrapUsesRAMOnly() async throws {
        let p = try profile(); defer { try? p.cleanupDisposableRoots() }
        try FileManager.default.createDirectory(at: p.rootDirectory.appendingPathComponent("workspace"),
            withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let args = ["MinisCanvas", RuntimeIsolationProfile.fieldActivationArgument,
                    DeepSeekEnvironmentPackageFieldBootstrap.journeyArgument,
                    DeepSeekEnvironmentPackageFieldBootstrap.activationArgument]
        let sentinel = "synthetic-env-journey-" + UUID().uuidString
        var env = [RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                   RuntimeIsolationProfile.fieldActivationRootKey: p.rootDirectory.path,
                   "DEEPSEEK_BASE_URL": DeepSeekProviderContract.baseURL,
                   DeepSeekProviderContract.apiKeyEnvironmentVariable: sentinel]
        let c = try #require(DeepSeekEnvironmentPackageFieldBootstrap.prepare(profile: p,
            bootstrapFailed: false, arguments: args, environment: env))
        let s = settings(p, keychain: c.keychain, environmentStore: c.environmentStore)
        #expect(c.install(settings: s, actualKeychain: c.keychain,
                          primaryCompositionSucceeded: true) == .configured)
        #expect(s.providerRecords.first?.name == DeepSeekEnvironmentPackageFieldBootstrap.journeyProviderName)
        #expect(s.providerRecords.first?.modelNames == ["deepseek-flash"])
        let read = await s.providerCredentialReadAsync(named: DeepSeekEnvironmentPackageFieldBootstrap.journeyProviderName)
        let matches: Bool
        if case .success(let value) = read { matches = value == sentinel } else { matches = false }
        #expect(matches)
        #expect(!FileManager.default.fileExists(atPath: p.rootDirectory
            .appendingPathComponent(DeepSeekEnvironmentPackageFieldBootstrap.journeyKeyFileName).path))
        #expect(DeepSeekEnvironmentPackageFieldBootstrap.prepare(profile: p,
            bootstrapFailed: false,
            arguments: args.filter { $0 != DeepSeekEnvironmentPackageFieldBootstrap.activationArgument },
            environment: env) == nil)
        #expect(DeepSeekEnvironmentPackageFieldBootstrap.prepare(profile: p,
            bootstrapFailed: false, arguments: args + [DeepSeekEnvironmentPackageFieldBootstrap.activationArgument],
            environment: env) == nil)
        env["DEEPSEEK_BASE_URL"] = "https://example.com"
        #expect(DeepSeekEnvironmentPackageFieldBootstrap.prepare(profile: p,
            bootstrapFailed: false, arguments: args, environment: env) == nil)
        env["DEEPSEEK_BASE_URL"] = DeepSeekProviderContract.baseURL
        env[DeepSeekProviderContract.apiKeyEnvironmentVariable] = " "
        #expect(DeepSeekEnvironmentPackageFieldBootstrap.prepare(profile: p,
            bootstrapFailed: false, arguments: args, environment: env) == nil)
    }
}
