import Foundation
import Observation
import MinisCore

/// Captured by the real Bridge child lifecycle. This is not a path-based grant:
/// the source retains the original scope, authority and resource lease.
struct P03CleanupAppResource: Sendable {
    let source: any GitChildWorktreeCleanupSource
    let managedRoot: GitChildWorktreeRoot
    let readOnly: GitChildWorktreeCleanupService.ReadOnlyExecutor
}

struct P03CleanupAppRow: Identifiable, Sendable {
    let id: UUID
    var snapshot: GitChildWorktreeCleanupSnapshot
    var failure: String?
    var result: GitChildWorktreeCleanupResult?
    var isBusy = false

    var status: String {
        if let result { return result.message }
        if isBusy { return "正在核验" }
        if let failure { return failure }
        if snapshot.taskIsActive { return "任务仍活动，不能清理" }
        if !snapshot.childScopeRevoked { return "子任务授权尚未撤销，不能清理" }
        if !snapshot.parentAuthorityValid { return "父项目授权失效，不能清理" }
        return "残留目录，需检查 Git 状态并逐次确认"
    }
    var canPrepare: Bool {
        result == nil && !isBusy && !snapshot.taskIsActive
            && snapshot.childScopeRevoked && snapshot.parentAuthorityValid
    }
}

/// 落盘的隔离目录登记：只记路径和分支，不含任何授权。
struct P03CleanupLeftoverRecord: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let taskID: String
    let workingDirectory: String
    let branch: String
    let recordedAt: Date
}

struct P03CleanupConfirmationGate: Sendable {
    private var pending: UUID?
    mutating func issue() -> UUID {
        let id = UUID()
        pending = id
        return id
    }
    mutating func cancel() { pending = nil }
    mutating func consume(_ id: UUID) -> Bool {
        guard pending == id else { return false }
        pending = nil
        return true
    }
}

struct P03CleanupAppConfirmation: Identifiable, Sendable {
    let id: UUID
    let resourceID: UUID
    let request: GitChildWorktreeCleanupRequest
}

@MainActor @Observable
final class P03CleanupAppController {
    private(set) var rows: [P03CleanupAppRow] = []
    private(set) var confirmation: P03CleanupAppConfirmation?
    /// True while the residual panel sheet is on screen. The task-center
    /// approval card is then hosted by the panel itself, because a sheet
    /// cannot present over another sheet's host.
    var isPanelPresented = false
    private let platformTrash: GitChildWorktreeCleanupService.ApprovedTrash

    init(platformTrash: @escaping GitChildWorktreeCleanupService.ApprovedTrash = {
        try P03CleanupPlatformTrash.move($0)
    }) {
        self.platformTrash = platformTrash
    }

    private var confirmationGate = P03CleanupConfirmationGate()
    private var reviewGeneration: UInt64 = 0
    private var resources: [UUID: P03CleanupAppResource] = [:]

    // MARK: 重启后可见的残留登记（只读展示，不是清理授权）

    private var persistedRecords: [P03CleanupLeftoverRecord] = []
    private var recordsURL: URL?
    private(set) var recordsError: String?

    /// 上次运行登记、本次运行没有对应授权来源的隔离目录。清理授权不落盘，
    /// 所以这里只能展示路径和分支，由用户自行核对处理。
    var leftovers: [P03CleanupLeftoverRecord] {
        persistedRecords.filter { resources[$0.id] == nil }
    }

