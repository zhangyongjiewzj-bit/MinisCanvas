import Foundation
import Testing
import MinisCore

@testable import MinisCanvasApp

// SETTINGS-25 / 缺陷族 P3-P1-03（lane 147）：「从进程导入」预览 API 的
// 生产消费证明。
//
// 背景：`EnvVarStore.processEnvironmentImportPreview()` 与
// `applyProcessEnvironmentImport(selectedNames:)`（SETTINGS-25 核心层，
// 本头之前由 MinisCore 自带测试覆盖）在 src/ 生产侧曾为零消费者，而
// 出厂 SettingsView 按钮仍走 `importFromProcessEnvironment()` 静默批量
// 写入。本套件钉住接线后的三层事实：
//  1) 生产消费点存在——SettingsView 的「从进程导入」按钮先经只读预览，
//     apply 唯一出现在预览表的确认回调内；视图层批量导入入口已消失。
//  2) 按钮不变量——label 文案、图标、accessibilityIdentifier 与改动前
//     逐字节一致，未新增任何强制步骤（仍是同一按钮的一次 预览→确认）。
//  3) 真实 store 行为（经生产 SettingsCenter 组合、临时目录注入）——
//     预览零写副作用；确认（apply）前不落盘；add-only，确认也不覆盖
//     既有条目。
//
// 诚实边界：宿主测试环境不做 SwiftUI 视图托管，故 1)/2) 为源码级 pin，
// 3) 驱动的是与生产接线逐字相同的 store 调用序列；本文件不声称验证了
// 渲染后的交互。

@Suite("SETTINGS-25 从进程导入预览生产消费 (lane 147)", .serialized)
struct EnvVarImportPreviewConsumer147Tests {

