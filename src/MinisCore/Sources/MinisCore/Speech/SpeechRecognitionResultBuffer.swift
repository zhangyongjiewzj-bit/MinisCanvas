/// Keeps transcripts from a cancelled recording out of the next recording.
/// The audio callback supplies text; this value never opens an input device.
struct SpeechRecognitionResultBuffer {
    private(set) var text = ""
    private var generation: UInt64 = 0
    private var accepting = false

    mutating func begin() -> UInt64 {
        generation &+= 1
        text = ""
        accepting = true
        return generation
    }

    /// Returns true only when this active generation reached a final result
    /// or error and its owner should tear down the audio resources.
    mutating func receive(
        generation receivedGeneration: UInt64,
        text newText: String?,
        isFinal: Bool,
        failed: Bool
    ) -> Bool {
        guard accepting, receivedGeneration == generation else { return false }
        if let newText { text = newText }
        guard isFinal || failed else { return false }
        accepting = false
        generation &+= 1
        return true
    }

    @discardableResult
    mutating func stop() -> String {
        accepting = false
        generation &+= 1
        return text
    }
}
