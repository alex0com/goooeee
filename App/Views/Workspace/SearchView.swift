import AppKit
import GoooeeeCore
import SwiftUI

/// ⌘K: search chat titles and message text in this workspace or in all of them.
struct SearchView: View {
    var model: WorkspaceModel
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var query = ""
    @State private var allWorkspaces = false
    @State private var hits: [SearchHit] = []
    @State private var highlighted: UUID?
    @State private var searching = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search chats", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit { openHighlighted() }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                if searching { ProgressView().controlSize(.small) }
                Picker("Scope", selection: $allWorkspaces) {
                    Text("This workspace").tag(false)
                    Text("All").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                List(hits, selection: $highlighted) { hit in
                    hitRow(hit)
                        .tag(hit.conversationID)
                        .id(hit.conversationID)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { open(hit) }
                }
                .listStyle(.plain)
                .onChange(of: highlighted) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
            .overlay {
                if hits.isEmpty {
                    Text(query.isEmpty ? "Type to search titles and messages." : searching ? "" : "No matches")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 600, height: 440)
        .onAppear { fieldFocused = true }
        .onExitCommand { dismiss() }
        .task(id: SearchKey(query: query, all: allWorkspaces)) {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            searching = true
            let found = (try? await app.database.search(query, workspaceID: allWorkspaces ? nil : model.workspace.id)) ?? []
            guard !Task.isCancelled else { return }
            hits = found
            highlighted = found.first?.conversationID
            searching = false
        }
    }

    private struct SearchKey: Hashable {
        var query: String
        var all: Bool
    }

    private func hitRow(_ hit: SearchHit) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(hit.title).fontWeight(.medium).lineLimit(1)
                Spacer()
                if hit.workspaceID != model.workspace.id, let workspace = app.workspaces.first(where: { $0.id == hit.workspaceID }) {
                    Text(workspace.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if !hit.snippet.isEmpty {
                Text(highlightedSnippet(hit.snippet))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }

    /// Bolds the query words in the snippet.
    private func highlightedSnippet(_ snippet: String) -> AttributedString {
        var attributed = AttributedString(snippet)
        for word in query.split(whereSeparator: \.isWhitespace) where word.count > 1 {
            var searchStart = attributed.startIndex
            while searchStart < attributed.endIndex,
                let range = attributed[searchStart...].range(of: String(word), options: .caseInsensitive)
            {
                attributed[range].font = .callout.bold()
                attributed[range].foregroundColor = .primary
                searchStart = range.upperBound
            }
        }
        return attributed
    }

    private func move(_ offset: Int) {
        guard !hits.isEmpty else { return }
        let index = hits.firstIndex { $0.conversationID == highlighted } ?? -1
        let next = min(max(0, index + offset), hits.count - 1)
        highlighted = hits[next].conversationID
    }

    private func openHighlighted() {
        guard let hit = hits.first(where: { $0.conversationID == highlighted }) ?? hits.first else { return }
        open(hit)
    }

    private func open(_ hit: SearchHit) {
        dismiss()
        if hit.workspaceID == model.workspace.id {
            model.selectedConversationID = hit.conversationID
            return
        }
        if app.openWorkspaceIDs.contains(hit.workspaceID), let other = app.workspaceModel(for: hit.workspaceID) {
            other.selectedConversationID = hit.conversationID
            other.window?.makeKeyAndOrderFront(nil)
            return
        }
        Task {
            if var workspace = app.workspaces.first(where: { $0.id == hit.workspaceID }) {
                workspace.selectedConversationID = hit.conversationID
                await app.saveWorkspace(workspace)
            }
            openWindow(id: WindowID.workspace, value: hit.workspaceID)
        }
    }
}
