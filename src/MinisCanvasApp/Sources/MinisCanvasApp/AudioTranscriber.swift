import AVFoundation
import Foundation
import MinisCore
import Speech

// 音频附件本机转写（系统语音识别，对文件识别）。
// 隐私：默认只在本机识别（requiresOnDeviceRecognition）；本机不支持该语言时，
// 只有用户在附件卡片上明确同意后才会把音频交给 Apple 在线识别。

enum AudioTranscriptionFailure: Error, Equatable, Sendable {
    case permissionDenied
    case recognizerUnavailable
    /// 本机不支持该语言的离线识别，需要用户同意联网识别。
    case onlineConsentRequired
    case decodeFailed
    case recognitionFailed

    var userMessage: String {
        switch self {
        case .permissionDenied:
            return "语音识别权限未开启，无法转写。请在 系统设置 → 隐私与安全性 → 语音识别 里允许本应用，然后点“重试”。"
        case .recognizerUnavailable:
            return "当前语言的语音识别暂不可用。请换一种语言，或检查网络后点“重试”。"
        case .onlineConsentRequired:
            return "本机不支持识别这种语言，需要联网识别。"
        case .decodeFailed:
            return "这段音频无法解码，可能已损坏或格式不受支持。请移除后重新添加，或换一个文件。"
        case .recognitionFailed:
            return "识别失败。请点“重试”；仍失败可换一种语言，或改用支持音频的模型。"
        }
    }
}

/// 一个音频附件的转写进度（只在草稿阶段存在）。
struct AudioTranscriptionUIState: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// total 为 0 表示还在准备（权限、解码、切段）。
        case running(done: Int, total: Int)
        case needsOnlineConsent
        case failed(String)
    }

    var phase: Phase
    var localeID: String
}

enum AudioTranscriptionLanguages {
    struct Option: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
    }

    /// 默认跟随 App 语言（与输入框麦克风同一套映射）；App 语言缺失时用中文。
    static func defaultLocaleID(generalLanguage: String?) -> String {
        (try? SpeechLocaleResolver.runtimeLanguage(for: generalLanguage)) ?? "zh-CN"
    }

    static func displayName(for localeID: String) -> String {
        let display = Locale(identifier: "zh-Hans")
        return display.localizedString(forIdentifier: localeID) ?? localeID
    }

    /// 系统支持的识别语言；中文、英文、日文排在最前。
    static func options() -> [Option] {
        let preferred = ["zh-CN", "en-US", "ja-JP"]
        var supported = Set(SFSpeechRecognizer.supportedLocales().map {
            $0.identifier.replacingOccurrences(of: "_", with: "-")
        })
        if supported.isEmpty { supported = Set(preferred) }
        let rest = supported.subtracting(preferred).sorted {
            displayName(for: $0).localizedCompare(displayName(for: $1)) == .orderedAscending
        }
        return (preferred.filter { supported.contains($0) } + rest).map {
            Option(id: $0, name: displayName(for: $0))
        }
    }
}

enum AudioTranscriber {
    typealias Progress = @Sendable (_ done: Int, _ total: Int) -> Void

    static let temporaryDirectoryPrefix = "MinisAudioTranscription-"

    /// 删除上次没来得及清理的转写临时目录（App 在转写中退出或崩溃时 defer 不会执行）。
    static func removeLeftoverTemporaryDirectories() {
        let manager = FileManager.default
        let root = manager.temporaryDirectory
        guard let names = try? manager.contentsOfDirectory(atPath: root.path) else { return }
        for name in names where name.hasPrefix(temporaryDirectoryPrefix) {
            try? manager.removeItem(at: root.appendingPathComponent(name, isDirectory: true))
        }
    }

