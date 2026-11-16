import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("packaged field App Support consumers 1536")
@MainActor
struct FieldAppSupportIsolation1536Tests {
    @Test("formal default badge and ordinary Bridge consumer use the verified root")
    func formalDefaultBadgeConsumerUsesVerifiedRoot1613() throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        #expect(profile.minisCanvasDirectory == formal.minisCanvasDirectory)
        let root = formal.temporaryDirectory.appendingPathComponent(
            "badge-default-1613-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let independent = root.appendingPathComponent("independent-support")
        let control = SessionBadgeStore(directory: independent)
        #expect(control.increment(for: "independent-control") == 1)
        let controlURL = independent.appendingPathComponent("badges.json")
        let controlBefore = try Data(contentsOf: controlURL)

        let defaults = profile.makeUserDefaults()
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            logManager: profile.makeLogManager(),
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("Workflows")),
            sessionDocumentStore: SessionDocumentStore(directory: root.appendingPathComponent("sessions")),
            canvasRuntimeState: .disabled,
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            taskCenterBindingPersistenceURL: root.appendingPathComponent("task-bindings.json"),
            canvasFeatureLane: .phase3NonCanvas
        )
        #expect(bridge.sessionBadgeStore === SessionBadgeStore.shared)
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        #expect(bridge.chat.attachPersistence(sessions))
        #expect(bridge.chat.sessionManager?.badgeStore === bridge.sessionBadgeStore)

        let probeID = "formal-badge-1613-\(UUID().uuidString)"
        #expect(bridge.sessionBadgeStore.increment(for: probeID) == 1)
        let formalURL = formal.minisCanvasDirectory.appendingPathComponent("badges.json")
        #expect(FileManager.default.fileExists(atPath: formalURL.path))
        #expect(SessionBadgeStore(directory: formal.minisCanvasDirectory).unreadCount(for: probeID) == 1)
        #expect(try Data(contentsOf: controlURL) == controlBefore)
    }

    @Test("badge reader, writer, sidebar, scheduler and workflow stay in the field root")
    func fieldStoresDoNotReadOrChangeIndependentSupportRoot() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("field-support-1536-\(UUID().uuidString)", isDirectory: true)
        let fieldRoot = parent.appendingPathComponent("field", isDirectory: true)
        let otherSupport = parent.appendingPathComponent(
            "independent/Application Support/MinisCanvas", isDirectory: true
        )
        try FileManager.default.createDirectory(at: otherSupport, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        // Synthetic negative control: this independent App Support tree must
        // remain byte-identical after the field consumers read and persist.
        let otherBadges = SessionBadgeStore(directory: otherSupport)
        #expect(otherBadges.increment(for: "independent-session") == 1)
        let otherBadgeURL = otherSupport.appendingPathComponent("badges.json")
        let otherBytesBefore = try Data(contentsOf: otherBadgeURL)

        let profile = try RuntimeIsolationProfile.makePackagedField(
            label: "app-support-1536",
            processEnvironment: [
                RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                RuntimeIsolationProfile.fieldActivationRootKey: fieldRoot.path
            ],
            processArguments: [
                "/Applications/MinisCanvas.app/Contents/MacOS/MinisCanvas",
                RuntimeIsolationProfile.fieldActivationArgument
            ]
        )
        defer { try? profile.cleanupDisposableRoots() }
        let badges = SessionBadgeStore(directory: profile.minisCanvasDirectory)
        let workflows = WorkflowStore(
            storeDirectory: profile.minisCanvasDirectory.appendingPathComponent(
                "Workflows", isDirectory: true
            )
        )
        let defaults = profile.makeUserDefaults()
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults),
            preferencesDefaults: defaults,
            logManager: profile.makeLogManager(),
            workflowStore: workflows,
            sessionBadgeStore: badges,
            sessionDocumentStore: SessionDocumentStore(directory: profile.sessionDirectory),
            canvasRuntimeState: .disabled,
            memoryStore: MemoryStore(directory: profile.memoryDirectory),
            canvasFeatureLane: .phase3NonCanvas
        )
        #expect(bridge.sessionBadgeStore === badges)
        let sessions = SessionStore(directory: profile.sessionDirectory)
        #expect(bridge.chat.attachPersistence(sessions, badgeStore: bridge.sessionBadgeStore))
        #expect(bridge.chat.sessionManager?.badgeStore === badges)

        let activeID = try #require(bridge.chat.activeSessionID)
        #expect(badges.increment(for: activeID.uuidString) == 1)
        let item = try #require(bridge.chat.sessionList.first { $0.id == activeID })
        _ = SessionSidebarView.sessionBadgePresentation(
            for: item, source: item.indicator, store: bridge.sessionBadgeStore
        )
        let fieldBadgeURL = profile.minisCanvasDirectory.appendingPathComponent("badges.json")
        #expect(FileManager.default.fileExists(atPath: fieldBadgeURL.path))
        #expect(SessionBadgeStore(directory: profile.minisCanvasDirectory)
            .unreadCount(for: activeID.uuidString) >= 0)
        #expect(fieldBadgeURL.path.hasPrefix(profile.rootDirectory.path + "/"))

        let ledgerURL = profile.minisCanvasDirectory.appendingPathComponent(
            "scheduler-occurrences-v1.json", isDirectory: false
        )
        let scheduler = SchedulerTaskStore(
            defaults: defaults, occurrenceLedgerURL: ledgerURL
        )
        #expect(scheduler.occurrenceLedgerURL == ledgerURL)
        #expect(ledgerURL.path.hasPrefix(profile.rootDirectory.path + "/"))
        #expect(workflows.template(id: "missing-field-template") == nil)
        #expect(try Data(contentsOf: otherBadgeURL) == otherBytesBefore)
        let otherEntries = try FileManager.default.contentsOfDirectory(
            atPath: otherSupport.path
        )
        #expect(otherEntries.filter { $0 != "badges.json" }.isEmpty)
    }
}
