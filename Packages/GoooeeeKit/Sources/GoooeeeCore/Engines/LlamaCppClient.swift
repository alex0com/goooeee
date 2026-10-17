import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// llama.cpp `/props`.
public struct LlamaProps: Sendable, Hashable {
    public var contextLength: Int?
    public var defaultSampling: SamplingSettings
    public var vision: Bool?
    public var audio: Bool?
    public var chatTemplate: String?
    public var modelPath: String?
    public var isRouter: Bool
    public var buildInfo: String?
    public var totalSlots: Int?

    public init(json: JSONValue) {
        let settings = json["default_generation_settings"]
        contextLength = settings?["n_ctx"]?.intValue ?? json["n_ctx"]?.intValue
        var sampling = SamplingSettings()
        if let params = settings?["params"] {
            let mapping: [(String, SamplingKey)] = [
                ("temperature", .temperature), ("top_k", .topK), ("top_p", .topP), ("min_p", .minP),
                ("typ_p", .typicalP), ("repeat_penalty", .repeatPenalty), ("repeat_last_n", .repeatLastN),
                ("presence_penalty", .presencePenalty), ("frequency_penalty", .frequencyPenalty),
                ("dynatemp_range", .dynatempRange), ("dynatemp_exponent", .dynatempExponent),
                ("xtc_probability", .xtcProbability), ("xtc_threshold", .xtcThreshold),
                ("dry_multiplier", .dryMultiplier), ("dry_base", .dryBase),
                ("dry_allowed_length", .dryAllowedLength), ("dry_penalty_last_n", .dryPenaltyLastN),
                ("samplers", .samplers), ("max_tokens", .maxTokens),
            ]
            for (wire, key) in mapping {
                if let value = params[wire], let sample = SamplingValue(json: value, for: key) {
                    sampling[key] = sample
                }
            }
        }
        defaultSampling = sampling
        vision = json["modalities"]?["vision"]?.boolValue
        audio = json["modalities"]?["audio"]?.boolValue
        chatTemplate = json["chat_template"]?.stringValue
        modelPath = json["model_path"]?.stringValue
        isRouter = json["role"]?.stringValue == "router"
        buildInfo = json["build_info"]?.stringValue
        totalSlots = json["total_slots"]?.intValue
    }
}

/// A llama.cpp server tool from `GET /tools`.
public struct LlamaServerTool: Sendable, Hashable {
    public var name: String
    public var displayName: String
    public var definition: JSONValue
    public var canWrite: Bool
    public var usesWorkingDirectory: Bool

    public var toolDefinition: ToolDefinition {
        let function = definition["function"] ?? definition
        return ToolDefinition(
            name: name,
            originalName: name,
            title: displayName,
            description: function["description"]?.stringValue,
            parameters: function["parameters"] ?? ["type": "object", "properties": [:]],
            sourceKind: .serverTools,
            sourceID: "llama-server",
            sourceName: "llama-server",
            readOnlyHint: !canWrite,
            destructiveHint: canWrite,
            usesWorkingDirectory: usesWorkingDirectory
        )
    }
}

/// llama.cpp-specific endpoints that the OpenAI API doesn't cover.
public struct LlamaCppClient: Sendable {
    public var connection: ServerConnection
    public var apiKey: String?
    public var http: HTTPClient

    public init(connection: ServerConnection, apiKey: String?, http: HTTPClient = URLSessionHTTPClient.shared) {
        self.connection = connection
        self.apiKey = apiKey
        self.http = http
    }

