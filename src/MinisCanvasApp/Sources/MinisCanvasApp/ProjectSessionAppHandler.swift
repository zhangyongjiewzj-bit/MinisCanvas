import AppKit
import CryptoKit
import Darwin
import Foundation
import MinisCore

/// App-only navigation fact. The transcript contains only a short, harmless
/// announcement; these identities are held by the digest-fenced App sidecar.
struct SessionReferenceCard: Codable, Equatable, Sendable, Identifiable {
    enum Status: String, Codable, Sendable {
        case running, succeeded, failed, unavailable

        var displayTitle: String {
            switch self {
            case .running: return "运行中"
            case .succeeded: return "已完成"
            case .failed: return "失败"
            case .unavailable: return "不可用"
            }
        }
    }

    let id: String
    let sourceSessionID: String
    let targetSessionID: String
    let taskID: String
    let runID: String
    let projectID: String
    let projectTitle: String
    let title: String
    let createdAt: Date
    var status: Status

    var deepLink: URL? { URL(string: "miniscanvas://session/\(targetSessionID)") }
    var isStructurallyValid: Bool {
        UUID(uuidString: id) != nil && UUID(uuidString: sourceSessionID) != nil
            && UUID(uuidString: targetSessionID) != nil
            && !taskID.isEmpty && !runID.isEmpty && !projectID.isEmpty
            && !projectTitle.isEmpty && !title.isEmpty && deepLink != nil
    }
}

enum ProjectSessionAppError: Error, Equatable {
    case grantUnavailable
    case grantChanged
    case sourceUnavailable
    case conflictingReplay
    case persistenceUncertain
    case targetUnavailable
    case runUnavailable
    case busy
    case creationNotAuthorized
}

/// Exact, bounded source material recovered from the current Composer turn.
/// The journal stores only its digest; raw context is never a reusable grant.
struct ProjectSessionCapsuleSnapshot: Equatable {
    let sourceMessageID: String
    let cardID: String
    let material: String
    let digest: String
}

private enum ProjectSessionLocalFile {
    static let limit = 1024 * 1024
    private struct Identity: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
    }

    private static func identity(_ url: URL) throws -> Identity? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw ProjectSessionAppError.persistenceUncertain
        }
        guard (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1, info.st_size >= 0,
              info.st_size <= off_t(limit) else {
            throw ProjectSessionAppError.persistenceUncertain
        }
        return Identity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino),
            size: Int64(info.st_size), modifiedSeconds: info.st_mtimespec.tv_sec,
            modifiedNanoseconds: info.st_mtimespec.tv_nsec)
    }

    static func readIfPresent(_ url: URL) throws -> Data? {
        guard let initial = try identity(url) else { return nil }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ProjectSessionAppError.persistenceUncertain }
        defer { _ = close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0,
              UInt64(opened.st_dev) == initial.device,
              UInt64(opened.st_ino) == initial.inode,
              Int64(opened.st_size) == initial.size else {
            throw ProjectSessionAppError.persistenceUncertain
        }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = bytes.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.read(fd, base, raw.count)
            }
            guard count >= 0 else { throw ProjectSessionAppError.persistenceUncertain }
            if count == 0 { break }
            data.append(contentsOf: bytes.prefix(count))
            guard data.count <= limit else { throw ProjectSessionAppError.persistenceUncertain }
        }
        var after = stat()
        guard fstat(fd, &after) == 0, after.st_size == off_t(data.count),
              after.st_dev == opened.st_dev, after.st_ino == opened.st_ino,
              try identity(url) == initial else {
            throw ProjectSessionAppError.persistenceUncertain
        }
        return data
    }

    static func write(_ data: Data, to url: URL) throws {
        guard data.count <= limit else { throw ProjectSessionAppError.persistenceUncertain }
        let expected = try identity(url)
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw ProjectSessionAppError.persistenceUncertain }
        var descriptor = fd
        do {
            try data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                    guard count > 0 else { throw ProjectSessionAppError.persistenceUncertain }
                    offset += count
                }
            }
            guard fsync(descriptor) == 0, Darwin.close(descriptor) == 0 else {
                throw ProjectSessionAppError.persistenceUncertain
            }
            descriptor = -1
            guard try identity(url) == expected else {
                throw ProjectSessionAppError.persistenceUncertain
            }
            let renamed = temporary.path.withCString { source in
                url.path.withCString { destination in
                    Darwin.rename(source, destination)
                }
            }
            guard renamed == 0 else {
                throw ProjectSessionAppError.persistenceUncertain
            }
        } catch {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            _ = temporary.path.withCString { Darwin.unlink($0) }
            throw error
        }
    }
}

/// Immutable per-run bindings shared by old and rebuilt production chains.
/// Retired target IDs stay tombstoned so a late tool call cannot fall through
/// to the ordinary source-session executor.
final class ProjectSessionWorkspaceBindings: @unchecked Sendable {
    private let lock = NSLock()
    private var current: [String: TargetWorkspaceBinding] = [:]
    private var targetIDs = Set<String>()

    func register(_ binding: TargetWorkspaceBinding) throws {
        lock.lock(); defer { lock.unlock() }
        if let existing = current[binding.targetSessionID], existing != binding {
            throw ProjectSessionAppError.conflictingReplay
        }
        current[binding.targetSessionID] = binding
        targetIDs.insert(binding.targetSessionID)
    }

    func lookup(sessionID: String) -> (wasTarget: Bool, binding: TargetWorkspaceBinding?) {
        lock.lock(); defer { lock.unlock() }
        return (targetIDs.contains(sessionID), current[sessionID])
    }

    func retire(sessionID: String, runID: String) {
        lock.lock(); defer { lock.unlock() }
        guard current[sessionID]?.runID == runID else { return }
        current.removeValue(forKey: sessionID)
    }
}

/// Only native App folder selection may create a grant. Session grouping,
/// mounted file roots, Home, and a model-supplied path never enter this map.
@MainActor
final class ProjectSessionGrantRegistry {
    private struct Grant: Codable {
        let id: String
        let displayName: String
        let bookmark: Data
        let originalCanonicalPath: String
        let revision: String
        var revoked: Bool
    }
    struct DirectoryGrant: Codable, Equatable, Sendable, Identifiable {
        let id: UUID
        let sessionID: String?
        let projectID: String
        let workingDirectory: String
        let path: String
        let identity: String
        let bookmark: Data?
        var revision: UUID
        var revoked: Bool
    }
    struct InstructionTrust: Codable, Equatable {
        let rootIdentity: String
        let paths: [String]
        let hashes: [String: String]
    }
    private struct Envelope: Codable {
        let version: Int
        var grants: [Grant]
        var directories: [DirectoryGrant]? = nil
        var instructionTrust: [String: InstructionTrust]? = nil
    }
    private var directories: [DirectoryGrant] = []
    private var temporaryDirectories: [DirectoryGrant] = []
    private var instructionTrust: [String: InstructionTrust] = [:]

