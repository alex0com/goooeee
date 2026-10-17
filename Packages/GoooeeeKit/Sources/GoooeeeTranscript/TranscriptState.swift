import Foundation
import GoooeeeCore
import GoooeeeMarkdown

/// Display options that change which rows are produced.
public struct TranscriptOptions: Sendable, Hashable {
    public var renderUserMarkdown: Bool
    public var renderMath: Bool
    public var showStats: Bool
    public var enableContinue: Bool
    /// The connection supports llama.cpp's stop-reasoning control.
    public var canStopReasoning: Bool

    public init(renderUserMarkdown: Bool = true, renderMath: Bool = true, showStats: Bool = true, enableContinue: Bool = true, canStopReasoning: Bool = false) {
        self.renderUserMarkdown = renderUserMarkdown
        self.renderMath = renderMath
        self.showStats = showStats
        self.enableContinue = enableContinue
        self.canStopReasoning = canStopReasoning
    }
}

/// Row changes for the table, applied in order inside one batch update.
public struct TranscriptUpdate: Sendable {
    public struct Step: Sendable, Hashable {
        /// Indexes in the table as it is before this step.
        public var removed: IndexSet
        /// Indexes in the table after this step.
        public var inserted: IndexSet
    }

    public var isFullReload: Bool
    public var steps: [Step]
    /// Indexes (final numbering) whose content changed in place.
    public var reloaded: IndexSet
    /// Rows were inserted above the existing ones (older messages paged in).
    public var prependedCount: Int

    public static let full = TranscriptUpdate(isFullReload: true, steps: [], reloaded: [], prependedCount: 0)
    public static let none = TranscriptUpdate(isFullReload: false, steps: [], reloaded: [], prependedCount: 0)

    public var isEmpty: Bool { !isFullReload && steps.isEmpty && reloaded.isEmpty }
}

/// Builds transcript rows from a conversation path and updates them incrementally while streaming.
///
/// Each message owns a contiguous segment of rows. A streaming message only rebuilds its own
/// segment; its markdown is parsed incrementally (completed blocks are frozen), so the cost of
/// an update doesn't grow with the length of the conversation.
public struct TranscriptState: Sendable {
    public private(set) var rows: [TranscriptRow] = []
    public private(set) var path: [Message] = []
    public private(set) var windowStart = 0
    public var options: TranscriptOptions

    private var segments: [UUID: [TranscriptRow]] = [:]
    private var engines: [String: IncrementalMarkdown] = [:]
    private var tree = MessageTree([])
    private var streaming: Set<UUID> = []
    private var progress: [UUID: PromptProgress] = [:]
    private var toolResults: [String: ToolResult] = [:]

    public static let pageSize = 40

    public init(options: TranscriptOptions = TranscriptOptions()) {
        self.options = options
    }

    /// Visible messages (tool results are shown inside their call rows).
    public var visibleMessages: ArraySlice<Message> { path[windowStart...] }

    public var hasOlderMessages: Bool { windowStart > 0 }

    public func message(_ id: UUID) -> Message? {
        tree[id]
    }

    public func rowIndex(id: String) -> Int? {
        rows.firstIndex { $0.id == id }
    }

    // MARK: Full load

    /// Replaces everything (conversation opened, branch switched, options changed).
    public mutating func load(tree: MessageTree, leafID: UUID?, streaming: Set<UUID> = [], progress: [UUID: PromptProgress] = [:]) -> TranscriptUpdate {
        self.tree = tree
        self.streaming = streaming
        self.progress = progress
        path = tree.path(to: leafID)
        windowStart = max(0, displayedCountStart(for: path))
        rebuildToolResults()
        segments = [:]
        let keep = Set(path.map(\.id))
        engines = engines.filter { key, _ in keep.contains(where: { key.hasPrefix($0.uuidString) }) }
        rows = []
        for message in path[windowStart...] {
            let segment = buildRows(for: message)
            segments[message.id] = segment
            rows += segment
        }
        return .full
    }

