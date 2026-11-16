import Testing
@testable import MinisCanvasApp

@Suite("Staged enablement")
struct StagedEnablementTests {
    private let head = "8f28f574c14438d31a791ac8a37f6729a101c40d"

    @Test("all eleven rings promote monotonically with green receipts")
    func promotesAllRings() throws {
        let controller = StagedEnablementController(expectedHead: head)

        for ring in StagedEnablementRing.allCases.dropFirst() {
            let state = try controller.promote(to: ring, receipt: receipt(for: ring))
            #expect(state.currentRing == ring)
            #expect(state.failStopReason == nil)
        }

        #expect(controller.snapshot().currentRing == .stable)
    }

    @Test("each required RED signal fail-stops promotion")
    func redSignalsFailStop() {
        let redCases: [(String, StagedEnablementSignals)] = [
            ("error", signals(error: .red)),
            ("performance", signals(performance: .red)),
            ("memory", signals(memory: .red)),
            ("disk", signals(disk: .red)),
            ("processReap", signals(processReap: .red)),
            ("business", signals(business: .red)),
        ]

        for (name, signals) in redCases {
            let controller = StagedEnablementController(expectedHead: head)
            do {
                _ = try controller.promote(
                    to: .a7aBasicAgent,
                    receipt: receipt(for: .a7aBasicAgent, signals: signals, id: "red-\(name)")
                )
                #expect(Bool(false), "RED \(name) must stop promotion")
            } catch let error as StagedEnablementError {
                guard case .redSignals(let blocking) = error else {
                    #expect(Bool(false), "unexpected error for RED \(name)")
                    continue
                }
                #expect(blocking == [name])
                #expect(controller.snapshot().failStopReason == [name])
            } catch {
                #expect(Bool(false), "unexpected non-state-machine error for RED \(name)")
            }
        }
    }

    @Test("missing Profile or Kill Switch blocks external and child rings")
    func externalSafetyPrerequisiteIsRequired() {
        for ring in [StagedEnablementRing.externalAgent, .child4, .child8, .child16, .child24, .child40] {
            let controller = StagedEnablementController(expectedHead: head)
            do {
                _ = try controller.promote(
                    to: ring,
                    receipt: receipt(
                        for: ring,
                        prerequisites: StagedEnablementPrerequisites(
                            isolatedProfileReady: false,
                            killSwitchReady: false
                        )
                    )
                )
                #expect(Bool(false), "external safety must be required for \(ring)")
            } catch StagedEnablementError.missingExternalSafetyPrerequisite {
                #expect(controller.snapshot().currentRing == .internalPreview)
            } catch {
                #expect(Bool(false), "unexpected prerequisite error for \(ring)")
            }
        }
    }

    @Test("old head and old ring receipts are rejected")
    func rejectsLateReceipts() throws {
        let controller = StagedEnablementController(expectedHead: head)

        do {
            _ = try controller.promote(
                to: .a7aBasicAgent,
                receipt: receipt(for: .a7aBasicAgent, head: "old-head")
            )
            #expect(Bool(false))
        } catch StagedEnablementError.staleHead {
            #expect(controller.snapshot().currentRing == .internalPreview)
        }

        do {
            _ = try controller.promote(
                to: .a7aBasicAgent,
                receipt: receipt(for: .internalPreview)
            )
            #expect(Bool(false))
        } catch StagedEnablementError.staleRing {
            #expect(controller.snapshot().currentRing == .internalPreview)
        }
    }

    @Test("explicit rollback is the only way to clear a fail-stop and move backward")
    func explicitRollbackClearsFailStop() throws {
        let controller = StagedEnablementController(expectedHead: head)
        _ = try controller.promote(to: .a7aBasicAgent, receipt: receipt(for: .a7aBasicAgent))

        do {
            _ = try controller.promote(
                to: .toolMCP,
                receipt: receipt(for: .toolMCP, signals: signals(memory: .red))
            )
            #expect(Bool(false))
        } catch StagedEnablementError.redSignals {
            #expect(controller.snapshot().failStopReason == ["memory"])
        }

        do {
            _ = try controller.promote(to: .toolMCP, receipt: receipt(for: .toolMCP))
            #expect(Bool(false))
        } catch StagedEnablementError.failStopped {
            #expect(controller.snapshot().currentRing == .a7aBasicAgent)
        }

        let rollback = receipt(
            for: .internalPreview,
            id: "rollback-1",
            explicitRollback: true,
            rollbackReason: "revert failed promotion"
        )
        let rolledBack = try controller.rollback(to: .internalPreview, receipt: rollback)
        #expect(rolledBack.currentRing == .internalPreview)
        #expect(rolledBack.failStopReason == nil)
        #expect(rolledBack.lastAcceptedReceiptID == "rollback-1")
    }

    @Test("missing signals are fail-stop rather than implicit green")
    func missingSignalsFailStop() {
        let controller = StagedEnablementController(expectedHead: head)
        do {
            _ = try controller.promote(
                to: .a7aBasicAgent,
                receipt: receipt(for: .a7aBasicAgent, signals: signals(error: .missing))
            )
            #expect(Bool(false))
        } catch StagedEnablementError.redSignals(let blocking) {
            #expect(blocking == ["error"])
            #expect(controller.snapshot().failStopReason == ["error"])
        } catch {
            #expect(Bool(false))
        }
    }

    private func receipt(
        for ring: StagedEnablementRing,
        head: String? = nil,
        signals: StagedEnablementSignals = .allGreen,
        prerequisites: StagedEnablementPrerequisites? = nil,
        id: String? = nil,
        explicitRollback: Bool = false,
        rollbackReason: String? = nil
    ) -> StagedEnablementReceipt {
        StagedEnablementReceipt(
            receiptID: id ?? "receipt-\(ring.rawValue)",
            head: head ?? self.head,
            ring: ring,
            signals: signals,
            prerequisites: prerequisites ?? (ring.requiresExternalSafety ? .externalReady : .internalOnly),
            explicitRollback: explicitRollback,
            rollbackReason: rollbackReason
        )
    }

    private func signals(
        error: StagedSignalStatus = .green,
        performance: StagedSignalStatus = .green,
        memory: StagedSignalStatus = .green,
        disk: StagedSignalStatus = .green,
        processReap: StagedSignalStatus = .green,
        business: StagedSignalStatus = .green
    ) -> StagedEnablementSignals {
        StagedEnablementSignals(
            error: error,
            performance: performance,
            memory: memory,
            disk: disk,
            processReap: processReap,
            business: business
        )
    }
}
