import Foundation
import CryptoKit
import Darwin
import os

private let logger = AppLogger(category: "OpenAIResponsesProvider")

private extension Array where Element == UInt8 {
    subscript(safe index: Int) -> UInt8? {
        indices.contains(index) ? self[index] : nil
    }
}

/// LLMProvider implementation for the **OpenAI Responses API**
/// (POST /v1/responses) — the wire protocol behind `ProviderType.openAIResponses`.
///
/// 此前该类型错误地复用 OpenAICompatibleProvider（/v1/chat/completions 协议），
/// 与类型名不符，且会被 wire_api=responses 的中转站拒绝（Chat Completions 带
/// developer/system role 时中继直接 400）。本 Provider 实现真 Responses 协议：
///   - 请求体：model / input（item 数组）/ instructions（系统指令，取代
///     system role）/ max_output_tokens / temperature / stream；
///   - 非流式响应：output[] 中 message item 的 output_text 部件；
///   - 流式：带 event: 名称的 SSE（response.created / response.output_text.delta
///     / response.completed / response.failed / response.incomplete / error），
///     无 Chat Completions 的 [DONE] 哨兵；error 事件与中途 EOF 均抛明确错误。
public final class OpenAIResponsesProvider: LLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
    /// 展示名：默认 "OpenAI Responses"，ProviderFactory 创建时注入真实供应商名
    /// （config.label），让错误提示/UI 显示真实供应商。
    private let providerName: String
    public var name: String { providerName }
    // Public configuration setters, request snapshots and identity fences
    // share one lock. The provider is @unchecked Sendable because callers may
    // rebind it while stream tasks read its state off the main actor.
    private let stateLock = NSLock()
    private var storedModel: LLMModel
    public var model: LLMModel {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return storedModel
        }
        set {
            stateLock.lock()
            defer { stateLock.unlock() }
            storedModel = newValue
            // A generation fence must never wrap back to an earlier value:
            // after exhaustion, keep the terminal value and continue relying
            // on the request nonce/model identity fences.
            if modelGeneration < UInt64.max {
                modelGeneration += 1
            }
            // Rotate independently of the saturating generation so an
            // A→B→A rebind cannot resurrect a completion captured before
            // the generation ceiling was reached.
            latestRequestID = UUID()
        }
    }

    /// 自定义 base URL（官方 https://api.openai.com 或 Responses 兼容中转站）。
    private var storedCustomBaseURL: String?
    public var customBaseURL: String? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return storedCustomBaseURL
        }
        set {
            stateLock.lock()
            defer { stateLock.unlock() }
            storedCustomBaseURL = newValue
        }
    }
    /// 为 true 时在 base 后规范拼接 "/v1"（已带 /v1 后缀会先去重）。
    private var storedAppendV1Suffix: Bool
    public var appendV1Suffix: Bool {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return storedAppendV1Suffix
        }
        set {
            stateLock.lock()
            defer { stateLock.unlock() }
            storedAppendV1Suffix = newValue
        }
    }
    /// 附加 HTTP 头。
    private var storedExtraHeaders: [String: String] = [:]
    public var extraHeaders: [String: String] {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return storedExtraHeaders
        }
        set {
            stateLock.lock()
            defer { stateLock.unlock() }
            storedExtraHeaders = newValue
        }
    }
    /// Non-secret endpoint material injected by `ProviderFactory` for route
    /// configuration binding. Nil for manually constructed legacy providers.
    private var runtimeConfigurationMaterialOverride: String? = nil
    private var runtimeConfigurationUsedCustomBaseURL = false
    public var runtimeConfigurationMaterial: String? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            guard let runtimeConfigurationMaterialOverride else { return nil }
            return runtimeConfigurationUsedCustomBaseURL
                ? (storedCustomBaseURL ?? "") + "|append-v1=" + (storedAppendV1Suffix ? "true" : "false")
                : runtimeConfigurationMaterialOverride
        }
        set {
            stateLock.lock()
            defer { stateLock.unlock() }
            runtimeConfigurationMaterialOverride = newValue
            runtimeConfigurationUsedCustomBaseURL = storedCustomBaseURL != nil
        }
    }

    public static let wireCapabilities: Set<ProviderCapability> = [.streaming, .tools, .vision, .audio]
    public var capabilities: Set<ProviderCapability> { Self.wireCapabilities }

    private let apiKey: String
    /// 可注入 session（测试用 URLProtocol mock；默认长超时 SSE session）。
    private let session: URLSession
    /// Instance-scoped test checkpoint root. Production keeps the canonical path.
    /// Immutable instance binding; the App must supply its profile-local
    /// directory before the initializer reads durable attempt state.
    let attemptCheckpointDirectory: URL?
    /// Internal, instance-bound observation point for a controlled assembly
    /// barrier. Production leaves it nil and follows the same request path.
    private let requestAssemblyProbe: (@Sendable () -> Void)?
    /// Test-only observation immediately before a durable write. Production
    /// leaves this nil; it lets a test hold real persistence while reading
    /// public configuration from another task.
    private let durableWriteProbe: (@Sendable () -> Void)?

    private struct RequestAssemblyConfiguration: Sendable {
        let model: LLMModel
        let customBaseURL: String?
        let appendV1Suffix: Bool
        let extraHeaders: [String: String]
        let apiKey: String
        let probe: (@Sendable () -> Void)?
        /// ChatGPT account sign-in: `apiKey` is a placeholder swapped for the live access token.
        let usesChatGPTAccount: Bool

        func replacingAPIKey(_ value: String) -> RequestAssemblyConfiguration {
            RequestAssemblyConfiguration(
                model: model, customBaseURL: customBaseURL, appendV1Suffix: appendV1Suffix,
                extraHeaders: extraHeaders, apiKey: value, probe: probe,
                usesChatGPTAccount: usesChatGPTAccount)
        }
    }

    /// True when the provider record signs in with a ChatGPT account instead of an API key.
    private var usesChatGPTAccount: Bool { apiKey == ChatGPTAccountSession.credentialPlaceholder }
    /// Monotonic local generation fencing requests against a later model rebind.
    private var modelGeneration: UInt64 = 0
    /// The latest request nonce prevents a late result from an older request
    /// being projected as an error for a newer retry or rebind.
    private var latestRequestID: UUID?
    /// Monotonic attempt fence: completed request IDs are never reused under
    /// the same attempt generation, even when the model generation is stable.
    private var attemptGeneration: UInt64 = 0
    private var attemptGenerationHighWaterByScope: [DurableAttemptScope: UInt64] = [:]
    /// Invalid durable state blocks requests until the checkpoint is repaired;
    /// silently starting from zero could reuse a completed attempt fence.
    private var durableAttemptStateValid = true
    private var lastDurableAttemptWriteStage = DurableAttemptWriteStage.none
    private let persistAttemptReceiptDiagnosticLock = NSLock()
    private var lastPersistAttemptReceiptStage = PersistAttemptReceiptStage.notAttempted

    /// Bounds the untrusted SSE surface before JSON decoding or accumulation.
    private static let maxSSELineBytes = 256 * 1024
    private static let maxSSEEventDataBytes = 1024 * 1024
    private static let maxSSEFieldNameBytes = 64
    private static let maxSSEFieldValueBytes = 4 * 1024
    private static let maxSSEEventNameBytes = 256
    private static let maxSSEEventIDBytes = 4 * 1024
    private static let maxSSEResponseIdentityBytes = 256
    private static let maxSSERetryBytes = 64
    private static let maxSSELineCount = 100_000
    private static let maxSSETotalBytes = 16 * 1024 * 1024
    private static let maxSSEEventCount = 10_000
    private static let maxRequestIdentityFieldBytes = 256
    /// Bounds a non-streaming response before Foundation JSON decoding.
    private static let maxNonStreamingResponseBytes = 16 * 1024 * 1024
    /// Durable attempt receipts are intentionally tiny; never read an
    /// unbounded checkpoint into memory before validating its JSON shape.
    private static let maxDurableAttemptRecordBytes = 64 * 1024
    private static let maxDurableResponseBodyBytes = 16 * 1024 * 1024
    private static let maxDurableReceiptHistory = 8
    private static let maxJSONDepth = 32
    /// 整份 JSON 的键总数。ChatGPT 账号会在 response.created / response.completed 里
    /// 回显整份工具定义，接几个 MCP 服务器就有几千个键；旧值 2048 让"先说话再调工具"的
    /// 回复被判成 invalid SSE JSON（11/19 现场）。解析成本仍由单事件 1MB、整流 16MB 的
    /// 字节上限兜住，这里只防病态的超多小键。
    private static let maxJSONKeyCount = 262_144
    private static let maxJSONStringBytes = 1024 * 1024
    private static let nonStreamingResponseSchemaFingerprint = "responses-json-v1"
    private static let streamingResponseSchemaFingerprint = "responses-sse-v1"

    private enum DurableAttemptWriteStage: String, Sendable {
        case none
        case targetURLRejected
        case existingIdentityRejected
        case absentIdentityRejected
        case generationCASRejected
        case placeholderSizeRejected
        case temporaryIdentityRejected
        case finalizedIdentityOrPhaseRejected
        case finalizedGenerationOrHistoryRejected
        case finalizedRequestPayloadOrCheckpointDigestRejected
        case finalizedSegmentManifestRootOrSealRejected
        case finalizedCleanupLineageRejected
        case finalizedResponseProjectionRejected
        case finalizedSizeRejected
        case temporaryIdentityChanged
        case temporarySyncRejected
        case pendingSymbolicLinkRejected
        case pendingReplacementRejected
        case pendingSyncRejected
        case targetIdentityRejected
        case absentTargetRejected
        case finalReadbackRejected
        case ioRejected
        case unknown
    }

    private enum PersistAttemptReceiptStage: String, Sendable {
        case notAttempted
        case canonicalIdentity
        case responseBodyBound
        case durableStateRequestBinding
        case committedDowngrade
        case responseIDConflict
        case cumulativeResponseBodyBound
        case writeAttempted
    }

    private struct DurableAttemptScope: Hashable, Sendable {
        let providerID: String
        let modelID: String
    }

    private enum DurableAttemptValidationRejection {
        case identityOrPhase
        case generationOrHistory
        case requestPayloadOrCheckpointDigest
        case segmentManifestRootOrSeal
        case cleanupLineage
        case responseProjection

        var writeStage: DurableAttemptWriteStage {
            switch self {
            case .identityOrPhase:
                return .finalizedIdentityOrPhaseRejected
            case .generationOrHistory:
                return .finalizedGenerationOrHistoryRejected
            case .requestPayloadOrCheckpointDigest:
                return .finalizedRequestPayloadOrCheckpointDigestRejected
            case .segmentManifestRootOrSeal:
                return .finalizedSegmentManifestRootOrSealRejected
            case .cleanupLineage:
                return .finalizedCleanupLineageRejected
            case .responseProjection:
                return .finalizedResponseProjectionRejected
            }
        }
    }

    func durableAttemptWriteDiagnosticStage() -> String {
        Self.durableAttemptStateLock.lock()
        defer { Self.durableAttemptStateLock.unlock() }
        return lastDurableAttemptWriteStage == .none
            ? DurableAttemptWriteStage.unknown.rawValue
            : lastDurableAttemptWriteStage.rawValue
    }

    func persistAttemptReceiptDiagnosticStage() -> String {
        persistAttemptReceiptDiagnosticLock.lock()
        defer { persistAttemptReceiptDiagnosticLock.unlock() }
        return lastPersistAttemptReceiptStage.rawValue
    }

    private func setPersistAttemptReceiptDiagnosticStage(
        _ stage: PersistAttemptReceiptStage
    ) {
        persistAttemptReceiptDiagnosticLock.lock()
        defer { persistAttemptReceiptDiagnosticLock.unlock() }
        lastPersistAttemptReceiptStage = stage
    }

    private struct RequestIdentity: Equatable, Sendable {
        let providerID: String
        let modelID: String
        let generation: UInt64
        let attemptGeneration: UInt64
        let requestID: UUID
        let stream: Bool
        let responseSchemaFingerprint: String
        let requestScopeDigest: String

        init(
            providerID: String,
            modelID: String,
            generation: UInt64,
            attemptGeneration: UInt64,
            requestID: UUID,
            stream: Bool,
            responseSchemaFingerprint: String,
            requestScopeDigest: String
        ) {
            self.providerID = providerID
            self.modelID = modelID
            self.generation = generation
            self.attemptGeneration = attemptGeneration
            self.requestID = requestID
            self.stream = stream
            self.responseSchemaFingerprint = responseSchemaFingerprint
            self.requestScopeDigest = requestScopeDigest
        }
    }

    private struct DurableReceiptHistoryEntry: Codable, Equatable, Sendable {
        let generation: UInt64
        let requestDigest: String
        let transactionID: UUID
        let payloadDigest: String
        let checkpointDigest: String?
    }

    private struct DurableCleanupTombstone: Codable, Equatable, Sendable {
        let generation: UInt64
        let requestDigest: String
        let transactionID: UUID
        let payloadDigest: String
        let checkpointDigest: String
        let predecessorHistoryDigest: String
        let predecessorCheckpointDigest: String
        let predecessorManifestRoot: String
        let successorManifestRoot: String?
        let successorHistoryDigest: String?
        let successorPayloadDigest: String?
    }

    private struct DurableAttemptRecord: Codable, Equatable, Sendable {
        let providerID: String
        let modelID: String
        let generation: UInt64
        let previousGeneration: UInt64?
        let previousDigest: String?
        let previousTransactionID: UUID?
        let previousPayloadDigest: String?
        let epochPredecessorDigest: String?
        let historyPredecessorDigest: String?
        let modelGeneration: UInt64
        let requestID: UUID?
        let requestDigest: String?
        let transactionID: UUID?
        let requestScopeDigest: String?
        let responseSchemaFingerprint: String?
        let receiptHistory: [DurableReceiptHistoryEntry]
        let historyDigest: String?
        let compactionTransactionID: UUID?
        let segmentManifest: [DurableReceiptHistoryEntry]
        let segmentManifestRoot: String?
        let segmentManifestReadbackSeal: String?
        let segmentGenerationCAS: [UInt64]
        let cleanupTombstone: DurableCleanupTombstone?
        let cleanupTombstoneSeal: String?
        let cleanupEpochPredecessorSeal: String?
        let segmentManifestPredecessorRoot: String?
        let payloadDigest: String?
        let checkpointDigest: String?
        let responseBodyDigest: String?
        let responseBodyBytes: UInt64?
        let phase: String
        let responseID: String?
        let lastEventID: String?
        let retryMilliseconds: UInt64?
        let fileDevice: UInt64
        let fileInode: UInt64

        func validationRejection(
            forProviderID providerID: String,
            modelID: String
        ) -> DurableAttemptValidationRejection? {
            guard self.providerID == providerID, self.modelID == modelID,
                  OpenAIResponsesProvider.canonicalIdentityField(self.providerID) == self.providerID,
                  OpenAIResponsesProvider.canonicalIdentityField(self.modelID) == self.modelID,
                  fileDevice > 0, fileInode > 0,
                  phase == "prepared" || phase == "committed" else { return .identityOrPhase }
            if generation == 0 {
                    guard previousGeneration == nil, previousDigest == nil,
                      previousTransactionID == nil, previousPayloadDigest == nil,
                      epochPredecessorDigest == nil,
                      historyPredecessorDigest == nil,
                      requestID == nil, requestDigest == nil,
                      requestScopeDigest == nil, responseSchemaFingerprint == nil,
                      receiptHistory.isEmpty,
                      historyDigest == nil, compactionTransactionID == nil,
                      segmentManifest.isEmpty, segmentManifestRoot == nil,
                      segmentManifestReadbackSeal == nil,
                      segmentGenerationCAS.isEmpty,
                      cleanupTombstone == nil, cleanupTombstoneSeal == nil,
                      cleanupEpochPredecessorSeal == nil,
                      segmentManifestPredecessorRoot == nil,
                      payloadDigest == nil, checkpointDigest == nil,
                      responseBodyDigest == nil,
                      responseBodyBytes == nil,
                      responseID == nil else { return .generationOrHistory }
            } else {
                guard let previousGeneration,
                      previousGeneration < UInt64.max,
                      generation == previousGeneration + 1 else { return .generationOrHistory }
                if previousGeneration == 0 {
                    guard previousDigest == nil,
                          previousTransactionID == nil,
                          previousPayloadDigest == nil,
                          epochPredecessorDigest == nil,
                          historyPredecessorDigest == nil,
                          receiptHistory.isEmpty,
                          compactionTransactionID == nil,
                          cleanupTombstone == nil, cleanupTombstoneSeal == nil,
                          cleanupEpochPredecessorSeal == nil,
                          segmentManifestPredecessorRoot == nil else { return .generationOrHistory }
                } else {
                    guard let previousDigest,
                          let previousTransactionID,
                          let previousPayloadDigest,
                          let epochPredecessorDigest,
                          OpenAIResponsesProvider.isDigest(previousDigest),
                          OpenAIResponsesProvider.isDigest(previousPayloadDigest),
                          OpenAIResponsesProvider.isDigest(epochPredecessorDigest),
                          let historyPredecessorDigest,
                          OpenAIResponsesProvider.isDigest(historyPredecessorDigest),
                          previousTransactionID.uuidString != "00000000-0000-0000-0000-000000000000",
                          receiptHistory.count <= OpenAIResponsesProvider.maxDurableReceiptHistory,
                          let last = receiptHistory.last,
                          last.generation == previousGeneration,
                          last.requestDigest == previousDigest,
                          last.transactionID == previousTransactionID,
                          last.payloadDigest == previousPayloadDigest,
                          last.checkpointDigest == epochPredecessorDigest,
                          let segmentManifestPredecessorRoot,
                          OpenAIResponsesProvider.isDigest(segmentManifestPredecessorRoot) else { return .generationOrHistory }
                }
                guard let historyDigest,
                      OpenAIResponsesProvider.isDigest(historyDigest),
                      historyDigest == OpenAIResponsesProvider.receiptHistoryDigest(receiptHistory) else { return .generationOrHistory }
                if let compactionTransactionID {
                    guard receiptHistory.count == OpenAIResponsesProvider.maxDurableReceiptHistory,
                          compactionTransactionID.uuidString != "00000000-0000-0000-0000-000000000000",
                          !receiptHistory.contains(where: { $0.transactionID == compactionTransactionID }) else { return .generationOrHistory }
                } else {
                    guard cleanupTombstone == nil, cleanupTombstoneSeal == nil,
                          cleanupEpochPredecessorSeal == nil else { return .cleanupLineage }
                }
                guard segmentGenerationCAS.count <= OpenAIResponsesProvider.maxDurableReceiptHistory + 1,
                      segmentGenerationCAS == segmentManifest.map(\.generation) else { return .generationOrHistory }
                var lastGeneration: UInt64?
                var historyTransactionIDs = Set<UUID>()
                var historyRequestDigests = Set<String>()
                for entry in receiptHistory {
                    guard entry.generation > 0,
                          OpenAIResponsesProvider.isDigest(entry.requestDigest),
                          OpenAIResponsesProvider.isDigest(entry.payloadDigest),
                          OpenAIResponsesProvider.isDigest(entry.checkpointDigest ?? ""),
                          entry.transactionID.uuidString != "00000000-0000-0000-0000-000000000000",
                          historyTransactionIDs.insert(entry.transactionID).inserted,
                          historyRequestDigests.insert(entry.requestDigest).inserted else { return .generationOrHistory }
                    if let lastGeneration, entry.generation <= lastGeneration { return .generationOrHistory }
                    lastGeneration = entry.generation
                }
                guard let requestID, let requestDigest,
                      let transactionID,
                      let requestScopeDigest,
                      let responseSchemaFingerprint,
                      let payloadDigest,
                      OpenAIResponsesProvider.isDigest(requestDigest),
                      OpenAIResponsesProvider.isDigest(requestScopeDigest),
                      OpenAIResponsesProvider.isDigest(payloadDigest),
                      OpenAIResponsesProvider.isKnownResponseSchema(responseSchemaFingerprint),
                      transactionID.uuidString != "00000000-0000-0000-0000-000000000000",
                      requestDigest == OpenAIResponsesProvider.requestDigest(
                        providerID: self.providerID,
                        modelID: self.modelID,
                        generation: modelGeneration,
                        attemptGeneration: generation,
                        requestID: requestID
                      ),
                      requestScopeDigest == OpenAIResponsesProvider.requestScopeDigest(
                        providerID: self.providerID,
                        modelID: self.modelID,
                        generation: modelGeneration,
                        attemptGeneration: generation,
                        requestID: requestID,
                        responseSchemaFingerprint: responseSchemaFingerprint
                      ),
                      !receiptHistory.contains(where: {
                          $0.generation == generation
                              || $0.requestDigest == requestDigest
                              || $0.transactionID == transactionID
                              || $0.transactionID == compactionTransactionID
                      }),
                      payloadDigest == OpenAIResponsesProvider.receiptPayloadDigest(self),
                      let checkpointDigest,
                      OpenAIResponsesProvider.isDigest(checkpointDigest),
                      checkpointDigest == OpenAIResponsesProvider.receiptCheckpointDigest(self) else { return .requestPayloadOrCheckpointDigest }
                let expectedManifest = receiptHistory + [
                    DurableReceiptHistoryEntry(
                        generation: generation,
                        requestDigest: requestDigest,
                        transactionID: transactionID,
                        payloadDigest: payloadDigest,
                        checkpointDigest: nil
                    )
                ]
                guard segmentManifest.count <= OpenAIResponsesProvider.maxDurableReceiptHistory + 1,
                      segmentManifest.count == receiptHistory.count + 1,
                      segmentManifest == expectedManifest,
                      let segmentManifestRoot,
                      OpenAIResponsesProvider.isDigest(segmentManifestRoot),
                      segmentManifestRoot == OpenAIResponsesProvider.segmentManifestRoot(segmentManifest),
                      let segmentManifestReadbackSeal,
                      OpenAIResponsesProvider.isDigest(segmentManifestReadbackSeal),
                      segmentManifestReadbackSeal == OpenAIResponsesProvider.segmentManifestReadbackSeal(self) else { return .segmentManifestRootOrSeal }
                if let compactionTransactionID {
                    guard let cleanupTombstone,
                          cleanupTombstone.generation > 0,
                          cleanupTombstone.generation < UInt64.max,
                          OpenAIResponsesProvider.isDigest(cleanupTombstone.requestDigest),
                          OpenAIResponsesProvider.isDigest(cleanupTombstone.payloadDigest),
                          OpenAIResponsesProvider.isDigest(cleanupTombstone.checkpointDigest),
                          OpenAIResponsesProvider.isDigest(cleanupTombstone.predecessorHistoryDigest),
                          cleanupTombstone.predecessorHistoryDigest == historyPredecessorDigest,
                          OpenAIResponsesProvider.isDigest(cleanupTombstone.predecessorCheckpointDigest),
                          cleanupTombstone.predecessorCheckpointDigest == epochPredecessorDigest,
                          OpenAIResponsesProvider.isDigest(cleanupTombstone.predecessorManifestRoot),
                          cleanupTombstone.predecessorManifestRoot == segmentManifestPredecessorRoot,
                          let successorManifestRoot = cleanupTombstone.successorManifestRoot,
                          OpenAIResponsesProvider.isDigest(successorManifestRoot),
                          successorManifestRoot == segmentManifestRoot,
                          let successorHistoryDigest = cleanupTombstone.successorHistoryDigest,
                          OpenAIResponsesProvider.isDigest(successorHistoryDigest),
                          successorHistoryDigest == historyDigest,
                          let successorPayloadDigest = cleanupTombstone.successorPayloadDigest,
                          OpenAIResponsesProvider.isDigest(successorPayloadDigest),
                          successorPayloadDigest == payloadDigest,
                          cleanupTombstone.transactionID.uuidString != "00000000-0000-0000-0000-000000000000",
                          cleanupTombstone.transactionID != transactionID,
                          cleanupTombstone.transactionID != compactionTransactionID,
                          !segmentManifest.contains(where: { $0.generation == cleanupTombstone.generation }),
                          segmentManifest.first?.generation == cleanupTombstone.generation + 1,
                          let cleanupTombstoneSeal,
                          OpenAIResponsesProvider.isDigest(cleanupTombstoneSeal),
                          cleanupTombstoneSeal == OpenAIResponsesProvider.cleanupTombstoneSeal(
                              cleanupTombstone,
                              compactionTransactionID: compactionTransactionID,
                              previousSeal: cleanupEpochPredecessorSeal
                          ) else { return .cleanupLineage }
                    if cleanupTombstone.generation == 1 {
                        guard cleanupEpochPredecessorSeal == nil else { return .cleanupLineage }
                    } else {
                        guard let cleanupEpochPredecessorSeal,
                              OpenAIResponsesProvider.isDigest(cleanupEpochPredecessorSeal) else { return .cleanupLineage }
                    }
                } else {
                    guard cleanupTombstone == nil, cleanupTombstoneSeal == nil,
                          cleanupEpochPredecessorSeal == nil else { return .cleanupLineage }
                }
            }
            if let responseBodyDigest {
                guard OpenAIResponsesProvider.isDigest(responseBodyDigest),
                      let responseBodyBytes,
                      responseBodyBytes > 0,
                      responseBodyBytes <= OpenAIResponsesProvider.maxDurableResponseBodyBytes else { return .responseProjection }
            } else {
                guard responseBodyBytes == nil else { return .responseProjection }
            }
            guard responseID == nil || requestID != nil else { return .responseProjection }
            if phase == "committed",
               responseSchemaFingerprint == OpenAIResponsesProvider.streamingResponseSchemaFingerprint {
                guard responseID != nil, responseBodyDigest != nil else { return .responseProjection }
            } else if phase == "committed",
                      responseSchemaFingerprint == OpenAIResponsesProvider.nonStreamingResponseSchemaFingerprint {
                guard responseBodyDigest != nil else { return .responseProjection }
            }
            guard responseID?.isEmpty != true,
                  lastEventID?.isEmpty != true else { return .responseProjection }
            return nil
        }

        func isValid(forProviderID providerID: String, modelID: String) -> Bool {
            validationRejection(forProviderID: providerID, modelID: modelID) == nil
        }
    }

    private static let durableAttemptStateLock = NSLock()
    /// Tests may point receipts at an isolated directory; production uses the
    /// app-support checkpoint directory. The override is internal by design so
    /// direct tests never touch a user's durable state.
    nonisolated(unsafe) static var attemptCheckpointDirectoryOverride: URL?

    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    private struct DurableAttemptCandidate {
        let url: URL
        let record: DurableAttemptRecord
        let identity: FileIdentity
    }

    /// Per-attempt SSE reconnect metadata. It is deliberately value-scoped to
    /// one stream task: a truncated/invalid transaction is discarded with the
    /// task and can never poison a later attempt with stale IDs or retry data.
    private struct SSEReconnectState: Sendable {
        let identity: RequestIdentity
        var lastEventID: String?
        var retryMilliseconds: UInt64?
        var seenEventIDs = Set<String>()

        init(identity: RequestIdentity) {
            self.identity = identity
        }

        @discardableResult
        mutating func commit(
            for identity: RequestIdentity,
            eventID: String?,
            retryMilliseconds: UInt64?
        ) -> Bool {
            guard self.identity == identity else { return false }
            if let eventID, !eventID.isEmpty {
                seenEventIDs.insert(eventID)
                lastEventID = eventID
            }
            if let retryMilliseconds {
                self.retryMilliseconds = retryMilliseconds
            }
            return true
        }

        mutating func reset() {
            lastEventID = nil
            retryMilliseconds = nil
            seenEventIDs.removeAll(keepingCapacity: false)
        }
    }

    private static let defaultStreamingSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 600  // 10 分钟长流
        // S4：携带 Bearer 的请求只允许跟随到 https / loopback http 的重定向。
        return URLSession(configuration: config, delegate: ProviderRedirectGuard.shared, delegateQueue: nil)
    }()

    public convenience init(apiKey: String, model: LLMModel = .gpt4oMini, customBaseURL: String? = nil,
                            appendV1Suffix: Bool = true, session: URLSession? = nil, providerName: String = "OpenAI Responses") {
        self.init(apiKey: apiKey, model: model, customBaseURL: customBaseURL,
                  appendV1Suffix: appendV1Suffix, session: session, providerName: providerName,
                  attemptCheckpointDirectory: nil)
    }

    init(apiKey: String, model: LLMModel, customBaseURL: String?, appendV1Suffix: Bool,
         session: URLSession?, providerName: String, attemptCheckpointDirectory: URL?,
         requestAssemblyProbe: (@Sendable () -> Void)? = nil,
         durableWriteProbe: (@Sendable () -> Void)? = nil) {
        self.apiKey = apiKey
        self.storedModel = model
        self.storedCustomBaseURL = customBaseURL
        self.storedAppendV1Suffix = appendV1Suffix
        self.session = session ?? Self.defaultStreamingSession
        self.providerName = providerName
        self.attemptCheckpointDirectory = attemptCheckpointDirectory
        self.requestAssemblyProbe = requestAssemblyProbe
        self.durableWriteProbe = durableWriteProbe
        let durableState = Self.readDurableAttemptState(
            providerID: providerName,
            modelID: model.id,
            directoryOverride: attemptCheckpointDirectory
        )
        self.attemptGeneration = durableState.generation
        self.durableAttemptStateValid = durableState.isValid
        if durableState.isValid,
           let providerID = Self.canonicalIdentityField(providerName),
           let modelID = Self.canonicalIdentityField(model.id) {
            self.attemptGenerationHighWaterByScope[
                DurableAttemptScope(providerID: providerID, modelID: modelID)
            ] = durableState.generation
        }
    }

    // MARK: - Endpoint

    /// POST {base}/v1/responses（appendV1Suffix=false 时 base 原样 + /responses）。
    private static func endpointURL(customBaseURL: String?, appendV1Suffix: Bool) -> URL? {
        let base = appendV1Suffix
            ? stripV1Suffix(customBaseURL ?? "https://api.openai.com")
            : (customBaseURL ?? "https://api.openai.com")
        let v1Path = appendV1Suffix ? "/v1" : ""
        return URL(string: URLBuilding.join(base, v1Path, "/responses"))
    }

    /// 去掉末尾 "/v1"（与 OpenAICompatibleProvider 同规则），避免 /v1/v1/responses。
    private static func stripV1Suffix(_ base: String) -> String {
        var s = base
        while s.hasSuffix("/") { s = String(s.dropLast()) }
        if s.hasSuffix("/v1") { s = String(s.dropLast(3)) }
        return s
    }

    // MARK: - Message serialization（Chat Completions 消息 → Responses input items）

    /// 单条 LLMMessage → Responses input item（role + content 部件数组）。
    ///
    /// P3-MEDIA-01 consumer coverage (lane 138): when `mediaCapabilities` is
    /// provided — production assembly (`requestBody`) passes
    /// `model.capabilities` — every media part first goes through
    /// `MediaCapabilityGate`, the same single decision source the
    /// OpenAI-compatible chat-completions wire uses. Gate-rejected parts
    /// (SVG, unclassifiable MIME, media the model does not declare) and
    /// capability-admitted parts this wire's content items cannot carry
    /// (non-raster payloads inside `input_image`) degrade to a deterministic
    /// `[media-gate]` input_text part; allowed raster images and audios
    /// serialize exactly as before. Failure isolation: one rejected part
    /// never drops or corrupts its siblings, and its bytes are never
    /// (re-)emitted on later turns.
    /// `mediaCapabilities: nil` keeps the legacy ungated behavior for pinned
    /// tests only; it must not be used by product call sites.
    public static func responsesInputItem(
        _ msg: LLMMessage,
        mediaCapabilities: ModelCapabilities? = nil
    ) -> ResponsesAPIRequestBody.InputMessage {
        typealias Part = ResponsesAPIRequestBody.InputMessage.ContentPart
        // 历史里的助手消息：只回放文本，部件类型必须是 output_text（input_text 会让第二轮起整轮 400）。
        if msg.role == .assistant {
            return .init(role: msg.role.rawValue,
                         content: msg.content.isEmpty ? [] : [.outputTextPart(msg.content)])
        }
        var parts: [Part] = []
        for img in msg.images {
            if let capabilities = mediaCapabilities {
                let decision = MediaPayloadValidation.decision(data: img.data, mimeType: img.mimeType,
                    capabilities: capabilities, wire: .openaiResponses)
                let note: String?
                if let rejection = MediaCapabilityGate.rejectionNote(
                    for: decision, mimeType: img.mimeType) {
                    note = rejection
                } else if case .allowed(let kind) = decision, kind != .rasterImage {
                    // Capability admitted the medium, but this wire's
                    // `input_image` item carries raster images only.
                    note = MediaCapabilityGate.rejectionNote(
                        mimeType: img.mimeType,
                        reason: "the Responses API input_image content part on this wire path carries raster images only."
                    )
                } else {
                    note = nil
                }
                if let note {
                    parts.append(.textPart(note))
                    continue
                }
            }
            let dataURL = "data:\(img.mimeType);base64,\(img.data.base64EncodedString())"
            parts.append(.imagePart(dataURL: dataURL))
        }
        for audio in msg.audios {
            let audioMIME = "audio/\(audio.format)"
            if let capabilities = mediaCapabilities,
               let note = MediaCapabilityGate.rejectionNote(
                for: MediaPayloadValidation.decision(data: Data(base64Encoded: audio.base64Data) ?? Data(),
                    mimeType: audioMIME, capabilities: capabilities, wire: .openaiResponses),
                mimeType: audioMIME
               ) {
                parts.append(.textPart(note))
                continue
            }
            parts.append(.audioPart(base64Data: audio.base64Data, format: mediaCapabilities == nil
                ? audio.format : MediaPayloadValidation.audioFormat(Data(base64Encoded: audio.base64Data) ?? Data()) ?? audio.format))
        }
        if !msg.content.isEmpty {
            parts.append(.textPart(msg.content))
        }
        return .init(role: msg.role.rawValue, content: parts)
    }

    /// 构造请求体字典（JSONEncoder 前的中间形态，便于测试断言）。
    func requestBody(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition] = [],
        maxTokens: Int,
        temperature: Double?,
        stream: Bool
    ) throws -> ResponsesAPIRequestBody {
        try Self.requestBody(
            messages: messages, systemPrompt: systemPrompt, tools: tools,
            maxTokens: maxTokens, temperature: temperature, stream: stream,
            model: model
        )
    }

    private static func requestBody(
        messages: [LLMMessage], systemPrompt: String?,
        tools: [AgentToolDefinition], maxTokens: Int,
        temperature: Double?, stream: Bool, model: LLMModel
    ) throws -> ResponsesAPIRequestBody {
        guard !messages.isEmpty else {
            throw LLMError.providerError(message: "Responses API requires at least one input message")
        }
        var specialItems: [ResponsesAPIRequestBody.InputItem] = []
        var containsSpecialItems = false
        // 工具返回的图片：function_call_output 只能放文字，图片在这一批连续工具输出之后追加成 user 消息。
        var toolNames: [String: String] = [:]
        var pendingImageMessages: [LLMMessage] = []
        func flushToolImages() {
            for imageMessage in pendingImageMessages {
                specialItems.append(.message(responsesInputItem(imageMessage, mediaCapabilities: model.capabilities)))
            }
            pendingImageMessages.removeAll()
        }
        for message in messages {
            if message.role != .tool { flushToolImages() }
            for call in message.toolCalls { toolNames[call.id] = call.name }
            if message.role == .tool {
                containsSpecialItems = true
                specialItems.append(.functionCallOutput(
                    callID: message.toolCallID ?? "unknown_tool_call",
                    output: message.content
                ))
                if !message.images.isEmpty {
                    let name = message.toolCallID.flatMap { toolNames[$0] } ?? "未知工具"
                    pendingImageMessages.append(LLMMessage(role: .user, content: "[工具 \(name) 返回的图片]",
                                                           images: message.images))
                }
            } else if !message.toolCalls.isEmpty {
                containsSpecialItems = true
                if !message.content.isEmpty {
                    specialItems.append(.message(responsesInputItem(message, mediaCapabilities: model.capabilities)))
                }
                for call in message.toolCalls {
                    specialItems.append(.functionCall(
                        callID: call.id,
                        name: call.name,
                        arguments: call.rawArguments
                    ))
                }
            } else {
                // 空的助手消息（例如被中断、没有文字也没有工具调用）不回放：空 content 会被拒。
                if message.role == .assistant && message.content.isEmpty { continue }
                specialItems.append(.message(responsesInputItem(message, mediaCapabilities: model.capabilities)))
            }
        }
        flushToolImages()
        let input: AnyCodableInput = containsSpecialItems
            ? .items(specialItems)
            : .messages(messages
                .filter { !($0.role == .assistant && $0.content.isEmpty) }
                .map { responsesInputItem($0, mediaCapabilities: model.capabilities) })
        return ResponsesAPIRequestBody(
            model: model.id,
            input: input,
            instructions: (systemPrompt?.isEmpty == false) ? systemPrompt : nil,
            maxOutputTokens: maxTokens,
            temperature: temperature,
            stream: stream,
            tools: tools.map { $0.responsesToolDict }
        )
    }

    private func buildRequestOffMain(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?,
        thinkingLevel: ThinkingLevel? = nil,
        stream: Bool,
        identity: RequestIdentity
    ) async throws -> URLRequest {
        // Freeze every mutable wire input before leaving the caller's actor.
        // A later model/endpoint rebind cannot change the in-flight bytes.
        let frozenConfiguration = try requestConfiguration(for: identity)
        let configuration: RequestAssemblyConfiguration
        if frozenConfiguration.usesChatGPTAccount {
            // The access token rotates hourly: resolve it per request, never at construction.
            configuration = frozenConfiguration.replacingAPIKey(try await Self.chatGPTAccessToken())
        } else {
            configuration = frozenConfiguration
        }
        let applicationObserver = AssistantThinkingParameters.reportApplication
        let worker = Task.detached(priority: .userInitiated) {
            try Self.buildRequest(
                messages: messages, systemPrompt: systemPrompt, tools: tools,
                maxTokens: maxTokens, temperature: temperature, thinkingLevel: thinkingLevel, stream: stream,
                configuration: configuration, applicationObserver: applicationObserver
            )
        }
        let request: URLRequest
        do {
            request = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
        } catch is CancellationError {
            throw LLMError.cancelled
        }
        guard !Task.isCancelled, isCurrent(identity) else { throw LLMError.cancelled }
        return request
    }

    private func requestConfiguration(for identity: RequestIdentity) throws -> RequestAssemblyConfiguration {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard Self.canonicalIdentityField(storedModel.id) == identity.modelID,
              modelGeneration == identity.generation,
              attemptGeneration == identity.attemptGeneration,
              latestRequestID == identity.requestID else { throw LLMError.cancelled }
        return RequestAssemblyConfiguration(
            model: storedModel, customBaseURL: storedCustomBaseURL,
            appendV1Suffix: storedAppendV1Suffix, extraHeaders: storedExtraHeaders,
            apiKey: apiKey, probe: requestAssemblyProbe,
            usesChatGPTAccount: usesChatGPTAccount
        )
    }

    private static func buildRequest(
        messages: [LLMMessage], systemPrompt: String?,
        tools: [AgentToolDefinition], maxTokens: Int,
        temperature: Double?, thinkingLevel: ThinkingLevel? = nil, stream: Bool,
        configuration: RequestAssemblyConfiguration,
        applicationObserver: (@Sendable (ThinkingParameterApplication) -> Void)?
    ) throws -> URLRequest {
        configuration.probe?()
        try Task.checkCancellation()
        // S4：自定义 base URL 必须通过 scheme/host 校验（https，或显式
        // loopback http；不得内嵌凭据），否则 fail-closed，不构造带 Bearer 的请求。
        if let custom = configuration.customBaseURL {
            do {
                _ = try CustomProviderURL.validate(custom)
            } catch let failure as CustomProviderURL.Failure {
                throw LLMError.providerError(message: "Unsafe custom provider URL: \(failure.localizedDescription)")
            }
        }
        guard let url = endpointURL(
            customBaseURL: configuration.customBaseURL,
            appendV1Suffix: configuration.appendV1Suffix
        ) else {
            throw LLMError.providerError(message: "Invalid Responses API base URL")
        }
        // The ChatGPT access token may only ever go to the official API host.
        if configuration.usesChatGPTAccount, !ChatGPTAccountEndpoints.isOfficialAPIURL(url) {
            throw LLMError.providerError(message: "ChatGPT 账号只能连接官方接口地址。")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        for (key, value) in configuration.extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let body = try requestBody(
            messages: messages,
            systemPrompt: systemPrompt,
            tools: tools,
            maxTokens: maxTokens,
            temperature: temperature,
            stream: stream,
            model: configuration.model
        )
        try Task.checkCancellation()
        let encodedBody = try JSONEncoder().encode(body)
        if let thinkingLevel,
           var wireBody = try JSONSerialization.jsonObject(with: encodedBody) as? [String: Any] {
            AssistantThinkingParameters.apply(thinkingLevel, modelID: configuration.model.id,
                wire: .openAIResponses, body: &wireBody, report: applicationObserver)
            request.httpBody = try JSONSerialization.data(withJSONObject: wireBody, options: [.sortedKeys])
        } else {
            request.httpBody = encodedBody
        }
        if configuration.usesChatGPTAccount,
           let finalBody = request.httpBody,
           var wireBody = try JSONSerialization.jsonObject(with: finalBody) as? [String: Any] {
            ChatGPTAccountRequestPolicy.rewrite(&wireBody)
            request.httpBody = try JSONSerialization.data(withJSONObject: wireBody, options: [.sortedKeys])
        }
        return request
    }

    /// Live ChatGPT access token (refreshes ahead of expiry). Failures carry fixed Chinese guidance.
    private static func chatGPTAccessToken() async throws -> String {
        guard let session = ChatGPTAccountSessions.shared else {
            throw LLMError.providerError(message: ChatGPTAccountError.notSignedIn.localizedDescription)
        }
        do {
            return try await session.accessToken()
        } catch is CancellationError {
            throw LLMError.cancelled
        } catch let failure as ChatGPTAccountError {
            if failure == .cancelled { throw LLMError.cancelled }
            if failure == .requestFailed { throw LLMError.transientError(message: failure.localizedDescription) }
            throw LLMError.providerError(message: failure.localizedDescription)
        }
    }

    /// Non-2xx before a stream opens. The error body is read (bounded) for every account
    /// type, only to pick fixed local guidance (ChatGPT plan usage, context overflow,
    /// insufficient balance); the body text itself never reaches the UI or the logs.
    private func httpFailure(
        statusCode: Int,
        headers: [String: String],
        bytes: URLSession.AsyncBytes,
        identity: RequestIdentity
    ) async -> LLMError {
        var body = Data()
        do {
            for try await byte in bytes {
                body.append(byte)
                if body.count >= 16 * 1024 { break }
            }
        } catch {}
        if usesChatGPTAccount {
            if statusCode == 401 { await ChatGPTAccountSessions.shared?.noteRejectedAccessToken() }
            // 诊断：只把状态码和服务端错误的类型/代码/字段名（标识符形态）写进本机系统日志，
            // 不写 message 与正文；界面仍只显示本地固定文案。
            logger.error("ChatGPT 账号请求被拒 " + ChatGPTAccountErrors.diagnosticSummary(statusCode: statusCode, body: body))
            if isCurrent(identity), let mapped = ChatGPTAccountErrors.llmError(statusCode: statusCode, body: body) {
                return mapped
            }
        }
        return mapHTTPError(
            statusCode: statusCode,
            headers: headers,
            body: String(decoding: body, as: UTF8.self),
            identity: identity
        )
    }

    // MARK: - LLMProvider

    public func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        try await sendMessage(
            messages: messages,
            systemPrompt: systemPrompt,
            tools: [],
            maxTokens: maxTokens,
            temperature: temperature
        )
    }

    public func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        // A cancelled caller must never start an attempt that can later
        // project a buffered response into ChatAgentEngine.
        guard !Task.isCancelled else { throw LLMError.cancelled }
        if usesChatGPTAccount {
            // ChatGPT plan usage only accepts streamed requests: collect the stream.
            var terminal: LLMResponse?
            let events = try await streamAssistantMessage(
                messages: messages, systemPrompt: systemPrompt, tools: tools,
                maxTokens: maxTokens, temperature: temperature, thinkingLevel: nil)
            for try await event in events {
                if case .completed(let response) = event { terminal = response }
            }
            guard let terminal else {
                throw LLMError.decodingError(underlying: ResponsesAPIError.prematureStreamEnd)
            }
            return terminal
        }
        let identity = try beginRequestIdentity(stream: false)
        let request = try await buildRequestOffMain(
            messages: messages,
            systemPrompt: systemPrompt,
            tools: tools,
            maxTokens: maxTokens,
            temperature: temperature,
            stream: false,
            identity: identity
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
            // URLSession implementations and test transports may deliver a
            // buffered success even after cancellation. Re-check before any
            // status/JSON projection so cancellation remains terminal.
            try Task.checkCancellation()
        } catch {
            throw mapError(error, identity: identity)
        }
        let httpResponse = response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode ?? -1

        guard (200..<300).contains(statusCode) else {
            throw mapHTTPError(
                statusCode: statusCode,
                headers: Self.stringHeaders(from: httpResponse),
                body: String(decoding: data, as: UTF8.self),
                identity: identity
            )
        }

        guard isCurrent(identity) else { throw LLMError.cancelled }
        guard data.count <= Self.maxNonStreamingResponseBytes,
              Self.isSafeJSONData(data),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Self.isBoundedJSON(json),
              Self.hasSafeResponseIdentity(in: json),
              Self.hasSafeNonStreamingOutput(in: json) else {
            throw LLMError.decodingError(underlying: ResponsesAPIError.emptyResponseOutput)
        }
        if let usage = json["usage"], !Self.isValidUsage(usage) {
            throw LLMError.decodingError(underlying: ResponsesAPIError.emptyResponseOutput)
        }
        if let rawStatus = json["status"] {
            guard let status = rawStatus as? String else {
                throw LLMError.decodingError(underlying: ResponsesAPIError.emptyResponseOutput)
            }
            switch status {
            case "completed", "incomplete":
                break
            case "failed", "cancelled":
                guard let error = json["error"] as? [String: Any],
                      let message = error["message"] as? String,
                      !message.isEmpty else {
                    throw LLMError.decodingError(underlying: ResponsesAPIError.emptyResponseOutput)
                }
            default:
                throw LLMError.decodingError(underlying: ResponsesAPIError.emptyResponseOutput)
            }
        }
        if let rawError = json["error"], !(rawError is NSNull) {
            guard let error = rawError as? [String: Any],
                  let message = error["message"] as? String,
                  !message.isEmpty else {
                throw LLMError.decodingError(underlying: ResponsesAPIError.emptyResponseOutput)
            }
        }
        guard let canonicalResponseBody = Self.canonicalJSONData(json),
              !canonicalResponseBody.isEmpty,
              canonicalResponseBody.count <= Self.maxDurableResponseBodyBytes else {
            throw LLMError.decodingError(underlying: ResponsesAPIError.emptyResponseOutput)
        }
        let extracted: (text: String, status: String?, toolCalls: [LLMToolCall])
        do {
            extracted = try ResponsesAPIResponseParser.extractResponse(from: json)
        } catch let error as ResponsesAPIError {
            if case .serverStreamError(_, _) = error {
                // Never project server-controlled response text as a local error.
                throw LLMError.providerError(message: "Responses API response error")
            }
            throw error
        }
        guard isCurrent(identity) else { throw LLMError.cancelled }
        let usage = (json["usage"] as? [String: Any]).flatMap { ResponsesAPIResponseParser.parseUsage($0) }
        let responseID = (json["id"] as? String).flatMap { Self.isSafeResponseIdentity($0) ? $0 : nil }
        if json["id"] != nil, responseID == nil {
            throw LLMError.decodingError(underlying: ResponsesAPIError.emptyResponseOutput)
        }
        guard persistAttemptReceipt(
            identity: identity,
            responseID: responseID,
            eventID: nil,
            retryMilliseconds: nil,
            responseBody: canonicalResponseBody,
            committed: true
        ) else {
            throw LLMError.providerError(message: "Invalid durable Responses receipt")
        }
        guard isCurrent(identity) else { throw LLMError.cancelled }
        return LLMResponse(text: extracted.text, stopReason: extracted.status, usage: usage, toolCalls: extracted.toolCalls)
    }

    public func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        // Keep streaming and non-streaming attempts on the same cancellation
        // contract before creating a request identity or opening transport.
        guard !Task.isCancelled else { throw LLMError.cancelled }
        let identity = try beginRequestIdentity(stream: true)
        let request = try await buildRequestOffMain(
            messages: messages,
            systemPrompt: systemPrompt,
            tools: [],
            maxTokens: maxTokens,
            temperature: temperature,
            stream: true,
            identity: identity
        )

        let byteStream: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (byteStream, response) = try await session.bytes(for: request)
            // Do not return a stream after the caller has already cancelled;
            // otherwise a buffered terminal event could still be consumed.
            try Task.checkCancellation()
        } catch {
            throw mapError(error, identity: identity)
        }
        let httpResponse = response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode ?? -1

        if !(200..<300).contains(statusCode) {
            throw await httpFailure(
                statusCode: statusCode,
                headers: Self.stringHeaders(from: httpResponse),
                bytes: byteStream,
                identity: identity
            )
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                var receivedTerminator = false
                var lastEventName: String? = nil
                var pendingEventID: String? = nil
                var pendingRetryMilliseconds: UInt64? = nil
                var reconnectState = SSEReconnectState(identity: identity)
                var eventData = ""
                var lineCount = 0
                var totalBytes = 0
                var eventCount = 0
                var eventDataBytes = 0
                var responseID: String?
                var seenResponseCreated = false
                var seenOutputItemIDs = Set<String>()
                var finishedOutputItemIDs = Set<String>()
                var atStreamStart = true

                // AsyncBytes.lines does not consistently surface empty SSE
                // delimiter lines across Foundation transports. Flush an
                // accumulated event at the next event line as well as at a
                // delimiter/EOF, preserving event boundaries without relying
                // on blank-line delivery.
                func processEvent(
                    eventName: String?,
                    eventID: String?,
                    retryMilliseconds: UInt64?,
                    payload: String
                ) throws -> Bool {
                    // Cancellation wins while the stream is still active.
                    // Once a terminal event is committed below, later
                    // cancellation must not append a second terminal error.
                    try Task.checkCancellation()
                    guard eventCount < Self.maxSSEEventCount else {
                        throw streamFailure(identity: identity, message: "too many SSE events")
                    }
                    eventCount += 1
                    if let eventID, !eventID.isEmpty, reconnectState.seenEventIDs.contains(eventID) {
                        throw streamFailure(identity: identity, message: "duplicate SSE event identity")
                    }
                    func commitTransaction(committed: Bool = false, responseBody: Data? = nil) throws {
                        var candidateState = reconnectState
                        guard candidateState.commit(
                            for: identity,
                            eventID: eventID,
                            retryMilliseconds: retryMilliseconds
                        ) else {
                            throw streamFailure(identity: identity, message: "stale SSE reconnect transaction")
                        }
                        guard persistAttemptReceipt(
                            identity: identity,
                            responseID: responseID,
                            eventID: eventID,
                            retryMilliseconds: retryMilliseconds,
                            responseBody: responseBody,
                            committed: committed
                        ) else {
                            throw streamFailure(identity: identity, message: "invalid durable SSE receipt")
                        }
                        reconnectState = candidateState
                    }
                    if payload == "[DONE]" { return false }
                    guard let payloadData = payload.data(using: .utf8),
                          Self.isSafeJSONData(payloadData),
                          let json = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any],
                          Self.isBoundedJSON(json) else {
                        throw streamFailure(identity: identity, message: "invalid SSE JSON")
                    }
                    guard let canonicalPayload = Self.canonicalJSONData(json),
                          !canonicalPayload.isEmpty,
                          canonicalPayload.count <= Self.maxDurableResponseBodyBytes else {
                        throw streamFailure(identity: identity, message: "oversized SSE response body")
                    }
                    if let eventName {
                        guard json["type"] as? String == eventName else {
                            throw streamFailure(identity: identity, message: "SSE event type mismatch")
                        }
                    }
                    if let eventName,
                       ["response.completed", "response.failed", "response.incomplete"].contains(eventName) {
                        guard json["type"] as? String == eventName,
                              let response = json["response"] as? [String: Any],
                              let responseID = response["id"] as? String,
                              Self.isSafeResponseIdentity(responseID),
                              response["status"] as? String == eventName.replacingOccurrences(of: "response.", with: "") else {
                            throw streamFailure(identity: identity, message: "invalid terminal response metadata")
                        }
                        if eventName == "response.incomplete" {
                            guard let details = response["incomplete_details"] as? [String: Any],
                                  let reason = details["reason"] as? String,
                                  !reason.isEmpty,
                                  reason.utf8.count <= Self.maxSSEEventNameBytes,
                                  Self.isASCII(reason),
                                  !Self.containsSSEControlCharacter(reason) else {
                                throw streamFailure(identity: identity, message: "invalid incomplete response metadata")
                            }
                        }
                        if eventName == "response.failed" {
                            guard let error = response["error"] as? [String: Any],
                                  let message = error["message"] as? String,
                                  !message.isEmpty else {
                                throw streamFailure(identity: identity, message: "invalid failed response metadata")
                            }
                        }
                    }
                    let nestedResponseID = (json["response"] as? [String: Any])?["id"] as? String
                    if let nestedResponseID, !Self.isSafeResponseIdentity(nestedResponseID) {
                        throw streamFailure(identity: identity, message: "invalid response identity")
                    }
                    let topLevelResponseID: String?
                    if json["response_id"] != nil {
                        guard let value = json["response_id"] as? String,
                              Self.isSafeResponseIdentity(value) else {
                            throw streamFailure(identity: identity, message: "invalid response identity")
                        }
                        topLevelResponseID = value
                    } else {
                        topLevelResponseID = nil
                    }
                    if let nestedResponseID, let topLevelResponseID, nestedResponseID != topLevelResponseID {
                        throw streamFailure(identity: identity, message: "conflicting response identity")
                    }
                    if eventName == "response.output_text.delta" {
                        guard json["delta"] is String else {
                            throw streamFailure(identity: identity, message: "invalid text delta")
                        }
                    }
                    if eventName == "response.output_text.done" {
                        guard json["text"] is String else {
                            throw streamFailure(identity: identity, message: "invalid completed text")
                        }
                        if let itemID = json["item_id"] {
                            guard let itemID = itemID as? String,
                                  Self.isSafeResponseIdentity(itemID) else {
                                throw streamFailure(identity: identity, message: "invalid output item identity")
                            }
                        }
                    }
                    if ["response.content_part.added", "response.content_part.done"].contains(eventName) {
                        guard let part = json["part"] as? [String: Any],
                              let partType = part["type"] as? String,
                              !partType.isEmpty else {
                            throw streamFailure(identity: identity, message: "invalid content part")
                        }
                        if partType == "output_text" {
                            guard part["text"] is String else {
                                throw streamFailure(identity: identity, message: "invalid content part text")
                            }
                        }
                        if let itemID = json["item_id"] {
                            guard let itemID = itemID as? String,
                                  Self.isSafeResponseIdentity(itemID) else {
                                throw streamFailure(identity: identity, message: "invalid output item identity")
                            }
                        }
                    }
                    if let observedID = nestedResponseID ?? topLevelResponseID {
                        let mayEstablishIdentity = eventName == "response.created"
                            || ["response.completed", "response.failed", "response.incomplete"].contains(eventName)
                        guard seenResponseCreated || mayEstablishIdentity else {
                            throw streamFailure(identity: identity, message: "response identity before creation")
                        }
                        if let responseID, responseID != observedID {
                            throw streamFailure(identity: identity, message: "conflicting response identity")
                        }
                        responseID = responseID ?? observedID
                    }
                    if eventName == "response.created" {
                        guard !seenResponseCreated else {
                            throw streamFailure(identity: identity, message: "duplicate response.created")
                        }
                        seenResponseCreated = true
                    }
                    switch eventName {
                    case "response.output_item.added", "response.output_item.done":
                        guard let item = json["item"] as? [String: Any] else {
                            throw streamFailure(identity: identity, message: "invalid output item")
                        }
                        if item["id"] != nil {
                            guard let observedID = item["id"] as? String,
                                  Self.isSafeResponseIdentity(observedID) else {
                                throw streamFailure(identity: identity, message: "invalid output item identity")
                            }
                            if eventName == "response.output_item.added" {
                                guard seenOutputItemIDs.insert(observedID).inserted else {
                                    throw streamFailure(identity: identity, message: "invalid output item identity")
                                }
                            } else {
                                guard seenOutputItemIDs.contains(observedID),
                                      finishedOutputItemIDs.insert(observedID).inserted else {
                                    throw streamFailure(identity: identity, message: "invalid output item identity")
                                }
                            }
                        } else if eventName == "response.output_item.done" {
                            // A done event must close an item established by
                            // an earlier added event. Without this fence, a
                            // reordered done could be accepted and a later
                            // added event could silently resurrect that item.
                            throw streamFailure(identity: identity, message: "invalid output item identity")
                        }
                        if item["call_id"] != nil {
                            guard let callID = item["call_id"] as? String,
                                  Self.isSafeResponseIdentity(callID) else {
                                throw streamFailure(identity: identity, message: "invalid output item identity")
                            }
                        }
                    default:
                        break
                    }
                    if eventName == "response.output_text.delta", json["item_id"] != nil {
                        guard let itemID = json["item_id"] as? String,
                              Self.isSafeResponseIdentity(itemID) else {
                            throw streamFailure(identity: identity, message: "invalid output item identity")
                        }
                    }
                    if ["response.completed", "response.incomplete"].contains(eventName),
                       let response = json["response"] as? [String: Any],
                       let usage = response["usage"],
                       !Self.isValidUsage(usage) {
                        throw streamFailure(identity: identity, message: "invalid response usage")
                    }
                    switch ResponsesAPIResponseParser.interpret(eventName: eventName, dataJSON: json) {
                    case .textDelta(let delta):
                        guard isCurrent(identity) else { throw LLMError.cancelled }
                        try Task.checkCancellation()
                        try commitTransaction(responseBody: canonicalPayload)
                        try Task.checkCancellation()
                        guard isCurrent(identity) else { throw LLMError.cancelled }
                        try ProviderStreamCancellationPolicy.yield(.text(delta), to: continuation)
                    case .completed(let usage):
                        guard isCurrent(identity) else { throw LLMError.cancelled }
                        try Task.checkCancellation()
                        receivedTerminator = true
                        try commitTransaction(committed: true, responseBody: canonicalPayload)
                        if let usage {
                            try ProviderStreamCancellationPolicy.yield(.usage(usage), to: continuation)
                        }
                        try ProviderStreamCancellationPolicy.yield(.finished(stopReason: "completed"), to: continuation)
                        return true
                    case .failed(let message):
                        receivedTerminator = true
                        let failedCode = ((json["response"] as? [String: Any])?["error"] as? [String: Any])?["code"] as? String
                        throw streamFailure(identity: identity, code: failedCode, message: message, serverReported: true)
                    case .incomplete(let reason):
                        guard isCurrent(identity) else { throw LLMError.cancelled }
                        try Task.checkCancellation()
                        receivedTerminator = true
                        try commitTransaction(committed: true, responseBody: canonicalPayload)
                        try ProviderStreamCancellationPolicy.yield(
                            .finished(stopReason: reason.map { "incomplete(\($0))" } ?? "incomplete"),
                            to: continuation
                        )
                        return true
                    case .error(let code, let message):
                        receivedTerminator = true
                        throw streamFailure(identity: identity, code: code, message: message, serverReported: true)
                    case .ignored:
                        try commitTransaction(responseBody: canonicalPayload)
                    }
                    return false
                }

                func discardTransaction() {
                    eventData.removeAll(keepingCapacity: false)
                    eventDataBytes = 0
                    lastEventName = nil
                    pendingEventID = nil
                    pendingRetryMilliseconds = nil
                    reconnectState.reset()
                }

                do {
                    try Task.checkCancellation()
                    try ProviderStreamCancellationPolicy.yield(.started, to: continuation)
                    // Decode and process only complete UTF-8 lines. This avoids
                    // AsyncBytes.lines buffering an unbounded no-newline line
                    // before the line ceiling can be enforced.
                    func processLine(_ line: String) throws -> Bool {
                        let retainsCarriageReturn = line.last == "\r"
                        guard !line.unicodeScalars.contains(where: { $0.value == 0xFFFD }),
                              !Self.containsSSEControlCharacter(
                                  retainsCarriageReturn ? String(line.dropLast()) : line
                              ) else {
                            throw streamFailure(identity: identity, message: "invalid or oversized SSE line")
                        }
                        guard isCurrent(identity) else { throw LLMError.cancelled }
                        var normalizedLine = retainsCarriageReturn ? String(line.dropLast()) : line
                        if atStreamStart {
                            atStreamStart = false
                            if normalizedLine.first == "\u{FEFF}" {
                                normalizedLine.removeFirst()
                            }
                        }
                        if normalizedLine.isEmpty {
                            guard !eventData.isEmpty else {
                                eventDataBytes = 0
                                lastEventName = nil
                                pendingEventID = nil
                                pendingRetryMilliseconds = nil
                                return false
                            }
                            let payload = eventData
                            let eventName = lastEventName
                            let eventID = pendingEventID
                            let retryMilliseconds = pendingRetryMilliseconds
                            eventData = ""
                            eventDataBytes = 0
                            lastEventName = nil
                            pendingEventID = nil
                            pendingRetryMilliseconds = nil
                            return try processEvent(
                                eventName: eventName,
                                eventID: eventID,
                                retryMilliseconds: retryMilliseconds,
                                payload: payload
                            )
                        }
                        if normalizedLine.first == ":" {
                            return false
                        }
                        let fieldName: String
                        let fieldValue: String
                        if let separator = normalizedLine.firstIndex(of: ":") {
                            fieldName = String(normalizedLine[..<separator])
                            let rawValue = String(normalizedLine[normalizedLine.index(after: separator)...])
                            fieldValue = rawValue.first == " " ? String(rawValue.dropFirst()) : rawValue
                        } else {
                            fieldName = normalizedLine
                            fieldValue = ""
                        }
                        guard !fieldName.isEmpty,
                              fieldName.utf8.count <= Self.maxSSEFieldNameBytes,
                              Self.isASCII(fieldName) else {
                            throw streamFailure(identity: identity, message: "invalid SSE field name")
                        }
                        switch fieldName {
                        case "event":
                            guard fieldValue.utf8.count <= Self.maxSSEEventNameBytes,
                                  Self.isASCII(fieldValue) else {
                                throw streamFailure(identity: identity, message: "invalid SSE event field")
                            }
                            lastEventName = fieldValue
                            return false
                        case "retry":
                            guard fieldValue.utf8.count <= Self.maxSSERetryBytes,
                                  Self.isASCII(fieldValue) else {
                                throw streamFailure(identity: identity, message: "invalid or oversized SSE retry field")
                            }
                            guard fieldValue.isEmpty ||
                                  (fieldValue.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) &&
                                   UInt64(fieldValue) != nil) else {
                                throw streamFailure(identity: identity, message: "invalid or overflowing SSE retry field")
                            }
                            if !fieldValue.isEmpty {
                                pendingRetryMilliseconds = UInt64(fieldValue)
                            }
                            return false
                        case "id":
                            guard !fieldValue.isEmpty,
                                  fieldValue.utf8.count <= Self.maxSSEEventIDBytes,
                                  Self.isASCII(fieldValue) else {
                                throw streamFailure(identity: identity, message: "invalid or oversized SSE event identity")
                            }
                            pendingEventID = fieldValue
                            return false
                        case "data":
                            let payloadBytes = fieldValue.utf8.count
                            let separatorBytes = eventData.isEmpty ? 0 : 1
                            guard payloadBytes <= Self.maxSSEEventDataBytes - eventDataBytes - separatorBytes else {
                                discardTransaction()
                                throw streamFailure(identity: identity, message: "oversized SSE event data")
                            }
                            eventDataBytes += separatorBytes + payloadBytes
                            eventData += (eventData.isEmpty ? "" : "\n") + fieldValue
                            return false
                        default:
                            guard fieldValue.utf8.count <= Self.maxSSEFieldValueBytes,
                                  Self.isASCII(fieldValue) else {
                                throw streamFailure(identity: identity, message: "invalid or oversized SSE field")
                            }
                            return false
                        }
                    }

                    var lineBuffer = Data()
                    var stoppedAfterTerminal = false
                    var skipLFAfterCarriageReturn = false
                    for try await byte in byteStream {
                        try Task.checkCancellation()
                        guard totalBytes < Self.maxSSETotalBytes else {
                            lineBuffer.removeAll(keepingCapacity: false)
                            discardTransaction()
                            throw streamFailure(identity: identity, message: "oversized SSE stream")
                        }
                        totalBytes += 1
                        if skipLFAfterCarriageReturn {
                            skipLFAfterCarriageReturn = false
                            if byte == 0x0A { continue }
                        }
                        if byte == 0x0A || byte == 0x0D {
                            if byte == 0x0D {
                                skipLFAfterCarriageReturn = true
                            }
                            guard lineCount < Self.maxSSELineCount else {
                                lineBuffer.removeAll(keepingCapacity: false)
                                discardTransaction()
                                throw streamFailure(identity: identity, message: "too many SSE lines")
                            }
                            lineCount += 1
                            guard let line = String(data: lineBuffer, encoding: .utf8) else {
                                lineBuffer.removeAll(keepingCapacity: false)
                                discardTransaction()
                                throw streamFailure(identity: identity, message: "invalid UTF-8 SSE line")
                            }
                            lineBuffer.removeAll(keepingCapacity: false)
                            if try processLine(line) {
                                stoppedAfterTerminal = true
                                break
                            }
                        } else {
                            guard lineBuffer.count < Self.maxSSELineBytes else {
                                lineBuffer.removeAll(keepingCapacity: false)
                                discardTransaction()
                                throw streamFailure(identity: identity, message: "oversized SSE line")
                            }
                            lineBuffer.append(byte)
                        }
                    }
                    if !stoppedAfterTerminal, !lineBuffer.isEmpty {
                        lineBuffer.removeAll(keepingCapacity: false)
                        discardTransaction()
                        throw streamFailure(identity: identity, message: "truncated SSE line at EOF")
                    }
                    if !stoppedAfterTerminal, !eventData.isEmpty {
                        discardTransaction()
                        throw streamFailure(identity: identity, message: "truncated SSE event at EOF")
                    }
                    // 中途 EOF：未收到 completed/failed/incomplete 终止事件 → 明确报错，
                    // 不静默成功（与 Chat Completions 的 [DONE] 哨兵语义不同）。
                    guard receivedTerminator else {
                        continuation.finish(throwing: ResponsesAPIError.prematureStreamEnd)
                        return
                    }
                    // A terminal event is already the committed outcome. A
                    // cancellation arriving after that event must not turn a
                    // successful terminal chunk into a second error terminal.
                    if !receivedTerminator {
                        guard isCurrent(identity) else {
                            continuation.finish(throwing: LLMError.cancelled)
                            return
                        }
                    }
                    continuation.finish()
                } catch {
                    discardTransaction()
                    continuation.finish(throwing: mapError(error, identity: identity))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func isBoundedJSON(
        _ value: Any,
        depth: Int = 0,
        keyCount: inout Int
    ) -> Bool {
        guard depth <= maxJSONDepth else { return false }
        if let object = value as? [String: Any] {
            guard keyCount <= maxJSONKeyCount - object.count else { return false }
            keyCount += object.count
            for child in object.values {
                guard isBoundedJSON(child, depth: depth + 1, keyCount: &keyCount) else { return false }
            }
        } else if let array = value as? [Any] {
            for child in array {
                guard isBoundedJSON(child, depth: depth + 1, keyCount: &keyCount) else { return false }
            }
        } else if let string = value as? String {
            guard string.utf8.count <= maxJSONStringBytes else { return false }
        }
        return true
    }

    private static func containsSSEControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
        }
    }

    private static func isASCII(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { $0.value < 0x80 }
    }

    /// Response IDs are provider-controlled identity keys. Keep them bounded
    /// and printable so escaped controls, homoglyphs, and delimiter-shaped
    /// values cannot alias a durable receipt or reconnect transaction.
    private static func isSafeResponseIdentity(_ value: String) -> Bool {
        let normalized = value.precomposedStringWithCanonicalMapping
        let scalars = normalized.unicodeScalars
        guard !normalized.isEmpty,
              normalized.utf8.count <= maxSSEResponseIdentityBytes,
              scalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else { return false }
        return normalized == value
    }

    private static func isBoundedJSON(_ object: [String: Any]) -> Bool {
        var keyCount = 0
        return isBoundedJSON(object, depth: 0, keyCount: &keyCount)
    }

    private static func isValidUsage(_ value: Any) -> Bool {
        guard let usage = value as? [String: Any], !usage.isEmpty else { return false }
        var foundTokenCount = false
        for key in ["input_tokens", "output_tokens"] {
            if let rawValue = usage[key] {
                guard let tokenCount = rawValue as? Int, tokenCount >= 0 else { return false }
                foundTokenCount = true
            }
        }
        guard foundTokenCount else { return false }
        if let rawDetails = usage["input_tokens_details"] {
            guard let details = rawDetails as? [String: Any] else { return false }
            if let rawCached = details["cached_tokens"] {
                guard let cachedTokens = rawCached as? Int, cachedTokens >= 0 else { return false }
            }
        }
        return true
    }

    private static func isSafeJSONData(_ data: Data) -> Bool {
        var scanner = JSONSafetyScanner(bytes: Array(data))
        return scanner.validate()
    }

    /// Reject ambiguous output identities before the parser projects them into
    /// text/tool calls. A duplicate id or call_id would otherwise make a
    /// non-streaming response indistinguishable from a replayed item.
    private static func hasSafeResponseIdentity(in json: [String: Any]) -> Bool {
        var itemIDs = Set<String>()
        var callIDs = Set<String>()
        guard let output = json["output"] as? [[String: Any]] else { return true }
        for item in output {
            if item["id"] != nil {
                guard let itemID = item["id"] as? String,
                      isSafeResponseIdentity(itemID),
                      itemIDs.insert(itemID).inserted else { return false }
            }
            if item["call_id"] != nil {
                guard let callID = item["call_id"] as? String,
                      isSafeResponseIdentity(callID),
                      callIDs.insert(callID).inserted else { return false }
            }
            if let rawArguments = item["arguments"] as? String,
               !Self.isSafeJSONData(Data(rawArguments.utf8)) {
                return false
            }
        }
        return true
    }

    /// Do not let a malformed message part disappear silently while another
    /// part in the same response is projected as a successful answer.
    private static func hasSafeNonStreamingOutput(in json: [String: Any]) -> Bool {
        guard let rawOutput = json["output"] else { return true }
        guard let output = rawOutput as? [[String: Any]] else { return false }
        for item in output {
            guard let type = item["type"] as? String, !type.isEmpty else { return false }
            if type == "function_call" {
                let argumentsData = (item["arguments"] as? String).flatMap { Data($0.utf8) }
                guard let name = item["name"] as? String, !name.isEmpty,
                      item["call_id"] != nil || item["id"] != nil,
                      let argumentsData,
                      Self.isSafeJSONData(argumentsData),
                      let arguments = try? JSONSerialization.jsonObject(with: argumentsData),
                      arguments is [String: Any] else { return false }
                continue
            }
            if type == "message" {
                guard let rawContent = item["content"],
                      let content = rawContent as? [[String: Any]] else { return false }
                for part in content {
                    guard let partType = part["type"] as? String, !partType.isEmpty else { return false }
                    if partType == "output_text", !(part["text"] is String) {
                        return false
                    }
                }
            }
        }
        return true
    }

    /// Minimal lexical preflight that preserves duplicate object keys, which
    /// JSONSerialization otherwise collapses with last-key-wins semantics.
    private struct JSONSafetyScanner {
        let bytes: [UInt8]
        var index = 0
        var keyCount = 0

        mutating func validate() -> Bool {
            guard parseValue(depth: 0) else { return false }
            skipWhitespace()
            return index == bytes.count
        }

        mutating private func parseValue(depth: Int) -> Bool {
            guard depth <= OpenAIResponsesProvider.maxJSONDepth else { return false }
            skipWhitespace()
            guard let byte = bytes[safe: index] else { return false }
            switch byte {
            case 0x7B: return parseObject(depth: depth)
            case 0x5B: return parseArray(depth: depth)
            case 0x22: return parseString() != nil
            case 0x2D, 0x30...0x39: return parseNumber()
            case 0x74: return parseLiteral("true")
            case 0x66: return parseLiteral("false")
            case 0x6E: return parseLiteral("null")
            default: return false
            }
        }

        mutating private func parseObject(depth: Int) -> Bool {
            index += 1
            skipWhitespace()
            if bytes[safe: index] == 0x7D {
                index += 1
                return true
            }
            var keys = Set<String>()
            while true {
                guard let key = parseString(canonicalizeEscapes: true), keys.insert(key).inserted else { return false }
                guard keyCount < OpenAIResponsesProvider.maxJSONKeyCount else { return false }
                keyCount += 1
                skipWhitespace()
                guard bytes[safe: index] == 0x3A else { return false }
                index += 1
                guard parseValue(depth: depth + 1) else { return false }
                skipWhitespace()
                if bytes[safe: index] == 0x7D {
                    index += 1
                    return true
                }
                guard bytes[safe: index] == 0x2C else { return false }
                index += 1
                skipWhitespace()
            }
        }

        mutating private func parseArray(depth: Int) -> Bool {
            index += 1
            skipWhitespace()
            if bytes[safe: index] == 0x5D {
                index += 1
                return true
            }
            while true {
                guard parseValue(depth: depth + 1) else { return false }
                skipWhitespace()
                if bytes[safe: index] == 0x5D {
                    index += 1
                    return true
                }
                guard bytes[safe: index] == 0x2C else { return false }
                index += 1
                skipWhitespace()
            }
        }

        mutating private func parseString(canonicalizeEscapes: Bool = false) -> String? {
            guard bytes[safe: index] == 0x22 else { return nil }
            let tokenStart = index
            index += 1
            let start = index
            while let byte = bytes[safe: index] {
                switch byte {
                case 0x22:
                    guard index - start <= OpenAIResponsesProvider.maxJSONStringBytes else { return nil }
                    let tokenEnd = index
                    let value = String(decoding: bytes[start..<index], as: UTF8.self)
                    index += 1
                    if canonicalizeEscapes {
                        let token = Data(bytes[tokenStart...tokenEnd])
                        return (try? JSONSerialization.jsonObject(with: token, options: [.fragmentsAllowed])) as? String
                    }
                    return value
                case 0x5C:
                    index += 1
                    guard let escaped = bytes[safe: index] else { return nil }
                    if escaped == 0x75 {
                        guard index + 4 < bytes.count else { return nil }
                        index += 5
                    } else {
                        index += 1
                    }
                case 0x00...0x1F:
                    return nil
                default:
                    index += 1
                }
                guard index - start <= OpenAIResponsesProvider.maxJSONStringBytes else { return nil }
            }
            return nil
        }

        mutating private func parseNumber() -> Bool {
            if bytes[safe: index] == 0x2D { index += 1 }
            guard bytes[safe: index] != nil else { return false }
            while let byte = bytes[safe: index], byte >= 0x30, byte <= 0x39 { index += 1 }
            if bytes[safe: index] == 0x2E {
                index += 1
                guard let firstFraction = bytes[safe: index], firstFraction >= 0x30, firstFraction <= 0x39 else {
                    return false
                }
                while let byte = bytes[safe: index], byte >= 0x30, byte <= 0x39 { index += 1 }
            }
            if bytes[safe: index] == 0x65 || bytes[safe: index] == 0x45 {
                index += 1
                if bytes[safe: index] == 0x2B || bytes[safe: index] == 0x2D { index += 1 }
                guard let firstExponent = bytes[safe: index], firstExponent >= 0x30, firstExponent <= 0x39 else {
                    return false
                }
                while let byte = bytes[safe: index], byte >= 0x30, byte <= 0x39 { index += 1 }
            }
            return true
        }

        mutating private func parseLiteral(_ literal: String) -> Bool {
            let literalBytes = Array(literal.utf8)
            guard index + literalBytes.count <= bytes.count,
                  Array(bytes[index..<(index + literalBytes.count)]) == literalBytes else { return false }
            index += literalBytes.count
            return true
        }

        mutating private func skipWhitespace() {
            while let byte = bytes[safe: index], byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                index += 1
            }
        }
    }

    // MARK: - Error Handling

    public func mapError(_ error: Error) -> LLMError {
        mapError(error, identity: currentRequestIdentity())
    }

    private func mapError(_ error: Error, identity: RequestIdentity) -> LLMError {
        guard isCurrent(identity) else { return .cancelled }
        if error is CancellationError { return .cancelled }
        if error is ResponsesAPIError {
            // The parser may carry server-controlled text. Keep only a typed,
            // payload-free category at the provider boundary.
            return .providerError(message: "Responses API stream error")
        }
        if error is URLError || (error as NSError).domain == NSURLErrorDomain {
            return ProviderHTTPErrorAdapter.classify(transport: error).llmError
        }
        if let llmError = error as? LLMError { return llmError }
        return .providerError(message: "Provider transport error")
    }

    /// E20 统一 HTTP 错误映射（与 OpenAICompatibleProvider 一致）：
    /// 按状态码抛 typed `LLMError.httpStatus(code:detail:)`；服务方 body
    /// 只作为兼容性入参，永不进入任何错误表面。
    public func mapHTTPError(statusCode: Int, body: String) -> LLMError {
        mapHTTPError(statusCode: statusCode, headers: [:], body: body)
    }

    public func mapHTTPError(
        statusCode: Int,
        headers: [String: String],
        body: String
    ) -> LLMError {
        mapHTTPError(
            statusCode: statusCode,
            headers: headers,
            body: body,
            identity: currentRequestIdentity()
        )
    }

    private func mapHTTPError(
        statusCode: Int,
        headers: [String: String],
        body: String,
        identity: RequestIdentity
    ) -> LLMError {
        guard isCurrent(identity) else { return .cancelled }
        if ProviderContextOverflowClassifier.isOpenAIStyleOverflow(statusCode: statusCode, body: body) { return .contextLengthExceeded }
        if ProviderHTTPErrorAdapter.indicatesQuotaExhausted(statusCode: statusCode, body: body) {
            return .httpStatus(code: statusCode, detail: ProviderHTTPErrorAdapter.quotaDetail(statusCode: statusCode, headers: headers))
        }
        return ProviderHTTPErrorAdapter.classify(statusCode: statusCode, headers: headers).llmError
    }

    private static func stringHeaders(from response: HTTPURLResponse?) -> [String: String] {
        guard let response else { return [:] }
        return response.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            guard let key = entry.key as? String, let value = entry.value as? String else { return }
            result[key] = value
        }
    }

    static func attemptCheckpointKey(providerID: String, modelID: String) -> String {
        let identity = Data((providerID + "\u{001F}" + modelID).utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "MinisCore.OpenAIResponsesProvider.attempt.v1." + identity
    }

    static func attemptCheckpointURL(providerID: String, modelID: String,
                                     directoryOverride: URL? = nil) -> URL? {
        guard let providerID = canonicalIdentityField(providerID),
              let modelID = canonicalIdentityField(modelID) else { return nil }
        let directory: URL
        if let directoryOverride {
            directory = directoryOverride
        } else if let attemptCheckpointDirectoryOverride {
            directory = attemptCheckpointDirectoryOverride
        } else if let formal = FormalTestIsolationPaths.currentOrFail() {
            directory = formal.minisCoreDirectory.appendingPathComponent(
                "responses-attempts", isDirectory: true
            )
        } else {
            directory = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory)
                .appendingPathComponent("MinisCore", isDirectory: true)
                .appendingPathComponent("responses-attempts", isDirectory: true)
        }
        return directory.appendingPathComponent(attemptCheckpointKey(
            providerID: providerID,
            modelID: modelID
        ) + ".json", isDirectory: false)
    }

    private static func canonicalJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func requestDigest(
        providerID: String,
        modelID: String,
        generation: UInt64,
        attemptGeneration: UInt64,
        requestID: UUID
    ) -> String {
        struct DigestPayload: Codable {
            let providerID: String
            let modelID: String
            let generation: UInt64
            let attemptGeneration: UInt64
            let requestID: UUID
        }
        let payload = DigestPayload(
            providerID: providerID,
            modelID: modelID,
            generation: generation,
            attemptGeneration: attemptGeneration,
            requestID: requestID
        )
        guard let data = try? canonicalJSONEncoder().encode(payload) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func requestScopeDigest(
        providerID: String,
        modelID: String,
        generation: UInt64,
        attemptGeneration: UInt64,
        requestID: UUID,
        responseSchemaFingerprint: String
    ) -> String {
        struct ScopePayload: Codable {
            let providerID: String
            let modelID: String
            let generation: UInt64
            let attemptGeneration: UInt64
            let requestID: UUID
            let responseSchemaFingerprint: String
        }
        let payload = ScopePayload(
            providerID: providerID,
            modelID: modelID,
            generation: generation,
            attemptGeneration: attemptGeneration,
            requestID: requestID,
            responseSchemaFingerprint: responseSchemaFingerprint
        )
        guard let data = try? canonicalJSONEncoder().encode(payload) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isKnownResponseSchema(_ fingerprint: String) -> Bool {
        fingerprint == nonStreamingResponseSchemaFingerprint
            || fingerprint == streamingResponseSchemaFingerprint
    }

    private static func canonicalJSONData(_ object: Any) -> Data? {
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func sha256Digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func appendResponseBodyDigest(previous: String?, body: Data) -> String {
        struct BodyPayload: Codable {
            let previousDigest: String?
            let bodyDigest: String
            let bodyBytes: UInt64
        }
        let payload = BodyPayload(
            previousDigest: previous,
            bodyDigest: sha256Digest(body),
            bodyBytes: UInt64(body.count)
        )
        guard let data = try? canonicalJSONEncoder().encode(payload) else { return "" }
        return sha256Digest(data)
    }

    private static func receiptHistoryDigest(_ history: [DurableReceiptHistoryEntry]) -> String {
        guard let data = try? canonicalJSONEncoder().encode(history) else { return "" }
        return sha256Digest(data)
    }

    private static func segmentManifestRoot(_ manifest: [DurableReceiptHistoryEntry]) -> String {
        guard let data = try? canonicalJSONEncoder().encode(manifest) else { return "" }
        return sha256Digest(data)
    }

    private static func cleanupTombstoneSeal(
        _ tombstone: DurableCleanupTombstone,
        compactionTransactionID: UUID,
        previousSeal: String?
    ) -> String {
        struct TombstonePayload: Codable {
            let tombstone: DurableCleanupTombstone
            let compactionTransactionID: UUID
            let previousSeal: String?
        }
        let payload = TombstonePayload(
            tombstone: tombstone,
            compactionTransactionID: compactionTransactionID,
            previousSeal: previousSeal
        )
        guard let data = try? canonicalJSONEncoder().encode(payload) else { return "" }
        return sha256Digest(data)
    }

    private static func segmentManifestReadbackSeal(_ record: DurableAttemptRecord) -> String {
        struct ReadbackPayload: Codable {
            let generation: UInt64
            let segmentManifestRoot: String?
            let checkpointDigest: String?
            let fileDevice: UInt64
            let fileInode: UInt64
        }
        let payload = ReadbackPayload(
            generation: record.generation,
            segmentManifestRoot: record.segmentManifestRoot,
            checkpointDigest: record.checkpointDigest,
            fileDevice: record.fileDevice,
            fileInode: record.fileInode
        )
        guard let data = try? canonicalJSONEncoder().encode(payload) else { return "" }
        return sha256Digest(data)
    }

    private static func receiptCheckpointDigest(_ record: DurableAttemptRecord) -> String {
        struct CheckpointPayload: Codable {
            let generation: UInt64
            let previousGeneration: UInt64?
            let previousDigest: String?
            let previousTransactionID: UUID?
            let previousPayloadDigest: String?
            let epochPredecessorDigest: String?
            let historyPredecessorDigest: String?
            let historyDigest: String?
            let compactionTransactionID: UUID?
            let segmentManifestRoot: String?
            let segmentManifestPredecessorRoot: String?
            let segmentGenerationCAS: [UInt64]
            let cleanupTombstone: DurableCleanupTombstone?
            let cleanupTombstoneSeal: String?
            let cleanupEpochPredecessorSeal: String?
            let payloadDigest: String?
        }
        let payload = CheckpointPayload(
            generation: record.generation,
            previousGeneration: record.previousGeneration,
            previousDigest: record.previousDigest,
            previousTransactionID: record.previousTransactionID,
            previousPayloadDigest: record.previousPayloadDigest,
            epochPredecessorDigest: record.epochPredecessorDigest,
            historyPredecessorDigest: record.historyPredecessorDigest,
            historyDigest: record.historyDigest,
            compactionTransactionID: record.compactionTransactionID,
            segmentManifestRoot: record.segmentManifestRoot,
            segmentManifestPredecessorRoot: record.segmentManifestPredecessorRoot,
            segmentGenerationCAS: record.segmentGenerationCAS,
            cleanupTombstone: record.cleanupTombstone,
            cleanupTombstoneSeal: record.cleanupTombstoneSeal,
            cleanupEpochPredecessorSeal: record.cleanupEpochPredecessorSeal,
            payloadDigest: record.payloadDigest
        )
        guard let data = try? canonicalJSONEncoder().encode(payload) else { return "" }
        return sha256Digest(data)
    }

    private static func receiptPayloadDigest(_ record: DurableAttemptRecord) -> String {
        struct ReceiptPayload: Codable {
            let providerID: String
            let modelID: String
            let generation: UInt64
            let previousGeneration: UInt64?
            let previousDigest: String?
            let previousTransactionID: UUID?
            let previousPayloadDigest: String?
            let epochPredecessorDigest: String?
            let historyPredecessorDigest: String?
            let segmentManifestPredecessorRoot: String?
            let cleanupEpochPredecessorSeal: String?
            let modelGeneration: UInt64
            let requestID: UUID?
            let requestDigest: String?
            let transactionID: UUID?
            let requestScopeDigest: String?
            let responseSchemaFingerprint: String?
            let receiptHistory: [DurableReceiptHistoryEntry]
            let historyDigest: String?
            let compactionTransactionID: UUID?
            let responseBodyDigest: String?
            let responseBodyBytes: UInt64?
            let phase: String
            let responseID: String?
            let lastEventID: String?
            let retryMilliseconds: UInt64?
        }
        let payload = ReceiptPayload(
            providerID: record.providerID,
            modelID: record.modelID,
            generation: record.generation,
            previousGeneration: record.previousGeneration,
            previousDigest: record.previousDigest,
            previousTransactionID: record.previousTransactionID,
            previousPayloadDigest: record.previousPayloadDigest,
            epochPredecessorDigest: record.epochPredecessorDigest,
            historyPredecessorDigest: record.historyPredecessorDigest,
            segmentManifestPredecessorRoot: record.segmentManifestPredecessorRoot,
            cleanupEpochPredecessorSeal: record.cleanupEpochPredecessorSeal,
            modelGeneration: record.modelGeneration,
            requestID: record.requestID,
            requestDigest: record.requestDigest,
            transactionID: record.transactionID,
            requestScopeDigest: record.requestScopeDigest,
            responseSchemaFingerprint: record.responseSchemaFingerprint,
            receiptHistory: record.receiptHistory,
            historyDigest: record.historyDigest,
            compactionTransactionID: record.compactionTransactionID,
            responseBodyDigest: record.responseBodyDigest,
            responseBodyBytes: record.responseBodyBytes,
            phase: record.phase,
            responseID: record.responseID,
            lastEventID: record.lastEventID,
            retryMilliseconds: record.retryMilliseconds
        )
        guard let data = try? canonicalJSONEncoder().encode(payload) else { return "" }
        return sha256Digest(data)
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy {
                (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
            }
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFLNK
    }

    private static func fileIdentity(_ url: URL) -> FileIdentity? {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_dev > 0, info.st_ino > 0 else { return nil }
        return FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }

    private static func readDurableAttemptBytes(
        from url: URL
    ) -> (data: Data, identity: FileIdentity)? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0,
              UInt64(info.st_size) <= UInt64(maxDurableAttemptRecordBytes) else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = handle.readDataToEndOfFile()
        guard data.count <= maxDurableAttemptRecordBytes,
              info.st_dev > 0, info.st_ino > 0 else { return nil }
        return (data, FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino)))
    }

    private static func readDurableAttemptState(
        providerID: String,
        modelID: String,
        directoryOverride: URL? = nil
    ) -> (generation: UInt64, isValid: Bool, record: DurableAttemptRecord?, identity: FileIdentity?, url: URL?, casGeneration: UInt64?) {
        guard let providerID = canonicalIdentityField(providerID),
              let modelID = canonicalIdentityField(modelID),
              let url = attemptCheckpointURL(providerID: providerID, modelID: modelID,
                                             directoryOverride: directoryOverride) else {
            return (0, false, nil, nil, nil, nil)
        }
        let pendingURL = url.appendingPathExtension("pending")
        guard !isSymbolicLink(url), !isSymbolicLink(pendingURL) else {
            return (0, false, nil, nil, nil, nil)
        }
        let primaryExists = FileManager.default.fileExists(atPath: url.path)
        let pendingExists = FileManager.default.fileExists(atPath: pendingURL.path)
        guard primaryExists || !pendingExists else {
            // A pending transaction without its main receipt has no durable
            // predecessor to CAS against; never publish or send from it.
            return (0, false, nil, nil, nil, nil)
        }
        let candidates = [url, pendingURL].compactMap {
            readDurableAttemptCandidate(from: $0, providerID: providerID, modelID: modelID)
        }
        guard !candidates.isEmpty else {
            guard !FileManager.default.fileExists(atPath: url.path),
                  !FileManager.default.fileExists(atPath: pendingURL.path) else {
                return (0, false, nil, nil, nil, nil)
            }
            // A fresh scope has no predecessor identity, but its target path
            // is already known. Keep that path through the first CAS write so
            // an instance-scoped test root cannot fall back to production.
            return (0, true, nil, nil, url, nil)
        }
        if candidates.count == 1, primaryExists, pendingExists,
           candidates[0].url == url {
            // A valid primary plus an unreadable pending candidate is not a
            // safe basis for choosing a generation: fail closed rather than
            // silently accepting a forked crash-window receipt.
            return (0, false, nil, nil, nil, nil)
        }
        if candidates.count == 2 {
            let first = candidates[0].record
            let second = candidates[1].record
            guard first.generation != second.generation
                    || (first.requestDigest == second.requestDigest
                        && first.transactionID == second.transactionID
                        && first.requestScopeDigest == second.requestScopeDigest
                        && first.responseSchemaFingerprint == second.responseSchemaFingerprint
                        && first.payloadDigest == second.payloadDigest
                        && first.epochPredecessorDigest == second.epochPredecessorDigest
                        && first.historyDigest == second.historyDigest
                        && first.compactionTransactionID == second.compactionTransactionID
                        && first.segmentManifest == second.segmentManifest
                        && first.segmentManifestPredecessorRoot == second.segmentManifestPredecessorRoot
                        && first.segmentGenerationCAS == second.segmentGenerationCAS
                        && first.cleanupTombstone == second.cleanupTombstone
                        && first.cleanupTombstoneSeal == second.cleanupTombstoneSeal
                        && first.cleanupEpochPredecessorSeal == second.cleanupEpochPredecessorSeal
                        && first.checkpointDigest == second.checkpointDigest) else {
                return (0, false, nil, nil, nil, nil)
            }
            let newer = first.generation > second.generation ? first : second
            let older = first.generation > second.generation ? second : first
            guard newer.previousGeneration == older.generation,
                  newer.previousDigest == (older.generation == 0 ? nil : older.requestDigest),
                  newer.previousTransactionID == (older.generation == 0 ? nil : older.transactionID),
                  newer.previousPayloadDigest == (older.generation == 0 ? nil : older.payloadDigest),
                  newer.epochPredecessorDigest == (older.generation == 0 ? nil : older.checkpointDigest),
                  newer.historyPredecessorDigest == (older.generation == 0 ? nil : older.historyDigest),
                  newer.segmentManifestPredecessorRoot == (older.generation == 0 ? nil : older.segmentManifestRoot),
                  newer.cleanupEpochPredecessorSeal == (older.generation == 0 ? nil : older.cleanupTombstoneSeal),
                  newer.requestID != older.requestID,
                  newer.transactionID != older.transactionID else {
                return (0, false, nil, nil, nil, nil)
            }
        }
        guard let candidate = candidates.max(by: {
            $0.record.generation < $1.record.generation
        }) else { return (0, false, nil, nil, nil, nil) }
        // If both primary and pending are valid, finish recovery by writing
        // the next generation to the primary path. This prevents a later
        // write to `.pending` from leaving a generation gap between the two
        // bounded candidates.
        if let primary = candidates.first(where: { $0.url == url }) {
            return (candidate.record.generation, true, candidate.record, primary.identity, url, primary.record.generation)
        }
        return (candidate.record.generation, true, candidate.record, candidate.identity, candidate.url, candidate.record.generation)
    }

    private static func readDurableAttemptCandidate(
        from url: URL,
        providerID: String,
        modelID: String
    ) -> DurableAttemptCandidate? {
        guard !isSymbolicLink(url),
              let bytes = readDurableAttemptBytes(from: url),
              let identity = fileIdentity(url),
              identity == bytes.identity,
              let data = Optional(bytes.data),
              let record = try? JSONDecoder().decode(DurableAttemptRecord.self, from: data),
              let canonicalData = try? canonicalJSONEncoder().encode(record),
              canonicalData == data,
              record.fileDevice == identity.device,
              record.fileInode == identity.inode,
              record.isValid(forProviderID: providerID, modelID: modelID) else {
            return nil
        }
        return DurableAttemptCandidate(url: url, record: record, identity: identity)
    }

    private static func syncFile(at url: URL) -> Bool {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        return fsync(descriptor) == 0
    }

    private static func syncDirectory(at url: URL) -> Bool {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        return fsync(descriptor) == 0
    }

    private static func writeDurableAttemptRecord(
        _ record: DurableAttemptRecord,
        expectedIdentity: FileIdentity?,
        targetURL: URL? = nil,
        expectedGeneration: UInt64? = nil,
        diagnostic: (DurableAttemptWriteStage) -> Void = { _ in }
    ) -> Bool {
        let unsealed = DurableAttemptRecord(
            providerID: record.providerID,
            modelID: record.modelID,
            generation: record.generation,
            previousGeneration: record.previousGeneration,
            previousDigest: record.previousDigest,
            previousTransactionID: record.previousTransactionID,
            previousPayloadDigest: record.previousPayloadDigest,
            epochPredecessorDigest: record.epochPredecessorDigest,
            historyPredecessorDigest: record.historyPredecessorDigest,
            modelGeneration: record.modelGeneration,
            requestID: record.requestID,
            requestDigest: record.requestDigest,
            transactionID: record.transactionID,
            requestScopeDigest: record.requestScopeDigest,
            responseSchemaFingerprint: record.responseSchemaFingerprint,
            receiptHistory: record.receiptHistory,
            historyDigest: record.historyDigest,
            compactionTransactionID: record.compactionTransactionID,
            segmentManifest: record.segmentManifest,
            segmentManifestRoot: record.segmentManifestRoot,
            segmentManifestReadbackSeal: record.segmentManifestReadbackSeal,
            segmentGenerationCAS: record.segmentGenerationCAS,
            cleanupTombstone: record.cleanupTombstone,
            cleanupTombstoneSeal: record.cleanupTombstoneSeal,
            cleanupEpochPredecessorSeal: record.cleanupEpochPredecessorSeal,
            segmentManifestPredecessorRoot: record.segmentManifestPredecessorRoot,
            payloadDigest: nil,
            checkpointDigest: nil,
            responseBodyDigest: record.responseBodyDigest,
            responseBodyBytes: record.responseBodyBytes,
            phase: record.phase,
            responseID: record.responseID,
            lastEventID: record.lastEventID,
            retryMilliseconds: record.retryMilliseconds,
            fileDevice: record.fileDevice,
            fileInode: record.fileInode
        )
        let payloadSealed = DurableAttemptRecord(
            providerID: unsealed.providerID,
            modelID: unsealed.modelID,
            generation: unsealed.generation,
            previousGeneration: unsealed.previousGeneration,
            previousDigest: unsealed.previousDigest,
            previousTransactionID: unsealed.previousTransactionID,
            previousPayloadDigest: unsealed.previousPayloadDigest,
            epochPredecessorDigest: unsealed.epochPredecessorDigest,
            historyPredecessorDigest: unsealed.historyPredecessorDigest,
            modelGeneration: unsealed.modelGeneration,
            requestID: unsealed.requestID,
            requestDigest: unsealed.requestDigest,
            transactionID: unsealed.transactionID,
            requestScopeDigest: unsealed.requestScopeDigest,
            responseSchemaFingerprint: unsealed.responseSchemaFingerprint,
            receiptHistory: unsealed.receiptHistory,
            historyDigest: unsealed.historyDigest,
            compactionTransactionID: unsealed.compactionTransactionID,
            segmentManifest: [],
            segmentManifestRoot: nil,
            segmentManifestReadbackSeal: nil,
            segmentGenerationCAS: [],
            cleanupTombstone: unsealed.cleanupTombstone,
            cleanupTombstoneSeal: unsealed.cleanupTombstoneSeal,
            cleanupEpochPredecessorSeal: unsealed.cleanupEpochPredecessorSeal,
            segmentManifestPredecessorRoot: unsealed.segmentManifestPredecessorRoot,
            payloadDigest: receiptPayloadDigest(unsealed),
            checkpointDigest: nil,
            responseBodyDigest: unsealed.responseBodyDigest,
            responseBodyBytes: unsealed.responseBodyBytes,
            phase: unsealed.phase,
            responseID: unsealed.responseID,
            lastEventID: unsealed.lastEventID,
            retryMilliseconds: unsealed.retryMilliseconds,
            fileDevice: unsealed.fileDevice,
            fileInode: unsealed.fileInode
        )
        let activeSegment: DurableReceiptHistoryEntry?
        if let requestDigest = payloadSealed.requestDigest,
           let transactionID = payloadSealed.transactionID,
           let payloadDigest = payloadSealed.payloadDigest {
            activeSegment = DurableReceiptHistoryEntry(
                generation: payloadSealed.generation,
                requestDigest: requestDigest,
                transactionID: transactionID,
                payloadDigest: payloadDigest,
                checkpointDigest: nil
            )
        } else {
            activeSegment = nil
        }
        let manifest = payloadSealed.receiptHistory + (activeSegment.map { [$0] } ?? [])
        let manifestRoot = segmentManifestRoot(manifest)
        let manifestCleanupTombstone = payloadSealed.cleanupTombstone.map {
            DurableCleanupTombstone(
                generation: $0.generation,
                requestDigest: $0.requestDigest,
                transactionID: $0.transactionID,
                payloadDigest: $0.payloadDigest,
                checkpointDigest: $0.checkpointDigest,
                predecessorHistoryDigest: payloadSealed.historyPredecessorDigest ?? "",
                predecessorCheckpointDigest: payloadSealed.epochPredecessorDigest ?? "",
                predecessorManifestRoot: $0.predecessorManifestRoot,
                successorManifestRoot: manifestRoot,
                successorHistoryDigest: payloadSealed.historyDigest,
                successorPayloadDigest: payloadSealed.payloadDigest
            )
        }
        let manifestCleanupTombstoneSeal: String? = {
            guard let manifestCleanupTombstone,
                  let compactionTransactionID = payloadSealed.compactionTransactionID else { return nil }
            return cleanupTombstoneSeal(
                manifestCleanupTombstone,
                compactionTransactionID: compactionTransactionID,
                previousSeal: payloadSealed.cleanupEpochPredecessorSeal
            )
        }()
        let manifestSealed = DurableAttemptRecord(
            providerID: payloadSealed.providerID,
            modelID: payloadSealed.modelID,
            generation: payloadSealed.generation,
            previousGeneration: payloadSealed.previousGeneration,
            previousDigest: payloadSealed.previousDigest,
            previousTransactionID: payloadSealed.previousTransactionID,
            previousPayloadDigest: payloadSealed.previousPayloadDigest,
            epochPredecessorDigest: payloadSealed.epochPredecessorDigest,
            historyPredecessorDigest: payloadSealed.historyPredecessorDigest,
            modelGeneration: payloadSealed.modelGeneration,
            requestID: payloadSealed.requestID,
            requestDigest: payloadSealed.requestDigest,
            transactionID: payloadSealed.transactionID,
            requestScopeDigest: payloadSealed.requestScopeDigest,
            responseSchemaFingerprint: payloadSealed.responseSchemaFingerprint,
            receiptHistory: payloadSealed.receiptHistory,
            historyDigest: payloadSealed.historyDigest,
            compactionTransactionID: payloadSealed.compactionTransactionID,
            segmentManifest: manifest,
            segmentManifestRoot: nil,
            segmentManifestReadbackSeal: nil,
            segmentGenerationCAS: [],
            cleanupTombstone: manifestCleanupTombstone,
            cleanupTombstoneSeal: manifestCleanupTombstoneSeal,
            cleanupEpochPredecessorSeal: payloadSealed.cleanupEpochPredecessorSeal,
            segmentManifestPredecessorRoot: payloadSealed.segmentManifestPredecessorRoot,
            payloadDigest: payloadSealed.payloadDigest,
            checkpointDigest: nil,
            responseBodyDigest: payloadSealed.responseBodyDigest,
            responseBodyBytes: payloadSealed.responseBodyBytes,
            phase: payloadSealed.phase,
            responseID: payloadSealed.responseID,
            lastEventID: payloadSealed.lastEventID,
            retryMilliseconds: payloadSealed.retryMilliseconds,
            fileDevice: payloadSealed.fileDevice,
            fileInode: payloadSealed.fileInode
        )
        let manifestRooted = DurableAttemptRecord(
            providerID: manifestSealed.providerID,
            modelID: manifestSealed.modelID,
            generation: manifestSealed.generation,
            previousGeneration: manifestSealed.previousGeneration,
            previousDigest: manifestSealed.previousDigest,
            previousTransactionID: manifestSealed.previousTransactionID,
            previousPayloadDigest: manifestSealed.previousPayloadDigest,
            epochPredecessorDigest: manifestSealed.epochPredecessorDigest,
            historyPredecessorDigest: manifestSealed.historyPredecessorDigest,
            modelGeneration: manifestSealed.modelGeneration,
            requestID: manifestSealed.requestID,
            requestDigest: manifestSealed.requestDigest,
            transactionID: manifestSealed.transactionID,
            requestScopeDigest: manifestSealed.requestScopeDigest,
            responseSchemaFingerprint: manifestSealed.responseSchemaFingerprint,
            receiptHistory: manifestSealed.receiptHistory,
            historyDigest: manifestSealed.historyDigest,
            compactionTransactionID: manifestSealed.compactionTransactionID,
            segmentManifest: manifestSealed.segmentManifest,
            segmentManifestRoot: manifestRoot,
            segmentManifestReadbackSeal: nil,
            segmentGenerationCAS: manifestSealed.segmentManifest.map(\.generation),
            cleanupTombstone: manifestSealed.cleanupTombstone,
            cleanupTombstoneSeal: manifestSealed.cleanupTombstoneSeal,
            cleanupEpochPredecessorSeal: manifestSealed.cleanupEpochPredecessorSeal,
            segmentManifestPredecessorRoot: manifestSealed.segmentManifestPredecessorRoot,
            payloadDigest: manifestSealed.payloadDigest,
            checkpointDigest: nil,
            responseBodyDigest: manifestSealed.responseBodyDigest,
            responseBodyBytes: manifestSealed.responseBodyBytes,
            phase: manifestSealed.phase,
            responseID: manifestSealed.responseID,
            lastEventID: manifestSealed.lastEventID,
            retryMilliseconds: manifestSealed.retryMilliseconds,
            fileDevice: manifestSealed.fileDevice,
            fileInode: manifestSealed.fileInode
        )
        let sealed = DurableAttemptRecord(
            providerID: manifestRooted.providerID,
            modelID: manifestRooted.modelID,
            generation: manifestRooted.generation,
            previousGeneration: manifestRooted.previousGeneration,
            previousDigest: manifestRooted.previousDigest,
            previousTransactionID: manifestRooted.previousTransactionID,
            previousPayloadDigest: manifestRooted.previousPayloadDigest,
            epochPredecessorDigest: manifestRooted.epochPredecessorDigest,
            historyPredecessorDigest: manifestRooted.historyPredecessorDigest,
            modelGeneration: manifestRooted.modelGeneration,
            requestID: manifestRooted.requestID,
            requestDigest: manifestRooted.requestDigest,
            transactionID: manifestRooted.transactionID,
            requestScopeDigest: manifestRooted.requestScopeDigest,
            responseSchemaFingerprint: manifestRooted.responseSchemaFingerprint,
            receiptHistory: manifestRooted.receiptHistory,
            historyDigest: manifestRooted.historyDigest,
            compactionTransactionID: manifestRooted.compactionTransactionID,
            segmentManifest: manifestRooted.segmentManifest,
            segmentManifestRoot: manifestRooted.segmentManifestRoot,
            segmentManifestReadbackSeal: nil,
            segmentGenerationCAS: manifestRooted.segmentGenerationCAS,
            cleanupTombstone: manifestRooted.cleanupTombstone,
            cleanupTombstoneSeal: manifestRooted.cleanupTombstoneSeal,
            cleanupEpochPredecessorSeal: manifestRooted.cleanupEpochPredecessorSeal,
            segmentManifestPredecessorRoot: manifestRooted.segmentManifestPredecessorRoot,
            payloadDigest: manifestRooted.payloadDigest,
            checkpointDigest: receiptCheckpointDigest(manifestRooted),
            responseBodyDigest: manifestRooted.responseBodyDigest,
            responseBodyBytes: manifestRooted.responseBodyBytes,
            phase: manifestRooted.phase,
            responseID: manifestRooted.responseID,
            lastEventID: manifestRooted.lastEventID,
            retryMilliseconds: manifestRooted.retryMilliseconds,
            fileDevice: manifestRooted.fileDevice,
            fileInode: manifestRooted.fileInode
        )
        guard let url = targetURL ?? attemptCheckpointURL(providerID: sealed.providerID, modelID: sealed.modelID) else {
            diagnostic(.targetURLRejected)
            return false
        }
        if let existing = fileIdentity(url) {
            guard let expectedIdentity, existing == expectedIdentity else {
                diagnostic(.existingIdentityRejected)
                return false
            }
        } else {
            guard expectedIdentity == nil, !isSymbolicLink(url) else {
                diagnostic(.absentIdentityRejected)
                return false
            }
        }
        if let expectedGeneration {
            guard let current = readDurableAttemptCandidate(
                from: url,
                providerID: record.providerID,
                modelID: record.modelID
            ), current.record.generation == expectedGeneration else {
                diagnostic(.generationCASRejected)
                return false
            }
        }
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let temporary = directory.appendingPathComponent("." + UUID().uuidString + ".tmp")
            defer { try? FileManager.default.removeItem(at: temporary) }
            let placeholder = DurableAttemptRecord(
                providerID: sealed.providerID,
                modelID: sealed.modelID,
                generation: sealed.generation,
                previousGeneration: sealed.previousGeneration,
                previousDigest: sealed.previousDigest,
                previousTransactionID: sealed.previousTransactionID,
                previousPayloadDigest: sealed.previousPayloadDigest,
                epochPredecessorDigest: sealed.epochPredecessorDigest,
                historyPredecessorDigest: sealed.historyPredecessorDigest,
                modelGeneration: sealed.modelGeneration,
                requestID: sealed.requestID,
                requestDigest: sealed.requestDigest,
                transactionID: sealed.transactionID,
                requestScopeDigest: sealed.requestScopeDigest,
                responseSchemaFingerprint: sealed.responseSchemaFingerprint,
                receiptHistory: sealed.receiptHistory,
                historyDigest: sealed.historyDigest,
                compactionTransactionID: sealed.compactionTransactionID,
                segmentManifest: sealed.segmentManifest,
                segmentManifestRoot: sealed.segmentManifestRoot,
                segmentManifestReadbackSeal: nil,
                segmentGenerationCAS: sealed.segmentGenerationCAS,
                cleanupTombstone: sealed.cleanupTombstone,
                cleanupTombstoneSeal: sealed.cleanupTombstoneSeal,
                cleanupEpochPredecessorSeal: sealed.cleanupEpochPredecessorSeal,
                segmentManifestPredecessorRoot: sealed.segmentManifestPredecessorRoot,
                payloadDigest: sealed.payloadDigest,
                checkpointDigest: sealed.checkpointDigest,
                responseBodyDigest: sealed.responseBodyDigest,
                responseBodyBytes: sealed.responseBodyBytes,
                phase: sealed.phase,
                responseID: sealed.responseID,
                lastEventID: sealed.lastEventID,
                retryMilliseconds: sealed.retryMilliseconds,
                fileDevice: 0,
                fileInode: 0
            )
            let placeholderData = try canonicalJSONEncoder().encode(placeholder)
            guard placeholderData.count <= maxDurableAttemptRecordBytes else {
                diagnostic(.placeholderSizeRejected)
                return false
            }
            try placeholderData.write(to: temporary)
            guard let temporaryIdentity = fileIdentity(temporary) else {
                diagnostic(.temporaryIdentityRejected)
                return false
            }
            let finalizedBase = DurableAttemptRecord(
                providerID: placeholder.providerID,
                modelID: placeholder.modelID,
                generation: placeholder.generation,
                previousGeneration: placeholder.previousGeneration,
                previousDigest: placeholder.previousDigest,
                previousTransactionID: placeholder.previousTransactionID,
                previousPayloadDigest: placeholder.previousPayloadDigest,
                epochPredecessorDigest: placeholder.epochPredecessorDigest,
                historyPredecessorDigest: placeholder.historyPredecessorDigest,
                modelGeneration: placeholder.modelGeneration,
                requestID: placeholder.requestID,
                requestDigest: placeholder.requestDigest,
                transactionID: placeholder.transactionID,
                requestScopeDigest: placeholder.requestScopeDigest,
                responseSchemaFingerprint: placeholder.responseSchemaFingerprint,
                receiptHistory: placeholder.receiptHistory,
                historyDigest: placeholder.historyDigest,
                compactionTransactionID: placeholder.compactionTransactionID,
                segmentManifest: placeholder.segmentManifest,
                segmentManifestRoot: placeholder.segmentManifestRoot,
                segmentManifestReadbackSeal: nil,
                segmentGenerationCAS: placeholder.segmentGenerationCAS,
                cleanupTombstone: placeholder.cleanupTombstone,
                cleanupTombstoneSeal: placeholder.cleanupTombstoneSeal,
                cleanupEpochPredecessorSeal: placeholder.cleanupEpochPredecessorSeal,
                segmentManifestPredecessorRoot: placeholder.segmentManifestPredecessorRoot,
                payloadDigest: placeholder.payloadDigest,
                checkpointDigest: placeholder.checkpointDigest,
                responseBodyDigest: placeholder.responseBodyDigest,
                responseBodyBytes: placeholder.responseBodyBytes,
                phase: placeholder.phase,
                responseID: placeholder.responseID,
                lastEventID: placeholder.lastEventID,
                retryMilliseconds: placeholder.retryMilliseconds,
                fileDevice: temporaryIdentity.device,
                fileInode: temporaryIdentity.inode
            )
            let finalized = DurableAttemptRecord(
                providerID: finalizedBase.providerID,
                modelID: finalizedBase.modelID,
                generation: finalizedBase.generation,
                previousGeneration: finalizedBase.previousGeneration,
                previousDigest: finalizedBase.previousDigest,
                previousTransactionID: finalizedBase.previousTransactionID,
                previousPayloadDigest: finalizedBase.previousPayloadDigest,
                epochPredecessorDigest: finalizedBase.epochPredecessorDigest,
                historyPredecessorDigest: finalizedBase.historyPredecessorDigest,
                modelGeneration: finalizedBase.modelGeneration,
                requestID: finalizedBase.requestID,
                requestDigest: finalizedBase.requestDigest,
                transactionID: finalizedBase.transactionID,
                requestScopeDigest: finalizedBase.requestScopeDigest,
                responseSchemaFingerprint: finalizedBase.responseSchemaFingerprint,
                receiptHistory: finalizedBase.receiptHistory,
                historyDigest: finalizedBase.historyDigest,
                compactionTransactionID: finalizedBase.compactionTransactionID,
                segmentManifest: finalizedBase.segmentManifest,
                segmentManifestRoot: finalizedBase.segmentManifestRoot,
                segmentManifestReadbackSeal: segmentManifestReadbackSeal(finalizedBase),
                segmentGenerationCAS: finalizedBase.segmentGenerationCAS,
                cleanupTombstone: finalizedBase.cleanupTombstone,
                cleanupTombstoneSeal: finalizedBase.cleanupTombstoneSeal,
                cleanupEpochPredecessorSeal: finalizedBase.cleanupEpochPredecessorSeal,
                segmentManifestPredecessorRoot: finalizedBase.segmentManifestPredecessorRoot,
                payloadDigest: finalizedBase.payloadDigest,
                checkpointDigest: finalizedBase.checkpointDigest,
                responseBodyDigest: finalizedBase.responseBodyDigest,
                responseBodyBytes: finalizedBase.responseBodyBytes,
                phase: finalizedBase.phase,
                responseID: finalizedBase.responseID,
                lastEventID: finalizedBase.lastEventID,
                retryMilliseconds: finalizedBase.retryMilliseconds,
                fileDevice: finalizedBase.fileDevice,
                fileInode: finalizedBase.fileInode
            )
            if let rejection = finalized.validationRejection(
                forProviderID: finalized.providerID,
                modelID: finalized.modelID
            ) {
                diagnostic(rejection.writeStage)
                return false
            }
            let finalizedData = try canonicalJSONEncoder().encode(finalized)
            guard finalizedData.count <= maxDurableAttemptRecordBytes else {
                diagnostic(.finalizedSizeRejected)
                return false
            }
            try finalizedData.write(to: temporary)
            guard fileIdentity(temporary) == temporaryIdentity else {
                diagnostic(.temporaryIdentityChanged)
                return false
            }
            guard syncFile(at: temporary) else {
                diagnostic(.temporarySyncRejected)
                return false
            }
            let pendingURL = url.appendingPathExtension("pending")
            guard !isSymbolicLink(pendingURL) else {
                diagnostic(.pendingSymbolicLinkRejected)
                return false
            }
            if fileIdentity(pendingURL) != nil {
                _ = try FileManager.default.replaceItemAt(pendingURL, withItemAt: temporary)
            } else {
                guard !FileManager.default.fileExists(atPath: pendingURL.path) else {
                    diagnostic(.pendingReplacementRejected)
                    return false
                }
                try FileManager.default.moveItem(at: temporary, to: pendingURL)
            }
            guard syncFile(at: pendingURL) else {
                diagnostic(.pendingSyncRejected)
                return false
            }
            if let current = fileIdentity(url) {
                guard let expectedIdentity, current == expectedIdentity else {
                    diagnostic(.targetIdentityRejected)
                    return false
                }
                _ = try FileManager.default.replaceItemAt(url, withItemAt: pendingURL)
            } else {
                guard expectedIdentity == nil, !isSymbolicLink(url) else {
                    diagnostic(.absentTargetRejected)
                    return false
                }
                try FileManager.default.moveItem(at: pendingURL, to: url)
            }
            guard fileIdentity(url) == temporaryIdentity,
                  syncFile(at: url),
                  syncDirectory(at: directory),
                  let readback = readDurableAttemptCandidate(
                    from: url,
                    providerID: sealed.providerID,
                    modelID: sealed.modelID
                  ),
                  readback.identity == temporaryIdentity,
                  readback.record == finalized else {
                diagnostic(.finalReadbackRejected)
                return false
            }
            return true
        } catch {
            diagnostic(.ioRejected)
            return false
        }
    }

    private func persistAttemptReceipt(
        identity: RequestIdentity,
        responseID: String?,
        eventID: String?,
        retryMilliseconds: UInt64?,
        responseBody: Data?,
        committed: Bool = false
    ) -> Bool {
        // Serialize durable CAS/read/write separately from the public field
        // lock. A receipt fsync must not block a main-actor model read.
        Self.durableAttemptStateLock.lock()
        defer { Self.durableAttemptStateLock.unlock() }
        setPersistAttemptReceiptDiagnosticStage(.canonicalIdentity)
        stateLock.lock()
        let modelID = Self.canonicalIdentityField(storedModel.id)
        let currentGeneration = modelGeneration
        let currentAttemptGeneration = attemptGeneration
        let currentRequestID = latestRequestID
        stateLock.unlock()
        guard let providerID = Self.canonicalIdentityField(providerName),
              let modelID,
              modelID == identity.modelID,
              currentGeneration == identity.generation,
              currentAttemptGeneration == identity.attemptGeneration,
              currentRequestID == identity.requestID,
              responseID?.isEmpty != true,
              eventID?.isEmpty != true else { return false }
        setPersistAttemptReceiptDiagnosticStage(.responseBodyBound)
        if let responseBody,
           responseBody.isEmpty || responseBody.count > Self.maxDurableResponseBodyBytes {
            return false
        }
        setPersistAttemptReceiptDiagnosticStage(.durableStateRequestBinding)
        let durableState = Self.readDurableAttemptState(
            providerID: providerID, modelID: modelID,
            directoryOverride: attemptCheckpointDirectory
        )
        guard let record = durableState.record,
              let fileIdentity = durableState.identity,
              let targetURL = durableState.url,
              record.generation == identity.attemptGeneration,
              record.modelGeneration == identity.generation,
              record.requestID == identity.requestID,
              record.requestDigest == Self.requestDigest(
                providerID: identity.providerID,
                modelID: identity.modelID,
                generation: identity.generation,
                attemptGeneration: identity.attemptGeneration,
                requestID: identity.requestID
              ),
              record.requestScopeDigest == identity.requestScopeDigest,
              record.responseSchemaFingerprint == identity.responseSchemaFingerprint else { return false }
        setPersistAttemptReceiptDiagnosticStage(.committedDowngrade)
        guard !(record.phase == "committed" && !committed) else { return false }
        setPersistAttemptReceiptDiagnosticStage(.responseIDConflict)
        if let existingResponseID = record.responseID,
           let responseID,
           existingResponseID != responseID { return false }
        let responseBodyDigest: String?
        let responseBodyBytes: UInt64?
        if let responseBody {
            let bodyBytes = UInt64(responseBody.count)
            let priorBytes = record.responseBodyBytes ?? 0
            setPersistAttemptReceiptDiagnosticStage(.cumulativeResponseBodyBound)
            guard bodyBytes <= UInt64(Self.maxDurableResponseBodyBytes),
                  priorBytes <= UInt64(Self.maxDurableResponseBodyBytes) - bodyBytes else { return false }
            responseBodyDigest = Self.appendResponseBodyDigest(
                previous: record.responseBodyDigest,
                body: responseBody
            )
            responseBodyBytes = priorBytes + bodyBytes
        } else {
            responseBodyDigest = record.responseBodyDigest
            responseBodyBytes = record.responseBodyBytes
        }
        let updated = DurableAttemptRecord(
            providerID: record.providerID,
            modelID: record.modelID,
            generation: record.generation,
            previousGeneration: record.previousGeneration,
            previousDigest: record.previousDigest,
            previousTransactionID: record.previousTransactionID,
            previousPayloadDigest: record.previousPayloadDigest,
            epochPredecessorDigest: record.epochPredecessorDigest,
            historyPredecessorDigest: record.historyPredecessorDigest,
            modelGeneration: record.modelGeneration,
            requestID: record.requestID,
            requestDigest: record.requestDigest,
            transactionID: record.transactionID,
            requestScopeDigest: record.requestScopeDigest,
            responseSchemaFingerprint: record.responseSchemaFingerprint,
            receiptHistory: record.receiptHistory,
            historyDigest: record.historyDigest,
            compactionTransactionID: record.compactionTransactionID,
            segmentManifest: record.segmentManifest,
            segmentManifestRoot: record.segmentManifestRoot,
            segmentManifestReadbackSeal: record.segmentManifestReadbackSeal,
            segmentGenerationCAS: record.segmentGenerationCAS,
            cleanupTombstone: record.cleanupTombstone,
            cleanupTombstoneSeal: record.cleanupTombstoneSeal,
            cleanupEpochPredecessorSeal: record.cleanupEpochPredecessorSeal,
            segmentManifestPredecessorRoot: record.segmentManifestPredecessorRoot,
            payloadDigest: nil,
            checkpointDigest: nil,
            responseBodyDigest: responseBodyDigest ?? record.responseBodyDigest,
            responseBodyBytes: responseBodyBytes ?? record.responseBodyBytes,
            phase: committed ? "committed" : record.phase,
            responseID: responseID ?? record.responseID,
            lastEventID: eventID ?? record.lastEventID,
            retryMilliseconds: retryMilliseconds ?? record.retryMilliseconds,
            fileDevice: record.fileDevice,
            fileInode: record.fileInode
        )
        setPersistAttemptReceiptDiagnosticStage(.writeAttempted)
        // A rebind while the durable state was read invalidates the receipt;
        // the write itself still runs outside stateLock.
        guard isCurrent(identity) else { return false }
        lastDurableAttemptWriteStage = .none
        durableWriteProbe?()
        return Self.writeDurableAttemptRecord(
            updated,
            expectedIdentity: fileIdentity,
            targetURL: targetURL,
            expectedGeneration: durableState.casGeneration,
            diagnostic: { [weak self] stage in
                self?.lastDurableAttemptWriteStage = stage
            }
        )
    }

    private func beginRequestIdentity(stream: Bool) throws -> RequestIdentity {
        // This lock serializes checkpoint generations; public configuration
        // readers use only stateLock and never wait for durable fsync.
        Self.durableAttemptStateLock.lock()
        defer { Self.durableAttemptStateLock.unlock() }
        setPersistAttemptReceiptDiagnosticStage(.notAttempted)
        stateLock.lock()
        let modelID = Self.canonicalIdentityField(storedModel.id)
        let generation = modelGeneration
        let stateValid = durableAttemptStateValid
        stateLock.unlock()
        guard let providerID = Self.canonicalIdentityField(providerName),
              let modelID else {
            throw LLMError.providerError(message: "Invalid provider request identity")
        }
        guard stateValid else {
            throw LLMError.providerError(message: "Invalid durable Responses attempt checkpoint")
        }
        let durableState = Self.readDurableAttemptState(
            providerID: providerID, modelID: modelID,
            directoryOverride: attemptCheckpointDirectory
        )
        let scope = DurableAttemptScope(providerID: providerID, modelID: modelID)
        stateLock.lock()
        let knownHighWater = attemptGenerationHighWaterByScope[scope]
        stateLock.unlock()
        guard durableState.isValid,
              knownHighWater == nil || durableState.generation >= knownHighWater! else {
            stateLock.lock()
            durableAttemptStateValid = false
            stateLock.unlock()
            throw LLMError.providerError(message: "Invalid durable Responses attempt checkpoint")
        }
        let nextGeneration = try Self.incrementAttemptGeneration(after: durableState.generation)
        let requestID = UUID()
        let responseSchemaFingerprint = stream
            ? Self.streamingResponseSchemaFingerprint
            : Self.nonStreamingResponseSchemaFingerprint
        let requestScopeDigest = Self.requestScopeDigest(
            providerID: providerID,
            modelID: modelID,
            generation: generation,
            attemptGeneration: nextGeneration,
            requestID: requestID,
            responseSchemaFingerprint: responseSchemaFingerprint
        )
        var receiptHistory = durableState.record?.receiptHistory ?? []
        var compactionTransactionID = durableState.record?.compactionTransactionID
        var cleanupTombstone = durableState.record?.cleanupTombstone
        var cleanupTombstoneSeal = durableState.record?.cleanupTombstoneSeal
        var cleanupEpochPredecessorSeal: String? = nil
        let segmentManifestPredecessorRoot = durableState.record?.segmentManifestRoot
        if let predecessor = durableState.record,
           predecessor.generation > 0,
           let requestDigest = predecessor.requestDigest,
           let transactionID = predecessor.transactionID,
           let payloadDigest = predecessor.payloadDigest,
           let checkpointDigest = predecessor.checkpointDigest {
            receiptHistory.append(DurableReceiptHistoryEntry(
                generation: predecessor.generation,
                requestDigest: requestDigest,
                transactionID: transactionID,
                payloadDigest: payloadDigest,
                checkpointDigest: checkpointDigest
            ))
            if receiptHistory.count > Self.maxDurableReceiptHistory {
                let removed = Array(receiptHistory.prefix(receiptHistory.count - Self.maxDurableReceiptHistory))
                receiptHistory.removeFirst(removed.count)
                compactionTransactionID = UUID()
                cleanupEpochPredecessorSeal = predecessor.cleanupTombstoneSeal
                cleanupTombstone = removed.first.map {
                    DurableCleanupTombstone(
                        generation: $0.generation,
                        requestDigest: $0.requestDigest,
                        transactionID: $0.transactionID,
                        payloadDigest: $0.payloadDigest,
                        checkpointDigest: $0.checkpointDigest ?? "",
                        predecessorHistoryDigest: predecessor.historyDigest ?? "",
                        predecessorCheckpointDigest: predecessor.checkpointDigest ?? "",
                        predecessorManifestRoot: predecessor.segmentManifestRoot ?? "",
                        successorManifestRoot: nil,
                        successorHistoryDigest: nil,
                        successorPayloadDigest: nil
                    )
                }
                if let cleanupTombstone,
                   let compactionTransactionID {
                    cleanupTombstoneSeal = Self.cleanupTombstoneSeal(
                        cleanupTombstone,
                        compactionTransactionID: compactionTransactionID,
                        previousSeal: cleanupEpochPredecessorSeal
                    )
                }
            }
        }
        if receiptHistory.count < Self.maxDurableReceiptHistory {
            compactionTransactionID = nil
            cleanupTombstone = nil
            cleanupTombstoneSeal = nil
            cleanupEpochPredecessorSeal = nil
        }
        let record = DurableAttemptRecord(
            providerID: providerID,
            modelID: modelID,
            generation: nextGeneration,
            previousGeneration: durableState.generation,
            previousDigest: durableState.record?.requestDigest,
            previousTransactionID: durableState.record?.transactionID,
            previousPayloadDigest: durableState.record?.payloadDigest,
            epochPredecessorDigest: durableState.record?.checkpointDigest,
            historyPredecessorDigest: durableState.record?.historyDigest,
            modelGeneration: generation,
            requestID: requestID,
            requestDigest: Self.requestDigest(
                providerID: providerID,
                modelID: modelID,
                generation: generation,
                attemptGeneration: nextGeneration,
                requestID: requestID
            ),
            transactionID: UUID(),
            requestScopeDigest: requestScopeDigest,
            responseSchemaFingerprint: responseSchemaFingerprint,
            receiptHistory: receiptHistory,
            historyDigest: Self.receiptHistoryDigest(receiptHistory),
            compactionTransactionID: compactionTransactionID,
            segmentManifest: [],
            segmentManifestRoot: nil,
            segmentManifestReadbackSeal: nil,
            segmentGenerationCAS: [],
            cleanupTombstone: cleanupTombstone,
            cleanupTombstoneSeal: cleanupTombstoneSeal,
            cleanupEpochPredecessorSeal: cleanupEpochPredecessorSeal,
            segmentManifestPredecessorRoot: segmentManifestPredecessorRoot,
            payloadDigest: nil,
            checkpointDigest: nil,
            responseBodyDigest: nil,
            responseBodyBytes: nil,
            phase: "prepared",
            responseID: nil,
            lastEventID: nil,
            retryMilliseconds: nil,
            fileDevice: 1,
            fileInode: 1
        )
        lastDurableAttemptWriteStage = .none
        durableWriteProbe?()
        guard Self.writeDurableAttemptRecord(
            record,
            expectedIdentity: durableState.identity,
            targetURL: durableState.url,
            expectedGeneration: durableState.casGeneration,
            diagnostic: { [weak self] stage in
                self?.lastDurableAttemptWriteStage = stage
            }
        ) else {
            if lastDurableAttemptWriteStage == .none {
                lastDurableAttemptWriteStage = .unknown
            }
            throw LLMError.providerError(message: "Unable to persist Responses attempt checkpoint")
        }
        stateLock.lock()
        defer { stateLock.unlock() }
        guard Self.canonicalIdentityField(storedModel.id) == modelID,
              modelGeneration == generation,
              durableAttemptStateValid else {
            throw LLMError.cancelled
        }
        attemptGeneration = nextGeneration
        attemptGenerationHighWaterByScope[scope] = nextGeneration
        let identity = RequestIdentity(
            providerID: providerID,
            modelID: modelID,
            generation: generation,
            attemptGeneration: nextGeneration,
            requestID: requestID,
            stream: stream,
            responseSchemaFingerprint: responseSchemaFingerprint,
            requestScopeDigest: requestScopeDigest
        )
        latestRequestID = identity.requestID
        return identity
    }

    private func currentRequestIdentity() -> RequestIdentity {
        stateLock.lock()
        defer { stateLock.unlock() }
        let providerID = Self.canonicalIdentityField(providerName) ?? "__invalid_provider_identity__"
        let modelID = Self.canonicalIdentityField(storedModel.id) ?? "__invalid_model_identity__"
        let requestID = latestRequestID ?? UUID()
        let responseSchemaFingerprint = Self.nonStreamingResponseSchemaFingerprint
        return RequestIdentity(
            providerID: providerID,
            modelID: modelID,
            generation: modelGeneration,
            attemptGeneration: attemptGeneration,
            requestID: requestID,
            stream: false,
            responseSchemaFingerprint: responseSchemaFingerprint,
            requestScopeDigest: Self.requestScopeDigest(
                providerID: providerID,
                modelID: modelID,
                generation: modelGeneration,
                attemptGeneration: attemptGeneration,
                requestID: requestID,
                responseSchemaFingerprint: responseSchemaFingerprint
            )
        )
    }

    private func isCurrent(_ identity: RequestIdentity) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let providerID = Self.canonicalIdentityField(providerName),
              let modelID = Self.canonicalIdentityField(storedModel.id) else { return false }
        return providerID == identity.providerID
            && modelID == identity.modelID
            && modelGeneration == identity.generation
            && attemptGeneration == identity.attemptGeneration
            && (latestRequestID == nil || latestRequestID == identity.requestID)
    }

    static func incrementAttemptGeneration(after value: UInt64) throws -> UInt64 {
        guard value < UInt64.max else {
            throw LLMError.providerError(message: "Responses API attempt generation exhausted")
        }
        return value + 1
    }

    /// Request identity is an internal security boundary, not a display label:
    /// NFC is deterministic, while printable ASCII excludes homoglyphs,
    /// bidi/zero-width controls, CRLF and NUL confusion.
    private static func canonicalIdentityField(_ value: String) -> String? {
        let normalized = value.precomposedStringWithCanonicalMapping
        let scalars = normalized.unicodeScalars
        guard !normalized.isEmpty,
              normalized.utf8.count <= maxRequestIdentityFieldBytes,
              scalars.allSatisfy({ (0x20...0x7E).contains($0.value) }),
              normalized.first != " ",
              normalized.last != " " else { return nil }
        return normalized
    }

    /// 本机日志里的失败原因（V-11）。`message` 是本地写死的原因短语时原样记录；
    /// 来自服务端的事件（`serverReported`）只记“服务端返回失败事件”和已识别的固定错误码，
    /// 不写服务端原文、令牌或请求体。
    static func streamFailureDiagnostic(code: String?, message: String, serverReported: Bool) -> String {
        guard serverReported else { return "Responses 流失败：" + message }
        switch code {
        case "context_length_exceeded", "insufficient_quota":
            return "Responses 流失败：服务端返回失败事件（\(code ?? "")）"
        default:
            return "Responses 流失败：服务端返回失败事件"
        }
    }

    private func streamFailure(
        identity: RequestIdentity,
        code: String? = nil,
        message: String,
        serverReported: Bool = false
    ) -> LLMError {
        guard isCurrent(identity) else { return .cancelled }
        logger.error(Self.streamFailureDiagnostic(code: code, message: message, serverReported: serverReported))
        // 只按固定错误码映射成类型化错误；服务端的 message 不进入任何错误表面。
        switch code {
        case "context_length_exceeded":
            return .contextLengthExceeded
        case "insufficient_quota":
            return .httpStatus(code: 429, detail: ProviderHTTPErrorAdapter.quotaDetail(statusCode: 429))
        default:
            return .providerError(message: "Responses API stream error")
        }
    }
}

