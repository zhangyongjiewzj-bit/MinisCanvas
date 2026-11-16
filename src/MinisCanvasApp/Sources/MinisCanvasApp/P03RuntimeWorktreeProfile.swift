import Foundation
import MinisCore

/// The sole production adapter captures the already resolved App profile.
/// It selects storage only; the child allocation still needs its exact grant.
struct P03RuntimeWorktreeProfile: GitChildWorktreeRuntimeProfile {
    private let profile: RuntimeIsolationProfile

    init(profile: RuntimeIsolationProfile) {
        self.profile = profile
    }

    var worktreeProfileIsDisposable: Bool { profile.isDisposable }
    var worktreeProfileIsBlocked: Bool { profile.mode == .blocked }

    func validatedWorktreeProfileHome() throws -> URL {
        guard profile.mode != .blocked else {
            throw RuntimeIsolationProfile.IsolationError.invalidDisposableRoot
        }
        if profile.isDisposable {
            try profile.validateDisposableRootIdentity()
            return profile.rootDirectory
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}