    private let url: URL
    private var grants: [Grant]
    private var scopedURLs: [String: URL] = [:]

    init(directory: URL) throws {
        url = directory.appendingPathComponent("project-session-grants-v1.json")
        if let data = try ProjectSessionLocalFile.readIfPresent(url) {
            let decoded = try JSONDecoder().decode(Envelope.self, from: data)
            guard decoded.version == 1,
                  Set(decoded.grants.map(\.id)).count == decoded.grants.count,
                  Set((decoded.directories ?? []).map(\.id)).count == (decoded.directories ?? []).count,
                  (decoded.directories ?? []).allSatisfy({ $0.sessionID == nil && $0.bookmark != nil }) else {
                throw ProjectSessionAppError.persistenceUncertain
            }
            grants = decoded.grants
            directories = decoded.directories ?? []
            instructionTrust = decoded.instructionTrust ?? [:]
        } else {
            grants = []
        }
    }

    /// Called only with the URL returned by the sidebar's NSOpenPanel.
    @discardableResult
    func registerNativeSelection(_ selected: URL, displayName: String,
                                 trustedInstructions: TrustedProjectInstructionSnapshot? = nil) throws -> String {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, selected.isFileURL,
              let root = Self.canonicalDirectory(selected), Self.isSafeRoot(root) else {
            throw ProjectSessionAppError.grantUnavailable
        }
        let bookmark = try selected.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let grant = Grant(id: UUID().uuidString, displayName: name, bookmark: bookmark,
                          originalCanonicalPath: root.path, revision: UUID().uuidString, revoked: false)
        grants.append(grant)
        do {
            if let trustedInstructions { instructionTrust[grant.id] = try instructionRecord(trustedInstructions, projectID: grant.id) }
            try persist()
        } catch {
            grants.removeLast()
            instructionTrust.removeValue(forKey: grant.id)
            throw error
        }
        return grant.id
    }

    func revoke(id: String) throws {
        guard let index = grants.firstIndex(where: { $0.id == id }) else { return }
        let old = grants[index]
        grants[index].revoked = true
        do { try persist() } catch { grants[index] = old; throw error }
    }

    private func instructionRecord(_ snapshot: TrustedProjectInstructionSnapshot,
                                   projectID: String) throws -> InstructionTrust {
        let project = try resolve(id: projectID)
        let directory = try self.directory(for: project)
        guard let identity = snapshot.rootDirectoryIdentity,
              identity == (try Self.directoryIdentity(directory)),
              !snapshot.loadedRelativePaths.isEmpty,
              snapshot.loadedRelativePaths.allSatisfy({ snapshot.sourceFileSHA256[$0] != nil }),
              snapshot.sourceFileSHA256.count == Set(snapshot.loadedRelativePaths).count else {
            throw ProjectSessionAppError.grantChanged
        }
        return InstructionTrust(rootIdentity: identity, paths: snapshot.loadedRelativePaths,
                                hashes: snapshot.sourceFileSHA256)
    }

    func hasInstructionTrust(_ snapshot: TrustedProjectInstructionSnapshot, projectID: String) -> Bool {
        guard let candidate = try? instructionRecord(snapshot, projectID: projectID) else { return false }
        return instructionTrust[projectID] == candidate
    }

    func trustInstructions(_ snapshot: TrustedProjectInstructionSnapshot, projectID: String) throws {
        let candidate = try instructionRecord(snapshot, projectID: projectID)
        let previous = instructionTrust[projectID]
        instructionTrust[projectID] = candidate
        do { try persist() } catch { instructionTrust[projectID] = previous; throw error }
    }

    func revokeInstructionTrust(projectID: String) throws {
        let previous = instructionTrust.removeValue(forKey: projectID)
        do { try persist() } catch { instructionTrust[projectID] = previous; throw error }
    }

    func instructionTrustRows() -> [(projectID: String, path: String, hash: String)] {
        instructionTrust.keys.sorted().flatMap { projectID -> [(projectID: String, path: String, hash: String)] in
            guard (try? resolve(id: projectID)) != nil, let record = instructionTrust[projectID] else { return [] }
            var seen = Set<String>()
            return record.paths.filter { seen.insert($0).inserted }.compactMap { path in
                record.hashes[path].map { (projectID: projectID, path: path, hash: $0) }
            }
        }
    }

    func hasProject(_ id: String) -> Bool { grants.contains { $0.id == id } }
    func inheritSessionDirectories(from previous: ProjectSessionGrantRegistry) {
        temporaryDirectories = previous.temporaryDirectories
    }

    func directoryGrants() -> [DirectoryGrant] { directories + temporaryDirectories }

    func approveDirectory(_ url: URL, identity: String, sessionID: String, projectID: String,
                          workingDirectory: String, persistForProject: Bool) throws {
        if persistForProject { _ = try resolve(id: projectID) }
        let bookmark = persistForProject ? try url.bookmarkData(options: [.withSecurityScope],
            includingResourceValuesForKeys: nil, relativeTo: nil) : nil
        let grant = DirectoryGrant(id: UUID(), sessionID: persistForProject ? nil : sessionID,
            projectID: projectID, workingDirectory: workingDirectory, path: url.path,
            identity: identity, bookmark: bookmark, revision: UUID(), revoked: false)
        if persistForProject {
            let old = directories
            directories.removeAll { $0.projectID == projectID && $0.path == url.path }
            directories.append(grant)
            do { try persist() } catch { directories = old; throw error }
        } else {
            temporaryDirectories.removeAll { $0.sessionID == sessionID && $0.path == url.path }
            temporaryDirectories.append(grant)
        }
    }

    func revokeDirectory(_ id: UUID) throws {
        if let index = temporaryDirectories.firstIndex(where: { $0.id == id }) {
            temporaryDirectories[index].revoked = true
            temporaryDirectories[index].revision = UUID()
            return
        }
        guard let index = directories.firstIndex(where: { $0.id == id }) else { return }
        let old = directories
        directories[index].revoked = true
        directories[index].revision = UUID()
        do { try persist() } catch { directories = old; throw error }
    }

    func retainDirectorySessions(_ sessions: Set<String>) {
        temporaryDirectories.removeAll { !sessions.contains($0.sessionID ?? "") }
    }

    static func directoryIdentity(_ url: URL) throws -> String {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory,
              let device = attrs[.systemNumber] as? NSNumber,
              let inode = attrs[.systemFileNumber] as? NSNumber else { throw ProjectSessionAppError.grantChanged }
        return "\(device):\(inode)"
    }

