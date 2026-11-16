import Foundation
import Testing
@testable import MinisCore

private actor PinnedWebApproval: ApprovalDelegate {
    let approves: Bool
    let persistAllow: Bool
    private var calls = 0
    private var latestRequest: ApprovalRequest?
    init(_ approves: Bool, persistAllow: Bool) {
        self.approves = approves
        self.persistAllow = persistAllow
    }
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        calls += 1
        latestRequest = request
        if let context = ApprovalPresentationContext.current,
           let presented = context.makeFact(for: request, stage: .presented) {
            context.eventSink(presented)
        }
        return .init(approved: approves, reason: "synthetic", confirmed: approves,
            requestID: request.requestID, bindingDigest: request.identityDigest, persistAllow: persistAllow)
    }
    func count() -> Int { calls }
    func lastRequest() -> ApprovalRequest? { latestRequest }
}

private final class PinnedWebApprovalEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var facts: [ApprovalLifecycleFact] = []
    func record(_ fact: ApprovalLifecycleFact) { lock.withLock { facts.append(fact) } }
    var snapshot: [ApprovalLifecycleFact] { lock.withLock { facts } }
}

private actor PinnedWebEffects {
    private var pins: [[String]] = []
    private var resolves = 0
    private var replayDenied = false
    func resolve(_ endpoint: WebFetchEndpoint, privateAddress: Bool) throws -> [WebFetchNumericAddress] {
        resolves += 1
        return [try WebFetchNumericAddress(privateAddress ? "127.0.0.1" : "93.184.216.34")]
    }
    func load(_ invocation: WebFetchPinnedCurlInvocation, url: URL, redirect: Bool,
              backendOutput: Data? = nil) async throws -> WebFetchHop {
        pins.append(invocation.arguments)
        if let permit = WebFetchPinnedCallContext.current {
            do { _ = try await permit.load(url) }
            catch { replayDenied = true }
        }
        if let backendOutput {
            return try WebFetchPinnedBackend.parseCurlOutput(backendOutput,
                url: url, pinnedAddress: invocation.pinnedAddress)
        }
        let next = redirect && url.host == "first.example"
        let response = HTTPURLResponse(url: url, statusCode: next ? 302 : 200, httpVersion: "HTTP/1.1",
            headerFields: next ? ["Location": "https://second.example/page"] : ["Content-Type": "text/plain; charset=utf-8"])!
        return WebFetchHop(response: response, body: Data("synthetic content".utf8))
    }
    func counts() -> (Int, Int, Bool) { (pins.count, resolves, replayDenied) }
}

