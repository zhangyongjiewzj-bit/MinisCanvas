import Foundation
import MinisCore

/// 一次进行中的转写。token 用来丢弃被取消、被新一次转写取代的旧任务的收尾。
struct AudioTranscriptionRun {
    let token: UUID
    let task: Task<Void, Never>
}

/// 图片文字识别 / 视频音轨转写的草稿状态（按附件 id）。
enum AttachmentTextRecognitionState: Equatable, Sendable {
    case running
    case done(String)
    case failed(String)

    var text: String? {
        if case .done(let text) = self { return text }
        return nil
    }
}

extension ChatStore {
    var audioTranscriptionDefaultLocaleID: String {
        AudioTranscriptionLanguages.defaultLocaleID(generalLanguage: audioTranscriptionGeneralLanguage)
    }

    /// 开始（或重试）转写草稿里的一个音频附件。
    /// `allowOnline` 只在用户明确同意“音频发送给 Apple 在线识别”后才为 true。
    func startAudioTranscription(id: UUID, localeID: String? = nil, allowOnline: Bool = false) {
        guard audioTranscriptionRuns[id] == nil,
              let attachment = pendingAttachments.first(where: { $0.id == id }),
              attachment.kind == .audio, attachment.status == .ready,
              let data = attachment.data else { return }
        let sessionID = activeSessionID
        let locale = localeID ?? audioTranscriptionStates[id]?.localeID
            ?? attachment.audioTranscript?.localeIdentifier ?? audioTranscriptionDefaultLocaleID
        let token = UUID()
        audioTranscriptionStates[id] = AudioTranscriptionUIState(
            phase: .running(done: 0, total: 0), localeID: locale)
        let progress: AudioTranscriber.Progress = { [weak self] done, total in
            Task { @MainActor in
                self?.noteAudioTranscriptionProgress(id: id, token: token, done: done, total: total)
            }
        }
        let task = Task { [weak self] in
            let result: Result<AudioTranscript, Error>
            do {
                result = .success(try await AudioTranscriber.transcribe(
                    data: data, localeID: locale, allowOnline: allowOnline, progress: progress))
            } catch {
                result = .failure(error)
            }
            self?.finishAudioTranscription(
                id: id, token: token, sessionID: sessionID, localeID: locale, result: result)
        }
        audioTranscriptionRuns[id] = AudioTranscriptionRun(token: token, task: task)
    }

    /// 取消进行中的转写并清掉该附件的转写状态（已转好的文字不动）。
    func cancelAudioTranscription(id: UUID) {
        audioTranscriptionRuns[id]?.task.cancel()
        audioTranscriptionRuns[id] = nil
        audioTranscriptionStates[id] = nil
    }

    /// 切换识别语言后重新转写（会覆盖已有文字，包括用户改过的）。
    func restartAudioTranscription(id: UUID, localeID: String) {
        cancelAudioTranscription(id: id)
        startAudioTranscription(id: id, localeID: localeID)
    }

    /// 用户同意把这段音频交给 Apple 在线识别。
    func approveOnlineAudioTranscription(id: UUID) {
        let locale = audioTranscriptionStates[id]?.localeID
        cancelAudioTranscription(id: id)
        startAudioTranscription(id: id, localeID: locale, allowOnline: true)
    }

    /// 用户不同意联网识别：不转写，音频不会离开本机。
    func declineOnlineAudioTranscription(id: UUID) {
        let locale = audioTranscriptionStates[id]?.localeID ?? audioTranscriptionDefaultLocaleID
        audioTranscriptionStates[id] = AudioTranscriptionUIState(
            phase: .failed("未同意联网识别，音频没有离开本机，也没有转写。可换一种本机支持的语言重试，或改用支持音频的模型。"),
            localeID: locale)
    }

    /// 保存用户修改后的转写文字；空文字不保存。
    func setAudioTranscriptText(id: UUID, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutatePendingAudio(id: id, sessionID: activeSessionID) { attachment in
            guard var transcript = attachment.audioTranscript, transcript.text != trimmed else { return }
            transcript.text = trimmed
            transcript.edited = true
            attachment.audioTranscript = transcript
        }
    }

    /// 草稿里被所选模型拦下的音频自动在本机转写；失败后不自动重试，等用户点“重试”。
    func autoTranscribeAudioDraftsIfNeeded() {
        for item in composerMediaReadinessSnapshot.attachments where item.audioTranscribable {
            guard audioTranscriptionStates[item.attachmentID] == nil,
                  audioTranscriptionRuns[item.attachmentID] == nil,
                  pendingAttachments.first(where: { $0.id == item.attachmentID })?.audioTranscript == nil
            else { continue }
            startAudioTranscription(id: item.attachmentID)
        }
        autoRecognizeImageAndVideoTextIfNeeded()
    }

