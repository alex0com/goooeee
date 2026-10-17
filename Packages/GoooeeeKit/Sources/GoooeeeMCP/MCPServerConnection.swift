import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import GoooeeeCore
import MCP

/// One MCP server: transport, client, lists, logs and reconnect with backoff.
actor MCPServerConnection {
    static let clientName = "goooeee"
    static let clientVersion = "0.1.0"

    /// Backoff policy, as in the llama.cpp UI: 1 s doubling to 30 s, 15 s per attempt.
    enum Reconnect {
        static let initialDelay: TimeInterval = 1
        static let maxDelay: TimeInterval = 30
        static let multiplier: Double = 2
        static let attemptTimeout: TimeInterval = 15
    }

    let config: MCPServerConfig
    private let secrets: SecretStore
    private let delegate: MCPClientDelegate?
    private let onChange: @Sendable (MCPServerState) async -> Void
    private(set) var state: MCPServerState

    private var client: Client?
    private var transport: (any Transport)?
    private var connectTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectDelay = Reconnect.initialDelay
    /// The user or a workspace wants this server connected (reconnect after failures).
    private var wanted = false
    private var generation = 0
    private var progressHandlers: [String: @Sendable (Double?, String?) -> Void] = [:]

    init(config: MCPServerConfig, secrets: SecretStore, delegate: MCPClientDelegate?, onChange: @escaping @Sendable (MCPServerState) async -> Void) {
        self.config = config
        self.secrets = secrets
        self.delegate = delegate
        self.onChange = onChange
        self.state = MCPServerState(id: config.id, name: config.name)
    }

    var isConnected: Bool { client != nil && state.phase == .connected }

    // MARK: Connect / disconnect

    /// Connects if needed and waits until connected or failed.
    func ensureConnected(timeout: TimeInterval) async {
        wanted = true
        if isConnected { return }
        if connectTask == nil {
            startConnect(timeout: timeout)
        }
        await connectTask?.value
    }

    func connect(timeout: TimeInterval) async {
        wanted = true
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectDelay = Reconnect.initialDelay
        await teardown()
        startConnect(timeout: timeout)
        await connectTask?.value
    }

    func disconnect() async {
        wanted = false
        reconnectTask?.cancel()
        reconnectTask = nil
        await teardown()
        state.phase = .disconnected
        state.log(.info, "Disconnected.")
        await publish()
    }

    private func startConnect(timeout: TimeInterval) {
        generation += 1
        let current = generation
        connectTask = Task {
            await self.performConnect(timeout: timeout, generation: current)
            self.connectTask = nil
        }
    }

    private func performConnect(timeout: TimeInterval, generation current: Int) async {
        let started = MonotonicClock.now()
        state.error = nil
        state.phase = .starting
        state.log(.info, "Connecting (\(config.transport.kindLabel)): \(config.transport.summary)")
        await publish()

        do {
            let transport = try makeTransport(generation: current)
            let client = Client(
                name: Self.clientName,
                version: Self.clientVersion,
                capabilities: clientCapabilities
            )
            await registerHandlers(on: client)

            state.phase = .initializing
            await publish()
            let result = try await withTimeout(seconds: timeout) {
                try await client.connect(transport: transport)
            }
            guard current == generation else {
                await client.disconnect()
                return
            }
            self.client = client
            self.transport = transport
            state.serverName = result.serverInfo.name
            state.serverTitle = result.serverInfo.title
            state.serverVersion = result.serverInfo.version
            state.instructions = result.instructions
            state.protocolVersion = result.protocolVersion
            var badges: [String] = []
            if result.capabilities.tools != nil { badges.append("tools") }
            if result.capabilities.prompts != nil { badges.append("prompts") }
            if result.capabilities.resources != nil { badges.append("resources") }
            if result.capabilities.logging != nil { badges.append("logging") }
            if result.capabilities.completions != nil { badges.append("completions") }
            state.capabilities = badges
            state.log(.info, "Initialized \(result.serverInfo.name) \(result.serverInfo.version) (protocol \(result.protocolVersion)).")

            state.phase = .listing
            await publish()
            await refreshLists()
            if result.capabilities.logging != nil {
                try? await client.setLoggingLevel(.info)
            }
            state.phase = .connected
            state.connectTimeMs = (MonotonicClock.now() - started) * 1000
            reconnectDelay = Reconnect.initialDelay
            state.log(.info, "Connected in \(MetricsFormatter.duration(ms: state.connectTimeMs ?? 0)) with \(state.tools.count) tool\(state.tools.count == 1 ? "" : "s").")
            await publish()
        } catch {
            guard current == generation else { return }
            await teardown()
            let message = Self.describe(error)
            state.phase = .failed
            state.error = message
            state.log(.error, message)
            await publish()
            scheduleReconnect()
        }
    }

    private var clientCapabilities: Client.Capabilities {
        guard delegate != nil else { return Client.Capabilities() }
        return Client.Capabilities(
            sampling: .init(),
            elicitation: .init(form: .init(), url: .init()),
            roots: .init(listChanged: true)
        )
    }

    private func makeTransport(generation current: Int) throws -> any Transport {
        switch config.transport {
        case .stdio(let command, let args, let env, let cwd):
            var resolvedEnv = env
            for key in config.secretKeys {
                if let value = secrets.secret(for: config.secretRef(for: key)) { resolvedEnv[key] = value }
            }
            return ProcessStdioTransport(
                command: command,
                arguments: args,
                environment: resolvedEnv,
                workingDirectory: cwd,
                onStderr: { [weak self] line in
                    Task { await self?.appendLog(.stderr, line) }
                },
                onExit: { [weak self] status in
                    Task { await self?.transportClosed(generation: current, reason: "Process exited with status \(status).") }
                }
            )
        case .http(let url, let headers):
            let resolved = resolvedHeaders(headers)
            return HTTPClientTransport(
                endpoint: url,
                streaming: true,
                requestModifier: { request in
                    var request = request
                    for (name, value) in resolved { request.setValue(value, forHTTPHeaderField: name) }
                    return request
                }
            )
        case .sse(let url, let headers):
            return LegacySSETransport(url: url, headers: resolvedHeaders(headers))
        }
    }

    private func resolvedHeaders(_ headers: [String: String]) -> [String: String] {
        var resolved = headers
        for key in config.secretKeys {
            if let value = secrets.secret(for: config.secretRef(for: key)) { resolved[key] = value }
        }
        return resolved
    }

    private func registerHandlers(on client: Client) async {
        let serverName = config.name
        await client.onNotification(ToolListChangedNotification.self) { [weak self] _ in
            await self?.refreshLists()
        }
        await client.onNotification(PromptListChangedNotification.self) { [weak self] _ in
            await self?.refreshLists()
        }
        await client.onNotification(ResourceListChangedNotification.self) { [weak self] _ in
            await self?.refreshLists()
        }
        await client.onNotification(LogMessageNotification.self) { [weak self] message in
            let text = message.params.data.stringValue ?? JSONValue(mcp: message.params.data).encodedString()
            let prefix = message.params.logger.map { "[\($0)] " } ?? ""
            await self?.appendLog(.server, "\(message.params.level.rawValue): \(prefix)\(text)")
        }
        await client.onNotification(ProgressNotification.self) { [weak self] message in
            let token: String
            switch message.params.progressToken {
            case .string(let value): token = value
            case .integer(let value): token = String(value)
            }
            let fraction = message.params.total.map { $0 > 0 ? message.params.progress / $0 : 0 }
            await self?.progress(token: token, fraction: fraction, message: message.params.message)
        }

        guard let delegate else { return }
        await client.withElicitationHandler { parameters in
            let response: MCPElicitationResponse
            switch parameters {
            case .form(let form):
                let schema = (try? JSONValue.from(form.requestedSchema)) ?? .object([:])
                response = await delegate.elicit(serverName: serverName, message: form.message, schema: schema)
            case .url(let urlParameters):
                guard let url = URL(string: urlParameters.url) else { return CreateElicitation.Result(action: .decline) }
                response = await delegate.elicitURL(serverName: serverName, message: urlParameters.message, url: url)
            }
            switch response {
            case .accept(let values): return CreateElicitation.Result(action: .accept, content: values.mapValues(\.mcpValue))
            case .decline: return CreateElicitation.Result(action: .decline)
            case .cancel: return CreateElicitation.Result(action: .cancel)
            }
        }
        await client.withSamplingHandler { parameters in
            let messages: [(role: String, text: String)] = parameters.messages.map { message in
                let text = message.content.asArray.compactMap { block -> String? in
                    if case .text(let text) = block { return text }
                    return nil
                }.joined(separator: "\n")
                return (message.role.rawValue, text)
            }
            let request = MCPSamplingRequest(messages: messages, systemPrompt: parameters.systemPrompt, maxTokens: parameters.maxTokens, temperature: parameters.temperature)
            let text = try await delegate.sample(serverName: serverName, request: request)
            return CreateSamplingMessage.Result(model: "goooeee", stopReason: .endTurn, role: .assistant, content: .single(.text(text)))
        }
        await client.withRootsHandler {
            await delegate.roots().map { Root(uri: $0.absoluteString, name: $0.lastPathComponent) }
        }
    }

    // MARK: Lists

    func refreshLists() async {
        guard let client else { return }
        await refreshLists(using: client)
    }

    private func refreshLists(using client: Client) async {
        let capabilities = Set(state.capabilities)
        if capabilities.contains("tools") {
            var tools: [ToolDefinition] = []
            var cursor: String?
            repeat {
                guard let page = try? await client.listTools(cursor: cursor) else { break }
                tools += page.tools.map(toolDefinition)
                cursor = page.nextCursor
            } while cursor != nil
            state.tools = tools
        }
        if capabilities.contains("prompts") {
            var prompts: [MCPPromptInfo] = []
            var cursor: String?
            repeat {
                guard let page = try? await client.listPrompts(cursor: cursor) else { break }
                prompts += page.prompts.map { prompt in
                    MCPPromptInfo(
                        serverID: config.id,
                        serverName: config.name,
                        name: prompt.name,
                        title: prompt.title,
                        description: prompt.description,
                        arguments: (prompt.arguments ?? []).map {
                            .init(name: $0.name, title: $0.title, description: $0.description, required: $0.required ?? false)
                        }
                    )
                }
                cursor = page.nextCursor
            } while cursor != nil
            state.prompts = prompts
        }
        if capabilities.contains("resources") {
            var resources: [MCPResourceInfo] = []
            var cursor: String?
            repeat {
                guard let page = try? await client.listResources(cursor: cursor) else { break }
                resources += page.resources.map {
                    MCPResourceInfo(serverID: config.id, serverName: config.name, uri: $0.uri, name: $0.name, title: $0.title,
                                    description: $0.description, mimeType: $0.mimeType, size: $0.size)
                }
                cursor = page.nextCursor
            } while cursor != nil
            state.resources = resources
            if let templates = try? await client.listResourceTemplates() {
                state.resourceTemplates = templates.templates.map {
                    MCPResourceTemplateInfo(serverID: config.id, serverName: config.name, uriTemplate: $0.uriTemplate, name: $0.name,
                                            title: $0.title, description: $0.description, mimeType: $0.mimeType)
                }
            }
        }
        await publish()
    }

    private func toolDefinition(_ tool: Tool) -> ToolDefinition {
        ToolDefinition(
            name: tool.name,
            originalName: tool.name,
            title: tool.title ?? tool.annotations.title,
            description: tool.description,
            parameters: JSONValue(mcp: tool.inputSchema),
            sourceKind: .mcp,
            sourceID: config.id.uuidString,
            sourceName: config.name,
            readOnlyHint: tool.annotations.readOnlyHint,
            destructiveHint: tool.annotations.destructiveHint
        )
    }

    // MARK: Requests

    func callTool(name: String, arguments: JSONValue, onProgress: @escaping @Sendable (Double?, String?) -> Void) async throws -> ToolResult {
        guard let client else { throw ToolError.unavailable("\(config.name) isn't connected.") }
        let token = UUID().uuidString
        progressHandlers[token] = onProgress
        defer { progressHandlers[token] = nil }
        let args = arguments.objectValue?.mapValues(\.mcpValue)
        let result = try await client.callTool(name: name, arguments: args, meta: Metadata(progressToken: .string(token)))
        return ToolResult(content: result.content.map(ToolResultContent.init(mcp:)), isError: result.isError ?? false)
    }

    func getPrompt(name: String, arguments: [String: String]) async throws -> [Prompt.Message] {
        guard let client else { throw ToolError.unavailable("\(config.name) isn't connected.") }
        return try await client.getPrompt(name: name, arguments: arguments).messages
    }

    func readResource(uri: String) async throws -> [Resource.Content] {
        guard let client else { throw ToolError.unavailable("\(config.name) isn't connected.") }
        return try await client.readResource(uri: uri)
    }

    func subscribe(uri: String) async throws {
        guard let client else { throw ToolError.unavailable("\(config.name) isn't connected.") }
        try await client.subscribeToResource(uri: uri)
    }

    func complete(promptName: String, argument: String, value: String) async -> [String] {
        guard let client, state.capabilities.contains("completions") else { return [] }
        return (try? await client.complete(promptName: promptName, argumentName: argument, argumentValue: value).values) ?? []
    }

    func notifyRootsChanged() async {
        try? await client?.notifyRootsChanged()
    }

    // MARK: Internals

    private func progress(token: String, fraction: Double?, message: String?) {
        progressHandlers[token]?(fraction, message)
    }

    private func appendLog(_ level: MCPLogEntry.Level, _ message: String) async {
        state.log(level, message)
        await publish()
    }

    private func transportClosed(generation closed: Int, reason: String) async {
        guard closed == generation, state.phase == .connected || state.phase.isBusy else { return }
        state.log(.warning, reason)
        await teardown()
        state.phase = wanted ? .reconnecting : .disconnected
        await publish()
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard wanted, reconnectTask == nil else { return }
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * Reconnect.multiplier, Reconnect.maxDelay)
        state.log(.info, "Retrying in \(Int(delay)) s.")
        reconnectTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.reconnectTask = nil
            guard self.wanted, !self.isConnected else { return }
            self.state.phase = .reconnecting
            await self.publish()
            self.startConnect(timeout: Reconnect.attemptTimeout)
        }
    }

    private func teardown() async {
        generation += 1
        let client = self.client
        let transport = self.transport
        self.client = nil
        self.transport = nil
        if let client {
            await client.disconnect()
        } else {
            await transport?.disconnect()
        }
    }

    private func publish() async {
        await onChange(state)
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? ToolError { return error.localizedDescription }
        if let error = error as? MCPError {
            switch error {
            case .internalError(let message): return message ?? "Internal error"
            case .connectionClosed: return "The connection closed."
            case .transportError(let underlying): return underlying.localizedDescription
            default: return String(describing: error)
            }
        }
        if let error = error as? InferenceError { return error.localizedDescription }
        return error.localizedDescription
    }
}
