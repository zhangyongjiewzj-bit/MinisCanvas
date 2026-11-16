import Foundation
import MinisCore

/// 测试档：仅在已打包 field profile 进程里允许调小会话 token 上限，
/// 让 P-03（超限后新会话继续）与 P-18（压缩原因卡）能在包上用少量消息触发。
///
/// 生效条件（全部满足，沿用 `RuntimeIsolationProfile.makePackagedField` 的激活判定）：
/// - 环境 `MINISCANVAS_FIELD_PROFILE == "1"`；
/// - 启动参数恰好出现一次 `--miniscanvas-field-profile`；
/// - `MINISCANVAS_FIELD_CONTEXT_LIMIT_TOKENS` 是纯十进制正整数。
/// 取值夹在 [minimumTokens, 默认上限]；非法值（空、非数字、负、零、带符号、溢出）一律忽略，
/// 回落到默认上限。非 field profile 永远返回默认上限。
enum FieldContextLimitOverride {
    static let environmentKey = "MINISCANVAS_FIELD_CONTEXT_LIMIT_TOKENS"
    static let minimumTokens = 2_000

    static func effectiveTokenLimit(
        defaultCap: Int?, environment: [String: String], arguments: [String]
    ) -> Int? {
        if let defaultCap {
            return effectiveCap(defaultCap: defaultCap, environment: environment, arguments: arguments)
        }
        guard environment[RuntimeIsolationProfile.fieldActivationMarkerKey] == "1",
              arguments.filter({ $0 == RuntimeIsolationProfile.fieldActivationArgument }).count == 1,
              let raw = environment[environmentKey], !raw.isEmpty,
              raw.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
              let requested = Int(raw), requested > 0 else { return nil }
        return min(RequestBudget.defaultMaxTokensPerSession, max(minimumTokens, requested))
    }

    static func effectiveCap(
        defaultCap: Int = RequestBudget.defaultMaxTokensPerSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Int {
        guard environment[RuntimeIsolationProfile.fieldActivationMarkerKey] == "1",
              arguments.filter({ $0 == RuntimeIsolationProfile.fieldActivationArgument }).count == 1,
              let raw = environment[environmentKey],
              !raw.isEmpty, raw.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
              let requested = Int(raw), requested > 0 else {
            return defaultCap
        }
        return min(defaultCap, max(minimumTokens, requested))
    }
}
