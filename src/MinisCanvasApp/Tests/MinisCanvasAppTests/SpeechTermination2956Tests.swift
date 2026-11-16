import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Bound Quit cancels composer speech 2956")
@MainActor
struct SpeechTermination2956Tests {
    @Test("recording and late permission/stop callbacks are revoked before exit flush",
          arguments: ["recording", "permission", "finishing"])
    func boundQuitRevokesSpeech(state: String) async throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let identity = UUID().uuidString
        let directory = formal.rootDirectory.appendingPathComponent("speech-quit-2956-\(identity)")
        let suite = "speech-quit-2956.\(identity)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let driver = ControlledQuitSpeechDriver2956()
        let bridge = BridgeStore(
            preferencesDefaults: defaults,
            logManager: LogManager(directory: directory.appendingPathComponent("logs"), ringCapacity: 20),
            sessionDocumentStore: SessionDocumentStore(directory: directory),
            canvasRuntimeState: .disabled,
            memoryStore: MemoryStore(directory: directory),
            canvasFeatureLane: .phase3NonCanvas,
            composerSpeechDriver: driver
        )
        defer {
            bridge.cancelComposerSpeechInput()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let session = try #require(bridge.chat.activeSessionID)
        let drafts = DraftStore(directory: directory.appendingPathComponent("drafts"))
        bridge.chat.attachDraftStore(drafts)
        bridge.chat.draftText = "退出前草稿"
        let messageCount = bridge.chat.messages.count
        let lifecycle = AppLifecycleGuard.beginAtLaunch(defaults: defaults)
        let delegate = MinisCanvasAppDelegate()
        lifecycle.bind(appDelegate: delegate, bridge: bridge)
        var pending: Task<Bool, Never>?

        if state == "permission" {
            driver.speechPermission = .requestable
            driver.microphonePermission = .requestable
            driver.deferPermission = true
            pending = Task { await bridge.startComposerSpeechInput() }
            #expect(await eventually { driver.permissionContinuation != nil })
            #expect(bridge.composerSpeechPhase == .requestingPermission)
        } else {
            #expect(await bridge.startComposerSpeechInput())
            if state == "finishing" {
                driver.deferStop = true
                pending = Task { await bridge.stopComposerSpeechInput() }
                #expect(await eventually { driver.stopContinuation != nil })
                #expect(bridge.composerSpeechPhase == .finishing)
            } else {
                #expect(bridge.composerSpeechPhase == .recording)
            }
        }

        delegate.applicationWillTerminate(Notification(name: Notification.Name("synthetic-will-terminate")))
        #expect(driver.cancels == 1, "the bound production exit must cancel its active driver")
        #expect(bridge.composerSpeechPhase == .idle)
        #expect(bridge.composerSpeechClickGeneration == nil)
        #expect(defaults.bool(forKey: AppLifecycleGuard.cleanExitDefaultsKey))
        let persistedBeforeCallback = drafts.load(key: DraftStore.chatDraftKey(sessionID: session))
        #expect(persistedBeforeCallback != nil)

        // Resume the controlled API only after the real lifecycle callback.
        // The baseline also settles here, so a missing cancel reports failures
        // instead of leaving a checked continuation or test task stranded.
        driver.finishPermission()
        driver.finishStop(with: "退出后迟到转录")
        if let pending { #expect(await pending.value == false) }
        #expect(driver.starts == (state == "permission" ? 0 : 1))
        #expect(bridge.chat.activeSessionID == session)
        #expect(bridge.chat.draftText == "退出前草稿")
        #expect(bridge.chat.messages.count == messageCount)
        #expect(drafts.load(key: DraftStore.chatDraftKey(sessionID: session)) == persistedBeforeCallback)
        delegate.applicationWillTerminate(Notification(name: Notification.Name("synthetic-will-terminate")))
        #expect(driver.cancels == 1, "repeated shutdown must not cancel twice")
        #expect(bridge.composerSpeechPhase == .idle)
    }

    private func eventually(_ predicate: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }
}

@MainActor
private final class ControlledQuitSpeechDriver2956: ComposerSpeechInputDriver {
    var configured = true
    var recognizerAvailable = true
    var hasAudioInput = true
    var speechPermission: ComposerSpeechPermission = .granted
    var microphonePermission: ComposerSpeechPermission = .granted
    var deferPermission = false
    var deferStop = false
    private(set) var starts = 0
    private(set) var cancels = 0
    private(set) var permissionContinuation: CheckedContinuation<Bool, Never>?
    private(set) var stopContinuation: CheckedContinuation<String, Never>?

    func requestAuthorization() async -> Bool {
        if deferPermission {
            return await withCheckedContinuation { permissionContinuation = $0 }
        }
        return true
    }
    func start() throws { starts += 1 }
    func stop() async -> String {
        if deferStop { return await withCheckedContinuation { stopContinuation = $0 } }
        return ""
    }
    func cancel() { cancels += 1 }
    func finishPermission() {
        speechPermission = .granted
        microphonePermission = .granted
        let pending = permissionContinuation
        permissionContinuation = nil
        pending?.resume(returning: true)
    }
    func finishStop(with transcript: String) {
        let pending = stopContinuation
        stopContinuation = nil
        pending?.resume(returning: transcript)
    }
}
