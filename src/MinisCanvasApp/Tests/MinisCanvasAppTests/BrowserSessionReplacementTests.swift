import Testing
import Foundation
@testable import MinisCanvasApp
@testable import MinisCore

private actor ReplacementApprovalDelegate: ApprovalDelegate {
    private var request: ApprovalRequest?
    private var continuation: CheckedContinuation<ApprovalDecision, Never>?

    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        self.request = request
        print("BROWSER2_OBSERVATION delegate.requestRaised=true")
        return await withCheckedContinuation { continuation = $0 }
    }

    func requestRaised() -> Bool { request != nil }

    func waitUntilRequested() async {
        while request == nil { await Task.yield() }
    }

    func approve() {
        guard let request else { return }
        continuation?.resume(returning: ApprovalDecision(
            approved: true,
            confirmed: true,
            requestID: request.requestID,
            bindingDigest: request.identityDigest
        ))
        continuation = nil
    }
}


// Scripted provider stays inside the nonisolated run helper; only the real
// AgentLoop result and ledger leave it. It never fabricates a browser response.
private final class TransferTerminalProvider: LLMProvider {
    let name = "Synthetic transfer terminal"
    var model: LLMModel = .claudeHaiku45
    var capabilities: Set<ProviderCapability> { [.tools] }
    private var responses: [String]
    init(envelope: String) { responses = [envelope, "synthetic transfer complete"] }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        LLMResponse(text: responses.isEmpty ? "" : responses.removeFirst(), stopReason: nil, usage: nil)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt,
                              maxTokens: maxTokens, temperature: temperature)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private actor TransferTerminalApprovalDelegate: ApprovalDelegate {
    private(set) var requests: [ApprovalRequest] = []
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        requests.append(request)
        return ApprovalDecision(approved: true, confirmed: true,
            requestID: request.requestID, bindingDigest: request.identityDigest)
    }
}

/// D-BROWSER-08 (P3-BROWSER-01 / BROWSER-08): replacing the production
/// browser resource (settings-driven re-attach inside one process) must not
/// leave a ghost WebView behind and must destroy the previous session's
/// unspent approval grants so a result or a side effect can never be written
/// into the wrong (retired) session.
@MainActor
@Suite("QODER-DEV-BROWSER-POLICY-007 生产浏览器会话替换生命周期")
struct BrowserSessionReplacementTests {


    @Test("真实传输经生产审批与AgentLoop终态持久化", arguments: ["download", "upload"])
    func transferToolLoopPersistsApprovedSuccess(action: String) async throws {
        try await verifyTransferToolLoopPersistsApprovedSuccess(action: action, useSystemAlias: false)
    }

    @Test("下载暂存经系统路径别名仍可提交")
    func downloadCommitsUnderPrivateSystemAlias() async throws {
        try await verifyTransferToolLoopPersistsApprovedSuccess(action: "download", useSystemAlias: true)
    }

