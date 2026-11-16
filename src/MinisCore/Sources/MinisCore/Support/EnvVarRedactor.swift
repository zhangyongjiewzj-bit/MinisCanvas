// Historical source: OpenMinis EnvVarRedactor; MinisCanvas uses full-value masking.
// Reimplemented from an independent behavior specification.
import Foundation

public enum EnvVarRedactor {
    public static let minMatchLen = 5

    public static func redact(_ value: String) -> String {
        String(repeating: "*", count: value.count)
    }

    public static func redactAll(in text: String, values: [String]) -> (String, Int) {
        struct Hit {
            let range: Range<String.Index>
            let value: String
            let width: Int
        }
        var hits: [Hit] = []
        for value in Set(values) {
            let width = value.count
            if width < minMatchLen { continue }
            var search = text.startIndex..<text.endIndex
            while let range = text.range(of: value, options: .literal, range: search) {
                hits.append(Hit(range: range, value: value, width: width))
                search = range.upperBound..<text.endIndex
            }
        }
        hits.sort { $0.width > $1.width }
        var occupied = IndexSet()
        var selected: [Hit] = []
        var matched = Set<String>()
        for hit in hits {
            let units = NSRange(hit.range, in: text)
            let interval = units.location..<(units.location + units.length)
            if occupied.intersects(integersIn: interval) { continue }
            occupied.insert(integersIn: interval)
            selected.append(hit)
            matched.insert(hit.value)
        }
        selected.sort { $0.range.lowerBound < $1.range.lowerBound }
        var output = ""
        var cursor = text.startIndex
        for hit in selected {
            output += text[cursor..<hit.range.lowerBound]
            output += String(repeating: "*", count: hit.width)
            cursor = hit.range.upperBound
        }
        output += text[cursor...]
        return (output, matched.count)
    }

    public static func redactAll(in text: String, entries: [EnvVarEntry]) -> (String, Int) {
        redactAll(in: text, values: entries.filter(\.isSecret).map(\.value))
    }
}
