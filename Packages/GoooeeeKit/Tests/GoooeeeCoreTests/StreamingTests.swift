import Foundation
import Testing
@testable import GoooeeeCore

@Suite("SSE parser")
struct SSEParserTests {
    @Test func splitsEventsAcrossChunks() {
        var parser = SSEParser()
        let text = "data: {\"a\":1}\n\n: keep-alive\n\ndata: {\"b\":2}\r\n\r\ndata: [DONE]\n\n"
        var events: [SSEEvent] = []
        for byte in Data(text.utf8) {
            events += parser.feed(Data([byte]))
        }
        events += parser.finish()
        #expect(events.map(\.data) == ["{\"a\":1}", "{\"b\":2}", "[DONE]"])
        #expect(events.last?.isDone == true)
    }

    @Test func keepsMultibyteCharactersIntact() {
        var parser = SSEParser()
        let data = Data("data: héllo 👋\n\n".utf8)
        var events: [SSEEvent] = []
        for byte in data { events += parser.feed(Data([byte])) }
        #expect(events.first?.data == "héllo 👋")
    }

    @Test func tracksEventNames() {
        var parser = SSEParser()
        let events = parser.feed(Data("event: message_start\ndata: {}\n\nevent: ping\ndata: {\"type\":\"ping\"}\n\n".utf8))
        #expect(events.map(\.event) == ["message_start", "ping"])
    }

    @Test func passesBareJSONLines() {
        var parser = SSEParser()
        let events = parser.feed(Data("{\"choices\":[]}\n".utf8))
        #expect(events.first?.data == "{\"choices\":[]}")
    }
}

@Suite("Reasoning splitter")
struct ReasoningSplitterTests {
    static let thinkFormat = ReasoningFormat.tags(open: "<think>", close: "</think>", mayStartInside: false)

    @Test(arguments: [1, 2, 3, 5, 8, 100])
    func splitsTagsAtAnyChunkBoundary(size: Int) {
        let result = split("<think>Step one.\nStep two.</think>\n\nThe answer is 42.", format: Self.thinkFormat, size: size)
        #expect(result.reasoning == "Step one.\nStep two.")
        #expect(result.content.trimmingCharacters(in: .whitespacesAndNewlines) == "The answer is 42.")
    }

    @Test func leadingWhitespaceBeforeTag() {
        let result = split("\n\n<think>hmm</think>Answer", format: Self.thinkFormat, size: 3)
        #expect(result.reasoning == "hmm")
        #expect(result.content.hasSuffix("Answer"))
    }

    @Test func tagMentionedLaterIsContent() {
        let result = split("Use the <think> tag like this.", format: Self.thinkFormat, size: 4)
        #expect(result.reasoning.isEmpty)
        #expect(result.content == "Use the <think> tag like this.")
    }

    @Test(arguments: [1, 4, 9])
    func startInsideTemplatesReclassify(size: Int) {
        let format = ReasoningFormat.tags(open: "<think>", close: "</think>", mayStartInside: true)
        let result = split("I should add 2 and 2.</think>\n\nIt is 4.", format: format, size: size)
        #expect(result.reclassified)
        #expect(result.reasoning == "I should add 2 and 2.")
        #expect(result.content.trimmingCharacters(in: .whitespacesAndNewlines) == "It is 4.")
    }

    @Test func startInsideIgnoredWhenThinkingDisabled() {
        let format = ReasoningFormat.tags(open: "<think>", close: "</think>", mayStartInside: true)
        let result = split("Plain answer.", format: format, size: 3, thinkingDisabled: true)
        #expect(!result.reclassified)
        #expect(result.content == "Plain answer.")
    }

    @Test func bracketTags() {
        let format = ReasoningFormat.tags(open: "[THINK]", close: "[/THINK]", mayStartInside: false)
        let result = split("[THINK]Magistral thoughts[/THINK]Final.", format: format, size: 2)
        #expect(result.reasoning == "Magistral thoughts")
        #expect(result.content == "Final.")
    }

    @Test(arguments: [1, 3, 7, 50])
    func harmonyChannels(size: Int) {
        let text = "<|channel|>analysis<|message|>Thinking in harmony.<|end|><|start|>assistant<|channel|>final<|message|>Harmony answer.<|return|>"
        let result = split(text, format: .harmony, size: size)
        #expect(result.reasoning == "Thinking in harmony.")
        #expect(result.content == "Harmony answer.")
    }

