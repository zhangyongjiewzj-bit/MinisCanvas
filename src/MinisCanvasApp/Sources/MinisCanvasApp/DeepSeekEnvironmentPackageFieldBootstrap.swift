import Foundation
import Darwin
import MinisCore

/// Explicit configuration-only producer. Never probes, applies a model or sends.
/// The credential is consumed inside the App and stays in its injected backing.
@MainActor
enum DeepSeekEnvironmentPackageFieldBootstrap {
    static let activationArgument = "--deepseek-env-field-bootstrap"
    static let journeyArgument = "--deepseek-isolated-journey"
    static let journeyKeyFileName = "deepseek-api-key"
    // A custom identity avoids the legacy built-in DeepSeek catalog, whose
    // v4 model IDs differ from the current official native-vision Flash ID.
    static let journeyProviderName = "MINISCANVAS_JOURNEY_DEEPSEEK_API_KEY"
    static let modelID = "deepseek-flash"

    enum Outcome: String, Equatable { case configured, refused, alreadyConsumed, saveFailed }

    @MainActor final class Composition {
        let keychain: KeychainStore
        let environmentStore: EnvVarStore
        private let profile: RuntimeIsolationProfile
        private var credential: String?
        private var mm01Prepared = false
        private let baseURL: String
        let isJourney: Bool

        fileprivate init(profile: RuntimeIsolationProfile, credential: String, baseURL: String, isJourney: Bool = false) {
            self.isJourney = isJourney
            self.profile = profile
            // This exact factory, rather than an arbitrary `.injected` label,
            // constructs NamespacedKeychainBacking(InMemoryKeychainBacking).
            let keychain = profile.makeKeychainStore()
            self.keychain = keychain
            self.environmentStore = profile.makeEnvironmentStore(keychain: keychain)
            self.credential = credential
            self.baseURL = baseURL
        }

        private var mm01Arguments: [String]?
        private var mm01Environment: [String: String]?
        private var installationSucceeded = false
        private var mm01Activated = false
        private var mm01Lane: DeepSeekMM01FieldLane?
        private var remoteContractConfiguration: URLSessionConfiguration?

        /// Inert admission only. It cannot mint a permit or send before install.
        func prepareMM01(arguments: [String] = CommandLine.arguments,
                         environment: [String: String]? = nil) -> Bool {
            guard arguments.filter({ $0 == DeepSeekMM01FieldLane.activationArgument }).count == 1,
                  !mm01Prepared else { return false }
            mm01Prepared = true
            let supplied = environment ?? ProcessInfo.processInfo.environment
            guard DeepSeekMM01FieldLane.acceptsAdmission(profile: profile, keychain: keychain,
                arguments: arguments, environment: supplied) else { return false }
            mm01Arguments = arguments
            // Keep only three non-secret identity markers, never a full env.
            mm01Environment = [RuntimeIsolationProfile.fieldActivationMarkerKey: supplied[RuntimeIsolationProfile.fieldActivationMarkerKey]!,
                RuntimeIsolationProfile.fieldActivationRootKey: supplied[RuntimeIsolationProfile.fieldActivationRootKey]!,
                RuntimeIsolationProfile.profileIdentityKey: supplied[RuntimeIsolationProfile.profileIdentityKey]!]
            return true
        }

        /// Release test hosts use an existing formal contract; the App call site
        /// never calls this API or supplies protocolClasses/session injection.
        func prepareMM01ForRemoteContractTest(arguments: [String], environment: [String: String],
                                             session: URLSession) throws -> Bool {
            guard try FormalTestIsolationPaths.resolveCurrentProcess() != nil,
                  prepareMM01(arguments: arguments, environment: environment) else { return false }
            remoteContractConfiguration = session.configuration
            return true
        }

