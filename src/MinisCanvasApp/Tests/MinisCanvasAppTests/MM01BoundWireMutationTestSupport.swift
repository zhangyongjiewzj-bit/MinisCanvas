import Foundation
import CryptoKit
import MinisCore
@testable import MinisCanvasApp

// TEST TARGET ONLY. Parse-only candidate; not typechecked, linked or run.
// Does not mint scenarios, replace backing stores, create snapshots of authority,
// weaken lane guards, launch App, or create URLSessions.
enum MM01BoundWireMutation: Sendable {
    case control
    case wrongPNG(Data)
    case audio(LLMMessage.AudioAttachment)
    case finalPrompt(String)
    case sendBudget(Int)
}

struct MM01BoundWireRequest: Sendable {
    var messages: [LLMMessage]
    var systemPrompt: String?
    var tools: [AgentToolDefinition]
    var maxTokens: Int
    var temperature: Double?
}

enum MM01BoundWireSupportError: Error {
    case missingFactory, notFresh, adapterRejected, duplicateInterception
    case baselineRequest, invalidMutation, configurationDrift
}

struct MM01BoundWireEvent: Sendable {
    let stage: String
    let executionIdentity: AgentExecutionIdentity
    let routeReceiptID: String
    let applyReceiptID: String
    let requestPromptSHA256: String
    let imageSHA256: [String]
    let audioCount: Int
    let toolCount: Int
    let maxTokens: Int
}

// Single fixture/turn owner. No static mutable state and no global hook.
@MainActor
final class MM01BoundWireMutationTestSupport {
    typealias Factory = (AgentTurnIdentity, any LLMProvider) -> ChatTurnRuntimeSnapshot
    private weak var chat: ChatStore?
    private let lane: DeepSeekMM01FieldLane
    private let originalFactory: Factory
    private let expectedSession: UUID
    private let expectedApplyReceipt: String
    private let mutation: MM01BoundWireMutation
    private let pauseBeforeDelegate: (@Sendable () async throws -> Void)?
    private let onEntry: (@MainActor @Sendable (MM01BoundWireEvent) -> Void)?
    private var installed = false
    private(set) var factoryCalls = 0
    private(set) var interceptions = 0
    private(set) var delegations = 0
    private(set) var originalRouteReceiptIDs: [String] = []
    private(set) var originalRouteSnapshots: [ProviderRuntimeSnapshot] = []
    private(set) var events: [MM01BoundWireEvent] = []
    private(set) var adapterFailures: [String] = []
    private(set) var delegatedErrorTypes: [String] = []

    init(chat: ChatStore, lane: DeepSeekMM01FieldLane,
         mutation: MM01BoundWireMutation,
         pauseBeforeDelegate: (@Sendable () async throws -> Void)? = nil,
         onEntry: (@MainActor @Sendable (MM01BoundWireEvent) -> Void)? = nil) throws {
        guard let factory = chat.turnRuntimeSnapshotFactory else {
            throw MM01BoundWireSupportError.missingFactory
        }
        guard let session = chat.activeSessionID,
              let apply = chat.lastChatModelApplyReceipt, apply.isApplied,
              !apply.applyReceiptID.isEmpty, !chat.isStreaming,
              chat.mm01FieldLane === lane,
              chat.streamingProviderOverride == nil,
              chat.agentEngine is AgentLoopChatEngine,
              chat.messages.allSatisfy({
                  $0.role == .assistant && $0.content == ChatStore.welcomeText && $0.attachments.isEmpty
              }) else { throw MM01BoundWireSupportError.notFresh }
        self.chat = chat; self.lane = lane; self.originalFactory = factory
        self.expectedSession = session; self.expectedApplyReceipt = apply.applyReceiptID
        self.mutation = mutation; self.pauseBeforeDelegate = pauseBeforeDelegate; self.onEntry = onEntry
        installed = true
        chat.turnRuntimeSnapshotFactory = { [weak self] turn, provider in
            let original = factory(turn, provider) // Original producer called exactly once.
            guard let self else {
                original.providerRuntimeRoutePreparation?.cancel()
                return Self.forward(original, route: nil, error: .missingPrimaryProvenance, preparation: nil)
            }
            return self.map(original, turn: turn, provider: provider)
        }
    }

    // Fixture must have no competing factory installer. Call only after its real terminal
    // or after stop + awaiting the existing owned Task. This does not cancel a live turn.
    func restore() {
        guard installed else { return }
        installed = false
        chat?.turnRuntimeSnapshotFactory = originalFactory
    }

