import Foundation
import Testing
@testable import MinisCore

private struct SyntheticVideoFrameSource: MediaVideoFrameSource {
    let duration: Double
    let samples: [Double: MediaVideoFrameSample]
    let failingTime: Double?

    init(
        duration: Double = 2,
        samples: [Double: MediaVideoFrameSample] = [:],
        failingTime: Double? = nil
    ) {
        self.duration = duration
        self.samples = samples
        self.failingTime = failingTime
    }

    func durationSeconds() async throws -> Double { duration }

    func pngFrame(at seconds: Double, maxPixelSize: Int) async throws -> MediaVideoFrameSample {
        if let failingTime, seconds == failingTime {
            throw MediaVideoExtractionFailure.unreadableSource
        }
        guard let sample = samples[seconds] else {
            throw MediaVideoExtractionFailure.emptyResult
        }
        return sample
    }
}

private func syntheticSample(
    time: Double, bytes: Int = 8, width: Int = 2, height: Int = 2
) -> MediaVideoFrameSample {
    var png = Data([0x89, 0x50, 0x4E, 0x47])
    png.append(contentsOf: repeatElement(UInt8(0), count: max(0, bytes - 4)))
    return MediaVideoFrameSample(
        pngData: png, actualSeconds: time, pixelWidth: width, pixelHeight: height
    )
}

private func expectFailure(
    _ result: Result<[MediaVideoFrame], MediaVideoExtractionFailure>,
    _ expected: MediaVideoExtractionFailure
) {
    guard case .failure(let failure) = result else {
        Issue.record("Expected a typed, no-partial-batch failure")
        return
    }
    #expect(failure == expected)
}

@Suite("D-MULTIMODAL-06 bounded Core video frames")
struct MediaVideoExtractionTests {
    private let limits = MediaVideoExtractionLimits(
        maxFrameCount: 2, maxPixelSize: 64, maxOutputBytes: 16
    )

    @Test func requestedAndActualTimecodesRemainDistinctAndOrdered() async {
        let source = SyntheticVideoFrameSource(samples: [
            0.25: syntheticSample(time: 0.24),
            1.5: syntheticSample(time: 1.52)
        ])
        let result = await MediaVideoExtraction.extractFrames(
            from: source, requestedTimes: [0.25, 1.5], limits: limits
        )
        guard case .success(let frames) = result else {
            Issue.record("Synthetic frames should pass the bounded producer")
            return
        }
        #expect(frames.map(\.requestedSeconds) == [0.25, 1.5])
        #expect(frames.map(\.timecodeSeconds) == [0.24, 1.52])
        #expect(frames.map(\.pngData.count) == [8, 8])
        #expect(frames.allSatisfy { $0.pixelWidth == 2 && $0.pixelHeight == 2 })
    }

    @Test func callerMustSupplyPositiveBoundsAndFrameCountFits() async {
        let source = SyntheticVideoFrameSource()
        expectFailure(await MediaVideoExtraction.extractFrames(
            from: source, requestedTimes: [0.2],
            limits: .init(maxFrameCount: 0, maxPixelSize: 64, maxOutputBytes: 16)
        ), .invalidLimits)
        expectFailure(await MediaVideoExtraction.extractFrames(
            from: source, requestedTimes: [0.2],
            limits: .init(maxFrameCount: 1, maxPixelSize: 0, maxOutputBytes: 16)
        ), .invalidLimits)
        expectFailure(await MediaVideoExtraction.extractFrames(
            from: source, requestedTimes: [0.2],
            limits: .init(maxFrameCount: 1, maxPixelSize: 64, maxOutputBytes: 0)
        ), .invalidLimits)
        expectFailure(await MediaVideoExtraction.extractFrames(
            from: source, requestedTimes: [0.2, 0.4],
            limits: .init(maxFrameCount: 1, maxPixelSize: 64, maxOutputBytes: 16)
        ), .limitExceeded)
        expectFailure(await MediaVideoExtraction.extractFrames(
            from: source, requestedTimes: [], limits: limits
        ), .emptyResult)
    }

    @Test func durationAndTimesMustBeFiniteInRangeAndStrictlyOrdered() async {
        expectFailure(await MediaVideoExtraction.extractFrames(
            from: SyntheticVideoFrameSource(duration: .infinity),
            requestedTimes: [0.2], limits: limits
        ), .invalidDuration)
        let source = SyntheticVideoFrameSource()
        for invalid in [Double.nan, Double.infinity, -0.1, 2] {
            expectFailure(await MediaVideoExtraction.extractFrames(
                from: source, requestedTimes: [invalid], limits: limits
            ), .invalidTime)
        }
        expectFailure(await MediaVideoExtraction.extractFrames(
            from: source, requestedTimes: [0.2, 0.2], limits: limits
        ), .duplicateTime)
        expectFailure(await MediaVideoExtraction.extractFrames(
            from: source, requestedTimes: [0.4, 0.2], limits: limits
        ), .invalidTime)
    }

