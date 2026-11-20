import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

// MARK: - F6 设置生效链（P0-3 key 注入 + P1-2 默认模型 + P1-5 Agent 设置）
//
// 关键纪律：
//  · 全程临时目录（绝不读写真实 envvars.json / settings.json）；
//  · 全程占位符 key（如 "sk-test-f6-placeholder"），绝不落真实 key 值；
//  · 进程环境操作 setenv/unsetenv 一律 defer 复原 + 套件 .serialized（全局态）。

@Suite("F6 设置生效链", .serialized)
struct F6SettingsChainTests {

    // MARK: 工具

    private func makeTempStore() throws -> (EnvVarStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("F6Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (EnvVarStore(directory: dir), dir)
    }

    // MARK: P0-3 key 注入链路

    /// EnvVarStore 经 F6EnvStoreSource.bind 成为 EnvCredentials 补充源：
    /// 进程环境无该变量时，从 store 命中（设置中心填 key → Provider 拿到的完整链路）。
    @Test func envStoreKeyReachesEnvCredentials() throws {
        TestEnvIsolation.hermeticize()
        let (store, _) = try makeTempStore()
        store.setEnvVar(name: "F6_TEST_KEY", value: "sk-test-f6-placeholder", isSecret: true)
        defer { F6EnvStoreSource.unbind() }
        F6EnvStoreSource.bind(store: store)
        #expect(EnvCredentials.value(for: "F6_TEST_KEY") == "sk-test-f6-placeholder")
        // 大小写不敏感（store 按规范化名存，查询侧容错）
        #expect(EnvCredentials.value(for: "f6_test_key") == "sk-test-f6-placeholder")
        // 未配置变量 → nil（不虚构）
        #expect(EnvCredentials.value(for: "F6_ABSENT_KEY") == nil)
    }

    /// 优先级：进程环境变量 > EnvVarStore（getenv 先查，非空即返回，不查 store）。
    @Test func processEnvWinsOverStore() throws {
        TestEnvIsolation.hermeticize()
        let (store, _) = try makeTempStore()
        store.setEnvVar(name: "F6_TEST_KEY", value: "store-value")
        setenv("F6_TEST_KEY", "process-value", 1)
        defer {
            unsetenv("F6_TEST_KEY")
            F6EnvStoreSource.unbind()
        }
        F6EnvStoreSource.bind(store: store)
        #expect(EnvCredentials.value(for: "F6_TEST_KEY") == "process-value")
        // 进程环境为空字符串 → 视为未设置，回落 store
        setenv("F6_TEST_KEY", "", 1)
        #expect(EnvCredentials.value(for: "F6_TEST_KEY") == "store-value")
    }

    /// unbind 后回到纯进程环境旧行为（补充源清零，零残留）。
    @Test func unbindRestoresLegacyBehavior() throws {
        TestEnvIsolation.hermeticize()
        let (store, _) = try makeTempStore()
        store.setEnvVar(name: "F6_TEST_KEY", value: "store-value")
        F6EnvStoreSource.bind(store: store)
        #expect(EnvCredentials.value(for: "F6_TEST_KEY") == "store-value")
        F6EnvStoreSource.unbind()
        #expect(EnvCredentials.value(for: "F6_TEST_KEY") == nil)
    }

    /// 端到端：DashScopeProvider 凭据解析链（百炼用户场景）—— 进程环境全空时，
    /// 设置中心存的 DASHSCOPE_API_KEY 经补充源被 resolveAPIKey 命中。
    @Test func dashScopeResolvesKeyFromStore() throws {
        TestEnvIsolation.hermeticize()   // 三个百炼变量全部 unset
        #expect(DashScopeProvider.resolveAPIKey(injected: nil) == nil)  // 前置：确实无 key
        let (store, _) = try makeTempStore()
        store.setEnvVar(name: "DASHSCOPE_API_KEY", value: "sk-test-f6-placeholder", isSecret: true)
        defer { F6EnvStoreSource.unbind() }
        F6EnvStoreSource.bind(store: store)
        #expect(DashScopeProvider.resolveAPIKey(injected: nil) == "sk-test-f6-placeholder")
        // 注入 key 仍最高优先
        #expect(DashScopeProvider.resolveAPIKey(injected: "injected") == "injected")
    }

    /// 设置页「保存后免重启生效」语义：bind 后同一 store 实例再写新值，
    /// 凭据解析立即可见（闭包读同一内存表）。
    @Test func storeUpdateVisibleWithoutRebind() throws {
        TestEnvIsolation.hermeticize()
        let (store, _) = try makeTempStore()
        defer { F6EnvStoreSource.unbind() }
        F6EnvStoreSource.bind(store: store)
        #expect(EnvCredentials.value(for: "F6_TEST_KEY") == nil)
        store.setEnvVar(name: "F6_TEST_KEY", value: "late-saved")
        #expect(EnvCredentials.value(for: "F6_TEST_KEY") == "late-saved")
        store.deleteEnvVar(name: "F6_TEST_KEY")
        #expect(EnvCredentials.value(for: "F6_TEST_KEY") == nil)
    }

    // MARK: P1-2 默认 Provider / 默认模型

    /// 无显式选择时，设置中心的默认 provider/model 落到聊天选择。
    @Test @MainActor func applyDefaultProviderModelSelectsChatProvider() {
        let chat = ChatStore()
        #expect(chat.selectedProviderType == nil && chat.selectedModelID == nil)
        let general = GeneralSettings(defaultProviderID: "dashScope", defaultModelID: "qwen3.8-max-preview")
        #expect(chat.applyDefaultProviderModel(general: general) == true)
        #expect(chat.selectedProviderType == .dashScope)
        #expect(chat.selectedModelID == "qwen3.8-max-preview")
        #expect(chat.modelSpeedTier == .balanced)   // 档位随模型自动匹配
    }

    /// 已有显式选择 → 默认不覆盖（restoreSpeedTier 同哲学）。
    @Test @MainActor func applyDefaultDoesNotOverrideExplicitSelection() {
        let chat = ChatStore()
        chat.setProvider(.deepSeek)   // 显式选择
        let general = GeneralSettings(defaultProviderID: "dashScope", defaultModelID: "qwen3.8-max-preview")
        #expect(chat.applyDefaultProviderModel(general: general) == false)
        #expect(chat.selectedProviderType == .deepSeek)
    }

    /// 非法 providerID / 生图生视频后端 → 不落到半配置状态（保持 nil）。
    @Test @MainActor func applyDefaultRejectsInvalidOrNonChatProvider() {
        let chat = ChatStore()
        #expect(chat.applyDefaultProviderModel(
            general: GeneralSettings(defaultProviderID: "no-such-provider")) == false)
        #expect(chat.applyDefaultProviderModel(
            general: GeneralSettings(defaultProviderID: "gimage2")) == false)
        #expect(chat.applyDefaultProviderModel(
            general: GeneralSettings(defaultProviderID: nil)) == false)
        #expect(chat.selectedProviderType == nil && chat.selectedModelID == nil)
    }

    /// 模型不在 provider 目录 → 回落 provider 首内置模型（不悬空）。
    @Test @MainActor func applyDefaultFallsBackToFirstBuiltInModel() {
        let chat = ChatStore()
        let general = GeneralSettings(defaultProviderID: "dashScope", defaultModelID: "no-such-model")
        #expect(chat.applyDefaultProviderModel(general: general) == true)
        #expect(chat.selectedProviderType == .dashScope)
        #expect(chat.selectedModelID == ProviderType.dashScope.builtInModels.first?.id)
    }

    // MARK: F6 U5 自定义供应商（custom. 前缀）默认应用分支
    //
    // applyDefaultProviderModel 的 custom 分支为最近新增，此前仅有内置分支覆盖。
    // 这里补足：在列表命中模型 / 模型不在列表回落首模型 / 空模型列表仅选供应商 /
    // 悬挂默认（记录不存在）/ 小写-规范名大小写不一致的静默失效。

    @MainActor
    private func makeCustomChat(_ records: [EnvVarEntry]) -> ChatStore {
        let chat = ChatStore()
        chat.providerRecordsSource = { records }
        return chat
    }

    /// 自定义供应商默认：模型在列表 → 选供应商 + 该模型，返回 true。
    @Test @MainActor func applyDefaultCustomProviderModelSelected() {
        let records = [EnvVarEntry(
            name: "MY_PROVIDER", value: "«redacted:sk-…»", isSecret: true,
            modelNames: ["gpt-4o", "gpt-4o-mini"])]
        let chat = makeCustomChat(records)
        let general = GeneralSettings(defaultProviderID: "custom.MY_PROVIDER", defaultModelID: "gpt-4o")
        #expect(chat.applyDefaultProviderModel(general: general) == true)
        #expect(chat.selectedCustomProvider?.name == "MY_PROVIDER")
        #expect(chat.selectedModelID == "gpt-4o")
    }

    /// 自定义供应商默认：模型不在列表 → 回落供应商首模型。
    @Test @MainActor func applyDefaultCustomProviderFallsBackToFirstModel() {
        let records = [EnvVarEntry(
            name: "MY_PROVIDER", value: "«redacted:sk-…»", isSecret: true,
            modelNames: ["gpt-4o", "gpt-4o-mini"])]
        let chat = makeCustomChat(records)
        let general = GeneralSettings(defaultProviderID: "custom.MY_PROVIDER", defaultModelID: "no-such-model")
        #expect(chat.applyDefaultProviderModel(general: general) == true)
        #expect(chat.selectedCustomProvider?.name == "MY_PROVIDER")
        #expect(chat.selectedModelID == "gpt-4o")
    }

    /// 自定义供应商默认：空模型列表 → 仅选供应商，模型保留 nil。
    @Test @MainActor func applyDefaultCustomProviderNoModelsSelectsProviderOnly() {
        let records = [EnvVarEntry(
            name: "NO_MODELS_PROVIDER", value: "«redacted:sk-…»", isSecret: true,
            modelNames: [])]
        let chat = makeCustomChat(records)
        let general = GeneralSettings(defaultProviderID: "custom.NO_MODELS_PROVIDER", defaultModelID: nil)
        #expect(chat.applyDefaultProviderModel(general: general) == true)
        #expect(chat.selectedCustomProvider?.name == "NO_MODELS_PROVIDER")
        #expect(chat.selectedModelID == nil)
    }

    /// 悬挂默认：custom.<不存在供应商> → 返回 false，不落入半配置状态。
    @Test @MainActor func applyDefaultCustomProviderDanglingFails() {
        let chat = makeCustomChat([EnvVarEntry(
            name: "EXISTS", value: "«redacted:sk-…»", isSecret: true,
            modelNames: ["m1"])])
        let general = GeneralSettings(defaultProviderID: "custom.NO_SUCH", defaultModelID: nil)
        #expect(chat.applyDefaultProviderModel(general: general) == false)
        #expect(chat.selectedCustomProvider == nil)
        #expect(chat.selectedModelID == nil)
    }

    /// 大小写不一致：defaultProviderID 用全小写而记录是规范大写名。
    /// L1 P2 修复：custom provider 匹配改为大小写不敏感，不再静默失效。
    @Test @MainActor func applyDefaultCustomProviderCaseSensitiveLookup() {
        let records = [EnvVarEntry(
            name: "MY_PROVIDER", value: "«redacted:sk-…»", isSecret: true,
            modelNames: ["gpt-4o"])]
        let chat = makeCustomChat(records)
        // 小写 id 与规范大写记录名不匹配（EnvVarStore 规范名大写）→ 大小写不敏感命中
        let general = GeneralSettings(defaultProviderID: "custom.my_provider", defaultModelID: "gpt-4o")
        #expect(chat.applyDefaultProviderModel(general: general) == true,
                "L1 P2：大小写不敏感匹配应命中并应用默认")
        #expect(chat.selectedCustomProvider?.name == "MY_PROVIDER")
    }

    // MARK: P1-5 Agent 四项设置接入引擎

    /// attachProductionServices 把 AgentSettings 注入引擎与执行器。
    @Test @MainActor func attachProductionServicesInjectsAgentSettings() {
        let bridge = BridgeStore()
        var agent = AgentSettings.default
        agent.maxLoopIterations = 7
        agent.loopIterationsUnlimited = false   // 11/19 起默认不限，这里显式选有限值
        agent.toolTimeoutSeconds = 90
        agent.concurrentToolLimit = 2
        agent.fallbackEnabled = false
        bridge.attachProductionServices(agentSettings: agent)

        let engine = try! #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        #expect(engine.loop.maxIterations == 7)
        #expect(engine.toolTimeoutSeconds == 90)
        #expect(engine.concurrentToolLimit == 2)
        #expect(engine.fallbackEnabled == false)
        // The production composition root always installs the turn-scoped
        // builder; missing readiness provenance still fails closed when used.
        #expect(engine.hasProviderRuntimeRoute == true)
    }

    /// 默认 AgentSettings（attachProductionServices 默认参数）遵循当前 H07 默认 50。
    @Test @MainActor func attachProductionServicesDefaultSettingsBackwardCompatible() {
        let bridge = BridgeStore()
        bridge.attachProductionServices()
        let engine = try! #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        #expect(engine.loop.maxIterations == AgentLoop.unlimitedIterations) // AgentSettings.default：11/19 起默认不限
        #expect(engine.toolTimeoutSeconds == 300)          // AgentSettings.default
        #expect(engine.fallbackEnabled == false)           // AgentSettings.default（跨供应商自动回退默认关闭，2026-11-16）
        #expect(engine.concurrentToolLimit == 4)           // AgentSettings.default
        #expect(engine.hasProviderRuntimeRoute == true)
    }

    /// fallback 路由链构建器：开关关 / 链 ≤1 项 → nil；开且多项 → 按序 FallbackRouter。
    @Test func makeFallbackRouterRespectsToggle() {
        #expect(AgentLoopChatEngine.makeFallbackRouter(enabled: false, providerIDs: ["a", "b"]) == nil)
        #expect(AgentLoopChatEngine.makeFallbackRouter(enabled: true, providerIDs: []) == nil)
        #expect(AgentLoopChatEngine.makeFallbackRouter(enabled: true, providerIDs: ["a"]) == nil)
        let router = try! #require(AgentLoopChatEngine.makeFallbackRouter(enabled: true, providerIDs: ["a", "b"]))
        #expect(router.providerIDs == ["a", "b"])
    }

    /// ConcurrentToolLimitingExecutor：单次调用透传结果；错误透传（非吞）。
    @Test func concurrentLimitingExecutorPassesThrough() async throws {
        let base = EchoToolExecutor()
        let limiting = ConcurrentToolLimitingExecutor(base: base, maxConcurrent: 2)
        let out = try await limiting.execute(name: "echo", input: ["text": "hello"])
        #expect(out == "hello")
        // 错误透传：base 抛错 → limiting 抛错（AgentLoop 转 is_error 结果）
        await #expect(throws: Error.self) {
            _ = try await limiting.execute(name: "boom", input: [:])
        }
    }

    /// ConcurrentToolLimitingExecutor：并发门控真实生效（peak ≤ maxConcurrent）。
    @Test func concurrentLimitingExecutorCapsParallelism() async {
        let counter = ConcurrencyCounter()
        let base = SlowConcurrencyProbeExecutor(counter: counter)
        let limiting = ConcurrentToolLimitingExecutor(base: base, maxConcurrent: 2)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask { _ = try? await limiting.execute(name: "slow", input: [:]) }
            }
            await group.waitForAll()
        }
        let stats = await counter.snapshot()
        #expect(stats.peak <= 2)
        #expect(stats.finished == 6)
    }
}

