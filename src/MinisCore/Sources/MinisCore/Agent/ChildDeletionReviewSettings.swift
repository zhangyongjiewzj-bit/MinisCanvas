import Foundation

/// Goal18 CHILD-DELETE-AUTO: user-owned settings for the optional independent
/// review of child-task `file_delete` approvals.
///
/// This type only normalizes the persisted user choice and turns it into the
/// existing `ChildDeletionReviewConfiguration`. It never widens what a child may
/// do: the reviewer itself still falls back to the human approval UI outside the
/// whitelist, for permission/sensitive files, without a verified checkpoint, or
/// when the independent classifier is unsure/fails/times out.
public enum ChildDeletionReviewSettings {
    /// Upper bound that keeps the persisted list reviewable by a human.
    public static let maxWhitelistDirectories = 20

    /// Filesystem-free normalization used at the persistence boundary
    /// (init/decode/encode): absolute paths only, standardized, no control
    /// characters, no filesystem root, de-duplicated in first-seen order and
    /// capped. Symlink resolution and existence are checked separately, at add
    /// time (`canonicalDirectory`) and again at use time (`configuration`).
    public static func normalizedWhitelist(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in paths {
            guard let path = normalizedPath(raw), seen.insert(path).inserted else { continue }
            result.append(path)
            if result.count == maxWhitelistDirectories { break }
        }
        return result
    }

    static func normalizedPath(_ raw: String) -> String? {
        guard raw.hasPrefix("/"),
              !raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        let path = URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL.path
        return path == "/" ? nil : path
    }

    // MARK: broad / protected directories

    /// System roots refused together with their whole subtree (lower-cased).
    /// `/etc` also covers `/private/etc` (see `pathForms`). `/usr/local` and
    /// below is the one carve-out (`subtreeExemptions`).
    private static let broadSystemSubtrees: [String] = [
        "/system", "/library", "/applications", "/usr", "/bin", "/sbin", "/etc", "/opt"
    ]
    private static let subtreeExemptions: [String] = ["/usr/local"]

    /// `/Volumes` itself and each volume root (`/Volumes/<name>`) are refused;
    /// project folders deeper on an external drive stay usable.
    private static func isVolumesRootOrMount(_ form: String) -> Bool {
        guard form == "/volumes" || form.hasPrefix("/volumes/") else { return false }
        return form.split(separator: "/").count <= 2
    }

    /// Exact-match system directories (the `/private`-aliased spelling of each is also tried through
    /// `pathForms`; the clean-room boundary test keeps system alias literals out of production sources):
    /// only the directory itself is refused,
    /// never its children, because the per-user temporary directory lives
    /// below `/private/var`.
    private static let broadSystemExact: Set<String> = [
        "/var", "/private", "/tmp", "/private/var"
    ]

    private static func isInSubtree(_ form: String, _ root: String) -> Bool {
        form == root || form.hasPrefix(root + "/")
    }

    private static func pathForms(_ path: String) -> [String] {
        let lowered = path.lowercased()
        var forms = [lowered]
        if lowered == "/private" || lowered.hasPrefix("/private/") {
            forms.append(String(lowered.dropFirst("/private".count)))
        } else {
            forms.append("/private" + lowered)
        }
        return forms.filter { !$0.isEmpty }
    }

    private static func homeForms(_ home: String) -> [String] {
        let url = URL(fileURLWithPath: home, isDirectory: true)
        var result: [String] = []
        for candidate in [url.standardizedFileURL.path, url.resolvingSymlinksInPath().standardizedFileURL.path] {
            for form in pathForms(candidate) where !result.contains(form) { result.append(form) }
        }
        return result
    }

