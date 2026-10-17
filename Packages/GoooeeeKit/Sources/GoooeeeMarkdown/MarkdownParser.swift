import Foundation
import Markdown

/// Parses markdown (GFM via cmark-gfm) into the UI-independent `MDBlock` model.
public enum MarkdownParser {
    public struct Options: Sendable, Hashable {
        public var math: Bool

        public init(math: Bool = true) {
            self.math = math
        }
    }

    public static func parse(_ source: String, options: Options = Options()) -> [MDBlock] {
        guard !source.isEmpty else { return [] }
        var formulas: [String] = []
        var text = source
        if options.math, source.contains("$") || source.contains("\\[") || source.contains("\\(") {
            let protected = MathProtection.protect(source)
            text = protected.text
            formulas = protected.formulas
        }
        let document = Document(parsing: text, options: [.disableSmartOpts, .disableSourcePosOpts])
        let converter = Converter(formulas: formulas)
        return document.children.compactMap { converter.block($0) }
    }

    struct Converter {
        let formulas: [String]

        func block(_ markup: Markup) -> MDBlock? {
            switch markup {
            case let paragraph as Paragraph:
                let inlines = inlines(paragraph.children)
                if case .text(let raw)? = inlines.first, inlines.count == 1,
                    let formula = MathProtection.displayFormula(raw, formulas: formulas)
                {
                    return .mathBlock(formula)
                }
                if inlines.count == 1, case .math(let latex) = inlines[0], isDisplayOnly(paragraph) {
                    return .mathBlock(latex)
                }
                return .paragraph(inlines)
            case let heading as Heading:
                return .heading(level: heading.level, inlines(heading.children))
            case let code as CodeBlock:
                var body = code.code
                if body.hasSuffix("\n") { body.removeLast() }
                let language = code.language?.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init)
                return .codeBlock(language: language?.isEmpty == true ? nil : language, code: body, isOpen: false)
            case let quote as BlockQuote:
                return .blockQuote(quote.children.compactMap { block($0) })
            case let list as OrderedList:
                return .list(MDList(ordered: true, start: Int(list.startIndex), items: listItems(list.children)))
            case let list as UnorderedList:
                return .list(MDList(ordered: false, items: listItems(list.children)))
            case let table as Table:
                let alignments: [MDAlignment] = table.columnAlignments.map {
                    switch $0 {
                    case .left: .left
                    case .center: .center
                    case .right: .right
                    case nil: .none
                    }
                }
                let header: [[MDInline]] = table.head.cells.map { inlines($0.children) }
                let rows: [[[MDInline]]] = table.body.rows.map { row in row.cells.map { inlines($0.children) } }
                return .table(MDTable(alignments: alignments, header: header, rows: rows))
            case is ThematicBreak:
                return .thematicBreak
            case let html as HTMLBlock:
                return .html(html.rawHTML)
            default:
                let children = markup.children.compactMap { block($0) }
                return children.isEmpty ? nil : .blockQuote(children)
            }
        }

        func isDisplayOnly(_ paragraph: Paragraph) -> Bool {
            guard let text = paragraph.child(at: 0) as? Text else { return false }
            return MathProtection.displayFormula(text.string, formulas: formulas) != nil
        }

        func listItems(_ children: MarkupChildren) -> [MDListItem] {
            children.compactMap { child in
                guard let item = child as? ListItem else { return nil }
                let checkbox: Bool? = switch item.checkbox {
                case .checked: true
                case .unchecked: false
                case nil: nil
                }
                return MDListItem(checkbox: checkbox, blocks: item.children.compactMap { block($0) })
            }
        }

        func inlines(_ children: MarkupChildren) -> [MDInline] {
            var result: [MDInline] = []
            for child in children {
                result.append(contentsOf: inline(child))
            }
            return merged(result)
        }

        func inline(_ markup: Markup) -> [MDInline] {
            switch markup {
            case let text as Text:
                return MathProtection.restore(text.string, formulas: formulas)
            case let emphasis as Emphasis:
                return [.emphasis(inlines(emphasis.children))]
            case let strong as Strong:
                return [.strong(inlines(strong.children))]
            case let strike as Strikethrough:
                return [.strikethrough(inlines(strike.children))]
            case let code as InlineCode:
                return [.code(code.code)]
            case let link as Link:
                return [.link(destination: link.destination ?? "", children: inlines(link.children))]
            case let image as Image:
                return [.image(source: image.source ?? "", alt: image.plainText)]
            case is SoftBreak:
                return [.softBreak]
            case is LineBreak:
                return [.lineBreak]
            case let html as InlineHTML:
                return [.html(html.rawHTML)]
            default:
                return inlines(markup.children)
            }
        }

        /// Joins adjacent text runs.
        func merged(_ inlines: [MDInline]) -> [MDInline] {
            var output: [MDInline] = []
            for inline in inlines {
                if case .text(let next) = inline, case .text(let previous)? = output.last {
                    output[output.count - 1] = .text(previous + next)
                } else {
                    output.append(inline)
                }
            }
            return output
        }
    }
}
