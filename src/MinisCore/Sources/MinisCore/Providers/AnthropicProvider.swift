import Foundation

/// Retains content-block positions independently of arrival order. Tool JSON is never
/// published as text and remains invalid until a complete object can be decoded.
private struct AnthropicReplyAssembly {
    private var blockOrder: [Int] = []
    private var blocks: [Int: AnthropicProvider.AssistantStreamBlock] = [:]
    private var fragmentedInputs: Set<Int> = []
    private var hasAmbiguousToolSlots = false
    private var messageUsage: LLMUsage?
    private var deltaUsage: LLMUsage?
    private(set) var stopReason: String?
    private(set) var stopped = false
    /// 最近一次 accept 产生的思考增量（显示用），每次调用开头清空。
    private(set) var pendingThinking: String?

    mutating func accept(_ object: [String: Any], argumentByteLimit: Int) throws -> String? {
        pendingThinking = nil
        guard !stopped else { return nil }
        guard let type = object["type"] as? String else { throw badShape() }
        switch type {
        case "message_start":
            guard let message = object["message"] as? [String: Any] else { throw badShape() }
            if let value = message["usage"] as? [String: Any] {
                messageUsage = AnthropicProvider.parseMessagesUsage(value)
            }
            if let reason = message["stop_reason"] as? String { stopReason = reason }
        case "content_block_start":
            guard let index = object["index"] as? Int,
                  let value = object["content_block"] as? [String: Any],
                  let kind = value["type"] as? String else { throw badShape() }
            var block = AnthropicProvider.AssistantStreamBlock(type: kind,
                text: value["text"] as? String ?? "", toolID: value["id"] as? String,
                toolName: value["name"] as? String)
            if kind == "thinking" {
                block.thinking = value["thinking"] as? String ?? ""
                block.signature = value["signature"] as? String ?? ""
                if !block.thinking.isEmpty { pendingThinking = block.thinking }
            } else if kind == "redacted_thinking" {
                block.redactedData = value["data"] as? String
                pendingThinking = "（思考内容已加密）"
            }
            if let input = value["input"] as? [String: Any],
               let encoded = try? JSONSerialization.data(withJSONObject: input) {
                block.toolInputJSON = String(decoding: encoded, as: UTF8.self)
            }
            if let prior = blocks[index], prior.type == "tool_use" || kind == "tool_use" {
                hasAmbiguousToolSlots = true
            }
            if blocks[index] == nil { blockOrder.append(index) }
            blocks[index] = block
            fragmentedInputs.remove(index)
            return kind == "text" ? block.text : nil
        case "content_block_delta":
            guard let index = object["index"] as? Int,
                  let delta = object["delta"] as? [String: Any],
                  let kind = delta["type"] as? String else { throw badShape() }
            switch kind {
            case "text_delta":
                guard let text = delta["text"] as? String else { throw badShape() }
                var block = blocks[index] ?? AnthropicProvider.AssistantStreamBlock(type: "text")
                guard block.type == "text" else { throw badShape() }
                if blocks[index] == nil { blockOrder.append(index) }
                block.text += text
                blocks[index] = block
                return text
            case "thinking_delta":
                guard let piece = delta["thinking"] as? String else { throw badShape() }
                var block = blocks[index] ?? AnthropicProvider.AssistantStreamBlock(type: "thinking")
                guard block.type == "thinking" else { throw badShape() }
                if blocks[index] == nil { blockOrder.append(index) }
                block.thinking += piece
                blocks[index] = block
                if !piece.isEmpty { pendingThinking = piece }
            case "signature_delta":
                guard var block = blocks[index], block.type == "thinking",
                      let piece = delta["signature"] as? String else { throw badShape() }
                block.signature += piece
                blocks[index] = block
            case "input_json_delta":
                guard var block = blocks[index], block.type == "tool_use",
                      let piece = delta["partial_json"] as? String else { throw badShape() }
                if fragmentedInputs.insert(index).inserted { block.toolInputJSON = "" }
                if block.toolInputOversized { break }
                if piece.utf8.count > argumentByteLimit - block.toolInputJSON.utf8.count {
                    // V-6：不整轮失败；丢掉已累计的参数并标记，收尾时回给模型固定的工具错误。
                    block.toolInputJSON = ""
                    block.toolInputOversized = true
                } else {
                    block.toolInputJSON += piece
                }
                blocks[index] = block
            default: break
            }
        case "content_block_stop":
            guard object["index"] is Int else { throw badShape() }
        case "message_delta":
            guard let delta = object["delta"] as? [String: Any] else { throw badShape() }
            if let reason = delta["stop_reason"] as? String { stopReason = reason }
            if let value = object["usage"] as? [String: Any] { deltaUsage = AnthropicProvider.parseMessagesUsage(value) }
        case "message_stop": stopped = true
        case "error":
            throw ProviderAnthropicErrorProjectionPolicy.streamLLMError(object)
        default: break
        }
        return nil
    }

