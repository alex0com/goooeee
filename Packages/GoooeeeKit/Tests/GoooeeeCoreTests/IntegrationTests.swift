import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import GoooeeeCore

/// End-to-end tests against `Tools/MockServer/mock_server.py` over real HTTP.
/// Skipped when python3 isn't available.
@Suite("Mock server integration", .serialized, .enabled(if: RepoPaths.python != nil))
struct IntegrationTests {
    func connection(_ engine: EngineKind, _ server: MockServerProcess) -> ServerConnection {
        var connection = ServerConnection.preset(engine, baseURL: server.baseURL)
        connection.requestTimeout = 30
        return connection
    }

    @Test func streamsReasoningContentAndTimings() async throws {
        let server = try #require(MockServerProcess(engine: "llamacpp"))
        defer { server.stop() }
        let provider = OpenAIChatProvider(connection: connection(.llamaCpp, server), apiKey: nil)
        let events = try await collect(provider.stream(ChatRequest(model: "mock", messages: [.text(.user, "please think")])))
        #expect(events.reasoning.contains("think briefly"))
        #expect(events.content == "After thinking: **OK**.")
        #expect(events.contains { if case .serverTimings = $0 { return true } else { return false } })
        #expect(events.contains { if case .promptProgress = $0 { return true } else { return false } })
        #expect(events.last == .finished(.stop))
    }

    @Test func vllmStyleReasoningAndUsage() async throws {
        let server = try #require(MockServerProcess(engine: "vllm"))
        defer { server.stop() }
        let provider = OpenAIChatProvider(connection: connection(.vllm, server), apiKey: nil)
        let events = try await collect(provider.stream(ChatRequest(model: "mock", messages: [.text(.user, "think please")])))
        #expect(!events.reasoning.isEmpty)
        #expect(events.contains { if case .usage(let usage) = $0 { return usage.completionTokens != nil } else { return false } })
        let models = try await provider.listModels()
        #expect(models.first?.contextLength == 32768)
    }

    @Test func toolCallScenario() async throws {
        let server = try #require(MockServerProcess(engine: "llamacpp"))
        defer { server.stop() }
        let provider = OpenAIChatProvider(connection: connection(.llamaCpp, server), apiKey: nil)
        let request = ChatRequest(model: "mock", messages: [.text(.user, "use the tool please")], tools: [CurlRenderer.exampleTool])
        var accumulator = StreamAccumulator(splitter: ReasoningSplitter(format: .auto))
        for try await event in provider.stream(request) { _ = accumulator.apply(event) }
        let calls = accumulator.finalizeToolCalls()
        #expect(calls.first?.name == "get_current_time")
        #expect(calls.first?.parsedArguments == ["timezone": "Asia/Tokyo"])
        #expect(accumulator.finishReason == .toolCalls)
    }

