import Foundation
import Darwin
import Testing
@testable import MinisCore

@Suite("Goal18 approval preview — real temporary files")
struct ApprovalFilePreviewTests {
    @Test func deletionReviewerRemainsOffWithoutEveryPrerequisite() {
        var prerequisites = ChildDeletionReviewPrerequisites()
        #expect(!prerequisites.canRequestIndependentReview)
        prerequisites.enabled = true
        prerequisites.isWhitelisted = true
        prerequisites.changesPermissions = false
        #expect(!prerequisites.canRequestIndependentReview)
        prerequisites.hasRecoverableCheckpoint = true
        #expect(prerequisites.canRequestIndependentReview)
        prerequisites.changesPermissions = true
        #expect(!prerequisites.canRequestIndependentReview)
        prerequisites.changesPermissions = false
        prerequisites.isWhitelisted = false
        #expect(!prerequisites.canRequestIndependentReview)
    }

    @Test func sameLengthMutationInvalidatesOldPreview() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("goal18-approval-" + UUID().uuidString)
        #expect(root.standardizedFileURL.path.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path + "/"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("note.txt")
        try Data("before".utf8).write(to: target)
        let preview = try #require(ApprovalFilePreview.capture(tool: "file_edit", input: ["path": target.path, "old_string": "before", "new_string": "after!"]))
        try preview.validateCurrent()
        try Data("change".utf8).write(to: target)
        #expect(throws: ApprovalFileChangedError.self) { try preview.validateCurrent() }
    }

    @Test func mutationWhileHumanIsApprovingCannotAuthorizeOldFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("goal18-approval-" + UUID().uuidString)
        #expect(root.standardizedFileURL.path.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path + "/"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("note.txt")
        try Data("before".utf8).write(to: target)
        let gate = ApprovalGate(delegate: MutatingFileApprovalDelegate(target: target))
        await #expect(throws: ApprovalFileChangedError.self) {
            _ = try await gate.gate(tool: "file_write", input: ["path": target.path, "content": "approved proposal"])
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "concurrent change")
    }

    @Test func oneConcurrentChangeRequestsFreshPreviewForSameAction() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("goal18-approval-" + UUID().uuidString)
        #expect(root.standardizedFileURL.path.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path + "/"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("note.txt")
        try Data("before".utf8).write(to: target)
        let delegate = ChangeOnceFileApprovalDelegate(target: target)
        let gate = ApprovalGate(delegate: delegate)
        let decision = try await gate.gate(tool: "file_write", input: ["path": target.path, "content": "same proposal"], callID: "same-model-action")
        #expect(decision.approved)
        let requests = await delegate.requests
        #expect(requests.count == 2)
        #expect(requests[0].callID == requests[1].callID)
        #expect(requests[0].requestID != requests[1].requestID)
        #expect(requests[0].filePreview?.version != requests[1].filePreview?.version)
        #expect(decision.filePreview == requests[1].filePreview)
        try decision.filePreview?.validateCurrent()
    }

    @Test func sensitiveFileCanaryNeverReachesPreviewOrSummary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("goal18-approval-" + UUID().uuidString)
        #expect(root.standardizedFileURL.path.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path + "/"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let canary = UUID().uuidString
        for filename in [".env", ".env.local", "id_rsa", "id_ed25519", "private.pem"] {
            let target = root.appendingPathComponent(filename)
            try Data(canary.utf8).write(to: target)
            let request = ApprovalGate().makeRequest(tool: "file_write", input: ["path": target.path, "content": canary])
            let preview = try #require(request.filePreview)
            #expect(preview.isSensitive)
            #expect(!preview.text.contains(canary))
            #expect(!request.inputSummary.contains(canary))
            #expect(request.inputRiskLevel == .high)
        }
    }

    @Test func boundedPreviewRedactsBeforeTruncating() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("goal18-approval-" + UUID().uuidString)
        #expect(root.standardizedFileURL.path.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path + "/"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("note.txt")
        let canary = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let text = "Authorization: Bearer " + canary + "\n" + String(repeating: "visible", count: 4000)
        let preview = try #require(ApprovalFilePreview.capture(tool: "file_write", input: ["path": target.path, "content": text]))
        #expect(!preview.text.contains(canary))
        #expect(preview.text.count <= ApprovalFilePreview.maximumCharacters + 32)
        #expect(preview.text.contains("预览已截断"))
    }

    @Test func newlyCreatedTargetInvalidatesMissingFileApproval() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("goal18-approval-" + UUID().uuidString)
        #expect(root.standardizedFileURL.path.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path + "/"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("new.txt")
        let version = try ApprovalFileVersion.capture(path: target.path)
        try Data("created by someone else".utf8).write(to: target)
        #expect(throws: ApprovalFileChangedError.self) { try version.validateCurrent() }
    }
}

