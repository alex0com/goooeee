import AppKit
import GoooeeeCore
import GoooeeeTranscript
import Observation

/// Receives transcript row changes (the AppKit transcript view).
@MainActor
protocol TranscriptSink: AnyObject {
    func transcriptDidUpdate(_ update: TranscriptUpdate)
}

/// One open conversation: its message tree, the streaming state and the transcript rows.
///
/// Engine events only mutate in-memory state and mark messages dirty. The transcript view's
/// display link calls `flush()` at most once per frame, which rebuilds the rows of the dirty
/// messages and hands the table a minimal update.
@MainActor
@Observable
final class ChatController {
    let id: UUID
    @ObservationIgnored weak var workspace: WorkspaceModel?
    private(set) var conversation: Conversation
    @ObservationIgnored private(set) var tree = MessageTree([])
    @ObservationIgnored private(set) var transcript: TranscriptState
    private(set) var isLoaded = false
    private(set) var isGenerating = false
    private(set) var lastError: InferenceError?
    /// Throttled copies for SwiftUI (≈10 Hz).
    private(set) var liveMetrics: GenerationMetrics?
    private(set) var liveProgress: PromptProgress?
    private(set) var pathMessageCount = 0

    var draft: Draft {
        didSet { scheduleDraftSave() }
    }
    /// A message typed while the agent runs; sent before its next turn (or after it finishes).
    var pendingSteering: String?

    /// Thinking blocks the user expanded or collapsed explicitly (row IDs → expanded).
    var thinkingExpansion: [String: Bool] = [:]
    var expandedTools: Set<String> = []
    var rawOutputMessages: Set<UUID> = []
    var isPinnedToBottom = true

    @ObservationIgnored weak var sink: TranscriptSink? {
        didSet {
            if sink != nil, isLoaded {
                needsFlush = false
                sink?.transcriptDidUpdate(.full)
            }
        }
    }
    @ObservationIgnored private var dirty = Set<UUID>()
    @ObservationIgnored private var streaming = Set<UUID>()
    @ObservationIgnored private var progress: [UUID: PromptProgress] = [:]
    @ObservationIgnored private(set) var needsFlush = false
    @ObservationIgnored private var flushScheduled = false
    @ObservationIgnored private var lastLiveUpdate: TimeInterval = 0
    @ObservationIgnored private var draftSaveTask: Task<Void, Never>?
    @ObservationIgnored private var generationTask: Task<Void, Never>?

    init(conversation: Conversation, workspace: WorkspaceModel) {
        self.id = conversation.id
        self.conversation = conversation
        self.workspace = workspace
        self.draft = conversation.draft ?? Draft()
        self.transcript = TranscriptState()
        transcript.options = makeOptions()
        Task { await load() }
    }

    private var database: AppDatabase? { workspace?.app.database }
    private var settings: AppSettings { workspace?.app.settings ?? AppSettings() }

    func makeOptions() -> TranscriptOptions {
        let settings = self.settings
        return TranscriptOptions(
            renderUserMarkdown: settings.renderUserMessagesAsMarkdown,
            renderMath: settings.renderMath,
            showStats: settings.showMessageStats,
            enableContinue: settings.enableContinue,
            canStopReasoning: workspace?.canStopReasoning ?? false
        )
    }

    // MARK: Loading

    func load() async {
        let messages = (try? await database?.messages(conversationID: id)) ?? []
        tree = MessageTree(messages)
        _ = transcript.load(tree: tree, leafID: conversation.currentLeafID, streaming: streaming, progress: progress)
        pathMessageCount = transcript.path.count
        isLoaded = true
        sink?.transcriptDidUpdate(.full)
    }

    /// Re-renders everything (settings or fonts changed).
    func rebuildTranscript() {
        transcript.options = makeOptions()
        let update = transcript.rebuildAll()
        sink?.transcriptDidUpdate(update)
    }

    func loadOlder() -> TranscriptUpdate {
        transcript.loadOlder()
    }