    /// 转写一段已解码好的 WAV/MP3 字节。超过约 55 秒按时间切段逐段识别；
    /// 临时文件放在系统临时目录，结束（含取消、失败）后整个目录删除。
    static func transcribe(
        data: Data, localeID: String, allowOnline: Bool, progress: Progress
    ) async throws -> AudioTranscript {
        guard await authorize() else { throw AudioTranscriptionFailure.permissionDenied }
        guard let probe = SFSpeechRecognizer(locale: Locale(identifier: localeID)) else {
            throw AudioTranscriptionFailure.recognizerUnavailable
        }
        let route = AudioTranscriptionDecision.route(
            recognizerAvailable: probe.isAvailable,
            onDeviceSupported: probe.supportsOnDeviceRecognition
        )
        switch route {
        case .unavailable: throw AudioTranscriptionFailure.recognizerUnavailable
        case .requiresOnlineConsent:
            guard allowOnline else { throw AudioTranscriptionFailure.onlineConsentRequired }
        case .onDevice: break
        }
        let onDevice = route == .onDevice

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(temporaryDirectoryPrefix)\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent(
            "source.\(MediaPayloadValidation.audioFormat(data) ?? "wav")")
        let file: AVAudioFile
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: source)
            file = try AVAudioFile(forReading: source)
        } catch {
            throw AudioTranscriptionFailure.decodeFailed
        }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0, file.length > 0 else { throw AudioTranscriptionFailure.decodeFailed }
        let duration = Double(file.length) / sampleRate
        let plan = AudioTranscriptionPlan.segments(totalDuration: duration)
        guard !plan.isEmpty else { throw AudioTranscriptionFailure.decodeFailed }

        var pieces: [String] = []
        for segment in plan {
            try Task.checkCancellation()
            progress(segment.index + 1, plan.count)
            let url: URL
            if plan.count == 1 {
                url = source
            } else {
                url = directory.appendingPathComponent("segment-\(segment.index).caf")
                do {
                    try writeSegment(
                        from: file, segment: segment, isLast: segment.index == plan.count - 1, to: url)
                } catch {
                    throw AudioTranscriptionFailure.decodeFailed
                }
            }
            do {
                pieces.append(try await recognize(url: url, localeID: localeID, onDevice: onDevice))
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as AudioTranscriptionFailure {
                throw failure
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw AudioTranscriptionFailure.recognitionFailed
            }
            if plan.count > 1 { try? FileManager.default.removeItem(at: url) }
        }
        return AudioTranscript(
            text: AudioTranscriptFormat.joinSegments(pieces), localeIdentifier: localeID,
            durationSeconds: duration, onDevice: onDevice)
    }

    // MARK: 权限

    private static func authorize() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        @unknown default: return false
        }
    }

    // MARK: 切段

    /// 把源文件里 [start, start+duration) 的采样写成独立的临时 CAF 文件；最后一段读到文件末尾。
    private static func writeSegment(
        from file: AVAudioFile, segment: AudioTranscriptionPlan.Segment, isLast: Bool, to url: URL
    ) throws {
        let format = file.processingFormat
        let rate = format.sampleRate
        let startFrame = min(file.length, AVAudioFramePosition((segment.startSeconds * rate).rounded()))
        var remaining = isLast
            ? file.length - startFrame
            : min(file.length - startFrame, Int64((segment.durationSeconds * rate).rounded(.up)))
        guard remaining > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else {
            throw AudioTranscriptionFailure.decodeFailed
        }
        file.framePosition = startFrame
        let output = try AVAudioFile(forWriting: url, settings: format.settings)
        while remaining > 0 {
            let count = AVAudioFrameCount(min(Int64(buffer.frameCapacity), remaining))
            try file.read(into: buffer, frameCount: count)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
            remaining -= Int64(buffer.frameLength)
        }
    }

    // MARK: 识别一个文件

    private final class RecognitionTaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: SFSpeechRecognitionTask?
        private var cancelled = false
        private var finished = false

        func attach(_ task: SFSpeechRecognitionTask) {
            lock.lock()
            let alreadyCancelled = cancelled
            self.task = task
            lock.unlock()
            if alreadyCancelled { task.cancel() }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let current = task
            lock.unlock()
            current?.cancel()
        }

        /// 只有第一次调用返回 true，保证 continuation 只恢复一次。
        func claimFinish() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if finished { return false }
            finished = true
            return true
        }
    }

    nonisolated private static func makeRecognitionCallback(
        box: RecognitionTaskBox, continuation: CheckedContinuation<String, Error>
    ) -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            if let result, result.isFinal {
                let text = result.bestTranscription.formattedString
                if box.claimFinish() { continuation.resume(returning: text) }
            } else if let error {
                let nsError = error as NSError
                // 1110 = 没有检测到语音：当作空文本，由上层提示。
                let noSpeech = nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110
                if box.claimFinish() {
                    if noSpeech {
                        continuation.resume(returning: "")
                    } else {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    private static func recognize(url: URL, localeID: String, onDevice: Bool) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)) else {
            throw AudioTranscriptionFailure.recognizerUnavailable
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = onDevice
        request.taskHint = .dictation
        let box = RecognitionTaskBox()
        let text: String = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                let task = recognizer.recognitionTask(
                    with: request,
                    resultHandler: makeRecognitionCallback(box: box, continuation: continuation)
                )
                box.attach(task)
            }
        } onCancel: {
            box.cancel()
        }
        withExtendedLifetime(recognizer) {}
        try Task.checkCancellation()
        return text
    }
}
