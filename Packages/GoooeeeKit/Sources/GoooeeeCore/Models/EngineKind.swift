import Foundation

/// The API a connection speaks. OpenAI chat completions is the default for every inference engine.
public enum APIStyle: String, Codable, Sendable, CaseIterable, Hashable {
    /// `POST /v1/chat/completions` (default).
    case openAIChat
    /// `POST /v1/completions` with a prompt rendered client-side from a user-loaded Jinja template.
    case openAICompletion
    /// `POST /v1/messages` (Anthropic's API).
    case anthropicMessages

    public var label: String {
        switch self {
        case .openAIChat: "OpenAI chat completions"
        case .openAICompletion: "OpenAI completions + local template"
        case .anthropicMessages: "Anthropic messages"
        }
    }
}

/// Known inference engines. Each one is a preset on top of the OpenAI-compatible API.
public enum EngineKind: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    case llamaCpp
    case vllm
    case mlxLM
    case mlxVLM
    case dwarfStar4
    case lmStudio
    case ollama
    case openAI
    case anthropic
    case genericOpenAI

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .llamaCpp: "llama.cpp"
        case .vllm: "vLLM"
        case .mlxLM: "mlx_lm"
        case .mlxVLM: "mlx-vlm"
        case .dwarfStar4: "DwarfStar 4"
        case .lmStudio: "LM Studio"
        case .ollama: "Ollama"
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .genericOpenAI: "OpenAI-compatible"
        }
    }

    /// Server root, without the API prefix.
    public var defaultBaseURL: URL {
        switch self {
        case .llamaCpp, .mlxLM, .mlxVLM: URL(string: "http://127.0.0.1:8080")!
        case .vllm, .dwarfStar4: URL(string: "http://127.0.0.1:8000")!
        case .lmStudio: URL(string: "http://127.0.0.1:1234")!
        case .ollama: URL(string: "http://127.0.0.1:11434")!
        case .openAI: URL(string: "https://api.openai.com")!
        case .anthropic: URL(string: "https://api.anthropic.com")!
        case .genericOpenAI: URL(string: "http://127.0.0.1:8080")!
        }
    }

    public var defaultAPIPrefix: String { "/v1" }

    public var defaultAPIStyle: APIStyle {
        self == .anthropic ? .anthropicMessages : .openAIChat
    }

    public var isLocalByDefault: Bool {
        switch self {
        case .openAI, .anthropic: false
        default: true
        }
    }

    public var requiresAPIKey: Bool {
        switch self {
        case .openAI, .anthropic: true
        default: false
        }
    }

    /// Path checked by the health probe, relative to the server root.
    public var healthPath: String? {
        switch self {
        case .llamaCpp, .vllm, .mlxVLM: "/health"
        default: nil
        }
    }

    public var launchCommandExample: String {
        switch self {
        case .llamaCpp: "llama-server -m ~/models/model.gguf --jinja --port 8080 -c 32768"
        case .vllm: "vllm serve Qwen/Qwen3-32B --reasoning-parser qwen3 --enable-auto-tool-choice --tool-call-parser hermes --port 8000"
        case .mlxLM: "mlx_lm.server --model mlx-community/Qwen3-32B-4bit --port 8080"
        case .mlxVLM: "mlx_vlm.server --model mlx-community/Qwen2.5-VL-7B-Instruct-4bit --port 8080"
        case .dwarfStar4: "./ds4-server --ctx 32768"
        case .lmStudio: "lms server start --port 1234"
        case .ollama: "ollama serve"
        case .openAI, .anthropic: ""
        case .genericOpenAI: ""
        }
    }

    public var capabilities: EngineCapabilities {
        switch self {
        case .llamaCpp:
            EngineCapabilities(
                samplingKeys: Set(SamplingKey.allCases),
                wireNames: [:],
                streamOptionsUsage: true,
                llamaCppExtras: true,
                continueFinalMessage: true,
                thinkingMechanisms: [.chatTemplateKwarg, .llamaCppBudget, .reasoningEffort],
                supportsProps: true,
                supportsRouter: true,
                supportsServerTools: true,
                supportsApplyTemplate: true,
                maxTokensKey: "max_tokens"
            )
        case .vllm:
            EngineCapabilities(
                samplingKeys: [.temperature, .topK, .topP, .minP, .maxTokens, .repeatPenalty, .presencePenalty,
                               .frequencyPenalty, .seed, .stop],
                wireNames: [.repeatPenalty: "repetition_penalty"],
                streamOptionsUsage: true,
                continueFinalMessage: true,
                thinkingMechanisms: [.chatTemplateKwarg, .reasoningEffort],
                maxTokensKey: "max_tokens"
            )
        case .mlxLM:
            EngineCapabilities(
                samplingKeys: [.temperature, .topK, .topP, .minP, .maxTokens, .repeatPenalty, .presencePenalty,
                               .frequencyPenalty, .stop],
                wireNames: [.repeatPenalty: "repetition_penalty"],
                streamOptionsUsage: true,
                thinkingMechanisms: [.chatTemplateKwarg],
                maxTokensKey: "max_tokens"
            )
        case .mlxVLM:
            EngineCapabilities(
                samplingKeys: [.temperature, .topK, .topP, .minP, .maxTokens, .repeatPenalty],
                wireNames: [.repeatPenalty: "repetition_penalty"],
                streamOptionsUsage: false,
                thinkingMechanisms: [.enableThinkingFlag],
                maxTokensKey: "max_tokens"
            )
        case .dwarfStar4:
            EngineCapabilities(
                samplingKeys: [.temperature, .topK, .topP, .minP, .maxTokens, .stop, .seed],
                wireNames: [:],
                streamOptionsUsage: true,
                thinkingMechanisms: [.thinkFlag, .reasoningEffort],
                maxTokensKey: "max_tokens"
            )
        case .lmStudio:
            EngineCapabilities(
                samplingKeys: [.temperature, .topK, .topP, .minP, .maxTokens, .repeatPenalty, .presencePenalty,
                               .frequencyPenalty, .seed, .stop],
                wireNames: [:],
                streamOptionsUsage: true,
                thinkingMechanisms: [.reasoningEffort],
                maxTokensKey: "max_tokens"
            )
        case .ollama:
            EngineCapabilities(
                samplingKeys: [.temperature, .topP, .maxTokens, .presencePenalty, .frequencyPenalty, .seed, .stop],
                wireNames: [:],
                streamOptionsUsage: true,
                thinkingMechanisms: [.reasoningEffort, .thinkFlag],
                maxTokensKey: "max_tokens"
            )
        case .openAI:
            EngineCapabilities(
                samplingKeys: [.temperature, .topP, .maxTokens, .presencePenalty, .frequencyPenalty, .seed, .stop],
                wireNames: [:],
                streamOptionsUsage: true,
                thinkingMechanisms: [.reasoningEffort],
                maxTokensKey: "max_completion_tokens"
            )
        case .anthropic:
            EngineCapabilities(
                samplingKeys: [.temperature, .topK, .topP, .maxTokens, .stop],
                wireNames: [.stop: "stop_sequences"],
                streamOptionsUsage: false,
                thinkingMechanisms: [.anthropicThinking],
                maxTokensKey: "max_tokens"
            )
        case .genericOpenAI:
            EngineCapabilities(
                samplingKeys: [.temperature, .topK, .topP, .minP, .maxTokens, .repeatPenalty, .presencePenalty,
                               .frequencyPenalty, .seed, .stop],
                wireNames: [.repeatPenalty: "repetition_penalty"],
                streamOptionsUsage: true,
                thinkingMechanisms: [.chatTemplateKwarg, .reasoningEffort],
                maxTokensKey: "max_tokens"
            )
        }
    }
}

