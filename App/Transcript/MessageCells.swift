import AppKit
import GoooeeeCore
import GoooeeeTranscript

// MARK: - User message

/// The user's message: attachments and a right-aligned bubble, with actions on hover.
final class UserMessageCell: TranscriptCellView {
    private let attachments = AttachmentStripView()
    private let bubble = RoundedBackgroundView()
    private let textView = TranscriptTextView.makeReadOnly()
    private let editedLabel = makeTranscriptLabel(font: .systemFont(ofSize: 10.5))
    private let branch = BranchControl()
    private let editButton = ActionButton.icon("pencil", "Edit")
    private let copyButton = ActionButton.icon("doc.on.doc", "Copy")
    private let deleteButton = ActionButton.icon("trash", "Delete")

    private static let topPadding: CGFloat = 16
    private static var padX: CGFloat { TranscriptMetrics.bubblePaddingX }
    private static var padY: CGFloat { TranscriptMetrics.bubblePaddingY }

    override var tracksHover: Bool { true }

    override func setUp() {
        bubble.fillColor = TranscriptColors.userBubble
        bubble.cornerRadius = 14
        bubble.addSubview(textView)
        editedLabel.stringValue = "Edited"
        addSubview(attachments)
        addSubview(bubble)
        for view in [editedLabel, branch, editButton, copyButton, deleteButton] as [NSView] {
            addSubview(view)
        }
        hoverChanged()
    }

    struct Layout {
        var tilesHeight: CGFloat
        var bubble: CGSize
        var text: TextMeasurer.Size
        var height: CGFloat
    }

    static func layout(for row: TranscriptRow, content: UserContent, width: CGFloat, context: TranscriptContext) -> Layout {
        let column = context.column(for: width)
        let maxBubble = (column.width * 0.85).rounded(.down)
        let string = content.text.isEmpty ? NSAttributedString() : context.userString(row, content)
        let text = context.measure(string, width: maxBubble - padX * 2, key: "\(row.id)#\(row.signature)")
        let bubble = string.length == 0 ? CGSize.zero : CGSize(width: min(maxBubble, text.width + padX * 2 + 2), height: text.height + padY * 2)
        let tiles = content.attachments.isEmpty ? 0 : TranscriptMetrics.attachmentTile
        var height = topPadding + tiles
        if tiles > 0, bubble.height > 0 { height += 6 }
        height += bubble.height + 2 + TranscriptMetrics.actionBarHeight + 4
        return Layout(tilesHeight: tiles, bubble: bubble, text: text, height: height)
    }

    static func height(for row: TranscriptRow, width: CGFloat, context: TranscriptContext) -> CGFloat {
        guard case .user(let content) = row.kind else { return 1 }
        return layout(for: row, content: content, width: width, context: context).height
    }

    override func configure(_ row: TranscriptRow, context: TranscriptContext) {
        super.configure(row, context: context)
        guard case .user(let content) = row.kind else { return }
        let messageID = row.messageID
        textView.messageID = messageID
        textView.menuProvider = menuProvider()
        textView.setContent(content.text.isEmpty ? NSAttributedString() : context.userString(row, content))
        attachments.configure(content.attachments, messageID: messageID, context: context)
        attachments.onOpen = { [weak context] id in context?.openAttachment(messageID: messageID, attachmentID: id) }
        branch.configure(content.branch)
        branch.onSwitch = { [weak context] offset in context?.switchBranch(messageID, offset: offset) }
        editedLabel.isHidden = !content.isEdited
        let busy = context.controller?.isGenerating == true
        editButton.isEnabled = !busy
        deleteButton.isEnabled = !busy
        editButton.onClick = { [weak context] in context?.startEditing(messageID) }
        copyButton.onClick = { [weak context] in context?.copyMessage(messageID) }
        deleteButton.onClick = { [weak context] in context?.deleteMessage(messageID) }
    }

    override func hoverChanged() {
        for button in [editButton, copyButton, deleteButton] {
            button.alphaValue = isHovered ? 1 : 0
        }
    }

