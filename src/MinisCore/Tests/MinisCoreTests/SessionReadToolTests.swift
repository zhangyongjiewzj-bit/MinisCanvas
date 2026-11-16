import Foundation
import Testing
@testable import MinisCore

/// AJ-2：macOS Agent 跨会话只读能力。
struct SessionReadToolTests {

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCore-SessionRead-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeManager() throws -> (SessionManager, URL) {
        let directory = try makeTempDirectory()
        let store = SessionStore(directory: directory)
        return (SessionManager(store: store, badgeStore: SessionBadgeStore(directory: directory)), directory)
    }

    private func authorizedRead(
        input: [String: Any],
        manager: SessionManager
    ) throws -> String {
        let sessionID = (input["session_id"] as? String) ?? "missing-session"
        let now = Date()
        let scope = SessionReadScope(
            rawValue: (input["scope"] as? String) ?? "metadata"
        ) ?? .metadata
        let authorization = CrossSessionReadAuthorization.issue(
            currentConversationID: sessionID,
            authorizedSessionID: sessionID,
            turnID: 1,
            issuedAt: now,
            lifetime: 60,
            scope: scope
        )
        return try SessionReadTool.read(
            input: input,
            manager: manager,
            authorization: authorization,
            context: SessionReadExecutionContext(
                currentConversationID: sessionID,
                turnID: 1
            ),
            now: now
        )
    }

    private func object(_ output: String) throws -> [String: Any] {
        let data = try #require(output.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func catalogExposesReadOnlySessionTool() throws {
        let definition = try #require(AgentToolCatalog.makeTools().first { $0.name == "session_read" })

        #expect(definition.required == ["scope"])
        #expect(definition.parameters["scope"]?.enumValues == ["metadata", "messages", "list", "export"])
        #expect(definition.parameters["query"]?.type == .string)
        #expect(definition.parameters["session_id"]?.type == .string)
        #expect(definition.parameters["offset"]?.type == .integer)
        #expect(definition.parameters["limit"]?.type == .integer)
        #expect(definition.parameters["max_chars"]?.type == .integer)
        #expect(definition.description.contains("read-only"))
    }

    @Test func metadataReturnsSessionModelAndCounts() throws {
        let (manager, directory) = try makeManager()
        defer { try? FileManager.default.removeItem(at: directory) }

        let session = ChatSession(
            id: "session-meta",
            title: "模型核查",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200),
            messages: [
                LLMMessage(role: .user, content: "查看模型"),
                LLMMessage(role: .assistant, content: "正在查看"),
            ],
            modelID: "deepseek-chat",
            providerTypeRaw: "deepSeek"
        )
        try manager.store.updateSession(session)

        let output = try authorizedRead(
            input: ["session_id": session.id, "scope": "metadata"],
            manager: manager
        )
        let json = try object(output)
        let metadata = try #require(json["metadata"] as? [String: Any])

