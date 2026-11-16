import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-EXTJ actual selected-root capability declarations")
@MainActor
struct ExternalDeclaredCapabilitiesActualRootCurrentConsumerTests {
    @Test func actualReaderCapabilityDeclarationIsSeparateFromCurrentGrantValidity() async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "EXTJ-actual-roots")
        defer { try? profile.cleanupDisposableRoots() }
        let composition = ProductionOrchestrationDefaults.makeExternalSessionAuthorization(runtimeConsumer: nil)
        composition.configureExternalSourceRegistration(hostID: "owned-extj-host")
        #expect(composition.externalSourceSupport.map(\.kind) == [.codex, .claudeCode, .hermes])
        for kind in [ExternalSessionSourceKindV1.codex, .claudeCode, .hermes] {
            let initial = composition.sourceSupport(for: kind)
            #expect(initial.registeredSourceIDs.isEmpty)
            #expect(initial.declaredCapabilities.isEmpty)
            #expect(initial.missingPrerequisite == .adapterNotRegistered)
        }
        let readCapabilities: Set<ExternalSessionCapabilityV1> = [.readMetadata, .readMessages, .status]
        let controlCapabilities: Set<ExternalSessionCapabilityV1> = [.resume, .fork, .steer, .interrupt, .approval, .stream]
        for kind in [ExternalSessionSourceKindV1.codex, .claudeCode] {
            let root = profile.rootDirectory.appendingPathComponent("owned-" + kind.rawValue, isDirectory: true)
                .appendingPathComponent(kind == .codex ? "sessions" : "projects", isDirectory: true)
            let thread = kind == .codex ? "12345678-1234-1234-1234-123456789abc"
                                      : "87654321-4321-4321-4321-cba987654321"
            let folder = root.appendingPathComponent(kind == .codex ? "2026/10/01" : "-owned-project", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(kind == .codex
                ? "rollout-2026-10-01T00-00-00-\(thread).jsonl" : "\(thread).jsonl")
            let jsonl: String
            if kind == .codex {
                jsonl = """
                {"timestamp":"2026-10-01T00:00:00Z","type":"session_meta","payload":{"id":"\(thread)","cwd":"/synthetic/project","cli_version":"0.151.0"}}
                {"timestamp":"2026-10-01T00:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"owned-extj-question"}]}}
                """
            } else {
                jsonl = """
                {"type":"user","sessionId":"\(thread)","cwd":"/synthetic/project","version":"2.1.0","timestamp":"2026-10-01T00:00:00Z","message":{"role":"user","content":"owned-extj-question"}}
                """
            }
            let originalBytes = Data(jsonl.utf8)
            try originalBytes.write(to: file)
            let sourceID = try composition.registerSelectedReadRoot(kind: kind, rootURL: root)
            let pending = composition.sourceSupport(for: kind)
            #expect(pending.registeredSourceIDs == [sourceID])
            #expect(pending.missingPrerequisite == .readAuthorizationRequired)
            #expect(pending.declaredCapabilities.isEmpty)
            #expect(composition.adapter(for: sourceID)?.source.capabilities.isEmpty == true)
            #expect(composition.isReadRootPending(for: sourceID))
            let profileID = try #require(composition.supervisedProfileID(for: sourceID))
            let grant = try await composition.issueReadGrant(
                authorizationID: ExternalSessionAuthorizationID(rawValue: "owned-extj-" + kind.rawValue),
                sourceID: sourceID, profileID: profileID, target: .source(sourceID),
                scopes: [.metadata, .messages, .status], lifetime: 60)
            let adapter = try await composition.activateSelectedReadRoot(sourceID: sourceID, readGrant: grant)
            let active = composition.sourceSupport(for: kind)
            #expect(active.registeredSourceIDs == [sourceID])
            #expect(active.missingPrerequisite == .readOnlyAvailable)
            #expect(active.declaredCapabilities == readCapabilities)
            #expect(active.declaredCapabilities.isDisjoint(with: controlCapabilities))
            #expect(adapter.source.kind == kind)
            #expect(adapter.source.capabilities == readCapabilities)
            let threads = try await adapter.listThreads(query: .init(sourceID: sourceID, limit: 10), readGrant: grant)
            #expect(threads.threads.map(\.threadID.rawValue) == [thread])
            let page = try await adapter.read(request: .init(sourceID: sourceID,
                threadID: ExternalSessionThreadID(rawValue: thread), limit: 10), readGrant: grant)
            #expect(page.messageChunks.map(\.text).joined() == "owned-extj-question")
            let status = try await adapter.status(target: .init(sourceID: sourceID,
                threadID: ExternalSessionThreadID(rawValue: thread)), readGrant: grant)
            #expect(status.sourceID == sourceID)
            let returnedThread = try #require(status.threadID)
            #expect(returnedThread.rawValue == thread)
            #expect(try Data(contentsOf: file) == originalBytes)
            let hermes = composition.sourceSupport(for: .hermes)
            #expect(hermes.registeredSourceIDs.isEmpty)
            #expect(hermes.declaredCapabilities.isEmpty)
            #expect(hermes.missingPrerequisite == .adapterNotRegistered)
            _ = await composition.revoke(sourceID: sourceID, profileID: profileID)
            await #expect(throws: ExternalSessionAppAdapterError.grantRevoked) {
                _ = try await adapter.listThreads(query: .init(sourceID: sourceID, limit: 10), readGrant: grant)
            }
            let revoked = composition.sourceSupport(for: kind)
            // A registered reader's capability declaration is not a grant.
            // Revocation disconnects the actual runtime and forbids old reads;
            // it does not turn a supported reader into an unregistered source.
            #expect(revoked.registeredSourceIDs == [sourceID])
            #expect(revoked.declaredCapabilities == readCapabilities)
            #expect(revoked.declaredCapabilities.isDisjoint(with: controlCapabilities))
            #expect(revoked.missingPrerequisite == .readOnlyAvailable)
            #expect(adapter.runtimeSnapshot.state == .disconnected)
            #expect(adapter.runtimeSnapshot.ownerID == nil)
            let freshGrant = try await composition.issueReadGrant(
                authorizationID: ExternalSessionAuthorizationID(rawValue: "owned-extj-fresh-" + kind.rawValue),
                sourceID: sourceID, profileID: profileID, target: .source(sourceID),
                scopes: [.metadata, .messages, .status], lifetime: 60)
            #expect(freshGrant.revocationEpoch != grant.revocationEpoch)
            let fresh = try #require(composition.adapter(for: sourceID))
            #expect(fresh.source == adapter.source)
            #expect(fresh.runtimeSnapshot == adapter.runtimeSnapshot)
            let freshList = try await fresh.listThreads(query: .init(sourceID: sourceID, limit: 10), readGrant: freshGrant)
            #expect(freshList.threads.map(\.threadID.rawValue) == [thread])
            _ = await composition.revoke(sourceID: sourceID, profileID: profileID)
            #expect(try Data(contentsOf: file) == originalBytes)
            print("ACTUAL_EXTJ_ROOT kind=\(kind.rawValue) pending_no_caps=true actual_list_read_status=true read_only=true old_grant_refused=true fresh_legal_grant_read=true original_bytes_unchanged=true")
        }
        #expect(composition.sourceSupport(for: .hermes).declaredCapabilities.isEmpty)
        #expect(composition.externalSourceSupport.allSatisfy { $0.declaredCapabilities.isDisjoint(with: controlCapabilities) })
        print("ACTUAL_EXTJ_HERMES no_adapter=true no_claimed_capability=true")
    }
}
