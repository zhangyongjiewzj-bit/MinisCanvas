import Foundation
import CryptoKit
import Darwin

/// The runner's pre-created, process-local filesystem and preferences domain.
/// A test marker is configuration, not evidence that a process is a test.
public struct FormalTestIsolationPaths: Equatable, Sendable {
    public enum IsolationError: Error, Equatable, Sendable {
        case unrecognizedTestProcess
        case missingContract
        case invalidContract
        case unsafeRoot
        case rootIdentityMismatch
    }

    public static let profileMarkerKey = "MINISCANVAS_TEST_PROFILE"
    public static let profileDirectoryKey = "MINISCANVAS_TEST_DIRECTORY"
    public static let profileIdentityKey = "MINISCANVAS_PROFILE_IDENTITY"
    public static let runIDKey = "MINISCANVAS_TEST_RUN_ID"
    public static let packageKey = "MINISCANVAS_TEST_PACKAGE"
    public static let scratchDirectoryKey = "MINISCANVAS_TEST_SCRATCH_DIRECTORY"
    public static let rootDeviceKey = "MINISCANVAS_TEST_ROOT_DEVICE"
    public static let rootInodeKey = "MINISCANVAS_TEST_ROOT_INODE"
    public static let rootOwnerKey = "MINISCANVAS_TEST_ROOT_OWNER"

    private static let formalOnlyKeys = [
        runIDKey, packageKey, scratchDirectoryKey,
        rootDeviceKey, rootInodeKey, rootOwnerKey
    ]

    public let rootDirectory: URL
    public let runIdentity: String
    public let packageName: String
    public let rootDevice: UInt64
    public let rootInode: UInt64
    public let rootOwner: UInt32

    public var applicationSupportDirectory: URL { rootDirectory.appendingPathComponent("Application Support", isDirectory: true) }
    public var minisCanvasDirectory: URL { rootDirectory.appendingPathComponent("Canvas", isDirectory: true) }
    public var minisCoreDirectory: URL { applicationSupportDirectory.appendingPathComponent("MinisCore", isDirectory: true) }
    public var settingsDirectory: URL { minisCoreDirectory }
    public var sessionDirectory: URL { applicationSupportDirectory.appendingPathComponent("Chat", isDirectory: true) }
    public var memoryDirectory: URL { sessionDirectory }
    public var taskDirectory: URL { sessionDirectory }
    public var mcpDirectory: URL { minisCoreDirectory.appendingPathComponent("mcp", isDirectory: true) }
    public var mcpFileURL: URL { mcpDirectory.appendingPathComponent("mcps.json") }
    public var providerConfigurationDirectory: URL { minisCoreDirectory.appendingPathComponent("providers", isDirectory: true) }
    public var logDirectory: URL { minisCanvasDirectory.appendingPathComponent("logs", isDirectory: true) }
    public var browserStateDirectory: URL { sessionDirectory.appendingPathComponent("browser", isDirectory: true) }
    public var terminalStateDirectory: URL { sessionDirectory.appendingPathComponent("terminal", isDirectory: true) }
    public var attachmentsDirectory: URL { sessionDirectory.appendingPathComponent("ChatAttachments", isDirectory: true) }
    public var temporaryDirectory: URL { rootDirectory.appendingPathComponent("temporary", isDirectory: true) }
    public var hermesSkillsDirectory: URL { rootDirectory.appendingPathComponent("hermes-skills", isDirectory: true) }
    public var skillStateURL: URL { minisCoreDirectory.appendingPathComponent("skills-enabled.json") }
    public var skillsRoot: URL { minisCoreDirectory.appendingPathComponent("skills", isDirectory: true) }
    public var userDefaultsSuiteName: String { "com.miniscanvas.formal-test.preferences.\(namespaceSuffix)" }
    public var keychainService: String { "com.miniscanvas.test.formal.\(namespaceSuffix)" }

