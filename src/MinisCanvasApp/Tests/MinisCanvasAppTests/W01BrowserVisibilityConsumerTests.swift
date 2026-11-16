import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@MainActor
struct W01BrowserVisibilityConsumerTests {
    @MainActor private final class CurrentTool { var value: BrowserTool? }

    @Test func missingVisibilitySourceKeepsReadOnlyAdvertisement() async throws {
        let engine = AgentLoopChatEngine()
        let definitions = try await engine.makeTurnToolCatalog(bridge: nil, settingsAvailable: false,
            speechAvailability: nil)
        let browser = try #require(definitions.first { $0.name == "browser" })
        #expect(browser.parameters["action"]?.enumValues == ["navigate", "read", "back", "screenshot"])
    }

    @Test func eachResolveReadsActualToolFlagButVisibilityNeverApprovesExecution() async throws {
        let current = CurrentTool()
        let engine = AgentLoopChatEngine(browserWriteActionsVisibleSource: {
            await MainActor.run { current.value?.writeActionsVisible ?? false }
        })
        // Reuse one engine across replacement, as the production Bridge does
        // when settings change. There is no network or page/file operation.
        for enabled in [false, true, false] {
            let session = BrowserSession(scopeID: UUID().uuidString, userAgent: nil)
            defer { session.close() }
            let tool = BrowserTool(session: session, writeActionsEnabled: enabled)
            current.value = tool
            let definitions = try await engine.makeTurnToolCatalog(bridge: nil, settingsAvailable: false,
                speechAvailability: nil)
            let browser = try #require(definitions.first { $0.name == "browser" })
            let expected = enabled
                ? ["navigate", "read", "back", "screenshot", "click", "type", "download", "upload"]
                : ["navigate", "read", "back", "screenshot"]
            #expect(browser.parameters["action"]?.enumValues == expected)
            if enabled { #expect(browser.parameters["path"] != nil) }
            for action in ["click", "type", "download", "upload"] {
                let input: [String: Any] = ["action": action, "selector": "#target",
                    "text": "synthetic", "path": "/synthetic/never-opened.bin"]
                let output = try await tool.execute(name: "browser", input: input)
                let response = try JSONDecoder().decode(BrowserToolResponse.self, from: Data(output.utf8))
                #expect(response.outcome == "denied")
                if !enabled { #expect(response.result == "Browser write actions are disabled.") }
                #expect(session.sideEffectGrants.pendingGrantCount == 0)
                #expect(session.webView.url == nil)
            }
            current.value = nil
        }
    }
}
