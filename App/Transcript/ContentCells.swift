import AppKit
import GoooeeeCore
import GoooeeeMarkdown
import GoooeeeTranscript

// MARK: - Thinking

/// A collapsible thinking block: "Thinking…" while streaming, "Thought for 12s" when done.
final class ThinkingCell: TranscriptCellView {
    private let header = ClickableView()
    private let chevron = NSImageView()
    private let titleLabel = makeTranscriptLabel(font: .systemFont(ofSize: 12, weight: .medium))
    private let spinner = NSProgressIndicator()
    private let stopButton = ActionButton.link("Stop thinking")
    private let textView = TranscriptTextView.makeReadOnly()
    private var showsBody = false

    private static let headerHeight: CGFloat = 24
    private static let bodyIndent: CGFloat = 14

    override func setUp() {
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        chevron.contentTintColor = .secondaryLabelColor
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        header.addSubview(chevron)
        header.addSubview(titleLabel)
        header.addSubview(spinner)
        addSubview(header)
        addSubview(stopButton)
        addSubview(textView)
    }

    private static func bodySize(_ row: TranscriptRow, _ content: ThinkingContent, width: CGFloat, context: TranscriptContext) -> CGSize {
        let column = context.column(for: width)
        let string = context.thinkingString(row, content)
        let size = context.measure(string, width: column.width - bodyIndent, key: "\(row.id)#\(row.signature)#think")
        return CGSize(width: size.width, height: size.height)
    }

    static func height(for row: TranscriptRow, width: CGFloat, context: TranscriptContext) -> CGFloat {
        guard case .thinking(let content) = row.kind else { return 1 }
        var height: CGFloat = 4 + headerHeight
        if context.isThinkingExpanded(row, content), !content.text.isEmpty {
            height += 4 + bodySize(row, content, width: width, context: context).height + 4
        }
        return height + 4
    }

    static func title(_ content: ThinkingContent) -> String {
        if content.isStreaming { return "Thinking…" }
        guard let duration = content.duration else { return "Thinking" }
        let seconds = Int(duration.rounded())
        if seconds < 1 { return "Thought for a moment" }
        if seconds < 60 { return "Thought for \(seconds)s" }
        return "Thought for \(seconds / 60)m \(seconds % 60)s"
    }

    override func configure(_ row: TranscriptRow, context: TranscriptContext) {
        super.configure(row, context: context)
        guard case .thinking(let content) = row.kind else { return }
        let expanded = context.isThinkingExpanded(row, content)
        showsBody = expanded && !content.text.isEmpty
        titleLabel.stringValue = Self.title(content)
        titleLabel.font = .systemFont(ofSize: max(11, context.theme.thinkingFont.pointSize), weight: .medium)
        chevron.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: expanded ? "Collapse" : "Expand")
        if content.isStreaming { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        stopButton.isHidden = !content.canStop
        stopButton.onClick = { [weak context] in context?.stopThinking() }
        header.onClick = { [weak context] in context?.toggleThinking(row) }
        header.setAccessibilityLabel(Self.title(content))
        textView.isHidden = !showsBody
        textView.messageID = row.messageID
        textView.menuProvider = menuProvider()
        if showsBody {
            textView.setContent(context.thinkingString(row, content))
        }
    }

    override func layout() {
        super.layout()
        guard let row, let context, case .thinking(let content) = row.kind else { return }
        let column = self.column
        header.frame = CGRect(x: column.x, y: 4, width: column.width, height: Self.headerHeight)
        chevron.frame = CGRect(x: 0, y: 6, width: 12, height: 12)
        let titleWidth = ceil(titleLabel.intrinsicContentSize.width)
        titleLabel.frame = CGRect(x: 16, y: 4, width: min(titleWidth, column.width - 140), height: 16)
        spinner.frame = CGRect(x: titleLabel.frame.maxX + 6, y: 4, width: 16, height: 16)
        stopButton.sizeToFit()
        stopButton.frame = CGRect(x: column.x + column.width - stopButton.frame.width, y: 6, width: stopButton.frame.width, height: 18)
        if showsBody {
            let size = Self.bodySize(row, content, width: bounds.width, context: context)
            textView.frame = CGRect(x: column.x + Self.bodyIndent, y: 4 + Self.headerHeight + 4, width: column.width - Self.bodyIndent, height: size.height)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard showsBody else { return }
        TranscriptColors.thinkingBar.setFill()
        let frame = textView.frame
        NSBezierPath(roundedRect: CGRect(x: column.x + 4, y: frame.minY, width: 2, height: frame.height), xRadius: 1, yRadius: 1).fill()
    }
}

// MARK: - Prose

/// A run of markdown paragraphs, lists, headings and quotes in one selectable text view.
final class ProseCell: TranscriptCellView {
    private let textView = TranscriptTextView.makeReadOnly()
    private var hasDecorations = false

