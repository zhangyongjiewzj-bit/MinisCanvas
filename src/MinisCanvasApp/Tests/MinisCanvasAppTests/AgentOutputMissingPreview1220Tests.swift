import CryptoKit
import Foundation
import Darwin
import MinisCore
import Testing
@testable import MinisCanvasApp

private actor Output1220Approval: ApprovalDelegate {
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        ApprovalDecision(approved: true, confirmed: true,
            requestID: request.requestID, bindingDigest: request.identityDigest)
    }
}

private final class Output1220Provider: LLMProvider, ProviderRuntimeConfigurationIdentity {
    let name = "owned-output1220"
    var model = LLMModel(id: "owned-output1220", displayName: "Owned", provider: "owned-output1220")
    let capabilities: Set<ProviderCapability> = [.tools]
    var runtimeConfigurationMaterial: String? = "owned-output1220-fixed"
    private var replies: [String]
    init(path: String, content: String) throws {
        let envelope = try JSONSerialization.data(withJSONObject: ["tool_calls": [[
            "id": "write1220", "name": "file_write", "input": ["path": path, "content": content]
        ]]])
        replies = [String(decoding: envelope, as: UTF8.self), "owned output complete"]
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        let response = try #require(replies.isEmpty ? nil : replies.removeFirst())
        return LLMResponse(text: response, stopReason: "stop", usage: nil)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt,
                              maxTokens: maxTokens, temperature: temperature)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        throw CancellationError()
    }
}

private final class Output1220Records: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ActionRecord] = []
    func append(_ record: ActionRecord) { lock.withLock { values.append(record) } }
    var records: [ActionRecord] { lock.withLock { values } }
}

