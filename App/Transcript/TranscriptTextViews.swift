import AppKit

extension NSAttributedString.Key {
    /// Block quote nesting depth of a paragraph (draws bars at the left).
    static let transcriptQuoteDepth = NSAttributedString.Key("goooeee.quoteDepth")
    /// A thematic break paragraph (draws a horizontal rule).
    static let transcriptRule = NSAttributedString.Key("goooeee.rule")
}

/// Read-only, selectable TextKit 2 text view used by transcript rows.
///
/// Never touch `layoutManager` on these views: that would switch them to TextKit 1.
final class TranscriptTextView: NSTextView {
    /// Message whose text this view shows (for the context menu).
    var messageID: UUID?
    var menuProvider: ((UUID?) -> [NSMenuItem])?

    static func makeReadOnly() -> TranscriptTextView {
        let view = TranscriptTextView(usingTextLayoutManager: true)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.autoresizingMask = []
        view.allowsUndo = false
        view.isAutomaticLinkDetectionEnabled = false
        view.usesFindBar = false
        view.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .cursor: NSCursor.pointingHand,
        ]
        view.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor]
        return view
    }

    /// A non-wrapping variant for code blocks (sized by its cell).
    static func makeCode() -> TranscriptTextView {
        let view = makeReadOnly()
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.size = NSSize(width: 1_000_000, height: 10_000_000)
        return view
    }

    /// Replaces only the part after the unchanged prefix, so a streaming row keeps the layout of its
    /// earlier lines (and the selection in them).
    func setContent(_ string: NSAttributedString) {
        guard let storage = textStorage else { return }
        let prefix = Self.commonPrefixLength(storage, string)
        guard prefix < storage.length || prefix < string.length else { return }
        storage.beginEditing()
        storage.replaceCharacters(
            in: NSRange(location: prefix, length: storage.length - prefix),
            with: string.attributedSubstring(from: NSRange(location: prefix, length: string.length - prefix))
        )
        storage.endEditing()
        needsFullLayout = true
        ensureFullLayoutIfNeeded()
    }

    /// Length of the leading part that has the same characters and attributes in both strings.
    static func commonPrefixLength(_ a: NSAttributedString, _ b: NSAttributedString) -> Int {
        guard a.length > 0, b.length > 0 else { return 0 }
        var length = (a.string as NSString).commonPrefix(with: b.string, options: .literal).utf16.count
        var location = 0
        while location < length {
            let limit = NSRange(location: 0, length: length)
            var rangeA = NSRange()
            var rangeB = NSRange()
            let attributesA = a.attributes(at: location, longestEffectiveRange: &rangeA, in: limit)
            let attributesB = b.attributes(at: location, longestEffectiveRange: &rangeB, in: limit)
            if !NSDictionary(dictionary: attributesA).isEqual(to: attributesB) {
                length = location
                break
            }
            location = min(NSMaxRange(rangeA), NSMaxRange(rangeB))
        }
        return length
    }

    // MARK: Layout

    /// TextKit 2 lays out only the visible part and estimates the position of everything above it.
    /// In a tall row (long thinking or answer, scrolled to its end) the estimate is off by
    /// hundreds or thousands of points, so the visible lines jump on every update or are drawn
    /// outside the view. Laying out the whole text gives exact positions; after an append only
    /// the new tail is actually laid out.
    private var needsFullLayout = false

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged { needsFullLayout = true }
        ensureFullLayoutIfNeeded()
    }

    private func ensureFullLayoutIfNeeded() {
        // Before the cell sizes the view the width is 0; layout at that width would be thrown away.
        guard needsFullLayout, frame.width > 1, let layoutManager = textLayoutManager else { return }
        needsFullLayout = false
        layoutManager.ensureLayout(for: layoutManager.documentRange)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        if let items = menuProvider?(messageID), !items.isEmpty {
            menu.insertItem(.separator(), at: 0)
            for item in items.reversed() {
                menu.insertItem(item, at: 0)
            }
        }
        return menu
    }

    // MARK: Decorations

    enum Decoration {
        case quoteBar(CGRect)
        case rule(CGRect)
    }

    /// Rectangles for quote bars and horizontal rules, in this view's coordinates.
    func decorations() -> [Decoration] {
        guard let storage = textStorage, storage.length > 0,
            let layoutManager = textLayoutManager,
            let contentManager = layoutManager.textContentManager
        else { return [] }
        var result: [Decoration] = []
        let whole = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.transcriptQuoteDepth, in: whole) { value, range, _ in
            guard let depth = value as? Int, depth > 0, let frame = Self.frame(of: range, layoutManager: layoutManager, contentManager: contentManager) else { return }
            for level in 0..<depth {
                let x = CGFloat(level) * TranscriptMetrics.quoteIndent + 2
                result.append(.quoteBar(CGRect(x: x, y: frame.minY, width: 3, height: frame.height)))
            }
        }
        storage.enumerateAttribute(.transcriptRule, in: whole) { value, range, _ in
            guard value != nil, let frame = Self.frame(of: range, layoutManager: layoutManager, contentManager: contentManager) else { return }
            result.append(.rule(CGRect(x: 0, y: frame.midY.rounded(), width: bounds.width, height: 1)))
        }
        return result
    }

    private static func frame(of range: NSRange, layoutManager: NSTextLayoutManager, contentManager: NSTextContentManager) -> CGRect? {
        guard let start = contentManager.location(contentManager.documentRange.location, offsetBy: range.location),
            let end = contentManager.location(start, offsetBy: range.length),
            let textRange = NSTextRange(location: start, end: end)
        else { return nil }
        var union: CGRect?
        layoutManager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
            union = union.map { $0.union(frame) } ?? frame
            return true
        }
        return union
    }
}

/// The editable text view used when editing a message in place.
final class EditorTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?

    static func make(font: NSFont) -> EditorTextView {
        let view = EditorTextView(usingTextLayoutManager: true)
        view.isEditable = true
        view.isSelectable = true
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.font = font
        view.textColor = .labelColor
        view.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor]
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        return view
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, event.modifierFlags.contains(.command), event.keyCode == 36 || event.keyCode == 76 {
            onSubmit?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