    override func layout() {
        super.layout()
        guard let row, let context, case .user(let content) = row.kind else { return }
        let layout = Self.layout(for: row, content: content, width: bounds.width, context: context)
        let column = self.column
        let right = column.x + column.width
        var y = Self.topPadding
        attachments.isHidden = layout.tilesHeight == 0
        if layout.tilesHeight > 0 {
            let width = min(AttachmentStripView.preferredWidth(count: content.attachments.count), column.width)
            attachments.frame = CGRect(x: right - width, y: y, width: width, height: layout.tilesHeight)
            y += layout.tilesHeight + (layout.bubble.height > 0 ? 6 : 0)
        }
        bubble.isHidden = layout.bubble.height == 0
        bubble.frame = CGRect(x: right - layout.bubble.width, y: y, width: layout.bubble.width, height: layout.bubble.height)
        textView.frame = CGRect(x: Self.padX, y: Self.padY, width: max(1, layout.bubble.width - Self.padX * 2), height: layout.text.height)
        y += layout.bubble.height + 2

        let button = TranscriptMetrics.iconButtonSize
        var x = right
        for view in [deleteButton, copyButton, editButton] {
            x -= button
            view.frame = CGRect(x: x, y: y, width: button, height: button)
        }
        if !branch.isHidden {
            let width = branch.preferredWidth
            x -= width + 4
            branch.frame = CGRect(x: x, y: y, width: width, height: button)
        }
        if !editedLabel.isHidden {
            let width = ceil(editedLabel.intrinsicContentSize.width)
            x -= width + 6
            editedLabel.frame = CGRect(x: x, y: y + 4, width: width, height: 14)
        }
    }
}

// MARK: - Editor

/// A message being edited in place, with Cancel, Save and (for your messages) Send.
final class EditorCell: TranscriptCellView, NSTextViewDelegate {
    private let box = RoundedBackgroundView()
    private let scrollView = NSScrollView()
    private let textView = EditorTextView.make(font: .systemFont(ofSize: 14))
    private let hint = makeTranscriptLabel(font: .systemFont(ofSize: 10.5), color: .tertiaryLabelColor)
    private let cancelButton = ActionButton.text("Cancel")
    private let saveButton = ActionButton.text("Save")
    private let sendButton = ActionButton.text("Send", prominent: true)
    private var wantsFocus = false

    private static let insetX: CGFloat = 12
    private static let insetY: CGFloat = 10
    private static let buttonRow: CGFloat = 26

    override func setUp() {
        box.fillColor = TranscriptColors.editorBackground
        box.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.6)
        box.cornerRadius = 10
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = textView
        textView.delegate = self
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        addSubview(box)
        addSubview(scrollView)
        addSubview(hint)
        addSubview(cancelButton)
        addSubview(saveButton)
        addSubview(sendButton)
    }

    static func textHeight(context: TranscriptContext, width: CGFloat) -> CGFloat {
        guard let editing = context.editing else { return 40 }
        let font = context.theme.inputFont
        let metrics = context.measurer.lineMetrics(for: font)
        let string = NSAttributedString(string: editing.text.isEmpty ? " " : editing.text, attributes: [.font: font])
        var height = context.measure(string, width: width, key: nil).height
        if editing.text.hasSuffix("\n") { height += metrics.line }
        let minimum = metrics.first + metrics.line * 2
        return min(max(height, minimum), 420)
    }

    static func height(for row: TranscriptRow, width: CGFloat, context: TranscriptContext) -> CGFloat {
        let column = context.column(for: width)
        let text = textHeight(context: context, width: column.width - insetX * 2)
        return 14 + insetY * 2 + text + 8 + buttonRow + TranscriptMetrics.messageGap
    }

    override func configure(_ row: TranscriptRow, context: TranscriptContext) {
        super.configure(row, context: context)
        guard let editing = context.editing else { return }
        let font = context.theme.inputFont
        if textView.font != font {
            textView.font = font
            textView.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor]
        }
        if textView.string != editing.text {
            textView.string = editing.text
        }
        let busy = context.controller?.isGenerating == true
        sendButton.isHidden = !editing.isUser
        sendButton.isEnabled = !busy
        hint.stringValue = editing.isUser ? "⌘↩ to send · Esc to cancel" : "⌘↩ to save · Esc to cancel"
        cancelButton.onClick = { [weak context] in context?.cancelEditing() }
        saveButton.onClick = { [weak context] in context?.commitEditing(send: false) }
        sendButton.onClick = { [weak context] in context?.commitEditing(send: true) }
        textView.onSubmit = { [weak context] in context?.commitEditing(send: editing.isUser) }
        textView.onCancel = { [weak context] in context?.cancelEditing() }
        if context.focusEditor {
            context.focusEditor = false
            wantsFocus = true
            focusIfPossible()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusIfPossible()
    }

    private func focusIfPossible() {
        guard wantsFocus, let window else { return }
        wantsFocus = false
        window.makeFirstResponder(textView)
        let end = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: end, length: 0))
    }

    func textDidChange(_ notification: Notification) {
        context?.updateEditingText(textView.string)
    }

    override func layout() {
        super.layout()
        guard let context else { return }
        let column = self.column
        let text = Self.textHeight(context: context, width: column.width - Self.insetX * 2)
        box.frame = CGRect(x: column.x, y: 14, width: column.width, height: text + Self.insetY * 2)
        scrollView.frame = box.frame.insetBy(dx: Self.insetX, dy: Self.insetY)
        let contentWidth = scrollView.contentSize.width
        if abs(textView.frame.width - contentWidth) > 0.5 {
            textView.frame = CGRect(x: 0, y: 0, width: contentWidth, height: max(textView.frame.height, text))
        }
        let y = box.frame.maxY + 8
        var x = column.x + column.width
        for button in [sendButton, saveButton, cancelButton] where !button.isHidden {
            button.sizeToFit()
            let width = max(70, button.frame.width)
            x -= width
            button.frame = CGRect(x: x, y: y, width: width, height: Self.buttonRow)
            x -= 8
        }
        hint.frame = CGRect(x: column.x + 2, y: y + 6, width: max(0, x - column.x - 8), height: 16)
    }
}

