import Testing
import Foundation
import CanvasCore
import MinisCore
@testable import MinisCanvasApp

private struct CanvasExecutionAssetProbe: VideoAssetDownloader {
    let data: Data

    func download(remoteURL: String, recordID: String, into directory: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(recordID).mp4")
        try data.write(to: destination, options: .atomic)
        return destination
    }
}

private struct CanvasExecutionCloudVideoProbe: CloudVideoGenerator {
    let providerID = "test-video"
    let displayName = "Test Video"
    let isConfigured = true

    func submitVideo(_ request: CloudVideoRequest) async throws -> String {
        "remote-production-path"
    }

    func pollVideo(taskID: String) async throws -> CloudTaskState {
        CloudTaskState(phase: .succeeded, videoURL: "https://cdn.test/production-path.mp4")
    }
}

private actor CanvasExecutionConcurrentCloudVideoProbe: CloudVideoGenerator {
    let providerID = "test-video-concurrent"
    let displayName = "Concurrent Test Video"
    let isConfigured = true
    private(set) var submitCount = 0

    func submitVideo(_ request: CloudVideoRequest) async throws -> String {
        submitCount += 1
        return "remote-concurrent"
    }

    func pollVideo(taskID: String) async throws -> CloudTaskState {
        CloudTaskState(phase: .succeeded, videoURL: "https://cdn.test/concurrent.mp4")
    }
}

// MARK: - CanvasExecution 纯函数 + Provider 路由（swift-testing 补写）
//
// 缺口清单（P2_3FlowHazardTests 已盖端到端写回/BLOCKED；VideoGenRequestParamsTests
// 已盖 Kling/Jimeng 的 extraParams/duration/modelOverride 透传）：
//   ① MinisCanvasVideoInvoker 纯函数：promptFingerprint（FNV-1a 确定性）、
//     normalizedDuration、resolvedAspectRatio、makeVideoRequest 的 aspectRatio 分支
//   ② resolveVideoProvider 路由表（kling/jimeng/空→.unconfigured/未知→.unsupported）
//   ③ CanvasVideoRoutingError 中文消息

@Suite("CanvasExecution 纯函数与 Provider 路由", .serialized)
struct CanvasExecutionTests {

    init() {
        // 构造 KlingProvider/JimengProvider 会解析 API key 环境变量
        // （KLING_API_KEY / JIMENG_* / VOLC_* / SEEDANCE_API_KEY 等）——
        // 测试进程必须无真实 key，否则 isConfigured 断言不确定。
        TestEnvIsolation.hermeticize()
        for key in ["KLING_API_KEY", "KING_API_KEY", "JIMENG_API_KEY", "SEEDANCE_API_KEY",
                    "JIMENG_ACCESS_KEY", "JIMENG_SECRET_KEY",
                    "VOLC_ACCESSKEY", "VOLC_ACCESS_KEY", "VOLC_SECRETKEY", "VOLC_SECRET_KEY"] {
            unsetenv(key)
        }
    }

    // MARK: ① promptFingerprint（FNV-1a 确定性）

    @Test func promptFingerprintIsDeterministicAndTrimsWhitespace() {
        let a = MinisCanvasVideoInvoker.promptFingerprint("hello")
        let b = MinisCanvasVideoInvoker.promptFingerprint("hello")
        #expect(a == b, "同提示词同指纹（防重键确定性）")
        #expect(a == MinisCanvasVideoInvoker.promptFingerprint("  hello  "), "指纹应忽略首尾空白")
        #expect(a == MinisCanvasVideoInvoker.promptFingerprint("hello\n"), "换行同样剥离")
        #expect(a.count == 16, "固定 16 位十六进制")
        #expect(a.allSatisfy { $0.isHexDigit })
    }

