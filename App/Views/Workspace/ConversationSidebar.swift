import AppKit
import GoooeeeCore
import SwiftUI

/// The workspace's conversations, grouped by date. Swipe left to delete, right to pin.
struct ConversationSidebar: View {
    @Bindable var model: WorkspaceModel
    @Environment(AppModel.self) private var app
    @State private var selection: Set<UUID> = []
    @State private var filter = ""
    @State private var pendingDelete: Set<UUID>?

    var body: some View {
        List(selection: $selection) {
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.conversations) { conversation in
                        row(conversation)
                    }
                }
            }
            if !model.deletedConversations.isEmpty && filter.isEmpty {
                Section {
                    Button {
                        model.showRecentlyDeleted = true
                    } label: {
                        Label("Recently Deleted (\(model.deletedConversations.count))", systemImage: "trash")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $filter, placement: .sidebar, prompt: "Filter chats")
        .overlay {
            if model.conversations.isEmpty {
                ContentUnavailableView {
                    Label("No chats yet", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Start one with ⌘N.")
                } actions: {
                    Button("New Chat") { model.newConversation() }
                }
            } else if sections.isEmpty {
                ContentUnavailableView.search(text: filter)
            }
        }
        .onDeleteCommand { requestDelete(selection) }
        .onChange(of: selection) { _, newValue in
            if newValue.count == 1, let id = newValue.first, id != model.selectedConversationID {
                model.selectedConversationID = id
            }
        }
        .onChange(of: model.selectedConversationID, initial: true) { _, id in
            guard let id else {
                selection = []
                return
            }
            if !selection.contains(id) { selection = [id] }
        }
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let ids = pendingDelete { model.delete(ids) }
                pendingDelete = nil
            }
        } message: {
            Text("Deleted chats stay in Recently Deleted for \(app.settings.keepDeletedDays) days.")
        }
    }

    private var sections: [ConversationGrouping.Section] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let conversations = query.isEmpty
            ? model.conversations
            : model.conversations.filter { $0.title.lowercased().contains(query) || $0.preview.lowercased().contains(query) }
        return ConversationGrouping.sections(conversations)
    }

    private var deleteTitle: String {
        let count = pendingDelete?.count ?? 0
        return count == 1 ? "Delete this chat?" : "Delete \(count) chats?"
    }

    private func requestDelete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        if app.settings.confirmDelete {
            pendingDelete = ids
        } else {
            model.delete(ids)
        }
    }

    /// Selected rows act together (multi-selection), otherwise just the clicked row.
    private func targets(for conversation: Conversation) -> Set<UUID> {
        selection.contains(conversation.id) && selection.count > 1 ? selection : [conversation.id]
    }

    @ViewBuilder
    private func row(_ conversation: Conversation) -> some View {
        ConversationRow(
            conversation: conversation,
            controller: model.controllers[conversation.id],
            isRenaming: model.isRenamingConversationID == conversation.id,
            onRename: { title in
                model.rename(conversation.id, to: title)
                model.isRenamingConversationID = nil
            },
            onCancelRename: { model.isRenamingConversationID = nil }
        )
        .tag(conversation.id)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                // A swipe deletes right away; the toast offers Undo.
                model.delete([conversation.id])
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                model.togglePin(conversation.id)
            } label: {
                Label(conversation.isPinned ? "Unpin" : "Pin", systemImage: conversation.isPinned ? "pin.slash" : "pin")
            }
            .tint(.orange)
        }
        .contextMenu {
            contextMenu(for: conversation)
        }
    }

    @ViewBuilder
    private func contextMenu(for conversation: Conversation) -> some View {
        let ids = targets(for: conversation)
        if ids.count == 1 {
            Button("Rename") { model.isRenamingConversationID = conversation.id }
            Button(conversation.isPinned ? "Unpin" : "Pin") { model.togglePin(conversation.id) }
            Button("Copy as Markdown") { copyMarkdown(conversation) }
            Menu("Move to Workspace") {
                ForEach(app.workspaces.filter { $0.id != model.workspace.id }) { workspace in
                    Button(workspace.name) {
                        Task { await app.moveConversation(conversation, to: workspace.id) }
                    }
                }
            }
            .disabled(app.workspaces.count < 2)
            Divider()
        }
        Button(ids.count == 1 ? "Delete" : "Delete \(ids.count) Chats", role: .destructive) {
            requestDelete(ids)
        }
    }

    private func copyMarkdown(_ conversation: Conversation) {
        Task {
            let messages = (try? await app.database.messages(conversationID: conversation.id)) ?? []
            let tree = MessageTree(messages)
            let path = tree.path(to: conversation.currentLeafID)
            let markdown = path.compactMap { message -> String? in
                switch message.role {
                case .user: return "**You:**\n\n" + message.text
                case .assistant: return "**Assistant:**\n\n" + message.copyText(includeReasoning: false)
                case .system: return "**System:**\n\n" + message.text
                case .tool: return nil
                }
            }.joined(separator: "\n\n---\n\n")
            NSPasteboard.copy("# \(conversation.title)\n\n" + markdown)
            model.showInfo("Copied “\(conversation.title)”")
        }
    }
}

