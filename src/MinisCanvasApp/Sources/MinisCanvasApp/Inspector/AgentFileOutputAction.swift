import AppKit
import Foundation
import MinisCore
import SwiftUI
import CryptoKit
import Darwin

/// A user-triggered action on a successful, session-bound file_write/file_edit result.
/// The action never trusts the path displayed by the inspector as an authorization.
enum AgentFileOutputIntent {
    case systemOpen
    case finderReveal
    case copySafePath
    case preview
}

enum AgentFileOutputFailure: Error, Equatable {
    case unbound
    case unavailable
    case missing
    case permissionDenied
    case outOfBounds
    case notAFile
    case actionFailed
    case previewUnsupported
    case stale
    /// 大文件的摘要正在后台核验，稍后再点即可（不再在主线程逐字节读）。
    case verifying

    var message: String {
        switch self {
        case .unbound: return "文件变更已不属于当前会话，操作已阻止。"
        case .unavailable: return "文件访问边界尚未就绪，操作已阻止。"
        case .missing: return "文件已不存在或已删除，无法操作。"
        case .permissionDenied: return "没有读取此文件的权限，操作已阻止。"
        case .outOfBounds: return "文件目标超出授权工作区，操作已阻止。"
        case .notAFile: return "目标不是普通文件，操作已阻止。"
        case .actionFailed: return "系统未能完成文件操作。"
        case .previewUnsupported: return "当前支持文本、Markdown、图片、PDF 和视频预览；这个类型可尝试系统打开。"
        case .stale: return "文件内容已变化，无法打开这次生成的文件。"
        case .verifying: return "文件较大，正在后台核验内容，请稍后再点一次。"
        }
    }
}

enum AgentFileOutputOutcome: Equatable {
    case completed
    case failed(AgentFileOutputFailure)

    var message: String {
        switch self {
        case .completed: return "文件操作已完成。"
        case .failed(let failure): return failure.message
        }
    }
}

enum AgentFileOutputProbe {
    case readableFile
    case missing
    case permissionDenied
    case notAFile
    case unavailable
}

struct GeneratedFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
}

