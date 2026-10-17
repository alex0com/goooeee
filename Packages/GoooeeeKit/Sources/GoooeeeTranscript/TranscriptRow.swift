import Foundation
import GoooeeeCore
import GoooeeeMarkdown

/// One row of the transcript table. Rows are small value types; the AppKit view renders them.
public struct TranscriptRow: Identifiable, Sendable {
    public enum Kind: Sendable {
        case user(UserContent)
        case assistantHeader(AssistantHeader)
        case thinking(ThinkingContent)
        case markdown(MarkdownContent)
        case toolCall(ToolCallContent)
        case promptProgress(PromptProgress)
        case notice(NoticeContent)
        case footer(FooterContent)
    }

    public var id: String
    public var messageID: UUID
    public var kind: Kind
    /// Cheap fingerprint of the content: rows whose signature changed are redrawn and re-measured.
    public var signature: Int

    public init(id: String, messageID: UUID, kind: Kind, signature: Int) {
        self.id = id
        self.messageID = messageID
        self.kind = kind
        self.signature = signature
    }
}

public struct BranchInfo: Sendable, Hashable {
    public var index: Int
    public var count: Int

    public init(index: Int, count: Int) {
        self.index = index
        self.count = count
    }

    public var label: String { "\(index + 1)/\(count)" }
    public var hasSiblings: Bool { count > 1 }
}

public struct UserContent: Sendable, Hashable {
    public var text: String
    /// Parsed markdown when "render user messages as markdown" is on.
    public var blocks: [MDBlock]?
    public var attachments: [AttachmentSummary]
    public var branch: BranchInfo
    public var isEdited: Bool
}

public struct AttachmentSummary: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var kind: AttachmentKind
    public var name: String
    public var mimeType: String
    public var byteCount: Int
    public var pixelSize: (width: Int, height: Int)?

    public static func == (lhs: AttachmentSummary, rhs: AttachmentSummary) -> Bool {
        lhs.id == rhs.id && lhs.byteCount == rhs.byteCount
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(byteCount)
    }

    public init(_ attachment: Attachment) {
        id = attachment.id
        kind = attachment.kind
        name = attachment.name
        mimeType = attachment.mimeType
        byteCount = attachment.byteCount
        if let width = attachment.pixelWidth, let height = attachment.pixelHeight {
            pixelSize = (width, height)
        }
    }
}

public struct AssistantHeader: Sendable, Hashable {
    public var modelName: String?
    public var branch: BranchInfo
    public var isStreaming: Bool
}

public struct ThinkingContent: Sendable, Hashable {
    public var blockIndex: Int
    public var text: String
    public var isStreaming: Bool
    public var duration: TimeInterval?
    /// llama.cpp's stop-reasoning control is available for this message.
    public var canStop: Bool
}

public struct MarkdownContent: Sendable {
    public var row: MarkdownRow
    public var role: Role
    public var isStreaming: Bool
    /// The text block this row belongs to (for "copy this block").
    public var blockIndex: Int
}

public struct ToolCallContent: Sendable, Hashable {
    public var call: ToolCall
    public var result: ToolResult?
}

public struct NoticeContent: Sendable, Hashable {
    public enum Style: Sendable, Hashable {
        case stopped
        case error
        case info
    }

    public var style: Style
    public var text: String
    public var suggestion: String?
}

public struct FooterContent: Sendable, Hashable {
    public var metrics: GenerationMetrics?
    public var isStreaming: Bool
    public var state: MessageState
    public var branch: BranchInfo
    public var canContinue: Bool
    public var hasReasoning: Bool
    public var modelID: String?
}

// MARK: - Signatures

extension TranscriptRow {
    static func signature(_ build: (inout Hasher) -> Void) -> Int {
        var hasher = Hasher()
        build(&hasher)
        return hasher.finalize()
    }

    /// Markdown rows change when items are added, frozen, or when the live tail changes.
    static func markdownSignature(_ row: MarkdownRow, isStreaming: Bool) -> Int {
        signature { hasher in
            hasher.combine(row.kind)
            hasher.combine(row.items.count)
            hasher.combine(row.frozenPrefixCount)
            hasher.combine(isStreaming)
            for item in row.items where !item.isFrozen {
                hasher.combine(item.block)
            }
            if let first = row.items.first, first.isFrozen { hasher.combine(first.key) }
        }
    }
}
