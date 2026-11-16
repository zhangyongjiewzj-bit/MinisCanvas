import Foundation
import os

/// Shared final scrubber for product log sinks. It is intentionally bounded
/// and content-only: it never reads credentials or performs I/O.
public enum AppLogRedactionPolicy {
    public static let maxEventIDLength = 96
    public static let maxCategoryLength = 80
    public static let maxMessageLength = 1_024

    public static func scrub(
        eventID: String?,
        category: String,
        message: String,
        knownSecrets: [String] = []
    ) -> (eventID: String, category: String, message: String) {
        let safeID = bounded(eventID ?? UUID().uuidString, limit: maxEventIDLength, knownSecrets: knownSecrets)
        let safeCategory = bounded(category, limit: maxCategoryLength, knownSecrets: knownSecrets)
        let safeMessage = bounded(message, limit: maxMessageLength, knownSecrets: knownSecrets)
        return (
            safeID.isEmpty ? UUID().uuidString : safeID,
            safeCategory.isEmpty ? "General" : safeCategory,
            safeMessage
        )
    }

    private static func bounded(_ value: String, limit: Int, knownSecrets: [String]) -> String {
        guard limit > 0 else { return "" }
        var result = ContentSecretRedactor.redact(value, knownSecrets: knownSecrets)
        result = replace(result, pattern: #"https?://[^\s\"'`<>]+"#, replacement: "<remote-url>")
        result = replace(result, pattern: #"(?<![A-Za-z0-9_])(?:/|~\/)[^\s\"'`<>]+"#, replacement: "<path>")
        result = result.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        return String(result.prefix(limit))
    }

    private static func replace(_ text: String, pattern: String, replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }
}

/// Minimal os.Logger wrapper (ported from OpenMinis `Shared/AppLogger.swift`),
/// UIKit/iSH-free. Subsystem is fixed so log filtering works across the app.
public final class AppLogger: Sendable {
    private let logger: os.Logger
    private let knownSecrets: [String]

    public init(
        category: String,
        subsystem: String = "com.miniscanvas.miniscore",
        knownSecrets: [String] = []
    ) {
        let scrubbed = AppLogRedactionPolicy.scrub(
            eventID: nil,
            category: category,
            message: "",
            knownSecrets: knownSecrets
        )
        let safeSubsystem = AppLogRedactionPolicy.scrub(
            eventID: nil,
            category: subsystem,
            message: "",
            knownSecrets: knownSecrets
        ).category
        self.logger = os.Logger(
            subsystem: safeSubsystem.isEmpty ? "com.miniscanvas.miniscore" : safeSubsystem,
            category: scrubbed.category
        )
        self.knownSecrets = knownSecrets
    }

    public func debug(_ message: String, eventID: String? = nil) {
        let event = AppLogRedactionPolicy.scrub(
            eventID: eventID,
            category: "debug",
            message: message,
            knownSecrets: knownSecrets
        )
        logger.debug("[\(event.eventID)] \(event.message, privacy: .public)")
    }

    public func info(_ message: String, eventID: String? = nil) {
        let event = AppLogRedactionPolicy.scrub(
            eventID: eventID,
            category: "info",
            message: message,
            knownSecrets: knownSecrets
        )
        logger.info("[\(event.eventID)] \(event.message, privacy: .public)")
    }

    public func warning(_ message: String, eventID: String? = nil) {
        let event = AppLogRedactionPolicy.scrub(
            eventID: eventID,
            category: "warning",
            message: message,
            knownSecrets: knownSecrets
        )
        logger.warning("[\(event.eventID)] \(event.message, privacy: .public)")
    }

    public func error(_ message: String, eventID: String? = nil) {
        let event = AppLogRedactionPolicy.scrub(
            eventID: eventID,
            category: "error",
            message: message,
            knownSecrets: knownSecrets
        )
        logger.error("[\(event.eventID)] \(event.message, privacy: .public)")
    }
}
