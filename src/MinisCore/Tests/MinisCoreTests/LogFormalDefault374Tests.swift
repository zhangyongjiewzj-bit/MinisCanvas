import Foundation
import Testing
@testable import MinisCore

@Suite("TASK374 actual default and shared log formal-root prerequisite", .serialized)
struct LogFormalDefault374Tests {
    @Test func defaultAndSharedLoggersWriteSyntheticRecordsInsideTheActualFormalRoot() throws {
        let formal = try #require(FormalTestIsolationPaths.currentOrFail())
        let directory = formal.logDirectory
        try #require(directory.path.hasPrefix(formal.rootDirectory.path + "/"))
        let defaultMessage = "synthetic-default-log374-\(UUID().uuidString)"
        let sharedMessage = "synthetic-shared-log374-\(UUID().uuidString)"
        let logger = LogManager()
        logger.info(defaultMessage, category: "Formal374")
        LogManager.shared.info(sharedMessage, category: "Formal374")
        #expect(logger.recentLogs().contains { $0.message == defaultMessage })
        #expect(LogManager.shared.recentLogs().contains { $0.message == sharedMessage })
        let contents = try String(contentsOf: directory.appendingPathComponent("app.log"), encoding: .utf8)
        #expect(contents.contains(defaultMessage))
        #expect(contents.contains(sharedMessage))
    }
}
