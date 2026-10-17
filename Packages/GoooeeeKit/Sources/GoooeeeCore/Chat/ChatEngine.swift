import Foundation

/// Persistence used by the engine (the app passes `AppDatabase`; tests use an in-memory store).
public protocol GenerationStore: Sendable {
    func save(_ message: Message, workspaceID: UUID, indexText: Bool) async throws
    func save(_ conversation: Conversation) async throws
    func append(_ entry: ToolCallLogEntry) async throws
}

extension AppDatabase: GenerationStore {
    public func save(_ message: Message, workspaceID: UUID, indexText: Bool) async throws {
        try await save(message, workspaceID: Optional(workspaceID), indexText: indexText)
    }
}

/// A tool call waiting for the user's decision.
public struct ToolPermissionRequest: Identifiable, Sendable, Hashable {
    public var id: String { call.id }
    public var workspaceID: UUID
    public var conversationID: UUID
    public var call: ToolCall
    public var tool: ToolDefinition
}

/// The UI side of the agentic loop: permission prompts, the turn-limit question, steering messages.
public protocol AgenticDelegate: Sendable {
    func requestPermission(_ request: ToolPermissionRequest) async -> PermissionDecision
    func requestContinue(conversationID: UUID, turns: Int) async -> Bool
    func takeSteeringMessage(conversationID: UUID) async -> String?
}

public struct GenerationOptions: Sendable {
    public var excludeReasoningFromContext: Bool
    public var disableReasoningParsing: Bool
    public var maxAgenticTurns: Int
    public var toolTimeout: TimeInterval
    public var pdfAsImages: Bool
    public var workingDirectory: String?
    public var titleMode: TitleMode?
    public var titlePrompt: String

    public init(
        excludeReasoningFromContext: Bool = true,
        disableReasoningParsing: Bool = false,
        maxAgenticTurns: Int = 100,
        toolTimeout: TimeInterval = 300,
        pdfAsImages: Bool = false,
        workingDirectory: String? = nil,
        titleMode: TitleMode? = nil,
        titlePrompt: String = ConversationTitle.defaultPrompt
    ) {
        self.excludeReasoningFromContext = excludeReasoningFromContext
        self.disableReasoningParsing = disableReasoningParsing
        self.maxAgenticTurns = maxAgenticTurns
        self.toolTimeout = toolTimeout
        self.pdfAsImages = pdfAsImages
        self.workingDirectory = workingDirectory
        self.titleMode = titleMode
        self.titlePrompt = titlePrompt
    }

    public init(settings: AppSettings, workingDirectory: String?) {
        self.init(
            excludeReasoningFromContext: settings.excludeReasoningFromContext,
            disableReasoningParsing: settings.disableReasoningParsing,
            maxAgenticTurns: settings.maxAgenticTurns,
            toolTimeout: settings.mcpRequestTimeoutSeconds,
            pdfAsImages: settings.pdfAsImages,
            workingDirectory: workingDirectory,
            titleMode: settings.titleMode,
            titlePrompt: settings.titlePrompt
        )
    }
}

public struct GenerationRequest: Sendable {
    public enum Mode: Sendable, Hashable {
        /// Generate a new assistant reply as a child of `parentID` (usually the user message just sent).
        case reply(parentID: UUID)
        /// Continue an existing assistant message.
        case continueMessage(UUID)
    }

    public var mode: Mode
    public var workspaceID: UUID
    public var conversation: Conversation
    /// Every message of the conversation (the tree).
    public var messages: [Message]
    public var connection: ServerConnection
    public var apiKey: String?
    public var modelID: String?
    public var settings: EffectiveSettings
    public var supportsVision: Bool
    public var tools: [ToolDefinition]
    public var options: GenerationOptions

