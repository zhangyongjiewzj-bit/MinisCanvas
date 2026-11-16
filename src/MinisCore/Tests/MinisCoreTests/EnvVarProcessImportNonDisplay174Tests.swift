import Foundation
import Testing
@testable import MinisCore

// D-PRIVACY-08（lane 174 认证钉）：「可以从进程环境导入变量，但不会显示未授权
// secret 原文」。导入与脱敏实现均已在 base 存在（ENVIMPORT-PREVIEW-118 核心层、
// ENVIMPORT-CONSUMER-147/162 UI 消费侧、EnvVarRedactor/ContentSecretRedactor 缝）。
// 本 lane 的生产代码写集 = 空集；本文件补齐 UNVERIFIED_SUBCAPABILITY → 认证所需
// 的端到端钉：
//  1) 全量导入（loadFromProcessEnvironment）后，secret 类变量的合成哨兵明文不得
//     出现在任何可渲染面（落盘 envvars.json 元数据、env.list 斜杠命令输出、
//     转录/日志内容级脱敏缝），而已授权凭据消费者仍可取回原值（usable）；
//  2) 生产进程环境预览（测试注入合成 source）对 secret 类候选
//     恒为占位符、整条记录不携带明文；真正非 secret 的变量原样展示、不受影响；
//  3) 选择性 apply（UI 唯一写入口语义）勾选后仍满足明文不落渲染面、非 secret
//     条目可用。
// 授权判定唯一事实来源 = EnvVarPrivacyStore.isSecret(name:)（名称分类），本文件
// 不引入第二套判定。所有值均为测试内生成的合成哨兵，与任何真实凭据无关。

/// 每个测试独占的临时目录（测试并行运行，路径绝不共享）。
private func makeLane174Dir(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MinisCore-Dev174-EnvNonDisplay-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// 唯一、合法的合成变量名；不修改进程环境。
private func lane174Name(_ label: String) -> String {
    "DEV174_\(label)_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))".uppercased()
}

/// 全部后端禁用（不触发任何网络探测）。
private func lane174OfflineBackends() -> LocalBackends {
    let configs: [LocalBackendKind: LocalBackendConfig] = Dictionary(
        uniqueKeysWithValues: LocalBackendKind.allCases.map {
            ($0, LocalBackendConfig(kind: $0, baseURL: $0.defaultBaseURL, enabled: false))
        }
    )
    return LocalBackends(configs: configs)
}

/// 独立偏好域和内存 Keychain backing；不触碰用户环境与真实钥匙串。
private func makeLane174Store(_ dir: URL) throws -> (store: EnvVarStore, defaults: UserDefaults, suiteName: String) {
    let suiteName = "EnvNonDisplay174.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    let store = EnvVarStore(
        directory: dir,
        keychain: KeychainStore(backing: InMemoryKeychainBacking()),
        privacyStore: EnvVarPrivacyStore(defaults: defaults)
    )
    return (store, defaults, suiteName)
}

private func readLane174MetadataText(_ dir: URL) throws -> String {
    let data = try Data(contentsOf: dir.appendingPathComponent(EnvVarStore.fileName))
    return String(decoding: data, as: UTF8.self)
}

struct EnvVarProcessImportNonDisplay174Tests {

    // MARK: - 1. 全量导入路径：secret 明文不上任何渲染面

