import Darwin
import Foundation

/// Opt-in packaged-field producer for the real transcript scroll journey.
/// The operator releases each assistant row with an empty, owner-only marker
/// after parking the ordinary ContentView at a history position. No transcript
/// file or view state is fabricated by this fixture.
enum ChatScrollAsyncFieldFixture {
    static let activationArgument = "--chat-scroll-append-fixture"
    static let targetTitle = "S1566 琥珀会话"

    enum Release: Equatable {
        case waiting
        case appended
        case alreadyConsumed
        case refused
    }

    static func isRequested(
        profile: RuntimeIsolationProfile,
        sessionFieldJourney: Bool,
        arguments: [String] = CommandLine.arguments
    ) -> Bool {
        let count = arguments.filter { $0 == activationArgument }.count
        guard count > 0 else { return false }
        precondition(count == 1, "Chat scroll field fixture activation must be unique")
        precondition(profile.mode == .packagedField && sessionFieldJourney,
                     "Chat scroll field fixture requires the Session packaged-field journey")
        return true
    }

    static func readyName(for step: Int) -> String { "chat-scroll-step-\(step).ready" }
    static func consumedName(for step: Int) -> String { "chat-scroll-step-\(step).consumed" }

    /// `openat` keeps both fixed marker names under the same validated 0700
    /// root descriptor. A symlink, nonempty marker or foreign owner refuses.
    @MainActor
    static func releaseIfReady(
        step: Int,
        targetSessionID: UUID,
        profile: RuntimeIsolationProfile,
        chat: ChatStore
    ) -> Release {
        guard (1...3).contains(step), profile.mode == .packagedField,
              let identity = profile.disposableRootIdentity else { return .refused }
        do { try profile.validateDisposableRootIdentity() }
        catch { return .refused }
        let rootFD = Darwin.open(
            profile.rootDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootFD >= 0 else { return .refused }
        defer { _ = Darwin.close(rootFD) }
        var rootInfo = stat()
        guard fstat(rootFD, &rootInfo) == 0,
              UInt64(rootInfo.st_dev) == identity.device,
              UInt64(rootInfo.st_ino) == identity.inode,
              rootInfo.st_uid == geteuid(),
              rootInfo.st_mode & 0o777 == 0o700 else { return .refused }

        let consumed = markerState(
            consumedName(for: step), in: rootFD, device: identity.device
        )
        switch consumed {
        case .valid: return .alreadyConsumed
        case .invalid: return .refused
        case .missing: break
        }
        switch markerState(readyName(for: step), in: rootFD, device: identity.device) {
        case .missing: return .waiting
        case .invalid: return .refused
        case .valid: break
        }
        guard chat.sessions.contains(where: { $0.id == targetSessionID }) else {
            return .refused
        }
        // Claim before the production append. A crash can leave an incomplete
        // field trial, but a restart cannot duplicate a previously released row.
        let claimFD = Darwin.openat(
            rootFD, consumedName(for: step),
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600
        )
        guard claimFD >= 0 else { return .refused }
        _ = Darwin.close(claimFD)
        return chat.appendAssistant(
            "MC2314 异步助手消息 \(step)：隔离现场滚动计数。",
            toSession: targetSessionID
        ) ? .appended : .refused
    }

    @MainActor
    static func run(profile: RuntimeIsolationProfile, chat: ChatStore) async {
        guard profile.mode == .packagedField else { return }
        let matches = chat.sessions.filter { $0.title == targetTitle }
        guard matches.count == 1 else { return }
        let targetID = matches[0].id
        for step in 1...3 {
            stage: while !Task.isCancelled {
                switch releaseIfReady(
                    step: step, targetSessionID: targetID, profile: profile, chat: chat
                ) {
                case .appended, .alreadyConsumed: break stage
                case .refused: return
                case .waiting:
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }
        }
    }

    private enum MarkerState { case missing, valid, invalid }

    private static func markerState(
        _ name: String, in rootFD: Int32, device: UInt64
    ) -> MarkerState {
        var info = stat()
        guard fstatat(rootFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            return errno == ENOENT ? .missing : .invalid
        }
        guard info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o777 == 0o600,
              info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_size == 0, UInt64(info.st_dev) == device else {
            return .invalid
        }
        return .valid
    }
}
