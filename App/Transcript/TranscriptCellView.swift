import AppKit
import GoooeeeCore
import GoooeeeTranscript

/// Base class for transcript cells.
///
/// Each subclass has a static `height(for:width:context:)` that the table uses for row heights,
/// and lays out its subviews with frames computed the same way (no Auto Layout).
class TranscriptCellView: NSView {
    weak var context: TranscriptContext?
    private(set) var row: TranscriptRow?
    private(set) var isHovered = false
    private var hoverArea: NSTrackingArea?

    /// Subclasses that show controls on hover set this.
    var tracksHover: Bool { false }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Creates subviews. Called once from `init(frame:)`.
    func setUp() {}

    func configure(_ row: TranscriptRow, context: TranscriptContext) {
        if isHovered, self.row?.id != row.id {
            // Reused for another row; the next mouse move updates hover again.
            isHovered = false
            hoverChanged()
        }
        self.row = row
        self.context = context
        needsLayout = true
        needsDisplay = true
    }

    /// The centered content column for this cell.
    var column: (x: CGFloat, width: CGFloat) {
        context?.column(for: bounds.width) ?? (0, bounds.width)
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard tracksHover else { return }
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        hoverChanged()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        hoverChanged()
    }

    func hoverChanged() {}

    /// Context menu items for the text views of this row's message.
    func menuProvider() -> (UUID?) -> [NSMenuItem] {
        { [weak self] messageID in self?.context?.menuItems(for: messageID) ?? [] }
    }
}

/// An empty cell for message content that is temporarily replaced (editing, raw output).
final class HiddenCell: TranscriptCellView {}

// MARK: - Small views

/// A view that calls `onClick` on mouse up and shows a pointing-hand cursor.
final class ClickableView: NSView {
    var onClick: (() -> Void)?

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// The ‹ 2/3 › control for switching between sibling messages.
final class BranchControl: NSView {
    private let previous = ActionButton.icon("chevron.left", "Previous version", pointSize: 10)
    private let next = ActionButton.icon("chevron.right", "Next version", pointSize: 10)
    private let label = makeTranscriptLabel(font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular))
    var onSwitch: ((Int) -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.alignment = .center
        previous.onClick = { [weak self] in self?.onSwitch?(-1) }
        next.onClick = { [weak self] in self?.onSwitch?(1) }
        addSubview(previous)
        addSubview(label)
        addSubview(next)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(_ info: BranchInfo) {
        isHidden = !info.hasSiblings
        label.stringValue = info.label
        previous.isEnabled = info.index > 0
        next.isEnabled = info.index < info.count - 1
        needsLayout = true
    }

    var preferredWidth: CGFloat {
        let labelWidth = ceil(label.attributedStringValue.size().width) + 4
        return TranscriptMetrics.iconButtonSize * 2 + max(28, labelWidth)
    }

    override func layout() {
        super.layout()
        let button = TranscriptMetrics.iconButtonSize
        previous.frame = CGRect(x: 0, y: (bounds.height - button) / 2, width: button, height: button)
        next.frame = CGRect(x: bounds.width - button, y: (bounds.height - button) / 2, width: button, height: button)
        let labelHeight = ceil(label.intrinsicContentSize.height)
        label.frame = CGRect(x: button, y: ((bounds.height - labelHeight) / 2).rounded(), width: bounds.width - button * 2, height: labelHeight)
    }
}

/// Thumbnails of a user message's attachments; clicking one opens it.
final class AttachmentStripView: NSView {
    private var tiles: [AttachmentTileView] = []
    var onOpen: ((UUID) -> Void)?

    override var isFlipped: Bool { true }

    func configure(_ attachments: [AttachmentSummary], messageID: UUID, context: TranscriptContext) {
        let message = context.message(messageID)
        while tiles.count < attachments.count {
            let tile = AttachmentTileView(frame: .zero)
            tiles.append(tile)
            addSubview(tile)
        }
        for (index, tile) in tiles.enumerated() {
            guard index < attachments.count else {
                tile.isHidden = true
                continue
            }
            let summary = attachments[index]
            let full = message?.attachments.first { $0.id == summary.id }
            tile.isHidden = false
            tile.configure(summary: summary, thumbnail: full.flatMap { context.thumbnail(for: $0) }, icon: full.map(AttachmentLoader.icon(for:)) ?? "doc")
            tile.onClick = { [weak self] in self?.onOpen?(summary.id) }
        }
        needsLayout = true
    }

    static func preferredWidth(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * TranscriptMetrics.attachmentTile + CGFloat(count - 1) * 6
    }

    override func layout() {
        super.layout()
        var x = bounds.width
        for tile in tiles.reversed() where !tile.isHidden {
            x -= TranscriptMetrics.attachmentTile
            tile.frame = CGRect(x: x, y: 0, width: TranscriptMetrics.attachmentTile, height: TranscriptMetrics.attachmentTile)
            x -= 6
        }
    }
}

/// One attachment: an image thumbnail, or an icon with the file name.
final class AttachmentTileView: NSView {
    private let imageLayer = CALayer()
    private let iconView = NSImageView()
    private let nameLabel = makeTranscriptLabel(font: .systemFont(ofSize: 10))
    var onClick: (() -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        layer?.addSublayer(imageLayer)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        iconView.contentTintColor = .secondaryLabelColor
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(iconView)
        addSubview(nameLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(summary: AttachmentSummary, thumbnail: NSImage?, icon: String) {
        toolTip = summary.name
        setAccessibilityLabel(summary.name)
        if let thumbnail {
            imageLayer.contents = thumbnail
            imageLayer.isHidden = false
            iconView.isHidden = true
            nameLabel.isHidden = true
        } else {
            imageLayer.contents = nil
            imageLayer.isHidden = true
            iconView.isHidden = false
            nameLabel.isHidden = false
            iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
            nameLabel.stringValue = summary.name
        }
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
        iconView.frame = CGRect(x: 0, y: 10, width: bounds.width, height: 26)
        nameLabel.frame = CGRect(x: 4, y: bounds.height - 22, width: bounds.width - 8, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        if imageLayer.isHidden {
            TranscriptColors.userBubble.setFill()
            bounds.fill()
        }
    }

    override func mouseUp(with event: NSEvent) {
        onClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
