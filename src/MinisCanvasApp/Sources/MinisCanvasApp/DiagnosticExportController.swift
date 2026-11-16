import Foundation
import Observation
import MinisCore

enum DiagnosticExportFailureReason: Equatable, Sendable {
    case busy
    case snapshotTooLarge
    case cancelled
    case destinationUnavailable
    case writeFailed
    case unknown

    var message: String {
        switch self {
        case .busy:
            return "已有诊断包导出正在进行。"
        case .snapshotTooLarge:
            return "诊断快照超过大小限制，未写入目标文件。"
        case .cancelled:
            return "导出已取消，目标文件未改变。"
        case .destinationUnavailable:
            return "目标位置不可用，未写入诊断包。"
        case .writeFailed, .unknown:
            return "诊断包导出失败，原目标文件已保留。"
        }
    }
}

enum DiagnosticExportControllerState: Equatable, Sendable {
    case idle
    case exporting
    case succeeded(DiagnosticBundleExportReceipt)
    case cancelled
    case failed(DiagnosticExportFailureReason)
}

/// Main-actor App consumer for the independent Core diagnostic exporter.
///
/// The controller receives an optional already-produced `HealthReport`; it
/// does not construct a runner, touch stores, read credentials, or start a
/// network check.  When no report is supplied the exported five-module health
/// projection remains explicitly unknown.
@MainActor
@Observable
final class DiagnosticExportController {
    private let exporter: DiagnosticBundleExporter
    private let healthReportProvider: @MainActor () -> HealthReport?
    private let applicationInfoProvider: @MainActor () -> DiagnosticApplicationInfo
    private let runtimeSummaryProvider: @MainActor () -> DiagnosticRuntimeSummary
    private let clock: @MainActor () -> Date

    private(set) var state: DiagnosticExportControllerState = .idle
    private var cancelActiveExport: (() -> Void)?

    init(
        exporter: DiagnosticBundleExporter = DiagnosticBundleExporter(),
        healthReportProvider: @escaping @MainActor () -> HealthReport? = { nil },
        applicationInfoProvider: @escaping @MainActor () -> DiagnosticApplicationInfo = { .current },
        runtimeSummaryProvider: @escaping @MainActor () -> DiagnosticRuntimeSummary = { .unknown },
        clock: @escaping @MainActor () -> Date = Date.init
    ) {
        self.exporter = exporter
        self.healthReportProvider = healthReportProvider
        self.applicationInfoProvider = applicationInfoProvider
        self.runtimeSummaryProvider = runtimeSummaryProvider
        self.clock = clock
    }

    var isExporting: Bool {
        if case .exporting = state { return true }
        return false
    }

    var lastReceipt: DiagnosticBundleExportReceipt? {
        if case .succeeded(let receipt) = state { return receipt }
        return nil
    }

    var failureReason: DiagnosticExportFailureReason? {
        if case .failed(let reason) = state { return reason }
        if case .cancelled = state { return .cancelled }
        return nil
    }

    /// The same live, content-free runtime summary used by export is also the
    /// visible phase source. "Ready" only describes App composition, never
    /// the health of the five independently unmeasured modules.
    var visibleRuntimePhase: String {
        let runtime = runtimeSummaryProvider()
        switch runtime.appState {
        case .degraded:
            return "应用启动受限"
        case .unknown:
            return "运行阶段未知"
        case .ready:
            if runtime.activeSessionStreaming == true { return "当前会话正在响应" }
            if runtime.activeSessionPresent == true { return "当前会话空闲" }
            if runtime.activeSessionPresent == false { return "等待打开会话" }
            return "应用已就绪；会话活动未知"
        }
    }

    /// Builds a Core bundle from the current typed projections.  This method
    /// remains useful to tests and future App surfaces without introducing a
    /// second data source or a health-probe side effect.
    func makeBundle() throws -> DiagnosticBundle {
        try DiagnosticBundle(
            application: applicationInfoProvider(),
            healthReport: healthReportProvider(),
            runtime: runtimeSummaryProvider(),
            capturedAt: clock()
        )
    }

    /// Export a complete bundle to an explicit user-selected destination.
    /// The bounded JSON encoding runs in a detached utility task; cancellation
    /// is wired to that task, while the Core writer's synchronous final commit
    /// keeps a successfully installed file from being reported as cancelled.
    func export(to destinationURL: URL) async {
        guard !isExporting else {
            state = .failed(.busy)
            return
        }
        state = .exporting

        do {
            try checkCancellation()
            await Task.yield()
            try checkCancellation()

            let bundle = try makeBundle()
            try checkCancellation()
            let exporter = exporter
            let operation = Task.detached(priority: .utility) {
                try exporter.export(bundle, to: destinationURL)
            }
            cancelActiveExport = { operation.cancel() }
            defer { cancelActiveExport = nil }

            let receipt = try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: {
                operation.cancel()
            }
            state = .succeeded(receipt)
        } catch is CancellationError {
            state = .cancelled
        } catch let error as DiagnosticBundleSnapshotError {
            state = .failed(Self.failureReason(for: error))
        } catch let error as DiagnosticBundleExportError {
            if error == .cancelled {
                state = .cancelled
            } else {
                state = .failed(Self.failureReason(for: error))
            }
        } catch {
            // The UI receives only a stable category, never arbitrary error
            // text that could contain a path, URL, or provider detail.
            state = .failed(.unknown)
        }
    }

    /// Cancels only the active export.  If the writer already committed its
    /// atomic replacement, its completed receipt remains authoritative.
    func cancel() {
        cancelActiveExport?()
    }

    func reset() {
        guard !isExporting else { return }
        state = .idle
    }

    private func checkCancellation() throws {
        if Task.isCancelled { throw CancellationError() }
    }

    private static func failureReason(for error: DiagnosticBundleSnapshotError) -> DiagnosticExportFailureReason {
        switch error {
        case .tooManyHealthItems:
            return .snapshotTooLarge
        case .invalidTimestamp:
            return .unknown
        }
    }

    private static func failureReason(for error: DiagnosticBundleExportError) -> DiagnosticExportFailureReason {
        switch error {
        case .cancelled:
            return .cancelled
        case .destinationUnavailable, .invalidDestination:
            return .destinationUnavailable
        case .inputTooLarge:
            return .snapshotTooLarge
        case .encodingFailed, .verificationFailed, .writeFailed:
            return .writeFailed
        }
    }
}