    @Test func bulkProcessEnvironmentImportKeepsUnauthorizedSecretPlaintextOffRenderedSurfaces() async throws {
        let dir = try makeLane174Dir("bulk")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = try makeLane174Store(dir)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let store = fixture.store

        let secretName = lane174Name("BULKSECRET") + "_API_KEY"   // EnvVarPrivacyStore 默认后缀 → secret 类
        let plainName = lane174Name("BULKPLAIN")                  // 无敏感词 → 非 secret 类
        let tokenName = lane174Name("BULK") + "_TOKEN"
        let passwordName = lane174Name("BULK") + "_PASSWORD"
        let opaqueName = lane174Name("BULK") + "_OPAQUE_SLOT"
        let secretSentinel = "sk-dev174-\(UUID().uuidString)-bulk-plaintext"
        let plainValue = "dev174-bulk-plain-visible"
        let tokenValue = "dev174-bulk-token-synthetic"
        let passwordValue = "dev174-bulk-password-synthetic"
        let opaqueValue = "dev174-bulk-opaque-synthetic"
        let source = [
            secretName: secretSentinel,
            plainName: plainValue,
            tokenName: tokenValue,
            passwordName: passwordValue,
            opaqueName: opaqueValue,
        ]

        #expect(store.loadFromProcessEnvironment(source: source) == source.count)

        // 授权判定（唯一事实来源）落到条目：secret 名 → isSecret + Keychain 托管。
        let entry = try #require(store.entry(name: secretName))
        #expect(entry.isSecret)
        #expect(entry.valueInKeychain)
        for name in [tokenName, passwordName] {
            #expect(store.entry(name: name)?.isSecret == true)
            #expect(store.entry(name: name)?.valueInKeychain == true)
        }

        // 已授权变量仍可正常使用：凭据消费者取回的是原值（读取≠展示）。
        #expect(store.getEnvVar(name: secretName) == secretSentinel)

        // 渲染面 A：落盘元数据（设置页列表数据源/导出面）不含明文；非 secret 原样。
        let onDisk = try readLane174MetadataText(dir)
        #expect(!onDisk.contains(secretSentinel))
        #expect(!onDisk.contains(tokenValue))
        #expect(!onDisk.contains(passwordValue))
        #expect(onDisk.contains(plainValue))

        // 渲染面 B：env.list 斜杠命令（聊天/转录面真正执行的渲染输出）。
        let deps = CommandDependencies(
            env: store,
            log: LogManager(directory: dir),
            backends: lane174OfflineBackends(),
            sessions: SessionStore(directory: dir),
            memory: MemoryStore(directory: dir),
            workflows: WorkflowStore(storeDirectory: dir.appendingPathComponent("Workflows", isDirectory: true))
        )
        let registry = CommandRegistry(commands: PresetCommands.all(dependencies: deps))
        let result = try await registry.execute(id: "env.list")
        #expect(result.ok)
        #expect(!result.text.contains(secretSentinel), "env.list 输出携带了未授权 secret 原文")
        #expect(!result.text.contains(tokenValue))
        #expect(!result.text.contains(passwordValue))
        #expect(!result.text.contains(opaqueValue))
        #expect(result.text.contains(secretName))
        #expect(result.text.contains("[secret]"))
        // 未显式允许公开的普通变量也只显示名称；其值仍可供授权消费者使用。
        #expect(result.text.contains("\(plainName) = [hidden]"))
        #expect(result.text.contains("\(opaqueName) = [hidden]"))
        #expect(!result.text.contains(plainValue))

        // 渲染面 C：转录/日志内容级脱敏缝（ChatTranscriptRedactor/ContentSecretRedactor
        // 的底层规则）对嵌在自由文本中的明文整体替换。
        let (masked, hits) = EnvVarRedactor.redactAll(
            in: "tool echoed \(secretSentinel) back", entries: store.allEnvVars)
        #expect(hits >= 1)
        #expect(!masked.contains(secretSentinel))
    }

    // MARK: - 2. 合成环境预览：secret 候选恒占位、非 secret 原样