    private func reject(_ original: ChatTurnRuntimeSnapshot, reason: String) -> ChatTurnRuntimeSnapshot {
        adapterFailures.append(reason) // Adapter failure is NOT a production predicate refusal.
        original.providerRuntimeRoutePreparation?.cancel()
        return Self.forward(original, route: nil, error: .missingPrimaryProvenance, preparation: nil)
    }

    private func map(_ original: ChatTurnRuntimeSnapshot, turn: AgentTurnIdentity,
                     provider: any LLMProvider) -> ChatTurnRuntimeSnapshot {
        factoryCalls += 1
        guard installed, factoryCalls == 1, original.turn == turn,
              original.requiresProviderRuntimeRoute,
              let actual = provider as? MM01FieldProvider,
              actual.lane === lane, actual.sessionID == expectedSession,
              actual.configurationIsIntact,
              turn.sessionID == expectedSession.uuidString,
              let chat, let identity = chat.activeExecutionIdentity(for: expectedSession),
              identity.isValid, identity.turn == turn,
              chat.lastChatModelApplyReceipt?.applyReceiptID == expectedApplyReceipt
        else { return reject(original, reason: "ACTUAL_FACTORY_OR_REGISTERED_IDENTITY_MISMATCH") }

        if let prior = original.providerRuntimeRoutePreparation {
            let mapped = Task { @MainActor [self] () -> Result<ProviderRuntimeRoute, ProviderRuntimeSnapshotError> in
                await withTaskCancellationHandler {
                    let result = await prior.value
                    guard !Task.isCancelled else { return .failure(.missingPrimaryProvenance) }
                    switch result {
                    case .failure(let error):
                        return .failure(error) // Preserve actual producer failure.
                    case .success(let route):
                        return wrappedResult(route, actual: actual, identity: identity)
                    }
                } onCancel: { prior.cancel() }
            }
            // Direct slot is preserved: the real preparation result still has precedence.
            return Self.forward(original, route: original.providerRuntimeRoute,
                                error: original.providerRuntimeRouteError, preparation: mapped)
        }
        guard let route = original.providerRuntimeRoute, original.providerRuntimeRouteError == nil else {
            // No invented good route in place of a missing/failed original one.
            if original.providerRuntimeRouteError != nil {
                return Self.forward(original, route: original.providerRuntimeRoute,
                                    error: original.providerRuntimeRouteError, preparation: nil)
            }
            return reject(original, reason: "ORIGINAL_ROUTE_MISSING")
        }
        switch wrappedResult(route, actual: actual, identity: identity) {
        case .success(let wrapped):
            return Self.forward(original, route: wrapped, error: nil, preparation: nil)
        case .failure(let error):
            return Self.forward(original, route: nil, error: error, preparation: nil)
        }
    }

    private func wrappedResult(_ route: ProviderRuntimeRoute, actual: MM01FieldProvider,
                               identity: AgentExecutionIdentity)
      -> Result<ProviderRuntimeRoute, ProviderRuntimeSnapshotError> {
        guard route.snapshot.fallbackProviderIDs.isEmpty,
              route.snapshot.fallbackProvenance.isEmpty,
              route.name == actual.name, route.model == actual.model,
              route.capabilities == actual.capabilities,
              actual.configurationIsIntact else {
            adapterFailures.append("NONEMPTY_FALLBACK_OR_ACTUAL_CONFIGURATION_MISMATCH")
            return .failure(.providerBindingMismatch(route.snapshot.providerID))
        }
        let wrapper = MM01BoundForwarder(originalRoute: route, actual: actual,
                                         owner: self, identity: identity)
        do {
            // Retain original route INCLUDING its private storage/observation sink.
            // Outer route has no sink; it must not forge a second production observation.
            let wrapped = try ProviderRuntimeRoute(snapshot: route.snapshot, primary: wrapper,
                fallbacks: [], observationSink: nil as ProviderRuntimeRoute.ObservationSink?)
            originalRouteReceiptIDs.append(route.snapshot.routeReceiptID)
            originalRouteSnapshots.append(route.snapshot)
            return .success(wrapped)
        } catch let error as ProviderRuntimeSnapshotError {
            adapterFailures.append("TYPED_OUTER_ROUTE_CONSTRUCTION_FAILED")
            return .failure(error)
        } catch {
            // Unexpected adapter failure is separately visible and disqualifies this candidate.
            adapterFailures.append("UNEXPECTED_ADAPTER_ERROR_TYPE:" + String(reflecting: type(of: error)))
            return .failure(.missingPrimaryProvenance)
        }
    }

