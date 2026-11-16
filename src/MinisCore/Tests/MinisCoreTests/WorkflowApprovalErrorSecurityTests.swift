import Foundation
import Testing
@testable import MinisCore

private let unsafeWorkflowDenialReason =
    "delegate https://example.test/deny?api_key=fixture-secret /Users/alice/private.txt "
        + String(repeating: "d", count: 240) + "\u{0000}"

@Suite("Workflow approval error security", .serialized)
struct WorkflowApprovalErrorSecurityTests {
    @Test("workflow failure does not stringify a raw approval denial")
    func workflowFailureUsesSafeApprovalDiagnostic() async throws {
        let template = WorkflowTemplate(
            id: "approval-error",
            name: "审批错误",
            description: "审批错误诊断边界",
            steps: [
                WorkflowStep(
                    id: "step",
                    type: .custom,
                    title: "步骤",
                    promptTemplate: "固定提示",
                    outputKey: "output"
                )
            ]
        )

        do {
            _ = try await WorkflowRunner().run(
                template: template,
                inputs: [:],
                provider: DenyingWorkflowProvider(reason: unsafeWorkflowDenialReason)
            )
            Issue.record("expected the workflow provider to deny the fixture")
        } catch let error as WorkflowError {
            guard case let .stepFailed(_, _, underlying) = error else {
                Issue.record("unexpected workflow error shape")
                return
            }
            #expect(underlying.hasPrefix("审批被拒绝"))
            #expect(underlying.contains("[remote resource]"))
            #expect(underlying.contains("[local path]"))
            #expect(!underlying.contains("fixture-secret"))
            #expect(!underlying.contains("/Users/alice/private.txt"))
            #expect(underlying.count <= 170)
            #expect(underlying.unicodeScalars.allSatisfy { scalar in
                scalar.value >= 0x20 && scalar.value != 0x7F
            })
        } catch {
            Issue.record("unexpected non-workflow error shape")
        }
    }

    @Test("raw approval denial remains equatable after safe projection")
    func rawApprovalReasonRemainsInternalEqualityData() {
        let error = ApprovalError.denied(reason: unsafeWorkflowDenialReason)
        #expect(error == .denied(reason: unsafeWorkflowDenialReason))
        #expect(error.localizedDescription.hasPrefix("审批被拒绝"))
        #expect(!error.localizedDescription.contains("fixture-secret"))
    }
}

private struct DenyingWorkflowProvider: WorkflowProvider {
    let reason: String

    func generate(prompt _: String, step _: WorkflowStep) async throws -> String {
        throw ApprovalError.denied(reason: reason)
    }
}
