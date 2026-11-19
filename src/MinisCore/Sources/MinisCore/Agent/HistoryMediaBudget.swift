import Foundation

/// 历史媒体字节预算：每轮请求都会把历史里的用户图片、视频帧、音频整份重发，
/// 累计超过服务端请求体上限（例如 Anthropic 约 32 MB）后会话会一直 413。
/// 对齐 Claude Code：只保留最近若干轮的原始媒体，较早的在超出预算时换成文字占位。
///
/// 只作用在发出前的请求副本上，不改持久化的对话；输出只取决于消息内容和位置，
/// 同一份历史每次得到同样的结果。最近一条用户消息的媒体始终保留。
public enum HistoryMediaBudget {
    /// 请求里保留的历史媒体原始字节上限（base64 后约 21 MB，低于常见 32 MB 请求体上限）。
    public static let defaultMaxBytes = 16 * 1024 * 1024
    /// 整份请求保留的图片张数上限：Anthropic 在一次请求超过 20 张图时，要求每张边长都不超过 2000 像素，
    /// 超限整份请求被拒（且历史不变，之后每轮都失败）。从最新往前数，较早的整条消息的图片换成文字占位。
    public static let defaultMaxImages = 20

    public static let imagePlaceholder = "[较早的图片已省略]"
    /// 音频没有像图片那样可用 file_read 重新读取的办法：明确告诉模型现在听不到，需要细节就请用户重新添加，
    /// 免得凭不完整的历史回答（MC4-020）。
    public static let audioPlaceholder = "[较早的音频已省略：现在听不到这段音频；需要其中细节时，请用户重新添加这段音频]"

    private static func protectedStart(_ messages: [LLMMessage]) -> Int {
        messages.indices.last { messages[$0].role == .user && messages[$0].toolCallID == nil } ?? messages.count
    }

    private static func mediaBytes(_ message: LLMMessage) -> Int {
        message.images.reduce(0) { $0 + $1.data.count }
            + message.audios.reduce(0) { $0 + $1.base64Data.utf8.count / 4 * 3 }
    }

    /// 最近一条真实用户消息自带的媒体原始字节数。这部分不受预算影响，更早的媒体已被预算换成占位：
    /// 它一个人就占满预算（>= `defaultMaxBytes`）时，请求体过大只能靠减少这条消息的媒体，
    /// 压缩对话帮不上忙。
    /// 其后本回合工具返回的图片不算：它们有自己的保留预算（`ToolResultImageChannel.pruneHistoryImages`），
    /// 压缩或缩减请求时可以摘掉，把它们算进来会把文字超窗误判成“图片太大”。
    public static func protectedMediaBytes(_ messages: [LLMMessage]) -> Int {
        let start = protectedStart(messages)
        guard messages.indices.contains(start) else { return 0 }
        return mediaBytes(messages[start])
    }

    /// 最近一条真实用户消息是否带图片或音频。
    public static func newestUserMessageHasMedia(_ messages: [LLMMessage]) -> Bool {
        let start = protectedStart(messages)
        guard messages.indices.contains(start) else { return false }
        return !messages[start].images.isEmpty || !messages[start].audios.isEmpty
    }

    public static func apply(
        _ messages: [LLMMessage], maxBytes: Int = defaultMaxBytes, maxImages: Int = defaultMaxImages
    ) -> [LLMMessage] {
        // 最近一条真实用户消息及其后的消息不受预算影响。
        let protectedFrom = protectedStart(messages)
        var kept = 0
        var keptImages = 0
        var result = messages
        for index in messages.indices.reversed() {
            let message = messages[index]
            guard !message.images.isEmpty || !message.audios.isEmpty else { continue }
            let bytes = mediaBytes(message)
            let imageCount = message.images.count
            let withinImageCount = imageCount == 0 || keptImages + imageCount <= maxImages
            if index >= protectedFrom || (kept + bytes <= maxBytes && withinImageCount) {
                kept += bytes
                keptImages += imageCount
                continue
            }
            var notes: [String] = []
            if !message.images.isEmpty { notes.append(imagePlaceholder) }
            if !message.audios.isEmpty { notes.append(audioPlaceholder) }
            result[index] = LLMMessage(
                role: message.role,
                content: message.content + (message.content.isEmpty ? "" : "\n") + notes.joined(separator: "\n"),
                images: [], audios: [], toolCallID: message.toolCallID, toolCalls: message.toolCalls,
                legacyToolOutputSummary: message.legacyToolOutputSummary)
        }
        return result
    }
}
