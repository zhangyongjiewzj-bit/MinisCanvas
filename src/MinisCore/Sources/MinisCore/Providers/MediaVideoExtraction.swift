import AVFoundation
import AudioToolbox
import CryptoKit
import Foundation
import ImageIO

/// The caller must choose all three per-request bounds. This Core primitive
/// does not select a model, a sampling policy, or an attachment budget.
public struct MediaVideoExtractionLimits: Equatable, Sendable {
    public let maxFrameCount: Int
    public let maxPixelSize: Int
    public let maxOutputBytes: Int

    public init(maxFrameCount: Int, maxPixelSize: Int, maxOutputBytes: Int) {
        self.maxFrameCount = maxFrameCount
        self.maxPixelSize = maxPixelSize
        self.maxOutputBytes = maxOutputBytes
    }

    var isValid: Bool {
        maxFrameCount > 0 && maxPixelSize > 0 && maxOutputBytes > 0
    }
}

/// A source returns PNG bytes and the actual presentation time, which may
/// differ from the requested time. The injectable boundary keeps tests local
/// and synthetic; the production implementation below uses AVFoundation.
public protocol MediaVideoFrameSource: Sendable {
    func durationSeconds() async throws -> Double
    func pngFrame(at seconds: Double, maxPixelSize: Int) async throws -> MediaVideoFrameSample
    /// Optional for existing injected frame-only sources. Production inspects
    /// only embedded tracks in the same explicitly selected local asset.
    func supplementaryContext(maxOutputBytes: Int) async -> MediaVideoSupplementaryContext?
}

public extension MediaVideoFrameSource {
    func supplementaryContext(maxOutputBytes: Int) async -> MediaVideoSupplementaryContext? { nil }
}

public enum MediaVideoTrackState: String, Codable, Sendable { case absent, extracted, unavailable }

public struct MediaVideoSubtitleCue: Codable, Equatable, Sendable {
    public let startSeconds: Double
    public let endSeconds: Double
    public let text: String
    public init(startSeconds: Double, endSeconds: Double, text: String) {
        self.startSeconds = startSeconds; self.endSeconds = endSeconds; self.text = text
    }
}