    /// 由 App 组合根在启动时调用一次。登记文件读不出来时不覆盖它，只提示。
    func enablePersistence(at url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                persistedRecords = try JSONDecoder().decode([P03CleanupLeftoverRecord].self,
                                                            from: Data(contentsOf: url))
            } catch {
                recordsError = "残留隔离目录的登记文件读取失败，已保留原文件：\(UserFacingErrorText.describe(error))"
                return
            }
        }
        recordsURL = url
        for row in rows { addRecord(for: row.snapshot) }
    }

    func dismissLeftover(_ id: UUID) {
        persistedRecords.removeAll { $0.id == id }
        saveRecords()
    }

    private func addRecord(for snapshot: GitChildWorktreeCleanupSnapshot) {
        let id = snapshot.allocation.identity.executionID
        guard recordsURL != nil, !persistedRecords.contains(where: { $0.id == id }) else { return }
        persistedRecords.append(P03CleanupLeftoverRecord(
            id: id, taskID: snapshot.allocation.identity.taskID,
            workingDirectory: snapshot.allocation.workingDirectory,
            branch: snapshot.allocation.branch, recordedAt: Date()))
        saveRecords()
    }

    private func saveRecords() {
        guard let recordsURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: recordsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(persistedRecords).write(to: recordsURL, options: .atomic)
            recordsError = nil
        } catch {
            recordsError = "残留隔离目录的登记写入失败：\(UserFacingErrorText.describe(error))"
        }
    }

    /// Called once at actual allocation capture, never from a model URL/list scan.
    func register(_ resource: P03CleanupAppResource) async throws {
        let snapshot = try await resource.source.currentSnapshot()
        let id = snapshot.allocation.identity.executionID
        guard resources[id] == nil else {
            throw GitChildWorktreeCleanupService.CleanupError.rejected("此执行资源已登记，不能替换原清理归属")
        }
        resources[id] = resource
        rows.append(P03CleanupAppRow(id: id, snapshot: snapshot))
        addRecord(for: snapshot)
    }

    func refresh(_ id: UUID) async {
        guard let resource = resources[id], let index = index(id),
              rows[index].result == nil, !rows[index].isBusy else { return }
        do {
            let snapshot = try await resource.source.currentSnapshot()
            guard snapshot.allocation.identity.executionID == id else {
                throw GitChildWorktreeCleanupService.CleanupError.rejected("执行归属已改变，不能清理")
            }
            rows[index].snapshot = snapshot
            rows[index].failure = nil
        } catch { rows[index].failure = UserFacingErrorText.describe(error) }
    }

    /// The child finishes (scope.revoke) long after register() captured its
    /// row, so the panel re-reads every live snapshot when it opens.
    func refreshAll() async {
        for row in rows { await refresh(row.id) }
    }

    func prepare(_ id: UUID) async {
        guard confirmation == nil, let resource = resources[id], let index = index(id),
              rows[index].canPrepare, !rows.contains(where: { $0.isBusy }) else { return }
        let generation = reviewGeneration
        rows[index].isBusy = true
        defer { rows[index].isBusy = false }
        do {
            let request = try await GitChildWorktreeCleanupService.prepare(source: resource.source,
                managedRoot: resource.managedRoot, readOnly: resource.readOnly)
            guard request.snapshot.allocation.identity.executionID == id else {
                throw GitChildWorktreeCleanupService.CleanupError.rejected("执行归属已改变，未生成确认")
            }
            rows[index].snapshot = request.snapshot
            rows[index].failure = nil
            guard generation == reviewGeneration else { return }
            confirmation = P03CleanupAppConfirmation(id: confirmationGate.issue(), resourceID: id, request: request)
        } catch { rows[index].failure = UserFacingErrorText.describe(error) }
    }

    func cancelConfirmation() {
        reviewGeneration &+= 1
        confirmation = nil
        confirmationGate.cancel()
    }

    /// Invoked only by the explicit confirmation button for this exact request.
    @discardableResult
    func confirm(_ confirmationID: UUID) -> Task<Void, Never>? {
        guard let approved = confirmation, approved.id == confirmationID,
              let resource = resources[approved.resourceID], let index = index(approved.resourceID),
              rows[index].result == nil, !rows[index].isBusy,
              confirmationGate.consume(confirmationID) else { return nil }
        confirmation = nil // Consume once; cancellation/failure never auto-retries.
        rows[index].isBusy = true
        return Task { await retire(approved, resource: resource, index: index) }
    }

    private func retire(_ approved: P03CleanupAppConfirmation, resource: P03CleanupAppResource, index: Int) async {
        defer { rows[index].isBusy = false }
        let trash = platformTrash
        do {
            let result = try await GitChildWorktreeCleanupService.retire(request: approved.request,
                source: resource.source, managedRoot: resource.managedRoot, readOnly: resource.readOnly,
                approvedTrash: { exactRequest in
                    guard exactRequest == approved.request else {
                        throw GitChildWorktreeCleanupService.CleanupError.rejected("确认与当前清理请求不匹配")
                    }
                    // Core is holding the source's real resource lease here.
                    try await resource.source.validateExactWorktreePath(exactRequest.snapshot.allocation)
                    guard try await resource.source.currentSnapshot() == exactRequest.snapshot else {
                        throw GitChildWorktreeCleanupService.CleanupError.rejected("确认后任务归属或授权已变化")
                    }
                    return try await trash(exactRequest)
                })
            rows[index].result = result
            rows[index].failure = nil
            dismissLeftover(approved.resourceID)
        } catch { rows[index].failure = UserFacingErrorText.describe(error) }
    }

    private func index(_ id: UUID) -> Int? { rows.firstIndex { $0.id == id } }
}

/// Production platform effect. The only input is the Core's prepared request;
/// caller must hold its real source lease and the consumed user confirmation.
enum P03CleanupPlatformTrash {
    static func move(_ request: GitChildWorktreeCleanupRequest) throws -> URL {
        let path = request.snapshot.allocation.workingDirectory
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              url.standardizedFileURL.path == path,
              url.resolvingSymlinksInPath().path == path else {
            throw GitChildWorktreeCleanupService.CleanupError.rejected("目标路径已改变或含符号链接，未移动目录")
        }
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        guard let resultingURL else {
            throw GitChildWorktreeCleanupService.CleanupError.rejected("系统未返回废纸篓位置；请手动检查，不会重试或永久删除")
        }
        return resultingURL as URL
    }
}
