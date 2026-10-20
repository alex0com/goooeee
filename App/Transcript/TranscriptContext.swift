import AppKit
import GoooeeeCore
import GoooeeeMarkdown
import GoooeeeTranscript

/// A message being edited in place.
struct TranscriptEditState: Equatable {
    var messageID: UUID
    var isUser: Bool
    var text: String
    var original: String
}

/// Which cell class renders a row.
enum TranscriptCellKind: String {
    case user, editor, header, thinking, prose, code, table, math, tool, progress, notice, footer, hidden

    var identifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("transcript." + rawValue)
    }

    @MainActor
    func makeView() -> TranscriptCellView {
        switch self {
        case .user: UserMessageCell(frame: .zero)
        case .editor: EditorCell(frame: .zero)
        case .header: AssistantHeaderCell(frame: .zero)
        case .thinking: ThinkingCell(frame: .zero)
        case .prose: ProseCell(frame: .zero)
        case .code: CodeBlockCell(frame: .zero)
        case .table: TableCell(frame: .zero)
        case .math: MathBlockCell(frame: .zero)
        case .tool: ToolCallCell(frame: .zero)
        case .progress: PromptProgressCell(frame: .zero)
        case .notice: NoticeCell(frame: .zero)
        case .footer: FooterCell(frame: .zero)
        case .hidden: HiddenCell(frame: .zero)
        }
    }

    @MainActor
    func height(for row: TranscriptRow, width: CGFloat, context: TranscriptContext) -> CGFloat {
        switch self {
        case .user: UserMessageCell.height(for: row, width: width, context: context)
        case .editor: EditorCell.height(for: row, width: width, context: context)
        case .header: AssistantHeaderCell.height(for: row, width: width, context: context)
        case .thinking: ThinkingCell.height(for: row, width: width, context: context)
        case .prose: ProseCell.height(for: row, width: width, context: context)
        case .code: CodeBlockCell.height(for: row, width: width, context: context)
        case .table: TableCell.height(for: row, width: width, context: context)
        case .math: MathBlockCell.height(for: row, width: width, context: context)
        case .tool: ToolCallCell.height(for: row, width: width, context: context)
        case .progress: PromptProgressCell.height(for: row, width: width, context: context)
        case .notice: NoticeCell.height(for: row, width: width, context: context)
        case .footer: FooterCell.height(for: row, width: width, context: context)
        case .hidden: 1
        }
    }
}

/// Shared state for the cells of one transcript: theme, renderers, caches, UI state and actions.
@MainActor
final class TranscriptContext {
    weak var controller: ChatController?
    weak var workspace: WorkspaceModel?
    weak var viewController: TranscriptViewController?
    private(set) var settings: AppSettings
    private(set) var theme: TranscriptTheme
    let renderer: MarkdownRenderer
    let highlighter = CodeHighlighter()
    let measurer = TextMeasurer()

    var editing: TranscriptEditState?
    /// Focus the editor text view the next time an editor cell is configured.
    var focusEditor = false
    /// Code blocks the user expanded past the collapsed height.
    var expandedCode: Set<String> = []

    private struct HeightEntry {
        var signature: Int
        var state: Int
        var width: CGFloat
        var height: CGFloat
    }

    private var heights: [String: HeightEntry] = [:]
    private var strings = LRUCache<String, NSAttributedString>(capacity: 800)
    private var thumbnails = LRUCache<UUID, NSImage>(capacity: 200)
    private var tableLayouts = LRUCache<String, MarkdownTableLayout>(capacity: 120)
    private var saveNames: [String: String?] = [:]
    private var themeGeneration = 0

    init(store: SettingsStore) {
        settings = store.settings
        let theme = TranscriptTheme(store: store, isDark: false, generation: 0)
        self.theme = theme
        renderer = MarkdownRenderer(theme: theme)
        highlighter.onHighlighted = { [weak self] rowID in
            self?.viewController?.reconfigureRow(id: rowID)
        }
    }