/// Reused at the user click and immediately before the preview's background
/// read. It resolves both the authorized root and candidate to physical paths
/// without turning a displayed path into authority.
enum AgentFileOutputTargetResolver {
    static func generatedFileIdentity(_ url: URL) -> GeneratedFileIdentity? {
        var item = stat()
        guard lstat(url.path, &item) == 0, item.st_mode & S_IFMT == S_IFREG else { return nil }
        return GeneratedFileIdentity(device: UInt64(item.st_dev), inode: UInt64(item.st_ino), size: item.st_size,
            modifiedSeconds: Int64(item.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(item.st_mtimespec.tv_nsec),
            changedSeconds: Int64(item.st_ctimespec.tv_sec), changedNanoseconds: Int64(item.st_ctimespec.tv_nsec))
    }
    /// Task artifacts use the existing ledger record and an independently
    /// revalidated canonical binding, never a synthesized ActionRecord.
    static func resolveTaskArtifact(
        access: TaskCenterFileArtifactAccess,
        validateBinding: () -> Bool,
        authorizeTarget: (URL) -> Bool,
        probe: (URL) -> AgentFileOutputProbe,
        digest: (URL) -> String?
    ) -> Result<URL, AgentFileOutputFailure> {
        guard validateBinding(), let binding = access.record.taskArtifactBinding,
              binding.isValid, let expected = access.record.outputSHA256 else { return .failure(.unbound) }
        let root = URL(fileURLWithPath: binding.workingDirectory, isDirectory: true).standardizedFileURL
        guard root.resolvingSymlinksInPath().standardizedFileURL == root else { return .failure(.outOfBounds) }
        let target: URL
        switch resolve(path: access.record.path, workspaceRoot: access.workspaceRoot, probe: probe) {
        case .failure(let failure): return .failure(failure)
        case .success(let url): target = url
        }
        switch resolve(path: target.path, workspaceRoot: binding.workingDirectory, probe: probe) {
        case .failure(let failure): return .failure(failure)
        case .success(let url):
            guard authorizeTarget(url) else { return .failure(.outOfBounds) }
            guard digest(url) == expected else { return .failure(.stale) }
            guard validateBinding() else { return .failure(.unbound) }
            guard authorizeTarget(url) else { return .failure(.outOfBounds) }
            return .success(url)
        }
    }

    /// The verified descriptor must still describe the resolved regular file
    /// before any bytes are read. System-open races after validation remain
    /// external; this is not a claim to lock another application's file.
    static func generatedFileHandle(_ url: URL) -> FileHandle? {
        let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var descriptor = stat()
        var current = stat()
        guard fstat(fd, &descriptor) == 0,
              lstat(url.path, &current) == 0,
              descriptor.st_mode & S_IFMT == S_IFREG,
              descriptor.st_dev == current.st_dev, descriptor.st_ino == current.st_ino,
              url.resolvingSymlinksInPath().standardizedFileURL == url.standardizedFileURL else {
            Darwin.close(fd)
            return nil
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// 已核验摘要缓存：键含文件身份（设备、inode、大小、修改与变更时间），文件一变就自然失效。
    private final class DigestCache: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: String] = [:]
        private var pending: Set<String> = []
        func key(_ url: URL, _ identity: GeneratedFileIdentity) -> String {
            "\(url.path)|\(identity.device)|\(identity.inode)|\(identity.size)|\(identity.modifiedSeconds).\(identity.modifiedNanoseconds)|\(identity.changedSeconds).\(identity.changedNanoseconds)"
        }
        func value(for key: String) -> String? { lock.lock(); defer { lock.unlock() }; return items[key] }
        func store(_ digest: String, for key: String) {
            lock.lock(); defer { lock.unlock() }
            if items.count >= 64 { items.removeAll() }
            items[key] = digest
        }
        func beginPending(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return pending.insert(key).inserted }
        func endPending(_ key: String) { lock.lock(); defer { lock.unlock() }; pending.remove(key) }
        func isPending(prefix: String) -> Bool { lock.lock(); defer { lock.unlock() }; return pending.contains { $0.hasPrefix(prefix) } }
    }
    private static let digestCache = DigestCache()
    /// 超过这个大小的文件在主线程点击时不同步算摘要，改为后台核验。
    static let inlineDigestLimitBytes = 8 * 1_048_576

    /// 这个文件的摘要是否正在后台核验。
    static func isDigestVerificationPending(_ url: URL) -> Bool {
        digestCache.isPending(prefix: url.path + "|")
    }

    /// 主线程点击用：命中缓存直接返回；小文件同步算；大文件交给后台，本次返回 nil（调用方可查 isDigestVerificationPending）。
    static func generatedFileDigestDeferringLarge(_ url: URL) -> String? {
        guard let identity = generatedFileIdentity(url) else { return nil }
        let key = digestCache.key(url, identity)
        if let cached = digestCache.value(for: key) { return cached }
        if identity.size <= Int64(inlineDigestLimitBytes) { return generatedFileDigest(url) }
        guard digestCache.beginPending(key) else { return nil }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = generatedFileDigest(url)
            digestCache.endPending(key)
        }
        return nil
    }

    static func generatedFileDigest(_ url: URL) -> String? {
        let cacheKey = generatedFileIdentity(url).map { digestCache.key(url, $0) }
        if let cacheKey, let cached = digestCache.value(for: cacheKey) { return cached }
        guard let handle = generatedFileHandle(url) else { return nil }
        defer { try? handle.close() }
        var before = stat()
        // 超过 100MB 的文件不逐字节核验（按“已变化”处理，用户可在访达中查看）。
        guard fstat(handle.fileDescriptor, &before) == 0, before.st_size <= 100 * 1_048_576 else { return nil }
        var hash = SHA256()
        do {
            while let bytes = try handle.read(upToCount: 65_536), !bytes.isEmpty { hash.update(data: bytes) }
        } catch { return nil }
        var after = stat()
        guard fstat(handle.fileDescriptor, &after) == 0,
              generatedFileStillMatches(handle, url: url),
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { return nil }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        if let cacheKey, generatedFileIdentity(url).map({ digestCache.key(url, $0) }) == cacheKey {
            digestCache.store(digest, for: cacheKey)
        }
        return digest
    }

