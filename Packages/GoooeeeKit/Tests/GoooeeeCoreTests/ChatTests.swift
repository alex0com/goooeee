import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import GoooeeeCore

@Suite("Message tree")
struct MessageTreeTests {
    let conversation = UUID()

    func message(_ id: Int, parent: Int?, role: Role = .user, time: Double) -> Message {
        Message(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!,
            conversationID: conversation,
            parentID: parent.map { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))! },
            role: role,
            blocks: [.text("m\(id)")],
            createdAt: Date(timeIntervalSince1970: time)
        )
    }

    @Test func pathsAndBranches() {
        // 1 → 2 → 3, and 1 → 4 (edited branch) → 5
        let tree = MessageTree([
            message(1, parent: nil, time: 1),
            message(2, parent: 1, role: .assistant, time: 2),
            message(3, parent: 2, time: 3),
            message(4, parent: 1, role: .assistant, time: 4),
            message(5, parent: 4, time: 5),
        ])
        let id = { (n: Int) in UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }
        #expect(tree.path(to: id(3)).map(\.text) == ["m1", "m2", "m3"])
        #expect(tree.path(to: nil).map(\.text) == ["m1", "m4", "m5"])
        #expect(tree.branchPosition(of: id(2)) == (0, 2))
        #expect(tree.branchPosition(of: id(4)) == (1, 2))
        #expect(tree.leafAfterSwitching(from: id(2), offset: 1) == id(5))
        #expect(tree.leafAfterSwitching(from: id(4), offset: -1) == id(3))
        #expect(tree.leafAfterSwitching(from: id(4), offset: 1) == nil)
    }

    @Test func removeSubtree() {
        var tree = MessageTree([message(1, parent: nil, time: 1), message(2, parent: 1, time: 2), message(3, parent: 2, time: 3)])
        let removed = tree.remove(subtreeOf: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        #expect(removed.count == 2)
        #expect(tree.allMessages.count == 1)
    }
}

@Suite("Prompt assembler")
struct PromptAssemblerTests {
    @Test func attachmentsReasoningAndToolImages() {
        let conversation = UUID()
        let user = Message(conversationID: conversation, parentID: nil, role: .user, blocks: [.text("Summarize")], attachments: [
            Attachment(kind: .text, name: "notes.txt", mimeType: "text/plain", text: "alpha"),
            Attachment(kind: .image, name: "a.png", mimeType: "image/png", data: Data([1])),
        ])
        let call = ToolCall(id: "c1", name: "image", arguments: "{}")
        let assistant = Message(conversationID: conversation, parentID: user.id, role: .assistant,
                                blocks: [.thinking("why", duration: 1, signature: nil), .text("calling")], toolCalls: [call])
        let tool = Message(conversationID: conversation, parentID: assistant.id, role: .tool, blocks: [.text("[image]")], toolCallID: "c1",
                           toolResult: ToolResult(content: [.image(data: Data([2]), mimeType: "image/png")]))

        let withVision = PromptAssembler.messages(path: [user, assistant, tool], options: .init(systemPrompt: "sys", includeReasoning: false, supportsVision: true))
        #expect(withVision.map(\.role) == [.system, .user, .assistant, .tool, .user])
        #expect(withVision[1].content.count == 3)
        #expect(withVision[1].text.contains("File: notes.txt"))
        #expect(withVision[2].reasoning == nil)
        #expect(withVision[4].hasImages)

        let noVision = PromptAssembler.messages(path: [user, assistant, tool], options: .init(includeReasoning: true, supportsVision: false))
        #expect(noVision.map(\.role) == [.user, .assistant, .tool])
        #expect(noVision[0].text.contains("omitted"))
        #expect(noVision[1].reasoning == "why")
    }
}

