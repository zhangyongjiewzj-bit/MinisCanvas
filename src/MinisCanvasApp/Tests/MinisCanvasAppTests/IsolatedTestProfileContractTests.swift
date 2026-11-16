import Foundation
import Testing
@testable import MinisCanvasApp

@Suite("isolated test profile contract")
struct IsolatedTestProfileContractTests {
    private let testProcessArguments = ["/tmp/MinisCanvasAppTests.xctest"]

    @Test("legal labels are accepted by the isolated profile")
    func legalProfileLabelsAreAccepted() throws {
        for label in ["contract", "A7-A_2.0"] {
            let profile = try TestEnvIsolation.makeIsolatedProfile(
                label: label,
                processEnvironment: [:],
                processArguments: testProcessArguments
            )
            defer { try? FileManager.default.removeItem(at: profile.rootDirectory) }

            #expect(FileManager.default.fileExists(atPath: profile.rootDirectory.path))
        }
    }

    @Test("profile supplies only disposable test metadata")
    func profileIsDisposableAndDoesNotCarryCredentials() throws {
        let profile = try TestEnvIsolation.makeIsolatedProfile(
            label: "contract",
            processEnvironment: [:],
            processArguments: testProcessArguments
        )
        defer { try? FileManager.default.removeItem(at: profile.rootDirectory) }

        let temporaryRoot = FileManager.default.temporaryDirectory.path
        #expect(profile.rootDirectory.path.hasPrefix(temporaryRoot + "/"))
        #expect(FileManager.default.fileExists(atPath: profile.rootDirectory.path))
        #expect(profile.environment[TestEnvIsolation.profileMarkerKey] == "1")
        #expect(
            profile.environment[TestEnvIsolation.profileDirectoryKey]
                == profile.rootDirectory.path
        )
        for key in TestEnvIsolation.apiKeyEnvVars {
            #expect(profile.environment[key] == nil)
        }
    }

    @Test("invalid labels fail closed")
    func invalidProfileLabelsFailClosed() {
        for label in ["", "../escape", "contains space", "contains/slash"] {
            do {
                _ = try TestEnvIsolation.makeIsolatedProfile(
                    label: label,
                    processEnvironment: [:],
                    processArguments: testProcessArguments
                )
                Issue.record("invalid profile label unexpectedly accepted: \(label)")
            } catch let error as TestEnvIsolation.IsolationError {
                #expect(error == .invalidProfileLabel)
            } catch {
                Issue.record("unexpected profile error for \(label): \(error)")
            }
        }
    }

    @Test("non-test processes cannot create a test profile")
    func nonTestProcessFailsClosed() {
        do {
            _ = try TestEnvIsolation.makeIsolatedProfile(
                label: "should-not-create",
                processEnvironment: [
                    TestEnvIsolation.profileMarkerKey: "1"
                ],
                processArguments: [
                    "/Applications/MinisCanvasApp.app/Contents/MacOS/MinisCanvasApp"
                ]
            )
            Issue.record("non-test process must not receive a test-only profile")
        } catch let error as TestEnvIsolation.IsolationError {
            #expect(error == .notRunningInTestProcess)
        } catch {
            Issue.record("unexpected profile error: \(error)")
        }
    }

    @Test("app composition accepts an immutable isolated profile")
    func appCompositionProfileCarriesTheRequiredBoundary() throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "composition",
            processEnvironment: [:],
            processArguments: testProcessArguments
        )
        defer { try? profile.cleanupDisposableRoots() }

        #expect(profile.isDisposable)
        #expect(profile.sessionDirectory.path.hasPrefix(profile.rootDirectory.path + "/"))
        #expect(profile.mcpConfigurationURL.path.hasPrefix(profile.rootDirectory.path + "/"))
        #expect(profile.keychainService.hasPrefix("com.miniscanvas.test."))
        #expect(profile.canvasRuntimeState == .enabled)
    }

    @Test("Chat composition fails closed for every unhealthy Canvas state")
    func chatCompositionStateMatrixIsDeterministic() {
        let unhealthyStates: [
            (RuntimeIsolationProfile.CanvasRuntimeState, String)
        ] = [
            (.disabled, "canvas-disabled"),
            (.absent, "canvas-absent"),
            (.corrupt, "canvas-corrupt")
        ]

        for (state, reason) in unhealthyStates {
            let contract = RuntimeIsolationProfile.ChatCompositionContract.make(
                canvasState: state
            )
            #expect(contract.chatStartupIndependent)
            #expect(contract.canvasCapabilities.isEmpty)
            #expect(contract.failClosedReason == reason)
        }

        let healthy = RuntimeIsolationProfile.ChatCompositionContract.make(
            canvasState: .enabled
        )
        #expect(healthy.chatStartupIndependent)
        #expect(healthy.canvasCapabilities == ["canvas_read", "canvas_mutation"])
        #expect(healthy.failClosedReason == nil)
    }

    @Test("Bridge composition never publishes Canvas capabilities when unhealthy")
    @MainActor
    func bridgeCompositionTracksSafetyAndCanvasState() {
        let bridge = BridgeStore(canvasRuntimeState: .corrupt)
        #expect(bridge.productionChatComposition.chatStartupIndependent)
        #expect(bridge.productionChatComposition.canvasCapabilities.isEmpty)

        bridge.updateSafetyRuntimeSnapshot(
            SafetyRuntimeSnapshot(safeModeEnabled: false, killSwitchEnabled: true)
        )
        #expect(bridge.canvasRuntimeState == .disabled)
        #expect(bridge.productionChatComposition.canvasCapabilities.isEmpty)
    }
}
