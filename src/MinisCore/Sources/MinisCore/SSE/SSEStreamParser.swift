import Foundation

/// Independent, incremental Server-Sent Events (SSE) parser.
///
/// Ported from the SSE handling scattered across OpenMinis
/// (`AIChatViewModel+SSEStream.swift` stream processing +
/// `OpenAIProvider.ssePayloadLocal` + the agent providers' raw line loops) and
/// extracted into a single testable component. Handles the full SSE wire
/// format used by OpenAI / Anthropic / Ollama streams:
///
///   - `data:` payload lines (multi-line data joined with "\n")
///   - `event:` / `id:` / `retry:` fields
///   - `[DONE]` sentinel (OpenAI)
///   - comments (`: ...`) and blank-line event terminators
///   - CRLF, LF, and lone CR line endings
///
/// Usage (incremental — feed arbitrary chunk sizes):
/// ```swift
/// var parser = SSEStreamParser()
/// for chunk in byteChunks {
///     for output in parser.feed(chunk) {
///         switch output { case .event(let e): ...; case .done: ... }
///     }
/// }
/// ```
public struct SSEStreamParser: Sendable {

    /// A parsed SSE event (fields from one blank-line-terminated block).
    public struct Event: Equatable, Sendable {
        /// Value of the `event:` field (nil when absent).
        public var eventName: String?
        /// Payload of the `data:` field(s), joined with "\n".
        public var data: String
        /// Value of the `id:` field (nil when absent).
        public var id: String?
        /// Value of the `retry:` field (nil when absent).
        public var retry: Int?

        public init(eventName: String? = nil, data: String = "", id: String? = nil, retry: Int? = nil) {
            self.eventName = eventName
            self.data = data
            self.id = id
            self.retry = retry
        }

        /// True for the OpenAI `[DONE]` sentinel.
        public var isDone: Bool { data == "[DONE]" }

        /// True when the payload parses as a JSON object (via JSONSerialization).
        public var jsonObject: [String: Any]? {
            guard let d = data.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
            return obj
        }
    }

    public enum Output: Equatable, Sendable {
        case event(Event)
        /// OpenAI `data: [DONE]` sentinel observed.
        case done
    }

    /// Accumulated partial line(s) not yet terminated by a newline.
    ///
    /// Keep this as bytes instead of a `String`: URLSession can split a
    /// multi-byte UTF-8 scalar between two network chunks. Decoding each
    /// chunk independently would turn that scalar into U+FFFD before the
    /// parser has a chance to join it.
    private var pendingBytes: [UInt8] = []
    /// The event currently being assembled (fields since last blank line).
    private var currentEvent = Event()
    /// True once any field has been seen in the current event block.
    private var hasFields = false
    /// Distinguishes an absent `data:` field from a present empty one so
    /// `data:\ndata:second` correctly produces `\nsecond`.
    private var hasDataField = false

    public init() {}

    // MARK: - Feed

    /// Feed a chunk of text; returns any complete events produced.
    public mutating func feed(_ chunk: String) -> [Output] {
        feed(Data(chunk.utf8))
    }

    /// Feed raw bytes (UTF-8).
    public mutating func feed(_ data: Data) -> [Output] {
        pendingBytes.append(contentsOf: data)
        var outputs: [Output] = []
        processCompleteLines(into: &outputs)
        return outputs
    }

    /// Convenience for tests / whole-buffer parsing: parse everything and
    /// return the events (ignoring the `.done` sentinel).
    public mutating func parseAll(_ text: String) -> [Event] {
        var events: [Event] = []
        for output in feed(text) {
            if case .event(let e) = output { events.append(e) }
        }
        return events
    }

    /// True when there is an unterminated event in the buffer (stream ended
    /// without a trailing blank line).
    public var hasPendingEvent: Bool { hasFields || !pendingBytes.isEmpty }