        #expect(json["ok"] as? Bool == true)
        #expect(metadata["session_id"] as? String == "session-meta")
        #expect(metadata["title"] as? String == "模型核查")
        #expect(metadata["message_count"] as? Int == 2)
        #expect(metadata["model_id"] as? String == "deepseek-chat")
        #expect(metadata["provider"] as? String == "deepSeek")
        #expect(metadata["model_source"] as? String == "session_override")
    }

    @Test func metadataDoesNotInventGlobalModel() throws {
        let (manager, directory) = try makeManager()
        defer { try? FileManager.default.removeItem(at: directory) }

        let session = ChatSession(id: "session-inherited", title: "继承默认")
        try manager.store.updateSession(session)

        let output = try authorizedRead(
            input: ["session_id": session.id, "scope": "metadata"],
            manager: manager
        )
        let json = try object(output)
        let metadata = try #require(json["metadata"] as? [String: Any])

        #expect(metadata["model_id"] is NSNull)
        #expect(metadata["provider"] is NSNull)
        #expect(metadata["model_source"] as? String == "global_default_unresolved")
        #expect((metadata["model_note"] as? String)?.contains("没有保存") == true)
    }

    @Test func messagesArePaginatedAndCapped() throws {
        let (manager, directory) = try makeManager()
        defer { try? FileManager.default.removeItem(at: directory) }

        let session = ChatSession(
            id: "session-messages",
            title: "消息读取",
            messages: [
                LLMMessage(role: .user, content: "第一条"),
                LLMMessage(role: .assistant, content: String(repeating: "长", count: 220)),
                LLMMessage(role: .user, content: "第三条"),
            ]
        )
        try manager.store.updateSession(session)

        let output = try authorizedRead(
            input: [
                "session_id": session.id,
                "scope": "messages",
                "offset": 1,
                "limit": 1,
                "max_chars": 200,
            ],
            manager: manager
        )
        let json = try object(output)
        let messages = try #require(json["messages"] as? [[String: Any]])
        let message = try #require(messages.first)

        #expect(json["ok"] as? Bool == true)
        #expect(json["offset"] as? Int == 1)
        #expect(json["limit"] as? Int == 1)
        #expect(json["total"] as? Int == 3)
        #expect(messages.count == 1)
        #expect(message["role"] as? String == "assistant")
        #expect((message["text"] as? String)?.count == 200)
        #expect(message["truncated"] as? Bool == true)
    }

    @Test func archivedSessionCanBeReadByID() throws {
        let (manager, directory) = try makeManager()
        defer { try? FileManager.default.removeItem(at: directory) }

        let session = ChatSession(id: "archived-session", title: "已归档", modelID: "gpt-5")
        try manager.store.updateSession(session)
        try manager.archive(sessionID: session.id)

        let output = try authorizedRead(
            input: ["session_id": session.id, "scope": "metadata"],
            manager: manager
        )
        let json = try object(output)
        let metadata = try #require(json["metadata"] as? [String: Any])

        #expect(json["ok"] as? Bool == true)
        #expect(metadata["title"] as? String == "已归档")
        #expect(metadata["model_id"] as? String == "gpt-5")
    }

    @Test func invalidInputsAreRejected() throws {
        let (manager, directory) = try makeManager()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: ToolExecutorError.missingParameter("session_id")) {
            _ = try authorizedRead(input: ["scope": "metadata"], manager: manager)
        }
        #expect(throws: ToolExecutorError.invalidParameter("scope")) {
            _ = try authorizedRead(
                input: ["session_id": "safe", "scope": "delete"],
                manager: manager
            )
        }
        #expect(throws: ToolExecutorError.invalidParameter("session_id")) {
            _ = try authorizedRead(
                input: ["session_id": "../secrets", "scope": "metadata"],
                manager: manager
            )
        }
        #expect(throws: ToolExecutorError.fileNotFound("missing")) {
            _ = try authorizedRead(
                input: ["session_id": "missing", "scope": "metadata"],
                manager: manager
            )
        }
    }

    @Test func validatedCapabilityIsConsumedBeforeTargetLookup() throws {
        let (manager, directory) = try makeManager()
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSince1970: 5_000)
        let authorization = CrossSessionReadAuthorization.issue(
            currentConversationID: "source-session",
            authorizedSessionID: "missing",
            turnID: 4,
            issuedAt: now,
            lifetime: 60,
            scope: .metadata
        )
        let context = SessionReadExecutionContext(
            currentConversationID: "source-session",
            turnID: 4
        )
        let input: [String: Any] = [
            "session_id": "missing",
            "scope": "metadata",
        ]

        #expect(throws: ToolExecutorError.fileNotFound("missing")) {
            _ = try SessionReadTool.read(
                input: input,
                manager: manager,
                authorization: authorization,
                context: context,
                now: now
            )
        }
        #expect(throws: CrossSessionReadAuthorizationError.replayed) {
            _ = try SessionReadTool.read(
                input: input,
                manager: manager,
                authorization: authorization,
                context: context,
                now: now
            )
        }
    }

    @Test func restartMismatchTerminatesLateCapabilityRetry() throws {
        let (manager, directory) = try makeManager()
        defer { try? FileManager.default.removeItem(at: directory) }
        try manager.store.updateSession(ChatSession(id: "restart-target", title: "重启目标"))

        let now = Date(timeIntervalSince1970: 6_000)
        let authorization = CrossSessionReadAuthorization.issue(
            currentConversationID: "source-session",
            authorizedSessionID: "restart-target",
            turnID: 5,
            issuedAt: now,
            lifetime: 60,
            scope: .metadata,
            restartRevision: "runtime-1"
        )
        let input: [String: Any] = [
            "session_id": "restart-target",
            "scope": "metadata",
        ]
        #expect(throws: CrossSessionReadAuthorizationError.restartRevisionMismatch) {
            _ = try SessionReadTool.read(
                input: input,
                manager: manager,
                authorization: authorization,
                context: SessionReadExecutionContext(
                    currentConversationID: "source-session",
                    turnID: 5,
                    restartRevision: "runtime-2"
                ),
                now: now
            )
        }
        #expect(authorization.isActive == false)
        #expect(authorization.invalidationReason == .revoked)
        #expect(throws: CrossSessionReadAuthorizationError.revoked) {
            _ = try SessionReadTool.read(
                input: input,
                manager: manager,
                authorization: authorization,
                context: SessionReadExecutionContext(
                    currentConversationID: "source-session",
                    turnID: 5,
                    restartRevision: "runtime-1"
                ),
                now: now
            )
        }
    }

    private func persistedBytes(_ manager: SessionManager, id: String, archived: Bool) throws -> Data {
        let relative = archived ? "_archive/\(id).json" : "\(id).json"
        return try Data(contentsOf: manager.store.sessionsDirectory.appendingPathComponent(relative))
    }

    @Test(arguments: [false, true])
    func metadataRedactsRecognizedContentAndPreservesStoredBytes(archived: Bool) throws {
        let (manager, directory) = try makeManager()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = "sk-D05SyntheticKeyInteriorABCDEFGHIJ"
        let bearer = "D05SyntheticBearerInterior0123456789"
        let cookie = "D05SyntheticCookieInteriorABCDEFGHIJ"
        let session = ChatSession(id: "d05-metadata", title: "普通标题 \(key) 结尾",
            createdAt: Date(timeIntervalSince1970: 100), updatedAt: Date(timeIntervalSince1970: 200),
            messages: [LLMMessage(role: .tool, content: "不投影工具消息"), LLMMessage(role: .user, content: "普通正文")],
            modelID: "Bearer \(bearer)", providerTypeRaw: "Cookie: \(cookie); theme=dark")
        try manager.store.updateSession(session)
        if archived { try manager.archive(sessionID: session.id) }
        let before = try persistedBytes(manager, id: session.id, archived: archived)
        let output = try authorizedRead(input: ["session_id": session.id, "scope": "metadata"], manager: manager)
        let envelope = try object(output)
        let metadata = try #require(envelope["metadata"] as? [String: Any])
        #expect(Set(envelope.keys) == ["ok", "tool", "scope", "metadata"])
        #expect(Set(metadata.keys) == ["session_id", "title", "created_at", "updated_at", "message_count", "model_id", "provider", "model_source"])
        #expect(metadata["title"] as? String == "普通标题 \(ContentSecretRedactor.mask(key)) 结尾")
        #expect(metadata["model_id"] as? String == "Bearer \(ContentSecretRedactor.mask(bearer))")
        // Every cookie value is opaque at this boundary, including short
        // values whose key does not look like a credential.
        #expect(metadata["provider"] as? String == "Cookie: \(ContentSecretRedactor.mask(cookie)); theme=\(ContentSecretRedactor.mask("dark"))")
        #expect(!output.contains("theme=dark"))
        #expect(metadata["session_id"] as? String == session.id)
        #expect(metadata["message_count"] as? Int == 2)
        #expect(metadata["created_at"] as? String == ISO8601DateFormatter().string(from: session.createdAt))
        #expect(metadata["updated_at"] as? String == ISO8601DateFormatter().string(from: session.updatedAt))
        #expect(metadata["model_source"] as? String == "session_override")
        for secret in [key, bearer, cookie] { #expect(!output.contains(secret)) }
        #expect(try persistedBytes(manager, id: session.id, archived: archived) == before)

        let mixed = ChatSession(id: "d05-mixed-null", title: "普通标题", modelID: nil, providerTypeRaw: "deepSeek")
        try manager.store.updateSession(mixed)
        if archived { try manager.archive(sessionID: mixed.id) }
        let mixedBefore = try persistedBytes(manager, id: mixed.id, archived: archived)
        let mixedJSON = try object(authorizedRead(input: ["session_id": mixed.id, "scope": "metadata"], manager: manager))
        let mixedMetadata = try #require(mixedJSON["metadata"] as? [String: Any])
        #expect(mixedMetadata["model_id"] is NSNull)
        #expect(mixedMetadata["provider"] as? String == "deepSeek")
        #expect(mixedMetadata["title"] as? String == "普通标题")
        #expect(mixedMetadata["model_source"] as? String == "session_override")
        #expect(try persistedBytes(manager, id: mixed.id, archived: archived) == mixedBefore)
    }

    @Test(arguments: [false, true])
    func fullTextRedactionPrecedesCharacterTruncation(archived: Bool) throws {
        let (manager, directory) = try makeManager()
        defer { try? FileManager.default.removeItem(at: directory) }
        let token = "HEAD" + String(repeating: "UNMASKED_INTERIOR", count: 60) + "TAIL"
        let key = "sk-D05RepeatedSyntheticKey0123456789"
        let cookie = "D05RepeatedSyntheticCookie0123456789"
        let boundaryPrefix = String(repeating: "前", count: 185)
        let unicodePrefix = "汉👩🏽‍💻e\u{301} Bearer "
        let scenarios: [(String, String, String, Int, Bool)] = [
            ("boundary", boundaryPrefix + " Bearer " + token + " 结束",
             boundaryPrefix + " Bearer " + ContentSecretRedactor.mask(token) + " 结束", 200, true),
            ("full-mask-limit", "开始 Bearer " + token + " 结束",
             "开始 Bearer " + ContentSecretRedactor.mask(token) + " 结束", 200, true),
            ("unicode", unicodePrefix + token + " " + String(repeating: "文👩🏽‍💻e\u{301}", count: 100),
             unicodePrefix + ContentSecretRedactor.mask(token) + " " + String(repeating: "文👩🏽‍💻e\u{301}", count: 100), 200, true),
            ("repeated", "普通 \(key)\nBearer \(token)\nCookie: \(cookie); theme=dark\n重复 \(key) 结束",
             "普通 \(ContentSecretRedactor.mask(key))\nBearer \(ContentSecretRedactor.mask(token))\nCookie: \(ContentSecretRedactor.mask(cookie)); theme=\(ContentSecretRedactor.mask("dark"))\n重复 \(ContentSecretRedactor.mask(key)) 结束", 8000, false),
        ]
        for (name, raw, projection, limit, truncated) in scenarios {
            let session = ChatSession(id: "d05-\(name)", title: "边界回归", messages: [LLMMessage(role: .user, content: raw)])
            try manager.store.updateSession(session)
            if archived { try manager.archive(sessionID: session.id) }
            let before = try persistedBytes(manager, id: session.id, archived: archived)
            let output = try authorizedRead(input: ["session_id": session.id, "scope": "messages", "max_chars": limit], manager: manager)
            let json = try object(output)
            let messages = try #require(json["messages"] as? [[String: Any]])
            let message = try #require(messages.first)
            let text = try #require(message["text"] as? String)
            let expected = String(projection.prefix(limit))
            #expect(text == expected, "\(name): full-value mask then Swift Character prefix")
            #expect(messages.count == 1 && json["total"] as? Int == 1)
            #expect(message["role"] as? String == "user")
            #expect(message["created_at"] is NSNull)
            if truncated {
                #expect(text.count == limit)
                #expect(message["truncated"] as? Bool == true)
            } else {
                #expect(message["truncated"] == nil)
                #expect(text == projection)
            }
            if name == "boundary" {
                #expect(ContentSecretRedactor.redact(String(raw.prefix(limit))) != expected)
                #expect(!text.contains("HEADUNM"))
            }
            if name == "full-mask-limit" {
                // Full masking preserves this ASCII token's character count.
                // The old preview-style mask made the projection appear to fit;
                // the actual post-redaction character limit must still apply.
                let correctLengthBoundary = raw.count == projection.count && projection.count > limit
                #expect(correctLengthBoundary)
                let tokenCharacters = Array(token)
                let exposesFragment = (0...(tokenCharacters.count - 4)).contains { offset in
                    output.contains(String(tokenCharacters[offset..<(offset + 4)]))
                }
                #expect(!exposesFragment, "the bounded output contains no four-character token fragment")
            }
            for secret in [token, key, cookie] { #expect(!output.contains(secret)) }
            #expect(!output.contains("theme=dark"))
            #expect(!text.contains("UNMASKED_INTERIOR"))
            #expect(try persistedBytes(manager, id: session.id, archived: archived) == before)
        }
    }

    @Test(arguments: [false, true])
    func sanitizedMessagesKeepRoleFilteringPaginationAndClamps(archived: Bool) throws {
        let (manager, directory) = try makeManager()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = "sk-D05PageSyntheticKeyABCDEFGHIJKLMN"
        let session = ChatSession(id: "d05-page", title: "分页", messages: [
            LLMMessage(role: .tool, content: "HIDDEN_TOOL_BEFORE \(key)"),
            LLMMessage(role: .user, content: "普通首条 \(key)"),
            LLMMessage(role: .tool, content: "HIDDEN_TOOL \(key)"),
            // Keep this case on the character boundary: the 3-byte CJK scalar
            // stays below the independent 64,000-byte projection ceiling.
            LLMMessage(role: .assistant, content: String(repeating: "界", count: 8100)),
        ])
        try manager.store.updateSession(session)
        if archived { try manager.archive(sessionID: session.id) }
        let before = try persistedBytes(manager, id: session.id, archived: archived)
        let firstOutput = try authorizedRead(input: ["session_id": session.id, "scope": "messages", "offset": -1, "limit": 0, "max_chars": 1], manager: manager)
        let first = try object(firstOutput)
        let firstPage = try #require(first["messages"] as? [[String: Any]])
        #expect(first["offset"] as? Int == 0 && first["limit"] as? Int == 1 && first["max_chars"] as? Int == 200)
        #expect(first["total"] as? Int == 2)
        #expect(firstPage.first?["text"] as? String == "普通首条 \(ContentSecretRedactor.mask(key))")
        #expect(!firstOutput.contains("HIDDEN_TOOL_BEFORE") && !firstOutput.contains("HIDDEN_TOOL"))
        let last = try object(authorizedRead(input: ["session_id": session.id, "scope": "messages", "offset": 1, "limit": 999, "max_chars": 99999], manager: manager))
        let lastPage = try #require(last["messages"] as? [[String: Any]])
        #expect(last["limit"] as? Int == 50 && last["max_chars"] as? Int == 8000)
        #expect(lastPage.count == 1 && lastPage.first?["role"] as? String == "assistant")
        #expect((lastPage.first?["text"] as? String)?.count == 8000)
        #expect(lastPage.first?["source_character_count"] as? Int == 8100)
        #expect(lastPage.first?["source_byte_count"] as? Int == 24_300)
        #expect(lastPage.first?["character_count"] as? Int == 8000)
        #expect(lastPage.first?["byte_count"] as? Int == 24_000)
        #expect(lastPage.first?["max_bytes"] as? Int == 64_000)
        #expect(lastPage.first?["truncated"] as? Bool == true)

        // A ZWJ emoji is one Character but 15 UTF-8 bytes, so this separate
        // case proves the byte budget wins at 4,266 clusters before max_chars.
        let byteBound = ChatSession(id: "d05-byte-clamp-\(archived)", title: "字节上限", messages: [
            LLMMessage(role: .assistant, content: String(repeating: "👩🏽‍💻", count: 8100)),
        ])
        try manager.store.updateSession(byteBound)
        if archived { try manager.archive(sessionID: byteBound.id) }
        let bytePage = try object(authorizedRead(input: ["session_id": byteBound.id, "scope": "messages", "max_chars": 99999], manager: manager))
        let byteMessage = try #require((bytePage["messages"] as? [[String: Any]])?.first)
        #expect(byteMessage["source_character_count"] as? Int == 8100)
        #expect(byteMessage["source_byte_count"] as? Int == 121_500)
        #expect(byteMessage["character_count"] as? Int == 4_266)
        #expect(byteMessage["byte_count"] as? Int == 63_990)
        #expect(byteMessage["max_characters"] as? Int == 8000)
        #expect(byteMessage["max_bytes"] as? Int == 64_000)
        #expect((byteMessage["text"] as? String)?.count == 4_266)
        #expect(byteMessage["truncated"] as? Bool == true)
        let defaults = try object(authorizedRead(input: ["session_id": session.id, "scope": "messages", "offset": 99], manager: manager))
        #expect(defaults["offset"] as? Int == 99 && defaults["limit"] as? Int == 20 && defaults["max_chars"] as? Int == 4000)
        #expect((defaults["messages"] as? [[String: Any]])?.isEmpty == true)
        #expect(try persistedBytes(manager, id: session.id, archived: archived) == before)
    }

    @Test(arguments: ["legacy", "wrongTarget", "wrongScope", "stopped", "replay"])
    func redactionDoesNotBroadenCapabilityAuthorization(failure: String) throws {
        let (manager, directory) = try makeManager()
        defer { try? FileManager.default.removeItem(at: directory) }
        let secret = "sk-D05DeniedSyntheticKeyABCDEFGHIJKL"
        for id in ["d05-authorized", "d05-other"] {
            try manager.store.updateSession(ChatSession(id: id, title: "保护目标 \(secret)", messages: [LLMMessage(role: .user, content: "保护正文 \(secret)")]))
        }
        let before = try persistedBytes(manager, id: "d05-authorized", archived: false)
        let otherBefore = try persistedBytes(manager, id: "d05-other", archived: false)
        let now = Date(timeIntervalSince1970: 10_000)
        let authorization = CrossSessionReadAuthorization.issue(currentConversationID: "d05-source", authorizedSessionID: "d05-authorized", turnID: 9, issuedAt: now, lifetime: 60, scope: .messages)
        let context = SessionReadExecutionContext(currentConversationID: "d05-source", turnID: 9, isStopped: failure == "stopped")
        var input: [String: Any] = ["session_id": "d05-authorized", "scope": "messages"]
        let error: CrossSessionReadAuthorizationError
        switch failure {
        case "legacy": error = .capabilityRequired
        case "wrongTarget": input["session_id"] = "d05-other"; error = .sessionNotAuthorized
        case "wrongScope": input["scope"] = "metadata"; error = .scopeNotAuthorized
        case "stopped": error = .stopped
        default:
            let first = try SessionReadTool.read(input: input, manager: manager, authorization: authorization, context: context, now: now)
            #expect(!first.contains(secret) && first.contains(ContentSecretRedactor.mask(secret)))
            error = .replayed
        }
        var output: String?
        #expect(throws: error) {
            if failure == "legacy" { output = try SessionReadTool.read(input: input, manager: manager) }
            else { output = try SessionReadTool.read(input: input, manager: manager, authorization: authorization, context: context, now: now) }
        }
        #expect(output == nil)
        if failure == "stopped" { #expect(authorization.invalidationReason == .stopped) }
        #expect(try persistedBytes(manager, id: "d05-authorized", archived: false) == before)
        #expect(try persistedBytes(manager, id: "d05-other", archived: false) == otherBefore)
    }
}

// The synchronous provider can be called from an executor task. All test state
// is isolated and protected by the same lock; no credentials or shared stores.
private final class D05KnownValuesProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String]
    private var calls = 0
    init(_ values: [String]) { self.values = values }
    func replace(_ values: [String]) { lock.withLock { self.values = values } }
    func snapshot() -> [String] { lock.withLock { calls += 1; return values } }
    var count: Int { lock.withLock { calls } }
}