    public init(
        mode: Mode,
        workspaceID: UUID,
        conversation: Conversation,
        messages: [Message],
        connection: ServerConnection,
        apiKey: String?,
        modelID: String?,
        settings: EffectiveSettings,
        supportsVision: Bool,
        tools: [ToolDefinition] = [],
        options: GenerationOptions = GenerationOptions()
    ) {
        self.mode = mode
        self.workspaceID = workspaceID
        self.conversation = conversation
        self.messages = messages
        self.connection = connection
        self.apiKey = apiKey
        self.modelID = modelID
        self.settings = settings
        self.supportsVision = supportsVision
        self.tools = tools
        self.options = options
    }
}

/// What the engine reports to the UI.
public enum ChatEvent: Sendable {
    /// A new message was created (assistant reply, tool result, steering message).
    case messageAdded(Message)
    /// Streaming changes to an assistant message.
    case streaming(messageID: UUID, changes: [AccumulatorChange])
    /// A message's stored state changed (tool call status, final content, error).
    case messageUpdated(Message)
    case conversationUpdated(Conversation)
    case toolPermissionRequested(ToolPermissionRequest)
    /// MCP progress for a running tool call.
    case toolProgress(messageID: UUID, callID: String, fraction: Double?, message: String?)
    case continueRequested(turns: Int)
    case finished(error: InferenceError?)
}

/// Runs generations for one workspace, keyed by conversation, independent of any view.
public actor ChatEngine {
    private let store: GenerationStore
    private let toolRouter: ToolRouter
    private let delegate: AgenticDelegate
    private let makeProvider: @Sendable (ServerConnection, String?) -> InferenceProvider
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var tokens: [UUID: UUID] = [:]

    public init(
        store: GenerationStore,
        toolRouter: ToolRouter = ToolRouter(),
        delegate: AgenticDelegate,
        makeProvider: @escaping @Sendable (ServerConnection, String?) -> InferenceProvider = { ProviderFactory.make(connection: $0, apiKey: $1) }
    ) {
        self.store = store
        self.toolRouter = toolRouter
        self.delegate = delegate
        self.makeProvider = makeProvider
    }

    public func isRunning(conversationID: UUID) -> Bool {
        tasks[conversationID] != nil
    }

    public var runningConversations: Set<UUID> { Set(tasks.keys) }

    public func cancel(conversationID: UUID) {
        tasks[conversationID]?.cancel()
    }

    public func cancelAll() {
        for task in tasks.values { task.cancel() }
    }

    /// Starts a generation. Events stop with `.finished`.
    public func start(_ request: GenerationRequest) -> AsyncStream<ChatEvent> {
        let conversationID = request.conversation.id
        tasks[conversationID]?.cancel()
        let (stream, continuation) = AsyncStream<ChatEvent>.makeStream(bufferingPolicy: .unbounded)
        let token = UUID()
        tokens[conversationID] = token
        let runner = GenerationRun(
            request: request,
            store: store,
            toolRouter: toolRouter,
            delegate: delegate,
            provider: makeProvider(request.connection, request.apiKey),
            emit: { continuation.yield($0) }
        )
        let task = Task {
            let error = await runner.run()
            continuation.yield(.finished(error: error))
            continuation.finish()
            self.finished(conversationID: conversationID, token: token)
        }
        tasks[conversationID] = task
        return stream
    }

    private func finished(conversationID: UUID, token: UUID) {
        guard tokens[conversationID] == token else { return }
        tasks[conversationID] = nil
        tokens[conversationID] = nil
    }

    /// Generates a conversation title with the model (Settings → Chat → title by LLM).
    public static func generateTitle(
        provider: InferenceProvider,
        model: String?,
        prompt: String,
        userText: String,
        assistantText: String,
        profile: ModelProfile
    ) async -> String? {
        let filled = prompt
            .replacingOccurrences(of: "{{USER}}", with: String(userText.prefix(2000)))
            .replacingOccurrences(of: "{{ASSISTANT}}", with: String(assistantText.prefix(2000)))
        var settings = EffectiveSettings(profile: profile)
        settings.thinking = profile.thinkingControl.alwaysThinks ? .low : .off
        settings.sampling[.maxTokens] = ResolvedValue(value: .int(profile.thinkingControl.alwaysThinks ? 512 : 32), source: .connection)
        settings.sampling[.temperature] = ResolvedValue(value: .double(0.3), source: .connection)
        let request = ChatRequest(model: model, messages: [.text(.user, filled)], settings: settings)
        var accumulator = StreamAccumulator(splitter: ReasoningSplitter(format: profile.reasoning, thinkingDisabled: true))
        do {
            for try await event in provider.stream(request) {
                _ = accumulator.apply(event)
            }
        } catch {
            return nil
        }
        let text = accumulator.currentText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return ConversationTitle.cleanGenerated(text)
    }
}

