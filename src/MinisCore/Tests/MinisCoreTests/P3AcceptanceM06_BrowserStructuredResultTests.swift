import Foundation
import Testing
@testable import MinisCore

struct P3AcceptanceM06BrowserStructuredResultTests {
    @Test("five completed non-read actions carry their real action and result")
    func completedActionsEncodeStructuredResults() throws {
        for action in ["navigate", "click", "type", "back", "screenshot"] {
            let actualResult = "completed-\(action)"
            let raw = try BrowserToolResponse.succeeded(
                action: action,
                scopeID: "fixture-scope",
                result: actualResult
            )
            let decoded = try JSONDecoder().decode(
                BrowserToolResponse.self, from: Data(raw.utf8)
            )
            #expect(decoded.outcome == "succeeded")
            #expect(decoded.action == action)
            #expect(decoded.scopeID == "fixture-scope")
            #expect(decoded.result == actualResult)
            #expect(decoded.untrustedPageContent == nil)
            #expect(decoded.refusalReason == nil)
            #expect(decoded.failureCode == nil)
        }
    }

    @Test("existing read and denial payloads remain decodable without a result")
    func legacyPayloadsKeepTheirShape() throws {
        let previousRead = #"{"action":"read","outcome":"read","scopeID":"fixture-scope","untrustedPageContent":"page text"}"#
        let read = try JSONDecoder().decode(
            BrowserToolResponse.self, from: Data(previousRead.utf8)
        )
        #expect(read.outcome == "read")
        #expect(read.untrustedPageContent == "page text")
        #expect(read.result == nil)
        #expect(read.failureCode == nil)
        #expect(try read.encoded() == previousRead)

        let previousDenial = #"{"action":"click","outcome":"denied","refusalReason":"write_authorization_required","scopeID":"fixture-scope"}"#
        let denial = try JSONDecoder().decode(
            BrowserToolResponse.self, from: Data(previousDenial.utf8)
        )
        #expect(denial.outcome == "denied")
        #expect(denial.refusalReason == "write_authorization_required")
        #expect(denial.result == nil)
        #expect(denial.failureCode == nil)
        #expect(try denial.encoded() == previousDenial)
    }

    @Test("empty browser history is a typed failed back result without page data")
    @MainActor
    func emptyHistoryBackKeepsActionAndReleasesLease() async throws {
        let session = BrowserSession(scopeID: "browser-empty-history")
        defer { session.close() }
        let tool = BrowserTool(session: session)

        let raw = try await tool.execute(
            name: BrowserTool.toolName,
            input: ["action": "back"]
        )
        let response = try JSONDecoder().decode(
            BrowserToolResponse.self, from: Data(raw.utf8)
        )
        #expect(response.outcome == "failed")
        #expect(response.action == "back")
        #expect(response.scopeID == session.scope.id)
        #expect(response.failureCode == "cannot_go_back")
        #expect(response.result == nil)
        #expect(response.untrustedPageContent == nil)
        #expect(response.refusalReason == nil)
        #expect(session.activeOperationCount == 0)
        #expect(session.currentURL() == nil)
    }

    @Test("unapproved click remains a denial, not an executed-action failure")
    @MainActor
    func clickWithoutGrantKeepsExistingRefusal() async throws {
        let session = BrowserSession(scopeID: "browser-click-denied")
        defer { session.close() }
        let tool = BrowserTool(session: session)

        let raw = try await tool.execute(
            name: BrowserTool.toolName,
            input: ["action": "click", "selector": "#submit"]
        )
        let response = try JSONDecoder().decode(
            BrowserToolResponse.self, from: Data(raw.utf8)
        )
        #expect(response.outcome == "denied")
        #expect(response.action == "click")
        #expect(response.refusalReason == "write_authorization_required")
        #expect(response.failureCode == nil)
        #expect(session.activeOperationCount == 0)
    }
}
