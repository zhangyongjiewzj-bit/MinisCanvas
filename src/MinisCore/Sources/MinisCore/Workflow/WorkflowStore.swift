import Foundation

public enum WorkflowStoreInitialLoadError: Error, Equatable, Sendable {
    case pending
}

// MARK: - WorkflowStore

/// 工作流模板管理：预置 3 个漫剧模板 + 用户自定义模板，持久化到 `workflows.json`。
///
/// - 预置模板（`WorkflowTemplate.presets`）只读，始终可列出
/// - 用户可 `saveTemplate` 保存/覆盖自定义模板（id 与预置相同则覆盖预置）
/// - `removeTemplate` 删除用户模板；预置模板删除后自动恢复默认
/// - 持久化文件：`<storeDirectory>/workflows.json`（仅存用户模板，预置不入盘）
public final class WorkflowStore: @unchecked Sendable {

    /// 应用级共享实例，目录为 `~/Library/Application Support/MinisCanvas/Workflows/`。
    public static let shared = WorkflowStore(storeDirectory: defaultDirectory())

    /// Formal test hosts resolve their verified root before Foundation's user domain.
    static func defaultDirectory() -> URL {
        if let formal = FormalTestIsolationPaths.currentOrFail() {
            return formal.applicationSupportDirectory
                .appendingPathComponent("MinisCanvas", isDirectory: true)
                .appendingPathComponent("Workflows", isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("MinisCanvas", isDirectory: true)
            .appendingPathComponent("Workflows", isDirectory: true)
    }

    /// 持久化文件名。
    public static let fileName = "workflows.json"

    private let lock = NSLock()
    private let storeDirectory: URL
    private let fileURL: URL
    private let readData: @Sendable (URL) -> Data?
    /// 用户模板：id → template（含对预置的覆盖）。
    private var userTemplates: [String: WorkflowTemplate]
    private var initialLoadComplete: Bool
    private var initialLoadTask: Task<Void, Never>?

    public convenience init(
        storeDirectory: URL,
        readData: @escaping @Sendable (URL) -> Data? = { try? Data(contentsOf: $0) }
    ) {
        self.init(storeDirectory: storeDirectory, readData: readData, loadImmediately: true)
    }

    /// App bootstrap keeps its canonical store identity while the document is read off MainActor.
    /// Until the initial load finishes, lookups and mutations fail closed so a persisted override
    /// cannot be mistaken for a built-in template or overwritten by a first save.
    public static func startForAppBootstrap(
        storeDirectory: URL,
        readData: @escaping @Sendable (URL) -> Data? = { try? Data(contentsOf: $0) }
    ) -> WorkflowStore {
        let store = WorkflowStore(
            storeDirectory: storeDirectory, readData: readData, loadImmediately: false
        )
        store.beginInitialLoad()
        return store
    }

    private init(
        storeDirectory: URL,
        readData: @escaping @Sendable (URL) -> Data?,
        loadImmediately: Bool
    ) {
        self.storeDirectory = storeDirectory
        self.fileURL = storeDirectory.appendingPathComponent(Self.fileName)
        self.readData = readData
        self.userTemplates = [:]
        self.initialLoadComplete = loadImmediately
        if loadImmediately { loadFromDisk() }
    }

    deinit {
        initialLoadTask?.cancel()
    }

    public var isInitialLoadComplete: Bool {
        lock.lock()
        defer { lock.unlock() }
        return initialLoadComplete
    }

    public func waitForInitialLoad() async {
        await initialLoadTaskSnapshot()?.value
    }

    private func initialLoadTaskSnapshot() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return initialLoadTask
    }

    // MARK: - 查询

    /// 全部模板：预置（被用户覆盖的用用户版本）+ 用户新增，按预置顺序在前。
    public func listTemplates() -> [WorkflowTemplate] {
        lock.lock()
        defer { lock.unlock() }
        guard initialLoadComplete else { return [] }
        return allTemplatesLocked()
    }

    /// 按 id 或 name 查找（id 优先，其次 name；用户模板优先于预置）。
    public func template(id: String) -> WorkflowTemplate? {
        lock.lock()
        defer { lock.unlock() }
        guard initialLoadComplete else { return nil }
        if let user = userTemplates[id] { return user }
        if let preset = WorkflowTemplate.presets.first(where: { $0.id == id }) { return preset }
        return allTemplatesLocked().first { $0.name == id }
    }

    // MARK: - 修改

    /// 保存模板（新增或覆盖）。校验通过后写盘。
    public func saveTemplate(_ template: WorkflowTemplate) throws {
        try template.validate()
        lock.lock()
        defer { lock.unlock() }
        guard initialLoadComplete else { throw WorkflowStoreInitialLoadError.pending }
        userTemplates[template.id] = template
        try persistLocked()
    }

    /// 删除用户模板。返回 false 表示没有可删的用户版本（预置模板删除后回到默认，仍返回 true）。
    @discardableResult
    public func removeTemplate(id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard initialLoadComplete else { return false }
        guard userTemplates.removeValue(forKey: id) != nil else { return false }
        try? persistLocked()
        return true
    }

    /// 立即把用户模板写盘（saveTemplate 已自动调用；此方法用于显式落盘）。
    public func saveToDisk() throws {
        lock.lock()
        defer { lock.unlock() }
        guard initialLoadComplete else { throw WorkflowStoreInitialLoadError.pending }
        _ = try persistLocked()
    }

    // MARK: - 私有

    /// 调用方必须持锁。
    private func allTemplatesLocked() -> [WorkflowTemplate] {
        var result: [WorkflowTemplate] = []
        for preset in WorkflowTemplate.presets {
            result.append(userTemplates[preset.id] ?? preset)
        }
        // 用户新增（非预置 id）按保存顺序追加
        for (id, template) in userTemplates where !WorkflowTemplate.presets.contains(where: { $0.id == id }) {
            result.append(template)
        }
        return result
    }

    /// 调用方必须持锁；写盘失败抛错。
    private func persistLocked() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Array(userTemplates.values))
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    private func loadFromDisk() {
        let loaded = Self.decodeTemplates(readData(fileURL))
        lock.lock()
        userTemplates = loaded
        lock.unlock()
    }

    private func beginInitialLoad() {
        let reader = readData
        let url = fileURL
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let loaded = Self.decodeTemplates(reader(url))
            guard !Task.isCancelled else { return }
            self?.completeInitialLoad(loaded)
        }
        lock.lock()
        initialLoadTask = task
        lock.unlock()
    }

    private func completeInitialLoad(_ loaded: [String: WorkflowTemplate]) {
        lock.lock()
        userTemplates = loaded
        initialLoadComplete = true
        lock.unlock()
    }

    private static func decodeTemplates(_ data: Data?) -> [String: WorkflowTemplate] {
        guard let data,
              let decoded = try? JSONDecoder().decode([WorkflowTemplate].self, from: data)
        else { return [:] }
        var loaded: [String: WorkflowTemplate] = [:]
        for template in decoded {
            loaded[template.id] = template
        }
        return loaded
    }
}
