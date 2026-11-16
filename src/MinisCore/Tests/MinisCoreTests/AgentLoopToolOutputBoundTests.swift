import Foundation
import Testing
@testable import MinisCore

@Suite struct AgentLoopToolOutputBoundTests {
    private final class LargeOutputExecutor: ToolExecutor {
        let fails: Bool
        let text = String(repeating: "界🙂", count: 40_000)
        init(fails: Bool) { self.fails = fails }
        func execute(name: String, input: [String: Any]) async throws -> String {
            if fails { throw ToolExecutorError.invalidParameter(text) }
            return text
        }
    }

    @Test(arguments: [false, true])
    func everyModelVisibleResultIsBoundedIncludingErrors(fails: Bool) async throws {
        let profile = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = profile.rootDirectory.appendingPathComponent("goal18-tool-cap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ledger = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts.json"))
        let call = try JSONSerialization.data(withJSONObject: ["tool_calls": [[
            "id": "bounded-read", "name": "file_read",
            "input": ["path": root.appendingPathComponent("synthetic.txt").path]
        ]]])
        let provider = ScriptedChildProvider(responses: [String(decoding: call, as: UTF8.self), "done"])
        let loop = AgentLoop(maxIterations: 3, toolExecutionFactLedger: ledger)
        let identity = AgentExecutionIdentity(turn: AgentTurnIdentity(sessionID: "output-bound-session",
            turnID: 1, messageID: "output-bound-message"), operationID: "output-bound-operation", attempt: 1)
        _ = try await loop.run(messages: [LLMMessage(role: .user, content: "read synthetic")],
            systemPrompt: nil, provider: provider, toolExecutor: LargeOutputExecutor(fails: fails),
            tools: AgentToolCatalog.makeTools().filter { $0.name == "file_read" },
            currentConversationID: "output-bound-session", executionIdentity: identity)
        let returned = try #require(provider.receivedRequests.dropFirst().first?.last)
        let parts = try #require(JSONSerialization.jsonObject(with: Data(returned.content.utf8)) as? [[String: Any]])
        let part = try #require(parts.first)
        let content = try #require(part["content"] as? String)
        #expect(content.utf8.count <= MCPOutputLimiter.defaultMaximumCharacters)
        #expect(part["is_error"] as? Bool == fails)
        #expect(ledger.facts.count == 1)
        #expect(ledger.pendingReceipts.isEmpty)
    }
    @Test func typedSettingsReceiptKeepsExactFalseBooleanThroughOutputProjection() throws {
        let receipt = BL6SettingsReceipt(requestID: "synthetic-typed-receipt", operation: .apply,
            previousRevision: "before", effectiveRevision: "after",
            changedKeys: ["general.language", "agent.fallback-enabled"], rollbackValues: [:])
        let text = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
        let projections = [MCPOutputLimiter.project(text),
            MCPOutputLimiter.limit([String(text.prefix(20)), String(text.dropFirst(20))],
                to: MCPOutputLimiter.defaultMaximumCharacters)]
        for projection in projections {
            let decoded = try JSONDecoder().decode(BL6SettingsReceipt.self, from: Data(projection.utf8))
            #expect(decoded == receipt)
            #expect(!decoded.secretValuesExposed)
        }
    }

    @Test(arguments: [".env", "config.json"])
    func refusesModelVisibleMasksOnWriteAndEdit(filename: String) async throws {
        let root = try minisCoreToolContractRoot("masked-file-round-trip").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(filename)
        let secret = "synthetic-secret-for-mask-round-trip"
        let isJSON = filename == "config.json"
        let source = isJSON
            ? "{\"note\":\"[REDACTED]\",\"api_key\":\"\(secret)\"}\n"
            : "OPENAI_API_KEY=\(secret)\nNOTE=****\n"
        let original = Data(source.utf8)
        try original.write(to: file)
        let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        let visible = try await modelVisibleFile(at: file, root: root, executor: executor)
        let mask = isJSON ? "[REDACTED]" : String(repeating: "*", count: secret.count)
        try #require(visible.contains(mask))
        try #require(!visible.contains(secret))

        try await expectMaskedWriteRefusal(visible, at: file, executor: executor)
        #expect(try Data(contentsOf: file) == original)

        // Isolate the edit assertion so a broken write cannot hide its effect.
        try original.write(to: file)
        await #expect(throws: ToolExecutorError.self) {
            _ = try await executor.execute(name: "file_edit", input: [
                "path": file.path, "old_string": secret, "new_string": mask
            ])
        }
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func changingOnlyThePortDoesNotPermitWritingBackAModelVisibleDotenvMask() async throws {
        let root = try minisCoreToolContractRoot("dotenv-port-mask").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(".env")
        let secret = "synthetic-secret-for-port-mask"
        let source = "OPENAI_API_KEY=\(secret)\nPORT=3000\n"
        let original = Data(source.utf8)
        try original.write(to: file)
        let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        let visible = try await modelVisibleFile(at: file, root: root, executor: executor)
        let mask = String(repeating: "*", count: secret.count)
        try #require(visible == "OPENAI_API_KEY=\(mask)\nPORT=3000\n")

        let wholeFile = visible.replacingOccurrences(of: "PORT=3000", with: "PORT=4000")
        try await expectMaskedWriteRefusal(wholeFile, at: file, executor: executor)
        #expect(try Data(contentsOf: file) == original)

        _ = try await executor.execute(name: "file_edit", input: [
            "path": file.path, "old_string": "PORT=3000", "new_string": "PORT=4000"
        ])
        #expect(try Data(contentsOf: file) == Data(source.replacingOccurrences(
            of: "PORT=3000", with: "PORT=4000").utf8))
    }

    private func expectMaskedWriteRefusal(_ content: String, at file: URL,
                                          executor: BuiltinToolExecutor) async throws {
        do {
            _ = try await executor.execute(name: "file_write", input: [
                "path": file.path, "content": content
            ])
            Issue.record("A model-visible redaction mask must not be written to disk")
        } catch let ToolExecutorError.writeFailed(reason) {
            #expect(reason == "本次改动包含脱敏占位符，未写入。请用 file_edit 只修改目标行，不要把脱敏占位符写入文件。")
        }
    }

    @Test func preservesExistingLiteralMasksAcrossWritesAndEdits() async throws {
        let root = try minisCoreToolContractRoot("literal-file-masks").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("literals.txt")
        let original = "Example=[REDACTED]\nStars=****\nVersion=1\n"
        try Data(original.utf8).write(to: file)
        let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        let next = original.replacingOccurrences(of: "Version=1", with: "Version=2")
        _ = try await executor.execute(name: "file_write", input: ["path": file.path, "content": next])
        #expect(try Data(contentsOf: file) == Data(next.utf8))
        _ = try await executor.execute(name: "file_edit", input: [
            "path": file.path, "old_string": "Stars=****\nVersion=2", "new_string": "Stars=****\nVersion=3"
        ])
        #expect(try Data(contentsOf: file) == Data(next.replacingOccurrences(of: "Version=2", with: "Version=3").utf8))
    }

    @Test(arguments: [false, true])
    func movedCredentialLinesAndReplaceAllCannotAddMasks(checkpoints: Bool) async throws {
        let root = try minisCoreToolContractRoot("file-mask-mutation").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        // The checkpoint store excludes sensitive basenames even for
        // synthetic data. Keep the content identical on a permitted path.
        let file = root.appendingPathComponent(checkpoints ? "settings-example.txt" : ".env")
        let secret = "synthetic-secret-for-repeated-key"
        let mask = String(repeating: "*", count: secret.count)
        let credential = "OPENAI_API_KEY=\(secret)\n"
        let literal = "OPENAI_API_KEY=\(mask)\n"
        let original = "NOTE=before\n" + credential + literal + credential
        try Data(original.utf8).write(to: file)
        let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        let store = try FileCheckpointStore(
            directory: root.appendingPathComponent("checkpoints"), allowedRoots: [root])
        executor.fileCheckpointsEnabled = checkpoints
        executor.fileCheckpointStore = store
        executor.fileChangeSessionID = "file-mask-mutation"

        await #expect(throws: ToolExecutorError.self) {
            _ = try await executor.execute(name: "file_write", input: [
                "path": file.path, "content": literal + credential + "NOTE=after\n" + literal
            ])
        }
        await #expect(throws: ToolExecutorError.self) {
            _ = try await executor.execute(name: "file_edit", input: [
                "path": file.path, "old_string": secret, "new_string": mask, "replace_all": true
            ])
        }
        #expect(try Data(contentsOf: file) == Data(original.utf8))
        #expect(try store.summaries(sessionID: executor.fileChangeSessionID).isEmpty)

        let reordered = credential + literal + credential + "NOTE=after\n"
        _ = try await executor.execute(name: "file_write", input: ["path": file.path, "content": reordered])
        let appendix = "EXAMPLE=****\n"
        _ = try await executor.execute(name: "file_write", input: [
            "path": file.path, "content": appendix, "append": true
        ])
        #expect(try Data(contentsOf: file) == Data((reordered + appendix).utf8))
        #expect(try store.summaries(sessionID: executor.fileChangeSessionID).count == (checkpoints ? 2 : 0))
    }

    @Test(arguments: ["export OPENAI_API_KEY=", "OPENAI_API_KEY  =  "])
    func refusesMasksForTheSameDotenvKeyAfterAssignmentFormattingChanges(prefix: String) async throws {
        let root = try minisCoreToolContractRoot("dotenv-mask-assignment").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(".env")
        let secret = "synthetic-secret-for-dotenv-format"
        let mask = String(repeating: "*", count: secret.count)
        let literal = "EXAMPLE=\(mask)\n"
        let original = "OPENAI_API_KEY=\(secret)\n" + literal
        try Data(original.utf8).write(to: file)
        let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        let changed = prefix + mask + "\n" + literal

        await #expect(throws: ToolExecutorError.self) {
            _ = try await executor.execute(name: "file_write", input: [
                "path": file.path, "content": changed
            ])
        }
        #expect(try Data(contentsOf: file) == Data(original.utf8))

        try Data(original.utf8).write(to: file)
        await #expect(throws: ToolExecutorError.self) {
            _ = try await executor.execute(name: "file_edit", input: [
                "path": file.path, "old_string": original, "new_string": changed
            ])
        }
        #expect(try Data(contentsOf: file) == Data(original.utf8))

        let preserved = prefix + secret + "\nexport " + literal
        _ = try await executor.execute(name: "file_write", input: [
            "path": file.path, "content": preserved
        ])
        #expect(try Data(contentsOf: file) == Data(preserved.utf8))
    }

    @Test func attributesSameKeyMasksByTheirExistingDotenvComments() async throws {
        let root = try minisCoreToolContractRoot("dotenv-mask-comments").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(".env")
        let secret = "synthetic-secret-for-comment-context"
        let mask = String(repeating: "*", count: secret.count)
        let key = "OPENAI_API_KEY="
        let credential = key + secret + " # primary\n"
        let literal = key + mask + " # sample\n"
        let original = credential + literal
        let replaced = key + mask + " # primary\n" + key + "sample-updated # sample\n"
        let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        try Data(original.utf8).write(to: file)
        await #expect(throws: ToolExecutorError.self) {
            _ = try await executor.execute(name: "file_write", input: [
                "path": file.path, "content": replaced
            ])
        }
        #expect(try Data(contentsOf: file) == Data(original.utf8))

        try Data(original.utf8).write(to: file)
        await #expect(throws: ToolExecutorError.self) {
            _ = try await executor.execute(name: "file_edit", input: [
                "path": file.path, "old_string": original, "new_string": replaced
            ])
        }
        #expect(try Data(contentsOf: file) == Data(original.utf8))

        let changedLiteralComment = key + mask + " # primary\n" + credential
        _ = try await executor.execute(name: "file_write", input: [
            "path": file.path, "content": changedLiteralComment
        ])
        #expect(try Data(contentsOf: file) == Data(changedLiteralComment.utf8))
    }

    @Test func checkpointedFileEditReportsMissingOldString() async throws {
        let root = try minisCoreToolContractRoot("file-edit-missing").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("note.txt")
        let original = Data("original text".utf8)
        try original.write(to: file)
        let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        executor.fileCheckpointsEnabled = true
        executor.fileCheckpointStore = try FileCheckpointStore(
            directory: root.appendingPathComponent("checkpoints"), allowedRoots: [root])
        executor.fileChangeSessionID = "file-edit-missing"
        do {
            _ = try await executor.execute(name: "file_edit", input: [
                "path": file.path, "old_string": "absent text", "new_string": "replacement"
            ])
            Issue.record("file_edit should report that old_string was not found")
        } catch let ToolExecutorError.editFailed(reason) {
            #expect(reason.contains("old_string not found"))
            #expect(!reason.contains("replace_all"))
        }
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func modelVisibleFileReadPreservesJSONBytesAroundSensitiveValue() async throws {
        let root = try minisCoreToolContractRoot("file-read-format").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("config.json")
        let source = "{\n  \"path\": \"src/index.js\",\n  \"ratio\": 7e-1,\n  \"api_key\": \"opaque-synthetic-value\"\n}\n"
        try Data(source.utf8).write(to: file)
        let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        let visible = try await modelVisibleFile(at: file, root: root, executor: executor)
        #expect(Data(visible.utf8) == Data(source.replacingOccurrences(
            of: "opaque-synthetic-value", with: "[REDACTED]").utf8))
        #expect(try Data(contentsOf: file) == Data(source.utf8))
    }

    @Test func fileReadJSONProjectionPreservesRedactionAcrossTheSameCorpus() throws {
        let oversized = #"{"api_key":"oversized-value","padding":""#
            + String(repeating: "界", count: 1_000) + #""}"#
        let cases: [(source: String, secret: String, limit: Int)] = [
            (#"{"nested":{"api_key":"nested-value"},"ratio":7e-1}"#, "nested-value", 512),
            (#"[{"cookie":"array-value"},{"public":true}]"#, "array-value", 512),
            (#"{"api_key":"first-duplicate","api_key":"last-duplicate"}"#, "first-duplicate", 512),
            (#"{"api_key":"first-duplicate","api_key":"last-duplicate"}"#, "last-duplicate", 512),
            (#"{"api\u005fkey":"escaped-key-value"}"#, "escaped-key-value", 512),
            ("\u{FEFF}" + #"{"api_key":"bom-value"}"#, "bom-value", 512),
            (#"{"note":"broken", api_key=invalid-json-value"#, "invalid-json-value", 512),
            (oversized, "oversized-value", 128)
        ]
        for item in cases {
            let legacy = MCPOutputLimiter.project(item.source, to: item.limit)
            let fileRead = MCPOutputLimiter.projectFileRead(item.source, to: item.limit)
            #expect(!legacy.contains(item.secret))
            #expect(!fileRead.contains(item.secret))
            #expect(fileRead.utf8.count <= item.limit)
        }

        let escapedCredential = #"{"note":"\u0073k-syntheticMaskCheck0123456789"}"#
        let legacy = MCPOutputLimiter.project(escapedCredential)
        let fileRead = MCPOutputLimiter.projectFileRead(escapedCredential)
        let decoded = try JSONDecoder().decode([String: String].self, from: Data(fileRead.utf8))
        #expect(!legacy.contains("syntheticMaskCheck"))
        #expect(decoded["note"]?.contains("syntheticMaskCheck") == false)
    }

    private func modelVisibleFile(at file: URL, root: URL, executor: BuiltinToolExecutor) async throws -> String {
        let call = try JSONSerialization.data(withJSONObject: ["tool_calls": [[
            "id": "read-file", "name": "file_read", "input": ["path": file.path]
        ]]])
        let provider = ScriptedChildProvider(responses: [String(decoding: call, as: UTF8.self), "done"])
        let ledger = try minisCoreToolContractLedger(at: root)
        let identity = minisCoreToolContractIdentity(root.lastPathComponent)
        let approval = DotenvReadApproval()
        let loop = AgentLoop(maxIterations: 3, approvalGate: ApprovalGate(delegate: approval),
            turnController: TurnController(), timeout: 30, toolExecutionFactLedger: ledger)
        _ = try await loop.run(messages: [.init(role: .user, content: "Read the configuration")],
            systemPrompt: nil, provider: provider, toolExecutor: executor,
            tools: AgentToolCatalog.makeTools().filter { $0.name == "file_read" },
            currentConversationID: identity.turn.sessionID,
            parentIdentitySeed: ParentRuntimeIdentitySeed(sessionID: identity.turn.sessionID,
                conversationID: identity.turn.sessionID, taskID: identity.operationID, actorID: "test"),
            executionIdentity: identity)
        let returned = try #require(provider.receivedRequests.dropFirst().first?.last)
        let parts = try #require(JSONSerialization.jsonObject(with: Data(returned.content.utf8)) as? [[String: Any]])
        let part = try #require(parts.first)
        if part["is_error"] as? Bool != false {
            Issue.record("The synthetic file read did not reach the model: \(part["content"] as? String ?? "no tool feedback")")
            throw CocoaError(.fileReadUnknown)
        }
        if file.lastPathComponent == ".env" {
            let requests = await approval.requests
            try #require(requests.count == 1)
            #expect(requests.first?.toolName == "file_read")
            #expect(requests.first?.callID == "read-file")
            #expect(requests.first?.binding != nil)
        }
        return try #require(part["content"] as? String)
    }

    private actor DotenvReadApproval: ApprovalDelegate {
        private(set) var requests: [ApprovalRequest] = []

        func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
            requests.append(request)
            return ApprovalDecision(approved: true, confirmed: true, requestID: request.requestID,
                bindingDigest: request.identityDigest, filePreview: request.filePreview)
        }
    }
}
