import Foundation
import GoooeeeCore
import MCP

/// Connection lifecycle of one MCP server (mirrors the llama.cpp UI's connection phases).
public enum MCPConnectionPhase: String, Sendable, Hashable {
    case idle
    case starting
    case initializing
    case listing
    case connected
    case reconnecting
    case failed
    case disconnected

    public var label: String {
        switch self {
        case .idle: "Not connected"
        case .starting: "Starting…"
        case .initializing: "Initializing…"
        case .listing: "Loading tools…"
        case .connected: "Connected"
        case .reconnecting: "Reconnecting…"
        case .failed: "Failed"
        case .disconnected: "Disconnected"
        }
    }

    public var isBusy: Bool {
        switch self {
        case .starting, .initializing, .listing, .reconnecting: true
        default: false
        }
    }
}

public struct MCPLogEntry: Identifiable, Sendable, Hashable {
    public enum Level: String, Sendable, Hashable {
        case info, warning, error, stderr, server
    }

    public var id = UUID()
    public var date = Date()
    public var level: Level
    public var message: String

    public init(level: Level, message: String) {
        self.level = level
        self.message = message
    }
}

public struct MCPPromptInfo: Identifiable, Sendable, Hashable {
    public struct Argument: Sendable, Hashable {
        public var name: String
        public var title: String?
        public var description: String?
        public var required: Bool
    }

    public var serverID: UUID
    public var serverName: String
    public var name: String
    public var title: String?
    public var description: String?
    public var arguments: [Argument]

    public var id: String { "\(serverID.uuidString)/\(name)" }
    public var displayName: String { title ?? name }
}

public struct MCPResourceInfo: Identifiable, Sendable, Hashable {
    public var serverID: UUID
    public var serverName: String
    public var uri: String
    public var name: String
    public var title: String?
    public var description: String?
    public var mimeType: String?
    public var size: Int?

    public var id: String { "\(serverID.uuidString)/\(uri)" }
    public var displayName: String { title ?? name }
}

public struct MCPResourceTemplateInfo: Identifiable, Sendable, Hashable {
    public var serverID: UUID
    public var serverName: String
    public var uriTemplate: String
    public var name: String
    public var title: String?
    public var description: String?
    public var mimeType: String?

    public var id: String { "\(serverID.uuidString)/\(uriTemplate)" }

    /// Variable names in the template (`{name}`, `{+path}`, …).
    public var variables: [String] {
        var names: [String] = []
        var current: String?
        for char in uriTemplate {
            if char == "{" {
                current = ""
            } else if char == "}" {
                if let name = current {
                    for part in name.split(separator: ",") {
                        let trimmed = part.trimmingCharacters(in: CharacterSet(charactersIn: "+#./;?&*"))
                        if !trimmed.isEmpty && !names.contains(trimmed) { names.append(trimmed) }
                    }
                }
                current = nil
            } else if current != nil {
                current?.append(char)
            }
        }
        return names
    }

    /// Simple RFC 6570 expansion (level 1–2), enough for typical MCP resource templates.
    public func expand(_ values: [String: String]) -> String {
        var result = ""
        var expression: String?
        for char in uriTemplate {
            if char == "{" {
                expression = ""
            } else if char == "}", let body = expression {
                let reserved = body.hasPrefix("+") || body.hasPrefix("#")
                let names = body.trimmingCharacters(in: CharacterSet(charactersIn: "+#./;?&*")).split(separator: ",").map(String.init)
                let parts = names.compactMap { name -> String? in
                    guard let value = values[name] else { return nil }
                    let allowed: CharacterSet = reserved ? .urlPathAllowed : .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
                    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                }
                result += parts.joined(separator: ",")
                expression = nil
            } else if expression != nil {
                expression?.append(char)
            } else {
                result.append(char)
            }
        }
        return result
    }
}

