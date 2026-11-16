import Foundation
import Testing
@testable import MinisCore

/// Non-AX contracts only. The local HTTP/WebView journey remains a separate
/// same-package acceptance task.
struct P3AcceptanceM06BrowserContractsTests {
    @Test("browser UA, viewport, and idle settings survive a store reopen")
    func browserSettingsSurviveStoreReopen() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("P3AcceptanceM06-BrowserSettings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let expected = BrowserSettings(
            userAgentPreset: .custom,
            customUserAgent: "M06-UA/1.0",
            viewportMode: .custom,
            customViewportWidth: 721,
            customViewportHeight: 513,
            idleTabTimeoutMinutes: 7
        )
        let store = SettingsStore(directory: directory)
        store.update(\.browser, to: expected)
        #expect(store.lastPersistenceError == nil)

        let reopened = SettingsStore(directory: directory)
        #expect(reopened.settings.browser == expected)
        #expect(reopened.settings.browser.resolvedUserAgent() == "M06-UA/1.0")
        #expect(reopened.settings.browser.resolvedViewport().width == 721)
        #expect(reopened.settings.browser.resolvedViewport().height == 513)
        #expect(reopened.settings.browser.idleTabTimeoutMinutes == 7)
    }

    private static let schemaGrant = BrowserCapabilityGrant(
        capability: BrowserCapabilityGrant.writeCapability,
        approvalReceipt: "synthetic-approval"
    )

    @Test("model-facing browser schema defaults OFF to exactly four read actions")
    func browserCatalogOffExposesOnlyReadActionsWithSameGrant() throws {
        let definition = try #require(
            AgentToolCatalog.makeTools(browserGrant: Self.schemaGrant)
                .first { $0.name == BrowserTool.toolName }
        )
        let exposed = try #require(definition.parameters["action"]?.enumValues)
        #expect(exposed == ["navigate", "read", "back", "screenshot"])
    }

    @Test("model-facing browser schema ON adds exactly the four approved write actions")
    func browserCatalogOnExposesRestrictedWritesWithSameGrant() throws {
        let definition = try #require(
            AgentToolCatalog.makeTools(browserGrant: Self.schemaGrant, browserWriteActionsVisible: true)
                .first { $0.name == BrowserTool.toolName }
        )
        let exposed = try #require(definition.parameters["action"]?.enumValues)
        #expect(exposed == ["navigate", "read", "back", "screenshot", "click", "type", "download", "upload"])

        try BrowserTool.validate(name: definition.name, input: ["action": "navigate", "url": "https://example.com"])
        try BrowserTool.validate(name: definition.name, input: ["action": "read"])
        try BrowserTool.validate(name: definition.name, input: ["action": "click", "selector": "#button"])
        try BrowserTool.validate(name: definition.name, input: ["action": "type", "selector": "#input", "text": "hello"])
        try BrowserTool.validate(name: definition.name, input: ["action": "back"])
        try BrowserTool.validate(name: definition.name, input: ["action": "screenshot"])
        for action in ["download", "upload"] {
            try BrowserTool.validate(name: definition.name, input: [
                "action": action, "selector": "#transfer", "path": "/synthetic/transfer.bin"
            ])
        }
    }
}
