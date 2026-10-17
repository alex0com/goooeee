import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CurlExample: Identifiable, Sendable, Hashable {
    public var id: String
    public var title: String
    public var command: String
    public var note: String?

    public init(id: String, title: String, command: String, note: String? = nil) {
        self.id = id
        self.title = title
        self.command = command
        self.note = note
    }
}

/// Renders the app's real requests as curl commands.
public enum CurlRenderer {
    public static let keyPlaceholder = "$GOOOEEE_API_KEY"

    /// Renders a request. With `revealKey == false` the API key is replaced by `$GOOOEEE_API_KEY`.
    public static func render(_ request: URLRequest, revealKey: Bool = false) -> String {
        let method = request.httpMethod ?? "GET"
        let streaming = request.value(forHTTPHeaderField: "Accept") == "text/event-stream"
        var lines = ["curl -sS" + (streaming ? " -N" : "") + (method == "GET" ? "" : " -X \(method)") + " \(quote(request.url?.absoluteString ?? ""))"]
        let headers = (request.allHTTPHeaderFields ?? [:]).sorted { $0.key.lowercased() < $1.key.lowercased() }
        for (name, value) in headers {
            if name.lowercased() == "accept" && !streaming { continue }
            var shown = value
            if !revealKey {
                if name.lowercased() == "authorization", value.hasPrefix("Bearer ") {
                    shown = "Bearer \(keyPlaceholder)"
                } else if name.lowercased() == "x-api-key" {
                    shown = keyPlaceholder
                }
            }
            // Double quotes so $GOOOEEE_API_KEY expands in the shell.
            let needsExpansion = shown.contains(keyPlaceholder)
            lines.append("  -H " + (needsExpansion ? doubleQuote("\(name): \(shown)") : quote("\(name): \(shown)")))
        }
        if let body = request.httpBody, !body.isEmpty {
            let pretty = (try? JSONValue.parse(body).encodedString(pretty: true)) ?? String(decoding: body, as: UTF8.self)
            lines.append("  --data-binary @- <<'JSON'\n\(pretty)\nJSON")
            return lines.joined(separator: " \\\n")
        }
        return lines.joined(separator: " \\\n")
    }

    static func quote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func doubleQuote(_ string: String) -> String {
        "\"" + string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "`", with: "\\`") + "\""
    }

    /// A 1×1 PNG used in the image example and the vision test.
    public static let tinyPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    /// Example tool for the tool-calling example and test.
    public static let exampleTool = ToolDefinition(
        name: "get_current_time",
        description: "Returns the current time in a given IANA time zone.",
        parameters: [
            "type": "object",
            "properties": ["timezone": ["type": "string", "description": "IANA time zone, e.g. Europe/Paris"]],
            "required": ["timezone"],
        ],
        sourceKind: .mcp,
        sourceID: "example",
        sourceName: "example"
    )

    /// The curl examples shown in a connection's **curl** tab.
    public static func examples(
        connection: ServerConnection,
        apiKey: String?,
        model: String?,
        settings: EffectiveSettings,
        revealKey: Bool = false
    ) -> [CurlExample] {
        let effectiveKey = apiKey ?? (connection.engine.requiresAPIKey ? "KEY" : nil)
        let provider = ProviderFactory.make(connection: connection, apiKey: effectiveKey)
        var examples: [CurlExample] = []
        func add(_ id: String, _ title: String, _ request: URLRequest?, note: String? = nil) {
            guard let request else { return }
            examples.append(CurlExample(id: id, title: title, command: render(request, revealKey: revealKey), note: note))
        }
        func get(_ url: URL) -> URLRequest {
            var request = URLRequest(url: url)
            RequestHeaders.apply(to: &request, connection: connection, apiKey: effectiveKey)
            request.setValue(nil, forHTTPHeaderField: "Content-Type")
            return request
        }

        add("models", "List models", get(connection.apiURL("/models")))

        let hello = [ChatMessage.text(.user, "Hello! Reply with one short sentence.")]
        var system = hello
        if let prompt = settings.systemPrompt { system.insert(.text(.system, prompt), at: 0) }

        add("chat", "Chat", try? provider.makeURLRequest(ChatRequest(model: model, messages: system, settings: settings, stream: false)))
        add("chat-stream", "Chat (streaming)", try? provider.makeURLRequest(ChatRequest(model: model, messages: system, settings: settings, stream: true)))

        if !connection.engine.capabilities.thinkingMechanisms.isEmpty {
            var on = settings
            on.thinking = .medium
            var off = settings
            off.thinking = .off
            add("thinking-on", "Thinking on", try? provider.makeURLRequest(ChatRequest(model: model, messages: hello, settings: on)))
            add("thinking-off", "Thinking off", try? provider.makeURLRequest(ChatRequest(model: model, messages: hello, settings: off)))
        }

        let imageMessage = ChatMessage(role: .user, content: [.text("What color is this image?"), .image(data: tinyPNG, mimeType: "image/png")])
        add("image", "Chat with an image", try? provider.makeURLRequest(ChatRequest(model: model, messages: [imageMessage], settings: settings)),
            note: "Needs a vision model (llama.cpp: start with --mmproj).")

        let toolMessage = ChatMessage.text(.user, "What time is it in Tokyo?")
        add("tools", "Chat with tools", try? provider.makeURLRequest(ChatRequest(model: model, messages: [toolMessage], settings: settings, tools: [exampleTool])),
            note: connection.engine == .llamaCpp ? "llama-server needs --jinja for tool calls." : nil)

        switch connection.engine {
        case .llamaCpp:
            add("health", "Health", get(connection.rootURL("/health")))
            add("props", "Server properties", get(connection.rootURL("/props")))
            var template = get(connection.rootURL("/apply-template"))
            template.httpMethod = "POST"
            template.setValue("application/json", forHTTPHeaderField: "Content-Type")
            template.httpBody = try? JSONValue.object(["messages": .array(OpenAIRequestBuilder.messagesJSON(hello, supportsVision: false, engine: .llamaCpp))]).encoded()
            add("apply-template", "Rendered prompt (apply-template)", template)
            add("tools-list", "Server tools", get(connection.rootURL("/tools")), note: "Requires llama-server --tools or --mcp-servers-config.")
        case .vllm, .mlxVLM:
            add("health", "Health", get(connection.rootURL("/health")))
        default:
            break
        }
        return examples
    }
}
