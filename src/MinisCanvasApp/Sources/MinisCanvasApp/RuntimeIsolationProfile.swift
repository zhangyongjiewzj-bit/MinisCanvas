import Foundation
import Darwin
import MinisCore

/// Injectable filesystem and secret namespace boundary for app composition.
///
/// Production keeps the existing Application Support and Keychain defaults.
/// Test profiles are created only for a recognized test process and never copy
/// process credentials or user data into the returned environment.
struct RuntimeIsolationProfile: Equatable, Sendable {
    enum Mode: String, Equatable, Sendable {
        case production
        case isolatedTest
        case packagedField
        /// A safe, disposable composition used only to render a bootstrap
        /// blocker. It can never be treated as a production profile.
        case blocked
    }

    /// The Canvas state is an input to composition, never an implicit
    /// capability. Chat remains a valid production consumer for every state;
    /// only the Canvas capability surface is published when the state is
    /// explicitly healthy.
    enum CanvasRuntimeState: String, Equatable, Sendable {
        case enabled
        case disabled
        case absent
        case corrupt

        var isHealthy: Bool { self == .enabled }

        /// Only an explicitly healthy Canvas may expose a runtime directory
        /// or be considered for activation.  Missing, disabled, and corrupt
        /// profiles therefore cannot be revived by a downstream consumer.
        var allowsCanvasActivation: Bool { isHealthy }

        var failureReason: String? {
            switch self {
            case .enabled:
                return nil
            case .disabled:
                return "canvas-disabled"
            case .absent:
                return "canvas-absent"
            case .corrupt:
                return "canvas-corrupt"
            }
        }
    }

    /// Phase3 keeps Canvas source available for the future Phase4 lane, but
    /// the packaged runtime cannot publish a Canvas consumer or event bridge.
    enum CanvasFeatureLane: String, Equatable, Sendable {
        case phase3NonCanvas
        case phase4OptIn
    }

    /// Typed admission result for the disposable root boundary.  An
    /// unavailable root is not silently treated as production, and an unsafe
    /// root is never normalized into a path that could escape temporary
    /// storage.
    enum DisposableRootOutcome: Equatable, Sendable {
        case resolved(URL)
        case unavailable
        case unsafe
    }

