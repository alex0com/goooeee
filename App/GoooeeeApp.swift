import AppKit
import GoooeeeCore
import SwiftUI

@main
struct GoooeeeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        // One window per workspace; the window's value is the workspace ID and is restored on relaunch.
        WindowGroup("goooeee", id: WindowID.workspace, for: UUID.self) { $workspaceID in
            WorkspaceWindow(workspaceID: $workspaceID)
                .environment(model)
                .preferredColorScheme(model.settingsStore.colorScheme)
        }
        .defaultSize(width: 1280, height: 820)
        .commands { AppCommands(model: model) }

        Window("Connections", id: WindowID.connections) {
            ConnectionsView()
                .environment(model)
                .preferredColorScheme(model.settingsStore.colorScheme)
        }
        .defaultSize(width: 1000, height: 700)

        Window("MCP Servers", id: WindowID.mcpServers) {
            MCPServersView()
                .environment(model)
                .preferredColorScheme(model.settingsStore.colorScheme)
        }
        .defaultSize(width: 1000, height: 700)

        Window("Workspaces", id: WindowID.workspaces) {
            WorkspacesListView()
                .environment(model)
                .preferredColorScheme(model.settingsStore.colorScheme)
        }
        .defaultSize(width: 640, height: 480)

        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(model.settingsStore.colorScheme)
        }
    }
}

enum WindowID {
    static let workspace = "workspace"
    static let connections = "connections"
    static let mcpServers = "mcp-servers"
    static let workspaces = "workspaces"
}

extension FocusedValues {
    @Entry var workspaceModel: WorkspaceModel?
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = AppModel.shared.openWorkspaceIDs.compactMap { AppModel.shared.workspaceModel(for: $0) }.filter(\.terminal.hasRunningServer)
        guard !running.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit and stop the servers started in goooeee?"
        alert.informativeText = running.map(\.workspace.name).joined(separator: ", ") + " still have a server running in their terminal."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}

struct AppCommands: Commands {
    let model: AppModel
    @FocusedValue(\.workspaceModel) private var workspace
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Chat") { workspace?.newConversation() }
                .keyboardShortcut("n")
                .disabled(workspace == nil)
            Button("New Workspace…") { openWindow(id: WindowID.workspace) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Search Chats…") { workspace?.isSearchPresented = true }
                .keyboardShortcut("k")
                .disabled(workspace == nil)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Delete Chat") {
                if let workspace, let id = workspace.selectedConversationID { workspace.delete([id]) }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(workspace?.selectedConversationID == nil)
        }

        CommandMenu("Chat") {
            Button("Stop") { workspace?.selectedController?.stop() }
                .keyboardShortcut(".")
                .disabled(workspace?.selectedController?.isGenerating != true)
            Button("Regenerate") {
                if let controller = workspace?.selectedController,
                    let last = controller.path.last(where: { $0.role == .assistant })
                {
                    controller.regenerate(last.id)
                }
            }
            .keyboardShortcut("r")
            Button("Edit Last Message") {
                NotificationCenter.default.post(name: .editLastMessage, object: workspace?.selectedConversationID)
            }
            .keyboardShortcut("e")
            Divider()
            Button("Previous Branch") { workspace?.selectedController?.switchLastBranch(offset: -1) }
                .keyboardShortcut("[")
            Button("Next Branch") { workspace?.selectedController?.switchLastBranch(offset: 1) }
                .keyboardShortcut("]")
            Divider()
            Button("Start Server") { workspace?.startServer() }
                .disabled(workspace?.connection.launch?.command.isEmpty ?? true)
            Button("Stop Server") { workspace?.stopServer() }
                .disabled(workspace?.terminal.hasRunningServer != true)
        }

        CommandGroup(after: .sidebar) {
            Button("Toggle Terminal") {
                workspace?.updateWorkspace { $0.showTerminal.toggle() }
            }
            .keyboardShortcut("`")
            Button("Toggle Inspector") {
                workspace?.updateWorkspace { $0.showInspector.toggle() }
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
            Button("Bigger Text") { model.settingsStore.increaseTextSize() }
                .keyboardShortcut("+")
            Button("Smaller Text") { model.settingsStore.decreaseTextSize() }
                .keyboardShortcut("-")
            Button("Actual Size") { model.settingsStore.resetTextSize() }
                .keyboardShortcut("0")
        }

        CommandGroup(before: .windowList) {
            Button("Workspaces") { openWindow(id: WindowID.workspaces) }
            Button("Connections") { openWindow(id: WindowID.connections) }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Button("MCP Servers") { openWindow(id: WindowID.mcpServers) }
                .keyboardShortcut("m", modifiers: [.command, .option])
            Divider()
        }
    }
}

extension Notification.Name {
    static let editLastMessage = Notification.Name("goooeee.editLastMessage")
    static let focusComposer = Notification.Name("goooeee.focusComposer")
}
