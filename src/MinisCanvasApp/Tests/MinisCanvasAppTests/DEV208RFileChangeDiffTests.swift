import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

// QODER-DEV-208R — D-OUTPUT-01 / D-OUTPUT-02（清单 :380-381）
// D-OUTPUT-01 「工具和子智能体输出以可折叠摘要呈现，点击后能查看脱敏详情和终态。」
// D-OUTPUT-02 「智能体创建、修改、删除的文件形成可展开变更列表，并可查看逐文件 Diff。」
// 本套件钉住：纯派生缝的语义、脱敏与有界性，以及生产可达性（消费链源文本合同）。

@Suite("DEV208R 变更文件事实与逐文件 Diff（D-OUTPUT-02）")
struct DEV208RAgentFileChangeTests {

    private func fileWriteInput(path: String, content: String, append: Bool = false) -> [String: Any] {
        var input: [String: Any] = ["path": path, "content": content]
        if append { input["append"] = true }
        return input
    }

    @Test("非文件工具不产生任何变更事实或预检 IO")
    func nonFileToolsAreIgnored() {
        #expect(AgentFileChangeRecorder.precheck(toolName: "shell_execute", input: ["command": "ls"]) == nil)
        #expect(AgentFileChangeRecorder.change(
            toolName: "file_read",
            input: ["path": "/tmp/whatever"],
            precheck: nil,
            knownSecretValues: [],
            timestamp: Date()
        ) == nil)
    }

    @Test("file_edit 成功派生 .edited 事实与替换区间 Diff")
    func fileEditProducesEditedRecord() {
        let change = AgentFileChangeRecorder.change(
            toolName: "file_edit",
            input: [
                "path": "/tmp/dev208r/target.txt",
                "old_string": "alpha\nbeta",
                "new_string": "alpha\ngamma",
            ],
            precheck: nil,
            knownSecretValues: [],
            timestamp: Date(timeIntervalSince1970: 1_000)
        )
        #expect(change?.kind == .edited)
        #expect(change?.path == "/tmp/dev208r/target.txt")
        #expect(change?.additions == 1)
        #expect(change?.deletions == 1)
        #expect(change?.diffText.contains("+gamma") == true)
        #expect(change?.diffText.contains("-beta") == true)
        #expect(change?.diffIsPartial == false)
    }

    @Test("file_write 新建：执行前不存在 → .created，Diff 全为新增")
    func createRecordIsAllAdditions() {
        let change = AgentFileChangeRecorder.change(
            toolName: "file_write",
            input: fileWriteInput(path: "/tmp/dev208r/fresh.txt", content: "line1\nline2"),
            precheck: AgentFileChangeRecorder.Precheck(existedBefore: false, oldText: nil, oldTextOverCaptureBudget: false),
            knownSecretValues: [],
            timestamp: Date()
        )
        #expect(change?.kind == .created)
        #expect(change?.additions == 2)
        #expect(change?.deletions == 0)
        #expect(change?.diffText.contains("+line1") == true)
    }

    @Test("file_write 覆盖：捕获到旧文 → .overwritten，Diff 含两侧")
    func overwriteRecordShowsBothSides() {
        let change = AgentFileChangeRecorder.change(
            toolName: "file_write",
            input: fileWriteInput(path: "/tmp/dev208r/over.txt", content: "same\nnew tail"),
            precheck: AgentFileChangeRecorder.Precheck(existedBefore: true, oldText: "same\nold tail", oldTextOverCaptureBudget: false),
            knownSecretValues: [],
            timestamp: Date()
        )
        #expect(change?.kind == .overwritten)
        #expect(change?.diffText.contains("-old tail") == true)
        #expect(change?.diffText.contains("+new tail") == true)
        #expect(change?.diffIsPartial == false)
    }

    @Test("旧文超预算的覆盖写如实标记 partial，不伪造完整 Diff")
    func overBudgetOldTextIsMarkedPartial() {
        let change = AgentFileChangeRecorder.change(
            toolName: "file_write",
            input: fileWriteInput(path: "/tmp/dev208r/big.txt", content: "replacement"),
            precheck: AgentFileChangeRecorder.Precheck(existedBefore: true, oldText: nil, oldTextOverCaptureBudget: true),
            knownSecretValues: [],
            timestamp: Date()
        )
        #expect(change?.kind == .overwritten)
        #expect(change?.diffIsPartial == true)
    }

    @Test("append 追加：已存在 → .appended，未存在 → .created")
    func appendKindFollowsPrecheck() {
        let appended = AgentFileChangeRecorder.change(
            toolName: "file_write",
            input: fileWriteInput(path: "/tmp/dev208r/log.txt", content: "more\n", append: true),
            precheck: AgentFileChangeRecorder.Precheck(existedBefore: true, oldText: nil, oldTextOverCaptureBudget: false),
            knownSecretValues: [],
            timestamp: Date()
        )
        #expect(appended?.kind == .appended)
        let created = AgentFileChangeRecorder.change(
            toolName: "file_write",
            input: fileWriteInput(path: "/tmp/dev208r/log.txt", content: "more\n", append: true),
            precheck: AgentFileChangeRecorder.Precheck(existedBefore: false, oldText: nil, oldTextOverCaptureBudget: false),
            knownSecretValues: [],
            timestamp: Date()
        )
        #expect(created?.kind == .created)
    }

    @Test("Diff 文本经 ContentSecretRedactor 脱敏且长度有界")
    func diffIsRedactedAndBounded() {
        let secret = "DEV208RTESTFIXTUREPRIVATEVALUE123"
        let change = AgentFileChangeRecorder.change(
            toolName: "file_write",
            input: fileWriteInput(path: "/tmp/dev208r/secret.txt", content: "api_key=\(secret)"),
            precheck: AgentFileChangeRecorder.Precheck(
                existedBefore: false, oldText: nil, oldTextOverCaptureBudget: false),
            knownSecretValues: [secret],
            timestamp: Date()
        )
        #expect(change?.diffText.contains(secret) == false)

        let huge = (0...4_000).map { "line-\($0)" }.joined(separator: "\n")
        let bounded = AgentFileChangeRecorder.change(
            toolName: "file_write",
            input: fileWriteInput(path: "/tmp/dev208r/huge.txt", content: huge),
            precheck: AgentFileChangeRecorder.Precheck(
                existedBefore: false, oldText: nil, oldTextOverCaptureBudget: false),
            knownSecretValues: [],
            timestamp: Date()
        )
        #expect(bounded?.diffIsPartial == true)
        #expect((bounded?.diffText.count ?? 0) <= AgentFileChangeRecorder.maximumDiffCharacters + 64)
        #expect(bounded?.diffText.contains("[diff 已截断]") == true)
    }

    @Test("precheck 对真实临时文件报告存在性与旧文")
    func precheckReadsRealFileBounded() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("dev208r-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appendingPathComponent("missing.txt").path
        let existing = dir.appendingPathComponent("existing.txt").path
        try "old content".write(toFile: existing, atomically: true, encoding: .utf8)

        let preMissing = AgentFileChangeRecorder.precheck(
            toolName: "file_write", input: fileWriteInput(path: missing, content: "x"))
        #expect(preMissing?.existedBefore == false)
        let preExisting = AgentFileChangeRecorder.precheck(
            toolName: "file_write", input: fileWriteInput(path: existing, content: "x"))
        #expect(preExisting?.existedBefore == true)
        #expect(preExisting?.oldText == "old content")
        // 相对路径不预检（执行侧 resolveAllowedPath 先行拒绝）。
        #expect(AgentFileChangeRecorder.precheck(
            toolName: "file_write", input: fileWriteInput(path: "relative/x.txt", content: "x")) == nil)
    }

    @Test("ActionRecord 向后兼容：无 fileChange 键的旧持久记录可解码")
    func actionRecordDecodesWithoutFileChange() throws {
        let legacy = """
        {"id":"3F2504E0-4F89-41D3-9A0C-0305E82C3301","toolName":"file_write",\
        "argsSummary":"{}","resultSummary":"ok","timestamp":1000,"succeeded":true,"undoable":true}
        """
        let decoded = try JSONDecoder().decode(ActionRecord.self, from: Data(legacy.utf8))
        #expect(decoded.fileChange == nil)
        let record = ActionRecord(toolName: "shell_execute", argsSummary: "{}", resultSummary: "ok")
        #expect(record.fileChange == nil)
    }
}