/// Only the human response is scripted; the production gate and real filesystem
/// mutation are exercised. No fake executor or simulated file-version result.
private struct MutatingFileApprovalDelegate: ApprovalDelegate {
    let target: URL
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        do { try Data("concurrent change".utf8).write(to: target, options: .atomic) }
        catch { return .deny }
        return ApprovalDecision(approved: true, confirmed: true,
            requestID: request.requestID, bindingDigest: request.identityDigest, filePreview: request.filePreview)
    }
}

private actor ChangeOnceFileApprovalDelegate: ApprovalDelegate {
    let target: URL
    private(set) var requests: [ApprovalRequest] = []
    init(target: URL) { self.target = target }
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        requests.append(request)
        if requests.count == 1 {
            do { try Data("changed once".utf8).write(to: target, options: .atomic) }
            catch { return .deny }
        }
        return ApprovalDecision(approved: true, confirmed: true, requestID: request.requestID,
            bindingDigest: request.identityDigest, filePreview: request.filePreview)
    }
}


@Suite("Goal18 final file check precedes approval identity consumption")
struct ApprovalFileConsumptionOrderingTests {
    @Test func receiptAwaitMutationGetsOneFreshPreviewWithoutReplayingOldGrant() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("goal18-gate-order-" + UUID().uuidString)
        #expect(root.path.hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("note.txt")
        try Data("before".utf8).write(to: file)
        let input: [String: Any] = ["path": file.path, "content": "proposal"]
        let identity = context(input: input)
        let human = OrderedFileHumanDelegate()
        let sink = ReceiptFileMutationSink(file: file, mutateEveryTime: false)
        let gate = ApprovalGate(delegate: human, onApprovalReceipt: { _ in try await sink.receive() })
        let decision = try await gate.gate(tool: "file_write", input: input, context: identity)
        let shown = await human.requests
        #expect(shown.count == 2)
        #expect(shown[0].requestID != shown[1].requestID)
        #expect(shown[0].callID == shown[1].callID)
        #expect(shown[0].effectID == identity.effectID)
        #expect(shown[1].effectID == identity.effectID)
        #expect(shown[0].identityDigest == shown[1].identityDigest)
        #expect(decision.filePreview == shown[1].filePreview)
        #expect(throws: ApprovalFileChangedError.self) { try shown[0].filePreview?.validateCurrent() }
        try decision.filePreview?.validateCurrent()
        // No stale preview can authorize the final proposed write.
        #expect(try String(contentsOf: file, encoding: .utf8) != "proposal")
        await #expect(throws: ApprovalError.self) {
            _ = try await gate.gate(tool: "file_write", input: input, context: identity)
        }
    }

    @Test func repeatedChangesAbortBeforeConsumptionAndNeverWriteProposal() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("goal18-gate-order-" + UUID().uuidString)
        #expect(root.path.hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("note.txt")
        try Data("before".utf8).write(to: file)
        let input: [String: Any] = ["path": file.path, "content": "proposal"]
        let identity = context(input: input)
        let human = OrderedFileHumanDelegate()
        let sink = ReceiptFileMutationSink(file: file, mutateEveryTime: true)
        let gate = ApprovalGate(delegate: human, onApprovalReceipt: { _ in try await sink.receive() })
        await #expect(throws: ApprovalFileChangedError.self) {
            _ = try await gate.gate(tool: "file_write", input: input, context: identity)
        }
        #expect(await human.requests.count == 2)
        #expect(try String(contentsOf: file, encoding: .utf8) != "proposal")
        // Both stale human decisions were discarded BEFORE consumption.
        // A real fresh approval can still use this original unconsumed identity.
        let stableGate = ApprovalGate(delegate: human)
        let fresh = try await stableGate.gate(tool: "file_write", input: input, context: identity)
        #expect(fresh.approved)
        try fresh.filePreview?.validateCurrent()
        await #expect(throws: ApprovalError.self) {
            _ = try await stableGate.gate(tool: "file_write", input: input, context: identity)
        }
    }

    @Test func wrongAnswerIdentityCannotReachSinkOrConsumeFileApproval() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("goal18-gate-order-" + UUID().uuidString)
        #expect(root.path.hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("note.txt")
        try Data("before".utf8).write(to: file)
        let input: [String: Any] = ["path": file.path, "content": "proposal"]
        let identity = context(input: input)
        let sink = ReceiptFileMutationSink(file: file, mutateEveryTime: false)
        let invalid = ApprovalGate(delegate: WrongFileHumanDelegate(), onApprovalReceipt: { _ in try await sink.receive() })
        await #expect(throws: ApprovalError.self) {
            _ = try await invalid.gate(tool: "file_write", input: input, context: identity)
        }
        #expect(await sink.count == 0)
        #expect(try String(contentsOf: file, encoding: .utf8) == "before")
        let fresh = try await ApprovalGate(delegate: OrderedFileHumanDelegate()).gate(tool: "file_write", input: input, context: identity)
        #expect(fresh.approved)
    }

    private func context(input: [String: Any]) -> ApprovalAuthorizationContext {
        ApprovalAuthorizationContext(actorID: "parent", sessionID: "synthetic-session", turnID: 1,
            taskID: "task", runID: "run", attemptID: "canonical-attempt", effectID: UUID().uuidString,
            scope: "request", payloadDigest: ApprovalAuthorizationContext.payloadDigest(for: input)!,
            expiresAt: Date().addingTimeInterval(60), policyRevision: "current", grantEpoch: "current-generation",
            toolName: "file_write")
    }
}

