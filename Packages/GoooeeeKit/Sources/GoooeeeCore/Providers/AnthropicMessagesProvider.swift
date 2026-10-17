import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Builds `/v1/messages` request bodies for Anthropic's API.
public struct AnthropicRequestBuilder: Sendable {
    public var connection: ServerConnection
    public var apiKey: String?
    public static let defaultMaxTokens = 8192

    public init(connection: ServerConnection, apiKey: String?) {
        self.connection = connection
        self.apiKey = apiKey
    }

    public func urlRequest(for request: ChatRequest) throws -> URLRequest {
        var urlRequest = URLRequest(url: connection.apiURL("/messages"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = connection.requestTimeout
        RequestHeaders.apply(to: &urlRequest, connection: connection, apiKey: apiKey, accept: request.stream ? "text/event-stream" : "application/json")
        urlRequest.httpBody = try body(for: request).encoded()
        return urlRequest
    }

    public func body(for request: ChatRequest) throws -> JSONValue {
        guard let model = request.model, !model.isEmpty else {
            throw InferenceError.invalidRequest("Choose a model for this workspace first.")
        }
        let settings = request.settings
        let sampling = settings.sentSampling
        var maxTokens = AnthropicRequestBuilder.defaultMaxTokens
        if case .int(let value)? = sampling[.maxTokens]?.normalized(for: .maxTokens), value > 0 {
            maxTokens = value
        }

        var body: [String: JSONValue] = [
            "model": .string(model),
            "stream": .bool(request.stream),
        ]

        let system = request.messages.filter { $0.role == .system }.map(\.text).joined(separator: "\n\n")
        if !system.isEmpty { body["system"] = .string(system) }
        body["messages"] = .array(Self.messagesJSON(request.messages.filter { $0.role != .system }, supportsVision: request.supportsVision))

        let thinkingBudget = settings.thinking.isEnabled == true ? settings.thinking.anthropicBudgetTokens : nil
        if let budget = thinkingBudget {
            body["thinking"] = ["type": "enabled", "budget_tokens": .int(budget)]
            maxTokens = max(maxTokens, budget + 4096)
        } else {
            // Sampling parameters are only allowed without extended thinking.
            if let value = sampling[.temperature]?.doubleValue { body["temperature"] = .double(min(value, 1)) }
            if let value = sampling[.topP]?.doubleValue { body["top_p"] = .double(value) }
            if case .int(let value)? = sampling[.topK]?.normalized(for: .topK), value > 0 { body["top_k"] = .int(value) }
        }
        body["max_tokens"] = .int(maxTokens)
        if case .strings(let stops)? = sampling[.stop], !stops.isEmpty {
            body["stop_sequences"] = .array(stops.map(JSONValue.string))
        }
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map(\.anthropicJSON))
        }

        var result = JSONValue.object(body)
        if let extra = settings.extraBody { result = result.merging(extra) }
        return result
    }

    /// Anthropic messages: alternating user/assistant, tool results inside user messages.
    public static func messagesJSON(_ messages: [ChatMessage], supportsVision: Bool) -> [JSONValue] {
        var output: [(role: String, blocks: [JSONValue])] = []

        func append(_ role: String, _ blocks: [JSONValue]) {
            guard !blocks.isEmpty else { return }
            if let last = output.last, last.role == role {
                output[output.count - 1].blocks.append(contentsOf: blocks)
            } else {
                output.append((role, blocks))
            }
        }

        for message in messages {
            switch message.role {
            case .system:
                continue
            case .user:
                var blocks: [JSONValue] = []
                for part in message.content {
                    switch part {
                    case .text(let text) where !text.isEmpty:
                        blocks.append(["type": "text", "text": .string(text)])
                    case .image(let data, let mimeType) where supportsVision:
                        blocks.append([
                            "type": "image",
                            "source": ["type": "base64", "media_type": .string(mimeType), "data": .string(data.base64EncodedString())],
                        ])
                    default:
                        continue
                    }
                }
                append("user", blocks)
            case .assistant:
                var blocks: [JSONValue] = []
                if let reasoning = message.reasoning, !reasoning.isEmpty, let signature = message.reasoningSignature {
                    blocks.append(["type": "thinking", "thinking": .string(reasoning), "signature": .string(signature)])
                }
                let text = message.text
                if !text.isEmpty { blocks.append(["type": "text", "text": .string(text)]) }
                for call in message.toolCalls {
                    blocks.append([
                        "type": "tool_use",
                        "id": .string(call.id),
                        "name": .string(call.name),
                        "input": call.parsedArguments ?? .object([:]),
                    ])
                }
                append("assistant", blocks)
            case .tool:
                append("user", [[
                    "type": "tool_result",
                    "tool_use_id": .string(message.toolCallID ?? ""),
                    "content": .string(message.text),
                ]])
            }
        }
        return output.map { ["role": .string($0.role), "content": .array($0.blocks)] }
    }
}