    static func generatedFileStillMatches(_ handle: FileHandle, url: URL) -> Bool {
        var descriptor = stat()
        var current = stat()
        return fstat(handle.fileDescriptor, &descriptor) == 0
            && lstat(url.path, &current) == 0
            && descriptor.st_mode & S_IFMT == S_IFREG
            && current.st_mode & S_IFMT == S_IFREG
            && descriptor.st_dev == current.st_dev && descriptor.st_ino == current.st_ino
            && url.resolvingSymlinksInPath().standardizedFileURL == url.standardizedFileURL
    }

    static func resolve(
        path: String,
        workspaceRoot: String?,
        probe: (URL) -> AgentFileOutputProbe
    ) -> Result<URL, AgentFileOutputFailure> {
        guard let workspaceRoot, workspaceRoot.hasPrefix("/") else {
            return .failure(.unavailable)
        }
        // Standardizing an existing /private/var root can remove /private,
        // while standardizing an absent absolute leaf keeps that spelling.
        // A raw, component-bound child of the declared root can use the
        // already-supported relative input. Preserve all original lexical
        // refusals; every input still goes through confine and the physical
        // boundary below, before any filesystem probe.
        let root = URL(fileURLWithPath: workspaceRoot, isDirectory: true).standardizedFileURL
        let physicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        var rootSpellings = [String(workspaceRoot.reversed().drop(while: { $0 == "/" }).reversed())]
        // The ledger may already hold /var while the recorded tool argument
        // used its /private/var alias. Resolve only the authorized root here,
        // never the unconfined candidate, and accept this spelling only when
        // it denotes that same current physical root.
        if !workspaceRoot.utf8.contains(0), let canonical = realpath(workspaceRoot, nil) {
            defer { free(canonical) }
            let spelling = String(cString: canonical)
            if URL(fileURLWithPath: spelling, isDirectory: true)
                .resolvingSymlinksInPath().standardizedFileURL == physicalRoot {
                rootSpellings.append(spelling)
            }
        }
        let confinedInput: String
        if !path.contains("~"), !path.contains("\u{1}"),
           !path.split(separator: "/").contains(".."),
           let rootSpelling = rootSpellings.first(where: { !$0.isEmpty && path.hasPrefix($0 + "/") }) {
            confinedInput = String(path.dropFirst(rootSpelling.count + 1))
        } else {
            confinedInput = path
        }
        guard let relative = FileChangeLedger.confine(
            relativeToWorkspaceRoot: confinedInput,
            workspaceRoot: workspaceRoot
        ) else {
            return .failure(.outOfBounds)
        }
        // A missing leaf may retain the original /private/var spelling while
        // its existing root resolves to /var. Anchor the already-confined
        // relative path to that physical root before resolving the target;
        // the unchanged physical boundary still rejects escaping symlinks
        // before any probe or action.
        let physicalTarget = physicalRoot.appendingPathComponent(relative, isDirectory: false)
            .standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        guard AgentOutputPhysicalPathBoundaryContract.isPhysicalPath(
            physicalTarget.path, inside: physicalRoot.path
        ) else {
            return .failure(.outOfBounds)
        }
        switch probe(physicalTarget) {
        case .readableFile: return .success(physicalTarget)
        case .missing: return .failure(.missing)
        case .permissionDenied: return .failure(.permissionDenied)
        case .notAFile: return .failure(.notAFile)
        case .unavailable: return .failure(.unavailable)
        }
    }

