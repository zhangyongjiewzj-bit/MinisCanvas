import os

/// D-PERF-07: production transcript intervals visible to Instruments.
/// Names are stable and carry no message text, session ID, or credentials.
enum TranscriptPerformanceSignposts {
    static let signposter = OSSignposter(
        subsystem: "com.miniscanvas.MinisCanvas", category: "TranscriptPerformance"
    )

    static let render = StaticString("TranscriptRender")
    static let nativeApply = StaticString("TranscriptNativeApply")
    static let layout = StaticString("TranscriptLayout")
}