    @Test func midStreamErrorSurfaces() async throws {
        let server = try #require(MockServerProcess(engine: "generic"))
        defer { server.stop() }
        let provider = OpenAIChatProvider(connection: connection(.genericOpenAI, server), apiKey: nil)
        await #expect(throws: InferenceError.server("Mock server error in the middle of the stream")) {
            _ = try await collect(provider.stream(ChatRequest(model: "mock", messages: [.text(.user, "trigger an error now")])))
        }
    }

    @Test func httpErrorsAndAuth() async throws {
        let server = try #require(MockServerProcess(engine: "generic", extra: ["--api-key", "secret"]))
        defer { server.stop() }
        let unauthorized = OpenAIChatProvider(connection: connection(.genericOpenAI, server), apiKey: "wrong")
        await #expect(throws: InferenceError.http(status: 401, message: "Invalid API key")) {
            _ = try await unauthorized.listModels()
        }
        let authorized = OpenAIChatProvider(connection: connection(.genericOpenAI, server), apiKey: "secret")
        #expect(try await authorized.listModels().count == 1)
    }

    @Test func connectionRefused() async {
        var connection = ServerConnection.preset(.llamaCpp, baseURL: URL(string: "http://127.0.0.1:1")!)
        connection.requestTimeout = 5
        let provider = OpenAIChatProvider(connection: connection, apiKey: nil)
        do {
            _ = try await provider.listModels()
            Issue.record("expected an error")
        } catch let error as InferenceError {
            if case .connectionRefused = error {} else if case .network = error {} else { Issue.record("unexpected \(error)") }
            #expect(error.recoverySuggestion != nil || error.localizedDescription.isEmpty == false)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func cancellationStopsQuickly() async throws {
        let server = try #require(MockServerProcess(engine: "llamacpp", extra: ["--tps", "40"]))
        defer { server.stop() }
        let provider = OpenAIChatProvider(connection: connection(.llamaCpp, server), apiKey: nil)
        let start = Date()
        let task = Task {
            var count = 0
            for try await event in provider.stream(ChatRequest(model: "mock", messages: [.text(.user, "long 4000")])) {
                if case .contentDelta = event { count += 1 }
            }
            return count
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        let count = try await task.value
        #expect(count < 4000)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func probeAndDiscovery() async throws {
        let server = try #require(MockServerProcess(engine: "llamacpp", extra: ["--vision", "--server-tools"]))
        defer { server.stop() }
        let probe = await ServerProbe(connection: connection(.llamaCpp, server), apiKey: nil).probe()
        #expect(probe.error == nil)
        #expect(probe.status == .online)
        #expect(probe.capabilities.contextLength == 32768)
        #expect(probe.capabilities.vision == true)
        #expect(probe.capabilities.serverToolsAvailable)
        #expect(probe.capabilities.defaultSampling[.temperature] == .double(0.8))

        let found = await LocalDiscovery.scan(ports: [server.port])
        #expect(found.first?.engine == .llamaCpp)
        #expect(found.first?.models == ["mock-qwen3-8b"])

        let client = LlamaCppClient(connection: connection(.llamaCpp, server), apiKey: nil)
        let tools = try await client.tools()
        #expect(tools.first?.name == "read_file")
        let result = try await client.executeTool(name: "read_file", arguments: ["path": "a.txt"], workingDirectory: "/tmp")
        #expect(result.textForModel == "contents of a.txt")
        #expect(try await client.stopReasoning(completionID: "x", model: nil))
        #expect(try await client.applyTemplate(messages: [.text(.user, "hi")]).contains("<|im_start|>user"))
    }

    @Test func discoveryDetectsVLLM() async throws {
        let server = try #require(MockServerProcess(engine: "vllm"))
        defer { server.stop() }
        let found = await LocalDiscovery.scan(ports: [server.port])
        #expect(found.first?.engine == .vllm)
    }

    @Test func connectionTesterPasses() async throws {
        let server = try #require(MockServerProcess(engine: "llamacpp", extra: ["--vision"]))
        defer { server.stop() }
        let tester = ConnectionTester(connection: connection(.llamaCpp, server), apiKey: nil, profiles: .bundled())
        var last: [ConnectionTestStep] = []
        for await steps in tester.run(.init(modelID: "mock-qwen3-8b", testVision: true, testToolCalling: true)) {
            last = steps
        }
        let failures = last.filter { $0.status == .failed }
        #expect(failures.isEmpty, "\(failures.map { "\($0.title): \($0.detail)" })")
        #expect(last.first { $0.id == .toolCalling }?.status == .passed)
        #expect(last.first { $0.id == .vision }?.status == .passed)
        #expect(ConnectionTester.summary(of: last).passed)
    }

    @Test func connectionTesterReportsNoVision() async throws {
        let server = try #require(MockServerProcess(engine: "llamacpp"))
        defer { server.stop() }
        let tester = ConnectionTester(connection: connection(.llamaCpp, server), apiKey: nil, profiles: .bundled())
        var last: [ConnectionTestStep] = []
        for await steps in tester.run(.init(testVision: true)) { last = steps }
        #expect(last.first { $0.id == .vision }?.status == .skipped)
    }

    @Test func anthropicProviderAgainstMock() async throws {
        let server = try #require(MockServerProcess(engine: "generic"))
        defer { server.stop() }
        var anthropic = ServerConnection.preset(.anthropic, baseURL: server.baseURL)
        anthropic.requestTimeout = 30
        let provider = AnthropicMessagesProvider(connection: anthropic, apiKey: "k")
        var settings = EffectiveSettings()
        settings.thinking = .low
        let events = try await collect(provider.stream(ChatRequest(model: "claude-test", messages: [.text(.user, "hello")], settings: settings)))
        #expect(events.reasoning == "Thinking about it.")
        #expect(events.content == "Hello from the mock Anthropic API.")
        #expect(events.contains(.reasoningSignature("sig123")))
    }

    @Test func completionProviderAgainstMock() async throws {
        let server = try #require(MockServerProcess(engine: "llamacpp"))
        defer { server.stop() }
        var connection = connection(.llamaCpp, server)
        connection.apiStyle = .openAICompletion
        connection.chatTemplate = ChatTemplate(source: "{% for m in messages %}{{ m.content }}{% endfor %}")
        let events = try await collect(OpenAICompletionProvider(connection: connection, apiKey: nil).stream(ChatRequest(model: "m", messages: [.text(.user, "abc")])))
        #expect(events.content.hasPrefix("Completion for a prompt"))
    }

    @Test func chatEngineEndToEnd() async throws {
        let server = try #require(MockServerProcess(engine: "llamacpp"))
        defer { server.stop() }
        let database = try AppDatabase.inMemory()
        let connection = connection(.llamaCpp, server)
        let workspace = Workspace(name: "W", connectionID: connection.id, modelID: "mock-qwen3-8b")
        let conversation = Conversation(workspaceID: workspace.id)
        try await database.save(conversation)
        let user = Message(conversationID: conversation.id, parentID: nil, role: .user, blocks: [.text("Hello there")])
        try await database.save(user, workspaceID: workspace.id, indexText: true)
        let profile = ProfileRegistry.bundled().resolve(modelID: workspace.modelID, explicitID: nil)
        let settings = try SettingsResolver(connection: connection, profile: profile).resolve()
        let engine = ChatEngine(store: database, delegate: ScriptedDelegate())
        let request = GenerationRequest(
            mode: .reply(parentID: user.id), workspaceID: workspace.id, conversation: conversation, messages: [user],
            connection: connection, apiKey: nil, modelID: workspace.modelID, settings: settings, supportsVision: false,
            options: GenerationOptions(titleMode: .firstLine)
        )
        var streamed = 0
        for await event in await engine.start(request) {
            if case .streaming = event { streamed += 1 }
        }
        #expect(streamed > 5)
        let stored = try await database.messages(conversationID: conversation.id)
        let reply = stored.first { $0.role == .assistant }
        #expect(reply?.text.contains("## Answer") == true)
        #expect(reply?.metrics?.generationSpeed != nil)
        #expect(try await database.conversation(id: conversation.id)?.title == "Hello there")
    }
}
