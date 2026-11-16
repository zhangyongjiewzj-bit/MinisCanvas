import AVFoundation
import Foundation
import Testing
@testable import MinisCore

/// Controlled lifecycle effects only. No system synthesizer, voice lookup,
/// device, permissions or audible playback is created by this backend.
@MainActor
private final class IdleLifecycleBackend3243: SpeechSynthesisPlaybackBackend {
    var speaking = false
    private(set) var stateReads = 0
    var isSpeaking: Bool { stateReads += 1; return speaking }
    var onFinish: ((AVSpeechUtterance) -> Void)?
    var onCancel: ((AVSpeechUtterance) -> Void)?
    private(set) var stops = 0
    private(set) var prepared: [AVSpeechUtterance] = []
    private(set) var started: [AVSpeechUtterance] = []
    func stop() { stops += 1; speaking = false }
    func prepareUtterance(text: String, voice: String?, defaultLanguageCode: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        prepared.append(utterance)
        return utterance
    }
    func speak(_ utterance: AVSpeechUtterance) { started.append(utterance) }
}

@Suite("3243 speech idle backend lifecycle; controlled non-device evidence")
@MainActor
struct SpeechIdleBackendLifecycle3243Tests {
    @Test func idleAndRejectedActionsDoNotCreateBackend() async throws {
        let backend = IdleLifecycleBackend3243()
        var creations = 0
        let synthesizer = SpeechSynthesizer(backendFactory: { creations += 1; return backend })
        let tool = SpeechTool(synthesizer: synthesizer)
        #expect(creations == 0)
        #expect(synthesizer.isSpeaking == false)
        #expect(synthesizer.speak(text: " \n ") == false)
        synthesizer.stop()
        let idle = try await tool.execute(name: "speech", input: ["action": "stop"])
        #expect(idle == "当前没有正在进行的朗读。")
        await #expect(throws: ToolExecutorError.missingParameter("text")) {
            try await tool.execute(name: "speech", input: ["action": "speak"])
        }
        await #expect(throws: ToolExecutorError.invalidParameter("action=sing")) {
            try await tool.execute(name: "speech", input: ["action": "sing"])
        }
        await #expect(throws: ToolExecutorError.unknownTool("wrong")) {
            try await tool.execute(name: "wrong", input: ["action": "stop"])
        }
        #expect(creations == 0)
        #expect(backend.stateReads == 0)
        #expect(backend.prepared.isEmpty)
        #expect(backend.started.isEmpty)
        #expect(backend.stops == 0)
        print("TASK3243_IDLE creations=\(creations) stateReads=\(backend.stateReads) stops=\(backend.stops)")
    }

    @Test func pendingStopRestartAndLateCallbacksKeepCurrentGeneration() async throws {
        let backend = IdleLifecycleBackend3243()
        var creations = 0
        let synthesizer = SpeechSynthesizer(backendFactory: { creations += 1; return backend })
        let tool = SpeechTool(synthesizer: synthesizer)
        let first = try await tool.execute(name: "speech", input: ["action": "speak", "text": "first"])
        #expect(first.contains("已开始朗读"))
        #expect(creations == 1)
        #expect(backend.speaking == false)
        #expect(synthesizer.isSpeaking)
        let old = try #require(backend.started.last)
        let oldGeneration = try #require(synthesizer.activeGeneration)
        _ = try await tool.execute(name: "speech", input: ["action": "stop"])
        #expect(backend.stops == 1)
        #expect(synthesizer.activeGeneration == nil)
        _ = try await tool.execute(name: "speech", input: ["action": "speak", "text": "next"])
        let current = try #require(backend.started.last)
        let currentGeneration = try #require(synthesizer.activeGeneration)
        #expect(currentGeneration != oldGeneration)
        backend.onFinish?(old)
        backend.onCancel?(old)
        #expect(synthesizer.activeGeneration == currentGeneration)
        #expect(synthesizer.isSpeaking)
        backend.onCancel?(current)
        #expect(synthesizer.activeGeneration == nil)
        #expect(synthesizer.isSpeaking == false)
        #expect(creations == 1)
        #expect(backend.prepared.count == 2)
        #expect(backend.started.count == 2)
        print("TASK3243_GENERATIONS creations=\(creations) starts=\(backend.started.count) stops=\(backend.stops)")
    }

    @Test func injectedAlreadySpeakingBackendStillStopsWithoutActiveToken() {
        let backend = IdleLifecycleBackend3243()
        backend.speaking = true
        let synthesizer = SpeechSynthesizer(backend: backend)
        #expect(synthesizer.activeGeneration == nil)
        synthesizer.stop()
        #expect(backend.stateReads == 1)
        #expect(backend.stops == 1)
        #expect(backend.speaking == false)
        synthesizer.stop()
        #expect(backend.stateReads == 2)
        #expect(backend.stops == 1)
    }

    @Test func finishAndRestartReuseCreatedBackendAndStopRealBackendState() throws {
        let backend = IdleLifecycleBackend3243()
        var creations = 0
        let synthesizer = SpeechSynthesizer(backendFactory: { creations += 1; return backend })
        #expect(synthesizer.speak(text: "first"))
        let first = try #require(backend.started.last)
        backend.onFinish?(first)
        #expect(synthesizer.isSpeaking == false)
        // Preserve the previous adapter state fallback even after a delegate
        // cleared the generation token: an existing backend can still be busy.
        backend.speaking = true
        synthesizer.stop()
        #expect(backend.stops == 1)
        #expect(backend.speaking == false)
        #expect(synthesizer.speak(text: "next"))
        #expect(creations == 1)
        #expect(backend.started.count == 2)
        synthesizer.stop()
        #expect(backend.stops == 2)
        #expect(synthesizer.isSpeaking == false)
    }
}
