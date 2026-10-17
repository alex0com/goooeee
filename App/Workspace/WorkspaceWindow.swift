import AppKit
import GoooeeeCore
import SwiftUI

/// Root view of a workspace window. With no workspace yet, it shows the workspace picker
/// (and, on first launch, server discovery).
struct WorkspaceWindow: View {
    @Binding var workspaceID: UUID?
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if !app.isLoaded {
                ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let id = workspaceID, let model = app.workspaceModel(for: id) {
                WorkspaceView(model: model)
                    .background(WindowAccessor { window in
                        model.window = window
                        window.tabbingMode = .preferred
                    })
                    .focusedSceneValue(\.workspaceModel, model)
                    .onAppear { model.start() }
                    .onDisappear { app.windowClosed(workspaceID: id) }
                    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
                        if (note.object as? NSWindow) === model.window { model.becameActive() }
                    }
            } else {
                WorkspacePickerView { workspace in
                    workspaceID = workspace.id
                }
                .frame(minWidth: 720, minHeight: 520)
            }
        }
    }
}

/// Gives access to the hosting `NSWindow`.
struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window { onWindow(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window { onWindow(window) }
    }
}

/// Choose an existing workspace or create a new one. On first launch it scans for local servers.
struct WorkspacePickerView: View {
    var onOpen: (Workspace) -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var creating = false

    var body: some View {
        VStack(spacing: 0) {
            if app.workspaces.isEmpty || creating {
                NewWorkspaceView(onCreated: onOpen, onCancel: app.workspaces.isEmpty ? nil : { creating = false })
            } else {
                existingWorkspaces
            }
        }
    }

    private var existingWorkspaces: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Open a workspace").font(.title2.weight(.semibold))
                    Text("Each window is a workspace for one server and one model, with its own chats.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("New Workspace…") { creating = true }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            List(app.workspaces.sorted { $0.updatedAt > $1.updatedAt }) { workspace in
                Button {
                    open(workspace)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "rectangle.stack")
                            .font(.title2)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(workspace.name).font(.headline)
                            let connection = app.connections.first { $0.id == workspace.connectionID }
                            Text([connection.map { "\($0.engine.displayName) \($0.hostDescription)" }, workspace.modelID.map(ModelNameFormatter.shortName)]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if app.openWorkspaceIDs.contains(workspace.id) {
                            Text("Open").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
            }
            .listStyle(.inset)
        }
        .padding(24)
    }

    private func open(_ workspace: Workspace) {
        if app.openWorkspaceIDs.contains(workspace.id), let window = app.workspaceModel(for: workspace.id)?.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.keyWindow?.close()
            return
        }
        onOpen(workspace)
    }
}

/// Create a workspace: pick a discovered server, a saved connection or enter a URL; then a model.
struct NewWorkspaceView: View {
    var onCreated: (Workspace) -> Void
    var onCancel: (() -> Void)?
    @Environment(AppModel.self) private var app
    @State private var discovered: [DiscoveredServer] = []
    @State private var scanning = false
    @State private var choice: Choice?
    @State private var manualURL = ""
    @State private var manualEngine: EngineKind = .genericOpenAI
    @State private var apiKey = ""
    @State private var models: [RemoteModel] = []
    @State private var selectedModel: String?
    @State private var loadingModels = false
    @State private var error: String?
    @State private var name = ""

