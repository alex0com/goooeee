import AppKit
import GoooeeeCore
import GoooeeeMCP
import Observation
import SwiftUI

/// A short message shown at the bottom of the window, optionally with an action (Undo).
struct Toast: Identifiable, Equatable {
    let id = UUID()
    var message: String
    var actionTitle: String?
    var action: (@MainActor () -> Void)?
    var isError = false

    static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }
}

/// One workspace window: a server connection, a model, its conversations, tools and terminal.
@MainActor
@Observable
final class WorkspaceModel {
    let app: AppModel
    var workspace: Workspace
    private(set) var connection: ServerConnection
    private(set) var status: ServerStatus = .unknown
    private(set) var capabilities = ServerCapabilities()
    private(set) var conversations: [Conversation] = []
    private(set) var deletedConversations: [Conversation] = []
    private(set) var grants: [ToolGrant] = []
    private(set) var availableTools: [ToolDefinition] = []
    var selectedConversationID: UUID? {
        didSet {
            guard selectedConversationID != oldValue else { return }
            workspace.selectedConversationID = selectedConversationID
            persistWorkspaceSoon()
        }
    }
    var toast: Toast?
    var isSearchPresented = false
    var isNewWorkspacePresented = false
    var isRenamingConversationID: UUID?
    var showRecentlyDeleted = false

    /// Tool calls waiting for Allow/Deny, by call ID.
    private(set) var pendingPermissions: [String: ToolPermissionRequest] = [:]
    @ObservationIgnored private var permissionContinuations: [String: CheckedContinuation<PermissionDecision, Never>] = [:]
    /// The agentic loop reached its turn limit and asks whether to continue.
    private(set) var pendingContinue: (conversationID: UUID, turns: Int)?
    @ObservationIgnored private var continueContinuation: CheckedContinuation<Bool, Never>?

    @ObservationIgnored private(set) var controllers: [UUID: ChatController] = [:]
    let terminal: TerminalSession
    @ObservationIgnored private(set) var engine: ChatEngine!
    @ObservationIgnored private var llamaTools: LlamaServerToolSource?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored weak var window: NSWindow?

    // MARK: Registry (for MCP sampling and menu commands)

    private static var live: [ObjectIdentifier: WeakModel] = [:]
    static var lastActive: WorkspaceModel?

    private struct WeakModel { weak var model: WorkspaceModel? }

    static func model(for window: NSWindow) -> WorkspaceModel? {
        live.values.compactMap(\.model).first { $0.window === window }
    }

    init(app: AppModel, workspace: Workspace, connection: ServerConnection) {
        self.app = app
        self.workspace = workspace
        self.connection = connection
        self.selectedConversationID = workspace.selectedConversationID
        self.terminal = TerminalSession(workingDirectory: workspace.workingDirectory)
        rebuildEngine()
        Self.live[ObjectIdentifier(self)] = WeakModel(model: self)
        Self.lastActive = self
    }

    // MARK: Lifecycle

    func start() {
        Task { await reloadConversations() }
        Task { await reloadGrants() }
        startStatusPolling()
        if workspace.isOpen == false {
            workspace.isOpen = true
            persistWorkspaceSoon()
        }
    }

    func stop() {
        statusTask?.cancel()
        statusTask = nil
        Task { await engine.cancelAll() }
        terminal.terminate()
        Self.live[ObjectIdentifier(self)] = nil
        if Self.lastActive === self { Self.lastActive = nil }
    }

    func becameActive() {
        Self.lastActive = self
    }

    private func rebuildEngine() {
        let llama: LlamaServerToolSource? = connection.engine == .llamaCpp
            ? LlamaServerToolSource(client: LlamaCppClient(connection: connection, apiKey: app.apiKey(for: connection)))
            : nil
        llamaTools = llama
        var providers: [any ToolProviding] = [app.mcpHost]
        if let llama { providers.append(llama) }
        engine = ChatEngine(store: app.database, toolRouter: ToolRouter(providers: providers), delegate: self)
    }

    func connectionChanged(_ updated: ServerConnection) {
        connection = updated
        if controllers.values.allSatisfy({ !$0.isGenerating }) { rebuildEngine() }
        Task { await refreshStatus() }
    }

    // MARK: Derived

    var profile: ModelProfile {
        app.profiles.resolve(modelID: workspace.modelID, explicitID: connection.profileID)
    }

    var supportsVision: Bool {
        connection.supportsImages ?? capabilities.model(id: workspace.modelID)?.supportsVision ?? capabilities.vision ?? profile.vision ?? false
    }

    var supportsTools: Bool {
        connection.supportsTools ?? profile.tools ?? true
    }

    var apiKey: String? { app.apiKey(for: connection) }

    var contextLength: Int? { capabilities.contextLength(for: workspace.modelID) }

