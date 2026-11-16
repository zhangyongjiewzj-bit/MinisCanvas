import Foundation
import SwiftUI
import Darwin
import MinisCore

/// Explicit packaged-field producer for the ordinary production approval sheet.
/// It runs the existing bound gate and UI delegate, then discards the result:
/// no tool executor, browser grant, settings mutation or durable task is invoked.
enum ThemeApprovalPackageFieldFixture {
    static let activationArgument = "--theme-approval-field-fixture"

    enum Outcome: String, Sendable {
        case approved, deniedOrCancelled, inactive, unsafeRoot
    }

    static func isRequested(
        mode: RuntimeIsolationProfile.Mode,
        arguments: [String],
        environment: [String: String],
        activationArgument: String = Self.activationArgument
    ) -> Bool {
        mode == .packagedField
            && arguments.filter { $0 == activationArgument }.count == 1
            && arguments.filter { $0 == RuntimeIsolationProfile.fieldActivationArgument }.count == 1
            && environment[RuntimeIsolationProfile.fieldActivationMarkerKey] == "1"
    }

    @MainActor
    static func runIfRequested(
        profile: RuntimeIsolationProfile,
        center: ApprovalPromptCenter,
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> Outcome {
        guard isRequested(mode: profile.mode, arguments: arguments, environment: environment)
        else { return .inactive }
        // Validate metadata only after explicit field admission. Never inspect
        // a normal profile's directory or read any stored configuration here.
        guard rootIsSafe(profile) else { return .unsafeRoot }
        return await requestApproval(center: center)
    }

    static func rootIsSafe(_ profile: RuntimeIsolationProfile) -> Bool {
        var metadata = stat()
        return lstat(profile.rootDirectory.path, &metadata) == 0
            && metadata.st_mode & S_IFMT == S_IFDIR
            && metadata.st_mode & 0o777 == 0o700
            && metadata.st_uid == geteuid()
    }

    /// Keep non-Sendable JSON and the gate on one worker, just as the existing
    /// production approval consumer tests do. Only the main-actor delegate
    /// crosses into the exact BridgeStore-owned presentation center.
    nonisolated static func requestApproval(center: ApprovalPromptCenter) async -> Outcome {
        let input: [String: Any] = [
            "command": "printf 'TASK2287 synthetic preview only'",
            "fixture": "THEME04: approval display only; no command will execute"
        ]
        guard let digest = ApprovalAuthorizationContext.payloadDigest(for: input)
        else { return .deniedOrCancelled }
        let nonce = UUID().uuidString
        let context = ApprovalAuthorizationContext(
            actorID: "field-fixture-2287", sessionID: "synthetic-theme-2287",
            turnID: 1, taskID: "synthetic-approval-2287", runID: nonce,
            attemptID: nonce, effectID: "theme-2287-" + nonce,
            scope: "fixture-display-only", payloadDigest: digest,
            expiresAt: Date().addingTimeInterval(300),
            policyRevision: "fixture-2287-no-executor", grantEpoch: nonce,
            toolName: "shell_execute"
        )
        let gate = ApprovalGate(delegate: ApprovalPromptDelegate(center: center))
        do {
            let decision = try await gate.gate(tool: "shell_execute", input: input, context: context)
            return decision.approved ? .approved : .deniedOrCancelled
        } catch { return .deniedOrCancelled }
    }
}

/// The fixed field URL replaces only the initial user-browser page. It is not
/// an allowlist/grant: the ordinary address/navigation consumer still decides.
enum BrowserLocalPackageFieldFixture {
    static let activationArgument = "--browser-local-field-fixture"
    static let localURL = URL(string: "http://127.0.0.1:22871/index.html")!

    static func initialURL(
        profile: RuntimeIsolationProfile,
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard ThemeApprovalPackageFieldFixture.isRequested(
            mode: profile.mode, arguments: arguments, environment: environment,
            activationArgument: activationArgument
        ), ThemeApprovalPackageFieldFixture.rootIsSafe(profile) else { return nil }
        return localURL
    }
}

private struct BrowserFieldInitialURLKey: EnvironmentKey {
    static let defaultValue: URL? = nil
}

extension EnvironmentValues {
    var browserFieldInitialURL: URL? {
        get { self[BrowserFieldInitialURLKey.self] }
        set { self[BrowserFieldInitialURLKey.self] = newValue }
    }
}
