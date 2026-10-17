import AppKit
import GoooeeeCore
import SwiftUI

/// The Connections window: saved servers on the left, the selected connection's editor on the right.
struct ConnectionsView: View {
    @Environment(AppModel.self) private var app
    @State private var selection: UUID?
    @State private var pendingDelete: ServerConnection?
    @State private var blockedDelete: ServerConnection?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            detail
        }
        .onAppear {
            if selection == nil { selection = app.connections.first?.id }
        }
        .confirmationDialog(
            "Delete “\(pendingDelete?.name ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { connection in
            Button("Delete", role: .destructive) { delete(connection) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The connection and its saved API key are removed. This can't be undone.")
        }
        .alert(
            "“\(blockedDelete?.name ?? "")” is in use",
            isPresented: Binding(get: { blockedDelete != nil }, set: { if !$0 { blockedDelete = nil } }),
            presenting: blockedDelete
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { connection in
            Text(blockedMessage(for: connection))
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            ForEach(app.connections) { connection in
                ConnectionListRow(connection: connection, workspaceCount: app.workspacesUsing(connection).count)
                    .tag(connection.id)
                    .contextMenu { contextMenu(for: connection) }
            }
        }
        .overlay {
            if app.connections.isEmpty {
                ContentUnavailableView("No Connections", systemImage: "server.rack", description: Text("Add a server with the + button."))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
        }
        .onDeleteCommand {
            if let connection = selectedConnection { requestDelete(connection) }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 4) {
            addMenu
            Button {
                if let connection = selectedConnection { requestDelete(connection) }
            } label: {
                Image(systemName: "minus")
                    .frame(width: 20, height: 18)
            }
            .buttonStyle(.borderless)
            .disabled(selectedConnection == nil)
            .help("Delete the selected connection")
            Spacer()
        }
        .padding(8)
        .background(.bar)
    }

    private var addMenu: some View {
        Menu {
            ForEach(EngineKind.allCases) { engine in
                Button(engine.displayName) { add(engine) }
            }
        } label: {
            Image(systemName: "plus")
                .frame(width: 20, height: 18)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add a connection")
    }

    @ViewBuilder
    private func contextMenu(for connection: ServerConnection) -> some View {
        Button("Duplicate") { duplicate(connection) }
        Divider()
        Button("Delete…", role: .destructive) { requestDelete(connection) }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let connection = selectedConnection {
            ConnectionEditor(original: connection)
                .id(connection.id)
        } else {
            ContentUnavailableView(
                "No Connection Selected",
                systemImage: "server.rack",
                description: Text("A connection is a server address, its engine and the default settings sent to it.")
            )
        }
    }

    private var selectedConnection: ServerConnection? {
        selection.flatMap { id in app.connections.first { $0.id == id } }
    }

    // MARK: Actions

    private func add(_ engine: EngineKind) {
        let existing = Set(app.connections.map(\.name))
        var name = engine.displayName
        var counter = 2
        while existing.contains(name) {
            name = "\(engine.displayName) \(counter)"
            counter += 1
        }
        let connection = ServerConnection.preset(engine, name: name)
        Task {
            let saved = await app.saveConnection(connection)
            selection = saved.id
        }
    }

    private func duplicate(_ connection: ServerConnection) {
        var copy = connection
        copy.id = UUID()
        copy.name = connection.name + " copy"
        copy.apiKeyRef = nil
        copy.lastTest = nil
        copy.createdAt = Date()
        let key = app.apiKey(for: connection)
        Task {
            let saved = await app.saveConnection(copy, apiKey: key)
            selection = saved.id
        }
    }

    private func requestDelete(_ connection: ServerConnection) {
        if app.workspacesUsing(connection).isEmpty {
            pendingDelete = connection
        } else {
            blockedDelete = connection
        }
    }

    private func delete(_ connection: ServerConnection) {
        let index = app.connections.firstIndex { $0.id == connection.id }
        Task {
            await app.deleteConnection(connection)
            if selection == connection.id {
                let remaining = app.connections
                if let index, !remaining.isEmpty {
                    selection = remaining[min(index, remaining.count - 1)].id
                } else {
                    selection = nil
                }
            }
        }
    }

    private func blockedMessage(for connection: ServerConnection) -> String {
        let names = app.workspacesUsing(connection).map { "“\($0.name)”" }.joined(separator: ", ")
        return "It's used by \(names). Delete those workspaces or switch them to another connection in Window → Workspaces first."
    }
}

/// A connection in the sidebar: name, engine and host, and the result of the last test.
private struct ConnectionListRow: View {
    var connection: ServerConnection
    var workspaceCount: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: connection.engine.isLocalByDefault ? "desktopcomputer" : "cloud")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.name)
                    .lineLimit(1)
                Text("\(connection.engine.displayName) · \(connection.hostDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if workspaceCount > 0 {
                Text("\(workspaceCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("Used by \(workspaceCount) workspace\(workspaceCount == 1 ? "" : "s")")
            }
            if let test = connection.lastTest {
                Circle()
                    .fill(test.passed ? Color.green : Color.red)
                    .frame(width: 7, height: 7)
                    .help("Last test \(test.date.formatted(.relative(presentation: .named))): \(test.message)")
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Editor

/// Edits a copy of a connection; changes apply on Save (⌘S).
struct ConnectionEditor: View {
    let original: ServerConnection
    @Environment(AppModel.self) private var app
    @State private var draft: ServerConnection
    @State private var apiKey = ""
    @State private var savedAPIKey = ""
    @State private var tab: ConnectionEditorTab = .general
    /// Bumped on Revert and Save so tabs reload their local field state.
    @State private var formRevision = 0
    @State private var saveError: String?
    @State private var isSaving = false

    init(original: ServerConnection) {
        self.original = original
        _draft = State(initialValue: original)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .id(formRevision)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .navigationTitle(draft.name.isEmpty ? "Connection" : draft.name)
        .toolbar { toolbarContent }
        .onAppear {
            let key = app.apiKey(for: original) ?? ""
            apiKey = key
            savedAPIKey = key
        }
        .alert("Couldn't save", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
    }

    private var header: some View {
        Picker("Section", selection: $tab) {
            ForEach(ConnectionEditorTab.allCases) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .general:
            ConnectionGeneralTab(draft: $draft, apiKey: $apiKey)
        case .sampling:
            ConnectionSamplingTab(draft: $draft, apiKey: apiKey)
        case .thinking:
            ConnectionThinkingTab(draft: $draft)
        case .template:
            ConnectionTemplateTab(draft: $draft)
        case .launch:
            ConnectionLaunchTab(draft: $draft)
        case .test:
            ConnectionTestTab(connection: draft, apiKey: apiKey, onFinished: recordTest)
        case .curl:
            ConnectionCurlTab(connection: draft, apiKey: apiKey)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if hasChanges {
                Text("Edited")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Revert") { revert() }
                .disabled(!hasChanges || isSaving)
            Button("Save") { save() }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!hasChanges || isSaving)
        }
    }

    private var hasChanges: Bool {
        Self.comparable(draft) != Self.comparable(original) || apiKey != savedAPIKey
    }

    /// Ignores fields that change without user edits.
    private static func comparable(_ connection: ServerConnection) -> ServerConnection {
        var copy = connection
        copy.updatedAt = .distantPast
        copy.lastTest = nil
        return copy
    }

    private func revert() {
        draft = original
        apiKey = savedAPIKey
        formRevision += 1
    }

    private func save() {
        if let problem = validationProblem() {
            saveError = problem
            return
        }
        isSaving = true
        var toSave = draft
        toSave.name = toSave.name.trimmingCharacters(in: .whitespacesAndNewlines)
        toSave.lastTest = original.lastTest ?? draft.lastTest
        let key: String? = apiKey != savedAPIKey ? apiKey : nil
        Task {
            let saved = await app.saveConnection(toSave, apiKey: key)
            draft = saved
            savedAPIKey = apiKey
            isSaving = false
            formRevision += 1
        }
    }

    private func validationProblem() -> String? {
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Give the connection a name."
        }
        guard let scheme = draft.baseURL.scheme, ["http", "https"].contains(scheme), draft.baseURL.host != nil else {
            return "The server URL must start with http:// or https:// and include a host."
        }
        if let json = draft.extraBodyJSON, !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                guard case .object = try JSONValue.parse(json) else { return "Extra request JSON must be an object, like {\"key\": \"value\"}." }
            } catch {
                return "Extra request JSON isn't valid JSON: \(error.localizedDescription)"
            }
        }
        if draft.apiStyle == .openAICompletion, draft.chatTemplate == nil {
            return "The completions API needs a chat template. Load one in the Template tab, or switch the API back to chat completions."
        }
        return nil
    }

    /// Test results are saved right away, without the rest of the draft.
    private func recordTest(_ summary: ConnectionTestSummary) {
        draft.lastTest = summary
        guard let stored = app.connections.first(where: { $0.id == original.id }) else { return }
        var updated = stored
        updated.lastTest = summary
        Task { await app.saveConnection(updated) }
    }
}

enum ConnectionEditorTab: String, CaseIterable, Identifiable {
    case general, sampling, thinking, template, launch, test, curl

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .sampling: "Model & Sampling"
        case .thinking: "Thinking"
        case .template: "Template"
        case .launch: "Launch"
        case .test: "Test"
        case .curl: "curl"
        }
    }
}