@Suite("H05 B real Composer Policy Transport source consumer")
struct WebFetchPinnedConsumerTests {
    private struct Fixture {
        let approval: PinnedWebApproval
        let effects: PinnedWebEffects
        let composer: ComposerPolicyEnforcedToolExecutor
        let goal: GoalEnvelope
        init(approves: Bool = true, privateAddress: Bool = false, redirect: Bool = false,
             route: WebFetchPinnedRoute = .directConfirmed, knownSource: Bool = true, hookDenies: Bool = false,
             ruleStore: PersistentApprovalRuleStore? = nil, backendOutput: Data? = nil,
             persistAllow: Bool = false, configuredDomains: Set<String> = [],
             redirectRoute: WebFetchPinnedRoute? = nil, mode: ComposerTaskMode = .auto,
             bypassConfirmed: Bool = false) throws {
            approval = PinnedWebApproval(approves, persistAllow: persistAllow)
            effects = PinnedWebEffects()
            let effects = effects
            let configuration = WebFetchPinnedConfiguration(
                provenance: knownSource ? .actualLocalSettingsConfiguredCeiling(domains: configuredDomains) : .unknown,
                configuredDomains: configuredDomains, externalNetworkAllowed: true,
                routeProvider: { url in url.host == "second.example" ? redirectRoute ?? route : route },
                operations: .init(resolve: { endpoint in
                    try await effects.resolve(endpoint, privateAddress: privateAddress)
                }, load: { invocation, url in
                    try await effects.load(invocation, url: url, redirect: redirect, backendOutput: backendOutput)
                }))
            let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            let owner = BuiltinToolExecutor(allowedRoot: root,
                webFetch: WebFetchTransport(allowedDomains: configuredDomains, pinnedConfiguration: configuration))
            owner.registerToolNames([WebFetchToolContract.toolName])
            let now = Date()
            goal = GoalEnvelope(scopeID: "project", allowedCapabilities: [WebFetchToolContract.toolName],
                networkDomains: configuredDomains, budget: 10, deadline: now.addingTimeInterval(60), autonomyLevel: .l3)
            let lease = AutonomyLease(goalID: goal.goalID, scopeID: goal.scopeID,
                issuedAt: now, expiresAt: goal.deadline)
            let snapshot = ComposerSubmissionSnapshot(mode: mode, approvalScope: .session,
                effort: .standard, sessionID: "session", turnID: 1, taskID: "task", attemptID: "attempt",
                messageID: "message", workspaceID: "project", createdAt: now,
                policyRevision: "revision", grantEpoch: "epoch", bypassModeConfirmed: bypassConfirmed, autonomyCeiling: .l3)
            let facts = ComposerPolicyFactSource(knownCapabilities: [WebFetchToolContract.toolName],
                grantedCapabilities: [WebFetchToolContract.toolName], allowedWriteRoots: [root.path],
                workspaceID: "project", revision: "revision", grantEpoch: "epoch", leaseID: "lease",
                expiresAt: goal.deadline, autonomyCeiling: .l3)
            composer = ComposerPolicyEnforcedToolExecutor(
                base: PolicyEnforcedToolExecutor(base: owner, goal: goal, lease: lease),
                controller: ComposerAuthorizationController(snapshot: snapshot, facts: facts,
                    grants: ComposerApprovalGrantStore(persistentRules: ruleStore ?? PersistentApprovalRuleStore())),
                approvalGate: ApprovalGate(policy: .autoApprove, delegate: approval),
                hookHandler: { invocation in
                    ComposerHookResult(verdict: hookDenies ? .deny : .allow,
                        invocationIdentityDigest: invocation.identityDigest,
                        reason: hookDenies ? "synthetic explicit Hook deny" : nil,
                        hasDecision: hookDenies)
                })
        }
    }

    @Test func freshHumanPermitPinsOnceAndDoesNotMutateParentGoalOrLeakScope() async throws {
        let f = try Fixture()
        _ = try await f.composer.execute(callID: "first", name: "web_fetch", input: ["url": "https://first.example/page"])
        #expect(await f.approval.count() == 1)
        #expect(await f.effects.counts().0 == 1)
        #expect(await f.effects.counts().2)
        #expect(f.goal.networkDomains.isEmpty)
        #expect(WebFetchPinnedCallContext.current == nil)
        // Session consent cannot authorize a new host.
        _ = try await f.composer.execute(callID: "second", name: "web_fetch", input: ["url": "https://second.example/page"])
        #expect(await f.approval.count() == 2)
    }

    @Test func confirmedBypassPinsPublicHostWithoutPromptAndKeepsRouteFloors() async throws {
        let input = ["url": "https://first.example/page"]
        let publicRoute = try Fixture(mode: .bypassPermission, bypassConfirmed: true)
        _ = try await publicRoute.composer.execute(callID: "public", name: "web_fetch", input: input)
        #expect(await publicRoute.approval.count() == 0)
        #expect(await publicRoute.effects.counts().0 == 1)
        #expect(await publicRoute.effects.counts().1 == 1)
        #expect(await publicRoute.effects.counts().2)

        let privateRoute = try Fixture(privateAddress: true, mode: .bypassPermission, bypassConfirmed: true)
        await #expect(throws: WebFetchPinnedError.nonPublicDestination) {
            _ = try await privateRoute.composer.execute(callID: "private", name: "web_fetch", input: input)
        }
        #expect(await privateRoute.approval.count() == 0)
        #expect(await privateRoute.effects.counts().0 == 0)
        #expect(await privateRoute.effects.counts().1 == 1)

