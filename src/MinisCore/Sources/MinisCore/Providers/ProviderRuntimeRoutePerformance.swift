import Foundation

/// Converts one monotonic route acquisition interval for the bounded route
/// observation. No clock reading or request content is retained.
public enum ProviderRuntimeRoutePerformance {
    /// Whole milliseconds, rounded down. A clock anomaly produces zero rather
    /// than wrapping into a misleading large duration.
    public static func elapsedMilliseconds(
        startNanoseconds: UInt64,
        endNanoseconds: UInt64
    ) -> Int {
        guard endNanoseconds >= startNanoseconds else { return 0 }
        let milliseconds = (endNanoseconds - startNanoseconds) / 1_000_000
        return milliseconds > UInt64(Int.max) ? Int.max : Int(milliseconds)
    }
}
