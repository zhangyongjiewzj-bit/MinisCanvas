/// Declared reasoning limits for model IDs with a verified catalog bound.
/// An undeclared ID returns `nil`; callers apply their own fallback.
public enum ThinkingLevelCatalog {
    public static func declaredMaxLevel(for modelID: String) -> ThinkingLevel? {
        modelID.lowercased().hasPrefix("claude-opus-4") ? .max : nil
    }
}
