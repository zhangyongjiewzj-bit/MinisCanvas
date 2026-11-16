import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

// MARK: - D-PROVIDER-11/12/13：typed Provider 失败分类的消费端（lane 063）

/// 契约（`issues/三期初期合拢-App逐项功能验收清单-20260826.md:246-248`）：
/// - PROVIDER-11「请求失败时能区分未配置、401/403、404、429、5xx、超时和取消」
///   —— 037 已在 MinisCore 落地 `ProviderRequestFailureKind`，本文件钉住它必须
///   穿过 ChatStore 投影成**可区分**的用户可见文案（此前 9 类被压成一句定文案）。
/// - PROVIDER-12「fallback 发生时能看到原 Provider、失败原因和最终 route」——
///   本文件钉住「失败原因」这一半：typed kind + wire 状态码同时进入
///   ①可见消息与②持久化执行失败记录（同一投影，磁盘往返后可读回）。
///   「原 Provider」的**标识字符串**仍不外显：`ErrorMessageTests` 与
///   `ProviderRuntimeProviderIdentityProjectionSecurityTests` 已把 providerID
///   钉成远端可控文本不得进入用户/日志面，这里不放宽。
/// - PROVIDER-13「fallback 不会重复插入消息」—— 本文件钉住分类增量只追加一次。
///
/// 全程离线：不触网、不调用真实 Provider、不使用任何真实凭据材料；
/// 只有 kind 与状态码跨边界，远端正文一律用哨兵字符串验证「不得出现」。
@Suite("Provider typed 失败分类消费（lane 063）")
@MainActor
struct ProviderFailureKindConsumer063Tests {
    /// 远端可控自由文本哨兵：`FallbackEvent.boundedErrorDescription` 只拒绝
    /// 凭据标记/URL 语法，这段合法文本会原样留在事件里，因此「消息中不得出现」
    /// 的断言不是空断言。
    private static let bodySentinel = "remote-body-text-must-not-persist"
    private static let identitySentinel = "evil-provider-identity"

    private func kindOutcomes() -> [(kind: ProviderRequestFailureKind, phrase: String)] {
        [
            (kind: .unconfigured, phrase: "未配置"),
            (kind: .unauthorized, phrase: "认证失败"),
            (kind: .permissionDenied, phrase: "权限被拒"),
            (kind: .notFound, phrase: "不存在"),
            (kind: .rateLimited, phrase: "限流"),
            (kind: .server, phrase: "服务端错误"),
            (kind: .timeout, phrase: "请求超时"),
            (kind: .cancelled, phrase: "已取消"),
            (kind: .transport, phrase: "网络传输失败"),
        ]
    }

    private static let legacyAllFailed =
        "所有服务商均失败，请返回设置检查服务商和模型配置后重试。"

    private func trail(
        _ failures: [(kind: ProviderRequestFailureKind?, statusCode: Int?)]
    ) -> MinisCore.FallbackRouterError {
        .allProvidersFailed(
            failures.enumerated().map { offset, failure in
                FallbackRouter.FallbackEvent(
                    providerID: Self.identitySentinel + "-\(offset + 1)",
                    errorDescription: Self.bodySentinel,
                    attempt: offset + 1,
                    failureKind: failure.kind,
                    statusCode: failure.statusCode
                )
            }
        )
    }

    // MARK: PROVIDER-11：每一种 typed kind 都有自己的可见结果

