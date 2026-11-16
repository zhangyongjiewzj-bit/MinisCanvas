import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Composer speech control without devices")
@MainActor
struct ComposerSpeechControlTests {
    @Test("unsupported and denied paths explain why recording cannot start")
    func unsupportedAndDeniedCannotStart() async {
        let driver = SyntheticComposerSpeechDriver()
        driver.configured = false
        let bridge = makeBridge(driver)

        #expect(bridge.composerSpeechAvailability == .unsupported(.speechLocaleUnresolved))
        #expect(await bridge.startComposerSpeechInput() == false)
        #expect(driver.permissionRequests == 0)
        #expect(driver.starts == 0)

        driver.configured = true
        driver.speechPermission = .denied
        #expect(bridge.composerSpeechAvailability == .unsupported(.speechRecognitionNotAuthorized))
        #expect(await bridge.startComposerSpeechInput() == false)
        #expect(driver.permissionRequests == 0)
        #expect(driver.starts == 0)

        driver.speechPermission = .requestable
        driver.microphonePermission = .denied
        #expect(bridge.composerSpeechAvailability == .unsupported(.microphoneNotAuthorized))
        #expect(await bridge.startComposerSpeechInput() == false)
        #expect(driver.permissionRequests == 0)

        driver.microphonePermission = .requestable
        driver.hasAudioInput = false
        #expect(bridge.composerSpeechAvailability == .unsupported(.noAudioInputDevice))
        #expect(await bridge.startComposerSpeechInput() == false)
        #expect(driver.permissionRequests == 0)
        #expect(driver.starts == 0)
    }

