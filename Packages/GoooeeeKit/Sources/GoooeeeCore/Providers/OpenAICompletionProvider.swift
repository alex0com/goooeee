import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Last-resort provider: renders the prompt with a user-loaded Jinja template and calls `/v1/completions`.
public struct OpenAICompletionProvider: InferenceProvider {
    public var connection: ServerConnection
    public var apiKey: String?
    public var http: HTTPClient

    public init(connection: ServerConnection, apiKey: String?, http: HTTPClient = URLSessionHTTPClient.shared) {
        self.connection = connection
        self.apiKey = apiKey
        self.http = http
    }

    public func body(for request: ChatRequest) throws -> JSONValue {
        guard let template = connection.chatTemplate else {
            throw InferenceError.invalidRequest("This connection has no chat template loaded.")
        }
        let engine = connection.engine
        let capabilities = engine.capabilities
        var messages = request.messages
        var addGenerationPrompt = true
        if request.continueFinalMessage, messages.last?.role == .assistant {
            addGenerationPrompt = false
        }
        let thinking = ThinkingTranslator.translate(level: request.settings.thinking, profile: request.settings.profile, engine: engine)
        if let suffix = thinking.systemPromptSuffix {
            if let index = messages.firstIndex(where: { $0.role == .system }) {
                messages[index].content.append(.text(suffix))
            } else {
                messages.insert(.text(.system, suffix), at: 0)
            }
        }
        var prompt = try ChatTemplateRenderer.render(
            template: template,
            messages: messages,
            tools: request.tools,
            addGenerationPrompt: addGenerationPrompt,
            enableThinking: request.settings.thinking.isEnabled
        )
        if !addGenerationPrompt, !template.eosToken.isEmpty, prompt.hasSuffix(template.eosToken) {
            prompt.removeLast(template.eosToken.count)
        }

        var body: [String: JSONValue] = ["prompt": .string(prompt), "stream": .bool(request.stream)]
        if let model = request.model, !model.isEmpty { body["model"] = .string(model) }
        if request.stream && capabilities.streamOptionsUsage { body["stream_options"] = ["include_usage": true] }

        var stops = template.stopTokens
        if !template.eosToken.isEmpty, !stops.contains(template.eosToken) { stops.append(template.eosToken) }
        for (key, value) in request.settings.sentSampling.values where capabilities.samplingKeys.contains(key) {
            if key == .stop, case .strings(let userStops) = value {
                stops.append(contentsOf: userStops)
                continue
            }
            if key == .maxTokens, case .int(let count) = value.normalized(for: key), count <= 0 { continue }
            body[capabilities.wireName(for: key)] = value.normalized(for: key).jsonValue
        }
        if !stops.isEmpty { body["stop"] = .array(stops.map(JSONValue.string)) }
        if capabilities.llamaCppExtras && request.stream {
            body["return_progress"] = true
        }
        var result = JSONValue.object(body)
        if let extra = request.settings.extraBody { result = result.merging(extra) }
        return result
    }

    public func makeURLRequest(_ request: ChatRequest) throws -> URLRequest {
        var urlRequest = URLRequest(url: connection.apiURL("/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = connection.requestTimeout
        RequestHeaders.apply(to: &urlRequest, connection: connection, apiKey: apiKey, accept: request.stream ? "text/event-stream" : "application/json")
        urlRequest.httpBody = try body(for: request).encoded()
        return urlRequest
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
        try await OpenAIChatProvider(connection: connection, apiKey: apiKey, http: http).listModels()
    }
}

/// Creates the provider for a connection's API style.
public enum ProviderFactory {
    public static func make(connection: ServerConnection, apiKey: String?, http: HTTPClient = URLSessionHTTPClient.shared) -> InferenceProvider {
        switch connection.apiStyle {
        case .openAIChat:
            OpenAIChatProvider(connection: connection, apiKey: apiKey, http: http)
        case .openAICompletion:
            OpenAICompletionProvider(connection: connection, apiKey: apiKey, http: http)
        case .anthropicMessages:
            AnthropicMessagesProvider(connection: connection, apiKey: apiKey, http: http)
        }
    }
}
