import AppKit
import GoooeeeCore
import GoooeeeMCP
import Observation
import SwiftUI

/// App-wide state shared by every workspace window: storage, connections, MCP servers, settings.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let database: AppDatabase
    let secrets: KeychainSecretStore
    let settingsStore = SettingsStore()
    let mcpHost: MCPHost
    let mcpBridge: MCPDelegateBridge

    private(set) var connections: [ServerConnection] = []
    private(set) var workspaces: [Workspace] = []
    private(set) var mcpServers: [MCPServerConfig] = []
    private(set) var mcpStates: [UUID: MCPServerState] = [:]
    private(set) var profiles = ProfileRegistry.bundled()
    private(set) var isLoaded = false
    var startupError: String?

    /// Open workspace windows.
    private var workspaceModels: [UUID: WorkspaceModel] = [:]

    var settings: AppSettings { settingsStore.settings }

    private init() {
        let secrets = KeychainSecretStore()
        self.secrets = secrets
        do {
            database = try AppDatabase.open(at: AppDatabase.defaultURL)
        } catch {
            startupError = "Couldn't open the database: \(error.localizedDescription). Using a temporary in-memory store."
            database = try! AppDatabase.inMemory()
        }
        let bridge = MCPDelegateBridge()
        mcpBridge = bridge
        mcpHost = MCPHost(secrets: secrets, delegate: bridge)
        bridge.app = self
        Task { await load() }
    }

    func load() async {
        do {
            connections = try await database.connections()
            workspaces = try await database.workspaces()
            mcpServers = try await database.mcpServers()
            var registry = ProfileRegistry.bundled()
            registry.setCustom(try await database.customProfiles())
            profiles = registry
        } catch {
            startupError = error.localizedDescription
        }
        await mcpHost.setHandshakeTimeout(settings.mcpHandshakeTimeoutSeconds)
        await mcpHost.update(servers: mcpServers)
        observeMCP()
        isLoaded = true
        let keepDays = settings.keepDeletedDays
        let retention = settings.toolLogRetentionDays
        Task.detached(priority: .background) { [database] in
            _ = try? await database.purgeDeleted(before: Date().addingTimeInterval(-Double(keepDays) * 86_400))
            try? await database.pruneToolLog(before: Date().addingTimeInterval(-Double(retention) * 86_400))
        }
    }

    private func observeMCP() {
        Task { [weak self] in
            guard let stream = await self?.mcpHost.observe() else { return }
            for await states in stream {
                guard let self else { return }
                self.mcpStates = Dictionary(uniqueKeysWithValues: states.map { ($0.id, $0) })
            }
        }
    }

    // MARK: Workspace windows

    func workspaceModel(for id: UUID) -> WorkspaceModel? {
        if let existing = workspaceModels[id] { return existing }
        guard let workspace = workspaces.first(where: { $0.id == id }),
            let connection = connections.first(where: { $0.id == workspace.connectionID })
        else { return nil }
        let model = WorkspaceModel(app: self, workspace: workspace, connection: connection)
        workspaceModels[id] = model
        return model
    }

    func windowClosed(workspaceID: UUID) {
        guard let model = workspaceModels[workspaceID] else { return }
        model.stop()
        workspaceModels[workspaceID] = nil
        if var workspace = workspaces.first(where: { $0.id == workspaceID }) {
            workspace.isOpen = false
            Task { await saveWorkspace(workspace) }
        }
    }

    var openWorkspaceIDs: Set<UUID> { Set(workspaceModels.keys) }

    // MARK: Connections

    func apiKey(for connection: ServerConnection) -> String? {
        connection.apiKeyRef.flatMap { secrets.secret(for: $0) }
    }

    @discardableResult
    func saveConnection(_ connection: ServerConnection, apiKey: String? = nil) async -> ServerConnection {
        var updated = connection
        updated.updatedAt = Date()
        if let apiKey {
            let ref = updated.apiKeyRef ?? SecretRef.apiKey(for: updated.id)
            try? secrets.setSecret(apiKey, for: ref)
            updated.apiKeyRef = apiKey.isEmpty ? nil : ref
        }
        try? await database.save(updated)
        if let index = connections.firstIndex(where: { $0.id == updated.id }) {
            connections[index] = updated
        } else {
            connections.append(updated)
        }
        for model in workspaceModels.values where model.connection.id == updated.id {
            model.connectionChanged(updated)
        }
        return updated
    }

    func deleteConnection(_ connection: ServerConnection) async {
        if let ref = connection.apiKeyRef { try? secrets.setSecret(nil, for: ref) }
        try? await database.deleteConnection(id: connection.id)
        connections.removeAll { $0.id == connection.id }
    }

    func workspacesUsing(_ connection: ServerConnection) -> [Workspace] {
        workspaces.filter { $0.connectionID == connection.id }
    }

    // MARK: Workspaces

    func createWorkspace(connection: ServerConnection, modelID: String?, name: String? = nil) async -> Workspace {
        var saved = connection
        if !connections.contains(where: { $0.id == connection.id }) {
            saved = await saveConnection(connection)
        }
        let workspace = Workspace(
            name: name ?? Workspace.defaultName(connection: saved, modelID: modelID),
            connectionID: saved.id,
            modelID: modelID,
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
            sortIndex: (workspaces.map(\.sortIndex).max() ?? 0) + 1
        )
        await saveWorkspace(workspace)
        return workspace
    }

    func saveWorkspace(_ workspace: Workspace) async {
        var updated = workspace
        updated.updatedAt = Date()
        try? await database.save(updated)
        if let index = workspaces.firstIndex(where: { $0.id == updated.id }) {
            workspaces[index] = updated
        } else {
            workspaces.append(updated)
        }
    }

    func deleteWorkspace(_ workspace: Workspace) async {
        workspaceModels[workspace.id]?.stop()
        workspaceModels[workspace.id] = nil
        try? await database.deleteWorkspace(id: workspace.id)
        workspaces.removeAll { $0.id == workspace.id }
    }

    func duplicateWorkspace(_ workspace: Workspace) async -> Workspace {
        var copy = workspace
        copy.id = UUID()
        copy.name = workspace.name + " copy"
        copy.selectedConversationID = nil
        copy.createdAt = Date()
        copy.sortIndex = (workspaces.map(\.sortIndex).max() ?? 0) + 1
        await saveWorkspace(copy)
        return copy
    }

    /// Moves a conversation to another workspace.
    func moveConversation(_ conversation: Conversation, to workspaceID: UUID) async {
        var moved = conversation
        moved.workspaceID = workspaceID
        moved.updatedAt = Date()
        try? await database.save(moved)
        workspaceModels[conversation.workspaceID]?.conversationMovedAway(conversation.id)
        await workspaceModels[workspaceID]?.reloadConversations()
    }

    // MARK: MCP servers

    func saveMCPServer(_ server: MCPServerConfig, secrets values: [String: String] = [:]) async {
        var updated = server
        for (key, value) in values {
            try? secrets.setSecret(value, for: updated.secretRef(for: key))
            updated.secretKeys.insert(key)
        }
        let index = mcpServers.firstIndex { $0.id == updated.id }
        try? await database.save(updated, sortIndex: index ?? mcpServers.count)
        if let index {
            mcpServers[index] = updated
        } else {
            mcpServers.append(updated)
        }
        await mcpHost.update(servers: mcpServers)
    }

    func deleteMCPServer(_ server: MCPServerConfig) async {
        for key in server.secretKeys { try? secrets.setSecret(nil, for: server.secretRef(for: key)) }
        try? await database.deleteMCPServer(id: server.id)
        mcpServers.removeAll { $0.id == server.id }
        await mcpHost.update(servers: mcpServers)
    }

    func importMCPServers(from data: Data) async throws -> Int {
        let imported = try MCPServersJSON.parse(data)
        for server in imported where !mcpServers.contains(where: { $0.name == server.name }) {
            await saveMCPServer(server)
        }
        return imported.count
    }

    // MARK: Profiles

    func saveCustomProfiles(_ profiles: [ModelProfile]) async {
        try? await database.saveCustomProfiles(profiles)
        var registry = ProfileRegistry.bundled()
        registry.setCustom(profiles)
        self.profiles = registry
    }

    // MARK: Roots for MCP

    var workspaceRoots: [URL] {
        workspaceModels.values.compactMap { $0.workspace.workingDirectory.map { URL(fileURLWithPath: $0) } }
    }
}