/// One generation, including the agentic loop.
struct GenerationRun: Sendable {
    let request: GenerationRequest
    let store: GenerationStore
    let toolRouter: ToolRouter
    let delegate: AgenticDelegate
    let provider: InferenceProvider
    let emit: @Sendable (ChatEvent) -> Void

    func run() async -> InferenceError? {
        var tree = MessageTree(request.messages)
        var conversation = request.conversation
        let workspaceID = request.workspaceID
        let options = request.options
        let profile = request.settings.profile
        var totals = AgenticTotals()
        var lastAssistantID: UUID?
        var turn = 0
        var leafID: UUID
        var continuingID: UUID?

        switch request.mode {
        case .reply(let parentID): leafID = parentID
        case .continueMessage(let id):
            leafID = id
            continuingID = id
        }

        while true {
            turn += 1
            let path = tree.path(to: leafID)
            let chatMessages = PromptAssembler.messages(path: path, options: PromptAssembler.Options(
                systemPrompt: request.settings.systemPrompt,
                includeReasoning: profile.keepReasoningInContext || !options.excludeReasoningFromContext,
                supportsVision: request.supportsVision,
                pdfAsImages: options.pdfAsImages
            ))
            let chatRequest = ChatRequest(
                model: request.modelID,
                messages: chatMessages,
                settings: request.settings,
                tools: request.tools,
                continueFinalMessage: continuingID != nil,
                supportsVision: request.supportsVision,
                disableReasoningParsing: options.disableReasoningParsing
            )

            // The assistant message being written.
            var assistant: Message
            var accumulator: StreamAccumulator
            let splitter = ReasoningSplitter(
                format: profile.reasoning,
                enabled: !options.disableReasoningParsing,
                thinkingDisabled: request.settings.thinking == .off
            )
            if let continuingID, let existing = tree[continuingID] {
                assistant = existing
                assistant.state = .streaming
                accumulator = StreamAccumulator(continuing: existing.blocks, splitter: splitter)
                emit(.messageUpdated(assistant))
            } else {
                assistant = Message(conversationID: conversation.id, parentID: leafID, role: .assistant, state: .streaming, modelID: request.modelID)
                accumulator = StreamAccumulator(splitter: splitter)
                tree.upsert(assistant)
                conversation.currentLeafID = assistant.id
                try? await store.save(assistant, workspaceID: workspaceID, indexText: false)
                emit(.messageAdded(assistant))
                emit(.conversationUpdated(conversation))
            }
            continuingID = nil
            lastAssistantID = assistant.id

            var streamError: InferenceError?
            var lastSave = MonotonicClock.now()
            do {
                for try await event in provider.stream(chatRequest) {
                    if Task.isCancelled { throw CancellationError() }
                    let changes = accumulator.apply(event)
                    if case .started(let id, _) = event, let id { assistant.completionID = id }
                    if !changes.isEmpty { emit(.streaming(messageID: assistant.id, changes: changes)) }
                    let now = MonotonicClock.now()
                    if now - lastSave > 1 {
                        lastSave = now
                        var snapshot = assistant
                        snapshot.blocks = accumulator.blocks
                        snapshot.metrics = accumulator.metrics
                        try? await store.save(snapshot, workspaceID: workspaceID, indexText: false)
                    }
                }
            } catch {
                streamError = InferenceError.from(error)
            }

            let cancelled = Task.isCancelled || streamError == .cancelled
            if streamError != nil {
                let changes = accumulator.finishAbruptly()
                emit(.streaming(messageID: assistant.id, changes: changes))
            }
            assistant.blocks = accumulator.blocks
            assistant.metrics = accumulator.metrics
            assistant.toolCalls = cancelled ? [] : accumulator.finalizeToolCalls()
            assistant.modelID = accumulator.model ?? request.modelID
            if let error = streamError {
                assistant.state = cancelled ? .stopped : .failed(error.localizedDescription)
            } else {
                assistant.state = .complete
            }
            var turnStats = AgenticTotals.TurnStats(
                promptTokens: assistant.metrics?.promptTokens,
                completionTokens: assistant.metrics?.generatedTokens,
                promptMs: assistant.metrics?.serverPromptMs ?? assistant.metrics?.ttftMs,
                generationMs: assistant.metrics?.serverPredictedMs ?? assistant.metrics?.clientGenerationMs
            )
            tree.upsert(assistant)
            leafID = assistant.id

            if streamError != nil || assistant.toolCalls.isEmpty || request.tools.isEmpty {
                if totals.turns > 0 {
                    totals.turns += 1
                    totals.perTurn.append(turnStats)
                    assistant.metrics?.agentic = totals
                    tree.upsert(assistant)
                }
                try? await store.save(assistant, workspaceID: workspaceID, indexText: true)
                emit(.messageUpdated(assistant))
                conversation.currentLeafID = leafID
                conversation.updatedAt = Date()
                conversation.preview = assistant.preview.isEmpty ? conversation.preview : assistant.preview
                try? await store.save(conversation)
                emit(.conversationUpdated(conversation))
                if streamError == nil, let titled = await titleIfNeeded(conversation, path: tree.path(to: leafID)) {
                    conversation = titled
                    try? await store.save(conversation)
                    emit(.conversationUpdated(conversation))
                }
                return cancelled ? nil : streamError
            }

            // Tool calls: ask, run, append results, go again.
            try? await store.save(assistant, workspaceID: workspaceID, indexText: true)
            emit(.messageUpdated(assistant))
            var toolMs: Double = 0
            for index in assistant.toolCalls.indices {
                if Task.isCancelled { break }
                var call = assistant.toolCalls[index]
                guard let tool = request.tools.first(where: { $0.name == call.name }) else {
                    call.status = .failed
                    call.errorMessage = ToolError.unknownTool(call.name).localizedDescription
                    assistant.toolCalls[index] = call
                    leafID = await appendToolResult(.text(call.errorMessage!, isError: true), for: call, parent: leafID, tree: &tree, conversation: conversation)
                    continue
                }
                call.sourceLabel = tool.sourceLabel
                call.status = .awaitingPermission
                assistant.toolCalls[index] = call
                emit(.messageUpdated(assistant))
                let permission = ToolPermissionRequest(workspaceID: workspaceID, conversationID: conversation.id, call: call, tool: tool)
                emit(.toolPermissionRequested(permission))
                let decision = await delegate.requestPermission(permission)

                var result: ToolResult
                if !decision.allows || Task.isCancelled {
                    call.status = Task.isCancelled ? .cancelled : .denied
                    result = .text(Task.isCancelled ? "Cancelled." : "The user denied this tool call.", isError: true)
                } else {
                    call.status = .running
                    call.startedAt = Date()
                    assistant.toolCalls[index] = call
                    emit(.messageUpdated(assistant))
                    let started = MonotonicClock.now()
                    let assistantID = assistant.id
                    let callID = call.id
                    let emit = self.emit
                    let context = ToolExecutionContext(
                        workspaceID: workspaceID,
                        conversationID: conversation.id,
                        workingDirectory: options.workingDirectory,
                        timeout: options.toolTimeout,
                        onProgress: { fraction, message in
                            emit(.toolProgress(messageID: assistantID, callID: callID, fraction: fraction, message: message))
                        }
                    )
                    result = await toolRouter.execute(tool, call: call, context: context)
                    let elapsed = (MonotonicClock.now() - started) * 1000
                    toolMs += elapsed
                    call.durationMs = elapsed
                    call.status = Task.isCancelled ? .cancelled : (result.isError ? .failed : .completed)
                    if result.isError { call.errorMessage = result.textForModel }
                }
                assistant.toolCalls[index] = call
                tree.upsert(assistant)
                emit(.messageUpdated(assistant))
                try? await store.append(ToolCallLogEntry(
                    workspaceID: workspaceID,
                    conversationID: conversation.id,
                    toolKey: tool.key,
                    toolName: tool.name,
                    sourceLabel: tool.sourceLabel,
                    arguments: call.arguments,
                    decision: decision,
                    resultPreview: String(result.textForModel.prefix(500)),
                    isError: result.isError,
                    durationMs: call.durationMs
                ))
                leafID = await appendToolResult(result, for: call, parent: leafID, tree: &tree, conversation: conversation)
            }
            try? await store.save(assistant, workspaceID: workspaceID, indexText: false)

            totals.turns += 1
            totals.toolCalls += assistant.toolCalls.count
            totals.toolMs += toolMs
            turnStats.toolMs = toolMs
            totals.perTurn.append(turnStats)
            conversation.currentLeafID = leafID
            try? await store.save(conversation)
            emit(.conversationUpdated(conversation))

            if Task.isCancelled {
                return nil
            }
            if turn >= options.maxAgenticTurns {
                emit(.continueRequested(turns: turn))
                guard await delegate.requestContinue(conversationID: conversation.id, turns: turn) else {
                    if let id = lastAssistantID, var last = tree[id] {
                        last.metrics?.agentic = totals
                        tree.upsert(last)
                        try? await store.save(last, workspaceID: workspaceID, indexText: true)
                        emit(.messageUpdated(last))
                    }
                    return nil
                }
                turn = 0
            }
            if let steering = await delegate.takeSteeringMessage(conversationID: conversation.id), !steering.isEmpty {
                let message = Message(conversationID: conversation.id, parentID: leafID, role: .user, blocks: [.text(steering)])
                tree.upsert(message)
                try? await store.save(message, workspaceID: workspaceID, indexText: true)
                emit(.messageAdded(message))
                leafID = message.id
            }
        }
    }

