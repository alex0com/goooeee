import Foundation

/// Which tool sources and individual tools are enabled.
public struct ToolSelection: Codable, Sendable, Hashable {
    /// Enabled MCP server IDs.
    public var mcpServerIDs: Set<UUID>
    /// Use the llama.cpp server's own `/tools` when available.
    public var serverToolsEnabled: Bool
    /// Tool keys (`ToolDefinition.key`) that were switched off individually.
    public var disabledToolKeys: Set<String>

    public init(mcpServerIDs: Set<UUID> = [], serverToolsEnabled: Bool = false, disabledToolKeys: Set<String> = []) {
        self.mcpServerIDs = mcpServerIDs
        self.serverToolsEnabled = serverToolsEnabled
        self.disabledToolKeys = disabledToolKeys
    }

    public var isEmpty: Bool { mcpServerIDs.isEmpty && !serverToolsEnabled }
}

/// Settings that can be layered: connection → workspace → conversation.
public struct SettingsOverrides: Codable, Sendable, Hashable {
    public var sampling: SamplingSettings
    public var thinking: ThinkingLevel?
    public var systemPrompt: String?
    public var extraBodyJSON: String?

    public init(sampling: SamplingSettings = SamplingSettings(), thinking: ThinkingLevel? = nil, systemPrompt: String? = nil, extraBodyJSON: String? = nil) {
        self.sampling = sampling
        self.thinking = thinking
        self.systemPrompt = systemPrompt
        self.extraBodyJSON = extraBodyJSON
    }

    public var isEmpty: Bool {
        sampling.isEmpty && thinking == nil && systemPrompt == nil && extraBodyJSON == nil
    }
}

/// A window bound to one server connection and one model, with its own conversations.
public struct Workspace: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var name: String
    public var connectionID: UUID
    public var modelID: String?
    public var overrides: SettingsOverrides
    public var tools: ToolSelection
    /// Working directory for the terminal, launch command, MCP roots and llama.cpp server tools.
    public var workingDirectory: String?
    public var isOpen: Bool
    public var selectedConversationID: UUID?
    public var showInspector: Bool
    public var showTerminal: Bool
    public var sortIndex: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        connectionID: UUID,
        modelID: String? = nil,
        overrides: SettingsOverrides = SettingsOverrides(),
        tools: ToolSelection = ToolSelection(),
        workingDirectory: String? = nil,
        isOpen: Bool = true,
        selectedConversationID: UUID? = nil,
        showInspector: Bool = true,
        showTerminal: Bool = false,
        sortIndex: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.connectionID = connectionID
        self.modelID = modelID
        self.overrides = overrides
        self.tools = tools
        self.workingDirectory = workingDirectory
        self.isOpen = isOpen
        self.selectedConversationID = selectedConversationID
        self.showInspector = showInspector
        self.showTerminal = showTerminal
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Default name: "connection · model".
    public static func defaultName(connection: ServerConnection, modelID: String?) -> String {
        guard let modelID, !modelID.isEmpty else { return connection.name }
        return "\(connection.name) · \(ModelNameFormatter.shortName(modelID))"
    }
}

public enum ModelNameFormatter {
    /// `mlx-community/Qwen3-32B-4bit` → `Qwen3-32B-4bit`; `/models/x/qwen3-32b-q4_k_m.gguf` → `qwen3-32b-q4_k_m`.
    public static func shortName(_ modelID: String) -> String {
        var name = modelID
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        if name.lowercased().hasSuffix(".gguf") { name.removeLast(5) }
        return name.isEmpty ? modelID : name
    }
}