    @Test("unknown authorization is blocked without claiming a denial or requesting permission")
    func unknownPermissionCannotStart() async {
        let driver = SyntheticComposerSpeechDriver()
        driver.speechPermission = .unknown
        let bridge = makeBridge(driver)
        let messagesBefore = bridge.chat.messages.count

        #expect(bridge.composerSpeechAvailability == .permissionStatusUnknown)
        #expect(bridge.composerSpeechAvailability.canStartFromClick == false)
        #expect(ComposerSpeechPresentation.feedback(
            phase: .idle,
            availability: bridge.composerSpeechAvailability
        ) == ComposerSpeechAvailability.permissionStatusUnknown.explanation)
        #expect(await bridge.startComposerSpeechInput() == false)
        #expect(driver.permissionRequests == 0)
        #expect(driver.starts == 0)
        #expect(bridge.chat.messages.count == messagesBefore)

        driver.speechPermission = .denied
        driver.microphonePermission = .unknown
        #expect(bridge.composerSpeechAvailability == .unsupported(.speechRecognitionNotAuthorized))
        #expect(await bridge.startComposerSpeechInput() == false)
        #expect(driver.permissionRequests == 0)
        #expect(driver.starts == 0)

        driver.speechPermission = .granted
        #expect(bridge.composerSpeechAvailability == .permissionStatusUnknown)
        #expect(await bridge.startComposerSpeechInput() == false)
        #expect(driver.permissionRequests == 0)
        #expect(driver.starts == 0)
    }

    @Test("one explicit permission action adds text to original draft without sending")
    func permissionAndStopOnlyEditDraft() async {
        let driver = SyntheticComposerSpeechDriver()
        driver.speechPermission = .requestable
        driver.microphonePermission = .requestable
        driver.transcript = "语音文字"
        let bridge = makeBridge(driver)
        let session = bridge.chat.activeSessionID
        bridge.chat.draftText = "原草稿"
        let messagesBefore = bridge.chat.messages.count

        #expect(driver.permissionRequests == 0)
        #expect(bridge.composerSpeechAvailability == .permissionRequired)
        #expect(await bridge.startComposerSpeechInput())
        #expect(bridge.composerSpeechPhase == .recording)
        #expect(driver.permissionRequests == 1)
        #expect(driver.starts == 1)
        #expect(await bridge.startComposerSpeechInput() == false)

        #expect(await bridge.stopComposerSpeechInput())
        #expect(bridge.chat.activeSessionID == session)
        #expect(bridge.chat.draftText == "原草稿 语音文字")
        #expect(bridge.chat.messages.count == messagesBefore)
        #expect(bridge.composerSpeechPhase == .idle)
        #expect(await bridge.stopComposerSpeechInput() == false)
    }

    @Test("microphone denial after an explicit permission click does not start or send")
    func deniedPermissionCompletionDoesNotStart() async {
        let driver = SyntheticComposerSpeechDriver()
        driver.speechPermission = .requestable
        driver.microphonePermission = .requestable
        driver.deferPermission = true
        let bridge = makeBridge(driver)
        bridge.chat.draftText = "保留草稿"
        let messagesBefore = bridge.chat.messages.count

        let start = Task { await bridge.startComposerSpeechInput() }
        #expect(await eventually { driver.hasPendingPermission })
        #expect(bridge.composerSpeechPhase == .requestingPermission)
        driver.speechPermission = .granted
        driver.microphonePermission = .denied
        driver.finishPermission(granted: false)

        #expect(await start.value == false)
        #expect(bridge.composerSpeechPhase == .failed(
            ComposerSpeechAvailability.unsupported(.microphoneNotAuthorized).explanation
        ))
        #expect(driver.permissionRequests == 1)
        #expect(driver.starts == 0)
        #expect(bridge.chat.draftText == "保留草稿")
        #expect(bridge.chat.messages.count == messagesBefore)
    }

    @Test("late stop result after session switch cannot enter either draft")
    func switchedSessionRejectsLateResult() async {
        let driver = SyntheticComposerSpeechDriver()
        driver.deferStop = true
        let bridge = makeBridge(driver)
        let original = bridge.chat.activeSessionID
        bridge.chat.draftText = "原会话"
        #expect(await bridge.startComposerSpeechInput())

        let stopping = Task { await bridge.stopComposerSpeechInput() }
        #expect(await eventually { driver.hasPendingStop })
        bridge.chat.newSession()
        #expect(bridge.chat.activeSessionID != original)
        #expect(bridge.composerSpeechPhase == .idle)
        driver.finishStop(with: "迟到结果")
        #expect(await stopping.value == false)
        #expect(bridge.chat.draftText.isEmpty)
        if let original {
            bridge.chat.switchSession(id: original)
            #expect(bridge.chat.draftText == "原会话")
        }
    }

    @Test("project rebinding and cancellation reject a delayed result")
    func projectRebindingAndCancelRejectLateResult() async {
        let driver = SyntheticComposerSpeechDriver()
        driver.deferStop = true
        let bridge = makeBridge(driver)
        let sessionID = bridge.chat.activeSessionID!
        bridge.chat.draftText = "保留"
        #expect(await bridge.startComposerSpeechInput())

        let stopping = Task { await bridge.stopComposerSpeechInput() }
        #expect(await eventually { driver.hasPendingStop })
        bridge.chat.setProject(
            ChatStore.SessionProject(id: "new-project", name: "新项目", workingDirectory: "/synthetic"),
            forSession: sessionID
        )
        // The two composer controls call this same owner check when the
        // observable session list changes; the delayed result also rechecks.
        bridge.cancelComposerSpeechInputIfContextChanged()
        driver.finishStop(with: "不应写回")
        #expect(await stopping.value == false)
        #expect(bridge.chat.draftText == "保留")
        #expect(bridge.composerSpeechPhase == .idle)
    }

    @Test("a canceled stop callback cannot write text or cancel the next recording")
    func staleStopCannotMutateNextGeneration() async {
        let driver = SyntheticComposerSpeechDriver()
        driver.deferStop = true
        let bridge = makeBridge(driver)
        bridge.chat.draftText = "原草稿"
        let messagesBefore = bridge.chat.messages.count
        #expect(await bridge.startComposerSpeechInput())
        let firstGeneration = bridge.composerSpeechClickGeneration

        let oldStop = Task { await bridge.stopComposerSpeechInput() }
        #expect(await eventually { driver.hasPendingStop })
        bridge.cancelComposerSpeechInput()
        #expect(bridge.composerSpeechPhase == .idle)

        #expect(await bridge.startComposerSpeechInput())
        #expect(bridge.composerSpeechClickGeneration != firstGeneration)
        #expect(bridge.composerSpeechPhase == .recording)
        driver.finishStop(with: "旧录音的迟到文字")

        #expect(await oldStop.value == false)
        #expect(bridge.composerSpeechPhase == .recording)
        #expect(bridge.chat.draftText == "原草稿")
        #expect(bridge.chat.messages.count == messagesBefore)
        #expect(driver.starts == 2)
        bridge.cancelComposerSpeechInput()
    }

    @Test("a queued stop click cannot stop a replacement recording")
    func staleStopClickDoesNotStopNextGeneration() async {
        let driver = SyntheticComposerSpeechDriver()
        let bridge = makeBridge(driver)
        #expect(await bridge.startComposerSpeechInput())
        let oldClickGeneration = bridge.composerSpeechClickGeneration
        bridge.cancelComposerSpeechInput()
        #expect(await bridge.startComposerSpeechInput())
        #expect(bridge.composerSpeechClickGeneration != oldClickGeneration)

        #expect(await bridge.stopComposerSpeechInput(expectedGeneration: oldClickGeneration) == false)
        #expect(driver.stops == 0)
        #expect(bridge.composerSpeechPhase == .recording)
        bridge.cancelComposerSpeechInput()
    }

    @Test("old permission completion cannot cancel a newer recording")
    func stalePermissionCannotCancelNewGeneration() async {
        let driver = SyntheticComposerSpeechDriver()
        driver.speechPermission = .requestable
        driver.microphonePermission = .requestable
        driver.deferPermission = true
        let bridge = makeBridge(driver)

        let oldStart = Task { await bridge.startComposerSpeechInput() }
        #expect(await eventually { driver.hasPendingPermission })
        bridge.cancelComposerSpeechInput()
        driver.speechPermission = .granted
        driver.microphonePermission = .granted
        #expect(await bridge.startComposerSpeechInput())
        #expect(bridge.composerSpeechPhase == .recording)
        driver.finishPermission(granted: true)
        #expect(await oldStart.value == false)
        #expect(bridge.composerSpeechPhase == .recording)
        #expect(driver.starts == 1)
        bridge.cancelComposerSpeechInput()
        #expect(bridge.composerSpeechPhase == .idle)
    }

    @Test("cancel while permission is pending revokes the active driver before a late grant")
    func pendingPermissionCancellationRevokesDriverAndRejectsLateGrant() async {
        let driver = SyntheticComposerSpeechDriver()
        driver.speechPermission = .requestable
        driver.microphonePermission = .requestable
        driver.deferPermission = true
        let bridge = makeBridge(driver)

        let start = Task { await bridge.startComposerSpeechInput() }
        #expect(await eventually { driver.hasPendingPermission })
        #expect(bridge.composerSpeechPhase == .requestingPermission)

        bridge.cancelComposerSpeechInput()
        #expect(driver.cancels == 1)
        #expect(bridge.composerSpeechPhase == .idle)
        #expect(bridge.composerSpeechClickGeneration == nil)

        // The synthetic permission provider resolves the already pending
        // continuation after cancellation to model a system dialog returning
        // late. BridgeStore's generation/context fence must reject it.
        driver.finishPermission(granted: true)
        #expect(await start.value == false)
        #expect(driver.starts == 0)
        #expect(bridge.composerSpeechPhase == .idle)
    }

    @Test("returning to the same session does not revive an old permission request")
    func sessionAwayAndBackRejectsOldPermission() async {
        let driver = SyntheticComposerSpeechDriver()
        driver.speechPermission = .requestable
        driver.microphonePermission = .requestable
        driver.deferPermission = true
        let bridge = makeBridge(driver)
        let original = bridge.chat.activeSessionID!

        let oldStart = Task { await bridge.startComposerSpeechInput() }
        #expect(await eventually { driver.hasPendingPermission })
        bridge.chat.newSession()
        #expect(bridge.chat.activeSessionID != original)
        bridge.chat.switchSession(id: original)
        #expect(bridge.chat.activeSessionID == original)
        driver.finishPermission(granted: true)
        #expect(await oldStart.value == false)
        #expect(driver.starts == 0)
        #expect(bridge.chat.draftText.isEmpty)
    }

    @Test("a queued speech click cannot request permission after session ABA")
    func staleClickAfterSessionAwayAndBackCannotStart() async {
        let driver = SyntheticComposerSpeechDriver()
        driver.speechPermission = .requestable
        driver.microphonePermission = .requestable
        let bridge = makeBridge(driver)
        let originalSession = bridge.chat.activeSessionID!
        let queuedClickContext = bridge.composerSpeechClickContext
        #expect(queuedClickContext != nil)

        bridge.chat.newSession()
        #expect(bridge.chat.activeSessionID != originalSession)
        bridge.chat.switchSession(id: originalSession)
        #expect(bridge.chat.activeSessionID == originalSession)
        #expect(bridge.composerSpeechClickContext != queuedClickContext)

        // This models a Button action captured before the session actions,
        // whose MainActor Task begins only after both transitions.
        #expect(await bridge.startComposerSpeechInput(expectedContext: queuedClickContext) == false)
        #expect(driver.permissionRequests == 0)
        #expect(driver.starts == 0)
        #expect(bridge.composerSpeechPhase == .idle)
    }

    private func eventually(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<30 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    private func makeBridge(_ driver: SyntheticComposerSpeechDriver) -> BridgeStore {
        let identity = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("composer-speech-\(identity)", isDirectory: true)
        let defaults = UserDefaults(suiteName: "dev194.composer-speech.\(identity)")!
        return BridgeStore(
            preferencesDefaults: defaults,
            logManager: LogManager(directory: directory.appendingPathComponent("logs"), ringCapacity: 20),
            sessionDocumentStore: SessionDocumentStore(directory: directory),
            memoryStore: MemoryStore(directory: directory),
            composerSpeechDriver: driver
        )
    }
}

