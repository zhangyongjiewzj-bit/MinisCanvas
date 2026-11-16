import Foundation

/// A locally recorded obstacle that requires the user's input.
public struct ConversationGoalBlocker: Codable, Hashable, Sendable {
    public let summary: String
    public let reason: String
    public let options: [String: String]
    public let userAction: String

    public init?(summary: String, reason: String, options: [String: String], userAction: String) {
        let summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let userAction = userAction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty, !reason.isEmpty, !userAction.isEmpty, !options.isEmpty,
              options.allSatisfy({
                  !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                  !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }) else { return nil }
        self.summary = summary
        self.reason = reason
        self.options = options
        self.userAction = userAction
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        guard let blocker = try Self(
            summary: fields.decode(String.self, forKey: .summary),
            reason: fields.decode(String.self, forKey: .reason),
            options: fields.decode([String: String].self, forKey: .options),
            userAction: fields.decode(String.self, forKey: .userAction)
        ) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid persisted goal blocker")
            )
        }
        self = blocker
    }
}
