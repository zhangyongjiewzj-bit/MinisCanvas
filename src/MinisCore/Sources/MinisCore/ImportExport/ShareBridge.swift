import Foundation

/// A ready-to-share payload produced by `ShareBridge`. The UI layer decides
/// how to present it (macOS `NSSharingServicePicker`, drag onto a folder, …);
/// this type only describes *what* should be shared.
public struct SharePayload: Codable, Equatable, Sendable {
    /// What kind of content is being shared.
    public let type: PayloadType
    /// Suggested share title (document name, message subject, …).
    public let title: String
    /// The content body (text / JSON string) for inline payloads.
    public let content: String
    /// On-disk path of a staged file when the payload was written to disk.
    public let dataPath: String?

    public enum PayloadType: String, Codable, Sendable {
        case text
        case json
        case file
    }

    public init(type: PayloadType, title: String, content: String = "", dataPath: String? = nil) {
        self.type = type
        self.title = title
        self.content = content
        self.dataPath = dataPath
    }
}

/// Generates share payloads and writes shareable files to disk.
///
/// The macOS share sheet (`NSSharingServicePicker`) is owned by the UI layer —
/// this bridge ends at producing the payload / file that the picker would
/// carry. Boundary concept reference: OpenMinis `ShareCoordinator`; this core stages
/// content, the UI presents it.
public enum ShareBridge {

    /// Default directory for staged share files.
    public static let defaultShareDirectoryName = "Shares"

    // MARK: - Payloads

    /// Build a text share payload without touching disk.
    public static func exportText(_ text: String, title: String) -> SharePayload {
        SharePayload(type: .text, title: title, content: text)
    }

    /// Build a JSON share payload from an `Encodable` value.
    public static func exportJSON<T: Encodable>(_ value: T, title: String, encoder: JSONEncoder = JSONEncoder()) throws -> SharePayload {
        let data = try encoder.encode(value)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ShareError.encodingFailed("Encoded data is not valid UTF-8")
        }
        return SharePayload(type: .json, title: title, content: json)
    }

    // MARK: - Writing files

    /// Write `text` as a `.txt` file under `directory` (created if needed).
    /// - Returns: the written file URL.
    @discardableResult
    public static func exportText(_ text: String, to directory: URL, fileName: String? = nil) throws -> URL {
        let data = Data(text.utf8)
        return try write(data, to: directory, fileName: fileName ?? defaultFileName(prefix: "text", ext: "txt"))
    }

    /// Encode `value` as JSON and write it to `directory`.
    /// - Returns: the written file URL.
    @discardableResult
    public static func exportJSON<T: Encodable>(_ value: T, to directory: URL, fileName: String? = nil, encoder: JSONEncoder = JSONEncoder()) throws -> URL {
        let data = try encoder.encode(value)
        return try write(data, to: directory, fileName: fileName ?? defaultFileName(prefix: "json", ext: "json"))
    }

    /// Write raw bytes to `directory` (created if needed) under `fileName`.
    /// Collisions get a numeric suffix (`file-1.txt`) instead of overwriting.
    /// - Returns: the written file URL.
    @discardableResult
    public static func write(_ data: Data, to directory: URL, fileName: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = fileName
        var url = directory.appendingPathComponent(candidate)
        var counter = 1
        while fm.fileExists(atPath: url.path) {
            candidate = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            url = directory.appendingPathComponent(candidate)
            counter += 1
        }

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ShareError.writeFailed(url, error.localizedDescription)
        }
        return url
    }

    /// Stage a share payload to disk and return the file-backed payload
    /// (used for sharing files via the system picker).
    public static func stage(_ payload: SharePayload, to directory: URL) throws -> SharePayload {
        switch payload.type {
        case .json:
            let data = Data(payload.content.utf8)
            let url = try write(data, to: directory, fileName: "\(sanitized(payload.title)).json")
            return SharePayload(type: .json, title: payload.title, content: payload.content, dataPath: url.path)
        case .text:
            let url = try exportText(payload.content, to: directory, fileName: "\(sanitized(payload.title)).txt")
            return SharePayload(type: .text, title: payload.title, content: payload.content, dataPath: url.path)
        case .file:
            return payload
        }
    }

    // MARK: - Helpers

    /// Default share directory under an app's Documents directory.
    public static func defaultShareDirectory(baseDirectory: URL) -> URL {
        baseDirectory.appendingPathComponent(defaultShareDirectoryName, isDirectory: true)
    }

    /// A `# Heading`-safe file name: keep letters/digits/`-`/`_`, collapse runs.
    public static func sanitized(_ name: String) -> String {
        let allowed = name.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" || scalar == " "
        }
        let cleaned = String(String.UnicodeScalarView(allowed))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = cleaned
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: "-")
        return collapsed.isEmpty ? "share" : collapsed
    }

    private static func defaultFileName(prefix: String, ext: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(prefix)-\(formatter.string(from: Date())).\(ext)"
    }
}

/// Errors raised while exporting / sharing content.
public enum ShareError: Error, Equatable, Sendable {
    case encodingFailed(String)
    case writeFailed(URL, String)

    public var localizedDescription: String {
        switch self {
        case .encodingFailed(let reason):
            return "Failed to encode share content: \(reason)"
        case .writeFailed(let url, let reason):
            return "Failed to write share file \(url.lastPathComponent): \(reason)"
        }
    }
}
