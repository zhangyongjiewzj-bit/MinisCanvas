import Foundation
import XCTest
import Testing
import MinisCore
@testable import MinisCanvasApp

/// Focused, side-effect-free probe for the two native Swift test hosts.
/// Diagnostics contain key names and booleans only, never environment values.
private enum FormalHostContractProbe {
    struct Finding {
        let valid: Bool
        let diagnostic: String
    }

    static func inspect() -> Finding {
        let process = ProcessInfo.processInfo
        let environment = process.environment
        let keys = [
            FormalTestIsolationPaths.profileMarkerKey,
            FormalTestIsolationPaths.profileDirectoryKey,
            FormalTestIsolationPaths.profileIdentityKey,
            FormalTestIsolationPaths.runIDKey,
            FormalTestIsolationPaths.packageKey,
            FormalTestIsolationPaths.scratchDirectoryKey,
            FormalTestIsolationPaths.rootDeviceKey,
            FormalTestIsolationPaths.rootInodeKey,
            FormalTestIsolationPaths.rootOwnerKey,
        ]
        let missing = keys.filter { environment[$0] == nil }
        let fieldSignal = environment["MINISCANVAS_FIELD_PROFILE"] != nil
            || environment["MINISCANVAS_FIELD_PROFILE_ROOT"] != nil
            || process.arguments.contains("--miniscanvas-field-profile")
            || process.arguments.contains("--miniscanvas-field-root-witness")
        let markerValid = environment[FormalTestIsolationPaths.profileMarkerKey] == "1"
        let runID = environment[FormalTestIsolationPaths.runIDKey] ?? ""
        let package = environment[FormalTestIsolationPaths.packageKey] ?? ""
        let identityParts = (environment[FormalTestIsolationPaths.profileIdentityKey] ?? "")
            .split(separator: ":", omittingEmptySubsequences: false)
        let identityShapeValid = identityParts.count == 4
            && identityParts.first == "formal-test"
            && identityParts.dropFirst().first == Substring(runID)
            && identityParts.dropFirst(2).first == Substring(package)
        let numericShapeValid = [
            FormalTestIsolationPaths.rootDeviceKey,
            FormalTestIsolationPaths.rootInodeKey,
            FormalTestIsolationPaths.rootOwnerKey,
        ].allSatisfy { key in
            guard let value = environment[key], !value.isEmpty else { return false }
            return value.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
        }
        let root = URL(fileURLWithPath: environment[FormalTestIsolationPaths.profileDirectoryKey] ?? "")
        let scratch = URL(fileURLWithPath: environment[FormalTestIsolationPaths.scratchDirectoryKey] ?? "")
        let directoryShapeValid = root.lastPathComponent == "formal-test-root"
            && scratch.lastPathComponent == package
            && root.deletingLastPathComponent() == scratch

        let explicit: String
        do {
            explicit = try FormalTestIsolationPaths.resolve(
                environment: environment,
                arguments: process.arguments,
                processName: process.processName
            ) == nil ? "no-formal-profile" : "valid"
        } catch let error as FormalTestIsolationPaths.IsolationError {
            explicit = String(describing: error)
        } catch {
            explicit = "unexpected-error"
        }

        let cached: String
        do {
            cached = try FormalTestIsolationPaths.resolveCurrentProcess() == nil
                ? "no-formal-profile" : "valid"
        } catch let error as FormalTestIsolationPaths.IsolationError {
            cached = String(describing: error)
        } catch {
            cached = "unexpected-error"
        }

        let app: String
        do {
            app = try RuntimeIsolationProfile.resolveLaunchProfile().mode == .isolatedTest
                ? "isolated-test" : "other-profile"
        } catch let error as RuntimeIsolationProfile.IsolationError {
            app = String(describing: error)
        } catch let error as FormalTestIsolationPaths.IsolationError {
            app = String(describing: error)
        } catch {
            app = "unexpected-error"
        }

        let host: String
        let executable = URL(fileURLWithPath: process.arguments.first ?? "")
            .lastPathComponent.lowercased()
        if process.processName.lowercased() == "swiftpm-testing-helper"
            || executable == "swiftpm-testing-helper" {
            host = "swift-testing-helper"
        } else if executable == "xctest" || process.processName.lowercased() == "xctest" {
            host = "xctest"
        } else if (process.arguments.first ?? "").lowercased().contains(".xctest/contents/macos/") {
            host = "test-bundle-executable"
        } else {
            host = "unrecognized"
        }

        return Finding(
            valid: missing.isEmpty && !fieldSignal && explicit == "valid"
                && cached == "valid" && app == "isolated-test",
            diagnostic: "host=\(host) missingKeys=\(missing) fieldSignal=\(fieldSignal) "
                + "markerValid=\(markerValid) identityShapeValid=\(identityShapeValid) "
                + "numericShapeValid=\(numericShapeValid) directoryShapeValid=\(directoryShapeValid) "
                + "explicit=\(explicit) cached=\(cached) app=\(app)"
        )
    }
}

