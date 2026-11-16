import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// Use the same Core-owned parent-turn seam as ProductionPolicyWiringTests.
/// Direct calls to the composed executor have no verified source identity and
/// are deliberately rejected by ProjectSessionCompositeToolExecutor.
@MainActor
enum P3Output01VerifiedFileWriteProbe {
    static func execute(
        bridge: BridgeStore,
        input: [String: String],
        currentConversationIDOverride: String? = nil
    ) async throws -> String {
        let sessionID = try #require(bridge.chat.activeSessionID).uuidString
        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let toolTitle = try #require(input["tool_title"])
        let path = try #require(input["path"])
        let content = try #require(input["content"])
        let turnController = TurnController()
        let parentTurn = await turnController.beginTurn()
        let context = AgentExecutionContextSnapshot(
            provider: MockProvider.shared,
            approvalGate: nil,
            turnController: turnController,
            currentConversationID: currentConversationIDOverride ?? sessionID,
            makeChildBudget: nil,
            deadline: Date().addingTimeInterval(60),
            parentTurnHandle: parentTurn,
            parentRuntimeIdentity: ParentRuntimeIdentity(
                sessionID: sessionID,
                conversationID: sessionID,
                turnID: "turn-handle:\(parentTurn.turnID)",
                taskID: "output01-ledger-parent",
                actorID: "app"
            )
        )
        do {
            try #require(context.hasVerifiedParentRuntime)
            let execution = AgentExecutionIdentity(
                turn: AgentTurnIdentity(sessionID: sessionID, turnID: parentTurn.turnID,
                    messageID: UUID().uuidString), operationID: "output01-file-write-" + UUID().uuidString, attempt: 1)
            let ledger = engine.toolExecutionFactLedger
            let receipt = try ledger.mint(toolCallID: UUID().uuidString, toolName: "file_write",
                attemptID: "output01-attempt-1", attemptNumber: 1, executionIdentity: execution)
            let output: String
            do {
                output = try await AgentExecutionContext.$current.withValue(context) {
                    try await ToolExecutionReceiptContext.$current.withValue(receipt) {
                        try await ToolExecutionReceiptContext.$ledger.withValue(ledger) {
                            try await engine.composedExecutor.execute(
                                name: "file_write",
                                input: ["tool_title": toolTitle, "path": path, "content": content]
                            )
                        }
                    }
                }
                _ = try ledger.settle(receipt, status: .succeeded)
            } catch {
                _ = try? ledger.settle(receipt, status: .failed)
                throw error
            }
            await parentTurn.finish()
            return output
        } catch {
            await parentTurn.finish()
            throw error
        }
    }
}

// P3-OUTPUT-01（DEV-297 接线）：应用层生产消费者闭环。DEV-286/294 已在
// MinisCore 落头 FileChangeLedger 生产者与 BuiltinToolExecutor 的写入口
// 登记；本组测试证明组合根（attachProductionServices 的 executor 组合段）
// 把生产台账注入工具执行链：一次真实 file_write 经生产组合链（Recording →
// Policy → SafetyGate → Builtin）执行后，生产可达入口（BridgeStore.
// productionFileChangeLedger / productionBuiltinToolExecutor）能按会话键
// 查回该文件的逐文件变更条目与 diffID。不测 MinisCore 内部语义（那是
// FileChangeLedgerTests），只测生产接线可达性。
@Suite("P3-OUTPUT-01 FileChangeLedger production consumer wiring (DEV-297)")
@MainActor
struct P3Output01FileChangeLedgerProductionConsumer297Tests {

    private struct Fixture {
        let bridge: BridgeStore
        let workspace: URL
        let sessions: URL
    }