    func validatedDirectory(_ grant: DirectoryGrant) throws -> URL {
        guard !grant.revoked else { throw ProjectSessionAppError.grantUnavailable }
        if grant.sessionID == nil { _ = try resolve(id: grant.projectID) }
        let url: URL
        if let bookmark = grant.bookmark {
            var stale = false
            url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope],
                relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !stale else { throw ProjectSessionAppError.grantChanged }
        } else { url = URL(fileURLWithPath: grant.path, isDirectory: true) }
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        guard canonical.path == grant.path, try Self.directoryIdentity(canonical) == grant.identity else {
            throw ProjectSessionAppError.grantChanged
        }
        return canonical
    }

    func list() -> [ProjectSessionAuthorizedProject] {
        grants.compactMap { try? resolve(id: $0.id) }
    }

    func resolve(id: String) throws -> ProjectSessionAuthorizedProject {
        guard let grant = grants.first(where: { $0.id == id && !$0.revoked }) else {
            throw ProjectSessionAppError.grantUnavailable
        }
        _ = try resolveURL(grant)
        return ProjectSessionAuthorizedProject(projectID: grant.id, displayName: grant.displayName,
            workdirReference: "grant:\(grant.id):\(grant.revision)")
    }

    func directory(for project: ProjectSessionAuthorizedProject) throws -> URL {
        guard let grant = grants.first(where: { $0.id == project.projectID && !$0.revoked }),
              project.workdirReference == "grant:\(grant.id):\(grant.revision)" else {
            throw ProjectSessionAppError.grantChanged
        }
        return try resolveURL(grant).resolvingSymlinksInPath().standardizedFileURL
    }

    /// Keep security scope open while a target run owns this project. The
    /// resolved URL is checked again at every effect boundary.
    func beginRunAccess(_ project: ProjectSessionAuthorizedProject, runID: String) throws -> URL {
        guard let grant = grants.first(where: { $0.id == project.projectID && !$0.revoked }) else {
            throw ProjectSessionAppError.grantUnavailable
        }
        let scoped = try resolveURL(grant)
        guard scoped.startAccessingSecurityScopedResource() else {
            throw ProjectSessionAppError.grantUnavailable
        }
        scopedURLs[runID] = scoped
        return scoped.resolvingSymlinksInPath().standardizedFileURL
    }

    func endRunAccess(runID: String) {
        scopedURLs.removeValue(forKey: runID)?.stopAccessingSecurityScopedResource()
    }

    private func resolveURL(_ grant: Grant) throws -> URL {
        var stale = false
        let resolved = try URL(resolvingBookmarkData: grant.bookmark,
            options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale, let canonical = Self.canonicalDirectory(resolved),
              canonical.path == grant.originalCanonicalPath,
              Self.isSafeRoot(canonical) else { throw ProjectSessionAppError.grantUnavailable }
        return resolved
    }

    private static func canonicalDirectory(_ url: URL) -> URL? {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true).standardizedFileURL
    }

    private static func isSafeRoot(_ root: URL) -> Bool {
        let path = root.path
        guard path != "/", !path.contains("/../") else { return false }
        return !BuiltinToolExecutor.defaultDeniedRoots().contains { denied in
            let prefix = denied.resolvingSymlinksInPath().standardizedFileURL.path
            return path == prefix || path.hasPrefix(prefix + "/")
        }
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(Envelope(version: 1, grants: grants, directories: directories, instructionTrust: instructionTrust))
        guard data.count <= 1024 * 1024 else { throw ProjectSessionAppError.persistenceUncertain }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ProjectSessionLocalFile.write(data, to: url)
    }
}

/// Routing lives below the existing Safety -> Policy -> Recording chain.
/// The catalog validator strips exactly these three names before delegating.
final class ProjectSessionCompositeToolExecutor: ToolCatalogValidatingExecutor,
    PolicyCapabilityResolving, SessionReadCapabilityAwareToolExecutor,
    BuiltinOwnerBoundToolExecutor, @unchecked Sendable {
    let base: any ToolExecutor
    let projectSession: ProjectSessionToolExecutor
    let builtin: BuiltinToolExecutor
    let appHandler: ProjectSessionAppHandler
    let workspaceBindings: ProjectSessionWorkspaceBindings
    let directorySnapshot: [ProjectSessionGrantRegistry.DirectoryGrant]
    let directoryOriginalRoots: [String]

    init(base: any ToolExecutor, builtin: BuiltinToolExecutor,
         handler: ProjectSessionAppHandler,
         workspaceBindings: ProjectSessionWorkspaceBindings,
         directorySnapshot: [ProjectSessionGrantRegistry.DirectoryGrant] = [],
         directoryOriginalRoots: [String] = []) {
        self.base = base
        self.builtin = builtin
        appHandler = handler
        self.workspaceBindings = workspaceBindings
        self.directorySnapshot = directorySnapshot
        self.directoryOriginalRoots = directoryOriginalRoots
        projectSession = ProjectSessionToolExecutor(handler: handler)
    }

    func execute(name: String, input: [String: Any]) async throws -> String {
        try await execute(name: name, input: input, boundOwner: nil)
    }

    var currentBuiltinOwner: BuiltinToolExecutor? {
        guard let owner = (base as? any BuiltinOwnerBoundToolExecutor)?.currentBuiltinOwner,
              owner === builtin else { return nil }
        return owner
    }

    func executeBoundToBuiltinOwner(
        _ owner: BuiltinToolExecutor, name: String, input: [String: Any]
    ) async throws -> String {
        guard currentBuiltinOwner === owner else { throw ToolExecutorError.resourceScopeInvalid }
        return try await execute(name: name, input: input, boundOwner: owner)
    }

    private func execute(
        name: String, input: [String: Any], boundOwner: BuiltinToolExecutor?
    ) async throws -> String {
        if ProjectSessionToolContract.toolNames.contains(name) {
            return try await projectSession.execute(name: name, input: input)
        }
        if ["shell_execute", "file_read", "file_grep", "file_glob", "file_write", "file_edit", "file_delete"].contains(name) {
            guard let context = AgentExecutionContext.current else {
                throw ProjectSessionAppError.sourceUnavailable
            }
            let sessionID: String
            if context.hasVerifiedParentRuntime,
               let currentSessionID = context.currentConversationID,
               context.parentRuntimeIdentity?.sessionID == currentSessionID {
                sessionID = currentSessionID
            } else {
                // Forward only through this child's exact registered owner and
                // admitted canonical attempt. Its offered catalog and capability
                // executor already enforce the user mutation switch.
                guard let boundOwner, boundOwner === builtin,
                      currentBuiltinOwner === boundOwner,
                      let child = context.childToolRuntimeBinding,
                      let parentSessionID = await child.verifiedParentSessionID(for: name, context: context) else {
                    throw ProjectSessionAppError.sourceUnavailable
                }
                sessionID = parentSessionID
            }
            let independentEffect: Bool
            if let receipt = ToolExecutionReceiptContext.current, let frozen = try? ComposerToolInput(input) {
                independentEffect = ComposerPolicyEnforcedToolExecutor.hasIndependentFileEffectAuthority(
                    owner: builtin, name: name, input: frozen, receipt: receipt)
            } else { independentEffect = false }
            // This exemption is only for N07's new directory custody check.
            // Target identity, project policy and the real builtin still run.
            if !independentEffect {
                try await appHandler.validateDirectoryAdmission(directorySnapshot, sessionID: sessionID,
                    tool: name, path: input["path"] as? String, originalRoots: directoryOriginalRoots)
            }
            let target = workspaceBindings.lookup(sessionID: sessionID)
            if target.wasTarget {
                guard let binding = target.binding,
                      await appHandler.isWorkspaceAuthorized(binding) else {
                    throw ProjectSessionAppError.grantUnavailable
                }
                return try await builtin.executeInTargetWorkspace(name: name,
                    input: input, binding: binding)
            }
        }
        if let boundOwner {
            return try await executeThroughBoundBuiltinOwner(
                base, owner: boundOwner, name: name, input: input
            )
        }
        return try await base.execute(name: name, input: input)
    }

    func resolvesCapability(_ name: String) async throws -> Bool {
        if ProjectSessionToolContract.toolNames.contains(name) { return true }
        guard let resolver = base as? any PolicyCapabilityResolving else { return false }
        return try await resolver.resolvesCapability(name)
    }

    func validateToolCatalog(_ tools: [AgentToolDefinition]) throws {
        let names = Set(tools.map(\.name))
        let exposedProject = names.intersection(ProjectSessionToolContract.toolNames)
        guard (exposedProject.isEmpty || exposedProject == ProjectSessionToolContract.toolNames),
              names.count == tools.count else { throw ProjectSessionAppError.grantUnavailable }
        try (base as? any ToolCatalogValidatingExecutor)?.validateToolCatalog(
            tools.filter { !ProjectSessionToolContract.toolNames.contains($0.name) })
    }

    func executeSessionRead(input: [String: Any], authorization: CrossSessionReadAuthorization,
                            context: SessionReadExecutionContext, now: Date) async throws -> String {
        guard let aware = base as? any SessionReadCapabilityAwareToolExecutor else {
            throw CrossSessionReadAuthorizationError.capabilityRequired
        }
        return try await aware.executeSessionRead(input: input, authorization: authorization, context: context, now: now)
    }
}

