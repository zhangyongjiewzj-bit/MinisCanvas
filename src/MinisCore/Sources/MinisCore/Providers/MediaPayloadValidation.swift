import Foundation
import ImageIO

/// Byte inspection shared by Composer admission and the existing gated wire
/// assemblers. Image header/dimension checks reuse donor f9f99fbf3's preflight;
/// a MIME or filename is not evidence that a payload fits the current wire.
public enum MediaPayloadValidation {
    public enum Failure: String, Sendable, Equatable {
        case emptyOrTooLarge, unsupportedImageFormat, declaredFormatMismatch
        case invalidImageDimensions, unsupportedAudioFormat, invalidAudioContainer
        case unsupportedWire

        public var reason: String {
            switch self {
            case .emptyOrTooLarge: return "媒体实际字节为空或超过附件上限。"
            case .unsupportedImageFormat:
                return "图片实际格式不是 PNG、JPEG 或 WebP。新添加的 HEIC、GIF、TIFF、BMP 等图片会自动转换；"
                    + "此附件未经转换（可能来自旧记录，或自动转换失败）。请移除后重新添加，或手动转换为 PNG、JPEG 或 WebP。"
            case .declaredFormatMismatch: return "媒体声明格式与实际字节不一致。"
            case .invalidImageDimensions: return "图片实际字节无法完整解码出有效像素与宽高。"
            case .unsupportedAudioFormat:
                return "当前音频线路仅接收 WAV 或 MP3。新添加的 m4a、aac、flac、aiff、caf 音频会自动转换为 WAV；"
                    + "此附件未经转换（可能来自旧记录，或为 ogg 等无法转换的格式）。请移除后重新添加，或手动转换为 WAV/MP3。"
            case .invalidAudioContainer: return "音频实际字节未通过格式结构校验。"
            case .unsupportedWire: return "当前线路不支持此媒体输入。"
            }
        }
    }

    /// Existing Composer byte budget, applied again when stored history is
    /// assembled. This is not a new pixel-limit or transcoding policy.
    public static let maxInputBytes = 25 * 1024 * 1024

