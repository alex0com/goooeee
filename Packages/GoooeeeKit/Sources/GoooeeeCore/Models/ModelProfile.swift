import Foundation

/// How a model marks its reasoning in plain text output.
public enum ReasoningFormat: Codable, Sendable, Hashable {
    /// Detect common tags automatically.
    case auto
    /// No reasoning.
    case none
    /// Open/close tags such as `<think>`…`</think>`. `mayStartInside` is for templates that open the
    /// tag in the prompt, so the output contains only the closing tag.
    case tags(open: String, close: String, mayStartInside: Bool)
    /// OpenAI Harmony channels (`<|channel|>analysis<|message|>…`).
    case harmony

    private enum CodingKeys: String, CodingKey { case format, open, close, mayStartInside }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .format) {
        case "none": self = .none
        case "harmony": self = .harmony
        case "tags":
            self = .tags(
                open: try container.decode(String.self, forKey: .open),
                close: try container.decode(String.self, forKey: .close),
                mayStartInside: try container.decodeIfPresent(Bool.self, forKey: .mayStartInside) ?? false
            )
        default: self = .auto
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .auto: try container.encode("auto", forKey: .format)
        case .none: try container.encode("none", forKey: .format)
        case .harmony: try container.encode("harmony", forKey: .format)
        case .tags(let open, let close, let mayStartInside):
            try container.encode("tags", forKey: .format)
            try container.encode(open, forKey: .open)
            try container.encode(close, forKey: .close)
            try container.encode(mayStartInside, forKey: .mayStartInside)
        }
    }
}

/// How the model's chat template expects thinking to be switched.
public struct ThinkingControl: Codable, Sendable, Hashable {
    /// `chat_template_kwargs` key, usually `enable_thinking`.
    public var chatTemplateKwarg: String?
    /// Soft-switch strings appended to the system prompt: `[on, off]`, e.g. `["/think", "/no_think"]`.
    public var softSwitch: [String]?
    /// Model understands `reasoning_effort` (gpt-oss, DeepSeek V4).
    public var reasoningEffort: Bool
    /// Model can't turn thinking off (always thinks).
    public var alwaysThinks: Bool

    public init(chatTemplateKwarg: String? = nil, softSwitch: [String]? = nil, reasoningEffort: Bool = false, alwaysThinks: Bool = false) {
        self.chatTemplateKwarg = chatTemplateKwarg
        self.softSwitch = softSwitch
        self.reasoningEffort = reasoningEffort
        self.alwaysThinks = alwaysThinks
    }

    private enum CodingKeys: String, CodingKey { case chatTemplateKwarg, softSwitch, reasoningEffort, alwaysThinks }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chatTemplateKwarg = try container.decodeIfPresent(String.self, forKey: .chatTemplateKwarg)
        softSwitch = try container.decodeIfPresent([String].self, forKey: .softSwitch)
        reasoningEffort = try container.decodeIfPresent(Bool.self, forKey: .reasoningEffort) ?? false
        alwaysThinks = try container.decodeIfPresent(Bool.self, forKey: .alwaysThinks) ?? false
    }
}

public struct ProfileSampling: Codable, Sendable, Hashable {
    /// Used when thinking is on, or when the model has no separate presets.
    public var thinking: SamplingSettings?
    /// Used when thinking is off.
    public var nonThinking: SamplingSettings?
    /// Used when the model has a single recommendation.
    public var standard: SamplingSettings?

    public init(thinking: SamplingSettings? = nil, nonThinking: SamplingSettings? = nil, standard: SamplingSettings? = nil) {
        self.thinking = thinking
        self.nonThinking = nonThinking
        self.standard = standard
    }

    public func settings(thinking level: ThinkingLevel) -> SamplingSettings {
        switch level.isEnabled {
        case .some(false): nonThinking ?? standard ?? thinking ?? SamplingSettings()
        case .some(true): thinking ?? standard ?? nonThinking ?? SamplingSettings()
        case .none: thinking ?? standard ?? nonThinking ?? SamplingSettings()
        }
    }
}

