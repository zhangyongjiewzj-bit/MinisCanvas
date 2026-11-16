import Foundation
import Observation
import MinisCore

/// P3-P1-03 证据（A）· 布局宽度影子配置的正主合同。
///
/// 本文件是「会话侧栏宽度」这一设置能力的唯一声明与唯一读写网关：
/// feature ↔ settings_key ↔ scope ↔ default ↔ effective_source ↔
/// persistence ↔ restart ↔ reset ↔ validation ↔ consumer 全部收敛到
/// `SessionSidebarWidthContract`。前端（ContentView）只消费本合同的
/// effective 值，不再持有私有 `@AppStorage` 键绑定。
///
/// 单一事实源约束：
/// - 持久化域保持为 `BridgeStore.preferencesDefaults` 注入的 profile 作用域
///   UserDefaults（生产由 RuntimeIsolationProfile 解析 suite），键与原
///   `@AppStorage("minisCanvas.sidebarWidth")` 完全一致，因此既有用户值
///   无需迁移、继续可读，重启/折叠恢复语义不变。
/// - 契约矩阵复用既有 `PersistentStateDescriptor` 类型（SettingsStateClassification
///   的声明机制），不发明第二套矩阵类型。将 `descriptor` 并入
///   `SettingsStateClassification.descriptors` 与设置中心编辑行需要修改本 lane
///   写集之外的文件（SettingsStateClassification.swift / SettingsView.swift /
///   MinisCanvasApp.swift），见回执 WRITE_SET_ESCALATION_REQUESTED 的集成配方；
///   在该合并完成前，本文件已是该键在生产源码中的唯一读写点。
enum SessionSidebarWidthContract {
    /// 唯一 settings_key（与历史 @AppStorage 键逐字节一致，保证旧值可读）。
    static let settingsKey = "minisCanvas.sidebarWidth"
    static let typedCatalogID = settingsKey
    /// 唯一默认值：与 SidebarWidthMemory 同一常量，不另立数值。
    static let defaultValue: Double = SidebarWidthMemory.defaultWidth
    /// 用户可请求的最小宽度；上限是窗口布局策略的临时夹取，不落持久化。
    static let minWidth: Double = SidebarWidthMemory.minWidth

    /// 唯一验证入口：非有限值回落默认，低于最小值抬升最小值。
    /// 直接委托 `SidebarWidthMemory`，避免第二套夹取逻辑。
    static func validate(_ raw: Double?) -> Double {
        guard let raw else { return defaultValue }
        // SidebarWidthMemory.normalized：非有限值→defaultWidth，低于 minWidth→minWidth。
        return SidebarWidthMemory(width: raw).width
    }

    /// 读取持久化原始值（NSNumber 桥接，容忍历史 plist 的整型表示）。
    static func persistedRawValue(in defaults: UserDefaults) -> Double? {
        (defaults.object(forKey: settingsKey) as? NSNumber)?.doubleValue
    }

    /// 统一矩阵条目（PersistentStateDescriptor 即既有合同类型）。
    /// 合并进 `SettingsStateClassification.descriptors` 前的登记材料；
    /// `SessionSidebarWidthContractTests` 断言各字段与本实现逐字对应。
    static var descriptor: PersistentStateDescriptor {
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SessionSidebarWidthContract -> ContentView",
            priority: 100,
            scope: "app/window-layout",
            defaultValue: "SessionSidebarWidthContract.defaultValue = 240",
            reset: "SessionSidebarWidthSetting.resetToDefault() 覆写唯一键为默认值",
            persistence: "UserDefaults(suite: BridgeStore.preferencesDefaults) key minisCanvas.sidebarWidth",
            restart: "immediate; new ContentView instances load via SessionSidebarWidthSetting in onAppear",
            validation: "SessionSidebarWidthContract.validate -> SidebarWidthMemory 同界 (>=56, finite)",
            consumer: "ContentView.effectiveSidebarWidth / collapseSidebar / applySidebarDrag",
            settingsKey: settingsKey,
            effectiveSource: "SessionSidebarWidthSetting.storedWidth"
        )
    }
}

/// 会话侧栏宽度的唯一访问器（@MainActor 网关，前端与未来设置中心共用）。
///
/// 语义承诺（对用户诚实）：
/// - persistence：写入即同步落 UserDefaults（与 @AppStorage 时序一致）。
/// - restart：新实例 init 读回同一键；既有值不迁移、不清除。
/// - reset：覆写为默认 240（用户显式动作），不静默删除键。
@MainActor
@Observable
final class SessionSidebarWidthSetting {
    private static let replayKey = "minisCanvas.sidebarWidth.typedReplay.v1"
    private struct Pending: Codable {
        let previousRaw: Double?
        let target: Double
    }
    private struct ReplayState: Codable {
        var profileID: String
        var token: String
        var completed: [String: BL6SettingsReplayRecord]
        var pending: Pending?
    }