    // MARK: 图片文字识别 / 视频音轨转写（模型看不到图、听不到音轨时的文字兜底）

    /// 图片文字识别用的 MIME 标记（正文已带“[图片文字识别：…]”头）。
    nonisolated static let imageTextMimeType = "text/x-image-text"

    /// 模型看不到图片：已有识别出的文字就换成只含文字的文本附件（不改草稿里的原图），并说明只附了文字。
    nonisolated static func imageTextSubstitution(
        _ attachment: ChatAttachment, supported: ModelModality, recognizedText: String?
    ) -> (attachment: ChatAttachment, note: String)? {
        guard attachment.kind == .image, attachment.status == .ready,
              !supported.contains(.imageInput),
              let text = recognizedText, !text.isEmpty else { return nil }
        var body = "[图片文字识别：\(attachment.fileName)]\n"
            + "（当前模型看不到图片，这里只附了本机识别出的文字，可能有误，也不包含图中的图形、颜色等内容。）\n"
            + text
        if let path = attachment.fileURL { body += "\n（来源路径：\(path)。）" }
        let substitute = ChatAttachment(
            id: attachment.id, kind: .text, fileName: attachment.fileName, fileType: attachment.fileType,
            mimeType: imageTextMimeType, size: Int64(body.utf8.count),
            data: Data(body.utf8), fileURL: nil, status: .ready)
        return (substitute, "当前模型看不到图片，只附了本机识别出的图中文字，没有发送图片本身。")
    }

    /// 草稿里被所选模型拦下的图片自动在本机识别文字；视频的音轨模型收不了时自动转写。
    /// 识别和转写都在后台线程做，失败后不自动重试。
    private func autoRecognizeImageAndVideoTextIfNeeded() {
        for item in composerMediaReadinessSnapshot.attachments where item.imageTextRecognizable {
            startImageTextRecognition(id: item.attachmentID)
        }
        let source = pendingAttachments
        guard source.contains(where: {
            $0.fileType == .video && $0.videoContext?.audio?.data != nil
                && attachmentTextRecognitionStates[$0.id] == nil
        }) else { return }
        let adapted = composerAdaptedPendingAttachments
        guard adapted.count == source.count else { return }
        for (original, current) in zip(source, adapted) {
            // 只在“音轨被去掉、画面仍保留”时转写；模型本身能收音轨、或视频已改成路径引用时不处理。
            guard original.fileType == .video, original.videoContext?.audio?.data != nil,
                  current.videoFrames != nil, current.videoContext?.audio == nil else { continue }
            startVideoTrackTranscription(video: original)
        }
    }

    /// 附件被移除或草稿清空时取消识别/转写并清状态。
    func cancelAttachmentTextRecognition(id: UUID) {
        attachmentTextRecognitionRuns[id]?.cancel()
        attachmentTextRecognitionRuns[id] = nil
        attachmentTextRecognitionStates[id] = nil
    }

    func startImageTextRecognition(id: UUID) {
        guard attachmentTextRecognitionStates[id] == nil,
              let attachment = pendingAttachments.first(where: { $0.id == id }),
              attachment.kind == .image, attachment.status == .ready,
              let data = attachment.data else { return }
        attachmentTextRecognitionStates[id] = .running
        let image = LLMMessage.ImageAttachment(mimeType: attachment.mimeType ?? "image/png", data: data)
        attachmentTextRecognitionRuns[id] = Task { [weak self] in
            // Vision 识别在 recognizeText 内部的后台任务里执行，不占主线程。
            let text = await ToolResultImageChannel.recognizeText(in: [image])
            self?.finishImageTextRecognition(id: id, text: text)
        }
    }

    private func finishImageTextRecognition(id: UUID, text: String) {
        guard attachmentTextRecognitionRuns[id] != nil else { return }
        attachmentTextRecognitionRuns[id] = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        attachmentTextRecognitionStates[id] = trimmed.isEmpty
            ? .failed("当前模型看不到图片，本机也没有从图里识别出文字。请换支持图片的模型，或移除这张图后发送。")
            : .done(trimmed)
    }

    func startVideoTrackTranscription(video: ChatAttachment) {
        let id = video.id
        guard attachmentTextRecognitionStates[id] == nil,
              let data = video.videoContext?.audio?.data else { return }
        let sessionID = activeSessionID
        let locale = audioTranscriptionDefaultLocaleID
        let fileName = video.fileName
        attachmentTextRecognitionStates[id] = .running
        attachmentTextRecognitionRuns[id] = Task { [weak self] in
            let result: Result<AudioTranscript, Error>
            do {
                // 默认只在本机识别；本机不支持该语言时不联网，如实说明“音轨未转写”。
                result = .success(try await AudioTranscriber.transcribe(
                    data: data, localeID: locale, allowOnline: false, progress: { _, _ in }))
            } catch {
                result = .failure(error)
            }
            self?.finishVideoTrackTranscription(id: id, sessionID: sessionID, fileName: fileName, result: result)
        }
    }