@Suite("DEV208R 输出视图生产可达性（D-OUTPUT-01/02）")
struct DEV208ROutputReachabilityTests {
    private func source(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MinisCanvasAppTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // MinisCanvasApp
            .deletingLastPathComponent() // src
            .deletingLastPathComponent() // repository
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    @Test("ToolEventCard 在生产导航链中被 ChatInspectorView 渲染")
    func toolEventCardIsWiredIntoInspector() throws {
        let inspector = try source(
            "src/MinisCanvasApp/Sources/MinisCanvasApp/Inspector/ChatInspectorView.swift")
        // The production card may receive optional result-page/session context;
        // keep this contract focused on the event consumer rather than a
        // particular formatting or argument list.
        #expect(inspector.range(
            of: #"ToolEventCard\s*\(\s*event:\s*event\b"#,
            options: .regularExpression
        ) != nil, "Inspector must render each tool event through ToolEventCard")
        // 可达链：MinisCanvasApp → ContentView → ContextPanelView → ChatInspectorView。
        let panel = try source(
            "src/MinisCanvasApp/Sources/MinisCanvasApp/ContextPanelView.swift")
        #expect(panel.range(
            of: #"ChatInspectorView\s*\(\s*snapshot:\s*chatSnapshot,\s*onCompact:\s*onCompact\b"#,
            options: .regularExpression
        ) != nil, "Inspector must receive the current snapshot and production compaction action")
        let content = try source(
            "src/MinisCanvasApp/Sources/MinisCanvasApp/ContentView.swift")
        #expect(content.range(
            of: #"ContextPanelView\s*\([^}]*onCollapse:[^\n]*\}\s*,\s*onCompact:\s*\{\s*guard[^}]*AppCommandMenuBuilder\.command\(\s*id:\s*"ui\.chat\.compact",\s*registry:\s*bridge\.commandRegistry,[^}]*command\.isEnabled\s+else\s*\{\s*return\s*\}\s*bridge\.runCommand\(id:\s*command\.id\)"#,
            options: .regularExpression
        ) != nil, "Visible compaction must dispatch the enabled registered command")
    }

    @Test("变更文件列表经 snapshot 值投影进入生产视图")
    func fileChangesFlowThroughSnapshot() throws {
        let inspector = try source(
            "src/MinisCanvasApp/Sources/MinisCanvasApp/Inspector/ChatInspectorView.swift")
        let content = try source(
            "src/MinisCanvasApp/Sources/MinisCanvasApp/ContentView.swift")
        #expect(inspector.contains("chat-inspector.file-changes"))
        #expect(inspector.contains("FileChangeRow(change: change)"))
        #expect(inspector.contains("[AgentFileChangeRecord]"))
        #expect(content.contains("fileChanges: fileChanges"))
        #expect(content.contains("compactMap(\\.fileChange)"))
        // 脱敏详情面仍由 canonical 投影负责（事件本体不出 UI 边界）。
        #expect(inspector.contains("ConversationEventDisplayProjection"))
    }

    @Test("RecordingToolExecutor 成功缝挂接文件变更派生")
    func recorderHookSitsOnSuccessPath() throws {
        let drafts = try source(
            "src/MinisCanvasApp/Sources/MinisCanvasApp/SessionDrafts.swift")
        #expect(drafts.contains("AgentFileChangeRecorder.precheck(toolName: name, input: input)"))
        #expect(drafts.contains("AgentFileChangeRecorder.change("))
        #expect(drafts.contains("fileChange: AgentFileChangeRecord? = nil"))
    }
}