    func completedResponse(offeredNames: [String]) -> LLMResponse {
        AnthropicProvider.assistantStreamCompletedResponse(blockOrder: blockOrder, blocks: blocks,
            stopReason: stopReason, messageUsage: messageUsage, deltaUsage: deltaUsage,
            countToolSlots: !hasAmbiguousToolSlots, offeredNames: offeredNames)
    }

    private func badShape() -> LLMError { .decodingError(underlying: ShapeFailure.invalidEvent) }
    private enum ShapeFailure: Error { case invalidEvent }
}

private enum AnthropicModelPolicy {
    static func version(in model: String) -> (major: Int, minor: Int)? {
        let text = model.lowercased()
        // Vendor prefixes are permitted, but a non-Claude model with incidental
        // digits must not acquire Claude-specific request policies.
        let components = text.split(separator: "/", omittingEmptySubsequences: true)
        guard let name = components.last, name == "claude" || name.hasPrefix("claude-") else { return nil }
        let segments = name.split(separator: "-", omittingEmptySubsequences: true).dropFirst()
        for (offset, segment) in segments.enumerated() {
            let pieces = segment.split(separator: ".", omittingEmptySubsequences: false)
            guard let major = pieces.first.flatMap({ Int($0) }), major >= 0 else { continue }
            if pieces.count == 2 {
                guard let minor = Int(pieces[1]), minor >= 0 else { return nil }
                return (major, minor)
            }
            guard pieces.count == 1 else { return nil }
            let following = segments.dropFirst(offset + 1).first
            return (major, following.flatMap { Int($0) } ?? 0)
        }
        return nil
    }

    static func omitsTemperature(model: String) -> Bool {
        guard let version = version(in: model) else { return false }
        return version.major > 4 || (version.major == 4 && version.minor >= 6)
    }
}

struct ProviderWireJSON: @unchecked Sendable {
    let object: [String: Any]
}

func providerWireHeaders(_ response: HTTPURLResponse) -> [String: String] {
    var result: [String: String] = [:]
    for (key, value) in response.allHeaderFields { result[String(describing: key)] = String(describing: value) }
    return result
}

