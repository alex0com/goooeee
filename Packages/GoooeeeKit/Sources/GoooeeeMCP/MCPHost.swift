import Foundation
import GoooeeeCore
import MCP

/// goooeee's MCP host: owns one connection per configured server, shared by all workspaces.
///
/// Workspaces choose which servers they use (`ToolSelection.mcpServerIDs`); servers connect on
/// demand the first time a workspace needs their tools, prompts or resources.
public actor MCPHost: ToolProviding {
    private var configs: [UUID: MCPServerConfig] = [:]
    private var order: [UUID] = []
    private var connections: [UUID: MCPServerConnection] = [:]
    private var states: [UUID: MCPServerState] = [:]
    private var observers: [UUID: AsyncStream<[MCPServerState]>.Continuation] = [:]
    private let secrets: SecretStore
    private var delegate: MCPClientDelegate?
    public var handshakeTimeout: TimeInterval = 10

    public init(secrets: SecretStore, delegate: MCPClientDelegate? = nil) {
        self.secrets = secrets
        self.delegate = delegate
    }

    public func setDelegate(_ delegate: MCPClientDelegate?) {
        self.delegate = delegate
    }

    public func setHandshakeTimeout(_ seconds: TimeInterval) {
        handshakeTimeout = seconds
    }

    // MARK: Configuration

    /// Reconciles with the stored server list: new servers are added, removed ones disconnected,
    /// changed ones reconnected if they were connected.
    public func update(servers: [MCPServerConfig]) async {
        let incoming = Dictionary(servers.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for (id, connection) in connections where incoming[id] == nil || incoming[id]?.isEnabled == false {
            await connection.disconnect()
            connections[id] = nil
            if incoming[id] == nil { states[id] = nil }
        }
        for server in servers {
            let previous = configs[server.id]
            configs[server.id] = server
            if states[server.id] == nil {
                states[server.id] = MCPServerState(id: server.id, name: server.name)
            } else {
                states[server.id]?.name = server.name
            }
            if let previous, previous != server, let connection = connections[server.id] {
                let wasConnected = await connection.isConnected
                await connection.disconnect()
                connections[server.id] = nil
                if wasConnected && server.isEnabled {
                    await connect(server.id)
                }
            }
        }
        order = servers.map(\.id)
        notify()
    }

    public func allStates() -> [MCPServerState] {
        order.compactMap { states[$0] }
    }

    public func state(for id: UUID) -> MCPServerState? {
        states[id]
    }

    /// Snapshots of every server's state whenever something changes.
    public func observe() -> AsyncStream<[MCPServerState]> {
        let (stream, continuation) = AsyncStream<[MCPServerState]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        observers[id] = continuation
        continuation.yield(allStates())
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func notify() {
        let snapshot = allStates()
        for observer in observers.values { observer.yield(snapshot) }
    }

    private func receive(_ state: MCPServerState) {
        guard configs[state.id] != nil else { return }
        states[state.id] = state
        notify()
    }

    private func connection(for id: UUID) -> MCPServerConnection? {
        if let existing = connections[id] { return existing }
        guard let config = configs[id], config.isEnabled else { return nil }
        let connection = MCPServerConnection(config: config, secrets: secrets, delegate: delegate) { [weak self] state in
            await self?.receive(state)
        }
        connections[id] = connection
        return connection
    }

    // MARK: Lifecycle

    public func connect(_ id: UUID) async {
        guard let connection = connection(for: id) else { return }
        await connection.connect(timeout: handshakeTimeout)
    }

    public func disconnect(_ id: UUID) async {
        await connections[id]?.disconnect()
    }

    public func ensureConnected(_ ids: Set<UUID>) async {
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                guard let connection = connection(for: id) else { continue }
                let timeout = handshakeTimeout
                group.addTask { await connection.ensureConnected(timeout: timeout) }
            }
        }
    }

    public func disconnectAll() async {
        for connection in connections.values { await connection.disconnect() }
    }

    public func rootsChanged() async {
        for connection in connections.values { await connection.notifyRootsChanged() }
    }

    // MARK: ToolProviding

    public func tools(for selection: ToolSelection) async -> [ToolDefinition] {
        let ids = selection.mcpServerIDs.filter { configs[$0]?.isEnabled == true }
        await ensureConnected(ids)
        return order.filter(ids.contains).flatMap { states[$0]?.tools ?? [] }
    }

    public nonisolated func canExecute(_ tool: ToolDefinition) -> Bool {
        tool.sourceKind == .mcp
    }

    public func execute(_ tool: ToolDefinition, arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolResult {
        guard let id = UUID(uuidString: tool.sourceID), let connection = connection(for: id) else {
            throw ToolError.unavailable("The MCP server for \(tool.name) isn't configured or is disabled.")
        }
        await connection.ensureConnected(timeout: handshakeTimeout)
        return try await connection.callTool(name: tool.originalName, arguments: arguments, onProgress: context.onProgress)
    }

    // MARK: Prompts

    public func prompts(serverIDs: Set<UUID>) async -> [MCPPromptInfo] {
        await ensureConnected(serverIDs)
        return order.filter(serverIDs.contains).flatMap { states[$0]?.prompts ?? [] }
    }

    /// Renders a prompt into attachments (one text attachment, plus images it contains).
    public func getPrompt(_ prompt: MCPPromptInfo, arguments: [String: String]) async throws -> [Attachment] {
        guard let connection = connection(for: prompt.serverID) else { throw ToolError.unavailable("\(prompt.serverName) is not available.") }
        await connection.ensureConnected(timeout: handshakeTimeout)
        let messages = try await connection.getPrompt(name: prompt.name, arguments: arguments)
        var lines: [String] = []
        var attachments: [Attachment] = []
        for message in messages {
            let prefix = message.role == .assistant ? "Assistant: " : ""
            switch message.content {
            case .text(let text):
                lines.append(prefix + text)
            case .image(let data, let mimeType):
                if let bytes = Data(base64Encoded: data) {
                    attachments.append(Attachment(kind: .image, name: "\(prompt.name) image", mimeType: mimeType, data: bytes))
                }
            case .resource(let resource, _, _):
                lines.append(prefix + (resource.text ?? "[resource \(resource.uri)]"))
            case .resourceLink(let uri, let name, _, _, _, _):
                lines.append(prefix + "[\(name)](\(uri))")
            case .audio:
                lines.append(prefix + "[audio]")
            }
        }
        let text = Attachment(
            kind: .mcpPrompt,
            name: prompt.displayName,
            mimeType: "text/plain",
            text: lines.joined(separator: "\n\n"),
            sourceURI: "\(prompt.serverName)/\(prompt.name)"
        )
        return [text] + attachments
    }

    public func complete(prompt: MCPPromptInfo, argument: String, value: String) async -> [String] {
        guard let connection = connections[prompt.serverID] else { return [] }
        return await connection.complete(promptName: prompt.name, argument: argument, value: value)
    }

    // MARK: Resources

    public func resources(serverIDs: Set<UUID>) async -> [MCPResourceInfo] {
        await ensureConnected(serverIDs)
        return order.filter(serverIDs.contains).flatMap { states[$0]?.resources ?? [] }
    }

    public func resourceTemplates(serverIDs: Set<UUID>) async -> [MCPResourceTemplateInfo] {
        await ensureConnected(serverIDs)
        return order.filter(serverIDs.contains).flatMap { states[$0]?.resourceTemplates ?? [] }
    }

    /// Reads a resource as an attachment (text, or bytes for images and other binary types).
    public func readResource(serverID: UUID, uri: String, name: String? = nil) async throws -> Attachment {
        guard let connection = connection(for: serverID) else { throw ToolError.unavailable("The MCP server is not available.") }
        await connection.ensureConnected(timeout: handshakeTimeout)
        let contents = try await connection.readResource(uri: uri)
        let displayName = name ?? URL(string: uri)?.lastPathComponent ?? uri
        if let text = contents.compactMap(\.text).first {
            let joined = contents.compactMap(\.text).joined(separator: "\n\n")
            return Attachment(kind: .mcpResource, name: displayName, mimeType: contents.first?.mimeType ?? "text/plain",
                              text: joined.isEmpty ? text : joined, sourceURI: uri)
        }
        if let first = contents.first, let blob = first.blob, let data = Data(base64Encoded: blob) {
            return Attachment(kind: .mcpResource, name: displayName, mimeType: first.mimeType ?? "application/octet-stream", data: data, sourceURI: uri)
        }
        return Attachment(kind: .mcpResource, name: displayName, mimeType: "text/plain", text: "", sourceURI: uri)
    }

    public func subscribe(serverID: UUID, uri: String) async throws {
        guard let connection = connections[serverID] else { return }
        try await connection.subscribe(uri: uri)
    }
}