        var mm01ReadinessTransport: any SettingsProviderReadinessTransport {
            DeferredMM01ReadinessTransport(composition: self)
        }
        func sendMM01Readiness(_ request: ProviderReadinessTransportRequest) async throws -> ProviderReadinessTransportResponse {
            guard let mm01Lane else { throw DeepSeekMM01FieldLane.Refusal.admission }
            return try await mm01Lane.sendReadiness(request)
        }
        func activateMM01(settings: SettingsCenter, actualKeychain: KeychainStore, chat: ChatStore) -> DeepSeekMM01FieldLane? {
            guard installationSucceeded, !mm01Activated, actualKeychain === keychain,
                  let arguments = mm01Arguments, let environment = mm01Environment else { return nil }
            mm01Activated = true
            guard let lane = DeepSeekMM01FieldLane.makeAfterSuccessfulInstall(profile: profile,
                keychain: keychain, environmentStore: environmentStore, arguments: arguments,
                environment: environment, testConfiguration: remoteContractConfiguration),
                lane.bind(settings: settings, actualKeychain: actualKeychain, chat: chat) else { return nil }
            mm01Lane = lane
            return lane
        }

        /// Only the explicit App composition installs builders. Merely
        /// preparing or saving metadata cannot alter the process factory.
        func activateJourneyProviders(chat: ChatStore) {
            guard installationSucceeded, isJourney else { return }
            chat.isolatedDeepSeekJourneyConfigured = true
            let builder: ProviderFactory.Builder = { config in
                guard let base = config.effectiveCustomBaseURL,
                      DeepSeekProviderContract.isCanonicalBaseURL(base),
                      let key = config.apiKey, !key.isEmpty else {
                    throw JourneyRefusal.destination
                }
                let provider = OpenAICompatibleProvider(apiKey: key,
                    model: LLMModel(id: "deepseek-flash", displayName: "DeepSeek Flash", provider: "deepseek",
                        modalityOverride: .vision, contextWindow: 1_000_000,
                        supportsReasoning: false), customBaseURL: DeepSeekProviderContract.baseURL,
                    appendV1Suffix: false, session: DeepSeekEnvironmentPackageFieldBootstrap.makeJourneySession(),
                    providerName: config.runtimeProviderID ?? config.label)
                // Reuse the existing Chat Completions max_tokens assembler.
                provider.useOpenRouterCompat = true
                return provider
            }
            ProviderFactory.shared.register(.openAI, builder: builder)
            ProviderFactory.shared.register(.deepSeek, builder: builder)
        }

        /// Called only from the successful primary Bridge construction outlet.
        /// Refusals occur before any credential or provider write.
        func install(settings: SettingsCenter, actualKeychain: KeychainStore,
                     primaryCompositionSucceeded: Bool) -> Outcome {
            guard primaryCompositionSucceeded,
                  actualKeychain === keychain, actualKeychain.backingKind == .injected,
                  settings.envStore === environmentStore,
                  profile.isDisposableRootIntact,
                  ThemeApprovalPackageFieldFixture.rootIsSafe(profile),
                  settings.envStore.metadataDirectory == profile.providerConfigurationDirectory,
                  settings.sessionStore.directory == profile.sessionDirectory else { return .refused }
            guard let credential else { return .alreadyConsumed }
            self.credential = nil
            // Existing production APIs provide the opaque binding and the
            // discovered/unverified readiness projection. No ready state is forged.
            let saved = settings.saveProvider(
                name: !isJourney ? DeepSeekProviderContract.apiKeyEnvironmentVariable : DeepSeekEnvironmentPackageFieldBootstrap.journeyProviderName,
                credential: .replace(credential), baseURL: baseURL,
                modelNames: [!isJourney ? DeepSeekEnvironmentPackageFieldBootstrap.modelID : "deepseek-flash"],
                protocolType: .openaiCompatible
            )
            installationSucceeded = saved
            return saved ? .configured : .saveFailed
        }
    }

