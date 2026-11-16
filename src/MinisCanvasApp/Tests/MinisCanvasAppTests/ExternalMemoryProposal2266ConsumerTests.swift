import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private struct Memory2266EventTransport: ExistingAgentSessionAdapter {
    let source: ExternalSessionSourceV1

    func listThreads(query: ExternalSessionThreadQueryV1, readGrant: ExternalSessionReadGrantV1) async throws -> ExternalSessionThreadPageV1 {
        ExternalSessionThreadPageV1(sourceID: source.sourceID, threads: [], observedCursor: query.cursor)
    }
    func read(request: ExternalSessionReadRequestV1, readGrant: ExternalSessionReadGrantV1) async throws -> ExternalSessionReadPageV1 {
        ExternalSessionReadPageV1(sourceID: source.sourceID, threadID: request.threadID, turns: [], events: [], observedCursor: request.cursor)
    }
    func status(target: ExternalSessionStatusTargetV1, readGrant: ExternalSessionReadGrantV1) async throws -> ExternalSessionStatusV1 {
        ExternalSessionStatusV1(sourceID: source.sourceID, threadID: target.threadID, turnID: target.turnID,
                                threadStatus: .active, observedCursor: .beginning)
    }
    func control(request: ExternalSessionControlRequestV1, controlGrant: ExternalSessionControlGrantV1) async throws -> ExternalSessionControlReceiptV1 {
        throw ExternalSessionAppAdapterError.operationNotGranted(request.operation)
    }
}

@Suite("D-MEMA registered external explicit memory proposal production consumer")
@MainActor
struct ExternalMemoryProposal2266ConsumerTests {
    private func frame(eventID: String, text: String = "合成事实：项目在星期二复盘") -> Data {
        Data("""
        {"schemaVersion":2,"type":"miniscanvas.memory.propose","sourceEventID":"\(eventID)","threadID":"thread-2266","turnID":"turn-2266","factText":"\(text)"}
        """.utf8)
    }