    @Test func syntheticProcessEnvironmentPreviewWithholdsSecretCandidatePlaintext() throws {
        let dir = try makeLane174Dir("livepreview")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = try makeLane174Store(dir)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let store = fixture.store

        let secretName = lane174Name("LIVESECRET") + "_API_KEY"
        let plainName = lane174Name("LIVEPLAIN")
        let tokenName = lane174Name("LIVE") + "_TOKEN"
        let passwordName = lane174Name("LIVE") + "_PASSWORD"
        let opaqueName = lane174Name("LIVE") + "_OPAQUE_SLOT"
        let secretSentinel = "sk-dev174-\(UUID().uuidString)-preview-plaintext"
        let plainValue = "dev174-live-preview-visible"
        let tokenValue = "dev174-preview-token-synthetic"
        let passwordValue = "dev174-preview-password-synthetic"
        let opaqueValue = "dev174-preview-opaque-synthetic"
        EnvVarPrivacyStore(defaults: fixture.defaults).unmarkSecret(name: plainName)
        let source = [
            secretName: secretSentinel,
            plainName: plainValue,
            tokenName: tokenValue,
            passwordName: passwordValue,
            opaqueName: opaqueValue,
        ]

        // 同一个生产预览方法，注入合成字典而非读取主机进程环境。
        let preview = store.processEnvironmentImportPreview(source: source)

        let secretItem = try #require(preview.first { $0.name == secretName })
        #expect(secretItem.isSecretClassified)
        #expect(secretItem.valueDisplay == EnvVarStore.EnvVarProcessImportPreviewItem.redactedValuePlaceholder)
        #expect(!secretItem.valueDisplay.contains(secretSentinel))
        // 整条记录的任何字段（含 description 回显）都不得携带原始明文。
        #expect(!String(describing: secretItem).contains(secretSentinel))

        let plainItem = try #require(preview.first { $0.name == plainName })
        #expect(!plainItem.isSecretClassified)
        #expect(plainItem.valueDisplay == plainValue)   // 非 secret 变量不受影响
        for (name, value) in [(tokenName, tokenValue), (passwordName, passwordValue)] {
            let item = try #require(preview.first { $0.name == name })
            #expect(item.isSecretClassified)
            #expect(item.valueDisplay == EnvVarStore.EnvVarProcessImportPreviewItem.redactedValuePlaceholder)
            #expect(!String(describing: item).contains(value))
        }
        let opaqueItem = try #require(preview.first { $0.name == opaqueName })
        #expect(!opaqueItem.isSecretClassified)
        #expect(opaqueItem.valueDisplay == EnvVarStore.EnvVarProcessImportPreviewItem.redactedValuePlaceholder)
        #expect(!String(describing: opaqueItem).contains(opaqueValue))

        // 预览零写副作用：没有任何条目落入存储。
        #expect(store.count == 0)
    }

    // MARK: - 3. 选择性 apply（确认写入口）后仍无明文面

    @Test func selectiveApplyFromSyntheticEnvironmentKeepsSentinelOffRenderedSurfaces() throws {
        let dir = try makeLane174Dir("liveapply")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = try makeLane174Store(dir)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let store = fixture.store

        let secretName = lane174Name("APPLYSECRET") + "_API_KEY"
        let plainName = lane174Name("APPLYPLAIN")
        let tokenName = lane174Name("APPLY") + "_TOKEN"
        let passwordName = lane174Name("APPLY") + "_PASSWORD"
        let opaqueName = lane174Name("APPLY") + "_OPAQUE_SLOT"
        let unselectedName = lane174Name("APPLY_UNSELECTED")
        let secretSentinel = "sk-dev174-\(UUID().uuidString)-apply-plaintext"
        let plainValue = "dev174-apply-visible"
        let tokenValue = "dev174-apply-token-synthetic"
        let passwordValue = "dev174-apply-password-synthetic"
        let opaqueValue = "dev174-apply-opaque-synthetic"
        let source = [
            secretName: secretSentinel,
            plainName: plainValue,
            tokenName: tokenValue,
            passwordName: passwordValue,
            opaqueName: opaqueValue,
            unselectedName: "dev174-unselected-synthetic",
        ]

        let outcomes = store.applyProcessEnvironmentImport(
            selectedNames: Array(source.keys.filter { $0 != unselectedName }), source: source
        )
        #expect(outcomes[secretName] == .imported)
        #expect(outcomes[plainName] == .imported)
        #expect(outcomes[tokenName] == .imported)
        #expect(outcomes[passwordName] == .imported)
        #expect(outcomes[opaqueName] == .imported)
        #expect(outcomes[unselectedName] == nil)
        #expect(store.entry(name: unselectedName) == nil)

        let secretEntry = try #require(store.entry(name: secretName))
        #expect(secretEntry.isSecret)
        #expect(secretEntry.valueInKeychain)
        // 已授权：凭据消费者仍可用原值。
        #expect(store.getEnvVar(name: secretName) == secretSentinel)
        // 非 secret：完全不受影响。
        #expect(store.getEnvVar(name: plainName) == plainValue)
        #expect(store.getEnvVar(name: opaqueName) == opaqueValue)

        // 渲染面：落盘元数据不含未授权 secret 明文。
        let onDisk = try readLane174MetadataText(dir)
        #expect(!onDisk.contains(secretSentinel))
        #expect(!onDisk.contains(tokenValue))
        #expect(!onDisk.contains(passwordValue))
        #expect(onDisk.contains(plainValue))
    }
}
