import Foundation
import Testing
@testable import MinisCore

// SETTINGS-25：「从进程导入」的脱敏差异预览与逐项选择（EnvVarStore 核心层）。
// 本文件只覆盖纯预览 API（零持久化副作用）与显式 apply API（仅持久化被
// 勾选子项，add-only + 名称守卫 + secret 走 Keychain）。SwiftUI 半侧
// （SettingsCenter/SettingsView 接线）不在本写集内，需求项不得据此闭环。

/// 每个测试独占的临时目录（测试并行运行，路径绝不共享）。
private func makePreviewTempDir(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MinisCore-EnvImportPreview-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// 唯一、合法的环境变量名（进程环境为全局态，测试并行时防互相污染）。
private func uniqueEnvName(_ prefix: String) -> String {
    "\(prefix)_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))".uppercased()
}

/// 记录全部 Keychain 操作的内存 backing：用于证明预览阶段
/// set/get/delete 均为 0 次。
private final class ProbeKeychainBacking: KeychainBacking, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var setKeys: [String] = []
    private var getKeys: [String] = []
    private var deleteKeys: [String] = []

    func set(_ value: String, forKey key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        setKeys.append(key)
        values[key] = value
        return true
    }

    func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        getKeys.append(key)
        return values[key]
    }

    func delete(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        deleteKeys.append(key)
        values.removeValue(forKey: key)
        return true
    }

    var operationCounts: (sets: Int, gets: Int, deletes: Int) {
        lock.lock(); defer { lock.unlock() }
        return (setKeys.count, getKeys.count, deleteKeys.count)
    }

    func storedValue(forKey key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }
}

private func makeProbeStore(_ dir: URL) -> (EnvVarStore, ProbeKeychainBacking) {
    let backing = ProbeKeychainBacking()
    return (EnvVarStore(directory: dir, keychain: KeychainStore(backing: backing)), backing)
}

private func metadataURL(_ dir: URL) -> URL {
    dir.appendingPathComponent(EnvVarStore.fileName)
}

private func readMetadataBytes(_ dir: URL) -> Data {
    (try? Data(contentsOf: metadataURL(dir))) ?? Data()
}

struct EnvVarProcessImportPreviewTests {

    // MARK: - 预览无任何写副作用

    @Test func previewPerformsNoWrites() throws {
        let dir = try makePreviewTempDir("nowrites")
        defer { try? FileManager.default.removeItem(at: dir) }

        let (store, backing) = makeProbeStore(dir)
        let keepName = uniqueEnvName("MINISCORE_PREVIEW_KEEP")
        let addName = uniqueEnvName("MINISCORE_PREVIEW_ADD")
        let addSecretName = uniqueEnvName("MINISCORE_PREVIEW_ADD") + "_API_KEY"
        let emptyName = uniqueEnvName("MINISCORE_PREVIEW_EMPTY")
        #expect(store.setEnvVar(name: keepName, value: "stored-value"))

        let bytesBefore = readMetadataBytes(dir)
        let countBefore = store.count
        let keychainBefore = backing.operationCounts

        let preview = store.processEnvironmentImportPreview(source: [
            keepName: "process-value",
            addName: "brand-new-value",
            addSecretName: "sk-preview-must-not-leak",
            emptyName: "",
            "1 BAD NAME!": "invalid",
        ])

        #expect(preview.count == 5)
        // 存储集字节级不变。
        #expect(readMetadataBytes(dir) == bytesBefore)
        #expect(store.count == countBefore)
        // Keychain 零接触（不读、不写、不删）。
        let keychainAfter = backing.operationCounts
        #expect(keychainAfter.sets == keychainBefore.sets)
        #expect(keychainAfter.gets == keychainBefore.gets)
        #expect(keychainAfter.deletes == keychainBefore.deletes)
        // 候选未被物化进存储。
        #expect(store.entry(name: addName) == nil)
        #expect(store.entry(name: addSecretName) == nil)
        #expect(store.getEnvVar(name: keepName) == "stored-value")
    }

    // MARK: - secret 类值在预览中脱敏

