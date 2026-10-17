import Foundation
import Testing
@testable import GoooeeeCore

private let registry = ProfileRegistry.bundled()

private func settings(_ values: [SamplingKey: SamplingValue] = [:], thinking: ThinkingLevel = .default, profile: String? = nil, extra: JSONValue? = nil) -> EffectiveSettings {
    var settings = EffectiveSettings(profile: profile.flatMap(registry.profile(id:)) ?? .generic)
    for (key, value) in values { settings.sampling[key] = ResolvedValue(value: value, source: .connection) }
    settings.thinking = thinking
    settings.extraBody = extra
    return settings
}

private func body(_ engine: EngineKind, _ settings: EffectiveSettings, messages: [ChatMessage] = [.text(.user, "hi")], tools: [ToolDefinition] = [], continueFinal: Bool = false) throws -> JSONValue {
    let connection = ServerConnection.preset(engine)
    return try OpenAIRequestBuilder(connection: connection, apiKey: nil)
        .body(for: ChatRequest(model: "m", messages: messages, settings: settings, tools: tools, continueFinalMessage: continueFinal))
}

@Suite("OpenAI request builder")
struct OpenAIRequestBuilderTests {
    @Test func repeatPenaltyWireNamePerEngine() throws {
        let values: [SamplingKey: SamplingValue] = [.repeatPenalty: .double(1.1), .topK: .int(20), .minP: .double(0.05)]
        let llama = try body(.llamaCpp, settings(values))
        #expect(llama["repeat_penalty"] == .double(1.1))
        let vllm = try body(.vllm, settings(values))
        #expect(vllm["repetition_penalty"] == .double(1.1))
        #expect(vllm["repeat_penalty"] == nil)
        let openai = try body(.openAI, settings(values))
        #expect(openai["top_k"] == nil)
        #expect(openai["min_p"] == nil)
    }

    @Test func maxTokensHandling() throws {
        #expect(try body(.llamaCpp, settings([.maxTokens: .int(-1)]))["max_tokens"] == .int(-1))
        #expect(try body(.vllm, settings([.maxTokens: .int(-1)]))["max_tokens"] == nil)
        #expect(try body(.openAI, settings([.maxTokens: .int(500)]))["max_completion_tokens"] == .int(500))
        #expect(try body(.vllm, settings([.maxTokens: .double(256)]))["max_tokens"] == .int(256))
    }

    @Test func llamaCppExtrasAndStreamOptions() throws {
        let llama = try body(.llamaCpp, settings())
        #expect(llama["return_progress"] == true)
        #expect(llama["reasoning_format"] == "auto")
        #expect(llama["reasoning_control"] == true)
        #expect(llama["stream_options"]?["include_usage"] == true)
        let mlxvlm = try body(.mlxVLM, settings())
        #expect(mlxvlm["return_progress"] == nil)
        #expect(mlxvlm["stream_options"] == nil)
    }

    @Test func thinkingForQwen3AcrossEngines() throws {
        let off = settings(thinking: .off, profile: "qwen3")
        #expect(try body(.llamaCpp, off)["chat_template_kwargs"]?["enable_thinking"] == false)
        #expect(try body(.vllm, off)["chat_template_kwargs"]?["enable_thinking"] == false)
        #expect(try body(.mlxVLM, off)["enable_thinking"] == false)

        let medium = settings(thinking: .medium, profile: "qwen3")
        let llama = try body(.llamaCpp, medium)
        #expect(llama["chat_template_kwargs"]?["enable_thinking"] == true)
        #expect(llama["thinking_budget_tokens"] == .int(2048))
        #expect(try body(.vllm, medium)["thinking_budget_tokens"] == nil)
    }

    @Test func softSwitchWhenNoKwargSupport() throws {
        // LM Studio has no chat_template_kwargs; Qwen3 falls back to /no_think in the system prompt.
        let result = try body(.lmStudio, settings(thinking: .off, profile: "qwen3"))
        let messages = result["messages"]?.arrayValue ?? []
        #expect(messages.first?["role"] == "system")
        #expect(messages.first?["content"]?.stringValue?.contains("/no_think") == true)
    }

    @Test func reasoningEffortForGptOssAndDwarfStar() throws {
        let high = settings(thinking: .high, profile: "gpt-oss")
        let llama = try body(.llamaCpp, high)
        #expect(llama["reasoning_effort"] == "high")
        #expect(llama["chat_template_kwargs"]?["reasoning_effort"] == "high")
        #expect(llama["thinking_budget_tokens"] == nil)
        let ds4 = try body(.dwarfStar4, settings(thinking: .max, profile: "deepseek-v4"))
        #expect(ds4["reasoning_effort"] == "max")
        #expect(ds4["think"] == true)
        let ds4Off = try body(.dwarfStar4, settings(thinking: .off, profile: "deepseek-v4"))
        #expect(ds4Off["think"] == false)
        #expect(ds4Off["reasoning_effort"] == nil)
    }