    @Test func outputBytesPixelsAndEncodingFailClosed() async {
        let tooManyPixels = SyntheticVideoFrameSource(samples: [
            0.2: syntheticSample(time: 0.2, width: 65)
        ])
        expectFailure(await MediaVideoExtraction.extractFrames(
            from: tooManyPixels, requestedTimes: [0.2], limits: limits
        ), .limitExceeded)

        let tooManyBytes = SyntheticVideoFrameSource(samples: [
            0.2: syntheticSample(time: 0.2, bytes: 9),
            0.4: syntheticSample(time: 0.4, bytes: 9)
        ])
        expectFailure(await MediaVideoExtraction.extractFrames(
            from: tooManyBytes, requestedTimes: [0.2, 0.4], limits: limits
        ), .limitExceeded)

        let malformedPNG = SyntheticVideoFrameSource(samples: [
            0.2: .init(
                pngData: Data("not a PNG".utf8),
                actualSeconds: 0.2, pixelWidth: 2, pixelHeight: 2
            )
        ])
        expectFailure(await MediaVideoExtraction.extractFrames(
            from: malformedPNG, requestedTimes: [0.2], limits: limits
        ), .encodingFailed)
    }

    /// M-08：画面不动的视频（系统录屏）相邻取样时刻取到同一帧时跳过重复帧，不再整段失败。
    @Test func sampleLandingOnTheSameFrameIsSkippedNotFatal() async {
        let source = SyntheticVideoFrameSource(samples: [
            0.2: syntheticSample(time: 0.2),
            0.4: syntheticSample(time: 0.2),
            0.8: syntheticSample(time: 0.8)
        ])
        let result = await MediaVideoExtraction.extractFrames(
            from: source, requestedTimes: [0.2, 0.4, 0.8],
            limits: MediaVideoExtractionLimits(maxFrameCount: 3, maxPixelSize: 64, maxOutputBytes: 24)
        )
        guard case .success(let frames) = result else {
            Issue.record("A repeated actual frame should be skipped, not fail the whole video")
            return
        }
        #expect(frames.map(\.requestedSeconds) == [0.2, 0.8])
        #expect(frames.map(\.timecodeSeconds) == [0.2, 0.8])
    }

    @Test func laterFailureAndInvalidActualTimesNeverReturnPartialFrames() async {
        let nonFiniteActual = SyntheticVideoFrameSource(samples: [
            0.2: syntheticSample(time: .nan)
        ])
        expectFailure(await MediaVideoExtraction.extractFrames(
            from: nonFiniteActual, requestedTimes: [0.2], limits: limits
        ), .invalidTime)

        let backwardsActual = SyntheticVideoFrameSource(samples: [
            0.2: syntheticSample(time: 0.4),
            0.6: syntheticSample(time: 0.3)
        ])
        expectFailure(await MediaVideoExtraction.extractFrames(
            from: backwardsActual, requestedTimes: [0.2, 0.6], limits: limits
        ), .invalidTime)

        let laterFailure = SyntheticVideoFrameSource(
            samples: [0.2: syntheticSample(time: 0.2)], failingTime: 0.4
        )
        expectFailure(await MediaVideoExtraction.extractFrames(
            from: laterFailure, requestedTimes: [0.2, 0.4], limits: limits
        ), .unreadableSource)
        expectFailure(await MediaVideoExtraction.extractFrames(
            from: SyntheticVideoFrameSource(),
            requestedTimes: [0.2], limits: limits
        ), .emptyResult)
    }

    @Test func alreadyCancelledRequestReturnsNoFrameBatch() async {
        let limits = self.limits
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await MediaVideoExtraction.extractFrames(
                from: SyntheticVideoFrameSource(
                    samples: [0.2: syntheticSample(time: 0.2)]
                ),
                requestedTimes: [0.2],
                limits: limits
            )
        }
        expectFailure(await task.value, .cancelled)
    }

    @Test func platformAdapterRejectsRemoteURLBeforeAnyRead() {
        do {
            _ = try AVFoundationVideoFrameSource(
                fileURL: URL(string: "https://example.invalid/video.mp4")!
            )
            Issue.record("Remote URLs must not enter the local-video adapter")
        } catch let failure as MediaVideoExtractionFailure {
            #expect(failure == .unreadableSource)
        } catch {
            Issue.record("Adapter must return a typed, path-free error")
        }
    }
}

/// A source whose PNG size follows the requested pixel bound, like a real decoder.
private struct SizeFollowsPixelBoundSource: MediaVideoFrameSource {
    func durationSeconds() async throws -> Double { 10 }
    func pngFrame(at seconds: Double, maxPixelSize: Int) async throws -> MediaVideoFrameSample {
        var png = Data([0x89, 0x50, 0x4E, 0x47])
        png.append(contentsOf: repeatElement(UInt8(0), count: maxPixelSize * 10))
        return MediaVideoFrameSample(
            pngData: png, actualSeconds: seconds, pixelWidth: min(maxPixelSize, 100), pixelHeight: 10)
    }
}

@Suite("Video frames shrink to the byte budget instead of failing")
struct MediaVideoFrameShrinkTests {
    @Test func overBudgetFramesAreRetakenSmallerAndKeepTheirTimes() async {
        // 768 px frames are ~7.7 KB each; the budget only fits ~3 KB per frame.
        let limits = MediaVideoExtractionLimits(maxFrameCount: 3, maxPixelSize: 768, maxOutputBytes: 9_000)
        let result = await MediaVideoExtraction.extractFrames(
            from: SizeFollowsPixelBoundSource(), requestedTimes: [1, 5, 9], limits: limits)
        guard case .success(let frames) = result else {
            Issue.record("Over-budget frames should be retaken at a smaller size, not fail the batch")
            return
        }
        #expect(frames.map(\.requestedSeconds) == [1, 5, 9])
        #expect(frames.reduce(0) { $0 + $1.pngData.count } <= limits.maxOutputBytes)
    }
}
