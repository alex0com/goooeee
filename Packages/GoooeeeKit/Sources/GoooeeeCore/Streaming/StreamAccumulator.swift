import Foundation

/// Monotonic time in seconds.
public enum MonotonicClock {
    public static func now() -> Double { ProcessInfo.processInfo.systemUptime }
}

/// Assembles streamed tool call deltas (OpenAI `tool_calls[].index`, Anthropic content block index).
public struct ToolCallAssembler: Sendable {
    private struct Partial: Sendable {
        var id: String?
        var name: String
        var arguments: String
    }

    private var partials: [Int: Partial] = [:]
    private var order: [Int] = []

    public init() {}

    public var isEmpty: Bool { partials.isEmpty }

    public mutating func apply(index: Int, id: String?, name: String?, argumentsFragment: String) {
        if partials[index] == nil {
            partials[index] = Partial(id: nil, name: "", arguments: "")
            order.append(index)
        }
        if let id, !id.isEmpty, partials[index]?.id == nil { partials[index]?.id = id }
        if let name, !name.isEmpty {
            // Most servers send the name once; a few stream it in pieces.
            if partials[index]?.name.isEmpty == true || !(partials[index]?.name.hasSuffix(name) ?? false) {
                if partials[index]?.name.isEmpty == true {
                    partials[index]?.name = name
                } else if partials[index]?.name != name {
                    partials[index]?.name += name
                }
            }
        }
        partials[index]?.arguments += argumentsFragment
    }

    public var toolCalls: [ToolCall] {
        order.compactMap { index in
            guard let partial = partials[index], !partial.name.isEmpty else { return nil }
            return ToolCall(
                id: partial.id ?? "call_\(index)_\(UUID().uuidString.prefix(8).lowercased())",
                name: partial.name,
                arguments: partial.arguments
            )
        }
    }

    /// Calls with stable IDs (assigned once, so the UI can track them while arguments stream).
    public mutating func finalizedToolCalls() -> [ToolCall] {
        for index in order where partials[index]?.id == nil {
            partials[index]?.id = "call_\(index)_\(UUID().uuidString.prefix(8).lowercased())"
        }
        return toolCalls
    }
}

/// A change to the streaming message, applied by the UI.
public enum AccumulatorChange: Sendable, Hashable {
    case started(completionID: String?, model: String?)
    case promptProgress(PromptProgress)
    /// A new block was appended at `index`.
    case blockAdded(index: Int, block: ContentBlock)
    /// Text appended to the block at `index`.
    case textAppended(index: Int, text: String)
    /// Blocks were restructured (reasoning reclassified); redraw the message.
    case blocksReplaced([ContentBlock])
    case thinkingFinished(index: Int, duration: TimeInterval)
    case toolCallsUpdated([ToolCall])
    case metricsUpdated(GenerationMetrics)
    case finished(FinishReason)
}

/// Builds an assistant message from stream events and records timing.
public struct StreamAccumulator: Sendable {
    public private(set) var blocks: [ContentBlock] = []
    public private(set) var metrics = GenerationMetrics()
    public private(set) var completionID: String?
    public private(set) var model: String?
    public private(set) var finishReason: FinishReason?
    public private(set) var promptProgress: PromptProgress?
    public private(set) var signature: String?

    private var splitter: ReasoningSplitter
    private var tools = ToolCallAssembler()
    private let requestStart: Double
    private var firstTokenAt: Double?
    private var lastTokenAt: Double?
    private var thinkingStartedAt: Double?
    private var openThinkingIndex: Int?
    private var timings: ServerTimings?
    private var usage = TokenUsage()
    /// Reasoning delivered in a separate field: don't also parse tags in content.
    private var fieldReasoningSeen = false

    public init(splitter: ReasoningSplitter, requestStart: Double = MonotonicClock.now()) {
        self.splitter = splitter
        self.requestStart = requestStart
    }

    /// Continue an existing message (Continue button): new text is appended to its blocks.
    public init(continuing blocks: [ContentBlock], splitter: ReasoningSplitter, requestStart: Double = MonotonicClock.now()) {
        self.blocks = blocks
        self.splitter = splitter
        self.requestStart = requestStart
    }

    public var toolCalls: [ToolCall] { tools.toolCalls }
    public var hasToolCalls: Bool { !tools.isEmpty }