extension SessionReadToolTests {
    @Test func knownSecretFragmentsNeverReachSessionRead() throws {
        let (manager, directory) = try makeManager()
        defer { try? FileManager.default.removeItem(at: directory) }
        let alphabet = Array("q7B4c9D2e5F8g1H6")
        let unicode = "可信👩🏽‍💻e\u{301}私密裸值"
        #expect(unicode.count == 8)
        let secrets = [8, 9, 11, 12, 16].map { String(alphabet.prefix($0)) } + [unicode]

        for (index, secret) in secrets.enumerated() {
            let sessionID = "d05-fragment-\(index)"
            try manager.store.updateSession(ChatSession(
                id: sessionID,
                title: "标题 \(secret)",
                messages: [LLMMessage(role: .user, content: "正文 \(secret) 结束")]
            ))
            for (scopeIndex, scope) in [SessionReadScope.metadata, .messages].enumerated() {
                let now = Date()
                let turnID = index * 2 + scopeIndex
                let grant = CrossSessionReadAuthorization.issue(
                    currentConversationID: "d05-fragment-reader",
                    authorizedSessionID: sessionID,
                    turnID: turnID,
                    issuedAt: now,
                    lifetime: 60,
                    scope: scope
                )
                let output = try SessionReadTool.read(
                    input: ["session_id": sessionID, "scope": scope.rawValue],
                    manager: manager,
                    authorization: grant,
                    context: SessionReadExecutionContext(
                        currentConversationID: "d05-fragment-reader", turnID: turnID
                    ),
                    now: now,
                    knownSecretsProvider: { [secret] }
                )
                #expect(output.contains(ContentSecretRedactor.mask(secret)))
                let characters = Array(secret)
                for start in 0...(characters.count - 4) {
                    #expect(!output.contains(String(characters[start..<(start + 4)])))
                }
            }
        }
    }