public final class AnthropicProvider: LLMProvider, AssistantStreamingLLMProvider,
    ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
    public let name = "Anthropic"
    public static let wireCapabilities: Set<ProviderCapability> = [.streaming, .tools, .vision]
    public var capabilities: Set<ProviderCapability> { Self.wireCapabilities }

    private struct Configuration: Sendable {
        var model: LLMModel
        var base: String?
        var headers: [String: String] = [:]
        var revision: UInt64 = 0
        var identity: String?
        var identityFollowsEndpoint = false
    }
    private let lock = NSLock()
    private var configuration: Configuration
    private let key: String
    private let session: URLSession
    private let probe: (@Sendable () -> Void)?

    public init(apiKey: String, model: LLMModel = .claudeSonnet46, basePath: String? = nil,
                session: URLSession? = nil, requestAssemblyProbe: (@Sendable () -> Void)? = nil) {
        key = apiKey
        configuration = Configuration(model: model, base: basePath)
        probe = requestAssemblyProbe
        if let session { self.session = session }
        else {
            let options = URLSessionConfiguration.default
            options.timeoutIntervalForRequest = 600
            self.session = URLSession(configuration: options, delegate: ProviderRedirectGuard.shared, delegateQueue: nil)
        }
    }

    public var model: LLMModel {
        get { lock.withLock { configuration.model } }
        set { change { $0.model = newValue } }
    }
    public var customBasePath: String? {
        get { lock.withLock { configuration.base } }
        set { change { $0.base = newValue } }
    }
    public var extraHeaders: [String: String] {
        get { lock.withLock { configuration.headers } }
        set { change { $0.headers = newValue } }
    }
    public var runtimeConfigurationMaterial: String? {
        get { lock.withLock {
            configuration.identityFollowsEndpoint ? (configuration.base ?? "") : configuration.identity
        } }
        set { change {
            $0.identity = newValue
            $0.identityFollowsEndpoint = newValue != nil && $0.base != nil
        } }
    }
    private func change(_ edit: (inout Configuration) -> Void) {
        lock.withLock { edit(&configuration); configuration.revision &+= 1 }
    }

    public static func parseClaudeVersion(_ modelId: String) -> (major: Int, minor: Int)? {
        AnthropicModelPolicy.version(in: modelId)
    }
    public static func modelRejectsTemperature(_ modelId: String) -> Bool {
        AnthropicModelPolicy.omitsTemperature(model: modelId)
    }
    public static func modelUsesAdaptiveThinking(_ modelId: String) -> Bool {
        modelRejectsTemperature(modelId)
    }
    public func effectiveTemperature(_ temperature: Double?) -> Double? {
        Self.modelRejectsTemperature(model.id) ? nil : temperature
    }

    private static func anthropicImageBlocks(_ images: [LLMMessage.ImageAttachment],
                                             mediaCapabilities: ModelCapabilities?) -> [[String: Any]] {
        func textBlock(_ text: String) -> [String: Any] { ["text": text, "type": "text"] }
        return images.map { (attachment) -> [String: Any] in
            let kind = MediaPartKind.classify(mimeType: attachment.mimeType)
            let admission: MediaGateDecision?
            switch (kind, mediaCapabilities) {
            case (.rasterImage, .some(let capabilities)):
                admission = MediaPayloadValidation.decision(data: attachment.data,
                    mimeType: attachment.mimeType, capabilities: capabilities, wire: .anthropic)
            case (.rasterImage, .none):
                admission = nil
            case (_, .some(let capabilities)):
                let capabilityDecision = MediaCapabilityGate.decide(mimeType: attachment.mimeType,
                    capabilities: capabilities)
                admission = capabilityDecision.isAllowed
                    ? .rejected(kind: kind, reason: "Anthropic image content supports raster images only")
                    : capabilityDecision
            case (_, .none):
                admission = .rejected(kind: kind, reason: MediaPayloadValidation.Failure.unsupportedWire.reason)
            }
            let rejectedText = admission.flatMap {
                MediaCapabilityGate.rejectionNote(for: $0, mimeType: attachment.mimeType)
            }
            if let rejectedText { return textBlock(rejectedText) }
            let source: [String: Any] = [
                "data": attachment.data.base64EncodedString(),
                "media_type": attachment.mimeType,
                "type": "base64"
            ]
            return ["source": source, "type": "image"]
        }
    }

    public static func anthropicMessageDict(_ msg: LLMMessage,
                                            mediaCapabilities: ModelCapabilities? = nil) -> [String: Any] {
        var envelope: [String: Any] = ["role": msg.role.rawValue]
        switch msg.role {
        case .tool:
            // 工具返回的图片放进 tool_result 的内容数组（文字块 + 图片块）。
            let resultContent: Any = msg.images.isEmpty ? msg.content
                : ([["text": msg.content, "type": "text"] as [String: Any]]
                   + anthropicImageBlocks(msg.images, mediaCapabilities: mediaCapabilities))
            let resultBlock: [String: Any] = [
                "content": resultContent,
                "tool_use_id": msg.toolCallID ?? "unknown_tool_call",
                "type": "tool_result"
            ]
            envelope["role"] = "user"
            envelope["content"] = [resultBlock]
            return envelope
        case .user, .assistant:
            break
        }
        guard !(msg.images.isEmpty && msg.toolCalls.isEmpty && (mediaCapabilities == nil || msg.audios.isEmpty)) else {
            envelope["content"] = msg.content
            return envelope
        }

        func textBlock(_ text: String) -> [String: Any] { ["text": text, "type": "text"] }

        let imageBlocks = anthropicImageBlocks(msg.images, mediaCapabilities: mediaCapabilities)
        let audioBlocks = msg.audios.map { attachment in
            let mime: String
            switch attachment.format.lowercased() {
            case "wav": mime = "audio/wav"
            default: mime = "audio/mpeg"
            }
            return textBlock(MediaCapabilityGate.rejectionNote(mimeType: mime,
                reason: MediaPayloadValidation.Failure.unsupportedWire.reason))
        }
        let proseBlocks = msg.content.isEmpty ? [] : [textBlock(msg.content)]
        let invocationBlocks: [[String: Any]] = msg.toolCalls.compactMap { invocation in
            let candidate: [String: Any] = ["input": invocation.arguments,
                "name": invocation.name, "type": "tool_use", "id": invocation.id]
            guard let admitted = ProviderToolCallBoundary.parseAnthropic(candidate) else { return nil }
            return ["input": admitted.arguments, "name": admitted.name,
                "id": admitted.id, "type": "tool_use"]
        }
        let thinkingBlocks: [[String: Any]] = msg.role == .assistant
            ? (msg.toolCalls.first?.thinkingBlocks ?? []) : []
        envelope["content"] = thinkingBlocks + imageBlocks + audioBlocks + proseBlocks + invocationBlocks
        return envelope
    }

    public static func parseNativeToolCalls(from json: [String: Any]) -> [LLMToolCall] {
        let items = (json["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "tool_use" }
        guard items.count <= ProviderToolCallBoundary.maximumCalls else { return [] }
        let calls = items.compactMap(ProviderToolCallBoundary.parseAnthropicAdmittingOversized)
        return ProviderToolCallBoundary.hasUniqueIdentifiers(calls) ? calls : []
    }
    public static func parseMessagesUsage(_ usage: [String: Any]) -> LLMUsage {
        LLMUsage(inputTokens: usage["input_tokens"] as? Int ?? 0,
                 outputTokens: usage["output_tokens"] as? Int ?? 0,
                 cacheCreationInputTokens: usage["cache_creation_input_tokens"] as? Int,
                 cacheReadInputTokens: usage["cache_read_input_tokens"] as? Int,
                 cacheHitInputTokens: LLMUsage.anthropicCacheHitInputTokens(usage))
    }
    public static func parseMessagesResult(_ json: [String: Any]) -> LLMResponse {
        parseMessagesResult(json, offeredNames: nil)
    }

    /// 本轮可原样回传的思考块（thinking 需带 signature；redacted_thinking 需带 data）。
    static func replayableThinkingBlocks(_ content: [[String: Any]]) -> [[String: Any]] {
        content.compactMap { block -> [String: Any]? in
            switch block["type"] as? String {
            case "thinking":
                guard let thought = block["thinking"] as? String,
                      let signature = block["signature"] as? String, !signature.isEmpty else { return nil }
                return ["type": "thinking", "thinking": thought, "signature": signature]
            case "redacted_thinking":
                guard let data = block["data"] as? String, !data.isEmpty else { return nil }
                return ["type": "redacted_thinking", "data": data]
            default: return nil
            }
        }
    }

    private static func parseMessagesResult(_ json: [String: Any], offeredNames: [String]?) -> LLMResponse {
        let content = json["content"] as? [[String: Any]] ?? []
        let text = content.compactMap { block -> String? in
            block["type"] as? String == "text" ? block["text"] as? String : nil
        }.joined()
        let stopReason = json["stop_reason"] as? String
        let items = content.filter { $0["type"] as? String == "tool_use" }
        let withinCallLimit = items.count <= ProviderToolCallBoundary.maximumCalls
        let parsed = withinCallLimit ? items.map(ProviderToolCallBoundary.parseAnthropicAdmittingOversized) : []
        let parsedCalls = parsed.compactMap { $0 }
        let uniqueIdentifiers = ProviderToolCallBoundary.hasUniqueIdentifiers(parsedCalls)
        var calls = uniqueIdentifiers ? parsedCalls : []
        let replay = replayableThinkingBlocks(content)
        if !replay.isEmpty, !calls.isEmpty { calls[0].thinkingBlocks = replay }
        let ids = items.compactMap { $0["id"] as? String }
        let discarded = stopReason == "max_tokens" && withinCallLimit
            && Set(ids).count == ids.count ? max(0, items.count - calls.count) : 0
        let notice: DiscardedToolCallNotice?
        if discarded > 0, uniqueIdentifiers, let offeredNames {
            notice = DiscardedToolCallNotice(candidateNames: zip(items, parsed).filter {
                $0.1 == nil
            }.map { $0.0["name"] as? String }, offeredNames: offeredNames, count: discarded)
        } else {
            notice = nil
        }
        return LLMResponse(text: text, stopReason: stopReason,
            usage: (json["usage"] as? [String: Any]).map(parseMessagesUsage),
            mediaAttachments: [], toolCalls: calls, discardedToolCallCount: discarded,
            discardedToolCallNotice: notice)
    }

    public func mapError(_ error: Error) -> LLMError {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return .cancelled }
        if let known = error as? LLMError { return known }
        if error is URLError { return .networkError(underlying: error) }
        return .providerError(message: "The provider request failed.")
    }
    public func mapHTTPError(statusCode: Int, body: String) -> LLMError {
        mapHTTPError(statusCode: statusCode, body: body, headers: [:])
    }
    public func mapHTTPError(statusCode: Int, body: String, headers: [String: String]) -> LLMError {
        if ProviderContextOverflowClassifier.isAnthropicOverflow(statusCode: statusCode, body: body) { return .contextLengthExceeded }
        let safe = ProviderAnthropicErrorProjectionPolicy.project(statusCode: statusCode, headers: headers, body: body)
        return .httpStatus(code: statusCode, detail: safe.safeDetail)
    }

    private nonisolated(nonsending) func request(messages: [LLMMessage], system: String?,
        tools: [AgentToolDefinition], tokens: Int, temperature: Double?, stream: Bool,
        thinking: ThinkingLevel? = nil) async throws -> (URLRequest, UInt64) {
        let state = lock.withLock { configuration }
        let observer = AssistantThinkingParameters.reportApplication
        let key = key, probe = probe
        // Task-local hints do not cross `Task.detached`: read the caller's value here.
        let promptCaching = LLMRequestHints.promptCaching
        let worker = Task.detached { () throws -> URLRequest in
            try Task.checkCancellation()
            probe?()
            let base: URL
            do { base = try CustomProviderURL.validate(state.base ?? "https://api.anthropic.com") }
            catch is CustomProviderURL.Failure {
                throw LLMError.providerError(message: "The provider endpoint was rejected.")
            }
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
            while components.path.hasSuffix("/") { components.path.removeLast() }
            var endpoint = components.url!
            if endpoint.lastPathComponent != "v1" { endpoint.appendPathComponent("v1") }
            endpoint.appendPathComponent("messages")
            var body: [String: Any] = ["model": state.model.id, "max_tokens": tokens,
                "messages": messages.map { Self.anthropicMessageDict($0, mediaCapabilities: state.model.capabilities) },
                "stream": stream]
            if let system, !system.isEmpty { body["system"] = system }
            if let temperature, !Self.modelRejectsTemperature(state.model.id) { body["temperature"] = temperature }
            if !tools.isEmpty { body["tools"] = tools.map(\.providerAnthropicToolDict) }
            AssistantThinkingParameters.apply(thinking, modelID: state.model.id, wire: .anthropic, body: &body, report: observer)
            // 只给 Claude 模型打缓存断点：非 Claude 模型走 Anthropic 兼容网关时，不给网关多带它可能不认的字段和结构。
            // 压缩的摘要请求只发一次，调用方用 `LLMRequestHints.promptCaching` 关掉断点（省一次缓存写入加价）。
            if promptCaching, AnthropicModelPolicy.version(in: state.model.id) != nil {
                Self.addPromptCacheBreakpoints(to: &body)
            }
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            for (field, value) in state.headers { request.setValue(value, forHTTPHeaderField: field) }
            // 键顺序固定：缓存按请求前缀的字节匹配，字典遍历顺序不稳会让命中随机落空。
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            try Task.checkCancellation()
            return request
        }
        let assembled = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        return (assembled, state.revision)
    }

    private func verifyRevision(_ revision: UInt64) throws {
        try lock.withLock {
            try Task.checkCancellation()
            guard configuration.revision == revision else { throw CancellationError() }
        }
    }

    private nonisolated(nonsending) func open(_ assembledRequest: URLRequest, revision: UInt64) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            try verifyRevision(revision)
            (bytes, response) = try await session.bytes(for: assembledRequest)
        } catch { throw mapError(error) }
        guard let http = response as? HTTPURLResponse else {
            bytes.task.cancel(); throw ProviderResponseStreamPolicyError.missingHTTPResponse
        }
        if !(200...299).contains(http.statusCode) {
            defer { bytes.task.cancel() }
            var data = Data()
            do {
                for try await byte in bytes {
                    try Task.checkCancellation()
                    data.append(byte)
                    if data.count == 65536 { break }
                }
            } catch { throw mapError(error) }
            throw mapHTTPError(statusCode: http.statusCode, body: String(decoding: data, as: UTF8.self),
                               headers: providerWireHeaders(http))
        }
        return (bytes, http)
    }

    public nonisolated(nonsending) func sendMessage(messages: [LLMMessage], systemPrompt: String?,
        maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt, tools: [], maxTokens: maxTokens, temperature: temperature)
    }
    public nonisolated(nonsending) func sendMessage(messages: [LLMMessage], systemPrompt: String?,
        tools: [AgentToolDefinition], maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        do {
            let (assembledRequest, revision) = try await request(messages: messages, system: systemPrompt, tools: tools,
                tokens: maxTokens, temperature: temperature, stream: false)
            let (bytes, response) = try await open(assembledRequest, revision: revision)
            defer { bytes.task.cancel() }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < ProviderBufferedResponsePolicy.maximumDecodedResponseBytes else {
                    throw ProviderBufferedResponsePolicyError.responseTooLarge
                }
                data.append(byte)
            }
            try ProviderBufferedResponsePolicy.validateJSONResponse(response, data: data)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw LLMError.decodingError(underlying: DecodingFailure.notObject)
            }
            return Self.parseMessagesResult(object, offeredNames: tools.map(\.name))
        } catch { throw mapError(error) }
    }
    private enum DecodingFailure: Error { case notObject }
}