    @Test func defaultThinkingSendsNothing() throws {
        let result = try body(.vllm, settings(thinking: .default, profile: "qwen3"))
        #expect(result["chat_template_kwargs"] == nil)
        #expect(result["reasoning_effort"] == nil)
    }

    @Test func extraJSONMergesDeeply() throws {
        let extra: JSONValue = ["chat_template_kwargs": ["custom": 1], "seed": 7]
        let result = try body(.llamaCpp, settings(thinking: .off, profile: "qwen3", extra: extra))
        #expect(result["chat_template_kwargs"]?["custom"] == .int(1))
        #expect(result["chat_template_kwargs"]?["enable_thinking"] == false)
        #expect(result["seed"] == .int(7))
    }

    @Test func messagesWithImagesToolsAndReasoning() throws {
        let image = ChatMessage(role: .user, content: [.text("look"), .image(data: Data([1, 2, 3]), mimeType: "image/png")])
        let call = ToolCall(id: "call_1", name: "echo", arguments: "{\"text\":\"a\"}")
        let assistant = ChatMessage(role: .assistant, content: [.text("")], reasoning: "thought", toolCalls: [call])
        let tool = ChatMessage(role: .tool, content: [.text("a")], toolCallID: "call_1")

        let llama = try body(.llamaCpp, settings(), messages: [image, assistant, tool])
        let messages = llama["messages"]?.arrayValue ?? []
        #expect(messages[0]["content"]?[1]?["image_url"]?["url"]?.stringValue?.hasPrefix("data:image/png;base64,") == true)
        #expect(messages[1]["reasoning_content"] == "thought")
        #expect(messages[1]["content"] == .null)
        #expect(messages[1]["tool_calls"]?[0]?["function"]?["name"] == "echo")
        #expect(messages[2]["tool_call_id"] == "call_1")

        let vllm = try body(.vllm, settings(), messages: [assistant])
        #expect(vllm["messages"]?[0]?["content"]?.stringValue?.hasPrefix("<think>\nthought\n</think>") == true)
    }

    @Test func imagesDroppedWithoutVision() throws {
        let image = ChatMessage(role: .user, content: [.text("look"), .image(data: Data([1]), mimeType: "image/png")])
        let connection = ServerConnection.preset(.llamaCpp)
        let result = try OpenAIRequestBuilder(connection: connection, apiKey: nil)
            .body(for: ChatRequest(model: "m", messages: [image], supportsVision: false))
        #expect(result["messages"]?[0]?["content"] == "look")
    }

    @Test func toolsAndContinue() throws {
        let result = try body(.llamaCpp, settings(), tools: [CurlRenderer.exampleTool], continueFinal: true)
        #expect(result["tools"]?[0]?["function"]?["name"] == "get_current_time")
        #expect(result["continue_final_message"] == true)
        #expect(result["add_generation_prompt"] == false)
        #expect(try body(.openAI, settings(), continueFinal: true)["continue_final_message"] == nil)
    }

    @Test func headersAndURL() throws {
        var connection = ServerConnection.preset(.genericOpenAI, baseURL: URL(string: "http://host:9000")!)
        connection.extraHeaders = ["X-Test": "1"]
        let request = try OpenAIRequestBuilder(connection: connection, apiKey: "secret").urlRequest(for: ChatRequest(model: "m", messages: [.text(.user, "x")]))
        #expect(request.url?.absoluteString == "http://host:9000/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(request.value(forHTTPHeaderField: "X-Test") == "1")
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
    }
}