// MARK: - Assistant header

/// Model name above an assistant message, with a spinner while it streams.
final class AssistantHeaderCell: TranscriptCellView {
    private let icon = NSImageView()
    private let nameLabel = makeTranscriptLabel(font: .systemFont(ofSize: 12, weight: .semibold))
    private let spinner = NSProgressIndicator()

    static func height(for row: TranscriptRow, width: CGFloat, context: TranscriptContext) -> CGFloat {
        34
    }

    override func setUp() {
        icon.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        icon.contentTintColor = .controlAccentColor
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        addSubview(icon)
        addSubview(nameLabel)
        addSubview(spinner)
    }

    override func configure(_ row: TranscriptRow, context: TranscriptContext) {
        super.configure(row, context: context)
        guard case .assistantHeader(let header) = row.kind else { return }
        nameLabel.stringValue = header.modelName ?? "Assistant"
        if header.isStreaming {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
    }

    override func layout() {
        super.layout()
        let column = self.column
        icon.frame = CGRect(x: column.x, y: 14, width: 16, height: 16)
        let width = min(ceil(nameLabel.intrinsicContentSize.width), column.width - 60)
        nameLabel.frame = CGRect(x: column.x + 22, y: 14, width: max(0, width), height: 16)
        spinner.frame = CGRect(x: nameLabel.frame.maxX + 8, y: 14, width: 16, height: 16)
    }
}

// MARK: - Prompt progress

/// Prompt processing before the first token: progress bar, tokens and speed.
final class PromptProgressCell: TranscriptCellView {
    private let label = makeTranscriptLabel(font: .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular))
    private let bar = NSProgressIndicator()

    static func height(for row: TranscriptRow, width: CGFloat, context: TranscriptContext) -> CGFloat {
        50
    }

    override func setUp() {
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.controlSize = .small
        addSubview(label)
        addSubview(bar)
    }

    override func configure(_ row: TranscriptRow, context: TranscriptContext) {
        super.configure(row, context: context)
        guard case .promptProgress(let progress) = row.kind else { return }
        var text = "Processing prompt… \(MetricsFormatter.tokens(progress.processed)) / \(MetricsFormatter.tokens(progress.total)) tokens"
        if progress.cached > 0 { text += " (\(MetricsFormatter.compactTokens(progress.cached)) cached)" }
        if let speed = progress.speed { text += " · \(MetricsFormatter.speed(speed)) tok/s" }
        label.stringValue = text
        bar.doubleValue = progress.fraction
    }

    override func layout() {
        super.layout()
        let column = self.column
        label.frame = CGRect(x: column.x, y: 6, width: column.width, height: 16)
        bar.frame = CGRect(x: column.x, y: 28, width: min(column.width, 420), height: 12)
    }
}

// MARK: - Notice

