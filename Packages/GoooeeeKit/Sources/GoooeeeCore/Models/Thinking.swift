import Foundation

/// The single thinking control shown in the composer and inspector.
public enum ThinkingLevel: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    /// Send nothing; the server or chat template decides.
    case `default`
    case off
    case low
    case medium
    case high
    case max

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .default: "Default"
        case .off: "Off"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .max: "Max"
        }
    }

    /// `true` when thinking is explicitly requested, `false` when explicitly disabled, `nil` for default.
    public var isEnabled: Bool? {
        switch self {
        case .default: nil
        case .off: false
        default: true
        }
    }

    /// llama.cpp UI budget mapping (`REASONING_EFFORT_TOKENS`): Low 512, Medium 2048, High 8192, Max unlimited.
    public var llamaCppBudgetTokens: Int? {
        switch self {
        case .low: 512
        case .medium: 2048
        case .high: 8192
        case .max: -1
        default: nil
        }
    }

    /// Budget for Anthropic's `thinking.budget_tokens` (minimum 1024).
    public var anthropicBudgetTokens: Int? {
        switch self {
        case .low: 2048
        case .medium: 8192
        case .high: 16384
        case .max: 32000
        default: nil
        }
    }

    /// Value for OpenAI-style `reasoning_effort`.
    public var reasoningEffort: String? {
        switch self {
        case .default: nil
        case .off: "minimal"
        case .low: "low"
        case .medium: "medium"
        case .high: "high"
        case .max: "high"
        }
    }
}

public struct ThinkingSettings: Codable, Sendable, Hashable {
    public var level: ThinkingLevel

    public init(level: ThinkingLevel = .default) {
        self.level = level
    }
}

/// How a request turns thinking on or off for a given engine.
public enum ThinkingMechanism: String, Codable, Sendable, Hashable {
    /// `chat_template_kwargs.enable_thinking` (vLLM, llama.cpp `--jinja`, SGLang, mlx_lm).
    case chatTemplateKwarg
    /// llama.cpp `thinking_budget_tokens`.
    case llamaCppBudget
    /// mlx-vlm top-level `enable_thinking` + `thinking_budget`.
    case enableThinkingFlag
    /// OpenAI-style `reasoning_effort`.
    case reasoningEffort
    /// `think: true/false` (DwarfStar 4, Ollama).
    case thinkFlag
    /// Anthropic `thinking` object.
    case anthropicThinking
}
