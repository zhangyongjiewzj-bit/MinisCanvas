import Foundation
import Darwin
import MinisCore
import Testing
@testable import MinisCanvasApp

@MainActor
final class B1ARCHOwnedInputs {
    let root: URL
    let defaults: UserDefaults
    let defaultsSuite: String
    let keychain: KeychainStore
    let env: EnvVarStore
    let mcp: MCPServerManager
    let skills: SkillStore
    let catalog: SkillsStore
    let scheduler: SchedulerTaskStore
    let workflows: WorkflowStore
    let badges: SessionBadgeStore
    let sessions: SessionStore
    let documents: SessionDocumentStore
    let memory: MemoryStore
    let logger: LogManager
    let readiness: ProviderReadinessStore
    let tasks: AgentTaskStore
    let context: ContextManifestStore
    init(root: URL) throws {
        self.root = root
        defaultsSuite = "B1ARCH-Owned-" + root.lastPathComponent
        defaults = try #require(UserDefaults(suiteName: defaultsSuite))
        keychain = KeychainStore(backing: InMemoryKeychainBacking())
        try #require(keychain.backingKind == .injected)
        env = EnvVarStore(directory: root.appendingPathComponent("owned-env"), keychain: keychain,
            privacyStore: EnvVarPrivacyStore(defaults: defaults))
        mcp = MCPServerManager(fileURL: root.appendingPathComponent("owned-mcp/mcps.json"), keychain: keychain)
        skills = SkillStore(skillsRoot: root.appendingPathComponent("owned-skills"))
        catalog = SkillsStore(appStore: skills,
            stateFileURL: root.appendingPathComponent("owned-skills-state.json"), loadImmediately: false)
        scheduler = SchedulerTaskStore(defaults: defaults,
            occurrenceLedgerURL: root.appendingPathComponent("owned-scheduler.json"))
        workflows = WorkflowStore(storeDirectory: root.appendingPathComponent("owned-workflows"))
        badges = SessionBadgeStore(directory: root.appendingPathComponent("owned-badges"))
        sessions = SessionStore(directory: root.appendingPathComponent("owned-sessions"))
        documents = SessionDocumentStore(directory: sessions.directory)
        memory = MemoryStore(directory: root.appendingPathComponent("owned-memory"))
        logger = LogManager(directory: root.appendingPathComponent("owned-logs"))
        readiness = ProviderReadinessStore(directory: root.appendingPathComponent("owned-readiness"))
        tasks = try AgentTaskStore(persistenceURL: root.appendingPathComponent("owned-task.json"))
        context = try ContextManifestStore(persistenceURL: root.appendingPathComponent("owned-context.json"))
    }
}

