import AppKit
import GoooeeeCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - General

/// Name, engine, address, API key, headers, timeout and default model.
struct ConnectionGeneralTab: View {
    @Binding var draft: ServerConnection
    @Binding var apiKey: String
    @State private var urlText = ""
    @State private var urlProblem: String?
    @State private var pendingEngine: EngineKind?
    @State private var models: [RemoteModel] = []
    @State private var loadingModels = false
    @State private var modelError: String?

    var body: some View {
        Form {
            serverSection
            authSection
            modelSection
            headersSection
            networkSection
        }
        .formStyle(.grouped)
        .onAppear { urlText = Self.displayURL(draft) }
        .confirmationDialog(
            "Apply \(pendingEngine?.displayName ?? "") defaults?",
            isPresented: Binding(get: { pendingEngine != nil }, set: { if !$0 { pendingEngine = nil } }),
            presenting: pendingEngine
        ) { engine in
            Button("Apply Defaults") { applyDefaults(of: engine) }
            Button("Change Engine Only") { draft.engine = engine }
            Button("Cancel", role: .cancel) {}
        } message: { engine in
            Text("Defaults set the API style, the usual address (\(engine.defaultBaseURL.absoluteString)) and an example launch command. Your sampling values are kept.")
        }
    }

    private var serverSection: some View {
        Section("Server") {
            TextField("Name", text: $draft.name)
            Picker("Engine", selection: Binding(get: { draft.engine }, set: { if $0 != draft.engine { pendingEngine = $0 } })) {
                ForEach(EngineKind.allCases) { engine in
                    Text(engine.displayName).tag(engine)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                TextField("URL", text: $urlText, prompt: Text("http://192.168.1.20:8080"))
                    .onChange(of: urlText) { _, text in applyURL(text) }
                if let urlProblem {
                    Text(urlProblem).font(.caption).foregroundStyle(.red)
                }
            }
            TextField("API prefix", text: $draft.apiPrefix, prompt: Text("/v1"))
            Picker("API", selection: $draft.apiStyle) {
                ForEach(APIStyle.allCases, id: \.self) { style in
                    Text(style.label).tag(style)
                }
            }
            LabeledContent("Chat requests go to") {
                Text(draft.apiURL(chatPath).absoluteString)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var chatPath: String {
        switch draft.apiStyle {
        case .openAIChat: "/chat/completions"
        case .openAICompletion: "/completions"
        case .anthropicMessages: "/messages"
        }
    }

    private var authSection: some View {
        Section {
            SecureField("API key", text: $apiKey, prompt: Text(draft.engine.requiresAPIKey ? "Required" : "Optional"))
        } header: {
            Text("Authentication")
        } footer: {
            Text("Stored in your login Keychain. Local servers usually don't need a key.")
                .foregroundStyle(.secondary)
        }
    }

    private var modelSection: some View {
        Section {
            HStack {
                TextField("Default model", text: $draft.defaultModelID.emptyAsNil(), prompt: Text("Use the server's model"))
                modelMenu
            }
            if let modelError {
                Text(modelError).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Model")
        } footer: {
            Text("New workspaces on this connection start with this model. Each workspace can pick its own.")
                .foregroundStyle(.secondary)
        }
    }

    private var modelMenu: some View {
        Menu {
            if models.isEmpty {
                Text(loadingModels ? "Loading…" : "No models loaded")
            }
            ForEach(models) { model in
                Button(model.id + (model.loadState == .loaded ? "  (loaded)" : "")) {
                    draft.defaultModelID = model.id
                }
            }
            Divider()
            Button("Refresh List") { Task { await loadModels() } }
        } label: {
            if loadingModels {
                ProgressView().controlSize(.small)
            } else {
                Text("Choose")
            }
        }
        .fixedSize()
        .task { await loadModels() }
    }

    private var headersSection: some View {
        Section {
            KeyValueListEditor(pairs: $draft.extraHeaders, keyPlaceholder: "Header", valuePlaceholder: "Value", addTitle: "Add Header")
        } header: {
            Text("Extra headers")
        } footer: {
            Text("Sent with every request. For secrets, prefer the API key field, which is kept in the Keychain.")
                .foregroundStyle(.secondary)
        }
    }

    private var networkSection: some View {
        Section("Network") {
            LabeledContent("Request timeout") {
                HStack(spacing: 6) {
                    TextField("", value: $draft.requestTimeout, format: .number.precision(.fractionLength(0)))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                        .labelsHidden()
                    Text("seconds").foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Actions

    private static func displayURL(_ connection: ServerConnection) -> String {
        connection.baseURL.absoluteString
    }

    private func applyURL(_ text: String) {
        guard !text.isEmpty else {
            urlProblem = "Enter the server address."
            return
        }
        guard let normalized = URLBuilder.normalize(text) else {
            urlProblem = "That doesn't look like a URL."
            return
        }
        urlProblem = nil
        if draft.baseURL != normalized.base { draft.baseURL = normalized.base }
        // Only take the prefix when the pasted URL included one (e.g. …/v1/chat/completions).
        if text.contains("/v1"), draft.apiPrefix != normalized.prefix { draft.apiPrefix = normalized.prefix }
    }

    private func applyDefaults(of engine: EngineKind) {
        let previous = draft.engine
        draft.engine = engine
        draft.apiStyle = engine.defaultAPIStyle
        draft.apiPrefix = engine.defaultAPIPrefix
        if draft.baseURL == previous.defaultBaseURL || !engine.isLocalByDefault || !previous.isLocalByDefault {
            draft.baseURL = engine.defaultBaseURL
            urlText = engine.defaultBaseURL.absoluteString
        }
        let command = draft.launch?.command ?? ""
        if command.isEmpty || command == previous.launchCommandExample {
            draft.launch = engine.launchCommandExample.isEmpty ? nil : LaunchConfig(command: engine.launchCommandExample)
        }
    }

    private func loadModels() async {
        loadingModels = true
        defer { loadingModels = false }
        do {
            models = try await ProviderFactory.make(connection: draft, apiKey: apiKey.isEmpty ? nil : apiKey).listModels()
            modelError = models.isEmpty ? "The server listed no models." : nil
        } catch {
            models = []
            modelError = "Couldn't list models: \(InferenceError.from(error).localizedDescription)"
        }
    }
}

// MARK: - Model & sampling

/// Profile, defaults policy, sampling values, capability overrides, system prompt and extra JSON.
struct ConnectionSamplingTab: View {
    @Binding var draft: ServerConnection
    var apiKey: String
    @Environment(AppModel.self) private var app
    @State private var serverDefaults = SamplingSettings()
    @State private var probed = false

    var body: some View {
        Form {
            profileSection
            samplingSection
            capabilitiesSection
            systemPromptSection
            extraJSONSection
        }
        .formStyle(.grouped)
        .task { await probeServerDefaults() }
    }

    private var profile: ModelProfile {
        app.profiles.resolve(modelID: draft.defaultModelID, explicitID: draft.profileID)
    }

    private var detectedProfile: ModelProfile {
        app.profiles.resolve(modelID: draft.defaultModelID, explicitID: nil)
    }

    private var effective: EffectiveSettings? {
        try? SettingsResolver(connection: draft, profile: profile, serverDefaults: serverDefaults).resolve()
    }

    private var profileSection: some View {
        Section {
            Picker("Model profile", selection: $draft.profileID) {
                Text("Auto-detect (\(detectedProfile.displayName))").tag(String?.none)
                Divider()
                ForEach(app.profiles.all) { profile in
                    Text(profile.displayName + (profile.isCustom ? " (custom)" : "")).tag(Optional(profile.id))
                }
            }
            Picker("Defaults", selection: $draft.defaultsPolicy) {
                ForEach(DefaultsPolicy.allCases, id: \.self) { policy in
                    Text(policy.label).tag(policy)
                }
            }
        } header: {
            Text("Model profile")
        } footer: {
            Text("A profile holds the model family's recommended sampling and how it marks its reasoning. Values you leave unset come from the profile or the server, in the order chosen above.")
                .foregroundStyle(.secondary)
        }
    }

    private var samplingSection: some View {
        Section {
            SamplingEditor(values: $draft.sampling, effective: effective, supportedKeys: draft.engine.capabilities.samplingKeys)
        } header: {
            HStack {
                Text("Sampling")
                Spacer()
                if !probed {
                    ProgressView().controlSize(.mini)
                }
            }
        } footer: {
            Text("Workspaces and chats can override these. Parameters \(draft.engine.displayName) doesn't accept are hidden.")
                .foregroundStyle(.secondary)
        }
    }

    private var capabilitiesSection: some View {
        Section {
            TriStatePicker(title: "Images", value: $draft.supportsImages)
            TriStatePicker(title: "Tool calling", value: $draft.supportsTools)
        } header: {
            Text("Capabilities")
        } footer: {
            Text("Auto-detect asks the server and the model profile. Override when the detection is wrong.")
                .foregroundStyle(.secondary)
        }
    }

    private var systemPromptSection: some View {
        Section {
            CodeTextEditor(text: $draft.systemPrompt.emptyAsNil(), minHeight: 80)
        } header: {
            Text("System prompt")
        } footer: {
            Text("Used by every chat on this connection unless a workspace or chat sets its own.")
                .foregroundStyle(.secondary)
        }
    }

    private var extraJSONSection: some View {
        Section {
            CodeTextEditor(text: $draft.extraBodyJSON.emptyAsNil(), minHeight: 70)
            if let problem = extraJSONProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Extra request JSON")
        } footer: {
            Text("Merged into every request body, e.g. {\"chat_template_kwargs\": {\"enable_thinking\": false}}.")
                .foregroundStyle(.secondary)
        }
    }

    private var extraJSONProblem: String? {
        guard let json = draft.extraBodyJSON, !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do {
            guard case .object = try JSONValue.parse(json) else { return "Must be a JSON object." }
            return nil
        } catch {
            return "Not valid JSON."
        }
    }

    private func probeServerDefaults() async {
        let probe = ServerProbe(connection: draft, apiKey: apiKey.isEmpty ? nil : apiKey)
        let result = await probe.probe(modelID: draft.defaultModelID)
        serverDefaults = result.capabilities.defaultSampling
        probed = true
    }
}

// MARK: - Thinking

/// The default thinking level and what each level sends to this engine and model.
struct ConnectionThinkingTab: View {
    @Binding var draft: ServerConnection
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Section {
                Picker("Default level", selection: $draft.thinking.level) {
                    ForEach(ThinkingLevel.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
            } footer: {
                Text("“Default” sends nothing and lets the server or chat template decide. Workspaces and chats can override the level from the composer.")
                    .foregroundStyle(.secondary)
            }
            Section("What goooeee sends to \(draft.engine.displayName)") {
                ForEach(ThinkingLevel.allCases.filter { $0 != .default }) { level in
                    ThinkingLevelRow(level: level, translation: translation(for: level))
                }
            }
            modelSection
        }
        .formStyle(.grouped)
    }

    private var profile: ModelProfile {
        app.profiles.resolve(modelID: draft.defaultModelID, explicitID: draft.profileID)
    }

    private var modelSection: some View {
        Section("Model") {
            LabeledContent("Profile", value: profile.displayName)
            LabeledContent("Reasoning format", value: reasoningDescription)
            LabeledContent("Thinking switch", value: switchDescription)
        }
    }

    private func translation(for level: ThinkingLevel) -> String {
        if draft.apiStyle == .anthropicMessages {
            if let budget = level.anthropicBudgetTokens {
                return "thinking: {\"type\": \"enabled\", \"budget_tokens\": \(budget)}"
            }
            return "nothing (thinking stays off)"
        }
        let result = ThinkingTranslator.translate(level: level, profile: profile, engine: draft.engine)
        var parts: [String] = []
        if !result.body.isEmpty {
            parts.append(JSONValue.object(result.body).encodedString())
        }
        if let suffix = result.systemPromptSuffix {
            parts.append("system prompt + “\(suffix)”")
        }
        return parts.isEmpty ? "nothing (not supported for this engine and model)" : parts.joined(separator: "\n")
    }

    private var reasoningDescription: String {
        switch profile.reasoning {
        case .auto: "Detect <think> tags automatically"
        case .none: "None"
        case .tags(let open, let close, _): "\(open) … \(close)"
        case .harmony: "Harmony channels"
        }
    }

    private var switchDescription: String {
        let control = profile.thinkingControl
        var parts: [String] = []
        if let kwarg = control.chatTemplateKwarg { parts.append("chat_template_kwargs.\(kwarg)") }
        if let soft = control.softSwitch, soft.count == 2 { parts.append("\(soft[0]) / \(soft[1])") }
        if control.reasoningEffort { parts.append("reasoning_effort") }
        if control.alwaysThinks { parts.append("always thinks") }
        return parts.isEmpty ? "Unknown" : parts.joined(separator: ", ")
    }
}

private struct ThinkingLevelRow: View {
    var level: ThinkingLevel
    var translation: String

    var body: some View {
        LabeledContent(level.label) {
            Text(translation)
                .font(.system(.callout, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Template

/// A user-loaded Jinja chat template, for servers that can't apply the model's own template.
struct ConnectionTemplateTab: View {
    @Binding var draft: ServerConnection
    @State private var loadError: String?
    @State private var preview: String?
    @State private var previewError: String?

    var body: some View {
        Form {
            Section {
                Text("Most servers apply the model's chat template themselves; leave this empty unless yours can't. With a template loaded, goooeee renders the prompt itself and calls the plain completions API.")
                    .foregroundStyle(.secondary)
            }
            if draft.chatTemplate == nil {
                emptySection
            } else {
                templateSections
            }
        }
        .formStyle(.grouped)
    }

    private var emptySection: some View {
        Section {
            HStack {
                Button("Load Template File…") { loadFile() }
                Button("Paste Template") {
                    draft.chatTemplate = ChatTemplate(source: "")
                }
            }
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        } footer: {
            Text("Accepts .jinja files, chat_template.json and tokenizer_config.json (the template and BOS/EOS tokens are read from it).")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var templateSections: some View {
        Section {
            CodeTextEditor(text: templateBinding(\.source), minHeight: 220)
            HStack {
                Button("Replace from File…") { loadFile() }
                Button("Preview") { renderPreview() }
                Spacer()
                Button("Remove Template", role: .destructive) { removeTemplate() }
            }
        } header: {
            Text(draft.chatTemplate?.fileName ?? "Template")
        }
        Section("Tokens") {
            TextField("BOS token", text: templateBinding(\.bosToken), prompt: Text("e.g. <s>"))
            TextField("EOS token", text: templateBinding(\.eosToken), prompt: Text("e.g. </s>"))
            TextField("Stop strings", text: stopBinding, prompt: Text("separated by ;"))
        }
        .font(.system(.body, design: .monospaced))
        apiSection
        if preview != nil || previewError != nil {
            previewSection
        }
    }

    private var apiSection: some View {
        Section("API") {
            if draft.apiStyle == .openAICompletion {
                Text("Prompts are rendered with this template and sent to \(draft.apiURL("/completions").absoluteString).")
                    .foregroundStyle(.secondary)
                Button("Use Chat Completions Instead") { draft.apiStyle = .openAIChat }
            } else {
                Text("The template is only used with the completions API. The connection currently uses \(draft.apiStyle.label).")
                    .foregroundStyle(.secondary)
                Button("Use This Template") { draft.apiStyle = .openAICompletion }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var previewSection: some View {
        Section("Preview") {
            if let previewError {
                Label(previewError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if let preview {
                MonospacedBlock(text: preview, maxHeight: 260)
            }
        }
    }

    private func templateBinding(_ keyPath: WritableKeyPath<ChatTemplate, String>) -> Binding<String> {
        Binding(
            get: { draft.chatTemplate?[keyPath: keyPath] ?? "" },
            set: { value in
                var template = draft.chatTemplate ?? ChatTemplate(source: "")
                template[keyPath: keyPath] = value
                draft.chatTemplate = template
            }
        )
    }

    private var stopBinding: Binding<String> {
        Binding(
            get: { draft.chatTemplate?.stopTokens.joined(separator: ";") ?? "" },
            set: { value in
                var template = draft.chatTemplate ?? ChatTemplate(source: "")
                template.stopTokens = value.split(separator: ";", omittingEmptySubsequences: true).map(String.init)
                draft.chatTemplate = template
            }
        )
    }

    private func loadFile() {
        let jinja = UTType(filenameExtension: "jinja") ?? .plainText
        guard let url = EditorPanels.chooseFile(types: [jinja, .json, .plainText], message: "Choose a chat template or tokenizer_config.json") else { return }
        do {
            draft.chatTemplate = try TemplateFile.load(url)
            loadError = nil
            preview = nil
            previewError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func renderPreview() {
        guard let template = draft.chatTemplate else { return }
        do {
            preview = try ChatTemplateRenderer.validate(template)
            previewError = nil
        } catch {
            preview = nil
            previewError = error.localizedDescription
        }
    }

    private func removeTemplate() {
        draft.chatTemplate = nil
        if draft.apiStyle == .openAICompletion { draft.apiStyle = .openAIChat }
        preview = nil
        previewError = nil
    }
}

/// Reads a chat template from a `.jinja` file or a Hugging Face JSON config.
private enum TemplateFile {
    enum LoadError: LocalizedError {
        case noTemplate(String)
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .noTemplate(let name): "“\(name)” has no chat_template."
            case .unreadable(let name): "Couldn't read “\(name)” as text."
            }
        }
    }

    static func load(_ url: URL) throws -> ChatTemplate {
        let name = url.lastPathComponent
        let data = try Data(contentsOf: url)
        if url.pathExtension.lowercased() == "json", let json = try? JSONValue.parse(data) {
            guard let source = templateSource(in: json) else { throw LoadError.noTemplate(name) }
            let eos = token("eos_token", in: json)
            return ChatTemplate(
                source: source,
                fileName: name,
                bosToken: token("bos_token", in: json),
                eosToken: eos,
                stopTokens: eos.isEmpty ? [] : [eos]
            )
        }
        guard let text = String(data: data, encoding: .utf8) else { throw LoadError.unreadable(name) }
        return ChatTemplate(source: text, fileName: name)
    }

    /// `chat_template` is either a string or a list of `{name, template}` (prefer "default").
    private static func templateSource(in json: JSONValue) -> String? {
        if let source = json["chat_template"]?.stringValue { return source }
        guard let list = json["chat_template"]?.arrayValue else { return nil }
        let named = list.compactMap { entry -> (name: String, template: String)? in
            guard let template = entry["template"]?.stringValue else { return nil }
            return (entry["name"]?.stringValue ?? "", template)
        }
        return named.first { $0.name == "default" }?.template ?? named.first?.template
    }

    /// Tokens are strings or `{"content": "…"}` objects.
    private static func token(_ key: String, in json: JSONValue) -> String {
        json[key]?.stringValue ?? json[key]?["content"]?.stringValue ?? ""
    }
}

// MARK: - Launch

/// The command the workspace terminal runs to start this server.
struct ConnectionLaunchTab: View {
    @Binding var draft: ServerConnection

    var body: some View {
        Form {
            Section {
                CodeTextEditor(text: launchBinding(\.command), minHeight: 90)
                if !draft.engine.launchCommandExample.isEmpty, launchBinding(\.command).wrappedValue != draft.engine.launchCommandExample {
                    Button("Insert \(draft.engine.displayName) Example") {
                        launchBinding(\.command).wrappedValue = draft.engine.launchCommandExample
                    }
                }
            } header: {
                Text("Command")
            } footer: {
                Text("Chat → Start Server runs this in the workspace's terminal with your login shell's PATH, then waits for the server to answer.")
                    .foregroundStyle(.secondary)
            }
            Section("Working directory") {
                HStack {
                    TextField("Directory", text: workingDirectoryBinding, prompt: Text("The workspace's directory"))
                    Button("Choose…") {
                        if let path = EditorPanels.chooseDirectory(startingAt: draft.launch?.workingDirectory) {
                            workingDirectoryBinding.wrappedValue = path
                        }
                    }
                }
            }
            Section("Environment") {
                KeyValueListEditor(pairs: launchBinding(\.environment), keyPlaceholder: "VARIABLE", valuePlaceholder: "value", addTitle: "Add Variable")
            }
            Section {
                LabeledContent("Startup timeout") {
                    HStack(spacing: 6) {
                        TextField("", value: launchBinding(\.startupTimeout), format: .number.precision(.fractionLength(0)))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                            .labelsHidden()
                        Text("seconds").foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Large models can take minutes to load. goooeee keeps checking the server until this runs out.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func launchBinding<Value>(_ keyPath: WritableKeyPath<LaunchConfig, Value>) -> Binding<Value> {
        Binding(
            get: { (draft.launch ?? LaunchConfig())[keyPath: keyPath] },
            set: { value in
                var launch = draft.launch ?? LaunchConfig()
                launch[keyPath: keyPath] = value
                draft.launch = launch
            }
        )
    }

    private var workingDirectoryBinding: Binding<String> {
        Binding(
            get: { draft.launch?.workingDirectory ?? "" },
            set: { value in
                var launch = draft.launch ?? LaunchConfig()
                launch.workingDirectory = value.isEmpty ? nil : value
                draft.launch = launch
            }
        )
    }
}