extension AnthropicProvider {
    struct AssistantStreamBlock {
        var type: String
        var text: String = ""
        var toolID: String? = nil
        var toolName: String? = nil
        var toolInputJSON: String = ""
        /// 工具参数累计超过边界上限（V-6）：参数已丢弃，收尾时作为超限调用回给模型固定错误。
        var toolInputOversized = false
        var thinking: String = ""
        var signature: String = ""
        var redactedData: String? = nil
    }

    static func mergedAssistantStreamUsage(messageUsage: LLMUsage?, deltaUsage: LLMUsage?) -> LLMUsage? {
        guard let anchor = messageUsage ?? deltaUsage else { return nil }
        let cacheHit: Int?
        if let messageUsage { cacheHit = messageUsage.cacheHitInputTokens }
        else { cacheHit = deltaUsage?.cacheHitInputTokens }
        return LLMUsage(inputTokens: messageUsage?.inputTokens ?? anchor.inputTokens,
            outputTokens: deltaUsage?.outputTokens ?? anchor.outputTokens,
            cacheCreationInputTokens: messageUsage?.cacheCreationInputTokens ?? deltaUsage?.cacheCreationInputTokens,
            cacheReadInputTokens: messageUsage?.cacheReadInputTokens ?? deltaUsage?.cacheReadInputTokens,
            cacheHitInputTokens: cacheHit)
    }