    @Test(arguments: [1, 6])
    func autoDetectsCommonTags(size: Int) {
        #expect(split("<think>a</think>b", format: .auto, size: size).reasoning == "a")
        #expect(split("<thinking>c</thinking>d", format: .auto, size: size).reasoning == "c")
        #expect(split("<|channel|>analysis<|message|>e<|end|><|start|>assistant<|channel|>final<|message|>f", format: .auto, size: size).content == "f")
    }

    @Test func disabledPassesThrough() {
        var splitter = ReasoningSplitter(format: Self.thinkFormat, enabled: false)
        #expect(splitter.feed("<think>x</think>y") == [.content("<think>x</think>y")])
    }

    @Test func unterminatedReasoningIsFlushed() {
        let result = split("<think>never closed", format: Self.thinkFormat, size: 4)
        #expect(result.reasoning == "never closed")
    }
}

@Suite("Stream decoders")
struct StreamDecoderTests {
    @Test(arguments: [1, 13, 4096])
    func llamaCppReasoningProgressAndTimings(chunkSize: Int) throws {
        let events = try decodeFixture("llamacpp_reasoning", chunkSize: chunkSize, decoder: OpenAIStreamDecoderAdapter())
        #expect(events.reasoning == "Let me think.")
        #expect(events.content == "The answer is 4.")
        #expect(events.contains(.promptProgress(PromptProgress(processed: 120, total: 120, cached: 20, elapsedMs: 85.5))))
        #expect(events.contains { if case .serverTimings(let timings) = $0 { return timings.predictedN == 40 && timings.promptMs == 50 } else { return false } })
        #expect(events.last == .finished(.stop))
        #expect(events.first == .started(completionID: "chatcmpl-llama", model: "qwen3-8b"))
    }

    @Test func vllmReasoningFieldAndCachedUsage() throws {
        let events = try decodeFixture("vllm_reasoning", chunkSize: 9, decoder: OpenAIStreamDecoderAdapter())
        #expect(events.reasoning == "Thinking hard.")
        #expect(events.content == "Done.")
        #expect(events.contains(.usage(TokenUsage(promptTokens: 30, completionTokens: 12, cachedTokens: 16))))
    }

    @Test func mlxVlmRate() throws {
        let events = try decodeFixture("mlxvlm", chunkSize: 5, decoder: OpenAIStreamDecoderAdapter())
        #expect(events.content == "A red square.")
        #expect(events.contains { if case .serverTimings(let timings) = $0 { return timings.predictedPerSecond == 55.5 } else { return false } })
    }

    @Test func toolCallDeltas() throws {
        let events = try decodeFixture("tool_calls", chunkSize: 11, decoder: OpenAIStreamDecoderAdapter())
        var assembler = ToolCallAssembler()
        for event in events {
            if case .toolCallDelta(let index, let id, let name, let fragment) = event {
                assembler.apply(index: index, id: id, name: name, argumentsFragment: fragment)
            }
        }
        let calls = assembler.finalizedToolCalls()
        #expect(calls.count == 2)
        #expect(calls[0].id == "call_abc")
        #expect(calls[0].name == "get_current_time")
        #expect(calls[0].parsedArguments == ["timezone": "Asia/Tokyo"])
        #expect(calls[1].name == "echo")
        #expect(events.last == .finished(.toolCalls))
    }

    @Test func anthropicEvents() throws {
        let events = try decodeFixture("anthropic_thinking", chunkSize: 17, decoder: AnthropicStreamDecoder())
        #expect(events.reasoning == "Let me reason.")
        #expect(events.content == "Hello!")
        #expect(events.contains(.reasoningSignature("EqQB")))
        #expect(events.contains(.toolCallDelta(index: 2, id: "toolu_1", name: "echo", argumentsFragment: "")))
        #expect(events.contains(.usage(TokenUsage(promptTokens: 30, cachedTokens: 5))))
        #expect(events.last == .finished(.toolCalls))
    }

    @Test func midStreamErrorThrows() {
        #expect(throws: InferenceError.server("Context size has been exceeded.")) {
            _ = try decodeFixture("mid_stream_error", chunkSize: 8, decoder: OpenAIStreamDecoderAdapter())
        }
    }
}