    @Test func promptFingerprintMatchesLockedVectors() {
        // 锁定完整 FNV-1a 64 位向量，确保跨进程幂等键不会缩短为低 32 位。
        #expect(MinisCanvasVideoInvoker.promptFingerprint("") == "cbf29ce484222325")
        #expect(MinisCanvasVideoInvoker.promptFingerprint("hello") == "a430d84680aabd0b")
        #expect(MinisCanvasVideoInvoker.promptFingerprint("abc") == "e71fa2190541574b")
        #expect(MinisCanvasVideoInvoker.promptFingerprint("一段打斗") == "ba47e8ee1cccc5a5")
        // 不同提示词 → 不同指纹（同节点防重键区分语义）
        #expect(MinisCanvasVideoInvoker.promptFingerprint("hello")
                != MinisCanvasVideoInvoker.promptFingerprint("hello world"))
    }

    @Test
    func promptFingerprintShouldEmitFull64BitOffsetBasis() {
        // 空串指纹必须保留完整 FNV-1a 64 位 offset basis，避免幂等键碰撞。
        #expect(MinisCanvasVideoInvoker.promptFingerprint("") == "cbf29ce484222325")
    }

    // MARK: ① normalizedDuration

    @Test func normalizedDurationStripsUnitAndWhitespace() {
        #expect(MinisCanvasVideoInvoker.normalizedDuration("5s") == "5")
        #expect(MinisCanvasVideoInvoker.normalizedDuration("10S") == "10", "大写 S 后缀同样剥离")
        #expect(MinisCanvasVideoInvoker.normalizedDuration(" 10 ") == "10", "首尾空白剥离")
        #expect(MinisCanvasVideoInvoker.normalizedDuration("5.5") == "5.5", "非整秒保留小数")
    }

    @Test func normalizedDurationRejectsInvalidInput() {
        #expect(MinisCanvasVideoInvoker.normalizedDuration(nil) == nil)
        #expect(MinisCanvasVideoInvoker.normalizedDuration("") == nil)
        #expect(MinisCanvasVideoInvoker.normalizedDuration("   ") == nil)
        #expect(MinisCanvasVideoInvoker.normalizedDuration("abc") == nil)
        #expect(MinisCanvasVideoInvoker.normalizedDuration("0") == nil, "0 秒无意义 → 回落 Provider 默认")
        #expect(MinisCanvasVideoInvoker.normalizedDuration("-3") == nil)
    }

    // MARK: ① resolvedAspectRatio

    @Test func resolvedAspectRatioAcceptsBothKeyNames() {
        let standard = NodeBackendConfig(
            providerType: .cloud, providerID: "kling", modelID: "kling-v2",
            params: ["aspectRatio": "16:9"]
        )
        #expect(MinisCanvasVideoInvoker.resolvedAspectRatio(standard) == "16:9")
        let alias = NodeBackendConfig(
            providerType: .cloud, providerID: "kling", modelID: "kling-v2",
            params: ["aspect_ratio": "9:16"]
        )
        #expect(MinisCanvasVideoInvoker.resolvedAspectRatio(alias) == "9:16", "兼容 aspect_ratio 键名")
        let both = NodeBackendConfig(
            providerType: .cloud, providerID: "kling", modelID: "kling-v2",
            params: ["aspectRatio": "1:1", "aspect_ratio": "16:9"]
        )
        #expect(MinisCanvasVideoInvoker.resolvedAspectRatio(both) == "1:1", "aspectRatio 键优先")
    }

    @Test func resolvedAspectRatioReturnsNilForMissingOrBlank() {
        #expect(MinisCanvasVideoInvoker.resolvedAspectRatio(nil) == nil)
        let blank = NodeBackendConfig(
            providerType: .cloud, providerID: "kling", modelID: "kling-v2",
            params: ["aspectRatio": "   "]
        )
        #expect(MinisCanvasVideoInvoker.resolvedAspectRatio(blank) == nil, "纯空白视为未配置")
    }

    // MARK: ① makeVideoRequest（缺口：aspectRatio 真正进入请求）

    @Test func makeVideoRequestCarriesAspectRatioForKling() {
        let backend = NodeBackendConfig(
            providerType: .cloud, providerID: "kling", modelID: "kling-v2",
            params: ["aspectRatio": "16:9", "duration": "5s"]
        )
        let request = MinisCanvasVideoInvoker.makeVideoRequest(
            prompt: "p", firstFrame: nil, backend: backend, providerID: "kling"
        )
        #expect(request.aspectRatio == "16:9", "宽高比应进入 CloudVideoRequest.aspectRatio")
        #expect(request.duration == "5")
    }

    @Test func makeVideoRequestKeepsAspectRatioForJimengWithoutExtraParams() {
        let backend = NodeBackendConfig(
            providerType: .cloud, providerID: "jimeng", modelID: "seedance-v2",
            params: ["aspect_ratio": "9:16", "resolution": "1080p", "mode": "t2v"]
        )
        let request = MinisCanvasVideoInvoker.makeVideoRequest(
            prompt: "p", firstFrame: nil, backend: backend, providerID: "jimeng"
        )
        #expect(request.aspectRatio == "9:16", "Jimeng 画幅由 aspect_ratio 决定，必须进入请求")
        #expect(request.extraParams.isEmpty, "Jimeng 无 resolution/mode 字段，不透传避免未知字段")
    }

    // MARK: ② resolveVideoProvider 路由表

    @Test func resolveVideoProviderRoutesKnownBackends() throws {
        let kling = try MinisCanvasVideoInvoker.resolveVideoProvider("kling")
        #expect(kling.providerID == "kling")
        #expect(kling.isConfigured == false, "测试进程无 API key → 未配置（降级任务单路径）")
        let jimeng = try MinisCanvasVideoInvoker.resolveVideoProvider("jimeng")
        #expect(jimeng.providerID == "jimeng")
        let alias = try MinisCanvasVideoInvoker.resolveVideoProvider("jimengProvider")
        #expect(alias.providerID == "jimeng", "兼容 jimengProvider 别名")
    }

    @Test func resolveVideoProviderRejectsEmptyAndUnknown() {
        #expect(throws: CanvasVideoRoutingError.unconfigured) {
            _ = try MinisCanvasVideoInvoker.resolveVideoProvider("")
        }
        do {
            _ = try MinisCanvasVideoInvoker.resolveVideoProvider("wan-local")
            Issue.record("未知后端应抛 unsupported")
        } catch let error as CanvasVideoRoutingError {
            guard case .unsupported(let id) = error else {
                Issue.record("应抛 unsupported，实际 \(error)")
                return
            }
            #expect(id == "wan-local")
        } catch {
            Issue.record("错误类型不符: \(error)")
        }
    }

    // MARK: ③ CanvasVideoRoutingError 中文消息

    @Test func routingErrorMessagesAreUserFacingChinese() {
        #expect(CanvasVideoRoutingError.unconfigured.errorDescription?.contains("未配置视频后端") == true)
        let unsupported = CanvasVideoRoutingError.unsupported("wan-local")
        #expect(unsupported.errorDescription?.contains("wan-local") == true, "消息应带出未知后端 id")
        #expect(unsupported.errorDescription?.contains("可灵 kling / 即梦 jimeng") == true)
        #expect(unsupported.errorDescription?.contains("重新选择") == true)
    }

    @Test func configuredInvokerUsesRecoveryExecutorAndPersistsAsset() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("canvas-video-production-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let taskStore = VideoTaskStore(directory: directory)
        let invoker = MinisCanvasVideoInvoker(
            taskStore: taskStore,
            assetDirectory: directory.appendingPathComponent("assets", isDirectory: true),
            assetDownloader: CanvasExecutionAssetProbe(data: Data("video".utf8)),
            providerFactory: { _ in CanvasExecutionCloudVideoProbe() }
        )
        var backend = NodeBackendConfig()
        backend.providerID = "kling"
        let node = CanvasNode(type: ManjuNodeType.videoGen.rawValue, title: "视频生成")

        let outcome = try await invoker.generate(
            node: node,
            prompt: "生产执行器接线",
            firstFrame: nil,
            backend: backend
        )

        guard case .video(let path) = outcome else {
            Issue.record("已配置 Provider 应返回本地视频资产，而不是任务单：\(outcome)")
            return
        }
        let record = try #require(taskStore.allRecords().first)
        #expect(record.status == .succeeded)
        #expect(record.assetPath == path)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(record.videoURL == "https://cdn.test/production-path.mp4")
    }

    @Test func concurrentConfiguredInvocationsSubmitOnlyOnce() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("canvas-video-concurrent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let taskStore = VideoTaskStore(directory: directory)
        let provider = CanvasExecutionConcurrentCloudVideoProbe()
        let invoker = MinisCanvasVideoInvoker(
            taskStore: taskStore,
            assetDirectory: directory.appendingPathComponent("assets", isDirectory: true),
            assetDownloader: CanvasExecutionAssetProbe(data: Data("video".utf8)),
            providerFactory: { _ in provider }
        )
        var backend = NodeBackendConfig()
        backend.providerID = "kling"
        let node = CanvasNode(type: ManjuNodeType.videoGen.rawValue, title: "并发视频生成")

        async let first = invoker.generate(
            node: node, prompt: "并发幂等", firstFrame: nil, backend: backend
        )
        async let second = invoker.generate(
            node: node, prompt: "并发幂等", firstFrame: nil, backend: backend
        )
        _ = try await (first, second)

        #expect(await provider.submitCount == 1)
        #expect(taskStore.allRecords().count == 1)
        #expect(taskStore.allRecords().first?.status == .succeeded)
    }
}