    @Test("each typed kind projects a distinct user-visible outcome")
    func eachTypedKindProjectsDistinctOutcome() {
        let outcomes = kindOutcomes()
        var seen: [String: String] = [:]
        for outcome in outcomes {
            let message = ChatStore.userErrorMessage(
                trail([(kind: outcome.kind, statusCode: nil)])
            )
            #expect(
                message.contains(outcome.phrase),
                "kind \(outcome.kind.rawValue) 必须投影出 \(outcome.phrase)，实得：\(message)"
            )
            // 原引导语仍在：分类不得把 fail-closed 提示文案删掉。
            #expect(message.contains("所有服务商均失败"))
            #expect(message.contains("请返回设置"))
            seen[outcome.kind.rawValue] = message
        }
        // 9 类两两可区分 —— 回归「一句定文案吃掉全部失败」的旧缺陷。
        #expect(Set(seen.values).count == outcomes.count)
    }

    @Test("wire status code reaches the visible outcome alongside the kind")
    func statusCodeReachesVisibleOutcome() {
        let auth = ChatStore.userErrorMessage(
            trail([(kind: .unauthorized, statusCode: 401)])
        )
        let limited = ChatStore.userErrorMessage(
            trail([(kind: .rateLimited, statusCode: 429)])
        )
        let server = ChatStore.userErrorMessage(
            trail([(kind: .server, statusCode: 503)])
        )
        #expect(auth.contains("认证失败") && auth.contains("401"))
        #expect(limited.contains("限流") && limited.contains("429"))
        #expect(server.contains("服务端错误") && server.contains("503"))
        // 不同状态码之间不得再互相混淆（PROVIDER-11 的 401/429/5xx 区分）。
        #expect(Set([auth, limited, server]).count == 3)

        let noCode = ChatStore.userErrorMessage(
            trail([(kind: .timeout, statusCode: nil)])
        )
        #expect(noCode.contains("请求超时"))
        #expect(!noCode.contains("HTTP"))
    }

    @Test("ordered multi-provider trail keeps every distinct classification")
    func orderedTrailListsAllDistinctKinds() throws {
        // 说明：生产 shouldFallback = LLMError.isFallbackable。403/404 在白名单
        // 内、可进 trail；直接终止而不进 trail 的是 .cancelled 与服务端/传输/
        // 配置类（5xx、.transientError、.networkError、400/422 等）及未分类失败，
        // 它们只出现在 observation 的终态 attempt 上（由
        // ProviderFallbackRouteConsumerTests 逐类钉住）。本表事件为手工构造，
        // 投影覆盖闭集全部 9 类，任何一类都不会渲染成空白依据。
        let message = ChatStore.userErrorMessage(
            trail([
                (kind: .unauthorized, statusCode: 401),
                (kind: .notFound, statusCode: 404),
                (kind: .rateLimited, statusCode: 429),
            ])
        )
        #expect(message.contains("认证失败"))
        #expect(message.contains("不存在"))
        #expect(message.contains("限流"))
        let firstAuth = try #require(message.range(of: "认证失败"))
        let firstNotFound = try #require(message.range(of: "不存在"))
        let firstRate = try #require(message.range(of: "限流"))
        #expect(firstAuth.lowerBound < firstNotFound.lowerBound)
        #expect(firstNotFound.lowerBound < firstRate.lowerBound)
    }

    @Test("duplicate kinds collapse to one mention")
    func duplicateKindsCollapse() {
        let message = ChatStore.userErrorMessage(
            trail([
                (kind: .rateLimited, statusCode: 429),
                (kind: .rateLimited, statusCode: 429),
            ])
        )
        #expect(message.components(separatedBy: "限流").count - 1 == 1)
    }

    @Test("more than three kinds stay bounded so the persisted record keeps them")
    func manyKindsAreBounded() {
        let message = ChatStore.userErrorMessage(
            trail([
                (kind: .unauthorized, statusCode: 401),
                (kind: .permissionDenied, statusCode: nil),
                (kind: .notFound, statusCode: 404),
                (kind: .rateLimited, statusCode: 429),
                (kind: .timeout, statusCode: nil),
            ])
        )
        #expect(message.contains("等 5 类"))
        // 只列前 3 项；限界保证整句留在 sanitizedExecutionFailure 的 160 字窗口内。
        #expect(!message.contains("请求超时"))
        #expect(message.count < 120)
    }

    // MARK: fail-closed：未分类不得被「美化」成已分类

    @Test("unclassified trail keeps the legacy fail-closed string verbatim")
    func unclassifiedKeepsLegacyString() {
        let message = ChatStore.userErrorMessage(
            trail([(kind: nil, statusCode: nil)])
        )
        #expect(message == Self.legacyAllFailed)

        let mixed = ChatStore.userErrorMessage(
            trail([(kind: nil, statusCode: nil), (kind: .timeout, statusCode: nil)])
        )
        #expect(mixed.contains("请求超时"))
        #expect(!mixed.contains("未分类"))
    }

    @Test("empty chain guidance is untouched")
    func emptyChainUntouched() {
        #expect(
            ChatStore.userErrorMessage(MinisCore.FallbackRouterError.emptyChain)
                == "未配置可用的服务商，请返回设置配置服务商和模型后重试。"
        )
    }

    @Test("snapshot configuration failure distinguishes unconfigured without guessing")
    func snapshotConfigFailureDistinguishesUnconfigured() {
        let unconfigured = ChatStore.userErrorMessage(
            MinisCore.ProviderRuntimeSnapshotError.missingProvider("some-provider")
        )
        #expect(unconfigured.contains("未配置"))
        #expect(unconfigured.contains("当前请求未执行"))
        #expect(!unconfigured.contains("some-provider"))

        // 校验类失败在 Core 仍为 nil（未分类）→ 必须保持原定文案，不外扩语义。
        let unclassified = ChatStore.userErrorMessage(
            MinisCore.ProviderRuntimeSnapshotError.duplicateFallback
        )
        #expect(
            unclassified
                == "服务商运行时配置暂不可用，当前请求未执行。请返回设置检查服务商和模型后重试。"
        )
    }

    // MARK: payload-free：远端正文与 Provider 标识不得进入可见消息 / 落盘记录

    @Test("classified message carries no provider body text or identity")
    func classifiedMessageIsPayloadFree() {
        let message = ChatStore.userErrorMessage(
            trail([(kind: .unauthorized, statusCode: 401)])
        )
        // 事件里确实还带着这两段文本（否则本断言是空的）。
        let probe = trail([(kind: .unauthorized, statusCode: 401)])
        guard case .allProvidersFailed(let events) = probe else {
            Issue.record("expected allProvidersFailed")
            return
        }
        #expect(events[0].errorDescription == Self.bodySentinel)
        #expect(events[0].providerID == Self.identitySentinel + "-1")

        #expect(!message.contains(Self.bodySentinel))
        #expect(!message.contains(Self.identitySentinel))
        #expect(!message.contains("remote"))
        #expect(!message.contains("evil"))
        #expect(!message.contains("Bearer"))
        #expect(!message.contains("http"))
    }

    @Test("fallback failure appends one classified line and never the provider body")
    func storeMessageBodyStaysPayloadFree() async throws {
        let chat = ChatStore()
        chat.streamingProviderOverride = ErrorMessageTestProvider(
            name: "063 测试 Provider",
            modelID: "063-test-model"
        )
        chat.agentEngine = ErrorMessageThrowingEngine(
            error: trail([(kind: .server, statusCode: 503)])
        )
        let content = try await sendAndWait(for: chat)

        // 用户可见正文里出现了分类……
        #expect(content.contains("服务端错误"))
        #expect(content.contains("503"))
        // ……但没有远端正文/Provider 标识（不得被回写成明文本体）。
        #expect(!content.contains(Self.bodySentinel))
        #expect(!content.contains(Self.identitySentinel))
        // PROVIDER-13：分类增量只追加一次错误块。
        #expect(content.components(separatedBy: "**错误**").count - 1 == 1)
    }

    @Test("typed classification survives into the persisted execution record")
    func classificationPersistsIntoRecord() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "w063-provider-failure-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }

        let chat = ChatStore()
        #expect(chat.attachPersistence(SessionStore(directory: root)) == true)
        let sessionID = try #require(chat.activeSessionID)
        chat.markExecutionFailed(
            sessionID: sessionID,
            reason: ChatStore.userErrorMessage(
                trail([
                    (kind: .unauthorized, statusCode: 401),
                    (kind: .rateLimited, statusCode: 429),
                ])
            )
        )

        let inMemory = try #require(
            chat.executionSnapshot(forSessionID: sessionID)?.failureReason
        )
        #expect(inMemory.contains("认证失败"))
        #expect(inMemory.contains("401"))
        #expect(inMemory.contains("限流"))
        #expect(inMemory.contains("429"))
        #expect(!inMemory.contains(Self.bodySentinel))
        #expect(!inMemory.contains(Self.identitySentinel))
        #expect(inMemory.count <= 160)

        // 磁盘往返：持久化的 route/failure 记录保留同一分类。
        let recordURL = root.appendingPathComponent("chat-execution-state.json")
        let rawData = try Data(contentsOf: recordURL)
        let onDisk = String(decoding: rawData, as: UTF8.self)
        #expect(onDisk.contains("401"))
        #expect(!onDisk.contains(Self.bodySentinel))
        #expect(!onDisk.contains(Self.identitySentinel))

        let restarted = ChatStore()
        #expect(restarted.attachPersistence(SessionStore(directory: root)) == true)
        let restored = try #require(
            restarted.executionSnapshot(forSessionID: sessionID)?.failureReason
        )
        #expect(restored.contains("认证失败"))
        #expect(restored.contains("限流"))
        #expect(!restored.contains(Self.bodySentinel))
    }

    // MARK: helpers（与 ErrorMessageTests 同一条真实 catch 接线）

    private func sendAndWait(for chat: ChatStore) async throws -> String {
        chat.draftText = "触发 fallback 失败"
        chat.sendDraft()
        for _ in 0..<200 {
            if !chat.isStreaming {
                return chat.messages.last?.content ?? ""
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return chat.messages.last?.content ?? ""
    }
}
