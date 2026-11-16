import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-COMMAND-01 bilingual command metadata completeness")
struct P3AcceptanceM05CommandMetadataCompletenessTests {
    @Test func everyRegisteredCommandHasUsableMenuCopyAndParameterLabels() {
        let registry = CommandRegistry()
        registry.registerComposerCommands()
        let rows = ComposerSlashCommandMenu.entries(matching: "/", registry: registry)
        let metadataByID = Dictionary(
            uniqueKeysWithValues: CommandRegistry.composerCommandMetadata.map { ($0.id, $0) }
        )

        // The original 21-command catalog and the existing /model row must
        // remain discoverable. Exact identities are pinned by the Core suite.
        #expect(rows.count >= 21)
        #expect(rows.count == metadataByID.count)
        for row in rows {
            let descriptor = row.descriptor
            let id = row.id
            #expect(row.isRouted, "/\(id) has no registered consumer")
            #expect(!descriptor.zhTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "/\(id) has no Chinese title")
            #expect(!descriptor.enTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "/\(id) has no English title")
            #expect(!descriptor.zhSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "/\(id) has no Chinese description")
            #expect(!descriptor.enSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "/\(id) has no English description")
            #expect(!descriptor.argumentSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "/\(id) has no parameter summary")
            let riskLabel = descriptor.risk?.displayLabel ?? ""
            #expect(!riskLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "/\(id) has no visible risk grade")

            guard let metadata = metadataByID[id] else {
                Issue.record("/\(id) has no canonical metadata")
                continue
            }
            if !metadata.argumentSpecs.isEmpty {
                #expect(descriptor.argumentSummary != "无 / none",
                        "/\(id) has parameters but describes none")
            }
            for spec in metadata.argumentSpecs {
                #expect(!spec.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        "/\(id) has an unnamed parameter")
                #expect(!spec.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        "/\(id) has an unlabeled parameter")
            }
        }
    }
}
