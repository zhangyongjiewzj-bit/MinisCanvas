import Foundation
import MinisCore

/// An explicit tool event, never inferred from an ordinary message or a
/// redacted external-session summary. The registered App source is the actor;
/// these fields identify the event within its currently admitted attempt.
struct ExternalMemoryProposalToolEventV2: Decodable, Sendable {
    let schemaVersion: Int
    let type: String
    let sourceEventID: String
    let threadID: String
    let turnID: String
    let factText: String

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 8_192,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set([
                "schemaVersion", "type", "sourceEventID", "threadID", "turnID", "factText"
              ]) else { throw ExternalMemoryProposalError.invalidEvent }
        let event = try JSONDecoder().decode(Self.self, from: data)
        guard event.schemaVersion == 2,
              event.type == "miniscanvas.memory.propose",
              validID(event.sourceEventID), validID(event.threadID), validID(event.turnID),
              !event.factText.isEmpty,
              event.factText == event.factText.trimmingCharacters(in: .whitespacesAndNewlines),
              event.factText.utf8.count <= 4_096,
              !event.factText.contains("\0"),
              ContentSecretRedactor.redact(event.factText) == event.factText else {
            throw ExternalMemoryProposalError.invalidEvent
        }
        return event
    }

    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.contains("\0")
    }
}

enum ExternalMemoryProposalError: Error, Equatable {
    case invalidEvent
    case sourceUnavailable
    case scopeMismatch
    case sourceNotEnabled
    case runtimeRejected(ExternalSessionOutputAcceptance)
    case duplicateConflict
}