/// Curated knowledge about a model family: recommended sampling, reasoning format, capabilities.
public struct ModelProfile: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var displayName: String
    /// Case-insensitive regular expressions matched against the model ID.
    public var match: [String]
    public var reasoning: ReasoningFormat
    public var thinkingControl: ThinkingControl
    public var sampling: ProfileSampling
    public var vision: Bool?
    public var tools: Bool?
    /// Whether the template expects earlier reasoning to be sent back (e.g. MiniMax M2 interleaved thinking).
    public var keepReasoningInContext: Bool
    public var source: String?
    public var isCustom: Bool

    public init(
        id: String,
        displayName: String,
        match: [String],
        reasoning: ReasoningFormat = .auto,
        thinkingControl: ThinkingControl = ThinkingControl(),
        sampling: ProfileSampling = ProfileSampling(),
        vision: Bool? = nil,
        tools: Bool? = nil,
        keepReasoningInContext: Bool = false,
        source: String? = nil,
        isCustom: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.match = match
        self.reasoning = reasoning
        self.thinkingControl = thinkingControl
        self.sampling = sampling
        self.vision = vision
        self.tools = tools
        self.keepReasoningInContext = keepReasoningInContext
        self.source = source
        self.isCustom = isCustom
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, match, reasoning, thinkingControl, sampling, vision, tools, keepReasoningInContext, source, isCustom
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? id
        match = try container.decodeIfPresent([String].self, forKey: .match) ?? []
        reasoning = try container.decodeIfPresent(ReasoningFormat.self, forKey: .reasoning) ?? .auto
        thinkingControl = try container.decodeIfPresent(ThinkingControl.self, forKey: .thinkingControl) ?? ThinkingControl()
        sampling = try container.decodeIfPresent(ProfileSampling.self, forKey: .sampling) ?? ProfileSampling()
        vision = try container.decodeIfPresent(Bool.self, forKey: .vision)
        tools = try container.decodeIfPresent(Bool.self, forKey: .tools)
        keepReasoningInContext = try container.decodeIfPresent(Bool.self, forKey: .keepReasoningInContext) ?? false
        source = try container.decodeIfPresent(String.self, forKey: .source)
        isCustom = try container.decodeIfPresent(Bool.self, forKey: .isCustom) ?? false
    }

    /// Profile used when nothing matches: detect reasoning tags, send no sampling values.
    public static let generic = ModelProfile(id: "generic", displayName: "Generic", match: [], reasoning: .auto)

    public func matches(_ modelID: String) -> Bool {
        for pattern in match {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(modelID.startIndex..., in: modelID)
            if regex.firstMatch(in: modelID, range: range) != nil { return true }
        }
        return false
    }
}

/// Built-in profiles (bundled JSON) plus the user's custom profiles. Custom profiles win.
public struct ProfileRegistry: Sendable {
    public private(set) var builtIn: [ModelProfile]
    public private(set) var custom: [ModelProfile]

    public init(builtIn: [ModelProfile], custom: [ModelProfile] = []) {
        self.builtIn = builtIn
        self.custom = custom
    }

    /// Loads the bundled `model-profiles.json`.
    public static func bundled(custom: [ModelProfile] = []) -> ProfileRegistry {
        ProfileRegistry(builtIn: loadBundledProfiles(), custom: custom)
    }

    public static func loadBundledProfiles() -> [ModelProfile] {
        guard let url = Bundle.module.url(forResource: "model-profiles", withExtension: "json"),
            let data = try? Data(contentsOf: url)
        else { return [] }
        return (try? decodeProfiles(data)) ?? []
    }

    public static func decodeProfiles(_ data: Data) throws -> [ModelProfile] {
        struct File: Decodable { var profiles: [ModelProfile] }
        return try JSONDecoder().decode(File.self, from: data).profiles
    }

    public static func encodeProfiles(_ profiles: [ModelProfile]) throws -> Data {
        struct File: Encodable { var profiles: [ModelProfile] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(File(profiles: profiles))
    }

    public var all: [ModelProfile] { custom + builtIn }

    public func profile(id: String) -> ModelProfile? {
        all.first { $0.id == id }
    }

    /// First profile whose patterns match the model ID; custom profiles are checked first.
    public func match(modelID: String) -> ModelProfile? {
        all.first { $0.matches(modelID) }
    }

    /// Explicit choice, else a match, else the generic profile.
    public func resolve(modelID: String?, explicitID: String?) -> ModelProfile {
        if let explicitID, let profile = profile(id: explicitID) { return profile }
        if let modelID, let profile = match(modelID: modelID) { return profile }
        return .generic
    }

    public mutating func setCustom(_ profiles: [ModelProfile]) {
        custom = profiles.map {
            var profile = $0
            profile.isCustom = true
            return profile
        }
    }
}
