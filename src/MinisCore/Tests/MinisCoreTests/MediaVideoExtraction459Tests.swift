import AVFoundation
import Foundation
import Testing
@testable import MinisCore

// D-COMPOSER-05 / D-COMPOSER-08: task450's owned, synthetic blue video.
// Original bytes: 1895; SHA256:
// 52d0e3743e682ed661debfdde35831eb3a625be8b8177e7bbaab829c8ca7491e
// Embedding keeps this test independent of a user's picker path or real data.
private enum VideoFixture459 {
    static let base64 = """
        AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAO0bW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAA
        AAAD6AAAA+gAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAt50cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAAB
        AAAAAAAAA+gAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAA
        AUAAAAC0AAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAPoAAAIAAABAAAAAAJWbWRpYQAAACBtZGhk
        AAAAAAAAAAAAAAAAAAAoAAAAKABVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRl
        b0hhbmRsZXIAAAACAW1pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAA
        AQAAAAx1cmwgAAAAAQAAAcFzdGJsAAAAwXN0c2QAAAAAAAAAAQAAALFhdmMxAAAAAAAAAAEAAAAAAAAA
        AAAAAAAAAAAAAUAAtABIAAAASAAAAAAAAAABFUxhdmM2Mi4yOC4xMDIgbGlieDI2NAAAAAAAAAAAAAAA
        GP//AAAAN2F2Y0MBZAAM/+EAGmdkAAys2UFBn58BEAAAAwAQAAADAUDxQplgAQAGaOvjyyLA/fj4AAAA
        ABBwYXNwAAAAAQAAAAEAAAAUYnRydAAAAAAAABwYAAAAAAAAABhzdHRzAAAAAAAAAAEAAAAKAAAEAAAA
        ABRzdHNzAAAAAAAAAAEAAAABAAAAYGN0dHMAAAAAAAAACgAAAAEAAAgAAAAAAQAAFAAAAAABAAAIAAAA
        AAEAAAAAAAAAAQAABAAAAAABAAAUAAAAAAEAAAgAAAAAAQAAAAAAAAABAAAEAAAAAAEAAAgAAAAAHHN0
        c2MAAAAAAAAAAQAAAAEAAAAKAAAAAQAAADxzdHN6AAAAAAAAAAAAAAAKAAAC9gAAABEAAAANAAAADQAA
        AA0AAAAWAAAADwAAAA0AAAANAAAAFgAAABRzdGNvAAAAAAAAAAEAAAPkAAAAYnVkdGEAAABabWV0YQAA
        AAAAAAAhaGRscgAAAAAAAAAAbWRpcmFwcGwAAAAAAAAAAAAAAAAtaWxzdAAAACWpdG9vAAAAHWRhdGEA
        AAABAAAAAExhdmY2Mi4xMi4xMDIAAAAIZnJlZQAAA4ttZGF0AAACrgYF//+q3EXpvebZSLeWLNgg2SPu
        73gyNjQgLSBjb3JlIDE2NSByMzIyMiBiMzU2MDVhIC0gSC4yNjQvTVBFRy00IEFWQyBjb2RlYyAtIENv
        cHlsZWZ0IDIwMDMtMjAyNSAtIGh0dHA6Ly93d3cudmlkZW9sYW4ub3JnL3gyNjQuaHRtbCAtIG9wdGlv
        bnM6IGNhYmFjPTEgcmVmPTMgZGVibG9jaz0xOjA6MCBhbmFseXNlPTB4MzoweDExMyBtZT1oZXggc3Vi
        bWU9NyBwc3k9MSBwc3lfcmQ9MS4wMDowLjAwIG1peGVkX3JlZj0xIG1lX3JhbmdlPTE2IGNocm9tYV9t
        ZT0xIHRyZWxsaXM9MSA4eDhkY3Q9MSBjcW09MCBkZWFkem9uZT0yMSwxMSBmYXN0X3Bza2lwPTEgY2hy
        b21hX3FwX29mZnNldD0tMiB0aHJlYWRzPTEgbG9va2FoZWFkX3RocmVhZHM9MSBzbGljZWRfdGhyZWFk
        cz0wIG5yPTAgZGVjaW1hdGU9MSBpbnRlcmxhY2VkPTAgYmx1cmF5X2NvbXBhdD0wIGNvbnN0cmFpbmVk
        X2ludHJhPTAgYmZyYW1lcz0zIGJfcHlyYW1pZD0yIGJfYWRhcHQ9MSBiX2JpYXM9MCBkaXJlY3Q9MSB3
        ZWlnaHRiPTEgb3Blbl9nb3A9MCB3ZWlnaHRwPTIga2V5aW50PTI1MCBrZXlpbnRfbWluPTEwIHNjZW5l
        Y3V0PTQwIGludHJhX3JlZnJlc2g9MCByY19sb29rYWhlYWQ9NDAgcmM9Y3JmIG1idHJlZT0xIGNyZj0y
        My4wIHFjb21wPTAuNjAgcXBtaW49MCBxcG1heD02OSBxcHN0ZXA9NCBpcF9yYXRpbz0xLjQwIGFxPTE6
        MS4wMACAAAAAQGWIhAAR//7n4/wKbXzEcTp2GPr31tdyoujXh1cYhTyC6Mxkf19QAF7xKsX1bfTg8l/g
        UUAABCgiEzWymSzeNLkAAAANQZokbEEP/qpVAACFgAAAAAlBnkJ4h38AAQMAAAAJAZ5hdEN/AAF3AAAA
        CQGeY2pDfwABdwAAABJBmmhJqEFomUwId//+qZYAAgcAAAALQZ6GRREsO/8AAQMAAAAJAZ6ldEN/AAF3
        AAAACQGep2pDfwABdwAAABJBmqlJqEFsmUwIb//+p4QAA/w=
        """

