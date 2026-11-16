import Foundation
import CryptoKit
import Testing
@testable import MinisCore

@Suite("SKILL399 durable scoped rollback consumer")
struct SKILL399ScopedRollbackConsumerTests {
    @Test func rollbackRestoresNonNilScopeAndAuthorizationAcrossStoreReconstruction() throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = formal.temporaryDirectory.appendingPathComponent("skill399-rollback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillStore(skillsRoot: root)
        let scope = MemoryScope(sessionID: "previous-session", projectID: "previous-project")
        let expiry = Date().addingTimeInterval(600)
        let previousBody = "previous scoped body\nsecond complete line"
        let previousContent = "---\nname: scoped rollback\ndescription: scoped rollback\nversion: 1.0.0\n---\n\(previousBody)"
        let previous = try store.importSkillThroughLifecycle(
            content: previousContent, source: .bundled, reason: "scoped previous revision",
            scope: scope,
            approval: SkillApproval(approverID: "previous-scoped-reviewer", scope: scope, expiresAt: expiry)
        )
        let previousReceipt = try #require(store.lifecycleReceipt(for: previous.skill.id))
        let previousManifest = try Data(contentsOf: store.skillManifestURL(for: previous.skill.id))
        #expect(previousReceipt.scope == scope)
        #expect(previousReceipt.expiresAt == expiry)
        #expect(SkillInjector(store: store, minimumScore: 1)
            .buildInjection(for: "scoped rollback", within: scope).fragment?.contains(previousBody) == true)
        #expect(SkillInjector(store: store, minimumScore: 1)
            .buildInjection(for: "scoped rollback").fragment == nil)

        // The current revision has deliberately different, broader authorization.
        // A rollback that retains current.scope or resets scope to nil must fail.
        let current = try store.importSkillThroughLifecycle(
            content: "---\nname: scoped rollback\ndescription: scoped rollback\nversion: 2.0.0\n---\ncurrent global body",
            source: .file, reason: "new globally approved revision",
            approval: SkillApproval(approverID: "current-global-reviewer", expiresAt: expiry.addingTimeInterval(600))
        )
        #expect(current.receipt.scope == nil)
        #expect(current.receipt.approvedBy != previousReceipt.approvedBy)
        let rolledBack = try store.rollbackSkill(previous.skill.id, reason: "restore previous scoped revision")
        #expect(rolledBack.state == .rolledBack)
        #expect(rolledBack.scope == scope)
        #expect(rolledBack.scope != current.receipt.scope)
        #expect(rolledBack.contentHash == previousReceipt.contentHash)
        #expect(rolledBack.sourceIdentity == previousReceipt.sourceIdentity)
        #expect(rolledBack.approvedBy == previousReceipt.approvedBy)
        #expect(rolledBack.expiresAt == previousReceipt.expiresAt)
        // Capture only this method's synthetic operands before its original
        // byte oracle and deferred cleanup. Diagnostics never replace an oracle.
        let restoredManifest = try? Data(contentsOf: store.skillManifestURL(for: previous.skill.id))
        let manifestBytesEqual = restoredManifest.map { $0 == previousManifest } ?? false
        if !manifestBytesEqual {
            print("SKILL399_MANIFEST_DIAGNOSTIC bytesEqual=false afterReadable=\(restoredManifest != nil)")
            let manifestFields = Set(["schema", "version", "skillID", "source", "skillVersion", "contentHash"])
            let keyPattern = try? NSRegularExpression(pattern: #""([A-Za-z0-9_]+)"\s*:"#)
            for (phase, operand) in [("before", Optional(previousManifest)), ("after", restoredManifest)] {
                guard let bytes = operand else {
                    print("SKILL399_MANIFEST_OPERAND phase=\(phase) readable=false")
                    continue
                }
                let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                print("SKILL399_MANIFEST_OPERAND phase=\(phase) count=\(bytes.count) sha256=\(digest) base64=\(bytes.base64EncodedString())")
                if let object = try? JSONSerialization.jsonObject(with: bytes),
                   let fields = object as? [String: Any],
                   let canonical = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
                   let json = String(data: canonical, encoding: .utf8) {
                    print("SKILL399_MANIFEST_FIELDS phase=\(phase) json=\(json)")
                } else {
                    print("SKILL399_MANIFEST_FIELDS phase=\(phase) validObject=false")
                }
                if let text = String(data: bytes, encoding: .utf8), let keyPattern {
                    let order = keyPattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
                        .compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
                        .filter { manifestFields.contains($0) }
                    print("SKILL399_MANIFEST_ORDER phase=\(phase) keys=\(order.joined(separator: ","))")
                } else {
                    print("SKILL399_MANIFEST_ORDER phase=\(phase) available=false")
                }
            }
        }
        #expect(try Data(contentsOf: store.skillManifestURL(for: previous.skill.id)) == previousManifest)
        #expect(store.rawContent(previous.skill.id) == previousContent)

        // A new store must read the restored durable receipt, not the old instance.
        let restarted = SkillStore(skillsRoot: root)
        let durable = try #require(restarted.lifecycleReceipt(for: previous.skill.id))
        #expect(durable == rolledBack)
        #expect(durable.scope == scope)
        #expect(durable.approvedBy == "previous-scoped-reviewer")
        #expect(durable.expiresAt == expiry)
        #expect(restarted.rawContent(previous.skill.id) == previousContent)
        #expect(restarted.allSkills().first(where: { $0.id == previous.skill.id })?.importSource == .bundled)
        #expect(restarted.allSkills().first(where: { $0.id == previous.skill.id })?.isEnabled == false)
        let injector = SkillInjector(store: restarted, minimumScore: 1)
        for requestScope in [scope, MemoryScope(sessionID: "other-session", projectID: "previous-project"),
                             MemoryScope(sessionID: "previous-session", projectID: "other-project")] {
            let result = injector.buildInjection(for: "scoped rollback", selectedSkillIDs: [previous.skill.id], within: requestScope)
            #expect(result.fragment == nil)
            #expect(!result.receipts.contains { $0.injected })
        }
        let unscoped = injector.buildInjection(for: "scoped rollback", selectedSkillIDs: [previous.skill.id])
        #expect(unscoped.fragment == nil)
        #expect(!unscoped.receipts.contains { $0.injected })
        // Existing re-enable semantics must not bypass the fresh-approval boundary.
        restarted.setEnabled(previous.skill.id, enabled: true)
        #expect(restarted.allSkills().first(where: { $0.id == previous.skill.id })?.isEnabled == false)
        #expect(restarted.lifecycleReceipt(for: previous.skill.id)?.scope == scope)
    }
}
