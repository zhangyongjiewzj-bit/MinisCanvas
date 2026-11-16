import Foundation

/// Optional mutable configuration identity used to bind a provider instance
/// to one frozen runtime route. Conformers own the material they expose.
public protocol ProviderRuntimeConfigurationIdentity: AnyObject {
    var runtimeConfigurationMaterial: String? { get set }
}

/// One provider endpoint selected for a conversation turn.
///
/// The model and capabilities describe the active wire implementation. Callers
/// use them to bind a frozen route; they are not inferred from a model name.
public protocol LLMProvider {
    var name: String { get }
    var model: LLMModel { get set }
    var capabilities: Set<ProviderCapability> { get }

    nonisolated(nonsending) func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse

    nonisolated(nonsending) func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse

    nonisolated(nonsending) func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error>
}

public extension LLMProvider {
    /// Existing providers may implement the text calls without an explicit
    /// capability declaration. An absent declaration grants no optional wire
    /// operation; concrete providers advertise only operations they execute.
    var capabilities: Set<ProviderCapability> { [] }

    /// This fallback preserves ordinary requests when no tools are offered.
    /// A provider that supports native tool calls implements this requirement
    /// itself, so existential dispatch sends non-empty schemas to that wire.
    nonisolated(nonsending) func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        guard tools.isEmpty else {
            throw LLMError.unsupportedCapability(.tools)
        }
        return try await sendMessage(
            messages: messages,
            systemPrompt: systemPrompt,
            maxTokens: maxTokens,
            temperature: temperature
        )
    }
}