    /// Start index so the last `pageSize` displayable messages are shown.
    private func displayedCountStart(for path: [Message]) -> Int {
        var count = 0
        var index = path.count
        while index > 0 && count < Self.pageSize {
            index -= 1
            if path[index].role != .tool { count += 1 }
        }
        return index
    }

    /// Shows up to `pageSize` older messages above the current ones.
    public mutating func loadOlder() -> TranscriptUpdate {
        guard windowStart > 0 else { return .none }
        let newStart = max(0, windowStart - Self.pageSize)
        var inserted: [TranscriptRow] = []
        for message in path[newStart..<windowStart] {
            let segment = buildRows(for: message)
            segments[message.id] = segment
            inserted += segment
        }
        windowStart = newStart
        rows = inserted + rows
        return TranscriptUpdate(
            isFullReload: false,
            steps: inserted.isEmpty ? [] : [.init(removed: [], inserted: IndexSet(0..<inserted.count))],
            reloaded: [],
            prependedCount: inserted.count
        )
    }

    // MARK: Incremental updates

    /// Applies new message state. `changed` are the messages whose content changed; new
    /// messages that extend the current path are appended.
    public mutating func update(
        messages changed: [Message],
        leafID: UUID?,
        streaming: Set<UUID>,
        progress: [UUID: PromptProgress] = [:]
    ) -> TranscriptUpdate {
        for message in changed { tree.upsert(message) }
        let newPath = tree.path(to: leafID)
        let oldIDs = path.map(\.id)
        let newIDs = newPath.map(\.id)
        let streamingChanged = streaming != self.streaming
        self.streaming = streaming
        self.progress = progress

        // A branch switch or deletion: rebuild.
        guard newIDs.count >= oldIDs.count, Array(newIDs.prefix(oldIDs.count)) == oldIDs else {
            return load(tree: tree, leafID: leafID, streaming: streaming, progress: progress)
        }
        path = newPath
        rebuildToolResults()

        var dirty = Set(changed.map(\.id))
        // Tool results render inside the assistant message that made the call.
        for message in changed where message.role == .tool {
            if let parent = message.parentID { dirty.insert(parent) }
            if let owner = path.last(where: { $0.toolCalls.contains { $0.id == message.toolCallID } }) { dirty.insert(owner.id) }
        }
        if streamingChanged {
            for message in path[windowStart...] where message.role == .assistant { dirty.insert(message.id) }
        }
        for id in progress.keys { dirty.insert(id) }

        var steps: [TranscriptUpdate.Step] = []
        var reloadedIDs = Set<String>()

        // Existing segments that changed, in path order.
        for message in path[windowStart...] where dirty.contains(message.id) && segments[message.id] != nil {
            let old = segments[message.id] ?? []
            let new = buildRows(for: message)
            guard let offset = rows.firstIndex(where: { $0.messageID == message.id }) ?? segmentOffset(for: message.id) else { continue }
            let (step, changedRowIDs) = Self.diff(old: old, new: new, offset: offset)
            if let step { steps.append(step) }
            reloadedIDs.formUnion(changedRowIDs)
            rows.replaceSubrange(offset..<(offset + old.count), with: new)
            segments[message.id] = new
        }

        // New messages at the end.
        for message in path[windowStart...] where segments[message.id] == nil {
            let new = buildRows(for: message)
            segments[message.id] = new
            guard !new.isEmpty else { continue }
            steps.append(.init(removed: [], inserted: IndexSet(rows.count..<(rows.count + new.count))))
            rows += new
        }

        var reloaded = IndexSet()
        if !reloadedIDs.isEmpty {
            for (index, row) in rows.enumerated() where reloadedIDs.contains(row.id) { reloaded.insert(index) }
        }
        return TranscriptUpdate(isFullReload: false, steps: steps, reloaded: reloaded, prependedCount: 0)
    }

    /// Re-renders every row (font or option changes).
    public mutating func rebuildAll() -> TranscriptUpdate {
        engines = [:]
        let leaf = path.last?.id
        let saved = windowStart
        let update = load(tree: tree, leafID: leaf, streaming: streaming, progress: progress)
        if saved < windowStart {
            windowStart = saved
            rows = []
            for message in path[windowStart...] {
                let segment = buildRows(for: message)
                segments[message.id] = segment
                rows += segment
            }
        }
        return update
    }