    static func assistantStreamCompletedResponse(blockOrder: [Int], blocks: [Int: AssistantStreamBlock],
        stopReason: String?, messageUsage: LLMUsage?, deltaUsage: LLMUsage?,
        countToolSlots: Bool = true, offeredNames: [String]? = nil) -> LLMResponse {
        let content: [[String: Any]] = blockOrder.compactMap { index in
            guard let block = blocks[index] else { return nil }
            switch block.type {
            case "text":
                return block.text.isEmpty ? nil : ["type": "text", "text": block.text]
            case "tool_use":
                var candidate: [String: Any] = ["type": "tool_use"]
                if let id = block.toolID { candidate["id"] = id }
                if let name = block.toolName { candidate["name"] = name }
                if block.toolInputOversized { candidate[ProviderToolCallBoundary.oversizedMarkerKey] = true }
                if let data = block.toolInputJSON.data(using: .utf8),
                   let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    candidate["input"] = object
                }
                return candidate
            case "thinking":
                return block.signature.isEmpty ? nil
                    : ["type": "thinking", "thinking": block.thinking, "signature": block.signature]
            case "redacted_thinking":
                return block.redactedData.map { ["type": "redacted_thinking", "data": $0] }
            default: return nil
            }
        }
        var result: [String: Any] = ["content": content]
        if countToolSlots, let stopReason { result["stop_reason"] = stopReason }
        let decoded = parseMessagesResult(result, offeredNames: offeredNames)
        return LLMResponse(text: decoded.text, stopReason: stopReason,
            usage: mergedAssistantStreamUsage(messageUsage: messageUsage, deltaUsage: deltaUsage),
            mediaAttachments: [], toolCalls: decoded.toolCalls,
            discardedToolCallCount: decoded.discardedToolCallCount,
            discardedToolCallNotice: decoded.discardedToolCallNotice)
    }
}

