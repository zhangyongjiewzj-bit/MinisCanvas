import Foundation

/// Gate-protected SkillStore deletion. A skill directory is moved as one unit
/// into `.trash`, preserving bundled references and making restore atomic at
/// the filesystem level.
public final class SkillDeletionService: @unchecked Sendable {
    public let store: SkillStore
    private let fileManager = FileManager.default

    public init(store: SkillStore) {
        self.store = store
    }

    public func preview(skillID: String, now: Date = Date(), ttl: TimeInterval = 300) throws -> OperationIntent {
        let skill = try currentSkill(id: skillID)
        return DeletionGate.preview(
            targetID: skill.id,
            targetType: "skill",
            targetName: skill.name,
            affectedCount: 1,
            impactSummary: "移入回收站，可恢复 SKILL.md 及其附属文件",
            reversible: true,
            scopeID: "skill:\(skill.id)",
            revision: revision(for: skill),
            fingerprint: fingerprint(for: skill),
            now: now,
            ttl: ttl
        )
    }

    public func delete(_ intent: OperationIntent, now: Date = Date()) throws -> DeletionReceipt {
        let skill = try currentSkill(id: intent.targetID)
        return try DeletionGate.execute(
            intent,
            currentRevision: revision(for: skill),
            currentFingerprint: fingerprint(for: skill),
            now: now
        ) { confirmed in
            let source = store.skillDirectoryURL(for: confirmed.targetID)
            let trash = trashURL(for: confirmed.operationID)
            do {
                try fileManager.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
                try fileManager.moveItem(at: source, to: trash)
                store.reload()
            } catch {
                throw SkillDeletionError.deleteFailed(error.localizedDescription)
            }
        }
    }

    public func restore(_ receipt: DeletionReceipt) throws {
        let trash = trashURL(for: receipt.operationID)
        let destination = store.skillDirectoryURL(for: receipt.targetID)
        guard fileManager.fileExists(atPath: trash.path) else {
            throw SkillDeletionError.restoreFailed("回收站中不存在操作 \(receipt.operationID.uuidString)")
        }
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw SkillDeletionError.restoreTargetExists(receipt.targetID)
        }
        do {
            try fileManager.moveItem(at: trash, to: destination)
            store.reload()
        } catch {
            throw SkillDeletionError.restoreFailed(error.localizedDescription)
        }
    }

    private var trashDirectory: URL {
        store.skillsRoot.appendingPathComponent(".trash", isDirectory: true)
    }

    private func trashURL(for operationID: UUID) -> URL {
        trashDirectory.appendingPathComponent(operationID.uuidString, isDirectory: true)
    }

    private func currentSkill(id: String) throws -> Skill {
        store.reload()
        guard let skill = store.skills.first(where: { $0.id == id }) else {
            throw SkillError.skillNotFound(id)
        }
        return skill
    }

    private func revision(for skill: Skill) -> Int {
        Int(clamping: Int64(skill.updatedAt.timeIntervalSince1970.rounded(.down)))
    }

    private func fingerprint(for skill: Skill) -> String {
        let object: [String: Any] = [
            "id": skill.id,
            "name": skill.name,
            "description": skill.description,
            "version": skill.version,
            "source": skill.importSource.dbValue,
            "enabled": skill.isEnabled,
            "installedAt": skill.installedAt.timeIntervalSince1970,
            "updatedAt": skill.updatedAt.timeIntervalSince1970,
            "body": skill.body,
            "useCount": skill.useCount
        ]
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(skill.id.utf8)
        let directory = store.skillDirectoryURL(for: skill.id)
        let files = (fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [])?.compactMap { $0 as? URL } ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.path < $1.path }
        for file in files {
            let relative = String(file.path.dropFirst(directory.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let fileData = try? Data(contentsOf: file) else { continue }
            data.append(contentsOf: Data(relative.utf8))
            data.append(0)
            data.append(fileData)
            data.append(0)
        }
        return DeletionGate.fingerprint(data)
    }
}

public enum SkillDeletionError: Error, Equatable, Sendable {
    case deleteFailed(String)
    case restoreFailed(String)
    case restoreTargetExists(String)
}
