import AppKit
import GoooeeeCore
import GoooeeeMCP
import SwiftUI
import UniformTypeIdentifiers

/// The message box: text, attachments, MCP prompts/resources, tools and thinking for this chat.
struct ComposerView: View {
    @Bindable var controller: ChatController
    var model: WorkspaceModel
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    @State private var textHeight: CGFloat = 24
    @State private var trigger: CompletionTrigger?
    @State private var highlightedIndex = 0
    @State private var prompts: [MCPPromptInfo] = []
    @State private var resources: [MCPResourceInfo] = []
    @State private var templates: [MCPResourceTemplateInfo] = []
    @State private var argumentRequest: ArgumentRequest?
    @State private var focusToken = 0
    @State private var pastedCount = 0
    @State private var isLoadingAttachment = false

    private var settings: AppSettings { app.settings }
    private var conversation: Conversation? { model.conversation(controller.id) }
    private var selection: ToolSelection { model.toolSelection(for: conversation) }

    /// Reload prompts and resources when a server of this chat (re)connects, not on every log line.
    private var connectedServerIDs: Set<UUID> {
        Set(app.mcpStates.values.filter { $0.isConnected && selection.mcpServerIDs.contains($0.id) }.map(\.id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let steering = controller.pendingSteering, !steering.isEmpty {
                steeringChip(steering)
            }
            if !controller.draft.attachments.isEmpty || isLoadingAttachment {
                AttachmentStrip(attachments: controller.draft.attachments, isLoading: isLoadingAttachment) { id in
                    controller.draft.attachments.removeAll { $0.id == id }
                }
            }
            textView
                .frame(height: min(max(textHeight, 24), maxTextHeight))
            bottomBar
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.25))
                }
                .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
        }
        .overlay(alignment: .topLeading) {
            if let trigger, !completionItems.isEmpty {
                CompletionList(items: completionItems, highlighted: highlightedIndex) { index in
                    accept(index, trigger: trigger)
                }
                .alignmentGuide(.top) { $0[.bottom] + 6 }
            }
        }
        .frame(maxWidth: settings.maxMessageWidth + 24)
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .padding(.top, 6)
        .frame(maxWidth: .infinity)
        .task(id: selection) { await loadMCPItems() }
        .onChange(of: connectedServerIDs) { _, _ in Task { await loadMCPItems() } }
        .onReceive(NotificationCenter.default.publisher(for: .focusComposer)) { note in
            if note.object == nil || (note.object as? UUID) == controller.id { focusToken += 1 }
        }
        .sheet(item: $argumentRequest) { request in
            ArgumentSheet(request: request) { values in
                Task { await complete(request, values: values) }
            }
        }
    }

    private var maxTextHeight: CGFloat {
        let line = app.settingsStore.nsFont(for: .input).boundingRectForFont.height
        return ceil(line * 12) + 8
    }

    private var textView: some View {
        PromptTextView(
            text: $controller.draft.text,
            font: app.settingsStore.nsFont(for: .input),
            placeholder: placeholder,
            sendKey: settings.sendKey,
            isCompletionActive: trigger != nil && !completionItems.isEmpty,
            focusToken: focusToken,
            onSend: send,
            onHeightChange: { textHeight = $0 },
            onTrigger: { newTrigger in
                trigger = newTrigger
                highlightedIndex = 0
            },
            onCompletionKey: handleCompletionKey,
            onPasteboardAttachments: addAttachments(from:),
            onLongPaste: handleLongPaste,
            onEmptyUpArrow: {
                NotificationCenter.default.post(name: .editLastMessage, object: controller.id)
            }
        )
    }

    private var placeholder: String {
        if controller.isGenerating { return "Type to steer the model; it's sent after the current step…" }
        var hint = settings.sendKey == .enter ? "Message (⇧↩ for a new line)" : "Message (⌘↩ to send)"
        if !prompts.isEmpty || !resources.isEmpty { hint += " — / for prompts, @ for resources" }
        return hint
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 10) {
            attachMenu
            if model.supportsTools {
                ToolsMenu(model: model, conversationID: controller.id)
            }
            ThinkingPicker(level: thinkingBinding, inherited: inheritedThinking, compact: true)
                .disabled(model.profile.reasoning == .none && model.connection.engine != .anthropic)
            Spacer(minLength: 8)
            liveStatus
            sendButton
        }
        .buttonStyle(.borderless)
        .controlSize(.regular)
        .labelStyle(.iconOnly)
    }

    private var attachMenu: some View {
        Menu {
            Button("Photos and Files…", systemImage: "paperclip") { chooseFiles() }
            if !prompts.isEmpty {
                Menu("Prompts", systemImage: "text.bubble") {
                    ForEach(prompts) { prompt in
                        Button(prompt.displayName) { usePrompt(prompt) }
                    }
                }
            }
            if !resources.isEmpty || !templates.isEmpty {
                Menu("Resources", systemImage: "shippingbox") {
                    ForEach(resources) { resource in
                        Button(resource.displayName) { attachResource(resource) }
                    }
                    if !templates.isEmpty {
                        Divider()
                        ForEach(templates) { template in
                            Button((template.title ?? template.name) + "…") { useTemplate(template) }
                        }
                    }
                }
            }
        } label: {
            Label("Attach", systemImage: "plus")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Attach photos, files, MCP prompts or resources")
    }

    @ViewBuilder
    private var liveStatus: some View {
        if controller.isGenerating {
            if let progress = controller.liveProgress, controller.liveMetrics?.completionTokens == nil {
                Text("Reading prompt \(Int(progress.fraction * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else if let speed = controller.liveMetrics?.generationSpeed {
                Text("\(MetricsFormatter.speed(speed.value)) tok/s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } else {
            let usage = controller.contextUsage
            if let total = usage.total, usage.used > 0 {
                Text("\(MetricsFormatter.compactTokens(usage.used)) / \(MetricsFormatter.compactTokens(total))")
                    .font(.caption)
                    .foregroundStyle((usage.fraction ?? 0) > 0.9 ? .orange : .secondary)
                    .monospacedDigit()
                    .help("Approximate context used by this chat")
            }
        }
    }

    @ViewBuilder
    private var sendButton: some View {
        if controller.isGenerating {
            if controller.canSend {
                Button(action: send) {
                    Label("Steer", systemImage: "arrow.turn.down.right")
                }
                .help("Send after the current step")
            }
            Button {
                controller.stop()
            } label: {
                Label("Stop", systemImage: "stop.circle.fill")
                    .font(.title2)
            }
            .help("Stop (⌘.)")
        } else {
            Button(action: send) {
                Label("Send", systemImage: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(controller.canSend ? Color.accentColor : Color.secondary)
            }
            .disabled(!controller.canSend)
            .help(settings.sendKey == .enter ? "Send (↩)" : "Send (⌘↩)")
        }
    }

    private func steeringChip(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary)
            Text("Queued: \(text)")
                .lineLimit(1)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                controller.pendingSteering = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Don't send")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Thinking

    private var thinkingBinding: Binding<ThinkingLevel?> {
        Binding(
            get: { conversation?.overrides.thinking },
            set: { level in
                guard var conversation else { return }
                conversation.overrides.thinking = level
                model.save(conversation)
            }
        )
    }

    private var inheritedThinking: ThinkingLevel {
        if let level = model.workspace.overrides.thinking, level != .default { return level }
        return model.connection.thinking.level
    }

    // MARK: Sending

    private func send() {
        if trigger != nil, !completionItems.isEmpty, let trigger {
            accept(highlightedIndex, trigger: trigger)
            return
        }
        guard controller.canSend else { return }
        if !model.supportsVision, controller.draft.attachments.contains(where: \.isImage) {
            model.showError("\(model.workspace.modelID.map(ModelNameFormatter.shortName) ?? "This model") may not accept images. If the request fails, remove the image or turn on Images in the connection settings.")
        }
        controller.send()
    }

    // MARK: Attachments

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .pdf, .text, .sourceCode, .json, .data]
        panel.begin { response in
            guard response == .OK else { return }
            Task { @MainActor in addFiles(panel.urls) }
        }
    }

    private func addFiles(_ urls: [URL]) {
        let megapixels = settings.maxImageMegapixels
        let pdfAsImages = settings.pdfAsImages
        isLoadingAttachment = true
        Task.detached(priority: .userInitiated) {
            var loaded: [Attachment] = []
            var errors: [String] = []
            for url in urls {
                do {
                    loaded.append(try AttachmentLoader.load(url: url, maxMegapixels: megapixels, pdfAsImages: pdfAsImages))
                } catch {
                    errors.append(error.localizedDescription)
                }
            }
            await MainActor.run {
                controller.draft.attachments += loaded
                isLoadingAttachment = false
                if !errors.isEmpty { model.showError(errors.joined(separator: " ")) }
            }
        }
    }

    /// Paste or drop: files and images become attachments. Returns `false` for plain text.
    private func addAttachments(from pasteboard: NSPasteboard) -> Bool {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            addFiles(urls)
            return true
        }
        let results = AttachmentLoader.fromPasteboard(pasteboard, maxMegapixels: settings.maxImageMegapixels, pdfAsImages: settings.pdfAsImages)
        guard !results.isEmpty else { return false }
        for result in results {
            switch result {
            case .success(let attachment): controller.draft.attachments.append(attachment)
            case .failure(let error): model.showError(error.localizedDescription)
            }
        }
        return true
    }

    /// Long pastes become a text attachment instead of flooding the box.
    private func handleLongPaste(_ text: String) -> Bool {
        let limit = settings.pasteLongTextToFileLength
        guard limit > 0, text.count > limit else { return false }
        pastedCount += 1
        controller.draft.attachments.append(.pastedText(text, index: pastedCount))
        model.showInfo("Long text was added as an attachment.")
        return true
    }

    // MARK: MCP prompts and resources

    private func loadMCPItems() async {
        let ids = selection.mcpServerIDs
        guard !ids.isEmpty else {
            prompts = []
            resources = []
            templates = []
            return
        }
        async let loadedPrompts = app.mcpHost.prompts(serverIDs: ids)
        async let loadedResources = app.mcpHost.resources(serverIDs: ids)
        async let loadedTemplates = app.mcpHost.resourceTemplates(serverIDs: ids)
        prompts = await loadedPrompts
        resources = await loadedResources
        templates = await loadedTemplates
    }

    private var completionItems: [CompletionItem] {
        guard let trigger else { return [] }
        let query = trigger.query.lowercased()
        func matches(_ values: String?...) -> Bool {
            query.isEmpty || values.contains { $0?.lowercased().contains(query) == true }
        }
        switch trigger.kind {
        case .prompt:
            return prompts.filter { matches($0.name, $0.title) }.prefix(8).map {
                CompletionItem(id: $0.id, title: $0.displayName, subtitle: $0.description, detail: $0.serverName, icon: "text.bubble")
            }
        case .resource:
            let fixed = resources.filter { matches($0.name, $0.title, $0.uri) }.map {
                CompletionItem(id: $0.id, title: $0.displayName, subtitle: $0.uri, detail: $0.serverName, icon: "shippingbox")
            }
            let dynamic = templates.filter { matches($0.name, $0.title, $0.uriTemplate) }.map {
                CompletionItem(id: $0.id, title: ($0.title ?? $0.name) + "…", subtitle: $0.uriTemplate, detail: $0.serverName, icon: "curlybraces")
            }
            return Array((fixed + dynamic).prefix(8))
        }
    }

    private func handleCompletionKey(_ key: CompletionKey) {
        let count = completionItems.count
        switch key {
        case .up: highlightedIndex = (highlightedIndex - 1 + max(count, 1)) % max(count, 1)
        case .down: highlightedIndex = (highlightedIndex + 1) % max(count, 1)
        case .accept:
            if let trigger { accept(highlightedIndex, trigger: trigger) }
        case .dismiss: trigger = nil
        }
    }

    private func accept(_ index: Int, trigger: CompletionTrigger) {
        let items = completionItems
        guard items.indices.contains(index) else { return }
        let item = items[index]
        removeTriggerText(trigger)
        self.trigger = nil
        if let prompt = prompts.first(where: { $0.id == item.id }) {
            usePrompt(prompt)
        } else if let resource = resources.first(where: { $0.id == item.id }) {
            attachResource(resource)
        } else if let template = templates.first(where: { $0.id == item.id }) {
            useTemplate(template)
        }
    }

    private func removeTriggerText(_ trigger: CompletionTrigger) {
        let text = controller.draft.text as NSString
        guard NSMaxRange(trigger.range) <= text.length else { return }
        controller.draft.text = text.replacingCharacters(in: trigger.range, with: "")
    }

    private func usePrompt(_ prompt: MCPPromptInfo) {
        if prompt.arguments.isEmpty {
            Task { await complete(ArgumentRequest(target: .prompt(prompt)), values: [:]) }
        } else {
            argumentRequest = ArgumentRequest(target: .prompt(prompt))
        }
    }

    private func useTemplate(_ template: MCPResourceTemplateInfo) {
        argumentRequest = ArgumentRequest(target: .template(template))
    }

    private func attachResource(_ resource: MCPResourceInfo) {
        isLoadingAttachment = true
        Task {
            defer { isLoadingAttachment = false }
            do {
                let attachment = try await app.mcpHost.readResource(serverID: resource.serverID, uri: resource.uri, name: resource.displayName)
                controller.draft.attachments.append(attachment)
            } catch {
                model.showError("Couldn't read \(resource.displayName): \(error.localizedDescription)")
            }
        }
    }

    private func complete(_ request: ArgumentRequest, values: [String: String]) async {
        isLoadingAttachment = true
        defer { isLoadingAttachment = false }
        do {
            switch request.target {
            case .prompt(let prompt):
                let attachments = try await app.mcpHost.getPrompt(prompt, arguments: values)
                controller.draft.attachments += attachments
            case .template(let template):
                let uri = template.expand(values)
                let attachment = try await app.mcpHost.readResource(serverID: template.serverID, uri: uri, name: template.title ?? template.name)
                controller.draft.attachments.append(attachment)
            }
            focusToken += 1
        } catch {
            model.showError(error.localizedDescription)
        }
    }
}

// MARK: - Completion list

struct CompletionItem: Identifiable, Hashable {
    var id: String
    var title: String
    var subtitle: String?
    var detail: String
    var icon: String
}

/// The `/` and `@` picker shown above the composer.
struct CompletionList: View {
    var items: [CompletionItem]
    var highlighted: Int
    var choose: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 8) {
                    Image(systemName: item.icon)
                        .frame(width: 16)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).lineLimit(1)
                        if let subtitle = item.subtitle, !subtitle.isEmpty {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 12)
                    Text(item.detail).font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(index == highlighted ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .onTapGesture { choose(index) }
            }
        }
        .padding(5)
        .frame(width: 380, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.2)))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
    }
}