    func conversationChanged(_ updated: Conversation) {
        let leafChanged = updated.currentLeafID != conversation.currentLeafID
        conversation.title = updated.title
        conversation.isPinned = updated.isPinned
        conversation.overrides = updated.overrides
        conversation.tools = updated.tools
        if leafChanged {
            conversation.currentLeafID = updated.currentLeafID
            reloadTranscript()
        }
    }

    var currentLeafID: UUID? {
        conversation.currentLeafID ?? transcript.path.last?.id
    }

    var path: [Message] { transcript.path }

    // MARK: Dirty tracking and flushing

    private func markDirty(_ id: UUID) {
        dirty.insert(id)
        needsFlush = true
        scheduleFlushIfIdle()
    }

    /// Without an active display link (nothing streaming), flush on the next run loop turn.
    private func scheduleFlushIfIdle() {
        guard !isGenerating, !flushScheduled else { return }
        flushScheduled = true
        RunLoop.main.perform { [weak self] in
            MainActor.assumeIsolated {
                self?.flushScheduled = false
                self?.flush()
            }
        }
    }

    /// Called by the display link once per frame while streaming.
    func flush() {
        guard needsFlush, isLoaded else { return }
        needsFlush = false
        let changed = dirty.compactMap { tree[$0] }
        dirty.removeAll()
        let update = transcript.update(messages: changed, leafID: conversation.currentLeafID, streaming: streaming, progress: progress)
        pathMessageCount = transcript.path.count
        if !update.isEmpty { sink?.transcriptDidUpdate(update) }
    }

    private func reloadTranscript() {
        _ = transcript.load(tree: tree, leafID: conversation.currentLeafID, streaming: streaming, progress: progress)
        pathMessageCount = transcript.path.count
        sink?.transcriptDidUpdate(.full)
    }

    // MARK: Sending

    var canSend: Bool {
        !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.attachments.isEmpty
    }

    func send() {
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = draft.attachments
        guard !text.isEmpty || !attachments.isEmpty else { return }
        if isGenerating {
            pendingSteering = [pendingSteering, text].compactMap { $0 }.joined(separator: "\n\n")
            draft = Draft()
            return
        }
        guard let workspace else { return }
        draft = Draft()
        var message = Message(conversationID: id, parentID: currentLeafID, role: .user, blocks: text.isEmpty ? [] : [.text(text)], attachments: attachments)
        message.modelID = workspace.workspace.modelID
        tree.upsert(message)
        conversation.currentLeafID = message.id
        conversation.updatedAt = Date()
        conversation.preview = message.preview
        conversation.draft = nil
        if conversation.title == Conversation.untitled, settings.titleMode == .firstLine {
            conversation.title = ConversationTitle.fromFirstLine(text.isEmpty ? (attachments.first?.name ?? "") : text)
        }
        workspace.save(conversation)
        let workspaceID = workspace.workspace.id
        Task { try? await database?.save(message, workspaceID: workspaceID, indexText: true) }
        markDirty(message.id)
        isPinnedToBottom = true
        startGeneration(.reply(parentID: message.id))
    }

    /// Generates a new answer for the same question (a new branch).
    func regenerate(_ messageID: UUID) {
        guard !isGenerating, let message = tree[messageID], message.role == .assistant, let parent = message.parentID else { return }
        startGeneration(.reply(parentID: parent))
    }

    /// Generates a reply to the last message (e.g. after an error with no assistant message).
    func retry() {
        guard !isGenerating, let leaf = currentLeafID, let message = tree[leaf] else { return }
        if message.role == .assistant {
            regenerate(leaf)
        } else {
            startGeneration(.reply(parentID: leaf))
        }
    }

    /// Edits a user message as a new branch and asks again.
    func editAndResend(_ messageID: UUID, text: String) {
        guard !isGenerating, let original = tree[messageID], original.role == .user, let workspace else { return }
        let message = Message(
            conversationID: id,
            parentID: original.parentID,
            role: .user,
            blocks: [.text(text)],
            attachments: original.attachments,
            modelID: workspace.workspace.modelID,
            editedAt: Date()
        )
        tree.upsert(message)
        conversation.currentLeafID = message.id
        conversation.updatedAt = Date()
        workspace.save(conversation)
        let workspaceID = workspace.workspace.id
        Task { try? await database?.save(message, workspaceID: workspaceID, indexText: true) }
        reloadTranscript()
        startGeneration(.reply(parentID: message.id))
    }