// MARK: - 测试桩

/// 回显执行器：echo 返回入参 text；boom 抛错；其他返回空串。
struct EchoToolExecutor: ToolExecutor {
    func execute(name: String, input: [String: Any]) async throws -> String {
        if name == "boom" { throw ToolExecutorError.unknownTool(name) }
        if name == "echo" { return (input["text"] as? String) ?? "" }
        return ""
    }
}

/// 并发计数（actor，测试并发上限断言用）。
actor ConcurrencyCounter {
    var inFlight = 0
    var peak = 0
    var finished = 0

    func enter() {
        inFlight += 1
        peak = max(peak, inFlight)
    }
    func exit() {
        inFlight -= 1
        finished += 1
    }
    /// 供测试断言读取的快照（跨 actor 访问须经 await）。
    func snapshot() -> (peak: Int, finished: Int) { (peak, finished) }
}

/// 慢执行器：每次执行睡 30ms，进出计数 —— 探测 ConcurrentToolRunner 门控峰值。
struct SlowConcurrencyProbeExecutor: ToolExecutor {
    let counter: ConcurrencyCounter

    func execute(name: String, input: [String: Any]) async throws -> String {
        await counter.enter()
        try? await Task.sleep(for: .milliseconds(30))
        await counter.exit()
        return "ok"
    }
}