// MARK: - Attachments

/// Thumbnails and file chips above the text.
struct AttachmentStrip: View {
    var attachments: [Attachment]
    var isLoading: Bool
    var remove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    AttachmentChip(attachment: attachment) { remove(attachment.id) }
                }
                if isLoading {
                    ProgressView().controlSize(.small).padding(.horizontal, 8)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

struct AttachmentChip: View {
    var attachment: Attachment
    var remove: () -> Void
    @State private var thumbnail: NSImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: AttachmentLoader.icon(for: attachment))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(attachment.name).lineLimit(1).font(.callout)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 56)
                    .frame(maxWidth: 220)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .help(attachment.name)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .offset(x: 5, y: -5)
            .help("Remove")
        }
        .task(id: attachment.id) {
            guard attachment.isImage else { return }
            let attachment = attachment
            thumbnail = await Task.detached { AttachmentLoader.thumbnail(for: attachment, maxSize: 56) }.value
        }
    }
}

// MARK: - Arguments for prompts and resource templates

struct ArgumentRequest: Identifiable {
    enum Target {
        case prompt(MCPPromptInfo)
        case template(MCPResourceTemplateInfo)
    }

    let id = UUID()
    var target: Target

    var title: String {
        switch target {
        case .prompt(let prompt): prompt.displayName
        case .template(let template): template.title ?? template.name
        }
    }

