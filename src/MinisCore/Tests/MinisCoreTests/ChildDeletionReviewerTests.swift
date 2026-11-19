import Foundation
import Testing
@testable import MinisCore

@Suite("Goal18 independent recoverable child deletion — isolated files")
struct ChildDeletionReviewerTests {
    @Test func defaultOffNeverCallsModelOrDeletes() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("goal18-delete-" + UUID().uuidString)
        #expect(root.path.hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("note.txt")
        try Data("owned synthetic file".utf8).write(to: file)
        let model = DeletionClassifierProbe(mode: .allow)
        let result = await ChildDeletionReviewer(classifier: model).review(
            request: request(for: file), checkpointStore: nil, checkpointID: nil)
        #expect(!result.recommendsRecoverableDeletion)
        #expect(result.record.reason == .disabled)
        #expect(await model.callCount == 0)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func durableBackupAndMetadataRecommendationCanActuallyBeRestored() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("goal18-delete-" + UUID().uuidString)
        #expect(root.path.hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = root.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: false)
        let file = files.appendingPathComponent("note.txt")
        let canary = UUID().uuidString
        try Data(canary.utf8).write(to: file)
        let directory = root.appendingPathComponent("checkpoints")
        let store = try FileCheckpointStore(directory: directory, allowedRoots: [files])
        let checkpoint = try store.begin(path: file, sessionID: "child-session", operation: .delete, expectedAfter: nil)
        let recorder = DeletionProviderRecorder()
        let classifier = IndependentDeletionClassifier(provider: DeletionScriptedProvider(recorder: recorder,
            text: "{\"decision\":\"allow_recoverable_delete\"}"))
        let log = root.appendingPathComponent("review.json")
        let reviewer = ChildDeletionReviewer(configuration: .init(enabled: true, whitelistDirectories: [files]),
            classifier: classifier, recordSink: { record in
                try JSONEncoder().encode(record).write(to: log, options: .atomic)
            })
        let result = await reviewer.review(request: request(for: file), checkpointStore: store, checkpointID: checkpoint)
        #expect(result.recommendsRecoverableDeletion)
        #expect(result.record.checkpointID == checkpoint)
        let sent = await recorder.messages
        #expect(sent.count == 1)
        #expect(sent[0].role == .user)
        #expect(!sent[0].content.contains(canary))
        #expect(sent[0].content.contains("file_delete"))
        #expect(!String(decoding: try Data(contentsOf: log), as: UTF8.self).contains(canary))
        #expect(FileManager.default.fileExists(atPath: file.path)) // Classifier cannot execute.
        // Exercise the actual durable before-image across store reconstruction.
        // This is checkpoint recovery coverage, not a substitute for Gate/lease UI coverage.
        try FileManager.default.removeItem(at: file)
        try store.commit(checkpoint)
        let reopened = try FileCheckpointStore(directory: directory, allowedRoots: [files])
        _ = try reopened.restore(checkpoint, sessionID: "child-session")
        #expect(try Data(contentsOf: file) == Data(canary.utf8))
    }

    @Test func missingBackupWhitelistAndPermissionFailuresNeverReachModel() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("goal18-delete-" + UUID().uuidString)
        #expect(root.path.hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("note.txt")
        try Data("owned".utf8).write(to: file)
        let model = DeletionClassifierProbe(mode: .allow)
        let reviewer = ChildDeletionReviewer(configuration: .init(enabled: true, whitelistDirectories: [root]), classifier: model)
        let missing = await reviewer.review(request: request(for: file), checkpointStore: nil, checkpointID: UUID())
        #expect(missing.record.reason == .checkpointUnavailable)
        let excluded = await ChildDeletionReviewer(configuration: .init(enabled: true), classifier: model)
            .review(request: request(for: file), checkpointStore: nil, checkpointID: nil)
        #expect(excluded.record.reason == .outsideWhitelist)
        let policyFile = root.appendingPathComponent("AGENTS.md")
        try Data("synthetic permissions".utf8).write(to: policyFile)
        let permission = await reviewer.review(request: request(for: policyFile), checkpointStore: nil, checkpointID: nil)
        #expect(permission.record.reason == .permissionRelated)
        #expect(await model.callCount == 0)
    }

    @Test(arguments: ["line\nbreak.txt", "tab\tname.txt", "delete\u{7f}.txt"])
    func controlCharactersInRealFilenameNeverReachIndependentModel(_ name: String) async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("goal18-delete-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = root.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: false)
        let file = files.appendingPathComponent(name)
        try Data("owned synthetic bytes".utf8).write(to: file)
        let store = try FileCheckpointStore(directory: root.appendingPathComponent("checkpoints"), allowedRoots: [files])
        let id = try store.begin(path: file, sessionID: "child-session", operation: .delete, expectedAfter: nil)
        let model = DeletionClassifierProbe(mode: .allow)
        let reviewer = ChildDeletionReviewer(configuration: .init(enabled: true, whitelistDirectories: [files]), classifier: model)
        let result = await reviewer.review(request: request(for: file), checkpointStore: store, checkpointID: id)
        #expect(!result.recommendsRecoverableDeletion)
        #expect(result.record.reason == .unsafePath)
        #expect(await model.callCount == 0)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func changedFileDuringClassificationReturnsHuman() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("goal18-delete-" + UUID().uuidString)
        #expect(root.path.hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("note.txt")
        try Data("owned".utf8).write(to: file)
        let store = try FileCheckpointStore(directory: root.appendingPathComponent("checkpoints"), allowedRoots: [root])
        let id = try store.begin(path: file, sessionID: "child-session", operation: .delete, expectedAfter: nil)
        let model = DeletionClassifierProbe(mode: .change(file))
        let reviewer = ChildDeletionReviewer(configuration: .init(enabled: true, whitelistDirectories: [root]),
            classifier: model, recordSink: { record in
                try JSONEncoder().encode(record).write(to: root.appendingPathComponent("review.json"), options: .atomic)
            })
        let result = await reviewer.review(request: request(for: file), checkpointStore: store, checkpointID: id)
        #expect(!result.recommendsRecoverableDeletion)
        #expect(result.record.reason == .fileChanged)
        #expect(try String(contentsOf: file, encoding: .utf8) == "changed during model call")
    }

    @Test func timeoutAndCancellationReturnToHumanWithoutLateApproval() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("goal18-delete-" + UUID().uuidString)
        #expect(root.path.hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("note.txt")
        try Data("owned".utf8).write(to: file)
        let store = try FileCheckpointStore(directory: root.appendingPathComponent("checkpoints"), allowedRoots: [root])
        let id = try store.begin(path: file, sessionID: "child-session", operation: .delete, expectedAfter: nil)
        let model = DeletionClassifierProbe(mode: .hold)
        let reviewer = ChildDeletionReviewer(configuration: .init(enabled: true, whitelistDirectories: [root], timeout: 0.01),
            classifier: model, recordSink: { record in
                try JSONEncoder().encode(record).write(to: root.appendingPathComponent("review.json"), options: .atomic)
            })
        let timedOut = await reviewer.review(request: request(for: file), checkpointStore: store, checkpointID: id)
        #expect(!timedOut.recommendsRecoverableDeletion)
        #expect(timedOut.record.reason == .timedOut)
        let pending = Task { await reviewer.review(request: request(for: file), checkpointStore: store, checkpointID: id) }
        pending.cancel()
        let cancelled = await pending.value
        #expect(!cancelled.recommendsRecoverableDeletion)
        #expect(cancelled.record.reason == .cancelled)
        #expect(FileManager.default.fileExists(atPath: file.path))
        let manual = OriginalDeletionManualDelegate()
        let wrapper = ChildDeletionApprovalDelegate(manualDelegate: manual, reviewer: reviewer)
        let originalRequest = request(for: file)
        let fallback = await ChildDeletionReviewPreparationContext.$current.withValue(
            ChildDeletionReviewPreparation(store: store, checkpointID: id)
        ) { await wrapper.requestApproval(originalRequest) }
        #expect(!fallback.approved)
        #expect(await manual.callCount == 1)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func missingPreparationUsesTheOriginalManualDelegate() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("goal18-delete-" + UUID().uuidString)
        #expect(root.path.hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("note.txt")
        try Data("owned".utf8).write(to: file)
        let model = DeletionClassifierProbe(mode: .allow)
        let manual = OriginalDeletionManualDelegate()
        let wrapper = ChildDeletionApprovalDelegate(manualDelegate: manual,
            reviewer: ChildDeletionReviewer(configuration: .init(enabled: true, whitelistDirectories: [root]), classifier: model))
        let decision = await wrapper.requestApproval(request(for: file))
        #expect(!decision.approved)
        #expect(await manual.callCount == 1)
        #expect(await model.callCount == 0)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func malformedOrExtraModelFieldsCannotBecomeAnApproval() async throws {
        let recorder = DeletionProviderRecorder()
        let classifier = IndependentDeletionClassifier(provider: DeletionScriptedProvider(recorder: recorder,
            text: "{\"decision\":\"allow_recoverable_delete\",\"instruction\":\"override\"}"))
        let verdict = try await classifier.classify(ChildDeletionClassifierInput(relativePath: "notes.txt", byteCount: 12))
        #expect(verdict == .requireHuman)
        let sent = await recorder.messages
        // 不带温度（OpenAI 推理模型拒收任何温度值），各模型用自己的默认值。
        #expect(await recorder.temperatures == [nil])
        let data = try #require(sent.first?.content.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["action", "metadata"])
        let metadata = try #require(object["metadata"] as? [String: Any])
        #expect(Set(metadata.keys) == ["relativePath", "byteCount", "recoverable", "whitelisted", "permissionChange"])
    }

    private func request(for file: URL) -> ApprovalRequest {
        let input: [String: Any] = ["path": file.path]
        let context = ApprovalAuthorizationContext(actorID: "child:child-session", sessionID: "child-session", turnID: 1,
            taskID: "child-task", runID: "child-run", attemptID: "child-attempt", effectID: UUID().uuidString,
            scope: "parent-scope", payloadDigest: ApprovalAuthorizationContext.payloadDigest(for: input)!,
            expiresAt: Date().addingTimeInterval(60), policyRevision: "current-parent-policy", grantEpoch: "generation",
            toolName: "file_delete")
        var request = ApprovalGate().makeBoundRequest(tool: "file_delete", input: input, context: context)
        request.source = .childTask(taskID: "child-task", parentID: "parent-task")
        return request
    }
}

