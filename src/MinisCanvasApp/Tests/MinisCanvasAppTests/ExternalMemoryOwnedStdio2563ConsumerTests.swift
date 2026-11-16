import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-MEMA actual owned Codex stdio memory producer")
@MainActor
struct ExternalMemoryOwnedStdio2563ConsumerTests {
    @Test func explicitNewThreadEmitsPendingOnlyAndRevocationRejectsLateCall() async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "MEMA-2563")
        defer { try? profile.cleanupDisposableRoots() }
        let home = profile.rootDirectory.appendingPathComponent("owned-codex-home", isDirectory: true)
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        let workspace = profile.rootDirectory.appendingPathComponent("owned-workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let server = profile.rootDirectory.appendingPathComponent("owned-codex-server.py")
        try Data(#"""
        #!/usr/bin/python3 -IS
        import json, os, sys, time
        home = os.environ['CODEX_HOME']
        thread = 'owned-thread-2563'
        turn = 'owned-turn-2563'
        def mark(name, value='1'):
            with open(os.path.join(home, name), 'w') as f: f.write(value)
        def wait(name):
            while not os.path.exists(os.path.join(home, name)): time.sleep(0.01)
        def call(rid, callid, text, turnid=turn, tool='memory_propose'):
            print(json.dumps({'id':rid,'method':'item/tool/call','params':{
                'threadId':thread,'turnId':turnid,'callId':callid,
                'namespace':'miniscanvas','tool':tool,'arguments':{'factText':text}}}), flush=True)
        for line in sys.stdin:
            req = json.loads(line)
            method, rid = req.get('method'), req.get('id')
            if method == 'initialized': continue
            if method == 'initialize':
                if req.get('params',{}).get('capabilities',{}).get('experimentalApi') is not True:
                    mark('bad-initialize')
                    print(json.dumps({'id':rid,'error':{'code':-32602,'message':'experimentalApi required'}}),flush=True)
                    continue
                mark('experimental-enabled')
                result = {'userAgent':'miniscanvas/0.151.0 (synthetic)','platformFamily':'unix','platformOs':'macos'}
                print(json.dumps({'id':rid,'result':result}),flush=True)
            elif method == 'thread/start':
                tools = req.get('params',{}).get('dynamicTools',[])
                valid = len(tools)==1 and tools[0].get('name')=='miniscanvas' and any(
                    t.get('name')=='memory_propose' and t.get('inputSchema',{}).get('required')==['factText']
                    for t in tools[0].get('tools',[]))
                if not valid:
                    mark('bad-tool-registration')
                    print(json.dumps({'id':rid,'error':{'code':-32602,'message':'dynamicTools required'}}),flush=True)
                    continue
                mark('registered-new-thread')
                print(json.dumps({'id':rid,'result':{'thread':{'id':thread}}}),flush=True)
            elif method == 'turn/start':
                if req.get('params',{}).get('threadId') != thread:
                    mark('wrong-thread-start')
                    print(json.dumps({'id':rid,'error':{'code':-32602,'message':'thread mismatch'}}),flush=True)
                    continue
                print(json.dumps({'id':rid,'result':{'turn':{'id':turn,'status':'inProgress','items':[]}}}),flush=True)
                print(json.dumps({'method':'turn/started','params':{'threadId':thread,'turn':{'id':turn}}}),flush=True)
                wait('send-first')
                call(90,'foreign-call','合成外来事实',turnid='foreign-turn')
            elif method is None and rid == 90:
                mark('foreign-result', str(req.get('result',{}).get('success')))
                call(100,'call-one','合成事实：受控外部任务第一条')
            elif method is None and rid == 100:
                mark('first-result', str(req.get('result',{}).get('success')))
                wait('send-second')
                call(101,'call-two','合成事实：第二条待审后撤权')
            elif method is None and rid == 101:
                mark('second-result', str(req.get('result',{}).get('success')))
                wait('send-late')
                call(102,'call-late','合成事实：撤权后的迟到调用')
            elif method is None and rid == 102:
                mark('late-result', str(req.get('result',{}).get('success')))
                wait('send-after-regrant')
                call(103,'call-after-regrant','合成事实：旧回合不能借新授权')
            elif method is None and rid == 103:
                mark('after-regrant-result', str(req.get('result',{}).get('success')))
                wait('allow-exit')
        """#.utf8).write(to: server)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: server.path)

        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: profile.rootDirectory),
            envStore: EnvVarStore(directory: profile.rootDirectory),
            memoryStore: MemoryStore(directory: profile.rootDirectory),
            sessionStore: SessionStore(directory: profile.rootDirectory),
            logManager: LogManager(directory: profile.rootDirectory, ringCapacity: 10),
            mcpManager: MCPServerManager(fileURL: profile.rootDirectory.appendingPathComponent("mcps.json")),
            skillStore: SkillStore(skillsRoot: profile.rootDirectory.appendingPathComponent("skills"))
        )
        let scope = MemoryScope(sessionID: "owned-session-2563", projectID: "owned-project-2563")
        center.memoryScopeProvider = { scope }
        let composition = ProductionOrchestrationDefaults.makeExternalSessionAuthorization(runtimeConsumer: nil)
        composition.configureExternalSourceRegistration(hostID: "owned-host-2563")
        composition.configureMemoryProposalConsumer(center.memoryProposalConsumer)
        try composition.configureControlledMemoryRuntimeDirectory(
            profile.rootDirectory.appendingPathComponent("owned-runtime", isDirectory: true)
        )
        let sourceID = try composition.registerSelectedReadRoot(kind: .codex, rootURL: sessions)
        let profileID = try #require(composition.supervisedProfileID(for: sourceID))
        let statusGrant = try await composition.issueReadGrant(
            authorizationID: .init(rawValue: "status-2563"), sourceID: sourceID,
            profileID: profileID, target: .source(sourceID),
            scopes: [.metadata, .status], lifetime: 60
        )
        _ = try await composition.activateSelectedReadRoot(sourceID: sourceID, readGrant: statusGrant)
        #expect(composition.externalMemoryCandidates.isEmpty)
        await #expect(throws: ExternalMemoryProposalError.self) {
            _ = try await composition.startOwnedCodexMemoryTask(
                sourceID: sourceID, workspaceURL: workspace, prompt: "合成任务", eventsReadGrant: statusGrant
            )
        }
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("experimental-enabled").path))
        try await composition.connectOwnedCodexMemorySource(
            sourceID: sourceID, executableURL: server, statusReadGrant: statusGrant
        )
        do {
            let candidate = try #require(composition.externalMemoryCandidates.first)
            let eventsGrant = try await composition.issueReadGrant(
                authorizationID: .init(rawValue: "events-2563"), sourceID: sourceID,
                profileID: profileID, target: .source(sourceID), scopes: [.events], lifetime: 60
            )
            await #expect(throws: ExternalMemoryProposalError.self) {
                _ = try await composition.startOwnedCodexMemoryTask(
                    sourceID: sourceID, workspaceURL: workspace, prompt: "合成任务", eventsReadGrant: eventsGrant
                )
            }
            #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("registered-new-thread").path))
            _ = try composition.setMemoryCandidateSubmission(for: candidate, within: scope, enabled: true)
            let started = try await composition.startOwnedCodexMemoryTask(
                sourceID: sourceID, workspaceURL: workspace,
                prompt: "仅提交一条合成记忆候选", eventsReadGrant: eventsGrant
            )
            #expect(started.threadID.rawValue == "owned-thread-2563")
            #expect(started.turnID.rawValue == "owned-turn-2563")
            #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent("experimental-enabled").path))
            #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent("registered-new-thread").path))
            try Data().write(to: home.appendingPathComponent("send-first"))
            #expect(await waitUntil {
                FileManager.default.fileExists(atPath: home.appendingPathComponent("first-result").path)
            })
            #expect(try String(contentsOf: home.appendingPathComponent("foreign-result"), encoding: .utf8) == "False")
            #expect(try String(contentsOf: home.appendingPathComponent("first-result"), encoding: .utf8) == "True")
            let first = try #require(center.pendingMemoryProposals().first)
            #expect(first.state == .proposed)
            #expect(first.writeProvenance?.actorID == "registered:\(sourceID.rawValue)")
            #expect(first.writeProvenance?.runID.contains("external-codex-\(sourceID.rawValue)") == true)
            #expect(first.writeProvenance?.triggerID == "call-one")
            #expect(first.writeProvenance?.sourceID == candidate.memorySourceID)
            #expect(MemoryProposalReviewSourcePresentation(envelope: first).sourceLine.contains(candidate.memorySourceID))
            #expect(try center.memoryStore.loadFacts().isEmpty)
            try center.approveDisplayedMemoryProposal(first)
            #expect(try center.memoryStore.loadFacts().count == 1)
            try Data().write(to: home.appendingPathComponent("send-second"))
            #expect(await waitUntil { (try? center.pendingMemoryProposals().count) == 1
                && FileManager.default.fileExists(atPath: home.appendingPathComponent("second-result").path) })
            let second = try #require(center.pendingMemoryProposals().first)
            #expect(second.writeProvenance?.triggerID == "call-two")
            _ = try composition.setMemoryCandidateSubmission(for: candidate, within: scope, enabled: false)
            #expect(try center.pendingMemoryProposals().isEmpty)
            #expect(throws: MemoryProposalConsumerError.self) { try center.approveDisplayedMemoryProposal(second) }
            try Data().write(to: home.appendingPathComponent("send-late"))
            #expect(await waitUntil {
                FileManager.default.fileExists(atPath: home.appendingPathComponent("late-result").path)
            })
            #expect(try String(contentsOf: home.appendingPathComponent("late-result"), encoding: .utf8) == "False")
            _ = try composition.setMemoryCandidateSubmission(for: candidate, within: scope, enabled: true)
            try Data().write(to: home.appendingPathComponent("send-after-regrant"))
            #expect(await waitUntil {
                FileManager.default.fileExists(atPath: home.appendingPathComponent("after-regrant-result").path)
            })
            #expect(try String(contentsOf: home.appendingPathComponent("after-regrant-result"), encoding: .utf8) == "False")
            #expect(try center.memoryStore.loadFacts().count == 1)
            #expect(try center.memoryProposalConsumer.envelopes().count == 2)
            try Data().write(to: home.appendingPathComponent("allow-exit"))
            _ = await composition.revoke(sourceID: sourceID, profileID: profileID)
        } catch {
            try? Data().write(to: home.appendingPathComponent("send-first"))
            try? Data().write(to: home.appendingPathComponent("send-second"))
            try? Data().write(to: home.appendingPathComponent("send-late"))
            try? Data().write(to: home.appendingPathComponent("send-after-regrant"))
            try? Data().write(to: home.appendingPathComponent("allow-exit"))
            _ = await composition.revoke(sourceID: sourceID, profileID: profileID)
            throw error
        }
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<250 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}
