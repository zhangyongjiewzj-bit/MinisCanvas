import Testing
import Foundation
@testable import MinisCanvasApp

// MARK: - F21b（用户级 P0-2）生视频 taskID 持久化
//
// 病根：submit 返回的 taskID 只是 generateVideo 便捷包装里的局部变量、全链路无落盘 ——
// App 重启后云端任务失联、重试盲目重新 submit 二次扣费。
// 修复：VideoTaskStore（videoTasks.json）+ invoker 手动 submit/poll 每步落盘 +
// clientToken/提示词指纹本地防重。本套件验证存储层与指纹确定性（临时目录隔离，
// 绝不读写真实 <AppSupport>/MinisCore/videoTasks.json）。

@Suite("F21b VideoTaskStore")
struct F21bVideoTaskStoreTests {

    /// 唯一临时目录（测试隔离）
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("f21b-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// taskID 存取：submit 登记后落盘，新实例（模拟 App 重启）读回同一记录
    @Test func submitRecordPersistsAcrossInstances() throws {
        let dir = try makeTempDir()
        let nodeID = UUID()
        let store = VideoTaskStore(directory: dir)
        store.recordSubmitted(
            id: "token-1", nodeID: nodeID, providerID: "kling",
            taskID: "task-abc", promptFingerprint: "fp-1"
        )

        // 新实例 = 模拟 App 重启后从盘上恢复
        let reopened = VideoTaskStore(directory: dir)
        let record = reopened.record(id: "token-1")
        #expect(record?.taskID == "task-abc", "taskID 必须跨重启可读（续查的前提）")
        #expect(record?.providerID == "kling")
        #expect(record?.nodeID == nodeID)
        #expect(record?.status == .submitted)
        #expect(record?.promptFingerprint == "fp-1")
    }

    /// 续查列表：只有未终态（submitted）任务进 pendingTasks
    @Test func pendingTasksListsOnlyUnfinished() throws {
        let dir = try makeTempDir()
        let store = VideoTaskStore(directory: dir)
        store.recordSubmitted(id: "t1", nodeID: UUID(), providerID: "kling", taskID: "task-1", promptFingerprint: "fp-1")
        store.recordSubmitted(id: "t2", nodeID: UUID(), providerID: "jimeng", taskID: "task-2", promptFingerprint: "fp-2")
        store.recordSubmitted(id: "t3", nodeID: UUID(), providerID: "kling", taskID: "task-3", promptFingerprint: "fp-3")
        store.markSucceeded(id: "t2", videoURL: "https://example.com/v.mp4")

        let pending = store.pendingTasks()
        #expect(pending.count == 2, "t2 已终态，只剩 t1/t3 待续查")
        #expect(Set(pending.map(\.id)) == ["t1", "t3"])
        #expect(pending.allSatisfy { $0.status == .submitted })
    }

    /// 防重查询：同节点同指纹的未终态任务命中（invoker 据此续轮询而非重新 submit）
    @Test func dedupeLookupHitsSameNodeAndFingerprintOnly() throws {
        let dir = try makeTempDir()
        let nodeID = UUID()
        let store = VideoTaskStore(directory: dir)
        store.recordSubmitted(id: "t1", nodeID: nodeID, providerID: "kling", taskID: "task-1", promptFingerprint: "fp-A")

        // 同节点同指纹 → 命中
        #expect(store.pendingTask(nodeID: nodeID, promptFingerprint: "fp-A")?.id == "t1")
        // 同节点不同指纹（改了提示词）→ 不命中（新意图允许重新提交）
        #expect(store.pendingTask(nodeID: nodeID, promptFingerprint: "fp-B") == nil)
        // 不同节点同指纹 → 不命中（节点隔离）
        #expect(store.pendingTask(nodeID: UUID(), promptFingerprint: "fp-A") == nil)

        // 任务终态后 → 不再命中（允许同一意图重新生成）
        store.markSucceeded(id: "t1", videoURL: "https://example.com/v.mp4")
        #expect(store.pendingTask(nodeID: nodeID, promptFingerprint: "fp-A") == nil)
    }

    /// 终态落盘：succeeded 带 URL、failed 带原因，均从 pending 移除且可读
    @Test func terminalStatesPersistOutcome() throws {
        let dir = try makeTempDir()
        let store = VideoTaskStore(directory: dir)
        store.recordSubmitted(id: "ok", nodeID: UUID(), providerID: "kling", taskID: "task-ok", promptFingerprint: "fp-1")
        store.recordSubmitted(id: "bad", nodeID: UUID(), providerID: "jimeng", taskID: "task-bad", promptFingerprint: "fp-2")

        store.markSucceeded(id: "ok", videoURL: "https://cdn.example.com/out.mp4")
        store.markFailed(id: "bad", message: "内容审核未通过")

        let reopened = VideoTaskStore(directory: dir)
        #expect(reopened.record(id: "ok")?.status == .succeeded)
        #expect(reopened.record(id: "ok")?.videoURL == "https://cdn.example.com/out.mp4")
        #expect(reopened.record(id: "bad")?.status == .failed)
        #expect(reopened.record(id: "bad")?.errorMessage == "内容审核未通过")
        #expect(reopened.pendingTasks().isEmpty)
    }

    @Test func duplicateTerminalSuccessCannotOverwritePersistedOutcome() throws {
        let dir = try makeTempDir()
        let store = VideoTaskStore(directory: dir)
        store.recordSubmitted(
            id: "duplicate-success",
            nodeID: UUID(),
            providerID: "kling",
            taskID: "task-success",
            promptFingerprint: "fp-success"
        )

        #expect(store.markSucceeded(
            id: "duplicate-success",
            videoURL: "https://cdn.example.com/first.mp4",
            assetPath: "/tmp/first.mp4"
        ))
        #expect(store.markSucceeded(
            id: "duplicate-success",
            videoURL: "https://cdn.example.com/late.mp4",
            assetPath: "/tmp/late.mp4"
        ))

        let reopened = VideoTaskStore(directory: dir)
        let record = try #require(reopened.record(id: "duplicate-success"))
        #expect(record.status == .succeeded)
        #expect(record.videoURL == "https://cdn.example.com/first.mp4")
        #expect(record.assetPath == "/tmp/first.mp4")
    }

    /// 损坏文件隔离：videoTasks.json 内容损坏 → 空集加载，不崩溃不阻塞画布
    @Test func corruptedFileLoadsEmpty() throws {
        let dir = try makeTempDir()
        try "{broken json".data(using: .utf8)!.write(
            to: dir.appendingPathComponent(VideoTaskStore.fileName))
        let store = VideoTaskStore(directory: dir)
        #expect(store.allRecords().isEmpty)
        #expect(store.pendingTasks().isEmpty)
    }

    /// Int.max attempt 必须 fail closed，且不能把原终态记录改成半更新状态。
    @Test func retryAtMaximumAttemptLeavesRecordUnchanged() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = VideoTaskRecord(
            id: "attempt-max",
            nodeID: UUID(),
            providerID: "kling",
            taskID: "remote-attempt-max",
            promptFingerprint: "fp-attempt-max",
            status: .canceled,
            attempt: Int.max,
            remoteCancellationState: .accepted,
            errorMessage: "任务已取消"
        )
        let data = try JSONEncoder().encode([original])
        try data.write(
            to: dir.appendingPathComponent(VideoTaskStore.fileName),
            options: .atomic
        )

        let store = VideoTaskStore(directory: dir)
        let before = try #require(store.record(id: original.id))
        #expect(before.attempt == Int.max)
        #expect(before.status == .canceled)
        #expect(before.taskID == "remote-attempt-max")
        #expect(store.retry(id: original.id) == nil)
        #expect(store.record(id: original.id) == before)
    }

    /// 指纹确定性：FNV-1a 跨进程稳定（Hasher 随机种子会破坏重启续查），且去首尾空白
    @Test func promptFingerprintDeterministicAndTrimmed() {
        let a = MinisCanvasVideoInvoker.promptFingerprint("  夜色中的剑客缓缓抬头  ")
        let b = MinisCanvasVideoInvoker.promptFingerprint("夜色中的剑客缓缓抬头")
        #expect(a == b, "首尾空白不应改变指纹")
        #expect(a.count == 16, "16 位十六进制")
        #expect(a != MinisCanvasVideoInvoker.promptFingerprint("夜色中的剑客缓缓低头"),
                "不同提示词指纹必须不同")
    }
}