    // All initializer fields from Source020bc are explicitly forwarded. Private authority
    // remains live via the original getter; never replace it with nil/cached true.
    private static func forward(_ s: ChatTurnRuntimeSnapshot, route: ProviderRuntimeRoute?,
        error: ProviderRuntimeSnapshotError?,
        preparation: Task<Result<ProviderRuntimeRoute, ProviderRuntimeSnapshotError>, Never>?)
      -> ChatTurnRuntimeSnapshot {
        ChatTurnRuntimeSnapshot(
            turn: s.turn,
            skillInjector: s.skillInjector,
            skillPreparation: s.skillPreparation,
            deferredSkillPreparation: s.deferredSkillPreparation,
            skillsDisabled: s.skillsDisabled,
            skillAuthorityCheck: { @MainActor in s.hasCurrentSkillAuthority },
            mcpBridge: s.mcpBridge,
            mcpBridgePreparation: s.mcpBridgePreparation,
            providerRuntimeRoute: route,
            providerRuntimeRouteError: error,
            providerRuntimeRoutePreparation: preparation,
            providerLaunchSnapshot: s.providerLaunchSnapshot,
            requiresProviderRuntimeRoute: s.requiresProviderRuntimeRoute,
            speechToolAvailability: s.speechToolAvailability,
            speechToolAvailabilityPreparation: s.speechToolAvailabilityPreparation,
            inFlightSettingsSnapshot: s.inFlightSettingsSnapshot,
            requiresInFlightSettingsSnapshot: s.requiresInFlightSettingsSnapshot,
            contextSettingsCapture: s.contextSettingsCapture)
    }

    fileprivate func prepare(_ request: MM01BoundWireRequest,
        actual: MM01FieldProvider, identity: AgentExecutionIdentity,
        receiptID: String) async throws -> MM01BoundWireRequest {
        interceptions += 1
        guard interceptions == 1, delegations == 0 else {
            throw MM01BoundWireSupportError.duplicateInterception
        }
        guard installed, let chat, chat.activeSessionID == expectedSession,
              chat.mm01FieldLane === lane,
              chat.activeExecutionIdentity(for: expectedSession) == identity,
              chat.lastChatModelApplyReceipt?.applyReceiptID == expectedApplyReceipt,
              lane.admits(actual), actual.configurationIsIntact else {
            throw MM01BoundWireSupportError.adapterRejected
        }
        let users = request.messages.filter { $0.role == .user }
        let uiUsers = chat.messages.filter { $0.role == .user }
        guard let prompt = request.systemPrompt,
              Data(prompt.utf8) == Data(MM01AgentScenarioContract.approvedSystemPrompt.utf8),
              request.maxTokens == 256, request.tools.isEmpty,
              request.messages.allSatisfy({ $0.audios.isEmpty && $0.toolCalls.isEmpty }),
              users.count == 1, users[0].images.count == 1,
              users[0].images[0].mimeType == "image/png",
              digest(users[0].images[0].data) == DeepSeekMM01FieldLane.imageSHA256,
              uiUsers.count == 1, uiUsers[0].id.uuidString == identity.turn.messageID
        else { throw MM01BoundWireSupportError.baselineRequest }
        let event = MM01BoundWireEvent(stage: "REQUEST_ENTRY_AFTER_ENGINE_BIND_BY_SOURCE_ORDER",
            executionIdentity: identity, routeReceiptID: receiptID,
            applyReceiptID: expectedApplyReceipt,
            requestPromptSHA256: digest(Data(prompt.utf8)),
            imageSHA256: request.messages.flatMap(\.images).map { digest($0.data) },
            audioCount: request.messages.reduce(0) { $0 + $1.audios.count },
            toolCount: request.tools.count, maxTokens: request.maxTokens)
        events.append(event); onEntry?(event)
        if let pauseBeforeDelegate { try await pauseBeforeDelegate() }
        try Task.checkCancellation()
        var result = request
        switch mutation {
        case .control: break
        case .wrongPNG(let bytes):
            guard !bytes.isEmpty, digest(bytes) != DeepSeekMM01FieldLane.imageSHA256,
                  let i = result.messages.firstIndex(where: { $0.role == .user }) else {
                throw MM01BoundWireSupportError.invalidMutation
            }
            result.messages[i].images[0] = .init(mimeType: "image/png", data: bytes)
        case .audio(let audio):
            guard let i = result.messages.firstIndex(where: { $0.role == .user }) else {
                throw MM01BoundWireSupportError.invalidMutation
            }
            result.messages[i].audios.append(audio)
        case .finalPrompt(let text):
            guard Data(text.utf8) != Data(prompt.utf8) else {
                throw MM01BoundWireSupportError.invalidMutation
            }
            result.systemPrompt = text
        case .sendBudget(let value):
            guard !(1...256).contains(value) else { throw MM01BoundWireSupportError.invalidMutation }
            result.maxTokens = value
        }
        delegations += 1 // Exactly one call to ORIGINAL route follows; not a retry oracle.
        return result
    }

