import Foundation

/// 健康诊断执行器：把环境、本地后端、网络、Provider 配置、存储五个维度
/// 的检查跑一遍，汇总成一份 `HealthReport`。
///
/// 每一项检查独立容错：单个维度失败只会产生对应的 error/warning 条目，
/// 不会中断整轮诊断（`runAll()` 不抛错）。
public struct DiagnosticRunner: Sendable {
    // MARK: - 依赖（全部可注入，便于测试与 UI 层定制）

    /// 环境变量来源（进程环境 + 存储条目都会查）。
    public var envStore: EnvVarStore
    /// 本地后端探测（Ollama / ComfyUI / SD WebUI / Wan）。
    public var localBackends: LocalBackends
    /// 网络连通性监视器。
    public var networkMonitor: NetworkMonitor
    /// 需要参与解析检查的 Provider 配置列表（ProviderFactory 逐个解析）。
    public var providerConfigs: [ProviderConfig]
    /// 需要验证可写性的存储目录。
    public var storageDirectories: [URL]
    /// 必需环境变量清单。
    public var requiredEnvVars: [String]

    /// 默认必需环境变量（MinisCanvas 实际解析的 key 集合）。
    public static let defaultRequiredEnvVars: [String] = [
        "OPENAI_API_KEY",
        "ANTHROPIC_API_KEY",
        "OPENROUTER_API_KEY",
        "DASHSCOPE_API_KEY",
        "BAILIAN_TOKEN_PLAN_API_KEY",
        "HERMES_CUSTOM_QWEN38_API_KEY",
    ]

    public init(
        envStore: EnvVarStore = EnvVarStore(directory: EnvVarStore.defaultDirectory()),
        localBackends: LocalBackends = .shared,
        networkMonitor: NetworkMonitor = .shared,
        providerConfigs: [ProviderConfig] = [],
        storageDirectories: [URL] = [EnvVarStore.defaultDirectory()],
        requiredEnvVars: [String] = DiagnosticRunner.defaultRequiredEnvVars
    ) {
        self.envStore = envStore
        self.localBackends = localBackends
        self.networkMonitor = networkMonitor
        self.providerConfigs = providerConfigs
        self.storageDirectories = storageDirectories
        self.requiredEnvVars = requiredEnvVars
    }

    // MARK: - 入口

    /// 运行全部检查并汇总。永不抛错。
    public func runAll() async -> HealthReport {
        // These checks have no data dependency on one another. Schedule them
        // together so a slow local-backend probe or storage probe does not
        // extend the critical path for the other diagnostics. The final
        // flattening deliberately preserves the long-standing category order
        // used by the terminal and UI consumers.
        async let envItems = checkEnv()
        async let backendItems = checkBackends()
        async let networkItem = checkNetwork()
        async let providerItems = checkProviders()
        async let storageItems = checkStorage()

        let (env, backends, network, providers, storage) = await (
            envItems,
            backendItems,
            networkItem,
            providerItems,
            storageItems
        )
        let items = env + backends + [network] + providers + storage
        return HealthReport(items: items)
    }

    // MARK: - env

    /// 必需环境变量存在性检查。存在 → ok；值为空 → warning；缺失 → error。
    /// 敏感变量（EnvVarPrivacyStore 判定）的值一律脱敏后放入 details。
    public func checkEnv() -> [HealthItem] {
        requiredEnvVars.map { name in
            let canonical = EnvVarStore.canonicalName(name)
            let processValue = EnvCredentials.value(for: canonical) // nil = 未设置或空
            let storedValue = envStore.getEnvVar(name: canonical)   // 可能为 ""

            if let processValue, !processValue.isEmpty {
                return HealthItem(
                    name: canonical, category: .env, status: .ok, message: "已设置",
                    details: [redactedDetail(name: canonical, value: processValue)]
                )
            }
            if let storedValue {
                if storedValue.isEmpty {
                    return HealthItem(
                        name: canonical, category: .env, status: .warning,
                        message: "已设置但值为空"
                    )
                }
                return HealthItem(
                    name: canonical, category: .env, status: .ok, message: "已设置",
                    details: [redactedDetail(name: canonical, value: storedValue)]
                )
            }
            return HealthItem(
                name: canonical, category: .env, status: .error, message: "未设置",
                details: ["进程环境变量与 EnvVarStore 中均未找到"]
            )
        }
    }

