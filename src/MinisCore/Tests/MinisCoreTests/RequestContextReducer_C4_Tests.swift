import Foundation
import Testing
@testable import MinisCore

struct RequestContextReducerC4Tests {
    private func rounds(_ count: Int, characters: Int = 20_000) -> [LLMMessage] {
        var messages = [LLMMessage(role: .user, content: "读一下这些文件")]
        for index in 1...count {
            let id = "call-\(index)"
            messages.append(LLMMessage(
                role: .assistant, content: "",
                toolCalls: [LLMToolCall(id: id, name: "file_read", rawArguments: "{}", arguments: [:])]))
            messages.append(LLMMessage(
                role: .tool, content: "R\(index)-" + String(repeating: "x", count: characters), toolCallID: id))
        }
        return messages
    }

    @Test func oldLargeToolResultsKeepHeadAndTailAndPairing() {
        let source = rounds(20)
        let outcome = RequestContextReducer.reduce(source)
        #expect(outcome.messages.count == source.count)
        #expect(outcome.reducedToolResults == 14)
        for (before, after) in zip(source, outcome.messages) {
            #expect(before.role == after.role)
            #expect(before.toolCallID == after.toolCallID)
            #expect(before.toolCalls.map(\.id) == after.toolCalls.map(\.id))
        }
        let toolIndices = source.indices.filter { source[$0].role == .tool }
        for index in toolIndices.prefix(14) {
            let text = outcome.messages[index].content
            #expect(text.hasPrefix("R"))
            #expect(text.contains(ToolResultExcerpt.omissionMarker(
                omittedCharacters: source[index].content.count - 1_600)))
            #expect(text.count < 1_700)
        }
        #expect(windowTestCharacterCount(outcome.messages) * 100 < windowTestCharacterCount(source) * 40)
    }

    @Test func latestSixToolExchangesAreProtectedEvenInsideOneUserTurn() {
        let source = rounds(20)
        let outcome = RequestContextReducer.reduce(source)
        let toolIndices = source.indices.filter { source[$0].role == .tool }
        for index in toolIndices.suffix(6) {
            #expect(outcome.messages[index] == source[index])
        }
    }

    @Test func shortResultsAndFewRoundsAreIdentity() {
        let few = rounds(5)
        #expect(RequestContextReducer.reduce(few).messages == few)
        let small = rounds(20, characters: 2_000)
        #expect(RequestContextReducer.reduce(small).messages == small)
        #expect(!RequestContextReducer.reduce(small).changedAnything)
    }

    @Test func earlierImagesBecomeTextPlaceholdersAndTheLatestUserTurnKeepsItsImage() {
        let image = LLMMessage.ImageAttachment(mimeType: "image/png", data: Data(repeating: 1, count: 4_096))
        let source = [
            LLMMessage(role: .user, content: "看图一", images: [image]),
            LLMMessage(role: .assistant, content: "好的"),
            LLMMessage(role: .user, content: "看图二", images: [image]),
        ]
        let outcome = RequestContextReducer.reduce(source)
        #expect(outcome.replacedImages == 1)
        #expect(outcome.messages[0].images.isEmpty)
        #expect(outcome.messages[0].content.contains("[图片 image/png 4096B 已省略]"))
        #expect(outcome.messages[2] == source[2])
    }

    @Test func sameHistoryReducesToTheSameBytesAndEarlierPrefixIsStable() {
        let short = rounds(12)
        let long = rounds(14)
        let a = RequestContextReducer.reduce(short).messages
        #expect(a == RequestContextReducer.reduce(short).messages)
        // The first six rounds were already outside the protected window in both.
        let stable = 1 + 2 * 6
        #expect(Array(RequestContextReducer.reduce(long).messages.prefix(stable)) == Array(a.prefix(stable)))
    }

    @Test func excerptDoesNotExposeASecretThatWasInTheKeptHead() {
        let secret = "sk-" + String(repeating: "Zy9xWv8uTs", count: 4)
        var source = rounds(12)
        let first = source.firstIndex { $0.role == .tool }!
        source[first] = LLMMessage(
            role: .tool, content: "key=\(secret) " + String(repeating: "y", count: 6_000), toolCallID: "call-1")
        let reduced = RequestContextReducer.reduce(source).messages[first].content
        #expect(!reduced.contains(secret))
    }

    @Test func reductionStateIsIdentityUntilActivatedByTheLoop() {
        let source = rounds(20)
        let state = ContextReductionState()
        #expect(state.apply(source) == source)
        state.activate()
        #expect(state.apply(source) != source)
        #expect(state.apply(source) == RequestContextReducer.reduce(source).messages)
    }
}
