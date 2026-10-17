import AppKit
import GoooeeeCore
import GoooeeeTranscript

/// A tool call card: status, name, source and duration; arguments and result when expanded;
/// an inline Allow/Deny prompt while the call waits for permission.
final class ToolCallCell: TranscriptCellView {
    private let card = RoundedBackgroundView()
    private let header = ClickableView()
    private let statusIcon = NSImageView()
    private let spinner = NSProgressIndicator()
    private let nameLabel = makeTranscriptLabel(font: .systemFont(ofSize: 12.5, weight: .semibold), color: .labelColor)
    private let sourceLabel = makeTranscriptLabel(font: .systemFont(ofSize: 11))
    private let durationLabel = makeTranscriptLabel(font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular))
    private let chevron = NSImageView()
    private let progressBar = NSProgressIndicator()
    private let progressLabel = makeTranscriptLabel(font: .systemFont(ofSize: 11))
    private let argumentsCaption = makeTranscriptLabel(font: .systemFont(ofSize: 10.5, weight: .semibold))
    private let argumentsBox = RoundedBackgroundView()
    private let argumentsText = TranscriptTextView.makeReadOnly()
    private let resultCaption = makeTranscriptLabel(font: .systemFont(ofSize: 10.5, weight: .semibold))
    private let resultBox = RoundedBackgroundView()
    private let resultText = TranscriptTextView.makeReadOnly()
    private var imageViews: [NSImageView] = []
    private let permissionLabel = makeTranscriptLabel(font: .systemFont(ofSize: 12), color: .labelColor)
    private let denyButton = ActionButton.text("Deny")
    private let allowServerButton = ActionButton.text("Always Allow Server")
    private let allowToolButton = ActionButton.text("Always Allow Tool")
    private let allowOnceButton = ActionButton.text("Allow Once", prominent: true)

    private static let headerHeight: CGFloat = 32
    private static let progressHeight: CGFloat = 20
    private static let captionHeight: CGFloat = 18
    private static let imageHeight: CGFloat = 96
    private static let cardPadding: CGFloat = 12
    private static let boxPadding: CGFloat = 8

    override func setUp() {
        card.fillColor = TranscriptColors.cardBackground
        card.strokeColor = TranscriptColors.codeBorder
        card.cornerRadius = 8
        for box in [argumentsBox, resultBox] {
            box.fillColor = TranscriptColors.codeBackground
            box.cornerRadius = 6
        }
        argumentsBox.addSubview(argumentsText)
        resultBox.addSubview(resultText)
        statusIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        chevron.contentTintColor = .secondaryLabelColor
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        progressBar.style = .bar
        progressBar.controlSize = .small
        progressBar.minValue = 0
        progressBar.maxValue = 1
        argumentsCaption.stringValue = "ARGUMENTS"
        nameLabel.lineBreakMode = .byTruncatingMiddle
        durationLabel.alignment = .right
        for view in [statusIcon, spinner, nameLabel, sourceLabel, durationLabel, chevron] as [NSView] {
            header.addSubview(view)
        }
        addSubview(card)
        for view in [header, progressBar, progressLabel, argumentsCaption, argumentsBox, resultCaption, resultBox, permissionLabel,
                     denyButton, allowServerButton, allowToolButton, allowOnceButton] as [NSView] {
            addSubview(view)
        }
    }

    // MARK: Content

    private static func content(_ row: TranscriptRow) -> ToolCallContent? {
        guard case .toolCall(let content) = row.kind else { return nil }
        return content
    }

    private static func argumentsString(_ row: TranscriptRow, _ call: ToolCall, context: TranscriptContext) -> NSAttributedString {
        let text = call.prettyArguments.trimmingCharacters(in: .whitespacesAndNewlines)
        return context.monospaced(text.isEmpty ? "{}" : text, key: "\(row.id)#args#\(row.signature)")
    }

    private static func resultString(_ row: TranscriptRow, _ content: ToolCallContent, context: TranscriptContext) -> NSAttributedString? {
        let isError = content.result?.isError == true || content.call.status == .failed
        var parts: [String] = []
        if let result = content.result {
            for item in result.content {
                switch item {
                case .text(let text): parts.append(text)
                case .image: break
                case .resourceLink(let uri, let name, _): parts.append("[\(name)](\(uri))")
                case .resource(let uri, let text, _): parts.append(text ?? uri)
                }
            }
        }
        if parts.isEmpty, let error = content.call.errorMessage, !error.isEmpty {
            parts.append(error)
        }
        if parts.isEmpty, let result = content.result, result.images.isEmpty {
            parts.append(result.isError ? "Tool failed without output." : "(no output)")
        }
        guard !parts.isEmpty else { return nil }
        return context.monospaced(parts.joined(separator: "\n"), key: "\(row.id)#result#\(row.signature)", color: isError ? .systemRed : TranscriptColors.text)
    }

    private static func images(_ content: ToolCallContent) -> [Data] {
        Array((content.result?.images ?? []).prefix(4).map { $0.data })
    }

    private struct PermissionLayout {
        var rows: [[CGFloat]]
        var height: CGFloat
    }

    private static func buttonWidth(_ title: String) -> CGFloat {
        ceil((title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]).width) + 28
    }

    private static func permissionTitles(_ call: ToolCall, context: TranscriptContext) -> [String] {
        let server = context.workspace?.pendingPermissions[call.id]?.tool.sourceName ?? "Server"
        return ["Deny", "Always Allow \(server)", "Always Allow Tool", "Allow Once"]
    }

    /// Buttons go on one row when they fit, otherwise two.
    private static func permissionLayout(_ call: ToolCall, width: CGFloat, context: TranscriptContext) -> PermissionLayout {
        let widths = permissionTitles(call, context: context).map(buttonWidth)
        let total = widths.reduce(0, +) + CGFloat(widths.count - 1) * 8
        let rows = total <= width ? [widths] : [Array(widths.prefix(2)), Array(widths.suffix(2))]
        return PermissionLayout(rows: rows, height: 10 + 18 + 8 + CGFloat(rows.count) * 30)
    }

    // MARK: Layout

    private struct Layout {
        var innerWidth: CGFloat
        var showsProgress: Bool
        var expanded: Bool
        var arguments: CGFloat
        var result: CGFloat?
        var images: Bool
        var permission: PermissionLayout?
        var cardHeight: CGFloat
        var height: CGFloat
    }

    private static func layout(for row: TranscriptRow, width: CGFloat, context: TranscriptContext) -> Layout? {
        guard let content = Self.content(row) else { return nil }
        let call = content.call
        let column = context.column(for: width)
        let inner = column.width - cardPadding * 2
        let textWidth = inner - boxPadding * 2
        var height = headerHeight
        let showsProgress = call.status == .running && (call.progress != nil || call.progressMessage?.isEmpty == false)
        if showsProgress { height += progressHeight }
        let expanded = context.isToolExpanded(call)
        var arguments: CGFloat = 0
        var result: CGFloat?
        var images = false
        if expanded {
            arguments = context.measure(Self.argumentsString(row, call, context: context), width: textWidth, key: "\(row.id)#args#\(row.signature)").height
            height += captionHeight + arguments + boxPadding * 2 + 8
            if let string = Self.resultString(row, content, context: context) {
                let measured = context.measure(string, width: textWidth, key: "\(row.id)#result#\(row.signature)").height
                result = measured
                height += captionHeight + measured + boxPadding * 2 + 8
            }
            if !Self.images(content).isEmpty {
                images = true
                height += imageHeight + 8
            }
        }
        var permission: PermissionLayout?
        if context.hasPendingPermission(call) {
            let layout = Self.permissionLayout(call, width: inner, context: context)
            permission = layout
            height += layout.height
        }
        if expanded || permission != nil { height += 4 }
        return Layout(innerWidth: inner, showsProgress: showsProgress, expanded: expanded, arguments: arguments, result: result,
                      images: images, permission: permission, cardHeight: height, height: 4 + height + 8)
    }

    static func height(for row: TranscriptRow, width: CGFloat, context: TranscriptContext) -> CGFloat {
        layout(for: row, width: width, context: context)?.height ?? 1
    }

    // MARK: Configure

    override func configure(_ row: TranscriptRow, context: TranscriptContext) {
        super.configure(row, context: context)
        guard let content = Self.content(row) else { return }
        let call = content.call
        nameLabel.stringValue = call.name
        sourceLabel.stringValue = call.sourceLabel ?? ""
        var detail: [String] = []
        switch call.status {
        case .denied: detail.append("Denied")
        case .cancelled: detail.append("Cancelled")
        case .awaitingPermission: detail.append("Waiting for permission")
        default: break
        }
        if let duration = call.durationMs { detail.append(MetricsFormatter.duration(ms: duration)) }
        durationLabel.stringValue = detail.joined(separator: " · ")

        if call.status == .running {
            statusIcon.isHidden = true
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
            statusIcon.isHidden = false
            let (symbol, color) = Self.statusSymbol(call.status)
            statusIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: call.status.rawValue)
            statusIcon.contentTintColor = color
        }

        let expanded = context.isToolExpanded(call)
        chevron.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        let rowID = row.id
        header.onClick = { [weak context] in context?.toggleTool(call, rowID: rowID) }
        header.setAccessibilityLabel("Tool call \(call.name)")

        progressBar.isIndeterminate = call.progress == nil
        progressBar.doubleValue = call.progress ?? 0
        if call.progress == nil { progressBar.startAnimation(nil) } else { progressBar.stopAnimation(nil) }
        progressLabel.stringValue = call.progressMessage ?? ""

        argumentsText.messageID = row.messageID
        resultText.messageID = row.messageID
        argumentsText.menuProvider = menuProvider()
        resultText.menuProvider = menuProvider()
        if expanded {
            argumentsText.setContent(Self.argumentsString(row, call, context: context))
            if let result = Self.resultString(row, content, context: context) {
                resultText.setContent(result)
            }
            resultCaption.stringValue = content.result?.isError == true || call.status == .failed ? "ERROR" : "RESULT"
        }
        configureImages(expanded ? Self.images(content) : [])

        let titles = Self.permissionTitles(call, context: context)
        allowServerButton.title = titles[1]
        let callID = call.id
        denyButton.onClick = { [weak context] in context?.resolvePermission(callID: callID, decision: .deny) }
        allowServerButton.onClick = { [weak context] in context?.resolvePermission(callID: callID, decision: .alwaysServer) }
        allowToolButton.onClick = { [weak context] in context?.resolvePermission(callID: callID, decision: .alwaysTool) }
        allowOnceButton.onClick = { [weak context] in context?.resolvePermission(callID: callID, decision: .allowOnce) }
        let source = call.sourceLabel.map { " (\($0))" } ?? ""
        permissionLabel.stringValue = "Allow “\(call.name)”\(source) to run?"
    }

    private func configureImages(_ data: [Data]) {
        while imageViews.count < data.count {
            let view = NSImageView()
            view.imageScaling = .scaleProportionallyUpOrDown
            view.wantsLayer = true
            view.layer?.cornerRadius = 6
            view.layer?.masksToBounds = true
            imageViews.append(view)
            addSubview(view)
        }
        for (index, view) in imageViews.enumerated() {
            if index < data.count {
                view.image = NSImage(data: data[index])
                view.isHidden = false
            } else {
                view.image = nil
                view.isHidden = true
            }
        }
    }

    static func statusSymbol(_ status: ToolCallStatus) -> (String, NSColor) {
        switch status {
        case .pending: ("clock", .secondaryLabelColor)
        case .awaitingPermission: ("hand.raised.fill", .systemOrange)
        case .running: ("circle.dotted", .secondaryLabelColor)
        case .completed: ("checkmark.circle.fill", .systemGreen)
        case .failed: ("xmark.octagon.fill", .systemRed)
        case .denied: ("nosign", .secondaryLabelColor)
        case .cancelled: ("stop.circle", .secondaryLabelColor)
        }
    }

    override func layout() {
        super.layout()
        guard let row, let context, let layout = Self.layout(for: row, width: bounds.width, context: context) else { return }
        let column = self.column
        let left = column.x + Self.cardPadding
        card.frame = CGRect(x: column.x, y: 4, width: column.width, height: layout.cardHeight)

        header.frame = CGRect(x: column.x, y: 4, width: column.width, height: Self.headerHeight)
        statusIcon.frame = CGRect(x: 12, y: 8, width: 16, height: 16)
        spinner.frame = statusIcon.frame
        chevron.frame = CGRect(x: column.width - 24, y: 10, width: 12, height: 12)
        let durationWidth = min(220, ceil(durationLabel.intrinsicContentSize.width))
        durationLabel.frame = CGRect(x: chevron.frame.minX - 8 - durationWidth, y: 8, width: durationWidth, height: 16)
        let nameWidth = min(ceil(nameLabel.intrinsicContentSize.width), max(40, durationLabel.frame.minX - 40 - 80))
        nameLabel.frame = CGRect(x: 36, y: 8, width: nameWidth, height: 16)
        let sourceX = nameLabel.frame.maxX + 8
        sourceLabel.frame = CGRect(x: sourceX, y: 8, width: max(0, durationLabel.frame.minX - 8 - sourceX), height: 16)

        var y = 4 + Self.headerHeight
        progressBar.isHidden = !layout.showsProgress
        progressLabel.isHidden = !layout.showsProgress
        if layout.showsProgress {
            progressBar.frame = CGRect(x: left, y: y + 3, width: min(200, layout.innerWidth / 2), height: 12)
            progressLabel.frame = CGRect(x: progressBar.frame.maxX + 8, y: y + 1, width: max(0, layout.innerWidth - progressBar.frame.width - 8), height: 16)
            y += Self.progressHeight
        }

        for view in [argumentsCaption, argumentsBox, resultCaption, resultBox] as [NSView] {
            view.isHidden = !layout.expanded
        }
        if layout.expanded {
            argumentsCaption.frame = CGRect(x: left, y: y, width: layout.innerWidth, height: Self.captionHeight)
            y += Self.captionHeight
            argumentsBox.frame = CGRect(x: left, y: y, width: layout.innerWidth, height: layout.arguments + Self.boxPadding * 2)
            argumentsText.frame = CGRect(x: Self.boxPadding, y: Self.boxPadding, width: layout.innerWidth - Self.boxPadding * 2, height: layout.arguments)
            y += argumentsBox.frame.height + 8
            if let result = layout.result {
                resultCaption.frame = CGRect(x: left, y: y, width: layout.innerWidth, height: Self.captionHeight)
                y += Self.captionHeight
                resultBox.frame = CGRect(x: left, y: y, width: layout.innerWidth, height: result + Self.boxPadding * 2)
                resultText.frame = CGRect(x: Self.boxPadding, y: Self.boxPadding, width: layout.innerWidth - Self.boxPadding * 2, height: result)
                y += resultBox.frame.height + 8
            } else {
                resultCaption.isHidden = true
                resultBox.isHidden = true
            }
            if layout.images {
                var x = left
                for view in imageViews where !view.isHidden {
                    let size = view.image?.size ?? CGSize(width: 1, height: 1)
                    let width = min(Self.imageHeight * size.width / max(1, size.height), layout.innerWidth - (x - left))
                    view.frame = CGRect(x: x, y: y, width: max(0, width), height: Self.imageHeight)
                    x += width + 8
                }
                y += Self.imageHeight + 8
            }
        }

        let permissionViews: [NSView] = [permissionLabel, denyButton, allowServerButton, allowToolButton, allowOnceButton]
        for view in permissionViews {
            view.isHidden = layout.permission == nil
        }
        if let permission = layout.permission {
            y += 10
            permissionLabel.frame = CGRect(x: left, y: y, width: layout.innerWidth, height: 18)
            y += 18 + 8
            let buttons = [denyButton, allowServerButton, allowToolButton, allowOnceButton]
            var index = 0
            for widths in permission.rows {
                var x = left + layout.innerWidth
                let rowButtons = Array(buttons[index..<(index + widths.count)])
                for (button, width) in zip(rowButtons, widths).reversed() {
                    x -= width
                    button.frame = CGRect(x: x, y: y, width: width, height: 24)
                    x -= 8
                }
                index += widths.count
                y += 30
            }
        }
    }
}
