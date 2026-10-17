import Foundation

/// Totals for an agentic run (several model turns with tool calls in between).
public struct AgenticTotals: Codable, Sendable, Hashable {
    public var turns: Int
    public var toolCalls: Int
    public var toolMs: Double
    public var perTurn: [TurnStats]

    public init(turns: Int = 0, toolCalls: Int = 0, toolMs: Double = 0, perTurn: [TurnStats] = []) {
        self.turns = turns
        self.toolCalls = toolCalls
        self.toolMs = toolMs
        self.perTurn = perTurn
    }

    public struct TurnStats: Codable, Sendable, Hashable {
        public var promptTokens: Int?
        public var completionTokens: Int?
        public var promptMs: Double?
        public var generationMs: Double?
        public var toolMs: Double

        public init(promptTokens: Int? = nil, completionTokens: Int? = nil, promptMs: Double? = nil, generationMs: Double? = nil, toolMs: Double = 0) {
            self.promptTokens = promptTokens
            self.completionTokens = completionTokens
            self.promptMs = promptMs
            self.generationMs = generationMs
            self.toolMs = toolMs
        }
    }
}

/// Where a number came from: the server's own timing, or goooeee's clock.
public enum MetricSource: String, Codable, Sendable, Hashable {
    case server
    case client
}

/// Speed and token statistics for one assistant message.
public struct GenerationMetrics: Codable, Sendable, Hashable {
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var cachedTokens: Int?
    public var reasoningTokens: Int?
    /// Prompt tokens actually evaluated (not served from cache), llama.cpp `timings.prompt_n`.
    public var promptEvaluatedTokens: Int?
    /// Prompt processing time reported by the server (llama.cpp `timings.prompt_ms`).
    public var serverPromptMs: Double?
    /// Generation time reported by the server (llama.cpp `timings.predicted_ms`).
    public var serverPredictedMs: Double?
    /// Server-reported generation tok/s when it reports a rate but not a duration (mlx-vlm).
    public var serverPredictedPerSecond: Double?
    /// Request sent → first token (content or reasoning), client clock.
    public var ttftMs: Double?
    /// First token → last token, client clock.
    public var clientGenerationMs: Double?
    /// Request sent → stream finished, client clock.
    public var totalMs: Double?
    /// Number of streamed deltas (approximate token count while streaming).
    public var deltaCount: Int
    /// Duration of the thinking phase.
    public var thinkingMs: Double?
    public var agentic: AgenticTotals?

    public init(
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        cachedTokens: Int? = nil,
        reasoningTokens: Int? = nil,
        promptEvaluatedTokens: Int? = nil,
        serverPromptMs: Double? = nil,
        serverPredictedMs: Double? = nil,
        serverPredictedPerSecond: Double? = nil,
        ttftMs: Double? = nil,
        clientGenerationMs: Double? = nil,
        totalMs: Double? = nil,
        deltaCount: Int = 0,
        thinkingMs: Double? = nil,
        agentic: AgenticTotals? = nil
    ) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.cachedTokens = cachedTokens
        self.reasoningTokens = reasoningTokens
        self.promptEvaluatedTokens = promptEvaluatedTokens
        self.serverPromptMs = serverPromptMs
        self.serverPredictedMs = serverPredictedMs
        self.serverPredictedPerSecond = serverPredictedPerSecond
        self.ttftMs = ttftMs
        self.clientGenerationMs = clientGenerationMs
        self.totalMs = totalMs
        self.deltaCount = deltaCount
        self.thinkingMs = thinkingMs
        self.agentic = agentic
    }

    /// Tokens generated so far: the server count when known, else the delta count.
    public var generatedTokens: Int { completionTokens ?? deltaCount }

    /// Prompt processing speed (tok/s). `isEstimate` when derived from TTFT, which includes network and queueing.
    public var promptSpeed: (value: Double, isEstimate: Bool)? {
        if let ms = serverPromptMs, ms > 0, let evaluated = promptEvaluatedTokens, evaluated > 0 {
            return (Double(evaluated) / (ms / 1000), false)
        }
        if let ttft = ttftMs, ttft > 0, let tokens = promptTokens, tokens > 0 {
            let evaluated = max(tokens - (cachedTokens ?? 0), 1)
            return (Double(evaluated) / (ttft / 1000), true)
        }
        return nil
    }

    /// Generation speed (tok/s). Server timing preferred.
    public var generationSpeed: (value: Double, source: MetricSource)? {
        if let ms = serverPredictedMs, ms > 0, let tokens = completionTokens, tokens > 0 {
            return (Double(tokens) / (ms / 1000), .server)
        }
        if let rate = serverPredictedPerSecond, rate > 0 {
            return (rate, .server)
        }
        if let ms = clientGenerationMs, ms > 0 {
            let tokens = max(generatedTokens - 1, 0)
            guard tokens > 0 else { return nil }
            return (Double(tokens) / (ms / 1000), .client)
        }
        return nil
    }

    /// End-to-end average: generated tokens over the total request time.
    public var averageSpeed: Double? {
        guard let total = totalMs, total > 0, generatedTokens > 0 else { return nil }
        return Double(generatedTokens) / (total / 1000)
    }
}

/// Context window usage for the active conversation.
public struct ContextUsage: Sendable, Hashable {
    public var used: Int
    public var total: Int?

    public init(used: Int, total: Int?) {
        self.used = used
        self.total = total
    }

    public var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(used) / Double(total))
    }

    /// Uses the last assistant message's prompt + completion tokens, which is what the next request will carry.
    public static func estimate(path: [Message], contextLength: Int?) -> ContextUsage {
        let last = path.last { $0.role == .assistant && $0.metrics != nil }
        let used = (last?.metrics?.promptTokens ?? 0) + (last?.metrics?.generatedTokens ?? 0)
        if used > 0 { return ContextUsage(used: used, total: contextLength) }
        let characters = path.reduce(0) { $0 + $1.text.count + $1.reasoning.count }
        return ContextUsage(used: characters / 4, total: contextLength)
    }
}

/// Formats numbers for the metrics footer.
public enum MetricsFormatter {
    public static func speed(_ value: Double) -> String {
        value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    public static func duration(ms: Double) -> String {
        if ms < 1000 { return String(format: "%.0f ms", ms) }
        if ms < 60_000 { return String(format: "%.2f s", ms / 1000) }
        let minutes = Int(ms / 60_000)
        let seconds = Int(ms.truncatingRemainder(dividingBy: 60_000) / 1000)
        return "\(minutes)m \(seconds)s"
    }

    public static func tokens(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: count)) ?? String(count)
    }

    public static func compactTokens(_ count: Int) -> String {
        if count >= 10_000 { return String(format: "%.1fk", Double(count) / 1000) }
        return tokens(count)
    }
}