    public mutating func apply(_ event: StreamEvent, now: Double = MonotonicClock.now()) -> [AccumulatorChange] {
        switch event {
        case .started(let id, let model):
            completionID = completionID ?? id
            self.model = self.model ?? model
            return [.started(completionID: id, model: model)]

        case .promptProgress(let progress):
            promptProgress = progress
            return [.promptProgress(progress)]

        case .reasoningDelta(let text):
            fieldReasoningSeen = true
            markToken(now)
            return appendReasoning(text, now: now)

        case .reasoningSignature(let signature):
            self.signature = (self.signature ?? "") + signature
            if let index = openThinkingIndex ?? blocks.lastIndex(where: \.isThinking),
                case .thinking(let text, let duration, _) = blocks[index]
            {
                blocks[index] = .thinking(text, duration: duration, signature: self.signature)
            }
            return []

        case .contentDelta(let text):
            markToken(now)
            if fieldReasoningSeen {
                return appendContent(text, now: now)
            }
            var changes: [AccumulatorChange] = []
            for output in splitter.feed(text) {
                changes += apply(output, now: now)
            }
            return changes + [.metricsUpdated(metrics)]

        case .toolCallDelta(let index, let id, let name, let fragment):
            markToken(now)
            tools.apply(index: index, id: id, name: name, argumentsFragment: fragment)
            return closeThinking(now: now) + [.toolCallsUpdated(tools.toolCalls)]

        case .usage(let newUsage):
            usage.promptTokens = newUsage.promptTokens ?? usage.promptTokens
            usage.completionTokens = newUsage.completionTokens ?? usage.completionTokens
            usage.cachedTokens = newUsage.cachedTokens ?? usage.cachedTokens
            usage.reasoningTokens = newUsage.reasoningTokens ?? usage.reasoningTokens
            updateMetrics(now: now)
            return [.metricsUpdated(metrics)]

        case .serverTimings(let newTimings):
            timings = newTimings
            updateMetrics(now: now)
            return [.metricsUpdated(metrics)]

        case .finished(let reason):
            var changes: [AccumulatorChange] = []
            for output in splitter.flush() {
                changes += apply(output, now: now)
            }
            changes += closeThinking(now: now)
            finishReason = reason
            updateMetrics(now: now, finished: true)
            let calls = tools.finalizedToolCalls()
            if !calls.isEmpty { changes.append(.toolCallsUpdated(calls)) }
            changes.append(.metricsUpdated(metrics))
            changes.append(.finished(reason))
            return changes
        }
    }

    /// Final tool calls with stable IDs.
    public mutating func finalizeToolCalls() -> [ToolCall] {
        tools.finalizedToolCalls()
    }

    /// Marks the end of a cancelled or failed stream.
    public mutating func finishAbruptly(now: Double = MonotonicClock.now()) -> [AccumulatorChange] {
        var changes: [AccumulatorChange] = []
        for output in splitter.flush() { changes += apply(output, now: now) }
        changes += closeThinking(now: now)
        updateMetrics(now: now, finished: true)
        changes.append(.metricsUpdated(metrics))
        return changes
    }

    private mutating func apply(_ output: ReasoningSplitter.Output, now: Double) -> [AccumulatorChange] {
        switch output {
        case .content(let text): return appendContent(text, now: now)
        case .reasoning(let text): return appendReasoning(text, now: now)
        case .reclassifyContentAsReasoning:
            let text = blocks.map(\.text).joined()
            blocks = text.isEmpty ? [] : [.thinking(text, duration: nil, signature: nil)]
            openThinkingIndex = blocks.isEmpty ? nil : 0
            if thinkingStartedAt == nil { thinkingStartedAt = firstTokenAt ?? now }
            return [.blocksReplaced(blocks)]
        }
    }

    private mutating func appendReasoning(_ text: String, now: Double) -> [AccumulatorChange] {
        guard !text.isEmpty else { return [] }
        if let index = openThinkingIndex, case .thinking(let existing, let duration, let signature) = blocks[index] {
            blocks[index] = .thinking(existing + text, duration: duration, signature: signature)
            metrics.deltaCount += 1
            return [.textAppended(index: index, text: text)]
        }
        thinkingStartedAt = thinkingStartedAt ?? now
        blocks.append(.thinking(text, duration: nil, signature: nil))
        openThinkingIndex = blocks.count - 1
        metrics.deltaCount += 1
        return [.blockAdded(index: blocks.count - 1, block: blocks[blocks.count - 1])]
    }

