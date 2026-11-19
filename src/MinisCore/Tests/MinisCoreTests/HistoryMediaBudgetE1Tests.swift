import Foundation
import Testing
@testable import MinisCore

@Suite("E-1 历史媒体字节预算")
struct HistoryMediaBudgetE1Tests {
    private func image(_ bytes: Int) -> LLMMessage.ImageAttachment {
        .init(mimeType: "image/png", data: Data(count: bytes))
    }

    @Test("较早轮次的图片超出预算后换成文字占位，最近一条用户消息的媒体始终保留")
    func oldMediaReplacedNewestKept() {
        let mb = 1024 * 1024
        let messages = [
            LLMMessage(role: .user, content: "第一轮", images: [image(10 * mb)]),
            LLMMessage(role: .assistant, content: "好"),
            LLMMessage(role: .user, content: "第二轮", images: [image(10 * mb)]),
            LLMMessage(role: .assistant, content: "好"),
            LLMMessage(role: .user, content: "第三轮", images: [image(20 * mb)]),
        ]
        let out = HistoryMediaBudget.apply(messages, maxBytes: 16 * mb)
        #expect(out.count == messages.count)
        #expect(out[0].images.isEmpty)
        #expect(out[0].content.contains(HistoryMediaBudget.imagePlaceholder))
        #expect(out[2].images.isEmpty)
        #expect(out[4].images.count == 1)
    }

    @Test("预算内的媒体原样保留；音频同样计入并被占位")
    func withinBudgetUntouchedAudioCounted() {
        let small = [LLMMessage(role: .user, content: "a", images: [image(1024)]),
                     LLMMessage(role: .user, content: "b", images: [image(1024)])]
        #expect(HistoryMediaBudget.apply(small, maxBytes: 16 * 1024 * 1024).allSatisfy { $0.images.count == 1 })
        let base64 = Data(count: 3_000).base64EncodedString()
        let audio = [LLMMessage(role: .user, content: "old", audios: [.init(format: "wav", base64Data: base64)]),
                     LLMMessage(role: .user, content: "new")]
        let out = HistoryMediaBudget.apply(audio, maxBytes: 100)
        #expect(out[0].audios.isEmpty)
        #expect(out[0].content.contains(HistoryMediaBudget.audioPlaceholder))
        // MC4-020：音频没有重新读取的工具，占位必须明说听不到、需要时请用户重新添加。
        #expect(out[0].content.contains("请用户重新添加这段音频"))
    }

    @Test("R3-14 整份请求最多保留 20 张图，从最新往前数，最新一条始终保留")
    func imageCountCappedNewestKept() {
        var messages: [LLMMessage] = []
        for round in 0..<25 {
            messages.append(LLMMessage(role: .user, content: "第\(round)轮", images: [image(1024)]))
            messages.append(LLMMessage(role: .assistant, content: "好"))
        }
        let out = HistoryMediaBudget.apply(messages)
        #expect(out.count == messages.count)
        #expect(out.reduce(0) { $0 + $1.images.count } == HistoryMediaBudget.defaultMaxImages)
        // 最新一条（倒数第二个下标）保留，最早的 5 条被换成占位。
        #expect(out[out.count - 2].images.count == 1)
        for index in stride(from: 0, to: 10, by: 2) {
            #expect(out[index].images.isEmpty)
            #expect(out[index].content.contains(HistoryMediaBudget.imagePlaceholder))
        }
        #expect(out[10].images.count == 1)
    }

    @Test("R3-14 最新一条消息自带超过上限的图片时仍整条保留，不被张数上限砍掉")
    func newestMessageKeptEvenOverImageCap() {
        let messages = [
            LLMMessage(role: .user, content: "旧", images: [image(1024)]),
            LLMMessage(role: .assistant, content: "好"),
            LLMMessage(role: .user, content: "新", images: (0..<22).map { _ in image(1024) }),
        ]
        let out = HistoryMediaBudget.apply(messages)
        #expect(out[2].images.count == 22)
        #expect(out[0].images.isEmpty)
    }

    @Test("C3-11 最新一条用户消息及其后的媒体字节单独统计，较早的不算")
    func protectedMediaBytesCountsOnlyTheNewestUserMessageAndAfter() {
        let messages = [
            LLMMessage(role: .user, content: "旧", images: [image(5_000)]),
            LLMMessage(role: .assistant, content: "好"),
            LLMMessage(role: .user, content: "新", images: [image(300), image(200)]),
        ]
        #expect(HistoryMediaBudget.protectedMediaBytes(messages) == 500)
        #expect(HistoryMediaBudget.protectedMediaBytes([LLMMessage(role: .assistant, content: "无用户消息")]) == 0)
        #expect(HistoryMediaBudget.newestUserMessageHasMedia(messages))
        // F-05：其后本回合工具返回的图片不算进这条消息的媒体（它们有自己的保留预算，压缩或缩减时可以摘掉）。
        let withToolImages = messages + [
            LLMMessage(role: .assistant, content: "", toolCalls: [
                LLMToolCall(id: "t1", name: "file_read", rawArguments: "{}", arguments: [:])]),
            LLMMessage(role: .tool, content: "图", images: [image(7_000), image(9_000)], toolCallID: "t1"),
        ]
        #expect(HistoryMediaBudget.protectedMediaBytes(withToolImages) == 500)
        let textOnlyNewest = [LLMMessage(role: .user, content: "旧", images: [image(10)]),
                              LLMMessage(role: .assistant, content: "好"),
                              LLMMessage(role: .user, content: "新")]
        #expect(!HistoryMediaBudget.newestUserMessageHasMedia(textOnlyNewest))
        #expect(HistoryMediaBudget.protectedMediaBytes(textOnlyNewest) == 0)
    }

    @Test("413 请求体过大被识别为可降级重试的超长错误")
    func requestTooLarge413() {
        let body = #"{"type":"error","error":{"type":"request_too_large","message":"Request exceeds the maximum allowed number of bytes."}}"#
        #expect(ProviderContextOverflowClassifier.isAnthropicOverflow(statusCode: 413, body: body))
        let openAI = #"{"error":{"message":"Payload Too Large","type":"invalid_request_error"}}"#
        #expect(ProviderContextOverflowClassifier.isOpenAIStyleOverflow(statusCode: 413, body: openAI))
    }

    @Test("请求副本归约时较早的音频也被省略")
    func reducerDropsOldAudio() {
        let audio = LLMMessage.AudioAttachment(format: "wav", base64Data: "AAAA")
        let messages = [LLMMessage(role: .user, content: "old", audios: [audio]),
                        LLMMessage(role: .assistant, content: "ok"),
                        LLMMessage(role: .user, content: "new", audios: [audio])]
        let out = RequestContextReducer.reduce(messages).messages
        #expect(out[0].audios.isEmpty)
        #expect(out[2].audios.count == 1)
    }
}
