import Foundation
import Darwin
import Testing
@testable import MinisCore

@Suite("formal test isolation paths")
struct FormalTestIsolationPathsTests {
    private struct Fixture {
        let root: URL
        let environment: [String: String]
        let cleanupURL: URL

        func cleanup() { try? FileManager.default.removeItem(at: cleanupURL) }
    }

    private let testArguments = [
        "/tmp/MinisCorePackageTests.xctest/Contents/MacOS/MinisCorePackageTests"
    ]

    private func makeContract(packageName: String = "MinisCore") throws -> Fixture {
        // /var is a symlink on macOS, while Foundation may normalize an
        // existing /private/var URL back to /var. Keep the synthetic fixture
        // in SwiftPM's package-local scratch tree instead.
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        // A formal run already owns a validated canonical root. Keep fixtures
        // there so a checkout's /private/tmp alias cannot preempt the intended
        // negative assertion. Ordinary SwiftPM callers keep package scratch.
        let fixtureBase = try FormalTestIsolationPaths.resolveCurrentProcess()?.rootDirectory
            ?? packageRoot.appendingPathComponent(".build", isDirectory: true)
        let parent = fixtureBase
            .appendingPathComponent("formal-isolation-\(UUID().uuidString)", isDirectory: true)
        let scratch = parent.appendingPathComponent(packageName, isDirectory: true)
        let root = scratch.appendingPathComponent("formal-test-root", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: root.path
        )
        var metadata = stat()
        guard lstat(root.path, &metadata) == 0 else {
            throw FormalTestIsolationPaths.IsolationError.unsafeRoot
        }
        let environment = [
            FormalTestIsolationPaths.profileMarkerKey: "1",
            FormalTestIsolationPaths.profileDirectoryKey: root.path,
            FormalTestIsolationPaths.profileIdentityKey: "formal-test:run-1:\(packageName):nonce-1",
            FormalTestIsolationPaths.runIDKey: "run-1",
            FormalTestIsolationPaths.packageKey: packageName,
            FormalTestIsolationPaths.scratchDirectoryKey: scratch.path,
            FormalTestIsolationPaths.rootDeviceKey: String(UInt64(metadata.st_dev)),
            FormalTestIsolationPaths.rootInodeKey: String(UInt64(metadata.st_ino)),
            FormalTestIsolationPaths.rootOwnerKey: String(UInt32(metadata.st_uid))
        ]
        return Fixture(root: root, environment: environment, cleanupURL: parent)
    }

    private func nativeArguments(_ fixture: Fixture, library: String = "swift-testing") -> [String] {
        let executable = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("R13OriginalAppMain.app/Contents/MacOS/MinisCanvasOriginalAppMain")
        return [executable.path, "--testing-library", library]
    }

