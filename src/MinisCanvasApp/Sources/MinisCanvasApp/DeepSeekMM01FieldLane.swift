import Foundation
import CryptoKit
import MinisCore

/// One explicit owned field run. This is neither a global modality declaration
/// nor a network switch; the same object owns readiness, model resolution and I/O.
@MainActor
final class DeepSeekMM01FieldLane {
    nonisolated static let activationArgument = "--mm01-deepseek-flash-visual"
    nonisolated static let modelID = "deepseek-flash"
    nonisolated static let imageSHA256 = "f50b589c8793416b5b44b566e89bfff1e86a4d71cc18d50e0bf3b5e2e221ce90"
    nonisolated static let capabilityFactSHA256 = "325fb712be0dc063dbeceba0e1a4a1cfbfecf80fb80da2c7ffbe90fc08948c8e"
    nonisolated static let prompt = "请只根据图片描述：共有几个主要图形？从左到右分别是什么形状和颜色？若不能读取图片，请明确说明无法读取，不要猜测。"
    nonisolated static let assembledPrompt = prompt + "\n\n我上传了图片 标准几何图.png（已随消息附加，请查看）。"
    nonisolated static let verifiedModalities: ModelModality = [.textInput, .textOutput, .imageInput]
    enum Refusal: Error { case admission, readiness, payload, consumed }
    enum LocalControlReason: String, Sendable {
        case alreadyCompleted, alreadyFailed, sequenceLimit
        var message: String {
            switch self {
            case .alreadyCompleted: "本次受控检查已完成，保留原结果；未发送新请求。"
            case .alreadyFailed: "本次受控检查已结束且不重试，保留原失败结果；未发送新请求。"
            case .sequenceLimit: "本次请求不属于当前受控检查顺序；未发送新请求。"
            }
        }
    }
    struct ReadinessHTTPFailure: Error {
        let statusCode: Int
        let errorCategory: ProviderReadinessFailureCategory?
        fileprivate init(statusCode: Int, errorCategory: ProviderReadinessFailureCategory?) {
            self.statusCode = statusCode; self.errorCategory = errorCategory
        }
    }
    // Only this sender can mint a no-I/O control outcome. It carries the real
    // lane and secret-free binding, never a response or a successful receipt.
    struct LocalControlRefusal: Error {
        fileprivate let origin: DeepSeekMM01FieldLane
        fileprivate let binding: ProviderCredentialBinding
        let reason: LocalControlReason
        fileprivate init(origin: DeepSeekMM01FieldLane, binding: ProviderCredentialBinding,
                         reason: LocalControlReason) {
            self.origin = origin; self.binding = binding; self.reason = reason
        }
    }
    private let profile: RuntimeIsolationProfile
    private let keychain: KeychainStore
    private let environmentStore: EnvVarStore
    private let session: URLSession
    private let outboundAudit: OwnedMMOutboundLedger?
    var requiresOwnedOutboundAudit: Bool { outboundAudit != nil }
    func beginOwnedUIAction(_ caller: OwnedMMCaller) throws -> OwnedMMActionTicket? {
        try outboundAudit?.beginAction(caller)
    }
    private func auditPhase(_ operation: ProviderReadinessOperation) -> OwnedMMPhase {
        switch operation {
        case .reachability: .reachability
        case .authentication: .authentication
        case .modelDiscovery: .modelDiscovery
        case .minimalModelRequest: .minimalText
        }
    }
    private weak var settings: SettingsCenter?
    private weak var chat: ChatStore?
    private var recordID: String?
    private var revision: String?
    private var startupSession: UUID?
    private var visualSession: UUID?
    private var visualProviderID: String?
    private var visualApplyReceiptID: String?
    private var readinessOrdinal = 0
    private var readinessFailed = false
    private var readinessComplete = false
    private var visualConsumed = false
    private struct AgentScenarioBinding {
        let nonce: UUID
        let sessionID: UUID
        let applyReceiptID: String
        let executionIdentity: AgentExecutionIdentity
        var prepared = false
        let outboundAction: OwnedMMActionTicket?
    }
    private var agentScenarioBinding: AgentScenarioBinding?


