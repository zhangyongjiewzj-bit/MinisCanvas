import Foundation

/// Produces a readable paragraph from the Markdown forms used by text tools.
public enum MarkdownStripper {
    public static func strip(_ text: String) -> String {
        let withoutBlocks = removingCodeBlocks(text)
        let lines = withoutBlocks.components(separatedBy: .newlines).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("```"), !trimmed.hasPrefix("~~~"),
                  !isTableLine(trimmed), !isDivider(trimmed) else { return nil }
            let body = inlineText(removingLinePrefix(trimmed))
                .trimmingCharacters(in: .whitespaces)
            return body.isEmpty ? nil : body
        }
        var result = ""
        var previousWasSpace = false
        for character in lines.joined(separator: " ") {
            if character != " " || !previousWasSpace {
                result.append(character)
            }
            previousWasSpace = character == " "
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func plainText(_ text: String) -> String {
        strip(text)
    }

    private static func removingCodeBlocks(_ text: String) -> String {
        var remainder = text[...]
        var kept = ""
        while let opening = remainder.range(of: "```") {
            guard let closing = remainder[opening.upperBound...].range(of: "```") else { break }
            kept += remainder[..<opening.lowerBound]
            remainder = remainder[closing.upperBound...]
        }
        kept += remainder
        return kept
    }

    private static func isTableLine(_ line: String) -> Bool {
        if line.first == "|" || (line.contains("|") && line.last == "|") { return true }
        return line.contains("|") && line.allSatisfy {
            $0 == "|" || $0 == "-" || $0 == ":" || $0.isWhitespace
        }
    }

    private static func isDivider(_ line: String) -> Bool {
        line.allSatisfy { "-*_=~".contains($0) || $0.isWhitespace }
    }

    private static func removingLinePrefix(_ line: String) -> String {
        var body = line[...]
        while body.first == ">" {
            body = body.dropFirst().drop(while: { $0.isWhitespace })
        }
        let hashes = body.prefix(while: { $0 == "#" }).count
        if (1...6).contains(hashes) {
            let afterHashes = body.dropFirst(hashes)
            if afterHashes.first?.isWhitespace == true {
                return String(afterHashes.drop(while: { $0.isWhitespace }))
            }
        }
        if let first = body.first, "-*+".contains(first),
           body.dropFirst().first?.isWhitespace == true {
            return String(body.dropFirst().drop(while: { $0.isWhitespace }))
        }
        let digits = body.prefix(while: { "0123456789".contains($0) }).count
        if digits > 0 {
            let afterDigits = body.dropFirst(digits)
            if let punctuation = afterDigits.first, ".):".contains(punctuation),
               afterDigits.dropFirst().first?.isWhitespace == true {
                return String(afterDigits.dropFirst().drop(while: { $0.isWhitespace }))
            }
        }
        return String(body)
    }

    private static func inlineText(_ text: String) -> String {
        let characters = Array(text)
        var output = ""
        var cursor = 0
        while cursor < characters.count {
            let image = characters[cursor] == "!" && cursor + 1 < characters.count
                && characters[cursor + 1] == "["
            let bracket = image ? cursor + 1 : cursor
            if characters[bracket] == "[",
               let link = linkText(characters, startingAt: bracket, image: image) {
                output += link.text
                cursor = link.end
                continue
            }
            if characters[cursor] == "<",
               let end = characters[(cursor + 1)...].firstIndex(of: ">") {
                let address = String(characters[(cursor + 1)..<end])
                if address.hasPrefix("https://") || address.hasPrefix("http://") {
                    output += address
                    cursor = end + 1
                    continue
                }
            }
            output.append(characters[cursor])
            cursor += 1
        }
        for marker in ["**", "__", "~~", "`", "*", "_"] {
            output = removingPairedMarker(marker, from: output)
        }
        return output
    }

    private static func linkText(
        _ characters: [Character], startingAt start: Int, image: Bool
    ) -> (text: String, end: Int)? {
        guard let labelEnd = characters[(start + 1)...].firstIndex(of: "]"),
              labelEnd + 1 < characters.count, characters[labelEnd + 1] == "(" else { return nil }
        let targetStart = labelEnd + 2
        var cursor = targetStart
        var parentheses = 1
        var quote: Character?
        while cursor < characters.count {
            let character = characters[cursor]
            if let activeQuote = quote {
                if character == activeQuote { quote = nil }
            } else if (character == "\"" || character == "'") && cursor > targetStart
                        && characters[cursor - 1].isWhitespace {
                quote = character
            } else if character == "(" {
                parentheses += 1
            } else if character == ")" {
                parentheses -= 1
                if parentheses == 0 {
                    let label = String(characters[(start + 1)..<labelEnd])
                    let destination = characters[targetStart..<cursor]
                        .drop(while: { $0.isWhitespace })
                        .prefix(while: { !$0.isWhitespace })
                    let replacement = !label.isEmpty || image ? label : String(destination)
                    return (replacement, cursor + 1)
                }
            }
            cursor += 1
        }
        return nil
    }

    private static func removingPairedMarker(_ marker: String, from text: String) -> String {
        var remainder = text[...]
        var kept = ""
        while let opening = remainder.range(of: marker) {
            if marker == "_", opening.lowerBound > text.startIndex,
               isWordCharacter(text[text.index(before: opening.lowerBound)]) {
                kept += remainder[..<opening.upperBound]
                remainder = remainder[opening.upperBound...]
                continue
            }
            var search = remainder[opening.upperBound...]
            var closing = search.range(of: marker)
            while marker == "_", let candidate = closing,
                  candidate.upperBound < text.endIndex,
                  isWordCharacter(text[candidate.upperBound]) {
                search = search[candidate.upperBound...]
                closing = search.range(of: marker)
            }
            guard let closing else { break }
            kept += remainder[..<opening.lowerBound]
            kept += remainder[opening.upperBound..<closing.lowerBound]
            remainder = remainder[closing.upperBound...]
        }
        kept += remainder
        return kept
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }
}
