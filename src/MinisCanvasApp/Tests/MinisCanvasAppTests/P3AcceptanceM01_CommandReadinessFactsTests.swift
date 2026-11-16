import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Composer command readiness uses existing facts")
@MainActor
struct P3AcceptanceM01_CommandReadinessFactsTests {
    @Test("registered route and executor facts take precedence over provider state")
    func routeFactsPrecedeProvider() {
        let bridge = makeBridge()
        bridge.chat.effectiveSettingsSnapshotSource = { nil }

        #expect(bridge.composerCommandReadinessObservation(for: "help") == .noKnownBlocker)
        #expect(bridge.composerCommandReadinessObservation(for: "model") == .noKnownBlocker)
        // settings.open is an App palette command, not a Composer slash ID.
        #expect(bridge.composerCommandReadinessObservation(for: "settings.open")
                == .knownBlocked(reason: "命令未注册"))
        // N2: /stop now has a wired executor (the Stop button entry), so it is no
        // longer a missing-executor blocker. Canvas-only IDs keep that blocker.
        #expect(bridge.composerCommandReadinessObservation(for: "stop") == .noKnownBlocker)
        #expect(bridge.composerCommandReadinessObservation(for: "canvas.run").knownBlockerReason
                == "当前没有已接线的生产执行入口")
        #expect(bridge.composerCommandReadinessObservation(for: "not-a-command")
                == .knownBlocked(reason: "命令未注册"))
    }

    @Test("short history compact never reads settings or requires a provider")
    func shortHistoryDoesNotProbeDependencies() {
        let bridge = makeBridge()
        bridge.chat.messages = [ChatMessageUI(role: .user, content: "one")]
        var settingsReads = 0
        bridge.chat.effectiveSettingsSnapshotSource = {
            settingsReads += 1
            return nil
        }

        #expect(bridge.composerCommandReadinessObservation(for: "compact") == .noKnownBlocker)
        #expect(settingsReads == 0)
    }

    @Test("long history honors the settings transaction and existing Mock fallback")
    func longHistorySettingsAndMock() {
        let bridge = makeBridge()
        bridge.chat.messages = (0..<4).map {
            ChatMessageUI(role: .user, content: "message \($0)")
        }
        bridge.chat.effectiveSettingsSnapshotSource = { nil }

        #expect(bridge.composerCommandReadinessObservation(for: "compact").knownBlockerReason
                == "设置事务状态未知，当前不能压缩上下文")
        bridge.chat.effectiveSettingsSnapshotSource = nil
        #expect(bridge.chat.isMockMode)
        #expect(bridge.composerCommandReadinessObservation(for: "compact") == .noKnownBlocker)
    }

    @Test("non-Mock launch and selection observations never imply request health")
    func longHistoryProviderFactClassification() {
        let classify = BridgeStore.longHistoryCompactObservation
        let ready = ProviderLaunchStatus(providerID: "synthetic", state: .ready)
        let degraded = ProviderLaunchStatus(
            providerID: "synthetic", state: .degraded(.credentialUnavailable)
        )

        #expect(classify(nil, false, false, ready).knownBlockerReason
                == "当前模型未在目录中完成可用选择")
        #expect(classify(nil, false, true, degraded).knownBlockerReason
                == "当前 Provider 凭据不可用")
        #expect(classify(nil, false, true, nil) == .unknown)
        #expect(classify(nil, false, true, ready) == .noKnownBlocker)
        #expect(classify(nil, true, nil, nil) == .noKnownBlocker)
    }

    private func makeBridge() -> BridgeStore {
        let identity = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("command-readiness-\(identity)", isDirectory: true)
        let defaults = UserDefaults(suiteName: "m01.command-readiness.\(identity)")!
        return BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults),
            preferencesDefaults: defaults,
            logManager: LogManager(directory: directory.appendingPathComponent("logs"), ringCapacity: 20),
            sessionDocumentStore: SessionDocumentStore(directory: directory),
            memoryStore: MemoryStore(directory: directory),
            canvasFeatureLane: .phase3NonCanvas
        )
    }
}