/// "Stopped", errors (with Retry) and info lines.
final class NoticeCell: TranscriptCellView {
    private let box = RoundedBackgroundView()
    private let icon = NSImageView()
    private let textView = TranscriptTextView.makeReadOnly()
    private let retryButton = ActionButton.text("Retry")

    private static let iconWidth: CGFloat = 22
    private static let retryWidth: CGFloat = 76

    override func setUp() {
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        addSubview(box)
        addSubview(icon)
        addSubview(textView)
        addSubview(retryButton)
    }

    private static func string(_ content: NoticeContent, context: TranscriptContext) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: max(11, context.theme.bodyFont.pointSize - 1))
        let color: NSColor = content.style == .error ? TranscriptColors.text : TranscriptColors.secondaryText
        let result = NSMutableAttributedString(string: content.text, attributes: [.font: font, .foregroundColor: color])
        if let suggestion = content.suggestion, !suggestion.isEmpty {
            result.append(NSAttributedString(string: "\n" + suggestion, attributes: [.font: font, .foregroundColor: TranscriptColors.secondaryText]))
        }
        return result
    }

    private static func textWidth(_ content: NoticeContent, column: CGFloat) -> CGFloat {
        let padding: CGFloat = content.style == .error ? 24 : 0
        return max(40, column - padding - iconWidth - (content.style == .error ? retryWidth : 0))
    }

    static func height(for row: TranscriptRow, width: CGFloat, context: TranscriptContext) -> CGFloat {
        guard case .notice(let content) = row.kind else { return 1 }
        let column = context.column(for: width)
        let text = context.measure(Self.string(content, context: context), width: Self.textWidth(content, column: column.width), key: "\(row.id)#\(row.signature)")
        let inner = content.style == .error ? max(30, text.height + 18) : max(20, text.height + 4)
        return 6 + inner + 6
    }

    override func configure(_ row: TranscriptRow, context: TranscriptContext) {
        super.configure(row, context: context)
        guard case .notice(let content) = row.kind else { return }
        textView.messageID = row.messageID
        textView.menuProvider = menuProvider()
        textView.setContent(Self.string(content, context: context))
        let symbol: String
        switch content.style {
        case .error:
            symbol = "exclamationmark.triangle.fill"
            icon.contentTintColor = .systemRed
            box.fillColor = TranscriptColors.errorBackground
        case .stopped:
            symbol = "stop.circle"
            icon.contentTintColor = .secondaryLabelColor
            box.fillColor = nil
        case .info:
            symbol = "info.circle"
            icon.contentTintColor = .secondaryLabelColor
            box.fillColor = nil
        }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        box.isHidden = content.style != .error
        retryButton.isHidden = content.style != .error
        retryButton.isEnabled = context.controller?.isGenerating != true
        retryButton.onClick = { [weak context] in context?.retry() }
    }

    override func layout() {
        super.layout()
        guard let row, let context, case .notice(let content) = row.kind else { return }
        let column = self.column
        let isError = content.style == .error
        let width = Self.textWidth(content, column: column.width)
        let text = context.measure(Self.string(content, context: context), width: width, key: "\(row.id)#\(row.signature)")
        let inner = isError ? max(30, text.height + 18) : max(20, text.height + 4)
        box.frame = CGRect(x: column.x, y: 6, width: column.width, height: inner)
        let padding: CGFloat = isError ? 12 : 0
        icon.frame = CGRect(x: column.x + padding, y: 6 + (isError ? 9 : 2), width: 16, height: 16)
        textView.frame = CGRect(x: column.x + padding + Self.iconWidth, y: 6 + (isError ? 9 : 2), width: width, height: text.height)
        retryButton.frame = CGRect(x: column.x + column.width - Self.retryWidth + 4, y: 6 + (inner - 24) / 2, width: Self.retryWidth - 16, height: 24)
    }
}

// MARK: - Footer

/// Below an assistant message: actions, branch switcher, metrics and (optionally) the raw output.
final class FooterCell: TranscriptCellView {
    private let rawBox = RoundedBackgroundView()
    private let rawText = TranscriptTextView.makeReadOnly()
    private let metricsText = TranscriptTextView.makeReadOnly()
    private let branch = BranchControl()
    private let copyButton = ActionButton.icon("doc.on.doc", "Copy")
    private let regenerateButton = ActionButton.icon("arrow.clockwise", "Regenerate")
    private let continueButton = ActionButton.icon("text.append", "Continue")
    private let editButton = ActionButton.icon("pencil", "Edit")
    private let deleteButton = ActionButton.icon("trash", "Delete")
    private let rawButton = ActionButton.icon("chevron.left.forwardslash.chevron.right", "Show raw output")