    /// Edits a message in place (no new branch). Edited assistant text is used as context later.
    func saveEdit(_ messageID: UUID, text: String) {
        guard var message = tree[messageID], let workspace else { return }
        message.setText(text)
        message.editedAt = Date()
        tree.upsert(message)
        let workspaceID = workspace.workspace.id
        Task { try? await database?.save(message, workspaceID: workspaceID, indexText: true) }
        markDirty(messageID)
    }

    func continueMessage(_ messageID: UUID) {
        guard !isGenerating, let message = tree[messageID], message.role == .assistant else { return }
        startGeneration(.continueMessage(messageID))
    }

    /// Deletes a message and everything after it on its branch.
    func deleteMessage(_ messageID: UUID) {
        guard !isGenerating, let message = tree[messageID], let workspace else { return }
        let removed = tree.remove(subtreeOf: messageID)
        Task { try? await database?.deleteMessages(ids: removed) }
        conversation.currentLeafID = tree.latestLeaf(from: message.parentID) ?? message.parentID
        conversation.updatedAt = Date()
        workspace.save(conversation)
        reloadTranscript()
    }

    func switchBranch(from messageID: UUID, offset: Int) {
        guard !isGenerating, let leaf = tree.leafAfterSwitching(from: messageID, offset: offset), let workspace else { return }
        conversation.currentLeafID = leaf
        workspace.save(conversation)
        reloadTranscript()
    }

    /// ⌘[ / ⌘]: switch the branch of the last message that has siblings.
    func switchLastBranch(offset: Int) {
        for message in transcript.path.reversed() where tree.siblings(of: message.id).count > 1 {
            switchBranch(from: message.id, offset: offset)
            return
        }
    }

    // MARK: Generation

    private func startGeneration(_ mode: GenerationRequest.Mode) {
        guard let workspace else { return }
        lastError = nil
        isGenerating = true
        let conversationSnapshot = conversation
        let messages = tree.allMessages
        generationTask = Task { [weak self] in
            guard let self else { return }
            let request: GenerationRequest
            do {
                let settings = try workspace.effectiveSettings(for: conversationSnapshot)
                let tools = await workspace.tools(for: conversationSnapshot)
                request = GenerationRequest(
                    mode: mode,
                    workspaceID: workspace.workspace.id,
                    conversation: conversationSnapshot,
                    messages: messages,
                    connection: workspace.connection,
                    apiKey: workspace.apiKey,
                    modelID: workspace.workspace.modelID,
                    settings: settings,
                    supportsVision: workspace.supportsVision,
                    tools: tools,
                    options: GenerationOptions(settings: workspace.app.settings, workingDirectory: workspace.workspace.workingDirectory)
                )
            } catch {
                self.isGenerating = false
                self.lastError = InferenceError.invalidRequest(error.localizedDescription)
                workspace.showError(error.localizedDescription)
                return
            }
            let stream = await workspace.engine.start(request)
            for await event in stream {
                self.handle(event)
            }
        }
    }

