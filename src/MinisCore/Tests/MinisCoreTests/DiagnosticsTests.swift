import Foundation
import Testing
@testable import MinisCore

/// 唯一临时目录（测试并行运行，绝不共享路径）。
/// 注意：文件名用字符串拼接而非 `\\(...)` 插值，避免转义问题。
private func makeTempDir(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MinisCore-Diagnostics-" + label + "-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// 构造一个完全确定性的诊断器：
/// - EnvVarStore 指向临时目录（不碰真实 Application Support）
/// - 四个本地后端全部禁用（不发任何网络请求）
/// - 全新的 NetworkMonitor（未启动 → 网络项恒为 warning）
private func makeRunner(
    requiredEnvVars: [String] = [],
    providerConfigs: [ProviderConfig] = [],
    storageDirectories: [URL]? = nil
) throws -> (DiagnosticRunner, URL) {
    let dir = try makeTempDir("runner")
    let store = EnvVarStore(directory: dir)
    let backends = LocalBackends(configs: [
        .ollama: LocalBackendConfig(kind: .ollama, baseURL: "http://127.0.0.1:11434", enabled: false),
        .comfyui: LocalBackendConfig(kind: .comfyui, baseURL: "http://127.0.0.1:8188", enabled: false),
        .sdWebUI: LocalBackendConfig(kind: .sdWebUI, baseURL: "http://127.0.0.1:7860", enabled: false),
        .wan: LocalBackendConfig(kind: .wan, baseURL: "http://127.0.0.1:8188", enabled: false),
    ])
    let runner = DiagnosticRunner(
        envStore: store,
        localBackends: backends,
        networkMonitor: NetworkMonitor(),
        providerConfigs: providerConfigs,
        storageDirectories: storageDirectories ?? [dir],
        requiredEnvVars: requiredEnvVars
    )
    return (runner, dir)
}

struct DiagnosticsTests {

    // MARK: - 容错：runAll 永不抛错，五个维度齐全

    @Test func runAllCoversAllCategoriesAndNeverThrows() async throws {
        let (runner, dir) = try makeRunner(
            requiredEnvVars: ["MINISCORE_MISSING_VAR_" + UUID().uuidString],
            providerConfigs: [ProviderConfig(label: "NoKey", providerType: .openAI)]
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let report = await runner.runAll()
        // env(1) + backends(4) + network(1) + providers(1) + storage(1)
        #expect(report.items.count == 8)
        for category in HealthCategory.allCases {
            let msg = "category " + category.rawValue + " 应有条目"
            #expect(!report.items(in: category).isEmpty, Comment(rawValue: msg))
        }
        // 存在缺失环境变量 → 整体为 error（但 runAll 本身不抛错）
        #expect(report.summary.overall == .error)
        #expect(!report.summary.isHealthy)
    }

    @Test func runAllPreservesCanonicalCategoryOrdering() async throws {
        let (runner, dir) = try makeRunner(
            requiredEnvVars: ["MINISCORE_ORDERING_MISSING_" + UUID().uuidString],
            providerConfigs: [ProviderConfig(label: "Ordering-NoKey", providerType: .openAI)]
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let report = await runner.runAll()
        #expect(report.items.map(\.category) == [
            .env,
            .backends, .backends, .backends, .backends,
            .network,
            .providers,
            .storage,
        ])
    }

    @Test func doctorUsesInjectedRunner() async throws {
        let (runner, dir) = try makeRunner()
        defer { try? FileManager.default.removeItem(at: dir) }

        let report = await Doctor.doctor(runner: runner)
        #expect(report.summary.okCount + report.summary.warningCount + report.summary.errorCount == report.items.count)
        #expect(report.summary.overall == .warning) // 全禁用后端 + 未启动网络 → warning
    }

    // MARK: - env：存在且脱敏；缺失 → error

    @Test func envCheckRedactsSecretAndFlagsMissing() throws {
        let (runner, dir) = try makeRunner(
            requiredEnvVars: ["MINISCORE_TEST_SECRET_KEY", "MINISCORE_TEST_MISSING_XYZ"]
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = runner.envStore.setEnvVar(
            name: "MINISCORE_TEST_SECRET_KEY",
            value: "sk-1234567890abcdef",
            isSecret: true
        )

        let items = runner.checkEnv()
        let secretItem = try #require(items.first { $0.name == "MINISCORE_TEST_SECRET_KEY" })
        #expect(secretItem.status == .ok)
        #expect(secretItem.details.first?.contains(EnvVarRedactor.redact("sk-1234567890abcdef")) == true, "应展示脱敏值")
        #expect(secretItem.details.first?.contains("sk-1234567890abcdef") == false, "不得落明文")
        let detail = try #require(secretItem.details.first)
        let characters = Array("sk-1234567890abcdef")
        for start in 0...(characters.count - 4) {
            #expect(!detail.contains(String(characters[start..<(start + 4)])))
        }

        let missingItem = try #require(items.first { $0.name == "MINISCORE_TEST_MISSING_XYZ" })
        #expect(missingItem.status == .error)
        #expect(missingItem.message == "未设置")
    }

    // MARK: - backends：全禁用 → 全部 warning，不发网络请求

    @Test func backendsCheckDisabledAreWarnings() async throws {
        let (runner, dir) = try makeRunner()
        defer { try? FileManager.default.removeItem(at: dir) }

        let items = await runner.checkBackends()
        #expect(items.count == 4)
        #expect(items.allSatisfy { $0.status == .warning })
        #expect(items.allSatisfy { $0.message == "未启用" })
        #expect(Set(items.map(\.name)) == Set(["Ollama", "ComfyUI", "SD WebUI", "Wan"]))
    }

    // MARK: - network：监视器未启动 → warning（确定性，不依赖真实网络）

    @Test func networkCheckNotStartedIsWarning() throws {
        let (runner, dir) = try makeRunner()
        defer { try? FileManager.default.removeItem(at: dir) }

        let item = runner.checkNetwork()
        #expect(item.category == .network)
        #expect(item.status == .warning)
        #expect(item.message == "网络监视器未启动，连通性未知")
    }

    // MARK: - providers：ok / 已禁用 / 缺 key / 无 builder

    @Test func providersCheckOkDisabledMissingKeyUnsupported() throws {
        let ok = ProviderConfig(label: "OpenAI-Ok", providerType: .openAI, apiKey: "sk-test-key-123")
        let disabled = ProviderConfig(label: "OpenAI-Disabled", providerType: .openAI, isEnabled: false, apiKey: "sk-test-key-123")
        let missing = ProviderConfig(label: "OpenAI-NoKey", providerType: .openAI)
        let unsupported = ProviderConfig(label: "Unsupported", providerType: .unsupported, apiKey: "x")
        let (runner, dir) = try makeRunner(providerConfigs: [ok, disabled, missing, unsupported])
        defer { try? FileManager.default.removeItem(at: dir) }

        let items = runner.checkProviders()
        #expect(items.count == 4)
        #expect(items[0].status == .ok)
        #expect(items[0].message == "配置可解析")
        #expect(items[1].status == .warning)
        #expect(items[1].message == "已禁用")
        #expect(items[2].status == .error)
        #expect(items[2].details.contains { $0.contains("No API key") })
        #expect(items[3].status == .error)
        #expect(items[3].details.contains { $0.contains("No provider builder") })
    }

    // MARK: - storage：可写目录 → ok；父路径为文件的目录 → error

    @Test func storageCheckWritableAndBlocked() throws {
        let dir = try makeTempDir("storage")
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = dir.appendingPathComponent("good", isDirectory: true)
        try FileManager.default.createDirectory(at: good, withIntermediateDirectories: true)
        let blockerFile = dir.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blockerFile)
        let blocked = blockerFile.appendingPathComponent("sub") // 父路径是文件 → 建目录必失败

        let (runner, _) = try makeRunner(storageDirectories: [good, blocked])
        let items = runner.checkStorage()
        #expect(items.count == 2)
        #expect(items[0].status == .ok)
        #expect(items[0].message == "可写")
        #expect(items[1].status == .error)
        #expect(items[1].message == "不可写")
    }

    // MARK: - 汇总

    @Test func summaryCountsAndOverallSeverity() {
        let ok = HealthItem(name: "a", category: .env, status: .ok, message: "")
        let warn = HealthItem(name: "b", category: .env, status: .warning, message: "")
        let err = HealthItem(name: "c", category: .env, status: .error, message: "")

        let s = HealthSummary(items: [ok, warn, err])
        #expect(s.okCount == 1)
        #expect(s.warningCount == 1)
        #expect(s.errorCount == 1)
        #expect(s.overall == .error)
        #expect(!s.isHealthy)

        #expect(HealthSummary(items: [ok, warn]).overall == .warning)
        #expect(HealthSummary(items: [ok]).overall == .ok)
        #expect(HealthSummary(items: [ok]).isHealthy)
        #expect(HealthStatus.worse(.ok, .warning) == .warning)
        #expect(HealthStatus.worse(.error, .warning) == .error)
    }

    @Test func reportSummaryComputedFromItems() {
        let report = HealthReport(items: [
            HealthItem(name: "x", category: .network, status: .ok, message: ""),
            HealthItem(name: "y", category: .network, status: .error, message: ""),
        ])
        #expect(report.summary.errorCount == 1)
        #expect(report.summary.overall == .error)
        #expect(report.items(in: .network).count == 2)
        #expect(report.items(in: .env).isEmpty)
    }

    // MARK: - JSON + 人类可读文本

    @Test func jsonRoundTripPreservesReport() throws {
        // 秒级对齐的时间戳：ISO8601 编码精度为秒，避免往返后不等。
        let report = HealthReport(
            items: [
                HealthItem(name: "OPENAI_API_KEY", category: .env, status: .ok, message: "已设置", details: ["值(脱敏): *******************"]),
                HealthItem(name: "网络连通性", category: .network, status: .warning, message: "网络监视器未启动，连通性未知"),
            ],
            timestamp: Date(timeIntervalSince1970: 1_752_000_000)
        )

        let json = try Doctor.json(report)
        #expect(json.contains("\"overall\""))
        #expect(json.contains("\"summary\""))

        let data = try Doctor.jsonData(report)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(HealthReport.self, from: data)
        #expect(decoded == report)
    }

    @Test func humanReadableTextContainsCategoriesAndOverall() async throws {
        let (runner, dir) = try makeRunner(requiredEnvVars: ["MINISCORE_TEST_MISSING_VAR"])
        defer { try? FileManager.default.removeItem(at: dir) }

        let report = await runner.runAll()
        let text = Doctor.humanReadableText(report)
        #expect(text.contains("MinisCanvas 健康诊断"))
        #expect(text.contains("整体状态"))
        #expect(text.contains("[error]"))
        for category in HealthCategory.allCases {
            #expect(text.contains(category.displayName), "文本应包含分类 \\(category.displayName)")
        }
    }
}
