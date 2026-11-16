import Foundation
import Testing
@testable import MinisCore

struct AssistantThinkingExplicitReportTests {
    private final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [ThinkingParameterApplication] = []
        func record(_ value: ThinkingParameterApplication) { lock.withLock { values.append(value) } }
        var snapshot: [ThinkingParameterApplication] { lock.withLock { values } }
    }

    @Test func explicitReportReceivesWrittenResultAndPreservesBodyMapping() {
        let reports = Reports()
        var body: [String: Any] = ["temperature": 0.5, "messages": []]
        let result = AssistantThinkingParameters.apply(.high, modelID: "gpt-5.2",
            wire: .openAIChat, body: &body, report: { reports.record($0) })
        #expect(result == .written)
        #expect(reports.snapshot == [.written])
        #expect(body["reasoning_effort"] as? String == "high")
        #expect(body["temperature"] == nil)
        #expect(body["messages"] as? [String] == [])
    }

    @Test func explicitReportReceivesIgnoredResultWithoutBodyChanges() {
        let reports = Reports()
        var body: [String: Any] = ["temperature": 0.5]
        let result = AssistantThinkingParameters.apply(.high, modelID: "custom-model",
            wire: .openAIChat, body: &body, report: { reports.record($0) })
        #expect(result == .ignored("模型ID未声明思考参数映射"))
        #expect(reports.snapshot == [result])
        #expect(body.count == 1)
        #expect(body["temperature"] as? Double == 0.5)
    }

    @Test func absentLevelDoesNotReport() {
        let reports = Reports()
        var body: [String: Any] = ["temperature": 0.5]
        let result = AssistantThinkingParameters.apply(nil, modelID: "gpt-5.2",
            wire: .openAIChat, body: &body, report: { reports.record($0) })
        #expect(result == .notRequested)
        #expect(reports.snapshot.isEmpty)
        #expect(body.count == 1)
        #expect(body["temperature"] as? Double == 0.5)
    }

    @Test func unchangedCallerRetainsTaskLocalReportingAndExplicitReportTakesPrecedence() {
        let legacy = Reports()
        let explicit = Reports()
        AssistantThinkingParameters.$reportApplication.withValue({ legacy.record($0) }) {
            var legacyBody: [String: Any] = [:]
            AssistantThinkingParameters.apply(.high, modelID: "gpt-5.2",
                wire: .openAIResponses, body: &legacyBody)
            var explicitBody: [String: Any] = [:]
            AssistantThinkingParameters.apply(.high, modelID: "gpt-5.2",
                wire: .openAIResponses, body: &explicitBody, report: { explicit.record($0) })
            #expect(legacyBody["reasoning"] as? [String: String] == ["effort": "high"])
            #expect(explicitBody["reasoning"] as? [String: String] == ["effort": "high"])
        }
        #expect(legacy.snapshot == [.written])
        #expect(explicit.snapshot == [.written])
    }
}