@Suite("OUTPUT04 actual produced file missing classification", .serialized)
@MainActor
struct AgentOutputMissingPreview1220Tests {
    @Test("real file producer preview distinguishes a reversible missing private-var target from outside and symlink")
    func producedFileMissingIsNotOutsideAndRestoreKeepsItsBinding() async throws {
        try #require(KeychainStore.isTesting)
        try #require(FormalTestIsolationPaths.resolveCurrentProcess() != nil)
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.path
        try #require(temporary.hasPrefix("/var/"))
        // Preserve the exact /private/var spelling used by the observed App
        // root. Foundation resolves this alias differently for a missing leaf.
        let parent = URL(fileURLWithPath: "/private" + temporary, isDirectory: true)
            .appendingPathComponent("owned-output1220-\(UUID().uuidString)", isDirectory: true)
        let root = parent.appendingPathComponent("session-field-project", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = root.appendingPathComponent("output-owned-evidence.txt")
        let content = "owned output1220\nreal producer and preview\n"
        let records = Output1220Records()
        let ledger = FileChangeLedger(workspaceRoot: root.path)
        let facts = try ToolExecutionFactLedger(persistenceURL: parent.appendingPathComponent("facts.json"))
        let session = UUID().uuidString
        let builtin = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        builtin.fileChangeLedger = ledger
        builtin.fileChangeSessionID = session
        let recording = RecordingToolExecutor(base: builtin, onRecorded: { records.append($0) })
        let provider = try Output1220Provider(path: file.path, content: content)
        let loop = AgentLoop(maxIterations: 2, approvalGate: ApprovalGate(delegate: Output1220Approval()),
                             turnController: TurnController(), timeout: 30, toolExecutionFactLedger: facts)
        let tool = try #require(AgentToolCatalog.makeTools().first { $0.name == "file_write" })
        let identity = AgentExecutionIdentity(turn: AgentTurnIdentity(sessionID: session, turnID: 1,
            messageID: "owned-message1220"), operationID: "owned-operation1220", attempt: 1)
        _ = try await loop.run(messages: [], systemPrompt: "owned output probe", provider: provider,
            toolExecutor: recording, tools: [tool], currentConversationID: session,
            parentIdentitySeed: ParentRuntimeIdentitySeed(sessionID: session, conversationID: session,
                taskID: "owned-task1220", actorID: "owned1220"), executionIdentity: identity)
        try #require(records.records.count == 1)
        let record = try #require(records.records.first)
        let change = try #require(record.fileChange)
        #expect(record.succeeded)
        #expect(record.sourceSessionID == session)
        // The recorder emits its admitted canonical spelling. Check physical
        // identity independently while retaining the private-var input above.
        var recordedFile = stat()
        var suppliedFile = stat()
        try #require(lstat(change.path, &recordedFile) == 0)
        try #require(lstat(file.path, &suppliedFile) == 0)
        #expect((recordedFile.st_mode & S_IFMT) == S_IFREG)
        #expect((suppliedFile.st_mode & S_IFMT) == S_IFREG)
        #expect(recordedFile.st_dev == suppliedFile.st_dev)
        #expect(recordedFile.st_ino == suppliedFile.st_ino)
        #expect(change.toolName == "file_write")
        #expect(facts.facts.count == 1)
        #expect(facts.facts.first?.status == .succeeded)
        #expect(ledger.records(sessionID: session).count == 1)
        #expect(try Data(contentsOf: file) == Data(content.utf8))
        let originalDigest = AgentFileOutputTargetResolver.generatedFileDigest(file)
        #expect(originalDigest == SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined())
        var previews: [URL] = []
        var otherEffects = 0
        func perform(_ intent: AgentFileOutputIntent = .preview) -> AgentFileOutputOutcome {
            AgentFileOutputActionConsumer.perform(change: change, viewerSessionID: session,
                records: records.records, workspaceRoot: ledger.workspaceRoot, intent: intent,
                probe: AgentFileOutputTargetResolver.fileSystemProbe,
                open: { _ in otherEffects += 1; return true },
                reveal: { _ in otherEffects += 1; return true },
                copy: { _ in otherEffects += 1; return true },
                preview: { previews.append($0); return true })
        }
        #expect(perform() == .completed)
        #expect(previews == [file.resolvingSymlinksInPath().standardizedFileURL])
        let backup = file.appendingPathExtension("REVERSIBLE_MISSING_INPUT")
        try FileManager.default.moveItem(at: file, to: backup)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        print("OUTPUT1220_TYPED_DIAGNOSTIC ledgerRoot=\(ledger.workspaceRoot) root=\(root.path) standardizedRoot=\(root.standardizedFileURL.path) missingStandardizedTarget=\(file.standardizedFileURL.path) absoluteConfine=\(String(reflecting: FileChangeLedger.confine(relativeToWorkspaceRoot: file.path, workspaceRoot: ledger.workspaceRoot))) relativeConfine=\(String(reflecting: FileChangeLedger.confine(relativeToWorkspaceRoot: file.lastPathComponent, workspaceRoot: ledger.workspaceRoot)))")
        let missing = perform()
        #expect(missing == .failed(.missing))
        #expect(missing.message == AgentFileOutputFailure.missing.message)
        #expect(!missing.message.contains("超出授权工作区"))
        #expect(previews.count == 1)
        #expect(otherEffects == 0)
        #expect(facts.facts.count == 1)
        #expect(records.records == [record])
        try FileManager.default.moveItem(at: backup, to: file)
        #expect(AgentFileOutputTargetResolver.generatedFileDigest(file) == originalDigest)
        #expect(perform() == .completed)
        #expect(previews.count == 2)
        let outside = parent.appendingPathComponent("owned-outside.txt")
        try Data("owned outside must not be read".utf8).write(to: outside)
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        var probes = 0
        let escaped = AgentFileOutputActionConsumer.perform(change: change, viewerSessionID: session,
            records: records.records, workspaceRoot: ledger.workspaceRoot, intent: .preview,
            probe: { _ in probes += 1; return .readableFile },
            open: { _ in otherEffects += 1; return true },
            reveal: { _ in otherEffects += 1; return true },
            copy: { _ in otherEffects += 1; return true },
            preview: { previews.append($0); return true })
        #expect(escaped == .failed(.outOfBounds))
        #expect(probes == 0)
        #expect(previews.count == 2)
        #expect(otherEffects == 0)
        let unrelated = AgentFileOutputActionConsumer.perform(change: change, viewerSessionID: UUID().uuidString,
            records: records.records, workspaceRoot: ledger.workspaceRoot, intent: .preview,
            probe: { _ in probes += 1; return .readableFile }, open: { _ in false },
            reveal: { _ in false }, copy: { _ in false }, preview: { _ in false })
        #expect(unrelated == .failed(.unbound))
        #expect(probes == 0)
        // Restore by renaming the synthetic link away, without deletion or
        // editing canonical producer records. Every produced byte is retained.
        try FileManager.default.moveItem(at: file, to: file.appendingPathExtension("OWNED_SYMLINK_INPUT"))
        try FileManager.default.moveItem(at: backup, to: file)
        #expect(perform() == .completed)
        #expect(previews.count == 3)
        #expect(AgentFileOutputTargetResolver.generatedFileDigest(file) == originalDigest)
        #expect(records.records == [record])
        #expect(facts.facts.count == 1)
        #expect(ledger.records(sessionID: session).count == 1)
    }
}
