import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// Actual visible TerminalStore paths that do not reach a process runner.
/// These tests do not instantiate SettingsCenter, touch a real data root,
/// or execute the commands used as input.
@Suite("D-TERMINAL-07 visible command echo", .serialized)
@MainActor
struct TerminalOutputConsumer307Tests {
    private var snapshot: TerminalContextSnapshot {
        TerminalContextSnapshot(
            sessionID: "terminal307-session", turnID: "terminal307-turn",
            taskID: "terminal307-task", projectID: "terminal307-project",
            workdir: "/synthetic-terminal307"
        )
    }

    private func store() -> TerminalStore {
        TerminalStore(contextSnapshot: snapshot)
    }

    @Test("hard denied command echo masks recognized values while denial remains visible")
    func deniedCommandEchoDoesNotExposeSecret() {
        let terminal = store()
        let secret = "Terminal307BearerSyntheticInteriorABCDEFG"
        let raw = "halt --label 'Authorization: Bearer \(secret)' ordinary-body"
        terminal.input = raw
        terminal.submit()

        #expect(!terminal.isRunning)
        #expect(terminal.pendingConfirmation == nil)
        #expect(terminal.input.isEmpty)
        #expect(terminal.output.contains("命令被拒绝"))
        #expect(terminal.output.contains("halt"))
        #expect(terminal.output.contains("ordinary-body"))
        #expect(terminal.output.contains(ContentSecretRedactor.mask(secret)))
        #expect(!terminal.output.contains(secret))
        #expect(!terminal.output.contains(raw))
    }

    @Test("unknown command waits without echo; confirmation and denied echo mask assignment secrets")
    func unknownCommandEchoDoesNotExposeSecret() {
        let terminal = store()
        let secret = "Terminal307AssignmentSyntheticInteriorABCDEFG"
        let raw = "terminal307-unknown 'api_key=\(secret)' ordinary-tail"
        terminal.input = raw
        terminal.submit()

        #expect(!terminal.isRunning)
        let pending = terminal.pendingConfirmation
        #expect(pending?.raw == raw)
        #expect(terminal.output.isEmpty)
        #expect(pending?.confirmationPreview.contains("terminal307-unknown") == true)
        #expect(pending?.confirmationPreview.contains("ordinary-tail") == true)
        #expect(pending?.confirmationPreview.contains(ContentSecretRedactor.mask(secret)) == true)
        #expect(pending?.confirmationPreview.contains(secret) == false)
        #expect(!terminal.output.contains(secret))
        terminal.cancelPending()
        #expect(terminal.pendingConfirmation == nil)
        #expect(!terminal.isRunning)
        #expect(terminal.output.isEmpty)

        // A hard-denied command really echoes, without dispatching a runner.
        let denied = store()
        denied.input = "halt --label 'api_key=\(secret)' ordinary-tail"
        denied.submit()
        #expect(!denied.isRunning)
        #expect(denied.pendingConfirmation == nil)
        #expect(denied.output.contains("命令被拒绝"))
        #expect(denied.output.contains("ordinary-tail"))
        #expect(denied.output.contains(ContentSecretRedactor.mask(secret)))
        #expect(!denied.output.contains(secret))
    }

    @Test("confirmation keeps exact raw input and cancellation neither echoes nor dispatches it")
    func pendingConfirmationRetainsRawCommandWithoutPublishingSecret() {
        let terminal = store()
        let secret = "Terminal307PendingSyntheticInteriorABCDEFG"
        let raw = "git --label 'Authorization: Bearer \(secret)'"
        terminal.input = raw
        terminal.submit()

        #expect(terminal.pendingConfirmation?.raw == raw)
        let request = TerminalContextPanelAdapter(snapshot: snapshot).makeRequest(
            command: raw, cwd: terminal.cwd, approved: true
        )
        #expect(request.command == raw)
        #expect(request.approval?.requestFingerprint == request.requestFingerprint)
        #expect(request.approval?.scopeID == snapshot.scopeID)
        #expect(!terminal.isRunning)
        #expect(terminal.output.isEmpty)
        terminal.cancelPending()
        #expect(terminal.pendingConfirmation == nil)
        #expect(terminal.output.isEmpty)
    }

    @Test("ordinary command echo remains exact")
    func ordinaryUnknownCommandEchoRemainsReadable() {
        let terminal = store()
        let raw = "cd 'ordinary quoted body' tail"
        terminal.input = raw
        terminal.submit()

        #expect(!terminal.isRunning)
        #expect(terminal.output.hasPrefix("/synthetic-terminal307 $ \(raw)\n"))
        #expect(terminal.output.contains("cd: 目录不存在"))
    }
}