    override func setUp() {
        addSubview(textView)
    }

    private static func textHeight(_ row: TranscriptRow, _ content: MarkdownContent, width: CGFloat, context: TranscriptContext) -> CGFloat {
        let column = context.column(for: width)
        let string = context.proseString(row, content)
        return context.measure(string, width: column.width, key: "\(row.id)#\(row.signature)").height
    }

    static func height(for row: TranscriptRow, width: CGFloat, context: TranscriptContext) -> CGFloat {
        guard case .markdown(let content) = row.kind else { return 1 }
        return 2 + textHeight(row, content, width: width, context: context) + 4
    }

    override func configure(_ row: TranscriptRow, context: TranscriptContext) {
        super.configure(row, context: context)
        guard case .markdown(let content) = row.kind else { return }
        let string = context.proseString(row, content)
        textView.messageID = row.messageID
        textView.menuProvider = menuProvider()
        textView.setContent(string)
        var decorated = false
        let range = NSRange(location: 0, length: string.length)
        string.enumerateAttributes(in: range) { attributes, _, stop in
            if attributes[.transcriptQuoteDepth] != nil || attributes[.transcriptRule] != nil {
                decorated = true
                stop.pointee = true
            }
        }
        hasDecorations = decorated
    }

    override func layout() {
        super.layout()
        guard let row, let context, case .markdown(let content) = row.kind else { return }
        let column = self.column
        textView.frame = CGRect(x: column.x, y: 2, width: column.width, height: Self.textHeight(row, content, width: bounds.width, context: context))
        if hasDecorations { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hasDecorations else { return }
        let origin = textView.frame.origin
        for decoration in textView.decorations() {
            switch decoration {
            case .quoteBar(let rect):
                TranscriptColors.quoteBar.setFill()
                NSBezierPath(roundedRect: rect.offsetBy(dx: origin.x, dy: origin.y), xRadius: 1.5, yRadius: 1.5).fill()
            case .rule(let rect):
                TranscriptColors.separator.setFill()
                rect.offsetBy(dx: origin.x, dy: origin.y).fill()
            }
        }
    }
}

// MARK: - Code block

/// A fenced code block: language, copy/run/preview, highlighted code that scrolls sideways,
/// collapsed to 20 lines with "Show more" unless full-height code blocks are on.
final class CodeBlockCell: TranscriptCellView {
    private let box = RoundedBackgroundView()
    private let languageLabel = makeTranscriptLabel(font: .systemFont(ofSize: 11, weight: .medium))
    private let copyButton = ActionButton.icon("doc.on.doc", "Copy code")
    private let runButton = ActionButton.icon("terminal", "Run in terminal")
    private let previewButton = ActionButton.icon("eye", "Preview")
    private let scrollView = HorizontalScrollView()
    private let textView = TranscriptTextView.makeCode()
    private let toggleButton = ActionButton.link("Show more")
    private var isLive = false

    private static let codeInset: CGFloat = 12

    override func setUp() {
        box.fillColor = TranscriptColors.codeBackground
        box.strokeColor = TranscriptColors.codeBorder
        box.cornerRadius = 8
        textView.textContainerInset = NSSize(width: Self.codeInset, height: 0)
        scrollView.documentView = textView
        addSubview(box)
        for view in [languageLabel, copyButton, runButton, previewButton, scrollView, toggleButton] as [NSView] {
            addSubview(view)
        }
    }

    struct Info {
        var language: String?
        var code: String
        var isOpen: Bool
    }

    static func info(_ row: TranscriptRow) -> Info? {
        guard case .markdown(let content) = row.kind, let item = content.row.items.first,
            case .codeBlock(let language, let code, let isOpen) = item.block
        else { return nil }
        return Info(language: language, code: code, isOpen: isOpen && content.isStreaming)
    }

