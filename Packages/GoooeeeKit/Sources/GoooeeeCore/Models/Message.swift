import Foundation

public enum Role: String, Codable, Sendable, Hashable {
    case system
    case user
    case assistant
    case tool
}

/// Ordered content of a message. Thinking and text can interleave (e.g. Anthropic, Harmony).
public enum ContentBlock: Codable, Sendable, Hashable {
    case text(String)
    case thinking(String, duration: TimeInterval?, signature: String?)

    public var text: String {
        switch self {
        case .text(let text): text
        case .thinking(let text, _, _): text
        }
    }

    public var isThinking: Bool {
        if case .thinking = self { return true }
        return false
    }

    private enum CodingKeys: String, CodingKey { case type, text, duration, signature }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let text = try container.decode(String.self, forKey: .text)
        switch type {
        case "thinking":
            self = .thinking(
                text,
                duration: try container.decodeIfPresent(TimeInterval.self, forKey: .duration),
                signature: try container.decodeIfPresent(String.self, forKey: .signature)
            )
        default:
            self = .text(text)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .thinking(let text, let duration, let signature):
            try container.encode("thinking", forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(duration, forKey: .duration)
            try container.encodeIfPresent(signature, forKey: .signature)
        }
    }
}

public enum AttachmentKind: String, Codable, Sendable, Hashable {
    case image
    case text
    case pdf
    case mcpResource
    case mcpPrompt
}

public struct Attachment: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var kind: AttachmentKind
    public var name: String
    public var mimeType: String
    /// Raw bytes: image data (already downscaled) or the original PDF.
    public var data: Data?
    /// Text content: text files, extracted PDF text, MCP resource text, rendered MCP prompt.
    public var text: String?
    /// PDF pages rendered as images, used for vision models when "PDF as images" is on.
    public var pageImages: [Data]?
    /// Source URI for MCP resources, or `server/prompt` for MCP prompts.
    public var sourceURI: String?
    public var pixelWidth: Int?
    public var pixelHeight: Int?

    public init(
        id: UUID = UUID(),
        kind: AttachmentKind,
        name: String,
        mimeType: String,
        data: Data? = nil,
        text: String? = nil,
        pageImages: [Data]? = nil,
        sourceURI: String? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.mimeType = mimeType
        self.data = data
        self.text = text
        self.pageImages = pageImages
        self.sourceURI = sourceURI
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    public var byteCount: Int {
        let dataBytes: Int = data?.count ?? 0
        let textBytes: Int = text?.utf8.count ?? 0
        var pageBytes = 0
        for page in pageImages ?? [] { pageBytes += page.count }
        return dataBytes + textBytes + pageBytes
    }

    public var isImage: Bool { kind == .image }

    /// A text attachment created from a long paste.
    public static func pastedText(_ text: String, index: Int = 1) -> Attachment {
        Attachment(kind: .text, name: "Pasted text \(index).txt", mimeType: "text/plain", text: text)
    }
}

public enum ToolCallStatus: String, Codable, Sendable, Hashable {
    case pending
    case awaitingPermission
    case running
    case completed
    case failed
    case denied
    case cancelled

    public var isFinished: Bool {
        switch self {
        case .completed, .failed, .denied, .cancelled: true
        default: false
        }
    }
}

public enum ToolResultContent: Codable, Sendable, Hashable {
    case text(String)
    case image(data: Data, mimeType: String)
    case resourceLink(uri: String, name: String, mimeType: String?)
    case resource(uri: String, text: String?, mimeType: String?)

    private enum CodingKeys: String, CodingKey { case type, text, data, mimeType, uri, name }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "image":
            self = .image(data: try container.decode(Data.self, forKey: .data), mimeType: try container.decode(String.self, forKey: .mimeType))
        case "resource_link":
            self = .resourceLink(
                uri: try container.decode(String.self, forKey: .uri),
                name: try container.decode(String.self, forKey: .name),
                mimeType: try container.decodeIfPresent(String.self, forKey: .mimeType)
            )
        case "resource":
            self = .resource(
                uri: try container.decode(String.self, forKey: .uri),
                text: try container.decodeIfPresent(String.self, forKey: .text),
                mimeType: try container.decodeIfPresent(String.self, forKey: .mimeType)
            )
        default:
            self = .text(try container.decode(String.self, forKey: .text))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .image(let data, let mimeType):
            try container.encode("image", forKey: .type)
            try container.encode(data, forKey: .data)
            try container.encode(mimeType, forKey: .mimeType)
        case .resourceLink(let uri, let name, let mimeType):
            try container.encode("resource_link", forKey: .type)
            try container.encode(uri, forKey: .uri)
            try container.encode(name, forKey: .name)
            try container.encodeIfPresent(mimeType, forKey: .mimeType)
        case .resource(let uri, let text, let mimeType):
            try container.encode("resource", forKey: .type)
            try container.encode(uri, forKey: .uri)
            try container.encodeIfPresent(text, forKey: .text)
            try container.encodeIfPresent(mimeType, forKey: .mimeType)
        }
    }
}

public struct ToolResult: Codable, Sendable, Hashable {
    public var content: [ToolResultContent]
    public var isError: Bool

