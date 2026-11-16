import CryptoKit
import Darwin
import Foundation
import Testing
@testable import MinisCanvasApp

private final class RecoveryStopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
    }

    var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }
}

private final class RecoveryAttackState: @unchecked Sendable {
    private let lock = NSLock()
    private var renameCount = 0
    private var symlinkCount = 0
    private var restoreCount = 0
    private var failures: [String] = []

    func renamed() { lock.lock(); renameCount += 1; lock.unlock() }
    func symlinked() { lock.lock(); symlinkCount += 1; lock.unlock() }
    func restored() { lock.lock(); restoreCount += 1; lock.unlock() }
    func failure(_ message: String) { lock.lock(); failures.append(message); lock.unlock() }

    var summary: (renames: Int, symlinks: Int, restores: Int, failures: [String]) {
        lock.lock(); defer { lock.unlock() }
        return (renameCount, symlinkCount, restoreCount, failures)
    }
}

/// Focused R1/P3-RECOVERY coverage for the durable DraftStore seam.
/// These tests intentionally exercise disk-shaped inputs rather than an
/// in-memory mock so crash/restart handling stays tied to the production path.
@Suite("Session draft recovery integrity")
struct SessionDraftsRecoveryTests {
    private func makeStore() -> DraftStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-recovery-drafts-\(UUID().uuidString)", isDirectory: true)
        return DraftStore(directory: directory)
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func writeEnvelope(
        _ store: DraftStore,
        key: String,
        payload: Data,
        checksum: String?
    ) throws {
        try FileManager.default.createDirectory(
            at: store.draftsDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: store.directory.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: store.draftsDirectory.path
        )
        let envelope = DraftEnvelope(
            schemaVersion: DraftStore.currentSchemaVersion,
            savedAt: Date(timeIntervalSince1970: 1),
            payload: payload,
            payloadSHA256: checksum
        )
        let data = try JSONEncoder().encode(envelope)
        try data.write(
            to: store.draftsDirectory.appendingPathComponent("\(key).json"),
            options: .atomic
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: store.draftsDirectory.appendingPathComponent("\(key).json").path
        )
    }

    @Test func ownerOwnedLegacyRootIsHardenedBeforeFirstWrite() throws {
        let store = makeStore()
        defer {
            do { try FileManager.default.removeItem(at: store.directory) }
            catch { Issue.record(error) }
        }

        // A sibling persistence store may have created the shared root with
        // Foundation's default 0755 mode before DraftStore is attached.
        try FileManager.default.createDirectory(
            at: store.directory,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: store.directory.path
        )

        store.scheduleSave(key: "legacy-root", payload: Data("payload".utf8))
        #expect(store.flushNow(key: "legacy-root"))
        #expect(store.load(key: "legacy-root") == Data("payload".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: store.directory.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        #expect(permissions == 0o700)
    }

    @Test func partialPayloadWithValidEnvelopeIsRejectedAndQuarantined() throws {
        let store = makeStore()
        defer {
            do { try FileManager.default.removeItem(at: store.directory) }
            catch { Issue.record(error) }
        }

        let complete = Data("complete draft payload".utf8)
        let partial = Data("complete draft".utf8)
        try writeEnvelope(store, key: "session", payload: partial, checksum: digest(complete))

        #expect(store.load(key: "session") == nil)
        #expect(store.lastLoadError(for: "session") == .decodeFailed)
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: store.quarantineDirectory,
            includingPropertiesForKeys: nil
        )
        #expect(quarantined.count == 1)
        let preserved = try JSONDecoder().decode(
            DraftEnvelope.self,
            from: Data(contentsOf: try #require(quarantined.first))
        )
        #expect(preserved.payload == partial)
        #expect(preserved.payloadSHA256 == digest(complete))
    }

    @Test func repeatedCorruptWritesPreserveEveryQuarantineSnapshot() throws {
        let store = makeStore()
        defer {
            do { try FileManager.default.removeItem(at: store.directory) }
            catch { Issue.record(error) }
        }

        try writeEnvelope(store, key: "session", payload: Data("first".utf8), checksum: "wrong")
        #expect(store.load(key: "session") == nil)
        try writeEnvelope(store, key: "session", payload: Data("second".utf8), checksum: "wrong")
        #expect(store.load(key: "session") == nil)

        let files = try FileManager.default.contentsOfDirectory(
            at: store.quarantineDirectory,
            includingPropertiesForKeys: nil
        )
        #expect(files.count == 2)
        let payloads = try Set(files.map {
            try JSONDecoder().decode(DraftEnvelope.self, from: Data(contentsOf: $0)).payload
        })
        #expect(payloads == [Data("first".utf8), Data("second".utf8)])
    }