@Suite("Anthropic request builder")
struct AnthropicRequestBuilderTests {
    @Test func bodyShape() throws {
        let connection = ServerConnection.preset(.anthropic)
        let call = ToolCall(id: "toolu_1", name: "echo", arguments: "{\"text\":\"x\"}")
        let messages: [ChatMessage] = [
            .text(.system, "Be brief."),
            ChatMessage(role: .user, content: [.text("hi"), .image(data: Data([9]), mimeType: "image/jpeg")]),
            ChatMessage(role: .assistant, content: [.text("calling")], reasoning: "r", reasoningSignature: "sig", toolCalls: [call]),
            ChatMessage(role: .tool, content: [.text("x")], toolCallID: "toolu_1"),
        ]
        var effective = settings([.temperature: .double(0.5), .maxTokens: .int(1000)])
        effective.thinking = .default
        let body = try AnthropicRequestBuilder(connection: connection, apiKey: "k").body(for: ChatRequest(model: "claude-test", messages: messages, settings: effective))
        #expect(body["system"] == "Be brief.")
        #expect(body["max_tokens"] == .int(1000))
        #expect(body["temperature"] == .double(0.5))
        let wire = body["messages"]?.arrayValue ?? []
        #expect(wire.count == 3)
        #expect(wire[0]["content"]?[1]?["source"]?["media_type"] == "image/jpeg")
        #expect(wire[1]["content"]?[0]?["type"] == "thinking")
        #expect(wire[1]["content"]?[2]?["input"]?["text"] == "x")
        #expect(wire[2]["role"] == "user")
        #expect(wire[2]["content"]?[0]?["type"] == "tool_result")

        var thinking = effective
        thinking.thinking = .high
        let withThinking = try AnthropicRequestBuilder(connection: connection, apiKey: "k").body(for: ChatRequest(model: "claude-test", messages: messages, settings: thinking))
        #expect(withThinking["thinking"]?["budget_tokens"] == .int(16384))
        #expect(withThinking["temperature"] == nil)
        #expect((withThinking["max_tokens"]?.intValue ?? 0) > 16384)
    }

    @Test func headers() throws {
        let connection = ServerConnection.preset(.anthropic)
        let request = try AnthropicRequestBuilder(connection: connection, apiKey: "k").urlRequest(for: ChatRequest(model: "c", messages: [.text(.user, "x")]))
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "k")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.url?.path == "/v1/messages")
    }
}

@Suite("Settings resolver")
struct SettingsResolverTests {
    @Test func precedenceAndProvenance() throws {
        var connection = ServerConnection.preset(.llamaCpp)
        connection.sampling[.topK] = .int(30)
        let profile = registry.profile(id: "qwen3")!
        let resolver = SettingsResolver(
            connection: connection,
            workspace: SettingsOverrides(sampling: SamplingSettings([.minP: .double(0.1)])),
            chat: SettingsOverrides(sampling: SamplingSettings([.temperature: .double(0.2)])),
            profile: profile,
            serverDefaults: SamplingSettings([.temperature: .double(0.8), .topP: .double(0.9), .repeatPenalty: .double(1.0)])
        )
        let effective = try resolver.resolve()
        #expect(effective[.temperature]?.source == .chat)
        #expect(effective[.minP]?.source == .workspace)
        #expect(effective[.topK]?.source == .connection)
        #expect(effective[.topP]?.source == .profile)
        #expect(effective[.topP]?.value == .double(0.95))
        #expect(effective[.topP]?.disagreesWithServer == true)
        #expect(effective[.repeatPenalty]?.source == .server)
        #expect(effective[.repeatPenalty]?.isSent == false)
        #expect(effective.sentSampling[.repeatPenalty] == nil)
    }

    @Test func serverFirstPolicy() throws {
        var connection = ServerConnection.preset(.llamaCpp)
        connection.defaultsPolicy = .serverFirst
        let resolver = SettingsResolver(connection: connection, profile: registry.profile(id: "qwen3")!,
                                        serverDefaults: SamplingSettings([.temperature: .double(0.8)]))
        let effective = try resolver.resolve()
        #expect(effective[.temperature]?.source == .server)
        #expect(effective[.topP]?.source == .profile)
    }

    @Test func thinkingSelectsProfilePreset() throws {
        let profile = registry.profile(id: "qwen3")!
        var connection = ServerConnection.preset(.vllm)
        connection.thinking = ThinkingSettings(level: .off)
        let off = try SettingsResolver(connection: connection, profile: profile).resolve()
        #expect(off[.temperature]?.value == .double(0.7))
        let on = try SettingsResolver(connection: connection, chat: SettingsOverrides(thinking: .high), profile: profile).resolve()
        #expect(on.thinking == .high)
        #expect(on.thinkingSource == .chat)
        #expect(on[.temperature]?.value == .double(0.6))
    }

    @Test func systemPromptAndExtraJSON() throws {
        var connection = ServerConnection.preset(.llamaCpp)
        connection.systemPrompt = "Connection prompt"
        connection.extraBodyJSON = "{\"a\": 1, \"nested\": {\"x\": 1}}"
        let resolver = SettingsResolver(
            connection: connection,
            workspace: SettingsOverrides(systemPrompt: "Workspace prompt", extraBodyJSON: "{\"nested\": {\"y\": 2}}"),
            chat: SettingsOverrides(extraBodyJSON: "{\"a\": 3}"),
            profile: .generic
        )
        let effective = try resolver.resolve()
        #expect(effective.systemPrompt == "Workspace prompt")
        #expect(effective.systemPromptSource == .workspace)
        #expect(effective.extraBody == ["a": 3, "nested": ["x": 1, "y": 2]])
    }

