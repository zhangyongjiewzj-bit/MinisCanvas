import Foundation

/// Created only by the trusted-root loader, never from user/tool prompt text.
public struct TrustedProjectInstructionSnapshot: Sendable, Equatable {
    public let systemPromptPrefix: String
    public let loadedRelativePaths: [String]
    /// Hashes of the exact file bytes used to build this frozen snapshot.
    public let sourceFileSHA256: [String: String]
    public let rootDirectoryIdentity: String?

    init(systemPromptPrefix: String, loadedRelativePaths: [String],
         sourceFileSHA256: [String: String] = [:], rootDirectoryIdentity: String? = nil) {
        self.systemPromptPrefix = systemPromptPrefix
        self.loadedRelativePaths = loadedRelativePaths
        self.sourceFileSHA256 = sourceFileSHA256
        self.rootDirectoryIdentity = rootDirectoryIdentity
    }

    /// Apply the same credential redaction as the parent prompt without
    /// reconstructing authority from the resulting prompt text.
    public func redactingText(_ redact: (String) -> String) -> Self {
        Self(systemPromptPrefix: redact(systemPromptPrefix), loadedRelativePaths: loadedRelativePaths,
             sourceFileSHA256: sourceFileSHA256, rootDirectoryIdentity: rootDirectoryIdentity)
    }

    public func appendingChildPrompt(_ prompt: String?) -> String {
        guard let prompt, !prompt.isEmpty else { return systemPromptPrefix }
        return systemPromptPrefix + "\n\n" + prompt
    }
}

/// Scoped to the admitted parent turn. Orchestrators freeze this value before
/// dispatch, including background dispatch; model arguments never populate it.
public enum TrustedProjectInstructionContext {
    @TaskLocal public static var current: TrustedProjectInstructionSnapshot?
}