@Suite("Templates and titles")
struct TemplateTests {
    @Test func rendersChatML() throws {
        let template = ChatTemplate(source: """
            {%- for message in messages %}<|im_start|>{{ message.role }}
            {{ message.content }}<|im_end|>
            {% endfor %}{%- if add_generation_prompt %}<|im_start|>assistant
            {% endif %}
            """, eosToken: "<|im_end|>", stopTokens: ["<|im_end|>"])
        let prompt = try ChatTemplateRenderer.render(template: template, messages: [.text(.system, "S"), .text(.user, "Hi")])
        #expect(prompt.contains("<|im_start|>system\nS<|im_end|>"))
        #expect(prompt.hasSuffix("<|im_start|>assistant\n"))
        #expect(try ChatTemplateRenderer.validate(template).contains("What is 2 + 2?"))
    }

    @Test func completionProviderBody() throws {
        var connection = ServerConnection.preset(.llamaCpp)
        connection.apiStyle = .openAICompletion
        connection.chatTemplate = ChatTemplate(source: "{% for m in messages %}[{{ m.role }}]{{ m.content }}{% endfor %}{% if add_generation_prompt %}[assistant]{% endif %}", eosToken: "</s>")
        let body = try OpenAICompletionProvider(connection: connection, apiKey: nil).body(for: ChatRequest(model: "m", messages: [.text(.user, "x")]))
        #expect(body["prompt"] == "[user]x[assistant]")
        #expect(body["stop"] == ["</s>"])
    }

    @Test func badTemplateThrows() {
        #expect(throws: TemplateError.self) {
            _ = try ChatTemplateRenderer.validate(ChatTemplate(source: "{% for x in %}"))
        }
    }

    @Test func titles() {
        #expect(ConversationTitle.fromFirstLine("\n\n# Plan a trip to Kyoto\nmore") == "Plan a trip to Kyoto")
        #expect(ConversationTitle.fromFirstLine(String(repeating: "word ", count: 30)).hasSuffix("…"))
        #expect(ConversationTitle.cleanGenerated("<think>x</think>\n\"Kyoto Trip Plan.\"") == "Kyoto Trip Plan")
    }

    @Test func sidebarGrouping() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let workspace = UUID()
        let conversations = [
            Conversation(workspaceID: workspace, title: "today", updatedAt: now.addingTimeInterval(-60)),
            Conversation(workspaceID: workspace, title: "pinned", isPinned: true, updatedAt: now.addingTimeInterval(-86400 * 40)),
            Conversation(workspaceID: workspace, title: "week", updatedAt: now.addingTimeInterval(-86400 * 3)),
            Conversation(workspaceID: workspace, title: "old", updatedAt: now.addingTimeInterval(-86400 * 60)),
            Conversation(workspaceID: workspace, title: "deleted", updatedAt: now, deletedAt: now),
        ]
        let sections = ConversationGrouping.sections(conversations, now: now, calendar: calendar)
        #expect(sections.map(\.id).prefix(3) == ["pinned", "today", "week"])
        #expect(sections.flatMap(\.conversations).map(\.title).contains("deleted") == false)
        #expect(sections.last?.id.hasPrefix("month-") == true)
    }

    @Test func mcpServersJSONRoundTrip() throws {
        let json = """
            {"mcpServers": {
              "files": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"], "env": {"TOKEN": "x"}, "timeout_ms": 60000},
              "remote": {"url": "https://example.com/mcp", "headers": {"Authorization": "Bearer y"}},
              "legacy": {"url": "https://example.com/sse"}
            }}
            """
        let servers = try MCPServersJSON.parse(Data(json.utf8))
        #expect(servers.map(\.name) == ["files", "legacy", "remote"])
        guard case .stdio(let command, let args, let env, _) = servers[0].transport else {
            Issue.record("expected stdio")
            return
        }
        #expect(command == "npx")
        #expect(args.count == 3)
        #expect(env["TOKEN"] == "x")
        #expect(servers[0].toolTimeoutSeconds == 60)
        if case .sse = servers[1].transport {} else { Issue.record("expected sse") }
        if case .http = servers[2].transport {} else { Issue.record("expected http") }

        var secret = servers[0]
        secret.secretKeys = ["TOKEN"]
        let exported = try JSONValue.parse(MCPServersJSON.export([secret]))
        #expect(exported["mcpServers"]?["files"]?["env"] == nil)
        #expect(exported["mcpServers"]?["files"]?["command"] == "npx")
    }

    @Test func toolWireNames() {
        let a = ToolDefinition(name: "search", sourceKind: .mcp, sourceID: "1", sourceName: "web")
        let b = ToolDefinition(name: "search", sourceKind: .mcp, sourceID: "2", sourceName: "docs")
        let c = ToolDefinition(name: "read file", sourceKind: .mcp, sourceID: "2", sourceName: "docs")
        let named = ToolDefinition.assignWireNames([a, b, c])
        #expect(named.map(\.name) == ["web_search", "docs_search", "read_file"])
    }

    @Test func appSettingsDecodeWithMissingKeys() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{\"textScale\": 1.2, \"fonts\": {\"code\": {\"size\": 15}}}".utf8))
        #expect(settings.textScale == 1.2)
        #expect(settings.fonts[.code]?.size == 15)
        #expect(settings.sendKey == .enter)
        #expect(settings.font(for: .assistantMessage).size == 16.8)
    }
}

