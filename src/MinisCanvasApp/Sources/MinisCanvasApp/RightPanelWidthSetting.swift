import Foundation
import Observation

/// The existing asset sheet keeps its 720pt readable minimum. The finite
/// 1120pt upper bound is reused from cbfdc9e52's adaptive asset surface.
/// Only presentation width is persisted; Canvas availability and visibility
/// continue to belong to the existing runtime boundary.
@MainActor
@Observable
final class AssetPanelWidthSetting {
    static let settingsKey = "minisCanvas.assetPanelWidth"
    static let minimumWidth: Double = 720
    static let defaultWidth: Double = 720
    static let maximumWidth: Double = 1_120

    private let defaults: UserDefaults
    private(set) var width: Double
    private var dragStartWidth: Double?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        self.width = Self.normalized(
            (defaults.object(forKey: Self.settingsKey) as? NSNumber)?.doubleValue
                ?? Self.defaultWidth
        )
    }

    private static func normalized(_ requested: Double) -> Double {
        guard requested.isFinite else { return defaultWidth }
        return min(max(requested, minimumWidth), maximumWidth)
    }

    func write(_ requested: Double) {
        let validated = Self.normalized(requested)
        defaults.set(validated, forKey: Self.settingsKey)
        width = validated
    }

    /// DragGesture supplies cumulative translation from the gesture's start.
    /// Keep that origin until endDrag, including while clamped at a bound.
    func applyDragTranslation(_ translation: Double) {
        guard translation.isFinite else { return }
        if dragStartWidth == nil { dragStartWidth = width }
        guard let start = dragStartWidth else { return }
        write(start + translation)
    }

    func endDrag() {
        dragStartWidth = nil
    }

    func adjust(by delta: Double) {
        guard delta.isFinite else { return }
        endDrag()
        write(width + delta)
    }
}
