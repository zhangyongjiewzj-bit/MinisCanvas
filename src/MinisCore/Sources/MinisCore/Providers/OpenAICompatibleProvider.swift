import Foundation

public final class OpenAICompatibleProvider: LLMProvider, AssistantStreamingLLMProvider,
    ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
    public static let wireCapabilities: Set<ProviderCapability> = [.streaming, .tools, .vision, .audio, .image]
    public var capabilities: Set<ProviderCapability> { Self.wireCapabilities }
    public let name: String
    public let controlledFieldLoopbackOnly: Bool
    private let key: String
    private let session: URLSession
    private let ledger: OwnedMMOutboundLedger?
    private let lock = NSLock()
    private struct Settings: Sendable {
        var model: LLMModel
        var base: String?
        var appendVersion: Bool
        var headers: [String: String] = [:]
        var router = false
        var identity: String?
        var followsEndpoint = false
        var generation: UInt64 = 0
        var probe: (@Sendable () -> Void)?
    }
    private var settings: Settings

    public convenience init(apiKey: String, model: LLMModel = .gpt4oMini, customBaseURL: String? = nil,
        appendV1Suffix: Bool = true, session: URLSession? = nil, providerName: String = "OpenAI",
        ownedMMOutboundLedger: OwnedMMOutboundLedger? = nil) {
        self.init(apiKey: apiKey, model: model, customBaseURL: customBaseURL, appendV1Suffix: appendV1Suffix,
            session: session, controlledFieldLoopbackOnly: false, providerName: providerName,
            ownedMMOutboundLedger: ownedMMOutboundLedger)
    }
    init(apiKey: String, model: LLMModel, customBaseURL: String?, appendV1Suffix: Bool,
        session: URLSession?, controlledFieldLoopbackOnly: Bool, providerName: String,
        ownedMMOutboundLedger: OwnedMMOutboundLedger? = nil) {
        key = apiKey
        name = providerName
        self.controlledFieldLoopbackOnly = controlledFieldLoopbackOnly
        ledger = ownedMMOutboundLedger
        settings = Settings(model: model, base: customBaseURL, appendVersion: appendV1Suffix)
        if let session { self.session = session }
        else if controlledFieldLoopbackOnly { self.session = ControlledFieldLoopbackSession.make() }
        else {
            let options = URLSessionConfiguration.default
            options.timeoutIntervalForRequest = 600
            self.session = URLSession(configuration: options, delegate: ProviderRedirectGuard.shared, delegateQueue: nil)
        }
    }
    private func modify(_ edit: (inout Settings) -> Void) {
        lock.withLock { edit(&settings); settings.generation &+= 1 }
    }
    public var model: LLMModel {
        get { lock.withLock { settings.model } }
        set { modify { $0.model = newValue } }
    }
    public var customBaseURL: String? {
        get { lock.withLock { settings.base } }
        set { modify { $0.base = newValue } }
    }
    public var appendV1Suffix: Bool {
        get { lock.withLock { settings.appendVersion } }
        set { modify { $0.appendVersion = newValue } }
    }
    public var extraHeaders: [String: String] {
        get { lock.withLock { settings.headers } }
        set { modify { $0.headers = newValue } }
    }
    public var useOpenRouterCompat: Bool {
        get { lock.withLock { settings.router } }
        set { modify { $0.router = newValue } }
    }
    var requestAssemblyProbe: (@Sendable () -> Void)? {
        get { lock.withLock { settings.probe } }
        set { modify { $0.probe = newValue } }
    }
    public var runtimeConfigurationMaterial: String? {
        get { lock.withLock {
            if settings.followsEndpoint {
                return (settings.base ?? "") + "|append-v1=\(settings.appendVersion ? "true" : "false")"
            }
            return settings.identity
        } }
        set { modify { $0.identity = newValue; $0.followsEndpoint = newValue != nil && $0.base != nil } }
    }

    /// 组装请求消息：工具返回的图片在这一批连续 tool 消息之后，各追加一条 user 消息
    /// （"[工具 xxx 返回的图片]" + image_url），因为 chat completions 的 tool 消息不支持图片。
    public static func openAIRequestMessages(_ messages: [LLMMessage],
                                             mediaCapabilities: ModelCapabilities? = nil,
                                             reasoningField: String? = nil) -> [[String: Any]] {
        var toolNames: [String: String] = [:]
        var items: [[String: Any]] = []
        var pendingImageMessages: [LLMMessage] = []
        func flush() {
            for message in pendingImageMessages {
                items.append(openAIMessageDict(message, mediaCapabilities: mediaCapabilities))
            }
            pendingImageMessages.removeAll()
        }
        for message in messages {
            if message.role != .tool { flush() }
            for call in message.toolCalls { toolNames[call.id] = call.name }
            items.append(openAIMessageDict(message, mediaCapabilities: mediaCapabilities,
                                           reasoningField: reasoningField))
            if message.role == .tool, !message.images.isEmpty {
                let name = message.toolCallID.flatMap { toolNames[$0] } ?? "未知工具"
                pendingImageMessages.append(LLMMessage(role: .user, content: "[工具 \(name) 返回的图片]",
                                                       images: message.images))
            }
        }
        flush()
        return items
    }

    public static func openAIMessageDict(_ msg: LLMMessage,
                                        mediaCapabilities: ModelCapabilities? = nil,
                                        reasoningField: String? = nil) -> [String: Any] {
        var result: [String: Any] = ["role": msg.role.rawValue, "content": msg.content]
        if let id = msg.toolCallID { result["tool_call_id"] = id }
        if !msg.toolCalls.isEmpty { result["tool_calls"] = msg.toolCalls.map(\.openAIDict) }
        // DeepSeek 思考模式 + 工具调用：同一轮内要把本轮助手消息的思考文本回传（只对声明了该字段的模型）。
        if msg.role == .assistant, let reasoningField, !reasoningField.isEmpty,
           let reasoning = msg.toolCalls.first?.reasoningContent, !reasoning.isEmpty {
            result[reasoningField] = reasoning
        }
        // tool 消息本身不能带图片，工具图片由 openAIRequestMessages 追加成后续 user 消息。
        guard msg.role != .tool, !msg.images.isEmpty || !msg.audios.isEmpty else { return result }
        var parts: [[String: Any]] = []
        for image in msg.images {
            let kind = MediaPartKind.classify(mimeType: image.mimeType)
            var rejection: String?
            if kind != .rasterImage {
                rejection = MediaCapabilityGate.rejectionNote(mimeType: image.mimeType,
                    reason: MediaPayloadValidation.Failure.unsupportedWire.reason)
            } else if let mediaCapabilities {
                let decision = MediaPayloadValidation.decision(data: image.data, mimeType: image.mimeType,
                    capabilities: mediaCapabilities, wire: .openaiCompatible)
                rejection = MediaCapabilityGate.rejectionNote(for: decision, mimeType: image.mimeType)
            }
            if let rejection { parts.append(["type": "text", "text": rejection]) }
            else {
                parts.append(["type": "image_url", "image_url": ["url": "data:\(image.mimeType);base64,\(image.data.base64EncodedString())"]])
            }
        }
        for audio in msg.audios {
            let mime = audio.format.lowercased() == "wav" ? "audio/wav" : "audio/mpeg"
            let bytes = Data(base64Encoded: audio.base64Data) ?? Data()
            var rejection: String?
            var format = audio.format
            if let mediaCapabilities {
                let decision = MediaPayloadValidation.decision(data: bytes, mimeType: mime,
                    capabilities: mediaCapabilities, wire: .openaiCompatible)
                rejection = MediaCapabilityGate.rejectionNote(for: decision, mimeType: mime)
                if rejection == nil { format = MediaPayloadValidation.audioFormat(bytes) ?? audio.format }
            }
            if let rejection { parts.append(["type": "text", "text": rejection]) }
            else { parts.append(["type": "input_audio", "input_audio": ["data": audio.base64Data, "format": format]]) }
        }
        if !msg.content.isEmpty { parts.append(["type": "text", "text": msg.content]) }
        result["content"] = parts
        return result
    }
    public static func parseDataURL(_ url: String, mediaType: LLMMediaAttachment.MediaType) -> LLMMediaAttachment? {
        guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") else { return nil }
        let header = url[url.index(url.startIndex, offsetBy: 5)..<comma].split(separator: ";", omittingEmptySubsequences: false)
        guard let mime = header.first, !mime.isEmpty, header.last?.lowercased() == "base64",
              let data = Data(base64Encoded: String(url[url.index(after: comma)...])) else { return nil }
        return LLMMediaAttachment(type: mediaType, mimeType: String(mime), data: data)
    }
    public static func parseNativeToolCalls(from message: [String: Any]) -> [LLMToolCall] {
        let items = message["tool_calls"] as? [[String: Any]] ?? []
        guard items.count <= ProviderToolCallBoundary.maximumCalls else { return [] }
        let calls = items.compactMap(ProviderToolCallBoundary.parseOpenAIAdmittingOversized)
        return ProviderToolCallBoundary.hasUniqueIdentifiers(calls) ? calls : []
    }
    public static func parseChatCompletionsUsage(_ usage: [String: Any]) -> LLMUsage {
        let reportedTotal = usage["prompt_tokens"] as? Int
        let total = reportedTotal ?? 0
        let details = usage["prompt_tokens_details"] as? [String: Any]
        let cached = details?["cached_tokens"] as? Int ?? usage["prompt_cache_hit_tokens"] as? Int
        // Without cache detail, a positive prompt_tokens is the complete input denominator.
        let valid = cached.map { total >= 0 && $0 >= 0 && $0 <= total } ?? ((reportedTotal ?? 0) > 0)
        return LLMUsage(inputTokens: valid ? total - (cached ?? 0) : total,
            outputTokens: usage["completion_tokens"] as? Int ?? 0,
            cacheReadInputTokens: cached, cacheHitInputTokens: valid ? total : nil)
    }
    public static func parseChatCompletionsResult(_ json: [String: Any]) -> LLMResponse {
        parseChatCompletionsResult(json, offeredNames: nil)
    }

    private static func parseChatCompletionsResult(_ json: [String: Any], offeredNames: [String]?) -> LLMResponse {
        let first = (json["choices"] as? [[String: Any]])?.first ?? [:]
        let message = first["message"] as? [String: Any] ?? [:]
        var text = message["content"] as? String ?? ""
        var media: [LLMMediaAttachment] = []
        func takeImage(_ part: [String: Any]) {
            let url = (part["image_url"] as? [String: Any])?["url"] as? String ?? part["image_url"] as? String
            if let url, let item = parseDataURL(url, mediaType: .image) { media.append(item) }
        }
        if let parts = message["content"] as? [[String: Any]] {
            text = ""
            for part in parts {
                if part["type"] as? String == "text" { text += part["text"] as? String ?? "" }
                else if part["type"] as? String == "image_url" { takeImage(part) }
            }
        }
        for part in message["images"] as? [[String: Any]] ?? [] { takeImage(part) }
        let stopReason = first["finish_reason"] as? String
        var calls = parseNativeToolCalls(from: message)
        if let reasoning = message["reasoning_content"] as? String, !reasoning.isEmpty, !calls.isEmpty {
            calls[0].reasoningContent = reasoning
        }
        let items = message["tool_calls"] as? [[String: Any]] ?? []
        let ids = items.compactMap { $0["id"] as? String }
        let discarded = stopReason == "length" && items.count <= ProviderToolCallBoundary.maximumCalls
            && Set(ids).count == ids.count
            ? max(0, items.filter { $0["type"] as? String == "function" }.count - calls.count) : 0
        let notice: DiscardedToolCallNotice?
        if discarded > 0, let offeredNames {
            let admittedIDs = Set(calls.map(\.id))
            notice = DiscardedToolCallNotice(candidateNames: items.filter {
                $0["type"] as? String == "function"
                    && !(($0["id"] as? String).map { admittedIDs.contains($0) } ?? false)
            }.map { ($0["function"] as? [String: Any])?["name"] as? String },
                offeredNames: offeredNames, count: discarded)
        } else {
            notice = nil
        }
        return LLMResponse(text: text, stopReason: stopReason,
            usage: (json["usage"] as? [String: Any]).map(parseChatCompletionsUsage),
            mediaAttachments: media, toolCalls: calls, discardedToolCallCount: discarded,
            discardedToolCallNotice: notice)
    }
    static func assistantStreamCompletedResponse(text: String, stopReason: String?, usage: LLMUsage?,
        toolCalls: OpenAIStreamDecoder.ToolCallAccumulator, countToolSlots: Bool = true,
        offeredNames: [String]? = nil, ambiguousToolNameSlots: Set<Int> = []) -> LLMResponse {
        guard toolCalls.calls.count <= ProviderToolCallBoundary.maximumCalls else {
            return LLMResponse(text: text, stopReason: stopReason, usage: usage)
        }
        let items: [[String: Any]] = toolCalls.completedCalls().map { call in
            var value: [String: Any] = ["type": "function", "function": ["name": call.name ?? "", "arguments": call.arguments]]
            if let id = call.id { value["id"] = id }
            if call.argumentsOversized { value[ProviderToolCallBoundary.oversizedMarkerKey] = true }
            return value
        }
        let calls = parseNativeToolCalls(from: ["tool_calls": items])
        let ids = toolCalls.calls.values.compactMap(\.id)
        let discarded = stopReason == "length" && countToolSlots && Set(ids).count == ids.count
            ? toolCalls.calls.count - calls.count : 0
        let notice: DiscardedToolCallNotice?
        if discarded > 0, let offeredNames {
            let admittedIDs = Set(calls.map(\.id))
            notice = DiscardedToolCallNotice(candidateNames: toolCalls.calls.sorted { $0.key < $1.key }.filter {
                !($0.value.id.map { admittedIDs.contains($0) } ?? false)
            }.map { ambiguousToolNameSlots.contains($0.key) ? nil : $0.value.name }, offeredNames: offeredNames, count: discarded)
        } else {
            notice = nil
        }
        return LLMResponse(text: text, stopReason: stopReason, usage: usage,
            mediaAttachments: [], toolCalls: calls, discardedToolCallCount: discarded,
            discardedToolCallNotice: notice)
    }
    public func mapError(_ error: Error) -> LLMError {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return .cancelled }
        if let known = error as? LLMError { return known }
        if error is URLError { return ProviderHTTPErrorAdapter.classify(transport: error).llmError }
        return .providerError(message: "The provider request failed.")
    }
    public func mapHTTPError(statusCode: Int, body: String) -> LLMError {
        if ProviderHTTPErrorAdapter.indicatesQuotaExhausted(statusCode: statusCode, body: body) {
            return .httpStatus(code: statusCode, detail: ProviderHTTPErrorAdapter.quotaDetail(statusCode: statusCode))
        }
        return ProviderHTTPErrorAdapter.classify(statusCode: statusCode).llmError
    }
    public func mapHTTPError(statusCode: Int, body: String, headers: [String: String]) -> LLMError {
        if ProviderContextOverflowClassifier.isOpenAIStyleOverflow(statusCode: statusCode, body: body) { return .contextLengthExceeded }
        if ProviderHTTPErrorAdapter.indicatesQuotaExhausted(statusCode: statusCode, body: body) {
            return .httpStatus(code: statusCode, detail: ProviderHTTPErrorAdapter.quotaDetail(statusCode: statusCode, headers: headers))
        }
        let classification = ProviderHTTPErrorAdapter.classify(statusCode: statusCode, headers: headers)
        var detail = "status=\(statusCode); category=\(classification.category.rawValue)"
        if let seconds = classification.retryAfterSeconds { detail += "; retry_after=\(seconds)" }
        let idFields: Set<String> = ["request-id", "x-request-id", "openai-request-id"]
        if headers.contains(where: { idFields.contains($0.key.lowercased()) &&
            !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            detail += "; request_id=present"
        }
        return .httpStatus(code: statusCode, detail: detail)
    }

    /// MC4-012: OpenAI 官方端点与推理模型用 `max_completion_tokens`，其余自定义兼容端点（含 DeepSeek 官方）用 `max_tokens`。
    private static func outputCapField(_ url: URL, modelID: String) -> String {
        OpenAIOutputCapField.name(endpointHost: url.host, scheme: url.scheme, modelID: modelID)
    }

    private nonisolated(nonsending) func prepare(messages: [LLMMessage] = [], system: String? = nil,
        tools: [AgentToolDefinition] = [], tokens: Int = 0, temperature: Double? = nil,
        streaming: Bool = false, thinking: ThinkingLevel? = nil,
        raw: ProviderWireJSON? = nil) async throws -> (URLRequest, UInt64) {
        let state = lock.withLock { settings }
        let observer = AssistantThinkingParameters.reportApplication
        let key = key, loopback = controlledFieldLoopbackOnly
        let worker = Task.detached { () throws -> URLRequest in
            try Task.checkCancellation()
            state.probe?()
            let base: URL
            do { base = try CustomProviderURL.validate(state.base ?? "https://api.openai.com") }
            catch is CustomProviderURL.Failure {
                throw LLMError.providerError(message: "The provider endpoint was rejected.")
            }
            if loopback && !ControlledFieldLoopbackPolicy.accepts(base) {
                throw LLMError.providerError(message: "The controlled endpoint is not a permitted loopback address.")
            }
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
            while components.path.hasSuffix("/") { components.path.removeLast() }
            var endpoint = components.url!
            // 与连接检查同一规则：路径里没有版本段才补 /v1（/v1beta/openai、/api/paas/v4 原样；/api → /api/v1）。
            if state.appendVersion && OpenAICompatibleVersionPath.needsV1(endpoint.path) { endpoint.appendPathComponent("v1") }
            endpoint.appendPathComponent("chat/completions")
            var body: [String: Any]
            if let raw { body = raw.object }
            else {
                var items = Self.openAIRequestMessages(messages, mediaCapabilities: state.model.capabilities,
                                                       reasoningField: state.model.interleavedReasoningField)
                if let system, !system.isEmpty { items.insert(["role": "system", "content": system], at: 0) }
                body = ["model": state.model.id, "messages": items, "stream": streaming,
                    state.router ? "max_tokens" : Self.outputCapField(endpoint, modelID: state.model.id): tokens]
                if streaming && !state.router { body["stream_options"] = ["include_usage": true] }
                if let temperature { body["temperature"] = temperature }
                if !tools.isEmpty { body["tools"] = tools.map(\.providerOpenAIFunctionDict) }
                AssistantThinkingParameters.apply(thinking, modelID: state.model.id, wire: .openAIChat, body: &body, report: observer)
            }
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            for (field, value) in state.headers { request.setValue(value, forHTTPHeaderField: field) }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            try Task.checkCancellation()
            return request
        }
        let request = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        return (request, state.generation)
    }

    private nonisolated(nonsending) func open(_ assembledRequest: URLRequest, generation: UInt64) async throws
        -> (URLSession.AsyncBytes, HTTPURLResponse, OwnedMMSendPermit?) {
        let permit = try ledger?.beforeSend(action: OwnedMMOutboundContext.action, phase: .visual)
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            try lock.withLock {
                try Task.checkCancellation()
                guard settings.generation == generation else { throw CancellationError() }
            }
            (bytes, response) = try await session.bytes(for: assembledRequest, delegate: permit?.taskDelegate())
        } catch { permit?.fail(); throw mapError(error) }
        guard let http = response as? HTTPURLResponse else {
            bytes.task.cancel(); permit?.fail(); throw ProviderResponseStreamPolicyError.missingHTTPResponse
        }
        if !(200...299).contains(http.statusCode) {
            defer { bytes.task.cancel(); permit?.fail() }
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
        return (bytes, http, permit)
    }

    public nonisolated(nonsending) func sendMessage(messages: [LLMMessage], systemPrompt: String?,
        maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt, tools: [], maxTokens: maxTokens, temperature: temperature)
    }
    public nonisolated(nonsending) func sendMessage(messages: [LLMMessage], systemPrompt: String?,
        tools: [AgentToolDefinition], maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        let prepared: (URLRequest, UInt64)
        do {
            prepared = try await prepare(messages: messages, system: systemPrompt, tools: tools,
                tokens: maxTokens, temperature: temperature)
        } catch { throw mapError(error) }
        let (request, generation) = prepared
        let (bytes, response, permit) = try await open(request, generation: generation)
        defer { bytes.task.cancel() }
        do {
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
                throw LLMError.decodingError(underlying: DecodeFailure.notObject)
            }
            try ProviderChatResponseShapePolicy.validate(object)
            let result = Self.parseChatCompletionsResult(object, offeredNames: tools.map(\.name))
            permit?.completeAfterResponse(status: response.statusCode)
            try await permit?.waitForFinish()
            return result
        } catch { permit?.fail(); throw mapError(error) }
    }
    private enum DecodeFailure: Error { case notObject }

    public nonisolated(nonsending) func streamRaw(body: [String: Any]) async throws -> (AsyncThrowingStream<String, Error>, Int) {
        let (request, generation) = try await prepare(raw: ProviderWireJSON(object: body))
        let (bytes, response, permit) = try await open(request, generation: generation)
        do { try ProviderResponseStreamPolicy.validateSSEResponse(response) }
        catch { bytes.task.cancel(); permit?.fail(); throw error }
        return (makeRawLineStream(lines: bytes.lines, statusCode: response.statusCode,
            streamPermit: permit), response.statusCode)
    }

    func makeRawLineStream<Lines: AsyncSequence & Sendable>(lines: Lines, statusCode: Int,
        streamPermit: OwnedMMSendPermit?) -> AsyncThrowingStream<String, Error> where Lines.Element == String {
        AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    var budget = ProviderResponseStreamPolicy.DecodedByteBudget()
                    var deferredMarker: String?
                    for try await line in lines {
                        try ProviderStreamCancellationPolicy.check()
                        try budget.consume(line: line)
                        if streamPermit != nil {
                            if deferredMarker != nil { continue }
                            if line == "data:[DONE]" || line == "data: [DONE]" {
                                deferredMarker = line
                                continue
                            }
                        }
                        try ProviderStreamCancellationPolicy.yield(line, to: continuation)
                    }
                    try ProviderStreamCancellationPolicy.check()
                    if let streamPermit {
                        streamPermit.completeAfterBytesEOF(status: statusCode)
                        try await streamPermit.waitForFinish()
                    }
                    if let deferredMarker {
                        try ProviderStreamCancellationPolicy.yield(deferredMarker, to: continuation)
                    }
                    continuation.finish()
                } catch {
                    streamPermit?.fail()
                    continuation.finish(throwing: self.mapError(error))
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }
}