/// Decodes Anthropic SSE events.
public struct AnthropicStreamDecoder: StreamDecoding, Sendable {
    private var finishReason: String?
    private var toolBlockIndexes = Set<Int>()

    public init() {}

    public mutating func decode(_ event: SSEEvent) throws -> [StreamEvent] {
        guard let json = try? JSONValue.parse(event.data) else { return [] }
        let type = json["type"]?.stringValue ?? event.event ?? ""
        switch type {
        case "message_start":
            let message = json["message"]
            var events: [StreamEvent] = [.started(completionID: message?["id"]?.stringValue, model: message?["model"]?.stringValue)]
            if let usage = message?["usage"] {
                let input = usage["input_tokens"]?.intValue ?? 0
                let cacheRead = usage["cache_read_input_tokens"]?.intValue ?? 0
                let cacheWrite = usage["cache_creation_input_tokens"]?.intValue ?? 0
                events.append(.usage(TokenUsage(promptTokens: input + cacheRead + cacheWrite, cachedTokens: cacheRead)))
            }
            return events
        case "content_block_start":
            let index = json["index"]?.intValue ?? 0
            let block = json["content_block"]
            if block?["type"]?.stringValue == "tool_use" {
                toolBlockIndexes.insert(index)
                return [.toolCallDelta(index: index, id: block?["id"]?.stringValue, name: block?["name"]?.stringValue, argumentsFragment: "")]
            }
            if block?["type"]?.stringValue == "text", let text = block?["text"]?.stringValue, !text.isEmpty {
                return [.contentDelta(text)]
            }
            return []
        case "content_block_delta":
            let index = json["index"]?.intValue ?? 0
            let delta = json["delta"]
            switch delta?["type"]?.stringValue {
            case "text_delta": return delta?["text"]?.stringValue.map { [.contentDelta($0)] } ?? []
            case "thinking_delta": return delta?["thinking"]?.stringValue.map { [.reasoningDelta($0)] } ?? []
            case "signature_delta": return delta?["signature"]?.stringValue.map { [.reasoningSignature($0)] } ?? []
            case "input_json_delta":
                return [.toolCallDelta(index: index, id: nil, name: nil, argumentsFragment: delta?["partial_json"]?.stringValue ?? "")]
            default: return []
            }
        case "message_delta":
            if let reason = json["delta"]?["stop_reason"]?.stringValue { finishReason = reason }
            if let output = json["usage"]?["output_tokens"]?.intValue {
                return [.usage(TokenUsage(completionTokens: output))]
            }
            return []
        case "error":
            throw InferenceError.server(json["error"]?["message"]?.stringValue ?? "Anthropic API error")
        default:
            return []
        }
    }

    public mutating func finish() -> [StreamEvent] {
        [.finished(FinishReason(wire: finishReason ?? "end_turn"))]
    }
}

public struct AnthropicMessagesProvider: InferenceProvider {
    public var connection: ServerConnection
    public var apiKey: String?
    public var http: HTTPClient

    public init(connection: ServerConnection, apiKey: String?, http: HTTPClient = URLSessionHTTPClient.shared) {
        self.connection = connection
        self.apiKey = apiKey
        self.http = http
    }

    public func makeURLRequest(_ request: ChatRequest) throws -> URLRequest {
        try AnthropicRequestBuilder(connection: connection, apiKey: apiKey).urlRequest(for: request)
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        let urlRequest: URLRequest
        do {
            urlRequest = try makeURLRequest(request)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return SSEStreamRunner.run(urlRequest: urlRequest, http: http) { AnthropicStreamDecoder() }
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
