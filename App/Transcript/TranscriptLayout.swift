import AppKit

/// Spacing used by the transcript cells.
enum TranscriptMetrics {
    static let sidePadding: CGFloat = 24
    static let bubblePaddingX: CGFloat = 12
    static let bubblePaddingY: CGFloat = 8
    static let actionBarHeight: CGFloat = 22
    static let iconButtonSize: CGFloat = 22
    static let attachmentTile: CGFloat = 64
    static let codeHeaderHeight: CGFloat = 28
    static let codeCollapsedLines = 20
    static let codeToggleHeight: CGFloat = 26
    static let quoteIndent: CGFloat = 14
    static let messageGap: CGFloat = 18
}

/// Measures attributed strings with TextKit 2, the same engine the transcript's text views use.
@MainActor
final class TextMeasurer {
    struct Size: Hashable {
        var width: CGFloat
        var height: CGFloat
        static let zero = Size(width: 0, height: 0)
    }

    private let contentStorage = NSTextContentStorage()
    private let layoutManager = NSTextLayoutManager()
    private let container = NSTextContainer(size: CGSize(width: 100, height: 10_000_000))
    private var cache = LRUCache<String, Size>(capacity: 4000)
    private var lineMetrics: [String: (first: CGFloat, line: CGFloat)] = [:]

    init() {
        container.lineFragmentPadding = 0
        layoutManager.textContainer = container
        contentStorage.addTextLayoutManager(layoutManager)
        contentStorage.primaryTextLayoutManager = layoutManager
    }

    /// Size of `string` wrapped at `width`. `key` (with the width) caches the result.
    func measure(_ string: NSAttributedString, width: CGFloat, key: String? = nil) -> Size {
        guard string.length > 0 else { return .zero }
        let width = max(1, width.rounded(.down))
        let cacheKey = key.map { "\($0)|\(Int(width))" }
        if let cacheKey, let cached = cache.value(for: cacheKey) { return cached }
        container.size = CGSize(width: width, height: 10_000_000)
        contentStorage.textStorage?.setAttributedString(string)
        var maxY: CGFloat = 0
        var maxX: CGFloat = 0
        layoutManager.enumerateTextLayoutFragments(from: layoutManager.documentRange.location, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            maxY = max(maxY, frame.maxY)
            for line in fragment.textLineFragments {
                maxX = max(maxX, frame.minX + line.typographicBounds.maxX)
            }
            return true
        }
        let size = Size(width: ceil(min(maxX, width)), height: ceil(maxY))
        if let cacheKey { cache.set(size, for: cacheKey) }
        return size
    }

    /// Height of the first line and of each following line for unwrapped text in `font`.
    func lineMetrics(for font: NSFont) -> (first: CGFloat, line: CGFloat) {
        let key = "\(font.fontName)|\(font.pointSize)"
        if let cached = lineMetrics[key] { return cached }
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let one = measure(NSAttributedString(string: "Xg", attributes: attributes), width: 10_000).height
        let two = measure(NSAttributedString(string: "Xg\nXg", attributes: attributes), width: 10_000).height
        let metrics = (first: one, line: max(1, two - one))
        lineMetrics[key] = metrics
        return metrics
    }

    func removeAll() {
        cache.removeAll()
        lineMetrics.removeAll()
    }

    func remove(keysWithPrefix prefix: String) {
        cache.removeAll { $0.hasPrefix(prefix) }
    }
}

/// A small least-recently-used cache. Evicts the oldest quarter when full.
struct LRUCache<Key: Hashable, Value> {
    private var storage: [Key: (value: Value, tick: UInt64)] = [:]
    private var tick: UInt64 = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(4, capacity)
    }

    var count: Int { storage.count }

    mutating func value(for key: Key) -> Value? {
        guard let entry = storage[key] else { return nil }
        tick += 1
        storage[key] = (entry.value, tick)
        return entry.value
    }

    mutating func set(_ value: Value, for key: Key) {
        tick += 1
        storage[key] = (value, tick)
        if storage.count > capacity { evict() }
    }

    mutating func removeValue(for key: Key) {
        storage[key] = nil
    }

    mutating func removeAll() {
        storage.removeAll()
    }

    mutating func removeAll(where shouldRemove: (Key) -> Bool) {
        for key in storage.keys where shouldRemove(key) {
            storage[key] = nil
        }
    }

    private mutating func evict() {
        let target = capacity * 3 / 4
        let oldest = storage.sorted { $0.value.tick < $1.value.tick }.prefix(storage.count - target)
        for (key, _) in oldest {
            storage[key] = nil
        }
    }
}

// MARK: - Controls

/// A button that runs a closure.
final class ActionButton: NSButton {
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(clicked)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func clicked() {
        onClick?()
    }

    /// A borderless SF Symbol button.
    static func icon(_ symbol: String, _ tooltip: String, pointSize: CGFloat = 12) -> ActionButton {
        let button = ActionButton(frame: NSRect(x: 0, y: 0, width: TranscriptMetrics.iconButtonSize, height: TranscriptMetrics.iconButtonSize))
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
        return button
    }

    /// A small push button with a title.
    static func text(_ title: String, prominent: Bool = false) -> ActionButton {
        let button = ActionButton(frame: .zero)
        button.title = title
        button.bezelStyle = .push
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        if prominent {
            button.keyEquivalent = ""
            button.bezelColor = .controlAccentColor
            button.contentTintColor = .white
        }
        button.sizeToFit()
        return button
    }

    /// A borderless text link style button ("Show more", "Retry").
    static func link(_ title: String) -> ActionButton {
        let button = ActionButton(frame: .zero)
        button.isBordered = false
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium),
            .foregroundColor: NSColor.linkColor,
        ])
        button.sizeToFit()
        return button
    }

    func setSymbol(_ symbol: String, tooltip: String) {
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        toolTip = tooltip
        setAccessibilityLabel(tooltip)
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func run() {
        handler()
    }
}

/// A scroll view that only scrolls horizontally and hands vertical scrolling to the transcript.
final class HorizontalScrollView: NSScrollView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hasHorizontalScroller = true
        hasVerticalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        drawsBackground = false
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .none
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY), (documentView?.frame.width ?? 0) > contentView.bounds.width + 1 {
            super.scrollWheel(with: event)
        } else {
            nextResponder?.scrollWheel(with: event)
        }
    }
}

/// A view that draws a filled, optionally stroked rounded rectangle with dynamic colors.
final class RoundedBackgroundView: NSView {
    var fillColor: NSColor? { didSet { needsDisplay = true } }
    var strokeColor: NSColor? { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 8 { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius)
        if let fillColor {
            fillColor.setFill()
            path.fill()
        }
        if let strokeColor {
            strokeColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}

/// A label that doesn't take part in text selection or hit testing.
@MainActor
func makeTranscriptLabel(font: NSFont, color: NSColor = .secondaryLabelColor) -> NSTextField {
    let label = NSTextField(labelWithString: "")
    label.font = font
    label.textColor = color
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.isSelectable = false
    return label
}
