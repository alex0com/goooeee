import AppKit
import GoooeeeCore
import SwiftTerm
import SwiftUI

/// The terminal panel at the bottom of a workspace window.
struct TerminalDrawer: View {
    var model: WorkspaceModel
    @Environment(AppModel.self) private var app

    private var terminal: TerminalSession { model.terminal }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            TerminalHostView(session: terminal)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if !terminal.isShellRunning, terminal.hasView {
                        exitedOverlay
                    }
                }
        }
        .frame(minHeight: 120)
        .onChange(of: app.settingsStore.revision) { _, _ in terminal.applyAppearance() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
            Text(terminal.title)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            if let directory = terminal.currentDirectory {
                Text((directory as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            if let launch = model.connection.launch, !launch.command.isEmpty {
                if terminal.hasRunningServer || terminal.isServerStarting {
                    Button {
                        model.stopServer()
                    } label: {
                        Label("Stop Server", systemImage: "stop.fill")
                    }
                    .help("Send Ctrl-C to the server")
                } else {
                    Button {
                        model.startServer()
                    } label: {
                        Label("Start Server", systemImage: "play.fill")
                    }
                    .help(launch.command)
                }
            }
            Menu {
                Button("Clear") { terminal.clear() }
                Button("Send Ctrl-C") { terminal.interrupt() }
                Button("Restart Shell") { terminal.restartShell() }
                Divider()
                Button("Copy Launch Command") {
                    NSPasteboard.copy(model.connection.launch?.command ?? "")
                }
                .disabled(model.connection.launch?.command.isEmpty ?? true)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            Button {
                model.updateWorkspace { $0.showTerminal = false }
            } label: {
                Image(systemName: "xmark")
            }
            .help("Hide Terminal (⌘`)")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private var exitedOverlay: some View {
        VStack(spacing: 8) {
            Text(terminal.lastExitCode.map { "The shell exited (\($0))." } ?? "The shell exited.")
                .foregroundStyle(.secondary)
            Button("Restart Shell") { terminal.restartShell() }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Hosts the session's terminal view. The view outlives the drawer so output is kept while it's hidden.
struct TerminalHostView: NSViewRepresentable {
    var session: TerminalSession

    func makeNSView(context: Context) -> NSView {
        let container = TerminalContainerView()
        container.attach(session.view)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? TerminalContainerView)?.attach(session.view)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? TerminalContainerView)?.detach()
    }
}

final class TerminalContainerView: NSView {
    private weak var terminal: NSView?

    func attach(_ view: NSView) {
        guard terminal !== view else { return }
        view.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        terminal = view
        DispatchQueue.main.async { [weak view] in
            view?.window?.makeFirstResponder(view)
        }
    }

    func detach() {
        terminal?.removeFromSuperview()
        terminal = nil
    }

    override var isFlipped: Bool { true }
}