    private func handle(_ event: ChatEvent) {
        switch event {
        case .messageAdded(let message):
            tree.upsert(message)
            if message.role == .assistant, message.state == .streaming { streaming.insert(message.id) }
            markDirty(message.id)
        case .streaming(let messageID, let changes):
            guard var message = tree[messageID] else { return }
            for change in changes {
                switch change {
                case .promptProgress(let value):
                    progress[messageID] = value
                    updateLive(progress: value)
                case .metricsUpdated(let metrics):
                    updateLive(metrics: metrics)
                default:
                    break
                }
                message.apply(change)
            }
            if !message.blocks.isEmpty || !message.toolCalls.isEmpty { progress[messageID] = nil }
            tree.upsert(message)
            markDirty(messageID)
        case .messageUpdated(let message):
            tree.upsert(message)
            if message.state != .streaming {
                streaming.remove(message.id)
                progress[message.id] = nil
            } else {
                streaming.insert(message.id)
            }
            markDirty(message.id)
        case .conversationUpdated(let updated):
            conversation.currentLeafID = updated.currentLeafID
            conversation.updatedAt = updated.updatedAt
            conversation.preview = updated.preview.isEmpty ? conversation.preview : updated.preview
            if conversation.title == Conversation.untitled || updated.title != Conversation.untitled {
                conversation.title = updated.title
            }
            workspace?.update(conversation)
            needsFlush = true
        case .toolPermissionRequested:
            break
        case .toolProgress(let messageID, let callID, let fraction, let text):
            guard var message = tree[messageID], let index = message.toolCalls.firstIndex(where: { $0.id == callID }) else { return }
            message.toolCalls[index].progress = fraction
            message.toolCalls[index].progressMessage = text
            tree.upsert(message)
            markDirty(messageID)
        case .continueRequested:
            break
        case .finished(let error):
            isGenerating = false
            let wasStreaming = streaming
            streaming.removeAll()
            progress = [:]
            liveProgress = nil
            for id in wasStreaming { markDirty(id) }
            if let error {
                lastError = error
            }
            workspace?.cancelPending(conversationID: id)
            needsFlush = true
            scheduleFlushIfIdle()
            if let steering = pendingSteering, !steering.isEmpty {
                pendingSteering = nil
                draft = Draft(text: steering)
                send()
            }
        }
    }

    private func updateLive(metrics: GenerationMetrics? = nil, progress: PromptProgress? = nil) {
        let now = ProcessInfo.processInfo.systemUptime
        if let progress { liveProgress = progress }
        guard let metrics else { return }
        if now - lastLiveUpdate > 0.1 || liveMetrics == nil {
            lastLiveUpdate = now
            liveMetrics = metrics
        }
    }

    func stop() {
        guard let workspace else { return }
        Task { await workspace.engine.cancel(conversationID: id) }
        workspace.cancelPending(conversationID: id)
    }

    /// llama.cpp: end the thinking phase of the running completion.
    func stopThinking() {
        guard let workspace, let messageID = streaming.first, let completionID = tree[messageID]?.completionID else { return }
        let client = LlamaCppClient(connection: workspace.connection, apiKey: workspace.apiKey)
        let model = workspace.workspace.modelID
        Task {
            do {
                _ = try await client.stopReasoning(completionID: completionID, model: model)
            } catch {
                workspace.showError("Couldn't stop thinking: \(error.localizedDescription)")
            }
        }
    }

    func takeSteeringMessage() -> String? {
        defer { pendingSteering = nil }
        return pendingSteering
    }

    func permissionRequested(_ request: ToolPermissionRequest) {
        if let messageID = tree.allMessages.last(where: { $0.toolCalls.contains { $0.id == request.call.id } })?.id {
            markDirty(messageID)
        }
        needsFlush = true
    }

    // MARK: Drafts

    private func scheduleDraftSave() {
        draftSaveTask?.cancel()
        let draft = self.draft
        draftSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let self, let workspace = self.workspace else { return }
            self.conversation.draft = draft.isEmpty ? nil : draft
            if var stored = workspace.conversation(self.id) {
                stored.draft = self.conversation.draft
                workspace.update(stored)
                try? await workspace.app.database.save(stored)
            }
        }
    }

    // MARK: Copy

    func copyText(of messageID: UUID, includeReasoning: Bool) -> String {
        tree[messageID]?.copyText(includeReasoning: includeReasoning) ?? ""
    }

    /// Context usage for the inspector meter.
    var contextUsage: ContextUsage {
        ContextUsage.estimate(path: transcript.path, contextLength: workspace?.contextLength)
    }

    /// Mean speeds over this conversation's answers.
    var averages: (generation: Double?, prompt: Double?, tokens: Int) {
        let metrics = transcript.path.compactMap(\.metrics)
        let generation = metrics.compactMap { $0.generationSpeed?.value }
        let prompt = metrics.compactMap { $0.promptSpeed?.value }
        let tokens = metrics.reduce(0) { $0 + $1.generatedTokens }
        return (
            generation.isEmpty ? nil : generation.reduce(0, +) / Double(generation.count),
            prompt.isEmpty ? nil : prompt.reduce(0, +) / Double(prompt.count),
            tokens
        )
    }
}