private actor OrderedFileHumanDelegate: ApprovalDelegate {
    private(set) var requests: [ApprovalRequest] = []
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        requests.append(request)
        return ApprovalDecision(approved: true, confirmed: true, requestID: request.requestID,
            bindingDigest: request.identityDigest, filePreview: request.filePreview)
    }
}
private struct WrongFileHumanDelegate: ApprovalDelegate {
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        ApprovalDecision(approved: true, confirmed: true, requestID: "wrong-request",
            bindingDigest: request.identityDigest, filePreview: request.filePreview)
    }
}
private actor ReceiptFileMutationSink {
    let file: URL
    let mutateEveryTime: Bool
    private(set) var count = 0
    init(file: URL, mutateEveryTime: Bool) { self.file = file; self.mutateEveryTime = mutateEveryTime }
    func receive() throws {
        count += 1
        if mutateEveryTime || count == 1 {
            try Data("concurrent receipt change \(count)".utf8).write(to: file, options: .atomic)
        }
    }
}

extension ApprovalFilePreviewTests {
    @Test func shellPreviewBoundsLinesBytesAndKeepsWorkingDirectoryReadable() throws {
        let command = (1...24).map { "printf '合成第\($0)行'" }.joined(separator: "\n")
        let preview = try #require(ApprovalFilePreview.capture(tool: "shell_execute", input: [
            "command": command, "cwd": "/synthetic/project-a"
        ]))
        #expect(preview.text.contains("/synthetic/project-a"))
        #expect(preview.text.split(separator: "\n", omittingEmptySubsequences: false).count <= 20)
        let expanded = try #require(preview.expandedText)
        #expect(expanded.contains("第24行"))
        #expect(expanded.utf8.count <= 4 * 1024)
        try preview.validateCurrent()
        let long = try #require(ApprovalFilePreview.capture(tool: "shell_execute", input: [
            "command": String(repeating: "中文", count: 3000)
        ]))
        #expect(long.text.utf8.count <= 4 * 1024)
        #expect(!long.text.contains("�"))
    }

    @Test func overwritePreviewStreamsOldFileBeyondDeleteLimitWithoutRetainingItsBody() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("approval-write-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("note.txt")
        // 超过 256KiB 的旧文件不再出内容对比（≤256KiB 的 UTF-8 文件才出 diff），也不在预览里留正文。
        let old = String(repeating: "synthetic old line\n", count: 15000)
        let oldData = Data(old.utf8)
        #expect(oldData.count > 256 * 1024)
        try oldData.write(to: target)
        let input = try ComposerToolInput(["path": target.path, "content": "new\ntext\n"])
        let preview = try await BuiltinToolExecutor(allowedRoot: root).prepareFileApprovalPreview(tool: "file_write", input: input)
        #expect(preview.text.contains(target.path))
        #expect(preview.text.contains("拟写入大小：9 bytes"))
        #expect(preview.text.contains("将覆盖"))
        #expect(preview.text.contains("15000 → 2（差 -14998）"))
        #expect(!preview.text.contains("synthetic old line"))
        #expect(preview.deletionContentDigest == ApprovalFilePreview.digest(oldData))
        #expect(throws: ApprovalFileChangedError.self) {
            try preview.validateMutation(data: Data((old + "tail change").utf8))
        }
    }

    @Test func editPreviewUsesSourceLineNumbersAndThreeContextLinesThenBoundedExpansion() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("approval-edit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("note.txt")
        let old = (1...100).map { "line\($0)" }.joined(separator: "\n")
        try Data(old.utf8).write(to: target)
        let owner = BuiltinToolExecutor(allowedRoot: root)
        let input = try ComposerToolInput(["path": target.path, "old_string": "line50\n", "new_string": "changed50\n"])
        let preview = try await owner.prepareFileApprovalPreview(tool: "file_edit", input: input)
        #expect(preview.text.contains("@@ -47,7 +47,7 @@"))
        #expect(preview.text.contains(" line47"))
        #expect(preview.text.contains(" line53"))
        #expect(!preview.text.contains(" line46"))
        #expect(preview.text.contains("-line50"))
        #expect(preview.text.contains("+changed50"))
        let replacement = String(repeating: "changed line\n", count: 200)
        let wideInput = try ComposerToolInput(["path": target.path, "old_string": old, "new_string": replacement])
        let wide = try await owner.prepareFileApprovalPreview(tool: "file_edit", input: wideInput)
        #expect(wide.text.split(separator: "\n", omittingEmptySubsequences: false).count <= 80)
        #expect(wide.text.utf8.count <= 8 * 1024)
        #expect(try #require(wide.expandedText).utf8.count <= 64 * 1024)
    }
}

extension ApprovalFilePreviewTests {
    @Test(.enabled(if: geteuid() != 0))
    func writeOnlyTargetKeepsExplicitUnavailableBeforeImageAndOriginalWrite() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("approval-write-only-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("note.txt")
        try Data("unreadable old text".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o200], ofItemAtPath: target.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path) }
        let owner = BuiltinToolExecutor(allowedRoot: root)
        let input = try ComposerToolInput(["path": target.path, "content": "replacement\n"])
        let preview = try await owner.prepareFileApprovalPreview(tool: "file_write", input: input)
        #expect(preview.text.contains("旧内容不可读；旧行数差/旧全文摘要不可用"))
        #expect(preview.text.contains("replacement"))
        #expect(preview.deletionContentDigest == nil)
        _ = try await ApprovalFilePreviewContext.$current.withValue(preview) {
            try await owner.execute(name: "file_write", input: input.toolExecutionDictionary)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        #expect(try String(contentsOf: target, encoding: .utf8) == "replacement\n")
    }
}
