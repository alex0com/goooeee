import Foundation

/// The text roles that have their own font in Settings → Appearance.
public enum TextRole: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    case input
    case userMessage
    case assistantMessage
    case thinking
    case code
    case metrics

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .input: "Message input"
        case .userMessage: "Your messages"
        case .assistantMessage: "LLM output"
        case .thinking: "Thinking"
        case .code: "Code"
        case .metrics: "Statistics"
        }
    }

    public var defaultFont: FontSpec {
        switch self {
        case .input: FontSpec(family: nil, size: 14)
        case .userMessage: FontSpec(family: nil, size: 14)
        case .assistantMessage: FontSpec(family: nil, size: 14)
        case .thinking: FontSpec(family: nil, size: 12.5)
        case .code: FontSpec(family: "SF Mono", size: 12.5)
        case .metrics: FontSpec(family: nil, size: 11)
        }
    }
}

/// A font choice. `family == nil` means the system font.
public struct FontSpec: Codable, Sendable, Hashable {
    public var family: String?
    public var size: Double

    public init(family: String?, size: Double) {
        self.family = family
        self.size = size
    }
}

public enum ColorSchemePreference: String, Codable, Sendable, CaseIterable, Hashable {
    case system
    case light
    case dark
}

public enum SendKey: String, Codable, Sendable, CaseIterable, Hashable {
    /// Enter sends, Shift+Enter inserts a newline.
    case enter
    /// Cmd+Enter sends, Enter inserts a newline.
    case commandEnter
}

public enum TitleMode: String, Codable, Sendable, CaseIterable, Hashable {
    case firstLine
    case llm
}

public enum ThinkingDisplay: String, Codable, Sendable, CaseIterable, Hashable {
    /// Expanded while generating, collapsed when done.
    case collapseWhenDone
    case alwaysExpanded
    case alwaysCollapsed
}

/// Application-wide preferences (Settings window). Stored as JSON in user defaults.
public struct AppSettings: Codable, Sendable, Hashable {
    // Appearance
    public var fonts: [TextRole: FontSpec]
    /// Multiplier applied to every chat font (⌘+ / ⌘−).
    public var textScale: Double
    public var lineSpacing: Double
    public var maxMessageWidth: Double
    public var colorScheme: ColorSchemePreference
    public var codeThemeLight: String
    public var codeThemeDark: String

    // Chat
    public var sendKey: SendKey
    public var thinkingDisplay: ThinkingDisplay
    public var renderThinkingAsMarkdown: Bool
    public var renderUserMessagesAsMarkdown: Bool
    public var showMessageStats: Bool
    public var showAgenticTurnStats: Bool
    public var alwaysExpandToolCalls: Bool
    public var fullHeightCodeBlocks: Bool
    public var disableAutoScroll: Bool
    public var titleMode: TitleMode
    public var titlePrompt: String
    public var pasteLongTextToFileLength: Int
    public var maxImageMegapixels: Double
    public var pdfAsImages: Bool
    public var enableContinue: Bool
    public var renderMath: Bool
    public var confirmDelete: Bool
    public var keepDeletedDays: Int

    // Tools & MCP
    public var maxAgenticTurns: Int
    public var mcpRequestTimeoutSeconds: Double
    public var mcpHandshakeTimeoutSeconds: Double
    public var toolLogRetentionDays: Int

    // Connections
    public var localDiscoveryEnabled: Bool

    // Terminal
    public var terminalShell: String?
    public var terminalFont: FontSpec
    public var terminalScrollback: Int

    // Advanced
    public var showRawOutputToggle: Bool
    public var disableReasoningParsing: Bool
    public var excludeReasoningFromContext: Bool

