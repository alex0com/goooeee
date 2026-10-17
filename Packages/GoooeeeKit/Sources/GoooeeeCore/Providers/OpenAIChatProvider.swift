import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Common request headers.
enum RequestHeaders {
    static func apply(to request: inout URLRequest, connection: ServerConnection, apiKey: String?, accept: String = "application/json") {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty {
            if connection.apiStyle == .anthropicMessages {
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            } else {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
        }
        if connection.apiStyle == .anthropicMessages {
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        for (name, value) in connection.extraHeaders where !name.isEmpty {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }
}

/// Builds `/v1/chat/completions` request bodies for any OpenAI-compatible engine.
public struct OpenAIRequestBuilder: Sendable {
    public var connection: ServerConnection
    public var apiKey: String?

    public init(connection: ServerConnection, apiKey: String?) {
        self.connection = connection
        self.apiKey = apiKey
    }

    public func urlRequest(for request: ChatRequest) throws -> URLRequest {
        var urlRequest = URLRequest(url: connection.apiURL("/chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = connection.requestTimeout
        RequestHeaders.apply(to: &urlRequest, connection: connection, apiKey: apiKey, accept: request.stream ? "text/event-stream" : "application/json")
        urlRequest.httpBody = try body(for: request).encoded()
        return urlRequest
    }

    public func body(for request: ChatRequest) throws -> JSONValue {
        let engine = connection.engine
        let capabilities = engine.capabilities
        let settings = request.settings
        let thinking = ThinkingTranslator.translate(level: settings.thinking, profile: settings.profile, engine: engine)

        var messages = request.messages
        if let suffix = thinking.systemPromptSuffix {
            if let index = messages.firstIndex(where: { $0.role == .system }) {
                messages[index].content.append(.text(suffix))
            } else {
                messages.insert(.text(.system, suffix), at: 0)
            }
        }

        var body: [String: JSONValue] = [
            "messages": .array(Self.messagesJSON(messages, supportsVision: request.supportsVision, engine: engine)),
            "stream": .bool(request.stream),
        ]
        if let model = request.model, !model.isEmpty { body["model"] = .string(model) }
        if request.stream && capabilities.streamOptionsUsage {
            body["stream_options"] = ["include_usage": true]
        }

        for (key, value) in settings.sentSampling.values where capabilities.samplingKeys.contains(key) {
            if key == .maxTokens {
                let tokens = value.normalized(for: .maxTokens)
                if case .int(let count) = tokens, count <= 0 {
                    if engine == .llamaCpp { body[capabilities.wireName(for: key)] = .int(-1) }
                    continue
                }
            }
            body[capabilities.wireName(for: key)] = value.normalized(for: key).jsonValue
        }

        for (key, value) in thinking.body { body[key] = value }

        if capabilities.llamaCppExtras {
            body["reasoning_format"] = .string(request.disableReasoningParsing ? "none" : "auto")
            if request.stream {
                body["return_progress"] = true
                body["reasoning_control"] = true
                body["sse_ping_interval"] = 1
            }
        }

        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map(\.openAIJSON))
        }

        if request.continueFinalMessage && capabilities.continueFinalMessage {
            body["continue_final_message"] = true
            body["add_generation_prompt"] = false
        }

        var result = JSONValue.object(body)
        if let extra = settings.extraBody {
            result = result.merging(extra)
        }
        return result
    }

    /// OpenAI chat messages. Reasoning sent back uses `reasoning_content` on llama.cpp and inline `<think>` tags elsewhere.
    public static func messagesJSON(_ messages: [ChatMessage], supportsVision: Bool, engine: EngineKind) -> [JSONValue] {
        messages.map { message in
            var object: [String: JSONValue] = ["role": .string(message.role.rawValue)]
            switch message.role {
            case .system:
                object["content"] = .string(message.text)
            case .user:
                let parts = message.content.filter { supportsVision || !$0.isImage }
                if parts.contains(where: \.isImage) {
                    object["content"] = .array(parts.map(partJSON))
                } else {
                    object["content"] = .string(parts.compactMap { if case .text(let text) = $0 { return text } else { return nil } }.joined(separator: "\n\n"))
                }
            case .assistant:
                var text = message.text
                if let reasoning = message.reasoning, !reasoning.isEmpty {
                    if engine == .llamaCpp {
                        object["reasoning_content"] = .string(reasoning)
                    } else {
                        text = "<think>\n\(reasoning)\n</think>\n\n" + text
                    }
                }
                if !message.toolCalls.isEmpty {
                    object["content"] = text.isEmpty ? .null : .string(text)
                    object["tool_calls"] = .array(message.toolCalls.map { call in
                        [
                            "id": .string(call.id),
                            "type": "function",
                            "function": ["name": .string(call.name), "arguments": .string(call.arguments.isEmpty ? "{}" : call.arguments)],
                        ]
                    })
                } else {
                    object["content"] = .string(text)
                }
            case .tool:
                object["content"] = .string(message.text)
                if let id = message.toolCallID { object["tool_call_id"] = .string(id) }
            }
            return .object(object)
        }
    }

    static func partJSON(_ part: ChatContentPart) -> JSONValue {
        switch part {
        case .text(let text):
            return ["type": "text", "text": .string(text)]
        case .image(let data, let mimeType):
            return ["type": "image_url", "image_url": ["url": .string("data:\(mimeType);base64,\(data.base64EncodedString())")]]
        }
    }
}

/// Turns OpenAI-compatible stream chunks into `StreamEvent`s.
///
/// Accepts the field variants used by different engines: `reasoning_content` (llama.cpp,
/// LM Studio), `reasoning` (vLLM, Ollama), `thinking`; `timings` and `prompt_progress`
/// (llama.cpp); `timings.predicted_per_second` (mlx-vlm); usage in a trailing chunk.
public struct OpenAIStreamDecoder: Sendable {
    private var started = false
    private var finishReason: String?

    public init() {}

    public mutating func decode(_ event: SSEEvent) throws -> [StreamEvent] {
        if event.isDone { return [] }
        let trimmed = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let json = try? JSONValue.parse(trimmed) else { return [] }
        return try decode(json)
    }

    public mutating func decode(_ json: JSONValue) throws -> [StreamEvent] {
        if let error = json["error"], !error.isNull {
            let message = error["message"]?.stringValue ?? error.stringValue ?? error.encodedString()
            throw InferenceError.server(message)
        }
        var events: [StreamEvent] = []
        if !started {
            started = true
            events.append(.started(completionID: json["id"]?.stringValue, model: json["model"]?.stringValue))
        }
        if let progress = json["prompt_progress"], let total = progress["total"]?.intValue {
            events.append(.promptProgress(PromptProgress(
                processed: progress["processed"]?.intValue ?? 0,
                total: total,
                cached: progress["cache"]?.intValue ?? 0,
                elapsedMs: progress["time_ms"]?.doubleValue ?? 0
            )))
        }
        if let choice = json["choices"]?[0] {
            let delta = choice["delta"] ?? choice["message"]
            if let delta {
                for key in ["reasoning_content", "reasoning", "thinking"] {
                    if let text = delta[key]?.stringValue, !text.isEmpty {
                        events.append(.reasoningDelta(text))
                        break
                    }
                }
                if let text = delta["content"]?.stringValue, !text.isEmpty {
                    events.append(.contentDelta(text))
                }
                if let calls = delta["tool_calls"]?.arrayValue {
                    for (position, call) in calls.enumerated() {
                        events.append(.toolCallDelta(
                            index: call["index"]?.intValue ?? position,
                            id: call["id"]?.stringValue,
                            name: call["function"]?["name"]?.stringValue,
                            argumentsFragment: Self.argumentsFragment(call["function"]?["arguments"])
                        ))
                    }
                }
            }
            if let text = choice["text"]?.stringValue, !text.isEmpty {
                // /v1/completions chunks
                events.append(.contentDelta(text))
            }
            if let reason = choice["finish_reason"]?.stringValue {
                finishReason = reason
            }
        }
        if let usage = json["usage"], !usage.isNull {
            events.append(.usage(TokenUsage(
                promptTokens: usage["prompt_tokens"]?.intValue,
                completionTokens: usage["completion_tokens"]?.intValue,
                cachedTokens: usage["prompt_tokens_details"]?["cached_tokens"]?.intValue,
                reasoningTokens: usage["completion_tokens_details"]?["reasoning_tokens"]?.intValue
            )))
        }
        if let timings = json["timings"], !timings.isNull {
            events.append(.serverTimings(ServerTimings(
                promptN: timings["prompt_n"]?.intValue,
                promptMs: timings["prompt_ms"]?.doubleValue,
                predictedN: timings["predicted_n"]?.intValue,
                predictedMs: timings["predicted_ms"]?.doubleValue,
                cacheN: timings["cache_n"]?.intValue,
                predictedPerSecond: timings["predicted_per_second"]?.doubleValue
            )))
        }
        return events
    }

    public mutating func finish() -> [StreamEvent] {
        [.finished(FinishReason(wire: finishReason ?? "stop"))]
    }

    static func argumentsFragment(_ value: JSONValue?) -> String {
        guard let value else { return "" }
        if let string = value.stringValue { return string }
        if value.isNull { return "" }
        return value.encodedString()
    }
}

/// `/v1/chat/completions` provider. The default for every engine.
public struct OpenAIChatProvider: InferenceProvider {
    public var connection: ServerConnection
    public var apiKey: String?
    public var http: HTTPClient

    public init(connection: ServerConnection, apiKey: String?, http: HTTPClient = URLSessionHTTPClient.shared) {
        self.connection = connection
        self.apiKey = apiKey
        self.http = http
    }

    public func makeURLRequest(_ request: ChatRequest) throws -> URLRequest {
        try OpenAIRequestBuilder(connection: connection, apiKey: apiKey).urlRequest(for: request)
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        let urlRequest: URLRequest
        do {
            urlRequest = try makeURLRequest(request)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return SSEStreamRunner.run(urlRequest: urlRequest, http: http) { OpenAIStreamDecoderAdapter() }
    }

    public func listModels() async throws -> [RemoteModel] {
        var urlRequest = URLRequest(url: connection.apiURL("/models"))
        urlRequest.timeoutInterval = 15
        RequestHeaders.apply(to: &urlRequest, connection: connection, apiKey: apiKey)
        let (data, response) = try await http.data(for: urlRequest)
        guard response.isSuccess else { throw InferenceError.fromHTTP(status: response.statusCode, body: data) }
        return try ModelListParser.parse(data)
    }
}

/// Parses `/v1/models` responses (OpenAI, llama.cpp router, vLLM, Ollama, LM Studio, mlx).
public enum ModelListParser {
    public static func parse(_ data: Data) throws -> [RemoteModel] {
        let json = try JSONValue.parse(data)
        let entries = json["data"]?.arrayValue ?? json["models"]?.arrayValue ?? json.arrayValue ?? []
        return entries.compactMap { entry in
            guard let id = entry["id"]?.stringValue ?? entry["name"]?.stringValue ?? entry["model"]?.stringValue else { return nil }
            var model = RemoteModel(id: id, ownedBy: entry["owned_by"]?.stringValue)
            model.contextLength = entry["max_model_len"]?.intValue
                ?? entry["context_length"]?.intValue
                ?? entry["meta"]?["n_ctx_train"]?.intValue
                ?? entry["max_context_length"]?.intValue
            if let status = entry["status"] {
                let value = status["value"]?.stringValue ?? status.stringValue
                model.loadState = value.flatMap(ModelLoadState.init(rawValue:)) ?? .unknown
            } else if let loaded = entry["loaded"]?.boolValue {
                model.loadState = loaded ? .loaded : .unloaded
            }
            model.aliases = entry["aliases"]?.arrayValue?.compactMap(\.stringValue) ?? []
            model.inputModalities = entry["architecture"]?["input_modalities"]?.arrayValue?.compactMap(\.stringValue)
            return model
        }
    }
}

/// Adapts a decoder to the shared stream runner.
protocol StreamDecoding: Sendable {
    mutating func decode(_ event: SSEEvent) throws -> [StreamEvent]
    mutating func finish() -> [StreamEvent]
}

struct OpenAIStreamDecoderAdapter: StreamDecoding {
    var decoder = OpenAIStreamDecoder()
    mutating func decode(_ event: SSEEvent) throws -> [StreamEvent] { try decoder.decode(event) }
    mutating func finish() -> [StreamEvent] { decoder.finish() }
}

/// Runs an SSE request and feeds it through a decoder.
enum SSEStreamRunner {
    static func run<Decoder: StreamDecoding>(
        urlRequest: URLRequest,
        http: HTTPClient,
        makeDecoder: @escaping @Sendable () -> Decoder
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (response, bytes) = try await http.stream(for: urlRequest)
                    if !response.isSuccess {
                        var body = Data()
                        for try await chunk in bytes {
                            body.append(chunk)
                            if body.count > 65_536 { break }
                        }
                        throw InferenceError.fromHTTP(status: response.statusCode, body: body)
                    }
                    var parser = SSEParser()
                    var decoder = makeDecoder()
                    for try await chunk in bytes {
                        try Task.checkCancellation()
                        for event in parser.feed(chunk) {
                            for output in try decoder.decode(event) { continuation.yield(output) }
                        }
                    }
                    for event in parser.finish() {
                        for output in try decoder.decode(event) { continuation.yield(output) }
                    }
                    for output in decoder.finish() { continuation.yield(output) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: InferenceError.from(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