    public static func failure(data: Data, mimeType: String,
                               wire: ProviderWireProtocol? = nil) -> Failure? {
        guard !data.isEmpty, data.count <= maxInputBytes else { return .emptyOrTooLarge }
        let mime = normalized(mimeType)
        switch MediaPartKind.classify(mimeType: mime) {
        case .rasterImage:
            guard wire != .other else { return .unsupportedWire }
            guard let actual = imageMIME(data) else { return .unsupportedImageFormat }
            guard actual == mime else { return .declaredFormatMismatch }
            let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
            guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary),
                  CGImageSourceGetCount(source) > 0,
                  CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil),
                  let width = (properties as NSDictionary)[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = (properties as NSDictionary)[kCGImagePropertyPixelHeight] as? NSNumber,
                  width.intValue > 0, height.intValue > 0 else { return .invalidImageDimensions }
            // IHDR/EXIF dimensions can survive truncation without any pixels.
            // Force a small raster decode before bytes are admitted to any wire;
            // the thumbnail bound avoids caching a full-size decoded image here.
            let decodeOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 128,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let pixels = CGImageSourceCreateThumbnailAtIndex(source, 0, decodeOptions as CFDictionary),
                  pixels.width > 0, pixels.height > 0 else { return .invalidImageDimensions }
            return nil
        case .audio:
            guard wire != .anthropic, wire != .other else { return .unsupportedWire }
            guard mime == "audio/wav" || mime == "audio/mpeg" || mime == "audio/mp3" else {
                return .unsupportedAudioFormat
            }
            guard let actual = audioFormat(data) else { return .invalidAudioContainer }
            guard (actual == "wav" && mime == "audio/wav") ||
                    (actual == "mp3" && (mime == "audio/mpeg" || mime == "audio/mp3")) else {
                return .declaredFormatMismatch
            }
            return nil
        default: return nil // The modality gate owns SVG/PDF/video/unknown rejection.
        }
    }

    public static func decision(data: Data, mimeType: String, capabilities: ModelCapabilities,
                                wire: ProviderWireProtocol? = nil) -> MediaGateDecision {
        let decision = MediaCapabilityGate.decide(mimeType: mimeType, capabilities: capabilities)
        guard decision.isAllowed, let failure = failure(data: data, mimeType: mimeType, wire: wire) else {
            return decision
        }
        return .rejected(kind: MediaPartKind.classify(mimeType: mimeType), reason: failure.reason)
    }

    /// Canonical wire format comes from container bytes, never the filename.
    /// This checks bounded container/frame structure, not speech decoding or
    /// successful understanding by a remote model.
    public static func audioFormat(_ data: Data) -> String? {
        guard !data.isEmpty, data.count <= maxInputBytes else { return nil }
        let bytes = [UInt8](data)
        if bytes.count >= 12, bytes[0..<4].elementsEqual("RIFF".utf8),
           bytes[8..<12].elementsEqual("WAVE".utf8) {
            guard Int(little32(bytes, 4)) + 8 == bytes.count else { return nil }
            var offset = 12, hasFormat = false, hasSamples = false
            var blockAlignment = 0
            var sampleByteCounts: [Int] = []
            while offset + 8 <= bytes.count {
                let length = Int(little32(bytes, offset + 4)), start = offset + 8
                guard length <= bytes.count - start else { return nil }
                if bytes[offset..<offset + 4].elementsEqual("fmt ".utf8) {
                    guard length >= 16 else { return nil }
                    let tag = little16(bytes, start), channels = little16(bytes, start + 2)
                    let rate = little32(bytes, start + 4), align = little16(bytes, start + 12)
                    let byteRate = little32(bytes, start + 8)
                    let bits = little16(bytes, start + 14)
                    // IEEE-float WAV uses 32- or 64-bit samples. A coherent
                    // RIFF/byte-rate/block-align header cannot make float16
                    // decodable or authorize it on the audio wire.
                    guard (tag == 1 || (tag == 3 && (bits == 32 || bits == 64))),
                          channels > 0, rate > 0, align > 0,
                          bits > 0, Int(align) == Int(channels) * ((Int(bits) + 7) / 8),
                          UInt64(byteRate) == UInt64(rate) * UInt64(align) else { return nil }
                    blockAlignment = Int(align)
                    hasFormat = true
                } else if bytes[offset..<offset + 4].elementsEqual("data".utf8) {
                    hasSamples = length > 0
                    sampleByteCounts.append(length)
                }
                offset = start + length + length % 2
            }
            guard offset == bytes.count, hasFormat, hasSamples, blockAlignment > 0,
                  sampleByteCounts.allSatisfy({ $0 % blockAlignment == 0 }) else { return nil }
            return "wav"
        }
        var offset = 0
        if bytes.count >= 10, bytes[0..<3].elementsEqual("ID3".utf8) {
            guard bytes[6..<10].allSatisfy({ $0 < 128 }) else { return nil }
            let size = bytes[6..<10].reduce(0) { ($0 << 7) | Int($1) }
            offset = 10 + size + (bytes[5] & 0x10 == 0 ? 0 : 10)
        }
        guard offset <= bytes.count - 4 else { return nil }
        let a = bytes[offset], b = bytes[offset + 1], c = bytes[offset + 2]
        let version = (b >> 3) & 3, layer = (b >> 1) & 3
        let bitrateIndex = Int(c >> 4), sampleIndex = Int((c >> 2) & 3)
        guard a == 0xFF, b & 0xE0 == 0xE0, version != 1, layer == 1,
              bitrateIndex > 0, bitrateIndex < 15, sampleIndex < 3 else { return nil }
        let rates = [44100, 48000, 32000]
        let bitrates = version == 3
            ? [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
            : [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
        let divisor = version == 3 ? 1 : (version == 2 ? 2 : 4)
        let frameLength = (version == 3 ? 144000 : 72000) * bitrates[bitrateIndex]
            / (rates[sampleIndex] / divisor) + Int((c >> 1) & 1)
        return frameLength >= 4 && frameLength <= bytes.count - offset ? "mp3" : nil
    }

    private static func normalized(_ value: String) -> String {
        value.split(separator: ";", maxSplits: 1).first.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        } ?? ""
    }

    /// 按文件头判定的真实图片 MIME（PNG/JPEG/WebP），扩展名与声明类型不作依据。
    public static func sniffedImageMIME(_ data: Data) -> String? { imageMIME(data) }

    /// 按容器字节判定的真实音频 MIME（WAV → audio/wav，MP3 → audio/mpeg）；结构不合格返回 nil。
    public static func sniffedAudioMIME(_ data: Data) -> String? {
        switch audioFormat(data) {
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        default: return nil
        }
    }

    private static func imageMIME(_ data: Data) -> String? {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if data.count >= 12, data.starts(with: Array("RIFF".utf8)),
           data.dropFirst(8).prefix(4).elementsEqual("WEBP".utf8) { return "image/webp" }
        return nil
    }

    private static func little16(_ bytes: [UInt8], _ i: Int) -> UInt16 {
        UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8
    }
    private static func little32(_ bytes: [UInt8], _ i: Int) -> UInt32 {
        UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
    }
}
