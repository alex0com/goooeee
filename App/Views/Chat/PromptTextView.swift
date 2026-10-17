import AppKit
import GoooeeeCore
import SwiftUI
import UniformTypeIdentifiers

/// A `/prompt` or `@resource` being typed in the composer.
struct CompletionTrigger: Equatable {
    enum Kind: Equatable {
        case prompt
        case resource
    }

    var kind: Kind
    var query: String
    /// UTF-16 range of the trigger text (including `/` or `@`) in the composer.
    var range: NSRange
}

/// Keys the composer forwards to the completion list while it's open.
enum CompletionKey {
    case up, down, accept, dismiss
}

/// The composer's text view: grows with its content, sends on Return (or ⌘Return), takes
/// pasted and dropped files and images as attachments, and reports `/` and `@` triggers.
struct PromptTextView: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont
    var placeholder: String
    var sendKey: SendKey
    var isCompletionActive: Bool
    var focusToken: Int
    var onSend: () -> Void
    var onHeightChange: (CGFloat) -> Void
    var onTrigger: (CompletionTrigger?) -> Void
    var onCompletionKey: (CompletionKey) -> Void
    var onPasteboardAttachments: (NSPasteboard) -> Bool
    var onLongPaste: (String) -> Bool
    var onEmptyUpArrow: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = ComposerTextView(usingTextLayoutManager: true)
        textView.coordinator = context.coordinator
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.textContainer?.lineFragmentPadding = 2
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.font = font
        textView.typingAttributes = [.font: font, .foregroundColor: NSColor.textColor]
        textView.placeholder = placeholder
        textView.string = text
        textView.registerForDraggedTypes(ComposerTextView.attachmentTypes)
        scrollView.documentView = textView
        context.coordinator.textView = textView
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
            context.coordinator.reportHeight()
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            context.coordinator.reportHeight()
        }
        if textView.font != font {
            textView.font = font
            textView.typingAttributes = [.font: font, .foregroundColor: NSColor.textColor]
            context.coordinator.reportHeight()
        }
        if textView.placeholder != placeholder {
            textView.placeholder = placeholder
            textView.needsDisplay = true
        }
        if context.coordinator.focusToken != focusToken {
            context.coordinator.focusToken = focusToken
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptTextView
        weak var textView: ComposerTextView?
        var focusToken: Int
        private var lastHeight: CGFloat = 0
        private var lastTrigger: CompletionTrigger?

        init(_ parent: PromptTextView) {
            self.parent = parent
            self.focusToken = parent.focusToken
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            reportHeight()
            updateTrigger()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            updateTrigger()
        }

        func reportHeight() {
            guard let textView else { return }
            let height: CGFloat
            if let layoutManager = textView.textLayoutManager {
                layoutManager.ensureLayout(for: layoutManager.documentRange)
                height = layoutManager.usageBoundsForTextContainer.height
            } else {
                height = textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 0
            }
            let lineHeight = ceil((textView.font ?? parent.font).boundingRectForFont.height)
            let total = max(lineHeight, ceil(height)) + textView.textContainerInset.height * 2
            guard abs(total - lastHeight) > 0.5 else { return }
            lastHeight = total
            let callback = parent.onHeightChange
            DispatchQueue.main.async { callback(total) }
        }

        /// `/name` as the whole message, or `@word` just before the cursor.
        private func updateTrigger() {
            guard let textView else { return }
            let string = textView.string as NSString
            let cursor = textView.selectedRange().location
            var trigger: CompletionTrigger?
            if string.length > 0, string.character(at: 0) == UInt16(UnicodeScalar("/").value), cursor <= string.length {
                let typed = string.substring(with: NSRange(location: 1, length: max(0, cursor - 1)))
                if !typed.contains(where: { $0.isWhitespace }), cursor >= 1 {
                    trigger = CompletionTrigger(kind: .prompt, query: typed, range: NSRange(location: 0, length: cursor))
                }
            }
            if trigger == nil, cursor > 0, cursor <= string.length {
                var start = cursor
                while start > 0 {
                    let character = string.character(at: start - 1)
                    if let scalar = UnicodeScalar(character), CharacterSet.whitespacesAndNewlines.contains(scalar) { break }
                    start -= 1
                }
                if start < cursor, string.character(at: start) == UInt16(UnicodeScalar("@").value) {
                    let query = string.substring(with: NSRange(location: start + 1, length: cursor - start - 1))
                    trigger = CompletionTrigger(kind: .resource, query: query, range: NSRange(location: start, length: cursor - start))
                }
            }
            guard trigger != lastTrigger else { return }
            lastTrigger = trigger
            parent.onTrigger(trigger)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let flags = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
            if parent.isCompletionActive {
                switch selector {
                case #selector(NSResponder.moveUp(_:)):
                    parent.onCompletionKey(.up)
                    return true
                case #selector(NSResponder.moveDown(_:)):
                    parent.onCompletionKey(.down)
                    return true
                case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                    parent.onCompletionKey(.accept)
                    return true
                case #selector(NSResponder.cancelOperation(_:)):
                    parent.onCompletionKey(.dismiss)
                    return true
                default:
                    break
                }
            }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if flags.contains(.command) {
                    parent.onSend()
                    return true
                }
                if flags.contains(.shift) || flags.contains(.option) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                if parent.sendKey == .enter {
                    parent.onSend()
                    return true
                }
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            case #selector(NSResponder.insertLineBreak(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            case #selector(NSResponder.moveUp(_:)):
                if textView.string.isEmpty {
                    parent.onEmptyUpArrow()
                    return true
                }
                return false
            default:
                return false
            }
        }

        /// Replaces the trigger text (e.g. `/sum`) with `replacement`.
        func replace(_ range: NSRange, with replacement: String) {
            guard let textView, NSMaxRange(range) <= (textView.string as NSString).length else { return }
            if textView.shouldChangeText(in: range, replacementString: replacement) {
                textView.replaceCharacters(in: range, with: replacement)
                textView.didChangeText()
            }
        }
    }
}