    private mutating func appendContent(_ text: String, now: Double) -> [AccumulatorChange] {
        guard !text.isEmpty else { return [] }
        var changes = closeThinking(now: now)
        metrics.deltaCount += 1
        if let last = blocks.indices.last, case .text(let existing) = blocks[last] {
            blocks[last] = .text(existing + text)
            changes.append(.textAppended(index: last, text: text))
        } else {
            // Leading whitespace after a thinking block is noise.
            let trimmed = blocks.isEmpty ? text : String(text.drop { $0.isNewline })
            guard !trimmed.isEmpty else { return changes }
            blocks.append(.text(trimmed))
            changes.append(.blockAdded(index: blocks.count - 1, block: blocks[blocks.count - 1]))
        }
        return changes
    }

    private mutating func closeThinking(now: Double) -> [AccumulatorChange] {
        guard let index = openThinkingIndex, case .thinking(let text, _, let signature) = blocks[index] else { return [] }
        let duration = now - (thinkingStartedAt ?? now)
        blocks[index] = .thinking(text, duration: duration, signature: signature ?? self.signature)
        openThinkingIndex = nil
        metrics.thinkingMs = (metrics.thinkingMs ?? 0) + duration * 1000
        thinkingStartedAt = nil
        return [.thinkingFinished(index: index, duration: duration)]
    }

    private mutating func markToken(_ now: Double) {
        if firstTokenAt == nil {
            firstTokenAt = now
            metrics.ttftMs = (now - requestStart) * 1000
        }
        lastTokenAt = now
        if let first = firstTokenAt { metrics.clientGenerationMs = (now - first) * 1000 }
    }

    private mutating func updateMetrics(now: Double, finished: Bool = false) {
        metrics.promptTokens = usage.promptTokens ?? timings.flatMap { timing in
            timing.promptN.map { $0 + (timing.cacheN ?? 0) }
        } ?? metrics.promptTokens
        metrics.completionTokens = usage.completionTokens ?? timings?.predictedN ?? metrics.completionTokens
        metrics.cachedTokens = usage.cachedTokens ?? timings?.cacheN ?? metrics.cachedTokens
        metrics.reasoningTokens = usage.reasoningTokens ?? metrics.reasoningTokens
        if let timings {
            metrics.promptEvaluatedTokens = timings.promptN ?? metrics.promptEvaluatedTokens
            metrics.serverPromptMs = timings.promptMs ?? metrics.serverPromptMs
            metrics.serverPredictedMs = timings.predictedMs ?? metrics.serverPredictedMs
            metrics.serverPredictedPerSecond = timings.predictedPerSecond ?? metrics.serverPredictedPerSecond
        }
        if finished {
            metrics.totalMs = (now - requestStart) * 1000
        }
    }

    /// The message content assembled so far.
    public var currentText: String {
        blocks.compactMap { if case .text(let text) = $0 { return text } else { return nil } }.joined()
    }
}

extension Message {
    /// Applies a streaming change from the engine to the UI's copy of the message.
    public mutating func apply(_ change: AccumulatorChange) {
        switch change {
        case .started(let completionID, let model):
            if let completionID { self.completionID = completionID }
            if let model, modelID == nil { modelID = model }
        case .promptProgress:
            break
        case .blockAdded(let index, let block):
            if index < blocks.count {
                blocks[index] = block
            } else {
                blocks.append(block)
            }
        case .textAppended(let index, let text):
            guard blocks.indices.contains(index) else { return }
            switch blocks[index] {
            case .text(let existing): blocks[index] = .text(existing + text)
            case .thinking(let existing, let duration, let signature): blocks[index] = .thinking(existing + text, duration: duration, signature: signature)
            }
        case .blocksReplaced(let newBlocks):
            blocks = newBlocks
        case .thinkingFinished(let index, let duration):
            guard blocks.indices.contains(index), case .thinking(let text, _, let signature) = blocks[index] else { return }
            blocks[index] = .thinking(text, duration: duration, signature: signature)
        case .toolCallsUpdated(let calls):
            var merged = calls
            for index in merged.indices {
                if let existing = toolCalls.first(where: { $0.id == merged[index].id }) {
                    merged[index].status = existing.status
                    merged[index].sourceLabel = existing.sourceLabel
                }
            }
            toolCalls = merged
        case .metricsUpdated(let metrics):
            self.metrics = metrics
        case .finished:
            break
        }
    }
}
