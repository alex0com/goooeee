import Foundation

public enum ToolSourceKind: String, Codable, Sendable, Hashable {
    /// A tool from an MCP server.
    case mcp
    /// llama.cpp server tools (`GET/POST /tools`).
    case serverTools
}

/// A tool offered to the model through the OpenAI `tools` parameter.
public struct ToolDefinition: Codable, Sendable, Hashable, Identifiable {
    /// Name sent to the model. Unique within one request (prefixed with the server name on collisions).
    public var name: String
    /// Name on its own server.
    public var originalName: String
    public var title: String?
    public var description: String?
    /// JSON schema of the arguments.
    public var parameters: JSONValue
    public var sourceKind: ToolSourceKind
    /// MCP server ID (UUID string) or `llama-server`.
    public var sourceID: String
    /// Display name of the source, e.g. "filesystem".
    public var sourceName: String
    public var readOnlyHint: Bool?
    public var destructiveHint: Bool?
    /// llama.cpp server tools that resolve paths against the working directory.
    public var usesWorkingDirectory: Bool

    public init(
        name: String,
        originalName: String? = nil,
        title: String? = nil,
        description: String? = nil,
        parameters: JSONValue = ["type": "object", "properties": [:]],
        sourceKind: ToolSourceKind,
        sourceID: String,
        sourceName: String,
        readOnlyHint: Bool? = nil,
        destructiveHint: Bool? = nil,
        usesWorkingDirectory: Bool = false
    ) {
        self.name = name
        self.originalName = originalName ?? name
        self.title = title
        self.description = description
        self.parameters = parameters
        self.sourceKind = sourceKind
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.readOnlyHint = readOnlyHint
        self.destructiveHint = destructiveHint
        self.usesWorkingDirectory = usesWorkingDirectory
    }

    /// Stable identity used for enable/disable and permission grants.
    public var key: String { "\(sourceID)/\(originalName)" }
    public var id: String { key }

    public var sourceLabel: String {
        switch sourceKind {
        case .mcp: "\(sourceName) (MCP)"
        case .serverTools: "\(sourceName) (server)"
        }
    }

    /// OpenAI `tools[]` entry.
    public var openAIJSON: JSONValue {
        var function: [String: JSONValue] = ["name": .string(name), "parameters": normalizedParameters]
        if let description, !description.isEmpty { function["description"] = .string(description) }
        return ["type": "function", "function": .object(function)]
    }

    /// Anthropic `tools[]` entry.
    public var anthropicJSON: JSONValue {
        var tool: [String: JSONValue] = ["name": .string(name), "input_schema": normalizedParameters]
        if let description, !description.isEmpty { tool["description"] = .string(description) }
        return .object(tool)
    }

    /// Some servers reject schemas without `type`/`properties`.
    private var normalizedParameters: JSONValue {
        guard case .object(var schema) = parameters else { return ["type": "object", "properties": [:]] }
        if schema["type"] == nil { schema["type"] = "object" }
        if schema["type"] == "object", schema["properties"] == nil { schema["properties"] = .object([:]) }
        return .object(schema)
    }

    /// Makes wire names unique and valid (`^[a-zA-Z0-9_-]{1,64}$`), prefixing with the source name on collisions.
    public static func assignWireNames(_ tools: [ToolDefinition]) -> [ToolDefinition] {
        var counts: [String: Int] = [:]
        for tool in tools { counts[sanitize(tool.originalName), default: 0] += 1 }
        var used = Set<String>()
        return tools.map { tool in
            var copy = tool
            let base = sanitize(tool.originalName)
            var name = (counts[base] ?? 0) > 1 ? sanitize("\(tool.sourceName)_\(tool.originalName)") : base
            var suffix = 2
            while used.contains(name) {
                name = String(sanitize("\(tool.sourceName)_\(tool.originalName)").prefix(60)) + "_\(suffix)"
                suffix += 1
            }
            used.insert(name)
            copy.name = name
            return copy
        }
    }

    static func sanitize(_ name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        var result = String(name.map { allowed.contains($0) ? $0 : "_" })
        if result.isEmpty { result = "tool" }
        return String(result.prefix(64))
    }
}

/// A user decision on a tool call.
public enum PermissionDecision: String, Codable, Sendable, Hashable {
    case allowOnce
    case alwaysTool
    case alwaysServer
    case deny

    public var allows: Bool { self != .deny }
}

/// A stored "always" grant.
public struct ToolGrant: Codable, Sendable, Hashable, Identifiable {
    public enum Scope: String, Codable, Sendable, Hashable {
        case tool
        case server
    }

    public var id: UUID
    public var workspaceID: UUID
    public var scope: Scope
    /// Tool key for `.tool`, source ID for `.server`.
    public var target: String
    public var label: String
    public var createdAt: Date

    public init(id: UUID = UUID(), workspaceID: UUID, scope: Scope, target: String, label: String, createdAt: Date = Date()) {
        self.id = id
        self.workspaceID = workspaceID
        self.scope = scope
        self.target = target
        self.label = label
        self.createdAt = createdAt
    }

    public func covers(_ tool: ToolDefinition) -> Bool {
        switch scope {
        case .tool: target == tool.key
        case .server: target == tool.sourceID
        }
    }
}

/// One row of the per-workspace tool call log.
public struct ToolCallLogEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var workspaceID: UUID
    public var conversationID: UUID
    public var toolKey: String
    public var toolName: String
    public var sourceLabel: String
    public var arguments: String
    public var decision: PermissionDecision
    public var resultPreview: String?
    public var isError: Bool
    public var durationMs: Double?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        workspaceID: UUID,
        conversationID: UUID,
        toolKey: String,
        toolName: String,
        sourceLabel: String,
        arguments: String,
        decision: PermissionDecision,
        resultPreview: String? = nil,
        isError: Bool = false,
        durationMs: Double? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.conversationID = conversationID
        self.toolKey = toolKey
        self.toolName = toolName
        self.sourceLabel = sourceLabel
        self.arguments = arguments
        self.decision = decision
        self.resultPreview = resultPreview
        self.isError = isError
        self.durationMs = durationMs
        self.createdAt = createdAt
    }
}