/// What the UI shows about one server.
public struct MCPServerState: Identifiable, Sendable, Hashable {
    public var id: UUID
    public var name: String
    public var phase: MCPConnectionPhase
    public var serverName: String?
    public var serverVersion: String?
    public var serverTitle: String?
    public var instructions: String?
    public var protocolVersion: String?
    /// Capability badges: tools, prompts, resources, logging, completions.
    public var capabilities: [String]
    public var tools: [ToolDefinition]
    public var prompts: [MCPPromptInfo]
    public var resources: [MCPResourceInfo]
    public var resourceTemplates: [MCPResourceTemplateInfo]
    public var connectTimeMs: Double?
    public var error: String?
    public var logs: [MCPLogEntry]

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
        phase = .idle
        capabilities = []
        tools = []
        prompts = []
        resources = []
        resourceTemplates = []
        logs = []
    }

    public var isConnected: Bool { phase == .connected }

    mutating func log(_ level: MCPLogEntry.Level, _ message: String) {
        logs.append(MCPLogEntry(level: level, message: message))
        if logs.count > 500 { logs.removeFirst(logs.count - 500) }
    }
}

/// Answers to server-initiated requests (elicitation, sampling, roots). Implemented by the app.
public protocol MCPClientDelegate: Sendable {
    /// Form elicitation: show a form built from `schema`; return `nil` to decline, or the values.
    func elicit(serverName: String, message: String, schema: JSONValue) async -> MCPElicitationResponse
    /// URL elicitation: ask the user to open `url`.
    func elicitURL(serverName: String, message: String, url: URL) async -> MCPElicitationResponse
    /// Sampling: ask the user, then generate with the workspace model.
    func sample(serverName: String, request: MCPSamplingRequest) async throws -> String
    /// Roots: working directories of open workspaces.
    func roots() async -> [URL]
}

public enum MCPElicitationResponse: Sendable, Hashable {
    case accept([String: JSONValue])
    case decline
    case cancel
}

public struct MCPSamplingRequest: Sendable, Hashable {
    public var messages: [(role: String, text: String)]
    public var systemPrompt: String?
    public var maxTokens: Int
    public var temperature: Double?

    public static func == (lhs: MCPSamplingRequest, rhs: MCPSamplingRequest) -> Bool {
        lhs.messages.map(\.text) == rhs.messages.map(\.text) && lhs.systemPrompt == rhs.systemPrompt && lhs.maxTokens == rhs.maxTokens
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(messages.map(\.text))
        hasher.combine(systemPrompt)
        hasher.combine(maxTokens)
    }
}

// MARK: - Value conversion

/// The MCP SDK's JSON value (`Value` alone is ambiguous inside `JSONValue` extensions).
public typealias MCPValue = MCP.Value

extension JSONValue {
    init(mcp value: MCPValue) {
        switch value {
        case .null: self = .null
        case .bool(let bool): self = .bool(bool)
        case .int(let int): self = .int(int)
        case .double(let double): self = .double(double)
        case .string(let string): self = .string(string)
        case .data(let mimeType, let data): self = .string("data:\(mimeType ?? "application/octet-stream");base64,\(data.base64EncodedString())")
        case .array(let array): self = .array(array.map(JSONValue.init(mcp:)))
        case .object(let object): self = .object(object.mapValues(JSONValue.init(mcp:)))
        }
    }

    var mcpValue: MCPValue {
        switch self {
        case .null: .null
        case .bool(let bool): .bool(bool)
        case .int(let int): .int(int)
        case .double(let double): .double(double)
        case .string(let string): .string(string)
        case .array(let array): .array(array.map(\.mcpValue))
        case .object(let object): .object(object.mapValues(\.mcpValue))
        }
    }
}

extension ToolResultContent {
    init(mcp content: Tool.Content) {
        switch content {
        case .text(let text, _, _):
            self = .text(text)
        case .image(let data, let mimeType, _, _):
            if let bytes = Data(base64Encoded: data) {
                self = .image(data: bytes, mimeType: mimeType)
            } else {
                self = .text("[image: \(mimeType)]")
            }
        case .audio(_, let mimeType, _, _):
            self = .text("[audio: \(mimeType)]")
        case .resource(let resource, _, _):
            self = .resource(uri: resource.uri, text: resource.text ?? resource.blob.map { _ in "[binary content]" }, mimeType: resource.mimeType)
        case .resourceLink(let uri, let name, _, _, let mimeType, _):
            self = .resourceLink(uri: uri, name: name, mimeType: mimeType)
        }
    }
}