    // MARK: - 工具

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MinisCanvasAppTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // MinisCanvasApp
            .deletingLastPathComponent() // src
            .deletingLastPathComponent() // repository root
    }

    private func settingsViewSource() throws -> String {
        try String(
            contentsOf: repositoryRoot().appendingPathComponent(
                "src/MinisCanvasApp/Sources/MinisCanvasApp/SettingsView.swift"
            ),
            encoding: .utf8
        )
    }

    /// 生产组合的 SettingsCenter（临时目录注入，绝不触碰真实数据）。
    @MainActor
    private func makeCenter() throws -> (SettingsCenter, URL, UserDefaults, String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lane147-EnvImportPreview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let suiteName = "Lane147-EnvImportPreview.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: dir),
            envStore: EnvVarStore(
                directory: dir,
                keychain: KeychainStore(backing: InMemoryKeychainBacking()),
                privacyStore: EnvVarPrivacyStore(defaults: defaults)
            ),
            memoryStore: MemoryStore(directory: dir),
            sessionStore: SessionStore(directory: dir),
            logManager: LogManager(directory: dir, ringCapacity: 50)
        )
        return (center, dir, defaults, suiteName)
    }

    /// 唯一、合法且刻意避开 secret 后缀表（API_KEY/TOKEN/SECRET/
    /// PASSWORD/KEY 结尾）的变量名——测试全程不落 Keychain。
    private func uniqueLane147Name(_ role: String) -> String {
        "QODER147_\(role)_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
    }

    // MARK: - 1) 源码级 pin：生产消费点

    @Test func viewNoLongerBulkImportsAndRoutesThroughPreview() throws {
        let source = try settingsViewSource()

        // 视图层不再有静默批量导入入口（bulk API 仍留在 SettingsCenter，
        // 归其 owner；本 pin 只声明 SettingsView 不再调用）。
        #expect(!source.contains("importFromProcessEnvironment"))

        // 预览与 apply 各恰出现一次，且都经由生产组合的 store 实例。
        #expect(
            source.components(separatedBy: "center.envStore.processEnvironmentImportPreview()").count - 1 == 1
        )
        #expect(
            source.components(separatedBy: "center.envStore.applyProcessEnvironmentImport(selectedNames:")
                .count - 1 == 1
        )

        // 按钮 action 已改为预览入口（只读），不再是直接写入。
        #expect(source.contains("Button {\n                            presentProcessEnvironmentImportPreview()"))
    }

    @Test func applyCallSiteIsInsidePreviewConfirmWiring() throws {
        let source = try settingsViewSource()
        let applyAt = try #require(
            source.range(of: "center.envStore.applyProcessEnvironmentImport(selectedNames:")
        )
        let sheetAt = try #require(source.range(of: ".sheet(item: $pendingImportPreview)"))

        // 唯一的 apply 调用位于预览 sheet 的确认回调内：sheet 注册点到
        // apply 之间只隔着确认表构造与 selectedNames 回调签名。
        #expect(applyAt.lowerBound >= sheetAt.lowerBound)
        let between = source[sheetAt.lowerBound..<applyAt.lowerBound]
        #expect(between.contains("EnvVarProcessImportPreviewSheet(items: request.items)"))
        #expect(between.contains("selectedNames"))

        // 按钮按下路径零写入：预览入口的实现体内只有只读预览调用，
        // 直到下一个 MARK 边界都不出现 apply/批量导入。
        let presentAt = try #require(source.range(of: "private func presentProcessEnvironmentImportPreview()"))
        let markAfter = try #require(source.range(of: "// MARK: U5 模型供应商行"))
        #expect(presentAt.lowerBound < markAfter.lowerBound)
        let presentHelper = source[presentAt.lowerBound..<markAfter.lowerBound]
        #expect(presentHelper.contains("center.envStore.processEnvironmentImportPreview()"))
        #expect(!presentHelper.contains("applyProcessEnvironmentImport"))
        #expect(!presentHelper.contains("importFromProcessEnvironment"))
        #expect(!presentHelper.contains("loadFromProcessEnvironment"))
    }

    // MARK: - 2) 按钮不变量：用户按的还是同一个控件

    @Test func importButtonEntryUnchanged() throws {
        let source = try settingsViewSource()

        // 文案 + 图标逐字节不变，且各恰一次。
        #expect(
            source.components(separatedBy: "Label { Text(\"从进程导入\") } icon: { MinisIconView(.download, size: 14) }")
                .count - 1 == 1
        )
        // accessibilityIdentifier 不变且仍唯一（外部旅程/AX 脚本无感）。
        #expect(
            source.components(separatedBy: ".accessibilityIdentifier(\"settings.environment.import-process\")")
                .count - 1 == 1
        )
        // 结果提示仍复用既有状态行，没有新增强制步骤。
        #expect(source.contains(".accessibilityIdentifier(\"settings.environment.status\")"))
    }

    // MARK: - 3) 真实 store 行为：预览零写入，确认前不落盘，add-only

    @MainActor
    @Test func previewWritesNothingUntilConfirmAndNeverOverwrites() throws {
        let (center, dir, defaults, suiteName) = try makeCenter()
        defer { try? FileManager.default.removeItem(at: dir) }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let newName = uniqueLane147Name("NEW")
        let existingName = uniqueLane147Name("EXISTING")
        let emptyName = uniqueLane147Name("EMPTY")
        #expect(center.setEnvVar(name: existingName, value: "seed-value"))

        let metadataURL = dir.appendingPathComponent(EnvVarStore.fileName)
        let bytesBefore = try Data(contentsOf: metadataURL)
        let countBefore = center.envStore.count

        // 与生产按钮同一调用：只读预览（此处注入确定性候选源）。
        // 生产两侧都读同一份当前进程环境；注入源必须同时供预览与确认使用，
        // 否则确认侧读不到被预览的值（deterministic source ≠ live env）。
        let importSource: [String: String] = [
            newName: "process-value-a",
            existingName: "different-process-value",
            emptyName: "",
        ]
        let preview = center.envStore.processEnvironmentImportPreview(source: importSource)
        #expect(preview.filter(\.isSelectableForImport).map(\.name) == [newName])
        #expect(preview.first { $0.name == existingName }?.changeKind == .update)
        #expect(preview.first { $0.name == emptyName }?.changeKind == .skip)
        #expect(preview.first { $0.name == emptyName }?.skipReason == .emptyValue)

        // 预览零副作用：内存条目数、取值、磁盘元数据字节全部不变。
        #expect(center.envStore.count == countBefore)
        #expect(center.envStore.getEnvVar(name: newName) == nil)
        #expect(try Data(contentsOf: metadataURL) == bytesBefore)
        #expect(!center.envEntries.contains { $0.name == newName })

        // 模拟确认回调：仅勾选 add 类；update 类按 isSelectableForImport
        // 永不进清单——即便显式传入也被 skippedAlreadyStored 拒绝，
        // 既有条目原值保持不变（仅新增，不覆盖）。
        let selected = preview.filter(\.isSelectableForImport).map(\.name) + [existingName]
        let outcomes = center.envStore.applyProcessEnvironmentImport(
            selectedNames: selected,
            source: importSource
        )
        #expect(outcomes[newName] == .imported)
        #expect(outcomes[existingName] == .skippedAlreadyStored)
        #expect(outcomes[emptyName] == nil)

        // 与生产确认回调同一路径：刷新计数与列表快照。
        center.lastImportCount = outcomes.values.filter { $0 == .imported }.count
        center.reloadEnv()
        #expect(center.lastImportCount == 1)
        #expect(center.envStore.getEnvVar(name: newName) == "process-value-a")
        #expect(center.envStore.getEnvVar(name: existingName) == "seed-value")
        #expect(center.envEntries.contains { $0.name == newName })
    }

    @MainActor
    @Test func syntheticPreviewConsumerWithholdsUnclassifiedValueBeforeConfirm() throws {
        let (center, dir, defaults, suiteName) = try makeCenter()
        defer { try? FileManager.default.removeItem(at: dir) }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // 同一生产 store 预览 API，显式注入合成来源，不枚举主机进程环境。
        let seenName = uniqueLane147Name("SEEN")
        let preview = center.envStore.processEnvironmentImportPreview(
            source: [seenName: "synthetic-opaque-value"]
        )
        let item = try #require(preview.first { $0.name == seenName })
        #expect(item.changeKind == .add)
        #expect(item.isSelectableForImport)
        #expect(item.valueDisplay == EnvVarStore.EnvVarProcessImportPreviewItem.redactedValuePlaceholder)
        #expect(!String(describing: item).contains("synthetic-opaque-value"))

        // 确认前不写：预览清单可见新候选，但 store 未收到任何条目。
        #expect(center.envStore.getEnvVar(name: seenName) == nil)
        #expect(center.envEntries.isEmpty)
    }

    @MainActor
    @Test func importedValuesKeepTheirDisclosureBoundaryInListDetailAndEdit() throws {
        let (center, dir, defaults, suiteName) = try makeCenter()
        defer { try? FileManager.default.removeItem(at: dir) }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let opaqueName = uniqueLane147Name("OPAQUE")
        let publicName = uniqueLane147Name("PUBLIC")
        let secretName = uniqueLane147Name("TOKEN")
        let opaqueValue = "synthetic-opaque-never-display"
        let publicValue = "synthetic-public-display"
        let secretValue = "synthetic-token-never-display"
        let source = [
            opaqueName: opaqueValue,
            publicName: publicValue,
            secretName: secretValue,
        ]
        let privacy = EnvVarPrivacyStore(defaults: defaults)
        privacy.unmarkSecret(name: publicName)

        let preview = center.envStore.processEnvironmentImportPreview(source: source)
        #expect(preview.first { $0.name == opaqueName }?.valueDisplay
            == EnvVarStore.EnvVarProcessImportPreviewItem.redactedValuePlaceholder)
        #expect(preview.first { $0.name == secretName }?.valueDisplay
            == EnvVarStore.EnvVarProcessImportPreviewItem.redactedValuePlaceholder)
        #expect(preview.first { $0.name == publicName }?.valueDisplay == publicValue)

        let outcomes = center.envStore.applyProcessEnvironmentImport(
            selectedNames: [opaqueName, publicName, secretName], source: source
        )
        #expect(outcomes.count == 3)
        #expect(outcomes.values.allSatisfy { $0 == .imported })
        center.reloadEnv()

        let opaque = try #require(center.envEntries.first { $0.name == opaqueName })
        let publicEntry = try #require(center.envEntries.first { $0.name == publicName })
        let secret = try #require(center.envEntries.first { $0.name == secretName })
        let placeholder = EnvVarStore.EnvVarProcessImportPreviewItem.redactedValuePlaceholder

        #expect(center.environmentDisplayValue(for: opaque) == placeholder)
        #expect(center.environmentEditablePrefill(for: opaque).isEmpty)
        #expect(center.environmentDisplayValue(for: publicEntry) == publicValue)
        #expect(center.environmentEditablePrefill(for: publicEntry) == publicValue)
        #expect(!center.environmentDisplayValue(for: secret).contains(secretValue))
        #expect(center.environmentEditablePrefill(for: secret).isEmpty)

        // The actual row/detail tooltip and edit sheet must consume the same
        // production projection. This pin does not claim SwiftUI rendering.
        let view = try settingsViewSource()
        #expect(view.contains("center.environmentDisplayValue(for: entry)"))
        #expect(view.contains("prefilledValue: center.environmentEditablePrefill(for: entry)"))
        #expect(!view.contains("value = existing.value"))
    }
}