/// What an engine accepts beyond the basic OpenAI chat request.
public struct EngineCapabilities: Sendable, Hashable {
    /// Sampling keys that are sent to this engine. Others are dropped from requests.
    public var samplingKeys: Set<SamplingKey>
    /// Wire names that differ from `SamplingKey.rawValue`.
    public var wireNames: [SamplingKey: String]
    /// Sends `stream_options: {include_usage: true}`.
    public var streamOptionsUsage: Bool
    /// llama.cpp request extras: `return_progress`, `reasoning_format`, `reasoning_control`,
    /// `sse_ping_interval`, `thinking_budget_tokens`, `timings`.
    public var llamaCppExtras: Bool
    /// Supports `continue_final_message` + `add_generation_prompt: false`.
    public var continueFinalMessage: Bool
    /// Thinking mechanisms in order of preference.
    public var thinkingMechanisms: [ThinkingMechanism]
    public var supportsProps: Bool
    public var supportsRouter: Bool
    public var supportsServerTools: Bool
    public var supportsApplyTemplate: Bool
    public var maxTokensKey: String

    public init(
        samplingKeys: Set<SamplingKey>,
        wireNames: [SamplingKey: String],
        streamOptionsUsage: Bool,
        llamaCppExtras: Bool = false,
        continueFinalMessage: Bool = false,
        thinkingMechanisms: [ThinkingMechanism],
        supportsProps: Bool = false,
        supportsRouter: Bool = false,
        supportsServerTools: Bool = false,
        supportsApplyTemplate: Bool = false,
        maxTokensKey: String
    ) {
        self.samplingKeys = samplingKeys
        self.wireNames = wireNames
        self.streamOptionsUsage = streamOptionsUsage
        self.llamaCppExtras = llamaCppExtras
        self.continueFinalMessage = continueFinalMessage
        self.thinkingMechanisms = thinkingMechanisms
        self.supportsProps = supportsProps
        self.supportsRouter = supportsRouter
        self.supportsServerTools = supportsServerTools
        self.supportsApplyTemplate = supportsApplyTemplate
        self.maxTokensKey = maxTokensKey
    }

    public func wireName(for key: SamplingKey) -> String {
        if key == .maxTokens { return maxTokensKey }
        return wireNames[key] ?? key.rawValue
    }
}
