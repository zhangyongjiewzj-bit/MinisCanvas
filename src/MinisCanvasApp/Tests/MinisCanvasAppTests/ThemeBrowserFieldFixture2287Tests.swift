import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("2287 controlled field fixture", .serialized)
@MainActor
struct ThemeBrowserFieldFixture2287Tests {
    @Test func optInCannotActivateNormalOrIncompleteLaunch() {
        let a = ThemeApprovalPackageFieldFixture.activationArgument
        let f = RuntimeIsolationProfile.fieldActivationArgument
        let e = [RuntimeIsolationProfile.fieldActivationMarkerKey: "1"]
        #expect(ThemeApprovalPackageFieldFixture.isRequested(mode: .packagedField, arguments: [f, a], environment: e))
        for mode in [RuntimeIsolationProfile.Mode.production, .isolatedTest, .blocked] {
            #expect(!ThemeApprovalPackageFieldFixture.isRequested(mode: mode, arguments: [f, a], environment: e))
        }
        for args in [[], [f], [a], [f, a, a], [f, f, a]] {
            #expect(!ThemeApprovalPackageFieldFixture.isRequested(mode: .packagedField, arguments: args, environment: e))
        }
        #expect(!ThemeApprovalPackageFieldFixture.isRequested(mode: .packagedField, arguments: [f, a], environment: [:]))
    }

    @Test func browserInitialPageRequiresSafeFieldRootAndExplicitOptIn() throws {
        let resolvedPaths = try FormalTestIsolationPaths.resolveCurrentProcess()
        _ = try #require(resolvedPaths)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("field2287-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let arguments = [RuntimeIsolationProfile.fieldActivationArgument,
                         BrowserLocalPackageFieldFixture.activationArgument]
        let environment = [RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                           RuntimeIsolationProfile.fieldActivationRootKey: root.path]
        let profile = try RuntimeIsolationProfile.makePackagedField(
            label: "fixture2287", processEnvironment: environment, processArguments: arguments
        )
        #expect(BrowserLocalPackageFieldFixture.initialURL(
            profile: profile, arguments: arguments, environment: environment
        ) == BrowserLocalPackageFieldFixture.localURL)
        #expect(BrowserLocalPackageFieldFixture.initialURL(
            profile: profile, arguments: [], environment: environment
        ) == nil)
        #expect(BrowserLocalPackageFieldFixture.initialURL(
            profile: profile, arguments: arguments, environment: [:]
        ) == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        #expect(BrowserLocalPackageFieldFixture.initialURL(
            profile: profile, arguments: arguments, environment: environment
        ) == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }

    @Test(arguments: [true, false])
    func originalWaiterAndSecondConfirmationAreActuallyConsumed(allow: Bool) async throws {
        let center = ApprovalPromptCenter()
        let task = Task { await ThemeApprovalPackageFieldFixture.requestApproval(center: center) }
        defer { task.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while center.pendingRequest == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let request = try #require(center.pendingRequest)
        #expect(request.toolName == "shell_execute")
        #expect(request.binding != nil)
        #expect(request.requiresSecondConfirmation)
        #expect(request.inputSummary.contains("no command will execute"))
        let actions = center.actionsForPresentedRequest()
        if allow {
            try #require(!center.awaitingConfirmation)
            try await waitForApprovalInterval(deadline: deadline)
            try #require(center.pendingRequest?.id == request.id)
            try #require(center.pendingRequest?.identityDigest == request.identityDigest)
            try #require(!center.awaitingConfirmation)
            center.actionsForPresentedRequest().approve()
            #expect(center.awaitingConfirmation)
            #expect(center.pendingRequest?.identityDigest == request.identityDigest)
            try #require(center.awaitingConfirmation)
            try #require(center.pendingRequest?.id == request.id)
            try await waitForApprovalInterval(deadline: deadline)
            try #require(center.pendingRequest?.id == request.id)
            try #require(center.pendingRequest?.identityDigest == request.identityDigest)
            try #require(center.awaitingConfirmation)
            center.actionsForPresentedRequest().approve()
            try #require(center.pendingRequest == nil)
        } else { actions.deny() }
        let outcome = await task.value
        #expect(outcome == (allow ? .approved : .deniedOrCancelled))
        #expect(center.pendingRequest == nil)
        #expect(!center.awaitingConfirmation)
        // Retained actions cannot create a replacement or replay a result.
        actions.approve()
        #expect(center.pendingRequest == nil)
    }

    // Each production approval stage uses Date and resets its 0.5-second
    // accidental-input gate. Start after observing that stage, then recheck
    // request identity and state before taking a fresh action.
    private func waitForApprovalInterval(deadline: ContinuousClock.Instant) async throws {
        let observedAt = Date()
        while Date().timeIntervalSince(observedAt) < 0.5, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(ContinuousClock.now < deadline)
        try #require(Date().timeIntervalSince(observedAt) >= 0.5)
    }

    @Test func localPageStillUsesOriginalNavigationAndSideEffectPolicy() throws {
        let local = try #require(URL(string: "http://127.0.0.1:22871/index.html"))
        var state = BrowserNavigationState()
        guard case .navigate(_, let target) = state.start(rawInput: local.absoluteString) else {
            Issue.record("existing production address validator must admit HTTP loopback")
            return
        }
        #expect(target == local)
        var policy = BrowserNavigationPolicy()
        #expect(policy.decision(for: local, source: .initial) == .deny(.domainNotAuthorized))
        let authorizedLocal = policy.authorize(local)
        #expect(authorizedLocal)
        #expect(policy.decision(for: local, source: .initial) == .allow)
        let authorizedFile = policy.authorize(URL(fileURLWithPath: "/synthetic-2287/index.html"))
        #expect(!authorizedFile)
        #expect(policy.decision(for: URL(fileURLWithPath: "/synthetic-2287/index.html"), source: .initial) == .deny(.unsupportedScheme))
        #expect(policy.decision(for: URL(string: "http://localhost:22871/index.html"), source: .action, currentURL: local) == .deny(.crossOriginNotAuthorized))
        for action in ["click", "type", "download", "upload"] {
            #expect(BrowserSideEffectPolicy.requiresApproval(action: action))
        }
    }
}