    @Test(arguments: [false, true])
    func knownBareValuesAreMaskedBeforeProjection(archived: Bool) throws {
        let (manager, directory) = try makeManager()
        defer { try? FileManager.default.removeItem(at: directory) }
        let long = "HEAD" + String(repeating: "BARE_INTERIOR", count: 60) + "TAIL"
        let short = "q7!"
        let unicode = "私密👩🏽‍💻e\u{301}组合裸值"
        let ordinary = "保留普通值"
        let prefix = String(repeating: "前", count: 185) + "👩🏽‍💻e\u{301} "
        let raw = prefix + long + " 正文尾部"
        let safe = prefix + ContentSecretRedactor.mask(long) + " 正文尾部"
        let probe = D05KnownValuesProbe([long, short, unicode])
        let session = ChatSession(id: "d05-known-bare", title: "标题 \(long)", messages: [
            LLMMessage(role: .tool, content: "HIDDEN_TOOL \(long)"),
            LLMMessage(role: .user, content: raw),
            LLMMessage(role: .assistant, content: "\(ordinary) \(short) \(unicode)"),
        ], modelID: short, providerTypeRaw: unicode)
        try manager.store.updateSession(session)
        if archived { try manager.archive(sessionID: session.id) }
        let before = try persistedBytes(manager, id: session.id, archived: archived)
        for scope in [SessionReadScope.metadata, .messages] {
            let now = Date()
            let authorization = CrossSessionReadAuthorization.issue(currentConversationID: "d05-known-source",
                authorizedSessionID: session.id, turnID: 1, issuedAt: now, lifetime: 60, scope: scope)
            let output = try SessionReadTool.read(input: ["session_id": session.id, "scope": scope.rawValue,
                "max_chars": 200, "offset": 0, "limit": 2,
                "knownSecrets": [ordinary], "knownSecretsProvider": "model-controlled"],
                manager: manager, authorization: authorization,
                context: SessionReadExecutionContext(currentConversationID: "d05-known-source", turnID: 1),
                now: now, knownSecretsProvider: { probe.snapshot() })
            let json = try object(output)
            if scope == .metadata {
                let metadata = try #require(json["metadata"] as? [String: Any])
                #expect(metadata["title"] as? String == "标题 \(ContentSecretRedactor.mask(long))")
                #expect(metadata["model_id"] as? String == ContentSecretRedactor.mask(short))
                #expect(metadata["provider"] as? String == ContentSecretRedactor.mask(unicode))
                #expect(metadata["message_count"] as? Int == 3)
            } else {
                let messages = try #require(json["messages"] as? [[String: Any]])
                #expect(messages.count == 2 && json["total"] as? Int == 2)
                #expect(messages[0]["text"] as? String == String(safe.prefix(200)))
                #expect(messages[0]["truncated"] as? Bool == true)
                #expect(messages[0]["role"] as? String == "user" && messages[0]["created_at"] is NSNull)
                #expect(messages[1]["text"] as? String == "\(ordinary) \(ContentSecretRedactor.mask(short)) \(ContentSecretRedactor.mask(unicode))")
                #expect(messages[1]["truncated"] == nil && messages[1]["role"] as? String == "assistant")
                #expect(!output.contains("HIDDEN_TOOL"))
                #expect(ContentSecretRedactor.redact(String(raw.prefix(200)), knownSecrets: [long]) != String(safe.prefix(200)))
                #expect(!output.contains("BARE_INTERIOR"))
            }
            for secret in [long, short, unicode] { #expect(!output.contains(secret)) }
        }
        #expect(probe.count == 2)
        #expect(try persistedBytes(manager, id: session.id, archived: archived) == before)
    }

    @Test func trustedSnapshotRefreshesOnlyAfterCapabilityConsumption() throws {
        let (manager, directory) = try makeManager()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = "ALFAUnformattedPrivateValueOMEG"
        let second = "BETAChangedUnformattedPrivateValueTAIL"
        let probe = D05KnownValuesProbe([first])
        let session = ChatSession(id: "d05-refresh", title: "\(first) \(second)")
        try manager.store.updateSession(session)
        let before = try persistedBytes(manager, id: session.id, archived: false)
        let now = Date()
        for (index, secret) in [first, second].enumerated() {
            if index == 1 { probe.replace([second]) }
            let authorization = CrossSessionReadAuthorization.issue(currentConversationID: "source",
                authorizedSessionID: session.id, turnID: index, issuedAt: now, lifetime: 60)
            let output = try SessionReadTool.read(input: ["session_id": session.id, "scope": "metadata"],
                manager: manager, authorization: authorization, currentConversationID: "source", turnID: index,
                now: now, knownSecretsProvider: {
                    // consume() is already exhausted at the trusted source boundary.
                    #expect(!authorization.consume(targetSessionID: session.id, scope: .metadata))
                    return probe.snapshot()
                })
            #expect(output.contains(ContentSecretRedactor.mask(secret)) && !output.contains(secret))
            #expect(probe.count == index + 1)
        }
        #expect(try persistedBytes(manager, id: session.id, archived: false) == before)
        let missing = CrossSessionReadAuthorization.issue(currentConversationID: "source",
            authorizedSessionID: "not-created", turnID: 3, issuedAt: now, lifetime: 60)
        let context = SessionReadExecutionContext(currentConversationID: "source", turnID: 3)
        #expect(throws: ToolExecutorError.fileNotFound("not-created")) {
            _ = try SessionReadTool.read(input: ["session_id": "not-created", "scope": "metadata"],
                manager: manager, authorization: missing, context: context, now: now,
                knownSecretsProvider: { probe.snapshot() })
        }
        #expect(probe.count == 3)
        #expect(throws: CrossSessionReadAuthorizationError.replayed) {
            _ = try SessionReadTool.read(input: ["session_id": "not-created", "scope": "metadata"],
                manager: manager, authorization: missing, context: context, now: now,
                knownSecretsProvider: { probe.snapshot() })
        }
        #expect(probe.count == 3)
    }

    @Test(arguments: ["legacy", "wrongTarget", "wrongScope", "stopped", "replay", "expired"])
    func rejectedReadsNeverConsultTrustedKnownValues(failure: String) throws {
        let (manager, directory) = try makeManager()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = D05KnownValuesProbe(["NOFormattedMarkerPrivateValue"])
        let session = ChatSession(id: "d05-no-read", title: "NOFormattedMarkerPrivateValue")
        try manager.store.updateSession(session)
        let before = try persistedBytes(manager, id: session.id, archived: false)
        let issued = Date(timeIntervalSince1970: 20_000)
        let now = failure == "expired" ? issued.addingTimeInterval(61) : issued
        let authorization = CrossSessionReadAuthorization.issue(currentConversationID: "source",
            authorizedSessionID: session.id, turnID: 1, issuedAt: issued, lifetime: 60)
        let context = SessionReadExecutionContext(currentConversationID: "source", turnID: 1,
            isStopped: failure == "stopped")
        var input: [String: Any] = ["session_id": session.id, "scope": "metadata"]
        let expected: CrossSessionReadAuthorizationError
        switch failure {
        case "legacy": expected = .capabilityRequired
        case "wrongTarget": input["session_id"] = "other"; expected = .sessionNotAuthorized
        case "wrongScope": input["scope"] = "messages"; expected = .scopeNotAuthorized
        case "stopped": expected = .stopped
        case "expired": expected = .expired
        default:
            _ = try SessionReadTool.read(input: input, manager: manager, authorization: authorization,
                context: context, now: now, knownSecretsProvider: { probe.snapshot() })
            expected = .replayed
        }
        let callsBeforeRejection = probe.count
        #expect(throws: expected) {
            if failure == "legacy" { _ = try SessionReadTool.read(input: input, manager: manager) }
            else {
                _ = try SessionReadTool.read(input: input, manager: manager, authorization: authorization,
                    context: context, now: now, knownSecretsProvider: { probe.snapshot() })
            }
        }
        #expect(probe.count == callsBeforeRejection)
        #expect(callsBeforeRejection == (failure == "replay" ? 1 : 0))
        #expect(try persistedBytes(manager, id: session.id, archived: false) == before)
    }
}
