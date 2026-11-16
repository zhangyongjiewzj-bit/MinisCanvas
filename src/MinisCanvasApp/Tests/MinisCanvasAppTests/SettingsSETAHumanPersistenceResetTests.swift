import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// Goal19 SETA residual human P/R only. Existing BL6 fourteen-key P cases and
/// domain consumers remain their own evidence; this leaf never claims OS restart.
@Suite("SETA human persistence and one global reset", .serialized)
@MainActor
struct SettingsSETAHumanPersistenceResetTests {
    // Local composition adapted from SettingsCenterTests.makeResetConsumerFixture853
    // and SETBOutputModeResetConsumer2602Tests.makeCenter; no production defaults.
    private func center(root: URL, defaults: UserDefaults, keychain: KeychainStore) -> SettingsCenter {
        SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keychain,
                                 privacyStore: EnvVarPrivacyStore(defaults: defaults)),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            memoryFileStore: MemoryFileStore(directory: root.appendingPathComponent("memory-files")),
            sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            logManager: LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 20),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcp.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite(root.lastPathComponent)),
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessDeployment: .mock,
            providerReadinessStore: ProviderReadinessStore(directory: root.appendingPathComponent("readiness")))
    }

    private let seededPersona = Persona(name: "SETA synthetic", summary: "Owned fixture only",
                                        tone: "brief", abilities: "summarize")
    // Explicit contract oracle, not AppSettings.defaults or a catalog projection.
    private let resetPersona = Persona(name: "专业助手",
        summary: "严谨、可靠的中文助手，擅长结构化分析与清晰表达。",
        tone: "专业、礼貌、简洁", abilities: "综合分析、文档撰写、方案规划、信息整理")
    private let seededComposer = ComposerPolicySettings(mode: .manual, approvalScope: .request,
                                                        effort: .high)
    private let resetComposer = ComposerPolicySettings(mode: .manual, approvalScope: .request,
                                                       effort: .standard)
    private let seededPolicy = ProductionPolicyDefaults(budget: 777, deadlineHorizon: 125,
                                                        autonomyLevel: .l0, networkDomains: [])
    private let resetPolicy = ProductionPolicyDefaults(budget: 10_000, deadlineHorizon: 14_400,
                                                       autonomyLevel: .l2, networkDomains: [])
    private let seededTerminal = TerminalPolicySettings(automaticAllowCommands: ["echo"],
                                                        confirmationCommands: ["git"], userDeniedCommands: ["rm"])
    private let resetTerminal = TerminalPolicySettings(
        automaticAllowCommands: ["cd", "ls", "pwd", "echo", "whoami", "date", "cat", "head", "tail",
            "wc", "grep", "find", "tree", "clear", "which", "du", "df", "stat", "file", "basename",
            "dirname", "uname", "sw_vers", "sort", "uniq", "cut", "tr", "xargs",
            "history", "man", "help", "type"],
        confirmationCommands: ["mkdir", "touch", "cp", "mv", "rm", "git", "curl", "wget", "swift", "swiftc",
            "xcodebuild", "brew", "cargo", "python3", "python", "chmod", "chown", "kill", "pkill", "sed",
            "awk", "tar", "unzip", "zip", "plutil", "defaults", "install", "ln", "env", "printenv",
            "npm", "npx", "node", "pnpm", "yarn", "make", "pytest", "go", "gh", "jq", "rg", "uv", "docker"],
        userDeniedCommands: [], explicitConfirmationCommands: [], confirmationProvenanceVersion: 1)

    /// Decode only the explicitly named public field. The file is this leaf's
    /// owned synthetic settings.json; never print or decode replay/credential data.
    private func check<T: Decodable & Equatable>(
        _ key: String, path: String, actual: T, expected: T, disk: [String: Any]
    ) throws {
        var value: Any = disk
        for component in path.split(separator: ".") {
            value = (value as? [String: Any])?[String(component)] ?? NSNull()
        }
        let bytes = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        let stored = try JSONDecoder().decode(T.self, from: bytes)
        #expect(actual == expected, "human owner field: \(key)")
        #expect(stored == expected, "independent disk field: \(key)")
    }

    private func readOwnedPublicFile(_ url: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    /// One explicit residual contract, not a generated implementation matrix.
    /// reset=false checks only P absent from the existing fourteen-key BL6 leaf.
    /// reset=true also checks those fourteen R fields after the HUMAN reset.
    private func verify(_ c: SettingsCenter, disk: [String: Any], reset: Bool, root: URL) throws {
        try check("general.theme-preset", path: "general.themePreset", actual: c.themePreset,
                  expected: reset ? ThemePreset.system : .light, disk: disk)
        try check("general.appearance", path: "general.appearance", actual: c.appearance,
                  expected: reset ? Appearance.system : .light, disk: disk)
        try check("general.accent-theme", path: "general.accentTheme", actual: c.accentTheme,
                  expected: AccentTheme.pseudo, disk: disk)
        try check("general.default-provider-id", path: "general.defaultProviderID", actual: c.defaultProviderID,
                  expected: reset ? nil : Optional("openai"), disk: disk)
        try check("general.default-model-id", path: "general.defaultModelID", actual: c.defaultModelID,
                  expected: reset ? nil : Optional("gpt-4o-mini"), disk: disk)
        try check("general.model-speed-tier", path: "general.modelSpeedTier", actual: c.modelSpeedTier,
                  expected: reset ? ModelSpeedTier.balanced : .quality, disk: disk)
        try check("general.language", path: "general.language", actual: c.language,
                  expected: reset ? "zh-Hans" : "en", disk: disk)
        try check("agent.child-concurrency-user-selected", path: "agent.childConcurrencyUserSelected",
                  actual: c.childConcurrencyUserSelected, expected: reset ? 4 : 8, disk: disk)
        try check("agent.child-concurrency-enabled-session-count", path: "agent.childConcurrencyEnabledSessionCount",
                  actual: c.childConcurrencyEnabledSessionCount, expected: reset ? 1 : 3, disk: disk)
        try check("agent.fallback-enabled", path: "agent.fallbackEnabled", actual: c.fallbackEnabled,
                  expected: reset, disk: disk)
        try check("agent.persona-enabled", path: "agent.personaEnabled", actual: c.personaEnabled,
                  expected: !reset, disk: disk)
        try check("agent.persona", path: "agent.persona", actual: c.persona,
                  expected: reset ? resetPersona : seededPersona, disk: disk)
        try check("agent.memory-enabled", path: "agent.memoryEnabled", actual: c.memoryEnabled,
                  expected: reset, disk: disk)
        try check("agent.approval-policy", path: "agent.approvalPolicy", actual: c.approvalPolicy,
                  expected: reset ? ApprovalPolicy.alwaysAsk : .deny, disk: disk)
        try check("agent.available-model-whitelist", path: "agent.availableModelWhitelist", actual: c.availableModelWhitelist,
                  expected: reset ? [] : ["gpt-4o-mini"], disk: disk)
        try check("agent.composer-policy", path: "agent.composerPolicy", actual: c.composerPolicy,
                  expected: reset ? resetComposer : seededComposer, disk: disk)
        try check("agent.policy-runtime-defaults", path: "agent.policyRuntimeDefaults", actual: c.policyRuntimeDefaults,
                  expected: reset ? resetPolicy : seededPolicy, disk: disk)
        try check("agent.terminal-policy", path: "agent.terminalPolicy", actual: c.terminalPolicySettings,
                  expected: reset ? resetTerminal : seededTerminal, disk: disk)
        try check("privacy.redact-env-values", path: "privacy.redactEnvValues", actual: c.redactEnvValues,
                  expected: reset, disk: disk)
        try check("privacy.collect-analytics", path: "privacy.collectAnalytics", actual: c.collectAnalytics,
                  expected: !reset, disk: disk)
        try check("privacy.log-level", path: "privacy.logLevel", actual: c.privacyLogLevel,
                  expected: reset ? SettingsLogLevel.info : .debug, disk: disk)
        try check("privacy.allowed-root-path", path: "privacy.allowedRootPath", actual: c.fileAccessAllowedRoot,
                  expected: reset ? nil : Optional(root.appendingPathComponent("allowed").path), disk: disk)
        try check("privacy.denied-root-paths", path: "privacy.deniedRootPaths", actual: c.fileAccessDeniedRoots,
                  expected: reset ? [] : [root.appendingPathComponent("allowed/blocked").path], disk: disk)
        try check("privacy.mounted-folder-paths", path: "privacy.mountedFolderPaths", actual: c.mountedFolderPaths,
                  expected: reset ? [] : [root.appendingPathComponent("mounted").path], disk: disk)
        try check("storage.session-retention-days", path: "storage.sessionRetentionDays", actual: c.sessionRetentionDays,
                  expected: reset ? 30 : 7, disk: disk)
        try check("storage.memory-limit-mb", path: "storage.memoryLimitMB", actual: c.memoryLimitMB,
                  expected: reset ? nil : Optional(8), disk: disk)
        try check("storage.auto-delete-old-sessions", path: "storage.autoDeleteOldSessions", actual: c.autoDeleteOldSessions,
                  expected: !reset, disk: disk)
        if reset {
            try check("general.chat-output-mode", path: "general.chatOutputMode", actual: c.chatOutputMode,
                      expected: ChatOutputMode.normal, disk: disk)
            // e66e240 / I-20261025T0841: reset follows the reviewed current default.
            try check("agent.max-loop-iterations", path: "agent.maxLoopIterations", actual: c.maxLoopIterations,
                      expected: AppSettings.defaults.agent.maxLoopIterations, disk: disk)
            try check("agent.tool-timeout-seconds", path: "agent.toolTimeoutSeconds", actual: c.toolTimeoutSeconds, expected: 300, disk: disk)
            try check("agent.concurrent-tool-limit", path: "agent.concurrentToolLimit", actual: c.concurrentToolLimit, expected: 4, disk: disk)
            try check("agent.auto-compact-threshold", path: "agent.autoCompactThreshold", actual: c.autoCompactThreshold, expected: 0.8, disk: disk)
            try check("agent.persona-preset", path: "agent.personaPreset", actual: c.personaPreset, expected: PersonaPreset.professional, disk: disk)
            try check("agent.new-message-interrupts-generation", path: "agent.newMessageInterruptsGeneration", actual: c.newMessageInterruptsGeneration, expected: false, disk: disk)
            try check("browser.user-agent-preset", path: "browser.userAgentPreset", actual: c.userAgentPreset, expected: UserAgentPreset.desktopChrome, disk: disk)
            try check("browser.custom-user-agent", path: "browser.customUserAgent", actual: c.customUserAgent, expected: "", disk: disk)
            try check("browser.viewport-mode", path: "browser.viewportMode", actual: c.browserViewportMode, expected: BrowserViewportMode.autoByUA, disk: disk)
            try check("browser.custom-viewport-width", path: "browser.customViewportWidth", actual: c.customViewportWidth, expected: 1280, disk: disk)
            try check("browser.custom-viewport-height", path: "browser.customViewportHeight", actual: c.customViewportHeight, expected: 800, disk: disk)
            try check("browser.idle-tab-timeout-minutes", path: "browser.idleTabTimeoutMinutes", actual: c.idleTabTimeoutMinutes, expected: 15, disk: disk)
            try check("typography.ui-base-font-size", path: "typography.uiBaseFontSize", actual: c.uiBaseFontSize, expected: 14, disk: disk)
        }
    }

    @Test("missing public persistence and human global reset rebuild the same owner")
    func ownedNondefaultsPersistAndOneHumanResetReopensDefaults() throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "seta-human-prv", canvasRuntimeState: .disabled)
        let root = profile.rootDirectory
        let defaults = profile.makeUserDefaults()
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        defer {
            if let suite = profile.userDefaultsSuiteName { defaults.removePersistentDomain(forName: suite) }
            defaults.removePersistentDomain(forName: root.lastPathComponent)
            try? profile.cleanupDisposableRoots()
        }
        for path in ["allowed/blocked", "mounted"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        // I-20261024T0912 / I-20261025T0601: new defaults carry provenance 1;
        // the nondefault ordinary constructor remains legacy/unknown provenance.
        #expect(seededTerminal.confirmationProvenanceVersion == nil)
        #expect(seededTerminal.explicitConfirmationCommands.isEmpty)
        let c = center(root: root, defaults: defaults, keychain: keychain)
        let allowed = root.appendingPathComponent("allowed").path
        let denied = root.appendingPathComponent("allowed/blocked").path
        let mounted = root.appendingPathComponent("mounted").path
        c.themePreset = .light
        c.defaultProviderID = "openai"
        c.defaultModelID = "gpt-4o-mini"
        c.modelSpeedTier = .quality
        c.language = "en"
        c.chatOutputMode = .concise
        #expect(AppSettings.defaults.agent.maxLoopIterations != 25)
        c.maxLoopIterations = 25
        c.toolTimeoutSeconds = 120
        c.concurrentToolLimit = 8
        c.childConcurrencyUserSelected = 8
        c.childConcurrencyEnabledSessionCount = 3
        c.autoCompactThreshold = 0.9
        c.fallbackEnabled = false
        c.personaEnabled = true
        c.applyPersonaPreset(.creative)
        c.persona = seededPersona
        c.memoryEnabled = false
        c.approvalPolicy = .deny
        c.availableModelWhitelist = ["gpt-4o-mini"]
        c.newMessageInterruptsGeneration = true
        c.composerPolicy = seededComposer
        #expect(c.updatePolicyRuntimeDefaults(seededPolicy))
        c.terminalPolicySettings = seededTerminal
        c.redactEnvValues = false
        c.collectAnalytics = true
        c.privacyLogLevel = .debug
        #expect(c.setFileAccessAllowedRoot(allowed))
        #expect(c.addFileAccessDeniedRoot(denied))
        #expect(c.mountFolder(mounted))
        // Original AJ45/SettingsCenterTests positive exception: local reset keeps mounts.
        c.resetFileAccessRoots()
        #expect(c.mountedFolderPaths == [mounted])
        #expect(SettingsStore(directory: c.settingsDirectory).settings.privacy.mountedFolderPaths == [mounted])
        #expect(c.setFileAccessAllowedRoot(allowed))
        #expect(c.addFileAccessDeniedRoot(denied))
        c.sessionRetentionDays = 7
        c.memoryLimitMB = 8
        c.autoDeleteOldSessions = true
        c.userAgentPreset = .mobileChrome
        c.customUserAgent = "SETA-owned-synthetic/1.0"
        c.browserViewportMode = .custom
        c.customViewportWidth = 900
        c.customViewportHeight = 700
        c.idleTabTimeoutMinutes = 5
        c.uiBaseFontSize = 18
        // Only synthetic opaque custody. Observe metadata, never resolve a secret.
        #expect(c.setEnvVar(name: "SETA_SYNTHETIC_API_KEY", value: "synthetic-opaque-fixture", isSecret: true))
        #expect(c.envEntries.contains { $0.name == "SETA_SYNTHETIC_API_KEY" && $0.valueInKeychain })
        #expect(c.lastPersistenceError == nil)

        // Residual V only: original AJ28/AJ45 relative paths cannot overwrite a valid root.
        #expect(!c.setFileAccessAllowedRoot("relative/path"))
        #expect(!c.addFileAccessDeniedRoot("relative/path"))
        #expect(!c.mountFolder("relative/path"))
        #expect(c.fileAccessAllowedRoot == allowed)
        #expect(c.fileAccessDeniedRoots == [denied])
        #expect(c.mountedFolderPaths == [mounted])
        // Existing contract normalizes these numbers; no invented rejection semantics.
        c.customViewportWidth = 0
        c.customViewportHeight = 0
        c.idleTabTimeoutMinutes = 0
        c.uiBaseFontSize = 100
        #expect(c.customViewportWidth == 1)
        #expect(c.customViewportHeight == 1)
        #expect(c.idleTabTimeoutMinutes == 1)
        #expect(c.uiBaseFontSize == 20)
        c.customViewportWidth = 900
        c.customViewportHeight = 700
        c.idleTabTimeoutMinutes = 5
        c.uiBaseFontSize = 18
        // Terminal hard-deny is immutable even through the public human setter.
        c.terminalPolicySettings = TerminalPolicySettings(automaticAllowCommands: ["echo", "sudo"],
            confirmationCommands: ["git"], userDeniedCommands: ["rm"])
        #expect(c.terminalPolicySettings == seededTerminal)

        let diskBefore = try readOwnedPublicFile(c.settingsStore.fileURL)
        try verify(c, disk: diskBefore, reset: false, root: root)
        let reopened = center(root: root, defaults: defaults, keychain: keychain)
        try verify(reopened, disk: diskBefore, reset: false, root: root)
        // Establish all fourteen R-only nondefault preconditions without duplicating their P table.
        #expect(reopened.chatOutputMode == .concise)
        #expect(reopened.maxLoopIterations == 25)
        #expect(reopened.toolTimeoutSeconds == 120)
        #expect(reopened.concurrentToolLimit == 8)
        #expect(reopened.autoCompactThreshold == 0.9)
        #expect(reopened.personaPreset == .creative)
        #expect(reopened.newMessageInterruptsGeneration)
        #expect(reopened.userAgentPreset == .mobileChrome)
        #expect(reopened.customUserAgent == "SETA-owned-synthetic/1.0")
        #expect(reopened.browserViewportMode == .custom)
        #expect(reopened.customViewportWidth == 900)
        #expect(reopened.customViewportHeight == 700)
        #expect(reopened.idleTabTimeoutMinutes == 5)
        #expect(reopened.uiBaseFontSize == 18)

        // Positive real consumers adapted from original 853 and 2602 bodies.
        let chat = ChatStore(preferencesDefaults: defaults, logManager: reopened.logManager)
        reopened.bindChatOutputMode(to: chat)
        #expect(chat.outputMode == .concise)
        reopened.logManager.debug("seta-before-reset", category: "SettingsReset")
        #expect(reopened.logManager.recentLogs().contains { $0.message == "seta-before-reset" })
        reopened.resetToDefaults() // Exactly one human global reset in this owned root.
        #expect(reopened.lastPersistenceError == nil)
        let diskAfter = try readOwnedPublicFile(reopened.settingsStore.fileURL)
        let freshStore = SettingsStore(directory: reopened.settingsDirectory)
        #expect(freshStore.settings.general.chatOutputMode == .normal)
        #expect(freshStore.settings.privacy.logLevel == .info)
        let after = center(root: root, defaults: defaults, keychain: keychain)
        try verify(after, disk: diskAfter, reset: true, root: root)
        #expect(chat.outputMode == .normal)
        #expect(!ChatStore.systemPrompt(for: chat.outputMode).contains("只输出最终结果"))
        #expect(reopened.logManager.minimumLevel == .info)
        reopened.logManager.debug("seta-debug-after-reset", category: "SettingsReset")
        reopened.logManager.info("seta-info-after-reset", category: "SettingsReset")
        #expect(!reopened.logManager.recentLogs().contains { $0.message == "seta-debug-after-reset" })
        #expect(reopened.logManager.recentLogs().contains { $0.message == "seta-info-after-reset" })
        #expect(after.envEntries.contains { $0.name == "SETA_SYNTHETIC_API_KEY" && $0.valueInKeychain })
        // N/A: redact flag, analytics and memory-limit have no new operational consumer here.
        // sub-model-reference has no user UI entry: deliberately untested, never claimed PASS.
    }
}
