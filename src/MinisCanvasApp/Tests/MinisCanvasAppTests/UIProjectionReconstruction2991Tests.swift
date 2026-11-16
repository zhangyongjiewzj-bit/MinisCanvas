import AppKit
import ApplicationServices
import Foundation
import SwiftUI
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

// Remains in the existing native suite/entry route. The ordinary non-native
// suite banner does not execute this method or establish reconstruction proof.
extension TaskCenterNativeAccessibilityConsumerTests {
    @Test("ARCH3 主窗口与设置重建只投影同一 owner 的后继事实")
    @MainActor
    func rebuiltMainAndSettingsKeepCanonicalOwners2991() async throws {
        _ = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "ui-projection2991", processEnvironment: [:],
            processArguments: ["/tmp/MinisCanvasAppTests.xctest"], canvasRuntimeState: .disabled)
        defer { try? profile.cleanupDisposableRoots() }
        let defaults = profile.makeUserDefaults()
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let sessions = SessionStore(directory: profile.sessionDirectory)
        let badges = SessionBadgeStore(directory: profile.minisCanvasDirectory)
        let memory = MemoryStore(directory: profile.memoryDirectory)
        let shortcuts = ShortcutStore(defaults: defaults)
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: profile.settingsDirectory),
            envStore: EnvVarStore(directory: profile.providerConfigurationDirectory, keychain: keychain),
            memoryStore: memory, memoryFileStore: MemoryFileStore(directory: profile.memoryDirectory),
            sessionStore: sessions, sessionBadgeStore: badges, logManager: profile.makeLogManager(),
            mcpManager: MCPServerManager(fileURL: profile.mcpConfigurationURL, keychain: keychain),
            skillStore: SkillStore(skillsRoot: profile.minisCoreDirectory.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: profile.usageStoreDefaultsDomain), shortcutStore: shortcuts,
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessStore: ProviderReadinessStore(directory: profile.providerConfigurationDirectory))
        let skills = SkillsStore(appStore: center.skillStore,
            stateFileURL: profile.skillStateURL, loadImmediately: false)
        let scheduler = SchedulerTaskStore(defaults: defaults,
            occurrenceLedgerURL: profile.minisCanvasDirectory.appendingPathComponent("scheduler-occurrences-v1.json"))
        let schedulerRuntime = SchedulerTaskRuntime(store: scheduler, submitCommand: { _ in
            Issue.record("UI 重建不得提交调度任务")
        })
        defer { schedulerRuntime.stop() }
        let taskURL = profile.rootDirectory.appendingPathComponent("agent-tasks2991.json")
        let taskStore = try AgentTaskStore(persistenceURL: taskURL)
        _ = try taskStore.enqueue(taskID: "owned-task2991", parentID: "owned-parent2991",
                                  providerID: "offline", modelID: "synthetic")
        let syntheticSecret = "arch3-synthetic-secret-2991"
        #expect(center.envStore.setEnvVar(name: "ARCH3_SYNTHETIC_SECRET", value: syntheticSecret, isSecret: true))
        let sessionID = UUID()
        _ = try sessions.createSession(id: sessionID.uuidString, title: "ARCH3 初始会话2991")
        try sessions.saveMessage(.init(role: .user, content: "ARCH3 原领域原文2991 \(syntheticSecret)"),
                                 sessionID: sessionID.uuidString)
        try center.mcpManager.addServer(.init(id: "owned-mcp2991", name: "合成2991",
            type: .stdio, enabled: false, command: "echo"))
        center.safeModeEnabled = false
        let bridge = BridgeStore(shortcutStore: shortcuts, preferencesDefaults: defaults,
            settingsCatalogSkillsStore: skills, settingsCatalogSchedulerStore: scheduler,
            logManager: center.logManager,
            workflowStore: WorkflowStore(storeDirectory: profile.minisCanvasDirectory.appendingPathComponent("Workflows")),
            sessionBadgeStore: badges, sessionDocumentStore: SessionDocumentStore(directory: sessions.directory),
            sessionStore: sessions, canvasRuntimeState: .disabled, agentTaskStore: taskStore,
            memoryStore: memory, memoryProposalConsumer: center.memoryProposalConsumer,
            canvasFeatureLane: .phase3NonCanvas)
        #expect(bridge.bindConfirmedSessionDeletionProjection(to: center))
        #expect(ProductionPickerCatalogWiring.bind(chat: bridge.chat, center: center, profile: profile))
        await bridge.attachProductionServices(fileAccessAllowedRoot: profile.rootDirectory,
            sessionDirectory: sessions.directory, mcpManager: center.mcpManager, skillStore: center.skillStore,
            canvasRuntimeState: .disabled, externalNetworkAllowed: false).value
        #expect(bridge.chat.applySwitchSession(id: sessionID))
        bridge.chat.draftText = "ARCH3 原父草稿2991"
        let originalMessages = bridge.chat.messages

        // These are actual synthetic files in the exact injected owner roots.
        // Capturing after each intentional owner update separates legal source
        // writes from an unexpected write/reversion caused by a rebuilt UI.
        let canonicalFiles = [center.settingsDirectory.appendingPathComponent(SettingsStore.fileName),
            sessions.sessionsDirectory.appendingPathComponent(sessionID.uuidString + ".json"),
            taskURL, center.mcpManager.fileURL,
            profile.providerConfigurationDirectory.appendingPathComponent(EnvVarStore.fileName)]
        for generation in 0...1 {
            if generation == 1 {
                bridge.chat.renameSession(id: sessionID, title: "ARCH3 后继会话2991")
                center.safeModeEnabled = true
            }
            let expectedTitle = generation == 0 ? "ARCH3 初始会话2991" : "ARCH3 后继会话2991"
            let before = try canonicalFiles.map { try Data(contentsOf: $0) }
            let sourceFact = try #require(sessions.loadSession(id: sessionID.uuidString))
            #expect(sourceFact.title == expectedTitle)
            #expect(center.sessionStore === sessions)
            #expect(bridge.chat.sessionStore === sessions)
            #expect(bridge.chat.sessionManager?.store === sessions)
            #expect(bridge.taskCenterControlConsumer.sharesChildTranscriptSessionStore(sessions))

            let main = ContentView(bridge: bridge, transcriptEnvStore: center.envStore)
            #expect(main.bridge === bridge)
            #expect(main.transcriptEnvStore === center.envStore)
            let chatProjection = ChatMainView(chat: bridge.chat, documentStore: bridge.sessionDocuments,
                transcriptEnvStore: center.envStore)
            #expect(!chatProjection.transcriptPlainTextForCopy().contains(syntheticSecret),
                "copy-all must project live redaction facts from the canonical Settings owner")
            try await Self.withProjectionHost2991(AnyView(main
                .environment(bridge).environment(shortcuts)
                .environment(\.themeTokens, ThemeTokenProvider(center: center))
                .environment(\.typographyTokens, TypographyTokenProvider(center: center)))) { window in
                _ = try #require(try await Self.waitProjectionAX2991(window, label: expectedTitle),
                    "真实主窗口必须投影原 Chat/Session owner 的当前标题")
            }

            let settings = SettingsView(center: center, shortcutStore: shortcuts,
                skillsStore: skills, schedulerStore: scheduler, schedulerRuntime: schedulerRuntime)
            #expect(settings.center === center && settings.shortcutStore === shortcuts)
            #expect(settings.skillsStore === skills && settings.schedulerStore === scheduler)
            #expect(settings.schedulerRuntime === schedulerRuntime)
            try await Self.withProjectionHost2991(AnyView(settings
                .environment(center).environment(shortcuts)
                .environment(\.themeTokens, ThemeTokenProvider(center: center))
                .environment(\.typographyTokens, TypographyTokenProvider(center: center)))) { window in
                let safetyPage = try #require(try await Self.waitProjectionAX2991(window,
                    identifier: "settings-tab-safety"))
                #expect(NativeConsumerOwnedAX.press(safetyPage))
                let safeMode = try #require(try await Self.waitProjectionAX2991(window,
                    identifier: "settings.safety.safe-mode"))
                let value = try #require(NativeConsumerOwnedAX.attribute(safeMode,
                    kAXValueAttribute as CFString) as? NSNumber,
                    "缺失或不可读 AX value 不是安全开关的投影证明")
                #expect(value.boolValue == (generation == 1))
            }
            let after = try canonicalFiles.map { try Data(contentsOf: $0) }
            #expect(after == before,
                "Content/Settings 重建不得向规范文件写回旧事实或创建第二写方")
            #expect(sessions.loadSession(id: sessionID.uuidString) == sourceFact)
            #expect(bridge.chat.activeSessionID == sessionID)
            #expect(bridge.chat.draftText == "ARCH3 原父草稿2991")
            #expect(bridge.chat.messages == originalMessages && !bridge.chat.isStreaming)
            #expect(center.safeModeEnabled == (generation == 1))
        }
        let reopened = SessionStore(directory: sessions.directory)
        #expect(reopened.loadSession(id: sessionID.uuidString)?.title == "ARCH3 后继会话2991")
        #expect(reopened.loadSession(id: sessionID.uuidString)?.messages.map(\.content)
            == ["ARCH3 原领域原文2991 \(syntheticSecret)"])
    }

    // Normal NSHosting arrange/teardown uses the original shared observation
    // owner. This adds neither an NSApp entry point nor a second host lifecycle.
    @MainActor
    private static func withProjectionHost2991(_ root: AnyView,
        observe: @MainActor (NSWindow) async throws -> Void) async throws {
        let lease = NativeTestHostLifecycle.begin("ARCH3")
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        NativeTestHostLifecycle.bind(lease, to: window)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1000, height: 760))
        controller.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 760)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
            NativeTestHostLifecycle.end(window)
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        controller.view.display()
        NativeTestHostLifecycle.observe(window, phase: "sampled")
        try await observe(window)
    }

    @MainActor
    private static func pumpProjectionAX2991() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }

    @MainActor
    private static func waitProjectionAX2991(_ window: NSWindow, identifier: String? = nil,
        label: String? = nil) async throws -> AnyObject? {
        for _ in 0..<100 {
            Self.pumpProjectionAX2991()
            let node: AnyObject?
            if let identifier { node = NativeConsumerOwnedAX.find(in: window, identifier: identifier) }
            else if let label { node = NativeConsumerOwnedAX.find(in: window, label: label) }
            else { return nil }
            if let node { return node }
            try await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }
}