@Suite("Stream accumulator")
struct StreamAccumulatorTests {
    @Test func buildsBlocksAndServerMetrics() throws {
        let events = try decodeFixture("llamacpp_reasoning", chunkSize: 64, decoder: OpenAIStreamDecoderAdapter())
        var accumulator = StreamAccumulator(splitter: ReasoningSplitter(format: .auto), requestStart: 0)
        var time = 0.1
        var changes: [AccumulatorChange] = []
        for event in events {
            changes += accumulator.apply(event, now: time)
            time += 0.1
        }
        #expect(accumulator.blocks.count == 2)
        guard case .thinking(let thought, let duration, _) = accumulator.blocks[0] else {
            Issue.record("expected thinking first")
            return
        }
        #expect(thought == "Let me think.")
        #expect((duration ?? 0) > 0)
        #expect(accumulator.currentText == "The answer is 4.")
        let metrics = accumulator.metrics
        #expect(metrics.promptTokens == 120)
        #expect(metrics.completionTokens == 40)
        #expect(metrics.cachedTokens == 20)
        #expect(metrics.promptSpeed?.isEstimate == false)
        #expect(abs((metrics.promptSpeed?.value ?? 0) - 2000) < 0.01)
        #expect(metrics.generationSpeed?.source == .server)
        #expect(abs((metrics.generationSpeed?.value ?? 0) - 40) < 0.01)
        #expect(metrics.ttftMs != nil)
        #expect(metrics.totalMs != nil)
        #expect(changes.contains { if case .thinkingFinished = $0 { return true } else { return false } })
    }

    @Test func clientMetricsWithoutServerTimings() {
        var accumulator = StreamAccumulator(splitter: ReasoningSplitter(format: .none), requestStart: 0)
        _ = accumulator.apply(.started(completionID: nil, model: nil), now: 0)
        for index in 0..<11 {
            _ = accumulator.apply(.contentDelta("x"), now: 0.5 + Double(index) * 0.1)
        }
        _ = accumulator.apply(.usage(TokenUsage(promptTokens: 50, completionTokens: 11)), now: 1.6)
        _ = accumulator.apply(.finished(.stop), now: 1.6)
        let metrics = accumulator.metrics
        #expect(abs((metrics.ttftMs ?? 0) - 500) < 0.01)
        #expect(metrics.promptSpeed?.isEstimate == true)
        #expect(abs((metrics.promptSpeed?.value ?? 0) - 100) < 0.01)
        #expect(metrics.generationSpeed?.source == .client)
        #expect(abs((metrics.generationSpeed?.value ?? 0) - 10) < 0.01)
        #expect(abs((metrics.averageSpeed ?? 0) - 11 / 1.6) < 0.01)
    }

    @Test func tagsInContentBecomeThinkingBlock() throws {
        let events = try decodeFixture("tags_in_content", chunkSize: 3, decoder: OpenAIStreamDecoderAdapter())
        var accumulator = StreamAccumulator(splitter: ReasoningSplitter(format: .auto))
        for event in events { _ = accumulator.apply(event) }
        #expect(accumulator.blocks.first == .thinking("Reasoning text", duration: accumulator.blocks.first.flatMap {
            if case .thinking(_, let duration, _) = $0 { return duration } else { return nil }
        }, signature: nil))
        #expect(accumulator.currentText == "Visible answer.")
    }

    @Test func reclassifyEmitsBlocksReplaced() {
        let format = ReasoningFormat.tags(open: "<think>", close: "</think>", mayStartInside: true)
        var accumulator = StreamAccumulator(splitter: ReasoningSplitter(format: format))
        var changes: [AccumulatorChange] = []
        changes += accumulator.apply(.contentDelta("Reasoning first"))
        changes += accumulator.apply(.contentDelta("</think>Then answer"))
        changes += accumulator.apply(.finished(.stop))
        #expect(changes.contains { if case .blocksReplaced = $0 { return true } else { return false } })
        #expect(accumulator.blocks.first?.isThinking == true)
        #expect(accumulator.currentText == "Then answer")
    }

    @Test func continuingAppendsToExistingText() {
        var accumulator = StreamAccumulator(continuing: [.text("Hello")], splitter: ReasoningSplitter(format: .none))
        _ = accumulator.apply(.contentDelta(", world"))
        #expect(accumulator.currentText == "Hello, world")
    }
}