@MainActor
enum B1ARCHOriginalFixtureSupport {
    private struct Identity { let device: dev_t; let inode: ino_t; let owner: uid_t }
    private struct LinkIdentity { let identity: Identity; let destination: String }
    private static var roots: [String: Identity] = [:]
    private static var profiles: [String: Identity] = [:]
    private static var blockedProfileCleanup: [String: String] = [:]
    private static var links: [String: LinkIdentity] = [:]
    private static var ownedInputs: [String: B1ARCHOwnedInputs] = [:]
    private static func info(_ url: URL) throws -> stat {
        var s = stat(); try #require(lstat(url.path, &s) == 0); return s
    }
    private static func verify(_ url: URL, identity: Identity) throws {
        print("ARCH_VERIFY_ROOT_REQUEST path=\(url.path) expectedDevice=\(identity.device) expectedInode=\(identity.inode) expectedUID=\(identity.owner)")
        let s = try info(url)
        print("ARCH_VERIFY_ROOT_ACTUAL path=\(url.path) device=\(s.st_dev) inode=\(s.st_ino) uid=\(s.st_uid) mode=\(String(s.st_mode & 0o777, radix: 8))")
        try #require((s.st_mode & S_IFMT) == S_IFDIR && (s.st_mode & 0o777) == 0o700)
        try #require(s.st_dev == identity.device && s.st_ino == identity.inode && s.st_uid == identity.owner)
        try #require(s.st_uid == geteuid())
    }
    static func makeRoot(_ label: String, parent requested: URL? = nil) throws -> URL {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let parent = (requested ?? formal.rootDirectory).standardizedFileURL
        let canonicalFormal = formal.rootDirectory.resolvingSymlinksInPath().path
        let canonicalParent = parent.resolvingSymlinksInPath().path
        var parentBefore = stat(); errno = 0
        let parentStatus = lstat(parent.path, &parentBefore)
        let parentErrno = errno
        var rootBefore = stat(); errno = 0
        let rootStatus = lstat(formal.rootDirectory.path, &rootBefore)
        let rootErrno = errno
        let boundaryFacts: [String: String] = [
            "requestedParent": requested?.path ?? "DEFAULT_FORMAL_ROOT",
            "actualParent": parent.path, "resolvedParent": canonicalParent,
            "allowedRoot": formal.rootDirectory.path, "resolvedRoot": canonicalFormal,
            "parentLstat": String(parentStatus), "parentErrno": String(parentErrno),
            "parentDevice": String(parentBefore.st_dev), "parentInode": String(parentBefore.st_ino),
            "rootLstat": String(rootStatus), "rootErrno": String(rootErrno),
            "rootDevice": String(rootBefore.st_dev), "rootInode": String(rootBefore.st_ino)]
        print("ARCH_FIXTURE_ROOT_BOUNDARY=" + String(data: try JSONSerialization.data(withJSONObject: boundaryFacts, options: [.sortedKeys]), encoding: .utf8)!)
        try #require(canonicalParent == canonicalFormal || canonicalParent.hasPrefix(canonicalFormal + "/"))
        try FileManager().createDirectory(at: parent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let p = try info(parent)
        try #require((p.st_mode & S_IFMT) == S_IFDIR && p.st_uid == geteuid())
        try #require(UInt64(p.st_dev) == formal.rootDevice)
        let root = parent.appendingPathComponent("B1ARCH-" + label + "-" + UUID().uuidString, isDirectory: true)
        print("ARCH_OWNED_ROOT_REQUEST path=\(root.path) parentDevice=\(p.st_dev) parentInode=\(p.st_ino) parentUID=\(p.st_uid)")
        try FileManager().createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let s = try info(root)
        print("ARCH_OWNED_ROOT_OBSERVED path=\(root.path) device=\(s.st_dev) inode=\(s.st_ino) uid=\(s.st_uid) mode=\(String(s.st_mode & 0o777, radix: 8))")
        try #require((s.st_mode & S_IFMT) == S_IFDIR && (s.st_mode & 0o777) == 0o700)
        try #require(s.st_uid == geteuid() && s.st_dev == p.st_dev && s.st_ino != p.st_ino)
        roots[root.path] = Identity(device: s.st_dev, inode: s.st_ino, owner: s.st_uid)
        print("ARCH_OWNED_ROOT label=\(label) uid=\(s.st_uid) dev=\(s.st_dev) inode=\(s.st_ino) mode=700")
        return root
    }
    static func inputs(_ root: URL) throws -> B1ARCHOwnedInputs {
        if let result = ownedInputs[root.path] { return result }
        let identity = try #require(roots[root.path]); try verify(root, identity: identity)
        let result = try B1ARCHOwnedInputs(root: root); ownedInputs[root.path] = result; return result
    }
    static func cleanupRoot(_ root: URL) {
        do {
            let identity = try #require(roots[root.path]); try verify(root, identity: identity)
            if let inputs = ownedInputs.removeValue(forKey: root.path) {
                UserDefaults.standard.removePersistentDomain(forName: inputs.defaultsSuite)
            }
            try FileManager().removeItem(at: root)
            var s = stat(); errno = 0
            try #require(lstat(root.path, &s) == -1 && errno == ENOENT)
            roots.removeValue(forKey: root.path)
            print("ARCH_OWNED_ROOT_CLEANUP exactIdentity=true absent=true")
        } catch { Issue.record(error) }
    }
    static func qualifyProfile(_ profile: RuntimeIsolationProfile) throws {
        _ = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = profile.rootDirectory.standardizedFileURL
        let actualFM = FileManager().temporaryDirectory.standardizedFileURL
        print("ARCH_PROFILE_ROOT_REQUEST path=\(root.path) actualFM=\(actualFM.path)")
        let p = try info(actualFM); let immediate = try info(root.deletingLastPathComponent())
        let initial = try info(root)
        let boundaryFacts: [String: String] = ["actualProfileRoot": root.path,
            "resolvedProfileRoot": root.resolvingSymlinksInPath().path,
            "actualFMParent": actualFM.path, "actualImmediateParent": root.deletingLastPathComponent().path,
            "parentDevice": String(p.st_dev), "parentInode": String(p.st_ino),
            "rootDevice": String(initial.st_dev), "rootInode": String(initial.st_ino),
            "rootUID": String(initial.st_uid), "rootModeBefore": String(initial.st_mode & 0o777, radix: 8)]
        print("ARCH_PROFILE_ROOT_BOUNDARY=" + String(data: try JSONSerialization.data(withJSONObject: boundaryFacts, options: [.sortedKeys]), encoding: .utf8)!)
        try #require(profile.isDisposable)
        try #require(p.st_dev == immediate.st_dev && p.st_ino == immediate.st_ino)
        try #require((p.st_mode & S_IFMT) == S_IFDIR && p.st_uid == geteuid())
        try #require((initial.st_mode & S_IFMT) == S_IFDIR)
        try #require(initial.st_uid == geteuid() && initial.st_dev == p.st_dev && initial.st_ino != p.st_ino)
        try #require(root.lastPathComponent.hasPrefix("MinisCanvasAppTests-"))
        try #require(UUID(uuidString: String(root.lastPathComponent.suffix(36))) != nil)
        profiles[root.path] = Identity(device: initial.st_dev, inode: initial.st_ino, owner: initial.st_uid)
        // This root was just created by this method's original isolated factory.
        // Tighten only this verified UID/device/inode UUID child before any Root stores.
        if (initial.st_mode & 0o777) != 0o700 { try #require(chmod(root.path, 0o700) == 0) }
        let s = try info(root)
        try #require((s.st_mode & S_IFMT) == S_IFDIR && (s.st_mode & 0o777) == 0o700)
        try #require(s.st_uid == initial.st_uid && s.st_dev == initial.st_dev && s.st_ino == initial.st_ino)
        profiles[root.path] = Identity(device: s.st_dev, inode: s.st_ino, owner: s.st_uid)
        print("ARCH_PROFILE_OWNED actualFMParent=true uid=\(s.st_uid) dev=\(s.st_dev) inode=\(s.st_ino) mode=700")
    }
    static func registerOwnedLink(_ link: URL, target: URL) throws {
        print("ARCH_ALIAS_REGISTER_REQUEST path=\(link.path) parent=\(link.deletingLastPathComponent().path) target=\(target.path)")
        let parent = try info(link.deletingLastPathComponent())
        let s = try info(link)
        print("ARCH_ALIAS_REGISTER_ACTUAL path=\(link.path) parentDev=\(parent.st_dev) parentInode=\(parent.st_ino) parentUID=\(parent.st_uid) linkDev=\(s.st_dev) linkInode=\(s.st_ino) linkUID=\(s.st_uid) linkType=\(s.st_mode & S_IFMT)")
        try #require((s.st_mode & S_IFMT) == S_IFLNK && s.st_uid == geteuid())
        let destination = try FileManager().destinationOfSymbolicLink(atPath: link.path)
        try #require(destination == target.path)
        links[link.path] = LinkIdentity(identity: Identity(device: s.st_dev, inode: s.st_ino, owner: s.st_uid), destination: destination)
    }
    // A failed owned-server stop/join must retain its profile, even if later
    // cleanup defers run. There is deliberately no automatic unblock/retry.
    static func blockProfileCleanup(_ profile: RuntimeIsolationProfile, reason: String) {
        let root = profile.rootDirectory.standardizedFileURL
        blockedProfileCleanup[root.path] = reason
        print("ARCH_PROFILE_CLEANUP_BLOCKED path=\(root.path) reason=\(reason) retained=true")
    }
    static func cleanupProfile(_ profile: RuntimeIsolationProfile) {
        do {
            let root = profile.rootDirectory.standardizedFileURL
            if let reason = blockedProfileCleanup[root.path] {
                Issue.record("owned HTTP fixture did not join; profile retained: \(reason)")
                return
            }
            let identity = try #require(profiles[root.path]); try verify(root, identity: identity)
            for path in links.keys.sorted() {
                let expected = try #require(links[path]); let url = URL(fileURLWithPath: path)
                let registeredParentURL = url.deletingLastPathComponent()
                let registeredParent = try info(registeredParentURL)
                let belongsToRoot = registeredParent.st_dev == identity.device
                    && registeredParent.st_ino == identity.inode && registeredParent.st_uid == identity.owner
                print("ARCH_ALIAS_PARENT_MATCH path=\(path) parent=\(registeredParentURL.path) parentDev=\(registeredParent.st_dev) parentInode=\(registeredParent.st_ino) parentUID=\(registeredParent.st_uid) rootDev=\(identity.device) rootInode=\(identity.inode) rootUID=\(identity.owner) samePhysicalParent=\(belongsToRoot)")
                guard belongsToRoot else { continue }
                try #require((registeredParent.st_mode & S_IFMT) == S_IFDIR)
                let s = try info(url)
                try #require((s.st_mode & S_IFMT) == S_IFLNK && s.st_dev == expected.identity.device && s.st_ino == expected.identity.inode && s.st_uid == expected.identity.owner)
                try #require(try FileManager().destinationOfSymbolicLink(atPath: path) == expected.destination)
                print("ARCH_ALIAS_UNLINK_VERIFIED path=\(path) linkDev=\(s.st_dev) linkInode=\(s.st_ino) linkUID=\(s.st_uid) target=\(expected.destination)")
                try #require(unlink(path) == 0); links.removeValue(forKey: path)
            }
            try profile.cleanupDisposableRoots()
            var s = stat(); errno = 0
            try #require(lstat(root.path, &s) == -1 && errno == ENOENT)
            profiles.removeValue(forKey: root.path)
            print("ARCH_PROFILE_CLEANUP exactIdentity=true ownedLinksUnlinkedBeforeTreeCleanup=true absent=true")
        } catch { Issue.record(error) }
    }
}
