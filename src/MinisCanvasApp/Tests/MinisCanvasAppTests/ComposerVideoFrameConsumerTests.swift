import CoreGraphics
import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private struct ComposerSyntheticVideoSource: MediaVideoFrameSource {
    let failingTime: Double?

    func durationSeconds() async throws -> Double { 6 }

    func pngFrame(at seconds: Double, maxPixelSize: Int) async throws -> MediaVideoFrameSample {
        guard maxPixelSize == 768 else { throw MediaVideoExtractionFailure.invalidLimits }
        if seconds == failingTime { throw MediaVideoExtractionFailure.unreadableSource }
        let index = Int(seconds)
        guard [1, 3, 5].contains(index), Double(index) == seconds else {
            throw MediaVideoExtractionFailure.invalidTime
        }
        return MediaVideoFrameSample(
            pngData: try ComposerMediaFixtures589.png(color: CGFloat(index) / 6),
            actualSeconds: seconds + 0.125,
            pixelWidth: 8,
            pixelHeight: 8
        )
    }
}

@Suite("D-MULTIMODAL-06 App video frame consumer")
@MainActor
struct ComposerVideoFrameConsumerTests {
    private let fixtureURL = URL(fileURLWithPath: "/synthetic/composer-frames.mp4")

    private func providerRequestMessages(_ messages: [LLMMessage]) async throws -> [[String: Any]] {
        let host = "owned-video-\(UUID().uuidString.lowercased()).invalid"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VideoOwnedRequestProtocol.self]
        let provider = OpenAICompatibleProvider(
            apiKey: "offline-test-only",
            model: LLMModel(id: "owned-video", displayName: "Owned Video",
                provider: "Synthetic", modalityOverride: .vision),
            customBaseURL: "https://\(host)",
            session: URLSession(configuration: configuration)
        )
        defer { VideoOwnedRequestProtocol.forget(host: host) }
        _ = try await provider.sendMessage(
            messages: messages, systemPrompt: nil, maxTokens: 128, temperature: nil
        )
        let body = try #require(VideoOwnedRequestProtocol.body(for: host))
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        return try #require(json["messages"] as? [[String: Any]])
    }

    private func resolved(failingTime: Double? = nil, name: String = "composer-frames.mp4") async -> ChatAttachment {
        await ChatStore.resolveVideoAttachment(
            id: UUID(), url: fixtureURL, name: name,
            mime: "video/mp4", size: nil,
            source: ComposerSyntheticVideoSource(failingTime: failingTime)
        )
    }

    @Test("bounded local frames retain actual times and pass only through imageInput")
    func framePayloadAndModelGate() async throws {
        let attachment = await resolved()
        let frames = try #require(attachment.videoFrames)
        #expect(attachment.status == .ready)
        #expect(frames.map(\.requestedSeconds) == [1, 3, 5])
        #expect(frames.map(\.timecodeSeconds) == [1.125, 3.125, 5.125])
        #expect(frames.map(\.pixelWidth) == [8, 8, 8])
        #expect(frames.reduce(0) { $0 + ($1.pngData?.count ?? 0) } <= 2_097_152)
        #expect(attachment.statusText?.contains("00:03.125") == true)
        #expect(ComposerAttachmentPresentation.status(for: attachment) == .sampledVideoFrames)
        let accessibility = ComposerAttachmentPresentation.accessibilityValue(for: attachment)
        #expect(accessibility.contains("00:01.125"))
        #expect(accessibility.contains("00:05.125"))

        let content = ChatStore.composeUserContent(text: "只看这些抽出的静帧", attachments: [attachment])
        #expect(content.contains("第1帧 00:01.125"))
        #expect(content.contains("第3帧 00:05.125"))
        #expect(content.contains("音轨、字幕及完整视频未提取"))
        #expect(!content.contains(fixtureURL.path))
        let message = ChatMessageUI(role: .user, content: content, attachments: [attachment])
        let projected = message.asLLMMessage()
        #expect(projected.images.map(\.data) == frames.compactMap(\.pngData))
        #expect(projected.images.allSatisfy { $0.mimeType == "image/png" })
        #expect(projected.audios.isEmpty)

        let vision = ModelCapabilities(supportedModalities: .vision, supportedAuth: [.apiKey])
        let textOnly = ModelCapabilities(supportedModalities: .textOnly, supportedAuth: [.apiKey])
        let visionParts = OpenAICompatibleProvider.openAIMessageDict(
            projected, mediaCapabilities: vision
        )["content"] as? [[String: Any]]
        let textParts = OpenAICompatibleProvider.openAIMessageDict(
            projected, mediaCapabilities: textOnly
        )["content"] as? [[String: Any]]
        let visionImageCount = visionParts?.filter { $0["type"] as? String == "image_url" }.count ?? -1
        let textImageCount = textParts?.filter { $0["type"] as? String == "image_url" }.count ?? -1
        let textGateNoteCount = textParts?.filter {
            ($0["text"] as? String)?.contains("[media-gate]") == true
        }.count ?? -1
        #expect(visionImageCount == 3)
        #expect(textImageCount == 0)
        #expect(textGateNoteCount == 3)
    }

    @Test("the real attachment entry stays pending, upgrades in its own slot, and never auto-sends")
    func backgroundConsumerRetainsComposerOwner() async throws {
        let chat = ChatStore()
        chat.videoFrameSourceFactory = { _ in ComposerSyntheticVideoSource(failingTime: nil) }
        let owner = try #require(chat.activeSessionID)
        chat.draftText = "仅分析静帧"
        let staged = try #require(chat.addAttachments(urls: [fixtureURL]).first)
        #expect(staged.fileType == .video)
        #expect(staged.status == .pending)
        #expect(!chat.canSubmitComposerAttachments)
        chat.submitComposer()
        #expect(chat.messages.allSatisfy { $0.role != .user })
        for _ in 0..<100 where chat.pendingAttachments.first?.status == .pending {
            try await Task.sleep(for: .milliseconds(10))
        }
        let ready = try #require(chat.pendingAttachments.first)
        #expect(chat.activeSessionID == owner)
        #expect(ready.id == staged.id)
        #expect(ready.videoImageAttachments?.count == 3)
        #expect(chat.canSubmitComposerAttachments)
        #expect(chat.messages.allSatisfy { $0.role != .user })
        #expect(chat.draftText == "仅分析静帧")
    }

    @Test("a ready-looking video without verified PNG bytes cannot be submitted")
    func tamperedFramePayloadFailsClosed() async {
        let invalid = (await resolved()).sidecarProjection
        let chat = ChatStore()
        chat.addComposerDraftAttachment(invalid)
        #expect(!chat.canSubmitComposerAttachments)
        #expect(chat.composerAttachmentBlockReason != nil)
        #expect(ComposerAttachmentPresentation.status(for: invalid) == .videoSamplingFailed)
        #expect(invalid.videoImageAttachments == nil)
    }

    @Test("sidecar holds timecode metadata only and rebinds exact Core PNG slots")
    func restartRebindsOnlyMatchingPayload() async throws {
        let video = await resolved()
        let ordinaryImage = ChatAttachment(
            kind: .image, fileName: "still.png", fileType: .image,
            mimeType: "image/png", data: Data([1, 2, 3])
        )
        let composed = ChatStore.composeUserContentWithOwnership(
            text: "静帧比对", attachments: [ordinaryImage, video]
        )
        let content = composed.content
        let message = ChatMessageUI(role: .user, content: content,
            attachments: [ordinaryImage, video], composedContentOwnership: composed.ownership)
        let thread = ChatThread(messages: [message])
        let persisted = thread.asPersisted()
        let record = try #require(ChatAttachmentPersistence.records(for: thread).messages.first)
        #expect(record.attachments[1].videoFrames?.allSatisfy { $0.pngData == nil } == true)
        #expect(persisted.messages[0].images.count == 4)

        let reopened = ChatAttachmentPersistence.restoreAttachments(
            from: persisted, records: [record]
        )
        let restored = try #require(reopened.messages.first?.attachments.last)
        #expect(restored.id == video.id)
        #expect(restored.videoFrames?.map(\.timecodeSeconds) == [1.125, 3.125, 5.125])
        #expect(reopened.messages[0].asLLMMessage().images.map(\.data) == persisted.messages[0].images.map(\.data))
        #expect(reopened.messages[0].asLLMMessage().images.map(\.mimeType) == persisted.messages[0].images.map(\.mimeType))

        var reordered = persisted
        reordered.messages[0].images.swapAt(1, 2)
        let mismatched = ChatAttachmentPersistence.restoreAttachments(
            from: reordered, records: [record]
        )
        let failedVideo = try #require(mismatched.messages[0].attachments.last)
        #expect(failedVideo.status == .failed)
        #expect(failedVideo.videoImageAttachments == nil)
        #expect(mismatched.messages[0].asLLMMessage().images.map(\.data) == [Data([1, 2, 3])])
        let safeContent = mismatched.messages[0].asLLMMessage().content
        #expect(safeContent.contains("静帧与时间码恢复校验失败"))
        let retained = ChatStore.composeUserContent(text: "静帧比对", attachments: [ordinaryImage])
        #expect(safeContent == "视频 composer-frames.mp4 的静帧与时间码恢复校验失败；本轮不附加该视频画面，不能按原时间码判断视频内容。\n\n" + retained)
    }

    @Test("failed video sidecar cannot rewrite identical user-authored video text")
    func failedVideoPreservesFullIdenticalUserText() async throws {
        let video = await resolved()
        let description = try #require(video.sampledVideoDescription)
        let composed = ChatStore.composeUserContentWithOwnership(text: description, attachments: [video])
        let content = composed.content
        let thread = ChatThread(messages: [
            ChatMessageUI(role: .user, content: content, attachments: [video],
                composedContentOwnership: composed.ownership)
        ])
        var persisted = thread.asPersisted()
        let record = try #require(ChatAttachmentPersistence.records(for: thread).messages.first)
        let intact = ChatAttachmentPersistence.restoreAttachments(from: persisted, records: [record])
        #expect(intact.messages[0].attachments[0].status == .ready)
        #expect(intact.messages[0].asLLMMessage().content == content)
        let vision = ModelCapabilities(supportedModalities: .vision, supportedAuth: [.apiKey])
        let intactWire = OpenAICompatibleProvider.openAIMessageDict(
            intact.messages[0].asLLMMessage(), mediaCapabilities: vision
        )
        #expect((intactWire["content"] as? [[String: Any]])?
            .filter { $0["type"] as? String == "image_url" }.count == 3)
        let legacy = ChatAttachmentPersistence.MessageRecord(
            messageIndex: record.messageIndex, contentDigest: record.contentDigest,
            attachments: record.attachments
        )
        let legacyRejected = ChatAttachmentPersistence.restoreAttachments(
            from: persisted, records: [legacy]
        )
        #expect(legacyRejected.messages[0].attachments[0].status == .failed)
        #expect(legacyRejected.messages[0].asLLMMessage().images.isEmpty)
        #expect(legacyRejected.messages[0].asLLMMessage().content.hasSuffix(content))

        // The Core-owned first PNG no longer matches the sidecar. The original
        // description occurs twice: once in user text and once from compose.
        persisted.messages[0].images[0] = LLMMessage.ImageAttachment(
            mimeType: "image/png", data: Data([0x00])
        )
        let rejected = ChatAttachmentPersistence.restoreAttachments(from: persisted, records: [record])
        #expect(rejected.messages[0].attachments[0].status == .failed)
        #expect(rejected.messages[0].content == content)
        let projected = rejected.messages[0].asLLMMessage()
        #expect(projected.images.isEmpty)
        #expect(projected.content == "视频 composer-frames.mp4 的静帧与时间码恢复校验失败；本轮不附加该视频画面，不能按原时间码判断视频内容。\n\n" + description)
        #expect(projected.content.components(separatedBy: description).count == 2)

        // Exercise the ordinary durable consumer after restart and a new turn,
        // then capture the real Provider's serialized request with no network.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("video-failed-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(directory: root)
        try store.updateSession(persisted)
        try ChatAttachmentPersistence.save(sessions: [thread], to: root)
        let restarted = ChatStore()
        #expect(restarted.attachPersistence(SessionStore(directory: root)))
        #expect(restarted.activeSessionID == thread.id)
        #expect(restarted.messages.first?.attachments.first?.status == .failed)
        restarted.appendUser("继续对比已验证内容")
        let durable = try #require(store.loadSession(id: thread.id.uuidString))
        #expect(durable.messages.first?.images.isEmpty == true)
        #expect(durable.messages.first?.content == projected.content)
        let canonical = try ChatSessionBridge.resumeCanonicalMessages(
            sessionStore: store, sessionID: thread.id.uuidString
        )
        #expect(canonical.first?.images.isEmpty == true)
        #expect(canonical.first?.content == projected.content)
        #expect(canonical.last?.content == "继续对比已验证内容")
        let sent = try await providerRequestMessages(canonical)
        #expect(sent.first?["content"] as? String == projected.content)
        #expect(sent.first?["role"] as? String == "user")
        let reopenedAgain = ChatStore()
        #expect(reopenedAgain.attachPersistence(SessionStore(directory: root)))
        #expect(reopenedAgain.messages.first?.asLLMMessage().content == projected.content)
    }

    @Test("owned video reaches the next-turn Provider request only after exact restart rebind")
    func ownedVideoCanonicalProviderRequestPositive() async throws {
        let video = await resolved()
        let description = try #require(video.sampledVideoDescription)
        let composed = ChatStore.composeUserContentWithOwnership(
            text: description, attachments: [video]
        )
        let thread = ChatThread(messages: [.init(role: .user, content: composed.content,
            attachments: [video], composedContentOwnership: composed.ownership)])
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("video-owned-positive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(directory: root)
        try store.updateSession(thread.asPersisted())
        try ChatAttachmentPersistence.save(sessions: [thread], to: root)
        let reopened = ChatStore()
        #expect(reopened.attachPersistence(SessionStore(directory: root)))
        #expect(reopened.messages.first?.attachments.first?.status == .ready)
        reopened.appendUser("继续比较")
        let canonical = try ChatSessionBridge.resumeCanonicalMessages(
            sessionStore: store, sessionID: thread.id.uuidString
        )
        let prior = try #require(canonical.first)
        #expect(prior.content == composed.content)
        #expect(prior.images.count == 3)
        let sent = try await providerRequestMessages(canonical)
        let parts = try #require(sent.first?["content"] as? [[String: Any]])
        #expect(parts.filter { $0["type"] as? String == "image_url" }.count == 3)
        #expect(parts.contains { ($0["text"] as? String) == composed.content })
    }

    @Test("failed audio diagnostic preserves owned video across two reopens and actual wire")
    func mixedVideoAndFailedAudioKeepsVideoOwnership() async throws {
        let video = await resolved(name: "owned-video.mp4")
        let description = try #require(video.sampledVideoDescription)
        let wav = ComposerMediaFixtures589.wav
        let audio = ChatAttachment(kind: .audio, fileName: "voice.wav",
            fileType: .audio, mimeType: "audio/wav", data: wav)
        let userText = "用户原文逐字保留：" + description
        let composed = ChatStore.composeUserContentWithOwnership(
            text: userText, attachments: [video, audio]
        )
        let original = ChatThread(messages: [ChatMessageUI(role: .user,
            content: composed.content, attachments: [video, audio],
            composedContentOwnership: composed.ownership)])
        var otherWAV = wav
        otherWAV[otherWAV.count - 1] = 1
        #expect(MediaPayloadValidation.audioFormat(otherWAV) == "wav")
        let changedAudio = ChatAttachment(id: audio.id, kind: .audio,
            fileName: audio.fileName, fileType: .audio,
            mimeType: audio.mimeType, data: otherWAV)
        let changedSidecar = ChatThread(id: original.id,
            messages: [ChatMessageUI(role: .user, content: composed.content,
                attachments: [video, changedAudio],
                composedContentOwnership: composed.ownership)])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mixed-media-1771-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(directory: root)
        try store.updateSession(original.asPersisted())
        try ChatAttachmentPersistence.save(sessions: [changedSidecar], to: root)

        let firstDefaults = try #require(UserDefaults(
            suiteName: "mixed-media-first-\(UUID().uuidString)"))
        let first = ChatStore(preferencesDefaults: firstDefaults,
            logManager: LogManager(directory: root.appendingPathComponent("logs-first")))
        #expect(first.attachPersistence(SessionStore(directory: root)))
        #expect(first.messages.first?.attachments.map(\.status) == [.ready, .failed])
        #expect(first.messages.first?.asLLMMessage().images.count == 3)
        #expect(first.messages.first?.asLLMMessage().audios.isEmpty == true)
        first.appendUser("第一次续聊")
        let afterFirst = try #require(store.loadSession(id: original.id.uuidString))
        let projected = try #require(afterFirst.messages.first?.content)
        let audioNotice = "音频 voice.wav 的历史字节恢复校验失败；本轮未附加该音频，不能按原文的已附加说明判断其内容。"
        #expect(projected == audioNotice + "\n\n" + composed.content)
        #expect(afterFirst.messages.first?.images.count == 3)
        #expect(afterFirst.messages.first?.audios.isEmpty == true)
        let firstRecords = try ChatAttachmentPersistence.load(forSessionID: original.id.uuidString, from: root)
        let firstRecord = try #require(firstRecords?.first)
        #expect(firstRecord.messageIndex == 0)
        #expect(firstRecord.contentDigest == ChatComposedContentOwnership.digest(Data(projected.utf8)))
        #expect(firstRecord.composedContentOwnership != nil)

        let secondDefaults = try #require(UserDefaults(
            suiteName: "mixed-media-second-\(UUID().uuidString)"))
        let second = ChatStore(preferencesDefaults: secondDefaults,
            logManager: LogManager(directory: root.appendingPathComponent("logs-second")))
        #expect(second.attachPersistence(SessionStore(directory: root)))
        #expect(second.messages.first?.attachments.map(\.status) == [.ready, .failed])
        #expect(second.messages.first?.attachments.first?.videoImageAttachments?.count == 3)
        #expect(second.messages.first?.asLLMMessage().content == projected)
        second.appendUser("第二次续聊")
        let canonical = try ChatSessionBridge.resumeCanonicalMessages(
            sessionStore: store, sessionID: original.id.uuidString)
        #expect(canonical.first?.content == projected)
        #expect(canonical.first?.images.map(\.data) == original.asPersisted().messages.first?.images.map(\.data))
        #expect(canonical.first?.audios.isEmpty == true)
        let sent = try await providerRequestMessages(canonical)
        let parts = try #require(sent.first?["content"] as? [[String: Any]])
        let imageURLs = parts.compactMap { part in
            (part["image_url"] as? [String: String])?["url"]
        }
        #expect(imageURLs == original.asPersisted().messages[0].images.map {
            "data:image/png;base64," + $0.data.base64EncodedString()
        })
        #expect(parts.allSatisfy { $0["type"] as? String != "input_audio" })
        #expect(parts.contains { ($0["text"] as? String) == projected })
        #expect(projected.components(separatedBy: description).count == 3)
        #expect(!projected.contains(otherWAV.base64EncodedString()))
    }

    @Test("audio notice is the separator when original video message has no user body")
    func bodylessMixedVideoAndFailedAudioKeepsOwnedFrames() async throws {
        let video = await resolved(name: "bodyless.mp4")
        let wav = ComposerMediaFixtures589.wav
        let audio = ChatAttachment(kind: .audio, fileName: "bodyless.wav",
            fileType: .audio, mimeType: "audio/wav", data: wav)
        let composed = ChatStore.composeUserContentWithOwnership(
            text: "", attachments: [video, audio])
        let original = ChatThread(messages: [ChatMessageUI(role: .user,
            content: composed.content, attachments: [video, audio],
            composedContentOwnership: composed.ownership)])
        var changedBytes = wav
        changedBytes[changedBytes.count - 1] = 1
        let changedAudio = ChatAttachment(id: audio.id, kind: .audio,
            fileName: audio.fileName, fileType: .audio,
            mimeType: audio.mimeType, data: changedBytes)
        let changed = ChatThread(id: original.id,
            messages: [ChatMessageUI(role: .user, content: composed.content,
                attachments: [video, changedAudio],
                composedContentOwnership: composed.ownership)])
        let initialRecord = try #require(ChatAttachmentPersistence.records(for: changed).messages.first)
        let first = ChatAttachmentPersistence.restoreAttachments(
            from: original.asPersisted(), records: [initialRecord])
        #expect(first.messages[0].attachments.map(\.status) == [.ready, .failed])
        let rewrittenRecord = try #require(ChatAttachmentPersistence.records(for: first).messages.first)
        #expect(rewrittenRecord.composedContentOwnership != nil)
        let second = ChatAttachmentPersistence.restoreAttachments(
            from: first.asPersisted(), records: [rewrittenRecord])
        #expect(second.messages[0].attachments.map(\.status) == [.ready, .failed])
        #expect(second.messages[0].asLLMMessage().images.count == 3)
        #expect(second.messages[0].asLLMMessage().audios.isEmpty)
        #expect(second.messages[0].asLLMMessage().content == first.messages[0].asLLMMessage().content)
    }

    @Test("one mismatched video frame cannot relabel either video or matching user text")
    func multiVideoMismatchPreservesCanonicalBody() async throws {
        let first = await resolved(name: "first.mp4")
        let second = await resolved(name: "second.mp4")
        let secondDescription = try #require(second.sampledVideoDescription)
        let composed = ChatStore.composeUserContentWithOwnership(
            text: secondDescription, attachments: [first, second]
        )
        let content = composed.content
        let thread = ChatThread(messages: [
            ChatMessageUI(role: .user, content: content, attachments: [first, second],
                composedContentOwnership: composed.ownership)
        ])
        var persisted = thread.asPersisted()
        let record = try #require(ChatAttachmentPersistence.records(for: thread).messages.first)
        let intact = ChatAttachmentPersistence.restoreAttachments(from: persisted, records: [record])
        #expect(intact.messages[0].attachments.allSatisfy { $0.status == .ready })
        #expect(intact.messages[0].asLLMMessage().images.count == 6)

        persisted.messages[0].images[3] = LLMMessage.ImageAttachment(
            mimeType: "image/png", data: Data([0x00])
        )
        let rejected = ChatAttachmentPersistence.restoreAttachments(from: persisted, records: [record])
        #expect(rejected.messages[0].attachments.allSatisfy { $0.status == .failed })
        #expect(rejected.messages[0].content == content)
        let projected = rejected.messages[0].asLLMMessage()
        #expect(projected.images.isEmpty)
        let firstNotice = "视频 first.mp4 的静帧与时间码恢复校验失败；本轮不附加该视频画面，不能按原时间码判断视频内容。"
        let secondNotice = "视频 second.mp4 的静帧与时间码恢复校验失败；本轮不附加该视频画面，不能按原时间码判断视频内容。"
        #expect(projected.content == firstNotice + "\n" + secondNotice + "\n\n" + secondDescription)
        #expect(projected.content.components(separatedBy: secondDescription).count == 2)

        // The first sidecar now claims the second video's name. The claimed
        // full description occurs in user prose and in video two's part, but
        // neither is the producer-owned part for video one.
        var firstSidecar = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(record.attachments[0])
        ) as? [String: Any])
        firstSidecar["fileName"] = "second.mp4"
        let borrowed = try JSONDecoder().decode(ChatAttachment.self,
            from: JSONSerialization.data(withJSONObject: firstSidecar))
        let crossMatched = ChatAttachmentPersistence.MessageRecord(
            messageIndex: record.messageIndex, contentDigest: record.contentDigest,
            attachments: [borrowed, record.attachments[1]],
            composedContentOwnership: record.composedContentOwnership
        )
        let crossRejected = ChatAttachmentPersistence.restoreAttachments(
            from: thread.asPersisted(), records: [crossMatched]
        )
        #expect(crossRejected.messages[0].attachments.allSatisfy { $0.status == .failed })
        #expect(crossRejected.messages[0].asLLMMessage().images.isEmpty)
        #expect(crossRejected.messages[0].asLLMMessage().content
            .components(separatedBy: secondDescription).count == 2)
    }

    @Test("a changed frame-only sidecar timecode cannot borrow the sent PNG history")
    func restartRejectsChangedFrameOnlyTimecodeWithoutRelabelingOtherContent() async throws {
        let video = await resolved()
        let ordinaryImage = ChatAttachment(
            kind: .image, fileName: "still.png", fileType: .image,
            mimeType: "image/png", data: Data([1, 2, 3])
        )
        let userText = "用户原文：第1帧 00:01.125 是我自己的注释"
        let composed = ChatStore.composeUserContentWithOwnership(
            text: userText, attachments: [ordinaryImage, video]
        )
        let content = composed.content
        let thread = ChatThread(messages: [
            ChatMessageUI(role: .user, content: content, attachments: [ordinaryImage, video],
                composedContentOwnership: composed.ownership)
        ])
        let persisted = thread.asPersisted()
        let record = try #require(ChatAttachmentPersistence.records(for: thread).messages.first)
        let intact = ChatAttachmentPersistence.restoreAttachments(from: persisted, records: [record])
        #expect(intact.messages[0].attachments[1].status == .ready)
        #expect(intact.messages[0].asLLMMessage().images.map(\.data)
            == persisted.messages[0].images.map(\.data))
        #expect(intact.messages[0].asLLMMessage().content == persisted.messages[0].content)

        // The sidecar is the only owner of actual presentation times. Keep
        // its original PNG digests and Core image slots, changing just one
        // timecode as a malformed/replaced durable metadata record could.
        var sidecar = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(record.attachments[1])
        ) as? [String: Any])
        var frames = try #require(sidecar["videoFrames"] as? [[String: Any]])
        frames[0]["timecodeSeconds"] = 1.250
        sidecar["videoFrames"] = frames
        let alteredVideo = try JSONDecoder().decode(
            ChatAttachment.self, from: JSONSerialization.data(withJSONObject: sidecar)
        )
        let altered = ChatAttachmentPersistence.MessageRecord(
            messageIndex: record.messageIndex, contentDigest: record.contentDigest,
            attachments: [record.attachments[0], alteredVideo],
            composedContentOwnership: record.composedContentOwnership,
            referenceCard: record.referenceCard,
            trustedSessionReadIntent: record.trustedSessionReadIntent,
            turnTiming: record.turnTiming,
            sessionReferenceCard: record.sessionReferenceCard
        )
        let rejected = ChatAttachmentPersistence.restoreAttachments(from: persisted, records: [altered])
        #expect(rejected.messages[0].attachments[1].status == .failed)
        #expect(rejected.messages[0].attachments[1].videoImageAttachments == nil)
        let continuation = rejected.messages[0].asLLMMessage()
        #expect(continuation.images.map(\.data) == [Data([1, 2, 3])])
        #expect(continuation.content.hasPrefix("视频 composer-frames.mp4 的静帧与时间码恢复校验失败"))
        #expect(continuation.content.contains(userText))
        #expect(continuation.content.contains("我上传了图片 still.png"))
        #expect(!continuation.content.contains("第1帧 00:01.250"))
    }

    @Test("a late failure yields no partial batch and cannot replace another session or a sent slot")
    func failureAndOwnershipFences() async throws {
        let failure = await resolved(failingTime: 5)
        #expect(failure.status == .failed)
        #expect(failure.videoFrames == nil)
        #expect(failure.videoImageAttachments == nil)
        #expect(ComposerAttachmentPresentation.status(for: failure) == .videoSamplingFailed)

        let chat = ChatStore()
        let owner = try #require(chat.activeSessionID)
        let pending = ChatAttachment(
            id: failure.id, kind: .file, fileName: failure.fileName,
            fileType: .video, mimeType: failure.mimeType, fileURL: failure.fileURL,
            status: .pending
        )
        chat.draftText = "失败不能发送"
        chat.addComposerDraftAttachment(pending)
        chat.applyComposerAttachmentResolution(failure, sessionID: owner)
        #expect(!chat.canSubmitComposerAttachments)
        chat.submitComposer()
        #expect(chat.messages.allSatisfy { $0.role != .user })
        #expect(chat.draftText == "失败不能发送")

        let laterSuccess = await resolved()
        let sameIDSuccess = ChatAttachment(
            id: pending.id, kind: laterSuccess.kind,
            fileName: laterSuccess.fileName, fileType: laterSuccess.fileType,
            mimeType: laterSuccess.mimeType, fileURL: laterSuccess.fileURL,
            videoFrames: laterSuccess.videoFrames
        )
        chat.applyComposerAttachmentResolution(sameIDSuccess, sessionID: owner)
        #expect(chat.pendingAttachments == [failure])
        chat.removePendingAttachment(id: pending.id)
        // Retry through the production entry: a new selection owns a new ID.
        // The old callback must not bind to that otherwise identical URL.
        chat.videoFrameSourceFactory = { _ in ComposerSyntheticVideoSource(failingTime: nil) }
        let retry = try #require(chat.addAttachments(urls: [fixtureURL]).first)
        #expect(retry.status == .pending)
        #expect(retry.id != pending.id)
        let other = chat.applyNewSession(title: "synthetic other")
        chat.applyComposerAttachmentResolution(sameIDSuccess, sessionID: owner)
        #expect(chat.activeSessionID == other)
        #expect(chat.pendingAttachments.isEmpty)
        chat.switchSession(id: owner)
        #expect(chat.pendingAttachments == [retry])

        chat.removePendingAttachment(id: retry.id)
        chat.appendUser("已冻结", attachments: [sameIDSuccess])
        let sent = try #require(chat.messages.last(where: { $0.role == .user }))
        chat.applyComposerAttachmentResolution(failure, sessionID: owner)
        #expect(chat.messages.last(where: { $0.id == sent.id }) == sent)
    }

    @Test("cancelled extraction leaves a failed attachment without frame payloads")
    func cancellationDoesNotExposePartialFrames() async {
        let url = fixtureURL
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await ChatStore.resolveVideoAttachment(
                id: UUID(), url: url, name: "composer-frames.mp4",
                mime: "video/mp4", size: nil,
                source: ComposerSyntheticVideoSource(failingTime: nil)
            )
        }
        let cancelled = await task.value
        #expect(cancelled.status == .failed)
        #expect(cancelled.videoFrames == nil)
        #expect(cancelled.videoImageAttachments == nil)
    }
}

/// Captures the actual OpenAI-compatible HTTP request with a unique `.invalid`
/// host per test. URLSession never reaches DNS or a Provider service.
private final class VideoOwnedRequestProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var bodies: [String: Data] = [:]

    static func body(for host: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return bodies[host]
    }

    static func forget(host: String) {
        lock.lock(); defer { lock.unlock() }
        bodies.removeValue(forKey: host)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return host.hasPrefix("owned-video-") && host.hasSuffix(".invalid")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let host = request.url?.host, let body = Self.bodyData(from: request),
              let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        Self.lock.lock()
        Self.bodies[host] = body
        Self.lock.unlock()
        let result = Data(#"{"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}"#.utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            body.append(buffer, count: count)
        }
        return body
    }
}