    static func prepare(profile: RuntimeIsolationProfile, bootstrapFailed: Bool,
                        arguments: [String] = CommandLine.arguments,
                        environment suppliedEnvironment: [String: String]? = nil) -> Composition? {
        if arguments.contains(journeyArgument) {
            return prepareJourney(profile: profile, bootstrapFailed: bootstrapFailed,
                                  arguments: arguments, environment: suppliedEnvironment)
        }
        guard !bootstrapFailed, profile.mode == .packagedField,
              arguments.filter({ $0 == activationArgument }).count == 1,
              arguments.filter({ $0 == RuntimeIsolationProfile.fieldActivationArgument }).count == 1,
              profile.isDisposableRootIntact,
              ThemeApprovalPackageFieldFixture.rootIsSafe(profile),
              profile.keychainLegacyServices.isEmpty,
              !FileManager.default.fileExists(atPath: profile.providerConfigurationDirectory
                .appendingPathComponent(EnvVarStore.fileName).path) else { return nil }
        // Normal launches do not even enumerate the credential environment.
        let environment = suppliedEnvironment ?? ProcessInfo.processInfo.environment
        guard environment[RuntimeIsolationProfile.fieldActivationMarkerKey] == "1",
              environment[RuntimeIsolationProfile.fieldActivationRootKey] == profile.rootDirectory.path,
              let baseURL = environment["DEEPSEEK_BASE_URL"],
              DeepSeekProviderContract.isCanonicalBaseURL(baseURL),
              let credential = environment[DeepSeekProviderContract.apiKeyEnvironmentVariable],
              !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Composition(profile: profile, credential: credential,
                           baseURL: DeepSeekProviderContract.baseURL)
    }
    /// The separate explicit env-bootstrap flag consumes only values already
    /// injected by the authorized spawn. With no such flag, use the owned-root
    /// file entry exactly as before; never fall back between credential sources.
    private static func prepareJourney(profile: RuntimeIsolationProfile, bootstrapFailed: Bool,
        arguments: [String], environment: [String: String]?) -> Composition? {
        let env = environment ?? ProcessInfo.processInfo.environment
        guard !bootstrapFailed, profile.mode == .packagedField,
              arguments.filter({ $0 == journeyArgument }).count == 1,
              arguments.filter({ $0 == RuntimeIsolationProfile.fieldActivationArgument }).count == 1,
              arguments.filter({ $0 == activationArgument }).count <= 1,
              !arguments.contains(DeepSeekMM01FieldLane.activationArgument),
              env[RuntimeIsolationProfile.fieldActivationMarkerKey] == "1",
              env[RuntimeIsolationProfile.fieldActivationRootKey] == profile.rootDirectory.path,
              profile.isDisposableRootIntact,
              ThemeApprovalPackageFieldFixture.rootIsSafe(profile) else { return nil }
        do {
            _ = try validatedJourneyWorkspace(profile: profile)
            let credential: String
            if arguments.filter({ $0 == activationArgument }).count == 1 {
                guard let baseURL = env["DEEPSEEK_BASE_URL"],
                      DeepSeekProviderContract.isCanonicalBaseURL(baseURL),
                      let url = URL(string: baseURL), acceptsJourneyURL(url),
                      let injected = env[DeepSeekProviderContract.apiKeyEnvironmentVariable],
                      !injected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                credential = injected
            } else {
                credential = try readJourneyCredential(profile: profile)
            }
            return Composition(profile: profile, credential: credential,
                baseURL: DeepSeekProviderContract.baseURL, isJourney: true)
        } catch {
            // Fixed code only; never interpolate paths, file bytes or errors.
            print("DEEPSEEK_JOURNEY_KEY_MISSING_OR_UNSAFE")
            return nil
        }
    }

    enum JourneyRefusal: Error { case destination, unsafeKey, unsafeWorkspace }

