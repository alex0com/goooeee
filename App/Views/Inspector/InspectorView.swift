import AppKit
import GoooeeeCore
import GoooeeeMCP
import SwiftUI

/// The right column: model, sampling, thinking, system prompt, tools and statistics.
///
/// Settings edit one layer at a time: this chat or the whole workspace. Values that aren't set
/// show what they inherit and where it comes from (connection, model profile or server).
struct InspectorView: View {
    var model: WorkspaceModel
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @AppStorage("goooeee.inspector.scope") private var scope: Scope = .chat

    enum Scope: String, CaseIterable, Identifiable {
        case chat
        case workspace

        var id: String { rawValue }
        var label: String { self == .chat ? "This Chat" : "Workspace" }
    }

    private var conversation: Conversation? {
        model.selectedConversationID.flatMap { model.conversation($0) }
    }

    /// Chat scope falls back to workspace scope when no chat is selected.
    private var effectiveScope: Scope { conversation == nil ? .workspace : scope }

    private var effective: EffectiveSettings? {
        try? model.effectiveSettings(for: effectiveScope == .chat ? conversation : nil)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ModelSection(model: model)
                Divider()
                scopePicker
                samplingSection
                thinkingSection
                systemPromptSection
                Divider()
                ToolsSection(model: model, conversation: effectiveScope == .chat ? conversation : nil)
                Divider()
                if let controller = model.selectedController {
                    StatsSection(controller: controller, model: model)
                    Divider()
                }
                WorkspaceSection(model: model)
            }
            .padding(16)
        }
        .scrollIndicators(.automatic)
    }

    // MARK: Scope

    private var scopePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Applies to", selection: $scope) {
                ForEach(Scope.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(conversation == nil)
            Text(effectiveScope == .chat
                 ? "Changes apply to this chat only."
                 : "Changes apply to every chat in this workspace that doesn't set its own.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The overrides of the layer being edited.
    private var overrides: Binding<SettingsOverrides> {
        Binding(
            get: {
                effectiveScope == .chat ? (conversation?.overrides ?? SettingsOverrides()) : model.workspace.overrides
            },
            set: { newValue in
                if effectiveScope == .chat, var conversation {
                    conversation.overrides = newValue
                    model.save(conversation)
                } else {
                    model.updateWorkspace { $0.overrides = newValue }
                }
            }
        )
    }

    // MARK: Sampling

    private var samplingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Sampling").sectionHeader()
                Spacer()
                Text(model.profile.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Model profile used for recommended values")
            }
            SamplingEditor(
                values: overrides.sampling,
                effective: effective,
                supportedKeys: model.connection.engine.capabilities.samplingKeys
            )
        }
    }

    // MARK: Thinking

    private var thinkingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Thinking").sectionHeader()
            HStack {
                ThinkingPicker(level: overrides.thinking, inherited: inheritedThinking)
                Spacer()
                if let source = effective?.thinkingSource {
                    SourceBadge(source: source)
                }
            }
            if model.canStopReasoning {
                Text("While the model thinks, Stop Thinking in the chat ends the reasoning and moves on to the answer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// What applies to this layer when it doesn't set a level.
    private var inheritedThinking: ThinkingLevel {
        if effectiveScope == .chat, let level = model.workspace.overrides.thinking, level != .default { return level }
        return model.connection.thinking.level
    }

    // MARK: System prompt

    private var systemPromptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("System Prompt").sectionHeader()
                Spacer()
                if overrides.wrappedValue.systemPrompt != nil {
                    Button("Inherit") { overrides.wrappedValue.systemPrompt = nil }
                        .controlSize(.small)
                        .help("Use the system prompt from \(effectiveScope == .chat ? "the workspace or connection" : "the connection")")
                } else if let source = effective?.systemPromptSource {
                    SourceBadge(source: source)
                }
            }
            SystemPromptEditor(
                text: overrides.systemPrompt,
                inherited: inheritedSystemPrompt,
                font: app.settingsStore.nsFont(for: .input)
            )
        }
    }

    private var inheritedSystemPrompt: String? {
        if effectiveScope == .chat, let prompt = model.workspace.overrides.systemPrompt { return prompt }
        return model.connection.systemPrompt
    }
}

// MARK: - Model

