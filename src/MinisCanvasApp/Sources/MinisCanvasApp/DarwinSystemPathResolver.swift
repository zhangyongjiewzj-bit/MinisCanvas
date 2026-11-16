import Foundation

/// Resolves only Darwin's three stable system-directory aliases before the
/// descriptor-anchored walk. This is the sole production allowlist for these
/// aliases; all other configured absolute paths retain their spelling.
enum DarwinSystemPathResolver {
    /// The path admission result is deliberately typed.  Callers that need
    /// to explain a bootstrap decision can distinguish an absent descriptor
    /// from an unsafe spelling, while the legacy throwing API below remains
    /// source-compatible with DraftStore.
    enum ResolutionOutcome: Equatable, Sendable {
        case resolved(String)
        case unavailable
        case unsafe

        var path: String? {
            guard case .resolved(let path) = self else { return nil }
            return path
        }
    }

    private static let aliasRoots: [String: String] = [
        "var": "/private/var",
        "tmp": "/private/tmp",
        "etc": "/private/etc"
    ]

    static func resolve(_ directory: URL) throws -> String {
        switch resolveOutcome(directory) {
        case .resolved(let path):
            return path
        case .unavailable, .unsafe:
            // DraftStore has one intentionally secret-free public I/O error
            // for rejected path descriptors.  Keep that contract while the
            // outcome API gives isolation/bootstrap callers more precision.
            throw DraftStoreIOError.unsafe
        }
    }

    static func resolveOutcome(_ directory: URL) -> ResolutionOutcome {
        // `URL(fileURLWithPath:)` resolves a relative path against the current
        // directory when reading `path`, which would erase the caller's
        // unsafe relative spelling. Keep the URL's lexical path so that the
        // absolute-path admission check remains fail-closed.
        let configured = directory.relativePath
        guard directory.isFileURL else {
            return .unsafe
        }
        guard !configured.isEmpty else {
            return .unavailable
        }
        guard configured.hasPrefix("/"), configured != "/" else {
            return .unsafe
        }
        let components = configured.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty,
              !components.contains(where: { $0 == "." || $0 == ".." }) else {
            return .unsafe
        }

        let first = String(components[0])
        guard let aliasRoot = aliasRoots[first] else {
            return .resolved(configured)
        }
        let suffix = components.dropFirst().map(String.init).joined(separator: "/")
        return .resolved(suffix.isEmpty ? aliasRoot : "\(aliasRoot)/\(suffix)")
    }
}