extension AnthropicProvider {
    /// 流在 message_stop 之前就结束：瞬时故障，可由上层按"还没有任何输出"重试。
    static func prematureStreamEnd() -> LLMError {
        .transientError(message: "Provider stream ended before a complete response was received.")
    }

    /// 提示缓存（对齐 Claude Code）：在最后一个工具定义、系统提示、最后一条消息的最后一个可缓存块
    /// 各打一个 `cache_control: ephemeral` 断点，共 3 个，不超过 Anthropic 允许的 4 个。
    /// 缓存按 工具 → 系统 → 消息 的顺序做前缀匹配，所以下一步请求只多出末尾新增的内容。
    /// 低于模型最小可缓存长度时服务端会忽略断点，不报错。
    static func addPromptCacheBreakpoints(to body: inout [String: Any]) {
        let marker: [String: Any] = ["type": "ephemeral"]
        if var tools = body["tools"] as? [[String: Any]], !tools.isEmpty {
            tools[tools.count - 1]["cache_control"] = marker
            body["tools"] = tools
        }
        if let system = body["system"] as? String, !system.isEmpty {
            body["system"] = [["type": "text", "text": system, "cache_control": marker] as [String: Any]]
        }
        guard var messages = body["messages"] as? [[String: Any]], let last = messages.indices.last else { return }
        var message = messages[last]
        if let text = message["content"] as? String {
            // 空文本块不能带 cache_control。
            guard !text.isEmpty else { return }
            message["content"] = [["type": "text", "text": text, "cache_control": marker] as [String: Any]]
        } else if var blocks = message["content"] as? [[String: Any]],
                  let index = blocks.lastIndex(where: { block in
                      switch block["type"] as? String {
                      case "text": return !((block["text"] as? String) ?? "").isEmpty
                      case "image", "tool_use", "tool_result", "document": return true
                      default: return false  // thinking / redacted_thinking 不能打缓存标记
                      }
                  }) {
            blocks[index]["cache_control"] = marker
            message["content"] = blocks
        } else {
            return
        }
        messages[last] = message
        body["messages"] = messages
    }

