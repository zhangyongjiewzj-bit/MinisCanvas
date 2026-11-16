import Foundation
import Testing
@testable import MinisCore

/// No external page, network, uploads, downloads, or real file writes.
@MainActor
struct BrowserWriteDefaultOffTests {
    @Test func defaultOffDeniesClickAndTypeEvenWithMatchingApprovedReceipt() async throws {
        for action in ["click", "type"] {
            let session = BrowserSession(scopeID: "goal18-defaultoff-\(action)", userAgent: nil)
            let tool = BrowserTool(session: session)
            defer { session.close() }
            var input: [String: Any] = ["action": action, "selector": "#target"]
            if action == "type" { input["text"] = "synthetic" }
            let digest = try ComposerToolInput(input).digest
            let receipt = ApprovalReceipt(requestID: "goal18-\(action)", toolName: "browser",
                policy: .alwaysAsk, riskLevel: .high,
                inputSummary: "action: \(action), selector: #target", status: .approved, inputDigest: digest)
            #expect(tool.authorizeFromApprovalReceipt(receipt))
            let identity = BrowserSideEffectExecutionIdentity(callID: receipt.requestID, inputDigest: digest)
            let output = try await BrowserSideEffectCallContext.$current.withValue(identity) {
                // Keep the receipt input actor-local; transfer a fresh dictionary to execute.
                try await tool.execute(name: "browser", input: action == "type"
                    ? ["action": action, "selector": "#target", "text": "synthetic"]
                    : ["action": action, "selector": "#target"])
            }
            let response = try JSONDecoder().decode(BrowserToolResponse.self, from: Data(output.utf8))
            #expect(response.outcome == "denied")
            #expect(response.result == "Browser write actions are disabled.")
            #expect(session.sideEffectGrants.pendingGrantCount == 1)
            #expect(session.webView.url == nil)
        }
    }

    @Test func enabledFlagStaticCapabilityAndPublicContextDoNotReplaceHumanReceipt() async throws {
        let scope = BrowserSessionScope(id: "goal18-static-writer")
        let session = BrowserSession(userAgent: nil, scope: scope,
            writeAuthorization: BrowserWriteAuthorization(grantID: "old-static", scope: scope))
        let tool = BrowserTool(session: session, writeActionsEnabled: true)
        defer { session.close() }
        #expect(!session.isReadOnly)
        for action in ["click", "type"] {
            let input: [String: Any] = ["action": action, "selector": "#target", "text": "synthetic"]
            let identity = BrowserSideEffectExecutionIdentity(callID: "unapproved-\(action)",
                inputDigest: try ComposerToolInput(input).digest)
            let output = try await BrowserSideEffectCallContext.$current.withValue(identity) {
                try await tool.execute(name: "browser", input:
                    ["action": action, "selector": "#target", "text": "synthetic"])
            }
            let response = try JSONDecoder().decode(BrowserToolResponse.self, from: Data(output.utf8))
            #expect(response.outcome == "denied")
            #expect(session.sideEffectGrants.pendingGrantCount == 0)
            #expect(session.webView.url == nil)
        }
    }

    @Test func autoToolPolicyStillRequiresHumanAndTransferSchemaMatchesApprovedContract() {
        let gate = ApprovalGate(policyByTool: ["browser": .autoApprove])
        for action in ["click", "type", "upload", "download"] {
            #expect(gate.shouldAsk(tool: "browser", input: ["action": action]))
        }
        for action in ["upload", "download"] {
            #expect(throws: ToolExecutorError.self) {
                try BrowserTool.validate(name: "browser", input: ["action": action])
            }
        }
        let actions = BrowserTool.makeDefinition().parameters["action"]?.enumValues ?? []
        #expect(actions == ["navigate", "read", "back", "screenshot", "click", "type", "download", "upload"])
        let definition = BrowserTool.makeDefinition()
        #expect(definition.description.contains("仅支持无需登录的同站表单上传；需要登录或额外字段的页面会失败。"))
        #expect(definition.description.contains("不自动使用浏览器 Cookie，不回退到 DOM File 或文件选择器。"))
        #expect(definition.parameters["path"]?.description.contains("Exact absolute") == true)
        #expect(definition.parameters["path"]?.description.contains("existing output files are refused") == true)
    }

    @Test func cancelledCallNeverConsumesApprovalOrEntersEffect() async throws {
        let session = BrowserSession(scopeID: "goal18-cancelled", userAgent: nil)
        let tool = BrowserTool(session: session, writeActionsEnabled: true)
        defer { session.close() }
        let operation = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await tool.execute(name: "browser", input: ["action": "click", "selector": "#target"])
        }
        await #expect(throws: CancellationError.self) { _ = try await operation.value }
        #expect(session.sideEffectGrants.pendingGrantCount == 0)
        #expect(session.webView.url == nil)
    }
}