    private func finishVideoTrackTranscription(
        id: UUID, sessionID: UUID?, fileName: String, result: Result<AudioTranscript, Error>
    ) {
        guard attachmentTextRecognitionRuns[id] != nil else { return }
        attachmentTextRecognitionRuns[id] = nil
        func fail(_ reason: String) {
            attachmentTextRecognitionStates[id] = .failed(reason)
            if activeSessionID == sessionID {
                noteComposerInputFeedback("视频「\(fileName)」的音轨未转写：\(reason)")
            }
        }
        switch result {
        case .success(let transcript):
            guard transcript.hasContent else { fail("没有识别出文字。"); return }
            let body = AudioTranscriptFormat.modelText(
                fileName: "\(fileName) 的音轨", durationSeconds: transcript.durationSeconds, body: transcript.text)
            var text = ChatAttachment(
                kind: .text, fileName: "\(fileName) 音轨转写", fileType: .audio,
                mimeType: Self.audioTranscriptMimeType, size: Int64(body.utf8.count),
                data: Data(body.utf8), fileURL: nil, status: .ready)
            text.audioTranscript = transcript
            attachmentTextRecognitionStates[id] = .done(transcript.text)
            insertComposerAttachments([text], after: id, sessionID: sessionID)
            if activeSessionID == sessionID {
                noteComposerInputFeedback("当前模型听不到音轨，已把视频「\(fileName)」的音轨转写成文字，作为下一条附件一起发送。")
            }
        case .failure(let error):
            if error is CancellationError {
                attachmentTextRecognitionStates[id] = nil
            } else if let failure = error as? AudioTranscriptionFailure {
                fail(failure == .onlineConsentRequired
                    ? "本机不支持识别这种语言，未联网识别。" : failure.userMessage)
            } else {
                fail(AudioTranscriptionFailure.recognitionFailed.userMessage)
            }
        }
    }

    /// 发送门上给用户看的原因（音频被拦、尚无文字时）。
    func audioTranscriptionBlockReason(for attachment: ChatAttachment, modelName: String) -> String {
        guard let state = audioTranscriptionStates[attachment.id] else {
            return "\(modelName) 无法直接接收这段音频（模型不支持音频输入，或音频超过 25 MB）。点“转为文字”在本机识别后发送，或更换支持音频的模型，或移除附件。"
        }
        switch state.phase {
        case .running(let done, let total):
            return total > 0
                ? "正在本机转写（第 \(done)/\(total) 段），完成后即可发送（不会自动发送）"
                : "正在准备转写，完成后即可发送（不会自动发送）"
        case .needsOnlineConsent:
            return "本机不支持识别这种语言。需要你在附件卡片上选择是否同意联网识别；不同意则无法发送此音频。"
        case .failed(let message):
            return message
        }
    }

    private func noteAudioTranscriptionProgress(id: UUID, token: UUID, done: Int, total: Int) {
        guard audioTranscriptionRuns[id]?.token == token,
              var state = audioTranscriptionStates[id] else { return }
        state.phase = .running(done: done, total: total)
        audioTranscriptionStates[id] = state
    }

    private func finishAudioTranscription(
        id: UUID, token: UUID, sessionID: UUID?, localeID: String, result: Result<AudioTranscript, Error>
    ) {
        guard audioTranscriptionRuns[id]?.token == token else { return }
        audioTranscriptionRuns[id] = nil
        func fail(_ phase: AudioTranscriptionUIState.Phase) {
            audioTranscriptionStates[id] = AudioTranscriptionUIState(phase: phase, localeID: localeID)
        }
        switch result {
        case .success(let transcript):
            guard transcript.hasContent else {
                fail(.failed("没有识别出文字。可换一种语言重试，或改用支持音频的模型。"))
                return
            }
            audioTranscriptionStates[id] = nil
            mutatePendingAudio(id: id, sessionID: sessionID) { $0.audioTranscript = transcript }
        case .failure(let error):
            if error is CancellationError {
                audioTranscriptionStates[id] = nil
            } else if let failure = error as? AudioTranscriptionFailure {
                fail(failure == .onlineConsentRequired ? .needsOnlineConsent : .failed(failure.userMessage))
            } else {
                fail(.failed(AudioTranscriptionFailure.recognitionFailed.userMessage))
            }
        }
    }
}