    public nonisolated(nonsending) func streamMessage(messages: [LLMMessage], systemPrompt: String?,
        maxTokens: Int, temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        let (assembledRequest, revision) = try await request(messages: messages, system: systemPrompt, tools: [],
            tokens: maxTokens, temperature: temperature, stream: true)
        let (bytes, response) = try await open(assembledRequest, revision: revision)
        do { try ProviderResponseStreamPolicy.validateSSEResponse(response) }
        catch { bytes.task.cancel(); throw error }
        return AsyncThrowingStream { continuation in
            let producer = Task {
                defer { bytes.task.cancel() }
                do {
                    try ProviderStreamCancellationPolicy.yield(.started, to: continuation)
                    var budget = ProviderResponseStreamPolicy.DecodedByteBudget()
                    var parser = SSEStreamParser()
                    var done = false
                    var stopReason: String?
                    func publish(_ event: SSEStreamParser.Event) throws -> Bool {
                        guard let object = event.jsonObject else {
                            throw LLMError.decodingError(underlying: DecodingFailure.notObject)
                        }
                        try ProviderAnthropicResponseShapePolicy.validate(object)
                        guard let decoded = AnthropicStreamDecoder.decode(json: object) else {
                            throw ProviderAnthropicResponseShapePolicyError.invalidEventShape
                        }
                        switch decoded {
                        case .contentBlockDelta(_, let text, _):
                            if let text { try ProviderStreamCancellationPolicy.yield(.text(text), to: continuation) }
                        case .messageDelta(let reason, let usage):
                            if let reason { stopReason = reason }
                            if let usage { try ProviderStreamCancellationPolicy.yield(.usage(usage), to: continuation) }
                        case .messageStop:
                            try ProviderStreamCancellationPolicy.yield(.finished(stopReason: stopReason), to: continuation)
                            return true
                        case .error:
                            throw ProviderAnthropicErrorProjectionPolicy.streamLLMError(object)
                        default: break
                        }
                        return false
                    }
                    var budgetLine = Data()
                    var followsCR = false
                    for try await byte in bytes {
                        try ProviderStreamCancellationPolicy.check()
                        if byte == 13 || byte == 10 {
                            if byte != 10 || !followsCR {
                                try budget.consume(line: String(decoding: budgetLine, as: UTF8.self))
                                budgetLine.removeAll(keepingCapacity: true)
                            }
                            followsCR = byte == 13
                        } else {
                            followsCR = false
                            budgetLine.append(byte)
                            guard budgetLine.count <= ProviderResponseStreamPolicy.maximumDecodedLineBytes else {
                                throw ProviderResponseStreamPolicyError.lineTooLarge
                            }
                        }
                        for output in parser.feed(Data([byte])) {
                            if case .event(let event) = output { done = try publish(event) }
                            if done { break }
                        }
                        if done { break }
                    }
                    if !done && !budgetLine.isEmpty {
                        try budget.consume(line: String(decoding: budgetLine, as: UTF8.self))
                    }
                    if !done, let event = parser.flushPending() { done = try publish(event) }
                    try ProviderStreamCancellationPolicy.check()
                    // 已收到结束原因（message_delta）却没有 message_stop 就关连接：回答已经完整，按正常结束处理；
                    // 两者都没有才是提前断流。
                    if !done, let stopReason {
                        try ProviderStreamCancellationPolicy.yield(.finished(stopReason: stopReason), to: continuation)
                        done = true
                    }
                    guard done else { throw Self.prematureStreamEnd() }
                    continuation.finish()
                } catch { continuation.finish(throwing: self.mapError(error)) }
            }
            continuation.onTermination = { _ in producer.cancel(); bytes.task.cancel() }
        }
    }