    /// Rebuilds the theme and drops every render and height cache.
    func apply(store: SettingsStore, isDark: Bool) {
        themeGeneration += 1
        settings = store.settings
        theme = TranscriptTheme(store: store, isDark: isDark, generation: themeGeneration)
        FontVariants.clear()
        renderer.setTheme(theme)
        highlighter.removeAll()
        measurer.removeAll()
        strings.removeAll()
        tableLayouts.removeAll()
        heights.removeAll()
    }

    // MARK: Geometry

    /// The centered content column for a cell of `width`.
    func column(for width: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let side = TranscriptMetrics.sidePadding
        let columnWidth = min(theme.maxContentWidth, max(120, width - side * 2)).rounded(.down)
        return (max(0, ((width - columnWidth) / 2).rounded(.down)), columnWidth)
    }

    // MARK: Row kinds and heights

    func cellKind(for row: TranscriptRow) -> TranscriptCellKind {
        switch row.kind {
        case .user:
            return editing?.messageID == row.messageID ? .editor : .user
        case .assistantHeader:
            return .header
        case .thinking:
            return .thinking
        case .markdown(let content):
            if isContentHidden(row.messageID) { return .hidden }
            switch content.row.kind {
            case .prose: return .prose
            case .code: return .code
            case .table: return .table
            case .math: return .math
            }
        case .toolCall:
            return .tool
        case .promptProgress:
            return .progress
        case .notice:
            return .notice
        case .footer:
            return editing?.messageID == row.messageID ? .editor : .footer
        }
    }

    /// The assistant message's text is replaced by the editor or the raw output in its footer.
    func isContentHidden(_ messageID: UUID) -> Bool {
        if let editing, editing.messageID == messageID, !editing.isUser { return true }
        return controller?.rawOutputMessages.contains(messageID) == true
    }

    /// UI state that changes a row's height without changing its content.
    private func stateKey(for row: TranscriptRow) -> Int {
        var hasher = Hasher()
        hasher.combine(cellKind(for: row).rawValue)
        switch row.kind {
        case .thinking(let content):
            hasher.combine(isThinkingExpanded(row, content))
        case .markdown:
            hasher.combine(expandedCode.contains(row.id))
        case .toolCall(let content):
            hasher.combine(isToolExpanded(content.call))
            hasher.combine(hasPendingPermission(content.call))
        case .footer:
            hasher.combine(controller?.rawOutputMessages.contains(row.messageID) ?? false)
        default:
            break
        }
        if let editing, editing.messageID == row.messageID {
            hasher.combine(editing.text)
        }
        return hasher.finalize()
    }

    func height(for row: TranscriptRow, width: CGFloat) -> CGFloat {
        let state = stateKey(for: row)
        if let entry = heights[row.id], entry.signature == row.signature, entry.state == state, entry.width == width {
            return entry.height
        }
        let height = max(1, ceil(cellKind(for: row).height(for: row, width: width, context: self)))
        heights[row.id] = HeightEntry(signature: row.signature, state: state, width: width, height: height)
        return height
    }

    func pruneHeights(keeping ids: Set<String>) {
        guard heights.count > ids.count + 200 else { return }
        heights = heights.filter { ids.contains($0.key) }
    }

    /// Drops every cache entry for a message (after an in-place edit).
    func invalidate(messageID: UUID) {
        let prefix = messageID.uuidString
        for key in heights.keys where key.hasPrefix(prefix) {
            heights[key] = nil
        }
        strings.removeAll { $0.hasPrefix(prefix) }
        tableLayouts.removeAll { $0.hasPrefix(prefix) }
        measurer.remove(keysWithPrefix: prefix)
        renderer.invalidate(rowsWithPrefix: prefix)
    }

    // MARK: Styles

    var assistantStyle: MarkdownStyle {
        MarkdownStyle(font: theme.bodyFont, color: TranscriptColors.text, lineHeightMultiple: theme.lineHeightMultiple, paragraphSpacing: theme.paragraphSpacing)
    }

    var userStyle: MarkdownStyle {
        MarkdownStyle(font: theme.userFont, color: TranscriptColors.text, lineHeightMultiple: theme.lineHeightMultiple, paragraphSpacing: (theme.userFont.pointSize * 0.5).rounded())
    }

