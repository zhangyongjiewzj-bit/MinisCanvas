import Foundation
import SwiftUI

/// Passive, process-local observations of the renderer's existing onAppear.
/// There is no file/network export, policy decision or observable publication.
/// The App composition root owns the only production instance.
@MainActor
final class MinisIconRenderTelemetry {
    enum Scene: String, CaseIterable, Sendable {
        case mainWindow
        case settingsSheet
    }

    struct Appearance: Equatable, Sendable {
        let scene: Scene
        let instanceID: UUID
        let icon: MinisIcon
        let source: MinisIconRenderSource
    }

    struct Counts: Equatable, Sendable {
        let appearances: Int
        let uniqueInstances: Int
        let uniqueTokens: Int
        let keylineAppearances: Int
        let fallbackAppearances: Int
        let fallbackSystemNames: Set<String>

        /// Only the retained semantic onAppear sample. Direct Image/Label SF
        /// calls and the original 13-file K0 denominator are not measured here.
        var observedKeylineFraction: Double? {
            appearances == 0 ? nil : Double(keylineAppearances) / Double(appearances)
        }
    }

    struct Snapshot: Equatable, Sendable {
        let appearances: [Appearance]
        let discardedAppearances: Int

        func counts(in scene: Scene? = nil) -> Counts {
            let rows = appearances.filter { scene == nil || $0.scene == scene }
            let fallbackNames = rows.compactMap { row -> String? in
                if case .fallback(let name) = row.source { return name }
                return nil
            }
            return Counts(appearances: rows.count,
                          uniqueInstances: Set(rows.map(\.instanceID)).count,
                          uniqueTokens: Set(rows.map(\.icon)).count,
                          keylineAppearances: rows.filter { $0.source == .keyline }.count,
                          fallbackAppearances: fallbackNames.count,
                          fallbackSystemNames: Set(fallbackNames))
        }
    }

    private let capacity: Int
    private var retained: [Appearance] = []
    private var discarded = 0

    init(capacity: Int = 4096) {
        self.capacity = min(4096, max(1, capacity))
    }

    var snapshot: Snapshot {
        Snapshot(appearances: retained, discardedAppearances: discarded)
    }

    fileprivate func observe(_ appearance: Appearance) {
        if retained.count == capacity {
            retained.removeFirst()
            if discarded < Int.max { discarded += 1 }
        }
        // Repeated appearances stay separate. Reusing a view instance or
        // token must not erase a fallback from the actual appearance sample.
        retained.append(appearance)
    }
}

struct MinisIconRenderObservation: Sendable {
    let telemetry: MinisIconRenderTelemetry
    let scene: MinisIconRenderTelemetry.Scene

    @MainActor
    func onAppear(icon: MinisIcon, source: MinisIconRenderSource, instanceID: UUID) {
        telemetry.observe(.init(scene: scene, instanceID: instanceID, icon: icon, source: source))
    }
}

private struct MinisIconRenderObservationKey: EnvironmentKey {
    static let defaultValue: MinisIconRenderObservation? = nil
}

extension EnvironmentValues {
    var minisIconRenderObservation: MinisIconRenderObservation? {
        get { self[MinisIconRenderObservationKey.self] }
        set { self[MinisIconRenderObservationKey.self] = newValue }
    }
}

extension View {
    @MainActor
    func observingMinisIconRenders(
        using telemetry: MinisIconRenderTelemetry,
        scene: MinisIconRenderTelemetry.Scene
    ) -> some View {
        environment(\.minisIconRenderObservation,
                    MinisIconRenderObservation(telemetry: telemetry, scene: scene))
    }
}