    enum Choice: Hashable {
        case discovered(DiscoveredServer)
        case saved(UUID)
        case manual
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(app.workspaces.isEmpty ? "Connect to a server" : "New workspace").font(.title2.weight(.semibold))
                Text("goooeee talks to your inference server through its OpenAI-compatible API. Pick a server, then a model.")
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Found on this Mac").font(.headline)
                        Spacer()
                        if scanning { ProgressView().controlSize(.small) }
                        Button("Scan Again") { Task { await scan() } }.disabled(scanning)
                    }
                    if discovered.isEmpty && !scanning {
                        Text("No servers answered on the usual ports (8080, 8000, 1234, 11434). Start one, or enter its address below.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(discovered) { server in
                        choiceRow(.discovered(server), title: server.title, subtitle: server.subtitle, icon: "bolt.horizontal.circle")
                    }
                    if !app.connections.isEmpty {
                        Divider()
                        Text("Saved connections").font(.headline)
                        ForEach(app.connections) { connection in
                            choiceRow(.saved(connection.id), title: connection.name, subtitle: "\(connection.engine.displayName) · \(connection.hostDescription)", icon: "server.rack")
                        }
                    }
                    Divider()
                    choiceRow(.manual, title: "Another server…", subtitle: "Enter a URL, e.g. http://192.168.1.20:8080", icon: "network")
                    if choice == .manual {
                        HStack {
                            TextField("http://host:port", text: $manualURL)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { Task { await loadModels() } }
                            Picker("Engine", selection: $manualEngine) {
                                ForEach(EngineKind.allCases) { Text($0.displayName).tag($0) }
                            }
                            .frame(width: 220)
                        }
                        .padding(.leading, 34)
                        if manualEngine.requiresAPIKey {
                            SecureField("API key", text: $apiKey)
                                .textFieldStyle(.roundedBorder)
                                .padding(.leading, 34)
                        }
                    }
                }
                .padding(8)
            }

            if choice != nil {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Model").font(.headline)
                            Spacer()
                            if loadingModels { ProgressView().controlSize(.small) }
                            Button("Refresh") { Task { await loadModels() } }
                        }
                        if models.isEmpty {
                            Text(loadingModels ? "Asking the server for its models…" : "No models listed yet.")
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("Model", selection: $selectedModel) {
                                ForEach(models) { model in
                                    Text(model.id + (model.loadState == .loaded ? "  (loaded)" : "")).tag(Optional(model.id))
                                }
                            }
                            .labelsHidden()
                        }
                        TextField("Workspace name", text: $name, prompt: Text(defaultName))
                            .textFieldStyle(.roundedBorder)
                    }
                    .padding(8)
                }
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            Spacer(minLength: 0)
            HStack {
                if let onCancel { Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction) }
                Spacer()
                Button("Create Workspace") { Task { await create() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(choice == nil || (choice == .manual && manualURL.isEmpty))
            }
        }
        .padding(24)
        .task {
            if app.settings.localDiscoveryEnabled { await scan() }
        }
        .onChange(of: choice) { _, _ in
            models = []
            selectedModel = nil
            Task { await loadModels() }
        }
    }

    private func choiceRow(_ value: Choice, title: String, subtitle: String, icon: String) -> some View {
        Button {
            choice = value
        } label: {
            HStack(spacing: 12) {
                Image(systemName: choice == value ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(choice == value ? Color.accentColor : .secondary)
                Image(systemName: icon).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).fontWeight(.medium)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var defaultName: String {
        guard let connection = try? currentConnection() else { return "Workspace" }
        return Workspace.defaultName(connection: connection, modelID: selectedModel)
    }

    private func currentConnection() throws -> ServerConnection {
        switch choice {
        case .discovered(let server): return server.makeConnection()
        case .saved(let id):
            guard let connection = app.connections.first(where: { $0.id == id }) else { throw InferenceError.invalidRequest("Connection not found") }
            return connection
        case .manual:
            guard let normalized = URLBuilder.normalize(manualURL) else { throw InferenceError.invalidRequest("Enter a valid URL") }
            var connection = ServerConnection.preset(manualEngine, name: "\(manualEngine.displayName) \(normalized.base.host ?? "")", baseURL: normalized.base)
            connection.apiPrefix = normalized.prefix
            return connection
        case nil:
            throw InferenceError.invalidRequest("Choose a server")
        }
    }

    private func scan() async {
        scanning = true
        discovered = await LocalDiscovery.scan()
        scanning = false
        if choice == nil, let first = discovered.first { choice = .discovered(first) }
    }

    private func loadModels() async {
        guard let connection = try? currentConnection() else { return }
        loadingModels = true
        error = nil
        defer { loadingModels = false }
        let key = apiKey.isEmpty ? app.apiKey(for: connection) : apiKey
        do {
            models = try await ProviderFactory.make(connection: connection, apiKey: key).listModels()
            selectedModel = connection.defaultModelID.flatMap { id in models.first { $0.id == id }?.id }
                ?? models.first(where: { $0.loadState == .loaded })?.id ?? models.first?.id
        } catch {
            models = []
            let mapped = InferenceError.from(error)
            self.error = [mapped.localizedDescription, mapped.recoverySuggestion].compactMap { $0 }.joined(separator: " ")
        }
    }

    private func create() async {
        do {
            var connection = try currentConnection()
            if case .saved = choice {} else {
                connection.defaultModelID = selectedModel
                connection = await app.saveConnection(connection, apiKey: apiKey.isEmpty ? nil : apiKey)
            }
            let workspace = await app.createWorkspace(connection: connection, modelID: selectedModel, name: name.isEmpty ? nil : name)
            onCreated(workspace)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
