import AppKit
import GoooeeeMarkdown

/// Base text style for rendering markdown.
struct MarkdownStyle {
    var font: NSFont
    var color: NSColor
    var lineHeightMultiple: CGFloat
    var paragraphSpacing: CGFloat
}

/// Turns the markdown model into attributed strings for the transcript's text views.
///
/// For streaming prose rows the frozen items are rendered once and kept as a prefix per row;
/// each frame only appends the live tail.
@MainActor
final class MarkdownRenderer {
    private(set) var theme: TranscriptTheme
    let math = MathRenderer()
    private var prefixes: [String: (keys: [String], string: NSAttributedString)] = [:]

    init(theme: TranscriptTheme) {
        self.theme = theme
    }

    func setTheme(_ theme: TranscriptTheme) {
        let mathChanged = theme.isDark != self.theme.isDark || theme.generation != self.theme.generation
        self.theme = theme
        prefixes.removeAll()
        if mathChanged { math.removeAll() }
    }

    /// Forgets cached prefixes of rows whose ID starts with `prefix` (a message was edited).
    func invalidate(rowsWithPrefix prefix: String) {
        for key in prefixes.keys where key.hasPrefix(prefix) {
            prefixes[key] = nil
        }
    }

    // MARK: Entry points

    /// A prose row of an assistant message.
    func renderProse(_ row: MarkdownRow, rowID: String, style: MarkdownStyle) -> NSAttributedString {
        let frozenCount = row.frozenPrefixCount
        let keys = row.items.prefix(frozenCount).map(\.key)
        let prefix: NSAttributedString
        if let entry = prefixes[rowID], entry.keys == keys {
            prefix = entry.string
        } else if let entry = prefixes[rowID], entry.keys.count < keys.count, Array(keys.prefix(entry.keys.count)) == entry.keys {
            let extended = NSMutableAttributedString(attributedString: entry.string)
            for item in row.items[entry.keys.count..<frozenCount] {
                appendParagraphs(paragraphs(for: item.block, context: BlockContext(style: style)), to: extended)
            }
            prefix = extended
            prefixes[rowID] = (keys, extended)
        } else {
            let built = NSMutableAttributedString()
            for item in row.items.prefix(frozenCount) {
                appendParagraphs(paragraphs(for: item.block, context: BlockContext(style: style)), to: built)
            }
            prefix = built
            prefixes[rowID] = (keys, built)
        }
        if prefixes.count > 2000 { prefixes.removeAll() }
        guard frozenCount < row.items.count else { return prefix }
        let result = NSMutableAttributedString(attributedString: prefix)
        for item in row.items[frozenCount...] {
            appendParagraphs(paragraphs(for: item.block, context: BlockContext(style: style)), to: result)
        }
        return result
    }

