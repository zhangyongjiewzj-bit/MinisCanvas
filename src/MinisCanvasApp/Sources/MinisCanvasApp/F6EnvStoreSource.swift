import Foundation
import MinisCore

// MARK: - F6（P0-3）设置中心 EnvVarStore → Provider 凭据链接线
//
// 病根：用户在设置中心「环境变量」页填的 API key 存进 EnvVarStore（envvars.json），
// 但全部 Provider 凭据解析只走 EnvCredentials.value(for:) = getenv（进程环境），
// 两边不通 → 设置里填的 key「存了但不生效」。
//
// 修法：EnvCredentials 增加 `supplementarySource` 补充源注入点（MinisCore 侧，
// 默认 nil = 纯旧行为）；本文件把共享 EnvVarStore 接为补充源。优先级：
// 进程环境变量 > EnvVarStore 用户配置（EnvCredentials.value(for:) 先 getenv，
// nil 才查 store）——选择理由：
//   1. 进程环境是开发者/CI 的显式配置，语义上应覆盖应用内存储值；
//   2. 既有测试（setenv 断言 EnvCredentials）与 live 门控结果零变化，破坏最小；
//   3. 与 DiagnosticRunner.checkEnv 双源判定顺序（先进程、后存储）一致。
//
// 生效范围：bind 之后，所有经 EnvCredentials 的凭据解析自动双源——
// DashScope/DeepSeek/Kling/Gimage2/Jimeng resolveAPIKey、ProviderConfig.effectiveAPIKey、
// CloudBackendDescriptor.isConfigured、NodeChatStore / CanvasExecution 的 key 检查，
// 一处接线全链生效。

/// App 级共享 EnvVarStore（与 SettingsCenter 默认目录一致：<AppSupport>/MinisCore）。
/// 非 MainActor、Sendable：EnvVarStore 内部 NSLock 保护，跨线程读安全。
enum F6EnvStoreSource {
    /// 共享存储目录（与 SettingsCenter 默认 init 同目录，读同一份 envvars.json）。
    static func sharedDirectory() -> URL { EnvVarStore.defaultDirectory() }

    /// 共享 EnvVarStore 实例（lazy；首次访问建目录并读盘）。
    static let shared: EnvVarStore = EnvVarStore(directory: sharedDirectory())

    /// 把共享 EnvVarStore 接为 EnvCredentials 的补充凭据源。幂等可重复调用。
    /// App 启动装配时调（attachProductionServices 之前），测试可传自建临时目录 store。
    static func bind(store: EnvVarStore = shared) {
        EnvCredentials.supplementarySource = { name in
            // getEnvVar 已按规范化名（大写）查表；空字符串由 EnvCredentials 过滤。
            store.getEnvVar(name: name)
        }
    }

    /// 解除补充源（测试清理用；nil = 回到纯进程环境旧行为）。
    static func unbind() {
        EnvCredentials.supplementarySource = nil
    }
}
