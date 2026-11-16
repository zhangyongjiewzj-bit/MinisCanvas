import Foundation
import Testing
@testable import MinisCore

private actor Goal18ReviewDelegate: ApprovalDelegate {
    private var requests: [ApprovalRequest] = []
    let changeDuringSecondReview: URL?
    let changeDuringFirstReview: URL?
    init(changeDuringSecondReview: URL? = nil, changeDuringFirstReview: URL? = nil) {
        self.changeDuringSecondReview = changeDuringSecondReview
        self.changeDuringFirstReview = changeDuringFirstReview
    }
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        requests.append(request)
        if requests.count == 1, let url = changeDuringFirstReview {
            try? Data("changed during first review".utf8).write(to: url, options: .atomic)
        }
        if requests.count == 2, let url = changeDuringSecondReview {
            try? Data("changed again".utf8).write(to: url, options: .atomic)
        }
        return ApprovalDecision(approved: true, confirmed: true, requestID: request.requestID,
            bindingDigest: request.identityDigest, filePreview: request.filePreview)
    }
    func requestIDs() -> [String] { requests.map(\.requestID) }
}
private struct Goal18TestFileWriter: ToolExecutor {
    func execute(name: String, input: [String: Any]) async throws -> String {
        let path = try #require(input["path"] as? String)
        let content = try #require(input["content"] as? String)
        try Data(content.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        return "written"
    }
}
@Suite("Goal18 Composer file review before consume")
struct Goal18ComposerFileReviewTests {
    private func executor(root: URL, delegate: Goal18ReviewDelegate) -> ComposerPolicyEnforcedToolExecutor {
        let name = UUID().uuidString
        let now = Date()
        let snapshot = ComposerSubmissionSnapshot(mode: .manual, approvalScope: .turn, effort: .standard,
            sessionID: name, turnID: 1, taskID: name, attemptID: name, messageID: name,
            workspaceID: name, createdAt: now, policyRevision: name, grantEpoch: name,
            bypassModeConfirmed: false, autonomyCeiling: .l3)
        let facts = ComposerPolicyFactSource(knownCapabilities: ["file_write"], grantedCapabilities: ["file_write"],
            allowedWriteRoots: [root.path], workspaceID: name, revision: name, grantEpoch: name,
            leaseID: name, expiresAt: now.addingTimeInterval(600), autonomyCeiling: .l3)
        return ComposerPolicyEnforcedToolExecutor(base: Goal18TestFileWriter(),
            controller: ComposerAuthorizationController(snapshot: snapshot, facts: facts),
            approvalGate: ApprovalGate(delegate: delegate))
    }
    @Test func staleUnconsumedApprovalIsReviewedOnceBeforeRealEffect() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Goal18FileReview-" + UUID().uuidString).resolvingSymlinksInPath()
        try #require(root.path.hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("sample.txt")
        try Data("first".utf8).write(to: path)
        let delegate = Goal18ReviewDelegate()
        let subject = executor(root: root, delegate: delegate)
        let authorization = try await subject.authorizeExecution(callID: "write", name: "file_write",
            input: ["path": path.path, "content": "result"])
        try Data("changed before consume".utf8).write(to: path, options: .atomic)
        let result = try await ToolFileMutationScope.withLock(path: path) {
            try await subject.execute(preauthorization: authorization, callID: "write", name: "file_write",
                input: ["path": path.path, "content": "result"])
        }
        #expect(result == "written")
        #expect(try Data(contentsOf: path) == Data("result".utf8))
        let ids = await delegate.requestIDs()
        #expect(ids.count == 2)
        #expect(ids[0] != ids[1])
        await #expect(throws: ComposerAuthorizationError.authorizationBindingMismatch) {
            try await subject.execute(preauthorization: authorization, callID: "write", name: "file_write",
                input: ["path": path.path, "content": "result"])
        }
    }
    @Test func aSecondFileChangeRefusesWithoutEffectOrThirdPrompt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Goal18FileReview-" + UUID().uuidString).resolvingSymlinksInPath()
        try #require(root.path.hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("sample.txt")
        try Data("first".utf8).write(to: path)
        let delegate = Goal18ReviewDelegate(changeDuringSecondReview: path)
        let subject = executor(root: root, delegate: delegate)
        let authorization = try await subject.authorizeExecution(callID: "write", name: "file_write",
            input: ["path": path.path, "content": "result"])
        try Data("changed before consume".utf8).write(to: path, options: .atomic)
        await #expect(throws: ApprovalFileChangedError.self) {
            try await ToolFileMutationScope.withLock(path: path) {
                try await subject.execute(preauthorization: authorization, callID: "write", name: "file_write",
                    input: ["path": path.path, "content": "result"])
            }
        }
        #expect(try Data(contentsOf: path) == Data("changed again".utf8))
        // Returning the same bytes does not restore ctime/version metadata.
        // Require the authorization-binding error (not a file-version error)
        // to prove this old authorization itself was explicitly retired.
        try Data("first".utf8).write(to: path, options: .atomic)
        await #expect(throws: ComposerAuthorizationError.authorizationBindingMismatch) {
            try await subject.execute(preauthorization: authorization, callID: "write", name: "file_write",
                input: ["path": path.path, "content": "result"])
        }
        #expect(try Data(contentsOf: path) == Data("first".utf8))
        #expect(await delegate.requestIDs().count == 2)
        // The failed pending review cannot leave scoped consent that skips a
        // fresh approval for a subsequent canonical call with the same input.
        let next = try await subject.authorizeExecution(callID: "write-again", name: "file_write",
            input: ["path": path.path, "content": "result"])
        #expect(await delegate.requestIDs().count == 3)
        await next.observeUnexecutedCancellation()
    }
    @Test func usedReviewBudgetStillRetiresStaleApprovalBeforeRefusing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Goal18FileReview-" + UUID().uuidString).resolvingSymlinksInPath()
        try #require(root.path.hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("sample.txt")
        try Data("first".utf8).write(to: path)
        let delegate = Goal18ReviewDelegate(changeDuringFirstReview: path)
        let subject = executor(root: root, delegate: delegate)
        let authorization = try await subject.authorizeExecution(callID: "write", name: "file_write",
            input: ["path": path.path, "content": "result"])
        #expect(await delegate.requestIDs().count == 2)
        try Data("third version".utf8).write(to: path, options: .atomic)
        await #expect(throws: ApprovalFileChangedError.self) {
            try await ToolFileMutationScope.withLock(path: path) {
                try await subject.execute(preauthorization: authorization, callID: "write", name: "file_write",
                    input: ["path": path.path, "content": "result"])
            }
        }
        try Data("changed during first review".utf8).write(to: path, options: .atomic)
        await #expect(throws: ComposerAuthorizationError.authorizationBindingMismatch) {
            try await subject.execute(preauthorization: authorization, callID: "write", name: "file_write",
                input: ["path": path.path, "content": "result"])
        }
        #expect(try Data(contentsOf: path) == Data("changed during first review".utf8))
        #expect(await delegate.requestIDs().count == 2)
    }

}