    @Test func exactStandaloneNativeRunnerRequiresAndUsesFormalRoot() throws {
        let fixture = try makeContract(packageName: "MinisCanvasApp")
        defer { fixture.cleanup() }
        var environment = fixture.environment
        environment["RUN_TESTS_INTERNAL_NATIVE"] = "1"
        let swift = try #require(try FormalTestIsolationPaths.resolve(
            environment: environment, arguments: nativeArguments(fixture),
            processName: "MinisCanvasOriginalAppMain"
        ))
        let xctest = try #require(try FormalTestIsolationPaths.resolve(
            environment: environment, arguments: nativeArguments(fixture, library: "xctest"),
            processName: "MinisCanvasOriginalAppMain"
        ))
        #expect(swift.rootDirectory == fixture.root)
        #expect(xctest == swift)
    }

    @Test func standaloneNativeRunnerRejectsMissingKeysAndMarkerOnly() throws {
        let fixture = try makeContract(packageName: "MinisCanvasApp")
        defer { fixture.cleanup() }
        let arguments = nativeArguments(fixture)
        var environment = fixture.environment
        environment["RUN_TESTS_INTERNAL_NATIVE"] = "1"
        for missing in [
            FormalTestIsolationPaths.profileMarkerKey,
            FormalTestIsolationPaths.profileDirectoryKey,
            FormalTestIsolationPaths.profileIdentityKey,
            FormalTestIsolationPaths.runIDKey,
            FormalTestIsolationPaths.packageKey,
            FormalTestIsolationPaths.scratchDirectoryKey,
            FormalTestIsolationPaths.rootDeviceKey,
            FormalTestIsolationPaths.rootInodeKey,
            FormalTestIsolationPaths.rootOwnerKey
        ] {
            var incomplete = environment
            incomplete.removeValue(forKey: missing)
            #expect(throws: FormalTestIsolationPaths.IsolationError.missingContract) {
                try FormalTestIsolationPaths.resolve(
                    environment: incomplete, arguments: arguments,
                    processName: "MinisCanvasOriginalAppMain"
                )
            }
        }
        #expect(throws: FormalTestIsolationPaths.IsolationError.missingContract) {
            try FormalTestIsolationPaths.resolve(
                environment: [FormalTestIsolationPaths.profileMarkerKey: "1",
                              "RUN_TESTS_INTERNAL_NATIVE": "1"],
                arguments: arguments, processName: "MinisCanvasOriginalAppMain"
            )
        }
        #expect(throws: FormalTestIsolationPaths.IsolationError.missingContract) {
            try FormalTestIsolationPaths.resolve(
                environment: [:], arguments: arguments,
                processName: "MinisCanvasOriginalAppMain"
            )
        }
        environment.removeValue(forKey: "RUN_TESTS_INTERNAL_NATIVE")
        #expect(throws: FormalTestIsolationPaths.IsolationError.missingContract) {
            try FormalTestIsolationPaths.resolve(
                environment: environment, arguments: arguments,
                processName: "MinisCanvasOriginalAppMain"
            )
        }
    }

    @Test func standaloneNativeRunnerRejectsFakePathAndWrongRootIdentity() throws {
        let fixture = try makeContract(packageName: "MinisCanvasApp")
        defer { fixture.cleanup() }
        var environment = fixture.environment
        environment["RUN_TESTS_INTERNAL_NATIVE"] = "1"
        let arguments = nativeArguments(fixture)
        #expect(throws: FormalTestIsolationPaths.IsolationError.unrecognizedTestProcess) {
            try FormalTestIsolationPaths.resolve(
                environment: environment,
                arguments: ["/Applications/R13OriginalAppMain.app/Contents/MacOS/MinisCanvasOriginalAppMain",
                            "--testing-library", "swift-testing"],
                processName: "MinisCanvasOriginalAppMain"
            )
        }
        #expect(throws: FormalTestIsolationPaths.IsolationError.unrecognizedTestProcess) {
            try FormalTestIsolationPaths.resolve(
                environment: environment,
                arguments: [arguments[0].replacingOccurrences(of: "R13OriginalAppMain.app", with: "Other.app"),
                            "--testing-library", "swift-testing"],
                processName: "MinisCanvasOriginalAppMain"
            )
        }
        for key in [FormalTestIsolationPaths.rootDeviceKey,
                    FormalTestIsolationPaths.rootInodeKey,
                    FormalTestIsolationPaths.rootOwnerKey] {
            var mismatched = environment
            mismatched[key] = "0"
            #expect(throws: FormalTestIsolationPaths.IsolationError.rootIdentityMismatch) {
                try FormalTestIsolationPaths.resolve(
                    environment: mismatched, arguments: arguments,
                    processName: "MinisCanvasOriginalAppMain"
                )
            }
        }
        environment[FormalTestIsolationPaths.scratchDirectoryKey] = "/tmp/MinisCanvasApp"
        #expect(throws: FormalTestIsolationPaths.IsolationError.invalidContract) {
            try FormalTestIsolationPaths.resolve(
                environment: environment, arguments: arguments,
                processName: "MinisCanvasOriginalAppMain"
            )
        }
    }

    @Test func validatedRootDerivesCoreDefaultDomains() throws {
        let fixture = try makeContract()
        defer { fixture.cleanup() }
        let resolvedPaths = try FormalTestIsolationPaths.resolve(
            environment: fixture.environment,
            arguments: testArguments,
            processName: "MinisCorePackageTests"
        )
        let paths = try #require(resolvedPaths)
        #expect(paths.rootDirectory == fixture.root)
        #expect(paths.settingsDirectory == fixture.root.appendingPathComponent("Application Support/MinisCore", isDirectory: true))
        #expect(paths.sessionDirectory == fixture.root.appendingPathComponent("Application Support/Chat", isDirectory: true))
        #expect(paths.memoryDirectory == paths.sessionDirectory)
        #expect(paths.mcpFileURL == paths.mcpDirectory.appendingPathComponent("mcps.json"))
        #expect(paths.skillsRoot == paths.minisCoreDirectory.appendingPathComponent("skills", isDirectory: true))
        #expect(paths.skillStateURL == paths.minisCoreDirectory.appendingPathComponent("skills-enabled.json"))
        #expect(paths.hermesSkillsDirectory == fixture.root.appendingPathComponent("hermes-skills", isDirectory: true))
        #expect(paths.userDefaultsSuiteName.hasPrefix("com.miniscanvas.formal-test.preferences."))
        #expect(paths.keychainService.hasPrefix("com.miniscanvas.test.formal."))
        #expect(paths.userDefaultsSuiteName == (try FormalTestIsolationPaths.resolve(
            environment: fixture.environment,
            arguments: testArguments,
            processName: "MinisCorePackageTests"
        ))?.userDefaultsSuiteName)
    }

    @Test func ordinaryNativeTestsWithoutProfileUseDefaultPaths() throws {
        #expect(try FormalTestIsolationPaths.resolve(
            environment: [:], arguments: testArguments,
            processName: "MinisCorePackageTests"
        ) == nil)
        #expect(try FormalTestIsolationPaths.resolve(
            environment: [:],
            arguments: ["/usr/libexec/swiftpm-testing-helper", "--test-bundle-path", testArguments[0]],
            processName: "swiftpm-testing-helper"
        ) == nil)
    }

    @Test func recognizedTestRefusesPartialAndForgedContracts() throws {
        let fixture = try makeContract()
        defer { fixture.cleanup() }
        for missing in [FormalTestIsolationPaths.profileMarkerKey,
                        FormalTestIsolationPaths.profileDirectoryKey,
                        FormalTestIsolationPaths.profileIdentityKey,
                        FormalTestIsolationPaths.runIDKey] {
            var environment = fixture.environment
            environment.removeValue(forKey: missing)
            #expect(throws: FormalTestIsolationPaths.IsolationError.missingContract) {
                try FormalTestIsolationPaths.resolve(
                    environment: environment, arguments: testArguments,
                    processName: "MinisCorePackageTests"
                )
            }
        }
        #expect(throws: FormalTestIsolationPaths.IsolationError.missingContract) {
            try FormalTestIsolationPaths.resolve(
                environment: [FormalTestIsolationPaths.runIDKey: "run-1"],
                arguments: testArguments, processName: "MinisCorePackageTests"
            )
        }
        #expect(throws: FormalTestIsolationPaths.IsolationError.invalidContract) {
            try FormalTestIsolationPaths.resolve(
                environment: ["MINISCANVAS_FIELD_PROFILE": "1"],
                arguments: testArguments, processName: "MinisCorePackageTests"
            )
        }
        var changedDevice = fixture.environment
        changedDevice[FormalTestIsolationPaths.rootDeviceKey] = "0"
        #expect(throws: FormalTestIsolationPaths.IsolationError.rootIdentityMismatch) {
            try FormalTestIsolationPaths.resolve(
                environment: changedDevice, arguments: testArguments,
                processName: "MinisCorePackageTests"
            )
        }
        var changedIdentity = fixture.environment
        changedIdentity[FormalTestIsolationPaths.profileIdentityKey] = "formal-test:other-run:MinisCore:nonce-1"
        #expect(throws: FormalTestIsolationPaths.IsolationError.invalidContract) {
            try FormalTestIsolationPaths.resolve(
                environment: changedIdentity, arguments: testArguments,
                processName: "MinisCorePackageTests"
            )
        }
        #expect(throws: FormalTestIsolationPaths.IsolationError.unrecognizedTestProcess) {
            try FormalTestIsolationPaths.resolve(
                environment: fixture.environment,
                arguments: ["/Applications/MinisCanvas.app/Contents/MacOS/MinisCanvas", "example.xctest"],
                processName: "MinisCanvas"
            )
        }
    }

    @Test func unsafeRootAndFieldCompatibility() throws {
        let fixture = try makeContract()
        defer { fixture.cleanup() }
        var escaped = fixture.environment
        escaped[FormalTestIsolationPaths.profileDirectoryKey] = "/Users/example/Library/Application Support/MinisCore"
        #expect(throws: FormalTestIsolationPaths.IsolationError.unsafeRoot) {
            try FormalTestIsolationPaths.resolve(
                environment: escaped, arguments: testArguments,
                processName: "MinisCorePackageTests"
            )
        }
        let fieldRoot = "/private/tmp/packaged-field-example"
        let field: [String: String] = [
            FormalTestIsolationPaths.profileMarkerKey: "1",
            FormalTestIsolationPaths.profileDirectoryKey: fieldRoot,
            FormalTestIsolationPaths.profileIdentityKey: "packagedField:label:\(fieldRoot)",
            "MINISCANVAS_FIELD_PROFILE": "1",
            "MINISCANVAS_FIELD_PROFILE_ROOT": fieldRoot
        ]
        let fieldOnly: [String: String] = [
            "MINISCANVAS_FIELD_PROFILE": "1",
            "MINISCANVAS_FIELD_PROFILE_ROOT": fieldRoot
        ]
        #expect(try FormalTestIsolationPaths.resolve(
            environment: fieldOnly,
            arguments: ["MinisCanvas", "--miniscanvas-field-profile"],
            processName: "MinisCanvas"
        ) == nil)
        #expect(try FormalTestIsolationPaths.resolve(
            environment: field,
            arguments: ["MinisCanvas", "--miniscanvas-field-profile"],
            processName: "MinisCanvas"
        ) == nil)
        var mixed = field
        mixed[FormalTestIsolationPaths.runIDKey] = "run-1"
        #expect(throws: FormalTestIsolationPaths.IsolationError.invalidContract) {
            try FormalTestIsolationPaths.resolve(
                environment: mixed,
                arguments: ["MinisCanvas", "--miniscanvas-field-profile"],
                processName: "MinisCanvas"
            )
        }
        #expect(throws: FormalTestIsolationPaths.IsolationError.invalidContract) {
            try FormalTestIsolationPaths.resolve(
                environment: field,
                arguments: testArguments + ["--miniscanvas-field-profile"],
                processName: "MinisCorePackageTests"
            )
        }
    }

    @Test func symlinkRootIsRejected() throws {
        let fixture = try makeContract()
        defer { fixture.cleanup() }
        let realRoot = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("other-root", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.root, to: realRoot)
        try FileManager.default.createSymbolicLink(at: fixture.root, withDestinationURL: realRoot)
        #expect(throws: FormalTestIsolationPaths.IsolationError.unsafeRoot) {
            try FormalTestIsolationPaths.resolve(
                environment: fixture.environment, arguments: testArguments,
                processName: "MinisCorePackageTests"
            )
        }
    }

    /// Only formal-runner processes can check the injected in-memory domains.
    @Test func liveDefaultConstructionUsesFormalRootWhenProvided() throws {
        let resolvedPaths = try FormalTestIsolationPaths.resolveCurrentProcess()
        guard let paths = resolvedPaths else { return }
        #expect(SettingsStore.defaultDirectory() == paths.settingsDirectory)
        #expect(EnvVarStore.defaultDirectory() == paths.minisCoreDirectory)
        #expect(SessionStore.defaultDirectory == paths.sessionDirectory)
        #expect(MCPServerManager.defaultFileURL() == paths.mcpFileURL)
        #expect(SkillStore.defaultSkillsRoot() == paths.skillsRoot)

        let keychain = KeychainStore()
        #expect(keychain.backingKind == .inMemory)
        let settings = SettingsStore(directory: SettingsStore.defaultDirectory())
        let env = EnvVarStore(directory: EnvVarStore.defaultDirectory(), keychain: keychain)
        let session = SessionStore(directory: SessionStore.defaultDirectory)
        let mcp = MCPServerManager(fileURL: MCPServerManager.defaultFileURL(), keychain: keychain)
        let skills = SkillStore()
        #expect(settings.directory == paths.settingsDirectory)
        #expect(mcp.fileURL == paths.mcpFileURL)
        #expect(skills.skillsRoot == paths.skillsRoot)
        _ = env
        _ = session
    }
}