    private var namespaceSuffix: String {
        let input = "\(runIdentity):\(rootDirectory.path):\(rootDevice):\(rootInode)"
        return SHA256.hash(data: Data(input.utf8)).prefix(16)
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Live defaults share one result. A malformed formal-test process cannot
    /// later retry into the production path after its first failed resolution.
    private static let liveResolution: Result<FormalTestIsolationPaths?, IsolationError> = {
        do {
            return .success(try resolve(
                environment: ProcessInfo.processInfo.environment,
                arguments: ProcessInfo.processInfo.arguments,
                processName: ProcessInfo.processInfo.processName
            ))
        } catch let error as IsolationError {
            return .failure(error)
        } catch {
            return .failure(.invalidContract)
        }
    }()

    public static func resolveCurrentProcess() throws -> FormalTestIsolationPaths? {
        let paths = try liveResolution.get()
        if let paths {
            try checkRoot(
                paths.rootDirectory,
                scratch: paths.rootDirectory.deletingLastPathComponent(),
                device: paths.rootDevice,
                inode: paths.rootInode,
                owner: paths.rootOwner
            )
        }
        return paths
    }

    /// Called by Core's nonthrowing default path factories before any
    /// Foundation Application Support or Library lookup.
    static func currentOrFail() -> FormalTestIsolationPaths? {
        do { return try resolveCurrentProcess() }
        catch { preconditionFailure("Invalid formal-test isolation contract") }
    }

    /// Explicit input seam for source tests. Default consumers always use the
    /// live process snapshot above and cannot inject a claim of test identity.
    public static func resolve(
        environment: [String: String],
        arguments: [String],
        processName: String
    ) throws -> FormalTestIsolationPaths? {
        let isStandaloneNative = isStandaloneNativeTestExecutable(
            arguments: arguments, processName: processName
        )
        let isTest = isStandaloneNative
            || isNativeTestExecutable(arguments: arguments, processName: processName)
        let hasFormalKey = [profileMarkerKey, profileDirectoryKey, profileIdentityKey]
            .contains { environment[$0] != nil }
            || formalOnlyKeys.contains { environment[$0] != nil }
        let fieldArgument = arguments.filter { $0 == "--miniscanvas-field-profile" }.count
        let fieldWitness = arguments.filter { $0 == "--miniscanvas-field-root-witness" }.count
        let hasFieldKey = environment["MINISCANVAS_FIELD_PROFILE"] != nil
            || environment["MINISCANVAS_FIELD_PROFILE_ROOT"] != nil
        let hasFieldSignal = fieldArgument > 0 || fieldWitness > 0 || hasFieldKey

        if !isTest {
            if hasFieldSignal {
                // Preserve the existing 030 packaged-field profile only when
                // all of its original activation fields are present. The App
                // still performs its own field validation and injects stores.
                guard fieldArgument == 1, fieldWitness <= 1,
                      environment["MINISCANVAS_FIELD_PROFILE"] == "1",
                      let fieldRoot = environment["MINISCANVAS_FIELD_PROFILE_ROOT"],
                      !fieldRoot.isEmpty,
                      !formalOnlyKeys.contains(where: { environment[$0] != nil }) else {
                    throw IsolationError.invalidContract
                }
                let legacyKeys = [profileMarkerKey, profileDirectoryKey, profileIdentityKey]
                if legacyKeys.contains(where: { environment[$0] != nil }) {
                    guard environment[profileMarkerKey] == "1",
                          environment[profileDirectoryKey] == fieldRoot,
                          environment[profileIdentityKey]?.hasPrefix("packagedField:") == true else {
                        throw IsolationError.invalidContract
                    }
                }
                return nil
            }
            if hasFormalKey { throw IsolationError.unrecognizedTestProcess }
            return nil
        }

        // Ordinary swift test runs have no formal contract. Once a test opts
        // into a formal or field profile, keep rejecting incomplete claims.
        if hasFieldSignal { throw IsolationError.invalidContract }
        if isStandaloneNative, environment["RUN_TESTS_INTERNAL_NATIVE"] != "1" {
            throw IsolationError.missingContract
        }
        // The standalone App runner always requires a complete formal profile.
        // SwiftPM's existing no-profile default is limited to its own runners.
        if isStandaloneNative, !hasFormalKey { throw IsolationError.missingContract }
        guard hasFormalKey else { return nil }
        guard environment[profileMarkerKey] == "1",
              let rootPath = environment[profileDirectoryKey],
              let scratchPath = environment[scratchDirectoryKey],
              let runID = environment[runIDKey],
              let package = environment[packageKey],
              let identity = environment[profileIdentityKey],
              let deviceText = environment[rootDeviceKey],
              let inodeText = environment[rootInodeKey],
              let ownerText = environment[rootOwnerKey] else {
            throw IsolationError.missingContract
        }
        guard validIdentifier(runID), validIdentifier(package),
              !package.contains(".."),
              let device = strictUnsigned(deviceText),
              let inode = strictUnsigned(inodeText),
              let owner64 = strictUnsigned(ownerText),
              let owner = UInt32(exactly: owner64),
              identity.split(separator: ":", omittingEmptySubsequences: false).count == 4 else {
            throw IsolationError.invalidContract
        }
        let parts = identity.split(separator: ":", omittingEmptySubsequences: false)
        guard parts[0] == "formal-test", parts[1] == Substring(runID),
              parts[2] == Substring(package), validIdentifier(String(parts[3])) else {
            throw IsolationError.invalidContract
        }
        let root = try canonicalURL(rootPath)
        let scratch = try canonicalURL(scratchPath)
        if isStandaloneNative {
            let expectedExecutable = scratch
                .appendingPathComponent("R13OriginalAppMain.app/Contents/MacOS/MinisCanvasOriginalAppMain")
            guard package == "MinisCanvasApp",
                  scratch.lastPathComponent == "MinisCanvasApp",
                  arguments.first == expectedExecutable.path else {
                throw IsolationError.invalidContract
            }
        }
        guard scratch.lastPathComponent == package,
              root.lastPathComponent == "formal-test-root",
              root.deletingLastPathComponent() == scratch else {
            throw IsolationError.unsafeRoot
        }
        try checkRoot(root, scratch: scratch, device: device, inode: inode, owner: owner)
        return FormalTestIsolationPaths(
            rootDirectory: root,
            runIdentity: identity,
            packageName: package,
            rootDevice: device,
            rootInode: inode,
            rootOwner: owner
        )
    }

    private static func isNativeTestExecutable(arguments: [String], processName: String) -> Bool {
        let executable = arguments.first ?? ""
        let basename = URL(fileURLWithPath: executable).lastPathComponent.lowercased()
        let name = processName.lowercased()
        if name == "swiftpm-testing-helper" || basename == "swiftpm-testing-helper" { return true }
        if executable.lowercased().contains(".xctest/contents/macos/") { return true }
        if executable.lowercased().hasSuffix(".xctest") && name.hasSuffix("tests") { return true }
        return (name == "xctest" || basename == "xctest")
            && arguments.dropFirst().contains {
                $0.contains(".xctest") || $0.hasPrefix("-XCTest")
            }
    }

    private static func isStandaloneNativeTestExecutable(
        arguments: [String], processName: String
    ) -> Bool {
        guard arguments.count >= 3,
              processName == "MinisCanvasOriginalAppMain",
              arguments[1] == "--testing-library",
              ["swift-testing", "xctest"].contains(arguments[2]),
              arguments.dropFirst(3).filter({ $0 == "--testing-library" }).isEmpty else {
            return false
        }
        let executable = arguments[0]
        guard executable.hasPrefix("/"), !executable.hasPrefix("//"),
              URL(fileURLWithPath: executable).standardizedFileURL.path == executable else {
            return false
        }
        let url = URL(fileURLWithPath: executable)
        let scratch = url.deletingLastPathComponent() // MacOS
            .deletingLastPathComponent() // Contents
            .deletingLastPathComponent() // R13OriginalAppMain.app
            .deletingLastPathComponent() // formal scratch
        return scratch.lastPathComponent == "MinisCanvasApp"
            && url == scratch.appendingPathComponent(
                "R13OriginalAppMain.app/Contents/MacOS/MinisCanvasOriginalAppMain"
            )
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy {
            ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122)
                || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    private static func strictUnsigned(_ value: String) -> UInt64? {
        guard !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let parsed = UInt64(value), String(parsed) == value else { return nil }
        return parsed
    }

    private static func canonicalURL(_ path: String) throws -> URL {
        let lowered = path.lowercased()
        guard path.hasPrefix("/"), !path.hasPrefix("//"),
              !lowered.split(separator: "/").contains(where: { $0 == "secure" }),
              !lowered.contains("/library/application support/miniscore") else {
            throw IsolationError.unsafeRoot
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard url.standardizedFileURL.path == path else { throw IsolationError.unsafeRoot }
        return url
    }

    private static func checkRoot(
        _ root: URL, scratch: URL, device: UInt64, inode: UInt64, owner: UInt32
    ) throws {
        guard owner == geteuid() else { throw IsolationError.rootIdentityMismatch }
        try checkNoSymlinkComponents(root.path)
        var scratchStat = stat()
        var rootStat = stat()
        guard lstat(scratch.path, &scratchStat) == 0,
              lstat(root.path, &rootStat) == 0,
              (scratchStat.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              (rootStat.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              scratchStat.st_uid == owner,
              rootStat.st_uid == owner,
              (rootStat.st_mode & mode_t(0o777)) == mode_t(0o700),
              rootStat.st_dev == scratchStat.st_dev else {
            throw IsolationError.unsafeRoot
        }
        guard UInt64(rootStat.st_dev) == device,
              UInt64(rootStat.st_ino) == inode else {
            throw IsolationError.rootIdentityMismatch
        }
    }

    private static func checkNoSymlinkComponents(_ path: String) throws {
        var prefix = ""
        for component in path.split(separator: "/") {
            prefix += "/" + component
            var entry = stat()
            guard lstat(prefix, &entry) == 0,
                  (entry.st_mode & mode_t(S_IFMT)) != mode_t(S_IFLNK) else {
                throw IsolationError.unsafeRoot
            }
        }
    }
}
