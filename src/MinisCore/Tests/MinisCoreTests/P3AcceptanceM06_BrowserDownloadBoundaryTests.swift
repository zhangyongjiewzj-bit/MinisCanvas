import Foundation
import Testing
@testable import MinisCore

struct P3AcceptanceM06BrowserDownloadBoundaryTests {
    @Test("restricted transfers require approval and exact selector/path parameters")
    func restrictedTransferActionsRequireSelectorAndPath() throws {
        for action in ["download", "upload"] {
            #expect(BrowserSideEffectPolicy.inputRequiresApproval(
                tool: BrowserTool.toolName, input: ["action": action]
            ))
            #expect(throws: ToolExecutorError.invalidParameter("selector/path")) {
                try BrowserTool.validate(
                    name: BrowserTool.toolName,
                    input: ["action": action]
                )
            }
            let incompleteInputs: [[String: Any]] = [
                ["action": action, "selector": "#transfer"],
                ["action": action, "path": "/synthetic/transfer.bin"]
            ]
            for incomplete in incompleteInputs {
                #expect(throws: ToolExecutorError.invalidParameter("selector/path")) {
                    try BrowserTool.validate(name: BrowserTool.toolName, input: incomplete)
                }
            }
            try BrowserTool.validate(name: BrowserTool.toolName, input: [
                "action": action, "selector": "#transfer", "path": "/synthetic/transfer.bin"
            ])
        }
    }

    @Test("download requests fail closed before becoming a browser file write")
    func explicitDownloadAndNonDisplayableResponsesAreDenied() {
        let denied = BrowserNavigationPolicy.Decision.deny(.downloadNotAuthorized)
        #expect(BrowserSession.downloadDecision(actionRequestsDownload: true) == denied)
        #expect(BrowserSession.downloadDecision(responseCanShowMIMEType: false) == denied)
        #expect(BrowserSession.downloadDecision(
            contentDisposition: " ATTACHMENT ; filename=report.txt"
        ) == denied)
    }

    @Test("ordinary inline page responses remain eligible for URL policy")
    func inlineDisplayableResponseDoesNotGainAWriteGrant() {
        #expect(BrowserSession.downloadDecision(
            responseCanShowMIMEType: true,
            contentDisposition: "inline; filename=page.html"
        ) == .allow)
        #expect(BrowserSession.downloadDecision() == .allow)
    }

    @Test("download refusal keeps a structured policy reason")
    func downloadDenialEncodesAStableReason() throws {
        let raw = try BrowserToolResponse.navigationDenied(
            action: "navigate",
            scopeID: "fixture-scope",
            denial: .downloadNotAuthorized
        )
        let decoded = try JSONDecoder().decode(
            BrowserToolResponse.self, from: Data(raw.utf8)
        )
        #expect(decoded.outcome == "denied")
        #expect(decoded.action == "navigate")
        #expect(decoded.refusalReason == "navigation_denied:download_not_authorized")
        #expect(decoded.result == nil)
    }
}