final class FormalHostContractXCTestProbeTests: XCTestCase {
    func testFormalContractInXCTestHost() {
        let finding = FormalHostContractProbe.inspect()
        XCTAssertTrue(finding.valid, finding.diagnostic)
    }
}

@Suite("Formal contract Swift Testing host probe")
struct FormalHostContractSwiftProbeTests {
    @Test("Formal contract stays isolated in Swift Testing host")
    func formalContractInSwiftTestingHost() {
        let finding = FormalHostContractProbe.inspect()
        #expect(finding.valid, "\(finding.diagnostic)")
    }

    @Test("ChatStore defaults use the validated formal profile")
    @MainActor
    func chatStoreDefaultsStayInFormalProfile() throws {
        guard let paths = try FormalTestIsolationPaths.resolveCurrentProcess() else {
            Issue.record("Formal test profile is missing")
            return
        }
        guard let suite = UserDefaults(suiteName: paths.userDefaultsSuiteName) else {
            Issue.record("Formal preferences suite is unavailable")
            return
        }

        let chat = ChatStore()
        let key = "formal.chat-defaults.\(UUID().uuidString)"
        defer { suite.removeObject(forKey: key) }
        chat.preferencesDefaults.set("synthetic", forKey: key)
        #expect(suite.string(forKey: key) == "synthetic")

        chat.logManager.info("synthetic formal log", category: "Isolation")
        #expect(chat.logManager.logFileURL()?.deletingLastPathComponent() == paths.logDirectory)
    }

    @Test("BridgeStore default dependencies share the formal profile")
    @MainActor
    func bridgeDefaultsStayInFormalProfile() throws {
        guard let paths = try FormalTestIsolationPaths.resolveCurrentProcess(),
              let suite = UserDefaults(suiteName: paths.userDefaultsSuiteName) else {
            Issue.record("Formal test profile or preferences suite is missing")
            return
        }
        let bridge = BridgeStore()
        let key = "formal.bridge-defaults.\(UUID().uuidString)"
        defer { suite.removeObject(forKey: key) }
        bridge.preferencesDefaults.set("synthetic", forKey: key)
        #expect(suite.string(forKey: key) == "synthetic")
        bridge.chat.logManager.info("synthetic bridge log", category: "Isolation")
        #expect(bridge.chat.logManager.logFileURL()?.deletingLastPathComponent()
            == paths.logDirectory)
    }

    @Test("CanvasStore default width is persisted only in the formal suite")
    @MainActor
    func canvasDefaultsStayInFormalProfile() throws {
        guard let paths = try FormalTestIsolationPaths.resolveCurrentProcess(),
              let suite = UserDefaults(suiteName: paths.userDefaultsSuiteName) else {
            Issue.record("Formal test profile or preferences suite is missing")
            return
        }
        let key = "canvas.textInspectorWidth"
        let prior = suite.object(forKey: key)
        defer {
            if let prior { suite.set(prior, forKey: key) }
            else { suite.removeObject(forKey: key) }
        }
        let canvas = CanvasStore()
        canvas.textInspectorWidth = 431
        #expect(suite.double(forKey: key) == 431)
    }

    @Test("ShortcutStore default overrides are persisted only in the formal suite")
    @MainActor
    func shortcutDefaultsStayInFormalProfile() throws {
        guard let paths = try FormalTestIsolationPaths.resolveCurrentProcess(),
              let suite = UserDefaults(suiteName: paths.userDefaultsSuiteName) else {
            Issue.record("Formal test profile or preferences suite is missing")
            return
        }
        let key = "miniscanvas.shortcuts.v1"
        let prior = suite.data(forKey: key)
        defer {
            if let prior { suite.set(prior, forKey: key) }
            else { suite.removeObject(forKey: key) }
        }
        ShortcutStore().resetAll()
        #expect(suite.data(forKey: key) != nil)
    }
}
