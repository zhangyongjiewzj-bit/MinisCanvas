import Foundation

/// A requested reasoning level; model-specific availability belongs to its own catalog.
public enum ThinkingLevel: String, Codable, Hashable, CaseIterable, Comparable, Sendable {
    case off, low, medium, high, xhigh, max, ultra

    public var displayName: String {
        switch self {
        case .off: return "Off"
        case .low: return "Low"
        case .medium: return "Med"
        case .high: return "High"
        case .xhigh: return "XHigh"
        case .max: return "Max"
        case .ultra: return "Ultra"
        }
    }

    public var isEnabled: Bool { self != .off }

    public static func decoded(_ value: String) -> Self {
        Self(rawValue: value) ?? .xhigh
    }

    private var rank: Int {
        switch self {
        case .off: return 0
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        case .xhigh: return 4
        case .max: return 5
        case .ultra: return 6
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}