    struct Layout {
        var lines: Int
        var fullHeight: CGFloat
        var visibleHeight: CGFloat
        var contentWidth: CGFloat
        var collapsible: Bool
        var height: CGFloat
    }

    /// Line count and widest line (in columns, tabs as four) from one pass over the UTF-8 bytes.
    static func stats(_ code: String) -> (lines: Int, columns: Int) {
        var lines = 1
        var columns = 0
        var current = 0
        for byte in code.utf8 {
            switch byte {
            case 10:
                lines += 1
                columns = max(columns, current)
                current = 0
            case 9:
                current += 4
            case 0x80..<0xC0:
                break
            case 0xE0...:
                current += 2
            default:
                current += 1
            }
        }
        return (lines, max(columns, current))
    }

    static func layout(for row: TranscriptRow, width: CGFloat, context: TranscriptContext) -> Layout? {
        guard let info = Self.info(row) else { return nil }
        let column = context.column(for: width)
        let stats = Self.stats(info.code)
        let font = context.theme.codeFont
        let metrics = context.measurer.lineMetrics(for: font)
        let collapsedLines = TranscriptMetrics.codeCollapsedLines
        let collapsible = !context.settings.fullHeightCodeBlocks && stats.lines > collapsedLines + 2
        let expanded = context.expandedCode.contains(row.id)
        let visibleLines = collapsible && !expanded ? collapsedLines : stats.lines
        let fullHeight = metrics.first + CGFloat(stats.lines - 1) * metrics.line
        let visibleHeight = metrics.first + CGFloat(visibleLines - 1) * metrics.line
        let charWidth = ceil(("M" as NSString).size(withAttributes: [.font: font]).width * 100) / 100
        let contentWidth = CGFloat(stats.columns) * charWidth + codeInset * 2 + 8
        var height: CGFloat = 4 + TranscriptMetrics.codeHeaderHeight + 8 + visibleHeight + 10
        if collapsible { height += TranscriptMetrics.codeToggleHeight }
        height += 6
        return Layout(lines: stats.lines, fullHeight: fullHeight, visibleHeight: visibleHeight, contentWidth: max(contentWidth, column.width - 2), collapsible: collapsible, height: height)
    }

    static func height(for row: TranscriptRow, width: CGFloat, context: TranscriptContext) -> CGFloat {
        layout(for: row, width: width, context: context)?.height ?? 1
    }

    override func configure(_ row: TranscriptRow, context: TranscriptContext) {
        super.configure(row, context: context)
        guard let info = Self.info(row) else { return }
        isLive = info.isOpen
        textView.messageID = row.messageID
        textView.menuProvider = menuProvider()
        textView.setContent(context.codeString(rowID: row.id, code: info.code, language: info.language, isOpen: info.isOpen))
        languageLabel.stringValue = SyntaxHighlighter.displayName(info.language)
        runButton.isHidden = info.isOpen || !SyntaxHighlighter.isShell(info.language)
        previewButton.isHidden = info.isOpen || !SyntaxHighlighter.isPreviewable(info.language)
        let code = info.code
        let language = info.language
        copyButton.onClick = { [weak self] in
            TranscriptContext.copyToPasteboard(code)
            self?.flashCopied()
        }
        runButton.onClick = { [weak context] in context?.runInTerminal(code) }
        previewButton.onClick = { [weak context] in context?.preview(code: code, language: language) }
        let rowID = row.id
        toggleButton.onClick = { [weak context] in context?.toggleCode(rowID: rowID) }
    }

    private func flashCopied() {
        copyButton.setSymbol("checkmark", tooltip: "Copied")
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            self?.copyButton.setSymbol("doc.on.doc", tooltip: "Copy code")
        }
    }