    public init(content: [ToolResultContent], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    public static func text(_ text: String, isError: Bool = false) -> ToolResult {
        ToolResult(content: [.text(text)], isError: isError)
    }

    /// Text sent back to the model in the `tool` message.
    public var textForModel: String {
        let parts = content.compactMap { item -> String? in
            switch item {
            case .text(let text): return text
            case .image(_, let mimeType): return "[image: \(mimeType)]"
            case .resourceLink(let uri, let name, _): return "[resource: \(name) <\(uri)>]"
            case .resource(let uri, let text, _): return text ?? "[resource: \(uri)]"
            }
        }
        let joined = parts.joined(separator: "\n")
        return joined.isEmpty ? (isError ? "Tool failed without output." : "(no output)") : joined
    }

    public var images: [(data: Data, mimeType: String)] {
        content.compactMap {
            if case .image(let data, let mimeType) = $0 { return (data, mimeType) }
            return nil
        }
    }
}

public struct ToolCall: Identifiable, Codable, Sendable, Hashable {
    /// Call ID from the model (`tool_calls[].id`).
    public var id: String
    /// Wire name of the tool (may be prefixed with the server name).
    public var name: String
    /// Raw JSON arguments as produced by the model.
    public var arguments: String
    public var status: ToolCallStatus
    /// Human label of where the tool runs, e.g. "filesystem (MCP)".
    public var sourceLabel: String?
    public var startedAt: Date?
    public var durationMs: Double?
    public var progress: Double?
    public var progressMessage: String?
    public var errorMessage: String?

    public init(
        id: String,
        name: String,
        arguments: String,
        status: ToolCallStatus = .pending,
        sourceLabel: String? = nil,
        startedAt: Date? = nil,
        durationMs: Double? = nil,
        progress: Double? = nil,
        progressMessage: String? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.status = status
        self.sourceLabel = sourceLabel
        self.startedAt = startedAt
        self.durationMs = durationMs
        self.progress = progress
        self.progressMessage = progressMessage
        self.errorMessage = errorMessage
    }

    /// Arguments parsed as JSON; `nil` if the model produced invalid JSON.
    public var parsedArguments: JSONValue? {
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .object([:]) }
        return try? JSONValue.parse(trimmed)
    }

    public var prettyArguments: String {
        guard let parsed = parsedArguments else { return arguments }
        return parsed.encodedString(pretty: true)
    }
}

public enum MessageState: Codable, Sendable, Hashable {
    case streaming
    case complete
    case stopped
    case failed(String)

    public var isStreaming: Bool { self == .streaming }

    private enum CodingKeys: String, CodingKey { case state, error }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .state) {
        case "streaming": self = .streaming
        case "stopped": self = .stopped
        case "failed": self = .failed(try container.decodeIfPresent(String.self, forKey: .error) ?? "")
        default: self = .complete
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .streaming: try container.encode("streaming", forKey: .state)
        case .complete: try container.encode("complete", forKey: .state)
        case .stopped: try container.encode("stopped", forKey: .state)
        case .failed(let error):
            try container.encode("failed", forKey: .state)
            try container.encode(error, forKey: .error)
        }
    }
}

public struct Message: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var conversationID: UUID
    public var parentID: UUID?
    public var role: Role
    public var blocks: [ContentBlock]
    public var attachments: [Attachment]
    /// Tool calls requested by an assistant message.
    public var toolCalls: [ToolCall]
    /// For `tool` messages: the call this result answers.
    public var toolCallID: String?
    /// For `tool` messages: the structured result.
    public var toolResult: ToolResult?
    public var metrics: GenerationMetrics?
    public var state: MessageState
    public var modelID: String?
    /// Completion ID reported by the server (needed for llama.cpp's stop-reasoning control).
    public var completionID: String?
    public var createdAt: Date
    public var editedAt: Date?

    public init(
        id: UUID = UUID(),
        conversationID: UUID,
        parentID: UUID?,
        role: Role,
        blocks: [ContentBlock] = [],
        attachments: [Attachment] = [],
        toolCalls: [ToolCall] = [],
        toolCallID: String? = nil,
        toolResult: ToolResult? = nil,
        metrics: GenerationMetrics? = nil,
        state: MessageState = .complete,
        modelID: String? = nil,
        completionID: String? = nil,
        createdAt: Date = Date(),
        editedAt: Date? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.parentID = parentID
        self.role = role
        self.blocks = blocks
        self.attachments = attachments
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.toolResult = toolResult
        self.metrics = metrics
        self.state = state
        self.modelID = modelID
        self.completionID = completionID
        self.createdAt = createdAt
        self.editedAt = editedAt
    }

    /// All visible text (no thinking), joined.
    public var text: String {
        blocks.compactMap { if case .text(let text) = $0 { return text } else { return nil } }.joined()
    }

    /// All thinking text, joined.
    public var reasoning: String {
        blocks.compactMap { if case .thinking(let text, _, _) = $0 { return text } else { return nil } }.joined(separator: "\n\n")
    }

    public var hasReasoning: Bool { blocks.contains(where: \.isThinking) }

    /// Replaces all text blocks with a single one, keeping thinking blocks in place.
    public mutating func setText(_ text: String) {
        let thinking = blocks.filter(\.isThinking)
        blocks = thinking + [.text(text)]
    }

    /// Copy text in markdown, optionally with the reasoning first.
    public func copyText(includeReasoning: Bool) -> String {
        guard includeReasoning, hasReasoning else { return text }
        return "<think>\n\(reasoning)\n</think>\n\n\(text)"
    }

    /// One-line preview for the sidebar.
    public var preview: String {
        let source = text.isEmpty ? (attachments.first?.name ?? "") : text
        let line = source.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return String(line.prefix(120))
    }
}