    private let defaults: UserDefaults
    /// 已验证的生效持久值。唯一的 UserDefaults 读取点。
    private(set) var storedWidth: Double

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if var state = try? Self.readState(from: defaults), let pending = state.pending {
            // A torn two-key UserDefaults update is rolled back before either
            // the layout or the model catalog can read the new value.
            if let previous = pending.previousRaw {
                defaults.set(previous, forKey: SessionSidebarWidthContract.settingsKey)
            } else {
                defaults.removeObject(forKey: SessionSidebarWidthContract.settingsKey)
            }
            state.pending = nil
            if let data = try? JSONEncoder().encode(state) {
                defaults.set(data, forKey: Self.replayKey)
            }
        }
        self.storedWidth = SessionSidebarWidthContract.validate(
            SessionSidebarWidthContract.persistedRawValue(in: defaults)
        )
    }

    /// 有效值 = 经合同验证的持久值（折叠置 0 等瞬时投影由视图状态机处理，
    /// 不进入本合同，避免把 view state 伪装成设置值）。
    var effectiveWidth: Double { storedWidth }

    /// 唯一写入网关：验证后落盘并更新生效值。
    func write(_ requestedWidth: Double) {
        let validated = SessionSidebarWidthContract.validate(requestedWidth)
        guard var state = try? Self.readState(from: defaults), state.pending == nil else { return }
        let previous = SessionSidebarWidthContract.persistedRawValue(in: defaults)
        state.pending = Pending(previousRaw: previous?.isFinite == true ? previous : nil, target: validated)
        guard Self.save(state, to: defaults) else { return }
        defaults.set(validated, forKey: SessionSidebarWidthContract.settingsKey)
        guard SessionSidebarWidthContract.persistedRawValue(in: defaults) == validated else {
            restore(previous)
            return
        }
        state.pending = nil
        state.token = UUID().uuidString
        guard Self.save(state, to: defaults) else {
            restore(previous)
            return
        }
        storedWidth = validated
    }

    /// 用户可见的重置：覆写唯一键为默认值（旧值在此之前始终可读）。
    func resetToDefault() {
        write(SessionSidebarWidthContract.defaultValue)
    }

    /// suite 被外部整体重置后重新读回（不存在第二个写入方，故只做显式刷新）。
    func reload() {
        storedWidth = SessionSidebarWidthContract.validate(
            SessionSidebarWidthContract.persistedRawValue(in: defaults)
        )
    }

    private func restore(_ previous: Double?) {
        if let previous, previous.isFinite {
            defaults.set(previous, forKey: SessionSidebarWidthContract.settingsKey)
        } else {
            defaults.removeObject(forKey: SessionSidebarWidthContract.settingsKey)
        }
        if var state = try? Self.readState(from: defaults) {
            state.pending = nil
            _ = Self.save(state, to: defaults)
        }
    }

    private static func readState(from defaults: UserDefaults) throws -> ReplayState {
        guard let data = defaults.data(forKey: replayKey) else {
            return ReplayState(profileID: "", token: "legacy", completed: [:], pending: nil)
        }
        return try JSONDecoder().decode(ReplayState.self, from: data)
    }

    private static func save(_ state: ReplayState, to defaults: UserDefaults) -> Bool {
        guard let data = try? JSONEncoder().encode(state) else { return false }
        defaults.set(data, forKey: replayKey)
        return defaults.data(forKey: replayKey) == data
    }

    private static func revision(token: String, width: Double) -> String {
        "sidebar-width-v1:\(token):\(width.bitPattern)"
    }

    func bl6Snapshot(profileID: String) -> Result<(revision: String, value: BL6SettingValue), BL6SettingsReplayCommitError> {
        guard let state = try? Self.readState(from: defaults), state.pending == nil,
              state.profileID.isEmpty || state.profileID == profileID else {
            return .failure(.persistence(.transactionRecoveryRequired))
        }
        let width = SessionSidebarWidthContract.validate(
            SessionSidebarWidthContract.persistedRawValue(in: defaults)
        )
        return .success((Self.revision(token: state.token, width: width), .decimal(width)))
    }

    func bl6ReplayRecord(for requestID: String, profileID: String) -> Result<BL6SettingsReplayRecord?, BL6SettingsReplayCommitError> {
        guard let state = try? Self.readState(from: defaults), state.pending == nil,
              state.profileID.isEmpty || state.profileID == profileID else {
            return .failure(.persistence(.transactionRecoveryRequired))
        }
        return .success(state.completed[requestID])
    }

    func bl6ReplayRecord(receiptID: String, profileID: String) -> Result<BL6SettingsReplayRecord?, BL6SettingsReplayCommitError> {
        guard let state = try? Self.readState(from: defaults), state.pending == nil,
              state.profileID.isEmpty || state.profileID == profileID else {
            return .failure(.persistence(.transactionRecoveryRequired))
        }
        return .success(state.completed.values.first { $0.receipt.receiptID == receiptID })
    }

    func prepareBL6Replay(_ input: BL6SettingsApprovedInput, profileID: String)
        -> Result<(previousRevision: String, effectiveRevision: String, changedKeys: [String], rollbackValues: [String: BL6SettingValue]), BL6SettingsReplayCommitError> {
        guard case let .success(snapshot) = bl6Snapshot(profileID: profileID) else {
            return .failure(.persistence(.transactionRecoveryRequired))
        }
        guard input.expectedRevision == snapshot.revision else { return .failure(.staleRevision) }
        let target: Double
        switch targetWidth(for: input, profileID: profileID) {
        case .failure(let error): return .failure(error)
        case .success(let value): target = value
        }
        let current: Double
        guard case let .decimal(value) = snapshot.value else { return .failure(.conflict) }
        current = value
        return .success((snapshot.revision,
                         Self.revision(token: UUID().uuidString, width: target),
                         current == target ? [] : [SessionSidebarWidthContract.typedCatalogID],
                         [SessionSidebarWidthContract.typedCatalogID: .decimal(current)]))
    }

    private func targetWidth(for input: BL6SettingsApprovedInput, profileID: String)
        -> Result<Double, BL6SettingsReplayCommitError> {
        let key = SessionSidebarWidthContract.typedCatalogID
        let value: BL6SettingValue
        switch input.operation {
        case .apply:
            guard input.changes.count == 1, let candidate = input.changes[key] else { return .failure(.conflict) }
            value = candidate
        case .rollback:
            guard let receiptID = input.undoReceiptID,
                  case let .success(record?) = bl6ReplayRecord(receiptID: receiptID, profileID: profileID),
                  record.receipt.effectiveRevision == input.expectedRevision,
                  let candidate = record.rollbackValues[key] else { return .failure(.conflict) }
            value = candidate
        case .reset, .configureProvider:
            return .failure(.conflict)
        }
        guard case let .decimal(width) = value,
              width.isFinite, width >= SessionSidebarWidthContract.minWidth else { return .failure(.conflict) }
        return .success(width)
    }

    func commitBL6Replay(_ record: BL6SettingsReplayRecord, profileID: String)
        -> Result<BL6SettingsReceipt, BL6SettingsReplayCommitError> {
        guard record.profileID == profileID, Date() < record.approvalExpiresAt,
              var state = try? Self.readState(from: defaults), state.pending == nil,
              state.profileID.isEmpty || state.profileID == profileID else {
            return .failure(.persistence(.transactionRecoveryRequired))
        }
        if let existing = state.completed[record.requestID] {
            return existing == record ? .success(existing.receipt) : .failure(.conflict)
        }
        guard case let .success(snapshot) = bl6Snapshot(profileID: profileID),
              snapshot.revision == record.receipt.previousRevision,
              snapshot.revision == record.frozenInput.expectedRevision else { return .failure(.staleRevision) }
        let target: Double
        switch targetWidth(for: record.frozenInput, profileID: profileID) {
        case .failure(let error): return .failure(error)
        case .success(let value): target = value
        }
        guard record.receipt.effectiveRevision.hasSuffix(":\(target.bitPattern)"),
              record.rollbackValues == [SessionSidebarWidthContract.typedCatalogID: snapshot.value],
              record.receipt.changedKeys == (snapshot.value == .decimal(target) ? [] : [SessionSidebarWidthContract.typedCatalogID]) else {
            return .failure(.conflict)
        }
        let previous = SessionSidebarWidthContract.persistedRawValue(in: defaults)
        state.pending = Pending(previousRaw: previous?.isFinite == true ? previous : nil, target: target)
        guard Self.save(state, to: defaults) else { return .failure(.persistence(.writeFailed)) }
        defaults.set(target, forKey: SessionSidebarWidthContract.settingsKey)
        guard SessionSidebarWidthContract.persistedRawValue(in: defaults) == target else {
            restore(previous)
            return .failure(.persistence(.writeFailed))
        }
        state.pending = nil
        state.profileID = profileID
        // The receipt's token was frozen before the one-use approved effect.
        state.token = String(record.receipt.effectiveRevision.dropFirst("sidebar-width-v1:".count).split(separator: ":").first ?? "")
        state.completed[record.requestID] = record
        guard Self.save(state, to: defaults) else {
            restore(previous)
            return .failure(.persistence(.writeFailed))
        }
        storedWidth = target
        return .success(record.receipt)
    }
}