    static func writeOwnedFixture() throws -> URL {
        let bytes = try #require(Data(base64Encoded: base64, options: .ignoreUnknownCharacters))
        #expect(bytes.count == 1895)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("video459-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("owned-blue-1s.mp4")
        try bytes.write(to: url, options: .atomic)
        // Leave owned operands available for a failing run's readback.
        return url
    }
}

@Suite("D-COMPOSER-05 real AVFoundation short video; source-only459")
struct MediaVideoExtraction459Tests {
    @Test func ownedShortH264HasThreeDistinctProductionFrames() async throws {
        let url = try VideoFixture459.writeOwnedFixture()
        let source = try AVFoundationVideoFrameSource(fileURL: url)
        let duration = try await source.durationSeconds()
        #expect(duration.isFinite && duration > 0)
        #expect(abs(duration - 1) < 0.01)
        let requested = [1.0 / 6.0, 0.5, 5.0 / 6.0].map { duration * $0 }
        let limits = MediaVideoExtractionLimits(
            maxFrameCount: 3, maxPixelSize: 768, maxOutputBytes: 2 * 1024 * 1024
        )
        let result = await MediaVideoExtraction.extractFrames(
            from: source, requestedTimes: requested, limits: limits
        )
        if case .failure(let failure) = result {
            // Diagnostics never replace the production result's strong oracle.
            // No path, decoder message, image bytes, credentials, or network.
            print("VIDEO459 productionFailure=\(failure) duration=\(duration)")
            for time in requested {
                do {
                    let sample = try await source.pngFrame(at: time, maxPixelSize: 768)
                    print("VIDEO459 production requested=\(time) actual=\(sample.actualSeconds) pixels=\(sample.pixelWidth)x\(sample.pixelHeight) pngBytes=\(sample.pngData.count)")
                } catch {
                    let safe = error as NSError
                    print("VIDEO459 production requested=\(time) errorDomain=\(safe.domain) errorCode=\(safe.code)")
                }
            }
            // One variable differs from the platform adapter: time tolerance.
            // This local decoder control is evidence for a subsequent fix,
            // not a fallback production decoder or permission bypass.
            let asset = AVURLAsset(url: url)
            for time in requested {
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 768, height: 768)
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                do {
                    let sample = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
                    print("VIDEO459 zeroTolerance requested=\(time) actual=\(CMTimeGetSeconds(sample.actualTime)) pixels=\(sample.image.width)x\(sample.image.height)")
                } catch {
                    let safe = error as NSError
                    print("VIDEO459 zeroTolerance requested=\(time) errorDomain=\(safe.domain) errorCode=\(safe.code)")
                }
            }
        }
        guard case .success(let frames) = result else {
            Issue.record("Production extraction must return three distinct, bounded PNG frames for the owned H264 fixture")
            return
        }
        #expect(frames.count == 3)
        #expect(frames.map(\.requestedSeconds) == requested)
        #expect(Set(frames.map(\.timecodeSeconds)).count == 3)
        #expect(zip(frames, frames.dropFirst()).allSatisfy { $0.0.timecodeSeconds < $0.1.timecodeSeconds })
        #expect(frames.allSatisfy {
            $0.timecodeSeconds >= 0 && $0.timecodeSeconds < duration
                && $0.pixelWidth == 320 && $0.pixelHeight == 180
                && $0.pngData.starts(with: [0x89, 0x50, 0x4E, 0x47])
        })
        #expect(frames.reduce(0) { $0 + $1.pngData.count } <= limits.maxOutputBytes)
    }
}