/// Core transcript owns WAV bytes. The App sidecar retains this time range,
/// count and digest, and restores bytes only from the exact Core audio slot.
public struct MediaVideoAudioTrack: Codable, Equatable, Sendable {
    public let startSeconds: Double
    public let endSeconds: Double
    public let byteCount: Int
    public let digest: String
    public let data: Data?
    public init(startSeconds: Double, endSeconds: Double, data: Data) {
        self.startSeconds = startSeconds; self.endSeconds = endSeconds
        self.byteCount = data.count; self.digest = Self.digest(data); self.data = data
    }
    private init(copy: Self, data: Data?) {
        startSeconds = copy.startSeconds; endSeconds = copy.endSeconds
        byteCount = copy.byteCount; digest = copy.digest; self.data = data
    }
    public func withPayload(_ data: Data?) -> Self { Self(copy: self, data: data) }
    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct MediaVideoSupplementaryContext: Codable, Equatable, Sendable {
    public let durationSeconds: Double
    public let audioState: MediaVideoTrackState
    public let subtitleState: MediaVideoTrackState
    public let audio: MediaVideoAudioTrack?
    public let subtitles: [MediaVideoSubtitleCue]
    public init(durationSeconds: Double, audioState: MediaVideoTrackState,
                subtitleState: MediaVideoTrackState, audio: MediaVideoAudioTrack?,
                subtitles: [MediaVideoSubtitleCue]) {
        self.durationSeconds = durationSeconds; self.audioState = audioState
        self.subtitleState = subtitleState; self.audio = audio; self.subtitles = subtitles
    }
    public func withAudioPayload(_ data: Data?) -> Self {
        Self(durationSeconds: durationSeconds, audioState: audioState, subtitleState: subtitleState,
             audio: audio?.withPayload(data), subtitles: subtitles)
    }
    public func isValid(maxOutputBytes: Int, requireAudioPayload: Bool = true) -> Bool {
        guard durationSeconds.isFinite, durationSeconds > 0, maxOutputBytes >= 0,
              (audioState == .extracted) == (audio != nil),
              (subtitleState == .extracted) == !subtitles.isEmpty else { return false }
        var remaining = maxOutputBytes
        if let audio {
            guard audio.startSeconds.isFinite, audio.startSeconds >= 0,
                  audio.endSeconds.isFinite, audio.endSeconds > audio.startSeconds,
                  audio.endSeconds <= durationSeconds, audio.byteCount > 44,
                  audio.byteCount <= remaining, audio.digest.count == 64 else { return false }
            if let data = audio.data {
                guard data.count == audio.byteCount, MediaVideoAudioTrack.digest(data) == audio.digest,
                      MediaPayloadValidation.failure(data: data, mimeType: "audio/wav") == nil else { return false }
            } else if requireAudioPayload { return false }
            remaining -= audio.byteCount
        }
        var previous = -Double.infinity
        for cue in subtitles {
            guard cue.startSeconds.isFinite, cue.startSeconds >= 0, cue.startSeconds >= previous,
                  cue.endSeconds.isFinite, cue.endSeconds > cue.startSeconds,
                  cue.endSeconds <= durationSeconds, !cue.text.isEmpty,
                  cue.text.utf8.count <= remaining else { return false }
            remaining -= cue.text.utf8.count; previous = cue.startSeconds
        }
        return true
    }
}

public struct MediaVideoFrameSample: Sendable {
    public let pngData: Data
    public let actualSeconds: Double
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(pngData: Data, actualSeconds: Double, pixelWidth: Int, pixelHeight: Int) {
        self.pngData = pngData
        self.actualSeconds = actualSeconds
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

public struct MediaVideoFrame: Equatable, Sendable {
    public let requestedSeconds: Double
    public let timecodeSeconds: Double
    public let pngData: Data
    public let pixelWidth: Int
    public let pixelHeight: Int
}

/// No case contains a source path, URL, decoder message, or payload bytes.
public enum MediaVideoExtractionFailure: Error, Equatable, Sendable {
    case invalidLimits
    case invalidDuration
    case invalidTime
    case duplicateTime
    case emptyResult
    case limitExceeded
    case unreadableSource
    case encodingFailed
    case cancelled
}

/// Bounded frame/timecode producer. A failure returns no partial frame batch;
/// callers may display a truthful path-only fallback but must never describe
/// this result as a viewed video until a separately gated consumer uses it.
public enum MediaVideoExtraction {
    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
    /// The shrink-and-retry ladder for an over-budget frame stops here.
    private static let minShrinkPixelSize = 192

    public static func extractFrames(
        from source: any MediaVideoFrameSource,
        requestedTimes: [Double],
        limits: MediaVideoExtractionLimits
    ) async -> Result<[MediaVideoFrame], MediaVideoExtractionFailure> {
        guard limits.isValid else { return .failure(.invalidLimits) }
        guard !requestedTimes.isEmpty else { return .failure(.emptyResult) }
        guard requestedTimes.count <= limits.maxFrameCount else {
            return .failure(.limitExceeded)
        }

        do {
            try Task.checkCancellation()
            let duration = try await source.durationSeconds()
            try Task.checkCancellation()
            guard duration.isFinite, duration > 0 else {
                return .failure(.invalidDuration)
            }

            var previousRequested: Double?
            for requested in requestedTimes {
                guard requested.isFinite, requested >= 0, requested < duration else {
                    return .failure(.invalidTime)
                }
                if let previousRequested {
                    if requested == previousRequested { return .failure(.duplicateTime) }
                    guard requested > previousRequested else { return .failure(.invalidTime) }
                }
                previousRequested = requested
            }

            var frames: [MediaVideoFrame] = []
            frames.reserveCapacity(requestedTimes.count)
            var remainingBytes = limits.maxOutputBytes
            var previousActual: Double?

            for (index, requested) in requestedTimes.enumerated() {
                try Task.checkCancellation()
                var sample = try await source.pngFrame(
                    at: requested, maxPixelSize: limits.maxPixelSize
                )
                try Task.checkCancellation()
                // A frame over its fair share of the remaining budget is
                // re-requested at a smaller size instead of failing the whole
                // video; unused budget carries to later frames.
                let share = remainingBytes / (requestedTimes.count - index)
                var shrunkenSize = limits.maxPixelSize
                while sample.pngData.count > share, shrunkenSize > minShrinkPixelSize {
                    shrunkenSize = max(minShrinkPixelSize, shrunkenSize * 7 / 10)
                    sample = try await source.pngFrame(at: requested, maxPixelSize: shrunkenSize)
                    try Task.checkCancellation()
                }
                guard sample.actualSeconds.isFinite,
                      sample.actualSeconds >= 0,
                      sample.actualSeconds <= duration else {
                    return .failure(.invalidTime)
                }
                if let previousActual {
                    // 画面不动的视频（例如系统录屏）相邻取样时刻会落在同一帧上：这一帧已经取过，
                    // 跳过而不是让整段视频失败；它占的份额留给后面的帧。
                    if sample.actualSeconds == previousActual { continue }
                    guard sample.actualSeconds > previousActual else {
                        return .failure(.invalidTime)
                    }
                }
                guard sample.pixelWidth > 0, sample.pixelHeight > 0,
                      sample.pixelWidth <= limits.maxPixelSize,
                      sample.pixelHeight <= limits.maxPixelSize else {
                    return .failure(.limitExceeded)
                }
                guard sample.pngData.starts(with: pngSignature) else {
                    return .failure(.encodingFailed)
                }
                guard sample.pngData.count <= remainingBytes else {
                    return .failure(.limitExceeded)
                }
                remainingBytes -= sample.pngData.count
                frames.append(MediaVideoFrame(
                    requestedSeconds: requested,
                    timecodeSeconds: sample.actualSeconds,
                    pngData: sample.pngData,
                    pixelWidth: sample.pixelWidth,
                    pixelHeight: sample.pixelHeight
                ))
                previousActual = sample.actualSeconds
            }
            try Task.checkCancellation()
            return .success(frames)
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch let failure as MediaVideoExtractionFailure {
            return .failure(failure)
        } catch {
            return .failure(.unreadableSource)
        }
    }
}

/// Local-file AVFoundation adapter. Constructing it does not read a video;
/// extraction happens only when a future admitted consumer calls the API.
public actor AVFoundationVideoFrameSource: MediaVideoFrameSource {
    private let asset: AVURLAsset

    public init(fileURL: URL) throws {
        guard fileURL.isFileURL else { throw MediaVideoExtractionFailure.unreadableSource }
        self.asset = AVURLAsset(url: fileURL)
    }

    public func durationSeconds() async throws -> Double {
        try Task.checkCancellation()
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard !tracks.isEmpty else { throw MediaVideoExtractionFailure.emptyResult }
        let duration = try await asset.load(.duration)
        try Task.checkCancellation()
        return CMTimeGetSeconds(duration)
    }

    public func supplementaryContext(maxOutputBytes: Int) async -> MediaVideoSupplementaryContext? {
        do {
            try Task.checkCancellation()
            let duration = try await durationSeconds()
            guard duration.isFinite, duration > 0, maxOutputBytes >= 0,
                  !(try await asset.load(.hasProtectedContent)) else { return nil }
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            let subtitleTracks = try await asset.loadTracks(withMediaType: .subtitle)
            let textTracks = try await asset.loadTracks(withMediaType: .text)
            let captionTracks = try await asset.loadTracks(withMediaType: .closedCaption)
            let legibleTracks = subtitleTracks + textTracks + captionTracks
            var remaining = maxOutputBytes
            var audio: MediaVideoAudioTrack?
            var audioState: MediaVideoTrackState = audioTracks.isEmpty ? .absent : .unavailable
            // Multiple audio tracks require an explicit selection; do not mix
            // different languages/channels or silently select one of them.
            if audioTracks.count == 1 {
                do {
                    // Cap long soundtracks at 16 kHz mono so they fit the byte
                    // budget; a track already at or below that stays as is.
                    let nativeRate = (try? await audioTracks[0].load(.formatDescriptions))?.first
                        .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate } ?? 0
                    let outputRate = nativeRate > 0 ? min(nativeRate, 16_000) : 16_000
                    audio = try readAudio(audioTracks[0], duration: duration, maxBytes: remaining, sampleRate: outputRate)
                    remaining -= audio?.byteCount ?? 0; audioState = .extracted
                } catch { audio = nil }
            }
            var cues: [MediaVideoSubtitleCue] = []
            var subtitleState: MediaVideoTrackState = legibleTracks.isEmpty ? .absent : .unavailable
            // As above, multiple subtitle languages are not auto-selected.
            if legibleTracks.count == 1 {
                do {
                    cues = try readSubtitles(legibleTracks[0], duration: duration, maxBytes: remaining)
                    subtitleState = cues.isEmpty ? .unavailable : .extracted
                } catch { cues = [] }
            }
            try Task.checkCancellation()
            let result = MediaVideoSupplementaryContext(durationSeconds: duration,
                audioState: audioState, subtitleState: subtitleState, audio: audio, subtitles: cues)
            return result.isValid(maxOutputBytes: maxOutputBytes) ? result : nil
        } catch { return nil }
    }

    private func readAudio(_ track: AVAssetTrack, duration: Double, maxBytes: Int, sampleRate targetRate: Double) throws -> MediaVideoAudioTrack {
        guard maxBytes > 44 else { throw MediaVideoExtractionFailure.limitExceeded }
        let reader = try AVAssetReader(asset: asset)
        // Mono and at most 16 kHz keep a long soundtrack inside the byte
        // budget (about 32 KB per second) instead of dropping it.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
            AVSampleRateKey: targetRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        guard reader.canAdd(output) else { throw MediaVideoExtractionFailure.unreadableSource }
        reader.add(output); reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 60000))
        guard reader.startReading() else { throw MediaVideoExtractionFailure.unreadableSource }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var pcm = Data(), rate: UInt32 = 0, channels: UInt16 = 0
        var firstTime: Double?, endTime = 0.0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let description = CMSampleBufferGetFormatDescription(sample),
                  let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
                  format.mFormatID == kAudioFormatLinearPCM, format.mBitsPerChannel == 16,
                  format.mSampleRate.isFinite, format.mSampleRate > 0,
                  format.mSampleRate.rounded() == format.mSampleRate,
                  format.mSampleRate <= Double(UInt32.max),
                  format.mChannelsPerFrame > 0, format.mChannelsPerFrame <= UInt32(UInt16.max / 2),
                  let block = CMSampleBufferGetDataBuffer(sample) else {
                throw MediaVideoExtractionFailure.unreadableSource
            }
            let sampleRate = UInt32(format.mSampleRate), count = Int(CMSampleBufferGetNumSamples(sample))
            let channelCount = UInt16(format.mChannelsPerFrame), alignment = Int(channelCount) * 2
            if rate == 0 { rate = sampleRate; channels = channelCount }
            guard rate == sampleRate, channels == channelCount, count > 0, count <= Int.max / alignment,
                  CMBlockBufferGetDataLength(block) == count * alignment else { throw MediaVideoExtractionFailure.encodingFailed }
            let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            guard pts.isFinite else { throw MediaVideoExtractionFailure.invalidTime }
            if pts >= duration || pts + Double(count) / Double(rate) <= 0 { continue }
            // Strip decoder preroll/trailing samples outside the asset range;
            // every retained sample keeps its actual presentation-time origin.
            let lower = max(0, Int(ceil(-pts * Double(rate))))
            let upper = duration - pts >= Double(count) / Double(rate)
                ? count : Int(floor((duration - pts) * Double(rate)))
            if upper <= lower { continue }
            let start = pts + Double(lower) / Double(rate)
            let end = pts + Double(upper) / Double(rate)
            guard start >= 0, end <= duration,
                  firstTime == nil || abs(start - endTime) <= 1 / Double(rate) else {
                throw MediaVideoExtractionFailure.invalidTime
            }
            let length = (upper - lower) * alignment
            guard length <= maxBytes - 44 - pcm.count else { throw MediaVideoExtractionFailure.limitExceeded }
            var bytes = Data(count: length)
            let status = bytes.withUnsafeMutableBytes { pointer in
                CMBlockBufferCopyDataBytes(block, atOffset: lower * alignment, dataLength: length, destination: pointer.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { throw MediaVideoExtractionFailure.encodingFailed }
            pcm.append(bytes); firstTime = firstTime ?? start; endTime = end
        }
        guard reader.status == .completed, let firstTime, !pcm.isEmpty else { throw MediaVideoExtractionFailure.emptyResult }
        let alignment = UInt32(channels) * 2
        guard rate <= UInt32.max / alignment, pcm.count <= Int(UInt32.max) - 36 else { throw MediaVideoExtractionFailure.limitExceeded }
        var wav = Data("RIFF".utf8)
        func u16(_ value: UInt16) { wav.append(contentsOf: [UInt8(value & 255), UInt8(value >> 8)]) }
        func u32(_ value: UInt32) { wav.append(contentsOf: [UInt8(value & 255), UInt8((value >> 8) & 255), UInt8((value >> 16) & 255), UInt8(value >> 24)]) }
        u32(UInt32(pcm.count) + 36); wav.append(Data("WAVEfmt ".utf8)); u32(16)
        u16(1); u16(channels); u32(rate); u32(rate * alignment); u16(UInt16(alignment)); u16(16)
        wav.append(Data("data".utf8)); u32(UInt32(pcm.count)); wav.append(pcm)
        return MediaVideoAudioTrack(startSeconds: firstTime, endSeconds: endTime, data: wav)
    }

    private func readSubtitles(_ track: AVAssetTrack, duration: Double, maxBytes: Int) throws -> [MediaVideoSubtitleCue] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { throw MediaVideoExtractionFailure.unreadableSource }
        reader.add(output)
        guard reader.startReading() else { throw MediaVideoExtractionFailure.unreadableSource }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var cues: [MediaVideoSubtitleCue] = [], remaining = maxBytes
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            // AVFoundation supplies zero-sample/no-data control buffers around
            // tx3g media samples. They have no cue or presentation-time payload.
            if CMSampleBufferGetNumSamples(sample) == 0, CMSampleBufferGetDataBuffer(sample) == nil { continue }
            guard let description = CMSampleBufferGetFormatDescription(sample),
                  CMFormatDescriptionGetMediaSubType(description) == kCMSubtitleFormatType_3GText,
                  let block = CMSampleBufferGetDataBuffer(sample) else { throw MediaVideoExtractionFailure.encodingFailed }
            let length = CMBlockBufferGetDataLength(block)
            guard length >= 2, length - 2 <= remaining else { throw MediaVideoExtractionFailure.limitExceeded }
            var bytes = Data(count: length)
            let status = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            guard status == kCMBlockBufferNoErr else { throw MediaVideoExtractionFailure.encodingFailed }
            let count = Int(bytes[0]) * 256 + Int(bytes[1])
            guard count <= length - 2, let text = String(data: bytes.subdata(in: 2..<2 + count), encoding: .utf8) else {
                throw MediaVideoExtractionFailure.encodingFailed
            }
            if text.isEmpty { continue } // tx3g empty samples mark cue gaps.
            let start = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            let end = start + CMTimeGetSeconds(CMSampleBufferGetDuration(sample))
            guard start.isFinite, start >= 0, end.isFinite, end > start, end <= duration,
                  cues.last.map({ start >= $0.startSeconds }) ?? true else { throw MediaVideoExtractionFailure.invalidTime }
            guard text.utf8.count <= remaining else { throw MediaVideoExtractionFailure.limitExceeded }
            remaining -= text.utf8.count
            cues.append(.init(startSeconds: start, endSeconds: end, text: text))
        }
        guard reader.status == .completed else { throw MediaVideoExtractionFailure.unreadableSource }
        return cues
    }