    @Test func invalidExtraJSONThrows() {
        var connection = ServerConnection.preset(.llamaCpp)
        connection.extraBodyJSON = "{not json"
        #expect(throws: SettingsError.self) {
            _ = try SettingsResolver(connection: connection, profile: .generic).resolve()
        }
    }
}

@Suite("Model profiles")
struct ModelProfileTests {
    @Test(arguments: [
        ("Qwen/Qwen3-Coder-30B-A3B-Instruct", "qwen3-coder"),
        ("unsloth/Qwen3-30B-A3B-Thinking-2507-GGUF", "qwen3-thinking"),
        ("Qwen3-235B-A22B-Instruct-2507", "qwen3-instruct"),
        ("mlx-community/Qwen3-32B-4bit", "qwen3"),
        ("qwen3-8b-q4_k_m.gguf", "qwen3"),
        ("Qwen/Qwen3-VL-8B-Instruct", "qwen3-vl"),
        ("openai/gpt-oss-20b", "gpt-oss"),
        ("google/gemma-3-1b-it", "gemma-3-1b"),
        ("gemma-3-27b-it-qat", "gemma-3"),
        ("deepseek-ai/DeepSeek-R1-Distill-Qwen-7B", "deepseek-r1"),
        ("deepseek-v4-flash", "deepseek-v4"),
        ("mistralai/Magistral-Small-2509", "magistral"),
        ("llava-v1.6-mistral-7b", "vision-generic"),
    ])
    func matching(modelID: String, expected: String) {
        #expect(registry.match(modelID: modelID)?.id == expected)
    }

    @Test func customProfilesWin() {
        var custom = ModelProfile(id: "mine", displayName: "Mine", match: ["qwen3"])
        custom.sampling = ProfileSampling(standard: SamplingSettings([.temperature: .double(0.1)]))
        var local = registry
        local.setCustom([custom])
        #expect(local.match(modelID: "qwen3-8b")?.id == "mine")
        #expect(local.resolve(modelID: "unknown-model", explicitID: nil).id == "generic")
        #expect(local.resolve(modelID: "qwen3", explicitID: "gpt-oss").id == "gpt-oss")
    }

    @Test func bundledProfilesDecode() {
        #expect(registry.builtIn.count > 20)
        #expect(registry.profile(id: "qwen3")?.sampling.thinking?[.topK] == .int(20))
    }
}

@Suite("URLs and curl")
struct CurlAndURLTests {
    @Test func normalizeUserURLs() {
        #expect(URLBuilder.normalize("localhost:8080")?.base.absoluteString == "http://localhost:8080")
        #expect(URLBuilder.normalize("http://192.168.1.5:8000/v1")?.base.absoluteString == "http://192.168.1.5:8000")
        #expect(URLBuilder.normalize("http://host/v1/chat/completions")?.prefix == "/v1")
        #expect(URLBuilder.normalize("https://api.example.com/proxy/v1/")?.base.absoluteString == "https://api.example.com/proxy")
        #expect(URLBuilder.normalize("   ") == nil)
    }

    @Test func curlMasksKeyAndUsesHeredoc() throws {
        let connection = ServerConnection.preset(.openAI)
        let request = try OpenAIRequestBuilder(connection: connection, apiKey: "sk-real").urlRequest(for: ChatRequest(model: "gpt", messages: [.text(.user, "it's")]))
        let masked = CurlRenderer.render(request)
        #expect(masked.contains("\"Authorization: Bearer $GOOOEEE_API_KEY\""))
        #expect(!masked.contains("sk-real"))
        #expect(masked.contains("<<'JSON'"))
        #expect(masked.contains("-N"))
        #expect(CurlRenderer.render(request, revealKey: true).contains("sk-real"))
    }

    @Test func examplesForEngines() {
        let llama = CurlRenderer.examples(connection: .preset(.llamaCpp), apiKey: nil, model: "m", settings: EffectiveSettings())
        #expect(llama.map(\.id).contains("props"))
        #expect(llama.map(\.id).contains("apply-template"))
        let openai = CurlRenderer.examples(connection: .preset(.openAI), apiKey: nil, model: "m", settings: EffectiveSettings())
        #expect(!openai.map(\.id).contains("props"))
        #expect(openai.first { $0.id == "models" }?.command.contains("$GOOOEEE_API_KEY") == true)
    }
}