@MainActor
private final class SyntheticComposerSpeechDriver: ComposerSpeechInputDriver {
    var configured = true
    var recognizerAvailable = true
    var hasAudioInput = true
    var speechPermission: ComposerSpeechPermission = .granted
    var microphonePermission: ComposerSpeechPermission = .granted
    var transcript = ""
    var deferPermission = false
    var deferStop = false
    private(set) var permissionRequests = 0
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var cancels = 0
    private var permissionContinuation: CheckedContinuation<Bool, Never>?
    private var stopContinuation: CheckedContinuation<String, Never>?
    var hasPendingPermission: Bool { permissionContinuation != nil }
    var hasPendingStop: Bool { stopContinuation != nil }

    func requestAuthorization() async -> Bool {
        permissionRequests += 1
        if deferPermission {
            return await withCheckedContinuation { permissionContinuation = $0 }
        }
        speechPermission = .granted
        microphonePermission = .granted
        return true
    }

    func finishPermission(granted: Bool) {
        let pending = permissionContinuation
        permissionContinuation = nil
        pending?.resume(returning: granted)
    }

    func start() throws { starts += 1 }

    func stop() async -> String {
        stops += 1
        if deferStop {
            return await withCheckedContinuation { stopContinuation = $0 }
        }
        return transcript
    }

    func finishStop(with text: String) {
        let pending = stopContinuation
        stopContinuation = nil
        pending?.resume(returning: text)
    }

    func cancel() { cancels += 1 }
}
