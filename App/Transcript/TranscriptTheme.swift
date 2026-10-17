import AppKit
import GoooeeeCore
import GoooeeeMarkdown

/// Fonts and metrics for the transcript, built from the app settings.
///
/// Colors live in `TranscriptColors` and are dynamic, so cached attributed strings stay
/// correct when the appearance changes. Only rendered math depends on `isDark`.
@MainActor
struct TranscriptTheme {
    var bodyFont: NSFont
    var userFont: NSFont
    var thinkingFont: NSFont
    var codeFont: NSFont
    var metricsFont: NSFont
    var inputFont: NSFont
    var lineHeightMultiple: CGFloat
    var maxContentWidth: CGFloat
    var isDark: Bool
    /// Changes whenever fonts, settings or the appearance change.
    var generation: Int

    init(store: SettingsStore, isDark: Bool, generation: Int) {
        let settings = store.settings
        bodyFont = store.nsFont(for: .assistantMessage)
        userFont = store.nsFont(for: .userMessage)
        thinkingFont = store.nsFont(for: .thinking)
        codeFont = store.nsFont(for: .code)
        metricsFont = store.nsFont(for: .metrics)
        inputFont = store.nsFont(for: .input)
        lineHeightMultiple = CGFloat(max(1, min(2.5, settings.lineSpacing)))
        maxContentWidth = CGFloat(max(360, settings.maxMessageWidth))
        self.isDark = isDark
        self.generation = generation
    }

    var paragraphSpacing: CGFloat { (bodyFont.pointSize * 0.6).rounded() }

    /// Inline code: the code font family at the size of the surrounding text.
    func inlineCodeFont(for base: NSFont) -> NSFont {
        FontVariants.resized(codeFont, to: (base.pointSize * 0.92).rounded(toPlaces: 1))
    }

    func headingFont(level: Int, base: NSFont) -> NSFont {
        let scale: CGFloat
        switch level {
        case 1: scale = 1.55
        case 2: scale = 1.32
        case 3: scale = 1.15
        default: scale = 1.0
        }
        return FontVariants.font(FontVariants.resized(base, to: (base.pointSize * scale).rounded()), bold: true, italic: false)
    }

    var codeStyle: CodeHighlighter.Style {
        CodeHighlighter.Style(
            font: codeFont,
            textColor: TranscriptColors.text,
            colors: TranscriptColors.tokenColors,
            generation: generation
        )
    }
}

/// Dynamic colors used by the transcript.
@MainActor
enum TranscriptColors {
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: alpha
        )
    }

    static let text = NSColor.labelColor
    static let secondaryText = NSColor.secondaryLabelColor
    static let tertiaryText = NSColor.tertiaryLabelColor
    static let link = NSColor.linkColor
    static let accent = NSColor.controlAccentColor
    static let separator = NSColor.separatorColor
    static let userBubble = dynamic(light: NSColor(white: 0, alpha: 0.055), dark: NSColor(white: 1, alpha: 0.085))
    static let codeBackground = dynamic(light: hex(0xF6F7F9), dark: hex(0x1B1D22))
    static let codeHeader = dynamic(light: hex(0xECEEF2), dark: hex(0x24272E))
    static let codeBorder = dynamic(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.08))
    static let inlineCodeBackground = dynamic(light: NSColor(white: 0, alpha: 0.06), dark: NSColor(white: 1, alpha: 0.1))
    static let cardBackground = dynamic(light: NSColor(white: 0, alpha: 0.03), dark: NSColor(white: 1, alpha: 0.045))
    static let tableHeader = dynamic(light: NSColor(white: 0, alpha: 0.045), dark: NSColor(white: 1, alpha: 0.07))
    static let quoteBar = dynamic(light: NSColor(white: 0, alpha: 0.18), dark: NSColor(white: 1, alpha: 0.22))
    static let thinkingBar = dynamic(light: NSColor(white: 0, alpha: 0.12), dark: NSColor(white: 1, alpha: 0.14))
    static let errorBackground = dynamic(light: NSColor.systemRed.withAlphaComponent(0.08), dark: NSColor.systemRed.withAlphaComponent(0.16))
    static let warningBackground = dynamic(light: NSColor.systemOrange.withAlphaComponent(0.1), dark: NSColor.systemOrange.withAlphaComponent(0.16))
    static let editorBackground = NSColor.textBackgroundColor

    static func token(_ kind: SyntaxTokenKind) -> NSColor {
        tokenColors[kind] ?? text
    }

    static let tokenColors: [SyntaxTokenKind: NSColor] = Dictionary(uniqueKeysWithValues: SyntaxTokenKind.allCases.map { ($0, makeToken($0)) })

    /// Xcode-like colors in light mode, Atom One Dark-like colors in dark mode.
    private static func makeToken(_ kind: SyntaxTokenKind) -> NSColor {
        switch kind {
        case .keyword: dynamic(light: hex(0xAD3DA4), dark: hex(0xC678DD))
        case .string: dynamic(light: hex(0xC41A16), dark: hex(0x98C379))
        case .comment: dynamic(light: hex(0x707F8C), dark: hex(0x7F848E))
        case .number: dynamic(light: hex(0x1C00CF), dark: hex(0xD19A66))
        case .type: dynamic(light: hex(0x0B4F79), dark: hex(0xE5C07B))
        case .function: dynamic(light: hex(0x326D74), dark: hex(0x61AFEF))
        case .attribute: dynamic(light: hex(0x643820), dark: hex(0xD19A66))
        case .variable: dynamic(light: hex(0x0F68A0), dark: hex(0xE06C75))
        case .property: dynamic(light: hex(0x326D74), dark: hex(0xE06C75))
        case .tag: dynamic(light: hex(0xAD3DA4), dark: hex(0xE06C75))
        case .literal: dynamic(light: hex(0xAD3DA4), dark: hex(0x56B6C2))
        case .meta: dynamic(light: hex(0x643820), dark: hex(0xC678DD))
        case .inserted: dynamic(light: hex(0x1A7F37), dark: hex(0x98C379))
        case .deleted: dynamic(light: hex(0xCF222E), dark: hex(0xE06C75))
        }
    }
}

/// Bold/italic/resized variants of fonts, cached.
@MainActor
enum FontVariants {
    private static var cache: [String: NSFont] = [:]

    static func font(_ base: NSFont, bold: Bool, italic: Bool) -> NSFont {
        guard bold || italic else { return base }
        let key = "\(base.fontName)|\(base.pointSize)|\(bold)|\(italic)"
        if let cached = cache[key] { return cached }
        var traits = base.fontDescriptor.symbolicTraits
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
        let font = NSFont(descriptor: descriptor, size: base.pointSize) ?? base
        cache[key] = font
        return font
    }

    static func resized(_ base: NSFont, to size: CGFloat) -> NSFont {
        guard abs(base.pointSize - size) > 0.01 else { return base }
        let key = "\(base.fontName)|\(base.pointSize)|size\(size)"
        if let cached = cache[key] { return cached }
        let font = NSFont(descriptor: base.fontDescriptor, size: size) ?? base
        cache[key] = font
        return font
    }

    static func clear() {
        cache.removeAll()
    }
}

private extension CGFloat {
    func rounded(toPlaces places: Int) -> CGFloat {
        let factor = CGFloat(pow(10, Double(places)))
        return (self * factor).rounded() / factor
    }
}