    var detail: String? {
        switch target {
        case .prompt(let prompt): prompt.description
        case .template(let template): template.description ?? template.uriTemplate
        }
    }

    struct Field: Identifiable {
        var name: String
        var label: String
        var help: String?
        var required: Bool

        var id: String { name }
    }

    var fields: [Field] {
        switch target {
        case .prompt(let prompt):
            prompt.arguments.map { Field(name: $0.name, label: $0.title ?? $0.name, help: $0.description, required: $0.required) }
        case .template(let template):
            template.variables.map { Field(name: $0, label: $0, help: nil, required: true) }
        }
    }
}

/// Fills in MCP prompt arguments or resource template variables.
struct ArgumentSheet: View {
    var request: ArgumentRequest
    var submit: ([String: String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.title).font(.title3.weight(.semibold))
            if let detail = request.detail {
                Text(detail).foregroundStyle(.secondary)
            }
            Form {
                ForEach(request.fields) { field in
                    TextField(field.label + (field.required ? " *" : ""), text: Binding(
                        get: { values[field.name, default: ""] },
                        set: { values[field.name] = $0 }
                    ))
                    .help(field.help ?? "")
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Use") {
                    submit(values.filter { !$0.value.isEmpty })
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isComplete)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var isComplete: Bool {
        request.fields.allSatisfy { !$0.required || !(values[$0.name] ?? "").isEmpty }
    }
}

// MARK: - Tools menu

/// Per-chat tool sources. A chat inherits the workspace's tools until changed here.
struct ToolsMenu: View {
    var model: WorkspaceModel
    var conversationID: UUID
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    private var conversation: Conversation? { model.conversation(conversationID) }
    private var selection: ToolSelection { model.toolSelection(for: conversation) }

    var body: some View {
        Menu {
            if model.capabilities.serverToolsAvailable {
                Toggle("Server tools (llama.cpp)", isOn: Binding(
                    get: { selection.serverToolsEnabled },
                    set: { value in update { $0.serverToolsEnabled = value } }
                ))
                Divider()
            }
            if app.mcpServers.isEmpty {
                Text("No MCP servers yet")
            } else {
                Section("MCP servers") {
                    ForEach(app.mcpServers) { server in
                        Toggle(isOn: Binding(
                            get: { selection.mcpServerIDs.contains(server.id) },
                            set: { on in update { if on { $0.mcpServerIDs.insert(server.id) } else { $0.mcpServerIDs.remove(server.id) } } }
                        )) {
                            Text(server.name + stateSuffix(server))
                        }
                        .disabled(!server.isEnabled)
                    }
                }
            }
            Divider()
            if conversation?.tools != nil {
                Button("Use Workspace Tools") {
                    guard var conversation else { return }
                    conversation.tools = nil
                    model.save(conversation)
                }
            }
            Button("Manage MCP Servers…") { openWindow(id: WindowID.mcpServers) }
        } label: {
            Label(selection.isEmpty ? "Tools" : "Tools (\(toolCount))", systemImage: selection.isEmpty ? "wrench.and.screwdriver" : "wrench.and.screwdriver.fill")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help(selection.isEmpty ? "No tools for this chat" : "\(toolCount) tool sources on")
    }

    private var toolCount: Int {
        selection.mcpServerIDs.count + (selection.serverToolsEnabled ? 1 : 0)
    }

    private func stateSuffix(_ server: MCPServerConfig) -> String {
        guard let state = app.mcpStates[server.id] else { return "" }
        switch state.phase {
        case .connected: return state.tools.isEmpty ? "" : " — \(state.tools.count) tools"
        case .failed: return " — failed"
        default: return state.phase.isBusy ? " — \(state.phase.label.lowercased())" : ""
        }
    }

    private func update(_ change: (inout ToolSelection) -> Void) {
        guard var conversation else { return }
        var tools = selection
        change(&tools)
        conversation.tools = tools
        model.save(conversation)
        Task { await app.mcpHost.ensureConnected(tools.mcpServerIDs) }
    }
}