/// One local finite reservation around the existing SessionStore and
/// AgentTaskStore. A crash may leave a partial record; replay first checks
/// canonical facts and never blindly repeats an already-started external run.
@MainActor
final class ProjectSessionAppHandler: ProjectSessionProductionHandler {
    private struct Reservation: Codable {
        let key: String
        let source: ParentRuntimeIdentity
        let digest: String
        let projectID: String
        let targetID: String
        let taskID: String
        let runID: String
        let cardID: String
        let capsuleDigest: String?
        var approved: Bool
        var phase: String
        var didSwitch: Bool
    }
    private struct Journal: Codable { let version: Int; var reservations: [Reservation] }

    let grants: ProjectSessionGrantRegistry
    private unowned let chat: ChatStore
    private let sessionStore: SessionStore
    private let taskStore: AgentTaskStore
    private let workspaceBindings: ProjectSessionWorkspaceBindings
    private let journalURL: URL
    private var fileAccessExecutor: BuiltinToolExecutor
    private var productionBindingActive = true
    private var records: [Reservation]
    private var inFlight: Set<String> = []
    // The initial combined card may decline the first load before a prompt
    // exists. Preserve only its hash decision, never its instruction text.
    private var initialInstructionRefusals: [String: [String: String]] = [:]
    /// Production uses the native alert. Focused source tests can inject an
    /// explicit click fact without displaying a window.
    private let approve: @MainActor (ProjectSessionCreateRequest, String) -> Bool

