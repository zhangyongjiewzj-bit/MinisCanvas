import Darwin
import Testing
@testable import MinisCore

@Suite("D-CONC2 reaped shell PID signal boundary")
struct ToolExecutorReapedPIDRegressionTests {
    @Test
    func missingPrivateGroupNeverTargetsReapedPositivePID() {
        let reapedPID: pid_t = 42_424
        #expect(shellTerminationTarget(pid: reapedPID, groupExists: false) == nil)
    }

    @Test
    func livePrivateGroupTargetsOnlyTheGroup() {
        let shellPID: pid_t = 42_424
        #expect(shellTerminationTarget(pid: shellPID, groupExists: true) == -shellPID)
        #expect(shellTerminationTarget(pid: 0, groupExists: true) == nil)
    }
}