    override func layout() {
        super.layout()
        guard let row, let context, let layout = Self.layout(for: row, width: bounds.width, context: context) else { return }
        let column = self.column
        let boxHeight = bounds.height - 4 - 6
        box.frame = CGRect(x: column.x, y: 4, width: column.width, height: boxHeight)
        let headerY = box.frame.minY
        languageLabel.frame = CGRect(x: column.x + 12, y: headerY + 6, width: 160, height: 16)
        let button = TranscriptMetrics.iconButtonSize
        var x = column.x + column.width - 6
        for view in [copyButton, runButton, previewButton] where !view.isHidden {
            x -= button
            view.frame = CGRect(x: x, y: headerY + 3, width: button, height: button)
            x -= 2
        }
        let codeY = headerY + TranscriptMetrics.codeHeaderHeight + 8
        scrollView.frame = CGRect(x: column.x + 1, y: codeY, width: column.width - 2, height: layout.visibleHeight + 4)
        let documentSize = NSSize(width: max(layout.contentWidth, scrollView.contentSize.width), height: max(layout.fullHeight, layout.visibleHeight + 4))
        if textView.frame.size != documentSize {
            textView.frame = NSRect(origin: .zero, size: documentSize)
        }
        let clip = scrollView.contentView
        let expanded = context.expandedCode.contains(row.id)
        if layout.collapsible, !expanded, isLive {
            // Collapsed while streaming: follow the newest lines.
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: max(0, documentSize.height - clip.bounds.height)))
        } else if clip.bounds.minY != 0, !layout.collapsible || expanded || !isLive {
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: 0))
        }
        scrollView.reflectScrolledClipView(clip)
        toggleButton.isHidden = !layout.collapsible
        if layout.collapsible {
            let hidden = layout.lines - TranscriptMetrics.codeCollapsedLines
            let title = expanded ? "Show less" : "Show \(hidden) more line\(hidden == 1 ? "" : "s")"
            toggleButton.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium),
                .foregroundColor: NSColor.linkColor,
            ])
            toggleButton.sizeToFit()
            toggleButton.frame = CGRect(x: column.x + 12, y: scrollView.frame.maxY + 6, width: toggleButton.frame.width, height: 18)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = self.box.frame
        guard box.width > 0 else { return }
        TranscriptColors.codeBorder.setFill()
        CGRect(x: box.minX + 1, y: box.minY + TranscriptMetrics.codeHeaderHeight, width: box.width - 2, height: 1).fill()
    }
}

// MARK: - Table

/// Column widths, row heights and rendered cells of a markdown table.
struct MarkdownTableLayout {
    var cells: [[NSAttributedString]]
    var columnWidths: [CGFloat]
    var rowHeights: [CGFloat]
    var totalWidth: CGFloat
    var totalHeight: CGFloat
    var plainText: String
    var markdown: String

    static let paddingX: CGFloat = 9
    static let paddingY: CGFloat = 5

    @MainActor
    init(table: MDTable, availableWidth: CGFloat, renderer: MarkdownRenderer, font: NSFont) {
        let columns = max(1, table.columnCount)
        let headerFont = FontVariants.font(font, bold: true, italic: false)
        func alignment(_ column: Int) -> NSTextAlignment {
            guard column < table.alignments.count else { return .natural }
            switch table.alignments[column] {
            case .center: return .center
            case .right: return .right
            default: return .natural
            }
        }
        func row(_ inlines: [[MDInline]], header: Bool) -> [NSAttributedString] {
            (0..<columns).map { column in
                renderer.renderInlines(column < inlines.count ? inlines[column] : [], font: header ? headerFont : font, color: TranscriptColors.text, alignment: alignment(column))
            }
        }
        let rendered = [row(table.header, header: true)] + table.rows.map { row($0, header: false) }

        let unbounded = CGSize(width: 10_000, height: 10_000)
        var natural = [CGFloat](repeating: 60, count: columns)
        for rowCells in rendered {
            for (column, cell) in rowCells.enumerated() {
                let width = ceil(cell.boundingRect(with: unbounded, options: [.usesLineFragmentOrigin, .usesFontLeading]).width) + Self.paddingX * 2 + 1
                natural[column] = min(360, max(natural[column], width))
            }
        }
        let available = max(120, availableWidth)
        var widths = natural
        if natural.reduce(0, +) > available {
            let minimums = natural.map { min($0, 90) }
            let minimumTotal = minimums.reduce(0, +)
            if minimumTotal >= available {
                widths = minimums
            } else {
                let flexible = zip(natural, minimums).map { $0 - $1 }
                let flexibleTotal = max(1, flexible.reduce(0, +))
                let extra = available - minimumTotal
                widths = zip(minimums, flexible).map { ($0 + $1 * extra / flexibleTotal).rounded(.down) }
            }
        }
        let heights = rendered.map { rowCells in
            var height: CGFloat = 0
            for (column, cell) in rowCells.enumerated() {
                let size = CGSize(width: max(10, widths[column] - Self.paddingX * 2), height: 100_000)
                height = max(height, ceil(cell.boundingRect(with: size, options: [.usesLineFragmentOrigin, .usesFontLeading]).height))
            }
            return max(height, ceil(font.ascender - font.descender)) + Self.paddingY * 2
        }
        cells = rendered
        columnWidths = widths
        rowHeights = heights
        totalWidth = widths.reduce(0, +)
        totalHeight = heights.reduce(0, +)
        plainText = table.plainText
        let headerLine = "| " + (0..<columns).map { column in column < table.header.count ? table.header[column].plainText : "" }.joined(separator: " | ") + " |"
        let separator = "|" + (0..<columns).map { column -> String in
            switch column < table.alignments.count ? table.alignments[column] : MDAlignment.none {
            case .left: return ":---"
            case .center: return ":---:"
            case .right: return "---:"
            case .none: return "---"
            }
        }.joined(separator: "|") + "|"
        let body = table.rows.map { cells in "| " + (0..<columns).map { column in column < cells.count ? cells[column].plainText : "" }.joined(separator: " | ") + " |" }
        markdown = ([headerLine, separator] + body).joined(separator: "\n")
    }
}