    @Test func registeredSourceNeedsSeparateScopeGrantThenPerFactApprovalAndRevocation() async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "MEMA-2266")
        defer { try? profile.cleanupDisposableRoots() }
        let sessions = profile.rootDirectory.appendingPathComponent("owned/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: profile.rootDirectory),
            envStore: EnvVarStore(directory: profile.rootDirectory),
            memoryStore: MemoryStore(directory: profile.rootDirectory),
            sessionStore: SessionStore(directory: profile.rootDirectory),
            logManager: LogManager(directory: profile.rootDirectory, ringCapacity: 10),
            mcpManager: MCPServerManager(fileURL: profile.rootDirectory.appendingPathComponent("mcps.json")),
            skillStore: SkillStore(skillsRoot: profile.rootDirectory.appendingPathComponent("skills"))
        )
        let scope = MemoryScope(sessionID: "session-2266", projectID: "project-2266")
        center.memoryScopeProvider = { scope }
        let composition = ProductionOrchestrationDefaults.makeExternalSessionAuthorization(runtimeConsumer: nil)
        composition.configureExternalSourceRegistration(hostID: "owned-host-2266")
        composition.configureMemoryProposalConsumer(center.memoryProposalConsumer)
        let sourceID = try composition.registerSelectedReadRoot(kind: .codex, rootURL: sessions)
        let profileID = try #require(composition.supervisedProfileID(for: sourceID))
        #expect(composition.externalMemoryCandidates.isEmpty)
        let statusGrant = try await composition.issueReadGrant(
            authorizationID: .init(rawValue: "status-2266"), sourceID: sourceID, profileID: profileID,
            target: .source(sourceID), scopes: [.metadata, .status], lifetime: 60
        )
        _ = try await composition.activateSelectedReadRoot(sourceID: sourceID, readGrant: statusGrant)
        #expect(composition.externalMemoryCandidates.isEmpty)
        // The registered source's event transport exercises the production
        // AppAdapter ledger/attempt/checkpoint gate; the fixture supplies no
        // external provider emitter and reads no user session material.
        let source = ExternalSessionSourceV1(
            sourceID: sourceID, kind: .codex, adapterVersion: "owned-2266",
            profileID: profileID, hostID: "owned-host-2266",
            capabilities: [.readMetadata, .status, .stream], authState: .authorized
        )
        let adapter = composition.makeAdapter(implementation: Memory2266EventTransport(source: source))
        let candidate = try #require(composition.externalMemoryCandidates.first)
        #expect(try !composition.memoryCandidateSubmissionEnabled(for: candidate))
        let eventGrant = try await composition.issueReadGrant(
            authorizationID: .init(rawValue: "events-2266"), sourceID: sourceID, profileID: profileID,
            target: .thread(.init(rawValue: "thread-2266")), scopes: [.events], lifetime: 60
        )
        let connected = try await adapter.connect(readGrant: statusGrant)
        let owner = try #require(connected.ownerID)
        #expect(adapter.beginExternalAttempt(correlationID: "run-2266", attemptID: "attempt-2266", ownerID: owner))
        func deliver(_ eventID: String, sequence: UInt64, text: String = "合成事实：项目在星期二复盘") async throws -> MemoryProposalEnvelope {
            try await composition.consumeMemoryProposalToolFrame(
                frame(eventID: eventID, text: text), from: candidate,
                correlationID: "run-2266", attemptID: "attempt-2266", ownerID: owner,
                connectionGeneration: connected.generation, sequence: sequence,
                sourceCursor: .init(rawValue: "owned-\(sequence)"), readGrant: eventGrant
            )
        }
        await #expect(throws: ExternalMemoryProposalError.self) { _ = try await deliver("before-grant", sequence: 1) }
        #expect(try center.memoryProposalConsumer.envelopes().isEmpty)
        #expect(throws: ExternalMemoryProposalError.scopeMismatch) {
            _ = try composition.setMemoryCandidateSubmission(for: candidate, within: nil, enabled: true)
        }
        _ = try composition.setMemoryCandidateSubmission(for: candidate, within: scope, enabled: true)
        #expect(throws: ExternalMemoryProposalError.scopeMismatch) {
            _ = try composition.setMemoryCandidateSubmission(
                for: candidate, within: MemoryScope(sessionID: "foreign", projectID: "project-2266"), enabled: true
            )
        }
        await #expect(throws: ExternalMemoryProposalError.self) {
            _ = try await composition.consumeMemoryProposalToolFrame(
                frame(eventID: "wrong-owner"), from: candidate,
                correlationID: "run-2266", attemptID: "attempt-2266", ownerID: "foreign-owner",
                connectionGeneration: connected.generation, sequence: 1,
                sourceCursor: .init(rawValue: "foreign"), readGrant: eventGrant
            )
        }
        #expect(try center.memoryProposalConsumer.envelopes().isEmpty)
        #expect(throws: ExternalMemoryProposalError.invalidEvent) {
            _ = try ExternalMemoryProposalToolEventV2.decode(Data("{\"type\":\"message\",\"text\":\"remember me\"}".utf8))
        }
        let approved = try await deliver("fact-one", sequence: 1)
        #expect(approved.state == .proposed)
        #expect(approved.writeProvenance?.actorID == "registered:\(sourceID.rawValue)")
        #expect(approved.writeProvenance?.sourceID == candidate.memorySourceID)
        #expect(MemoryProposalReviewSourcePresentation(envelope: approved).sourceLine.contains(candidate.memorySourceID))
        #expect(try center.pendingMemoryProposals().map(\.proposal.proposalID) == [approved.proposal.proposalID])
        #expect(try center.memoryStore.loadFacts().isEmpty)
        try center.approveDisplayedMemoryProposal(approved)
        #expect(try center.memoryStore.loadFacts().count == 1)
        let pending = try await deliver("fact-two", sequence: 2, text: "合成事实：第二条单独审批")
        #expect(pending.state == .proposed)
        // Settings can now have no selected memory scope while the old source
        // remains granted. Turning it off must still revoke that old grant.
        center.memoryScopeProvider = { nil }
        _ = try composition.setMemoryCandidateSubmission(
            for: candidate, within: center.memoryScopeProvider?(), enabled: false
        )
        center.memoryScopeProvider = { scope }
        #expect(try !composition.memoryCandidateSubmissionEnabled(for: candidate))
        #expect(composition.boundMemoryScope(for: candidate) == nil)
        #expect(try center.pendingMemoryProposals().isEmpty)
        #expect(throws: MemoryProposalConsumerError.self) { try center.approveDisplayedMemoryProposal(pending) }
        await #expect(throws: ExternalMemoryProposalError.self) { _ = try await deliver("fact-three", sequence: 3) }
        _ = try composition.setMemoryCandidateSubmission(for: candidate, within: scope, enabled: true)
        #expect(throws: MemoryProposalConsumerError.self) { try center.approveDisplayedMemoryProposal(pending) }
        #expect(try center.memoryStore.loadFacts().count == 1)
        #expect(try center.memoryProposalConsumer.envelopes().count == 2)
    }
}