    @Test func legacyEnvelopeWithoutChecksumRemainsReadableAfterRestart() throws {
        let store = makeStore()
        defer {
            do { try FileManager.default.removeItem(at: store.directory) }
            catch { Issue.record(error) }
        }

        try writeEnvelope(store, key: "legacy", payload: Data("v1".utf8), checksum: nil)
        let restarted = DraftStore(directory: store.directory)
        #expect(restarted.load(key: "legacy") == Data("v1".utf8))
        #expect(restarted.lastLoadError(for: "legacy") == nil)
    }

    @Test func restartRejectsEnvelopeOwnedByAnotherSession() throws {
        let store = makeStore()
        defer {
            do { try FileManager.default.removeItem(at: store.directory) }
            catch { Issue.record(error) }
        }

        let ownerSessionID = "owner-session"
        let requestedSessionID = "requested-session"
        let identity = try ChatTranscriptIdentity(
            sessionID: ownerSessionID,
            turnID: "turn-1",
            streamID: "stream-1"
        )
        let transcript = ChatTranscriptEnvelope(
            schemaVersion: ChatTranscriptEnvelope.currentSchemaVersion,
            identity: identity,
            sequence: 0,
            terminal: true,
            entries: [ChatTranscriptEntry(role: .assistant, text: "owner")],
            savedAt: Date(timeIntervalSince1970: 1)
        )
        let payload = try JSONEncoder().encode(transcript)
        // A valid envelope under the requested key models a stale rename or
        // recovery copy; key lookup alone must not establish session identity.
        try writeEnvelope(
            store,
            key: ChatTranscriptPersistence.draftKey(sessionID: requestedSessionID),
            payload: payload,
            checksum: digest(payload)
        )

        let persistence = ChatTranscriptPersistence(draftStore: store)
        #expect(throws: ChatTranscriptPersistenceError.identityConflict) {
            try persistence.reopen(sessionID: requestedSessionID)
        }
        let projection = persistence.reopenProjection(sessionID: requestedSessionID)
        #expect(projection.state == .recoveryRequired)
        #expect(projection.recoveryAction == .reopenOrDiscard)
    }

    @Test func failedAtomicSaveRetainsPreviouslyCommittedPayload() throws {
        let store = makeStore()
        defer {
            do {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: store.draftsDirectory.path
                )
                try FileManager.default.removeItem(at: store.directory)
            } catch { Issue.record(error) }
        }

        store.scheduleSave(key: "stable", payload: Data("committed".utf8))
        #expect(store.flushNow(key: "stable"))

        // A failed atomic replacement must leave the old committed file
        // readable. Restricting the containing directory makes the failure
        // deterministic for the normal non-root test user.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: store.draftsDirectory.path
        )
        store.scheduleSave(key: "stable", payload: Data("interrupted".utf8))
        #expect(!store.flushNow(key: "stable"))

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: store.draftsDirectory.path
        )
        #expect(store.load(key: "stable") == Data("committed".utf8))
    }

    @Test func recoveryDiagnosticDoesNotExposeCorruptPayload() throws {
        let store = makeStore()
        defer {
            do { try FileManager.default.removeItem(at: store.directory) }
            catch { Issue.record(error) }
        }

        let secret = Data("Bearer recovery-secret-value".utf8)
        try FileManager.default.createDirectory(
            at: store.draftsDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: store.directory.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: store.draftsDirectory.path
        )
        try secret.write(
            to: store.draftsDirectory.appendingPathComponent("session.json"),
            options: .atomic
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: store.draftsDirectory.appendingPathComponent("session.json").path
        )

        #expect(store.load(key: "session") == nil)
        let diagnostic = String(describing: store.lastLoadError(for: "session"))
        #expect(!diagnostic.contains("recovery-secret-value"))
        #expect(!diagnostic.contains("Bearer"))
    }

    @Test func ordinaryDraftRejectsWorldReadablePermissions() throws {
        let store = makeStore()
        defer {
            do { try FileManager.default.removeItem(at: store.directory) }
            catch { Issue.record(error) }
        }
        try writeEnvelope(store, key: "private", payload: Data("payload".utf8), checksum: nil)
        let path = store.draftsDirectory.appendingPathComponent("private.json").path
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)

        // The owner-mismatch branch is covered by the same fstat contract;
        // this fixture can safely exercise the permission-negative without
        // impersonating another uid in a shared test runner.
        #expect(store.load(key: "private") == nil)
        #expect(store.lastLoadError(for: "private") == .decodeFailed)
        #expect(store.lastIOError(for: "private") == .unsafe)
    }

    @Test func cancelPendingInvalidatesGenerationAndExposesCancelled() async throws {
        let store = makeStore()
        let fm = FileManager.default
        defer {
            if fm.fileExists(atPath: store.directory.path) {
                do { try fm.removeItem(at: store.directory) }
                catch { Issue.record(error) }
            }
        }
        try fm.createDirectory(at: store.draftsDirectory, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.directory.path)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.draftsDirectory.path)
        // The long debounce keeps the task in its cancellable production
        // checkpoint; no sleep or timing race is needed to test the consumer.
        store.debounceInterval = .seconds(60)
        store.scheduleSave(key: "cancelled", payload: Data("memory-only".utf8))
        store.cancelPending(key: "cancelled")
        await Task.yield()

        #expect(store.latestPayload(for: "cancelled") == Data("memory-only".utf8))
        #expect(store.lastIOError(for: "cancelled") == .cancelled)
        #expect(fm.fileExists(atPath: store.draftsDirectory.path))
        let files = try fm.contentsOfDirectory(
            at: store.draftsDirectory, includingPropertiesForKeys: nil
        )
        #expect(files.isEmpty)
    }

    @Test func quarantineRejectsDeterministicSourceReplacementBeforeRename() throws {
        let store = makeStore()
        defer {
            do { try FileManager.default.removeItem(at: store.directory) }
            catch { Issue.record(error) }
        }
        try writeEnvelope(store, key: "session", payload: Data("old".utf8), checksum: "wrong")
        let source = store.draftsDirectory.appendingPathComponent("session.json")
        let displaced = store.draftsDirectory.appendingPathComponent("session.old.json")
        let replacement = store.draftsDirectory.appendingPathComponent("session.replacement.json")
        let originalBytes = try Data(contentsOf: source)
        let replacementBytes = Data("replacement-in-window".utf8)
        try replacementBytes.write(to: replacement, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: replacement.path)

        let attack = RecoveryAttackState()
        store.quarantineRecheckHook = {
            let moved = source.path.withCString { from in
                displaced.path.withCString { to in rename(from, to) }
            }
            if moved == 0 { attack.renamed() }
            else { attack.failure("deterministic source displacement errno=\(errno)") }
            let installed = replacement.path.withCString { from in
                source.path.withCString { to in rename(from, to) }
            }
            if installed == 0 { attack.renamed() }
            else { attack.failure("deterministic replacement install errno=\(errno)") }
        }

        #expect(store.load(key: "session") == nil)
        let summary = attack.summary
        #expect(summary.renames == 2)
        #expect(
            summary.failures.isEmpty,
            Comment(rawValue: summary.failures.joined(separator: "; "))
        )
        #expect(store.lastLoadError(for: "session") == .decodeFailed)
        #expect(store.lastIOError(for: "session") == .unsafe)
        #expect(try Data(contentsOf: source) == replacementBytes)
        #expect(try Data(contentsOf: displaced) == originalBytes)
    }

    @Test func configuredIntermediateSymlinkFailsClosedWithoutEscape() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("p3-recovery-intermediate-link-\(UUID().uuidString)", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        let link = base.appendingPathComponent("link", isDirectory: true)
        let root = link.appendingPathComponent("root", isDirectory: true)
        defer {
            do { try fm.removeItem(at: base) }
            catch { Issue.record(error) }
        }

        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let linked = outside.path.withCString { destination in
            link.path.withCString { source in symlink(destination, source) }
        }
        #expect(linked == 0)

        let store = DraftStore(directory: root)
        store.scheduleSave(key: "escape", payload: Data("must-not-leave-root".utf8))
        #expect(!store.flushNow(key: "escape"))
        #expect(store.lastIOError(for: "escape") == .unsafe)
        #expect(!fm.fileExists(atPath: outside.appendingPathComponent("drafts").path))
    }

    @Test func configuredFinalSymlinkFailsClosedWithoutTouchingTarget() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("p3-recovery-final-link-\(UUID().uuidString)", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        let target = outside.appendingPathComponent("target", isDirectory: true)
        let root = base.appendingPathComponent("root", isDirectory: true)
        defer {
            do { try fm.removeItem(at: base) }
            catch { Issue.record(error) }
        }

        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let linked = target.path.withCString { destination in
            root.path.withCString { source in symlink(destination, source) }
        }
        #expect(linked == 0)

        let store = DraftStore(directory: root)
        store.scheduleSave(key: "escape", payload: Data("must-not-follow-link".utf8))
        #expect(!store.flushNow(key: "escape"))
        #expect(store.lastIOError(for: "escape") == .unsafe)
        #expect(!fm.fileExists(atPath: target.appendingPathComponent("drafts").path))
    }

    @Test func varTemporaryDirectoryUsesAnchoredDraftPath() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("p3-recovery-var-alias-\(UUID().uuidString)", isDirectory: true)
        defer {
            do { try fm.removeItem(at: root) }
            catch { Issue.record(error) }
        }

        let store = DraftStore(directory: root)
        let payload = Data("darwin-alias-payload".utf8)
        store.scheduleSave(key: "alias", payload: payload)
        #expect(store.flushNow(key: "alias"))
        #expect(store.load(key: "alias") == payload)
    }

    @Test func darwinSystemPathResolverHasExplicitAliasSemantics() throws {
        let cases = [
            ("/var/miniscanvas/drafts", "/private/var/miniscanvas/drafts"),
            ("/tmp/miniscanvas/drafts", "/private/tmp/miniscanvas/drafts"),
            ("/etc/miniscanvas/config", "/private/etc/miniscanvas/config"),
            ("/private/var/miniscanvas/drafts", "/private/var/miniscanvas/drafts"),
            ("/Users/example/drafts", "/Users/example/drafts")
        ]
        for (input, expected) in cases {
            #expect(try DarwinSystemPathResolver.resolve(URL(fileURLWithPath: input)) == expected)
        }

        for input in ["relative/drafts", "/var/../Users/example", "/tmp/./drafts"] {
            #expect(throws: DraftStoreIOError.unsafe) {
                try DarwinSystemPathResolver.resolve(URL(fileURLWithPath: input))
            }
        }
    }

    @Test func concurrentRenameAndSymlinkWindowCannotEscapeAnchoredDraftFD() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("p3-recovery-concurrent-window-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("root", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        let outsideSentinel = outside.appendingPathComponent("sentinel.txt")
        let draftsURL = root.appendingPathComponent("drafts", isDirectory: true)
        defer {
            do { try fm.removeItem(at: base) }
            catch { Issue.record(error) }
        }

        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: draftsURL, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: draftsURL.path)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = Data("must-remain-outside".utf8)
        try sentinel.write(to: outsideSentinel, options: .atomic)
        let store = DraftStore(directory: root)

        // Warm the production store before opening the attacker window. From
        // this point on it must use its already-anchored root/drafts FDs.
        store.scheduleSave(key: "warm", payload: Data("warm".utf8))
        #expect(store.flushNow(key: "warm"))
        store.scheduleSave(key: "race", payload: Data("initial-race".utf8))
        #expect(store.flushNow(key: "race"))
        try Data("not-json".utf8).write(
            to: draftsURL.appendingPathComponent("corrupt.json"), options: .atomic
        )
        try fm.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: draftsURL.appendingPathComponent("corrupt.json").path
        )
        let beforeOutside = try fm.contentsOfDirectory(
            at: outside, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ).map(\.lastPathComponent).sorted()

        let stop = RecoveryStopFlag()
        let attackState = RecoveryAttackState()
        let attackerStarted = DispatchSemaphore(value: 0)
        let attackerDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            var iteration = 0
            attackerStarted.signal()
            func check(_ result: Int32, operation: String, allowedErrnos: Set<Int32> = []) {
                guard result != 0 else { return }
                let code = errno
                if !allowedErrnos.contains(code) {
                    attackState.failure("\(operation) errno=\(code)")
                }
            }

            func remove(_ path: URL, operation: String) {
                path.path.withCString { pointer in
                    check(unlink(pointer), operation: operation, allowedErrnos: [ENOENT])
                }
            }

            func writeAttackerPayload(_ path: URL) {
                let fd = path.path.withCString {
                    open($0, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
                }
                guard fd >= 0 else {
                    attackState.failure("open attacker payload errno=\(errno)")
                    return
                }
                let bytes = Array("attacker-local".utf8)
                let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
                if written != bytes.count {
                    attackState.failure("write attacker payload errno=\(errno)")
                }
                if Darwin.close(fd) != 0 {
                    attackState.failure("close attacker payload errno=\(errno)")
                }
            }

            while !stop.isStopped {
                let movedIndex = iteration.isMultiple(of: 2) ? iteration : iteration - 1
                let movedDrafts = base.appendingPathComponent("drafts-moved-\(movedIndex)", isDirectory: true)
                if iteration.isMultiple(of: 2) {
                    let renamed = draftsURL.path.withCString { source in
                        movedDrafts.path.withCString { destination in rename(source, destination) }
                    }
                    check(renamed, operation: "attacker rename drafts")
                    let linked = outside.path.withCString { destination in
                        draftsURL.path.withCString { link in symlink(destination, link) }
                    }
                    check(linked, operation: "attacker symlink drafts")
                    if renamed == 0 { attackState.renamed() }
                    if linked == 0 { attackState.symlinked() }
                } else {
                    remove(draftsURL, operation: "attacker unlink drafts symlink")
                    let restored = draftsURL.path.withCString { mkdir($0, mode_t(0o700)) }
                    check(restored, operation: "attacker restore drafts")
                    if restored == 0 { attackState.restored() }
                }
                // Also race the already-open file name itself. O_NOFOLLOW
                // must reject this symlink, while renameat may replace the
                // link only inside the anchored drafts directory.
                let anchoredRace = movedDrafts.appendingPathComponent("race.json")
                if iteration.isMultiple(of: 3) {
                    remove(anchoredRace, operation: "attacker unlink race")
                    let linked = outsideSentinel.path.withCString { destination in
                        anchoredRace.path.withCString { link in symlink(destination, link) }
                    }
                    check(linked, operation: "attacker symlink race")
                } else {
                    remove(anchoredRace, operation: "attacker unlink race")
                    writeAttackerPayload(anchoredRace)
                }
                iteration &+= 1
            }
            attackerDone.signal()
        }

        // Exercise read, atomic generation writes, clear/unlink, and
        // quarantine concurrently with repeated rename/symlink replacement.
        #expect(attackerStarted.wait(timeout: .now() + 1) == .success)
        DispatchQueue.concurrentPerform(iterations: 96) { index in
            let payload = Data("generation-\(index)".utf8)
            store.scheduleSave(key: "race", payload: payload)
            _ = store.flushNow(key: "race")
            _ = store.load(key: "corrupt")
            store.clear(key: "race")
        }
        stop.stop()
        #expect(attackerDone.wait(timeout: .now() + 2) == .success)
        let attackSummary = attackState.summary
        #expect(attackSummary.renames > 0)
        #expect(attackSummary.symlinks > 0)
        #expect(attackSummary.restores > 0)
        #expect(
            attackSummary.failures.isEmpty,
            Comment(rawValue: attackSummary.failures.joined(separator: "; "))
        )

        let finalPayload = Data("final-generation-payload".utf8)
        store.scheduleSave(key: "race", payload: finalPayload)
        #expect(store.flushNow(key: "race"))
        #expect(store.load(key: "race") == finalPayload)

        #expect(try Data(contentsOf: outsideSentinel) == sentinel)
        let afterOutside = try fm.contentsOfDirectory(
            at: outside, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ).map(\.lastPathComponent).sorted()
        #expect(afterOutside == beforeOutside, "attacker window不得在 drafts 外创建/删除文件")
    }
}
