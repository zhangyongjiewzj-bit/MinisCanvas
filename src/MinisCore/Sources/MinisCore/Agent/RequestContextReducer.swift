import Foundation

/// Shrinks old tool results and old images in a copy of the request messages.
///
/// This type only decides WHICH messages shrink; the shrinking of a tool
/// result is `ToolResultExcerpt.excerpt` (the single shared function). It is a
/// pure function of its input and never touches the canonical transcript:
/// callers hand it the delivery copy, after history and media projection.
///
/// Protected from shrinking (user decision S1, 11/9):
/// - the latest `keepRecentToolExchanges` tool results, wherever they sit, so
///   a single long tool turn can still be reduced from its older rounds;
/// - images and text of the latest `keepRecentUserTurns` user turns.
/// Everything is deterministic and depends only on message content and
/// position, so the same history reduces to the same bytes on every request.
///
/// `toolCallID`, `toolCalls`, message count and order are never changed, so
/// tool_use / tool_result pairing stays valid.
public struct RequestContextReducer: Sendable {
    public struct Policy: Sendable, Equatable {
        public var keepRecentToolExchanges: Int
        public var keepRecentUserTurns: Int
        public var toolResultHeadCharacters: Int
        public var toolResultTailCharacters: Int
        /// Tool results at or below this many characters are left alone.
        public var minimumReducibleCharacters: Int
        /// [assumption] values are starting points, not measured.
        public init(
            keepRecentToolExchanges: Int = 6,
            keepRecentUserTurns: Int = 1,
            toolResultHeadCharacters: Int = 1_200,
            toolResultTailCharacters: Int = 400,
            minimumReducibleCharacters: Int = 2_500
        ) {
            self.keepRecentToolExchanges = keepRecentToolExchanges
            self.keepRecentUserTurns = keepRecentUserTurns
            self.toolResultHeadCharacters = toolResultHeadCharacters
            self.toolResultTailCharacters = toolResultTailCharacters
            self.minimumReducibleCharacters = minimumReducibleCharacters
        }
    }

    public struct Outcome: Sendable, Equatable {
        public let messages: [LLMMessage]
        public let reducedToolResults: Int
        public let replacedImages: Int
        public var changedAnything: Bool { reducedToolResults > 0 || replacedImages > 0 }
    }

    /// Remembers the excerpt of a given content so repeated requests do not
    /// redact and cut the same tool result again. Keyed by the content itself.
    final class Memo: @unchecked Sendable {
        private struct Key: Hashable {
            let content: String
            let head: Int
            let tail: Int
        }
        private let lock = NSLock()
        private var entries: [Key: String] = [:]
        private let capacity = 512

        func excerpt(of content: String, head: Int, tail: Int) -> String {
            let key = Key(content: content, head: head, tail: tail)
            lock.lock()
            let cached = entries[key]
            lock.unlock()
            if let cached { return cached }
            let text = ToolResultExcerpt.excerpt(
                content, head: head, tail: tail, maxUTF8Bytes: nil).text
            lock.lock()
            if entries.count >= capacity { entries.removeAll(keepingCapacity: true) }
            entries[key] = text
            lock.unlock()
            return text
        }
    }

    public static func reduce(_ messages: [LLMMessage], policy: Policy = Policy()) -> Outcome {
        reduce(messages, policy: policy, memo: nil)
    }