    init(chat: ChatStore, sessionStore: SessionStore, taskStore: AgentTaskStore,
         workspaceBindings: ProjectSessionWorkspaceBindings,
         directory: URL, fileAccessExecutor: BuiltinToolExecutor,
         approval: (@MainActor (ProjectSessionCreateRequest, String) -> Bool)? = nil) throws {
        self.chat = chat
        self.sessionStore = sessionStore
        self.taskStore = taskStore
        self.workspaceBindings = workspaceBindings
        grants = try ProjectSessionGrantRegistry(directory: directory)
        journalURL = directory.appendingPathComponent("project-session-reservations-v1.json")
        self.fileAccessExecutor = fileAccessExecutor
        if let data = try ProjectSessionLocalFile.readIfPresent(journalURL) {
            let journal = try JSONDecoder().decode(Journal.self, from: data)
            guard journal.version == 1,
                  Set(journal.reservations.map(\.key)).count == journal.reservations.count else {
                throw ProjectSessionAppError.persistenceUncertain
            }
            records = journal.reservations
        } else { records = [] }
        approve = approval ?? { request, preview in
            let alert = NSAlert()
            alert.messageText = "创建跨项目任务？"
            alert.informativeText = "在「\(request.project.displayName)」创建「\(request.title)」并运行。"
                + (request.switchAfterCreate ? "创建后会切换到新会话。" : "当前会话保持打开。")
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 280))
            scroll.hasVerticalScroller = true
            let text = NSTextView(frame: scroll.bounds)
            text.isEditable = false
            text.isSelectable = true
            text.textContainer?.widthTracksTextView = true
            text.string = preview
            scroll.documentView = text
            alert.accessoryView = scroll
            alert.addButton(withTitle: request.switchAfterCreate ? "创建并切换" : "创建任务")
            alert.addButton(withTitle: "取消")
            return alert.runModal() == .alertFirstButtonReturn
        }
    }

    func listProjects(source: ProjectSessionTrustedSource) async throws -> [ProjectSessionAuthorizedProject] {
        guard productionBindingActive, validSource(source.identity),
              await validCurrentTurn(source.identity) else {
            throw ProjectSessionAppError.sourceUnavailable
        }
        return grants.list().filter { project in
            guard let directory = try? grants.directory(for: project) else { return false }
            return isWithinExecutionRoots(directory)
        }
    }

    func resolveProject(id: String, source: ProjectSessionTrustedSource) async throws -> ProjectSessionAuthorizedProject {
        guard productionBindingActive, validSource(source.identity),
              await validCurrentTurn(source.identity) else {
            throw ProjectSessionAppError.sourceUnavailable
        }
        let project = try grants.resolve(id: id)
        guard isWithinExecutionRoots(try grants.directory(for: project)) else {
            throw ProjectSessionAppError.grantUnavailable
        }
        return project
    }

    func authorizeCreate(_ request: ProjectSessionCreateRequest) async throws -> Bool {
        guard productionBindingActive, validSource(request.source.identity),
              await validCurrentTurn(request.source.identity),
              try grants.resolve(id: request.project.projectID) == request.project,
              isWithinExecutionRoots(try grants.directory(for: request.project)),
              chat.acceptsProjectTaskText(request.title, limit: 200),
              chat.acceptsProjectTaskText(request.initialTask, limit: 32_000) else { return false }
        let capsule = try chat.currentProjectCapsule(source: request.source.identity,
            reference: request.capsuleReference)
        let instruction = try Self.targetInstruction(request.initialTask, capsule: capsule)
        guard chat.acceptsProjectTaskPayload(instruction, limit: 32_000) else { return false }
        let digest = Self.digest(request)
        if let existing = records.first(where: { $0.key == request.idempotencyKey }) {
            guard existing.digest == digest, existing.source == request.source.identity else {
                throw ProjectSessionAppError.conflictingReplay
            }
            return existing.approved && existing.capsuleDigest == capsule?.digest
        }
        let preview = "将发送到目标任务的完整首条消息：\n\n" + instruction
        guard approve(request, preview), await validCurrentTurn(request.source.identity, requiresCurrentAuthority: true),
              try chat.currentProjectCapsule(source: request.source.identity,
                  reference: request.capsuleReference)?.digest == capsule?.digest else { return false }
        let record = Reservation(key: request.idempotencyKey, source: request.source.identity,
            digest: digest, projectID: request.project.projectID,
            targetID: UUID().uuidString, taskID: UUID().uuidString,
            runID: UUID().uuidString, cardID: UUID().uuidString,
            capsuleDigest: capsule?.digest,
            approved: true, phase: "reserved", didSwitch: false)
        records.append(record)
        do { try persistJournal() } catch { records.removeLast(); throw error }
        return true
    }

    func createSession(_ request: ProjectSessionCreateRequest) async throws -> ProjectSessionCreateOutcome {
        let source = request.source.identity
        guard productionBindingActive, validSource(source), await validCurrentTurn(source, requiresCurrentAuthority: true),
              try grants.resolve(id: request.project.projectID) == request.project,
              isWithinExecutionRoots(try grants.directory(for: request.project)),
              chat.acceptsProjectTaskText(request.title, limit: 200),
              chat.acceptsProjectTaskText(request.initialTask, limit: 32_000),
              let index = records.firstIndex(where: { $0.key == request.idempotencyKey }),
              records[index].approved, records[index].source == source,
              records[index].digest == Self.digest(request) else {
            throw ProjectSessionAppError.creationNotAuthorized
        }
        let capsule = try chat.currentProjectCapsule(source: source,
            reference: request.capsuleReference)
        guard records[index].capsuleDigest == capsule?.digest else {
            throw ProjectSessionAppError.creationNotAuthorized
        }
        let instruction = try Self.targetInstruction(request.initialTask, capsule: capsule)
        guard chat.acceptsProjectTaskPayload(instruction, limit: 32_000) else {
            throw ProjectSessionAppError.creationNotAuthorized
        }
        guard inFlight.insert(request.idempotencyKey).inserted else {
            return .partial(partial(for: records[index]))
        }
        defer { inFlight.remove(request.idempotencyKey) }
        let record = records[index]
        let projectURL = try grants.directory(for: request.project)
        let taskRequest = AgentTaskCreationRequest(taskID: record.taskID,
            parentID: source.taskID, source: source, title: request.title,
            projectID: request.project.projectID, workingDirectory: projectURL.path,
            scopeID: request.project.projectID, idempotencyKey: request.idempotencyKey)
        let consumer = AgentTaskCreationConsumer(store: taskStore,
            knownProjectIDs: [request.project.projectID], authorizedScopeIDs: [request.project.projectID])
        if record.phase == "committed" {
            guard let receipt = try? consumer.consume(taskRequest),
                  chat.hasProjectTarget(record.targetID, taskID: record.taskID, runID: record.runID),
                  chat.hasSourceCard(record.cardID, sourceID: source.sessionID),
                  taskStore.controlSnapshot(taskID: record.taskID, parentID: source.taskID)?.runID == record.runID else {
                return .partial(partial(for: record))
            }
            if receipt.snapshot.status == .running,
               !chat.isProjectTaskRunning(record.targetID) {
                chat.updateSourceCard(runID: record.runID, status: .unavailable)
                return .partial(partial(for: record))
            }
            return .committed(ProjectSessionCommittedCreation(targetSessionID: record.targetID,
                runID: record.runID, sourceBacklinkID: record.cardID,
                creationReceipt: receipt, didSwitch: record.didSwitch))
        }
        var didLaunch = false
        do {
            try chat.createProjectTarget(id: record.targetID, title: request.title,
                sourceID: source.sessionID, project: request.project, directory: projectURL,
                taskID: record.taskID, runID: record.runID)
            try setPhase("target", key: record.key)
            let receipt = try consumer.consume(taskRequest)
            try setPhase("queued", key: record.key)
            // An existing run after a crash is an uncertain external effect.
            guard taskStore.controlSnapshot(taskID: record.taskID, parentID: source.taskID)?.runID == nil else {
                return .partial(partial(for: record))
            }
            _ = try taskStore.startRun(taskID: record.taskID, parentID: source.taskID, runID: record.runID)
            try setPhase("running", key: record.key)
            guard try chat.currentProjectCapsule(source: source,
                reference: request.capsuleReference)?.digest == record.capsuleDigest else {
                throw ProjectSessionAppError.creationNotAuthorized
            }
            try chat.enqueueProjectTaskInstruction(instruction, targetID: record.targetID,
                projectID: request.project.projectID)
            let card = SessionReferenceCard(id: record.cardID, sourceSessionID: source.sessionID,
                targetSessionID: record.targetID, taskID: record.taskID, runID: record.runID,
                projectID: request.project.projectID, projectTitle: request.project.displayName,
                title: request.title, createdAt: Date(), status: .running)
            try chat.appendSourceCard(card)
            try setPhase("backlinked", key: record.key)
            _ = try grants.beginRunAccess(request.project, runID: record.runID)
            guard try chat.currentProjectCapsule(source: source,
                reference: request.capsuleReference)?.digest == record.capsuleDigest else {
                throw ProjectSessionAppError.creationNotAuthorized
            }
            let binding = TargetWorkspaceBinding(source: source,
                targetSessionID: record.targetID, taskID: record.taskID,
                runID: record.runID, projectID: request.project.projectID,
                workingDirectory: projectURL.path)
            try workspaceBindings.register(binding)
            guard chat.startProjectTask(targetID: record.targetID, projectID: request.project.projectID,
                instruction: instruction, runID: record.runID, taskStore: taskStore,
                authorization: { [weak self] in
                    guard let self else { return false }
                    return self.isWorkspaceAuthorized(binding)
                },
                onFinished: { [weak self, workspaceBindings] in
                    workspaceBindings.retire(sessionID: record.targetID, runID: record.runID)
                    self?.grants.endRunAccess(runID: record.runID)
                }) else {
                workspaceBindings.retire(sessionID: record.targetID, runID: record.runID)
                grants.endRunAccess(runID: record.runID)
                _ = try? taskStore.abortRunInitialization(runID: record.runID)
                throw ProjectSessionAppError.runUnavailable
            }
            didLaunch = true
            if request.switchAfterCreate {
                guard let id = UUID(uuidString: record.targetID), chat.applySwitchSession(id: id) else {
                    throw ProjectSessionAppError.targetUnavailable
                }
            }
            records[index].didSwitch = request.switchAfterCreate
            try setPhase("committed", key: record.key)
            return .committed(ProjectSessionCommittedCreation(targetSessionID: record.targetID,
                runID: record.runID, sourceBacklinkID: record.cardID,
                creationReceipt: receipt, didSwitch: request.switchAfterCreate))
        } catch {
            // No second run is started by recovery. The journal keeps stable
            // IDs and the visible card (if written) remains inspectable.
            if !didLaunch,
               taskStore.controlSnapshot(taskID: record.taskID, parentID: source.taskID)?.runID == record.runID {
                workspaceBindings.retire(sessionID: record.targetID, runID: record.runID)
                grants.endRunAccess(runID: record.runID)
                _ = try? taskStore.abortRunInitialization(runID: record.runID)
                chat.updateSourceCard(runID: record.runID, status: .failed)
            }
            return .partial(partial(for: record))
        }
    }

    func captureDirectoryGrants(sessionID: String?, owner: BuiltinToolExecutor,
                                originalRootCeiling: [String]) -> [ProjectSessionGrantRegistry.DirectoryGrant] {
        guard let sessionID,
              let session = chat.sessions.first(where: { $0.id.uuidString == sessionID }) else { return [] }
        let projectID = session.projectID ?? "session:\(sessionID)"
        let cwd = session.workingDirectory ?? fileAccessExecutor.allowedRoot.resolvingSymlinksInPath().path
        let added = Set(owner.additionalAllowedRoots.map { $0.standardizedFileURL.path })
        // Include tombstones: recomposing an old owner cannot revive a grant.
        // An unrelated original mount is never minted into directory custody.
        return grants.directoryGrants().filter {
            $0.projectID == projectID && $0.workingDirectory == cwd
                && ($0.sessionID == nil || $0.sessionID == sessionID) && added.contains($0.path)
                && !PolicyRuntimePathBoundary.isWithinRoots(path: $0.path, roots: originalRootCeiling)
        }
    }

    var acceptsDirectoryManagement: Bool { productionBindingActive }
    func directoryRevision(sessionID: String, projectID: String) -> String {
        grants.directoryGrants().filter {
            $0.projectID == projectID && ($0.sessionID == nil || $0.sessionID == sessionID)
        }.map { "\($0.id):\($0.revision)" }.sorted().joined(separator: "|")
    }

    func approvedAdditionalDirectories(sessionID: String, projectID: String, workingDirectory: String) throws -> [URL] {
        guard productionBindingActive else { throw ProjectSessionAppError.grantUnavailable }
        return try grants.directoryGrants().filter {
            !$0.revoked && $0.projectID == projectID && $0.workingDirectory == workingDirectory
                && ($0.sessionID == nil || $0.sessionID == sessionID)
        }.map { try grants.validatedDirectory($0) }
    }

    func approveAdditionalDirectory(_ url: URL, identity: String, sessionID: String, projectID: String,
                                   workingDirectory: String, persistForProject: Bool) throws {
        guard productionBindingActive, chat.activeSessionID?.uuidString == sessionID,
              let session = chat.sessions.first(where: { $0.id.uuidString == sessionID }),
              (session.projectID ?? "session:\(sessionID)") == projectID,
              (session.workingDirectory ?? fileAccessExecutor.allowedRoot.resolvingSymlinksInPath().path) == workingDirectory else {
            throw ProjectSessionAppError.sourceUnavailable
        }
        _ = try fileAccessExecutor.validatedApprovedSessionDirectory(url.path)
        try grants.approveDirectory(url, identity: identity, sessionID: sessionID,
            projectID: projectID, workingDirectory: workingDirectory, persistForProject: persistForProject)
    }

    func validateDirectoryAdmission(_ snapshot: [ProjectSessionGrantRegistry.DirectoryGrant], sessionID: String,
                                    tool: String, path: String?, originalRoots: [String]) throws {
        guard let session = chat.sessions.first(where: { $0.id.uuidString == sessionID }) else {
            if snapshot.isEmpty { return }
            throw ProjectSessionAppError.sourceUnavailable
        }
        let nativeProject = session.projectID.map { grants.hasProject($0) } == true
        guard !snapshot.isEmpty || nativeProject else { return }
        guard productionBindingActive else { throw ProjectSessionAppError.grantUnavailable }
        if nativeProject, let projectID = session.projectID { _ = try grants.resolve(id: projectID) }
        if tool != "shell_execute", let path,
           PolicyRuntimePathBoundary.isWithinRoots(path: path, roots: originalRoots) { return }
        let live = grants.directoryGrants()
        for pathGroup in Dictionary(grouping: snapshot, by: \.path).values {
            guard let root = pathGroup.first?.path else { continue }
            // This is only the captured directory grant, not the original
            // workspace or a separate one-use authorization.
            if tool != "shell_execute", let path,
               !PolicyRuntimePathBoundary.isWithinRoots(path: path, roots: [root]) { continue }
            let applicable = pathGroup.filter {
                ($0.sessionID == nil || $0.sessionID == sessionID)
                    && $0.projectID == (session.projectID ?? "session:\(sessionID)")
                    && $0.workingDirectory == (session.workingDirectory ?? fileAccessExecutor.allowedRoot.resolvingSymlinksInPath().path)
            }
            guard let current = applicable.compactMap({ captured in
                live.first { $0.id == captured.id && $0.revision == captured.revision && !$0.revoked }
            }).first else { throw ProjectSessionAppError.grantChanged }
            _ = try grants.validatedDirectory(current)
        }
    }

    @discardableResult
    func authorizeFolderFromNativePicker(_ url: URL) throws -> String {
        guard productionBindingActive else {
            throw ProjectSessionAppError.grantUnavailable
        }
        _ = try fileAccessExecutor.validatedProjectAuthorizationDirectory(
            url.resolvingSymlinksInPath().standardizedFileURL.path)
        return try grants.registerNativeSelection(url, displayName: url.lastPathComponent)
    }

    /// The sidebar "授权项目" path: register the native selection, then open a
    /// new session bound to that grant (project id = grant id, directory = the
    /// grant's canonical directory). Existing sessions and the name-only
    /// "归入项目" path stay unchanged; that path still grants nothing.
    @discardableResult
    func authorizeFolderAndOpenSession(_ url: URL, displayName: String? = nil) throws -> String {
        let projectID = try authorizeFolderFromNativePicker(url)
        // Any later failure revokes the grant just registered, so the user never
        // sees "授权失败" while a stale grant stays behind.
        let directory: URL
        do {
            let project = try grants.resolve(id: projectID)
            directory = try grants.directory(for: project)
            let validated = try fileAccessExecutor.validatedProjectAuthorizationDirectory(directory.path)
            guard validated.path == directory.path else {
                throw ProjectSessionAppError.grantUnavailable
            }
        } catch {
            try? grants.revoke(id: projectID)
            throw error
        }
        chat.newSession(projectID: projectID,
                        projectName: displayName ?? url.lastPathComponent,
                        workingDirectory: directory.path)
        guard chat.sessions.first(where: { $0.id == chat.activeSessionID })?.projectID == projectID else {
            try? grants.revoke(id: projectID)
            throw ProjectSessionAppError.grantUnavailable
        }
        return projectID
    }

    func admitProjectInstructions(_ snapshot: TrustedProjectInstructionSnapshot,
                                  scope: MemoryScope, allowPrompt: Bool,
                                  isCurrent: () -> Bool,
                                  modalPhase: ComposerModelPreparationContext.InstructionModalPhase?) -> Bool {
        guard isCurrent(), productionBindingActive,
              let session = chat.sessions.first(where: { $0.id.uuidString == scope.sessionID && $0.projectID == scope.projectID }),
              let directory = session.workingDirectory,
              isTaskFileProjectAuthorized(projectID: scope.projectID, workingDirectory: directory) else { return false }
        if let declinedHashes = initialInstructionRefusals.removeValue(forKey: scope.sessionID),
           declinedHashes == snapshot.sourceFileSHA256 { return false }
        if grants.hasInstructionTrust(snapshot, projectID: scope.projectID) { return isCurrent() }
        guard allowPrompt, NSApp?.isActive == true else { return false }
        let alert = NSAlert()
        alert.messageText = "加载项目指令？"
        alert.informativeText = "这些文件会作为项目指令发送给模型。仅信任所列哈希；文件变化后会再次询问。\n"
            + snapshot.loadedRelativePaths.map { ContentSecretRedactor.redact($0) + "\nSHA-256: " + (snapshot.sourceFileSHA256[$0] ?? "") }.joined(separator: "\n")
        alert.addButton(withTitle: "信任并加载")
        alert.addButton(withTitle: "本次不加载")
        guard modalPhase?(true) != false else { return false }
        let choice = alert.runModal()
        guard modalPhase?(false) != false,
              choice == .alertFirstButtonReturn,
              isCurrent(), productionBindingActive,
              chat.sessions.contains(where: { $0.id.uuidString == scope.sessionID && $0.projectID == scope.projectID && $0.workingDirectory == directory }),
              isTaskFileProjectAuthorized(projectID: scope.projectID, workingDirectory: directory) else { return false }
        do { try grants.trustInstructions(snapshot, projectID: scope.projectID); return true }
        catch { return false }
    }

    /// The OS picker remains separate. This one App card combines directory
    /// authorization with trust of the exact candidate read on the worker.
    func authorizeFolderAndOpenSessionWithInstructionConsent(_ url: URL) async throws -> Bool {
        let originalSession = chat.activeSessionID
        let selectedIdentity = try ProjectSessionGrantRegistry.directoryIdentity(url)
        _ = try fileAccessExecutor.validatedProjectAuthorizationDirectory(url.resolvingSymlinksInPath().standardizedFileURL.path)
        let physical = try DarwinSystemPathResolver.resolve(url)
        let candidate = try await Task.detached(priority: .userInitiated) {
            try TrustedProjectInstructions.loadSnapshot(atTrustedRoot: URL(fileURLWithPath: physical, isDirectory: true))
        }.value
        try Task.checkCancellation()
        guard productionBindingActive, chat.activeSessionID == originalSession,
              try ProjectSessionGrantRegistry.directoryIdentity(url) == selectedIdentity else { throw ProjectSessionAppError.grantChanged }
        let alert = NSAlert()
        alert.messageText = "授权项目目录" + (candidate == nil ? "" : "并加载项目指令？")
        alert.informativeText = candidate.map { snapshot in
            "目录访问与指令信任是两项独立授权。以下是本次读取的文件：\n"
            + snapshot.loadedRelativePaths.map { ContentSecretRedactor.redact($0) + "\nSHA-256: " + (snapshot.sourceFileSHA256[$0] ?? "") }.joined(separator: "\n")
        } ?? "授权目录访问；本次没有可加载的项目指令文件。"
        alert.addButton(withTitle: candidate == nil ? "授权目录" : "授权目录并信任这些指令")
        if candidate != nil { alert.addButton(withTitle: "仅授权目录，本次不加载") }
        alert.addButton(withTitle: "取消")
        let choice = alert.runModal()
        guard choice == .alertFirstButtonReturn || (candidate != nil && choice == .alertSecondButtonReturn) else { return false }
        guard productionBindingActive, chat.activeSessionID == originalSession,
              try ProjectSessionGrantRegistry.directoryIdentity(url) == selectedIdentity else { throw ProjectSessionAppError.grantChanged }
        _ = try fileAccessExecutor.validatedProjectAuthorizationDirectory(url.resolvingSymlinksInPath().standardizedFileURL.path)
        let projectID = try grants.registerNativeSelection(url, displayName: url.lastPathComponent,
            trustedInstructions: choice == .alertFirstButtonReturn ? candidate : nil)
        do {
            let project = try grants.resolve(id: projectID)
            let directory = try grants.directory(for: project)
            chat.newSession(projectID: projectID, projectName: url.lastPathComponent, workingDirectory: directory.path)
            guard chat.sessions.first(where: { $0.id == chat.activeSessionID })?.projectID == projectID else { throw ProjectSessionAppError.grantUnavailable }
            if let candidate, choice != .alertFirstButtonReturn {
                if let sessionID = chat.activeSessionID { initialInstructionRefusals[sessionID.uuidString] = candidate.sourceFileSHA256 }
                chat.noteProjectInstructionsNotLoaded()
            }
            return true
        } catch { try? grants.revoke(id: projectID); throw error }
    }

    func revokeProject(id: String) throws { try grants.revoke(id: id) }
    func isProjectAvailable(id: String) -> Bool {
        guard productionBindingActive,
              let project = try? grants.resolve(id: id),
              let directory = try? grants.directory(for: project) else { return false }
        return isWithinExecutionRoots(directory)
    }

    /// Read-only access to a completed task's result does not require a running
    /// run, but still requires the current native project grant and directory.
    func isTaskFileProjectAuthorized(projectID: String, workingDirectory: String) -> Bool {
        guard productionBindingActive,
              let project = try? grants.resolve(id: projectID),
              let directory = try? grants.directory(for: project),
              directory.path == workingDirectory else { return false }
        return isWithinExecutionRoots(directory)
    }

    /// Resolve only a current native grant for the frozen physical directory.
    /// Re-authorizing a revoked directory creates a distinct grant ID.
    func taskArtifactProjectID(workingDirectory: String) -> String? {
        guard productionBindingActive else { return nil }
        let physical = URL(fileURLWithPath: workingDirectory, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path
        return grants.list().first {
            isTaskFileProjectAuthorized(projectID: $0.projectID, workingDirectory: physical)
        }?.projectID
    }

    func isWorkspaceAuthorized(_ binding: TargetWorkspaceBinding) -> Bool {
        guard productionBindingActive,
              let record = records.first(where: { $0.runID == binding.runID }),
              record.source == binding.source, record.targetID == binding.targetSessionID,
              record.taskID == binding.taskID, record.projectID == binding.projectID,
              chat.hasProjectTarget(binding.targetSessionID, taskID: binding.taskID,
                  runID: binding.runID),
              let project = try? grants.resolve(id: binding.projectID),
              let directory = try? grants.directory(for: project),
              directory.path == binding.workingDirectory,
              isWithinExecutionRoots(directory),
              taskStore.taskSnapshot(runID: binding.runID)?.status == .running,
              taskStore.controlSnapshot(taskID: binding.taskID,
                  parentID: binding.source.taskID)?.runID == binding.runID else { return false }
        return true
    }

    /// A same-domain production rebind keeps one SessionStore, journal and
    /// grant registry while adopting the next-turn file authority snapshot.
    func rebindFileAccess(_ executor: BuiltinToolExecutor) {
        fileAccessExecutor = executor
        productionBindingActive = true
    }

    /// Different persistence domains cannot share this handler. Old active
    /// tool chains may still hold it, so reject at the handler boundary too.
    func disableProductionBinding() { productionBindingActive = false }

    /// Run only after ChatStore has loaded the canonical sessions and sidecar.
    /// A process restart cannot assert that an old running ledger still owns
    /// an executing task; it projects an explicit recovery state instead.
    func reconcileRecoveredReservations() {
        for record in records {
            guard chat.hasSourceCard(record.cardID, sourceID: record.source.sessionID) else { continue }
            let snapshot = taskStore.snapshot(taskID: record.taskID, parentID: record.source.taskID)
            if record.phase != "committed" {
                chat.updateSourceCard(runID: record.runID, status: .unavailable)
            } else if snapshot?.status == .running && !chat.isProjectTaskRunning(record.targetID) {
                chat.updateSourceCard(runID: record.runID, status: .unavailable)
            } else if snapshot?.status == .failed || snapshot?.status == .cancelled {
                chat.updateSourceCard(runID: record.runID, status: .failed)
            }
        }
    }

    private func validSource(_ identity: ParentRuntimeIdentity) -> Bool {
        identity.isValid && identity.sessionID == identity.conversationID
            && UUID(uuidString: identity.sessionID) != nil
            && chat.hasSession(UUID(uuidString: identity.sessionID)!)
            && sessionStore.loadSession(id: identity.sessionID) != nil
    }

    private func validCurrentTurn(_ identity: ParentRuntimeIdentity, requiresCurrentAuthority: Bool = false) async -> Bool {
        guard let context = AgentExecutionContext.current,
              context.hasVerifiedParentRuntime,
              context.parentRuntimeIdentity == identity,
              context.currentConversationID == identity.conversationID,
              let handle = context.parentTurnHandle else { return false }
        guard await handle.acceptsToolEvent() else { return false }
        guard await handle.isActive() else { return false }
        let parentCancelled = await handle.isCancelled()
        guard !parentCancelled else { return false }
        if requiresCurrentAuthority, await context.parentAuthorityCheck?() == false { return false }
        return !Task.isCancelled
    }

    private func isWithinExecutionRoots(_ directory: URL) -> Bool {
        guard productionBindingActive,
              let validated = try? fileAccessExecutor.validatedTargetWorkspaceDirectory(directory.path)
        else { return false }
        return validated.path == directory.path
    }

    private func partial(for record: Reservation) -> ProjectSessionPartialCreation {
        ProjectSessionPartialCreation(source: record.source, projectID: record.projectID,
            idempotencyKey: record.key, recoveryReceiptID: record.cardID)
    }

    private func setPhase(_ phase: String, key: String) throws {
        guard let index = records.firstIndex(where: { $0.key == key }) else {
            throw ProjectSessionAppError.persistenceUncertain
        }
        records[index].phase = phase
        try persistJournal()
    }

    private func persistJournal() throws {
        let data = try JSONEncoder().encode(Journal(version: 1, reservations: records))
        guard data.count <= 1024 * 1024 else { throw ProjectSessionAppError.persistenceUncertain }
        try ProjectSessionLocalFile.write(data, to: journalURL)
    }

    private static func digest(_ request: ProjectSessionCreateRequest) -> String {
        let fields = [request.source.identity.sessionID, request.source.identity.turnID,
            request.source.identity.taskID, request.project.projectID,
            request.project.workdirReference, request.title, request.initialTask,
            request.capsuleReference ?? "", request.switchAfterCreate ? "1" : "0"]
        return SHA256.hash(data: Data(fields.joined(separator: "\u{0}").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    static func targetInstruction(_ task: String,
        capsule: ProjectSessionCapsuleSnapshot?) throws -> String {
        guard let capsule else { return task }
        let instruction = task + "\n\n用户已批准从本次来源消息转交的资料：\n" + capsule.material
        guard instruction.count <= 32_000 else { throw ProjectSessionAppError.creationNotAuthorized }
        return instruction
    }
}

/// 项目授权时可自动加入可访问目录的路径判定（2026-11-15 用户批准）。
/// 原生选择框里选中即是明确授权；根目录、主目录本身和系统目录不自动加入。
enum ProjectFolderAutoMount {
    static let systemPrefixes = ["/System", "/Library", "/usr", "/bin", "/sbin", "/etc", "/private/etc",
                                 "/private/var/db", "/Applications", "/cores", "/dev", "/opt"]

    static func eligiblePath(for url: URL, home: String = NSHomeDirectory()) -> String? {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let homePath = URL(fileURLWithPath: home).resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasPrefix("/"), path != "/", path != homePath else { return nil }
        // APFS 默认不区分大小写：按小写比较，避免 /system、/USR 之类绕过。
        let lower = path.lowercased()
        guard lower != homePath.lowercased() else { return nil }
        guard !systemPrefixes.contains(where: { lower == $0.lowercased() || lower.hasPrefix($0.lowercased() + "/") })
        else { return nil }
        return path
    }
}