// MARK: - Persistence

@Suite("Database")
struct DatabaseTests {
    @Test func conversationsMessagesAttachmentsAndSearch() async throws {
        let database = try AppDatabase.inMemory()
        let connection = ServerConnection.preset(.llamaCpp)
        try await database.save(connection)
        let workspace = Workspace(name: "Test", connectionID: connection.id)
        try await database.save(workspace)
        var conversation = Conversation(workspaceID: workspace.id, title: "Kyoto plans")
        try await database.save(conversation)

        let image = Attachment(kind: .image, name: "map.png", mimeType: "image/png", data: Data(repeating: 7, count: 32))
        let user = Message(conversationID: conversation.id, parentID: nil, role: .user, blocks: [.text("Plan a temple itinerary")], attachments: [image])
        try await database.save(user, workspaceID: workspace.id, indexText: true)
        let reply = Message(conversationID: conversation.id, parentID: user.id, role: .assistant, blocks: [.text("Start at Kinkaku-ji in the morning.")])
        try await database.save(reply, workspaceID: workspace.id, indexText: true)
        conversation.currentLeafID = reply.id
        try await database.save(conversation)

        let loaded = try await database.messages(conversationID: conversation.id)
        #expect(loaded.count == 2)
        #expect(loaded.first?.attachments.first?.data?.count == 32)
        #expect(try await database.connections().first?.id == connection.id)
        #expect(try await database.workspaces().first?.name == "Test")

        let byTitle = try await database.search("kyoto", workspaceID: workspace.id)
        #expect(byTitle.first?.conversationID == conversation.id)
        if database.hasFullTextSearch {
            let byText = try await database.search("Kinkaku", workspaceID: nil)
            #expect(byText.first?.snippet.contains("Kinkaku") == true)
        }

        try await database.softDelete(conversationIDs: [conversation.id])
        #expect(try await database.conversations(workspaceID: workspace.id).isEmpty)
        #expect(try await database.deletedConversations(workspaceID: workspace.id).count == 1)
        try await database.restore(conversationIDs: [conversation.id])
        #expect(try await database.conversations(workspaceID: workspace.id).count == 1)

        try await database.softDelete(conversationIDs: [conversation.id], at: Date(timeIntervalSinceNow: -40 * 86400))
        let purged = try await database.purgeDeleted(before: Date(timeIntervalSinceNow: -30 * 86400))
        #expect(purged == 1)
        #expect(try await database.messages(conversationID: conversation.id).isEmpty)
    }

    @Test func grantsLogAndServers() async throws {
        let database = try AppDatabase.inMemory()
        let workspace = UUID()
        let grant = ToolGrant(workspaceID: workspace, scope: .server, target: "srv", label: "srv")
        try await database.save(grant)
        #expect(try await database.toolGrants(workspaceID: workspace) == [grant])
        try await database.append(ToolCallLogEntry(workspaceID: workspace, conversationID: UUID(), toolKey: "srv/x", toolName: "x", sourceLabel: "srv", arguments: "{}", decision: .allowOnce))
        #expect(try await database.toolLog(workspaceID: workspace).count == 1)
        let server = MCPServerConfig(name: "files", transport: .stdio(command: "npx", args: [], env: [:], cwd: nil))
        try await database.save(server)
        #expect(try await database.mcpServers().first?.name == "files")
    }

