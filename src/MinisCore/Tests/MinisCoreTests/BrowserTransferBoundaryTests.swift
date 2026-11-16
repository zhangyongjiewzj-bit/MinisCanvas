import Foundation
import Testing
@testable import MinisCore

private actor TransferHuman: ApprovalDelegate {
    private(set) var requests: [ApprovalRequest] = []
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        requests.append(request)
        return ApprovalDecision(approved: true, confirmed: true, requestID: request.requestID,
                                bindingDigest: request.identityDigest, persistAllow: true, browserRiskConfirmed: true)
    }
}

@MainActor
struct BrowserTransferBoundaryTests {
    nonisolated private static func executeBrowser(_ tool: BrowserTool, input: [String: String]) async throws -> String {
        // Erase only after crossing isolation with a value containing Strings.
        try await tool.execute(name: "browser", input: input.mapValues { $0 as Any })
    }

    @MainActor private final class AccessLog { var capabilities: [String] = [] }
    @Test func missingFilePolicyCannotReadUploadMetadata() async throws {
        await #expect(throws: BrowserTransferError.self) {
            try await BrowserTransferFileIdentity.capture(path: "/synthetic/not-read", upload: true, access: nil)
        }
    }

    @Test func uploadAndDownloadDoNotShareApprovalCategory() {
        let upload = BrowserInteractionInput.parse(tool: "browser", input: ["action":"upload", "selector":"#file", "path":"/synthetic/input"])
        let download = BrowserInteractionInput.parse(tool: "browser", input: ["action":"download", "selector":"#link", "path":"/synthetic/output"])
        #expect(upload?.category == .upload)
        #expect(download?.category == .download)
        #expect(BrowserInteractionInput.parse(tool: "browser", input: ["action":"upload", "selector":"#file"]) == nil)
    }

    @Test func fileIdentityDetectsReplacementAndRefusesOverwrite() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try! FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("literal-input.txt")
        try Data("synthetic bytes".utf8).write(to: input)
        let log = AccessLog()
        let access: BrowserTransferFileAccess = { capability, url in
            #expect(url.path.hasPrefix(root.path + "/"))
            log.capabilities.append(capability)
        }
        let before = try await BrowserTransferFileIdentity.capture(path: input.path, upload: true, access: access)
        try FileManager.default.removeItem(at: input)
        try Data("replacement with a different size".utf8).write(to: input)
        let after = try await BrowserTransferFileIdentity.capture(path: input.path, upload: true, access: access)
        #expect(before != after)
        #expect(log.capabilities == ["file_read", "file_read"])
        await #expect(throws: BrowserTransferError.self) {
            try await BrowserTransferFileIdentity.capture(path: input.path, upload: false, access: access)
        }
        let output = root.appendingPathComponent("new-output.bin")
        let destination = try await BrowserTransferFileIdentity.capture(path: output.path, upload: false, access: access)
        #expect(destination.path == output.path)
    }

    @Test func approvalCannotEscapeThroughSymlink() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try! FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("literal.txt")
        let link = root.appendingPathComponent("alias.txt")
        try Data("synthetic".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        await #expect(throws: BrowserTransferError.self) {
            try await BrowserTransferFileIdentity.capture(path: link.path, upload: true, access: { _, _ in })
        }
    }

    @Test func unapprovedTransferCannotReachFileOrWebKitEffect() async throws {
        let session = BrowserSession(scopeID: "synthetic-transfer", userAgent: nil)
        session.requiresInteractionReview = true
        defer { session.close() }
        await #expect(throws: BrowserTransferError.self) {
            try await session.transfer(action: "download", selector: "#link")
        }
    }
    @Test func transfersIgnoreStoredSiteRulesAndNeverOfferPermanentApproval() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try! FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("literal.txt")
        try Data("synthetic only".utf8).write(to: file)
        let session = BrowserSession(scopeID: UUID().uuidString, userAgent: nil,
            navigationPolicy: BrowserNavigationPolicy(allowedDomains: ["one.invalid"]))
        defer { session.close() }
        session.requiresInteractionReview = true
        try await session.loadHTMLString("<html><body><form action='/upload' method='post' enctype='multipart/form-data'><input id='upload' name='file' type='file'></form><a id='download' href='/literal.bin'>download</a></body></html>", baseURL: URL(string: "https://one.invalid/synthetic")!)
        let rules = BrowserInteractionRuleStore()
        let human = TransferHuman()
        let access: BrowserTransferFileAccess = { _, url in
            #expect(url.path.hasPrefix(root.path + "/"))
        }
        for action in ["upload", "download"] {
            let category: BrowserInteractionCategory = action == "upload" ? .upload : .download
            _ = rules.confirm(origin: URL(string: "https://one.invalid")!, category: category, mode: .always)
            for _ in 0..<2 {
                let raw: [String: Any] = ["action": action, "selector": "#" + action,
                                         "path": action == "upload" ? file.path : root.appendingPathComponent("new.bin").path]
                let request = ApprovalGate().makeRequest(tool: "browser", input: raw)
                let decision = await BrowserTransferFileAccessContext.$current.withValue(access) {
                    await BrowserInteractionApproval.decide(request, session: session, rules: rules, delegate: human)
                }
                #expect(decision.approved)
            }
        }
        let requests = await human.requests
        #expect(requests.count == 4)
        #expect(requests.allSatisfy { $0.persistentAllowOffer == nil })
        #expect(rules.rules.count == 2) // seeded entries only, no new transfer grants
        #expect(session.sideEffectGrants.pendingGrantCount == 0) // decide cannot mint a receipt grant
    }

    @Test func hardLinkedUploadIsDenied() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try! FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("literal.txt")
        let alias = root.appendingPathComponent("hard-alias.txt")
        try Data("synthetic".utf8).write(to: file)
        try FileManager.default.linkItem(at: file, to: alias)
        for path in [file.path, alias.path] {
            await #expect(throws: BrowserTransferError.self) {
                try await BrowserTransferFileIdentity.capture(path: path, upload: true, access: { _, _ in })
            }
        }
    }

    @Test func uploadRequiresSupportedSameOriginForm() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try! FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("literal.txt")
        try Data("synthetic".utf8).write(to: file)
        let session = BrowserSession(scopeID: UUID().uuidString, userAgent: nil,
            navigationPolicy: BrowserNavigationPolicy(allowedDomains: ["one.invalid"]))
        defer { session.close() }
        let input = BrowserInteractionInput.parse(tool: "browser", input: ["action":"upload", "selector":"#upload", "path":file.path])!
        let field = "<input id='upload' name='file' type='file'>"
        let supported = "<form action='/upload' method='post' enctype='multipart/form-data'>"
        let rejected = [
            field,
            "<form action='https://two.invalid/upload' method='post' enctype='multipart/form-data'>" + field + "</form>",
            "<form action='/upload' method='get' enctype='multipart/form-data'>" + field + "</form>",
            "<form action='/upload' method='post'>" + field + "</form>",
            "<form action='/upload' method='post' enctype='multipart/form-data' target='_blank'>" + field + "</form>",
            supported + field + "<button formaction='https://two.invalid/upload'>send</button></form>",
            supported + field + "<button formmethod='get'>send</button></form>",
            supported + field + "<button formenctype='text/plain'>send</button></form>",
            supported + field + "<button formtarget='_blank'>send</button></form>",
            supported + "<input id='upload' name='action' type='file'></form>"
        ]
        for html in rejected {
            try await session.loadHTMLString(html, baseURL: URL(string: "https://one.invalid/synthetic")!)
            await #expect(throws: BrowserInteractionError.self) {
                try await session.interactionTarget(input, fileAccess: { _, _ in })
            }
        }
        try await session.loadHTMLString(supported + field + "<button>send</button></form>", baseURL: URL(string: "https://one.invalid/synthetic")!)
        let target = try await session.interactionTarget(input, fileAccess: { _, _ in })
        #expect(target.submissionURL == "https://one.invalid/upload")
        #expect(target.uploadFieldName == "file")
    }

    @Test func settingsOffRejectsFileInputClickUploadDownloadBeforeEffects() async throws {
        for action in ["click", "upload", "download"] {
            let session = BrowserSession(scopeID: "synthetic-off-" + action, userAgent: nil)
            defer { session.close() }
            let tool = BrowserTool(session: session, writeActionsEnabled: false)
            // This selector represents the file input; the OFF gate must reject
            // before it queries DOM, opens a picker or reads the nonexistent file.
            let raw: [String: String] = action == "click"
                ? ["action":action, "selector":"input[type=file]"]
                : ["action":action, "selector":"#target", "path":"/synthetic/never-opened.bin"]
            let receipt = ApprovalReceipt(requestID: "off-" + action, toolName: "browser", policy: .alwaysAsk,
                riskLevel: .high, inputSummary: ApprovalGate().makeRequest(tool: "browser", input: raw).inputSummary, status: .approved,
                inputDigest: try ComposerToolInput(raw).digest)
            #expect(tool.authorizeFromApprovalReceipt(receipt))
            let identity = BrowserSideEffectExecutionIdentity(callID: receipt.requestID, inputDigest: try ComposerToolInput(raw).digest)
            let result = try await BrowserTransferFileAccessContext.$current.withValue({ _, _ in
                Issue.record("OFF action reached file access")
            }) {
                try await BrowserSideEffectCallContext.$current.withValue(identity) {
                    try await Self.executeBrowser(tool, input: raw)
                }
            }
            let response = try JSONDecoder().decode(BrowserToolResponse.self, from: Data(result.utf8))
            #expect(response.outcome == "denied")
            #expect(response.result == "Browser write actions are disabled.")
            #expect(session.sideEffectGrants.pendingGrantCount == 1)
            #expect(session.webView.url == nil)
        }
    }

    @Test func sensitiveAndGitControlPathsAreDeniedBeforeFileAccess() async throws {
        let access: BrowserTransferFileAccess = { _, _ in Issue.record("sensitive source reached file policy") }
        for path in ["/synthetic/.env", "/synthetic/.git/config", "/synthetic/login.keychain-db", "/synthetic/private.key"] {
            await #expect(throws: BrowserTransferError.self) {
                try await BrowserTransferFileIdentity.capture(path: path, upload: true, access: access)
            }
        }
        #expect(!BrowserCapabilityGrant.readOnly.allows(action: "download"))
        #expect(!BrowserCapabilityGrant(capability: "browser.write", approvalReceipt: "").allows(action: "upload"))
        let explicit = BrowserCapabilityGrant(capability: "browser.write", approvalReceipt: "synthetic-receipt")
        #expect(explicit.allows(action: "download"))
        #expect(explicit.allows(action: "upload"))
    }

}