// MARK: - Assistant tools-aware wire-SSE stream (W5-PROVIDER-RESPONSES-048)
//
// D-CHAT-03 `AssistantStreamingLLMProvider` conformance for the Responses
// wire protocol (POST /v1/responses, named-SSE). This closes the residual
// gap 037/044 recorded for this provider ("route no longer blocks it"):
// until now the AgentLoop tools-aware path fell back to the buffered
// `sendMessage(tools:)` single-`.completed` synthesis for Responses-backed
// routes and no assistant text streamed live.
//
// Contract alignment with the 044 wire-SSE migration (same seam semantics):
// 1. `response.output_text.delta` fragments are forwarded live as
//    `.textDelta`; the terminal `.completed` event is real data admitted
//    through the fence below — no synthetic `.completed` placeholder.
// 2. Function-call argument fragments (`response.function_call_arguments
//    .delta/.done`) and every non-text item event belong exclusively to the
//    terminal response and are never surfaced as text deltas.
// 3. The terminal is built from the `response.completed` /
//    `response.incomplete` event's embedded Response object through the
//    SAME admission fence the buffered `sendMessage(tools:)` runs on that
//    same JSON (`isBoundedJSON` + `hasSafeResponseIdentity` +
//    `hasSafeNonStreamingOutput` + usage/error shape checks +
//    `ResponsesAPIResponseParser.extractResponse`), so streamed and
//    buffered terminals are identical for identical wire facts. A
//    truncated/incomplete tool `arguments` payload fails closed exactly the
//    way the buffered path rejects it — the call is never admitted with
//    empty input and never synthesized.
// 4. Transport/framing keeps this provider's own hard limits and fences
//    (line/byte/event ceilings, `event:`↔`type` agreement, response & item
//    identity fencing, duplicate-event-id rejection, mid-stream EOF
//    `prematureStreamEnd`), and acquisition/terminal errors keep the
//    provider's payload-free typed projection (`mapError`/`mapHTTPError`
//    → `LLMError.httpStatus`/`.providerError`/`.cancelled`), which 037's
//    `ProviderRequestFailureKind.classify` consumes unchanged.
//
// Documented divergences from `streamMessage` (intentional, contract-safe):
// - durable per-event receipt commits (`persistAttemptReceipt`) are not
//   replayed on this path: the assistant stream has no Last-Event-ID
//   reconnect loop, so duplicate-event-id fencing is request-local. The
//   attempt checkpoint still advances through `beginRequestIdentity` so the
//   cross-attempt replay fence stays intact.
// - gateway media (`refusal`/non-`output_text` parts) is not reconstructed
//   into `mediaAttachments`; the seam contract covers text, usage and
//   native tool calls only (same note as the 044 extension).
//
// The buffered `sendMessage` paths and the text-only `streamMessage` are
// byte-for-byte untouched.
extension OpenAIResponsesProvider: AssistantStreamingLLMProvider {
    public func streamAssistantMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMAssistantStreamEvent, Error> {
        try await streamAssistantMessage(messages: messages, systemPrompt: systemPrompt,
            tools: tools, maxTokens: maxTokens, temperature: temperature, thinkingLevel: nil)
    }

