import Testing
import Foundation
import MinisCore

// MARK: - F6（P0-3）核心级：EnvCredentials.supplementarySource 双源解析
//
// 契约：value(for:) 先查进程环境（getenv），未命中/空 → 回落补充源
// （设置中心 EnvVarStore）；补充源空串视为未设置；nil 补充源 = 纯旧行为。
// 测试用隔离环境变量名（F6_TEST_*），不依赖开发机真实 key。

@Suite("F6 EnvCredentials 补充凭据源", .serialized)
struct F6SupplementarySourceTests {

    /// 进程环境有值 → 优先（补充源不覆盖显式环境配置）
    @Test func processEnvWinsOverSupplementary() {
        let orig = EnvCredentials.supplementarySource
        defer { EnvCredentials.supplementarySource = orig; unsetenv("F6_TEST_KEY_A") }
        setenv("F6_TEST_KEY_A", "from-env", 1)
        EnvCredentials.supplementarySource = { $0 == "F6_TEST_KEY_A" ? "from-store" : nil }
        #expect(EnvCredentials.value(for: "F6_TEST_KEY_A") == "from-env")
    }

    /// 进程环境无值 → 回落补充源（用户 API key P0 的核心链路）
    @Test func fallsBackToSupplementaryWhenEnvMissing() {
        let orig = EnvCredentials.supplementarySource
        defer { EnvCredentials.supplementarySource = orig; unsetenv("F6_TEST_KEY_B") }
        unsetenv("F6_TEST_KEY_B")
        EnvCredentials.supplementarySource = { $0 == "F6_TEST_KEY_B" ? "from-store" : nil }
        #expect(EnvCredentials.value(for: "F6_TEST_KEY_B") == "from-store")
    }

    /// 进程环境空串 → 同样回落补充源（GUI 启动常留空串占位）
    @Test func emptyEnvFallsBackToSupplementary() {
        let orig = EnvCredentials.supplementarySource
        defer { EnvCredentials.supplementarySource = orig; unsetenv("F6_TEST_KEY_C") }
        setenv("F6_TEST_KEY_C", "", 1)
        EnvCredentials.supplementarySource = { $0 == "F6_TEST_KEY_C" ? "from-store" : nil }
        #expect(EnvCredentials.value(for: "F6_TEST_KEY_C") == "from-store")
    }

    /// 补充源返回空串 → 视为未设置（不产生空 key 假阳性）
    @Test func emptySupplementaryIsNotSet() {
        let orig = EnvCredentials.supplementarySource
        defer { EnvCredentials.supplementarySource = orig; unsetenv("F6_TEST_KEY_D") }
        unsetenv("F6_TEST_KEY_D")
        EnvCredentials.supplementarySource = { _ in "" }
        #expect(EnvCredentials.value(for: "F6_TEST_KEY_D") == nil)
    }

    /// 补充源 nil = 纯旧行为（只读进程环境，未设置即 nil）
    @Test func nilSupplementaryKeepsLegacyBehavior() {
        let orig = EnvCredentials.supplementarySource
        defer { EnvCredentials.supplementarySource = orig; unsetenv("F6_TEST_KEY_E") }
        unsetenv("F6_TEST_KEY_E")
        EnvCredentials.supplementarySource = nil
        #expect(EnvCredentials.value(for: "F6_TEST_KEY_E") == nil)
    }
}