    fileprivate func recordDelegatedError(_ error: Error) {
        delegatedErrorTypes.append(String(reflecting: type(of: error))) // No body/credentials.
    }
    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private final class MM01BoundForwarder: AssistantStreamingLLMProvider,
    ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
    private let originalRoute: ProviderRuntimeRoute
    private let actual: MM01FieldProvider
    private let owner: MM01BoundWireMutationTestSupport
    private let identity: AgentExecutionIdentity

    init(originalRoute: ProviderRuntimeRoute, actual: MM01FieldProvider,
         owner: MM01BoundWireMutationTestSupport, identity: AgentExecutionIdentity) {
        self.originalRoute = originalRoute; self.actual = actual
        self.owner = owner; self.identity = identity
    }
    var name: String { originalRoute.name }
    var capabilities: Set<ProviderCapability> { originalRoute.capabilities }
    var model: LLMModel {
        get { originalRoute.model }
        set { actual.model = newValue } // Actual field provider invalidates on drift.
    }
    var runtimeConfigurationMaterial: String? {
        get { actual.runtimeConfigurationMaterial }
        set { actual.runtimeConfigurationMaterial = newValue }
    }
    private nonisolated(nonsending) func request(_ messages: [LLMMessage], _ prompt: String?,
        _ tools: [AgentToolDefinition], _ maxTokens: Int, _ temperature: Double?)
      async throws -> MM01BoundWireRequest {
        guard actual.configurationIsIntact, actual.model == originalRoute.model,
              actual.name == originalRoute.name, actual.capabilities == originalRoute.capabilities else {
            throw MM01BoundWireSupportError.configurationDrift
        }
        let prepared = try await owner.prepare(.init(messages: messages, systemPrompt: prompt,
            tools: tools, maxTokens: maxTokens, temperature: temperature),
            actual: actual, identity: identity, receiptID: originalRoute.snapshot.routeReceiptID)
        guard actual.configurationIsIntact, actual.model == originalRoute.model,
              actual.name == originalRoute.name, actual.capabilities == originalRoute.capabilities else {
            throw MM01BoundWireSupportError.configurationDrift
        }
        return prepared
    }
    nonisolated(nonsending) func sendMessage(messages: [LLMMessage], systemPrompt: String?,
        maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        let r = try await request(messages, systemPrompt, [], maxTokens, temperature)
        do { return try await originalRoute.sendMessage(messages: r.messages,
            systemPrompt: r.systemPrompt, maxTokens: r.maxTokens, temperature: r.temperature) }
        catch { await owner.recordDelegatedError(error); throw error }
    }
    nonisolated(nonsending) func sendMessage(messages: [LLMMessage], systemPrompt: String?,
        tools: [AgentToolDefinition], maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        let r = try await request(messages, systemPrompt, tools, maxTokens, temperature)
        do { return try await originalRoute.sendMessage(messages: r.messages,
            systemPrompt: r.systemPrompt, tools: r.tools, maxTokens: r.maxTokens, temperature: r.temperature) }
        catch { await owner.recordDelegatedError(error); throw error }
    }
    nonisolated(nonsending) func streamMessage(messages: [LLMMessage], systemPrompt: String?,
        maxTokens: Int, temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        let r = try await request(messages, systemPrompt, [], maxTokens, temperature)
        do { return try await originalRoute.streamMessage(messages: r.messages,
            systemPrompt: r.systemPrompt, maxTokens: r.maxTokens, temperature: r.temperature) }
        catch { await owner.recordDelegatedError(error); throw error }
    }
    nonisolated(nonsending) func streamAssistantMessage(messages: [LLMMessage], systemPrompt: String?,
        tools: [AgentToolDefinition], maxTokens: Int, temperature: Double?)
      async throws -> AsyncThrowingStream<LLMAssistantStreamEvent, Error> {
        let r = try await request(messages, systemPrompt, tools, maxTokens, temperature)
        do { return try await originalRoute.streamAssistantMessage(messages: r.messages,
            systemPrompt: r.systemPrompt, tools: r.tools, maxTokens: r.maxTokens, temperature: r.temperature) }
        catch { await owner.recordDelegatedError(error); throw error }
    }
}

