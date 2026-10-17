import AppKit
import GoooeeeCore
import GoooeeeMCP
import SwiftUI
import UniformTypeIdentifiers

/// The MCP Servers window: configured servers with their live state, an editor and what each server offers.
struct MCPServersView: View {
    @Environment(AppModel.self) private var app
    @State private var selection: UUID?
    /// A server being created; it's saved only when the user clicks Save.
    @State private var newServer: MCPServerConfig?
    @State private var pendingDelete: MCPServerConfig?
    @State private var notice: String?

    var body: some View {
        NavigationSplitView {
            sidebar
                .splitColumnSizing()
                .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 380)
        } detail: {
            detail
                .splitColumnSizing()
                .frame(minWidth: 560)
        }
        .onAppear {
            if selection == nil { selection = app.mcpServers.first?.id }
        }
        .onChange(of: selection) { _, value in
            if value != nil { newServer = nil }
        }
        .confirmationDialog(
            "Delete “\(pendingDelete?.name ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { server in
            Button("Delete", role: .destructive) { delete(server) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The server is removed from every workspace, with its secrets in the Keychain.")
        }
        .alert("MCP Servers", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            ForEach(app.mcpServers) { server in
                MCPServerListRow(server: server, state: app.mcpStates[server.id], isEnabled: enabledBinding(for: server))
                    .tag(server.id)
                    .contextMenu {
                        Button("Delete…", role: .destructive) { pendingDelete = server }
                    }
            }
        }
        .overlay {
            if app.mcpServers.isEmpty && newServer == nil {
                ContentUnavailableView {
                    Label("No MCP Servers", systemImage: "puzzlepiece.extension")
                } description: {
                    Text("MCP servers give the model tools, prompts and resources. Add one, or import an mcpServers JSON file from Claude Desktop, Cursor or llama-server.")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
        }
        .onDeleteCommand {
            if let server = selectedServer { pendingDelete = server }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 4) {
            Menu {
                Button("Command (stdio)…") { startNew(.stdio(command: "", args: [], env: [:], cwd: nil)) }
                Button("HTTP…") { startNew(.http(url: URL(string: "http://127.0.0.1:3000/mcp")!, headers: [:])) }
                Button("SSE (legacy)…") { startNew(.sse(url: URL(string: "http://127.0.0.1:3000/sse")!, headers: [:])) }
            } label: {
                Image(systemName: "plus").frame(width: 20, height: 18)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add a server")
            Button {
                if let server = selectedServer { pendingDelete = server }
            } label: {
                Image(systemName: "minus").frame(width: 20, height: 18)
            }
            .buttonStyle(.borderless)
            .disabled(selectedServer == nil)
            .help("Delete the selected server")
            Spacer()
            Menu {
                Button("Import mcpServers JSON…") { importServers() }
                Button("Export…") { exportServers() }
                    .disabled(app.mcpServers.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle").frame(width: 20, height: 18)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Import or export")
        }
        .padding(8)
        .background(.bar)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let newServer {
            MCPServerEditor(original: newServer, isNew: true, onSaved: { saved in
                self.newServer = nil
                selection = saved.id
            }, onCancel: {
                self.newServer = nil
                selection = app.mcpServers.first?.id
            })
            .id(newServer.id)
            .navigationTitle("New MCP Server")
        } else if let server = selectedServer {
            MCPServerDetail(server: server, state: app.mcpStates[server.id])
                .id(server.id)
        } else {
            ContentUnavailableView("No Server Selected", systemImage: "puzzlepiece.extension")
        }
    }

    private var selectedServer: MCPServerConfig? {
        selection.flatMap { id in app.mcpServers.first { $0.id == id } }
    }

    private func enabledBinding(for server: MCPServerConfig) -> Binding<Bool> {
        Binding(
            get: { server.isEnabled },
            set: { value in
                var updated = server
                updated.isEnabled = value
                Task {
                    if !value { await app.mcpHost.disconnect(server.id) }
                    await app.saveMCPServer(updated)
                }
            }
        )
    }

    // MARK: Actions

    private func startNew(_ transport: MCPTransportConfig) {
        selection = nil
        newServer = MCPServerConfig(name: "", transport: transport)
    }

    private func delete(_ server: MCPServerConfig) {
        Task {
            await app.mcpHost.disconnect(server.id)
            await app.deleteMCPServer(server)
            if selection == server.id { selection = app.mcpServers.first?.id }
        }
    }

    private func importServers() {
        guard let url = EditorPanels.chooseFile(types: [.json], message: "Choose a JSON file with an \"mcpServers\" object") else { return }
        Task {
            do {
                let data = try Data(contentsOf: url)
                let before = Set(app.mcpServers.map(\.id))
                let count = try await app.importMCPServers(from: data)
                let added = app.mcpServers.filter { !before.contains($0.id) }
                let skipped = count - added.count
                var text = "Imported \(added.count) server\(added.count == 1 ? "" : "s")."
                if skipped > 0 { text += " \(skipped) with names that already exist were skipped." }
                if added.contains(where: { !$0.secretKeys.isEmpty || hasCredentialLikeValues($0) }) {
                    text += " Check the imported servers for tokens and move them to Secrets."
                }
                notice = text
                if let first = added.first { selection = first.id }
            } catch {
                notice = "Couldn't import: \(error.localizedDescription)"
            }
        }
    }

    private func hasCredentialLikeValues(_ server: MCPServerConfig) -> Bool {
        let names: [String]
        switch server.transport {
        case .stdio(_, _, let env, _): names = Array(env.keys)
        case .http(_, let headers), .sse(_, let headers): names = Array(headers.keys)
        }
        return names.contains { name in
            let lower = name.lowercased()
            return ["key", "token", "secret", "password", "authorization"].contains { lower.contains($0) }
        }
    }

    private func exportServers() {
        guard let url = EditorPanels.saveFile(named: "mcp-servers.json", type: .json) else { return }
        do {
            try MCPServersJSON.export(app.mcpServers).write(to: url, options: .atomic)
            notice = "Exported \(app.mcpServers.count) server\(app.mcpServers.count == 1 ? "" : "s"). Secret values were left out."
        } catch {
            notice = "Couldn't export: \(error.localizedDescription)"
        }
    }
}

/// A server in the sidebar: name, transport, connection phase and the enable switch.
private struct MCPServerListRow: View {
    var server: MCPServerConfig
    var state: MCPServerState?
    @Binding var isEnabled: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(mcpPhaseColor(state?.phase, enabled: server.isEnabled))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name).lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(state?.error != nil ? Color.red : .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Toggle("Enabled", isOn: $isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        if !server.isEnabled { return "Disabled · \(server.transport.kindLabel)" }
        if let error = state?.error, state?.phase == .failed { return error }
        if let state, state.isConnected { return "\(state.tools.count) tool\(state.tools.count == 1 ? "" : "s") · \(server.transport.kindLabel)" }
        return "\(state?.phase.label ?? MCPConnectionPhase.idle.label) · \(server.transport.kindLabel)"
    }
}

/// Status color for a server's connection phase.
func mcpPhaseColor(_ phase: MCPConnectionPhase?, enabled: Bool) -> Color {
    guard enabled else { return .gray.opacity(0.5) }
    switch phase ?? .idle {
    case .connected: return .green
    case .failed: return .red
    case .starting, .initializing, .listing, .reconnecting: return .orange
    case .idle, .disconnected: return .gray
    }
}
