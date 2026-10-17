import AppKit
#if canImport(SwiftMath)
import SwiftMath
#endif

/// Renders LaTeX to images with SwiftMath, cached by formula, size and appearance.
///
/// Without SwiftMath (or when a formula doesn't parse) callers fall back to showing the source.
@MainActor
final class MathRenderer {
    private var cache = LRUCache<String, NSImage>(capacity: 400)
    private var failures = Set<String>()

    static var isAvailable: Bool {
        #if canImport(SwiftMath)
        true
        #else
        false
        #endif
    }

    func image(latex: String, display: Bool, fontSize: CGFloat, isDark: Bool) -> NSImage? {
        let trimmed = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let key = "\(display ? "D" : "I")|\(fontSize)|\(isDark ? 1 : 0)|\(trimmed)"
        if let cached = cache.value(for: key) { return cached }
        if failures.contains(key) { return nil }
        let color = isDark ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.08, alpha: 1)
        guard let image = Self.render(latex: trimmed, display: display, fontSize: fontSize, color: color) else {
            failures.insert(key)
            return nil
        }
        cache.set(image, for: key)
        return image
    }

    /// An inline formula as a text attachment, centered on the text's cap height.
    func inlineAttachment(latex: String, font: NSFont, isDark: Bool) -> NSAttributedString? {
        guard let image = image(latex: latex, display: false, fontSize: font.pointSize, isDark: isDark) else { return nil }
        let attachment = NSTextAttachment()
        attachment.image = image
        let y = ((font.capHeight - image.size.height) / 2).rounded()
        attachment.bounds = CGRect(x: 0, y: y, width: image.size.width, height: image.size.height)
        return NSAttributedString(attachment: attachment)
    }

    func removeAll() {
        cache.removeAll()
        failures.removeAll()
    }

    private static func render(latex: String, display: Bool, fontSize: CGFloat, color: NSColor) -> NSImage? {
        #if canImport(SwiftMath)
        var math = MathImage(latex: latex, fontSize: fontSize, textColor: color, labelMode: display ? .display : .text, textAlignment: .left)
        // `asImage()` returns (error, image) or (error, image, layoutInfo) depending on the version.
        let result = math.asImage()
        guard result.0 == nil, let image = result.1, image.size.width > 0, image.size.height > 0 else { return nil }
        return image
        #else
        return nil
        #endif
    }
}