    var thinkingStyle: MarkdownStyle {
        MarkdownStyle(font: theme.thinkingFont, color: TranscriptColors.secondaryText, lineHeightMultiple: theme.lineHeightMultiple, paragraphSpacing: (theme.thinkingFont.pointSize * 0.5).rounded())
    }

    // MARK: Content

    func cachedString(_ key: String, build: () -> NSAttributedString) -> NSAttributedString {
        if let cached = strings.value(for: key) { return cached }
        let built = build()
        strings.set(built, for: key)
        return built
    }

    func userString(_ row: TranscriptRow, _ content: UserContent) -> NSAttributedString {
        cachedString("\(row.id)#\(row.signature)") {
            if let blocks = content.blocks {
                return renderer.renderBlocks(blocks, style: userStyle)
            }
            return renderer.plain(content.text, style: userStyle)
        }
    }

    /// Thinking text. While streaming only the tail is shown as plain text, so long reasoning stays cheap.
    /// The tail's start moves in steps rather than on every update, so between steps the text view
    /// only appends (see `TranscriptTextView.setContent`).
    func thinkingString(_ row: TranscriptRow, _ content: ThinkingContent) -> NSAttributedString {
        if content.isStreaming {
            return cachedString("\(row.id)#\(row.signature)#live") {
                let limit = 6000
                let step = 1500
                var text = content.text
                let length = text.utf16.count
                if length > limit {
                    let nsText = text as NSString
                    let cut = nsText.rangeOfComposedCharacterSequence(at: ((length - limit) / step + 1) * step).location
                    let tail = nsText.substring(from: cut)
                    let start = tail.firstIndex(of: "\n").map { tail.index(after: $0) } ?? tail.startIndex
                    text = "…\n" + tail[start...]
                }
                return renderer.plain(text.trimmingCharacters(in: .whitespacesAndNewlines), style: thinkingStyle)
            }
        }
        return cachedString("\(row.id)#\(row.signature)") {
            let text = content.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if settings.renderThinkingAsMarkdown {
                return renderer.renderBlocks(MarkdownParser.parse(text, options: .init(math: settings.renderMath)), style: thinkingStyle)
            }
            return renderer.plain(text, style: thinkingStyle)
        }
    }

    /// Cached per signature, so the height pass and the cell share one render per frame.
    func proseString(_ row: TranscriptRow, _ content: MarkdownContent) -> NSAttributedString {
        cachedString("\(row.id)#\(row.signature)") {
            renderer.renderProse(content.row, rowID: row.id, style: assistantStyle)
        }
    }

    func codeString(rowID: String, code: String, language: String?, isOpen: Bool) -> NSAttributedString {
        let display = CodeHighlighter.displayCode(code)
        if isOpen {
            return highlighter.liveAttributedString(code: display, language: language, style: theme.codeStyle, rowID: rowID)
        }
        return highlighter.attributedString(code: display, language: language, style: theme.codeStyle, rowID: rowID)
    }

