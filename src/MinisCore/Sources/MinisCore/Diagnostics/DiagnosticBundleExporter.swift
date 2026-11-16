import Foundation

/// Stable, user-visible result of one completed local export.  The URL is
/// returned to the App consumer for navigation only; it is never serialized
/// into the diagnostic bundle itself.
public struct DiagnosticBundleExportReceipt: Equatable, Sendable {
    public let destinationURL: URL
    public let byteCount: Int
    public let completedAt: Date

    public init(destinationURL: URL, byteCount: Int, completedAt: Date = Date()) {
        self.destinationURL = destinationURL
        self.byteCount = byteCount
        self.completedAt = completedAt
    }
}

public enum DiagnosticBundleExportError: Error, Equatable, Sendable, LocalizedError {
    case cancelled
    case destinationUnavailable
    case invalidDestination
    case inputTooLarge
    case encodingFailed
    case verificationFailed
    case writeFailed

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "导出已取消，目标文件未改变。"
        case .destinationUnavailable, .invalidDestination:
            return "目标位置不可用，未写入诊断包。"
        case .inputTooLarge:
            return "诊断包超过大小限制，未写入目标文件。"
        case .encodingFailed, .verificationFailed, .writeFailed:
            return "诊断包导出失败，原目标文件已保留。"
        }
    }
}

/// Local-only writer for the bounded diagnostic envelope.
///
/// The exporter never runs a health check and never reads a store.  It encodes
/// the already-projected `DiagnosticBundle`, verifies the staged bytes, then
/// atomically installs them beside the selected destination.  Cancellation is
/// checked before every mutating stage; after the single synchronous commit no
/// cancellation check can turn a committed file into a false failure.
public struct DiagnosticBundleExporter: Sendable {
    public static let maximumBytes = 64 * 1024
    public static let fileExtension = "json"

    public let maximumOutputBytes: Int

    public init(maximumOutputBytes: Int = Self.maximumBytes) {
        self.maximumOutputBytes = max(1, min(maximumOutputBytes, Self.maximumBytes))
    }

    /// Encodes exactly the fixed schema with deterministic key ordering and
    /// ISO-8601 timestamps.  No source report or arbitrary text is traversed.
    public func encodedData(for bundle: DiagnosticBundle) throws -> Data {
        try checkCancellation()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do {
            data = try encoder.encode(bundle)
        } catch {
            throw DiagnosticBundleExportError.encodingFailed
        }
        guard data.count <= maximumOutputBytes else {
            throw DiagnosticBundleExportError.inputTooLarge
        }
        try checkCancellation()
        return data
    }

    /// Atomically writes one complete bundle to the user-selected URL.
    /// Existing files are replaced only at the final commit point.  A failed
    /// stage removes only the exporter-owned temporary file and preserves the
    /// source data and any previous destination contents.
    @discardableResult
    public func export(
        _ bundle: DiagnosticBundle,
        to destinationURL: URL
    ) throws -> DiagnosticBundleExportReceipt {
        let data = try encodedData(for: bundle)
        let fileManager = FileManager.default
        try validateDestination(destinationURL, fileManager: fileManager)
        try checkCancellation()

        let directory = destinationURL.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        var staged = true
        defer {
            if staged {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        do {
            // `.atomic` protects the staging write itself; the final replace or
            // move below is the separate destination commit.
            try data.write(to: temporaryURL, options: [.atomic])
        } catch {
            throw DiagnosticBundleExportError.writeFailed
        }
        guard fileManager.fileExists(atPath: temporaryURL.path),
              let stagedData = try? Data(contentsOf: temporaryURL),
              stagedData == data else {
            throw DiagnosticBundleExportError.verificationFailed
        }
        try checkCancellation()

        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(
                    destinationURL,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: .usingNewMetadataOnly
                )
            } else {
                try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            }
            staged = false
        } catch {
            throw DiagnosticBundleExportError.writeFailed
        }

        // Do not inspect cancellation after commit: the file is complete and
        // the caller must receive a success receipt for an installed artifact.
        return DiagnosticBundleExportReceipt(
            destinationURL: destinationURL,
            byteCount: data.count
        )
    }

    /// Default filename contains only a fixed prefix and UTC timestamp.
    public static func defaultFilename(now: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withDashSeparatorInDate,
                                   .withTime, .withColonSeparatorInTime, .withTimeZone]
        let timestamp = formatter.string(from: now)
            .replacingOccurrences(of: ":", with: "-")
        return "miniscanvas-diagnostics-\(timestamp).\(Self.fileExtension)"
    }

    private func checkCancellation() throws {
        if Task.isCancelled {
            throw DiagnosticBundleExportError.cancelled
        }
    }

    private func validateDestination(
        _ destinationURL: URL,
        fileManager: FileManager
    ) throws {
        guard destinationURL.isFileURL,
              !destinationURL.path.isEmpty,
              !destinationURL.lastPathComponent.isEmpty else {
            throw DiagnosticBundleExportError.invalidDestination
        }

        let directory = destinationURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw DiagnosticBundleExportError.destinationUnavailable
        }

        guard !isSymbolicLink(destinationURL) else {
            throw DiagnosticBundleExportError.invalidDestination
        }
        if fileManager.fileExists(atPath: destinationURL.path) {
            guard let attributes = try? fileManager.attributesOfItem(atPath: destinationURL.path),
                  let type = attributes[.type] as? FileAttributeType,
                  type == .typeRegular else {
                throw DiagnosticBundleExportError.invalidDestination
            }
        }
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]) else {
            return false
        }
        return values.isSymbolicLink == true
    }
}
