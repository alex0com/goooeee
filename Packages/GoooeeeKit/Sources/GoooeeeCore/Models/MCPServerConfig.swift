import Foundation

/// How goooeee reaches an MCP server.
public enum MCPTransportConfig: Codable, Sendable, Hashable {
    /// goooeee launches the server process and talks JSON-RPC over stdin/stdout.
    case stdio(command: String, args: [String], env: [String: String], cwd: String?)
    /// Streamable HTTP (current MCP transport).
    case http(url: URL, headers: [String: String])
    /// Legacy HTTP+SSE transport.
    case sse(url: URL, headers: [String: String])

    public var kindLabel: String {
        switch self {
        case .stdio: "stdio"
        case .http: "HTTP"
        case .sse: "SSE"
        }
    }

    /// Human-readable target: the command line or the URL.
    public var summary: String {
        switch self {
        case .stdio(let command, let args, _, _): ([command] + args).map(Self.shellQuote).joined(separator: " ")
        case .http(let url, _), .sse(let url, _): url.absoluteString
        }
    }

    static func shellQuote(_ word: String) -> String {
        word.contains(where: { $0.isWhitespace || "'\"$`\\".contains($0) }) ? "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'" : word
    }
}

public struct MCPServerConfig: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var name: String
    public var transport: MCPTransportConfig
    /// Globally enabled; workspaces choose which enabled servers they use.
    public var isEnabled: Bool
    /// Env var or header names whose values live in the Keychain (stored empty here).
    public var secretKeys: Set<String>
    /// Per-tool-call timeout override.
    public var toolTimeoutSeconds: Double?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        transport: MCPTransportConfig,
        isEnabled: Bool = true,
        secretKeys: Set<String> = [],
        toolTimeoutSeconds: Double? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.isEnabled = isEnabled
        self.secretKeys = secretKeys
        self.toolTimeoutSeconds = toolTimeoutSeconds
        self.createdAt = createdAt
    }

    public func secretRef(for key: String) -> SecretRef {
        SecretRef(account: "mcp.\(id.uuidString).\(key)")
    }
}

/// Import/export of the `mcpServers` JSON used by Cursor, Claude Desktop and llama-server's `--mcp-servers-config`.
public enum MCPServersJSON {
    public static func parse(_ data: Data) throws -> [MCPServerConfig] {
        let json = try JSONValue.parse(data)
        guard let servers = (json["mcpServers"] ?? json["servers"])?.objectValue else {
            throw InferenceError.invalidRequest("Expected an object with an \"mcpServers\" key.")
        }
        return servers.keys.sorted().compactMap { name in
            guard let entry = servers[name] else { return nil }
            let env = entry["env"]?.objectValue?.compactMapValues(\.stringValue) ?? [:]
            let headers = entry["headers"]?.objectValue?.compactMapValues(\.stringValue) ?? [:]
            if let command = entry["command"]?.stringValue {
                let args = entry["args"]?.arrayValue?.compactMap(\.stringValue) ?? []
                var config = MCPServerConfig(name: name, transport: .stdio(command: command, args: args, env: env, cwd: entry["cwd"]?.stringValue))
                if let timeout = entry["timeout_ms"]?.doubleValue { config.toolTimeoutSeconds = timeout / 1000 }
                config.isEnabled = !(entry["disabled"]?.boolValue ?? false)
                return config
            }
            if let urlString = entry["url"]?.stringValue ?? entry["serverUrl"]?.stringValue, let url = URL(string: urlString) {
                let type = entry["type"]?.stringValue ?? entry["transport"]?.stringValue ?? ""
                let isSSE = type.lowercased() == "sse" || (type.isEmpty && url.path.hasSuffix("/sse"))
                var config = MCPServerConfig(name: name, transport: isSSE ? .sse(url: url, headers: headers) : .http(url: url, headers: headers))
                config.isEnabled = !(entry["disabled"]?.boolValue ?? false)
                return config
            }
            return nil
        }
    }

    /// Exports servers. Secret values are left out.
    public static func export(_ servers: [MCPServerConfig]) -> Data {
        var object: [String: JSONValue] = [:]
        for server in servers {
            var entry: [String: JSONValue] = [:]
            switch server.transport {
            case .stdio(let command, let args, let env, let cwd):
                entry["command"] = .string(command)
                entry["args"] = .array(args.map(JSONValue.string))
                let visible = env.filter { !server.secretKeys.contains($0.key) }
                if !visible.isEmpty { entry["env"] = .object(visible.mapValues(JSONValue.string)) }
                if let cwd { entry["cwd"] = .string(cwd) }
                if let timeout = server.toolTimeoutSeconds { entry["timeout_ms"] = .int(Int(timeout * 1000)) }
            case .http(let url, let headers), .sse(let url, let headers):
                entry["url"] = .string(url.absoluteString)
                if case .sse = server.transport { entry["type"] = "sse" } else { entry["type"] = "http" }
                let visible = headers.filter { !server.secretKeys.contains($0.key) }
                if !visible.isEmpty { entry["headers"] = .object(visible.mapValues(JSONValue.string)) }
            }
            if !server.isEnabled { entry["disabled"] = true }
            object[server.name] = .object(entry)
        }
        return (try? JSONValue.object(["mcpServers": .object(object)]).encoded(pretty: true)) ?? Data()
    }
}

/// Where secrets (API keys, MCP tokens) are stored. Keychain on macOS.
public protocol SecretStore: Sendable {
    func secret(for ref: SecretRef) -> String?
    func setSecret(_ value: String?, for ref: SecretRef) throws
}

/// Test and fallback secret store.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    public init(_ values: [String: String] = [:]) {
        self.values = values
    }

    public func secret(for ref: SecretRef) -> String? {
        lock.withLock { values[ref.account] }
    }

    public func setSecret(_ value: String?, for ref: SecretRef) throws {
        lock.withLock { values[ref.account] = value }
    }
}