    /// Flush any pending event (call at end of stream when the server omits
    /// the final blank line).
    public mutating func flushPending() -> Event? {
        defer {
            pendingBytes.removeAll(keepingCapacity: true)
            currentEvent = Event()
            hasFields = false
            hasDataField = false
        }
        // A stream is allowed to end without a final LF. Treat the remaining
        // bytes as one final line before dispatching the assembled event.
        if !pendingBytes.isEmpty {
            var lineBytes = pendingBytes
            // A trailing CR is a line terminator (and may be a lone CR rather
            // than the first half of CRLF because the stream is ending).
            if lineBytes.last == 0x0D { lineBytes.removeLast() }
            let line = String(decoding: lineBytes, as: UTF8.self)
            pendingBytes.removeAll(keepingCapacity: true)
            var ignoredOutputs: [Output] = []
            processLine(line, into: &ignoredOutputs)
            // If a trailing lone CR completed a blank-line delimiter, preserve
            // the event for the caller instead of dropping it during reset.
            if let output = ignoredOutputs.first {
                switch output {
                case .event(let event):
                    defer { currentEvent = Event(); hasFields = false; hasDataField = false }
                    return event
                case .done:
                    defer { currentEvent = Event(); hasFields = false; hasDataField = false }
                    return Event(data: "[DONE]")
                }
            }
        }
        guard hasFields || !currentEvent.data.isEmpty else { return nil }
        return currentEvent
    }

    // MARK: - Line processing

    private mutating func processCompleteLines(into outputs: inout [Output]) {
        while let terminatorIndex = pendingBytes.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            // A CR at the very end may be the first half of CRLF split over
            // network chunks. Hold it until the next feed (or flushPending).
            if pendingBytes[terminatorIndex] == 0x0D,
               terminatorIndex == pendingBytes.count - 1 {
                break
            }

            let line = String(decoding: pendingBytes[..<terminatorIndex], as: UTF8.self)
            let isCRLF = pendingBytes[terminatorIndex] == 0x0D
                && pendingBytes[terminatorIndex + 1] == 0x0A
            let consumed = terminatorIndex + (isCRLF ? 2 : 1)
            pendingBytes.removeFirst(consumed)
            processLine(line, into: &outputs)
        }
    }

    private mutating func processLine(_ line: String, into outputs: inout [Output]) {
        // Blank line → dispatch the assembled event.
        if line.isEmpty {
            if hasFields {
                if currentEvent.isDone {
                    outputs.append(.done)
                } else {
                    outputs.append(.event(currentEvent))
                }
                currentEvent = Event()
                hasFields = false
                hasDataField = false
            }
            return
        }
        // Comment line → ignore.
        if line.hasPrefix(":") { return }

        // Split "field: value".
        guard let colonIdx = line.firstIndex(of: ":") else {
            // A line with no colon is a field with an empty value.
            applyField(name: line, value: "")
            return
        }
        let name = String(line[..<colonIdx])
        var value = String(line[line.index(after: colonIdx)...])
        // A single leading space after the colon is stripped (per SSE spec).
        if value.hasPrefix(" ") { value.removeFirst() }
        applyField(name: name, value: value)
    }

    private mutating func applyField(name: String, value: String) {
        hasFields = true
        switch name {
        case "data":
            // Multi-line data joins with "\n"; the first data line is verbatim.
            if !hasDataField {
                currentEvent.data = value
                hasDataField = true
            } else {
                currentEvent.data += "\n" + value
            }
        case "event":
            currentEvent.eventName = value
        case "id":
            currentEvent.id = value
        case "retry":
            currentEvent.retry = Int(value)
        default:
            break // unknown fields ignored
        }
    }

    // MARK: - Stateless helpers

    /// Strip the `data:` SSE-line prefix and the optional single space,
    /// returning nil for non-data lines. (Ported from
    /// `OpenAIProvider.ssePayloadLocal`.) `[DONE]` is returned verbatim —
    /// callers decide how to interpret it.
    public static func ssePayload(fromLine line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let after = line.dropFirst(5)
        return after.first == " " ? String(after.dropFirst()) : String(after)
    }
}