private struct ModelSection: View {
    var model: WorkspaceModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Model").sectionHeader()
            Picker("Model", selection: Binding(
                get: { model.workspace.modelID ?? "" },
                set: { if !$0.isEmpty { model.setModel($0) } }
            )) {
                if model.workspace.modelID == nil { Text("Choose a model").tag("") }
                ForEach(modelIDs, id: \.self) { id in
                    Text(ModelNameFormatter.shortName(id)).tag(id)
                }
            }
            .labelsHidden()
            HStack(spacing: 6) {
                StatusDot(status: model.status)
                Text(model.status.label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { Task { await model.refreshStatus() } }
                    .controlSize(.small)
            }
            capabilityRow
            HStack {
                Text(model.connection.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Connection…") { openWindow(id: WindowID.connections) }
                    .controlSize(.small)
            }
        }
    }

    /// Server models plus the current one if the server doesn't list it.
    private var modelIDs: [String] {
        var ids = model.capabilities.models.map(\.id)
        if let current = model.workspace.modelID, !ids.contains(current) { ids.insert(current, at: 0) }
        return ids
    }

    private var capabilityRow: some View {
        HStack(spacing: 6) {
            badge("Vision", on: model.supportsVision)
            badge("Tools", on: model.supportsTools)
            if let context = model.contextLength {
                Text("\(MetricsFormatter.compactTokens(context)) ctx")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
        }
    }

    private func badge(_ title: String, on: Bool) -> some View {
        Label(title, systemImage: on ? "checkmark" : "xmark")
            .font(.caption2.weight(.medium))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(on ? Color.green.opacity(0.15) : Color.secondary.opacity(0.1), in: Capsule())
            .foregroundStyle(on ? .primary : .secondary)
    }
}

// MARK: - System prompt editor

/// `nil` = inherited (shown greyed); an empty string turns the system prompt off for this layer.
private struct SystemPromptEditor: View {
    @Binding var text: String?
    var inherited: String?
    var font: NSFont

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: Binding(
                get: { text ?? "" },
                set: { text = $0 }
            ))
            .font(Font(font))
            .scrollContentBackground(.hidden)
            .frame(minHeight: 70, maxHeight: 180)
            .padding(4)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
            if text == nil || text?.isEmpty == true {
                Text(placeholder)
                    .font(Font(font))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .lineLimit(4)
                    .allowsHitTesting(false)
            }
        }
    }

    private var placeholder: String {
        if text != nil { return "No system prompt" }
        if let inherited, !inherited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return inherited }
        return "No system prompt"
    }
}

// MARK: - Tools

private struct ToolsSection: View {
    var model: WorkspaceModel
    /// `nil` edits the workspace's tools.
    var conversation: Conversation?
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var showTools = false