    @Test func previewRedactsSecretClassifiedValues() throws {
        let dir = try makePreviewTempDir("redact")
        defer { try? FileManager.default.removeItem(at: dir) }

        let (store, _) = makeProbeStore(dir)
        let secretName = uniqueEnvName("MINISCORE_PREVIEW_SECRET") + "_API_KEY"
        let plainName = uniqueEnvName("MINISCORE_PREVIEW_PLAIN")
        let rawSecret = "sk-live-abc123DEF456-never-materialize"
        let rawPlain = "visible-ordinary-value"

        let preview = store.processEnvironmentImportPreview(source: [
            secretName: rawSecret,
            plainName: rawPlain,
        ])
        #expect(preview.count == 2)
        let secretItem = try #require(preview.first { $0.name == EnvVarStore.canonicalName(secretName) })
        let plainItem = try #require(preview.first { $0.name == EnvVarStore.canonicalName(plainName) })

        #expect(secretItem.isSecretClassified)
        #expect(secretItem.valueDisplay == EnvVarStore.EnvVarProcessImportPreviewItem.redactedValuePlaceholder)
        #expect(!secretItem.valueDisplay.contains(rawSecret))
        // 整条记录的任何字段（含 description 回显）都不得携带原始 secret 值。
        #expect(!String(describing: secretItem).contains(rawSecret))
        // 未显式允许公开的普通值在预览中也只显示占位符。
        #expect(!plainItem.isSecretClassified)
        #expect(plainItem.valueDisplay == EnvVarStore.EnvVarProcessImportPreviewItem.redactedValuePlaceholder)
        #expect(!String(describing: plainItem).contains(rawPlain))
    }

    // MARK: - add/update/skip 分类

    @Test func previewClassifiesCandidates() throws {
        let dir = try makePreviewTempDir("classify")
        defer { try? FileManager.default.removeItem(at: dir) }

        let (store, _) = makeProbeStore(dir)
        let diffName = uniqueEnvName("MINISCORE_PREVIEW_DIFF")
        let sameName = uniqueEnvName("MINISCORE_PREVIEW_SAME")
        let newName = uniqueEnvName("MINISCORE_PREVIEW_NEW")
        #expect(store.setEnvVar(name: diffName, value: "stored"))
        #expect(store.setEnvVar(name: sameName, value: "identical"))

        let preview = store.processEnvironmentImportPreview(source: [
            diffName: "different",
            sameName: "identical",
            newName: "fresh",
            uniqueEnvName("MINISCORE_PREVIEW_BLANK"): "",
            "9 INVALID": "x",
        ])
        #expect(preview.count == 5)
        // 输出按规范名升序，供 UI 直接渲染。
        #expect(preview.map(\.name) == preview.map(\.name).sorted())

        let diffItem = try #require(preview.first { $0.name == EnvVarStore.canonicalName(diffName) })
        #expect(diffItem.changeKind == .update)
        #expect(diffItem.skipReason == nil)
        #expect(!diffItem.isSelectableForImport)

        let sameItem = try #require(preview.first { $0.name == EnvVarStore.canonicalName(sameName) })
        #expect(sameItem.changeKind == .skip)
        #expect(sameItem.skipReason == .alreadyStored)
        #expect(!sameItem.isSelectableForImport)

        let newItem = try #require(preview.first { $0.name == EnvVarStore.canonicalName(newName) })
        #expect(newItem.changeKind == .add)
        #expect(newItem.skipReason == nil)
        #expect(newItem.isSelectableForImport)
        #expect(newItem.valueDisplay == EnvVarStore.EnvVarProcessImportPreviewItem.redactedValuePlaceholder)

        let emptyItem = try #require(preview.first { $0.changeKind == .skip && $0.skipReason == .emptyValue })
        #expect(!emptyItem.isSelectableForImport)
        let invalidItem = try #require(preview.first { $0.skipReason == .invalidName })
        #expect(!invalidItem.isSelectableForImport)
    }

    // MARK: - 逐项选择：只持久化被勾选子集