    private func makeFixture(activeSessionRequired: Bool) -> Fixture {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let workspace = root.appendingPathComponent("dev297-output01-ws-\(UUID().uuidString)")
        let sessions = root.appendingPathComponent("dev297-output01-sessions-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let bridge = BridgeStore()
        if activeSessionRequired {
            // 首个会话沿用 App 启动同款直建路径；之后的会话变化才走
            // performSessionAction 统一生产入口（见 switch 测试）。
            bridge.chat.applyNewSession()
        }
        bridge.attachProductionServices(
            fileAccessAllowedRoot: workspace,
            fileAccessDeniedRoots: [],
            sessionDirectory: sessions,
            mcpManager: MCPServerManager(
                fileURL: sessions.appendingPathComponent("mcps.json")
            )
        )
        return Fixture(bridge: bridge, workspace: workspace, sessions: sessions)
    }

    private func discard(_ fixture: Fixture) {
        try? FileManager.default.removeItem(at: fixture.workspace)
        try? FileManager.default.removeItem(at: fixture.sessions)
    }

    // MARK: - 生产组合注入 + 一次真实工具执行产生台账条目

    @Test("production composition injects the ledger and one real file_write records an entry with diffID")
    func productionToolWriteRecordsEntryWithDiffID() async throws {
        let fixture = makeFixture(activeSessionRequired: true)
        defer { discard(fixture) }
        let bridge = fixture.bridge

        let ledger = try #require(bridge.productionFileChangeLedger)
        let executor = try #require(bridge.productionBuiltinToolExecutor)
        // 注入的必须是同一生产实例，会话键=装配时的活跃会话 uuidString。
        #expect(executor.fileChangeLedger === ledger)
        let sessionID = try #require(bridge.chat.activeSessionID).uuidString
        #expect(executor.fileChangeSessionID == sessionID)

        // 从生产组合可达入口执行真实工具：引擎组合出口（executorBox 最终
        // 包装 = Recording→Policy→SafetyGate→Builtin），非裸构造执行器。
        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let missingSource = fixture.workspace.appendingPathComponent("dev297-no-source-\(UUID().uuidString).txt")
        var missingSourceRejected = false
        do {
            _ = try await engine.composedExecutor.execute(
                name: "file_write",
                input: ["tool_title": "缺身份探针", "path": missingSource.path, "content": "denied\n"]
            )
        } catch let error as ToolExecutorError {
            if case .invalidParameter = error { missingSourceRejected = true }
        }
        #expect(missingSourceRejected)
        #expect(!FileManager.default.fileExists(atPath: missingSource.path))

        let mismatchedSource = fixture.workspace.appendingPathComponent("dev297-wrong-source-\(UUID().uuidString).txt")
        var mismatchedSourceRejected = false
        do {
            _ = try await P3Output01VerifiedFileWriteProbe.execute(
                bridge: bridge,
                input: ["tool_title": "错身份探针", "path": mismatchedSource.path, "content": "denied\n"],
                currentConversationIDOverride: UUID().uuidString
            )
        } catch let error as ToolExecutorError {
            if case .invalidParameter = error { mismatchedSourceRejected = true }
        }
        #expect(mismatchedSourceRejected)
        #expect(!FileManager.default.fileExists(atPath: mismatchedSource.path))
        #expect(ledger.count == 0)

        let relativeName = "dev297-output01-\(UUID().uuidString).txt"
        let marker = fixture.workspace.appendingPathComponent(relativeName)
        let content = "output01 production consumer probe\nsecond line\n"
        let result = try await P3Output01VerifiedFileWriteProbe.execute(
            bridge: bridge,
            input: ["tool_title": "写台账探针", "path": marker.path, "content": content]
        )

        // 真实写盘发生，结果串透传 diffID。
        #expect(try String(contentsOf: marker, encoding: .utf8) == content)
        let suffix = try #require(result.components(separatedBy: " [diffID:").last)
        let diffID = suffix.replacingOccurrences(of: "]", with: "")
        #expect(diffID.hasPrefix("diff-"))

        // 生产台账含该文件的逐文件条目（相对工作区根、created、含增删统计）。
        let record = try #require(ledger.record(diffID: diffID, sessionID: sessionID))
        #expect(record.path == relativeName)
        #expect(record.kind == .created)
        #expect(record.sessionID == sessionID)
        // 两行新增、零删除（逐行计数口径由 MinisCore FileChangeLedgerTests
        // 钉死，本线只断言生产接线的可达与形状）。
        #expect(record.insertions >= 2)
        #expect(record.deletions == 0)
        #expect(ledger.records(sessionID: sessionID).contains(record))

        // 逐文件差异正文与 244B 四字段投影形状均可从同一实例查回。
        let payload = try #require(ledger.diffPayload(diffID: diffID, sessionID: sessionID))
        #expect(payload.path == relativeName)
        #expect(payload.unifiedDiff.contains("output01 production consumer probe"))
        let reference = try #require(ledger.diffReference(for: diffID, sessionID: sessionID))
        #expect(reference.changedFileCount == 1)
        #expect(reference.insertions == record.insertions)
        #expect(reference.deletions == record.deletions)

        // 会话隔离：跨会话键不得命中该条目。
        #expect(ledger.record(diffID: diffID, sessionID: UUID().uuidString) == nil)
    }

    // MARK: - Receipt 归属优先于可变 UI 会话键，切换保持会话隔离

    @Test("canonical receipt keeps ledger attribution when UI key is cleared, including later session switches")
    func sessionKeyFollowsProductionSessionActionSeam() async throws {
        let fixture = makeFixture(activeSessionRequired: false)
        defer { discard(fixture) }
        let bridge = fixture.bridge
        let ledger = try #require(bridge.productionFileChangeLedger)
        let executor = try #require(bridge.productionBuiltinToolExecutor)

        // Production always has a bootstrap session. A minted tool receipt, not
        // mutable UI selection, owns the write after admission. Clearing the UI
        // key does not discard this already-verified execution identity.
        let initialSessionID = try #require(bridge.chat.activeSessionID).uuidString
        #expect(executor.fileChangeSessionID == initialSessionID)
        executor.fileChangeSessionID = ""
        #expect(executor.fileChangeSessionID == "")
        let orphan = fixture.workspace.appendingPathComponent("dev297-orphan-\(UUID().uuidString).txt")
        let orphanResult = try await P3Output01VerifiedFileWriteProbe.execute(
            bridge: bridge,
            input: ["tool_title": "未接线探针", "path": orphan.path, "content": "no session\n"]
        )
        #expect(try String(contentsOf: orphan, encoding: .utf8) == "no session\n")
        let initialDiffID = (try #require(orphanResult.components(separatedBy: " [diffID:").last))
            .replacingOccurrences(of: "]", with: "")
        let initialRecord = try #require(ledger.record(diffID: initialDiffID, sessionID: initialSessionID))
        #expect(initialRecord.sessionID == initialSessionID)
        #expect(initialRecord.path == orphan.lastPathComponent)
        #expect(ledger.records(sessionID: initialSessionID).count == 1)

        // 首个会话沿用 App 启动恢复同款直建路径（applyNewSession，仅用于
        // 让统一生产入口具备源会话）；之后的会话变化全部经
        // ChatStore.newSession/switchSession → sessionActionHandler →
        // performSessionAction，台账会话键就地跟随活跃会话。
        let bootstrapped = bridge.chat.applyNewSession()
        bridge.chat.newSession()
        let second = try #require(bridge.chat.activeSessionID)
        #expect(second != bootstrapped)
        #expect(executor.fileChangeSessionID == second.uuidString)
        bridge.chat.switchSession(id: bootstrapped)
        #expect(bridge.chat.activeSessionID == bootstrapped)
        #expect(executor.fileChangeSessionID == bootstrapped.uuidString)

        // 键接线后的一次真实工具执行按当前会话登记。
        let marker = fixture.workspace.appendingPathComponent("dev297-wired-\(UUID().uuidString).txt")
        let result = try await P3Output01VerifiedFileWriteProbe.execute(
            bridge: bridge,
            input: ["tool_title": "接线探针", "path": marker.path, "content": "wired\n"]
        )
        let diffID = (try #require(result.components(separatedBy: " [diffID:").last))
            .replacingOccurrences(of: "]", with: "")
        let record = try #require(ledger.record(diffID: diffID, sessionID: bootstrapped.uuidString))
        #expect(record.kind == .created)
        // The first receipt remains in its original session. The switched
        // execution records only in its own current session, never the other one.
        #expect(record.sessionID == bootstrapped.uuidString)
        #expect(ledger.count == 2)
        #expect(ledger.records(sessionID: bootstrapped.uuidString).count == 1)
        #expect(ledger.record(diffID: initialDiffID, sessionID: initialSessionID) == initialRecord)
        #expect(ledger.record(diffID: initialDiffID, sessionID: bootstrapped.uuidString) == nil)
        #expect(ledger.records(sessionID: second.uuidString).isEmpty)
    }
}