    /// `color` defaults to `TranscriptColors.text`.
    func monospaced(_ text: String, key: String, color: NSColor? = nil, limit: Int = 12_000) -> NSAttributedString {
        let color = color ?? TranscriptColors.text
        return cachedString(key) {
            var shown = text
            if shown.utf16.count > limit {
                shown = (shown as NSString).substring(to: limit) + "\n… (\(text.utf16.count - limit) more characters)"
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byCharWrapping
            return NSAttributedString(string: shown, attributes: [
                .font: FontVariants.resized(theme.codeFont, to: (theme.codeFont.pointSize * 0.95).rounded()),
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ])
        }
    }

    func measure(_ string: NSAttributedString, width: CGFloat, key: String?) -> TextMeasurer.Size {
        measurer.measure(string, width: width, key: key)
    }

    func tableLayout(for row: TranscriptRow, table: MDTable, width: CGFloat) -> MarkdownTableLayout {
        let key = "\(row.id)#\(row.signature)|\(Int(width))"
        if let cached = tableLayouts.value(for: key) { return cached }
        let layout = MarkdownTableLayout(table: table, availableWidth: width, renderer: renderer, font: theme.bodyFont)
        tableLayouts.set(layout, for: key)
        return layout
    }

    func thumbnail(for attachment: Attachment) -> NSImage? {
        if let cached = thumbnails.value(for: attachment.id) { return cached }
        guard let image = AttachmentLoader.thumbnail(for: attachment, maxSize: TranscriptMetrics.attachmentTile * 2) else { return nil }
        thumbnails.set(image, for: attachment.id)
        return image
    }

    func message(_ id: UUID) -> Message? {
        controller?.tree[id]
    }

    // MARK: Expansion state

    func isThinkingExpanded(_ row: TranscriptRow, _ content: ThinkingContent) -> Bool {
        if let explicit = controller?.thinkingExpansion[row.id] { return explicit }
        switch settings.thinkingDisplay {
        case .alwaysExpanded: return true
        case .alwaysCollapsed: return false
        case .collapseWhenDone: return content.isStreaming
        }
    }

    func toggleThinking(_ row: TranscriptRow) {
        guard let controller, case .thinking(let content) = row.kind else { return }
        controller.thinkingExpansion[row.id] = !isThinkingExpanded(row, content)
        viewController?.refreshRows { $0.id == row.id }
    }

    func isToolExpanded(_ call: ToolCall) -> Bool {
        if hasPendingPermission(call) { return true }
        if settings.alwaysExpandToolCalls { return controller?.expandedTools.contains("-" + call.id) != true }
        return controller?.expandedTools.contains(call.id) == true
    }

    /// With "always expand", collapsing is remembered as "-<id>".
    func toggleTool(_ call: ToolCall, rowID: String) {
        guard let controller else { return }
        let expanded = isToolExpanded(call)
        if settings.alwaysExpandToolCalls {
            if expanded { controller.expandedTools.insert("-" + call.id) } else { controller.expandedTools.remove("-" + call.id) }
        } else {
            if expanded { controller.expandedTools.remove(call.id) } else { controller.expandedTools.insert(call.id) }
        }
        viewController?.refreshRows { $0.id == rowID }
    }

    func hasPendingPermission(_ call: ToolCall) -> Bool {
        call.status == .awaitingPermission && workspace?.pendingPermissions[call.id] != nil
    }

    func toggleCode(rowID: String) {
        if expandedCode.contains(rowID) { expandedCode.remove(rowID) } else { expandedCode.insert(rowID) }
        viewController?.refreshRows { $0.id == rowID }
    }

    func toggleRawOutput(_ messageID: UUID) {
        guard let controller else { return }
        if controller.rawOutputMessages.contains(messageID) {
            controller.rawOutputMessages.remove(messageID)
        } else {
            controller.rawOutputMessages.insert(messageID)
        }
        viewController?.refreshRows { $0.messageID == messageID }
    }

    // MARK: Editing

    func startEditing(_ messageID: UUID) {
        guard let controller, !controller.isGenerating, let message = controller.tree[messageID] else { return }
        if let current = editing, current.messageID != messageID { cancelEditing() }
        let text = message.text
        editing = TranscriptEditState(messageID: messageID, isUser: message.role == .user, text: text, original: text)
        focusEditor = true
        viewController?.refreshRows { $0.messageID == messageID }
        viewController?.scrollToEditor(messageID: messageID)
    }

    /// Leaves edit mode without touching the table (the conversation is being switched).
    func cancelEditingSilently() {
        editing = nil
        focusEditor = false
    }

    func updateEditingText(_ text: String) {
        guard editing != nil, editing?.text != text else { return }
        editing?.text = text
        if let messageID = editing?.messageID {
            viewController?.refreshHeights { $0.messageID == messageID && self.cellKind(for: $0) == .editor }
        }
    }

    func cancelEditing() {
        guard let current = editing else { return }
        editing = nil
        viewController?.refreshRows { $0.messageID == current.messageID }
    }

    /// Saves the edit in place, or (user messages, `send`) asks again on a new branch.
    func commitEditing(send: Bool) {
        guard let current = editing, let controller else { return }
        let text = current.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        editing = nil
        if send, current.isUser {
            guard !controller.isGenerating else {
                editing = current
                NSSound.beep()
                return
            }
            controller.editAndResend(current.messageID, text: text)
            return
        }
        guard text != current.original else {
            viewController?.refreshRows { $0.messageID == current.messageID }
            return
        }
        controller.saveEdit(current.messageID, text: text)
        controller.flush()
        invalidate(messageID: current.messageID)
        viewController?.syncRowsAfterEdit()
        viewController?.refreshRows { $0.messageID == current.messageID }
    }

    // MARK: Actions

    static func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    func copyMessage(_ messageID: UUID, includeReasoning: Bool = false) {
        guard let controller else { return }
        Self.copyToPasteboard(controller.copyText(of: messageID, includeReasoning: includeReasoning))
    }

    /// Items added to the text views' context menus.
    func menuItems(for messageID: UUID?) -> [NSMenuItem] {
        guard let messageID, let message = message(messageID) else { return [] }
        var items: [NSMenuItem] = [
            ClosureMenuItem("Copy Message as Markdown") { [weak self] in self?.copyMessage(messageID) },
        ]
        if message.hasReasoning {
            items.append(ClosureMenuItem("Copy Message with Thinking") { [weak self] in self?.copyMessage(messageID, includeReasoning: true) })
        }
        if controller?.isGenerating == false, message.role == .user || message.role == .assistant {
            items.append(ClosureMenuItem("Edit Message") { [weak self] in self?.startEditing(messageID) })
        }
        return items
    }

    func regenerate(_ messageID: UUID) { controller?.regenerate(messageID) }
    func continueMessage(_ messageID: UUID) { controller?.continueMessage(messageID) }
    func retry() { controller?.retry() }
    func stopThinking() { controller?.stopThinking() }

    func deleteMessage(_ messageID: UUID) {
        guard let controller, !controller.isGenerating else { return }
        if settings.confirmDelete {
            let alert = NSAlert()
            alert.messageText = "Delete this message and everything after it?"
            alert.informativeText = "Replies that follow it on this branch are deleted too."
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        controller.deleteMessage(messageID)
    }

    func switchBranch(_ messageID: UUID, offset: Int) {
        controller?.switchBranch(from: messageID, offset: offset)
    }

    func resolvePermission(callID: String, decision: PermissionDecision) {
        workspace?.resolvePermission(callID: callID, decision: decision)
    }

    func pasteInTerminal(_ code: String) {
        workspace?.pasteInTerminal(code)
    }

    /// The file a finished code block should be saved as (`nil`: no Save As button). Cached per
    /// row signature, because finding it searches the whole message.
    func saveName(for row: TranscriptRow, code: String, language: String?) -> String? {
        let key = "\(row.id)#\(row.signature)"
        if let cached = saveNames[key] { return cached }
        let markdown = message(row.messageID)?.text
        let suggested = CodeFileName.suggested(code: code, precedingText: markdown.flatMap { CodeFileName.precedingText(of: code, in: $0) })
        let name = CodeFileName.isSaveable(code: code, suggestedName: suggested) ? suggested ?? CodeFileName.defaultName(language: language) : nil
        if saveNames.count > 500 { saveNames.removeAll() }
        saveNames[key] = .some(name)
        return name
    }

    func saveCode(_ code: String, name: String) {
        workspace?.saveCode(code, suggestedName: name)
    }

    func preview(code: String, language: String?) {
        HTMLPreview.show(code: code, language: language)
    }

    /// Opens an attachment in its default app (written to a temporary file first).
    func openAttachment(messageID: UUID, attachmentID: UUID) {
        guard let attachment = message(messageID)?.attachments.first(where: { $0.id == attachmentID }) else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("goooeee-attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeName = attachment.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("\(attachment.id.uuidString.prefix(8))-\(safeName)")
        do {
            if let data = attachment.data {
                try data.write(to: url, options: .atomic)
            } else if let text = attachment.text {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } else {
                return
            }
            NSWorkspace.shared.open(url)
        } catch {
            workspace?.showError("Couldn't open “\(attachment.name)”: \(error.localizedDescription)")
        }
    }
}
