import Testing
@testable import MinisCanvasApp

@Suite("PERF49 stream text buffer")
struct ChatStreamTextBufferTests {
    @Test("chunks Unicode text without losing scalar boundaries")
    func chunksUnicodeText() {
        var buffer = ChatStreamTextBuffer()
        buffer.append("你好🙂世界")

        #expect(buffer.nextChunk(maxCharacters: 3) == "你好🙂")
        #expect(buffer.nextChunk(maxCharacters: 3) == "世界")
        #expect(buffer.nextChunk(maxCharacters: 3) == nil)
    }

    @Test("appending after a partial drain preserves the unread suffix")
    func appendingAfterPartialDrainPreservesSuffix() {
        var buffer = ChatStreamTextBuffer()
        buffer.append("abcdef")

        #expect(buffer.nextChunk(maxCharacters: 2) == "ab")
        buffer.append("ghi")
        #expect(buffer.nextChunk(maxCharacters: 3) == "cde")
        #expect(buffer.nextChunk(maxCharacters: 3) == "fgh")
        #expect(buffer.nextChunk(maxCharacters: 3) == "i")
        #expect(buffer.nextChunk(maxCharacters: 3) == nil)
    }

    @Test("non-positive chunk sizes fail closed")
    func nonPositiveChunkSizesFailClosed() {
        var buffer = ChatStreamTextBuffer()
        buffer.append("text")

        #expect(buffer.nextChunk(maxCharacters: 0) == nil)
        #expect(buffer.nextChunk(maxCharacters: -1) == nil)
        #expect(buffer.nextChunk(maxCharacters: 4) == "text")
    }
}