    private func appendToolResult(_ result: ToolResult, for call: ToolCall, parent: UUID, tree: inout MessageTree, conversation: Conversation) async -> UUID {
        let message = Message(
            conversationID: conversation.id,
            parentID: parent,
            role: .tool,
            blocks: [.text(result.textForModel)],
            toolCallID: call.id,
            toolResult: result
        )
        tree.upsert(message)
        try? await store.save(message, workspaceID: request.workspaceID, indexText: false)
        emit(.messageAdded(message))
        return message.id
    }

    private func titleIfNeeded(_ conversation: Conversation, path: [Message]) async -> Conversation? {
        guard conversation.title == Conversation.untitled, let mode = request.options.titleMode else { return nil }
        guard let firstUser = path.first(where: { $0.role == .user }) else { return nil }
        var updated = conversation
        switch mode {
        case .firstLine:
            updated.title = ConversationTitle.fromFirstLine(firstUser.text.isEmpty ? (firstUser.attachments.first?.name ?? "") : firstUser.text)
        case .llm:
            let assistantText = path.last(where: { $0.role == .assistant })?.text ?? ""
            if let title = await ChatEngine.generateTitle(
                provider: provider,
                model: request.modelID,
                prompt: request.options.titlePrompt,
                userText: firstUser.text,
                assistantText: assistantText,
                profile: request.settings.profile
            ) {
                updated.title = title
            } else {
                updated.title = ConversationTitle.fromFirstLine(firstUser.text)
            }
        }
        return updated.title == conversation.title ? nil : updated
    }
}