    public init() {
        fonts = Dictionary(uniqueKeysWithValues: TextRole.allCases.map { ($0, $0.defaultFont) })
        textScale = 1
        lineSpacing = 1.25
        maxMessageWidth = 820
        colorScheme = .system
        codeThemeLight = "xcode"
        codeThemeDark = "atom-one-dark"
        sendKey = .enter
        thinkingDisplay = .collapseWhenDone
        renderThinkingAsMarkdown = true
        renderUserMessagesAsMarkdown = true
        showMessageStats = true
        showAgenticTurnStats = false
        alwaysExpandToolCalls = false
        fullHeightCodeBlocks = false
        disableAutoScroll = false
        titleMode = .firstLine
        titlePrompt = ConversationTitle.defaultPrompt
        pasteLongTextToFileLength = 2500
        maxImageMegapixels = 4
        pdfAsImages = false
        enableContinue = true
        renderMath = true
        confirmDelete = false
        keepDeletedDays = 30
        maxAgenticTurns = 100
        mcpRequestTimeoutSeconds = 300
        mcpHandshakeTimeoutSeconds = 10
        toolLogRetentionDays = 30
        localDiscoveryEnabled = true
        terminalShell = nil
        terminalFont = FontSpec(family: "SF Mono", size: 12)
        terminalScrollback = 10_000
        showRawOutputToggle = false
        disableReasoningParsing = false
        excludeReasoningFromContext = true
    }

    public func font(for role: TextRole) -> FontSpec {
        let base = fonts[role] ?? role.defaultFont
        return FontSpec(family: base.family, size: (base.size * textScale).rounded(toPlaces: 1))
    }