    /// Why a real directory path is too broad or protected to be a deletion
    /// whitelist root (nil = acceptable). Case-insensitive (APFS). `home` is
    /// injectable for tests.
    public static func broadDirectoryReason(_ realPath: String, home: String = NSHomeDirectory()) -> String? {
        let forms = pathForms(realPath)
        if forms.contains(where: { broadSystemExact.contains($0) || isVolumesRootOrMount($0) }) {
            return "系统目录范围过宽"
        }
        for form in forms where broadSystemSubtrees.contains(where: { isInSubtree(form, $0) })
            && !subtreeExemptions.contains(where: { isInSubtree(form, $0) }) {
            return "系统目录（含其子目录）不可加入"
        }
        let homes = homeForms(home)
        for form in forms {
            for h in homes {
                if form == "/" || form == h || h.hasPrefix(form + "/") { return "家目录或其上级目录范围过宽" }
            }
        }
        for h in homes {
            let library = h + "/library"
            let support = library + "/application support"
            if forms.contains(where: { isInSubtree($0, library) }) { return "用户资源库目录（含其子目录）不可加入" }
            for name in ["minisCanvas", "minisCore"] {
                let appData = support + "/" + name.lowercased()
                if forms.contains(where: { $0 == appData || $0.hasPrefix(appData + "/") }) {
                    return "MinisCanvas 自身数据目录不可加入"
                }
            }
        }
        return nil
    }

    public enum DirectoryCheck: Equatable {
        case accepted(String)
        case notADirectory
        case tooBroad(String)
    }

    /// Add-time check: canonical real directory that is not too broad/protected.
    public static func checkedDirectory(_ url: URL, home: String = NSHomeDirectory()) -> DirectoryCheck {
        guard let canonical = canonicalDirectory(url) else { return .notADirectory }
        if let reason = broadDirectoryReason(canonical, home: home) { return .tooBroad(reason) }
        return .accepted(canonical)
    }

    public enum EntryStatus: Equatable {
        case usable(String)
        case stale(String)
    }

    /// Use-time status of a stored entry (also drives the "已失效" list state).
    public static func entryStatus(_ stored: String, home: String = NSHomeDirectory()) -> EntryStatus {
        guard let real = canonicalDirectory(path: stored) else { return .stale("目录不存在或不再是目录") }
        guard real == stored else { return .stale("目录已被替换为符号链接或移动") }
        if let reason = broadDirectoryReason(real, home: home) { return .stale(reason) }
        return .usable(real)
    }

    /// Add-time canonicalization: an existing directory with symlinks resolved.
    /// Returns nil for files, missing paths, non-file URLs and the filesystem root.
    public static func canonicalDirectory(_ url: URL) -> String? {
        guard url.isFileURL else { return nil }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return normalizedPath(resolved.path)
    }

    public static func canonicalDirectory(path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        return canonicalDirectory(URL(fileURLWithPath: path, isDirectory: true))
    }

    /// Effective configuration for NEW production attachments. Off (the
    /// `ChildDeletionReviewConfiguration` default) unless the user enabled it.
    /// A stored directory is used only while it is still the same real,
    /// existing directory; one that became a symlink, moved or vanished is
    /// dropped so the request falls back to the human approval UI.
    public static func configuration(
        from agent: AgentSettings,
        timeout: TimeInterval = 10,
        home: String = NSHomeDirectory(),
        onDropped: ((_ reason: String) -> Void)? = nil
    ) -> ChildDeletionReviewConfiguration {
        guard agent.childDeletionAutoReviewEnabled else { return ChildDeletionReviewConfiguration() }
        let roots = agent.childDeletionAutoReviewWhitelist.compactMap { stored -> URL? in
            switch entryStatus(stored, home: home) {
            case .stale(let reason):
                onDropped?(reason)
                return nil
            case .usable(let real):
                // `real` is already the resolved real path. Build the URL without a
                // filesystem-dependent trailing slash, in the same form the reviewer's
                // own fixtures use, because the reviewer requires
                // `root == root.resolvingSymlinksInPath()` (URL equality).
                return URL(fileURLWithPath: real, isDirectory: false).standardizedFileURL
            }
        }
        return ChildDeletionReviewConfiguration(enabled: true, whitelistDirectories: roots, timeout: timeout)
    }
}