    static func fileSystemProbe(_ url: URL) -> AgentFileOutputProbe {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
                return .notAFile
            }
            return FileManager.default.isReadableFile(atPath: url.path)
                ? .readableFile : .permissionDenied
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .missing
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            return .permissionDenied
        } catch {
            return .unavailable
        }
    }
}

/// The existing inspector row receives only this action. The composition root
/// supplies the current verified ActionRecord and the same workspace root used
/// by the production file-change ledger; no path or approval is cached here.
@MainActor
enum AgentFileOutputActionConsumer {
    /// Hashing stays off the main actor; the descriptor/path and file metadata
    /// proof are checked before handing a validated URL to the existing action.
    static func performTaskArtifactInApp(navigation: TaskCenterFileArtifactNavigation,
                                         consumer: TaskCenterControlConsumer,
                                         intent: AgentFileOutputIntent) async -> AgentFileOutputOutcome {
        guard consumer.fileArtifactPresentationAuthorized(navigation: navigation),
              let access = consumer.fileArtifactAccess(navigation: navigation) else { return .failed(.unbound) }
        let verified: Result<(URL, GeneratedFileIdentity), AgentFileOutputFailure> = await Task.detached {
            var identity: GeneratedFileIdentity?
            let result = AgentFileOutputTargetResolver.resolveTaskArtifact(
                access: access,
                validateBinding: { consumer.fileArtifactAccess(navigation: navigation) == access },
                authorizeTarget: { consumer.fileArtifactTargetAuthorized(navigation: navigation, target: $0) },
                probe: AgentFileOutputTargetResolver.fileSystemProbe,
                digest: { url in
                    guard let before = AgentFileOutputTargetResolver.generatedFileIdentity(url),
                          let hash = AgentFileOutputTargetResolver.generatedFileDigest(url),
                          AgentFileOutputTargetResolver.generatedFileIdentity(url) == before else { return nil }
                    identity = before
                    return hash
                }
            )
            switch result {
            case .failure(let failure): return .failure(failure)
            case .success(let url):
                guard let identity else { return .failure(.stale) }
                return .success((url, identity))
            }
        }.value
        let target: URL
        let identity: GeneratedFileIdentity
        switch verified {
        case .failure(let failure): return .failed(failure)
        case .success(let proof): (target, identity) = proof
        }
        guard consumer.fileArtifactPresentationAuthorized(navigation: navigation, target: target) else { return .failed(.unbound) }
        return performTaskArtifact(
            access: access, validateBinding: { consumer.fileArtifactPresentationAuthorized(navigation: navigation, target: target) && consumer.fileArtifactAccess(navigation: navigation) == access },
            authorizeTarget: { consumer.fileArtifactTargetAuthorized(navigation: navigation, target: $0) },
            intent: intent, probe: AgentFileOutputTargetResolver.fileSystemProbe,
            digest: { candidate in
                candidate == target && AgentFileOutputTargetResolver.generatedFileIdentity(candidate) == identity
                    ? navigation.outputSHA256 : nil
            },
            open: { NSWorkspace.shared.open($0) },
            reveal: { NSWorkspace.shared.selectFile($0.path, inFileViewerRootedAtPath: $0.deletingLastPathComponent().path) },
            copy: { NSPasteboard.general.clearContents(); return NSPasteboard.general.setString($0, forType: .string) }
        )
    }

    /// “系统打开”统一套用可执行类型拦截：可执行/自动运行类型只在访达显示，
    /// 脚本类显式用文本编辑器打开，其余才交给系统默认程序。
    static func guardedSystemOpen(
        _ url: URL,
        open: (URL) -> Bool,
        reveal: (URL) -> Bool,
        openText: ((URL) -> Bool)?
    ) -> Bool {
        switch TranscriptLocalFileLink.openDisposition(for: url) {
        case .systemOpen: return open(url)
        case .textEditor: return (openText ?? { TranscriptLocalFileLink.openInTextEditor($0) })(url)
        case .revealOnly: return reveal(url)
        }
    }