    /// Complete blocks (user messages, finished thinking). Not cached here.
    func renderBlocks(_ blocks: [MDBlock], style: MarkdownStyle) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for block in blocks {
            appendParagraphs(paragraphs(for: block, context: BlockContext(style: style)), to: result)
        }
        return result
    }

    /// Plain text with the style's paragraph settings.
    func plain(_ text: String, style: MarkdownStyle) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = style.lineHeightMultiple
        paragraph.paragraphSpacing = 0
        return NSAttributedString(string: text, attributes: [
            .font: style.font,
            .foregroundColor: style.color,
            .paragraphStyle: paragraph,
        ])
    }

    /// Inline content of a table cell.
    func renderInlines(_ inlines: [MDInline], font: NSFont, color: NSColor, alignment: NSTextAlignment = .natural) -> NSAttributedString {
        let result = NSMutableAttributedString()
        appendInlines(inlines, to: result, traits: InlineTraits(base: font, color: color))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byWordWrapping
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        return result
    }

    // MARK: Blocks

    private struct BlockContext {
        var style: MarkdownStyle
        var indent: CGFloat = 0
        var quoteDepth = 0
        var listDepth = 0
        var color: NSColor

        init(style: MarkdownStyle) {
            self.style = style
            self.color = style.color
        }
    }

    private func paragraphs(for block: MDBlock, context: BlockContext) -> [NSMutableAttributedString] {
        switch block {
        case .paragraph(let inlines):
            let content = NSMutableAttributedString()
            appendInlines(inlines, to: content, traits: InlineTraits(base: context.style.font, color: context.color))
            return [finish(content, context: context)]

        case .heading(let level, let inlines):
            let font = theme.headingFont(level: level, base: context.style.font)
            let content = NSMutableAttributedString()
            appendInlines(inlines, to: content, traits: InlineTraits(base: font, color: context.color))
            let spacing = context.style.paragraphSpacing * (level <= 2 ? 0.7 : 0.5)
            let before = level <= 3 ? context.style.paragraphSpacing * 0.6 : 0
            return [finish(content, context: context, spacing: spacing, spacingBefore: before)]

        case .codeBlock(_, let code, _):
            // Top-level code blocks are rows of their own; this is code nested in a list or quote.
            let font = theme.inlineCodeFont(for: context.style.font)
            let text = CodeHighlighter.displayCode(code).replacingOccurrences(of: "\n", with: "\u{2028}")
            let content = NSMutableAttributedString(string: text.isEmpty ? " " : text, attributes: [
                .font: font,
                .foregroundColor: context.color,
                .backgroundColor: TranscriptColors.inlineCodeBackground,
            ])
            var nested = context
            nested.indent += 8
            return [finish(content, context: nested, lineHeightMultiple: 1.1)]

        case .blockQuote(let blocks):
            var nested = context
            nested.quoteDepth += 1
            nested.indent += TranscriptMetrics.quoteIndent
            nested.color = TranscriptColors.secondaryText
            return blocks.flatMap { paragraphs(for: $0, context: nested) }

        case .list(let list):
            return listParagraphs(list, context: context)

        case .table(let table):
            // Nested tables are rare; show them as tab-separated monospaced text.
            let font = theme.inlineCodeFont(for: context.style.font)
            let text = table.plainText.replacingOccurrences(of: "\n", with: "\u{2028}").replacingOccurrences(of: "\t", with: "  │  ")
            let content = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: context.color])
            return [finish(content, context: context)]

        case .thematicBreak:
            let content = NSMutableAttributedString(string: "\u{00A0}", attributes: [
                .font: NSFont.systemFont(ofSize: 6),
                .foregroundColor: context.color,
                .transcriptRule: true,
            ])
            return [finish(content, context: context, lineHeightMultiple: 1)]

        case .mathBlock(let latex):
            let content = NSMutableAttributedString()
            if let attachment = math.image(latex: latex, display: true, fontSize: (context.style.font.pointSize * 1.15).rounded(), isDark: theme.isDark) {
                let textAttachment = NSTextAttachment()
                textAttachment.image = attachment
                textAttachment.bounds = CGRect(origin: .zero, size: attachment.size)
                content.append(NSAttributedString(attachment: textAttachment))
            } else {
                content.append(NSAttributedString(string: latex, attributes: [
                    .font: theme.inlineCodeFont(for: context.style.font),
                    .foregroundColor: context.color,
                ]))
            }
            return [finish(content, context: context, alignment: .center)]

        case .html(let html):
            let content = NSMutableAttributedString(string: html, attributes: [
                .font: theme.inlineCodeFont(for: context.style.font),
                .foregroundColor: TranscriptColors.secondaryText,
            ])
            return [finish(content, context: context)]
        }
    }

    private func listParagraphs(_ list: MDList, context: BlockContext) -> [NSMutableAttributedString] {
        let font = context.style.font
        let markerWidth: CGFloat
        if list.ordered {
            let largest = list.start + max(0, list.items.count - 1)
            let sample = String(repeating: "0", count: String(largest).count) + "."
            markerWidth = ceil((sample as NSString).size(withAttributes: [.font: font]).width) + 8
        } else {
            markerWidth = ceil(font.pointSize * 1.3)
        }
        let bullets = ["•", "◦", "▪︎"]
        let tightSpacing = (context.style.paragraphSpacing * 0.3).rounded()
        var result: [NSMutableAttributedString] = []
        for (index, item) in list.items.enumerated() {
            var nested = context
            nested.indent = context.indent + markerWidth
            nested.listDepth += 1
            var itemParagraphs = item.blocks.flatMap { paragraphs(for: $0, context: nested) }
            if itemParagraphs.isEmpty {
                itemParagraphs = [finish(NSMutableAttributedString(string: " ", attributes: [.font: font, .foregroundColor: context.color]), context: nested)]
            }
            let marker: String
            if let checked = item.checkbox {
                marker = checked ? "☑︎" : "☐"
            } else if list.ordered {
                marker = "\(list.start + index)."
            } else {
                marker = bullets[context.listDepth % bullets.count]
            }
            let markerColor = list.ordered || item.checkbox != nil ? context.color : TranscriptColors.secondaryText
            let first = itemParagraphs[0]
            let existingStyle = first.length > 0 ? first.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle : nil
            let markerString = NSAttributedString(string: marker + "\t", attributes: [
                .font: font,
                .foregroundColor: markerColor,
                .paragraphStyle: existingStyle ?? baseParagraphStyle(nested),
            ])
            first.insert(markerString, at: 0)
            updateParagraphStyle(of: first) { style in
                style.firstLineHeadIndent = context.indent
                style.headIndent = nested.indent
                style.tabStops = [NSTextTab(textAlignment: .left, location: nested.indent)]
            }
            for paragraph in itemParagraphs {
                updateParagraphStyle(of: paragraph) { style in
                    style.paragraphSpacing = min(style.paragraphSpacing, tightSpacing)
                }
            }
            result += itemParagraphs
        }
        if let last = result.last {
            updateParagraphStyle(of: last) { $0.paragraphSpacing = context.style.paragraphSpacing }
        }
        return result
    }

    /// Applies the paragraph style and quote depth to a finished paragraph.
    private func finish(
        _ content: NSMutableAttributedString,
        context: BlockContext,
        spacing: CGFloat? = nil,
        spacingBefore: CGFloat = 0,
        lineHeightMultiple: CGFloat? = nil,
        alignment: NSTextAlignment = .natural
    ) -> NSMutableAttributedString {
        let style = baseParagraphStyle(context)
        if let lineHeightMultiple { style.lineHeightMultiple = lineHeightMultiple }
        if let spacing { style.paragraphSpacing = spacing }
        style.paragraphSpacingBefore = spacingBefore
        style.alignment = alignment
        let range = NSRange(location: 0, length: content.length)
        content.addAttribute(.paragraphStyle, value: style, range: range)
        if context.quoteDepth > 0 {
            content.addAttribute(.transcriptQuoteDepth, value: context.quoteDepth, range: range)
        }
        return content
    }

    private func baseParagraphStyle(_ context: BlockContext) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = context.style.lineHeightMultiple
        style.paragraphSpacing = context.style.paragraphSpacing
        style.headIndent = context.indent
        style.firstLineHeadIndent = context.indent
        style.lineBreakMode = .byWordWrapping
        return style
    }

    private func updateParagraphStyle(of paragraph: NSMutableAttributedString, _ change: (NSMutableParagraphStyle) -> Void) {
        guard paragraph.length > 0 else { return }
        let current = (paragraph.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle) ?? NSParagraphStyle.default
        guard let style = current.mutableCopy() as? NSMutableParagraphStyle else { return }
        change(style)
        paragraph.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: paragraph.length))
    }

    /// Joins paragraphs with newlines that carry the previous paragraph's style.
    private func appendParagraphs(_ paragraphs: [NSMutableAttributedString], to result: NSMutableAttributedString) {
        for paragraph in paragraphs {
            if result.length > 0 {
                var attributes = result.attributes(at: result.length - 1, effectiveRange: nil)
                for key in [NSAttributedString.Key.attachment, .link, .backgroundColor, .transcriptRule] {
                    attributes[key] = nil
                }
                result.append(NSAttributedString(string: "\n", attributes: attributes))
            }
            result.append(paragraph)
        }
    }

    // MARK: Inlines

    private struct InlineTraits {
        var base: NSFont
        var color: NSColor
        var bold = false
        var italic = false
        var strike = false
        var link: URL?
    }

    private func attributes(_ traits: InlineTraits) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: FontVariants.font(traits.base, bold: traits.bold, italic: traits.italic),
            .foregroundColor: traits.link != nil ? TranscriptColors.link : traits.color,
        ]
        if traits.strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let link = traits.link { attributes[.link] = link }
        return attributes
    }

    private func appendInlines(_ inlines: [MDInline], to result: NSMutableAttributedString, traits: InlineTraits) {
        for inline in inlines {
            switch inline {
            case .text(let text):
                result.append(NSAttributedString(string: text, attributes: attributes(traits)))
            case .emphasis(let children):
                var nested = traits
                nested.italic = true
                appendInlines(children, to: result, traits: nested)
            case .strong(let children):
                var nested = traits
                nested.bold = true
                appendInlines(children, to: result, traits: nested)
            case .strikethrough(let children):
                var nested = traits
                nested.strike = true
                appendInlines(children, to: result, traits: nested)
            case .code(let code):
                var codeAttributes = attributes(traits)
                codeAttributes[.font] = theme.inlineCodeFont(for: traits.base)
                codeAttributes[.backgroundColor] = TranscriptColors.inlineCodeBackground
                if traits.link == nil { codeAttributes[.foregroundColor] = traits.color }
                result.append(NSAttributedString(string: code, attributes: codeAttributes))
            case .link(let destination, let children):
                var nested = traits
                nested.link = URL(string: destination)
                if children.isEmpty {
                    result.append(NSAttributedString(string: destination, attributes: attributes(nested)))
                } else {
                    appendInlines(children, to: result, traits: nested)
                }
            case .image(let source, let alt):
                // Remote images aren't fetched; show a link instead.
                var nested = traits
                nested.link = URL(string: source)
                result.append(NSAttributedString(string: "🖼 " + (alt.isEmpty ? source : alt), attributes: attributes(nested)))
            case .math(let latex):
                if let attachment = math.inlineAttachment(latex: latex, font: traits.base, isDark: theme.isDark) {
                    result.append(attachment)
                } else {
                    var codeAttributes = attributes(traits)
                    codeAttributes[.font] = theme.inlineCodeFont(for: traits.base)
                    result.append(NSAttributedString(string: latex, attributes: codeAttributes))
                }
            case .softBreak:
                result.append(NSAttributedString(string: " ", attributes: attributes(traits)))
            case .lineBreak:
                result.append(NSAttributedString(string: "\u{2028}", attributes: attributes(traits)))
            case .html(let html):
                if html.lowercased().hasPrefix("<br") {
                    result.append(NSAttributedString(string: "\u{2028}", attributes: attributes(traits)))
                } else {
                    var htmlAttributes = attributes(traits)
                    htmlAttributes[.foregroundColor] = TranscriptColors.secondaryText
                    result.append(NSAttributedString(string: html, attributes: htmlAttributes))
                }
            }
        }
    }
}