/// Answers server-initiated MCP requests by asking the user in the frontmost workspace window.
final class MCPDelegateBridge: MCPClientDelegate, @unchecked Sendable {
    @MainActor weak var app: AppModel?

    func elicit(serverName: String, message: String, schema: JSONValue) async -> MCPElicitationResponse {
        await MainActor.run { ElicitationCenter.shared }.request(serverName: serverName, message: message, schema: schema)
    }

    func elicitURL(serverName: String, message: String, url: URL) async -> MCPElicitationResponse {
        let open = await MainActor.run { () -> Bool in
            let alert = NSAlert()
            alert.messageText = "\(serverName) wants you to open a link"
            alert.informativeText = "\(message)\n\n\(url.absoluteString)"
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Decline")
            return alert.runModal() == .alertFirstButtonReturn
        }
        if open {
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
            return .accept([:])
        }
        return .decline
    }

    func sample(serverName: String, request: MCPSamplingRequest) async throws -> String {
        let workspace = await MainActor.run { () -> WorkspaceModel? in
            NSApp.keyWindow.flatMap { WorkspaceModel.model(for: $0) } ?? WorkspaceModel.lastActive
        }
        guard let workspace else { throw ToolError.unavailable("No workspace window is open to run the request.") }
        let approved = await MainActor.run { () -> Bool in
            let alert = NSAlert()
            alert.messageText = "\(serverName) wants to use the model"
            alert.informativeText = "The MCP server asks \(workspace.workspace.name) to generate a reply (up to \(request.maxTokens) tokens).\n\n"
                + (request.messages.last?.text.prefix(400).description ?? "")
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Deny")
            return alert.runModal() == .alertFirstButtonReturn
        }
        guard approved else { throw ToolError.unavailable("The user declined the sampling request.") }
        return try await workspace.sample(request)
    }

    func roots() async -> [URL] {
        await MainActor.run { app?.workspaceRoots ?? [] }
    }
}