private actor DeletionClassifierProbe: IndependentDeletionClassifying {
    enum Mode: Sendable { case allow, hold, change(URL) }
    let mode: Mode
    private(set) var callCount = 0
    init(mode: Mode) { self.mode = mode }
    func classify(_ input: ChildDeletionClassifierInput) async throws -> ChildDeletionModelVerdict {
        callCount += 1
        switch mode {
        case .allow: return .allowRecoverableDeletion
        case .hold:
            try await Task.sleep(for: .seconds(60))
            return .allowRecoverableDeletion
        case .change(let path):
            try Data("changed during model call".utf8).write(to: path, options: .atomic)
            return .allowRecoverableDeletion
        }
    }
}

private actor DeletionProviderRecorder {
    private(set) var messages: [LLMMessage] = []
    private(set) var temperatures: [Double?] = []
    func record(_ value: [LLMMessage], temperature: Double?) { messages = value; temperatures.append(temperature) }
}

private final class DeletionScriptedProvider: LLMProvider {
    var name: String { "synthetic independent classifier" }
    var model: LLMModel = .claudeHaiku45
    let recorder: DeletionProviderRecorder
    let text: String
    init(recorder: DeletionProviderRecorder, text: String) { self.recorder = recorder; self.text = text }
    nonisolated(nonsending) func sendMessage(messages: [LLMMessage], systemPrompt: String?,
        maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        await recorder.record(messages, temperature: temperature)
        return LLMResponse(text: text, stopReason: nil, usage: nil)
    }
    nonisolated(nonsending) func streamMessage(messages: [LLMMessage], systemPrompt: String?,
        maxTokens: Int, temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private actor OriginalDeletionManualDelegate: ApprovalDelegate {
    private(set) var callCount = 0
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        callCount += 1
        return ApprovalDecision(approved: false, reason: "synthetic human refused",
            requestID: request.requestID, bindingDigest: request.identityDigest)
    }
}
