import AppKit
import GoooeeeCore
import SwiftUI

/// A workspace window: conversations on the left, the chat in the middle, settings on the right.
struct WorkspaceView: View {
    @Bindable var model: WorkspaceModel
    @Environment(AppModel.self) private var app
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ConversationSidebar(model: model)
                .splitColumnSizing()
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 420)
        } detail: {
            ChatDetailView(model: model)
                .splitColumnSizing()
        }
        .inspector(isPresented: inspectorBinding) {
            InspectorView(model: model)
                .splitColumnSizing()
                .inspectorColumnWidth(min: 270, ideal: 320, max: 520)
        }
        .toolbar { toolbarContent }
        .navigationTitle(model.workspace.name)
        .navigationSubtitle(subtitle)
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(toast: toast) { if model.toast?.id == toast.id { model.toast = nil } }
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: model.toast)
        .sheet(isPresented: $model.isSearchPresented) {
            SearchView(model: model)
        }
        .sheet(isPresented: $model.showRecentlyDeleted) {
            RecentlyDeletedView(model: model)
        }
        .frame(minWidth: 760, minHeight: 480)
    }

    private var inspectorBinding: Binding<Bool> {
        Binding(
            get: { model.workspace.showInspector },
            set: { value in model.updateWorkspace { $0.showInspector = value } }
        )
    }

    private var subtitle: String {
        var parts = ["\(model.connection.engine.displayName) \(model.connection.hostDescription)"]
        if let modelID = model.workspace.modelID { parts.append(ModelNameFormatter.shortName(modelID)) }
        return parts.joined(separator: " · ")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                model.newConversation()
            } label: {
                Label("New Chat", systemImage: "square.and.pencil")
            }
            .help("New Chat (⌘N)")
        }
        ToolbarItem(placement: .principal) {
            ModelPickerButton(model: model)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if let launch = model.connection.launch, !launch.command.isEmpty {
                if model.terminal.hasRunningServer || model.terminal.isServerStarting {
                    Button {
                        model.stopServer()
                    } label: {
                        Label("Stop Server", systemImage: "stop.circle")
                    }
                    .help("Stop the server running in the terminal")
                } else if !model.status.isOnline {
                    Button {
                        model.startServer()
                    } label: {
                        Label("Start Server", systemImage: "play.circle")
                    }
                    .help("Run the connection's launch command in the terminal")
                }
            }
            Button {
                model.updateWorkspace { $0.showTerminal.toggle() }
            } label: {
                Label("Terminal", systemImage: "terminal")
            }
            .help("Show or hide the terminal (⌘`)")
            Button {
                model.updateWorkspace { $0.showInspector.toggle() }
            } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .help("Show or hide settings (⌥⌘I)")
        }
    }
}

/// Status dot + model name; the menu switches models (and loads them on llama.cpp routers).
struct ModelPickerButton: View {
    var model: WorkspaceModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Menu {
            if model.capabilities.models.isEmpty {
                Text(model.status.isOnline ? "The server lists no models" : model.status.label)
            } else {
                Section("Models on \(model.connection.name)") {
                    ForEach(model.capabilities.models) { remote in
                        Button {
                            model.setModel(remote.id)
                        } label: {
                            HStack {
                                if remote.id == model.workspace.modelID { Image(systemName: "checkmark") }
                                Text(remote.displayName)
                                if let state = remote.loadState, state != .loaded, state != .unknown {
                                    Text(state.rawValue).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            Divider()
            Button("Refresh") { Task { await model.refreshStatus() } }
            Button("Connection Settings…") { openWindow(id: WindowID.connections) }
        } label: {
            HStack(spacing: 6) {
                StatusDot(status: model.status)
                Text(model.workspace.modelID.map(ModelNameFormatter.shortName) ?? "Choose a model")
                    .fontWeight(.medium)
                    .lineLimit(1)
                if case .offline = model.status {
                    Text("offline").foregroundStyle(.secondary)
                } else if model.status == .loadingModel || model.status == .starting {
                    Text(model.status.label).foregroundStyle(.secondary)
                }
            }
        }
        .menuIndicator(.visible)
        .fixedSize()
        .help(helpText)
    }

    private var helpText: String {
        var lines = ["\(model.connection.name) — \(model.connection.engine.displayName) at \(model.connection.hostDescription)", model.status.label]
        if case .offline(let reason) = model.status, !reason.isEmpty { lines.append(reason) }
        if let context = model.contextLength { lines.append("Context: \(MetricsFormatter.tokens(context)) tokens") }
        return lines.joined(separator: "\n")
    }
}