extension OpenAICompatibleProvider {
    public nonisolated(nonsending) func streamMessage(messages: [LLMMessage], systemPrompt: String?,
        maxTokens: Int, temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        let (request, generation) = try await prepare(messages: messages, system: systemPrompt,
            tokens: maxTokens, temperature: temperature, streaming: true)
        let (bytes, response, permit) = try await open(request, generation: generation)
        do { try ProviderResponseStreamPolicy.validateSSEResponse(response) }
        catch { bytes.task.cancel(); permit?.fail(); throw error }
        return AsyncThrowingStream { continuation in
            let producer = Task {
                defer { bytes.task.cancel() }
                var reportedEOFCompletion = false
                do {
                    try ProviderStreamCancellationPolicy.yield(.started, to: continuation)
                    var budget = ProviderResponseStreamPolicy.DecodedByteBudget()
                    var stopped = false
                    func consume(_ line: String) throws {
                        guard !stopped, line.hasPrefix("data:") else { return }
                        var payload = String(line.dropFirst(5))
                        if payload.hasPrefix(" ") { payload.removeFirst() }
                        if payload == "[DONE]" {
                            stopped = true
                            try ProviderStreamCancellationPolicy.yield(.finished(stopReason: nil), to: continuation)
                            return
                        }
                        guard let data = payload.data(using: .utf8),
                              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
                        try ProviderChatResponseShapePolicy.validate(object)
                        guard let chunk = OpenAIStreamDecoder.decodeChunk(object) else { return }
                        if let text = chunk.textDelta, !text.isEmpty {
                            try ProviderStreamCancellationPolicy.yield(.text(text), to: continuation)
                        }
                        if let usage = chunk.usage { try ProviderStreamCancellationPolicy.yield(.usage(usage), to: continuation) }
                        if let reason = chunk.finishReason {
                            stopped = true
                            try ProviderStreamCancellationPolicy.yield(.finished(stopReason: reason), to: continuation)
                        }
                    }
                    for try await line in bytes.lines {
                        try ProviderStreamCancellationPolicy.check()
                        try budget.consume(line: line)
                        try consume(line)
                        if stopped && permit == nil { break }
                    }
                    try ProviderStreamCancellationPolicy.check()
                    if let permit {
                        reportedEOFCompletion = true
                        permit.completeAfterBytesEOF(status: response.statusCode)
                        try await permit.waitForFinish()
                    }
                    try ProviderStreamCancellationPolicy.check()
                    continuation.finish()
                } catch {
                    if !reportedEOFCompletion { permit?.fail() }
                    continuation.finish(throwing: self.mapError(error))
                }
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
        let (request, generation) = try await prepare(messages: messages, system: systemPrompt, tools: tools,
            tokens: maxTokens, temperature: temperature, streaming: true, thinking: thinkingLevel)
        let offeredNames = tools.map(\.name)
        let (bytes, response, permit) = try await open(request, generation: generation)
        do { try ProviderResponseStreamPolicy.validateSSEResponse(response) }
        catch { bytes.task.cancel(); permit?.fail(); throw error }
        return AsyncThrowingStream { continuation in
            let producer = Task {
                defer { bytes.task.cancel() }
                do {
                    var budget = ProviderResponseStreamPolicy.DecodedByteBudget()
                    var tools = OpenAIStreamDecoder.ToolCallAccumulator()
                    var text = ""
                    var reasoning = ""
                    var usage: LLMUsage?
                    var reason: String?
                    var contentClosed = false
                    var hasAmbiguousToolSlots = false
                    var ambiguousToolNameSlots = Set<Int>()
                    var firstToolNames: [Int: String] = [:]
                    var done = false
                    func consume(_ line: String) throws {
                        guard !done, line.hasPrefix("data:") else { return }
                        var payload = String(line.dropFirst(5))
                        if payload.hasPrefix(" ") { payload.removeFirst() }
                        if payload == "[DONE]" { done = true; return }
                        guard let data = payload.data(using: .utf8),
                              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
                        try ProviderChatResponseShapePolicy.validate(object)
                        guard let chunk = OpenAIStreamDecoder.decodeChunk(object) else { return }
                        if let value = chunk.usage { usage = value }
                        guard !contentClosed else { return }
                        if let fragment = chunk.textDelta, !fragment.isEmpty {
                            text += fragment
                            try ProviderStreamCancellationPolicy.yield(.textDelta(fragment), to: continuation)
                        }
                        // reasoning_content 不进入 text；展示用 thinkingDelta。带工具调用的回合另挂在第一个
                        // 工具调用上，供声明了 interleavedReasoningField 的模型（DeepSeek 思考模式）同轮回传。
                        if let thought = chunk.reasoningDelta, !thought.isEmpty {
                            reasoning += thought
                            try ProviderStreamCancellationPolicy.yield(.thinkingDelta(thought), to: continuation)
                        }
                        if let choice = (object["choices"] as? [[String: Any]])?.first,
                           let delta = choice["delta"] as? [String: Any],
                           let rawCalls = delta["tool_calls"] {
                            if let items = rawCalls as? [[String: Any]] {
                                let indices = items.compactMap { $0["index"] as? Int }
                                if indices.count != items.count || Set(indices).count != indices.count
                                    || indices.contains(where: { $0 < 0 })
                                    || items.contains(where: { item in
                                        guard let type = item["type"] else { return false }
                                        return (type as? String) != "function"
                                    }) {
                                    hasAmbiguousToolSlots = true
                                }
                            } else {
                                hasAmbiguousToolSlots = true
                            }
                        }
                        for delta in chunk.toolCallDeltas {
                            if let name = delta.name, !name.isEmpty {
                                if let firstName = firstToolNames[delta.index] {
                                    if !firstName.utf8.elementsEqual(name.utf8) {
                                        ambiguousToolNameSlots.insert(delta.index)
                                    }
                                } else if firstToolNames.count < ProviderToolCallBoundary.maximumCalls {
                                    firstToolNames[delta.index] = name
                                }
                            }
                            let existing = tools.calls[delta.index]
                            if let existingID = existing?.id, let id = delta.id, existingID != id {
                                hasAmbiguousToolSlots = true
                            }
                            let current = existing?.arguments.utf8.count ?? 0
                            let extra = delta.arguments?.utf8.count ?? 0
                            if extra > ProviderToolCallBoundary.maximumArgumentsBytes - current {
                                // V-6：不整轮失败；丢掉这个调用已累计的参数并标记，收尾时回给模型固定的工具错误。
                                tools.apply(delta)
                                tools.markArgumentsOversized(index: delta.index)
                                continue
                            }
                            tools.apply(delta)
                        }
                        if let stop = chunk.finishReason { reason = stop; contentClosed = true }
                    }
                    for try await line in bytes.lines {
                        try ProviderStreamCancellationPolicy.check()
                        try budget.consume(line: line)
                        try consume(line)
                        if done && permit == nil { break }
                    }
                    try ProviderStreamCancellationPolicy.check()
                    if let permit {
                        permit.completeAfterBytesEOF(status: response.statusCode)
                        try await permit.waitForFinish()
                    }
                    if reason == nil && !done {
                        throw LLMError.transientError(message: "Provider stream ended before a complete response was received.")
                    }
                    var response = Self.assistantStreamCompletedResponse(text: text, stopReason: reason,
                        usage: usage, toolCalls: tools, countToolSlots: !hasAmbiguousToolSlots,
                        offeredNames: offeredNames, ambiguousToolNameSlots: ambiguousToolNameSlots)
                    if !reasoning.isEmpty, !response.toolCalls.isEmpty {
                        response.toolCalls[0].reasoningContent = reasoning
                    }
                    try ProviderStreamCancellationPolicy.yield(.completed(response), to: continuation)
                    continuation.finish()
                } catch { permit?.fail(); continuation.finish(throwing: self.mapError(error)) }
            }
            continuation.onTermination = { _ in producer.cancel(); bytes.task.cancel() }
        }
    }
}
