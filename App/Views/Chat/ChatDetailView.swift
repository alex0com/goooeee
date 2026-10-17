import AppKit
import GoooeeeCore
import SwiftUI

/// The middle column: the selected chat (transcript + composer) and the terminal drawer.
struct ChatDetailView: View {
    var model: WorkspaceModel

    var body: some View {
        if model.workspace.showTerminal {
            VSplitView {
                chat
                    .splitColumnSizing()
                    .frame(minHeight: 240)
                    .layoutPriority(1)
                TerminalDrawer(model: model)
                    .splitColumnSizing()
                    .frame(minHeight: 120, idealHeight: 260)
            }
        } else {
            chat
        }
    }

    @ViewBuilder
    private var chat: some View {
        if let controller = model.selectedController {
            ChatPane(controller: controller, model: model)
        } else {
            NoChatView(model: model)
        }
    }
}

/// Transcript, banners and composer for one conversation.
struct ChatPane: View {
    var controller: ChatController
    var model: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                TranscriptView(controller: controller, workspace: model)
                if controller.isLoaded && controller.pathMessageCount == 0 {
                    EmptyChatView(model: model, controller: controller)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let pending = model.pendingContinue, pending.conversationID == controller.id {
                ContinueBanner(turns: pending.turns) { model.resolveContinue($0) }
            }
            if let error = controller.lastError, !controller.isGenerating {
                ErrorBanner(error: error, controller: controller, model: model)
            }
            ComposerView(controller: controller, model: model)
                .id(controller.id)
        }
    }
}

/// Shown when the workspace has no chat selected.
struct NoChatView: View {
    var model: WorkspaceModel

    var body: some View {
        ContentUnavailableView {
            Label("No chat selected", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("Pick a chat on the left or start a new one.")
        } actions: {
            Button("New Chat") { model.newConversation() }
                .keyboardShortcut("n")
                .buttonStyle(.borderedProminent)
        }
    }
}

/// An empty conversation: the model, what it can do, and the server state.
struct EmptyChatView: View {
    var model: WorkspaceModel
    var controller: ChatController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 14) {
            Text(model.workspace.modelID.map(ModelNameFormatter.shortName) ?? "No model selected")
                .font(.title.weight(.semibold))
            HStack(spacing: 8) {
                StatusDot(status: model.status)
                Text("\(model.connection.engine.displayName) · \(model.connection.hostDescription)")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                if model.supportsVision { capability("Vision", "photo") }
                if model.supportsTools && !model.toolSelection(for: model.conversation(controller.id)).isEmpty { capability("Tools", "wrench.and.screwdriver") }
                if model.profile.reasoning != .none { capability("Thinking", "brain") }
                if let context = model.contextLength { capability("\(MetricsFormatter.compactTokens(context)) context", "text.alignleft") }
            }
            serverHint
        }
        .padding(32)
        .frame(maxWidth: 520)
        .allowsHitTesting(true)
    }

    private func capability(_ title: String, _ icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: Capsule())
    }

    @ViewBuilder
    private var serverHint: some View {
        switch model.status {
        case .offline(let reason):
            VStack(spacing: 8) {
                Text("The server isn't answering.").foregroundStyle(.secondary)
                if !reason.isEmpty {
                    Text(reason).font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                }
                HStack {
                    if let launch = model.connection.launch, !launch.command.isEmpty {
                        Button("Start Server") { model.startServer() }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("Connection Settings…") { openWindow(id: WindowID.connections) }
                }
            }
            .padding(.top, 8)
        case .starting, .loadingModel:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.status.label).foregroundStyle(.secondary)
            }
        default:
            EmptyView()
        }
    }
}

/// The agentic loop hit its turn limit.
struct ContinueBanner: View {
    var turns: Int
    var answer: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
            Text("The model used \(turns) tool turns. Keep going?")
            Spacer()
            Button("Stop") { answer(false) }
            Button("Continue") { answer(true) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.08))
        .overlay(alignment: .top) { Divider() }
    }
}

/// A request failed before any message was created (connection refused, bad settings…).
struct ErrorBanner: View {
    var error: InferenceError
    var controller: ChatController
    var model: WorkspaceModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Errors on a message are shown in the transcript; this covers the rest.
        if controller.path.last?.role != .assistant || controller.path.last?.state == .complete {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(error.localizedDescription)
                        .textSelection(.enabled)
                    if let suggestion = error.recoverySuggestion {
                        Text(suggestion)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Retry") { controller.retry() }
                if case .offline = model.status, let launch = model.connection.launch, !launch.command.isEmpty {
                    Button("Start Server") { model.startServer() }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.red.opacity(0.06))
            .overlay(alignment: .top) { Divider() }
        }
    }
}