/// The NSTextView behind the composer (placeholder, paste and drop handling).
final class ComposerTextView: NSTextView {
    weak var coordinator: PromptTextView.Coordinator?
    var placeholder = ""

    /// Files and images, taken as attachments.
    static let attachmentTypes: [NSPasteboard.PasteboardType] = [.fileURL] + AttachmentLoader.imageTypes

    /// Paste is enabled only for types listed here. A plain-text view lists no image types, so with
    /// just a screenshot on the clipboard ⌘V did nothing and `paste(_:)` never ran.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        let types = super.readablePasteboardTypes
        return types + Self.attachmentTypes.filter { !types.contains($0) }
    }

    private var showsPlaceholder = true

    override var string: String {
        didSet { placeholderVisibilityChanged() }
    }

    override func didChangeText() {
        super.didChangeText()
        placeholderVisibilityChanged()
    }

    /// Typing redraws only the new characters, so the placeholder would stay under the text.
    private func placeholderVisibilityChanged() {
        let shows = string.isEmpty
        guard shows != showsPlaceholder else { return }
        showsPlaceholder = shows
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        let padding = textContainer?.lineFragmentPadding ?? 0
        let origin = NSPoint(x: textContainerInset.width + padding, y: textContainerInset.height)
        (placeholder as NSString).draw(at: origin, withAttributes: attributes)
    }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if let coordinator, coordinator.parent.onPasteboardAttachments(pasteboard) { return }
        if let text = pasteboard.string(forType: .string), let coordinator, coordinator.parent.onLongPaste(text) { return }
        pasteAsPlainText(sender)
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if let coordinator, Self.attachmentTypes.contains(type), coordinator.parent.onPasteboardAttachments(pboard) {
            return true
        }
        return super.readSelection(from: pboard, type: type)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if hasAttachments(sender.draggingPasteboard) { return .copy }
        return super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        // Text with a picture of itself (cells from Numbers) is dropped as text.
        if hasAttachments(pasteboard), let coordinator, coordinator.parent.onPasteboardAttachments(pasteboard) {
            return true
        }
        return super.performDragOperation(sender)
    }

    private func hasAttachments(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || pasteboard.availableType(from: AttachmentLoader.imageTypes) != nil
    }
}