    private func segmentOffset(for id: UUID) -> Int? {
        var offset = 0
        for message in path[windowStart...] {
            if message.id == id { return offset }
            offset += segments[message.id]?.count ?? 0
        }
        return nil
    }

    private mutating func rebuildToolResults() {
        toolResults = [:]
        for message in path where message.role == .tool {
            if let id = message.toolCallID, let result = message.toolResult { toolResults[id] = result }
        }
    }

    // MARK: Diff

    /// Diffs one message's rows. Returns the structural step (if any) and the IDs of rows to redraw.
    static func diff(old: [TranscriptRow], new: [TranscriptRow], offset: Int) -> (TranscriptUpdate.Step?, Set<String>) {
        var reloaded = Set<String>()
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix].id == new[prefix].id {
            if old[prefix].signature != new[prefix].signature { reloaded.insert(new[prefix].id) }
            prefix += 1
        }
        if prefix == old.count && prefix == new.count {
            return (nil, reloaded)
        }
        // Keep rows that still exist in order; remove the rest of the old tail, insert the rest of the new.
        let oldTail = Array(old[prefix...])
        let newTail = Array(new[prefix...])
        let newIDs = newTail.map(\.id)
        var removed = IndexSet()
        var kept: [String] = []
        for (index, row) in oldTail.enumerated() {
            if newIDs.contains(row.id) {
                kept.append(row.id)
            } else {
                removed.insert(offset + prefix + index)
            }
        }
        // Kept rows must appear in the same relative order in the new tail.
        let keptInNew = newIDs.filter { kept.contains($0) }
        guard keptInNew == kept else {
            return (TranscriptUpdate.Step(removed: IndexSet((offset + prefix)..<(offset + old.count)),
                                          inserted: IndexSet((offset + prefix)..<(offset + new.count))), reloaded)
        }
        var inserted = IndexSet()
        for (index, row) in newTail.enumerated() {
            if kept.contains(row.id) {
                if let previous = oldTail.first(where: { $0.id == row.id }), previous.signature != row.signature {
                    reloaded.insert(row.id)
                }
            } else {
                inserted.insert(offset + prefix + index)
            }
        }
        if removed.isEmpty && inserted.isEmpty { return (nil, reloaded) }
        return (TranscriptUpdate.Step(removed: removed, inserted: inserted), reloaded)
    }

    // MARK: Row building

    private mutating func buildRows(for message: Message) -> [TranscriptRow] {
        switch message.role {
        case .tool:
            return []
        case .system:
            return [notice(message, NoticeContent(style: .info, text: "System: " + message.text, suggestion: nil), suffix: "system")]
        case .user:
            return [userRow(message)]
        case .assistant:
            return assistantRows(message)
        }
    }

    private func branch(_ message: Message) -> BranchInfo {
        let position = tree.branchPosition(of: message.id)
        return BranchInfo(index: position.index, count: position.count)
    }

    private mutating func userRow(_ message: Message) -> TranscriptRow {
        let text = message.text
        let blocks: [MDBlock]? = options.renderUserMarkdown && !text.isEmpty
            ? IncrementalMarkdown.render(text, options: .init(math: options.renderMath)).flatMap { $0.items.map(\.block) }
            : nil
        let content = UserContent(
            text: text,
            blocks: blocks,
            attachments: message.attachments.map(AttachmentSummary.init),
            branch: branch(message),
            isEdited: message.editedAt != nil
        )
        let signature = TranscriptRow.signature { hasher in
            hasher.combine(text)
            hasher.combine(content.attachments)
            hasher.combine(content.branch)
            hasher.combine(content.isEdited)
            hasher.combine(options.renderUserMarkdown)
        }
        return TranscriptRow(id: "\(message.id.uuidString)/user", messageID: message.id, kind: .user(content), signature: signature)
    }

    private mutating func assistantRows(_ message: Message) -> [TranscriptRow] {
        let id = message.id.uuidString
        let isStreaming = streaming.contains(message.id)
        var rows: [TranscriptRow] = []
        let branchInfo = branch(message)

        let header = AssistantHeader(modelName: message.modelID.map(ModelNameFormatter.shortName), branch: branchInfo, isStreaming: isStreaming)
        rows.append(TranscriptRow(id: "\(id)/header", messageID: message.id, kind: .assistantHeader(header),
                                  signature: TranscriptRow.signature { $0.combine(header) }))

        if isStreaming, let progress = progress[message.id], message.blocks.isEmpty, message.toolCalls.isEmpty {
            rows.append(TranscriptRow(id: "\(id)/progress", messageID: message.id, kind: .promptProgress(progress),
                                      signature: TranscriptRow.signature { $0.combine(progress) }))
        }

        let lastBlockIndex = message.blocks.indices.last
        for (index, block) in message.blocks.enumerated() {
            switch block {
            case .thinking(let text, let duration, _):
                let blockStreaming = isStreaming && index == lastBlockIndex && duration == nil
                let content = ThinkingContent(
                    blockIndex: index,
                    text: text,
                    isStreaming: blockStreaming,
                    duration: duration,
                    canStop: blockStreaming && options.canStopReasoning && message.completionID != nil
                )
                rows.append(TranscriptRow(id: "\(id)/think/\(index)", messageID: message.id, kind: .thinking(content), signature: TranscriptRow.signature { hasher in
                    hasher.combine(text.utf8.count)
                    hasher.combine(blockStreaming)
                    hasher.combine(duration != nil)
                    hasher.combine(content.canStop)
                }))
            case .text(let text):
                let key = "\(id)/text/\(index)"
                let blockStreaming = isStreaming && index == lastBlockIndex
                var engine = engines[key] ?? IncrementalMarkdown(options: .init(math: options.renderMath))
                let markdownRows = engine.update(text, isFinal: !blockStreaming)
                engines[key] = engine
                for markdownRow in markdownRows {
                    let content = MarkdownContent(row: markdownRow, role: .assistant, isStreaming: blockStreaming && markdownRow.isLive, blockIndex: index)
                    rows.append(TranscriptRow(
                        id: "\(key)/\(markdownRow.id)",
                        messageID: message.id,
                        kind: .markdown(content),
                        signature: TranscriptRow.markdownSignature(markdownRow, isStreaming: content.isStreaming)
                    ))
                }
            }
        }

        for call in message.toolCalls {
            let content = ToolCallContent(call: call, result: toolResults[call.id])
            rows.append(TranscriptRow(id: "\(id)/tool/\(call.id)", messageID: message.id, kind: .toolCall(content),
                                      signature: TranscriptRow.signature { $0.combine(content) }))
        }

        switch message.state {
        case .failed(let error):
            rows.append(notice(message, NoticeContent(style: .error, text: error, suggestion: nil), suffix: "notice"))
        case .stopped:
            rows.append(notice(message, NoticeContent(style: .stopped, text: "Stopped", suggestion: nil), suffix: "notice"))
        default:
            break
        }

        let footer = FooterContent(
            metrics: options.showStats ? message.metrics : nil,
            isStreaming: isStreaming,
            state: message.state,
            branch: branchInfo,
            canContinue: options.enableContinue && !isStreaming && message.toolCalls.isEmpty && (message.state == .stopped || message.metrics.map { _ in true } ?? false),
            hasReasoning: message.hasReasoning,
            modelID: message.modelID
        )
        rows.append(TranscriptRow(id: "\(id)/footer", messageID: message.id, kind: .footer(footer), signature: TranscriptRow.signature { hasher in
            hasher.combine(footer)
        }))
        return rows
    }

    private func notice(_ message: Message, _ content: NoticeContent, suffix: String) -> TranscriptRow {
        TranscriptRow(id: "\(message.id.uuidString)/\(suffix)", messageID: message.id, kind: .notice(content),
                      signature: TranscriptRow.signature { $0.combine(content) })
    }
}