    /// 敏感值脱敏；非敏感值只报长度，不落明文。
    private func redactedDetail(name: String, value: String) -> String {
        if EnvVarPrivacyStore.shared.isSecret(name: name) {
            return "值(脱敏): \(EnvVarRedactor.redact(value))"
        }
        return "值长度: \(value.count)"
    }

    // MARK: - backends

    /// 本地后端探测：启用且在线 → ok；启用但未在线 → warning；未启用/未配置 → warning。
    /// 探测由 LocalBackends.detect() 并行执行（每项 2 秒超时）。
    public func checkBackends() async -> [HealthItem] {
        let online = await localBackends.detect()
        return LocalBackendKind.allCases.map { kind in
            guard let config = localBackends.config(for: kind) else {
                return HealthItem(
                    name: kind.displayName, category: .backends, status: .warning,
                    message: "未配置", details: [kind.defaultBaseURL]
                )
            }
            guard config.enabled else {
                return HealthItem(
                    name: kind.displayName, category: .backends, status: .warning,
                    message: "未启用", details: [config.baseURL]
                )
            }
            if online[kind] == true {
                return HealthItem(
                    name: kind.displayName, category: .backends, status: .ok,
                    message: "在线", details: [config.baseURL]
                )
            }
            return HealthItem(
                name: kind.displayName, category: .backends, status: .warning,
                message: "未在线", details: ["\(config.baseURL)（默认 \(kind.defaultBaseURL)）"]
            )
        }
    }

    // MARK: - network

    /// 网络连通性：监视器未启动 → warning（无法判定）；已启动则按快照判 ok/error。
    public func checkNetwork() -> HealthItem {
        guard networkMonitor.isStarted() else {
            return HealthItem(
                name: "网络连通性", category: .network, status: .warning,
                message: "网络监视器未启动，连通性未知",
                details: ["调用 NetworkMonitor.shared.start() 后可检测真实连通性"]
            )
        }
        if networkMonitor.isConnected() {
            var details: [String] = []
            if networkMonitor.isExpensive() { details.append("当前为计费网络（蜂窝/热点）") }
            return HealthItem(
                name: "网络连通性", category: .network, status: .ok,
                message: "已连接", details: details
            )
        }
        return HealthItem(
            name: "网络连通性", category: .network, status: .error,
            message: "未连接网络"
        )
    }

    // MARK: - providers

    /// Provider 配置解析检查：逐个调用 ProviderFactory.makeProvider。
    /// 已禁用 → warning；解析成功 → ok；缺 key/无 builder → error。
    public func checkProviders() -> [HealthItem] {
        providerConfigs.map { config in
            let name = config.label.isEmpty ? config.providerType.displayName : config.label
            guard config.isEnabled else {
                return HealthItem(
                    name: name, category: .providers, status: .warning,
                    message: "已禁用", details: [config.providerType.displayName]
                )
            }
            do {
                _ = try ProviderFactory.shared.makeProvider(for: config)
                return HealthItem(
                    name: name, category: .providers, status: .ok,
                    message: "配置可解析", details: [config.providerType.displayName]
                )
            } catch {
                return HealthItem(
                    name: name, category: .providers, status: .error,
                    message: "解析失败", details: [
                        config.providerType.displayName,
                        error.localizedDescription,
                    ]
                )
            }
        }
    }

    // MARK: - storage

    /// 存储目录可写性检查：建目录 + 写探针文件 + 删除，全通过 → ok。
    public func checkStorage() -> [HealthItem] {
        storageDirectories.map { dir in
            let name = dir.lastPathComponent.isEmpty ? dir.path : dir.lastPathComponent
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let probe = dir.appendingPathComponent(".healthcheck-\(UUID().uuidString).tmp")
                try Data("ok".utf8).write(to: probe)
                try FileManager.default.removeItem(at: probe)
                return HealthItem(
                    name: name, category: .storage, status: .ok,
                    message: "可写", details: [dir.path]
                )
            } catch {
                return HealthItem(
                    name: name, category: .storage, status: .error,
                    message: "不可写", details: [dir.path, error.localizedDescription]
                )
            }
        }
    }
}
