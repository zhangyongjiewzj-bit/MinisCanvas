import Foundation

// MARK: - MemoryCategory

/// Classification of a persisted memory fact.
///
/// Categories let the memory layer group facts by intent so the UI can
/// summarize memory usage per category and search can filter by kind.
/// Persisted as a raw string; unknown/absent values fall back to `.fact`
/// (see `MemoryFact`'s decoding).
public enum MemoryCategory: String, Codable, CaseIterable, Hashable, Sendable {
    /// User preference (likes, dislikes, habits, style choices).
    case userPref
    /// Security / privacy related facts (credentials hints, safe practices).
    case security
    /// Lessons learned (what worked, what failed, how to do things).
    case lesson
    /// General fact — the default for facts captured without a category.
    case fact

    /// Human-readable (Chinese) label for UI display.
    public var label: String {
        switch self {
        case .userPref: return "用户偏好"
        case .security: return "安全"
        case .lesson: return "经验教训"
        case .fact: return "一般事实"
        }
    }
}