    private var selection: ToolSelection { model.toolSelection(for: conversation) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tools").sectionHeader()
                Spacer()
                Button("MCP Servers…") { openWindow(id: WindowID.mcpServers) }
                    .controlSize(.small)
            }
            if !model.supportsTools {
                Text("This connection is set to not use tools.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                if model.capabilities.serverToolsAvailable {
                    Toggle("Server tools (llama.cpp)", isOn: binding(\.serverToolsEnabled))
                        .help("Tools built into llama-server (--tools); they run in the workspace folder.")
                }
                if app.mcpServers.isEmpty {
                    Text("Add MCP servers to give the model tools.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(app.mcpServers) { server in
                    serverToggle(server)
                }
                if conversation?.tools != nil {
                    Button("Use Workspace Tools") {
                        guard var conversation else { return }
                        conversation.tools = nil
                        model.save(conversation)
                    }
                    .controlSize(.small)
                }
                if !model.availableTools.isEmpty {
                    DisclosureGroup("Individual tools (\(model.availableTools.count))", isExpanded: $showTools) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(model.availableTools) { tool in
                                Toggle(isOn: toolBinding(tool)) {
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(tool.title ?? tool.originalName).lineLimit(1)
                                        Text(tool.sourceName).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                .help(tool.description ?? "")
                            }
                        }
                        .padding(.top, 4)
                    }
                    .font(.callout)
                }
                GrantsList(model: model)
            }
        }
        .task(id: selection) { await model.refreshAvailableTools() }
    }

    private func serverToggle(_ server: MCPServerConfig) -> some View {
        let state = app.mcpStates[server.id]
        return HStack(spacing: 6) {
            Circle()
                .fill(color(for: state?.phase))
                .frame(width: 7, height: 7)
            Toggle(isOn: Binding(
                get: { selection.mcpServerIDs.contains(server.id) },
                set: { on in update { if on { $0.mcpServerIDs.insert(server.id) } else { $0.mcpServerIDs.remove(server.id) } } }
            )) {
                HStack {
                    Text(server.name).lineLimit(1)
                    Spacer()
                    if let state, state.isConnected {
                        Text("\(state.tools.count)").font(.caption).foregroundStyle(.secondary)
                    } else if let state, state.phase == .failed {
                        Text("failed").font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .disabled(!server.isEnabled)
        }
        .help(state?.error ?? state?.phase.label ?? "")
    }

    private func color(for phase: MCPConnectionPhase?) -> Color {
        switch phase {
        case .connected: .green
        case .failed: .red
        case .some(let phase) where phase.isBusy: .orange
        default: .gray
        }
    }

    private func binding(_ keyPath: WritableKeyPath<ToolSelection, Bool>) -> Binding<Bool> {
        Binding(get: { selection[keyPath: keyPath] }, set: { value in update { $0[keyPath: keyPath] = value } })
    }

    private func toolBinding(_ tool: ToolDefinition) -> Binding<Bool> {
        Binding(
            get: { !selection.disabledToolKeys.contains(tool.key) },
            set: { on in update { if on { $0.disabledToolKeys.remove(tool.key) } else { $0.disabledToolKeys.insert(tool.key) } } }
        )
    }

    private func update(_ change: (inout ToolSelection) -> Void) {
        var tools = selection
        change(&tools)
        if var conversation {
            conversation.tools = tools
            model.save(conversation)
        } else {
            model.updateWorkspace { $0.tools = tools }
        }
        Task { await app.mcpHost.ensureConnected(tools.mcpServerIDs) }
    }
}

/// "Always allow" decisions for this workspace.
private struct GrantsList: View {
    var model: WorkspaceModel

    var body: some View {
        if !model.grants.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Always allowed").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(model.grants) { grant in
                    HStack {
                        Image(systemName: grant.scope == .server ? "server.rack" : "wrench")
                            .foregroundStyle(.secondary)
                        Text(grant.label).lineLimit(1)
                        Spacer()
                        Button {
                            model.revokeGrant(grant)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Ask again before running")
                    }
                    .font(.callout)
                }
            }
            .padding(.top, 4)
        }
    }
}

// MARK: - Statistics

private struct StatsSection: View {
    var controller: ChatController
    var model: WorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This Chat").sectionHeader()
            contextMeter
            let averages = controller.averages
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                if let live = controller.liveMetrics, controller.isGenerating {
                    row("Now", live.generationSpeed.map { "\(MetricsFormatter.speed($0.value)) tok/s" } ?? "—")
                }
                row("Generation", averages.generation.map { "\(MetricsFormatter.speed($0)) tok/s avg" } ?? "—")
                row("Prompt", averages.prompt.map { "\(MetricsFormatter.speed($0)) tok/s avg" } ?? "—")
                row("Generated", "\(MetricsFormatter.tokens(averages.tokens)) tokens")
                row("Messages", "\(controller.pathMessageCount)")
            }
            .font(.callout)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }

    @ViewBuilder
    private var contextMeter: some View {
        let usage = controller.contextUsage
        if let total = usage.total, let fraction = usage.fraction {
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: min(1, fraction))
                    .tint(fraction > 0.9 ? Color.orange : Color.accentColor)
                Text("≈ \(MetricsFormatter.tokens(usage.used)) of \(MetricsFormatter.tokens(total)) context tokens")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if usage.used > 0 {
            Text("≈ \(MetricsFormatter.tokens(usage.used)) context tokens")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Workspace

private struct WorkspaceSection: View {
    var model: WorkspaceModel
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Workspace").sectionHeader()
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(saveName)
                .onAppear { name = model.workspace.name }
                .onChange(of: model.workspace.name) { _, newValue in name = newValue }
            HStack {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(directoryLabel)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .font(.callout)
                    .help("Working directory for the terminal, launch command, server tools and MCP roots")
                Spacer()
                Button("Choose…", action: chooseDirectory)
                    .controlSize(.small)
            }
        }
    }

    private var directoryLabel: String {
        guard let path = model.workspace.workingDirectory else { return "Home folder" }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    private func saveName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != model.workspace.name else { return }
        model.updateWorkspace { $0.name = trimmed }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = model.workspace.workingDirectory.map { URL(fileURLWithPath: $0) }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                model.updateWorkspace { $0.workingDirectory = url.path }
                model.terminal.setWorkingDirectory(url.path)
                await model.app.mcpHost.rootsChanged()
            }
        }
    }
}