    @Test func applyPersistsExactlyTheSelectedSubset() throws {
        let dir = try makePreviewTempDir("subset")
        defer { try? FileManager.default.removeItem(at: dir) }

        let (store, _) = makeProbeStore(dir)
        let name1 = uniqueEnvName("MINISCORE_PREVIEW_SEL1")
        let name2 = uniqueEnvName("MINISCORE_PREVIEW_SEL2")
        let name3 = uniqueEnvName("MINISCORE_PREVIEW_SEL3")
        let source = [name1: "v1", name2: "v2-unselected", name3: "v3"]
        #expect(store.count == 0)

        let preview = store.processEnvironmentImportPreview(source: source)
        #expect(preview.allSatisfy { $0.changeKind == .add && $0.isSelectableForImport })

        let outcomes = store.applyProcessEnvironmentImport(
            selectedNames: [name1, name3],
            source: source
        )
        #expect(outcomes.count == 2)
        #expect(outcomes[EnvVarStore.canonicalName(name1)] == .imported)
        #expect(outcomes[EnvVarStore.canonicalName(name3)] == .imported)
        #expect(store.count == 2)
        #expect(store.getEnvVar(name: name1) == "v1")
        #expect(store.getEnvVar(name: name3) == "v3")
        // 未勾选项完全未落盘。
        #expect(store.getEnvVar(name: name2) == nil)
        #expect(store.entry(name: name2) == nil)
        let onDisk = String(decoding: readMetadataBytes(dir), as: UTF8.self)
        #expect(onDisk.contains("v1"))
        #expect(onDisk.contains("v3"))
        #expect(!onDisk.contains("v2-unselected"))
    }

    // MARK: - add-only：既有条目永不覆盖

    @Test func applyNeverOverwritesExistingEntries() throws {
        let dir = try makePreviewTempDir("addonly")
        defer { try? FileManager.default.removeItem(at: dir) }

        let (store, _) = makeProbeStore(dir)
        let existingName = uniqueEnvName("MINISCORE_PREVIEW_EXIST")
        let newName = uniqueEnvName("MINISCORE_PREVIEW_WITHNEW")
        #expect(store.setEnvVar(name: existingName, value: "stored-value"))

        let source = [existingName: "process-value", newName: "new-value"]
        let outcomes = store.applyProcessEnvironmentImport(
            selectedNames: [existingName, newName],
            source: source
        )
        #expect(outcomes[EnvVarStore.canonicalName(existingName)] == .skippedAlreadyStored)
        #expect(outcomes[EnvVarStore.canonicalName(newName)] == .imported)
        // 既有条目原值原封不动（与 loadFromProcessEnvironment 同语义）。
        #expect(store.getEnvVar(name: existingName) == "stored-value")
        #expect(store.entry(name: existingName)?.value == "stored-value")
        #expect(store.count == 2)
    }

    // MARK: - secret 选择项经既有 secret 存储路径持久化

    @Test func applyRoutesSelectedSecretsThroughSecretStorage() throws {
        let dir = try makePreviewTempDir("secretapply")
        defer { try? FileManager.default.removeItem(at: dir) }

        let (store, backing) = makeProbeStore(dir)
        let secretName = uniqueEnvName("MINISCORE_PREVIEW_APPLYSECRET") + "_API_KEY"
        let rawSecret = "sk-apply-live-Zzz999-not-in-json"

        let outcomes = store.applyProcessEnvironmentImport(
            selectedNames: [secretName],
            source: [secretName: rawSecret]
        )
        #expect(outcomes[EnvVarStore.canonicalName(secretName)] == .imported)
        let canonical = EnvVarStore.canonicalName(secretName)
        let entry = try #require(store.entry(name: canonical))
        #expect(entry.isSecret)
        #expect(entry.valueInKeychain)
        // 真实值只进 Keychain 探针，元数据文件不得含明文。
        #expect(backing.storedValue(forKey: canonical) == rawSecret)
        let onDisk = String(decoding: readMetadataBytes(dir), as: UTF8.self)
        #expect(!onDisk.contains(rawSecret))
    }

    // MARK: - 既有导入行为，以合成来源验证而不读取主机环境

    @Test func legacyLoadFromProcessEnvironmentStillWorks() throws {
        let dir = try makePreviewTempDir("legacy")
        defer { try? FileManager.default.removeItem(at: dir) }

        let name = uniqueEnvName("MINISCORE_PREVIEW_LEGACY")
        let (store, _) = makeProbeStore(dir)
        let source = [name: "legacy-imported"]
        let imported = store.loadFromProcessEnvironment(source: source)
        #expect(imported == 1)
        #expect(store.getEnvVar(name: name) == "legacy-imported")

        // 同名二次调用不重复导入、不覆盖。
        #expect(store.loadFromProcessEnvironment(source: source) == 0)
        #expect(store.getEnvVar(name: name) == "legacy-imported")
    }
}