    var title: String {
        let model = workspace.modelID.map(ModelNameFormatter.shortName) ?? "no model"
        return "\(workspace.name) · \(connection.engine.displayName) \(connection.portDescription) · \(model)"
    }

    var canStopReasoning: Bool { connection.engine == .llamaCpp && connection.apiStyle == .openAIChat }

    func effectiveSettings(for conversation: Conversation?) throws -> EffectiveSettings {
        try SettingsResolver(
            connection: connection,
            workspace: workspace.overrides,
            chat: conversation?.overrides ?? SettingsOverrides(),
            profile: profile,
            serverDefaults: capabilities.defaultSampling
        ).resolve()
    }

    func toolSelection(for conversation: Conversation?) -> ToolSelection {
        conversation?.tools ?? workspace.tools
    }

    func tools(for conversation: Conversation?) async -> [ToolDefinition] {
        guard supportsTools else { return [] }
        let selection = toolSelection(for: conversation)
        guard !selection.isEmpty else { return [] }
        var all: [ToolDefinition] = []
        if !selection.mcpServerIDs.isEmpty {
            all += await app.mcpHost.tools(for: selection)
        }
        if let llamaTools, selection.serverToolsEnabled {
            all += await llamaTools.tools(for: selection)
        }
        all = all.filter { !selection.disabledToolKeys.contains($0.key) }
        return ToolDefinition.assignWireNames(all)
    }

    /// Refreshes the tool list shown in the inspector.
    func refreshAvailableTools() async {
        var selection = workspace.tools
        selection.disabledToolKeys = []
        var all: [ToolDefinition] = []
        if !selection.mcpServerIDs.isEmpty { all += await app.mcpHost.tools(for: selection) }
        if let llamaTools, capabilities.serverToolsAvailable {
            var serverSelection = selection
            serverSelection.serverToolsEnabled = true
            all += await llamaTools.tools(for: serverSelection)
        }
        availableTools = all
    }

    // MARK: Server status

