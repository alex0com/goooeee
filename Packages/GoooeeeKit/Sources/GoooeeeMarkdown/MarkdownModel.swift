import Foundation

/// Inline markdown content, independent of any UI framework.
public indirect enum MDInline: Sendable, Hashable {
    case text(String)
    case emphasis([MDInline])
    case strong([MDInline])
    case strikethrough([MDInline])
    case code(String)
    case link(destination: String, children: [MDInline])
    case image(source: String, alt: String)
    case math(String)
    case softBreak
    case lineBreak
    case html(String)

    /// Plain text (for copy, search and accessibility).
    public var plainText: String {
        switch self {
        case .text(let text), .code(let text), .html(let text): text
        case .emphasis(let children), .strong(let children), .strikethrough(let children): children.plainText
        case .link(_, let children): children.plainText
        case .image(_, let alt): alt
        case .math(let latex): latex
        case .softBreak: " "
        case .lineBreak: "\n"
        }
    }
}

extension Array where Element == MDInline {
    public var plainText: String { map(\.plainText).joined() }
}

public enum MDAlignment: Sendable, Hashable {
    case left, center, right, none
}

public struct MDTable: Sendable, Hashable {
    public var alignments: [MDAlignment]
    public var header: [[MDInline]]
    public var rows: [[[MDInline]]]

    public init(alignments: [MDAlignment], header: [[MDInline]], rows: [[[MDInline]]]) {
        self.alignments = alignments
        self.header = header
        self.rows = rows
    }

    public var columnCount: Int { max(header.count, rows.map(\.count).max() ?? 0) }

    /// Tab-separated text for copying.
    public var plainText: String {
        ([header] + rows).map { $0.map(\.plainText).joined(separator: "\t") }.joined(separator: "\n")
    }
}

public struct MDListItem: Sendable, Hashable {
    /// `nil` for a normal item, `true/false` for a task list item.
    public var checkbox: Bool?
    public var blocks: [MDBlock]

    public init(checkbox: Bool? = nil, blocks: [MDBlock]) {
        self.checkbox = checkbox
        self.blocks = blocks
    }
}

public struct MDList: Sendable, Hashable {
    public var ordered: Bool
    public var start: Int
    public var items: [MDListItem]

    public init(ordered: Bool, start: Int = 1, items: [MDListItem]) {
        self.ordered = ordered
        self.start = start
        self.items = items
    }
}

/// Block-level markdown content.
public indirect enum MDBlock: Sendable, Hashable {
    case paragraph([MDInline])
    case heading(level: Int, [MDInline])
    case codeBlock(language: String?, code: String, isOpen: Bool)
    case blockQuote([MDBlock])
    case list(MDList)
    case table(MDTable)
    case thematicBreak
    case mathBlock(String)
    case html(String)

    public var plainText: String {
        switch self {
        case .paragraph(let inlines): inlines.plainText
        case .heading(_, let inlines): inlines.plainText
        case .codeBlock(_, let code, _): code
        case .blockQuote(let blocks): blocks.map(\.plainText).joined(separator: "\n")
        case .list(let list):
            list.items.enumerated().map { index, item in
                let marker = list.ordered ? "\(list.start + index). " : "• "
                return marker + item.blocks.map(\.plainText).joined(separator: "\n")
            }.joined(separator: "\n")
        case .table(let table): table.plainText
        case .thematicBreak: "———"
        case .mathBlock(let latex): latex
        case .html(let html): html
        }
    }

    /// Blocks that get their own transcript row instead of joining a prose row.
    public var isStandalone: Bool {
        switch self {
        case .codeBlock, .table, .mathBlock: true
        default: false
        }
    }
}