/// Draws a table grid. Text isn't selectable; Copy puts the table on the pasteboard.
final class TableGridView: NSView {
    var layout: MarkdownTableLayout? {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let layout else { return }
        if let first = layout.rowHeights.first {
            TranscriptColors.tableHeader.setFill()
            CGRect(x: 0, y: 0, width: layout.totalWidth, height: first).fill()
        }
        TranscriptColors.codeBorder.setFill()
        var y: CGFloat = 0
        for (index, height) in layout.rowHeights.enumerated() {
            if index > 0 { CGRect(x: 0, y: y, width: layout.totalWidth, height: 1).fill() }
            y += height
        }
        var x: CGFloat = 0
        for (index, width) in layout.columnWidths.enumerated() {
            if index > 0 { CGRect(x: x, y: 0, width: 1, height: layout.totalHeight).fill() }
            x += width
        }
        y = 0
        for (rowIndex, rowCells) in layout.cells.enumerated() {
            let height = layout.rowHeights[rowIndex]
            defer { y += height }
            guard y <= dirtyRect.maxY, y + height >= dirtyRect.minY else { continue }
            x = 0
            for (column, cell) in rowCells.enumerated() where column < layout.columnWidths.count {
                let width = layout.columnWidths[column]
                let rect = CGRect(
                    x: x + MarkdownTableLayout.paddingX,
                    y: y + MarkdownTableLayout.paddingY,
                    width: width - MarkdownTableLayout.paddingX * 2,
                    height: height - MarkdownTableLayout.paddingY * 2
                )
                cell.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                x += width
            }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let layout else { return nil }
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Copy Table") { TranscriptContext.copyToPasteboard(layout.plainText) })
        menu.addItem(ClosureMenuItem("Copy Table as Markdown") { TranscriptContext.copyToPasteboard(layout.markdown) })
        return menu
    }
}

/// A markdown table in a bordered box that scrolls sideways when it's wider than the column.
final class TableCell: TranscriptCellView {
    private let box = RoundedBackgroundView()
    private let scrollView = HorizontalScrollView()
    private let grid = TableGridView()
    private let copyButton = ActionButton.icon("doc.on.doc", "Copy table")

    override var tracksHover: Bool { true }

    override func setUp() {
        box.strokeColor = TranscriptColors.codeBorder
        box.cornerRadius = 6
        scrollView.documentView = grid
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 6
        scrollView.layer?.masksToBounds = true
        addSubview(scrollView)
        addSubview(box)
        addSubview(copyButton)
        copyButton.alphaValue = 0
    }

    private static func table(_ row: TranscriptRow) -> MDTable? {
        guard case .markdown(let content) = row.kind, let item = content.row.items.first, case .table(let table) = item.block else { return nil }
        return table
    }

    static func height(for row: TranscriptRow, width: CGFloat, context: TranscriptContext) -> CGFloat {
        guard let table = Self.table(row) else { return 1 }
        let column = context.column(for: width)
        let layout = context.tableLayout(for: row, table: table, width: column.width - 2)
        return 4 + layout.totalHeight + 2 + 12
    }

