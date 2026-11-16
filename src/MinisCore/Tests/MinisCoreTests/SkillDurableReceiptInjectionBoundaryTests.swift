import Foundation
import Testing
@testable import MinisCore

/// Exercises the production loader and turn capture, not an invented in-memory
/// SkillStore snapshot. All durable files live under this process's formal
/// test root; no user skill root is read.
struct SkillDurableReceiptInjectionBoundaryTests {
    private let content = """
    ---
    name: durable-receipt-boundary
    description: durable receipt boundary probe
    version: 1.0.0
    ---

    TASK1600_APPROVED_BODY
    """

    @Test func approvedLocalAndBundledReceiptsKeepLegacyIdentityCompatibility() async throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        for source in [SkillImportSource.file, .bundled] {
            let root = formal.temporaryDirectory
                .appendingPathComponent("task1608-skill-positive-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let store = SkillStore(skillsRoot: root.appendingPathComponent("skills", isDirectory: true))
            let installed = try store.importSkillThroughLifecycle(
                content: content,
                source: source,
                reason: "isolated approved compatibility fixture",
                approval: SkillApproval(approverID: "task1608-reviewer")
            )
            let receiptURL = store.lifecycleReceiptsFileURL
            var document = try #require(
                JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as? [String: Any]
            )
            var receipts = try #require(document["receipts"] as? [String: Any])
            var receipt = try #require(receipts[installed.skill.id] as? [String: Any])
            receipt.removeValue(forKey: "sourceIdentity")
            receipts[installed.skill.id] = receipt
            document["receipts"] = receipts
            try JSONSerialization.data(withJSONObject: document)
                .write(to: receiptURL, options: .atomic)

            let reloaded = SkillStore(skillsRoot: store.skillsRoot)
            let turn = try #require(
                await SkillInjector(store: reloaded).captureTurnPreparation().prepare()
            )
            #expect(turn.buildInjection(
                for: "durable receipt boundary probe",
                selectedSkillIDs: [installed.skill.id]
            ).fragment?.contains("TASK1600_APPROVED_BODY") == true,
                    "approved \(source.dbValue) legacy receipt was blocked")
        }
    }

    @Test func loadedReceiptMustStillCarryTheOriginalApprovalAndSourceIdentity() async throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = formal.temporaryDirectory
            .appendingPathComponent("task1600-skill-receipt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SkillStore(skillsRoot: root.appendingPathComponent("skills", isDirectory: true))
        let installed = try store.importSkillThroughLifecycle(
            content: content,
            source: .bundled,
            reason: "isolated approved fixture",
            approval: SkillApproval(approverID: "task1600-reviewer")
        )
        #expect(installed.receipt.state == .active)
        let receiptURL = store.lifecycleReceiptsFileURL
        let original = try Data(contentsOf: receiptURL)

        let approvedReload = SkillStore(skillsRoot: store.skillsRoot)
        let approvedTurn = try #require(
            await SkillInjector(store: approvedReload).captureTurnPreparation().prepare()
        )
        let approved = approvedTurn.buildInjection(
            for: "durable receipt boundary probe",
            selectedSkillIDs: [installed.skill.id]
        )
        #expect(approved.fragment?.contains("TASK1600_APPROVED_BODY") == true)
        #expect(approvedTurn.buildInjection(for: "durable receipt boundary probe")
            .fragment?.contains("TASK1600_APPROVED_BODY") == true)

        // Each variant changes only the durable receipt produced by a real
        // approval. The manifest and SKILL.md remain the approved bytes.
        for variant in ["missing-approver", "wrong-skill-id", "wrong-trusted-source", "wrong-source-identity", "wrong-content-hash"] {
            var document = try #require(
                JSONSerialization.jsonObject(with: original) as? [String: Any]
            )
            var receipts = try #require(document["receipts"] as? [String: Any])
            var receipt = try #require(receipts[installed.skill.id] as? [String: Any])
            switch variant {
            case "missing-approver":
                receipt["approvedBy"] = NSNull()
            case "wrong-skill-id":
                receipt["skillID"] = "different-skill"
            case "wrong-trusted-source":
                // Bundled imports currently receive local trust. This is a
                // different trusted value, so the case tests source binding.
                receipt["trust"] = "bundled"
            case "wrong-source-identity":
                receipt["sourceIdentity"] = "skill:different-skill@different-hash"
            case "wrong-content-hash":
                receipt["contentHash"] = String(repeating: "0", count: 64)
            default:
                Issue.record("unknown receipt variant")
                continue
            }
            receipts[installed.skill.id] = receipt
            document["receipts"] = receipts
            try JSONSerialization.data(withJSONObject: document)
                .write(to: receiptURL, options: .atomic)

            let reloaded = SkillStore(skillsRoot: store.skillsRoot)
            #expect(reloaded.lifecycleReceipt(for: installed.skill.id)?.state == .quarantined,
                    "loader retained \(variant) as active")
            #expect(reloaded.allSkills().first(where: { $0.id == installed.skill.id })?.isEnabled == false,
                    "loader enabled \(variant)")
            let turn = try #require(
                await SkillInjector(store: reloaded).captureTurnPreparation().prepare()
            )
            let automatic = turn.buildInjection(for: "durable receipt boundary probe")
            let selected = turn.buildInjection(
                for: "durable receipt boundary probe",
                selectedSkillIDs: [installed.skill.id]
            )
            #expect(automatic.fragment?.contains("TASK1600_APPROVED_BODY") != true,
                    "automatic injection accepted \(variant)")
            #expect(selected.fragment?.contains("TASK1600_APPROVED_BODY") != true,
                    "selected injection accepted \(variant)")
        }
    }
}
