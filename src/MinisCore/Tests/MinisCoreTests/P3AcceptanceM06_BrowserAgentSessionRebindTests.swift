import Foundation
import Testing
import WebKit
@testable import MinisCore

/// D-BROWSER-05 producer contract for an App-controlled conversation switch.
/// This suite creates scoped resources but never loads a page or opens a GUI.
/// Live cookie/cache isolation still requires the controlled WebKit journey.
@MainActor
struct P3AcceptanceM06BrowserAgentSessionRebindTests {
    private func scope(_ sessionID: String) -> BrowserSessionScope {
        BrowserSessionScope(
            surface: .agentBrowser,
            profile: "production-agent-m06",
            session: sessionID,
            workspace: "workspace-m06"
        )
    }

    @Test("switch closes A, rejects its captured tool and lease, and gives B a separate data store")
    func switchingAgentConversationRetiresOldResource() async throws {
        let first = BrowserTool(scope: scope("conversation-a"))
        let originalStore = first.session.webView.configuration.websiteDataStore
        let originalIdentity = first.session.identity
        let outstandingLease = try first.session.acquireOperationLease()

        // The App composition owner performs this exact order at the trusted
        // active-session transition. A previously captured value still points
        // to the closed A resource, never to B.
        first.session.close()
        let second = BrowserTool(scope: scope("conversation-b"))
        defer { second.session.close() }

        #expect(first.session.resourceState == .closed)
        #expect(!first.session.accepts(originalIdentity))
        #expect(first.session.scope.id != second.session.scope.id)
        #expect(second.session.webView.configuration.websiteDataStore !== originalStore)
        #expect(second.session.resourceState == .live)
        #expect(second.session.activeOperationCount == 0)

        await #expect(throws: BrowserError.resourceClosed) {
            _ = try await first.execute(name: BrowserTool.toolName, input: ["action": "read"])
        }
        first.session.releaseOperationLease(outstandingLease)
        #expect(second.session.activeOperationCount == 0)
        #expect(first.session.resourceState == .closed)
    }

    @Test("missing trusted session identity fails closed before any page action")
    func missingConversationCannotBecomeSharedAgentScope() async throws {
        let unverified = scope("")
        let tool = BrowserTool(scope: unverified)
        defer { tool.session.close() }

        #expect(!tool.session.scope.isValid)
        #expect(tool.session.scope.isIsolationUnverified)
        let raw = try await tool.execute(name: BrowserTool.toolName, input: ["action": "read"])
        let response = try JSONDecoder().decode(BrowserToolResponse.self, from: Data(raw.utf8))
        #expect(response.outcome == "denied")
        #expect(response.refusalReason == "invalid_scope")
        #expect(response.untrustedPageContent == nil)
    }
}