        let proxyRoute = try Fixture(route: .proxyRequiresExistingRoute, mode: .bypassPermission, bypassConfirmed: true)
        await #expect(throws: (any Error).self) {
            _ = try await proxyRoute.composer.execute(callID: "proxy", name: "web_fetch", input: input)
        }
        #expect(await proxyRoute.approval.count() == 0)
        #expect(await proxyRoute.effects.counts().0 == 0)
        #expect(await proxyRoute.effects.counts().1 == 0)

        let unconfirmed = try Fixture(mode: .bypassPermission)
        await #expect(throws: ComposerAuthorizationError.bypassConfirmationRequired) {
            _ = try await unconfirmed.composer.execute(callID: "unconfirmed", name: "web_fetch", input: input)
        }
        #expect(await unconfirmed.approval.count() == 0)
        #expect(await unconfirmed.effects.counts().0 == 0)
        #expect(await unconfirmed.effects.counts().1 == 0)
    }

    @Test func deniedApprovalDoesNotResolveOrConnect() async throws {
        let f = try Fixture(approves: false)
        await #expect(throws: (any Error).self) {
            _ = try await f.composer.execute(callID: "deny", name: "web_fetch", input: ["url": "https://first.example/page"])
        }
        #expect(await f.effects.counts().0 == 0)
        #expect(await f.effects.counts().1 == 0)
    }

    @Test func exactCallHookDenyWinsBeforeHumanReceiptDNSAndConnection() async throws {
        let f = try Fixture(hookDenies: true)
        await #expect(throws: (any Error).self) {
            _ = try await f.composer.execute(callID: "hook-deny", name: "web_fetch", input: ["url": "https://first.example/page"])
        }
        #expect(await f.approval.count() == 0)
        #expect(await f.effects.counts().0 == 0)
        #expect(await f.effects.counts().1 == 0)
    }

    @Test func privateDNSAndUnsupportedRouteCannotReachBackend() async throws {
        for (privateAddress, route) in [(true, WebFetchPinnedRoute.directConfirmed), (false, .proxyRequiresExistingRoute), (false, .unknown)] {
            let f = try Fixture(privateAddress: privateAddress, route: route)
            await #expect(throws: (any Error).self) {
                _ = try await f.composer.execute(callID: "blocked", name: "web_fetch", input: ["url": "https://first.example/page"])
            }
            #expect(await f.effects.counts().0 == 0)
        }
    }

    @Test func unsupportedRouteExplainsHowToUseAllowedWebsites() async throws {
        let f = try Fixture(route: .proxyRequiresExistingRoute)
        do {
            _ = try await f.composer.execute(callID: "route-guidance", name: "web_fetch",
                input: ["url": "https://first.example/page"])
            Issue.record("A proxy-required route must remain blocked")
        } catch {
            #expect(error as? WebFetchPinnedError == .unsupportedRoute)
            let reason = error.localizedDescription
            #expect(reason.contains("代理"))
            #expect(reason.contains("允许访问的网站"))
            #expect(!reason.contains("未发出请求"))
            #expect(!reason.contains("first.example"))
            #expect(!reason.contains("MinisCore."))
        }
        #expect(await f.effects.counts().0 == 0)
        #expect(await f.effects.counts().1 == 0)
    }

    @Test func unsupportedRouteDoesNotAskForPointlessHumanApproval() async throws {
        let f = try Fixture(route: .proxyRequiresExistingRoute)
        await #expect(throws: WebFetchPinnedError.unsupportedRoute) {
            _ = try await f.composer.execute(callID: "route-preflight", name: "web_fetch",
                input: ["url": "https://first.example/page"])
        }
        #expect(await f.approval.count() == 0)
        #expect(await f.effects.counts().0 == 0)
        #expect(await f.effects.counts().1 == 0)
    }

    @Test func preauthorizationDistinguishesProxyFromUnknownWithoutAskingOrResolving() async throws {
        let routes: [(WebFetchPinnedRoute, String)] = [
            (.proxyRequiresExistingRoute, "检测到代理"),
            (.unknown, "无法确认直连路径"),
        ]
        var reasons: [String] = []
        for (route, expected) in routes {
            let f = try Fixture(route: route)
            do {
                _ = try await f.composer.authorizeExecution(callID: "route-description",
                    name: WebFetchToolContract.toolName, input: ["url": "https://first.example/page"])
                Issue.record("An unconfirmed direct route must not be authorized")
            } catch {
                let reason = error.localizedDescription
                reasons.append(reason)
                #expect(reason.contains(expected))
                #expect(!reason.contains("first.example"))
            }
            #expect(await f.approval.count() == 0)
            #expect(await f.effects.counts().0 == 0)
            #expect(await f.effects.counts().1 == 0)
        }
        #expect(Set(reasons).count == 2)
    }

    @Test func productionPreauthorizationKeepsApprovalWhenPrivateDNSBlocksDispatch() async throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("web-failure-rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rules = PersistentApprovalRuleStore(fileURL: directory.appendingPathComponent("rules.json"))
        let ruleCount = rules.allRules().count
        let f = try Fixture(privateAddress: true, ruleStore: rules, persistAllow: true)
        let callID = "private-address-approval-lifecycle"
        let observed = PinnedWebApprovalEvents()
        let identity = AgentExecutionIdentity(turn: AgentTurnIdentity(
            sessionID: "session", turnID: 1, messageID: "message"),
            operationID: "web-lifecycle-operation", attempt: 1)
        let presentation = ApprovalPresentationContext(compositeKey: ToolExecutionCompositeKey(
            sessionID: "session", turnID: 1, messageID: "message",
            operationID: identity.operationID, attemptID: "attempt", attemptNumber: 1, toolCallID: callID),
            executionIdentity: identity, toolName: WebFetchToolContract.toolName,
            eventSink: { observed.record($0) })
        do {
            _ = try await ApprovalPresentationContext.$current.withValue(presentation) {
                try await f.composer.authorizeExecution(callID: callID, name: "web_fetch",
                    input: ["url": "https://first.example/page"])
            }
            Issue.record("A non-public destination must remain blocked after human approval")
        } catch {
            try #require(error as? WebFetchPinnedError == .nonPublicDestination)
        }
        try #require(await f.approval.count() == 1)
        try #require(await f.effects.counts().1 == 1)
        try #require(await f.effects.counts().0 == 0)
        let facts = observed.snapshot
        let request = try #require(await f.approval.lastRequest())
        try #require(request.persistentAllowOffer?.isAvailable == true)
        try #require(facts.count == 2)
        try #require(facts.allSatisfy { $0.requestID == request.requestID
            && $0.identityDigest == request.identityDigest })
        try #require(facts.allSatisfy { $0.compositeKey.toolCallID == callID
            && $0.executionIdentity == identity && $0.toolName == WebFetchToolContract.toolName })
        #expect(facts.map(\.stage) == [.presented, .authorityApproved])
        let consumer = ToolLifecycleConsumer()
        try #require(await consumer.ingestApprovalLifecycleFact(facts[0]))
        let waiting = try #require(consumer.readOnlyProjection.approvalHistory.first)
        #expect(waiting.status == .waiting)
        #expect(waiting.receiptID == request.requestID)
        #expect(await consumer.ingestApprovalLifecycleFact(facts[1]))
        #expect(!(await consumer.ingestApprovalLifecycleFact(facts[1])))
        let settled = try #require(consumer.readOnlyProjection.approvalHistory.first)
        #expect(settled.id == waiting.id)
        #expect(settled.approvalDecision == .approved)
        #expect(consumer.readOnlyProjection.approvalHistory.count == 1)
        await #expect(throws: WebFetchPinnedError.nonPublicDestination) {
            _ = try await ApprovalPresentationContext.$current.withValue(presentation) {
                try await f.composer.authorizeExecution(callID: "private-address-approval-retry",
                    name: "web_fetch", input: ["url": "https://first.example/page"])
            }
        }
        #expect(observed.snapshot == facts, "The original call identity cannot observe the retry")
        #expect(await f.approval.count() == 2)
        #expect(await f.effects.counts().1 == 2)
        #expect(await f.effects.counts().0 == 0)
        #expect(rules.allRules().count == ruleCount)
    }

    @Test func privateDestinationExplainsTheRefusalWithoutChangingApprovalOrder() async throws {
        let f = try Fixture(privateAddress: true)
        do {
            _ = try await f.composer.execute(callID: "private-address-guidance", name: "web_fetch",
                input: ["url": "https://first.example/page"])
            Issue.record("A non-public destination must remain blocked")
        } catch {
            #expect(error as? WebFetchPinnedError == .nonPublicDestination)
            let reason = error.localizedDescription
            #expect(reason.contains("非公网") || reason.lowercased().contains("non-public"))
            #expect(!reason.contains("MinisCore."))
        }
        #expect(await f.approval.count() == 1)
        #expect(await f.effects.counts().1 == 1)
        #expect(await f.effects.counts().0 == 0)
    }

    @Test(arguments: [false, true])
    func backendConnectionFailureIsReadableWithoutLeakingTransportDetails(wrongAddressRecord: Bool) async throws {
        let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nPRIVATE_BACKEND_DETAIL_MARKER"
        let raw = reply + (wrongAddressRecord ? "\n\u{1}MINIS_REMOTE_IP:93.184.216.35\u{2}\n" : "")
        let f = try Fixture(backendOutput: Data(raw.utf8))
        do {
            _ = try await f.composer.execute(callID: "connection-failure-guidance", name: "web_fetch",
                input: ["url": "https://first.example/page"])
            Issue.record("Unverified backend connection metadata must remain blocked")
        } catch {
            #expect(error as? WebFetchPinnedError == .connectionFailed)
            let reason = error.localizedDescription
            #expect(reason.contains("连接") || reason.lowercased().contains("connection"))
            #expect(!reason.contains("MinisCore."))
            #expect(!reason.contains("PRIVATE_BACKEND_DETAIL_MARKER"))
        }
        #expect(await f.approval.count() == 1)
        #expect(await f.effects.counts().0 == 1)
    }

    @Test func foreignRedirectRequiresItsOwnHumanApprovalAndPin() async throws {
        let f = try Fixture(redirect: true)
        _ = try await f.composer.execute(callID: "redirect", name: "web_fetch", input: ["url": "https://first.example/page"])
        #expect(await f.approval.count() == 2)
        #expect(await f.effects.counts().0 == 2)
    }

    @Test func configuredRedirectHostDoesNotMoveDynamicEntryToSystemRoute() async throws {
        let f = try Fixture(redirect: true, configuredDomains: ["second.example"],
                            redirectRoute: .proxyRequiresExistingRoute)
        do {
            _ = try await f.composer.execute(callID: "redirect-proxy", name: "web_fetch",
                input: ["url": "https://first.example/page"])
            Issue.record("A pinned redirect must still require a direct route")
        } catch {
            let reason = error.localizedDescription
            #expect(reason.contains("起始域名"))
            #expect(reason.contains("跳转域名"))
            #expect(!reason.contains("未发出请求"))
            #expect(!reason.contains("first.example") && !reason.contains("second.example"))
        }
        #expect(await f.approval.count() == 1)
        #expect(await f.effects.counts().0 == 1)
    }

    @Test func existingCurrentProjectRuleSkipsOnlyPromptAndRemovalRestoresPrompt() async throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("h05-rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ruleURL = directory.appendingPathComponent("rules.json")
        let rules = PersistentApprovalRuleStore(fileURL: ruleURL)
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let project = try #require(PersistentApprovalRuleMatcher.projectScope(roots: [root]))
        #expect(rules.add(PersistentApprovalRule(projectKey: project.key, projectRoots: project.roots,
            kind: .webHost, capability: "web_fetch", pattern: "first.example")))
        let reloadedRules = PersistentApprovalRuleStore(fileURL: ruleURL)
        let f = try Fixture(ruleStore: reloadedRules)
        _ = try await f.composer.execute(callID: "remembered", name: "web_fetch", input: ["url": "https://first.example/page"])
        #expect(await f.approval.count() == 0)
        #expect(await f.effects.counts().0 == 1)
        _ = try await f.composer.execute(callID: "other-host", name: "web_fetch",
            input: ["url": "https://second.example/page"])
        #expect(await f.approval.count() == 1)
        #expect(await f.effects.counts().0 == 2)
        #expect(reloadedRules.removeAll())
        _ = try await f.composer.execute(callID: "removed", name: "web_fetch", input: ["url": "https://first.example/page"])
        #expect(await f.approval.count() == 2)
        #expect(f.goal.networkDomains.isEmpty)
    }

    @Test func unknownConfigurationCannotAcquireDynamicDomain() async throws {
        let f = try Fixture(knownSource: false)
        await #expect(throws: (any Error).self) {
            _ = try await f.composer.execute(callID: "unknown", name: "web_fetch", input: ["url": "https://first.example/page"])
        }
        #expect(await f.effects.counts().0 == 0)
        #expect(await f.effects.counts().1 == 0)
    }
}
