import Foundation
import Testing
@testable import GoooeeeCore
@testable import GoooeeeTranscript

@Suite("Transcript state")
struct TranscriptStateTests {
    let conversation = UUID()

    func user(_ text: String, parent: UUID?, at time: Double) -> Message {
        Message(conversationID: conversation, parentID: parent, role: .user, blocks: [.text(text)], createdAt: Date(timeIntervalSince1970: time))
    }

    func assistant(_ blocks: [ContentBlock], parent: UUID?, at time: Double, state: MessageState = .complete) -> Message {
        Message(conversationID: conversation, parentID: parent, role: .assistant, blocks: blocks, state: state, modelID: "qwen3-8b", createdAt: Date(timeIntervalSince1970: time))
    }

    /// Applies an update to a plain array the way NSTableView would, to check index bookkeeping.
    func apply(_ update: TranscriptUpdate, to ids: inout [String], state: TranscriptState) {
        if update.isFullReload {
            ids = state.rows.map(\.id)
            return
        }
        for step in update.steps {
            for index in step.removed.reversed() { ids.remove(at: index) }
            for index in step.inserted { ids.insert(state.rows[index].id, at: index) }
        }
    }

    @Test func buildsRowsForAConversation() {
        let first = user("Hello **there**", parent: nil, at: 1)
        let reply = assistant([.thinking("hmm", duration: 2, signature: nil), .text("Para one.\n\n```swift\nlet x = 1\n```\n\nPara two.")], parent: first.id, at: 2)
        var state = TranscriptState()
        let update = state.load(tree: MessageTree([first, reply]), leafID: reply.id)
        #expect(update.isFullReload)
        let kinds = state.rows.map { row -> String in
            switch row.kind {
            case .user: "user"
            case .assistantHeader: "header"
            case .thinking: "thinking"
            case .markdown(let content): "md-\(content.row.kind)"
            case .toolCall: "tool"
            case .promptProgress: "progress"
            case .notice: "notice"
            case .footer: "footer"
            }
        }
        #expect(kinds == ["user", "header", "thinking", "md-prose", "md-code", "md-prose", "footer"])
        if case .user(let content) = state.rows[0].kind {
            #expect(content.blocks?.isEmpty == false)
        }
    }

    @Test func editedTextRedrawsItsRows() {
        let first = user("Question", parent: nil, at: 1)
        var reply = assistant([.text("First paragraph.\n\nSecond paragraph.")], parent: first.id, at: 2)
        var state = TranscriptState()
        _ = state.load(tree: MessageTree([first, reply]), leafID: reply.id)
        let before = state.rows.filter { if case .markdown = $0.kind { true } else { false } }
        // Same structure, different words: row IDs stay, so only the signature can show the change.
        reply.setText("First paragraph.\n\nChanged paragraph.")
        let update = state.update(messages: [reply], leafID: reply.id, streaming: [])
        let after = state.rows.filter { if case .markdown = $0.kind { true } else { false } }
        #expect(before.map(\.id) == after.map(\.id))
        #expect(before.map(\.signature) != after.map(\.signature))
        #expect(!update.reloaded.isEmpty)
        if case .markdown(let old) = before[0].kind, case .markdown(let new) = after[0].kind {
            #expect(old.row.items.map(\.key) != new.row.items.map(\.key))
        }
    }

    @Test func streamingUpdatesOnlyTouchTheTail() {
        let first = user("Question", parent: nil, at: 1)
        var reply = assistant([], parent: first.id, at: 2, state: .streaming)
        var state = TranscriptState()
        var ids: [String] = []
        apply(state.load(tree: MessageTree([first, reply]), leafID: reply.id, streaming: [reply.id]), to: &ids, state: state)
        #expect(ids == state.rows.map(\.id))

        var text = ""
        let pieces = ["Hello ", "world.\n\n", "Second para", "graph.\n\n```py\nprint(1)", "\n```\n\nDone."]
        for piece in pieces {
            text += piece
            reply.blocks = [.text(text)]
            let update = state.update(messages: [reply], leafID: reply.id, streaming: [reply.id])
            apply(update, to: &ids, state: state)
            #expect(ids == state.rows.map(\.id))
            #expect(!update.isFullReload)
        }

        reply.state = .complete
        reply.metrics = GenerationMetrics(completionTokens: 10)
        let final = state.update(messages: [reply], leafID: reply.id, streaming: [])
        apply(final, to: &ids, state: state)
        #expect(ids == state.rows.map(\.id))
        #expect(final.reloaded.contains(state.rows.count - 1))  // footer
    }