/// One conversation in the sidebar.
struct ConversationRow: View {
    var conversation: Conversation
    var controller: ChatController?
    var isRenaming: Bool
    var onRename: (String) -> Void
    var onCancelRename: () -> Void
    @State private var draftTitle = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if isRenaming {
                    TextField("Title", text: $draftTitle)
                        .textFieldStyle(.plain)
                        .focused($titleFocused)
                        .onSubmit { onRename(draftTitle) }
                        .onExitCommand { onCancelRename() }
                        .onAppear {
                            draftTitle = conversation.title
                            titleFocused = true
                        }
                        .onChange(of: titleFocused) { _, focused in
                            if !focused { onRename(draftTitle) }
                        }
                } else {
                    Text(conversation.title)
                        .lineLimit(1)
                        .fontWeight(.medium)
                }
                Spacer(minLength: 4)
                if controller?.isGenerating == true {
                    ProgressView().controlSize(.mini)
                } else if conversation.draft != nil {
                    Image(systemName: "pencil")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("Unsent draft")
                }
            }
            if !conversation.preview.isEmpty {
                Text(conversation.preview)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .help(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))
    }
}

/// Recently Deleted: restore or delete for good.
struct RecentlyDeletedView: View {
    var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @State private var selection: Set<UUID> = []
    @State private var confirmEmpty = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recently Deleted").font(.title3.weight(.semibold))
                    Text("Chats are removed for good after \(app.settings.keepDeletedDays) days.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)
            List(model.deletedConversations, selection: $selection) { conversation in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(conversation.title).lineLimit(1)
                        if let deleted = conversation.deletedAt {
                            Text("Deleted \(deleted.formatted(.relative(presentation: .named)))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Restore") { model.restore([conversation.id]) }
                        .buttonStyle(.borderless)
                }
                .tag(conversation.id)
                .contextMenu {
                    Button("Restore") { model.restore(targets(conversation)) }
                    Button("Delete Permanently", role: .destructive) { model.purge(targets(conversation)) }
                }
            }
            .overlay {
                if model.deletedConversations.isEmpty {
                    ContentUnavailableView("Nothing here", systemImage: "trash")
                }
            }
            Divider()
            HStack {
                Button("Empty…", role: .destructive) { confirmEmpty = true }
                    .disabled(model.deletedConversations.isEmpty)
                Spacer()
                Button("Restore Selected") { model.restore(selection) }
                    .disabled(selection.isEmpty)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 480, height: 420)
        .confirmationDialog("Delete all \(model.deletedConversations.count) chats permanently?", isPresented: $confirmEmpty, titleVisibility: .visible) {
            Button("Delete Permanently", role: .destructive) { model.emptyRecentlyDeleted() }
        } message: {
            Text("This can't be undone.")
        }
    }

    private func targets(_ conversation: Conversation) -> Set<UUID> {
        selection.contains(conversation.id) ? selection : [conversation.id]
    }
}