    private static let actionRow: CGFloat = 24

    override func setUp() {
        rawBox.fillColor = TranscriptColors.codeBackground
        rawBox.strokeColor = TranscriptColors.codeBorder
        rawBox.addSubview(rawText)
        addSubview(rawBox)
        addSubview(metricsText)
        for view in [copyButton, regenerateButton, continueButton, editButton, deleteButton, rawButton, branch] as [NSView] {
            addSubview(view)
        }
    }

    struct Layout {
        var raw: CGSize?
        var metrics: CGSize?
        var showsActions: Bool
        var height: CGFloat
    }

    private static func metricsString(_ footer: FooterContent, context: TranscriptContext) -> NSAttributedString? {
        guard let metrics = footer.metrics else { return nil }
        let text = metricsSummary(metrics, streaming: footer.isStreaming)
        guard !text.isEmpty else { return nil }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: text, attributes: [
            .font: context.theme.metricsFont,
            .foregroundColor: TranscriptColors.tertiaryText,
            .paragraphStyle: paragraph,
        ])
    }

    /// "Prompt 1,234 tok · 850 tok/s   Generated 512 tok · 45.2 tok/s   …"
    static func metricsSummary(_ metrics: GenerationMetrics, streaming: Bool) -> String {
        var parts: [String] = []
        if let prompt = metrics.promptTokens, prompt > 0 {
            var part = "Prompt \(MetricsFormatter.tokens(prompt)) tok"
            if let cached = metrics.cachedTokens, cached > 0 { part += " (\(MetricsFormatter.compactTokens(cached)) cached)" }
            if let speed = metrics.promptSpeed { part += " · \(speed.isEstimate ? "≈" : "")\(MetricsFormatter.speed(speed.value)) tok/s" }
            parts.append(part)
        }
        let generated = metrics.generatedTokens
        if generated > 0 {
            var part = "Generated \(MetricsFormatter.tokens(generated)) tok"
            if let reasoning = metrics.reasoningTokens, reasoning > 0 { part += " (\(MetricsFormatter.compactTokens(reasoning)) thinking)" }
            if let speed = metrics.generationSpeed { part += " · \(MetricsFormatter.speed(speed.value)) tok/s" }
            parts.append(part)
        }
        if !streaming, let average = metrics.averageSpeed {
            parts.append("Avg \(MetricsFormatter.speed(average)) tok/s")
        }
        if let ttft = metrics.ttftMs {
            parts.append("TTFT \(MetricsFormatter.duration(ms: ttft))")
        }
        if !streaming, let total = metrics.totalMs {
            parts.append("Total \(MetricsFormatter.duration(ms: total))")
        }
        if let agentic = metrics.agentic, agentic.turns > 1 || agentic.toolCalls > 0 {
            var part = "\(agentic.turns) turn\(agentic.turns == 1 ? "" : "s") · \(agentic.toolCalls) tool call\(agentic.toolCalls == 1 ? "" : "s")"
            if agentic.toolMs > 0 { part += " · tools \(MetricsFormatter.duration(ms: agentic.toolMs))" }
            parts.append(part)
        }
        return parts.joined(separator: "   ")
    }

    private static func rawString(_ row: TranscriptRow, context: TranscriptContext) -> NSAttributedString? {
        guard context.controller?.rawOutputMessages.contains(row.messageID) == true, let message = context.message(row.messageID) else { return nil }
        return context.monospaced(message.copyText(includeReasoning: true), key: "\(row.id)#raw#\(row.signature)", limit: 200_000)
    }

    static func layout(for row: TranscriptRow, footer: FooterContent, width: CGFloat, context: TranscriptContext) -> Layout {
        let column = context.column(for: width)
        var height: CGFloat = 2
        var raw: CGSize?
        if let string = Self.rawString(row, context: context) {
            let size = context.measure(string, width: column.width - 24, key: "\(row.id)#raw#\(row.signature)")
            raw = CGSize(width: size.width, height: size.height)
            height += size.height + 20 + 6
        }
        let showsActions = !footer.isStreaming
        if showsActions { height += actionRow }
        var metrics: CGSize?
        if let string = Self.metricsString(footer, context: context) {
            let size = context.measure(string, width: column.width, key: footer.isStreaming ? nil : "\(row.id)#metrics#\(row.signature)")
            metrics = CGSize(width: size.width, height: size.height)
            height += 2 + size.height
        }
        height += TranscriptMetrics.messageGap
        return Layout(raw: raw, metrics: metrics, showsActions: showsActions, height: height)
    }

    static func height(for row: TranscriptRow, width: CGFloat, context: TranscriptContext) -> CGFloat {
        guard case .footer(let footer) = row.kind else { return 1 }
        return layout(for: row, footer: footer, width: width, context: context).height
    }

    override func configure(_ row: TranscriptRow, context: TranscriptContext) {
        super.configure(row, context: context)
        guard case .footer(let footer) = row.kind else { return }
        let messageID = row.messageID
        let busy = context.controller?.isGenerating == true
        let failedEmpty: Bool = {
            if case .failed = footer.state, context.message(messageID)?.text.isEmpty == true { return true }
            return false
        }()

        if let raw = Self.rawString(row, context: context) {
            rawText.setContent(raw)
            rawText.messageID = messageID
            rawBox.isHidden = false
        } else {
            rawBox.isHidden = true
        }
        if let metrics = Self.metricsString(footer, context: context) {
            metricsText.setContent(metrics)
            metricsText.isHidden = false
        } else {
            metricsText.isHidden = true
        }
        metricsText.messageID = messageID
        metricsText.menuProvider = menuProvider()

        branch.configure(footer.branch)
        branch.onSwitch = { [weak context] offset in context?.switchBranch(messageID, offset: offset) }

        for view in [copyButton, regenerateButton, deleteButton] {
            view.isHidden = footer.isStreaming
        }
        if footer.isStreaming { branch.isHidden = true }
        continueButton.isHidden = footer.isStreaming || !footer.canContinue
        rawButton.isHidden = footer.isStreaming || !context.settings.showRawOutputToggle
        copyButton.isHidden = footer.isStreaming || failedEmpty
        editButton.isHidden = footer.isStreaming || failedEmpty
        for button in [regenerateButton, continueButton, editButton, deleteButton] {
            button.isEnabled = !busy
        }
        let showingRaw = context.controller?.rawOutputMessages.contains(messageID) == true
        rawButton.contentTintColor = showingRaw ? .controlAccentColor : .secondaryLabelColor
        rawButton.setSymbol("chevron.left.forwardslash.chevron.right", tooltip: showingRaw ? "Show formatted output" : "Show raw output")

        copyButton.onClick = { [weak context] in context?.copyMessage(messageID) }
        regenerateButton.onClick = { [weak context] in context?.regenerate(messageID) }
        continueButton.onClick = { [weak context] in context?.continueMessage(messageID) }
        editButton.onClick = { [weak context] in context?.startEditing(messageID) }
        deleteButton.onClick = { [weak context] in context?.deleteMessage(messageID) }
        rawButton.onClick = { [weak context] in context?.toggleRawOutput(messageID) }
    }

    override func layout() {
        super.layout()
        guard let row, let context, case .footer(let footer) = row.kind else { return }
        let layout = Self.layout(for: row, footer: footer, width: bounds.width, context: context)
        let column = self.column
        var y: CGFloat = 2
        if let raw = layout.raw {
            rawBox.frame = CGRect(x: column.x, y: y, width: column.width, height: raw.height + 20)
            rawText.frame = CGRect(x: 12, y: 10, width: column.width - 24, height: raw.height)
            y += raw.height + 20 + 6
        }
        if layout.showsActions {
            let button = TranscriptMetrics.iconButtonSize
            var x = column.x - 4
            for view in [copyButton, regenerateButton, continueButton, editButton, deleteButton, rawButton] where !view.isHidden {
                view.frame = CGRect(x: x, y: y + 1, width: button, height: button)
                x += button + 2
            }
            if !branch.isHidden {
                let width = branch.preferredWidth
                branch.frame = CGRect(x: x + 6, y: y + 1, width: width, height: button)
            }
            y += Self.actionRow
        }
        if let metrics = layout.metrics {
            metricsText.frame = CGRect(x: column.x, y: y + 2, width: column.width, height: metrics.height)
        }
    }
}