    public nonisolated(nonsending) func streamAssistantMessage(messages: [LLMMessage], systemPrompt: String?,
        tools: [AgentToolDefinition], maxTokens: Int, temperature: Double?) async throws -> AsyncThrowingStream<LLMAssistantStreamEvent, Error> {
        try await streamAssistantMessage(messages: messages, systemPrompt: systemPrompt, tools: tools,
            maxTokens: maxTokens, temperature: temperature, thinkingLevel: nil)
    }
    public nonisolated(nonsending) func streamAssistantMessage(messages: [LLMMessage], systemPrompt: String?,
        tools: [AgentToolDefinition], maxTokens: Int, temperature: Double?,
        thinkingLevel: ThinkingLevel?) async throws -> AsyncThrowingStream<LLMAssistantStreamEvent, Error> {
        let (assembledRequest, revision) = try await request(messages: messages, system: systemPrompt, tools: tools,
            tokens: maxTokens, temperature: temperature, stream: true, thinking: thinkingLevel)
        let (bytes, response) = try await open(assembledRequest, revision: revision)
        do { try ProviderResponseStreamPolicy.validateSSEResponse(response) }
        catch { bytes.task.cancel(); throw error }
        return AsyncThrowingStream { continuation in
            let producer = Task {
                defer { bytes.task.cancel() }
                do {
                    var budget = ProviderResponseStreamPolicy.DecodedByteBudget()
                    var result = AnthropicReplyAssembly()
                    for try await line in bytes.lines {
                        try ProviderStreamCancellationPolicy.check()
                        try budget.consume(line: line)
                        guard line.hasPrefix("data:") else { continue }
                        var payload = String(line.dropFirst(5))
                        if payload.hasPrefix(" ") { payload.removeFirst() }
                        guard let data = payload.data(using: .utf8),
                              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            throw LLMError.decodingError(underlying: DecodingFailure.notObject)
                        }
                        try ProviderAnthropicResponseShapePolicy.validate(object)
                        if object["type"] as? String == "error" {
                            throw ProviderAnthropicErrorProjectionPolicy.streamLLMError(object)
                        }
                        if let text = try result.accept(object, argumentByteLimit: ProviderToolCallBoundary.maximumArgumentsBytes), !text.isEmpty {
                            try ProviderStreamCancellationPolicy.yield(.textDelta(text), to: continuation)
                        }
                        if let thought = result.pendingThinking, !thought.isEmpty {
                            try ProviderStreamCancellationPolicy.yield(.thinkingDelta(thought), to: continuation)
                        }
                        if result.stopped { break }
                    }
                    // 既没收到 message_stop 也没收到结束原因就断流（网关超时后正常关连接等）：半截回答不能当完整回答。
                    // 已收到结束原因（message_delta）只是没发 message_stop 的网关，回答是完整的，照常结束。
                    try ProviderStreamCancellationPolicy.check()
                    guard result.stopped || result.stopReason != nil else { throw Self.prematureStreamEnd() }
                    try ProviderStreamCancellationPolicy.yield(.completed(result.completedResponse(offeredNames: tools.map(\.name))), to: continuation)
                    continuation.finish()
                } catch { continuation.finish(throwing: self.mapError(error)) }
            }
            continuation.onTermination = { _ in producer.cancel(); bytes.task.cancel() }
        }
    }
}
