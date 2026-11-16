import Testing
import Foundation
import CanvasCore
import MinisCore
@testable import MinisCanvasApp

// MARK: - 生视频参数面板 → config.params → CloudVideoRequest 透传（F10 数据链扩展）

/// 覆盖右侧栏参数面板写回的 params 键（mode/resolution/duration/audio/last_frame_url）
/// 在 makeVideoRequest 中真正进入 CloudVideoRequest：
///   · Kling：resolution/audio/mode/last_frame_url 经 extraParams（settings/contents）
///   · Jimeng：仅 duration/aspectRatio/modelOverride（API 无 resolution/audio/mode 字段，
///     不传避免未知字段 400）
@Suite("生视频参数请求透传", .serialized)
struct VideoGenRequestParamsTests {

    private func backend(
        _ params: [String: String], providerID: String = "kling", modelID: String = "kling-v2"
    ) -> NodeBackendConfig {
        NodeBackendConfig(providerType: .cloud, providerID: providerID, modelID: modelID, params: params)
    }

    @Test func klingCarriesAudioModeResolutionAndLastFrame() {
        let request = MinisCanvasVideoInvoker.makeVideoRequest(
            prompt: "一段打斗",
            firstFrame: "/tmp/first.png",
            backend: backend([
                "mode": "r2v", "resolution": "1080p", "duration": "10s",
                "audio": "on", "last_frame_url": "https://cdn.example.com/last.png"
            ]),
            providerID: "kling"
        )
        #expect(request.extraParams["resolution"] == "1080p")
        #expect(request.extraParams["audio"] == "on", "带声音开关应进入 Kling settings.audio")
        #expect(request.extraParams["mode"] == "r2v", "生成模式应透传 Kling（帧路由语义标记）")
        #expect(request.extraParams["last_frame_url"] == "https://cdn.example.com/last.png",
                "首尾帧尾帧 URL 应进入 Kling contents.last_frame")
        #expect(request.duration == "10", "duration 10s 应归一化为纯秒数")
        #expect(request.imageURL == "/tmp/first.png", "首帧原样透传（t2v 时由执行器置 nil）")
    }

    @Test func klingPassesExplicitOffAudioAndLastFrameAlias() {
        let request = MinisCanvasVideoInvoker.makeVideoRequest(
            prompt: "p", firstFrame: nil,
            backend: backend(["audio": "off", "lastFrame": "https://x/l.png"]),
            providerID: "kling"
        )
        #expect(request.extraParams["audio"] == "off", "显式 off 也透传（Kling 默认即 off）")
        #expect(request.extraParams["last_frame_url"] == "https://x/l.png",
                "兼容 params[lastFrame] 别名键")
    }

    @Test func jimengSkipsProviderUnsupportedFields() {
        let request = MinisCanvasVideoInvoker.makeVideoRequest(
            prompt: "p", firstFrame: nil,
            backend: backend([
                "mode": "t2v", "resolution": "1080p", "audio": "on", "duration": "15s"
            ], providerID: "jimeng", modelID: "seedance-v2"),
            providerID: "jimeng"
        )
        #expect(request.extraParams.isEmpty,
                "Jimeng API 无 resolution/audio/mode 字段，不应透传避免未知字段 400")
        #expect(request.duration == "15")
        #expect(request.modelOverride == "seedance-v2")
    }

    @Test func durationAndModelOverrideAreNormalized() {
        let request = MinisCanvasVideoInvoker.makeVideoRequest(
            prompt: "p", firstFrame: nil,
            backend: backend(["duration": "5s"], modelID: "seedance-v1"),
            providerID: "kling"
        )
        #expect(request.duration == "5")
        #expect(request.modelOverride == "seedance-v1")
    }

    @Test func emptyParamsProduceBareRequest() {
        let request = MinisCanvasVideoInvoker.makeVideoRequest(
            prompt: "p", firstFrame: nil, backend: nil, providerID: "kling"
        )
        #expect(request.extraParams.isEmpty)
        #expect(request.duration == nil)
        #expect(request.modelOverride == nil)
        #expect(request.imageURL == nil)
    }
}

// MARK: - 生视频节点默认参数（右侧栏面板初始值来源）

@Suite("videoGen 节点默认生视频参数", .serialized)
@MainActor
struct VideoGenNodeDefaultParamsTests {

    @Test func videoGenDefaultsIncludeModeResolutionDurationAudio() throws {
        let store = CanvasStore()
        let node = try #require(store.addNode(ofType: "videoGen"))
        let params = node.backendConfig?.params ?? [:]
        #expect(params["mode"] == "i2v", "默认生成模式应为图生视频")
        #expect(params["resolution"] == "720p")
        #expect(params["duration"] == "5s")
        #expect(params["audio"] == "off", "默认不带声音（与可灵 settings.audio 默认一致）")
        #expect(node.backendConfig?.providerID == "kling")
        #expect(node.backendConfig?.modelID == "kling-v2")
    }

    @Test func updateBackendConfigPersistsVideoParams() throws {
        let store = CanvasStore()
        let node = try #require(store.addNode(ofType: "videoGen"))
        var config = node.backendConfig ?? NodeBackendConfig()
        config.params["mode"] = "t2v"
        config.params["audio"] = "on"
        config.params["resolution"] = "1080p"
        config.params["duration"] = "10s"
        config.modelID = "seedance-v2"
        store.updateBackendConfig(config, for: node.id)
        let updated = store.graph.node(id: node.id)?.backendConfig
        #expect(updated?.params["mode"] == "t2v")
        #expect(updated?.params["audio"] == "on")
        #expect(updated?.params["resolution"] == "1080p")
        #expect(updated?.params["duration"] == "10s")
        #expect(updated?.modelID == "seedance-v2")
    }
}
