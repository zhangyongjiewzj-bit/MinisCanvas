import Foundation

/// Tool-name constants shared by the read tool, the send tool and the
/// approval/registration wiring, so none of them depends on another's file.
enum ExternalSessionToolNames {
    static let read = "external_session_read"
    static let send = "external_session_send"
}
