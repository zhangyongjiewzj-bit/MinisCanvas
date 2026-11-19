import Foundation

// 音频附件本机转写的纯逻辑：切段计划、结果拼接格式、"是否转写"的决策。
// 真正的识别（Speech 框架）在 App 层；这里不碰任何系统框架，可直接单测。

/// 附件音频的本机转写结果，随附件持久化；`text` 可被用户修改。
public struct AudioTranscript: Codable, Equatable, Sendable {
    /// 转写正文（不含 `[音频转写：…]` 头）；用户修改后保存在这里。
    public var text: String
    /// 识别所用语言（如 zh-CN）。
    public var localeIdentifier: String
    /// 音频总时长（秒）。
    public var durationSeconds: Double
    /// true = 在本机识别；false = 经用户同意交给 Apple 在线识别。
    public var onDevice: Bool
    /// 用户是否改过文字。
    public var edited: Bool

    public init(
        text: String, localeIdentifier: String, durationSeconds: Double,
        onDevice: Bool, edited: Bool = false
    ) {
        self.text = text
        self.localeIdentifier = localeIdentifier
        self.durationSeconds = durationSeconds
        self.onDevice = onDevice
        self.edited = edited
    }

    /// 去掉首尾空白后是否还有内容。
    public var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum AudioTranscriptionPlan {
    /// 单段识别的目标上限（秒）：Apple 在线识别对单次音频约 1 分钟封顶，留出余量。
    public static let maxSegmentSeconds: Double = 55

    public struct Segment: Equatable, Sendable {
        public let index: Int
        public let startSeconds: Double
        public let durationSeconds: Double
        public init(index: Int, startSeconds: Double, durationSeconds: Double) {
            self.index = index
            self.startSeconds = startSeconds
            self.durationSeconds = durationSeconds
        }
    }

    /// 按时间把音频切成等长的几段，每段不超过 `maxSegmentSeconds`；不超过上限时只有一段。
    /// 等长切分避免末尾出现一两秒的碎片段。时长无效（非有限或 ≤ 0）返回空数组。
    public static func segments(
        totalDuration: Double, maxSegmentSeconds: Double = AudioTranscriptionPlan.maxSegmentSeconds
    ) -> [Segment] {
        guard totalDuration.isFinite, totalDuration > 0,
              maxSegmentSeconds.isFinite, maxSegmentSeconds > 0 else { return [] }
        let count = max(1, Int((totalDuration / maxSegmentSeconds).rounded(.up)))
        let length = totalDuration / Double(count)
        return (0..<count).map {
            Segment(index: $0, startSeconds: length * Double($0), durationSeconds: length)
        }
    }
}

public enum AudioTranscriptFormat {
    /// 时长写成 mm:ss（分钟可超过 59，如 125:03）；无效值写 00:00。
    public static func durationText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0, seconds < 360_000_000 else { return "00:00" }
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// 各段文字拼成一整段：去掉首尾空白、跳过空段；
    /// 相邻处两侧有一侧是中日韩文字或全角标点时不加空格，否则加一个空格。
    public static func joinSegments(_ texts: [String]) -> String {
        var result = ""
        for raw in texts {
            let piece = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            if let last = result.unicodeScalars.last, let first = piece.unicodeScalars.first,
               !isWide(last), !isWide(first) {
                result += " "
            }
            result += piece
        }
        return result
    }

    /// 发给模型的内容：`[音频转写：文件名，时长 mm:ss]` 换行后接文字。
    public static func modelText(fileName: String, durationSeconds: Double, body: String) -> String {
        "[音频转写：\(fileName)，时长 \(durationText(durationSeconds))]\n"
            + body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F, 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xAC00...0xD7AF, 0xFF00...0xFFEF:
            return true
        default:
            return false
        }
    }
}

public enum AudioTranscriptionDecision {
    public enum Action: Equatable, Sendable {
        /// 模型能收音频：保持原行为，音频原样随消息发送。
        case sendAudioNatively
        /// 模型不能收音频，且已有转写文字：改发文字。
        case sendTranscript
        /// 模型不能收音频，还没有转写文字：先在本机转写。
        case needsTranscription
    }

    public static func action(modelAcceptsAudio: Bool, transcriptText: String?) -> Action {
        if modelAcceptsAudio { return .sendAudioNatively }
        let trimmed = transcriptText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? .needsTranscription : .sendTranscript
    }

    public enum Route: Equatable, Sendable {
        /// 在本机识别，音频不离开这台电脑。
        case onDevice
        /// 本机不支持该语言，需征得同意后交给 Apple 在线识别。
        case requiresOnlineConsent
        /// 识别器不可用（语言不支持或服务不可用）。
        case unavailable
    }

    public static func route(recognizerAvailable: Bool, onDeviceSupported: Bool) -> Route {
        if onDeviceSupported { return .onDevice }
        return recognizerAvailable ? .requiresOnlineConsent : .unavailable
    }
}