    /// Filesystem identity captured after a disposable root is created.  A
    /// path string alone can be redirected by replacement or a mount change;
    /// device/inode keeps later open/finalize operations on the same object.
    struct DisposableRootIdentity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
    }

    static let phase3CanvasFeatureLane = CanvasFeatureLane.phase3NonCanvas
    static let phase3CanvasChatConsumerCount = 0
    static let phase3CanvasEventToChatWriteCount = 0

    /// Deterministic proof of the production Chat/Canvas composition boundary.
    /// Chat startup does not depend on Canvas construction or recovery. Canvas
    /// capabilities are intentionally empty unless the state is healthy.
    struct ChatCompositionContract: Equatable, Sendable {
        let canvasState: CanvasRuntimeState
        let chatStartupIndependent: Bool
        let canvasCapabilities: Set<String>
        let failClosedReason: String?

        static func make(
            canvasState: CanvasRuntimeState
        ) -> ChatCompositionContract {
            ChatCompositionContract(
                canvasState: canvasState,
                chatStartupIndependent: true,
                canvasCapabilities: canvasState.isHealthy
                    ? ["canvas_read", "canvas_mutation"]
                    : [],
                failClosedReason: canvasState.failureReason
            )
        }
    }

    enum IsolationError: Error, Equatable, Sendable {
        case notRunningInTestProcess
        case invalidProfileLabel
        case invalidDisposableRoot
        case missingFieldActivationArgument
        case missingFieldActivationEnvironment
        case invalidFieldActivationEnvironment
        case invalidFieldWitnessRequest
    }

    /// Typed, user-safe launch failure. The underlying error is retained for
    /// tests and diagnostics, while UI callers use `safeCode`/`userMessage`
    /// and never receive a path, environment value, or secret.
    enum BootstrapFailure: Error, Equatable, Sendable {
        case profileResolution(IsolationError)
        case unexpectedProfileResolution
        case isolatedJourneyCredentialUnavailable

        var safeCode: String {
            switch self {
            case .profileResolution(let error):
                switch error {
                case .notRunningInTestProcess:
                    return "BOOTSTRAP_TEST_PROCESS_REQUIRED"
                case .invalidProfileLabel:
                    return "BOOTSTRAP_INVALID_PROFILE_LABEL"
                case .invalidDisposableRoot:
                    return "BOOTSTRAP_INVALID_DISPOSABLE_ROOT"
                case .missingFieldActivationArgument:
                    return "BOOTSTRAP_FIELD_ARGUMENT_INVALID"
                case .missingFieldActivationEnvironment:
                    return "BOOTSTRAP_FIELD_ENVIRONMENT_MISSING"
                case .invalidFieldActivationEnvironment:
                    return "BOOTSTRAP_FIELD_ENVIRONMENT_INVALID"
                case .invalidFieldWitnessRequest:
                    return "BOOTSTRAP_FIELD_WITNESS_INVALID"
                }
            case .unexpectedProfileResolution:
                return "BOOTSTRAP_PROFILE_RESOLUTION_FAILED"
            case .isolatedJourneyCredentialUnavailable:
                return "DEEPSEEK_JOURNEY_KEY_MISSING_OR_UNSAFE"
            }
        }

        var userMessage: String {
            if self == .isolatedJourneyCredentialUnavailable {
                return "隔离旅程无法启动：请由本人在隔离根的 deepseek-api-key 文件中配置单行密钥（本人所有、0600、非链接），然后重新打开应用。"
            }
            return "无法安全启动：隔离运行环境未通过校验。请修正启动配置后重新打开应用。"
        }
    }

    enum LaunchProfileResolution: Equatable, Sendable {
        case ready(RuntimeIsolationProfile)
        case blocked(BootstrapFailure)
    }

    static let profileMarkerKey = "MINISCANVAS_TEST_PROFILE"
    static let profileDirectoryKey = "MINISCANVAS_TEST_DIRECTORY"
    static let fieldActivationArgument = "--miniscanvas-field-profile"
    static let fieldActivationMarkerKey = "MINISCANVAS_FIELD_PROFILE"
    static let fieldActivationRootKey = "MINISCANVAS_FIELD_PROFILE_ROOT"
    static let fieldWitnessArgument = "--miniscanvas-field-root-witness"
    static let profileIdentityKey = "MINISCANVAS_PROFILE_IDENTITY"

    let mode: Mode
    let label: String
    let rootDirectory: URL
    let disposableRootIdentity: DisposableRootIdentity?
    let applicationSupportDirectory: URL
    let minisCanvasDirectory: URL
    let minisCoreDirectory: URL
    let settingsDirectory: URL
    let sessionDirectory: URL
    let memoryDirectory: URL
    let taskDirectory: URL
    let mcpDirectory: URL
    let providerConfigurationDirectory: URL
    let logDirectory: URL
    let browserStateDirectory: URL
    let terminalStateDirectory: URL
    let attachmentsDirectory: URL
    let temporaryDirectory: URL
    let hermesSkillsDirectory: URL
    let skillStateURL: URL
    let keychainService: String
    let userDefaultsSuiteName: String?
    let environment: [String: String]
    let canvasRuntimeState: CanvasRuntimeState

    /// Sendable defaults-domain descriptor for stores that own their
    /// UserDefaults instance. Production uses standard; disposable field
    /// profiles use their stable per-profile suite.
    var usageStoreDefaultsDomain: UsageDefaultsDomain {
        userDefaultsSuiteName.map(UsageDefaultsDomain.suite) ?? .standard
    }

    static var production: RuntimeIsolationProfile {
        let sessionDirectory = SessionStore.defaultDirectory
        let applicationSupportDirectory = sessionDirectory.deletingLastPathComponent()
        let minisCoreDirectory = EnvVarStore.defaultDirectory()
        let mcpConfigurationURL = MCPServerManager.defaultFileURL()
        return RuntimeIsolationProfile(
            mode: .production,
            label: "production",
            rootDirectory: applicationSupportDirectory,
            disposableRootIdentity: nil,
            applicationSupportDirectory: applicationSupportDirectory,
            minisCanvasDirectory: sessionDirectory,
            minisCoreDirectory: minisCoreDirectory,
            settingsDirectory: minisCoreDirectory,
            sessionDirectory: sessionDirectory,
            memoryDirectory: sessionDirectory,
            taskDirectory: sessionDirectory,
            mcpDirectory: mcpConfigurationURL.deletingLastPathComponent(),
            providerConfigurationDirectory: minisCoreDirectory,
            logDirectory: applicationSupportDirectory.appendingPathComponent(
                "logs",
                isDirectory: true
            ),
            browserStateDirectory: sessionDirectory.appendingPathComponent(
                "browser",
                isDirectory: true
            ),
            terminalStateDirectory: sessionDirectory.appendingPathComponent(
                "terminal",
                isDirectory: true
            ),
            attachmentsDirectory: sessionDirectory.appendingPathComponent(
                "ChatAttachments",
                isDirectory: true
            ),
            temporaryDirectory: FileManager.default.temporaryDirectory,
            hermesSkillsDirectory: minisCoreDirectory,
            skillStateURL: SkillsStateStore.defaultFileURL(),
            keychainService: KeychainStore.defaultService,
            userDefaultsSuiteName: nil,
            environment: [:],
            canvasRuntimeState: .disabled
        )
    }

    static func makeIsolatedTest(
        label: String = "MinisCanvasAppTests",
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        processArguments: [String] = ProcessInfo.processInfo.arguments,
        canvasRuntimeState: CanvasRuntimeState = .enabled
    ) throws -> RuntimeIsolationProfile {
        guard isRunningInTestProcess(
            environment: processEnvironment,
            arguments: processArguments
        ) else {
            throw IsolationError.notRunningInTestProcess
        }

        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MinisCanvasAppTests-\(label)-\(UUID().uuidString)",
                isDirectory: true
            )
        return try makeDisposableProfile(
            mode: .isolatedTest,
            label: label,
            rootDirectory: rootDirectory,
            canvasRuntimeState: canvasRuntimeState
        )
    }

    /// Live launch always asks the Core formal-test boundary before any
    /// production default path is evaluated.
    static func resolveLaunchProfile() throws -> RuntimeIsolationProfile {
        try resolveLaunchProfile(
            processEnvironment: ProcessInfo.processInfo.environment,
            processArguments: ProcessInfo.processInfo.arguments,
            processName: ProcessInfo.processInfo.processName
        )
    }

    /// Injected inputs are for profile tests. HOME/TMPDIR/XDG_CONFIG_HOME do
    /// not select a profile; Core independently recognizes native test hosts.
    static func resolveLaunchProfile(
        processEnvironment: [String: String],
        processArguments: [String],
        processName: String = "MinisCanvasApp"
    ) throws -> RuntimeIsolationProfile {
        do {
            if let paths = try FormalTestIsolationPaths.resolve(
                environment: processEnvironment,
                arguments: processArguments,
                processName: processName
            ) {
                return makeFormalTestProfile(paths)
            }
        } catch {
            // Preserve 030's typed refusal for malformed field-only input.
            // Core has already rejected it; this maps the old diagnostic but
            // never converts a rejected native test into a field profile.
            let formalKeys = [
                FormalTestIsolationPaths.profileMarkerKey,
                FormalTestIsolationPaths.profileDirectoryKey,
                FormalTestIsolationPaths.profileIdentityKey,
                FormalTestIsolationPaths.runIDKey,
                FormalTestIsolationPaths.packageKey,
                FormalTestIsolationPaths.scratchDirectoryKey,
                FormalTestIsolationPaths.rootDeviceKey,
                FormalTestIsolationPaths.rootInodeKey,
                FormalTestIsolationPaths.rootOwnerKey
            ]
            let hasFormalInput = formalKeys.contains { processEnvironment[$0] != nil }
            let witnessCount = processArguments.filter { $0 == fieldWitnessArgument }.count
            let argumentCount = processArguments.filter { $0 == fieldActivationArgument }.count
            let hasFieldSignal = witnessCount > 0 || argumentCount > 0
                || processEnvironment[fieldActivationMarkerKey] != nil
                || processEnvironment[fieldActivationRootKey] != nil
            if hasFieldSignal && !hasFormalInput {
                if witnessCount > 1 { throw IsolationError.invalidFieldWitnessRequest }
                if argumentCount != 1 { throw IsolationError.missingFieldActivationArgument }
                if processEnvironment[fieldActivationMarkerKey] != "1" {
                    throw IsolationError.invalidFieldActivationEnvironment
                }
                if processEnvironment[fieldActivationRootKey]?.isEmpty != false {
                    throw IsolationError.missingFieldActivationEnvironment
                }
            }
            throw error
        }
        let argumentCount = processArguments.filter {
            $0 == fieldActivationArgument
        }.count
        let witnessCount = processArguments.filter {
            $0 == fieldWitnessArgument
        }.count
        guard witnessCount <= 1 else { throw IsolationError.invalidFieldWitnessRequest }
        let hasActivationSignal = argumentCount > 0
            || witnessCount > 0
            || processEnvironment[fieldActivationMarkerKey] != nil
            || processEnvironment[fieldActivationRootKey] != nil
        guard hasActivationSignal else { return .production }
        guard argumentCount == 1 else {
            throw IsolationError.missingFieldActivationArgument
        }
        return try makePackagedField(
            processEnvironment: processEnvironment,
            processArguments: processArguments
        )
    }

    /// A projection of the one validated Core value. No App path or suite is
    /// independently derived, and no production Keychain service is consulted.
    private static func makeFormalTestProfile(
        _ paths: FormalTestIsolationPaths
    ) -> RuntimeIsolationProfile {
        RuntimeIsolationProfile(
            mode: .isolatedTest,
            label: "formal-test",
            rootDirectory: paths.rootDirectory,
            disposableRootIdentity: DisposableRootIdentity(
                device: paths.rootDevice,
                inode: paths.rootInode
            ),
            applicationSupportDirectory: paths.applicationSupportDirectory,
            minisCanvasDirectory: paths.minisCanvasDirectory,
            minisCoreDirectory: paths.minisCoreDirectory,
            settingsDirectory: paths.settingsDirectory,
            sessionDirectory: paths.sessionDirectory,
            memoryDirectory: paths.memoryDirectory,
            taskDirectory: paths.taskDirectory,
            mcpDirectory: paths.mcpDirectory,
            providerConfigurationDirectory: paths.providerConfigurationDirectory,
            logDirectory: paths.logDirectory,
            browserStateDirectory: paths.browserStateDirectory,
            terminalStateDirectory: paths.terminalStateDirectory,
            attachmentsDirectory: paths.attachmentsDirectory,
            temporaryDirectory: paths.temporaryDirectory,
            hermesSkillsDirectory: paths.hermesSkillsDirectory,
            skillStateURL: paths.skillStateURL,
            keychainService: paths.keychainService,
            userDefaultsSuiteName: paths.userDefaultsSuiteName,
            environment: [
                profileMarkerKey: "1",
                profileDirectoryKey: paths.rootDirectory.path
            ],
            canvasRuntimeState: .enabled
        )
    }

    /// Default App consumers that have no throwing initializer use this
    /// process-local projection. A malformed formal test traps; a malformed
    /// non-test field launch stays on the disposable bootstrap blocker root.
    static func formalTestProfileForDefaultConsumer() -> RuntimeIsolationProfile? {
        do {
            return try FormalTestIsolationPaths.resolveCurrentProcess()
                .map(makeFormalTestProfile)
        } catch {
            if isRunningInTestProcess()
                || ProcessInfo.processInfo.processName.lowercased() == "swiftpm-testing-helper" {
                preconditionFailure("Invalid formal test isolation contract")
            }
            return blockedProfile()
        }
    }

    /// Build a disposable profile for the packaged Preview/field harness.
    /// Unlike the test factory, this path is not test-process-only, but every
    /// activation input remains explicit and the root is constrained to temp.
    static func makePackagedField(
        label: String = "packaged-field",
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        processArguments: [String] = ProcessInfo.processInfo.arguments,
        canvasRuntimeState: CanvasRuntimeState = .enabled
    ) throws -> RuntimeIsolationProfile {
        guard processArguments.filter({ $0 == fieldActivationArgument }).count == 1 else {
            throw IsolationError.missingFieldActivationArgument
        }
        guard processEnvironment[fieldActivationMarkerKey] == "1" else {
            throw IsolationError.invalidFieldActivationEnvironment
        }
        guard let rootPath = processEnvironment[fieldActivationRootKey],
              !rootPath.isEmpty else {
            throw IsolationError.missingFieldActivationEnvironment
        }
        return try makeDisposableProfile(
            mode: .packagedField,
            label: label,
            rootDirectory: URL(fileURLWithPath: rootPath, isDirectory: true),
            canvasRuntimeState: canvasRuntimeState
        )
    }

    /// App entry helper. Resolution happens before `self.init(profile:)`, so
    /// malformed field activation cannot construct a durable store first.
    /// Errors are typed rather than escalated with a process-trapping
    /// precondition, allowing the GUI to render a safe blocker.
    static func launchProfileResolution() -> LaunchProfileResolution {
        do {
            return .ready(try resolveLaunchProfile())
        } catch let error as IsolationError {
            return .blocked(.profileResolution(error))
        } catch {
            return .blocked(.unexpectedProfileResolution)
        }
    }

    static func launchProfileResolution(
        processEnvironment: [String: String],
        processArguments: [String],
        processName: String = "MinisCanvasApp"
    ) -> LaunchProfileResolution {
        do {
            return .ready(try resolveLaunchProfile(
                processEnvironment: processEnvironment,
                processArguments: processArguments,
                processName: processName
            ))
        } catch let error as IsolationError {
            return .blocked(.profileResolution(error))
        } catch {
            return .blocked(.unexpectedProfileResolution)
        }
    }

    /// The nonthrowing SettingsCenter initializer cannot surface a bootstrap
    /// result. Refuse an invalid formal test contract before any default store
    /// argument is constructed or a production directory is requested.
    static func defaultConstructionProfile() -> RuntimeIsolationProfile {
        do {
            return try resolveLaunchProfile()
        } catch {
            preconditionFailure("Invalid runtime isolation contract")
        }
    }

    /// A disposable, non-production profile for the bootstrap blocker. Even
    /// if the temporary filesystem is unavailable, this remains a blocked
    /// profile and never falls back to the user's production directories.
    static func blockedProfile() -> RuntimeIsolationProfile {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MinisCanvasBootstrapBlocked-\(UUID().uuidString)",
                isDirectory: true
            )
            .standardizedFileURL
        let rootIdentity: DisposableRootIdentity?
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            rootIdentity = directoryIdentity(at: root)
        } catch {
            rootIdentity = nil
        }
        let profile = makeDisposableProfileValue(
            mode: .blocked,
            label: "bootstrap-blocked",
            normalizedRoot: root,
            canvasRuntimeState: .disabled,
            disposableRootIdentity: rootIdentity
        )
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            for disposableRoot in profile.disposableRoots {
                try FileManager.default.createDirectory(
                    at: disposableRoot,
                    withIntermediateDirectories: true
                )
            }
        } catch {
            // The blocker is still safe: all stores remain pointed at the
            // disposable root and no production profile is substituted.
        }
        return profile
    }

    private static func makeDisposableProfile(
        mode: Mode,
        label: String,
        rootDirectory: URL,
        canvasRuntimeState: CanvasRuntimeState = .enabled
    ) throws -> RuntimeIsolationProfile {
        guard mode != .production else {
            return .production
        }

        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty,
              trimmedLabel.range(
                  of: #"^[A-Za-z0-9._-]+$"#,
                  options: .regularExpression
              ) != nil else {
            throw IsolationError.invalidProfileLabel
        }

        let normalizedRoot: URL
        switch disposableRootOutcome(for: rootDirectory) {
        case .resolved(let root):
            normalizedRoot = root
        case .unavailable, .unsafe:
            throw IsolationError.invalidDisposableRoot
        }
        try FileManager.default.createDirectory(
            at: normalizedRoot,
            withIntermediateDirectories: true
        )
        guard let rootIdentity = Self.directoryIdentity(at: normalizedRoot) else {
            throw IsolationError.invalidDisposableRoot
        }
        let profile = makeDisposableProfileValue(
            mode: mode,
            label: trimmedLabel,
            normalizedRoot: normalizedRoot,
            canvasRuntimeState: canvasRuntimeState,
            disposableRootIdentity: rootIdentity
        )

        if mode == .packagedField {
            try profile.prepareFieldSessionDirectory()
        }
        for root in profile.disposableRoots {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
        }
        guard profile.isDisposableRootIntact else {
            throw IsolationError.invalidDisposableRoot
        }
        return profile
    }

    /// Only the explicitly selected disposable field domain may repair its
    /// legacy Chat permissions. Never follow a path while changing its mode.
    private func prepareFieldSessionDirectory() throws {
        guard mode == .packagedField, let expectedRoot = disposableRootIdentity,
              isDisposableRootIntact else { throw IsolationError.invalidDisposableRoot }
        let rootFD = open(rootDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw IsolationError.invalidDisposableRoot }
        defer { _ = close(rootFD) }
        var rootInfo = stat()
        guard fstat(rootFD, &rootInfo) == 0, rootInfo.st_uid == geteuid(),
              (rootInfo.st_mode & S_IFMT) == S_IFDIR,
              UInt64(rootInfo.st_dev) == expectedRoot.device,
              UInt64(rootInfo.st_ino) == expectedRoot.inode else {
            throw IsolationError.invalidDisposableRoot
        }
        if mkdirat(rootFD, "Application Support", mode_t(0o755)) != 0 && errno != EEXIST {
            throw IsolationError.invalidDisposableRoot
        }
        let parentFD = openat(rootFD, "Application Support", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw IsolationError.invalidDisposableRoot }
        defer { _ = close(parentFD) }
        var parentInfo = stat()
        guard fstat(parentFD, &parentInfo) == 0, parentInfo.st_uid == geteuid(),
              (parentInfo.st_mode & S_IFMT) == S_IFDIR,
              parentInfo.st_dev == rootInfo.st_dev,
              Self.directoryIdentity(at: applicationSupportDirectory) == DisposableRootIdentity(
                device: UInt64(parentInfo.st_dev), inode: UInt64(parentInfo.st_ino)
              ) else { throw IsolationError.invalidDisposableRoot }
        if mkdirat(parentFD, "Chat", mode_t(0o700)) != 0 && errno != EEXIST {
            throw IsolationError.invalidDisposableRoot
        }
        let sessionFD = openat(parentFD, "Chat", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard sessionFD >= 0 else { throw IsolationError.invalidDisposableRoot }
        defer { _ = close(sessionFD) }
        var info = stat()
        guard fstat(sessionFD, &info) == 0, info.st_uid == geteuid(),
              (info.st_mode & S_IFMT) == S_IFDIR, info.st_dev == rootInfo.st_dev,
              (info.st_mode & mode_t(0o7777)) == 0o700 || (info.st_mode & mode_t(0o7777)) == 0o755,
              Self.directoryIdentity(at: sessionDirectory) == DisposableRootIdentity(
                device: UInt64(info.st_dev), inode: UInt64(info.st_ino)
              ), isDisposableRootIntact,
              Self.directoryIdentity(at: applicationSupportDirectory) == DisposableRootIdentity(
                device: UInt64(parentInfo.st_dev), inode: UInt64(parentInfo.st_ino)
              ) else { throw IsolationError.invalidDisposableRoot }
        let identity = DisposableRootIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
        guard fchmod(sessionFD, mode_t(0o700)) == 0,
              fstat(sessionFD, &info) == 0, info.st_uid == geteuid(),
              (info.st_mode & S_IFMT) == S_IFDIR,
              (info.st_mode & mode_t(0o7777)) == 0o700,
              UInt64(info.st_dev) == identity.device, UInt64(info.st_ino) == identity.inode,
              Self.directoryIdentity(at: sessionDirectory) == identity,
              Self.directoryIdentity(at: applicationSupportDirectory) == DisposableRootIdentity(
                device: UInt64(parentInfo.st_dev), inode: UInt64(parentInfo.st_ino)
              ), isDisposableRootIntact else { throw IsolationError.invalidDisposableRoot }
    }

    /// Classify a candidate root before any disposable directories are
    /// created.  This is intentionally a pure profile boundary: production
    /// directories are never a fallback for an unavailable or unsafe input.
    static func disposableRootOutcome(
        for rootDirectory: URL
    ) -> DisposableRootOutcome {
        guard !rootDirectory.relativePath.isEmpty else {
            return .unavailable
        }
        do {
            return .resolved(try normalizedDisposableRoot(rootDirectory))
        } catch IsolationError.invalidDisposableRoot {
            return .unsafe
        } catch {
            return .unavailable
        }
    }

    private static func makeDisposableProfileValue(
        mode: Mode,
        label trimmedLabel: String,
        normalizedRoot: URL,
        canvasRuntimeState: CanvasRuntimeState,
        disposableRootIdentity: DisposableRootIdentity? = nil
    ) -> RuntimeIsolationProfile {
        let applicationSupportDirectory = normalizedRoot
            .appendingPathComponent("Application Support", isDirectory: true)
        let minisCanvasDirectory = normalizedRoot
            .appendingPathComponent("Canvas", isDirectory: true)
        let sessionDirectory = applicationSupportDirectory
            .appendingPathComponent("Chat", isDirectory: true)
        let minisCoreDirectory = applicationSupportDirectory
            .appendingPathComponent("MinisCore", isDirectory: true)
        let temporaryDirectory = normalizedRoot
            .appendingPathComponent("temporary", isDirectory: true)
        let hermesSkillsDirectory = normalizedRoot
            .appendingPathComponent("hermes-skills", isDirectory: true)
        let logDirectory = minisCanvasDirectory
            .appendingPathComponent("logs", isDirectory: true)
        let skillStateURL = minisCoreDirectory
            .appendingPathComponent("skills-enabled.json", isDirectory: false)
        let profileIdentity = "\(mode.rawValue):\(trimmedLabel):\(normalizedRoot.path)"
        var profileEnvironment = [
            profileMarkerKey: "1",
            profileDirectoryKey: normalizedRoot.path
        ]
        if mode == .packagedField {
            profileEnvironment[fieldActivationMarkerKey] = "1"
            profileEnvironment[fieldActivationRootKey] = normalizedRoot.path
            profileEnvironment[profileIdentityKey] = profileIdentity
        }
        let keychainPrefix = mode == .isolatedTest || mode == .blocked
            ? "com.miniscanvas.test."
            : "com.miniscanvas.packaged-field."
        let userDefaultsSuiteName =
            "com.miniscanvas.\(mode.rawValue).preferences.\(stableIdentifier(profileIdentity))"
        // A packaged-field launch may be recreated after the app restarts. Its
        // disposable root and label therefore define a stable Keychain
        // namespace, while isolated-test profiles deliberately retain a fresh
        // UUID so parallel test runs cannot cross-read credentials.
        let keychainService = mode == .isolatedTest
            ? "\(keychainPrefix)\(trimmedLabel).\(UUID().uuidString)"
            : "\(keychainPrefix)\(stableIdentifier(profileIdentity))"

        return RuntimeIsolationProfile(
            mode: mode,
            label: trimmedLabel,
            rootDirectory: normalizedRoot,
            disposableRootIdentity: disposableRootIdentity,
            applicationSupportDirectory: applicationSupportDirectory,
            minisCanvasDirectory: minisCanvasDirectory,
            minisCoreDirectory: minisCoreDirectory,
            settingsDirectory: minisCoreDirectory,
            sessionDirectory: sessionDirectory,
            memoryDirectory: sessionDirectory,
            taskDirectory: sessionDirectory,
            mcpDirectory: minisCoreDirectory.appendingPathComponent(
                "mcp",
                isDirectory: true
            ),
            providerConfigurationDirectory: minisCoreDirectory.appendingPathComponent(
                "providers",
                isDirectory: true
            ),
            logDirectory: logDirectory,
            browserStateDirectory: sessionDirectory.appendingPathComponent(
                "browser",
                isDirectory: true
            ),
            terminalStateDirectory: sessionDirectory.appendingPathComponent(
                "terminal",
                isDirectory: true
            ),
            attachmentsDirectory: sessionDirectory.appendingPathComponent(
                "ChatAttachments",
                isDirectory: true
            ),
            temporaryDirectory: temporaryDirectory,
            hermesSkillsDirectory: hermesSkillsDirectory,
            skillStateURL: skillStateURL,
            keychainService: keychainService,
            userDefaultsSuiteName: userDefaultsSuiteName,
            environment: profileEnvironment,
            canvasRuntimeState: canvasRuntimeState
        )
    }

    private static func stableMappedPath(_ url: URL) -> String? {
        guard case .resolved(let rawMapped) = DarwinSystemPathResolver.resolveOutcome(url),
              case .resolved(let standardizedMapped) = DarwinSystemPathResolver.resolveOutcome(
                  url.standardizedFileURL
              ),
              case .resolved(let resolvedMapped) = DarwinSystemPathResolver.resolveOutcome(
                  url.resolvingSymlinksInPath().standardizedFileURL
              ),
              rawMapped == standardizedMapped,
              rawMapped == resolvedMapped else {
            return nil
        }
        return rawMapped
    }

    private static func normalizedDisposableRoot(_ rootDirectory: URL) throws -> URL {
        let temporaryRoot = FileManager.default.temporaryDirectory
        guard let mappedTemporaryRoot = stableMappedPath(temporaryRoot),
              let mappedRoot = stableMappedPath(rootDirectory) else {
            throw IsolationError.invalidDisposableRoot
        }
        guard rootDirectory.isFileURL,
              rootDirectory.path.hasPrefix("/"),
              mappedRoot != mappedTemporaryRoot,
              mappedRoot.hasPrefix(mappedTemporaryRoot + "/") else {
            throw IsolationError.invalidDisposableRoot
        }
        // Keep the resolver's mapped spelling as the namespace identity.
        // Standardizing it again would make existence change `/private/var`
        // back to `/var` and mint a different profile after creation.
        return URL(fileURLWithPath: mappedRoot, isDirectory: true)
    }

    private static func directoryIdentity(at directory: URL) -> DisposableRootIdentity? {
        var info = stat()
        guard lstat(directory.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR else {
            return nil
        }
        return DisposableRootIdentity(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino)
        )
    }

    private static func validateDisposableTree(
        at directory: URL,
        expectedDevice: UInt64
    ) throws {
        var info = stat()
        guard lstat(directory.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              UInt64(info.st_dev) == expectedDevice else {
            throw IsolationError.invalidDisposableRoot
        }
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            )
        } catch {
            throw IsolationError.invalidDisposableRoot
        }
        for entry in entries {
            var entryInfo = stat()
            guard lstat(entry.path, &entryInfo) == 0,
                  UInt64(entryInfo.st_dev) == expectedDevice else {
                throw IsolationError.invalidDisposableRoot
            }
            let type = entryInfo.st_mode & S_IFMT
            guard type != S_IFLNK else {
                throw IsolationError.invalidDisposableRoot
            }
            if type == S_IFREG {
                // A regular file with multiple links may have an owner outside
                // this profile. Removing it would mutate that external owner.
                guard entryInfo.st_nlink <= 1 else {
                    throw IsolationError.invalidDisposableRoot
                }
            } else if type == S_IFDIR {
                try validateDisposableTree(at: entry, expectedDevice: expectedDevice)
            }
        }
    }

    /// Stable, filesystem-independent suffix for the profile preference domain.
    /// Swift's `hashValue` is intentionally randomized per process, so use a
    /// deterministic FNV-1a digest to preserve field restart/recovery semantics.
    private static func stableIdentifier(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    static func isRunningInTestProcess(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        let argumentLine = arguments.joined(separator: " ")
        return argumentLine.contains(".xctest")
            || argumentLine.contains("swiftpm-testing-helper")
            || argumentLine.contains("-XCTest")
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["SWIFT_TESTING_ENABLED"] != nil
    }

    var isDisposable: Bool {
        mode != .production
    }

    /// External provider/browser network is production-only. Disposable
    /// profiles keep their filesystem and credential namespaces but cannot
    /// inherit the host process network capability.
    var allowsExternalNetwork: Bool {
        mode == .production
    }

    /// A failed Canvas profile has no runtime path at all.  This keeps a
    /// disabled/absent/corrupt Canvas from reusing Chat, Application Support,
    /// temporary, or cache paths through an accidental activation.
    var canvasRuntimeDirectory: URL? {
        guard canvasRuntimeState.allowsCanvasActivation,
              isDisposableRootIntact else { return nil }
        return minisCanvasDirectory
    }

    /// Re-check the disposable root immediately before an operation that will
    /// open or finalize profile-backed state.  A replaced directory, symlink,
    /// or mount identity is rejected instead of following the stale path.
    func validateDisposableRootIdentity() throws {
        guard isDisposable else { return }
        guard let disposableRootIdentity,
              Self.directoryIdentity(at: rootDirectory) == disposableRootIdentity else {
            throw IsolationError.invalidDisposableRoot
        }
    }

    /// Validate every entry before recursive cleanup.  The walk uses `lstat`
    /// and refuses links, hardlinked regular files, and foreign devices, so a
    /// profile cannot delete or follow storage outside its captured identity.
    func validateDisposableTree() throws {
        guard isDisposable else { return }
        try validateDisposableRootIdentity()
        guard let disposableRootIdentity else {
            throw IsolationError.invalidDisposableRoot
        }
        try Self.validateDisposableTree(
            at: rootDirectory,
            expectedDevice: disposableRootIdentity.device
        )
    }

    var isDisposableRootIntact: Bool {
        guard isDisposable else { return true }
        guard let disposableRootIdentity else { return false }
        return Self.directoryIdentity(at: rootDirectory) == disposableRootIdentity
    }

    var launchIdentity: String {
        "\(mode.rawValue):\(label):\(rootDirectory.path)"
    }

    struct FieldWitnessProcessIdentity: Equatable, Sendable {
        let pid: Int32
        let uid: UInt32
        let startSeconds: UInt64
        let startMicroseconds: UInt64
    }

    struct FieldWitnessReceipt: Codable, Equatable, Sendable {
        let schema: String
        let phase: String
        let instanceId: String
        let pid: Int32
        let uid: UInt32
        let startSeconds: UInt64
        let startMicroseconds: UInt64
        let createdAt: String
        let mode: String
        let rootPath: String
        let rootDevice: UInt64
        let rootInode: UInt64
        let profileIdentity: String
        let userDefaultsSuite: String
        let keychainService: String
        let keychainLegacyServices: [String]
        /// Actual KeychainStore descriptor, separate from the profile namespace.
        /// The namespaced in-memory factory reports injected, never SecItem.
        let keychainBackingKind: String
        let keychainBackingService: String?
        let settingsDirectory: String
        let sessionDirectory: String
    }

    enum FieldWitnessError: Error {
        case refused
    }

    static func fieldWitnessRequested(
        processArguments: [String] = CommandLine.arguments
    ) -> Bool {
        processArguments.filter { $0 == fieldWitnessArgument }.count == 1
    }

    /// Matches the existing native field journey's process-start observation.
    /// It reads only the current process metadata, never a Keychain item or
    /// another process's environment.
    private static func currentFieldWitnessProcessIdentity() throws -> FieldWitnessProcessIdentity {
        let pid = getpid()
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info,
                           Int32(MemoryLayout<proc_bsdinfo>.size))
                == Int32(MemoryLayout<proc_bsdinfo>.size),
              info.pbi_pid == UInt32(pid), info.pbi_uid == geteuid(),
              info.pbi_status != 5 else { throw FieldWitnessError.refused }
        return FieldWitnessProcessIdentity(
            pid: pid,
            uid: info.pbi_uid,
            startSeconds: UInt64(info.pbi_start_tvsec),
            startMicroseconds: UInt64(info.pbi_start_tvusec)
        )
    }

    /// The receipt is built from the same immutable profile used to construct
    /// the real stores. The actual store paths and backing service must agree.
    func makeFieldWitnessReceipt(
        process: FieldWitnessProcessIdentity,
        instanceID: UUID,
        createdAt: String,
        actualKeychainBacking: KeychainStore.BackingKind,
        actualSettingsDirectory: URL,
        actualSessionDirectory: URL
    ) throws -> FieldWitnessReceipt {
        guard mode == .packagedField,
              let rootIdentity = disposableRootIdentity,
              isDisposableRootIntact,
              let userDefaultsSuiteName,
              environment[Self.profileIdentityKey] == launchIdentity,
              keychainLegacyServices.isEmpty,
              matchesKeychainBacking(actualKeychainBacking),
              actualSettingsDirectory == settingsDirectory,
              actualSessionDirectory == sessionDirectory,
              process.pid > 0, process.uid == geteuid(),
              process.startSeconds > 0, process.startMicroseconds < 1_000_000 else {
            throw FieldWitnessError.refused
        }
        return FieldWitnessReceipt(
            schema: "miniscanvas.field-root-witness/v2",
            phase: "COMPOSITION_READY",
            instanceId: instanceID.uuidString.lowercased(),
            pid: process.pid,
            uid: process.uid,
            startSeconds: process.startSeconds,
            startMicroseconds: process.startMicroseconds,
            createdAt: createdAt,
            mode: mode.rawValue,
            rootPath: rootDirectory.path,
            rootDevice: rootIdentity.device,
            rootInode: rootIdentity.inode,
            profileIdentity: launchIdentity,
            userDefaultsSuite: userDefaultsSuiteName,
            keychainService: keychainService,
            keychainLegacyServices: keychainLegacyServices,
            keychainBackingKind: "injected",
            keychainBackingService: nil,
            settingsDirectory: actualSettingsDirectory.path,
            sessionDirectory: actualSessionDirectory.path
        )
    }

    /// Only an explicitly requested packaged-field launch publishes a witness.
    /// This is a non-secret observation, never a launch authority or L06 PASS.
    func publishFieldWitness(
        actualKeychainBacking: KeychainStore.BackingKind,
        actualSettingsDirectory: URL,
        actualSessionDirectory: URL
    ) throws {
        let process = try Self.currentFieldWitnessProcessIdentity()
        let receipt = try makeFieldWitnessReceipt(
            process: process,
            instanceID: UUID(),
            createdAt: ISO8601DateFormatter().string(from: Date()),
            actualKeychainBacking: actualKeychainBacking,
            actualSettingsDirectory: actualSettingsDirectory,
            actualSessionDirectory: actualSessionDirectory
        )
        try writeFieldWitness(receipt)
    }

    /// Anchors every operation to the captured root descriptor. Each process
    /// gets an exclusive generation; a restart never overwrites prior evidence.
    func writeFieldWitness(_ receipt: FieldWitnessReceipt) throws {
        guard mode == .packagedField,
              let rootIdentity = disposableRootIdentity,
              let userDefaultsSuiteName,
              let instanceID = UUID(uuidString: receipt.instanceId),
              instanceID.uuidString.lowercased() == receipt.instanceId,
              receipt.schema == "miniscanvas.field-root-witness/v2",
              receipt.phase == "COMPOSITION_READY",
              receipt.pid > 0,
              receipt.startSeconds > 0,
              receipt.startMicroseconds < 1_000_000,
              receipt.mode == mode.rawValue,
              receipt.rootPath == rootDirectory.path,
              receipt.rootDevice == rootIdentity.device,
              receipt.rootInode == rootIdentity.inode,
              receipt.profileIdentity == launchIdentity,
              receipt.userDefaultsSuite == userDefaultsSuiteName,
              receipt.keychainService == keychainService,
              receipt.keychainBackingKind == "injected",
              receipt.keychainBackingService == nil,
              receipt.keychainLegacyServices.isEmpty,
              receipt.settingsDirectory == settingsDirectory.path,
              receipt.sessionDirectory == sessionDirectory.path,
              isDisposableRootIntact else { throw FieldWitnessError.refused }

        let rootFD = open(rootDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw FieldWitnessError.refused }
        defer { _ = close(rootFD) }
        var rootInfo = stat()
        guard fstat(rootFD, &rootInfo) == 0,
              (rootInfo.st_mode & S_IFMT) == S_IFDIR,
              rootInfo.st_uid == geteuid(),
              (rootInfo.st_mode & mode_t(0o022)) == 0,
              UInt64(rootInfo.st_dev) == rootIdentity.device,
              UInt64(rootInfo.st_ino) == rootIdentity.inode else {
            throw FieldWitnessError.refused
        }

        let directoryName = ".miniscanvas-field-witness"
        if mkdirat(rootFD, directoryName, mode_t(0o700)) != 0 && errno != EEXIST {
            throw FieldWitnessError.refused
        }
        let directoryFD = openat(rootFD, directoryName,
                                 O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw FieldWitnessError.refused }
        defer { _ = close(directoryFD) }
        var directoryInfo = stat()
        guard fstat(directoryFD, &directoryInfo) == 0,
              (directoryInfo.st_mode & S_IFMT) == S_IFDIR,
              directoryInfo.st_uid == geteuid(),
              (directoryInfo.st_mode & mode_t(0o077)) == 0,
              directoryInfo.st_dev == rootInfo.st_dev else {
            throw FieldWitnessError.refused
        }

        let name = "\(receipt.pid)-\(receipt.startSeconds)-\(receipt.startMicroseconds)-\(receipt.instanceId).json"
        let fileFD = openat(directoryFD, name,
                            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                            mode_t(0o600))
        guard fileFD >= 0 else { throw FieldWitnessError.refused }
        defer { _ = close(fileFD) }
        var fileInfo = stat()
        guard fstat(fileFD, &fileInfo) == 0,
              (fileInfo.st_mode & S_IFMT) == S_IFREG,
              fileInfo.st_uid == geteuid(),
              (fileInfo.st_mode & mode_t(0o077)) == 0,
              fileInfo.st_nlink == 1 else { throw FieldWitnessError.refused }

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(receipt)
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { throw FieldWitnessError.refused }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fileFD, base.advanced(by: offset), bytes.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw FieldWitnessError.refused }
                offset += written
            }
        }
        guard fsync(fileFD) == 0, fsync(directoryFD) == 0,
              fstat(rootFD, &rootInfo) == 0,
              UInt64(rootInfo.st_dev) == rootIdentity.device,
              UInt64(rootInfo.st_ino) == rootIdentity.inode,
              isDisposableRootIntact else { throw FieldWitnessError.refused }
    }

    var agentTaskStorePersistenceURL: URL {
        taskDirectory.appendingPathComponent("agent-tasks-v1.json")
    }

    var mcpConfigurationURL: URL {
        mcpDirectory.appendingPathComponent("mcps.json")
    }

    var mcpAuthorizationURL: URL {
        mcpDirectory.appendingPathComponent("mcp-authorizations.json")
    }

    var providerReadinessURL: URL {
        providerConfigurationDirectory.appendingPathComponent(
            ProviderReadinessStore.fileName
        )
    }

    var disposableRoots: [URL] {
        [
            rootDirectory,
            applicationSupportDirectory,
            minisCanvasDirectory,
            minisCoreDirectory,
            settingsDirectory,
            sessionDirectory,
            memoryDirectory,
            taskDirectory,
            mcpDirectory,
            providerConfigurationDirectory,
            logDirectory,
            browserStateDirectory,
            terminalStateDirectory,
            attachmentsDirectory,
            temporaryDirectory,
            hermesSkillsDirectory,
            skillStateURL.deletingLastPathComponent()
        ]
    }

    enum KeychainComposition: Equatable, Sendable {
        case productionSecItem(service: String)
        case testNamespacedInMemory(namespace: String)
    }

    /// Pure value contract for profile-to-Keychain composition. Tests can
    /// assert the production choice without constructing or calling SecItem.
    var keychainComposition: KeychainComposition {
        switch mode {
        case .production:
            return .productionSecItem(service: keychainService)
        case .packagedField, .isolatedTest, .blocked:
            return .testNamespacedInMemory(namespace: keychainService)
        }
    }

    /// Match the descriptor reported by the actual composition factory.
    /// Production must keep its exact SecItem service. Disposable stores use
    /// an injected NamespacedKeychainBacking around InMemoryKeychainBacking.
    func matchesKeychainBacking(_ actual: KeychainStore.BackingKind) -> Bool {
        switch keychainComposition {
        case .productionSecItem(let service):
            return actual == .secItem(service: service)
        case .testNamespacedInMemory:
            return actual == .injected
        }
    }

    /// Launch profiles never infer a legacy credential source. In particular,
    /// a disposable packaged-field profile must not read the production
    /// service when its own namespace has no credential. Explicit migration
    /// callers retain the KeychainStore copy-only rebind contract.
    var keychainLegacyServices: [String] {
        []
    }

    /// Test-safe composition retained for existing SwiftPM callers. The
    /// production app uses `makeProductionKeychainStore()` explicitly, so no
    /// environment-derived `isTesting` branch decides profile wiring.
    func makeKeychainStore() -> KeychainStore {
        KeychainStore(
            backing: NamespacedKeychainBacking(
                namespace: keychainService,
                backing: InMemoryKeychainBacking()
            )
        )
    }

    func makeProductionKeychainStore(
        using makeStore: (String, [String]) -> KeychainStore = { service, legacyServices in
            KeychainStore(secItemService: service, legacyServices: legacyServices)
        }
    ) -> KeychainStore {
        guard case let .productionSecItem(service) = keychainComposition else {
            preconditionFailure("Production Keychain composition requires a production profile")
        }
        return makeStore(service, keychainLegacyServices)
    }

    func makeLogManager() -> LogManager {
        guard isDisposable else { return .shared }
        return LogManager(directory: logDirectory)
    }

    /// Environment privacy markings are preferences too. An isolated directory
    /// and Keychain alone must not leave this dependency on the shared
    /// production defaults when composing a field or blocked bootstrap.
    func makeEnvironmentStore(keychain: KeychainStore) -> EnvVarStore {
        EnvVarStore(
            directory: providerConfigurationDirectory,
            keychain: keychain,
            privacyStore: EnvVarPrivacyStore(defaults: makeUserDefaults())
        )
    }

    func makeUserDefaults() -> UserDefaults {
        guard isDisposable else { return .standard }
        guard let userDefaultsSuiteName,
              let defaults = UserDefaults(suiteName: userDefaultsSuiteName) else {
            preconditionFailure("Disposable profile preferences domain is unavailable")
        }
        return defaults
    }

    func cleanupDisposableRoots() throws {
        guard isDisposable else { return }
        try validateDisposableTree()
        if let userDefaultsSuiteName {
            UserDefaults.standard.removePersistentDomain(forName: userDefaultsSuiteName)
        }
        let disposableRoot = try Self.normalizedDisposableRoot(rootDirectory)
        if FileManager.default.fileExists(atPath: disposableRoot.path) {
            try FileManager.default.removeItem(at: disposableRoot)
        }
    }

    private init(
        mode: Mode,
        label: String,
        rootDirectory: URL,
        disposableRootIdentity: DisposableRootIdentity?,
        applicationSupportDirectory: URL,
        minisCanvasDirectory: URL,
        minisCoreDirectory: URL,
        settingsDirectory: URL,
        sessionDirectory: URL,
        memoryDirectory: URL,
        taskDirectory: URL,
        mcpDirectory: URL,
        providerConfigurationDirectory: URL,
        logDirectory: URL,
        browserStateDirectory: URL,
        terminalStateDirectory: URL,
        attachmentsDirectory: URL,
        temporaryDirectory: URL,
        hermesSkillsDirectory: URL,
        skillStateURL: URL,
        keychainService: String,
        userDefaultsSuiteName: String?,
        environment: [String: String],
        canvasRuntimeState: CanvasRuntimeState
    ) {
        self.mode = mode
        self.label = label
        self.rootDirectory = rootDirectory
        self.disposableRootIdentity = disposableRootIdentity
        self.applicationSupportDirectory = applicationSupportDirectory
        self.minisCanvasDirectory = minisCanvasDirectory
        self.minisCoreDirectory = minisCoreDirectory
        self.settingsDirectory = settingsDirectory
        self.sessionDirectory = sessionDirectory
        self.memoryDirectory = memoryDirectory
        self.taskDirectory = taskDirectory
        self.mcpDirectory = mcpDirectory
        self.providerConfigurationDirectory = providerConfigurationDirectory
        self.logDirectory = logDirectory
        self.browserStateDirectory = browserStateDirectory
        self.terminalStateDirectory = terminalStateDirectory
        self.attachmentsDirectory = attachmentsDirectory
        self.temporaryDirectory = temporaryDirectory
        self.hermesSkillsDirectory = hermesSkillsDirectory
        self.skillStateURL = skillStateURL
        self.keychainService = keychainService
        self.userDefaultsSuiteName = userDefaultsSuiteName
        self.environment = environment
        self.canvasRuntimeState = canvasRuntimeState
    }
}

private final class NamespacedKeychainBacking: KeychainBacking, @unchecked Sendable {
    private let namespace: String
    private let backing: KeychainBacking

    init(namespace: String, backing: KeychainBacking) {
        self.namespace = namespace
        self.backing = backing
    }

    @discardableResult
    func set(_ value: String, forKey key: String) -> Bool {
        backing.set(value, forKey: namespacedKey(key))
    }

    func get(_ key: String) -> String? {
        backing.get(namespacedKey(key))
    }

    @discardableResult
    func delete(_ key: String) -> Bool {
        backing.delete(namespacedKey(key))
    }

    private func namespacedKey(_ key: String) -> String {
        "\(namespace):\(key)"
    }
}