    static func performTaskArtifact(
        access: TaskCenterFileArtifactAccess,
        validateBinding: () -> Bool,
        authorizeTarget: (URL) -> Bool,
        intent: AgentFileOutputIntent,
        probe: (URL) -> AgentFileOutputProbe,
        digest: (URL) -> String?,
        open: (URL) -> Bool,
        reveal: (URL) -> Bool,
        copy: (String) -> Bool,
        preview: (URL) -> Bool = { _ in false },
        openText: ((URL) -> Bool)? = nil
    ) -> AgentFileOutputOutcome {
        let target: URL
        switch AgentFileOutputTargetResolver.resolveTaskArtifact(
            access: access, validateBinding: validateBinding, authorizeTarget: authorizeTarget,
            probe: probe, digest: digest
        ) {
        case .failure(let reason): return .failed(reason)
        case .success(let url): target = url
        }
        let succeeded: Bool
        switch intent {
        case .systemOpen:
            succeeded = guardedSystemOpen(target, open: open, reveal: reveal, openText: openText)
        case .finderReveal: succeeded = reveal(target)
        case .copySafePath: succeeded = copy(target.path)
        case .preview:
            guard FileKind.agentPreviewSupported(for: target) else { return .failed(.previewUnsupported) }
            succeeded = preview(target)
        }
        return succeeded ? .completed : .failed(.actionFailed)
    }

    static func perform(
        change: AgentFileChangeRecord,
        viewerSessionID: String?,
        records: [ActionRecord],
        workspaceRoot: String?,
        intent: AgentFileOutputIntent,
        probe: (URL) -> AgentFileOutputProbe,
        open: (URL) -> Bool,
        reveal: (URL) -> Bool,
        copy: (String) -> Bool,
        preview: (URL) -> Bool = { _ in false },
        openText: ((URL) -> Bool)? = nil
    ) -> AgentFileOutputOutcome {
        guard let sessionID = viewerSessionID, !sessionID.isEmpty,
              records.contains(where: {
                  $0.succeeded && $0.sourceSessionID == sessionID &&
                  $0.fileChange == change && $0.toolName == change.toolName &&
                  (change.toolName == "file_write" || change.toolName == "file_edit")
              }) else {
            return .failed(.unbound)
        }
        let physicalTarget: URL
        switch AgentFileOutputTargetResolver.resolve(
            path: change.path, workspaceRoot: workspaceRoot, probe: probe
        ) {
        case .success(let url): physicalTarget = url
        case .failure(let failure): return .failed(failure)
        }

        let succeeded: Bool
        switch intent {
        case .systemOpen:
            succeeded = guardedSystemOpen(physicalTarget, open: open, reveal: reveal, openText: openText)
        case .finderReveal: succeeded = reveal(physicalTarget)
        case .copySafePath: succeeded = copy(physicalTarget.path)
        case .preview:
            guard FileKind.agentPreviewSupported(for: physicalTarget) else {
                return .failed(.previewUnsupported)
            }
            succeeded = preview(physicalTarget)
        }
        return succeeded ? .completed : .failed(.actionFailed)
    }