    private init(profile: RuntimeIsolationProfile, keychain: KeychainStore,
                 environmentStore: EnvVarStore, configuration: URLSessionConfiguration, auditWindow: (nonce: String, deadline: Date)?) {
        self.profile = profile; self.keychain = keychain; self.environmentStore = environmentStore
        outboundAudit = auditWindow.map {
            let window = $0
            return OwnedMMOutboundLedger(runIdentity: profile.launchIdentity, windowNonce: window.nonce,
                deadline: window.deadline, windowIsCurrent: {
                    guard let current = KeychainStore.ownedMMCredentialReadWindow else { return false }
                    return current.nonce == window.nonce && current.deadline == window.deadline
                })
        }
        configuration.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0]
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration, delegate: MM01NoRedirect(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    /// The bootstrap's exact factory-created RAM object is supplied before any
    /// live I/O. This method never reads credential env; normal/no-flag is inert.
    static func acceptsAdmission(profile: RuntimeIsolationProfile, keychain: KeychainStore,
                                 arguments: [String], environment: [String: String]) -> Bool {
        arguments.filter({ $0 == activationArgument }).count == 1
            && arguments.filter({ $0 == DeepSeekEnvironmentPackageFieldBootstrap.activationArgument }).count == 1
            && arguments.filter({ $0 == RuntimeIsolationProfile.fieldActivationArgument }).count == 1
            && profile.mode == .packagedField && profile.isDisposableRootIntact
            && ThemeApprovalPackageFieldFixture.rootIsSafe(profile) && profile.keychainLegacyServices.isEmpty
            && keychain.backingKind == .injected
            && environment[RuntimeIsolationProfile.fieldActivationMarkerKey] == "1"
            && environment[RuntimeIsolationProfile.fieldActivationRootKey] == profile.rootDirectory.path
            && environment[RuntimeIsolationProfile.profileIdentityKey] == profile.launchIdentity
    }
    enum FactoryAuditRequirement: Equatable { case legacyNonMM, ownedMM }
    /// Pure classification only: it cannot mint a window, ticket or receipt.
    /// The production factory supplies the requirement from the real process's
    /// read policy; the synthetic `arguments` array is not an authority source.
    static func factoryAuditRequirement(actualProcessRequiresPlan: Bool,
        hasTestConfiguration: Bool, installedWindowPresent: Bool) -> FactoryAuditRequirement? {
        guard actualProcessRequiresPlan else { return .legacyNonMM }
        guard !hasTestConfiguration, installedWindowPresent else { return nil }
        return .ownedMM
    }

    static func makeAfterSuccessfulInstall(profile: RuntimeIsolationProfile, keychain: KeychainStore,
        environmentStore: EnvVarStore, arguments: [String], environment: [String: String],
        testConfiguration: URLSessionConfiguration?) -> DeepSeekMM01FieldLane? {
        guard acceptsAdmission(profile: profile, keychain: keychain, arguments: arguments, environment: environment) else { return nil }
        if testConfiguration != nil {
            guard (try? FormalTestIsolationPaths.resolveCurrentProcess()) != nil else { return nil }
        }
        let installedWindow = KeychainStore.ownedMMCredentialReadWindow
        guard let requirement = factoryAuditRequirement(
            actualProcessRequiresPlan: KeychainStore.ownedMMCredentialReadBudgetRequired,
            hasTestConfiguration: testConfiguration != nil,
            installedWindowPresent: installedWindow != nil) else { return nil }
        let auditWindow = requirement == .ownedMM ? installedWindow : nil
        let configuration = testConfiguration ?? .ephemeral
        if testConfiguration == nil { configuration.protocolClasses = nil }
        return DeepSeekMM01FieldLane(profile: profile, keychain: keychain,
            environmentStore: environmentStore, configuration: configuration, auditWindow: auditWindow)
    }
    nonisolated static let visualEndpoint = "https://api.deepseek.com:443/chat/completions"
    nonisolated static func normalizeOfficialRequest(_ original: URLRequest) throws -> URLRequest {
        guard let url = original.url, var c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme == "https", c.host == "api.deepseek.com", c.port == nil || c.port == 443,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              (original.httpMethod == "GET" && c.path == "/models")
                || (original.httpMethod == "POST" && c.path == "/chat/completions") else { throw Refusal.admission }
        c.port = 443
        var request = original; request.url = c.url
        return request
    }

    @discardableResult
    func bind(settings: SettingsCenter, actualKeychain: KeychainStore, chat: ChatStore) -> Bool {
        guard self.settings == nil, actualKeychain === keychain,
              settings.envStore === environmentStore,
              settings.sessionStore.directory == profile.sessionDirectory,
              chat.sessionStore?.directory == profile.sessionDirectory,
              settings.envStore.metadataDirectory == profile.providerConfigurationDirectory,
              profile.isDisposableRootIntact,
              let record = settings.providerRecords.first(where: { $0.name == DeepSeekProviderContract.apiKeyEnvironmentVariable }),
              record.baseURL == DeepSeekProviderContract.baseURL,
              record.protocolType == .openaiCompatible, record.modelNames == [Self.modelID],
              record.valueInKeychain, record.isSecret,
              (record.value.isEmpty || record.value == keychain.get(record.name)),
              let binding = settings.providerCredentialBinding(recordID: record.id) else { return false }
        self.settings = settings; self.chat = chat; recordID = record.id; revision = binding.revision
        startupSession = chat.activeSessionID
        settings.mm01FieldLane = self; chat.mm01FieldLane = self
        return true
    }
    // Field-only safe diagnostics. No credential/header/body/string-error values enter this schema.
    private func traceReadiness(_ event: String, condition: String? = nil, value: Bool? = nil,
                                operation: ProviderReadinessOperation? = nil,
                                status: Int? = nil, category: ProviderReadinessFailureCategory? = nil,
                                error: Error? = nil) {
        var row: [String: Any] = ["schema": "MM01_READINESS_SAFE_OUTCOME_V1", "event": event]
        if let condition { row["condition"] = condition }
        if let value { row["value"] = value }
        if let operation {
            switch operation {
            case .reachability: row["operation"] = "reachability"
            case .authentication: row["operation"] = "authentication"
            case .modelDiscovery: row["operation"] = "modelDiscovery"
            case .minimalModelRequest: row["operation"] = "minimalModelRequest"
            }
        }
        if let status { row["HTTP_status"] = status }
        if let category { row["error_category"] = category.rawValue }
        if let error {
            if let refusal = error as? Refusal {
                switch refusal {
                case .admission: row["error_type"] = "Refusal.admission"
                case .readiness: row["error_type"] = "Refusal.readiness"
                case .payload: row["error_type"] = "Refusal.payload"
                case .consumed: row["error_type"] = "Refusal.consumed"
                }
            } else if let failure = error as? ReadinessHTTPFailure {
                row["error_type"] = "ReadinessHTTPFailure"
                row["HTTP_status"] = failure.statusCode
            } else if let control = error as? LocalControlRefusal {
                switch control.reason {
                case .alreadyCompleted: row["error_type"] = "LocalControl.alreadyCompleted"
                case .alreadyFailed: row["error_type"] = "LocalControl.alreadyFailed"
                case .sequenceLimit: row["error_type"] = "LocalControl.sequenceLimit"
                }
            } else if let transport = error as? SettingsProviderReadinessTransportError {
                switch transport {
                case .missingCredential: row["error_type"] = "Transport.missingCredential"
                case .invalidURL: row["error_type"] = "Transport.invalidURL"
                case .timeout: row["error_type"] = "Transport.timeout"
                case .redirectRejected: row["error_type"] = "Transport.redirectRejected"
                case .invalidResponse: row["error_type"] = "Transport.invalidResponse"
                case .unavailable: row["error_type"] = "Transport.unavailable"
                }
            } else { row["error_type"] = "OTHER" }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        print(line)
    }
    private func traceBool(_ staticTag: String, _ originalValue: Bool) -> Bool {
        traceReadiness("condition", condition: staticTag, value: originalValue)
        return originalValue
    }

    var intact: Bool {
        guard traceBool("intact.profile_mode", profile.mode == .packagedField), traceBool("intact.root_intact", profile.isDisposableRootIntact),
              traceBool("intact.safe_root", ThemeApprovalPackageFieldFixture.rootIsSafe(profile)), traceBool("intact.injected", keychain.backingKind == .injected),
              let settings, traceBool("intact.environment_store", settings.envStore === environmentStore),
              let chat, traceBool("intact.chat_directory", chat.sessionStore?.directory == profile.sessionDirectory),
              traceBool("intact.settings_directory", settings.sessionStore.directory == profile.sessionDirectory),
              let recordID, let revision,
              let record = settings.providerRecords.first(where: { $0.id == recordID }),
              traceBool("intact.provider_name", record.name == DeepSeekProviderContract.apiKeyEnvironmentVariable),
              traceBool("intact.official_base", record.baseURL == DeepSeekProviderContract.baseURL), traceBool("intact.wire_protocol", record.protocolType == .openaiCompatible),
              traceBool("intact.fixed_model", record.modelNames == [Self.modelID]),
              traceBool("intact.binding_revision_equal", settings.providerCredentialBinding(recordID: recordID)?.revision == revision) else { return false }
        return true
    }
    func discoverySubset(_ discovered: [String], record: EnvVarEntry) -> [String] {
        // Only this lane-owned record has the field model allow-list.
        // Other builtin/custom records retain their ordinary discovery result.
        guard record.id == recordID else { return discovered }
        guard intact,
              record.name == DeepSeekProviderContract.apiKeyEnvironmentVariable,
              settings?.providerRecords.first(where: { $0.id == record.id }) == record else { return [] }
        return discovered.contains(Self.modelID) ? [Self.modelID] : []
    }
    var readinessTransport: any SettingsProviderReadinessTransport { MM01ReadinessTransport(lane: self) }

    /// Settings normalizes an empty base path to one slash. Admit only the
    /// same official HTTPS origin, retaining the exact endpoint policy below.
    nonisolated static func admitsOfficialReadinessOrigin(_ url: URL) -> Bool {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return c.scheme?.lowercased() == "https"
            && c.host?.lowercased() == "api.deepseek.com"
            && c.percentEncodedHost?.lowercased() == "api.deepseek.com"
            && (c.port == nil || c.port == 443)
            && (c.percentEncodedPath.isEmpty || c.percentEncodedPath == "/")
            && c.user == nil && c.password == nil && c.query == nil && c.fragment == nil
    }
    private func isOwnedReadinessOperation(_ request: ProviderReadinessTransportRequest) -> Bool {
        switch request.operation {
        case .reachability, .authentication, .modelDiscovery:
            return request.modelID == nil
        case .minimalModelRequest(let modelID):
            return modelID == Self.modelID && request.modelID == Self.modelID
        }
    }
    private func localControlRefusal(_ reason: LocalControlReason) throws -> LocalControlRefusal {
        guard intact, let settings, let recordID,
              let binding = settings.providerCredentialBinding(recordID: recordID),
              binding.revision == revision else { throw Refusal.admission }
        return LocalControlRefusal(origin: self, binding: binding, reason: reason)
    }
    // Revalidate the exact owner and opaque Keychain/metadata revision after
    // the await boundary. A changed key/configuration never borrows old facts.
    func localControlReason(for error: Error,
                            request: ProviderReadinessTransportRequest) -> LocalControlReason? {
        guard let control = error as? LocalControlRefusal, control.origin === self,
              intact, let settings, let recordID,
              settings.providerCredentialBinding(recordID: recordID) == control.binding,
              request.providerID == DeepSeekProviderContract.apiKeyEnvironmentVariable,
              Self.admitsOfficialReadinessOrigin(request.baseURL),
              request.protocolType == .openaiCompatible,
              isOwnedReadinessOperation(request) else { return nil }
        return control.reason
    }
    func sendReadiness(_ request: ProviderReadinessTransportRequest) async throws -> ProviderReadinessTransportResponse {
        var auditSucceeded = false
        defer { if !auditSucceeded { outboundAudit?.stop() } }
        try outboundAudit?.validate(request.ownedMMAction, phase: auditPhase(request.operation))
        guard traceBool("pre.intact", intact),
              traceBool("pre.provider_name", request.providerID == DeepSeekProviderContract.apiKeyEnvironmentVariable),
              traceBool("pre.official_origin", Self.admitsOfficialReadinessOrigin(request.baseURL)),
              traceBool("pre.wire_protocol", request.protocolType == .openaiCompatible) else {
            traceReadiness("PRE_HTTP_ADMISSION_DENIED", operation: request.operation)
            throw Refusal.admission
        }
        guard isOwnedReadinessOperation(request) else { throw Refusal.readiness }
        // A terminal no-I/O outcome needs the current lane/binding, not the
        // credential value. It cannot authorize transport or mint success.
        guard traceBool("pre.not_failed", !readinessFailed) else {
            let control = try localControlRefusal(.alreadyFailed)
            traceReadiness("LOCAL_CONTROL_REFUSED", operation: request.operation, error: control)
            throw control
        }
        guard traceBool("pre.not_complete", !readinessComplete) else {
            let control = try localControlRefusal(.alreadyCompleted)
            traceReadiness("LOCAL_CONTROL_REFUSED", operation: request.operation, error: control)
            throw control
        }
        guard let credential = keychain.get(request.providerID),
              traceBool("pre.credential_nonempty", !credential.isEmpty),
              traceBool("pre.credential_matches", request.apiKey == credential) else {
            traceReadiness("PRE_HTTP_ADMISSION_DENIED", operation: request.operation)
            throw Refusal.admission
        }
        let sequence: [ProviderReadinessOperation] = [.reachability, .authentication, .modelDiscovery, .minimalModelRequest(Self.modelID)]
        guard traceBool("sequence.ordinal_in_bounds", readinessOrdinal < sequence.count), traceBool("sequence.operation_matches", request.operation == sequence[readinessOrdinal]),
              traceBool("sequence.model_matches", request.modelID == (readinessOrdinal == 3 ? Self.modelID : nil)) else {
            let control = try localControlRefusal(.sequenceLimit)
            traceReadiness("LOCAL_CONTROL_REFUSED", operation: request.operation, error: control)
            throw control
        }
        readinessOrdinal += 1 // Consumption before await: no retry or duplicate stages.
        do {
            traceReadiness("BEFORE_TRANSPORT", operation: request.operation)
            let response = try await URLSessionProviderReadinessTransport(session: session, canProduceLiveEvidence: true,
                requestURLPolicy: Self.normalizeOfficialRequest,
                ownedMMOutboundLedger: outboundAudit).send(request)
            traceReadiness("HTTP_RESPONSE", operation: request.operation, status: response.statusCode, category: response.errorCategory)
            guard traceBool("post.intact", intact) else {
                readinessFailed = true; throw Refusal.admission
            }
            guard traceBool("post.HTTP_2xx", (200..<300).contains(response.statusCode)), traceBool("post.no_error_category", response.errorCategory == nil) else {
                readinessFailed = true
                throw ReadinessHTTPFailure(statusCode: response.statusCode, errorCategory: response.errorCategory)
            }
            if request.operation == .modelDiscovery, !response.modelIDs.contains(Self.modelID) {
                readinessFailed = true; throw Refusal.readiness
            }
            if readinessOrdinal == 4 { readinessComplete = true }
            auditSucceeded = true
            return response
        } catch {
            traceReadiness("TRANSPORT_OR_RESPONSE_FAILURE", operation: request.operation, error: error)
            readinessFailed = true; throw error
        }
    }

    private func currentCustomReceipt(record: EnvVarEntry, for chat: ChatStore) -> ChatModelPickerApplyReceipt? {
        guard self.chat === chat, intact, readinessComplete, !visualConsumed,
              record.id == recordID, record.name == DeepSeekProviderContract.apiKeyEnvironmentVariable,
              settings?.providerRecords.first(where: { $0.id == record.id }) == record,
              record.isSecret, record.valueInKeychain,
              record.baseURL == DeepSeekProviderContract.baseURL, record.protocolType == .openaiCompatible,
              record.modelNames == [Self.modelID],
              chat.selectedCustomProvider?.id == record.id, chat.selectedModelID == Self.modelID,
              chat.selectedReadinessProviderID.map(ProviderReadinessRevision.canonicalProviderID)
                == ProviderReadinessRevision.canonicalProviderID(record.name),
              let id = chat.activeSessionID, id != startupSession,
              visualSession == nil || visualSession == id,
              chat.messages.filter({ $0.role == .user }).count <= 1,
              let receipt = chat.chatModelPickerReceipt(providerID: record.name, modelID: Self.modelID),
              receipt.providerID == ProviderReadinessRevision.canonicalProviderID(record.name),
              receipt.modelID == Self.modelID, receipt.isApplied,
              receipt.evidenceID.hasPrefix("live-settings:"), !receipt.applyReceiptID.isEmpty,
              chat.lastChatModelApplyReceipt == receipt else { return nil }
        return receipt
    }
    func customMediaModel(record: EnvVarEntry, modelID: String, for chat: ChatStore) -> LLMModel? {
        guard modelID == Self.modelID, currentCustomReceipt(record: record, for: chat) != nil else { return nil }
        return LLMModel(id: Self.modelID, displayName: Self.modelID, provider: record.name)
            .withModalityOverride(Self.verifiedModalities)
    }
    func freezeCustom(record: EnvVarEntry, config: ProviderConfig, model: LLMModel,
                      for chat: ChatStore) throws -> MM01ProviderConstruction? {
        guard record.id == recordID else { return nil } // Ordinary custom rows keep their existing route.
        guard let receipt = currentCustomReceipt(record: record, for: chat),
              config.providerType == .openAI, config.runtimeProviderID == record.name,
              config.customBaseURL == record.baseURL, !config.appendV1Suffix, !config.controlledFieldLoopbackOnly,
              model.id == Self.modelID, model.provider == record.name,
              let credential = config.apiKey, !credential.isEmpty, keychain.get(record.name) == credential,
              let resolved = customMediaModel(record: record, modelID: model.id, for: chat),
              let id = chat.activeSessionID else { throw Refusal.admission }
        visualSession = id; visualProviderID = record.name; visualApplyReceiptID = receipt.applyReceiptID
        return MM01ProviderConstruction(lane: self, session: session, credential: credential,
            model: resolved, sessionID: id, runtimeProviderID: record.name, outboundAudit: outboundAudit)
    }
    func admits(_ provider: any LLMProvider) -> Bool {
        guard intact, readinessComplete, let wrapped = provider as? MM01FieldProvider,
              wrapped.lane === self, wrapped.configurationIsIntact, wrapped.model.id == Self.modelID,
              wrapped.sessionID == visualSession, wrapped.name == visualProviderID, !visualConsumed else { return false }
        return true
    }
    private func currentVisualReceipt(for chat: ChatStore) -> ChatModelPickerApplyReceipt? {
        guard self.chat === chat, intact, readinessComplete, !visualConsumed,
              let id = chat.activeSessionID, id == visualSession, id != startupSession,
              chat.selectedCustomProvider?.id == recordID,
              chat.selectedModelID == Self.modelID,
              let providerID = chat.selectedReadinessProviderID,
              ProviderReadinessRevision.canonicalProviderID(providerID)
                == ProviderReadinessRevision.canonicalProviderID(DeepSeekProviderContract.apiKeyEnvironmentVariable),
              visualProviderID == DeepSeekProviderContract.apiKeyEnvironmentVariable,
              let receipt = chat.chatModelPickerReceipt(providerID: providerID, modelID: Self.modelID),
              receipt.providerID == ProviderReadinessRevision.canonicalProviderID(providerID),
              receipt.modelID == Self.modelID, receipt.isApplied,
              receipt.evidenceID.hasPrefix("live-settings:"), receipt.applyReceiptID == visualApplyReceiptID,
              chat.lastChatModelApplyReceipt == receipt else { return nil }
        return receipt
    }
    /// Mint only for the real pre-append Composer turn, never a generic prompt hash.
    func agentScenario(for chat: ChatStore, provider: any LLMProvider,
                       executionIdentity: AgentExecutionIdentity) throws -> MM01AgentScenarioContract {
        guard self.chat === chat, admits(provider), let id = chat.activeSessionID,
              id == visualSession, id != startupSession, agentScenarioBinding == nil,
              executionIdentity.isValid, executionIdentity.attempt == 1,
              executionIdentity.turn.sessionID == id.uuidString,
              executionIdentity.operationID == "chat:\(executionIdentity.turn.sessionID):\(executionIdentity.turn.turnID):\(executionIdentity.turn.messageID)",
              UUID(uuidString: executionIdentity.turn.messageID)?.uuidString == executionIdentity.turn.messageID,
              chat.messages.allSatisfy({ $0.role == .assistant && ChatStore.isWelcomeText($0.content) && $0.attachments.isEmpty }),
              let receipt = currentVisualReceipt(for: chat),
              receipt.evidenceID.hasPrefix("live-settings:"), !receipt.applyReceiptID.isEmpty else { throw Refusal.admission }
        try outboundAudit?.validate(OwnedMMOutboundContext.action, phase: .visual)
        let nonce = UUID()
        agentScenarioBinding = AgentScenarioBinding(nonce: nonce, sessionID: id,
            applyReceiptID: receipt.applyReceiptID, executionIdentity: executionIdentity,
            outboundAction: OwnedMMOutboundContext.action)
        return MM01AgentScenarioContract(nonce: nonce, sessionID: id.uuidString,
            applyReceiptID: receipt.applyReceiptID, executionIdentity: executionIdentity,
            bindPrepared: { [weak self] prompt, identity in
                guard let self else { throw Refusal.admission }
                try self.bindAgentScenario(nonce: nonce, finalSystemPrompt: prompt, executionIdentity: identity)
            })
    }
    private func bindAgentScenario(nonce: UUID, finalSystemPrompt: String,
                                   executionIdentity: AgentExecutionIdentity) throws {
        guard intact, readinessComplete, !visualConsumed, var binding = agentScenarioBinding,
              binding.nonce == nonce, !binding.prepared,
              binding.executionIdentity == executionIdentity,
              chat?.activeSessionID == binding.sessionID,
              chat?.activeExecutionIdentity(for: binding.sessionID) == executionIdentity,
              let chat, let receipt = currentVisualReceipt(for: chat),
              receipt.applyReceiptID == binding.applyReceiptID,
              Data(finalSystemPrompt.utf8) == Data(MM01AgentScenarioContract.approvedSystemPrompt.utf8),
              finalSystemPrompt.utf8.count == MM01AgentScenarioContract.approvedPromptUTF8Length,
              SHA256.hash(data: Data(finalSystemPrompt.utf8)).map({ String(format: "%02x", $0) }).joined()
                == MM01AgentScenarioContract.approvedPromptSHA256 else { throw Refusal.admission }
        binding.prepared = true
        agentScenarioBinding = binding
    }
    func consumeVisual(sessionID: UUID, model: LLMModel, messages: [LLMMessage],
                       systemPrompt: String?, maxTokens: Int) throws {
        guard intact, readinessComplete, !visualConsumed, visualSession == sessionID,
              chat?.activeSessionID == sessionID, model.id == Self.modelID,
              model.provider == visualProviderID,
              let receiptProviderID = chat?.selectedReadinessProviderID,
              let receipt = chat?.chatModelPickerReceipt(providerID: receiptProviderID, modelID: Self.modelID),
              receipt.applyReceiptID == visualApplyReceiptID,
              chat?.lastChatModelApplyReceipt == receipt else { throw Refusal.admission }
        guard let binding = agentScenarioBinding, binding.prepared,
              binding.sessionID == sessionID, let chat,
              chat.activeExecutionIdentity(for: sessionID) == binding.executionIdentity,
              let receipt = currentVisualReceipt(for: chat),
              receipt.applyReceiptID == binding.applyReceiptID,
              let systemPrompt, Data(systemPrompt.utf8) == Data(MM01AgentScenarioContract.approvedSystemPrompt.utf8),
              systemPrompt.utf8.count == MM01AgentScenarioContract.approvedPromptUTF8Length,
              SHA256.hash(data: Data(systemPrompt.utf8)).map({ String(format: "%02x", $0) }).joined()
                == MM01AgentScenarioContract.approvedPromptSHA256,
              (1...256).contains(maxTokens),
              chat.messages.filter({ $0.role == .user }).count == 1,
              let actualUser = chat.messages.first(where: { $0.role == .user }),
              actualUser.id.uuidString == binding.executionIdentity.turn.messageID,
              [Self.prompt, Self.assembledPrompt].contains(actualUser.content), actualUser.toolCalls.isEmpty,
              actualUser.attachments.count == 1, let actualImage = actualUser.attachments.first,
              actualImage.kind == .image, actualImage.status == .ready,
              actualImage.fileName == "标准几何图.png", actualImage.mimeType == "image/png",
              let actualBytes = actualImage.data,
              SHA256.hash(data: actualBytes).map({ String(format: "%02x", $0) }).joined() == Self.imageSHA256
              else { throw Refusal.admission }
        let users = messages.filter { $0.role == .user }
        guard users.count == 1, [Self.prompt, Self.assembledPrompt].contains(users[0].content), users[0].images.count == 1,
              messages.allSatisfy({ $0.audios.isEmpty && $0.toolCalls.isEmpty && $0.role != .tool
                && ($0.role == .user || $0.images.isEmpty)
                && ($0.role == .user || ($0.role == .assistant && ChatStore.isWelcomeText($0.content))) }),
              let image = users[0].images.first, image.mimeType == "image/png",
              SHA256.hash(data: image.data).map({ String(format: "%02x", $0) }).joined() == Self.imageSHA256,
              MediaPayloadValidation.decision(data: image.data, mimeType: image.mimeType,
                capabilities: model.capabilities, wire: .openaiCompatible).isAllowed else { throw Refusal.payload }
        try outboundAudit?.validate(binding.outboundAction, phase: .visual)
        visualConsumed = true
    }
    func consumedVisualOutboundAction() throws -> OwnedMMActionTicket? {
        guard visualConsumed, let binding = agentScenarioBinding else { throw Refusal.admission }
        try outboundAudit?.validate(binding.outboundAction, phase: .visual)
        return binding.outboundAction
    }
}

final class MM01NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
struct MM01ReadinessTransport: SettingsProviderReadinessTransport {
    let lane: DeepSeekMM01FieldLane
    let canProduceLiveEvidence = true
    func send(_ request: ProviderReadinessTransportRequest) async throws -> ProviderReadinessTransportResponse {
        try await lane.sendReadiness(request)
    }
}
struct MM01ProviderConstruction: Sendable {
    let lane: DeepSeekMM01FieldLane
    let session: URLSession
    let credential: String
    let model: LLMModel
    let sessionID: UUID
    let runtimeProviderID: String
    var outboundAudit: OwnedMMOutboundLedger? = nil
    func makeProvider() -> any LLMProvider { MM01FieldProvider(construction: self) }
}
final class MM01FieldProvider: UsageRouteIdentityProviding, LLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
    let lane: DeepSeekMM01FieldLane
    let sessionID: UUID
    private let inner: OpenAICompatibleProvider
    private let outboundAudit: OwnedMMOutboundLedger?
    private let approvedModel: LLMModel
    private let approvedRuntimeProviderID: String
    private let configurationLock = NSLock()
    private var invalidated = false
    var configurationIsIntact: Bool {
        configurationLock.lock(); defer { configurationLock.unlock() }; return !invalidated
    }
    private func invalidate() { configurationLock.lock(); invalidated = true; configurationLock.unlock() }
    var usageRouteIdentity: UsageServedRoute? {
        guard let route = UsageTelemetryContext.directRoute(of: inner) else { return nil }
        return UsageServedRoute(provider: approvedRuntimeProviderID, model: route.model)
    }
    var name: String { approvedRuntimeProviderID }
    var model: LLMModel {
        get { approvedModel }
        set { if newValue != approvedModel { invalidate() } }
    }
    var capabilities: Set<ProviderCapability> { [.streaming, .vision] }
    var runtimeConfigurationMaterial: String? {
        get { DeepSeekProviderContract.baseURL + "|MM01|" + DeepSeekMM01FieldLane.capabilityFactSHA256 }
        set { if newValue != runtimeConfigurationMaterial { invalidate() } }
    }
    init(construction: MM01ProviderConstruction) {
        lane = construction.lane; sessionID = construction.sessionID; approvedModel = construction.model
        approvedRuntimeProviderID = construction.runtimeProviderID
        outboundAudit = construction.outboundAudit
        inner = OpenAICompatibleProvider(apiKey: construction.credential, model: construction.model,
            customBaseURL: "https://api.deepseek.com:443", appendV1Suffix: false,
            session: construction.session, providerName: construction.runtimeProviderID,
            ownedMMOutboundLedger: construction.outboundAudit)
        inner.useOpenRouterCompat = true // DeepSeek's actual max_tokens / stream contract.
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        var auditSucceeded = false
        defer { if !auditSucceeded { outboundAudit?.stop() } }
        guard configurationIsIntact else { throw DeepSeekMM01FieldLane.Refusal.admission }
        try await lane.consumeVisual(sessionID: sessionID, model: model, messages: messages, systemPrompt: systemPrompt, maxTokens: maxTokens)
        guard configurationIsIntact else { throw DeepSeekMM01FieldLane.Refusal.admission }
        if let ticket = try await lane.consumedVisualOutboundAction() {
            let result = try await OwnedMMOutboundContext.$action.withValue(ticket) {
                try await inner.sendMessage(messages: messages, systemPrompt: systemPrompt, maxTokens: maxTokens, temperature: temperature)
            }
            auditSucceeded = true
            return result
        }
        auditSucceeded = true
        return try await inner.sendMessage(messages: messages, systemPrompt: systemPrompt, maxTokens: maxTokens, temperature: temperature)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition], maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        guard tools.isEmpty else { throw DeepSeekMM01FieldLane.Refusal.payload }
        return try await sendMessage(messages: messages, systemPrompt: systemPrompt, maxTokens: maxTokens, temperature: temperature)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        var auditSucceeded = false
        defer { if !auditSucceeded { outboundAudit?.stop() } }
        guard configurationIsIntact else { throw DeepSeekMM01FieldLane.Refusal.admission }
        try await lane.consumeVisual(sessionID: sessionID, model: model, messages: messages, systemPrompt: systemPrompt, maxTokens: maxTokens)
        guard configurationIsIntact else { throw DeepSeekMM01FieldLane.Refusal.admission }
        if let ticket = try await lane.consumedVisualOutboundAction() {
            let result = try await OwnedMMOutboundContext.$action.withValue(ticket) {
                try await inner.streamMessage(messages: messages, systemPrompt: systemPrompt, maxTokens: maxTokens, temperature: temperature)
            }
            auditSucceeded = true
            return result
        }
        auditSucceeded = true
        return try await inner.streamMessage(messages: messages, systemPrompt: systemPrompt, maxTokens: maxTokens, temperature: temperature)
    }
}