    static func reduce(_ messages: [LLMMessage], policy: Policy, memo: Memo?) -> Outcome {
        let protectedTools = Set(
            messages.indices.filter { isToolResult(messages[$0]) }
                .suffix(max(0, policy.keepRecentToolExchanges)))
        let userTurnStarts = messages.indices.filter { isUserTurnStart(messages[$0]) }
        let mediaFloor: Int
        if policy.keepRecentUserTurns <= 0 {
            mediaFloor = messages.count
        } else if userTurnStarts.count >= policy.keepRecentUserTurns {
            mediaFloor = userTurnStarts[userTurnStarts.count - policy.keepRecentUserTurns]
        } else {
            mediaFloor = 0
        }

        var reducedToolResults = 0
        var replacedImages = 0
        var result: [LLMMessage] = []
        result.reserveCapacity(messages.count)
        for (index, message) in messages.enumerated() {
            var content = message.content
            var images = message.images
            var audios = message.audios
            if isToolResult(message), !protectedTools.contains(index),
               content.count > policy.minimumReducibleCharacters {
                let reduced = memo?.excerpt(
                    of: content, head: policy.toolResultHeadCharacters,
                    tail: policy.toolResultTailCharacters)
                    ?? ToolResultExcerpt.excerpt(
                        content, head: policy.toolResultHeadCharacters,
                        tail: policy.toolResultTailCharacters, maxUTF8Bytes: nil).text
                if reduced != content {
                    content = reduced
                    reducedToolResults += 1
                }
            }
            if index < mediaFloor, !message.images.isEmpty {
                let notes = message.images.map { "[图片 \($0.mimeType) \($0.data.count)B 已省略]" }
                content += (content.isEmpty ? "" : "\n") + notes.joined(separator: "\n")
                images = []
                replacedImages += message.images.count
            }
            // 音频同样占请求体：较早轮次的音频与图片一起换成文字占位。
            if index < mediaFloor, !message.audios.isEmpty {
                content += (content.isEmpty ? "" : "\n") + HistoryMediaBudget.audioPlaceholder
                audios = []
                replacedImages += message.audios.count
            }
            if content == message.content, images.count == message.images.count,
               audios.count == message.audios.count {
                result.append(message)
            } else {
                result.append(LLMMessage(
                    role: message.role, content: content, images: images, audios: audios,
                    toolCallID: message.toolCallID, toolCalls: message.toolCalls,
                    legacyToolOutputSummary: message.legacyToolOutputSummary))
            }
        }
        return Outcome(messages: result, reducedToolResults: reducedToolResults, replacedImages: replacedImages)
    }

    /// A native tool result (OpenAI-style `tool` role message).
    private static func isToolResult(_ message: LLMMessage) -> Bool {
        message.role == .tool || message.toolCallID != nil
    }

    /// A real user message, not the text-envelope `tool_result` carrier.
    private static func isUserTurnStart(_ message: LLMMessage) -> Bool {
        guard message.role == .user, message.toolCallID == nil,
              message.legacyToolOutputSummary == nil else { return false }
        return !(message.content.hasPrefix("[") && message.content.contains("\"tool_result\""))
    }
}

/// Reduction switch for one run, shared between `AgentLoop` (the only writer)
/// and the delivery-projection closure the App installs.
///
/// Activation is decided only by `AgentLoop.contextAdmission` (user decision
/// S2); the App only calls `apply` as the last stage of its provider-message
/// projection, after history and media projection. While inactive, `apply` is
/// the identity. Once activated it stays active for the run, so the reduced
/// prefix does not flip between requests.
public final class ContextReductionState: @unchecked Sendable {
    public let policy: RequestContextReducer.Policy
    private let lock = NSLock()
    private var active = false
    private let memo = RequestContextReducer.Memo()

    /// How many of the newest tool results stay unreduced. Starts at the
    /// policy's value; `AgentLoop` lowers it step by step only when the request
    /// would otherwise be refused at the hard block.
    private var protectedToolResults: Int

    /// The steps below the policy's value: 2 newest tool results, then 1.
    static let loweredToolResultProtection = [2, 1]

    public init(policy: RequestContextReducer.Policy = RequestContextReducer.Policy()) {
        self.policy = policy
        self.protectedToolResults = policy.keepRecentToolExchanges
    }

    /// Protects the next lower number of newest tool results. False when
    /// already at the last step. Only `AgentLoop` calls it.
    func lowerToolResultProtection() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let next = Self.loweredToolResultProtection.first(where: { $0 < protectedToolResults }) else {
            return false
        }
        protectedToolResults = next
        return true
    }

    private var effectivePolicy: RequestContextReducer.Policy {
        lock.lock(); defer { lock.unlock() }
        var effective = policy
        effective.keepRecentToolExchanges = protectedToolResults
        return effective
    }

    public var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return active
    }

    /// Only `AgentLoop` activates; the App cannot (module-internal).
    func activate() {
        lock.lock(); defer { lock.unlock() }
        active = true
    }

    /// Last stage of the delivery projection. Identity while inactive.
    public func apply(_ messages: [LLMMessage]) -> [LLMMessage] {
        guard isActive else { return messages }
        return RequestContextReducer.reduce(messages, policy: effectivePolicy, memo: memo).messages
    }

    /// What `apply` would produce, regardless of activation. Used by the loop
    /// to estimate the reduced request before deciding to activate.
    func reducedView(of messages: [LLMMessage]) -> RequestContextReducer.Outcome {
        RequestContextReducer.reduce(messages, policy: effectivePolicy, memo: memo)
    }
}
