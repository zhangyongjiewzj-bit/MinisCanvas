import Foundation

// MARK: - T1 测试环境隔离：API key 污染修复
//
// 背景：MinisCanvasLLMInvoker / DashScopeProvider 按环境变量解析真实 API key
// （DashScope 链：HERMES_CUSTOM_QWEN38_API_KEY → BAILIAN_TOKEN_PLAN_API_KEY →
// DASHSCOPE_API_KEY；OpenAI：OPENAI_API_KEY）。开发机 shell 若存在真实 key，
// 画布 LLM 节点测试会发真实网络请求 → 失败/不确定（P2-1-fix 发现：env -u 后 4 个
// 测试才全过）。这是测试隔离缺陷：**测试必须不依赖外部环境**。
//
// 用法：
//   1. 受影响 @Suite 加 `.serialized`（套件内串行，避免 env 竞态），init() 调
//      `TestEnvIsolation.hermeticize()`（幂等，每个测试前执行）。
//   2. 需要精确作用域控制时用 `withUnsetAPIKeys`（defer 恢复）。
//
// 设计说明：hermeticize() 故意**不恢复**环境变量——测试进程内没有任何测试需要
// 真实 key（真实联调测试保持 .disabled 单独跑），且恢复会与并行套件竞态
// （A 套件恢复 key 时 B 套件正在执行 → B 又变不确定）。unset 后全包行为与
// `env -u` 后全绿一致：离线、确定。

enum TestEnvIsolation {
    enum IsolationError: Error, Equatable {
        case notRunningInTestProcess
        case invalidProfileLabel
    }

    struct IsolatedProfile: Equatable {
        let rootDirectory: URL
        let environment: [String: String]
    }

    /// Profile metadata is deliberately test-only. It is returned to callers
    /// rather than installed globally, so production defaults cannot observe it.
    static let profileMarkerKey = "MINISCANVAS_TEST_PROFILE"
    static let profileDirectoryKey = "MINISCANVAS_TEST_DIRECTORY"

    /// 会触发真实 LLM 网络请求的 API key 环境变量（DashScope 解析链 + OpenAI）。
    static let apiKeyEnvVars: [String] = [
        "HERMES_CUSTOM_QWEN38_API_KEY",
        "BAILIAN_TOKEN_PLAN_API_KEY",
        "DASHSCOPE_API_KEY",
        "OPENAI_API_KEY",
    ]

    /// Detect the process signals used by SwiftPM/XCTest without accepting the
    /// profile marker itself as proof that this is a test process.
    static func isRunningInTestProcess(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        let argumentLine = arguments.joined(separator: " ")
        return argumentLine.contains(".xctest")
            || argumentLine.contains("swiftpm-testing-helper")
            || argumentLine.contains("-XCTest")
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["SWIFT_TESTING_ENABLED"] != nil
    }

    /// Build a unique, disposable profile for tests. No path or environment
    /// mutation occurs until a caller explicitly consumes the returned values.
    static func makeIsolatedProfile(
        label: String = "MinisCanvasAppTests",
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        processArguments: [String] = ProcessInfo.processInfo.arguments
    ) throws -> IsolatedProfile {
        guard isRunningInTestProcess(
            environment: processEnvironment,
            arguments: processArguments
        ) else {
            throw IsolationError.notRunningInTestProcess
        }

        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty,
              trimmedLabel.range(
                  of: #"^[A-Za-z0-9._-]+$"#,
                  options: .regularExpression
              ) != nil else {
            throw IsolationError.invalidProfileLabel
        }

        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MinisCanvasAppTests-\(trimmedLabel)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )

        return IsolatedProfile(
            rootDirectory: rootDirectory,
            environment: [
                profileMarkerKey: "1",
                profileDirectoryKey: rootDirectory.path
            ]
        )
    }

    /// 幂等 unset：确保测试进程内这些 key 不存在（多次调用无副作用）。
    static func hermeticize() {
        for key in apiKeyEnvVars {
            unsetenv(key)
        }
    }

    /// 作用域内临时 unset + defer 恢复（需要精确控制窗口时用）。
    static func withUnsetAPIKeys<T>(_ body: () async throws -> T) async rethrows -> T {
        var saved: [(key: String, value: String?)] = []
        for key in apiKeyEnvVars {
            let value = getenv(key).map { String(cString: $0) }
            saved.append((key, value))
            unsetenv(key)
        }
        defer {
            for (key, value) in saved.reversed() {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        return try await body()
    }
}