    override func configure(_ row: TranscriptRow, context: TranscriptContext) {
        super.configure(row, context: context)
        copyButton.onClick = { [weak self] in
            guard let layout = self?.grid.layout else { return }
            TranscriptContext.copyToPasteboard(layout.markdown)
        }
    }

    override func hoverChanged() {
        copyButton.alphaValue = isHovered ? 1 : 0
    }

    override func layout() {
        super.layout()
        guard let row, let context, let table = Self.table(row) else { return }
        let column = self.column
        let layout = context.tableLayout(for: row, table: table, width: column.width - 2)
        grid.layout = layout
        let width = min(column.width, layout.totalWidth + 2)
        box.frame = CGRect(x: column.x, y: 4, width: width, height: layout.totalHeight + 2)
        scrollView.frame = box.frame.insetBy(dx: 1, dy: 1)
        grid.frame = CGRect(x: 0, y: 0, width: layout.totalWidth, height: layout.totalHeight)
        let button = TranscriptMetrics.iconButtonSize
        copyButton.frame = CGRect(x: box.frame.maxX - button - 3, y: box.frame.minY + 2, width: button, height: button)
    }
}

// MARK: - Math block

/// A display formula rendered with SwiftMath, or its LaTeX source when that isn't possible.
final class MathBlockCell: TranscriptCellView {
    private let imageView = NSImageView()
    private let sourceView = TranscriptTextView.makeReadOnly()

    override func setUp() {
        imageView.imageScaling = .scaleProportionallyDown
        addSubview(imageView)
        addSubview(sourceView)
    }

    private static func latex(_ row: TranscriptRow) -> String? {
        guard case .markdown(let content) = row.kind, let item = content.row.items.first, case .mathBlock(let latex) = item.block else { return nil }
        return latex
    }

    private static func image(_ latex: String, context: TranscriptContext) -> NSImage? {
        context.renderer.math.image(latex: latex, display: true, fontSize: (context.theme.bodyFont.pointSize * 1.2).rounded(), isDark: context.theme.isDark)
    }

    private static func source(_ latex: String, context: TranscriptContext) -> NSAttributedString {
        NSAttributedString(string: latex, attributes: [
            .font: context.theme.inlineCodeFont(for: context.theme.bodyFont),
            .foregroundColor: TranscriptColors.secondaryText,
        ])
    }

    /// Size of the formula, scaled down to the column width.
    private static func contentSize(_ row: TranscriptRow, width: CGFloat, context: TranscriptContext) -> (size: CGSize, isImage: Bool) {
        guard let latex = Self.latex(row) else { return (.zero, false) }
        let column = context.column(for: width)
        if let image = Self.image(latex, context: context) {
            let scale = min(1, column.width / max(1, image.size.width))
            return (CGSize(width: image.size.width * scale, height: (image.size.height * scale).rounded(.up)), true)
        }
        let size = context.measure(Self.source(latex, context: context), width: column.width, key: "\(row.id)#\(row.signature)#math")
        return (CGSize(width: size.width, height: size.height), false)
    }

    static func height(for row: TranscriptRow, width: CGFloat, context: TranscriptContext) -> CGFloat {
        8 + contentSize(row, width: width, context: context).size.height + 12
    }

    override func configure(_ row: TranscriptRow, context: TranscriptContext) {
        super.configure(row, context: context)
        guard let latex = Self.latex(row) else { return }
        if let image = Self.image(latex, context: context) {
            imageView.image = image
            imageView.isHidden = false
            sourceView.isHidden = true
            imageView.toolTip = latex
        } else {
            sourceView.setContent(Self.source(latex, context: context))
            sourceView.messageID = row.messageID
            sourceView.menuProvider = menuProvider()
            imageView.isHidden = true
            sourceView.isHidden = false
        }
    }

    override func layout() {
        super.layout()
        guard let row, let context else { return }
        let column = self.column
        let content = Self.contentSize(row, width: bounds.width, context: context)
        if content.isImage {
            imageView.frame = CGRect(x: column.x + ((column.width - content.size.width) / 2).rounded(), y: 8, width: content.size.width, height: content.size.height)
        } else {
            sourceView.frame = CGRect(x: column.x, y: 8, width: column.width, height: content.size.height)
        }
    }
}