    public func pngFrame(
        at seconds: Double, maxPixelSize: Int
    ) async throws -> MediaVideoFrameSample {
        try Task.checkCancellation()
        guard maxPixelSize > 0 else {
            throw MediaVideoExtractionFailure.invalidLimits
        }
        guard seconds.isFinite, seconds >= 0 else {
            throw MediaVideoExtractionFailure.invalidTime
        }
        // Per-call generator prevents a concurrent actor re-entry from changing
        // another extraction's pixel bound while AVFoundation is suspended.
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(
            width: CGFloat(maxPixelSize), height: CGFloat(maxPixelSize)
        )
        let requested = CMTime(seconds: seconds, preferredTimescale: 600)
        let result = try await generator.image(at: requested)
        try Task.checkCancellation()

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, "public.png" as CFString, 1, nil
        ) else {
            throw MediaVideoExtractionFailure.encodingFailed
        }
        CGImageDestinationAddImage(destination, result.image, nil)
        guard CGImageDestinationFinalize(destination), output.length > 0 else {
            throw MediaVideoExtractionFailure.encodingFailed
        }
        try Task.checkCancellation()
        return MediaVideoFrameSample(
            pngData: output as Data,
            actualSeconds: CMTimeGetSeconds(result.actualTime),
            pixelWidth: result.image.width,
            pixelHeight: result.image.height
        )
    }
}