    /// This policy applies to readiness and to the Bridge's frozen provider
    /// admission. The builder fixes the same base; redirects never proceed.
    nonisolated static func acceptsJourneyURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == "api.deepseek.com"
            && url.port == nil && url.user == nil && url.password == nil
            && url.query == nil && url.fragment == nil
            && ["", "/", "/models", "/chat/completions"].contains(url.path)
    }

    static func admitsJourneyProvider(configured: Bool, providerName: String, baseURL: String?) -> Bool {
        guard configured, providerName == journeyProviderName,
              let baseURL, baseURL == DeepSeekProviderContract.baseURL,
              let url = URL(string: baseURL) else { return false }
        return acceptsJourneyURL(url)
    }

    nonisolated static func makeJourneySession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration,
            delegate: JourneyRedirectRejection.shared, delegateQueue: nil)
    }

    static func journeyReadinessTransport(for composition: Composition?) -> (any SettingsProviderReadinessTransport)? {
        guard composition?.isJourney == true else { return nil }
        return URLSessionProviderReadinessTransport(session: makeJourneySession(),
            canProduceLiveEvidence: true, requestURLPolicy: { request in
                guard let url = request.url, acceptsJourneyURL(url) else { throw JourneyRefusal.destination }
                return request
            })
    }

    /// Existing tool composition receives this exact child, never the root
    /// containing credentials. Do not normalize an unsafe link into admission.
    static func validatedJourneyWorkspace(profile: RuntimeIsolationProfile) throws -> URL {
        try profile.validateDisposableRootIdentity()
        let workspace = profile.rootDirectory.appendingPathComponent("workspace", isDirectory: true)
        var info = stat()
        guard profile.mode == .packagedField,
              lstat(workspace.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(), (info.st_mode & 0o022) == 0,
              UInt64(info.st_dev) == profile.disposableRootIdentity?.device,
              workspace.resolvingSymlinksInPath().deletingLastPathComponent().path
                == profile.rootDirectory.resolvingSymlinksInPath().path,
              profile.isDisposableRootIntact else { throw JourneyRefusal.unsafeWorkspace }
        return workspace
    }

    static func readJourneyCredential(profile: RuntimeIsolationProfile) throws -> String {
        try profile.validateDisposableRootIdentity()
        let root = open(profile.rootDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw JourneyRefusal.unsafeKey }
        defer { _ = close(root) }
        var rootInfo = stat()
        guard fstat(root, &rootInfo) == 0, let identity = profile.disposableRootIdentity,
              UInt64(rootInfo.st_dev) == identity.device,
              UInt64(rootInfo.st_ino) == identity.inode else {
            throw JourneyRefusal.unsafeKey
        }
        let fd = openat(root, journeyKeyFileName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw JourneyRefusal.unsafeKey }
        defer { _ = close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(), info.st_mode & 0o777 == 0o600,
              info.st_nlink == 1, info.st_dev == rootInfo.st_dev,
              info.st_size > 0, info.st_size <= 4096 else {
            throw JourneyRefusal.unsafeKey
        }
        var bytes = [UInt8](repeating: 0, count: 4097)
        let count = read(fd, &bytes, bytes.count)
        guard count == info.st_size, let raw = String(bytes: bytes.prefix(count), encoding: .utf8) else {
            throw JourneyRefusal.unsafeKey
        }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: { $0.isWhitespace || $0.isNewline }),
              profile.isDisposableRootIntact else { throw JourneyRefusal.unsafeKey }
        return key
    }

}

private struct DeferredMM01ReadinessTransport: SettingsProviderReadinessTransport {
    let composition: DeepSeekEnvironmentPackageFieldBootstrap.Composition
    let canProduceLiveEvidence = true
    func send(_ request: ProviderReadinessTransportRequest) async throws -> ProviderReadinessTransportResponse {
        try await composition.sendMM01Readiness(request)
    }
}

private final class JourneyRedirectRejection: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = JourneyRedirectRejection()
    func urlSession(_ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