    // Decoding tolerates missing keys so new settings don't reset existing ones.
    public init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ current: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? current
        }
        if let rawFonts = try? container.decodeIfPresent([String: FontSpec].self, forKey: .fonts) {
            for (name, spec) in rawFonts {
                if let role = TextRole(rawValue: name) { fonts[role] = spec }
            }
        }
        textScale = value(.textScale, textScale)
        lineSpacing = value(.lineSpacing, lineSpacing)
        maxMessageWidth = value(.maxMessageWidth, maxMessageWidth)
        colorScheme = value(.colorScheme, colorScheme)
        codeThemeLight = value(.codeThemeLight, codeThemeLight)
        codeThemeDark = value(.codeThemeDark, codeThemeDark)
        sendKey = value(.sendKey, sendKey)
        thinkingDisplay = value(.thinkingDisplay, thinkingDisplay)
        renderThinkingAsMarkdown = value(.renderThinkingAsMarkdown, renderThinkingAsMarkdown)
        renderUserMessagesAsMarkdown = value(.renderUserMessagesAsMarkdown, renderUserMessagesAsMarkdown)
        showMessageStats = value(.showMessageStats, showMessageStats)
        showAgenticTurnStats = value(.showAgenticTurnStats, showAgenticTurnStats)
        alwaysExpandToolCalls = value(.alwaysExpandToolCalls, alwaysExpandToolCalls)
        fullHeightCodeBlocks = value(.fullHeightCodeBlocks, fullHeightCodeBlocks)
        disableAutoScroll = value(.disableAutoScroll, disableAutoScroll)
        titleMode = value(.titleMode, titleMode)
        titlePrompt = value(.titlePrompt, titlePrompt)
        pasteLongTextToFileLength = value(.pasteLongTextToFileLength, pasteLongTextToFileLength)
        maxImageMegapixels = value(.maxImageMegapixels, maxImageMegapixels)
        pdfAsImages = value(.pdfAsImages, pdfAsImages)
        enableContinue = value(.enableContinue, enableContinue)
        renderMath = value(.renderMath, renderMath)
        confirmDelete = value(.confirmDelete, confirmDelete)
        keepDeletedDays = value(.keepDeletedDays, keepDeletedDays)
        maxAgenticTurns = value(.maxAgenticTurns, maxAgenticTurns)
        mcpRequestTimeoutSeconds = value(.mcpRequestTimeoutSeconds, mcpRequestTimeoutSeconds)
        mcpHandshakeTimeoutSeconds = value(.mcpHandshakeTimeoutSeconds, mcpHandshakeTimeoutSeconds)
        toolLogRetentionDays = value(.toolLogRetentionDays, toolLogRetentionDays)
        localDiscoveryEnabled = value(.localDiscoveryEnabled, localDiscoveryEnabled)
        terminalShell = value(.terminalShell, terminalShell)
        terminalFont = value(.terminalFont, terminalFont)
        terminalScrollback = value(.terminalScrollback, terminalScrollback)
        showRawOutputToggle = value(.showRawOutputToggle, showRawOutputToggle)
        disableReasoningParsing = value(.disableReasoningParsing, disableReasoningParsing)
        excludeReasoningFromContext = value(.excludeReasoningFromContext, excludeReasoningFromContext)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Dictionary(uniqueKeysWithValues: fonts.map { ($0.key.rawValue, $0.value) }), forKey: .fonts)
        try container.encode(textScale, forKey: .textScale)
        try container.encode(lineSpacing, forKey: .lineSpacing)
        try container.encode(maxMessageWidth, forKey: .maxMessageWidth)
        try container.encode(colorScheme, forKey: .colorScheme)
        try container.encode(codeThemeLight, forKey: .codeThemeLight)
        try container.encode(codeThemeDark, forKey: .codeThemeDark)
        try container.encode(sendKey, forKey: .sendKey)
        try container.encode(thinkingDisplay, forKey: .thinkingDisplay)
        try container.encode(renderThinkingAsMarkdown, forKey: .renderThinkingAsMarkdown)
        try container.encode(renderUserMessagesAsMarkdown, forKey: .renderUserMessagesAsMarkdown)
        try container.encode(showMessageStats, forKey: .showMessageStats)
        try container.encode(showAgenticTurnStats, forKey: .showAgenticTurnStats)
        try container.encode(alwaysExpandToolCalls, forKey: .alwaysExpandToolCalls)
        try container.encode(fullHeightCodeBlocks, forKey: .fullHeightCodeBlocks)
        try container.encode(disableAutoScroll, forKey: .disableAutoScroll)
        try container.encode(titleMode, forKey: .titleMode)
        try container.encode(titlePrompt, forKey: .titlePrompt)
        try container.encode(pasteLongTextToFileLength, forKey: .pasteLongTextToFileLength)
        try container.encode(maxImageMegapixels, forKey: .maxImageMegapixels)
        try container.encode(pdfAsImages, forKey: .pdfAsImages)
        try container.encode(enableContinue, forKey: .enableContinue)
        try container.encode(renderMath, forKey: .renderMath)
        try container.encode(confirmDelete, forKey: .confirmDelete)
        try container.encode(keepDeletedDays, forKey: .keepDeletedDays)
        try container.encode(maxAgenticTurns, forKey: .maxAgenticTurns)
        try container.encode(mcpRequestTimeoutSeconds, forKey: .mcpRequestTimeoutSeconds)
        try container.encode(mcpHandshakeTimeoutSeconds, forKey: .mcpHandshakeTimeoutSeconds)
        try container.encode(toolLogRetentionDays, forKey: .toolLogRetentionDays)
        try container.encode(localDiscoveryEnabled, forKey: .localDiscoveryEnabled)
        try container.encodeIfPresent(terminalShell, forKey: .terminalShell)
        try container.encode(terminalFont, forKey: .terminalFont)
        try container.encode(terminalScrollback, forKey: .terminalScrollback)
        try container.encode(showRawOutputToggle, forKey: .showRawOutputToggle)
        try container.encode(disableReasoningParsing, forKey: .disableReasoningParsing)
        try container.encode(excludeReasoningFromContext, forKey: .excludeReasoningFromContext)
    }

    private enum CodingKeys: String, CodingKey {
        case fonts, textScale, lineSpacing, maxMessageWidth, colorScheme, codeThemeLight, codeThemeDark
        case sendKey, thinkingDisplay, renderThinkingAsMarkdown, renderUserMessagesAsMarkdown, showMessageStats
        case showAgenticTurnStats, alwaysExpandToolCalls, fullHeightCodeBlocks, disableAutoScroll, titleMode
        case titlePrompt, pasteLongTextToFileLength, maxImageMegapixels, pdfAsImages, enableContinue, renderMath
        case confirmDelete, keepDeletedDays, maxAgenticTurns, mcpRequestTimeoutSeconds, mcpHandshakeTimeoutSeconds
        case toolLogRetentionDays, localDiscoveryEnabled, terminalShell, terminalFont, terminalScrollback
        case showRawOutputToggle, disableReasoningParsing, excludeReasoningFromContext
    }
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10, Double(places))
        return (self * factor).rounded() / factor
    }
}
