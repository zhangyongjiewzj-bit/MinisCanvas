import Foundation
import Testing
@testable import MinisCore

/// Only the runner's real validated formal contract may reach shared storage.
/// A missing contract stops before resolving any user-domain directory.
@Suite("TASK374 actual shared workflow formal-root prerequisite", .serialized)
struct WorkflowFormalDefault374Tests {
    @Test func sharedTemplatePersistsAndReloadsInsideTheActualFormalRoot() throws {
        let formal = try #require(FormalTestIsolationPaths.currentOrFail())
        let expected = formal.applicationSupportDirectory
            .appendingPathComponent("MinisCanvas", isDirectory: true)
            .appendingPathComponent("Workflows", isDirectory: true)
        let directory = WorkflowStore.defaultDirectory()
        // Require the path before touching .shared or producing any write.
        try #require(directory == expected)
        #expect(directory.path.hasPrefix(formal.rootDirectory.path + "/"))
        let id = "synthetic-workflow374-\(UUID().uuidString)"
        let template = WorkflowTemplate(
            id: id, name: "合成工作流374", description: "formal fixture only",
            steps: [WorkflowStep(id: "step", type: .custom, title: "合成步骤",
                                 promptTemplate: "synthetic", outputKey: "out")]
        )
        try WorkflowStore.shared.saveTemplate(template)
        #expect(WorkflowStore.shared.template(id: id) == template)
        let file = directory.appendingPathComponent(WorkflowStore.fileName)
        #expect(try String(contentsOf: file, encoding: .utf8).contains(id))
        let reloaded = WorkflowStore(storeDirectory: directory)
        #expect(reloaded.template(id: id) == template)
        #expect(reloaded.template(id: "manju-full") == WorkflowTemplate.manjuFullFlow)
    }
}