    private func request(_ url: URL, method: String = "GET", body: JSONValue? = nil, timeout: TimeInterval = 15) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        RequestHeaders.apply(to: &request, connection: connection, apiKey: apiKey)
        if let body { request.httpBody = try body.encoded() }
        return request
    }

    private func json(_ request: URLRequest) async throws -> JSONValue {
        let (data, response) = try await http.data(for: request)
        guard response.isSuccess else { throw InferenceError.fromHTTP(status: response.statusCode, body: data) }
        return try JSONValue.parse(data)
    }

    /// `GET /health`: `true` when ready, `false` while loading (503).
    public func health() async throws -> Bool {
        let (data, response) = try await http.data(for: try request(connection.rootURL("/health"), timeout: 5))
        if response.statusCode == 503 { return false }
        guard response.isSuccess else { throw InferenceError.fromHTTP(status: response.statusCode, body: data) }
        return true
    }

    public func props(model: String? = nil) async throws -> LlamaProps {
        var url = connection.rootURL("/props")
        if let model, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = [URLQueryItem(name: "model", value: model)]
            url = components.url ?? url
        }
        return LlamaProps(json: try await json(try request(url)))
    }

    /// Ends the reasoning phase of a running completion (`reasoning_control` must be on).
    public func stopReasoning(completionID: String, model: String?) async throws -> Bool {
        var body: [String: JSONValue] = ["action": "reasoning_end", "id": .string(completionID)]
        if let model { body["model"] = .string(model) }
        let result = try await json(try request(connection.apiURL("/chat/completions/control"), method: "POST", body: .object(body)))
        return result["success"]?.boolValue ?? false
    }

    /// Router mode model list (`GET /models`), with load state.
    public func routerModels() async throws -> [RemoteModel] {
        let (data, response) = try await http.data(for: try request(connection.rootURL("/models")))
        guard response.isSuccess else { throw InferenceError.fromHTTP(status: response.statusCode, body: data) }
        return try ModelListParser.parse(data)
    }

    public func loadModel(_ model: String) async throws {
        _ = try await json(try request(connection.rootURL("/models/load"), method: "POST", body: ["model": .string(model)], timeout: 600))
    }

    public func unloadModel(_ model: String) async throws {
        _ = try await json(try request(connection.rootURL("/models/unload"), method: "POST", body: ["model": .string(model)]))
    }

    /// Server tools from `GET /tools` (llama-server `--tools` / `--mcp-servers-config`).
    public func tools() async throws -> [LlamaServerTool] {
        let result = try await json(try request(connection.rootURL("/tools")))
        return (result.arrayValue ?? []).compactMap { entry in
            guard let name = entry["tool"]?.stringValue else { return nil }
            return LlamaServerTool(
                name: name,
                displayName: entry["display_name"]?.stringValue ?? name,
                definition: entry["definition"] ?? .object([:]),
                canWrite: entry["permissions"]?["write"]?.boolValue ?? false,
                usesWorkingDirectory: entry["uses_cwd"]?.boolValue ?? false
            )
        }
    }

    /// Runs a server tool (`POST /tools`). The working directory goes in `x-tool-cwd`.
    public func executeTool(name: String, arguments: JSONValue, workingDirectory: String?, timeout: TimeInterval = 300) async throws -> ToolResult {
        var urlRequest = try request(connection.rootURL("/tools"), method: "POST", body: ["tool": .string(name), "params": arguments], timeout: timeout)
        if let workingDirectory { urlRequest.setValue(workingDirectory, forHTTPHeaderField: "x-tool-cwd") }
        let (data, response) = try await http.data(for: urlRequest)
        guard response.isSuccess else {
            return .text(InferenceError.extractMessage(from: data) ?? "HTTP \(response.statusCode)", isError: true)
        }
        let result = (try? JSONValue.parse(data)) ?? .string(String(decoding: data, as: UTF8.self))
        if let error = result["error"], !error.isNull {
            return .text(error.stringValue ?? error.encodedString(), isError: true)
        }
        if let text = result["plain_text_response"]?.stringValue {
            return .text(text)
        }
        return .text(result.stringValue ?? result.encodedString(pretty: true))
    }

    /// The prompt the server would build for these messages (`POST /apply-template`).
    public func applyTemplate(messages: [ChatMessage]) async throws -> String {
        let body: JSONValue = ["messages": .array(OpenAIRequestBuilder.messagesJSON(messages, supportsVision: false, engine: .llamaCpp))]
        let result = try await json(try request(connection.rootURL("/apply-template"), method: "POST", body: body))
        return result["prompt"]?.stringValue ?? ""
    }
}
