import Darwin
import Foundation
import Testing
@testable import MinisCore

@Suite("SKILL-28 skill import concurrency fences")
struct SKILL28SkillImportConcurrencyTests {
    private let firstContent = "---\nname: Concurrent\nversion: 1.0.0\n---\nfirst body\n"
    private let secondContent = "---\nname: Concurrent\nversion: 1.0.0\n---\nsecond body\n"

    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SKILL28-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func skillDirectory(in root: URL, id: String = "concurrent") -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }

    private func holdImportLock(at directory: URL) throws -> Int32 {
        let lock = directory.appendingPathComponent(".skill-import.lock")
        let descriptor = Darwin.open(
            lock.path,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw SkillError.importFailed(reason: "test lock could not be opened")
        }
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            _ = Darwin.close(descriptor)
            throw SkillError.importFailed(reason: "test lock could not be held")
        }
        return descriptor
    }

    private func releaseImportLock(_ descriptor: Int32) {
        _ = flock(descriptor, LOCK_UN)
        _ = Darwin.close(descriptor)
    }

    @Test func occupiedRootLedgerLockFencesAnotherSkillWriter() throws {
        let root = try temporaryRoot("root-ledger-lock")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillStore(skillsRoot: root)
        let original = try store.importSkill(content: firstContent)
        let distinct = "---\nname: Separate\nversion: 1.0.0\n---\nseparate body\n"
        let lockFile = root.appendingPathComponent(".skill-root-write.lock")
        let descriptor = Darwin.open(lockFile.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        try #require(descriptor >= 0)
        defer { _ = Darwin.close(descriptor) }
        try #require(flock(descriptor, LOCK_EX | LOCK_NB) == 0)

        #expect(throws: SkillError.self) { _ = try store.importSkill(content: distinct) }
        #expect(!FileManager.default.fileExists(atPath: skillDirectory(in: root, id: "separate").path))

        try #require(flock(descriptor, LOCK_UN) == 0)
        let second = try store.importSkill(content: distinct)
        let reopened = SkillStore(skillsRoot: root)
        #expect(Set(reopened.allSkills().map(\.id)) == Set([original.id, second.id]))
    }

    @Test func separateProcessCannotWriteWhileRootLedgerIsHeld() throws {
        let arguments = CommandLine.arguments
        let bundleFlag = try #require(arguments.firstIndex(of: "--test-bundle-path"))
        try #require(arguments.indices.contains(bundleFlag + 1))
        let root = try temporaryRoot("process-ledger-lock")
        var retainOwnedRoot = false
        defer { if !retainOwnedRoot { try? FileManager.default.removeItem(at: root) } }
        let store = SkillStore(skillsRoot: root)
        let original = try store.importSkill(content: firstContent)
        let descriptor = open(root.appendingPathComponent(".skill-root-write.lock").path,
                              O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        try #require(descriptor >= 0)
        defer { _ = close(descriptor) }
        let nonce = UUID().uuidString
        let marker = root.appendingPathComponent(nonce)
        let ready = marker.appendingPathExtension("ready")
        let proceed = marker.appendingPathExtension("proceed")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = ["--test-bundle-path", arguments[bundleFlag + 1], "--testing-library",
                             "swift-testing", "--filter", "SKILL28SkillImportConcurrencyTests/rootLedgerWriterChild"]
        var environment = ProcessInfo.processInfo.environment
        environment["SKILL28_ROOT"] = root.path
        environment["SKILL28_PARENT"] = String(getpid())
        environment["SKILL28_NONCE"] = nonce
        process.environment = environment
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline
            && !FileManager.default.fileExists(atPath: ready.path) {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning && FileManager.default.fileExists(atPath: ready.path),
           flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            try? Data().write(to: proceed, options: .atomic)
        }
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            let teardownDeadline = ProcessInfo.processInfo.systemUptime + 2
            while process.isRunning && ProcessInfo.processInfo.systemUptime < teardownDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            retainOwnedRoot = process.isRunning
            if retainOwnedRoot {
                Issue.record("Owned writer PID \(process.processIdentifier) parent PID \(getpid()) did not terminate; cleanup held for fixture \(root.lastPathComponent)")
            } else {
                Issue.record("Owned writer timed out")
            }
            return
        }
        #expect(process.terminationStatus == 0)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "blocked")
        try #require(flock(descriptor, LOCK_UN) == 0)
        let reopened = SkillStore(skillsRoot: root)
        #expect(reopened.allSkills().map(\.id) == [original.id])
    }

    @Test func rootLedgerWriterChild() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let raw = environment["SKILL28_ROOT"], let nonce = environment["SKILL28_NONCE"],
              environment["SKILL28_PARENT"] == String(getppid()), UUID(uuidString: nonce) != nil else { return }
        let root = URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
        let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL
        try #require(root.deletingLastPathComponent().path == temporaryRoot.path)
        try #require(root.lastPathComponent.hasPrefix("SKILL28-process-ledger-lock-"))
        let writer = SkillStore(skillsRoot: root)
        try #require(writer.allSkills().count == 1)
        let marker = root.appendingPathComponent(nonce)
        try Data().write(to: marker.appendingPathExtension("ready"), options: .atomic)
        let proceed = marker.appendingPathExtension("proceed")
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while !FileManager.default.fileExists(atPath: proceed.path)
            && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        try #require(FileManager.default.fileExists(atPath: proceed.path))
        #expect(throws: SkillError.self) {
            _ = try writer.importSkill(content: "---\nname: Separate\nversion: 1.0.0\n---\nseparate body\n")
        }
        try #require(!FileManager.default.fileExists(atPath: skillDirectory(in: root, id: "separate").path))
        try "blocked".write(to: root.appendingPathComponent(nonce), atomically: true, encoding: .utf8)
    }

    @Test func rejectedFirstWriterPreservesTheActiveWriterDirectory() throws {
        let root = try temporaryRoot("first-writer-lock")
        defer { try? FileManager.default.removeItem(at: root) }

        let directory = skillDirectory(in: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lock = try holdImportLock(at: directory)
        defer { releaseImportLock(lock) }

        let store = SkillStore(skillsRoot: root)
        #expect(throws: SkillError.self) {
            _ = try store.importSkill(content: firstContent)
        }
        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(".skill-import.lock").path
        ))
    }

    @Test func inFlightWriterIsRejectedWithoutChangingTheCommittedPair() throws {
        let root = try temporaryRoot("single-writer")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SkillStore(skillsRoot: root)
        _ = try store.importSkill(content: firstContent)
        let directory = skillDirectory(in: root)
        let lock = try holdImportLock(at: directory)
        defer { releaseImportLock(lock) }

        #expect(throws: SkillError.self) {
            _ = try store.importSkill(content: secondContent)
        }
        #expect(try String(
            contentsOf: directory.appendingPathComponent("SKILL.md"),
            encoding: .utf8
        ) == firstContent)
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(".skill-import-pending.json").path
        ))
    }

    @Test func sameSkillConcurrentWritersLeaveOneSelfConsistentPair() async throws {
        let root = try temporaryRoot("same-skill")
        defer { try? FileManager.default.removeItem(at: root) }

        let first = SkillStore(skillsRoot: root)
        let second = SkillStore(skillsRoot: root)
        let firstContent = self.firstContent
        let secondContent = self.secondContent
        let results = await withTaskGroup(
            of: Result<Bool, Error>.self,
            returning: [Result<Bool, Error>].self
        ) { group in
            group.addTask {
                do {
                    _ = try first.importSkill(content: firstContent)
                    return .success(true)
                } catch {
                    return .failure(error)
                }
            }
            group.addTask {
                do {
                    _ = try second.importSkill(content: secondContent)
                    return .success(true)
                } catch {
                    return .failure(error)
                }
            }
            var collected: [Result<Bool, Error>] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        #expect(results.contains { if case .success = $0 { return true }; return false })
        let directory = skillDirectory(in: root)
        let finalContent = try String(
            contentsOf: directory.appendingPathComponent("SKILL.md"),
            encoding: .utf8
        )
        let manifestData = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(SkillSourceManifest.self, from: manifestData)
        #expect(finalContent == firstContent || finalContent == secondContent)
        #expect(manifest.contentHash == SkillManifest.hash(finalContent))
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(".skill-import-pending.json").path
        ))
        let residues = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(residues.allSatisfy { !$0.hasSuffix(".tmp") })
    }

    @Test func differentSkillsCanImportConcurrentlyWithoutSharingStaging() async throws {
        let root = try temporaryRoot("different-skills")
        defer { try? FileManager.default.removeItem(at: root) }

        let firstContent = "---\nname: Alpha\nversion: 1.0.0\n---\nalpha\n"
        let secondContent = "---\nname: Beta\nversion: 1.0.0\n---\nbeta\n"
        let first = SkillStore(skillsRoot: root)
        let second = SkillStore(skillsRoot: root)
        let results = await withTaskGroup(
            of: Result<Bool, Error>.self,
            returning: [Result<Bool, Error>].self
        ) { group in
            group.addTask {
                do {
                    _ = try first.importSkill(content: firstContent)
                    return .success(true)
                } catch {
                    return .failure(error)
                }
            }
            group.addTask {
                do {
                    _ = try second.importSkill(content: secondContent)
                    return .success(true)
                } catch {
                    return .failure(error)
                }
            }
            var collected: [Result<Bool, Error>] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        #expect(results.filter { if case .success = $0 { return true }; return false }.count == 2)
        for (id, content) in [("alpha", firstContent), ("beta", secondContent)] {
            let directory = skillDirectory(in: root, id: id)
            #expect(try String(
                contentsOf: directory.appendingPathComponent("SKILL.md"),
                encoding: .utf8
            ) == content)
            let residues = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            #expect(residues.allSatisfy { !$0.hasSuffix(".tmp") })
            #expect(!residues.contains(".skill-import-pending.json"))
        }
    }
}
