import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A content part of an API-neutral chat message.
public enum ChatContentPart: Sendable, Hashable {
    case text(String)
    case image(data: Data, mimeType: String)

    public var isImage: Bool {
        if case .image = self { return true }
        return false
    }
}

/// An API-neutral chat message, converted to OpenAI or Anthropic wire format by the providers.
public struct ChatMessage: Sendable, Hashable {
    public var role: Role
    public var content: [ChatContentPart]
    /// Reasoning to send back (only when the model's template needs it).
    public var reasoning: String?
    /// Anthropic thinking signature for `reasoning`.
    public var reasoningSignature: String?
    public var toolCalls: [ToolCall]
    public var toolCallID: String?

    public init(
        role: Role,
        content: [ChatContentPart],
        reasoning: String? = nil,
        reasoningSignature: String? = nil,
        toolCalls: [ToolCall] = [],
        toolCallID: String? = nil
    ) {
        self.role = role
        self.content = content
        self.reasoning = reasoning
        self.reasoningSignature = reasoningSignature
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }

    public static func text(_ role: Role, _ text: String) -> ChatMessage {
        ChatMessage(role: role, content: [.text(text)])
    }

    /// All text parts joined.
    public var text: String {
        content.compactMap { if case .text(let text) = $0 { return text } else { return nil } }.joined(separator: "\n\n")
    }

    public var hasImages: Bool { content.contains(where: \.isImage) }
}

/// Everything a provider needs to make one request.
public struct ChatRequest: Sendable {
    public var model: String?
    /// Includes the system message (first) when there is one.
    public var messages: [ChatMessage]
    public var settings: EffectiveSettings
    public var tools: [ToolDefinition]
    /// Continue the last assistant message instead of starting a new one.
    public var continueFinalMessage: Bool
    /// Strip images when the model can't see them.
    public var supportsVision: Bool
    /// llama.cpp: `reasoning_format: none` (leave reasoning in the content).
    public var disableReasoningParsing: Bool
    public var stream: Bool

    public init(
        model: String?,
        messages: [ChatMessage],
        settings: EffectiveSettings = EffectiveSettings(),
        tools: [ToolDefinition] = [],
        continueFinalMessage: Bool = false,
        supportsVision: Bool = true,
        disableReasoningParsing: Bool = false,
        stream: Bool = true
    ) {
        self.model = model
        self.messages = messages
        self.settings = settings
        self.tools = tools
        self.continueFinalMessage = continueFinalMessage
        self.supportsVision = supportsVision
        self.disableReasoningParsing = disableReasoningParsing
        self.stream = stream
    }
}

/// Token counts reported by the server.
public struct TokenUsage: Sendable, Hashable {
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var cachedTokens: Int?
    public var reasoningTokens: Int?

    public init(promptTokens: Int? = nil, completionTokens: Int? = nil, cachedTokens: Int? = nil, reasoningTokens: Int? = nil) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.cachedTokens = cachedTokens
        self.reasoningTokens = reasoningTokens
    }
}

/// llama.cpp `timings` (and mlx-vlm's partial version).
public struct ServerTimings: Sendable, Hashable {
    public var promptN: Int?
    public var promptMs: Double?
    public var predictedN: Int?
    public var predictedMs: Double?
    public var cacheN: Int?
    public var predictedPerSecond: Double?

    public init(promptN: Int? = nil, promptMs: Double? = nil, predictedN: Int? = nil, predictedMs: Double? = nil, cacheN: Int? = nil, predictedPerSecond: Double? = nil) {
        self.promptN = promptN
        self.promptMs = promptMs
        self.predictedN = predictedN
        self.predictedMs = predictedMs
        self.cacheN = cacheN
        self.predictedPerSecond = predictedPerSecond
    }
}

public struct PromptProgress: Sendable, Hashable {
    public var processed: Int
    public var total: Int
    public var cached: Int
    public var elapsedMs: Double

    public init(processed: Int, total: Int, cached: Int, elapsedMs: Double) {
        self.processed = processed
        self.total = total
        self.cached = cached
        self.elapsedMs = elapsedMs
    }

    public var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(processed) / Double(total))
    }

    /// Prompt tokens per second so far (excluding cached tokens).
    public var speed: Double? {
        let evaluated = processed - cached
        guard elapsedMs > 0, evaluated > 0 else { return nil }
        return Double(evaluated) / (elapsedMs / 1000)
    }
}

public enum FinishReason: String, Sendable, Hashable {
    case stop
    case length
    case toolCalls = "tool_calls"
    case contentFilter = "content_filter"
    case cancelled
    case unknown

    public init(wire: String?) {
        switch wire {
        case "stop", "end_turn", "stop_sequence", "eos": self = .stop
        case "length", "max_tokens": self = .length
        case "tool_calls", "tool_use", "function_call": self = .toolCalls
        case "content_filter", "refusal": self = .contentFilter
        case nil: self = .unknown
        default: self = .unknown
        }
    }
}

/// Events emitted while streaming one completion.
public enum StreamEvent: Sendable, Hashable {
    case started(completionID: String?, model: String?)
    case promptProgress(PromptProgress)
    case reasoningDelta(String)
    /// Anthropic thinking signature for the current thinking block.
    case reasoningSignature(String)
    case contentDelta(String)
    case toolCallDelta(index: Int, id: String?, name: String?, argumentsFragment: String)
    case usage(TokenUsage)
    case serverTimings(ServerTimings)
    case finished(FinishReason)
}

/// A provider for one API style.
public protocol InferenceProvider: Sendable {
    /// Builds the HTTP request for `request` (also used to render curl examples).
    func makeURLRequest(_ request: ChatRequest) throws -> URLRequest
    /// Streams one completion.
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error>
    /// Lists models (`GET /v1/models`).
    func listModels() async throws -> [RemoteModel]
}