    private func verifyTransferToolLoopPersistsApprovedSuccess(action: String, useSystemAlias: Bool) async throws {
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.path
        let temporaryPath = temporary.hasPrefix("/private/var/folders/")
            ? temporary
            : "/private" + temporary
        if useSystemAlias {
            try #require(temporaryPath.hasPrefix("/private/var/folders/"))
        }
        let directory = useSystemAlias ? URL(fileURLWithPath: temporaryPath, isDirectory: true)
            : FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let root = directory.appendingPathComponent("BrowserTransferTerminal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        if useSystemAlias {
            let probe = root.appendingPathComponent("alias-probe.bin")
            try Data([1]).write(to: probe)
            defer { try? FileManager.default.removeItem(at: probe) }
            let resolved = probe.resolvingSymlinksInPath()
            try #require(resolved.path == String(probe.path.dropFirst("/private".count)),
                         "fixture must reproduce Foundation’s system alias")
            try #require(try Data(contentsOf: resolved) == Data([1]))
        }
        let file = root.appendingPathComponent(action == "upload" ? "input.txt" : "output.bin")
        let bytes = Data("Goal22 synthetic transfer bytes".utf8)
        if action == "upload" { try bytes.write(to: file) }
        let server = try BrowserLocalHTTPFixture()
        defer { server.stop() }
        try await server.waitUntilReady()
        let delegate = TransferTerminalApprovalDelegate()
        let bridge = BridgeStore()
        await bridge.attachProductionServices(fileAccessAllowedRoot: root, sessionDirectory: root,
            approvalDelegateOverride: delegate,
            policyDefaults: ProductionPolicyDefaults(networkDomains: ["127.0.0.1"])).value
        let tool = try #require(bridge.productionBrowserTool)
        defer { tool.session.close() }
        #expect(tool.writeActionsVisible)
        let builtin = try #require(bridge.productionBuiltinToolExecutor)
        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let gate = try #require(engine.loop.approvalGate)
        let sessionID = try #require(tool.session.scope.isolationKey?.session)
        try await tool.session.loadHTMLString("""
            <html><body><a id='download' href='/transfer.bin'>download</a>
            <form action='/upload' method='post' enctype='multipart/form-data'>
            <input id='upload' name='file' type='file'></form></body></html>
            """, baseURL: server.url(path: "/synthetic"))
        let originalIdentity = tool.session.identity
        var stagingPath: String?
        // Same exact synthetic file grant as the existing production receipt
        // fixture, including one bound native download staging sibling.
        let access: BrowserTransferFileAccess = { operation, url in
            guard operation == (action == "upload" ? "file_read" : "file_write"),
                  // Foundation 的路径标准化会去掉已存在文件开头的 /private，别名场景下只核对原样路径。
                  useSystemAlias || (url.standardizedFileURL.path == url.path
                      && url.resolvingSymlinksInPath().path == url.path) else {
                throw BrowserTransferError.filePermissionRequired
            }
            if url.path == file.path { return }
            let prefix = ".browser-transfer-"
            let name = url.lastPathComponent
            guard action == "download", url.deletingLastPathComponent().path == root.path,
                  name.hasPrefix(prefix),
                  let uuid = UUID(uuidString: String(name.dropFirst(prefix.count))),
                  name == prefix + uuid.uuidString,
                  stagingPath == nil || stagingPath == url.path else {
                throw BrowserTransferError.filePermissionRequired
            }
            stagingPath = url.path
        }
        let ledgerURL = root.appendingPathComponent("terminal-facts.json")
        let ledger = try ToolExecutionFactLedger(persistenceURL: ledgerURL)
        let result = try await BrowserTransferFileAccessContext.$current.withValue(access) {
            try await Self.runTransferLoop(action: action, path: file.path,
                sessionID: sessionID, gate: gate, executor: builtin, ledger: ledger)
        }
        #expect(tool.session.identity == originalIdentity)
        #expect(bridge.productionBrowserTool?.session === tool.session)
        #expect(result.toolCallsExecuted == 1)
        #expect(result.messages.last?.content == "synthetic transfer complete")
        #expect(await delegate.requests.count == 1)
        #expect(await delegate.requests.allSatisfy { $0.requiresApproval && $0.persistentAllowOffer == nil })
        #expect(server.requestPaths.contains(action == "download" ? "/transfer.bin" : "/upload"))
        #expect(try Data(contentsOf: file) == bytes)
        #expect(ledger.facts.count == 1)
        #expect(result.toolExecutionFacts == ledger.facts)
        let fact = try #require(ledger.facts.first)
        #expect(fact.status == .succeeded)
        let detail = try #require(fact.browserDetail)
        #expect(detail.action == action && detail.outcome == "succeeded")
        #expect(detail.failureCode == nil && detail.refusalReason == nil && detail.readCharacterCount == nil)
        let encoded = try JSONEncoder().encode(fact)
        #expect(try JSONDecoder().decode(ToolExecutionFact.self, from: encoded) == fact)
        let reopened = try ToolExecutionFactLedger(persistenceURL: ledgerURL)
        #expect(reopened.facts == [fact])
        #expect(!detail.resultPreview.contains(file.path))
        // Unknown actions remain closed in BOTH changed whitelist consumers.
        // This negative mutation starts from the actual executed detail.
        #expect(BrowserToolExecutionDetail(action: "teleport", outcome: "succeeded") == nil)
        var forged = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(detail)) as? [String: Any])
        forged["action"] = "teleport"
        let forgedBytes = try JSONSerialization.data(withJSONObject: forged)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(BrowserToolExecutionDetail.self, from: forgedBytes)
        }
    }

    nonisolated private static func runTransferLoop(action: String, path: String, sessionID: String,
        gate: ApprovalGate, executor: any ToolExecutor, ledger: ToolExecutionFactLedger) async throws -> AgentLoopResult {
        let callID = "transfer-terminal-" + action
        let object: [String: Any] = ["tool_calls": [["id": callID, "name": "browser",
            "input": ["action": action, "selector": "#" + action, "path": path]]]]
        let envelope = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        let provider = TransferTerminalProvider(envelope: envelope)
        let identity = AgentExecutionIdentity(turn: AgentTurnIdentity(sessionID: sessionID, turnID: 1,
            messageID: callID), operationID: callID, attempt: 1)
        let loop = AgentLoop(maxIterations: 2, approvalGate: gate, turnController: TurnController(),
            timeout: 30, toolExecutionFactLedger: ledger)
        return try await loop.run(messages: [LLMMessage(role: .user, content: "synthetic local transfer")],
            systemPrompt: nil, provider: provider, toolExecutor: executor,
            tools: [BrowserTool.makeDefinition()], currentConversationID: sessionID,
            parentIdentitySeed: ParentRuntimeIdentitySeed(sessionID: sessionID,
                conversationID: sessionID, taskID: callID, actorID: "synthetic-test"),
            executionIdentity: identity)
    }

    @Test("审批挂起时会话替换，迟到回执不能授权新旧目标")
    func lateApprovalCannotRedeemAfterProductionReplacement() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserReplacementApproval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let delegate = ReplacementApprovalDelegate()
        let bridge = BridgeStore()
        await bridge.attachProductionServices(
            fileAccessAllowedRoot: root,
            sessionDirectory: root,
            approvalDelegateOverride: delegate,
            policyDefaults: ProductionPolicyDefaults(networkDomains: ["one.invalid"])
        ).value
        print("BROWSER2_OBSERVATION firstAttach.after")
        let oldTool = try #require(bridge.productionBrowserTool)
        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let oldGate = try #require(engine.loop.approvalGate)
        // Existing BrowserInteractionApprovalTests.page contract: literal HTML
        // with a synthetic HTTPS base URL; no resource or navigation is fetched.
        try await oldTool.session.loadHTMLString(
            "<html><body><button id=\"submit\" type=\"button\">synthetic</button></body></html>",
            baseURL: URL(string: "https://one.invalid/synthetic")!
        )
        // The production target reader must accept the loaded document before
        // holding approval; this neither creates nor redeems an approval grant.
        _ = try await oldTool.session.interactionTarget(
            BrowserInteractionInput(action: "click", selector: "#submit")
        )
        let schemeClass: String
        switch oldTool.session.webView.url?.scheme?.lowercased() {
        case nil: schemeClass = "nil"
        case "http": schemeClass = "http"
        case "https": schemeClass = "https"
        case "about": schemeClass = "about"
        default: schemeClass = "other"
        }
        print("BROWSER2_OBSERVATION webView.scheme=\(schemeClass) action=click selector=synthetic-submit callID=late-click")
        let approval = Task {
            print("BROWSER2_OBSERVATION gate.start")
            defer { print("BROWSER2_OBSERVATION gate.end") }
            do {
                let decision = try await oldGate.gate(
                tool: "browser",
                input: ["action": "click", "selector": "#submit"],
                callID: "late-click"
                )
                print("BROWSER2_OBSERVATION gate.result approved=\(decision.approved) confirmed=\(decision.confirmed)")
                return decision
            } catch {
                let errorClass: String
                if let approvalError = error as? ApprovalError {
                    switch approvalError {
                    case .denied: errorClass = "denied"
                    case .expired: errorClass = "expired"
                    case .revoked: errorClass = "revoked"
                    case .cancelled: errorClass = "cancelled"
                    case .bindingMismatch: errorClass = "bindingMismatch"
                    case .missingIdentity: errorClass = "missingIdentity"
                    case .alreadyConsumed: errorClass = "alreadyConsumed"
                    }
                } else {
                    errorClass = error is CancellationError ? "CancellationError" : "otherError"
                }
                print("BROWSER2_OBSERVATION gate.error=\(errorClass)")
                throw error
            }
        }
        print("BROWSER2_OBSERVATION waitUntilRequested.before requestRaised=\(await delegate.requestRaised())")
        await delegate.waitUntilRequested()
        print("BROWSER2_OBSERVATION waitUntilRequested.after requestRaised=\(await delegate.requestRaised())")
        print("BROWSER2_OBSERVATION secondAttach.before")
        await bridge.attachProductionServices(
            fileAccessAllowedRoot: root,
            sessionDirectory: root,
            approvalDelegateOverride: delegate,
            policyDefaults: ProductionPolicyDefaults(networkDomains: ["one.invalid"])
        ).value
        print("BROWSER2_OBSERVATION secondAttach.after")
        let newTool = try #require(bridge.productionBrowserTool)
        await delegate.approve()
        print("BROWSER2_OBSERVATION approval.value.before requestRaised=\(await delegate.requestRaised())")
        await #expect(throws: (any Error).self) { _ = try await approval.value }
        print("BROWSER2_OBSERVATION approval.value.after")
        #expect(oldTool.session.resourceState == .closed)
        #expect(oldTool.session.sideEffectGrants.pendingGrantCount == 0)
        #expect(newTool.session.sideEffectGrants.pendingGrantCount == 0)
        newTool.session.close()
    }

    @Test("生产审批回执抵达原会话并由真实传输消费一次", arguments: ["download", "upload"])
    func productionTransferReceiptReachesOriginalSession(action: String) async throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("BrowserTransfer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try BrowserLocalHTTPFixture()
        defer { server.stop() }
        try await server.waitUntilReady()
        let file = root.appendingPathComponent(action == "upload" ? "input.txt" : "output.bin")
        if action == "upload" { try Data("Goal22 synthetic upload".utf8).write(to: file) }
        let delegate = ReplacementApprovalDelegate()
        let bridge = BridgeStore()
        await bridge.attachProductionServices(fileAccessAllowedRoot: root, sessionDirectory: root,
            approvalDelegateOverride: delegate,
            policyDefaults: ProductionPolicyDefaults(networkDomains: ["127.0.0.1"])).value
        let tool = try #require(bridge.productionBrowserTool)
        defer { tool.session.close() }
        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let gate = try #require(engine.loop.approvalGate)
        try await tool.session.loadHTMLString("""
            <html><body><a id='download' href='/transfer.bin'>download</a>
            <form action='/upload' method='post' enctype='multipart/form-data'>
            <input id='upload' name='file' type='file'></form></body></html>
            """, baseURL: server.url(path: "/synthetic"))
        let identity = BrowserSideEffectExecutionIdentity(callID: "production-" + action,
            inputDigest: try ComposerToolInput([
                "action": action, "selector": "#" + action, "path": file.path
            ]).digest)
        // Only synthetic file admission is supplied here. Browser approval,
        // receipt sink, DOM review and transfer are the production composition.
        var boundStagingPath: String?
        let access: BrowserTransferFileAccess = { operation, url in
            let expectedOperation = action == "upload" ? "file_read" : "file_write"
            guard operation == expectedOperation,
                  url.standardizedFileURL.path == url.path,
                  url.resolvingSymlinksInPath().path == url.path else {
                throw BrowserTransferError.filePermissionRequired
            }
            if url.path == file.path { return }
            // Native download writes one private sibling before committing
            // the exact destination. Bind its first canonical UUID once.
            let prefix = ".browser-transfer-"
            let name = url.lastPathComponent
            guard action == "download", operation == "file_write",
                  url.deletingLastPathComponent().path == root.path,
                  name.hasPrefix(prefix),
                  let uuid = UUID(uuidString: String(name.dropFirst(prefix.count))),
                  name == prefix + uuid.uuidString,
                  boundStagingPath == nil || boundStagingPath == url.path else {
                throw BrowserTransferError.filePermissionRequired
            }
            boundStagingPath = url.path
        }
        await #expect(throws: BrowserTransferError.self) {
            try await access(action == "upload" ? "file_write" : "file_read", file)
        }
        await #expect(throws: BrowserTransferError.self) {
            try await access("file_write", root.appendingPathComponent(".browser-transfer-not-a-uuid"))
        }
        await #expect(throws: BrowserTransferError.self) {
            try await access("file_write", root.deletingLastPathComponent()
                .appendingPathComponent(".browser-transfer-" + UUID().uuidString))
        }
        let approval = Task { @MainActor in
            try await BrowserTransferFileAccessContext.$current.withValue(access) {
                // Transfer a fresh dictionary to the gate. The digest above
                // freezes equal Sendable scalar values without retaining Any.
                try await gate.gate(tool: "browser", input: [
                    "action": action, "selector": "#" + action, "path": file.path
                ], callID: identity.callID)
            }
        }
        defer { approval.cancel() }
        for _ in 0..<250 {
            if await delegate.requestRaised() { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(await delegate.requestRaised(), "production gate must reach the human transfer review")
        await delegate.approve()
        let decision = try await approval.value
        #expect(decision.approved && decision.confirmed)
        #expect(BrowserSideEffectCallContext.$current.withValue(identity) {
            tool.session.hasApprovedSideEffectGrant(for: action)
        })
        let foreign = BrowserSideEffectExecutionIdentity(callID: "foreign-" + action,
            inputDigest: identity.inputDigest)
        #expect(!BrowserSideEffectCallContext.$current.withValue(foreign) {
            tool.session.hasApprovedSideEffectGrant(for: action)
        })
        let changed = BrowserSideEffectExecutionIdentity(callID: identity.callID,
            inputDigest: try ComposerToolInput(["action": action, "selector": "#other", "path": file.path]).digest)
        #expect(!BrowserSideEffectCallContext.$current.withValue(changed) {
            tool.session.hasApprovedSideEffectGrant(for: action)
        })
        let nativeResult = try await BrowserTransferFileAccessContext.$current.withValue(access) {
            try await BrowserSideEffectCallContext.$current.withValue(identity) {
                try await tool.session.transfer(action: action, selector: "#" + action)
            }
        }
        print("GOAL22_TRANSFER_NATIVE_RESULT action=\(action) approved=\(decision.approved) result=\(nativeResult)")
        #expect(!nativeResult.isEmpty)
        #expect(tool.session.sideEffectGrants.pendingGrantCount == 0)
        if action == "download" {
            let staging = try #require(boundStagingPath)
            let bytesMatch = try Data(contentsOf: file) == Data("Goal22 synthetic transfer bytes".utf8)
            #expect(bytesMatch)
            print("GOAL22_TRANSFER_EFFECT action=download ownedBytesMatch=\(bytesMatch) stagingBound=true")
            await #expect(throws: BrowserTransferError.self) {
                try await access("file_write", root.appendingPathComponent(".browser-transfer-" + UUID().uuidString))
            }
            // The same staging identity remains admissible for the native
            // destination and commit callbacks; another UUID never replaces it.
            try await access("file_write", URL(fileURLWithPath: staging))
        } else {
            let received = server.requestPaths.contains("/upload")
            let sourceUnchanged = try Data(contentsOf: file) == Data("Goal22 synthetic upload".utf8)
            #expect(received)
            #expect(sourceUnchanged)
            #expect(boundStagingPath == nil)
            print("GOAL22_TRANSFER_EFFECT action=upload requestObserved=\(received) sourceUnchanged=\(sourceUnchanged)")
        }
        await #expect(throws: (any Error).self) {
            try await BrowserTransferFileAccessContext.$current.withValue(access) {
                try await BrowserSideEffectCallContext.$current.withValue(identity) {
                    _ = try await tool.session.transfer(action: action, selector: "#" + action)
                }
            }
        }
    }

    @Test("重新装配关闭旧会话、保留独立新会话且旧授权失效")
    func reattachClosesPreviousSessionAndItsGrants() async throws {
        let bridge = BridgeStore()
        await bridge.attachProductionServices(browserSettings: .default).value
        guard let firstTool = bridge.productionBrowserTool else {
            Issue.record("attach 后应存在生产 BrowserTool")
            return
        }
        let oldSession = firstTool.session
        let inputDigest = try ComposerToolInput(["action": "click", "selector": "#submit"]).digest
        let identity = BrowserSideEffectExecutionIdentity(
            callID: "reattach-grant-1", inputDigest: inputDigest
        )
        // An approved one-shot grant exists on the old session before swap.
        let receipt = ApprovalReceipt(
            requestID: "reattach-grant-1",
            toolName: "browser",
            policy: .autoApprove,
            riskLevel: .high,
            inputSummary: "action: click, selector: #submit",
            inputDigest: inputDigest
        )
        #expect(firstTool.authorizeFromApprovalReceipt(receipt))
        #expect(BrowserSideEffectCallContext.$current.withValue(identity) {
            oldSession.hasApprovedSideEffectGrant(for: "click")
        })

        await bridge.attachProductionServices(browserSettings: .default).value
        guard let secondTool = bridge.productionBrowserTool else {
            Issue.record("重装配后应存在新的生产 BrowserTool")
            return
        }
        // The previous resource is closed: detached WebView, no reopen, and
        // its unspent grant is destroyed.
        #expect(secondTool.session !== oldSession)
        #expect(oldSession.resourceState == .closed)
        #expect(!BrowserSideEffectCallContext.$current.withValue(identity) {
            oldSession.hasApprovedSideEffectGrant(for: "click")
        })
        #expect(!oldSession.reopenResource())
        // A receipt minted while the old session was current can never be
        // redeemed into it again after retirement.
        #expect(!firstTool.authorizeFromApprovalReceipt(
            ApprovalReceipt(
                requestID: "reattach-grant-2",
                toolName: "browser",
                policy: .autoApprove,
                riskLevel: .high,
                inputSummary: "action: click, selector: #submit",
                inputDigest: inputDigest
            )
        ))
        // The replacement session is live and independently scoped.
        #expect(secondTool.session.resourceState == .live)
        // Same trusted conversation/workspace keeps its tuple, while the
        // resource and grant generation are replaced on every re-attach.
        #expect(secondTool.session.scope == oldSession.scope)
        #expect(secondTool.session !== oldSession)
        secondTool.session.close()
    }
}