    private func startStatusPolling() {
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshStatus()
                let interval: UInt64 = self.status.isOnline ? 15 : 5
                try? await Task.sleep(nanoseconds: interval * 1_000_000_000)
            }
        }
    }

    func refreshStatus() async {
        if case .starting = status, terminal.isServerStarting {
            // The terminal's health wait updates the status.
        }
        let probe = ServerProbe(connection: connection, apiKey: apiKey)
        let result = await probe.probe(modelID: workspace.modelID)
        if terminal.isServerStarting, !result.status.isOnline {
            status = .starting
        } else {
            status = result.status
            if result.status.isOnline { terminal.isServerStarting = false }
        }
        if result.capabilities.reachable {
            capabilities = result.capabilities
            if workspace.modelID == nil, let first = capabilities.models.first(where: { $0.loadState != .unloaded }) ?? capabilities.models.first {
                setModel(first.id)
            }
        }
    }

    // MARK: Model

    func setModel(_ modelID: String) {
        guard modelID != workspace.modelID else { return }
        workspace.modelID = modelID
        if workspace.name == Workspace.defaultName(connection: connection, modelID: nil) || workspace.name.hasPrefix(connection.name + " · ") {
            workspace.name = Workspace.defaultName(connection: connection, modelID: modelID)
        }
        persistWorkspaceSoon()
        Task {
            if capabilities.isRouter, capabilities.model(id: modelID)?.loadState != .loaded {
                status = .loadingModel
                do {
                    try await LlamaCppClient(connection: connection, apiKey: apiKey).loadModel(modelID)
                } catch {
                    showError("Couldn't load \(ModelNameFormatter.shortName(modelID)): \(error.localizedDescription)")
                }
            }
            await refreshStatus()
        }
    }

    // MARK: Conversations

    func reloadConversations() async {
        conversations = (try? await app.database.conversations(workspaceID: workspace.id)) ?? []
        deletedConversations = (try? await app.database.deletedConversations(workspaceID: workspace.id)) ?? []
        if let selected = selectedConversationID, !conversations.contains(where: { $0.id == selected }) {
            selectedConversationID = conversations.first?.id
        }
        if selectedConversationID == nil {
            selectedConversationID = conversations.first?.id
        }
    }

    func conversation(_ id: UUID) -> Conversation? {
        conversations.first { $0.id == id }
    }

    /// Creates an empty conversation and selects it (⌘N).
    func newConversation() {
        // Reuse an existing empty chat instead of piling up empty ones.
        if let empty = conversations.first(where: { $0.currentLeafID == nil && $0.title == Conversation.untitled }) {
            selectedConversationID = empty.id
            return
        }
        let conversation = Conversation(workspaceID: workspace.id)
        conversations.insert(conversation, at: 0)
        selectedConversationID = conversation.id
        Task { try? await app.database.save(conversation) }
    }

    func update(_ conversation: Conversation) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index] = conversation
        } else if !conversation.isDeleted {
            conversations.insert(conversation, at: 0)
        }
        conversations.sort { $0.updatedAt > $1.updatedAt }
    }

    func save(_ conversation: Conversation) {
        update(conversation)
        controllers[conversation.id]?.conversationChanged(conversation)
        Task { try? await app.database.save(conversation) }
    }

    func rename(_ id: UUID, to title: String) {
        guard var conversation = conversation(id) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        conversation.title = trimmed.isEmpty ? Conversation.untitled : trimmed
        save(conversation)
    }

    func togglePin(_ id: UUID) {
        guard var conversation = conversation(id) else { return }
        conversation.isPinned.toggle()
        save(conversation)
    }

    /// Moves conversations to Recently Deleted with an Undo toast (swipe, ⌘⌫, context menu).
    func delete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for id in ids {
            if let controller = controllers[id], controller.isGenerating { controller.stop() }
        }
        let removed = conversations.filter { ids.contains($0.id) }
        let nextSelection = nextConversation(afterDeleting: ids)
        conversations.removeAll { ids.contains($0.id) }
        let now = Date()
        deletedConversations.insert(contentsOf: removed.map { var copy = $0; copy.deletedAt = now; return copy }, at: 0)
        if let selected = selectedConversationID, ids.contains(selected) {
            selectedConversationID = nextSelection
        }
        for id in ids { controllers[id] = nil }
        Task { try? await app.database.softDelete(conversationIDs: Array(ids), at: now) }
        let count = removed.count
        toast = Toast(
            message: count == 1 ? "Deleted “\(removed.first?.title ?? "chat")”" : "Deleted \(count) chats",
            actionTitle: "Undo",
            action: { [weak self] in self?.restore(ids) }
        )
    }

    func restore(_ ids: Set<UUID>) {
        let restored = deletedConversations.filter { ids.contains($0.id) }.map { var copy = $0; copy.deletedAt = nil; return copy }
        deletedConversations.removeAll { ids.contains($0.id) }
        for conversation in restored { update(conversation) }
        if let first = restored.first { selectedConversationID = first.id }
        Task { try? await app.database.restore(conversationIDs: Array(ids)) }
        toast = nil
    }

    func purge(_ ids: Set<UUID>) {
        deletedConversations.removeAll { ids.contains($0.id) }
        Task { try? await app.database.purge(conversationIDs: Array(ids)) }
    }

    func emptyRecentlyDeleted() {
        purge(Set(deletedConversations.map(\.id)))
    }

    private func nextConversation(afterDeleting ids: Set<UUID>) -> UUID? {
        guard let selected = selectedConversationID, ids.contains(selected),
            let index = conversations.firstIndex(where: { $0.id == selected })
        else { return selectedConversationID }
        let remaining = conversations.enumerated().filter { !ids.contains($0.element.id) }
        return remaining.first { $0.offset > index }?.element.id ?? remaining.last?.element.id
    }

    func conversationMovedAway(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        controllers[id] = nil
        if selectedConversationID == id { selectedConversationID = conversations.first?.id }
    }

    func controller(for id: UUID) -> ChatController? {
        if let existing = controllers[id] { return existing }
        guard let conversation = conversation(id) else { return nil }
        let controller = ChatController(conversation: conversation, workspace: self)
        controllers[id] = controller
        return controller
    }

    var selectedController: ChatController? {
        selectedConversationID.flatMap { controller(for: $0) }
    }

    // MARK: Workspace settings

    func updateWorkspace(_ change: (inout Workspace) -> Void) {
        change(&workspace)
        persistWorkspaceSoon()
    }

    private func persistWorkspaceSoon() {
        saveTask?.cancel()
        let snapshot = workspace
        saveTask = Task { [app] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await app.saveWorkspace(snapshot)
        }
    }

    // MARK: Tool permissions

    func reloadGrants() async {
        grants = (try? await app.database.toolGrants(workspaceID: workspace.id)) ?? []
    }

    func resolvePermission(callID: String, decision: PermissionDecision) {
        guard let request = pendingPermissions.removeValue(forKey: callID) else { return }
        switch decision {
        case .alwaysTool:
            addGrant(ToolGrant(workspaceID: workspace.id, scope: .tool, target: request.tool.key, label: request.tool.name))
        case .alwaysServer:
            addGrant(ToolGrant(workspaceID: workspace.id, scope: .server, target: request.tool.sourceID, label: request.tool.sourceName))
        default:
            break
        }
        permissionContinuations.removeValue(forKey: callID)?.resume(returning: decision)
    }

    private func addGrant(_ grant: ToolGrant) {
        grants.append(grant)
        Task { try? await app.database.save(grant) }
    }

    func revokeGrant(_ grant: ToolGrant) {
        grants.removeAll { $0.id == grant.id }
        Task { try? await app.database.deleteGrant(id: grant.id) }
    }

    func resolveContinue(_ shouldContinue: Bool) {
        pendingContinue = nil
        continueContinuation?.resume(returning: shouldContinue)
        continueContinuation = nil
    }

    /// Denies everything waiting for this conversation (used when a generation is stopped).
    func cancelPending(conversationID: UUID) {
        for (id, request) in pendingPermissions where request.conversationID == conversationID {
            resolvePermission(callID: id, decision: .deny)
        }
        if pendingContinue?.conversationID == conversationID { resolveContinue(false) }
    }

    // MARK: Sampling for MCP servers

    func sample(_ request: MCPSamplingRequest) async throws -> String {
        var messages: [ChatMessage] = []
        if let system = request.systemPrompt { messages.append(.text(.system, system)) }
        for message in request.messages {
            messages.append(.text(message.role == "assistant" ? .assistant : .user, message.text))
        }
        var settings = try effectiveSettings(for: nil)
        settings.sampling[.maxTokens] = ResolvedValue(value: .int(request.maxTokens), source: .connection)
        if let temperature = request.temperature {
            settings.sampling[.temperature] = ResolvedValue(value: .double(temperature), source: .connection)
        }
        let provider = ProviderFactory.make(connection: connection, apiKey: apiKey)
        var accumulator = StreamAccumulator(splitter: ReasoningSplitter(format: profile.reasoning))
        for try await event in provider.stream(ChatRequest(model: workspace.modelID, messages: messages, settings: settings)) {
            _ = accumulator.apply(event)
        }
        return accumulator.currentText
    }

    // MARK: Toasts

    func showError(_ message: String) {
        toast = Toast(message: message, isError: true)
    }

    func showInfo(_ message: String) {
        toast = Toast(message: message)
    }

    // MARK: Terminal

    func startServer() {
        guard let command = connection.launch?.command, !command.isEmpty else {
            showError("This connection has no launch command. Add one in the connection's Launch tab.")
            return
        }
        workspace.showTerminal = true
        persistWorkspaceSoon()
        status = .starting
        terminal.startServer(command: command, workingDirectory: connection.launch?.workingDirectory ?? workspace.workingDirectory,
                             environment: connection.launch?.environment ?? [:])
        let timeout = connection.launch?.startupTimeout ?? 300
        Task { [weak self] in
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                await self.refreshStatus()
                if self.status.isOnline {
                    self.terminal.isServerStarting = false
                    self.showInfo("\(self.connection.name) is online.")
                    return
                }
            }
            self?.terminal.isServerStarting = false
            await self?.refreshStatus()
        }
    }

    func stopServer() {
        terminal.interrupt()
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await refreshStatus()
        }
    }

    /// Shows the terminal and pastes a code block at its prompt; the user presses Return.
    func pasteInTerminal(_ code: String) {
        workspace.showTerminal = true
        persistWorkspaceSoon()
        terminal.paste(code)
    }

    /// Where a code block's Save As starts: the terminal's folder, so a following command such as
    /// `bash hello.sh` finds the file.
    var saveDirectory: URL {
        let path = terminal.currentDirectory ?? workspace.workingDirectory ?? NSHomeDirectory()
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Saves a code block with a save panel on the workspace window. Scripts with a `#!` line are
    /// made executable.
    func saveCode(_ code: String, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.directoryURL = saveDirectory
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let write: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try Data((code.hasSuffix("\n") ? code : code + "\n").utf8).write(to: url, options: .atomic)
                if code.hasPrefix("#!") {
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
                }
                self?.showInfo("Saved \(url.lastPathComponent)" + (code.hasPrefix("#!") ? " (executable)" : ""))
            } catch {
                self?.showError("Couldn't save \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: write)
        } else {
            write(panel.runModal())
        }
    }
}

// MARK: - AgenticDelegate

extension WorkspaceModel: AgenticDelegate {
    func requestPermission(_ request: ToolPermissionRequest) async -> PermissionDecision {
        if grants.contains(where: { $0.covers(request.tool) }) {
            return .allowOnce
        }
        return await withCheckedContinuation { continuation in
            pendingPermissions[request.call.id] = request
            permissionContinuations[request.call.id] = continuation
            controllers[request.conversationID]?.permissionRequested(request)
            if window?.isKeyWindow != true {
                NSApp.requestUserAttention(.informationalRequest)
            }
        }
    }

    func requestContinue(conversationID: UUID, turns: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            continueContinuation?.resume(returning: false)
            continueContinuation = continuation
            pendingContinue = (conversationID, turns)
        }
    }

    func takeSteeringMessage(conversationID: UUID) async -> String? {
        controllers[conversationID]?.takeSteeringMessage()
    }
}
