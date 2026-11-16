import Foundation
import Testing
@testable import MinisCore

// RED：「从进程导入」预览表默认不得勾选凭据类变量；全选/全不选只作用于可选项。
// 被测：EnvVarStore.processEnvironmentImportPreview（既有）+ 待新增
// EnvVarStore.EnvVarProcessImportSelection（默认集合/全选/全不选，视图改为持有它）。
// 修复前：EnvVarProcessImportSelection 不存在 → 测试目标编译失败（编译失败型 RED）。

private func makeSelectionStore() throws -> (EnvVarStore, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("MinisCore-EnvImportDefaultSel-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let suite = "EnvImportDefaultSel-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let store = EnvVarStore(
        directory: dir,
        keychain: KeychainStore(backing: InMemoryKeychainBackingForDefaultSelection()),
        privacyStore: EnvVarPrivacyStore(defaults: defaults)
    )
    return (store, dir)
}

private final class InMemoryKeychainBackingForDefaultSelection: KeychainBacking, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func set(_ value: String, forKey key: String) -> Bool { lock.lock(); defer { lock.unlock() }; values[key] = value; return true }
    func get(_ key: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func delete(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: key); return true }
}

struct EnvVarProcessImportDefaultSelectionTests {
    private let credentialNames = [
        "CLAUDE_CODE_MESSAGING_TOKEN", "GITHUB_TOKEN", "MY_API_KEY",
        "DB_PASSWORD", "SOME_SECRET", "X_OAUTH_TOKEN",
        // 以下名称现有 defaultSensitive 规则未覆盖（后缀/组件白名单没有），需一并补进判定：
        "CLAUDE_CODE_OAUTH_FOO", "DB_PASSWD", "WEB_COOKIE", "SESSION_ID", "SSH_PRIVATE_THING",
    ]
    private let plainNames = ["PATH", "HOME", "G22_IMPORT_PLAIN"]

    private func source() -> [String: String] {
        var s: [String: String] = [:]
        for n in credentialNames + plainNames { s[n] = "v-\(n)" }
        s["EMPTY_VALUE_PLAIN"] = ""
        s["1 BAD NAME!"] = "x"
        s["EMPTY_TOKEN"] = ""
        return s
    }

    @Test func defaultSelectionExcludesCredentialLikeNamesAndKeepsPlain() throws {
        let (store, dir) = try makeSelectionStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let items = store.processEnvironmentImportPreview(source: source())
        let selection = EnvVarStore.EnvVarProcessImportSelection(items: items)

        for n in credentialNames {
            #expect(!selection.selectedNames.contains(n), "凭据类 \(n) 不应默认勾选")
        }
        for n in plainNames {
            #expect(selection.selectedNames.contains(n), "普通类 \(n) 应保持默认勾选")
        }
    }

    @Test func emptyOrInvalidNamesNeverSelectable() throws {
        let (store, dir) = try makeSelectionStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let items = store.processEnvironmentImportPreview(source: source())
        var selection = EnvVarStore.EnvVarProcessImportSelection(items: items)
        #expect(!selection.selectedNames.contains("EMPTY_VALUE_PLAIN"))
        #expect(!selection.selectedNames.contains("EMPTY_TOKEN"))
        #expect(!selection.selectedNames.contains("1 BAD NAME!"))
        selection.selectAll()
        #expect(!selection.selectedNames.contains("EMPTY_VALUE_PLAIN"))
        #expect(!selection.selectedNames.contains("1 BAD NAME!"))
    }

    @Test func selectAllCoversEverySelectableIncludingCredentialsAndSelectNoneClears() throws {
        let (store, dir) = try makeSelectionStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let items = store.processEnvironmentImportPreview(source: source())
        var selection = EnvVarStore.EnvVarProcessImportSelection(items: items)
        let selectable = Set(items.filter(\.isSelectableForImport).map(\.name))

        selection.selectAll()
        #expect(selection.selectedNames == selectable)
        for n in credentialNames { #expect(selection.selectedNames.contains(n)) }

        selection.selectNone()
        #expect(selection.selectedNames.isEmpty)
    }

    /// 手动勾选凭据项仍可导入：selection 暴露的集合即 apply 入参，不改 add-only 语义。
    @Test func manuallyTickedCredentialStillImportsViaExistingApply() throws {
        let (store, dir) = try makeSelectionStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = ["G22_MANUAL_TOKEN": "v"]
        let items = store.processEnvironmentImportPreview(source: src)
        var selection = EnvVarStore.EnvVarProcessImportSelection(items: items)
        #expect(selection.selectedNames.isEmpty)
        selection.selectAll()
        let outcomes = store.applyProcessEnvironmentImport(
            selectedNames: selection.selectedNames.sorted(), source: src)
        #expect(outcomes["G22_MANUAL_TOKEN"] == .imported)
    }
}