    @Test func ftsQueryQuoting() {
        #expect(AppDatabase.ftsQuery("hello wor") == "\"hello\" \"wor\"*")
        #expect(AppDatabase.ftsQuery("say \"hi\"") == "\"say\" \"\"\"hi\"\"\"*")
    }
}

// MARK: - Chat engine

final class RecordingStore: GenerationStore, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var messages: [UUID: Message] = [:]
    private(set) var conversations: [UUID: Conversation] = [:]
    private(set) var log: [ToolCallLogEntry] = []

    func save(_ message: Message, workspaceID: UUID, indexText: Bool) async throws { lock.withLock { messages[message.id] = message } }
    func save(_ conversation: Conversation) async throws { lock.withLock { conversations[conversation.id] = conversation } }
    func append(_ entry: ToolCallLogEntry) async throws { lock.withLock { log.append(entry) } }
}

final class ScriptedDelegate: AgenticDelegate, @unchecked Sendable {
    var decision: PermissionDecision = .allowOnce
    var continueAnswer = false
    var steering: String?
    private(set) var permissionRequests = 0

    func requestPermission(_ request: ToolPermissionRequest) async -> PermissionDecision {
        permissionRequests += 1
        return decision
    }

    func requestContinue(conversationID: UUID, turns: Int) async -> Bool { continueAnswer }

    func takeSteeringMessage(conversationID: UUID) async -> String? {
        defer { steering = nil }
        return steering
    }
}

/// Replies with a tool call first, then with text once a tool result is in the conversation.
struct ScriptedProvider: InferenceProvider {
    var toolName: String?

    func makeURLRequest(_ request: ChatRequest) throws -> URLRequest { URLRequest(url: URL(string: "http://stub")!) }
    func listModels() async throws -> [RemoteModel] { [] }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        let hasToolResult = request.messages.contains { $0.role == .tool }
        let toolName = self.toolName
        return AsyncThrowingStream { continuation in
            continuation.yield(.started(completionID: "c1", model: "stub"))
            if let toolName, !hasToolResult {
                continuation.yield(.toolCallDelta(index: 0, id: "call_1", name: toolName, argumentsFragment: "{\"text\": \"ping\"}"))
                continuation.yield(.finished(.toolCalls))
            } else {
                continuation.yield(.reasoningDelta("thinking"))
                continuation.yield(.contentDelta("Final answer"))
                continuation.yield(.usage(TokenUsage(promptTokens: 10, completionTokens: 2)))
                continuation.yield(.finished(.stop))
            }
            continuation.finish()
        }
    }
}

struct EchoTools: ToolProviding {
    func tools(for selection: ToolSelection) async -> [ToolDefinition] {
        [ToolDefinition(name: "echo", parameters: ["type": "object", "properties": ["text": ["type": "string"]]], sourceKind: .mcp, sourceID: "srv", sourceName: "srv")]
    }

    func canExecute(_ tool: ToolDefinition) -> Bool { true }

    func execute(_ tool: ToolDefinition, arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolResult {
        .text("echo: \(arguments["text"]?.stringValue ?? "")")
    }
}

@Suite("Chat engine")
struct ChatEngineTests {
    func makeRequest(tools: [ToolDefinition], title: TitleMode? = .firstLine) -> (GenerationRequest, Message) {
        let workspace = UUID()
        let conversation = Conversation(workspaceID: workspace)
        let user = Message(conversationID: conversation.id, parentID: nil, role: .user, blocks: [.text("Say ping via the tool")])
        let request = GenerationRequest(
            mode: .reply(parentID: user.id),
            workspaceID: workspace,
            conversation: conversation,
            messages: [user],
            connection: .preset(.llamaCpp),
            apiKey: nil,
            modelID: "stub",
            settings: EffectiveSettings(),
            supportsVision: true,
            tools: tools,
            options: GenerationOptions(titleMode: title)
        )
        return (request, user)
    }

