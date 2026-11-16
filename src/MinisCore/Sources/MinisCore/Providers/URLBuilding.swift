import Foundation

/// Assembles provider endpoints without changing the authority of the base URL.
/// Credentialed callers validate their custom base before using this helper.
public enum URLBuilding {
    public static func join(_ base: String, _ segments: String...) -> String {
        join(base, segments: segments)
    }

    public static func join(_ base: String, segments: [String]) -> String {
        let trimmedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var url = URLComponents(string: trimmedBase) else {
            return joinWithoutComponents(trimmedBase, segments: segments)
        }

        var path = url.percentEncodedPath
        var query = url.percentEncodedQuery
        var fragment = url.percentEncodedFragment

        for segment in segments where !segment.isEmpty {
            let suffix = splitSuffix(segment)
            let rawPath = suffix.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !rawPath.isEmpty {
                var component = encode(rawPath, allowQueryMarkers: false)
                let existing = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if existing.split(separator: "/", omittingEmptySubsequences: true).last?.lowercased() == "v1",
                   component.split(separator: "/", omittingEmptySubsequences: true).first?.lowercased() == "v1" {
                    component = String(component.dropFirst(2))
                        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                }
                if !component.isEmpty {
                    if existing.isEmpty {
                        path = (url.host != nil || suffix.path.hasPrefix("/") ? "/" : "") + component
                    } else {
                        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        if url.host != nil || url.scheme != nil || url.percentEncodedPath.hasPrefix("/") {
                            path = "/" + path
                        }
                        path += "/" + component
                    }
                }
            }
            if let newQuery = suffix.query {
                let encoded = encode(newQuery, allowQueryMarkers: true)
                query = [query, encoded].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "&")
            }
            if let newFragment = suffix.fragment {
                fragment = encode(newFragment, allowQueryMarkers: true)
            }
        }

        url.percentEncodedPath = path
        url.percentEncodedQuery = query
        url.percentEncodedFragment = fragment
        return url.string ?? joinWithoutComponents(trimmedBase, segments: segments)
    }

    public static func joinURL(_ base: String, _ segments: String...) -> URL? {
        URL(string: join(base, segments: segments))
    }

    private static func splitSuffix(_ segment: String) -> (path: String, query: String?, fragment: String?) {
        let fragmentParts = segment.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let queryParts = fragmentParts[0].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        return (String(queryParts[0]),
                queryParts.count == 2 ? String(queryParts[1]) : nil,
                fragmentParts.count == 2 ? String(fragmentParts[1]) : nil)
    }

    private static func encode(_ value: String, allowQueryMarkers: Bool) -> String {
        let bytes = Array(value.utf8)
        var result = ""
        result.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 37, index + 2 < bytes.count,
               isHex(bytes[index + 1]), isHex(bytes[index + 2]) {
                result.append(Character(UnicodeScalar(byte)))
                result.append(Character(UnicodeScalar(bytes[index + 1])))
                result.append(Character(UnicodeScalar(bytes[index + 2])))
                index += 3
            } else if isPathByte(byte) || (allowQueryMarkers && (byte == 63 || byte == 91 || byte == 93)) {
                result.append(Character(UnicodeScalar(byte)))
                index += 1
            } else {
                result += String(format: "%%%02X", byte)
                index += 1
            }
        }
        return result
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }

    private static func isPathByte(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
            || "-._~!$&'()*+,;=:@/".utf8.contains(byte)
    }

    private static func joinWithoutComponents(_ base: String, segments: [String]) -> String {
        var result = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        for segment in segments {
            let part = segment.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !part.isEmpty else { continue }
            if result.isEmpty {
                result = (segment.hasPrefix("/") ? "/" : "") + part
            } else {
                result += "/" + part
            }
        }
        return result
    }
}
