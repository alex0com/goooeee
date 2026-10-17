import Foundation

/// A transcript row produced from markdown: a run of prose blocks, or one code block, table or math block.
public struct MarkdownRow: Identifiable, Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case prose
        case code
        case table
        case math
    }

    public struct Item: Sendable, Hashable {
        /// Stable cache key for frozen blocks; tail blocks get `t<n>` keys and change every update.
        public var key: String
        public var block: MDBlock
        public var isFrozen: Bool
        /// Plain-text length of frozen items (0 for the live tail).
        public var length: Int
    }

    /// Ordinal within the message (`"0"`, `"1"`, …). Rows are only ever appended, so IDs stay stable while streaming.
    public var id: String
    public var kind: Kind
    public var items: [Item]

    /// The row contains the unfinished tail and may still change.
    public var isLive: Bool { items.contains { !$0.isFrozen } }

    /// Number of leading items that will never change.
    public var frozenPrefixCount: Int { items.prefix { $0.isFrozen }.count }

    public var plainText: String { items.map(\.block.plainText).joined(separator: "\n\n") }
}

/// Incremental markdown for streaming.
///
/// Completed top-level blocks are parsed once and frozen; only the unfinished tail is
/// re-parsed on each update (the llama.cpp UI's stable/unstable block idea). Boundaries are
/// only taken where splitting can't change how the text renders: before an unindented line
/// that follows a blank line, a closed code fence or a heading, never inside code fences or
/// `$$` math blocks.
public struct IncrementalMarkdown: Sendable {
    public private(set) var source = ""
    private var frozenEnd: String.Index
    private var frozenChunks: [[(block: MDBlock, length: Int)]] = []
    private let options: MarkdownParser.Options
    /// Prose rows are split after this many characters of frozen text, so a long answer
    /// becomes several rows and per-frame layout stays bounded.
    public static let maxProseRowLength = 4000

    public init(options: MarkdownParser.Options = .init()) {
        self.options = options
        self.frozenEnd = source.startIndex
    }

    /// Characters of `source` that are frozen.
    public var frozenCharacterCount: Int { source.distance(from: source.startIndex, to: frozenEnd) }

    public mutating func reset() {
        source = ""
        frozenEnd = source.startIndex
        frozenChunks = []
    }

    /// Updates with the full text so far. `isFinal` freezes everything.
    public mutating func update(_ text: String, isFinal: Bool = false) -> [MarkdownRow] {
        if !text.hasPrefix(source) || frozenChunks.isEmpty && frozenEnd != source.startIndex {
            reset()
        }
        let frozenOffset = source.utf8.distance(from: source.startIndex, to: frozenEnd)
        source = text
        frozenEnd = source.utf8.index(source.startIndex, offsetBy: frozenOffset)

        let scan = Self.scan(source, from: frozenEnd)
        let freezeUpTo = isFinal ? source.endIndex : (scan.lastBoundary ?? frozenEnd)
        if freezeUpTo > frozenEnd {
            let chunk = String(source[frozenEnd..<freezeUpTo])
            if !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                frozenChunks.append(MarkdownParser.parse(chunk, options: options).map { ($0, $0.plainText.count) })
            }
            frozenEnd = freezeUpTo
        }

        var tailBlocks: [MDBlock] = []
        if frozenEnd < source.endIndex {
            let tail = String(source[frozenEnd...])
            tailBlocks = MarkdownParser.parse(tail, options: options)
            if scan.endsInsideFence, let index = tailBlocks.lastIndex(where: {
                if case .codeBlock = $0 { return true }
                return false
            }), case .codeBlock(let language, let code, _) = tailBlocks[index] {
                tailBlocks[index] = .codeBlock(language: language, code: code, isOpen: true)
            }
        }