    @Test func toolResultsRenderInsideCallRows() {
        let first = user("Use a tool", parent: nil, at: 1)
        var call = ToolCall(id: "call_1", name: "echo", arguments: "{}", status: .running)
        var reply = assistant([], parent: first.id, at: 2)
        reply.toolCalls = [call]
        var state = TranscriptState()
        _ = state.load(tree: MessageTree([first, reply]), leafID: reply.id)

        call.status = .completed
        reply.toolCalls = [call]
        let tool = Message(conversationID: conversation, parentID: reply.id, role: .tool, blocks: [.text("ok")], toolCallID: "call_1",
                           toolResult: .text("ok"), createdAt: Date(timeIntervalSince1970: 3))
        let update = state.update(messages: [reply, tool], leafID: tool.id, streaming: [])
        #expect(!update.isFullReload)
        let toolRow = state.rows.first { if case .toolCall = $0.kind { return true } else { return false } }
        guard case .toolCall(let content)? = toolRow?.kind else {
            Issue.record("missing tool row")
            return
        }
        #expect(content.result?.textForModel == "ok")
        #expect(content.call.status == .completed)
        #expect(!state.rows.contains { $0.messageID == tool.id })
    }

    @Test func branchSwitchReloads() {
        let first = user("Q", parent: nil, at: 1)
        let a = assistant([.text("A")], parent: first.id, at: 2)
        let b = assistant([.text("B")], parent: first.id, at: 3)
        var state = TranscriptState()
        _ = state.load(tree: MessageTree([first, a, b]), leafID: b.id)
        if case .assistantHeader(let header) = state.rows[1].kind {
            #expect(header.branch == BranchInfo(index: 1, count: 2))
        }
        let update = state.update(messages: [], leafID: a.id, streaming: [])
        #expect(update.isFullReload)
        #expect(state.path.last?.id == a.id)
    }

    @Test func pagesOlderMessages() {
        var messages: [Message] = []
        var parent: UUID?
        for index in 0..<100 {
            let message = index % 2 == 0
                ? user("u\(index)", parent: parent, at: Double(index))
                : assistant([.text("a\(index)")], parent: parent, at: Double(index))
            messages.append(message)
            parent = message.id
        }
        var state = TranscriptState()
        _ = state.load(tree: MessageTree(messages), leafID: parent)
        #expect(state.windowStart == 60)
        #expect(state.hasOlderMessages)
        let before = state.rows.count
        let update = state.loadOlder()
        #expect(update.prependedCount == state.rows.count - before)
        #expect(state.windowStart == 20)
        _ = state.loadOlder()
        #expect(!state.hasOlderMessages)
    }

    @Test func failedAndStoppedNotices() {
        let first = user("Q", parent: nil, at: 1)
        let failed = assistant([.text("partial")], parent: first.id, at: 2, state: .failed("HTTP 500: boom"))
        var state = TranscriptState()
        _ = state.load(tree: MessageTree([first, failed]), leafID: failed.id)
        #expect(state.rows.contains { if case .notice(let notice) = $0.kind { return notice.style == .error } else { return false } })
    }

    @Test func diffHandlesInterleavedChanges() {
        func row(_ id: String, _ signature: Int = 0) -> TranscriptRow {
            TranscriptRow(id: id, messageID: UUID(), kind: .notice(NoticeContent(style: .info, text: id, suggestion: nil)), signature: signature)
        }
        let (step, reloaded) = TranscriptState.diff(old: [row("a"), row("x"), row("b")], new: [row("a"), row("b", 1), row("y")], offset: 5)
        #expect(step?.removed == IndexSet([6]))
        #expect(step?.inserted == IndexSet([7]))
        #expect(reloaded == ["b"])
        let (none, changed) = TranscriptState.diff(old: [row("a")], new: [row("a", 2)], offset: 0)
        #expect(none == nil)
        #expect(changed == ["a"])
    }
}
