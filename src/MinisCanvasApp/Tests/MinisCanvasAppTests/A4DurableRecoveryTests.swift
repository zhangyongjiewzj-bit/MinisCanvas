import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("A4 durable transcript recovery")
@MainActor
struct A4DurableRecoveryTests {
    @Test("stale compaction snapshots cannot replace a newer transcript")
    func staleRevisionIsRejected() throws {
        let chat = ChatStore()
        let sessionID = try #require(chat.activeSessionID)
        let revision = try #require(chat.transcriptRevision(forSession: sessionID))
        let snapshot = chat.messages

        chat.appendUser("新消息")

        #expect(
            chat.setMessages(
                snapshot,
                forSession: sessionID,
                expectedTranscriptRevision: revision
            ) == false
        )
        #expect(chat.messages.contains { $0.content == "新消息" })
    }

    @Test("session bridge restores multimodal attachments and durable revision")
    func bridgeRoundTripPreservesRecoveryPayload() throws {
        let image = ChatAttachment(
            kind: .image,
            fileName: "cover.png",
            fileType: .image,
            mimeType: "image/png",
            data: try ComposerMediaFixtures589.png()
        )
        let audio = ChatAttachment(
            kind: .audio,
            fileName: "voice.wav",
            fileType: .audio,
            mimeType: "audio/wav",
            data: ComposerMediaFixtures589.wav
        )
        #expect(MediaPayloadValidation.failure(data: try #require(image.data), mimeType: "image/png") == nil)
        #expect(MediaPayloadValidation.audioFormat(try #require(audio.data)) == "wav")
        print("MEDIA633_A4 pngBytes=\(image.data?.count ?? 0) wavBytes=\(audio.data?.count ?? 0)")
        let toolCall = LLMToolCall(
            id: "call-a4-read",
            name: "file_read",
            rawArguments: #"{"path":"notes.md"}"#,
            arguments: ["path": "notes.md"]
        )
        let thread = ChatThread(
            title: "恢复",
            messages: [
                ChatMessageUI(
                    role: .user,
                    content: "请看附件",
                    attachments: [image, audio]
                ),
                ChatMessageUI(
                    role: .assistant,
                    content: "",
                    toolCalls: [toolCall]
                ),
                ChatMessageUI(
                    role: .assistant,
                    content: "读取完成",
                    toolCallID: "call-a4-read"
                )
            ],
            transcriptRevision: 7
        )

        let persisted = thread.asPersisted()
        let restored = persisted.asThread()

        #expect(persisted.transcriptRevision == 7)
        #expect(restored.transcriptRevision == 7)
        #expect(restored.messages.first?.attachments.map(\.kind) == [.image, .audio])
        #expect(restored.messages.first?.llmImages.first?.data == image.data)
        #expect(restored.messages.first?.llmAudios.first?.base64Data == audio.data?.base64EncodedString())
        #expect(restored.messages[1].toolCalls == [toolCall])
        #expect(restored.messages[2].toolCallID == "call-a4-read")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("a4-tool-call-restart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try SessionStore(directory: root).updateSession(persisted)
        let restarted = SessionStore(directory: root)
        let restoredFromStore = try #require(restarted.loadSession(id: persisted.id))
        let restartedThread = restoredFromStore.asThread()

        #expect(restartedThread.messages[1].toolCalls == [toolCall])
        #expect(restartedThread.messages[2].toolCallID == "call-a4-read")
    }

    @Test("persistence bootstrap is single-shot and exposes a ready gate")
    func persistenceAttachIsIdempotentlyRejectedAfterReady() {
        let chat = ChatStore()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("a4-attach-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(directory: root)

        #expect(chat.attachPersistence(store) == true)
        #expect(chat.isPersistenceReady)
        #expect(chat.attachPersistence(SessionStore(directory: root.appendingPathComponent("second"))) == false)
        #expect(chat.isPersistenceReady)
    }

    @Test("restart bootstrap reconciles a session created before attach instead of discarding it")
    func preAttachSessionSurvivesPersistenceBootstrap() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("a4-recovery10-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // 「进程 1」：正常启动装配后新建会话，随变更落盘（磁盘 = 欢迎壳 + durable）。
        let first = ChatStore()
        #expect(first.attachPersistence(SessionStore(directory: root)))
        let durableID = first.applyNewSession()

        // 「进程 2」启动竞态窗口：attachPersistence 完成前菜单/侧栏/深链新建
        // 的会话只能存在于内存（此刻 onSessionsChanged 未接线、sessionStore
        // 为 nil），它必然不在磁盘上——base 行为是磁盘快照把它整体覆盖掉。
        let restarted = ChatStore()
        let windowID = restarted.applyNewSession()
        #expect(!restarted.isPersistenceReady)
        #expect(!SessionStore(directory: root).listSessions().contains { $0.id == windowID.uuidString })

        #expect(restarted.attachPersistence(SessionStore(directory: root)))

        // RECOVERY-10：窗口期会话存活、保持活跃且即刻对账落盘；
        // 未触碰的 init 欢迎壳照旧被丢弃（磁盘 2 + 窗口 1 = 3，不多不少）。
        #expect(restarted.sessions.count == 3)
        #expect(restarted.sessions.contains { $0.id == windowID })
        #expect(restarted.sessions.contains { $0.id == durableID })
        #expect(restarted.sessions.first?.id == windowID)
        #expect(restarted.activeSessionID == windowID)
        let diskAfterAttach = SessionStore(directory: root).listSessions()
        #expect(diskAfterAttach.count == 3)
        #expect(diskAfterAttach.contains { $0.id == windowID.uuidString })
    }

    @Test("recovery preserves both durable and pre-attach transcript bodies across a fresh reload")
    func preAttachMessagesAndOldDurableMessagesSurviveTogether() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("a4-recovery10-two-bodies-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let badges = SessionBadgeStore(directory: root.appendingPathComponent("badges"))

        // The first process has already committed the old transcript.
        let oldProcess = ChatStore()
        #expect(oldProcess.attachPersistence(SessionStore(directory: root), badgeStore: badges))
        let oldID = oldProcess.applyNewSession()
        oldProcess.appendUser("旧会话已落盘的消息")
        let oldBeforeRecovery = try #require(SessionStore(directory: root).loadSession(id: oldID.uuidString))
        #expect(oldBeforeRecovery.asThread().messages.contains { $0.content == "旧会话已落盘的消息" })

        // A user creates and writes to a different session before the second
        // process attaches persistence; only the old transcript exists on disk.
        let recovering = ChatStore()
        let newID = recovering.applyNewSession()
        recovering.appendUser("恢复窗口中新建会话的消息")
        #expect(newID != oldID)
        #expect(SessionStore(directory: root).loadSession(id: newID.uuidString) == nil)
        #expect(recovering.activeSessionID == newID)

        #expect(recovering.attachPersistence(SessionStore(directory: root), badgeStore: badges))
        #expect(recovering.activeSessionID == newID)
        let mergedOld = try #require(recovering.messages(forSession: oldID))
        let mergedNew = try #require(recovering.messages(forSession: newID))
        #expect(mergedOld.filter { $0.role == .user }.map(\.content) == ["旧会话已落盘的消息"])
        #expect(mergedNew.filter { $0.role == .user }.map(\.content) == ["恢复窗口中新建会话的消息"])

        // Read through a new store and a new ChatStore, not the merged in-memory
        // array, so a lost body or a delayed non-durable merge fails here.
        let freshStore = SessionStore(directory: root)
        let oldReloaded = try #require(freshStore.loadSession(id: oldID.uuidString))
        let newReloaded = try #require(freshStore.loadSession(id: newID.uuidString))
        #expect(oldReloaded.asThread().messages.filter { $0.role == .user }.map(\.content) == ["旧会话已落盘的消息"])
        #expect(newReloaded.asThread().messages.filter { $0.role == .user }.map(\.content) == ["恢复窗口中新建会话的消息"])

        let freshChat = ChatStore()
        #expect(freshChat.attachPersistence(freshStore, badgeStore: badges))
        let freshOld = try #require(freshChat.messages(forSession: oldID))
        let freshNew = try #require(freshChat.messages(forSession: newID))
        #expect(freshOld.filter { $0.role == .user }.map(\.content) == ["旧会话已落盘的消息"])
        #expect(freshNew.filter { $0.role == .user }.map(\.content) == ["恢复窗口中新建会话的消息"])
    }

    @Test("bootstrap welcome touched inside the launch window is kept, untouched one is discarded")
    func preAttachTouchedWelcomeSurvives() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("a4-recovery10-welcome-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = ChatStore()
        #expect(first.attachPersistence(SessionStore(directory: root)))
        first.applyNewSession()

        // 窗口期用户在启动欢迎会话里发消息：该会话已不是纯欢迎壳，
        // 装配后这条用户消息必须仍在内存与磁盘，而不是被快照静默吞掉。
        let restarted = ChatStore()
        let welcomeID = try #require(restarted.activeSessionID)
        restarted.appendUser("窗口期用户消息")
        #expect(restarted.attachPersistence(SessionStore(directory: root)))

        let mergedWelcome = try #require(
            restarted.sessions.first { $0.id == welcomeID }
        )
        #expect(mergedWelcome.messages.contains { $0.content == "窗口期用户消息" })
        #expect(restarted.sessions.count == 3)
        #expect(restarted.activeSessionID == welcomeID)
        let diskAfterAttach = SessionStore(directory: root).listSessions()
        #expect(diskAfterAttach.contains { $0.id == welcomeID.uuidString })
        let reloadedWelcome = try #require(
            diskAfterAttach.first { $0.id == welcomeID.uuidString }
        )
        #expect(reloadedWelcome.messages.contains { $0.content == "窗口期用户消息" })
    }
}

@Suite("Media633 invalid legacy audio projection negative")
@MainActor
struct A4InvalidMediaProjection633Tests {
    @Test func bareRIFFDoesNotBecomeRecoveredAudioPayload() {
        let header = Data([0x52, 0x49, 0x46, 0x46])
        let invalid = ChatAttachment(kind: .audio, fileName: "voice.wav", fileType: .audio,
            mimeType: "audio/wav", data: header)
        let thread = ChatThread(messages: [.init(role: .user, content: "owned invalid audio", attachments: [invalid])])
        #expect(invalid.data == header)
        #expect(invalid.audioAttachment == nil)
        #expect(thread.messages[0].attachments == [invalid])
        let persisted = thread.asPersisted()
        #expect(persisted.messages[0].audios.isEmpty)
        #expect(persisted.asThread().messages[0].llmAudios.isEmpty)
    }
}
