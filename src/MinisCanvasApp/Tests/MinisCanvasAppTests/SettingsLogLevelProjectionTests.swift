import Foundation
import MinisCore
import XCTest
@testable import MinisCanvasApp

@MainActor
final class SettingsLogLevelProjectionTests: XCTestCase {
    private func center(
        profile: RuntimeIsolationProfile,
        logger: LogManager
    ) -> SettingsCenter {
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        return SettingsCenter(
            settingsStore: SettingsStore(directory: profile.settingsDirectory),
            envStore: EnvVarStore(directory: profile.providerConfigurationDirectory, keychain: keychain),
            memoryStore: MemoryStore(directory: profile.memoryDirectory),
            sessionStore: SessionStore(directory: profile.sessionDirectory),
            sessionBadgeStore: SessionBadgeStore(directory: profile.rootDirectory.appendingPathComponent("badges")),
            logManager: logger,
            mcpManager: MCPServerManager(fileURL: profile.mcpConfigurationURL, keychain: keychain),
            skillStore: SkillStore(skillsRoot: profile.hermesSkillsDirectory),
            usageStore: UsageStore(domain: profile.usageStoreDefaultsDomain)
        )
    }

    func testExistingEntriesFollowLiveThresholdAndReturnOnDebugAfterReopen() throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "settings20-log-projection", canvasRuntimeState: .disabled
        )
        defer { try? profile.cleanupDisposableRoots() }
        let logger = profile.makeLogManager()
        let settings = center(profile: profile, logger: logger)
        settings.liveLogLevel = .debug

        logger.debug("existing-debug", category: "Settings20")
        for index in 1...3 {
            logger.info("existing-info-\(index)", category: "Settings20")
        }
        logger.warn("existing-warn", category: "Settings20")
        logger.error("existing-error", category: "Settings20")
        settings.reloadLogs()

        let allMessages = logger.recentLogs(limit: nil).map(\.message)
        XCTAssertEqual(allMessages.count, 6)
        XCTAssertEqual(settings.visibleLogEntries.map(\.message), allMessages)

        settings.liveLogLevel = .warn
        XCTAssertEqual(logger.minimumLevel, .warn)
        XCTAssertEqual(settings.visibleLogEntries.map(\.message), ["existing-error", "existing-warn"])
        XCTAssertEqual(settings.logEntries.map(\.message), allMessages)
        XCTAssertEqual(logger.recentLogs(limit: nil).map(\.message), allMessages)

        // A recreated center reloads the saved level from the same isolated
        // profile and process logger; tab reopen also reloads this ring.
        let reopened = center(profile: profile, logger: logger)
        reopened.reloadLogs()
        XCTAssertEqual(reopened.liveLogLevel, .warn)
        XCTAssertEqual(reopened.visibleLogEntries.map(\.message), ["existing-error", "existing-warn"])

        let preview = try reopened.previewLogClear()
        XCTAssertEqual(preview.affectedCount, 6) // Full ring, not the two visible rows.
        XCTAssertNil(preview.firstConfirmation)
        XCTAssertNil(preview.secondConfirmation)
        // Cancel the preview by discarding it; no clear command is sent.
        XCTAssertEqual(logger.recentLogs(limit: nil).map(\.message), allMessages)

        reopened.liveLogLevel = .error
        XCTAssertEqual(reopened.visibleLogEntries.map(\.message), ["existing-error"])
        reopened.liveLogLevel = .debug
        XCTAssertEqual(reopened.visibleLogEntries.map(\.message), allMessages)
    }

    func testFilteringPrecedesTheDisplayLimitAndCanShowAnEmptyState() throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "settings20-log-limit", canvasRuntimeState: .disabled
        )
        defer { try? profile.cleanupDisposableRoots() }
        let logger = profile.makeLogManager()
        let settings = center(profile: profile, logger: logger)
        settings.liveLogLevel = .debug
        logger.warn("older-warn", category: "Settings20")
        for index in 1...201 {
            logger.info("newer-info-\(index)", category: "Settings20")
        }
        settings.reloadLogs()
        XCTAssertEqual(settings.visibleLogEntries.count, 200)

        settings.liveLogLevel = .warn
        XCTAssertEqual(settings.visibleLogEntries.map(\.message), ["older-warn"])
        settings.liveLogLevel = .error
        XCTAssertTrue(settings.visibleLogEntries.isEmpty)
        XCTAssertEqual(logger.recentLogs(limit: nil).count, 202)
        settings.liveLogLevel = .debug
        XCTAssertEqual(settings.visibleLogEntries.count, 200)
    }
}