        var items: [MarkdownRow.Item] = []
        for (chunkIndex, blocks) in frozenChunks.enumerated() {
            for (blockIndex, entry) in blocks.enumerated() {
                items.append(.init(key: "c\(chunkIndex).\(blockIndex)", block: entry.block, isFrozen: true, length: entry.length))
            }
        }
        for (index, block) in tailBlocks.enumerated() {
            items.append(.init(key: "t\(index)", block: block, isFrozen: false, length: 0))
        }
        return Self.group(items)
    }

    /// One-shot render of complete text.
    public static func render(_ text: String, options: MarkdownParser.Options = .init()) -> [MarkdownRow] {
        var engine = IncrementalMarkdown(options: options)
        return engine.update(text, isFinal: true)
    }

    static func group(_ items: [MarkdownRow.Item]) -> [MarkdownRow] {
        var rows: [MarkdownRow] = []
        var prose: [MarkdownRow.Item] = []
        var proseLength = 0
        func flushProse() {
            proseLength = 0
            guard !prose.isEmpty else { return }
            rows.append(MarkdownRow(id: String(rows.count), kind: .prose, items: prose))
            prose = []
        }
        for item in items {
            switch item.block {
            case .codeBlock:
                flushProse()
                rows.append(MarkdownRow(id: String(rows.count), kind: .code, items: [item]))
            case .table:
                flushProse()
                rows.append(MarkdownRow(id: String(rows.count), kind: .table, items: [item]))
            case .mathBlock:
                flushProse()
                rows.append(MarkdownRow(id: String(rows.count), kind: .math, items: [item]))
            default:
                // Split long prose only at frozen items, so earlier rows never regroup.
                if item.isFrozen, proseLength >= maxProseRowLength {
                    flushProse()
                }
                prose.append(item)
                proseLength += item.length
            }
        }
        flushProse()
        return rows
    }

    struct ScanResult {
        var lastBoundary: String.Index?
        var endsInsideFence: Bool
    }

    /// Finds the last position where the text can be split into independently parsed chunks.
    static func scan(_ text: String, from start: String.Index) -> ScanResult {
        var fence: (char: Character, count: Int)?
        var inMath = false
        var lastBoundary: String.Index?
        var previousBlank = false
        var previousClosedBlock = false
        var lineStart = start

        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
            let line = text[lineStart..<lineEnd]
            let hasNewline = lineEnd < text.endIndex
            let isBlank = line.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" }
            let indented = line.first == " " || line.first == "\t"

            if let open = fence {
                if let close = fenceMarker(line), close.char == open.char, close.count >= open.count,
                    line.drop(while: { $0 == " " }).dropFirst(close.count).allSatisfy({ $0 == " " || $0 == "\t" || $0 == "\r" })
                {
                    fence = nil
                    previousClosedBlock = true
                    previousBlank = false
                }
            } else if inMath {
                if line.contains("$$") {
                    inMath = false
                    previousClosedBlock = true
                    previousBlank = false
                }
            } else if isBlank {
                previousBlank = true
            } else {
                // Only a complete line after the boundary proves the previous block ended.
                if (previousBlank || previousClosedBlock) && !indented && lineStart > start {
                    lastBoundary = lineStart
                }
                previousBlank = false
                previousClosedBlock = false
                if let marker = fenceMarker(line), !indented || line.prefix(while: { $0 == " " }).count < 4 {
                    fence = marker
                } else {
                    let trimmed = line.drop(while: { $0 == " " })
                    if trimmed.hasPrefix("$$") {
                        let rest = trimmed.dropFirst(2)
                        if !rest.contains("$$") { inMath = true }
                    } else if trimmed.hasPrefix("#") && hasNewline {
                        previousClosedBlock = true
                    }
                }
            }
            guard hasNewline else { break }
            lineStart = text.index(after: lineEnd)
        }
        return ScanResult(lastBoundary: lastBoundary, endsInsideFence: fence != nil)
    }

    static func fenceMarker(_ line: Substring) -> (char: Character, count: Int)? {
        let trimmed = line.drop(while: { $0 == " " })
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let count = trimmed.prefix { $0 == first }.count
        guard count >= 3 else { return nil }
        if first == "`" && trimmed.dropFirst(count).contains("`") { return nil }
        return (first, count)
    }
}
