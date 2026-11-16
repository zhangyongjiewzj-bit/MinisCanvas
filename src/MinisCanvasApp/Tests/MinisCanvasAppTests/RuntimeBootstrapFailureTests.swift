import Foundation
import Testing
@testable import MinisCanvasApp

@Suite("runtime bootstrap failure")
struct RuntimeBootstrapFailureTests {
    private let executableArguments = ["/Applications/MinisCanvas.app/Contents/MacOS/MinisCanvas"]

    @Test("missing field environment returns a typed blocker")
    func missingFieldEnvironmentIsTyped() {
        let result = RuntimeIsolationProfile.launchProfileResolution(
            processEnvironment: [
                RuntimeIsolationProfile.fieldActivationMarkerKey: "1"
            ],
            processArguments: executableArguments + [
                RuntimeIsolationProfile.fieldActivationArgument
            ]
        )

        guard case .blocked(.profileResolution(.missingFieldActivationEnvironment)) = result else {
            #expect(Bool(false), "missing field environment must be observable as a typed failure")
            return
        }
    }

    @Test("invalid field arguments fail closed without a process trap")
    func invalidFieldArgumentsAreTyped() {
        let result = RuntimeIsolationProfile.launchProfileResolution(
            processEnvironment: [
                RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                RuntimeIsolationProfile.fieldActivationRootKey: "/private/tmp/miniscanvas-bootstrap-test"
            ],
            processArguments: executableArguments + [
                RuntimeIsolationProfile.fieldActivationArgument,
                RuntimeIsolationProfile.fieldActivationArgument
            ]
        )

        guard case .blocked(.profileResolution(.missingFieldActivationArgument)) = result else {
            #expect(Bool(false), "duplicate field arguments must be observable as a typed failure")
            return
        }
    }

    @Test("valid field configuration resolves to a disposable profile")
    func validFieldConfigurationResolvesSafely() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCanvasBootstrap-valid-\(UUID().uuidString)", isDirectory: true)
        let result = RuntimeIsolationProfile.launchProfileResolution(
            processEnvironment: [
                RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                RuntimeIsolationProfile.fieldActivationRootKey: root.path
            ],
            processArguments: executableArguments + [
                RuntimeIsolationProfile.fieldActivationArgument
            ]
        )

        guard case .ready(let profile) = result else {
            #expect(Bool(false), "valid field configuration must resolve")
            return
        }
        defer { try? profile.cleanupDisposableRoots() }
        #expect(profile.mode == .packagedField)
        #expect(profile.isDisposable)
        #expect(profile.canvasRuntimeState == .enabled)
        let mappedTemporaryRoot: String? = if case .resolved(let path) =
            DarwinSystemPathResolver.resolveOutcome(FileManager.default.temporaryDirectory) {
            path
        } else { nil }
        #expect(profile.rootDirectory.path.hasPrefix(try #require(mappedTemporaryRoot) + "/"))
        guard case let .testNamespacedInMemory(namespace) = profile.keychainComposition else {
            #expect(Bool(false), "packaged field must use its actual namespaced in-memory composition")
            return
        }
        #expect(namespace == profile.keychainService)
        #expect(profile.makeKeychainStore().backingKind == .injected)
    }

    @Test("blocked profile remains disposable and uses test-safe composition")
    func blockedProfileCannotDowngradeToProduction() throws {
        let profile = RuntimeIsolationProfile.blockedProfile()
        defer { try? profile.cleanupDisposableRoots() }

        #expect(profile.mode == .blocked)
        #expect(profile.isDisposable)
        #expect(profile.canvasRuntimeState == .disabled)
        #expect(profile.keychainComposition == .testNamespacedInMemory(namespace: profile.keychainService))
        #expect(profile.rootDirectory != RuntimeIsolationProfile.production.rootDirectory)
    }

    @Test("typed bootstrap failure replaces a caller supplied production profile")
    func bootstrapFailureNormalizesProfileBeforeComposition() throws {
        let profile = MinisCanvasAppMain.failClosedProfile(
            requestedProfile: .production,
            bootstrapFailure: .unexpectedProfileResolution
        )
        defer { try? profile.cleanupDisposableRoots() }

        #expect(profile.mode == .blocked)
        #expect(profile.isDisposable)
        #expect(profile.rootDirectory != RuntimeIsolationProfile.production.rootDirectory)
        #expect(profile.keychainComposition
            == .testNamespacedInMemory(namespace: profile.keychainService))
    }

    @Test("bootstrap failure gates durable stores and leaves only a terminal blocker")
    func bootstrapFailureCannotContinueThroughProductionAssembly() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: sourceRoot
                .appendingPathComponent("Sources/MinisCanvasApp/MinisCanvasApp.swift"),
            encoding: .utf8
        )
        let gate = try #require(source.range(of: "var profile = Self.failClosedProfile("))
        let defaults = try #require(source.range(of: "let defaults = profile.makeUserDefaults()"))
        let sessionStore = try #require(source.range(of: "let sessionStore = SessionStore(directory: profile.sessionDirectory)"))
        #expect(gate.lowerBound < defaults.lowerBound)
        #expect(gate.lowerBound < sessionStore.lowerBound)
        #expect(source.contains("bootstrapFailure == nil && profile.mode == .production"))

        let blocker = try #require(source.range(of: "RuntimeBootstrapFailureView(failure: bootstrapFailure)"))
        let content = try #require(source.range(of: "ContentView(bridge: bridge"))
        #expect(blocker.lowerBound < content.lowerBound)
        #expect(source.contains("Button(\"退出应用\")"))
        #expect(source.contains("NSApplication.shared.terminate(nil)"))
    }
}