    /// 已证实产物行的操作：按台账记录（会话、diffID）和 outputSHA256 重新核验，不依赖内存里的
    /// ActionHistory；根取记录自带的 workspaceRoot，缺失时才用台账主根。
    /// “系统打开”同样走可执行类型拦截。
    static func performLedgerArtifact(
        artifact: ProducedFileArtifactEvidence,
        ledgerRecord: FileChangeRecord?,
        fallbackRoot: String?,
        viewerSessionID: String?,
        intent: AgentFileOutputIntent,
        preview: (URL) -> Bool,
        probe: (URL) -> AgentFileOutputProbe,
        digest: (URL) -> String?,
        open: (URL) -> Bool,
        reveal: (URL) -> Bool,
        copy: (String) -> Bool
    ) -> AgentFileOutputOutcome {
        guard let sessionID = viewerSessionID, !sessionID.isEmpty,
              let record = ledgerRecord, record.sessionID == sessionID,
              record.diffID == artifact.diffID, record.path == artifact.path,
              let expected = record.outputSHA256, expected == artifact.outputSHA256 else {
            return .failed(.unbound)
        }
        let target: URL
        switch AgentFileOutputTargetResolver.resolve(
            path: record.path, workspaceRoot: record.workspaceRoot ?? fallbackRoot, probe: probe
        ) {
        case .failure(let failure): return .failed(failure)
        case .success(let url): target = url
        }
        guard digest(target) == expected else {
            return .failed(AgentFileOutputTargetResolver.isDigestVerificationPending(target) ? .verifying : .stale)
        }
        let succeeded: Bool
        switch intent {
        case .systemOpen: succeeded = guardedSystemOpen(target, open: open, reveal: reveal, openText: nil)
        case .finderReveal: succeeded = reveal(target)
        case .copySafePath: succeeded = copy(target.path)
        case .preview:
            guard FileKind.agentPreviewSupported(for: target) else { return .failed(.previewUnsupported) }
            succeeded = preview(target)
        }
        return succeeded ? .completed : .failed(.actionFailed)
    }

    static func performInApp(
        change: AgentFileChangeRecord,
        viewerSessionID: String?,
        records: [ActionRecord],
        workspaceRoot: String?,
        intent: AgentFileOutputIntent,
        preview: (URL) -> Bool
    ) -> AgentFileOutputOutcome {
        perform(
            change: change,
            viewerSessionID: viewerSessionID,
            records: records,
            workspaceRoot: workspaceRoot,
            intent: intent,
            probe: AgentFileOutputTargetResolver.fileSystemProbe,
            open: { NSWorkspace.shared.open($0) },
            reveal: {
                NSWorkspace.shared.selectFile(
                    $0.path, inFileViewerRootedAtPath: $0.deletingLastPathComponent().path
                )
            },
            copy: {
                NSPasteboard.general.clearContents()
                return NSPasteboard.general.setString($0, forType: .string)
            },
            preview: preview
        )
    }

    static func fileSystemProbe(_ url: URL) -> AgentFileOutputProbe {
        AgentFileOutputTargetResolver.fileSystemProbe(url)
    }
}

private struct AgentFileOutputActionKey: EnvironmentKey {
    static var defaultValue: ((AgentFileChangeRecord, AgentFileOutputIntent) -> AgentFileOutputOutcome)? { nil }
}

private struct AgentArtifactOutputActionKey: EnvironmentKey {
    static var defaultValue: ((ProducedFileArtifactEvidence, AgentFileOutputIntent) -> AgentFileOutputOutcome)? { nil }
}

extension EnvironmentValues {
    /// 已证实产物行的预览、系统打开、访达显示、复制路径入口（点击时重新核验）。
    var agentArtifactOutputAction: ((ProducedFileArtifactEvidence, AgentFileOutputIntent) -> AgentFileOutputOutcome)? {
        get { self[AgentArtifactOutputActionKey.self] }
        set { self[AgentArtifactOutputActionKey.self] = newValue }
    }
}

private struct TranscriptImagePreviewActionKey: EnvironmentKey {
    static var defaultValue: ((URL) -> Bool)? { nil }
}

extension EnvironmentValues {
    /// 对话里的本地图片缩略图点击后，在右侧面板预览（路径已在生成缩略图时校验过）。
    var transcriptImagePreviewAction: ((URL) -> Bool)? {
        get { self[TranscriptImagePreviewActionKey.self] }
        set { self[TranscriptImagePreviewActionKey.self] = newValue }
    }
}

extension EnvironmentValues {
    var agentFileOutputAction: ((AgentFileChangeRecord, AgentFileOutputIntent) -> AgentFileOutputOutcome)? {
        get { self[AgentFileOutputActionKey.self] }
        set { self[AgentFileOutputActionKey.self] = newValue }
    }
}
