import AppKit
import GoooeeeCore
import GoooeeeMCP
import SwiftUI

/// One configured server: connection controls, its settings, and what it offers once connected.
struct MCPServerDetail: View {
    var server: MCPServerConfig
    var state: MCPServerState?
    @Environment(AppModel.self) private var app
    @State private var tab: MCPDetailTab = .tools

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("Section", selection: $tab) {
                ForEach(MCPDetailTab.allCases) { tab in
                    Text(title(for: tab)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .navigationTitle(server.name)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Circle()
                .fill(mcpPhaseColor(state?.phase, enabled: server.isEnabled))
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(phaseText).font(.headline)
                Text(server.transport.summary)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if let error = state?.error, state?.phase == .failed {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            connectionButtons
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var phaseText: String {
        guard server.isEnabled else { return "Disabled" }
        guard let state else { return MCPConnectionPhase.idle.label }
        if state.isConnected, let ms = state.connectTimeMs {
            return "Connected in \(MetricsFormatter.duration(ms: ms))"
        }
        return state.phase.label
    }

    @ViewBuilder
    private var connectionButtons: some View {
        let phase = state?.phase ?? .idle
        if !server.isEnabled {
            Text("Enable the server to connect.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if phase == .connected {
            Button("Reconnect") { reconnect() }
            Button("Disconnect") { Task { await app.mcpHost.disconnect(server.id) } }
        } else if phase.isBusy {
            ProgressView().controlSize(.small)
            Button("Stop") { Task { await app.mcpHost.disconnect(server.id) } }
        } else {
            Button("Connect") { Task { await app.mcpHost.connect(server.id) } }
                .buttonStyle(.borderedProminent)
        }
    }

    private func reconnect() {
        let id = server.id
        Task {
            await app.mcpHost.disconnect(id)
            await app.mcpHost.connect(id)
        }
    }

    private func title(for tab: MCPDetailTab) -> String {
        switch tab {
        case .tools: "Tools" + count(state?.tools.count)
        case .prompts: "Prompts" + count(state?.prompts.count)
        case .resources: "Resources" + count(state.map { $0.resources.count + $0.resourceTemplates.count })
        case .settings: "Settings"
        case .logs: "Logs"
        case .info: "Info"
        }
    }

    private func count(_ value: Int?) -> String {
        guard let value, value > 0 else { return "" }
        return " (\(value))"
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .settings:
            MCPServerEditor(original: server, isNew: false, onSaved: { _ in }, onCancel: nil)
        case .tools:
            connectedContent { MCPToolsList(tools: $0.tools) }
        case .prompts:
            connectedContent { MCPPromptsList(prompts: $0.prompts) }
        case .resources:
            connectedContent { MCPResourcesList(resources: $0.resources, templates: $0.resourceTemplates) }
        case .logs:
            MCPLogsView(logs: state?.logs ?? [])
        case .info:
            MCPServerInfoView(server: server, state: state)
        }
    }

    @ViewBuilder
    private func connectedContent<Content: View>(@ViewBuilder _ content: (MCPServerState) -> Content) -> some View {
        if let state, state.isConnected {
            content(state)
        } else {
            ContentUnavailableView {
                Label(state?.phase.isBusy == true ? "Connecting…" : "Not Connected", systemImage: "bolt.horizontal.circle")
            } description: {
                Text("Connect to see what this server offers. Workspaces connect to their enabled servers on demand.")
            } actions: {
                if server.isEnabled, state?.phase.isBusy != true {
                    Button("Connect") { Task { await app.mcpHost.connect(server.id) } }
                }
            }
        }
    }
}

enum MCPDetailTab: String, CaseIterable, Identifiable {
    case tools, prompts, resources, settings, logs, info
    var id: String { rawValue }
}

// MARK: - Editor

/// Edits a server's name, transport, secrets and timeout. New servers are saved on the first Save.
struct MCPServerEditor: View {
    let original: MCPServerConfig
    var isNew: Bool
    var onSaved: @MainActor (MCPServerConfig) -> Void
    var onCancel: (@MainActor () -> Void)?
    @Environment(AppModel.self) private var app

    @State private var name: String
    @State private var kind: MCPTransportKind
    @State private var command: String
    @State private var argsText: String
    @State private var env: [String: String]
    @State private var cwd: String
    @State private var urlText: String
    @State private var headers: [String: String]
    @State private var toolTimeout: Double?
    /// Secret values typed in this session, written to the Keychain on Save.
    @State private var newSecrets: [String: String] = [:]
    @State private var removedSecrets: Set<String> = []
    @State private var secretName = ""
    @State private var secretValue = ""
    @State private var formRevision = 0
    @State private var problem: String?
    @State private var isSaving = false

    init(original: MCPServerConfig, isNew: Bool, onSaved: @escaping @MainActor (MCPServerConfig) -> Void, onCancel: (@MainActor () -> Void)?) {
        self.original = original
        self.isNew = isNew
        self.onSaved = onSaved
        self.onCancel = onCancel
        let fields = MCPTransportFields(original.transport)
        _name = State(initialValue: original.name)
        _kind = State(initialValue: fields.kind)
        _command = State(initialValue: fields.command)
        _argsText = State(initialValue: fields.args.joined(separator: "\n"))
        _env = State(initialValue: fields.env)
        _cwd = State(initialValue: fields.cwd)
        _urlText = State(initialValue: fields.url)
        _headers = State(initialValue: fields.headers)
        _toolTimeout = State(initialValue: original.toolTimeoutSeconds)
    }

    var body: some View {
        Form {
            generalSection
            if kind == .stdio {
                stdioSections
            } else {
                httpSections
            }
            secretsSection
            limitsSection
            actionsSection
        }
        .formStyle(.grouped)
    }

    private var generalSection: some View {
        Section {
            TextField("Name", text: $name, prompt: Text("e.g. filesystem"))
            Picker("Transport", selection: $kind) {
                Text("Command (stdio)").tag(MCPTransportKind.stdio)
                Text("Streamable HTTP").tag(MCPTransportKind.http)
                Text("SSE (legacy)").tag(MCPTransportKind.sse)
            }
        } footer: {
            Text(kind == .stdio
                ? "goooeee starts the command and talks to it over stdin and stdout, using your login shell's PATH."
                : "goooeee connects to a running server at this address.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var stdioSections: some View {
        Section("Command") {
            TextField("Command", text: $command, prompt: Text("npx"))
                .font(.system(.body, design: .monospaced))
            VStack(alignment: .leading, spacing: 4) {
                Text("Arguments, one per line").font(.callout).foregroundStyle(.secondary)
                CodeTextEditor(text: $argsText, minHeight: 70)
            }
            HStack {
                TextField("Working directory", text: $cwd, prompt: Text("Default"))
                Button("Choose…") {
                    if let path = EditorPanels.chooseDirectory(startingAt: cwd) { cwd = path }
                }
            }
        }
        Section {
            KeyValueListEditor(pairs: $env, keyPlaceholder: "VARIABLE", valuePlaceholder: "value", addTitle: "Add Variable")
                .id(formRevision)
        } header: {
            Text("Environment")
        } footer: {
            Text("Put tokens and keys in Secrets below instead; they're kept in the Keychain and left out of exports.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var httpSections: some View {
        Section("Address") {
            TextField("URL", text: $urlText, prompt: Text(kind == .sse ? "http://127.0.0.1:3000/sse" : "http://127.0.0.1:3000/mcp"))
                .font(.system(.body, design: .monospaced))
        }
        Section {
            KeyValueListEditor(pairs: $headers, keyPlaceholder: "Header", valuePlaceholder: "Value", addTitle: "Add Header")
                .id(formRevision)
        } header: {
            Text("Headers")
        } footer: {
            Text("For an Authorization header, add it under Secrets so the token stays in the Keychain.")
                .foregroundStyle(.secondary)
        }
    }

    private var secretKeys: [String] {
        let stored = original.secretKeys.subtracting(removedSecrets)
        return Array(stored.union(newSecrets.keys)).sorted()
    }

    private var secretsSection: some View {
        Section {
            ForEach(secretKeys, id: \.self) { key in
                HStack {
                    Text(key).font(.system(.body, design: .monospaced))
                    Spacer()
                    Text(newSecrets[key] != nil ? "will be saved" : "in Keychain")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        newSecrets[key] = nil
                        if original.secretKeys.contains(key) { removedSecrets.insert(key) }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this secret")
                }
            }
            HStack {
                TextField("Name", text: $secretName, prompt: Text(kind == .stdio ? "API_TOKEN" : "Authorization"))
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: 200)
                SecureField("Value", text: $secretValue, prompt: Text(kind == .stdio ? "value" : "Bearer …"))
                Button("Add") { addSecret() }
                    .disabled(secretName.trimmingCharacters(in: .whitespaces).isEmpty || secretValue.isEmpty)
            }
        } header: {
            Text("Secrets")
        } footer: {
            Text(kind == .stdio
                ? "Passed to the command as environment variables. Values are never shown again."
                : "Sent as HTTP headers. Values are never shown again.")
                .foregroundStyle(.secondary)
        }
    }

    private var limitsSection: some View {
        Section {
            LabeledContent("Tool call timeout") {
                HStack(spacing: 6) {
                    TextField("", value: $toolTimeout, format: .number.precision(.fractionLength(0)), prompt: Text("Default"))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .labelsHidden()
                    Text("seconds").foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("Empty uses the timeout from Settings → Tools & MCP.")
                .foregroundStyle(.secondary)
        }
    }

    private var actionsSection: some View {
        Section {
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            HStack {
                if let onCancel {
                    Button("Cancel", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("Revert") { revert() }
                        .disabled(!hasChanges || isSaving)
                }
                Spacer()
                Button(isNew ? "Add Server" : "Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled((!hasChanges && !isNew) || isSaving)
            }
        }
    }

    // MARK: Model

    private var argsList: [String] {
        argsText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The transport as edited, or `nil` when the URL is invalid.
    private var editedTransport: MCPTransportConfig? {
        switch kind {
        case .stdio:
            let trimmedCwd = cwd.trimmingCharacters(in: .whitespaces)
            return .stdio(command: command.trimmingCharacters(in: .whitespaces), args: argsList, env: env, cwd: trimmedCwd.isEmpty ? nil : trimmedCwd)
        case .http, .sse:
            guard let url = URL(string: urlText.trimmingCharacters(in: .whitespaces)),
                let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()), url.host != nil
            else { return nil }
            return kind == .sse ? .sse(url: url, headers: headers) : .http(url: url, headers: headers)
        }
    }

    private var edited: MCPServerConfig {
        var config = original
        config.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let transport = editedTransport { config.transport = transport }
        config.toolTimeoutSeconds = toolTimeout.flatMap { $0 > 0 ? $0 : nil }
        config.secretKeys = original.secretKeys.subtracting(removedSecrets)
        return config
    }

    private var hasChanges: Bool {
        edited != original || !newSecrets.isEmpty || !removedSecrets.isEmpty || (editedTransport == nil)
    }

    private func addSecret() {
        let key = secretName.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !secretValue.isEmpty else { return }
        newSecrets[key] = secretValue
        removedSecrets.remove(key)
        secretName = ""
        secretValue = ""
    }

    private func revert() {
        let fields = MCPTransportFields(original.transport)
        name = original.name
        kind = fields.kind
        command = fields.command
        argsText = fields.args.joined(separator: "\n")
        env = fields.env
        cwd = fields.cwd
        urlText = fields.url
        headers = fields.headers
        toolTimeout = original.toolTimeoutSeconds
        newSecrets = [:]
        removedSecrets = []
        problem = nil
        formRevision += 1
    }

    private func validate() -> String? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty { return "Give the server a name." }
        if app.mcpServers.contains(where: { $0.name == trimmedName && $0.id != original.id }) {
            return "Another server is already called “\(trimmedName)”."
        }
        switch kind {
        case .stdio:
            if command.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter the command that starts the server." }
        case .http, .sse:
            if editedTransport == nil { return "Enter an http:// or https:// URL." }
        }
        return nil
    }

    private func save() {
        if let message = validate() {
            problem = message
            return
        }
        problem = nil
        isSaving = true
        let config = edited
        let secrets = newSecrets
        let removed = removedSecrets
        Task {
            for key in removed {
                try? app.secrets.setSecret(nil, for: config.secretRef(for: key))
            }
            await app.saveMCPServer(config, secrets: secrets)
            // Reconnect so the new settings take effect.
            if !isNew, app.mcpStates[config.id]?.phase == .connected {
                await app.mcpHost.disconnect(config.id)
                await app.mcpHost.connect(config.id)
            }
            newSecrets = [:]
            removedSecrets = []
            isSaving = false
            onSaved(app.mcpServers.first { $0.id == config.id } ?? config)
        }
    }
}

enum MCPTransportKind: Hashable {
    case stdio, http, sse
}

/// Flattened transport fields for the editor.
private struct MCPTransportFields {
    var kind: MCPTransportKind = .stdio
    var command = ""
    var args: [String] = []
    var env: [String: String] = [:]
    var cwd = ""
    var url = ""
    var headers: [String: String] = [:]

    init(_ transport: MCPTransportConfig) {
        switch transport {
        case .stdio(let command, let args, let env, let cwd):
            kind = .stdio
            self.command = command
            self.args = args
            self.env = env
            self.cwd = cwd ?? ""
        case .http(let url, let headers):
            kind = .http
            self.url = url.absoluteString
            self.headers = headers
        case .sse(let url, let headers):
            kind = .sse
            self.url = url.absoluteString
            self.headers = headers
        }
    }
}

// MARK: - Tools, prompts, resources

private struct MCPToolsList: View {
    var tools: [ToolDefinition]

    var body: some View {
        if tools.isEmpty {
            ContentUnavailableView("No Tools", systemImage: "wrench.and.screwdriver", description: Text("This server doesn't offer tools."))
        } else {
            List(tools) { tool in
                MCPToolRow(tool: tool)
            }
        }
    }
}

private struct MCPToolRow: View {
    var tool: ToolDefinition
    @State private var showSchema = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(tool.originalName)
                    .font(.system(.body, design: .monospaced).weight(.medium))
                if let title = tool.title, title != tool.originalName {
                    Text(title).foregroundStyle(.secondary)
                }
                Spacer()
                if tool.readOnlyHint == true { hintBadge("read-only", color: .green) }
                if tool.destructiveHint == true { hintBadge("destructive", color: .red) }
            }
            if let description = tool.description, !description.isEmpty {
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            DisclosureGroup("Input schema", isExpanded: $showSchema) {
                MonospacedBlock(text: tool.parameters.encodedString(pretty: true), maxHeight: 220)
            }
            .font(.callout)
        }
        .padding(.vertical, 4)
    }

    private func hintBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

private struct MCPPromptsList: View {
    var prompts: [MCPPromptInfo]

    var body: some View {
        if prompts.isEmpty {
            ContentUnavailableView("No Prompts", systemImage: "text.bubble", description: Text("This server doesn't offer prompts. Prompts it offers appear in the composer when you type /."))
        } else {
            List(prompts) { prompt in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("/" + prompt.name).font(.system(.body, design: .monospaced).weight(.medium))
                        if prompt.displayName != prompt.name {
                            Text(prompt.displayName).foregroundStyle(.secondary)
                        }
                    }
                    if let description = prompt.description, !description.isEmpty {
                        Text(description).font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(prompt.arguments, id: \.name) { argument in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(argument.name + (argument.required ? "*" : ""))
                                .font(.system(.caption, design: .monospaced))
                            if let description = argument.description {
                                Text(description).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.leading, 12)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

private struct MCPResourcesList: View {
    var resources: [MCPResourceInfo]
    var templates: [MCPResourceTemplateInfo]

    var body: some View {
        if resources.isEmpty && templates.isEmpty {
            ContentUnavailableView("No Resources", systemImage: "shippingbox", description: Text("This server doesn't offer resources. Resources it offers can be attached in the composer by typing @."))
        } else {
            List {
                if !resources.isEmpty {
                    Section("Resources") {
                        ForEach(resources) { resource in
                            resourceRow(title: resource.displayName, uri: resource.uri, description: resource.description, detail: detail(for: resource))
                        }
                    }
                }
                if !templates.isEmpty {
                    Section("Templates") {
                        ForEach(templates) { template in
                            resourceRow(title: template.title ?? template.name, uri: template.uriTemplate, description: template.description, detail: template.mimeType)
                        }
                    }
                }
            }
        }
    }

    private func detail(for resource: MCPResourceInfo) -> String? {
        let parts = [resource.mimeType, resource.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func resourceRow(title: String, uri: String, description: String?, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).fontWeight(.medium)
                Spacer()
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(uri)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let description, !description.isEmpty {
                Text(description).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Logs and info

private struct MCPLogsView: View {
    var logs: [MCPLogEntry]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(logs.count) entries").font(.caption).foregroundStyle(.secondary)
                Spacer()
                CopyButton(text: { allText }, label: "Copy All", showsTitle: true)
                    .disabled(logs.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 6)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(logs) { entry in
                            line(entry).id(entry.id)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onAppear { if let last = logs.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                .onChange(of: logs.last?.id) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
    }

    private func line(_ entry: MCPLogEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.date.formatted(date: .omitted, time: .standard))
                .foregroundStyle(.tertiary)
            Text(entry.level.rawValue)
                .foregroundStyle(color(for: entry.level))
                .frame(width: 52, alignment: .leading)
            Text(entry.message)
                .textSelection(.enabled)
        }
        .font(.system(.caption, design: .monospaced))
    }

    private func color(for level: MCPLogEntry.Level) -> Color {
        switch level {
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        case .stderr: .purple
        case .server: .blue
        }
    }

    private var allText: String {
        logs.map { "\($0.date.formatted(date: .omitted, time: .standard)) [\($0.level.rawValue)] \($0.message)" }.joined(separator: "\n")
    }
}

private struct MCPServerInfoView: View {
    var server: MCPServerConfig
    var state: MCPServerState?

    var body: some View {
        Form {
            Section("Server") {
                LabeledContent("Name", value: state?.serverTitle ?? state?.serverName ?? "—")
                LabeledContent("Version", value: state?.serverVersion ?? "—")
                LabeledContent("Protocol", value: state?.protocolVersion ?? "—")
                LabeledContent("Capabilities", value: (state?.capabilities.isEmpty ?? true) ? "—" : state!.capabilities.joined(separator: ", "))
                if let ms = state?.connectTimeMs {
                    LabeledContent("Connect time", value: MetricsFormatter.duration(ms: ms))
                }
            }
            Section("Transport") {
                LabeledContent("Kind", value: server.transport.kindLabel)
                LabeledContent("Target") {
                    Text(server.transport.summary)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            if let instructions = state?.instructions, !instructions.isEmpty {
                Section("Instructions from the server") {
                    Text(instructions)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }
}
