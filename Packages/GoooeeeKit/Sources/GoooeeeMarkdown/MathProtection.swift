import Foundation

/// Finds LaTeX math in markdown and replaces it with placeholders before parsing, so the
/// markdown parser doesn't mangle `_`, `*` or `\` inside formulas.
///
/// Recognizes `$$…$$`, `\[…\]` (display) and `\(…\)`, `$…$` (inline). Code spans and
/// fenced code are left alone. Inline `$` follows the usual rules that avoid currency:
/// the opening `$` must not be followed by whitespace, the closing `$` must not be preceded
/// by whitespace or followed by a digit, and content that starts with a digit must look like math.
public enum MathProtection {
    public static let open: Character = "\u{E000}"
    public static let close: Character = "\u{E001}"
    public static let displayMarker: Character = "\u{E002}"

    public struct Result: Sendable {
        public var text: String
        public var formulas: [String]
        public var displayFlags: [Bool]
    }

    public static func protect(_ source: String) -> Result {
        var output = ""
        output.reserveCapacity(source.count)
        var formulas: [String] = []
        var display: [Bool] = []
        let chars = Array(source)
        var index = 0
        var lineStart = true
        var fence: (char: Character, count: Int)?

        func placeholder(_ latex: String, isDisplay: Bool) -> String {
            formulas.append(latex)
            display.append(isDisplay)
            return "\(open)\(isDisplay ? String(displayMarker) : "")\(formulas.count - 1)\(close)"
        }

        while index < chars.count {
            let char = chars[index]

            // Fenced code blocks: copy verbatim.
            if lineStart {
                var probe = index
                var indent = 0
                while probe < chars.count, chars[probe] == " ", indent < 4 { probe += 1; indent += 1 }
                if probe < chars.count, chars[probe] == "`" || chars[probe] == "~" {
                    let fenceChar = chars[probe]
                    var count = 0
                    while probe + count < chars.count, chars[probe + count] == fenceChar { count += 1 }
                    if count >= 3 {
                        if let open = fence {
                            if open.char == fenceChar && count >= open.count { fence = nil }
                        } else {
                            fence = (fenceChar, count)
                        }
                        // Copy the whole fence line.
                        var end = index
                        while end < chars.count, chars[end] != "\n" { end += 1 }
                        output.append(contentsOf: chars[index..<min(end + 1, chars.count)])
                        index = end + 1
                        lineStart = true
                        continue
                    }
                }
            }
            if fence != nil {
                output.append(char)
                lineStart = char == "\n"
                index += 1
                continue
            }

            // Inline code spans: copy verbatim.
            if char == "`" {
                var ticks = 0
                while index + ticks < chars.count, chars[index + ticks] == "`" { ticks += 1 }
                if let end = findClosingBackticks(chars, from: index + ticks, count: ticks) {
                    output.append(contentsOf: chars[index..<(end + ticks)])
                    index = end + ticks
                    lineStart = false
                    continue
                }
                output.append(contentsOf: chars[index..<(index + ticks)])
                index += ticks
                lineStart = false
                continue
            }

            // Escaped dollar.
            if char == "\\", index + 1 < chars.count, chars[index + 1] == "$" {
                output.append("\\$")
                index += 2
                lineStart = false
                continue
            }

            // \[ … \] and \( … \)
            if char == "\\", index + 1 < chars.count, chars[index + 1] == "[" || chars[index + 1] == "(" {
                let isDisplay = chars[index + 1] == "["
                let closing: [Character] = isDisplay ? ["\\", "]"] : ["\\", ")"]
                if let end = find(closing, in: chars, from: index + 2) {
                    let latex = String(chars[(index + 2)..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !latex.isEmpty {
                        output += placeholder(latex, isDisplay: isDisplay)
                        index = end + 2
                        lineStart = false
                        continue
                    }
                }
            }

            if char == "$" {
                // $$ … $$
                if index + 1 < chars.count, chars[index + 1] == "$" {
                    if let end = find(["$", "$"], in: chars, from: index + 2) {
                        let latex = String(chars[(index + 2)..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !latex.isEmpty {
                            output += placeholder(latex, isDisplay: true)
                            index = end + 2
                            lineStart = false
                            continue
                        }
                    }
                } else if let end = inlineDollarEnd(chars, start: index) {
                    let latex = String(chars[(index + 1)..<end])
                    output += placeholder(latex, isDisplay: false)
                    index = end + 1
                    lineStart = false
                    continue
                }
            }

            output.append(char)
            lineStart = char == "\n"
            index += 1
        }
        return Result(text: output, formulas: formulas, displayFlags: display)
    }

    static func inlineDollarEnd(_ chars: [Character], start: Int) -> Int? {
        let first = start + 1
        guard first < chars.count, !chars[first].isWhitespace, chars[first] != "$" else { return nil }
        var index = first
        while index < chars.count {
            let char = chars[index]
            if char == "\n" { return nil }
            if char == "\\" { index += 2; continue }
            if char == "$" {
                guard !chars[index - 1].isWhitespace else { return nil }
                if index + 1 < chars.count, chars[index + 1].isNumber { return nil }
                let content = String(chars[first..<index])
                if chars[first].isNumber && content.rangeOfCharacter(from: CharacterSet(charactersIn: "^_\\{}=+-*/<>()")) == nil {
                    return nil
                }
                return index
            }
            index += 1
        }
        return nil
    }

    static func find(_ needle: [Character], in chars: [Character], from start: Int) -> Int? {
        guard needle.count > 0, start < chars.count else { return nil }
        var index = start
        while index + needle.count <= chars.count {
            if chars[index] == needle[0] && Array(chars[index..<(index + needle.count)]) == needle {
                return index
            }
            index += 1
        }
        return nil
    }

    static func findClosingBackticks(_ chars: [Character], from start: Int, count: Int) -> Int? {
        var index = start
        while index < chars.count {
            if chars[index] == "\n", index + 1 < chars.count, chars[index + 1] == "\n" { return nil }
            if chars[index] == "`" {
                var run = 0
                while index + run < chars.count, chars[index + run] == "`" { run += 1 }
                if run == count { return index }
                index += run
                continue
            }
            index += 1
        }
        return nil
    }

    /// Splits text containing placeholders back into text and math inlines.
    static func restore(_ text: String, formulas: [String]) -> [MDInline] {
        guard text.contains(open), !formulas.isEmpty else { return [.text(text)] }
        var result: [MDInline] = []
        var current = ""
        var iterator = text.makeIterator()
        while let char = iterator.next() {
            if char == open {
                var token = ""
                while let next = iterator.next(), next != close { token.append(next) }
                if token.first == displayMarker { token.removeFirst() }
                if let number = Int(token), formulas.indices.contains(number) {
                    if !current.isEmpty { result.append(.text(current)); current = "" }
                    result.append(.math(formulas[number]))
                } else {
                    current += token
                }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { result.append(.text(current)) }
        return result
    }

    /// If `text` is exactly one display-math placeholder, returns its formula.
    static func displayFormula(_ text: String, formulas: [String]) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == open, trimmed.last == close else { return nil }
        let inner = trimmed.dropFirst().dropLast()
        guard inner.first == displayMarker, let number = Int(inner.dropFirst()), formulas.indices.contains(number) else { return nil }
        return formulas[number]
    }
}
