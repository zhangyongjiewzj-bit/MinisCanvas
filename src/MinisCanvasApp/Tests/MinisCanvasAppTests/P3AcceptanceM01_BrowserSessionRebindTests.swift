import Testing
import Foundation
@testable import MinisCanvasApp
@testable import MinisCore

private struct BrowserRebindProbeProvider: LLMProvider, Sendable {
    let name = "browser-rebind-probe"
    var model = LLMModel(id: "browser-rebind-probe", displayName: "Probe", provider: "synthetic")

    nonisolated(nonsending) func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        LLMResponse(text: "unused", stopReason: "end_turn", usage: nil)
    }

    nonisolated(nonsending) func streamMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }
}

private enum BrowserRebindRouteProbe {
    // The test owns each call on its current actor. This helper does not send
    // the non-Sendable ToolExecutor existential to another executor.
    nonisolated(nonsending) static func execute(
        _ route: any ToolExecutor,
        context: AgentExecutionContextSnapshot? = nil
    ) async throws -> String {
        try await AgentExecutionContext.$current.withValue(context) {
            try await route.execute(name: "browser", input: [:])
        }
    }
}

@Suite("D-BROWSER-05 Agent browser trusted session rebind")
@MainActor
struct P3AcceptanceM01BrowserSessionRebindTests {
    private func isolatedDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("m01-browser05-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func sessionAtoBtoAClosesEachOldResourceAndKeepsWorkspace() throws {
        let root = try isolatedDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = BridgeStore()
        bridge.attachProductionServices(fileAccessAllowedRoot: root, sessionDirectory: root)
        let a = try #require(bridge.chat.activeSessionID)
        let workspace = bridge.chat.composerWorkspaceID
        let first = try #require(bridge.productionBrowserTool)
        let scopeA = BrowserSessionScope(surface: .agentBrowser, profile: "production",
                                         session: a.uuidString, workspace: workspace)
        #expect(first.session.scope == scopeA)
        #expect(first.session.scope.isolationKey != nil)

        _ = bridge.chat.applyNewSession()
        let b = try #require(bridge.chat.activeSessionID)
        let second = try #require(bridge.productionBrowserTool)
        #expect(b != a)
        #expect(first.session.resourceState == .closed)
        #expect(second.session !== first.session)
        #expect(second.session.scope == BrowserSessionScope(
            surface: .agentBrowser, profile: "production",
            session: b.uuidString, workspace: workspace
        ))

        #expect(bridge.chat.applySwitchSession(id: a))
        let third = try #require(bridge.productionBrowserTool)
        #expect(second.session.resourceState == .closed)
        #expect(third.session !== first.session)
        #expect(third.session.scope == scopeA)
        #expect(!first.session.reopenResource())
        third.session.close()
    }

    @Test func missingActiveSessionClosesOldAndDoesNotInheritItsScope() throws {
        let root = try isolatedDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = BridgeStore()
        bridge.attachProductionServices(fileAccessAllowedRoot: root, sessionDirectory: root)
        let originalID = try #require(bridge.chat.activeSessionID)
        let old = try #require(bridge.productionBrowserTool)

        // Archive requires a persisted source file; the welcome shell has none.
        bridge.chat.appendUser("synthetic browser session to archive")
        bridge.chat.archiveSession(id: originalID)
        #expect(bridge.chat.activeSessionID == nil)
        #expect(old.session.resourceState == .closed)
        #expect(bridge.productionBrowserTool == nil)

        _ = bridge.chat.applyNewSession()
        let newID = try #require(bridge.chat.activeSessionID)
        let rebound = try #require(bridge.productionBrowserTool)
        #expect(rebound.session.scope.isolationKey != nil)
        #expect(rebound.session.scope != old.session.scope)
        #expect(rebound.session.scope == BrowserSessionScope(
            surface: .agentBrowser, profile: "production",
            session: newID.uuidString, workspace: bridge.chat.composerWorkspaceID
        ))
        rebound.session.close()
    }

    @Test func persistedSessionReplacesBootstrapScopeDuringAttach() async throws {
        let root = try isolatedDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstBridge = BridgeStore()
        firstBridge.attachProductionServices(fileAccessAllowedRoot: root, sessionDirectory: root)
        firstBridge.chat.appendUser("isolated restored conversation")
        let savedID = try #require(firstBridge.chat.activeSessionID)
        let oldGate = try #require((firstBridge.chat.agentEngine as? AgentLoopChatEngine)?.loop.approvalGate)

        let reopened = BridgeStore()
        let bootstrapID = try #require(reopened.chat.activeSessionID)
        reopened.attachProductionServices(fileAccessAllowedRoot: root, sessionDirectory: root)
        #expect(reopened.chat.activeSessionID == savedID)
        #expect(savedID != bootstrapID)
        let tool = try #require(reopened.productionBrowserTool)
        #expect(tool.session.scope == BrowserSessionScope(
            surface: .agentBrowser, profile: "production",
            session: savedID.uuidString, workspace: reopened.chat.composerWorkspaceID
        ))
        #expect(firstBridge.chat.composerWorkspaceID != reopened.chat.composerWorkspaceID)
        let route = try #require(reopened.productionBuiltinToolExecutor?.browser)
        let staleContext = AgentExecutionContextSnapshot(
            provider: BrowserRebindProbeProvider(), approvalGate: oldGate,
            turnController: nil, currentConversationID: savedID.uuidString,
            makeChildBudget: nil, deadline: nil
        )
        do {
            _ = try await BrowserRebindRouteProbe.execute(route, context: staleContext)
            Issue.record("same session ID in another workspace must reject the old gate")
        } catch let error as ToolExecutorError {
            #expect(error == .resourceScopeInvalid)
        }
        firstBridge.productionBrowserTool?.session.close()
        tool.session.close()
    }

    @Test func oldTurnCannotDispatchThroughSharedBuiltinAfterSessionSwitch() async throws {
        let root = try isolatedDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = BridgeStore()
        bridge.attachProductionServices(fileAccessAllowedRoot: root, sessionDirectory: root)
        let a = try #require(bridge.chat.activeSessionID)
        let aGate = try #require((bridge.chat.agentEngine as? AgentLoopChatEngine)?.loop.approvalGate)
        _ = bridge.chat.applyNewSession()
        let b = try #require(bridge.chat.activeSessionID)
        let bGate = try #require((bridge.chat.agentEngine as? AgentLoopChatEngine)?.loop.approvalGate)
        let route = try #require(bridge.productionBuiltinToolExecutor?.browser)
        let provider = BrowserRebindProbeProvider()
        let staleContext = AgentExecutionContextSnapshot(
            provider: provider, approvalGate: aGate, turnController: nil,
            currentConversationID: a.uuidString, makeChildBudget: nil, deadline: nil
        )
        do {
            _ = try await BrowserRebindRouteProbe.execute(route, context: staleContext)
            Issue.record("old conversation must not reach the replacement browser")
        } catch let error as ToolExecutorError {
            #expect(error == .browserSessionUnavailable)
        }

        let currentContext = AgentExecutionContextSnapshot(
            provider: provider, approvalGate: bGate, turnController: nil,
            currentConversationID: b.uuidString, makeChildBudget: nil, deadline: nil
        )
        do {
            _ = try await BrowserRebindRouteProbe.execute(route, context: currentContext)
            Issue.record("the synthetic missing-action call must reach BrowserTool parsing")
        } catch let error as ToolExecutorError {
            #expect(error == .missingParameter("action"))
        }
        do {
            _ = try await BrowserRebindRouteProbe.execute(route)
            Issue.record("a missing turn context must fail closed")
        } catch let error as ToolExecutorError {
            #expect(error == .resourceScopeInvalid)
        }
        bridge.productionBrowserTool?.session.close()
    }

    @Test func newSessionGateBindsNewResourceWhileOldGateCannotRedeemIt() async throws {
        let root = try isolatedDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = BridgeStore()
        bridge.attachProductionServices(fileAccessAllowedRoot: root, sessionDirectory: root)
        let oldGate = try #require((bridge.chat.agentEngine as? AgentLoopChatEngine)?.loop.approvalGate)
        let oldTool = try #require(bridge.productionBrowserTool)
        _ = bridge.chat.applyNewSession()
        let newGate = try #require((bridge.chat.agentEngine as? AgentLoopChatEngine)?.loop.approvalGate)
        let newTool = try #require(bridge.productionBrowserTool)
        let digest = try ComposerToolInput(["action": "click", "selector": "#synthetic"]).digest
        let receipt = ApprovalReceipt(
            requestID: "browser05-new-session", toolName: "browser", policy: .autoApprove,
            riskLevel: .high, inputSummary: "action: click, selector: #synthetic", inputDigest: digest
        )
        do {
            try await oldGate.onApprovalReceipt?(receipt)
            Issue.record("the old turn gate must reject its retired resource")
        } catch {
            #expect(oldTool.session.resourceState == .closed)
            #expect(newTool.session.sideEffectGrants.pendingGrantCount == 0)
        }
        try await newGate.onApprovalReceipt?(receipt)
        #expect(newTool.session.sideEffectGrants.pendingGrantCount == 1)
        newTool.session.close()
    }

    @Test func returningToSessionARejectsTheOlderATurnGeneration() async throws {
        let root = try isolatedDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = BridgeStore()
        bridge.attachProductionServices(fileAccessAllowedRoot: root, sessionDirectory: root)
        let a = try #require(bridge.chat.activeSessionID)
        let oldGate = try #require((bridge.chat.agentEngine as? AgentLoopChatEngine)?.loop.approvalGate)
        let oldResource = try #require(bridge.productionBrowserTool)
        _ = bridge.chat.applyNewSession()
        #expect(bridge.chat.applySwitchSession(id: a))
        let newGate = try #require((bridge.chat.agentEngine as? AgentLoopChatEngine)?.loop.approvalGate)
        let newResource = try #require(bridge.productionBrowserTool)
        let route = try #require(bridge.productionBuiltinToolExecutor?.browser)
        #expect(oldResource.session.scope == newResource.session.scope)
        #expect(oldResource.session.resourceState == .closed)
        let staleContext = AgentExecutionContextSnapshot(
            provider: BrowserRebindProbeProvider(), approvalGate: oldGate,
            turnController: nil, currentConversationID: a.uuidString,
            makeChildBudget: nil, deadline: nil
        )
        do {
            _ = try await BrowserRebindRouteProbe.execute(route, context: staleContext)
            Issue.record("an old A turn cannot enter A's new resource after A-B-A")
        } catch let error as ToolExecutorError {
            #expect(error == .resourceScopeInvalid)
        }
        let currentContext = AgentExecutionContextSnapshot(
            provider: BrowserRebindProbeProvider(), approvalGate: newGate,
            turnController: nil, currentConversationID: a.uuidString,
            makeChildBudget: nil, deadline: nil
        )
        do {
            _ = try await BrowserRebindRouteProbe.execute(route, context: currentContext)
            Issue.record("current A reaches the browser parser without touching WebKit")
        } catch let error as ToolExecutorError {
            #expect(error == .missingParameter("action"))
        }
        newResource.session.close()
    }
}
