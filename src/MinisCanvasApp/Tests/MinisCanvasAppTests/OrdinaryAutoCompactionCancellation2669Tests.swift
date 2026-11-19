import Foundation
import CryptoKit
import Darwin
import CoreFoundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("ordinary compaction cancellation ownership", .serialized)
@MainActor
struct OrdinaryAutoCompactionCancellation2669Tests {
    @Test("production output-limit UI names only offered tools", arguments: ["file_write", "unadvertised_remote_tool"])
    func productionTruncationDisplaysOnlyTheOfferedToolName(toolName: String) async throws {
        let fixture = try Fixture(initialHistory: [.init(role: .user, content: "Keep this owned session.")])
        let chat = fixture.bridge.chat
        let file = fixture.profile.rootDirectory.appendingPathComponent("unchanged-target.txt")
        try "original file".write(to: file, atomically: true, encoding: .utf8)
        let arguments = String(decoding: try JSONSerialization.data(withJSONObject: [
            "path": file.path, "content": "B32_UI_ARGUMENT_BODY"
        ]), as: UTF8.self)
        let frame: [String: Any] = ["choices": [["index": 0, "delta": [
            "content": "Partial production reply", "tool_calls": [["index": 0, "id": "ui-truncated-call",
                "type": "function", "function": ["name": toolName, "arguments": String(arguments.dropLast())]]]
        ], "finish_reason": "length"]]]
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: frame), as: UTF8.self)
        TruncatedToolUIProtocol.reset(body: Data("data: \(payload)\n\ndata: [DONE]\n\n".utf8))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TruncatedToolUIProtocol.self]
        let session = URLSession(configuration: configuration)
        let provider = OpenAICompatibleProvider(apiKey: "synthetic-ui-fixture-key",
            model: LLMModel(id: Dialogue.modelID, displayName: "Owned wire fixture", provider: Dialogue.providerID),
            customBaseURL: nil, session: session, providerName: Dialogue.providerID)
        provider.runtimeConfigurationMaterial = "owned-runtime2669"
        defer {
            chat.stopAllStreamingForSafety()
            session.invalidateAndCancel()
            TruncatedToolUIProtocol.reset()
            withExtendedLifetime(fixture.settings) {}
        }
        await fixture.attach()
        try #require(chat.applySwitchSession(id: fixture.sessionID))
        let engine = try #require(chat.agentEngine as? AgentLoopChatEngine)
        let approvalCenter = fixture.bridge.approvalCenter
        let previousApprovalObserver = approvalCenter.onPendingRequestChanged
        var approvalCount = 0
        approvalCenter.onPendingRequestChanged = { requestID, sessionID in
            if requestID != nil { approvalCount += 1 }
            previousApprovalObserver?(requestID, sessionID)
        }
        defer { approvalCenter.onPendingRequestChanged = previousApprovalObserver }
        chat.streamingProviderOverride = provider
        chat.draftText = "Produce the owned diagnostic fixture."
        chat.submitComposer()
        let task = try #require(chat.turnTaskForTests(sessionID: fixture.sessionID))
        let endedOrRequestedApproval = await waitUntil {
            !chat.hasStreamingTasksForSafety || approvalCount != 0
        }
        try #require(endedOrRequestedApproval)
        try #require(approvalCount == 0)
        await task.value
        try #require(TruncatedToolUIProtocol.requests.count == 1)
        let request = try #require(TruncatedToolUIProtocol.requests.first)
        let bodyData: Data
        if let data = request.httpBody { bodyData = data }
        else {
            let stream = try #require(request.httpBodyStream)
            stream.open()
            defer { stream.close() }
            var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(bytes, count: count)
            }
            bodyData = data
        }
        let wire = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        try #require(wire["stream"] as? Bool == true)
        let tools = try #require(wire["tools"] as? [[String: Any]])
        let offeredNames = tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        let isOffered = toolName == "file_write"
        try #require(offeredNames.contains("file_write"))
        try #require(!offeredNames.contains("unadvertised_remote_tool"))
        try #require(offeredNames.contains(toolName) == isOffered)
        try #require(fixture.bridge.approvalCenter.pendingRequest == nil)
        #expect(engine.toolExecutionFactLedger.facts.isEmpty)
        let visible = try #require(chat.messages.last(where: { $0.role == .assistant }))
        let stored = try #require(SessionStore(directory: fixture.profile.sessionDirectory).loadSession(id: fixture.sessionID.uuidString))
        let persisted = try #require(stored.messages.last(where: { $0.role == .assistant }))
        let count = #"(?i)\b(?:1|one)\s+(?:(?:discarded|omitted|incomplete)\s+tool calls?|tool calls?\s+(?:discarded|omitted|not executed))\b|\b(?:discarded|omitted)\s+(?:1|one)\s+tool calls?\b|(?:丢弃|省略|未完成)(?:的)?\s*[：:]?\s*(?:1|一)\s*(?:个|次)?\s*工具调用|(?<![0-9])(?:1|一)\s*(?:个|次)?\s*(?:(?:未完成的|被丢弃的|被省略的)工具调用|工具调用\s*(?:被丢弃|被省略|未执行))"#
        for text in [visible.content, persisted.content] {
            #expect(text.contains("Partial production reply"))
            #expect(text.contains("截断") || text.lowercased().contains("truncat"))
            #expect(text.range(of: count, options: .regularExpression) != nil)
            #expect(text.contains("file_write") == isOffered)
            #expect(!text.contains("unadvertised_remote_tool"))
            #expect(!text.contains(file.path))
            #expect(!text.contains("B32_UI_ARGUMENT_BODY"))
        }
        #expect(!stored.messages.contains { $0.role == .tool || !$0.toolCalls.isEmpty })
        #expect(try Data(contentsOf: file) == Data("original file".utf8))
    }

    @Test("an owned shell completion enters only the next explicit prompt")
    func ownedBackgroundShellCompletionEntersNextExplicitPrompt() async throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let environment = ProcessInfo.processInfo.environment
        let runID = try #require(environment[FormalTestIsolationPaths.runIDKey])
        let scratch = formal.rootDirectory.deletingLastPathComponent()
        // The formal resolver already validates the standalone host against this scratch root.
        let nativeHost = scratch.appendingPathComponent("R13OriginalAppMain.app/Contents/MacOS/MinisCanvasOriginalAppMain")
        let isFormalNativeHost = ProcessInfo.processInfo.arguments.first == nativeHost.path
        let homeParent = isFormalNativeHost
            ? scratch
            : scratch.appendingPathComponent("runs", isDirectory: true)
                .appendingPathComponent(runID, isDirectory: true)
        let home = homeParent.appendingPathComponent("home", isDirectory: true)
        let support = try #require(FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first)
        print("B13_ISOLATION pid=\(ProcessInfo.processInfo.processIdentifier) formal_root=\(formal.rootDirectory.path.debugDescription) run_home=\(home.path.debugDescription) foundation_application_support=\(support.path.debugDescription)")
        try #require(environment["HOME"] == home.path && environment["CFFIXED_USER_HOME"] == home.path)
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let expectedSupport = library.appendingPathComponent("Application Support", isDirectory: true)
        try #require(support.path == expectedSupport.path)
        let homeComponents = home.pathComponents
        // The account's real home from the user database: unlike NSHomeDirectory(), it is not
        // redirected by the isolated HOME / CFFIXED_USER_HOME this test asserts on.
        let realHomePath = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        let actualLibraryComponents = URL(fileURLWithPath: realHomePath)
            .appendingPathComponent("Library", isDirectory: true).pathComponents
        try #require(support.pathComponents.count > homeComponents.count
            && support.pathComponents.starts(with: homeComponents)
            && !support.pathComponents.starts(with: actualLibraryComponents))
        try #require(home.resolvingSymlinksInPath().path == home.path)

        // Check each remaining component without following symlinks. A
        // missing Library means the support directory cannot already exist.
        func isExistingDirectory(_ url: URL) throws -> Bool {
            var info = stat()
            let result = url.path.withCString { lstat($0, &info) }
            if result == -1 && errno == ENOENT { return false }
            try #require(result == 0 && (info.st_mode & S_IFMT) == S_IFDIR)
            return true
        }
        try #require(try isExistingDirectory(home))
        let supportExists = try isExistingDirectory(library) && isExistingDirectory(support)
        var supportState = "absent"
        if supportExists {
            let entries = try FileManager.default.contentsOfDirectory(atPath: support.path)
            if entries.isEmpty {
                supportState = "empty"
            } else {
                try #require(isFormalNativeHost && entries == ["CrashReporter"])
                let crashReporter = support.appendingPathComponent("CrashReporter", isDirectory: true)
                var info = stat()
                let result = crashReporter.path.withCString { lstat($0, &info) }
                try #require(result == 0 && (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == getuid())
                supportState = "crashreporter-only"
            }
        }
        print("B13_ISOLATION qualified=true support_state=\(supportState)")

        let fixture = try Fixture(initialHistory: [])
        let gate = fixture.profile.rootDirectory.appendingPathComponent("b13-release.fifo")
        try #require(gate.path.withCString { mkfifo($0, 0o600) } == 0)
        defer { try? FileManager.default.removeItem(at: gate) }
        try #require(!gate.path.contains("'"))
        let command = "cat '\(gate.path)'"
        let arguments: [String: Any] = ["command": command, "run_in_background": true, "timeout": 20]
        let input = try ComposerToolInput(arguments)
        let raw = String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
        let callID = "b13-owned-background-call"
        let dialogue = Dialogue(firstToolCall: LLMToolCall(id: callID, name: "shell_execute",
                                                           rawArguments: raw, arguments: arguments))
        let chat = fixture.bridge.chat
        let effects = SystemNotificationEffects(requestAuthorization: {
            Issue.record("B13 must not request system notification permission"); return false
        }, authorizationStatus: { .authorized }, deliver: { _, _, _ in false },
            isApplicationActive: { false }, remove: { _ in }, installResponseHandlers: { _, _ in })
        let notifications = SystemNotificationController(defaults: fixture.profile.makeUserDefaults(),
            canUseSystemNotifications: true, effects: effects)
        defer {
            notifications.cancelForApplicationExit()
            chat.stopAllStreamingForSafety()
            withExtendedLifetime(fixture.settings) {}
        }
        let terminalPolicy = fixture.settings.terminalPolicySettings
        fixture.settings.terminalPolicySettings = terminalPolicy.editingConfirmationCommands(
            terminalPolicy.confirmationCommands + ["cat"]
        )
        await fixture.attach()
        try #require(chat.applySwitchSession(id: fixture.sessionID))
        SystemNotificationAppBindings.bind(notifications, bridge: fixture.bridge,
            isSettingsVisible: { false }, closeSettings: {})
        let executor = try #require(fixture.bridge.productionBuiltinToolExecutor)
        let sessionID = fixture.sessionID.uuidString
        try #require(executor.fileChangeSessionID == sessionID)
        try #require(executor.terminalPolicySnapshot.classify(command: command) == .confirmation)
        let registry = executor.backgroundShells
        try #require(registry === BackgroundShellRegistry.shared && registry.events().isEmpty)

        do {
            chat.streamingProviderOverride = dialogue
            chat.draftText = "Start the synthetic background command."
            chat.submitComposer()
            let parent = try #require(chat.turnTaskForTests(sessionID: fixture.sessionID))
            var approved = false
            var unexpectedApproval = false
            let parentEnded = await waitUntil {
                if !approved, let request = fixture.bridge.approvalCenter.pendingRequest {
                    guard let snapshot = chat.lastComposerSubmissionSnapshot else {
                        unexpectedApproval = true; return true
                    }
                    let expected = snapshot.callSnapshot(callID: callID, input: input)
                    guard request.toolName == "shell_execute", request.callID == expected.callID,
                          request.sessionID == sessionID, request.sessionID == expected.sessionID,
                          request.turnID == expected.turnID, request.taskID == expected.taskID,
                          request.attemptID == expected.attemptID, request.messageID == expected.messageID,
                          request.policyRevision == expected.policyRevision, request.grantEpoch == expected.grantEpoch,
                          request.composerMode == expected.mode.rawValue,
                          request.approvalScope == expected.approvalScope.rawValue,
                          request.inputDigest == expected.inputDigest,
                          request.identityDigest == expected.identityDigest else {
                        unexpectedApproval = true; return true
                    }
                    approved = true
                    fixture.bridge.approvalCenter.approvePending(reason: "Approve the exact synthetic B13 command")
                    if fixture.bridge.approvalCenter.awaitingConfirmation {
                        fixture.bridge.approvalCenter.confirmPending(reason: "Confirm the exact synthetic B13 command")
                    }
                }
                return !chat.hasStreamingTasksForSafety
            }
            try #require(parentEnded && approved && !unexpectedApproval && dialogue.requests.count == 2)
            await parent.value
            try #require(chat.activeExecutionIdentity(for: fixture.sessionID) == nil)
            let result = try #require(dialogue.requests[1].first {
                $0.role == .tool && $0.toolCallID == callID
            })
            let start = try #require(JSONSerialization.jsonObject(with: Data(result.content.utf8)) as? [String: Any])
            let taskID = try #require(start["task_id"] as? String)
            try #require(start["background"] as? Bool == true)
            try #require(registry.snapshot(id: taskID, sessionID: sessionID)?.state == .running)
            try #require(!registry.events().contains { $0.kind == .finished && $0.snapshot.id == taskID })

            let (events, continuation) = AsyncStream<BackgroundShellEvent>.makeStream()
            let observer = NotificationCenter.default.addObserver(
                forName: BackgroundShellRegistry.didChangeNotification, object: registry, queue: nil
            ) { _ in
                if let event = registry.events().last(where: {
                    $0.kind == .finished && $0.snapshot.id == taskID && $0.snapshot.sessionID == sessionID
                }) {
                    continuation.yield(event)
                }
            }
            var observedFinish: BackgroundShellEvent?
            let listener = Task { @MainActor in
                for await event in events {
                    observedFinish = event
                    return
                }
            }
            defer {
                NotificationCenter.default.removeObserver(observer)
                continuation.finish()
                listener.cancel()
            }

            // The real shell blocks reading this FIFO until the parent retires.
            let stdout = "B13_SYNTHETIC_STDOUT_BODY"
            var writer: Int32 = -1
            try #require(await waitUntil {
                writer = gate.path.withCString { open($0, O_WRONLY | O_NONBLOCK) }
                return writer >= 0
            })
            do {
                defer { _ = close(writer) }
                try #require(fcntl(writer, F_SETNOSIGPIPE, 1) == 0)
                let bytes = Data(stdout.utf8)
                let written = bytes.withUnsafeBytes { write(writer, $0.baseAddress, $0.count) }
                try #require(written == bytes.count)
            }
            await registry.waitUntilFinished(ids: [taskID], waitSeconds: 5)
            let finished = registry.events().filter {
                $0.kind == .finished && $0.snapshot.id == taskID && $0.snapshot.sessionID == sessionID
            }
            try #require(finished.count == 1)
            try #require(await waitUntil { observedFinish != nil })
            try #require(observedFinish == finished.first)
            let snapshot = try #require(finished.first?.snapshot)
            try #require(snapshot.state == .exited && snapshot.exitCode == 0)
            try #require(registry.tail(id: taskID)?.stdout == stdout)
            try #require(!chat.hasStreamingTasksForSafety && dialogue.requests.count == 2)
            print("B13_FINISHED owned=true exit=0 parent_retired=true automatic_requests=0")

            func completions(in prompt: String) throws -> [[String: Any]] {
                let escaped = NSRegularExpression.escapedPattern(for: taskID)
                let pattern = #"\{[^{}]*"task_id"\s*:\s*""# + escaped + #""[^{}]*\}"#
                let regex = try NSRegularExpression(pattern: pattern)
                let body = prompt as NSString
                return regex.matches(in: prompt, range: NSRange(location: 0, length: body.length)).compactMap {
                    let object = try? JSONSerialization.jsonObject(
                        with: Data(body.substring(with: $0.range).utf8)) as? [String: Any]
                    guard object?["status"] as? String == snapshot.state.wireName else { return nil }
                    return object
                }
            }

            chat.draftText = "Tell me what completed in the background."
            chat.submitComposer()
            let next = try #require(chat.turnTaskForTests(sessionID: fixture.sessionID))
            await next.value
            try #require(dialogue.requests.count == 3)
            let prompt = try #require(dialogue.systemPrompts[2])
            let metadata = try completions(in: prompt)
            #expect(metadata.count == 1)
            if let completion = metadata.first {
                let exitCode = try #require(completion["exit_code"] as? NSNumber)
                #expect(CFGetTypeID(exitCode) != CFBooleanGetTypeID() && exitCode.doubleValue == 0)
                #expect(try JSONSerialization.data(withJSONObject: completion).count <= 2_048)
            }
            #expect(!prompt.contains(stdout))
            #expect(dialogue.requests[2].allSatisfy { !$0.content.contains(stdout) })

            chat.draftText = "Continue with a separate user request."
            chat.submitComposer()
            let later = try #require(chat.turnTaskForTests(sessionID: fixture.sessionID))
            await later.value
            try #require(dialogue.requests.count == 4)
            let laterPrompt = try #require(dialogue.systemPrompts[3])
            #expect(try completions(in: laterPrompt).isEmpty)
        } catch {
            _ = await registry.terminateAll(sessionID: sessionID, reason: .applicationExit, waitSeconds: 2)
            throw error
        }
    }

    @Test("own checkpoint followed by a real streamed reply budget pause must not isolate the window")
    func ownedCheckpointBudgetPauseKeepsFreshConversationWritable() async throws {
        let fixture = try Fixture()
        // 流式显示会扣住尚未遇到边界的末尾词（防止半截密钥闪现），回复带空格边界才能在终止前上屏。
        let reply = "CURRENT_REPLY_2669 streamed."
        let dialogue = Dialogue(replyText: reply, replyUsage: LLMUsage(inputTokens: 1_200, outputTokens: 100))
        let chat = fixture.bridge.chat
        defer {
            chat.stopAllStreamingForSafety()
            dialogue.releaseReplyCompletion()
            withExtendedLifetime(fixture.settings) {}
        }
        await fixture.attach()
        #expect(chat.applySwitchSession(id: fixture.sessionID))
        #expect(chat.outputMode == .normal)
        chat.configureBudget(from: fixture.settings.settings.agent,
            processEnvironment: [RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                FieldContextLimitOverride.environmentKey: "6000"],
            processArguments: [RuntimeIsolationProfile.fieldActivationArgument])
        await chat.budgetTracker.record(requestTokens: 5_300)
        chat.requestBudget = await chat.budgetTracker.budget
        try recordOccupancy(chat, fixture)
        chat.streamingProviderOverride = dialogue
        let original = try #require(fixture.settings.sessionStore.loadSession(id: fixture.sessionID.uuidString))
        let submitted = "Continue comparing the previously supplied options."
        chat.draftText = submitted
        chat.submitComposer()
        let liveReply = await waitUntil {
            chat.messages.last?.isStreaming == true && chat.messages.last?.content.hasPrefix("CURRENT_REPLY_2669 ") == true
        }
        try #require(liveReply, "the actual normal-mode consumer must display a nonempty delta before terminal usage")
        let checkpoint = try #require(try fixture.settings.sessionStore.loadLatestCompactionCheckpoint(
            sessionID: fixture.sessionID.uuidString))
        dialogue.releaseReplyCompletion()
        let ended = await waitUntil { !chat.hasStreamingTasksForSafety }
        #expect(ended)
        let canonical = try #require(fixture.settings.sessionStore.loadSession(id: fixture.sessionID.uuidString))
        #expect(Array(canonical.messages.prefix(original.messages.count)) == original.messages)
        #expect(canonical.messages.filter { $0.role == .user && $0.content == submitted }.count == 1)
        let pausedReply = try #require(canonical.messages.last)
        #expect(pausedReply.role == .assistant && pausedReply.content.contains("CURRENT_REPLY_2669"))
        #expect(pausedReply.content.contains("本会话累计用量已达上限，已暂停。可重置本会话预算，或到设置里调高上限或改为不限；也可以在新会话继续，原会话保留。"))
        #expect(!pausedReply.content.contains("CHAT-UNKNOWN"))
        #expect(dialogue.summaryRequests.count == 1,
            "the pause policy completes one pre-send summary, then pauses on ordinary reply usage without in-turn compaction")
        #expect(chat.executionSnapshot(forSessionID: fixture.sessionID)?.failureKind == .budgetPause)
        #expect(chat.budgetIsOverLimit && chat.canContinueAfterContextLimit)
        #expect(!chat.isCanonicalWriteIsolated(fixture.sessionID),
            "our verified checkpoint plus a budget pause must not be classified as an external writer")
        let freshStore = SessionStore(directory: fixture.profile.sessionDirectory)
        #expect(try freshStore.loadLatestCompactionCheckpoint(sessionID: fixture.sessionID.uuidString) == checkpoint)
        try await confirmEmptyContinuation(chat)
        let nextID = try #require(chat.activeSessionID)
        #expect(nextID != fixture.sessionID && chat.budgetUsedTokens == 0)
        #expect(!chat.hasUnsavedSessionChanges && !chat.isCanonicalWriteIsolated(nextID))
        chat.draftText = "A new ordinary question in the fresh conversation."
        chat.submitComposer()
        let nextEnded = await waitUntil { !chat.hasStreamingTasksForSafety }
        #expect(nextEnded)
        let nextCanonical = try #require(freshStore.loadSession(id: nextID.uuidString))
        #expect(nextCanonical.messages.last?.content == reply)
        #expect(!chat.hasUnsavedSessionChanges)
        #expect(try freshStore.loadLatestCompactionCheckpoint(sessionID: fixture.sessionID.uuidString) == checkpoint)
    }

    @Test("an independent canonical write after our verified checkpoint still isolates without overwrite")
    func externalCanonicalChangeAfterOwnedCheckpointStillIsolatesWithoutOverwrite() async throws {
        let fixture = try Fixture()
        // 流式显示会扣住尚未遇到边界的末尾词（防止半截密钥闪现），回复带空格边界才能在终止前上屏。
        let reply = "CURRENT_REPLY_2669 streamed."
        let dialogue = Dialogue(replyText: reply, replyUsage: LLMUsage(inputTokens: 1_200, outputTokens: 100))
        let chat = fixture.bridge.chat
        defer {
            chat.stopAllStreamingForSafety()
            dialogue.releaseReplyCompletion()
            withExtendedLifetime(fixture.settings) {}
        }
        await fixture.attach()
        #expect(chat.applySwitchSession(id: fixture.sessionID))
        #expect(chat.outputMode == .normal)
        chat.configureBudget(from: fixture.settings.settings.agent,
            processEnvironment: [RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                FieldContextLimitOverride.environmentKey: "6000"],
            processArguments: [RuntimeIsolationProfile.fieldActivationArgument])
        await chat.budgetTracker.record(requestTokens: 5_300)
        chat.requestBudget = await chat.budgetTracker.budget
        try recordOccupancy(chat, fixture)
        chat.streamingProviderOverride = dialogue
        chat.draftText = "Continue comparing the previously supplied options."
        chat.submitComposer()
        let liveReply = await waitUntil {
            chat.messages.last?.isStreaming == true && chat.messages.last?.content.hasPrefix("CURRENT_REPLY_2669 ") == true
        }
        try #require(liveReply, "the ordinary reply starts only after our checkpoint and full readback")
        let independent = SessionStore(directory: fixture.profile.sessionDirectory)
        let checkpoint = try #require(try independent.loadLatestCompactionCheckpoint(
            sessionID: fixture.sessionID.uuidString))
        var external = try #require(independent.loadSession(id: fixture.sessionID.uuidString))
        try #require(external.transcriptRevision == checkpoint.resultTranscriptRevision)
        external.messages.append(LLMMessage(role: .user, content: "Independent post-checkpoint edit must survive."))
        external.transcriptRevision += 1
        external.updatedAt = Date()
        try independent.updateSession(external)
        let path = independent.sessionsDirectory.appendingPathComponent(fixture.sessionID.uuidString + ".json")
        let externalBytes = try Data(contentsOf: path)
        dialogue.releaseReplyCompletion()
        let ended = await waitUntil { !chat.hasStreamingTasksForSafety }
        #expect(ended)
        #expect(dialogue.summaryRequests.count == 1)
        #expect(chat.executionSnapshot(forSessionID: fixture.sessionID)?.failureKind == .budgetPause)
        #expect(chat.budgetIsOverLimit && chat.canContinueAfterContextLimit)
        #expect(chat.isCanonicalWriteIsolated(fixture.sessionID))
        #expect(try Data(contentsOf: path) == externalBytes)
        #expect(independent.loadSession(id: fixture.sessionID.uuidString) == external)
        #expect(try independent.loadLatestCompactionCheckpoint(sessionID: fixture.sessionID.uuidString) == checkpoint)
    }

    @Test("an actual independent canonical write still refuses compaction and cannot be overwritten")
    func externalCanonicalChangeStillIsolatesWithoutOverwrite() async throws {
        let fixture = try Fixture()
        let summary = HeldSummary(lateFailure: false)
        let dialogue = Dialogue()
        let chat = fixture.bridge.chat
        defer {
            chat.stopAllStreamingForSafety()
            summary.releaseAll()
            withExtendedLifetime(fixture.settings) {}
        }
        await fixture.attach()
        #expect(chat.applySwitchSession(id: fixture.sessionID))
        try recordOccupancy(chat, fixture)
        chat.compactionProviderOverride = summary
        chat.streamingProviderOverride = dialogue
        chat.draftText = "A pending request whose canonical source will change independently."
        chat.submitComposer()
        let entered = await waitUntil { summary.calls == 1 && summary.active == 1 }
        try #require(entered)
        let independent = SessionStore(directory: fixture.profile.sessionDirectory)
        var external = try #require(independent.loadSession(id: fixture.sessionID.uuidString))
        external.messages.append(LLMMessage(role: .user, content: "Independent canonical edit must survive."))
        external.transcriptRevision += 1
        external.updatedAt = Date()
        try independent.updateSession(external)
        let path = independent.sessionsDirectory.appendingPathComponent(fixture.sessionID.uuidString + ".json")
        let externalBytes = try Data(contentsOf: path)
        summary.release(1)
        let ended = await waitUntil { !chat.hasStreamingTasksForSafety && summary.active == 0 }
        #expect(ended)
        #expect(chat.isCanonicalWriteIsolated(fixture.sessionID))
        #expect(dialogue.requests.isEmpty)
        #expect(try Data(contentsOf: path) == externalBytes)
        #expect(independent.loadSession(id: fixture.sessionID.uuidString) == external)
        #expect(try independent.loadLatestCompactionCheckpoint(sessionID: fixture.sessionID.uuidString) == nil)
    }

    @Test("live ordinary history compacts without inventing session-read provenance", arguments: [0, 1])
    func composerHistoryCarriesNoSessionReadProvenance(mode: Int) async throws {
        let legacySidecar = mode == 1
        let first = "请描写虚构蓝桥边的纸风车。"
        let texts = [first, "继续描写雨后天空。", "继续描写桥下河水。", "继续描写纸风车和微风。"]
        let reply = String(repeating: "The fictional blue bridge is quiet after rain. A paper windmill turns in the breeze while the river reflects the clearing sky. ", count: 8)
        let legacyHistory = texts.flatMap { [LLMMessage(role: .user, content: $0), LLMMessage(role: .assistant, content: reply)] }
        let fixture = try Fixture(initialHistory: legacySidecar ? legacyHistory : [],
            legacyUnrelatedIntent: legacySidecar ? first : nil)
        let dialogue = Dialogue(replyText: reply)
        let summary = HeldSummary(lateFailure: false,
            summaryText: "The assistant described the fictional blue bridge, river, clearing sky and paper windmill after rain.")
        let chat = fixture.bridge.chat
        defer {
            chat.stopAllStreamingForSafety()
            summary.releaseAll()
            withExtendedLifetime(fixture.settings) {}
        }
        await fixture.attach()
        #expect(chat.applySwitchSession(id: fixture.sessionID))
        chat.configureBudget(from: fixture.settings.settings.agent,
            processEnvironment: [RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                FieldContextLimitOverride.environmentKey: "6000"],
            processArguments: [RuntimeIsolationProfile.fieldActivationArgument])
        chat.streamingProviderOverride = dialogue
        for text in legacySidecar ? [] : texts {
            chat.draftText = text
            chat.submitComposer()
            let ended = await waitUntil { !chat.hasStreamingTasksForSafety }
            #expect(ended)
            #expect(chat.messages.last?.content == reply)
        }
        let priorRequests = legacySidecar ? 0 : 4
        #expect(dialogue.requests.count == priorRequests)
        let original = try #require(fixture.settings.sessionStore.loadSession(id: fixture.sessionID.uuidString))
        if legacySidecar {
            #expect(original.messages == legacyHistory)
            // The session-read intent field is no longer read or written (line L);
            // the legacy sidecar value is inert, so only the UI projection is checked below.
        }
        let firstUser = try #require(chat.messages.first { $0.role == .user })
        #expect(firstUser.trustedSessionReadIntent == nil)
        #expect(chat.messages.filter { $0.role == .user }.dropFirst().allSatisfy {
            $0.trustedSessionReadIntent == nil
        })
        await chat.budgetTracker.record(requestTokens: 5_300)
        chat.requestBudget = await chat.budgetTracker.budget
        #expect(!chat.budgetIsOverLimit)
        try recordOccupancy(chat, fixture)
        chat.compactionProviderOverride = summary
        let next = "请回顾蓝桥、纸风车与雨后天空。"
        chat.draftText = next
        chat.submitComposer()
        let reachedBoundary = await waitUntil { summary.calls == 1 || !chat.hasStreamingTasksForSafety }
        #expect(reachedBoundary)
        if summary.calls == 1 { summary.release(1) }
        let ended = await waitUntil { !chat.hasStreamingTasksForSafety && summary.active == 0 }
        #expect(ended)
        let canonical = try #require(fixture.settings.sessionStore.loadSession(id: fixture.sessionID.uuidString))
        #expect(Array(canonical.messages.prefix(original.messages.count)) == original.messages)
        let checkpoint = try fixture.settings.sessionStore.loadLatestCompactionCheckpoint(sessionID: fixture.sessionID.uuidString)
        #expect(summary.calls == 1 && summary.exits == 1 && dialogue.requests.count == priorRequests + 1)
        #expect(chat.contextLimitReason == nil && !chat.canContinueAfterContextLimit)
        let saved = try #require(checkpoint)
        let source = original.messages + [LLMMessage(role: .user, content: next)]
        #expect(Array(saved.replacementHistory.suffix(3)) == Array(source.suffix(3)))
        let request = try #require(dialogue.requests.last)
        // Older turns are summarized by the model (lossy): the continued request
        // carries that summary and the exact recent tail, not every old user turn.
        #expect(request.contains { $0.content.contains("The assistant described the fictional blue bridge") })
        #expect(request.contains { $0.content == next })
        #expect(canonical.messages.last?.content == reply)
    }

    /// Original short synthetic public input retained verbatim as the
    /// negative qualification control (I1005: cost363, cap326, lowerbound359).
    private func originalShortPlainHistory() -> [LLMMessage] {
        return [
            LLMMessage(role: .user, content: "P03_TEXT_01：这是纯文本短问答，不调用任何工具、不访问文件。请用160至180个汉字解释雨后为什么有彩虹，并记住本次合成故事主角名小岚、地点蓝桥、物件纸风车。后续只讨论这个虚构故事。"),
            LLMMessage(role: .assistant, content: "雨后空气中悬浮着许多细小水滴，阳光斜射进入水滴时先发生折射，在内壁反射一次，再折射出来就散开了。因为不同颜色的光，其折射率不同，白光被分解成红橙黄绿蓝靛紫的色谱，于是排成弧形彩带。彩虹其实是完整的圆，只是地面挡住了下半圈；它的圆心总在太阳的正对面，所以我们只能看到半弧。要看到它，太阳得在你身后、水滴在你前方，所以多见于清晨或傍晚雨刚停时。有时还能看到外圈颜色相反的第二道虹。（约170字）\n\n已记住虚构故事设定：主角小岚、地点蓝桥、物件纸风车。后续对话我将只围绕这个故事展开。"),
            LLMMessage(role: .user, content: "P03_TEXT_02：请用160至180个汉字续写小岚拿着纸风车走到蓝桥的场景，加入雨后树叶、河水和风，但不引入现实人物、路径或工具指令。结尾保留小岚准备观察天空。"),
            LLMMessage(role: .assistant, content: "雨后的小岚把纸风车举在胸前，走上蓝桥。桥头的树叶还挂着水珠，风一过，便簌簌落下，打在她手背上，凉丝丝的。河水涨了些，浑黄里翻着碎光，一圈圈推到桥墩下，声音低沉又连绵。风从水面升起来，穿过桥栏，把纸风车的四片叶子吹得呼呼转，红黄交错，像一小团转动的火。小岚停下脚步，把风车举高些，让风把它转得更欢。她仰起脸，望见云层正慢慢裂开一道缝，缝隙里透出淡淡的光。她深吸一口气，握紧竹柄，准备静静观察天空的动静。\n\n（175 字）场景已接续：小岚、蓝桥、纸风车保持一致，收束在仰头待观天空的姿态上。"),
            LLMMessage(role: .user, content: "P03_TEXT_03：继续这个虚构故事，用160至180个汉字描写小岚在蓝桥看见云缝露出阳光，纸风车慢慢转动。人物保持小岚，地点保持蓝桥，避免新增任务、引用、代码或工具操作。"),
            LLMMessage(role: .assistant, content: "云缝一点点变宽，光从里面漏下来，先是一线，后来铺成一片，落在蓝桥的木栏上，把湿漉漉的栏杆照得发亮。小岚眯起眼，看那束光斜斜地插进河面，水上映出一小片金。风忽然轻了，纸风车也跟着慢下来，四片叶子几乎停住，只一下、一下地转，像在迟疑。她不催它，只把手稍稍偏了偏，让风车正对着风来的方向。桥下的水声细了，树叶上的水珠被光照透，一颗颗亮起来，有几颗落进河里，一晃就没了。小岚屏住呼吸，觉出光正落在自己额头上，她抬着头，等天空再给出一点什么。\n\n（172 字）场景仍在蓝桥，人物仍是小岚，纸风车由疾转缓，收束于她静待天空变化。"),
            LLMMessage(role: .user, content: "P03_TEXT_04：请用120至150个汉字描写小岚回忆蓝桥名字的来历，设定只是村民喜爱晴天空色，不涉及现实资料。最后让小岚继续拿着纸风车等待彩虹。不用工具。"),
            LLMMessage(role: .assistant, content: "小岚想起村里老人说过，桥叫蓝桥，只因大家最爱晴天的天空颜色。那时雨后仰头，天色干净得像被洗过，蓝得让人心里也静下来，村里人便这样叫它。她把纸风车换个方向拿，四片叶子轻轻转了半圈。光还在云边亮着，她望着河水，不急着回去，就这么站在桥上等彩虹出来。\n\n（129 字）故事仍在小岚与蓝桥，纸风车在手中，收束于等待彩虹。"),
            LLMMessage(role: .user, content: "P03_TEXT_05：仍只做纯文本。用80至100个汉字描述风停片刻，小岚把纸风车举高又放低，注意河面映着云和蓝桥的影子。不要改变故事人物和地点，也不要调用工具。"),
            LLMMessage(role: .assistant, content: "风忽然停了片刻，纸风车慢得几乎不动。小岚把手臂举高，叶子颤了一下；又慢慢放低，风车斜斜垂在胸前。河面很静，云影和蓝桥的影子都落在水里，随着细微波纹轻轻错开，又慢慢合上。（88 字）"),
            LLMMessage(role: .user, content: "P03_TEXT_06：不用工具，用40字以内说出故事主角、地点、手中物件，并继续一句彩虹出现时的感受。"),
        ]
    }

    @Test("P03 qualifying synthetic plain-text history reaches the summary producer and continues the ordinary turn")
    func plainFieldHistoryReachesSummaryAndContinuesThroughOrdinarySend() async throws {
        // The original short field source remains the negative control below;
        // the positive source adds only permitted old natural-language detail.
        let originalShort = originalShortPlainHistory()
        // I1005 permits a genuinely reducible positive source. Only old
        // assistant prose grows; all user turns and the recent tail stay exact.
        let elaboration = String(repeating: "小岚仍在雨后的蓝桥，手里的纸风车随微风缓慢转动；湿润树叶映着阳光，河水倒映云影，她安静等候天空中的彩虹。", count: 20)
        let source = originalShort.enumerated().map { index, message in
            guard index < originalShort.count - 3, message.role == .assistant else { return message }
            return LLMMessage(role: .assistant, content: message.content + "\n\n" + elaboration)
        }
        let fixture = try Fixture(initialHistory: Array(source.dropLast()))
        let summaryText = "小岚在雨后的蓝桥拿着纸风车，观察云缝阳光、树叶与河水，回忆蓝桥得名于村民喜爱的晴天空色，继续等待彩虹。"
        let summary = HeldSummary(lateFailure: false, summaryText: summaryText)
        let dialogue = Dialogue()
        let work = PlainSourceWork()
        let chat = fixture.bridge.chat
        var failure: ChatTurnFailureObservationForTests?
        defer {
            chat.stopAllStreamingForSafety()
            summary.releaseAll()
            withExtendedLifetime(fixture.settings) {}
        }
        await fixture.attach()
        #expect(chat.applySwitchSession(id: fixture.sessionID))
        chat.configureBudget(from: fixture.settings.settings.agent,
            processEnvironment: [RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                FieldContextLimitOverride.environmentKey: "6000"],
            processArguments: [RuntimeIsolationProfile.fieldActivationArgument])
        await chat.budgetTracker.record(requestTokens: 5_300)
        chat.requestBudget = await chat.budgetTracker.budget
        #expect(chat.budgetCapTokens == 6_000 && !chat.budgetIsOverLimit)
        try recordOccupancy(chat, fixture)
        chat.automaticCompactionHighBudgetObserverForTests = { work.record($0) }
        chat.turnFailureObserverForTests = { failure = $0 }
        chat.compactionProviderOverride = summary
        chat.streamingProviderOverride = dialogue
        chat.draftText = try #require(source.last?.content)
        chat.submitComposer()
        let entered = await waitUntil { summary.calls == 1 || !chat.hasStreamingTasksForSafety }
        #expect(entered)
        // Existing producer and worker observations remain assertion inputs;
        // they do not introduce product trace or diagnostic output.
        if summary.calls == 1 { summary.release(1) }
        let ended = await waitUntil { !chat.hasStreamingTasksForSafety && summary.active == 0 }
        #expect(ended)
        #expect(summary.calls == 1 && summary.exits == 1,
            "the actual ordinary path must reach and finish the known safe summary producer")
        #expect(work.projections > 0 && work.canonicalReads > 0)
        #expect(failure == nil)
        #expect(dialogue.requests.count == 1)
        #expect(chat.contextLimitReason == nil && !chat.canContinueAfterContextLimit)
        let canonical = try #require(fixture.settings.sessionStore.loadSession(id: fixture.sessionID.uuidString))
        #expect(Array(canonical.messages.prefix(source.count)) == source,
            "canonical original user and assistant messages must remain unchanged")
        #expect(canonical.messages.last?.content == "CURRENT_REPLY_2669")
        let checkpoint = try #require(try fixture.settings.sessionStore.loadLatestCompactionCheckpoint(sessionID: fixture.sessionID.uuidString))
        #expect(Array(checkpoint.replacementHistory.suffix(3)) == Array(source.suffix(3)),
            "the recent tail, including this submission, must be kept verbatim")
        let request = try #require(dialogue.requests.first)
        #expect(request.filter { $0.content == source.last?.content }.count == 1)
        #expect(!request.contains { $0.role == .assistant && $0.content.isEmpty })
        #expect(request.contains { $0.content.contains(summaryText) })
        // Older user turns are summarized by the model (lossy), no longer kept verbatim.
        let reopened = SessionStore(directory: fixture.profile.sessionDirectory)
        #expect(reopened.loadSession(id: canonical.id) == canonical)
        #expect(try reopened.loadLatestCompactionCheckpoint(sessionID: canonical.id) == checkpoint)
    }

    @Test("P03 short history refuses an infeasible projection without changing history or blocking an ordinary next turn")
    func originalShortPlainProjectionRefusesAndNextOrdinaryTurnContinues() async throws {
        let source = originalShortPlainHistory()
        let fixture = try Fixture(initialHistory: source)
        let summary = Dialogue()
        let dialogue = Dialogue()
        let chat = fixture.bridge.chat
        defer {
            chat.stopAllStreamingForSafety()
            withExtendedLifetime(fixture.settings) {}
        }
        await fixture.attach()
        #expect(chat.applySwitchSession(id: fixture.sessionID))
        let visible = chat.messages
        // Empty facts is the most optimistic public lower bound. It is not
        // substituted for the App's canonical facts in the real send below.
        let result = try await Compactor(keepRecentMessages: 3).compact(
            messages: source, summarizeUsing: summary,
            systemPrompt: "Retain this synthetic plain story as background.",
            retentionFacts: [], safetyMode: .sourceAnchoredNatural)
        #expect(result.compactedCount == 0)
        #expect(result.messages == source)
        #expect(summary.summaryRequests.isEmpty)
        #expect(chat.messages == visible)
        chat.compactionProviderOverride = summary
        chat.streamingProviderOverride = dialogue
        chat.draftText = "下一轮仍只讲小岚在蓝桥拿着纸风车的虚构故事。"
        chat.submitComposer()
        let ended = await waitUntil { !chat.hasStreamingTasksForSafety }
        #expect(ended)
        #expect(dialogue.requests.count == 1)
        #expect(summary.summaryRequests.isEmpty)
        let canonical = try #require(fixture.settings.sessionStore.loadSession(id: fixture.sessionID.uuidString))
        #expect(Array(canonical.messages.prefix(source.count)) == source)
        #expect(canonical.messages.last?.content == "CURRENT_REPLY_2669")
    }

    @Test(arguments: [false, true])
    func stoppedSummaryCannotBlockOrWriteIntoNextOrdinarySend(lateFailure: Bool) async throws {
        let fixture = try Fixture()
        let summary = HeldSummary(lateFailure: lateFailure)
        let dialogue = Dialogue()
        let chat = fixture.bridge.chat
        defer {
            chat.stopAllStreamingForSafety()
            summary.releaseAll()
            withExtendedLifetime(fixture.settings) {}
        }
        await fixture.attach()
        #expect(chat.applySwitchSession(id: fixture.sessionID))
        // The default cumulative cap is 1,000,000 since C1; this test's 0.8 budget
        // fraction is built on an explicit 100_000 cap. The compaction trigger is
        // the window occupancy below, not this budget.
        var cappedAgent = fixture.settings.settings.agent
        cappedAgent.maxTokensPerSession = 100_000
        chat.configureBudget(from: cappedAgent)
        await chat.budgetTracker.record(requestTokens: 80_000)
        chat.requestBudget = await chat.budgetTracker.budget
        #expect(chat.requestBudget.usageFraction == 0.8)
        #expect(!chat.requestBudget.isExhausted)
        try recordOccupancy(chat, fixture)
        chat.compactionProviderOverride = summary
        chat.streamingProviderOverride = dialogue
        let first = "FIRST_CANCELLED_SEND_2669"
        let second = "SECOND_CURRENT_SEND_2669"
        chat.draftText = first
        chat.submitComposer()
        let firstEntered = await waitUntil { summary.calls == 1 && summary.active == 1 }
        #expect(firstEntered, "ordinary pre-send compaction never reached the held producer")
        guard firstEntered else { return }
        #expect(chat.isActiveSessionStreaming)
        #expect(dialogue.requests.isEmpty)
        #expect(try fixture.settings.sessionStore.loadLatestCompactionCheckpoint(sessionID: fixture.sessionID.uuidString) == nil)

        chat.stopStreaming()
        #expect(!chat.isActiveSessionStreaming, "stop must retire the UI/send ownership without pretending the summary producer exited")
        #expect(summary.active == 1, "controlled summary intentionally ignores cancellation until explicitly released")
        chat.draftText = second
        chat.submitComposer()
        let secondEntered = await waitUntil { summary.calls == 2 && summary.active == 2 }
        print("COMPACT2669 nextEntered=\(secondEntered) lateFailure=\(lateFailure) summaryCalls=\(summary.calls) active=\(summary.active) dialogue=\(dialogue.requests.count)")
        #expect(secondEntered, "a stopped summary retained the ordinary send admission slot")
        guard secondEntered else {
            chat.stopAllStreamingForSafety()
            summary.releaseAll()
            let drained = await waitUntil { summary.active == 0 }
            #expect(drained, "owned synthetic producers did not actually exit during RED cleanup")
            return
        }
        let secondSource = try #require(fixture.settings.sessionStore.loadSession(id: fixture.sessionID.uuidString))
        #expect(secondSource.messages.filter { $0.content == first }.count == 1)
        #expect(secondSource.messages.filter { $0.content == second }.count == 1)
        let capturedRevision = secondSource.transcriptRevision

        // Retire the OLD physical producer while the NEW preflight is held.
        // Both late success and late failure must be incapable of mutating it.
        summary.release(1)
        let oldExited = await waitUntil { summary.exits == 1 && summary.active == 1 }
        #expect(oldExited)
        // The ordinary task resumes on MainActor after compactContext returns;
        // yield across that callback before sampling the next-owned projection.
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(chat.isActiveSessionStreaming, "old defer cleared the new preflight")
        #expect(chat.contextLimitReason == nil, "cancelled summary must not add a failure card")
        #expect(chat.messages.filter { $0.content.contains("自动压缩未完成：") }.isEmpty,
            "retired catch appended a failure into the next send")
        let afterOld = try #require(fixture.settings.sessionStore.loadSession(id: fixture.sessionID.uuidString))
        #expect(afterOld.transcriptRevision == capturedRevision)
        #expect(afterOld.messages == secondSource.messages)
        #expect(dialogue.requests.isEmpty)
        #expect(try fixture.settings.sessionStore.loadLatestCompactionCheckpoint(sessionID: fixture.sessionID.uuidString) == nil)

        summary.release(2)
        let currentFinished = await waitUntil { dialogue.requests.count == 1 && !chat.hasStreamingTasksForSafety && summary.active == 0 }
        if !currentFinished { fixture.recordCheckpointFailure(label: "stopped2669", summary: summary, dialogue: dialogue) }
        #expect(currentFinished, "current ordinary send did not complete after its own valid summary")
        guard currentFinished else { return }
        #expect(summary.calls == 2 && summary.exits == 2)
        #expect(dialogue.requests.count == 1)
        #expect(chat.contextLimitReason == nil && !chat.canContinueAfterContextLimit)
        let sent = try #require(dialogue.requests.first)
        #expect(sent.filter { $0.content == second }.count == 1)
        #expect(sent.contains { $0.content == first }, "the stopped send's persisted user material must remain in canonical history")
        let canonical = try #require(fixture.settings.sessionStore.loadSession(id: fixture.sessionID.uuidString))
        #expect(canonical.messages.filter { $0.content == "CURRENT_REPLY_2669" }.count == 1)
        #expect(!canonical.messages.contains { $0.content.contains("自动压缩未完成：") })
        let checkpoint = try #require(try fixture.settings.sessionStore.loadLatestCompactionCheckpoint(sessionID: fixture.sessionID.uuidString))
        let reopened = SessionStore(directory: fixture.profile.sessionDirectory)
        #expect(reopened.loadSession(id: canonical.id) == canonical)
        #expect(try reopened.loadLatestCompactionCheckpoint(sessionID: canonical.id) == checkpoint)
        let engine = try #require(chat.agentEngine as? AgentLoopChatEngine)
        #expect(engine.toolExecutionFactLedger.facts.isEmpty)
        print("COMPACT2669 lateFailure=\(lateFailure) summaryCalls=\(summary.calls) physicalExits=\(summary.exits) dialogue=\(dialogue.requests.count)")
    }

    @Test("ordinary summary cancellation never shows a failure card or retries", arguments: [0, 1, 2])
    func ordinarySummaryCancellationKeepsTheCancelledOutcome(kind: Int) async throws {
        let cancellation: any Error
        switch kind {
        case 0: cancellation = CancellationError()
        case 1: cancellation = LLMError.cancelled
        default: cancellation = URLError(.cancelled)
        }
        let fixture = try Fixture()
        let summary = HeldSummary(lateFailure: true, summaryFailure: cancellation)
        let dialogue = Dialogue()
        let chat = fixture.bridge.chat
        defer {
            chat.stopAllStreamingForSafety()
            summary.releaseAll()
            withExtendedLifetime(fixture.settings) {}
        }
        await fixture.attach()
        #expect(chat.applySwitchSession(id: fixture.sessionID))
        let original = try #require(fixture.settings.sessionStore.loadSession(id: fixture.sessionID.uuidString))
        try recordOccupancy(chat, fixture)
        chat.compactionProviderOverride = summary
        chat.streamingProviderOverride = dialogue
        let prompt = "ORDINARY_SUMMARY_CANCELLED_P03"
        chat.draftText = prompt
        chat.submitComposer()
        let entered = await waitUntil { summary.calls == 1 && summary.active == 1 }
        #expect(entered)
        guard entered else { return }
        let identity = try #require(chat.activeExecutionIdentity(for: fixture.sessionID))
        // Do not stop/cancel the parent task: each producer error must reach
        // its actual cancellation classification rather than Task.isCancelled.
        summary.release(1)
        let ended = await waitUntil { summary.exits == 1 && !chat.hasStreamingTasksForSafety }
        #expect(ended)
        #expect(summary.calls == 1 && summary.exits == 1 && dialogue.requests.isEmpty)
        #expect(chat.terminalReceipt(for: identity)?.outcome == .cancelled)
        #expect(chat.contextLimitReason == nil && !chat.canContinueAfterContextLimit)
        #expect(chat.messages.last?.content.contains("请求已取消") == true)
        #expect(!chat.messages.contains { $0.content.contains("**错误**") || $0.content.contains("自动压缩未完成") })
        #expect(try fixture.settings.sessionStore.loadLatestCompactionCheckpoint(sessionID: fixture.sessionID.uuidString) == nil)
        let canonical = try #require(fixture.settings.sessionStore.loadSession(id: fixture.sessionID.uuidString))
        #expect(Array(canonical.messages.prefix(original.messages.count)) == original.messages)
        #expect(canonical.messages.filter { $0.content == prompt }.count == 1)
    }

    @Test("a failed summary request and a Compactor refusal below the hard block both still send", arguments: [false, true])
    func ordinarySummaryProviderErrorAndCompactorRefusalBothStillSend(providerThrows: Bool) async throws {
        let fixture = try Fixture()
        let providerError = LLMError.networkError(underlying: URLError(.timedOut))
        let summary = HeldSummary(lateFailure: providerThrows, summaryText: "   ", summaryFailure: providerError)
        let dialogue = Dialogue()
        let chat = fixture.bridge.chat
        var failure: ChatTurnFailureObservationForTests?
        chat.turnFailureObserverForTests = { failure = $0 }
        defer {
            chat.stopAllStreamingForSafety()
            summary.releaseAll()
            withExtendedLifetime(fixture.settings) {}
        }
        await fixture.attach()
        #expect(chat.applySwitchSession(id: fixture.sessionID))
        let original = try #require(fixture.settings.sessionStore.loadSession(id: fixture.sessionID.uuidString))
        await chat.budgetTracker.record(requestTokens: 80_000)
        chat.requestBudget = await chat.budgetTracker.budget
        try recordOccupancy(chat, fixture)
        chat.compactionProviderOverride = summary
        chat.streamingProviderOverride = dialogue
        let prompt = "ORDINARY_REFUSAL_P18"
        chat.draftText = prompt
        chat.submitComposer()
        let entered = await waitUntil { summary.calls == 1 && summary.active == 1 }
        #expect(entered)
        guard entered else { return }
        // The same ordinary entry sees two actual producer outcomes: a
        // typed timeout or empty text. Neither is replaced by a fake result,
        // dead preflight helper, checkpoint or safety override.
        summary.release(1)
        let ended = await waitUntil { summary.exits == 1 && !chat.hasStreamingTasksForSafety }
        #expect(ended)
        // C3 (user decision 1101:10, 11/9 contract change): an empty summary is the
        // Compactor's own refusal (same shape as a media refusal), and a refusal below
        // 95% of the window no longer stops the send. C3-05 (11/17): a failed summary
        // request (here a typed timeout) is handled the same way instead of failing the
        // turn; the old arm showed a failure card and made no request.
        #expect(summary.calls == 1 && dialogue.requests.count == 1)
        #expect(failure == nil)
        #expect(chat.contextLimitReason == nil && !chat.canContinueAfterContextLimit)
        #expect(!chat.messages.contains { $0.content.contains("自动压缩未完成") || $0.content.contains("**错误**") })
        // 1101:10: the refusal is explained by one quiet line while the send goes on.
        #expect(chat.messages.filter { $0.role == .system
            && $0.content == ChatStore.compactionNotExecutedNoticeText }.count == 1)
        #expect(try fixture.settings.sessionStore.loadLatestCompactionCheckpoint(sessionID: fixture.sessionID.uuidString) == nil)
        let sent = try #require(fixture.settings.sessionStore.loadSession(id: fixture.sessionID.uuidString))
        #expect(Array(sent.messages.prefix(original.messages.count)) == original.messages)
        #expect(sent.messages.filter { $0.content == prompt }.count == 1)
        #expect(sent.messages.last?.content == "CURRENT_REPLY_2669")
    }

    @Test("a dialogue failure never becomes an automatic compaction reason", arguments: [false, true])
    func ordinaryProviderFailureDoesNotInventCompactionCard(compactFirst: Bool) async throws {
        let fixture = try Fixture()
        let summary = HeldSummary(lateFailure: false)
        let dialogue = Dialogue(failReply: true)
        let chat = fixture.bridge.chat
        defer {
            chat.stopAllStreamingForSafety()
            summary.releaseAll()
            withExtendedLifetime(fixture.settings) {}
        }
        await fixture.attach()
        #expect(chat.applySwitchSession(id: fixture.sessionID))
        if compactFirst {
            try recordOccupancy(chat, fixture)
        }
        chat.compactionProviderOverride = summary
        chat.streamingProviderOverride = dialogue
        chat.draftText = "ORDINARY_DIALOGUE_FAILURE_P18"
        chat.submitComposer()
        if compactFirst {
            let entered = await waitUntil { summary.calls == 1 && summary.active == 1 }
            #expect(entered)
            guard entered else { return }
            summary.release(1)
        }
        let ended = await waitUntil { dialogue.requests.count == 1 && !chat.hasStreamingTasksForSafety }
        #expect(ended)
        #expect(chat.executionSnapshot(forSessionID: fixture.sessionID)?.state == .failed)
        #expect(chat.messages.last?.content.contains("CHAT-UNKNOWN") == true)
        #expect(chat.contextLimitReason == nil && !chat.canContinueAfterContextLimit)
        #expect(summary.calls == (compactFirst ? 1 : 0))
        let checkpoint = try fixture.settings.sessionStore.loadLatestCompactionCheckpoint(sessionID: fixture.sessionID.uuidString)
        #expect((checkpoint != nil) == compactFirst)
    }

    @Test("high mirrored budget compacts only the origin A after switching B, and current revocation still refuses execution", arguments: [false, true])
    func switchedOriginUsesFrozenBudgetAndCurrentAuthority2905(revoke: Bool) async throws {
        let fixture = try Fixture()
        let summaryA = HeldSummary(lateFailure: false)
        let summaryB = HeldSummary(lateFailure: false)
        let dialogue = Dialogue()
        let chat = fixture.bridge.chat
        defer {
            chat.stopAllStreamingForSafety()
            summaryA.releaseAll()
            summaryB.releaseAll()
            withExtendedLifetime(fixture.settings) {}
        }
        await fixture.attach()
        #expect(chat.applySwitchSession(id: fixture.sessionID))
        // Explicit 100_000 cap (the default is 1,000,000 since C1) keeps the 0.8
        // budget mirror this test is about; the compaction trigger is the occupancy.
        var cappedAgent = fixture.settings.settings.agent
        cappedAgent.maxTokensPerSession = 100_000
        chat.configureBudget(from: cappedAgent)
        let trackerA = chat.budgetTracker
        await trackerA.record(requestTokens: 80_000)
        chat.requestBudget = await trackerA.budget
        #expect(chat.requestBudget.usageFraction == 0.8)
        try recordOccupancy(chat, fixture)
        chat.compactionProviderOverride = summaryA
        chat.streamingProviderOverride = dialogue
        chat.draftText = "ORIGIN_A_SEND_2905"
        chat.submitComposer()
        let frozen = try #require(chat.lastComposerSubmissionSnapshot)
        #expect(frozen.sessionID == fixture.sessionID.uuidString)
        let entered = await waitUntil { summaryA.calls == 1 && summaryA.active == 1 }
        if !entered { fixture.recordFirstEntryFailure(label: "switched2905") }
        #expect(entered)
        guard entered else { return }
        let original = try #require(fixture.settings.sessionStore.loadSession(id: fixture.sessionID.uuidString))
        #expect(original.messages.filter { $0.content == "ORIGIN_A_SEND_2905" }.count == 1)
        let liveAssistant = try #require(chat.messages.last)
        #expect(liveAssistant.role == .assistant && liveAssistant.isStreaming && liveAssistant.content.isEmpty)
        #expect(original.messages.last == liveAssistant.asLLMMessage())
        let closedSource = Array(original.messages.dropLast())
        #expect(closedSource.last?.content == "ORIGIN_A_SEND_2905")
        #expect(dialogue.requests.isEmpty)
        let bID = chat.applyNewSession(title: "Untouched B2905")
        let trackerB = chat.budgetTracker
        #expect(trackerA !== trackerB)
        chat.compactionProviderOverride = summaryB
        chat.draftText = "UNSENT_B_DRAFT_2905"
        let bOriginal = try #require(fixture.settings.sessionStore.loadSession(id: bID.uuidString))
        let bBudget = await trackerB.budget
        #expect(bBudget.usedTokens == 0 && bBudget.usedRequests == 0)
        if revoke {
            chat.configureComposerPolicy(ComposerPolicyFactSource(
                knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
                workspaceID: chat.composerWorkspaceID, revision: "revoked2905",
                grantEpoch: "revoked2905", leaseID: chat.composerPolicyFacts.leaseID,
                expiresAt: Date()
            ))
        }
        summaryA.release(1)
        let ended = await waitUntil { !chat.hasStreamingTasksForSafety && summaryA.active == 0 }
        #expect(ended)
        #expect(summaryA.calls == 1 && summaryA.exits == 1)
        #expect(summaryB.calls == 0)
        #expect(chat.activeSessionID == bID)
        #expect(chat.draftText == "UNSENT_B_DRAFT_2905")
        #expect(chat.messages.allSatisfy { !$0.content.contains("ORIGIN_A_SEND_2905") })
        #expect(fixture.settings.sessionStore.loadSession(id: bID.uuidString) == bOriginal)
        let bAfter = await trackerB.budget
        #expect(bAfter.usedTokens == bBudget.usedTokens && bAfter.usedRequests == bBudget.usedRequests)
        let a = try #require(fixture.settings.sessionStore.loadSession(id: fixture.sessionID.uuidString))
        #expect(a.messages.filter { $0.content == "ORIGIN_A_SEND_2905" }.count == 1)
        let checkpoint = try fixture.settings.sessionStore.loadLatestCompactionCheckpoint(sessionID: fixture.sessionID.uuidString)
        if revoke {
            #expect(dialogue.requests.isEmpty)
            #expect(checkpoint == nil)
            #expect(a.messages.contains { $0.content.contains("自动压缩未完成") || $0.content.contains("错误") || $0.content.contains("已取消") })
        } else {
            if dialogue.requests.count != 1 { fixture.recordCheckpointFailure(label: "switched2905", summary: summaryA, dialogue: dialogue) }
            #expect(dialogue.requests.count == 1)
            let request = try #require(dialogue.requests.first)
            #expect(request.contains { $0.content == "ORIGIN_A_SEND_2905" })
            #expect(request.allSatisfy { !$0.content.contains("UNSENT_B_DRAFT_2905") })
            #expect(a.messages.filter { $0.content == "CURRENT_REPLY_2669" }.count == 1)
            let committed = try #require(checkpoint)
            #expect(committed.sourceTranscriptRevision == original.transcriptRevision)
            #expect(committed.retentionFacts?.allSatisfy { $0.source?.matchesTranscript(closedSource) == true } == true)
            #expect(committed.schemaVersion == CompactionCheckpoint.lossySummarySchemaVersion)
            #expect(committed.sourcePrefixDigest != nil)
            let reopened = SessionStore(directory: fixture.profile.sessionDirectory)
            #expect(reopened.loadSession(id: a.id) == a)
            #expect(try reopened.loadLatestCompactionCheckpoint(sessionID: a.id) == committed)
        }
        let engine = try #require(chat.agentEngine as? AgentLoopChatEngine)
        #expect(engine.toolExecutionFactLedger.facts.isEmpty)
    }

    @Test("a foreign canonical append during the actual held summary rejects the old checkpoint without overwriting bytes")
    func foreignCanonicalAppendDuringSummaryRetainsSourceBytes2962() async throws {
        let fixture = try Fixture()
        let summary = HeldSummary(lateFailure: false)
        let dialogue = Dialogue()
        let chat = fixture.bridge.chat
        defer {
            chat.stopAllStreamingForSafety()
            summary.releaseAll()
            withExtendedLifetime(fixture.settings) {}
        }
        await fixture.attach()
        #expect(chat.applySwitchSession(id: fixture.sessionID))
        try recordOccupancy(chat, fixture)
        chat.compactionProviderOverride = summary
        chat.streamingProviderOverride = dialogue
        chat.draftText = "OWNED_PENDING_SUMMARY_2962"
        chat.submitComposer()
        let entered = await waitUntil { summary.calls == 1 && summary.active == 1 }
        #expect(entered)
        guard entered else { return }
        // A distinct Store instance uses the supported writer on the same
        // owned synthetic root. The old producer has actually entered.
        let foreignWriter = SessionStore(directory: fixture.profile.sessionDirectory)
        let before = try #require(foreignWriter.loadSession(id: fixture.sessionID.uuidString))
        try foreignWriter.saveMessage(LLMMessage(role: .user,
            content: "FOREIGN_CANONICAL_APPEND_2962"), sessionID: before.id)
        let changed = try #require(foreignWriter.loadSession(id: before.id))
        #expect(changed.transcriptRevision > before.transcriptRevision)
        #expect(changed.messages.count == before.messages.count + 1)
        let bytesURL = foreignWriter.sessionsDirectory.appendingPathComponent(before.id + ".json")
        let changedBytes = try Data(contentsOf: bytesURL)
        summary.release(1)
        let ended = await waitUntil { summary.exits == 1 && summary.active == 0 && !chat.hasStreamingTasksForSafety }
        #expect(ended, "the owned producer must really exit and the rejected run must reach a terminal boundary")
        #expect(dialogue.requests.isEmpty)
        #expect(try fixture.settings.sessionStore.loadLatestCompactionCheckpoint(sessionID: before.id) == nil)
        #expect(foreignWriter.loadSession(id: before.id) == changed)
        #expect(try Data(contentsOf: bytesURL) == changedBytes)
        let reopened = SessionStore(directory: fixture.profile.sessionDirectory)
        #expect(reopened.loadSession(id: before.id) == changed)
        let engine = try #require(chat.agentEngine as? AgentLoopChatEngine)
        #expect(engine.toolExecutionFactLedger.facts.isEmpty)
    }

    /// C1: the trigger is the next request's window occupancy (users 1101:10),
    /// not the cumulative-usage budget. 86% of the dialogue model's window:
    /// above the 80% threshold, below the 95% hard block.
    private func recordOccupancy(_ chat: ChatStore, _ fixture: Fixture, inputTokens: Int = 110_000) throws {
        let canonical = try #require(fixture.settings.sessionStore.loadSession(id: fixture.sessionID.uuidString))
        chat.recordWindowOccupancy(
            sessionID: fixture.sessionID, providerID: Dialogue.providerID, modelID: Dialogue.modelID,
            sentMessageCount: canonical.messages.count, inputTokens: inputTokens)
    }

    private func confirmEmptyContinuation(_ chat: ChatStore) async throws {
        let previous = chat.compactionProviderOverride
        defer { chat.compactionProviderOverride = previous }
        let summary = HeldSummary(lateFailure: true)
        summary.release(1)
        chat.compactionProviderOverride = summary
        let sourceID = chat.activeSessionID
        chat.continueAfterContextLimit()
        let draft = try #require(chat.sessionContinuationDraft)
        try #require(await waitUntil { !draft.isGenerating })
        try #require(draft.failureMessage != nil && draft.previewText.isEmpty)
        try #require(draft.confirmedBackgroundText == nil)
        #expect(chat.activeSessionID == sourceID, "preview cannot open a new session without confirmation")
        chat.confirmSessionContinuation()
        #expect(chat.sessionContinuationDraft == nil)
    }

    private func waitUntil(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }

    private final class PlainSourceWork: @unchecked Sendable {
        private let lock = NSLock()
        private var projectionCount = 0
        private var readCount = 0
        var projections: Int { lock.withLock { projectionCount } }
        var canonicalReads: Int { lock.withLock { readCount } }
        func record(_ stage: AutomaticCompactionSourcePreprocessor.Stage) {
            lock.withLock {
                switch stage {
                case .projection: projectionCount += 1
                case .canonicalRead: readCount += 1
                }
            }
        }
    }

    @MainActor final class Fixture {
        let profile: RuntimeIsolationProfile
        let settings: SettingsCenter
        let bridge: BridgeStore
        let sessionID = UUID()

        init(initialHistory: [LLMMessage]? = nil, legacyUnrelatedIntent: String? = nil) throws {
            profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "Compaction2669",
                processEnvironment: [:], processArguments: ["MinisCanvasAppTests.xctest"], canvasRuntimeState: .disabled)
            let defaults = profile.makeUserDefaults()
            let keychain = profile.makeKeychainStore()
            let sessions = SessionStore(directory: profile.sessionDirectory)
            var history: [LLMMessage] = []
            for option in 0..<18 {
                history.append(LLMMessage(role: .user, content: "Compare distinct option \(option), dependency \(option + 7)."))
                history.append(LLMMessage(role: .assistant, content: (0..<24).map { detail in
                    "Option \(option), consideration \(detail): cost \(option + detail + 2), dependency \(option * 7 - detail), coefficient \(option * 31 + detail) and fallback \(detail % 5) have distinct tradeoffs."
                }.joined(separator: " ")))
            }
            try sessions.updateSession(ChatSession(id: sessionID.uuidString, title: "owned compaction2669", messages: initialHistory ?? history))
            let badges = SessionBadgeStore(directory: profile.rootDirectory.appendingPathComponent("badges"))
            let readiness = ProviderReadinessStore(directory: profile.providerConfigurationDirectory)
            let accepted = readiness.upsert([ProviderReadinessPersistenceRecord(
                providerID: Dialogue.providerID, modelID: Dialogue.modelID, status: .passed, readinessState: .mock,
                checkedAt: Date(timeIntervalSince1970: 1_000), evidenceID: "readiness2669", isApplied: true,
                discoveryReceiptID: "discovery2669", discoveredAt: Date(timeIntervalSince1970: 1_000),
                applyReceiptID: "provider-readiness-apply:2669", appliedAt: Date(timeIntervalSince1970: 1_001))])
            guard accepted else { throw CocoaError(.fileWriteUnknown) }
            let shortcuts = ShortcutStore(defaults: defaults)
            settings = SettingsCenter(settingsStore: SettingsStore(directory: profile.settingsDirectory),
                envStore: EnvVarStore(directory: profile.providerConfigurationDirectory, keychain: keychain,
                    privacyStore: EnvVarPrivacyStore(defaults: defaults)),
                memoryStore: MemoryStore(directory: profile.memoryDirectory),
                memoryFileStore: MemoryFileStore(directory: profile.rootDirectory.appendingPathComponent("memory-files")),
                sessionStore: sessions, sessionBadgeStore: badges, logManager: profile.makeLogManager(),
                mcpManager: MCPServerManager(fileURL: profile.mcpConfigurationURL, keychain: keychain),
                skillStore: SkillStore(skillsRoot: profile.rootDirectory.appendingPathComponent("skills")),
                usageStore: UsageStore(domain: profile.usageStoreDefaultsDomain), shortcutStore: shortcuts,
                providerReadinessTransport: FailClosedProviderReadinessTransport(), providerReadinessDeployment: .mock,
                providerReadinessStore: readiness)
            bridge = BridgeStore(shortcutStore: shortcuts, preferencesDefaults: defaults,
                logManager: settings.logManager,
                workflowStore: WorkflowStore(storeDirectory: profile.rootDirectory.appendingPathComponent("workflows")),
                sessionBadgeStore: badges, sessionDocumentStore: SessionDocumentStore(directory: profile.sessionDirectory),
                canvasRuntimeState: .disabled,
                agentTaskStore: try AgentTaskStore(persistenceURL: profile.rootDirectory.appendingPathComponent("tasks2669.json")),
                contextManifestStore: try ContextManifestStore(persistenceURL: profile.rootDirectory.appendingPathComponent("manifest2669.json")),
                memoryStore: settings.memoryStore, memoryProposalConsumer: settings.memoryProposalConsumer,
                providerReadinessStore: readiness,
                taskCenterBindingPersistenceURL: profile.rootDirectory.appendingPathComponent("task-center2669.json"),
                canvasFeatureLane: .phase3NonCanvas,
                speechToolDirectObservationProvider: { _ in SpeechToolDirectObservations() })
            if let legacyUnrelatedIntent {
                // Reproduce only the older App's ordinary-intent stamp using
                // its existing sidecar schema before normal App attachment.
                let digest = SHA256.hash(data: Data(legacyUnrelatedIntent.utf8))
                    .map { String(format: "%02x", $0) }.joined()
                let legacy: [String: Any] = ["schemaVersion": ChatAttachmentPersistence.schemaVersion,
                    "sessions": [["sessionID": sessionID.uuidString,
                        "messages": [["messageIndex": 0, "contentDigest": digest,
                            "attachments": [], "trustedSessionReadIntent": legacyUnrelatedIntent]]]]]
                try JSONSerialization.data(withJSONObject: legacy).write(
                    to: ChatAttachmentPersistence.url(in: profile.sessionDirectory), options: .atomic)
            }
            #expect(bridge.chat.attachPersistence(sessions, badgeStore: badges))
        }
        // Observe the actual production turn after the bounded wait fails.
        // No runtime factory or authority is replaced to make the producer enter.
        func recordFirstEntryFailure(label: String) {
            let chat = bridge.chat
            let snapshot = chat.lastComposerSubmissionSnapshot
            let last = chat.messages.last
            let setupRecorded = last?.turnTiming?.phaseTimings.contains {
                $0.phase == .turnSetup
            } ?? false
            let policyRevisionMatches = snapshot?.policyRevision == chat.composerPolicyFacts.revision
            let grantEpochMatches = snapshot?.grantEpoch == chat.composerPolicyFacts.grantEpoch
            let policyCurrent = !chat.composerPolicyFacts.revoked && chat.composerPolicyFacts.expiresAt > Date()
            print("TASK2962_FIRST_ENTRY label=\(label) setupRecorded=\(setupRecorded) skillsReady=\(settings.skillStore.isInitialLoadComplete) policyRevisionMatches=\(policyRevisionMatches) grantEpochMatches=\(grantEpochMatches) policyCurrent=\(policyCurrent) invalidSettings=\(chat.lastSubmissionBlockedByInvalidSettings) activeStreaming=\(chat.isActiveSessionStreaming) terminal=\(last?.content ?? "<none>")")
        }

        func recordCheckpointFailure(label: String, summary: HeldSummary, dialogue: Dialogue) {
            let chat = bridge.chat
            let canonical = settings.sessionStore.loadSession(id: sessionID.uuidString)
            let local = chat.messages(forSession: sessionID)?.filter { $0.role != .system }
            let localRevision = chat.transcriptRevision(forSession: sessionID)
            let checkpoint = try? settings.sessionStore.loadLatestCompactionCheckpoint(sessionID: sessionID.uuidString)
            print("TASK2962_CHECKPOINT label=\(label) summaryCalls=\(summary.calls) summaryActive=\(summary.active) summaryExits=\(summary.exits) dialogue=\(dialogue.requests.count) canonicalRevision=\(String(describing: canonical?.transcriptRevision)) localRevision=\(String(describing: localRevision)) canonicalCount=\(canonical?.messages.count ?? -1) localCount=\(local?.count ?? -1) projectionEqual=\(canonical?.messages == local?.map { $0.asLLMMessage() }) checkpoint=\(checkpoint != nil) busy=\(chat.hasStreamingTasksForSafety) terminal=\(local?.last?.content ?? "<none>")")
        }

        func attach() async {
            await bridge.attachProductionServices(agentSettings: settings.settings.agent,
                fileAccessAllowedRoot: profile.rootDirectory, fileAccessDeniedRoots: [],
                sessionDirectory: profile.sessionDirectory, mcpManager: settings.mcpManager,
                skillStore: settings.skillStore, canvasRuntimeState: .disabled, externalRunners: [:],
                externalNetworkAllowed: true, sessionReadSecretStore: settings.envStore).value
        }
    }

    final class HeldSummary: LLMProvider, @unchecked Sendable {
        let name = "owned-summary2669"
        var model = LLMModel(id: "summary2669", displayName: "Owned summary", provider: "owned-summary2669")
        private let lock = NSLock()
        private let lateFailure: Bool
        private let summaryText: String
        private let summaryFailure: (any Error)?
        private var entered = 0
        private var activeCount = 0
        private var exited = 0
        private var released: Set<Int> = []
        private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
        var calls: Int { lock.withLock { entered } }
        var active: Int { lock.withLock { activeCount } }
        var exits: Int { lock.withLock { exited } }
        init(lateFailure: Bool,
             summaryText: String = "The assistant compared distinct options and recorded their costs, dependencies and fallback tradeoffs.",
             summaryFailure: (any Error)? = nil) {
            self.lateFailure = lateFailure
            self.summaryText = summaryText
            self.summaryFailure = summaryFailure
        }
        func release(_ ordinal: Int) {
            let waiter = lock.withLock {
                released.insert(ordinal)
                return waiters.removeValue(forKey: ordinal)
            }
            waiter?.resume()
        }
        func releaseAll() { release(1); release(2) }
        func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
            let ordinal = lock.withLock { entered += 1; activeCount += 1; return entered }
            defer { lock.withLock { activeCount -= 1; exited += 1 } }
            if ordinal <= 2 {
                await withCheckedContinuation { continuation in
                    let resume = lock.withLock {
                        if released.contains(ordinal) { return true }
                        waiters[ordinal] = continuation
                        return false
                    }
                    if resume { continuation.resume() }
                }
            }
            // This synthetic local producer deliberately does not inspect
            // Task.isCancelled. It is not evidence of a remote server exit.
            if ordinal == 1 && lateFailure {
                if let summaryFailure { throw summaryFailure }
                throw CocoaError(.coderInvalidValue)
            }
            return LLMResponse(text: summaryText, stopReason: "stop", usage: nil)
        }
        func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
            throw LLMError.unsupportedCapability(.streaming)
        }
    }

    final class Dialogue: AssistantStreamingLLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
        static let providerID = "dialogue2669"
        static let modelID = "dialogue-model2669"
        let name = Dialogue.providerID
        var model = LLMModel(id: Dialogue.modelID, displayName: "Owned dialogue", provider: Dialogue.providerID)
        var runtimeConfigurationMaterial: String? = "owned-runtime2669"
        let capabilities: Set<ProviderCapability> = [.tools]
        private let lock = NSLock()
        private var captured: [[LLMMessage]] = []
        private var capturedSummaries: [[LLMMessage]] = []
        private var capturedSystemPrompts: [String?] = []
        private let firstToolCall: LLMToolCall?
        private let failReply: Bool
        private let replyText: String
        private let replyUsage: LLMUsage?
        private var replyCompletionReleased = false
        private var replyCompletionWaiter: CheckedContinuation<Void, Never>?
        init(failReply: Bool = false, replyText: String = "CURRENT_REPLY_2669", replyUsage: LLMUsage? = nil,
             firstToolCall: LLMToolCall? = nil) {
            self.firstToolCall = firstToolCall
            self.failReply = failReply
            self.replyText = replyText
            self.replyUsage = replyUsage
        }
        func releaseReplyCompletion() {
            let waiter = lock.withLock {
                replyCompletionReleased = true
                defer { replyCompletionWaiter = nil }
                return replyCompletionWaiter
            }
            waiter?.resume()
        }
        var summaryRequests: [[LLMMessage]] { lock.withLock { capturedSummaries } }
        var requests: [[LLMMessage]] { lock.withLock { captured } }
        var systemPrompts: [String?] { lock.withLock { capturedSystemPrompts } }
        private func respond(_ messages: [LLMMessage], systemPrompt: String?) throws -> LLMResponse {
            let ordinal = lock.withLock {
                captured.append(messages)
                capturedSystemPrompts.append(systemPrompt)
                return captured.count
            }
            if ordinal == 1, let firstToolCall {
                return LLMResponse(text: "", stopReason: "tool_calls", usage: nil, toolCalls: [firstToolCall])
            }
            if failReply { throw CocoaError(.coderInvalidValue) }
            return LLMResponse(text: replyText, stopReason: "stop", usage: replyUsage)
        }
        func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
            // This fixture's buffered entry serves summaries; ordinary replies
            // enter through the tool-aware send/stream methods below.
            lock.withLock {
                captured.append(messages)
                capturedSummaries.append(messages)
                capturedSystemPrompts.append(systemPrompt)
            }
            if failReply { throw CocoaError(.coderInvalidValue) }
            return LLMResponse(text: "The assistant compared the supplied options, dependencies and constraints.",
                stopReason: "stop", usage: nil)
        }
        func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition], maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
            try respond(messages, systemPrompt: systemPrompt)
        }
        func streamAssistantMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition], maxTokens: Int, temperature: Double?) async throws -> AsyncThrowingStream<LLMAssistantStreamEvent, Error> {
            let response = try respond(messages, systemPrompt: systemPrompt)
            // The existing default fixtures keep their completed-only response path.
            guard replyUsage != nil else { return llmAssistantCompletedStream(response) }
            return AsyncThrowingStream { continuation in
                let task = Task { [self] in
                    continuation.yield(.textDelta(response.text))
                    await withCheckedContinuation { waiter in
                        let released = lock.withLock {
                            if replyCompletionReleased { return true }
                            replyCompletionWaiter = waiter
                            return false
                        }
                        if released { waiter.resume() }
                    }
                    do {
                        try Task.checkCancellation()
                        continuation.yield(.completed(response))
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
            throw LLMError.unsupportedCapability(.streaming)
        }
    }
}

private final class TruncatedToolUIProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var body: Data?
    nonisolated(unsafe) private static var capturedRequests: [URLRequest] = []

    static var requests: [URLRequest] { lock.withLock { capturedRequests } }

    static func reset(body: Data? = nil) {
        lock.withLock {
            Self.body = body
            capturedRequests.removeAll()
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = Self.lock.withLock {
            Self.capturedRequests.append(request)
            return Self.body
        }
        guard let body, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
