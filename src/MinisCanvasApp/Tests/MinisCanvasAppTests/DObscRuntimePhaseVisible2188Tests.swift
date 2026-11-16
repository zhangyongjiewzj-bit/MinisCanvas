import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

@MainActor
private final class RuntimePhase2188Box {
    var current: DiagnosticRuntimeSummary = .unknown
    var healthReads = 0
}

@Suite("D-OBSC visible runtime phase 2188")
@MainActor
struct DObscRuntimePhaseVisible2188Tests {
    @Test("visible phase follows the same live content-free summary as diagnostic export")
    func phaseChangesWithoutRunningAHealthProbe() throws {
        let box = RuntimePhase2188Box()
        let controller = DiagnosticExportController(
            healthReportProvider: {
                box.healthReads += 1
                return nil
            },
            runtimeSummaryProvider: { box.current }
        )
        #expect(controller.visibleRuntimePhase == "运行阶段未知")
        #expect(box.healthReads == 0)

        box.current = DiagnosticRuntimeSummary(
            appState: .ready,
            activeSessionPresent: false,
            activeSessionStreaming: false
        )
        #expect(controller.visibleRuntimePhase == "等待打开会话")
        box.current = DiagnosticRuntimeSummary(
            appState: .ready,
            activeSessionPresent: true,
            activeSessionStreaming: false
        )
        #expect(controller.visibleRuntimePhase == "当前会话空闲")
        box.current = DiagnosticRuntimeSummary(
            appState: .ready,
            activeSessionPresent: true,
            activeSessionStreaming: true
        )
        #expect(controller.visibleRuntimePhase == "当前会话正在响应")
        #expect(box.healthReads == 0, "reading a phase must not start or consume a health check")
        #expect(try controller.makeBundle().runtime == box.current)
        box.current = DiagnosticRuntimeSummary(appState: .degraded)
        #expect(controller.visibleRuntimePhase == "应用启动受限")
    }
}