    func run(_ engine: ChatEngine, _ request: GenerationRequest) async -> [ChatEvent] {
        var events: [ChatEvent] = []
        for await event in await engine.start(request) { events.append(event) }
        return events
    }

    @Test func plainReplyIsStoredAndTitled() async {
        let store = RecordingStore()
        let engine = ChatEngine(store: store, delegate: ScriptedDelegate(), makeProvider: { _, _ in ScriptedProvider(toolName: nil) })
        let (request, _) = makeRequest(tools: [])
        let events = await run(engine, request)
        guard case .finished(let error) = events.last else {
            Issue.record("missing finished")
            return
        }
        #expect(error == nil)
        let assistant = store.messages.values.first { $0.role == .assistant }
        #expect(assistant?.text == "Final answer")
        #expect(assistant?.reasoning == "thinking")
        #expect(assistant?.state == .complete)
        #expect(assistant?.metrics?.completionTokens == 2)
        #expect(store.conversations[request.conversation.id]?.title == "Say ping via the tool")
        #expect(store.conversations[request.conversation.id]?.currentLeafID == assistant?.id)
    }

    @Test func agenticLoopRunsToolAndContinues() async {
        let store = RecordingStore()
        let delegate = ScriptedDelegate()
        let router = ToolRouter(providers: [EchoTools()])
        let tools = await router.tools(for: ToolSelection())
        let engine = ChatEngine(store: store, toolRouter: router, delegate: delegate, makeProvider: { _, _ in ScriptedProvider(toolName: "echo") })
        let (request, _) = makeRequest(tools: tools)
        let events = await run(engine, request)
        #expect(delegate.permissionRequests == 1)
        let tool = store.messages.values.first { $0.role == .tool }
        #expect(tool?.toolResult?.textForModel == "echo: ping")
        let assistants = store.messages.values.filter { $0.role == .assistant }.sorted { $0.createdAt < $1.createdAt }
        #expect(assistants.count == 2)
        #expect(assistants.first?.toolCalls.first?.status == .completed)
        #expect(assistants.last?.text == "Final answer")
        #expect(assistants.last?.metrics?.agentic?.turns == 2)
        #expect(assistants.last?.metrics?.agentic?.toolCalls == 1)
        #expect(store.log.count == 1)
        #expect(events.contains { if case .toolPermissionRequested = $0 { return true } else { return false } })
    }

    @Test func deniedToolIsReportedToModel() async {
        let store = RecordingStore()
        let delegate = ScriptedDelegate()
        delegate.decision = .deny
        let router = ToolRouter(providers: [EchoTools()])
        let tools = await router.tools(for: ToolSelection())
        let engine = ChatEngine(store: store, toolRouter: router, delegate: delegate, makeProvider: { _, _ in ScriptedProvider(toolName: "echo") })
        let (request, _) = makeRequest(tools: tools)
        _ = await run(engine, request)
        let tool = store.messages.values.first { $0.role == .tool }
        #expect(tool?.toolResult?.isError == true)
        #expect(store.messages.values.first { $0.role == .assistant && !$0.toolCalls.isEmpty }?.toolCalls.first?.status == .denied)
    }

    @Test func turnLimitAsksToContinue() async {
        let store = RecordingStore()
        let delegate = ScriptedDelegate()
        delegate.continueAnswer = false
        let router = ToolRouter(providers: [EchoTools()])
        let tools = await router.tools(for: ToolSelection())
        let engine = ChatEngine(store: store, toolRouter: router, delegate: delegate, makeProvider: { _, _ in ScriptedProvider(toolName: "echo") })
        var (request, _) = makeRequest(tools: tools)
        request.options.maxAgenticTurns = 1
        let events = await run(engine, request)
        #expect(events.contains { if case .continueRequested(1) = $0 { return true } else { return false } })
        #expect(store.messages.values.filter { $0.role == .assistant }.count == 1)
    }

    @Test func timeoutHelper() async {
        await #expect(throws: ToolError.timedOut(0.05)) {
            _ = try await withTimeout(seconds: 0.05) { () async throws -> Int in
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return 1
            }
        }
    }
}
