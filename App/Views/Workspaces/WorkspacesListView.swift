import AppKit
import GoooeeeCore
import SwiftUI

/// Window → Workspaces: every workspace with its connection and model. Open, rename, duplicate,
/// move to another connection or delete.
struct WorkspacesListView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var selection = Set<UUID>()
    @State private var sortOrder = [KeyPathComparator(\Workspace.updatedAt, order: .reverse)]
    @State private var renamingID: UUID?
    @State private var renameText = ""
    @State private var pendingDelete: [Workspace] = []
    @FocusState private var renameFocused: Bool

    var body: some View {
        table
            .contextMenu(forSelectionType: UUID.self) { ids in
                contextMenu(for: ids)
            } primaryAction: { ids in
                for workspace in workspaces(ids) { open(workspace) }
            }
            .overlay {
                if app.workspaces.isEmpty {
                    ContentUnavailableView {
                        Label("No Workspaces", systemImage: "rectangle.stack")
                    } description: {
                        Text("A workspace is a window for one server and one model, with its own chats.")
                    } actions: {
                        Button("New Workspace…") { openWindow(id: WindowID.workspace) }
                    }
                }
            }
            .toolbar { toolbar }
            .navigationTitle("Workspaces")
            .onDeleteCommand { requestDelete(selection) }
            .confirmationDialog(
                deleteTitle,
                isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } })
            ) {
                Button("Delete", role: .destructive) { deletePending() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("All their chats are deleted too. This can't be undone.")
            }
    }

    private var rows: [Workspace] {
        app.workspaces.sorted(using: sortOrder)
    }

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { workspace in
                nameCell(workspace)
            }
            TableColumn("Connection") { workspace in
                Text(connectionLabel(for: workspace))
                    .foregroundStyle(connection(for: workspace) == nil ? Color.red : .primary)
            }
            TableColumn("Model") { workspace in
                Text(workspace.modelID.map(ModelNameFormatter.shortName) ?? "—")
                    .help(workspace.modelID ?? "")
            }
            TableColumn("Last used", value: \.updatedAt) { workspace in
                Text(workspace.updatedAt, format: .relative(presentation: .named))
                    .foregroundStyle(.secondary)
            }
            TableColumn("") { workspace in
                if app.openWorkspaceIDs.contains(workspace.id) {
                    Text("Open")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .width(50)
        }
    }

    @ViewBuilder
    private func nameCell(_ workspace: Workspace) -> some View {
        if renamingID == workspace.id {
            TextField("Name", text: $renameText)
                .focused($renameFocused)
                .onSubmit { commitRename(workspace) }
                .onExitCommand { renamingID = nil }
                .onChange(of: renameFocused) { _, focused in
                    if !focused, renamingID == workspace.id { commitRename(workspace) }
                }
        } else {
            Text(workspace.name)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                openWindow(id: WindowID.workspace)
            } label: {
                Label("New Workspace", systemImage: "plus")
            }
            .help("New workspace")
            Button {
                for workspace in workspaces(selection) { open(workspace) }
            } label: {
                Label("Open", systemImage: "macwindow")
            }
            .disabled(selection.isEmpty)
            .help("Open the selected workspaces")
            Button {
                duplicate(selection)
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            .disabled(selection.count != 1)
            .help("Duplicate the selected workspace (without its chats)")
            Button {
                requestDelete(selection)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(selection.isEmpty)
            .help("Delete the selected workspaces")
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<UUID>) -> some View {
        let selected = workspaces(ids)
        if !selected.isEmpty {
            Button(selected.count == 1 ? "Open" : "Open \(selected.count) Workspaces") {
                for workspace in selected { open(workspace) }
            }
            if selected.count == 1, let workspace = selected.first {
                Button("Rename") { startRename(workspace) }
                Button("Duplicate") { duplicate(ids) }
                Menu("Connection") {
                    ForEach(app.connections) { connection in
                        Button {
                            changeConnection(of: workspace, to: connection)
                        } label: {
                            if connection.id == workspace.connectionID {
                                Label(connection.name, systemImage: "checkmark")
                            } else {
                                Text(connection.name)
                            }
                        }
                    }
                }
            }
            Divider()
            Button("Delete…", role: .destructive) { requestDelete(ids) }
        }
    }

    // MARK: Lookup

    private func workspaces(_ ids: Set<UUID>) -> [Workspace] {
        rows.filter { ids.contains($0.id) }
    }

    private func connection(for workspace: Workspace) -> ServerConnection? {
        app.connections.first { $0.id == workspace.connectionID }
    }

    private func connectionLabel(for workspace: Workspace) -> String {
        guard let connection = connection(for: workspace) else { return "Missing connection" }
        return "\(connection.name) (\(connection.engine.displayName) \(connection.hostDescription))"
    }

    /// The live model when the workspace's window is open (edits must go through it).
    private func openModel(for workspace: Workspace) -> WorkspaceModel? {
        guard app.openWorkspaceIDs.contains(workspace.id) else { return nil }
        return app.workspaceModel(for: workspace.id)
    }

    // MARK: Actions

    private func open(_ workspace: Workspace) {
        if let window = openModel(for: workspace)?.window {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: WindowID.workspace, value: workspace.id)
        }
    }

    private func startRename(_ workspace: Workspace) {
        renameText = workspace.name
        renamingID = workspace.id
        renameFocused = true
    }

    private func commitRename(_ workspace: Workspace) {
        renamingID = nil
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != workspace.name else { return }
        if let model = openModel(for: workspace) {
            model.updateWorkspace { $0.name = name }
        } else {
            var updated = workspace
            updated.name = name
            Task { await app.saveWorkspace(updated) }
        }
    }

    private func duplicate(_ ids: Set<UUID>) {
        guard let workspace = workspaces(ids).first else { return }
        Task {
            let copy = await app.duplicateWorkspace(workspace)
            selection = [copy.id]
        }
    }

    private func changeConnection(of workspace: Workspace, to connection: ServerConnection) {
        guard connection.id != workspace.connectionID else { return }
        if let model = openModel(for: workspace) {
            model.updateWorkspace { $0.connectionID = connection.id }
            model.connectionChanged(connection)
        } else {
            var updated = workspace
            updated.connectionID = connection.id
            Task { await app.saveWorkspace(updated) }
        }
    }

    private func requestDelete(_ ids: Set<UUID>) {
        pendingDelete = workspaces(ids)
    }

    private var deleteTitle: String {
        if pendingDelete.count == 1, let workspace = pendingDelete.first {
            return "Delete the workspace “\(workspace.name)”?"
        }
        return "Delete \(pendingDelete.count) workspaces?"
    }

    private func deletePending() {
        let targets = pendingDelete
        pendingDelete = []
        selection.subtract(targets.map(\.id))
        Task {
            for workspace in targets {
                await app.deleteWorkspace(workspace)
            }
        }
    }
}
