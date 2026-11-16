import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// Focused production-seam coverage for the BL6 transaction fence.  These
/// tests construct the real SettingsCenter and ChatStore consumers; they do
/// not duplicate the reducer or use a mock settings boundary.
@Suite("BL6 production boundary recovery")
@MainActor
struct BL6ProductionBoundaryRecoveryTests {
    private func makeCenter(at root: URL) -> SettingsCenter {
        SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(
                directory: root.appendingPathComponent("env"),
                keychain: KeychainStore(backing: InMemoryKeychainBacking())
            ),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
            logManager: LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 20)
        )
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BL6-boundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func removeRoot(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }

    @Test("transaction marker is durable and any marker contents reload as unknown")
    func transactionMarkerLoadsFailClosed() throws {
        let root = try makeRoot()
        defer { removeRoot(root) }

        let center = makeCenter(at: root)
        #expect(center.bl6SettingsTransactionState == .ready)
        center.markBL6SettingsTransactionUnknown()

        let markerURL = root
            .appendingPathComponent("settings", isDirectory: true)
            .appendingPathComponent(SettingsCenter.bl6SettingsTransactionMarkerFileName)
        #expect(FileManager.default.fileExists(atPath: markerURL.path))
        #expect(String(decoding: try Data(contentsOf: markerURL), as: UTF8.self) == "unknown\n")

        // Presence, rather than a parseable payload, is the durable fence.
        try Data("corrupt-but-secret-free\n".utf8).write(to: markerURL, options: .atomic)
        let reloaded = makeCenter(at: root)
        #expect(reloaded.bl6SettingsTransactionState == .unknown)
        #expect(reloaded.bl6EffectiveSettingsSnapshot == nil)
    }

    @Test("restart-loaded unknown state blocks the real ChatStore submission seam")
    func restartUnknownBlocksChatSubmission() throws {
        let root = try makeRoot()
        defer { removeRoot(root) }

        let center = makeCenter(at: root)
        center.markBL6SettingsTransactionUnknown()
        let restarted = makeCenter(at: root)
        let chat = ChatStore()
        let baselineMessages = chat.messages
        chat.effectiveSettingsSnapshotSource = { restarted.bl6EffectiveSettingsSnapshot }
        chat.draftText = "must remain local and unsent"

        chat.submitComposer()

        #expect(chat.lastSubmissionBlockedByInvalidSettings)
        #expect(chat.messages == baselineMessages)
        do {
            _ = try chat.activeProvider()
            Issue.record("restart unknown state reached the provider runtime")
        } catch let error as ChatStoreProviderError {
            #expect(error == .unavailable(
                providerID: "settings-transaction-unknown",
                protocolType: .other
            ))
        }
    }

    @Test("provider runtime remains fenced after a production transaction becomes unknown")
    func providerRuntimeFenceUsesEffectiveSnapshot() throws {
        let root = try makeRoot()
        defer { removeRoot(root) }

        let center = makeCenter(at: root)
        let chat = ChatStore()
        let baselineMessages = chat.messages
        chat.effectiveSettingsSnapshotSource = { center.bl6EffectiveSettingsSnapshot }
        center.markBL6SettingsTransactionUnknown()
        chat.draftText = "provider must not be constructed"

        chat.submitComposer()

        #expect(chat.lastSubmissionBlockedByInvalidSettings)
        #expect(chat.messages == baselineMessages)
        do {
            _ = try chat.activeProvider()
            Issue.record("unknown production transaction reached activeProvider")
        } catch let error as ChatStoreProviderError {
            #expect(error == .unavailable(
                providerID: "settings-transaction-unknown",
                protocolType: .other
            ))
        }
    }
}
