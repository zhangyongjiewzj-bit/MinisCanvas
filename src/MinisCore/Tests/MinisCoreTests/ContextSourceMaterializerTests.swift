import Testing
@testable import MinisCore

/// P3-A4-CONTEXT-SOURCE-MATERIALIZATION-20260818:
/// source selection must be explicit, ordered, and fail closed.
struct ContextSourceMaterializerTests {
    private func source(
        _ identifier: String,
        cost: Int,
        required: Bool = false,
        nonDroppable: Bool = false,
        scope: String = "conversation",
        provenance: String = "test"
    ) -> ContextSourceMaterializer.Source {
        ContextSourceMaterializer.Source(
            identifier: identifier,
            content: "content-\(identifier)",
            tokenCost: cost,
            level: .l1,
            scope: scope,
            provenance: provenance,
            required: required,
            nonDroppable: nonDroppable
        )
    }

    @Test func materializesProtectedSourcesAndRecordsOptionalBudgetDropInInputOrder() {
        let result = ContextSourceMaterializer.materialize(
            sources: [
                source("memory", cost: 4),
                source("system", cost: 2, required: true),
                source("receipt", cost: 3, nonDroppable: true),
                source("history", cost: 3)
            ],
            budget: 7
        )

        #expect(result.acceptedSources.map(\.identifier) == ["system", "receipt"])
        #expect(result.droppedSourceIDs == ["memory", "history"])
        #expect(result.usedBudget == 5)
        #expect(result.rejection == nil)
        #expect(result.decisions.map(\.sourceID) == ["memory", "system", "receipt", "history"])
        #expect(result.decisions.map(\.inputIndex) == [0, 1, 2, 3])
        #expect(result.decisions.map(\.reason) == [
            .budgetExceeded,
            nil,
            nil,
            .budgetExceeded
        ])
    }

    @Test func protectedSourceOverBudgetRejectsWholeBatchWithoutSilentDrop() {
        let result = ContextSourceMaterializer.materialize(
            sources: [
                source("optional", cost: 1),
                source("required-system", cost: 4, required: true),
                source("non-droppable-receipt", cost: 3, nonDroppable: true)
            ],
            budget: 5
        )

        #expect(result.acceptedSources.isEmpty)
        #expect(result.usedBudget == 0)
        #expect(result.rejection == .protectedSourceExceedsBudget)
        #expect(result.rejectionSourceIDs == ["non-droppable-receipt"])
        #expect(result.decisions.map(\.sourceID) == ["optional", "required-system", "non-droppable-receipt"])
        #expect(result.decisions.map(\.reason) == [
            .batchRejected,
            .batchRejected,
            .protectedSourceExceedsBudget
        ])
    }

    @Test func invalidSourceContractRejectsWholeBatchAndKeepsReasonAndOrder() {
        let result = ContextSourceMaterializer.materialize(
            sources: [
                source("valid", cost: 1),
                source("bad-scope", cost: 1, scope: "   "),
                source("bad-provenance", cost: 1, provenance: "")
            ],
            budget: 3
        )

        #expect(result.acceptedSources.isEmpty)
        #expect(result.rejection == .invalidSourceContract)
        #expect(result.rejectionSourceIDs == ["bad-scope", "bad-provenance"])
        #expect(result.decisions.map(\.sourceID) == ["valid", "bad-scope", "bad-provenance"])
        #expect(result.decisions.map(\.reason) == [
            .batchRejected,
            .invalidScope,
            .invalidProvenance
        ])
    }

    @Test func sameInputProducesStableMaterializationAndPreservesMetadata() {
        let input = [
            source("late", cost: 1),
            source("required", cost: 1, required: true)
        ]

        let first = ContextSourceMaterializer.materialize(sources: input, budget: 2)
        let second = ContextSourceMaterializer.materialize(sources: input, budget: 2)

        #expect(first == second)
        #expect(first.acceptedSources.map(\.identifier) == ["late", "required"])
        #expect(first.acceptedSources.last?.scope == "conversation")
        #expect(first.acceptedSources.last?.provenance == "test")
        #expect(first.acceptedSources.last?.required == true)
    }

    @Test func protectedBudgetOverflowFailsClosed() {
        let result = ContextSourceMaterializer.materialize(
            sources: [
                source("first", cost: Int.max, required: true),
                source("second", cost: Int.max, nonDroppable: true)
            ],
            budget: Int.max
        )

        #expect(result.acceptedSources.isEmpty)
        #expect(result.rejection == .protectedSourceExceedsBudget)
        #expect(result.rejectionSourceIDs == ["second"])
        #expect(result.decisions.map(\.sourceID) == ["first", "second"])
        #expect(result.decisions.map(\.reason) == [
            .batchRejected,
            .protectedSourceExceedsBudget
        ])
    }
}