    public func streamAssistantMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?,
        thinkingLevel: ThinkingLevel?
    ) async throws -> AsyncThrowingStream<LLMAssistantStreamEvent, Error> {
        // Same pre-acquisition cancellation contract as streamMessage: a
        // cancelled caller must not open an attempt at all.
        guard !Task.isCancelled else { throw LLMError.cancelled }
        let identity = try beginRequestIdentity(stream: true)
        let request = try await buildRequestOffMain(
            messages: messages,
            systemPrompt: systemPrompt,
            tools: tools,
            maxTokens: maxTokens,
            temperature: temperature,
            thinkingLevel: thinkingLevel,
            stream: true,
            identity: identity
        )

        let byteStream: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (byteStream, response) = try await session.bytes(for: request)
            // Do not hand back a stream after the caller already cancelled;
            // a buffered terminal event must not still be consumable.
            try Task.checkCancellation()
        } catch {
            // Acquisition is a provider boundary: keep the same typed,
            // payload-free projection the text-only stream uses.
            throw mapError(error, identity: identity)
        }
        let httpResponse = response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode ?? -1

        if !(200..<300).contains(statusCode) {
            throw await httpFailure(
                statusCode: statusCode,
                headers: Self.stringHeaders(from: httpResponse),
                bytes: byteStream,
                identity: identity
            )
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                var receivedTerminator = false
                var lastEventName: String? = nil
                var pendingEventID: String? = nil
                var eventData = ""
                var eventDataBytes = 0
                var lineCount = 0
                var totalBytes = 0
                var eventCount = 0
                var responseID: String?
                var seenResponseCreated = false
                var seenOutputItemIDs = Set<String>()
                var finishedOutputItemIDs = Set<String>()
                var seenEventIDs = Set<String>()
                var atStreamStart = true
                // Append-only mirror of the forwarded text deltas. The
                // terminal must equal it (seam contract 1) before admission.
                var streamedText = ""
                // Finished output items, in stream order. The ChatGPT account
                // backend (store: false) may send `response.completed` with an
                // empty `output`; like Codex, the terminal is then rebuilt from
                // these validated `response.output_item.done` items.
                var doneOutputItems: [[String: Any]] = []

                func discardTransaction() {
                    eventData.removeAll(keepingCapacity: false)
                    eventDataBytes = 0
                    lastEventName = nil
                    pendingEventID = nil
                }

                /// Validate and project one complete SSE event. Returns true
                /// once a terminal (completed/incomplete/failed/error) event
                /// has been handled.
                func processEvent(
                    eventName: String?,
                    eventID: String?,
                    payload: String
                ) throws -> Bool {
                    try Task.checkCancellation()
                    guard eventCount < Self.maxSSEEventCount else {
                        throw streamFailure(identity: identity, message: "too many SSE events")
                    }
                    eventCount += 1
                    if let eventID, !eventID.isEmpty {
                        guard !seenEventIDs.contains(eventID) else {
                            throw streamFailure(identity: identity, message: "duplicate SSE event identity")
                        }
                        seenEventIDs.insert(eventID)
                    }
                    // The Responses protocol has no Chat Completions `[DONE]`
                    // sentinel; a stray one is frame noise, never terminal.
                    if payload == "[DONE]" { return false }
                    guard let payloadData = payload.data(using: .utf8),
                          Self.isSafeJSONData(payloadData),
                          let json = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any],
                          Self.isBoundedJSON(json) else {
                        throw streamFailure(identity: identity, message: "invalid SSE JSON")
                    }
                    guard Self.canonicalJSONData(json) != nil else {
                        throw streamFailure(identity: identity, message: "oversized SSE response body")
                    }
                    if let eventName {
                        guard json["type"] as? String == eventName else {
                            throw streamFailure(identity: identity, message: "SSE event type mismatch")
                        }
                    }
                    if eventName == "response.output_text.delta" {
                        guard json["delta"] is String else {
                            throw streamFailure(identity: identity, message: "invalid text delta")
                        }
                    }
                    if eventName == "response.output_text.done" {
                        guard json["text"] is String else {
                            throw streamFailure(identity: identity, message: "invalid completed text")
                        }
                        if let itemID = json["item_id"] {
                            guard let itemID = itemID as? String,
                                  Self.isSafeResponseIdentity(itemID) else {
                                throw streamFailure(identity: identity, message: "invalid output item identity")
                            }
                        }
                    }
                    // Function-call argument fragments are terminal-only
                    // payload: shape-check them here and never project them
                    // toward the consumer.
                    if eventName == "response.function_call_arguments.delta" {
                        guard json["delta"] is String else {
                            throw streamFailure(identity: identity, message: "invalid function argument delta")
                        }
                        if let itemID = json["item_id"] {
                            guard let itemID = itemID as? String,
                                  Self.isSafeResponseIdentity(itemID) else {
                                throw streamFailure(identity: identity, message: "invalid output item identity")
                            }
                        }
                    }
                    if eventName == "response.function_call_arguments.done" {
                        guard json["arguments"] is String else {
                            throw streamFailure(identity: identity, message: "invalid completed function arguments")
                        }
                        if let itemID = json["item_id"] {
                            guard let itemID = itemID as? String,
                                  Self.isSafeResponseIdentity(itemID) else {
                                throw streamFailure(identity: identity, message: "invalid output item identity")
                            }
                        }
                    }
                    if ["response.content_part.added", "response.content_part.done"].contains(eventName) {
                        guard let part = json["part"] as? [String: Any],
                              let partType = part["type"] as? String,
                              !partType.isEmpty else {
                            throw streamFailure(identity: identity, message: "invalid content part")
                        }
                        if partType == "output_text" {
                            guard part["text"] is String else {
                                throw streamFailure(identity: identity, message: "invalid content part text")
                            }
                        }
                        if let itemID = json["item_id"] {
                            guard let itemID = itemID as? String,
                                  Self.isSafeResponseIdentity(itemID) else {
                                throw streamFailure(identity: identity, message: "invalid output item identity")
                            }
                        }
                    }
                    if eventName == "response.output_text.delta", json["item_id"] != nil {
                        guard let itemID = json["item_id"] as? String,
                              Self.isSafeResponseIdentity(itemID) else {
                            throw streamFailure(identity: identity, message: "invalid output item identity")
                        }
                    }
                    // Terminal metadata: same shape requirements as the
                    // text-only stream — embedded Response object whose id is
                    // safe and whose status equals the event name.
                    if let eventName,
                       ["response.completed", "response.failed", "response.incomplete"].contains(eventName) {
                        guard json["type"] as? String == eventName,
                              let response = json["response"] as? [String: Any],
                              let responseID = response["id"] as? String,
                              Self.isSafeResponseIdentity(responseID),
                              response["status"] as? String == eventName.replacingOccurrences(of: "response.", with: "") else {
                            throw streamFailure(identity: identity, message: "invalid terminal response metadata")
                        }
                        if eventName == "response.incomplete" {
                            guard let details = response["incomplete_details"] as? [String: Any],
                                  let reason = details["reason"] as? String,
                                  !reason.isEmpty,
                                  reason.utf8.count <= Self.maxSSEEventNameBytes,
                                  Self.isASCII(reason),
                                  !Self.containsSSEControlCharacter(reason) else {
                                throw streamFailure(identity: identity, message: "invalid incomplete response metadata")
                            }
                        }
                        if eventName == "response.failed" {
                            guard let error = response["error"] as? [String: Any],
                                  let message = error["message"] as? String,
                                  !message.isEmpty else {
                                throw streamFailure(identity: identity, message: "invalid failed response metadata")
                            }
                        }
                    }
                    let nestedResponseID = (json["response"] as? [String: Any])?["id"] as? String
                    if let nestedResponseID, !Self.isSafeResponseIdentity(nestedResponseID) {
                        throw streamFailure(identity: identity, message: "invalid response identity")
                    }
                    let topLevelResponseID: String?
                    if json["response_id"] != nil {
                        guard let value = json["response_id"] as? String,
                              Self.isSafeResponseIdentity(value) else {
                            throw streamFailure(identity: identity, message: "invalid response identity")
                        }
                        topLevelResponseID = value
                    } else {
                        topLevelResponseID = nil
                    }
                    if let nestedResponseID, let topLevelResponseID, nestedResponseID != topLevelResponseID {
                        throw streamFailure(identity: identity, message: "conflicting response identity")
                    }
                    if let observedID = nestedResponseID ?? topLevelResponseID {
                        let mayEstablishIdentity = eventName == "response.created"
                            || ["response.completed", "response.failed", "response.incomplete"].contains(eventName)
                        guard seenResponseCreated || mayEstablishIdentity else {
                            throw streamFailure(identity: identity, message: "response identity before creation")
                        }
                        if let responseID, responseID != observedID {
                            throw streamFailure(identity: identity, message: "conflicting response identity")
                        }
                        responseID = responseID ?? observedID
                    }
                    if eventName == "response.created" {
                        guard !seenResponseCreated else {
                            throw streamFailure(identity: identity, message: "duplicate response.created")
                        }
                        seenResponseCreated = true
                    }
                    switch eventName {
                    case "response.output_item.added", "response.output_item.done":
                        guard let item = json["item"] as? [String: Any] else {
                            throw streamFailure(identity: identity, message: "invalid output item")
                        }
                        if item["id"] != nil {
                            guard let observedID = item["id"] as? String,
                                  Self.isSafeResponseIdentity(observedID) else {
                                throw streamFailure(identity: identity, message: "invalid output item identity")
                            }
                            if eventName == "response.output_item.added" {
                                guard seenOutputItemIDs.insert(observedID).inserted else {
                                    throw streamFailure(identity: identity, message: "invalid output item identity")
                                }
                            } else {
                                guard seenOutputItemIDs.contains(observedID),
                                      finishedOutputItemIDs.insert(observedID).inserted else {
                                    throw streamFailure(identity: identity, message: "invalid output item identity")
                                }
                            }
                        } else if eventName == "response.output_item.done" {
                            throw streamFailure(identity: identity, message: "invalid output item identity")
                        }
                        if item["call_id"] != nil {
                            guard let callID = item["call_id"] as? String,
                                  Self.isSafeResponseIdentity(callID) else {
                                throw streamFailure(identity: identity, message: "invalid output item identity")
                            }
                        }
                        if eventName == "response.output_item.done" { doneOutputItems.append(item) }
                    default:
                        break
                    }
                    if ["response.completed", "response.incomplete"].contains(eventName),
                       let response = json["response"] as? [String: Any],
                       let usage = response["usage"],
                       !Self.isValidUsage(usage) {
                        throw streamFailure(identity: identity, message: "invalid response usage")
                    }

                    switch eventName {
                    case "response.output_text.delta":
                        guard isCurrent(identity) else { throw LLMError.cancelled }
                        if let delta = json["delta"] as? String, !delta.isEmpty {
                            streamedText += delta
                            try ProviderStreamCancellationPolicy.yield(
                                .textDelta(delta),
                                to: continuation
                            )
                        }
                    case "response.completed", "response.incomplete":
                        guard isCurrent(identity) else { throw LLMError.cancelled }
                        receivedTerminator = true
                        guard let terminalResponse = json["response"] as? [String: Any] else {
                            // Already validated above; belt-and-braces so no
                            // terminal projection ever runs on a missing
                            // Response object.
                            throw streamFailure(identity: identity, message: "invalid terminal response")
                        }
                        var terminalObject = terminalResponse
                        if usesChatGPTAccount,
                           (terminalResponse["output"] as? [Any])?.isEmpty ?? true,
                           !doneOutputItems.isEmpty {
                            terminalObject["output"] = doneOutputItems
                        }
                        let terminal = try assistantStreamTerminal(
                            from: terminalObject,
                            streamedText: streamedText,
                            identity: identity
                        )
                        try ProviderStreamCancellationPolicy.yield(
                            .completed(terminal),
                            to: continuation
                        )
                        return true
                    case "response.failed":
                        receivedTerminator = true
                        let failedError = (json["response"] as? [String: Any])?["error"] as? [String: Any]
                        if usesChatGPTAccount, isCurrent(identity),
                           let mapped = ChatGPTAccountErrors.llmError(code: failedError?["code"] as? String) {
                            throw mapped
                        }
                        let message = failedError?["message"] as? String ?? "response failed"
                        throw streamFailure(identity: identity, code: failedError?["code"] as? String, message: message,
                                            serverReported: true)
                    case "error":
                        receivedTerminator = true
                        throw streamFailure(
                            identity: identity,
                            code: json["code"] as? String,
                            message: json["message"] as? String ?? "unknown stream error",
                            serverReported: true
                        )
                    default:
                        // response.created / response.in_progress /
                        // response.output_item.* / response.content_part.* /
                        // response.output_text.done /
                        // response.function_call_arguments.* / reasoning
                        // summaries: framing-validated above, terminal-only
                        // content — nothing is forwarded here.
                        break
                    }
                    return false
                }

                do {
                    try Task.checkCancellation()
                    // Decode complete UTF-8 lines only (same rationale as
                    // streamMessage): a no-newline tail cannot buffer past
                    // the line ceiling before it is enforced.
                    func processLine(_ line: String) throws -> Bool {
                        let retainsCarriageReturn = line.last == "\r"
                        guard !line.unicodeScalars.contains(where: { $0.value == 0xFFFD }),
                              !Self.containsSSEControlCharacter(
                                  retainsCarriageReturn ? String(line.dropLast()) : line
                              ) else {
                            throw streamFailure(identity: identity, message: "invalid or oversized SSE line")
                        }
                        guard isCurrent(identity) else { throw LLMError.cancelled }
                        var normalizedLine = retainsCarriageReturn ? String(line.dropLast()) : line
                        if atStreamStart {
                            atStreamStart = false
                            if normalizedLine.first == "\u{FEFF}" {
                                normalizedLine.removeFirst()
                            }
                        }
                        if normalizedLine.isEmpty {
                            guard !eventData.isEmpty else {
                                eventDataBytes = 0
                                lastEventName = nil
                                pendingEventID = nil
                                return false
                            }
                            let payload = eventData
                            let eventName = lastEventName
                            let eventID = pendingEventID
                            eventData = ""
                            eventDataBytes = 0
                            lastEventName = nil
                            pendingEventID = nil
                            return try processEvent(
                                eventName: eventName,
                                eventID: eventID,
                                payload: payload
                            )
                        }
                        if normalizedLine.first == ":" {
                            return false
                        }
                        let fieldName: String
                        let fieldValue: String
                        if let separator = normalizedLine.firstIndex(of: ":") {
                            fieldName = String(normalizedLine[..<separator])
                            let rawValue = String(normalizedLine[normalizedLine.index(after: separator)...])
                            fieldValue = rawValue.first == " " ? String(rawValue.dropFirst()) : rawValue
                        } else {
                            fieldName = normalizedLine
                            fieldValue = ""
                        }
                        guard !fieldName.isEmpty,
                              fieldName.utf8.count <= Self.maxSSEFieldNameBytes,
                              Self.isASCII(fieldName) else {
                            throw streamFailure(identity: identity, message: "invalid SSE field name")
                        }
                        switch fieldName {
                        case "event":
                            guard fieldValue.utf8.count <= Self.maxSSEEventNameBytes,
                                  Self.isASCII(fieldValue) else {
                                throw streamFailure(identity: identity, message: "invalid SSE event field")
                            }
                            lastEventName = fieldValue
                            return false
                        case "retry":
                            // No reconnect loop on this path; the field is
                            // still shape-validated so oversized/hostile
                            // values cannot pass through unbounded.
                            guard fieldValue.utf8.count <= Self.maxSSERetryBytes,
                                  Self.isASCII(fieldValue) else {
                                throw streamFailure(identity: identity, message: "invalid or oversized SSE retry field")
                            }
                            guard fieldValue.isEmpty ||
                                  (fieldValue.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) &&
                                   UInt64(fieldValue) != nil) else {
                                throw streamFailure(identity: identity, message: "invalid or overflowing SSE retry field")
                            }
                            return false
                        case "id":
                            guard !fieldValue.isEmpty,
                                  fieldValue.utf8.count <= Self.maxSSEEventIDBytes,
                                  Self.isASCII(fieldValue) else {
                                throw streamFailure(identity: identity, message: "invalid or oversized SSE event identity")
                            }
                            pendingEventID = fieldValue
                            return false
                        case "data":
                            let payloadBytes = fieldValue.utf8.count
                            let separatorBytes = eventData.isEmpty ? 0 : 1
                            guard payloadBytes <= Self.maxSSEEventDataBytes - eventDataBytes - separatorBytes else {
                                discardTransaction()
                                throw streamFailure(identity: identity, message: "oversized SSE event data")
                            }
                            eventDataBytes += separatorBytes + payloadBytes
                            eventData += (eventData.isEmpty ? "" : "\n") + fieldValue
                            return false
                        default:
                            guard fieldValue.utf8.count <= Self.maxSSEFieldValueBytes,
                                  Self.isASCII(fieldValue) else {
                                throw streamFailure(identity: identity, message: "invalid or oversized SSE field")
                            }
                            return false
                        }
                    }

                    var lineBuffer = Data()
                    var stoppedAfterTerminal = false
                    var skipLFAfterCarriageReturn = false
                    for try await byte in byteStream {
                        try Task.checkCancellation()
                        guard totalBytes < Self.maxSSETotalBytes else {
                            lineBuffer.removeAll(keepingCapacity: false)
                            discardTransaction()
                            throw streamFailure(identity: identity, message: "oversized SSE stream")
                        }
                        totalBytes += 1
                        if skipLFAfterCarriageReturn {
                            skipLFAfterCarriageReturn = false
                            if byte == 0x0A { continue }
                        }
                        if byte == 0x0A || byte == 0x0D {
                            if byte == 0x0D {
                                skipLFAfterCarriageReturn = true
                            }
                            guard lineCount < Self.maxSSELineCount else {
                                lineBuffer.removeAll(keepingCapacity: false)
                                discardTransaction()
                                throw streamFailure(identity: identity, message: "too many SSE lines")
                            }
                            lineCount += 1
                            guard let line = String(data: lineBuffer, encoding: .utf8) else {
                                lineBuffer.removeAll(keepingCapacity: false)
                                discardTransaction()
                                throw streamFailure(identity: identity, message: "invalid UTF-8 SSE line")
                            }
                            lineBuffer.removeAll(keepingCapacity: false)
                            if try processLine(line) {
                                stoppedAfterTerminal = true
                                break
                            }
                        } else {
                            guard lineBuffer.count < Self.maxSSELineBytes else {
                                lineBuffer.removeAll(keepingCapacity: false)
                                discardTransaction()
                                throw streamFailure(identity: identity, message: "oversized SSE line")
                            }
                            lineBuffer.append(byte)
                        }
                    }
                    if !stoppedAfterTerminal, !lineBuffer.isEmpty {
                        lineBuffer.removeAll(keepingCapacity: false)
                        discardTransaction()
                        throw streamFailure(identity: identity, message: "truncated SSE line at EOF")
                    }
                    if !stoppedAfterTerminal, !eventData.isEmpty {
                        discardTransaction()
                        throw streamFailure(identity: identity, message: "truncated SSE event at EOF")
                    }
                    // Mid-stream EOF without response.completed/failed/
                    // incomplete: explicit terminal error, never a silent
                    // success (same rule as streamMessage and the buffered
                    // status fence).
                    guard receivedTerminator else {
                        continuation.finish(throwing: ResponsesAPIError.prematureStreamEnd)
                        return
                    }
                    continuation.finish()
                } catch {
                    discardTransaction()
                    continuation.finish(throwing: mapError(error, identity: identity))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Admit the terminal event's embedded Response object through the
    /// buffered `sendMessage(tools:)` fence and return the exact
    /// `LLMResponse` the buffered path would have produced for the same
    /// JSON: same bounded-identity / output-shape / usage / error checks,
    /// then the shared `ResponsesAPIResponseParser.extractResponse`.
    /// Incomplete or malformed tool input therefore fails closed here
    /// (dropped or rejected exactly as buffered), never synthesized, and
    /// seam contract 1 (terminal text == streamed deltas) is enforced.
    private func assistantStreamTerminal(
        from responseObject: [String: Any],
        streamedText: String,
        identity: RequestIdentity
    ) throws -> LLMResponse {
        guard Self.isBoundedJSON(responseObject),
              Self.hasSafeResponseIdentity(in: responseObject),
              Self.hasSafeNonStreamingOutput(in: responseObject) else {
            throw streamFailure(identity: identity, message: "invalid terminal response")
        }
        if let usage = responseObject["usage"], !Self.isValidUsage(usage) {
            throw streamFailure(identity: identity, message: "invalid terminal usage")
        }
        if let rawError = responseObject["error"], !(rawError is NSNull) {
            guard let error = rawError as? [String: Any],
                  let message = error["message"] as? String,
                  !message.isEmpty else {
                throw streamFailure(identity: identity, message: "invalid terminal error shape")
            }
        }
        let extracted: (text: String, status: String?, toolCalls: [LLMToolCall])
        do {
            extracted = try ResponsesAPIResponseParser.extractResponse(from: responseObject)
        } catch let error as ResponsesAPIError {
            if case .serverStreamError(_, _) = error {
                // Never project server-controlled response text as a local
                // error (identical projection to the buffered path).
                throw LLMError.providerError(message: "Responses API response error")
            }
            throw error
        }
        // Seam contract 1: the terminal must carry exactly the text that was
        // streamed live; a divergent terminal fails closed instead of being
        // rewritten or re-emitted.
        guard extracted.text == streamedText else {
            throw streamFailure(identity: identity, message: "terminal text diverged from deltas")
        }
        let usage = (responseObject["usage"] as? [String: Any]).flatMap { ResponsesAPIResponseParser.parseUsage($0) }
        if responseObject["id"] != nil,
           let rawID = responseObject["id"] as? String,
           !Self.isSafeResponseIdentity(rawID) {
            throw streamFailure(identity: identity, message: "invalid terminal response identity")
        }
        return LLMResponse(
            text: extracted.text,
            stopReason: extracted.status,
            usage: usage,
            toolCalls: extracted.toolCalls
        )
    }
}
