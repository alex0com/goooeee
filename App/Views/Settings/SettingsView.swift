import AppKit
import GoooeeeCore
import SwiftUI

/// The app's Settings window (⌘,). Every change applies immediately in all windows.
struct SettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var store = app.settingsStore
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsTab(settings: $store.settings)
            }
            Tab("Fonts & Text", systemImage: "textformat.size") {
                FontsSettingsTab(settings: $store.settings)
            }
            Tab("Chat", systemImage: "bubble.left.and.text.bubble.right") {
                ChatSettingsTab(settings: $store.settings)
            }
            Tab("Tools & MCP", systemImage: "wrench.and.screwdriver") {
                ToolsSettingsTab(settings: $store.settings)
            }
            Tab("Terminal", systemImage: "terminal") {
                TerminalSettingsTab(settings: $store.settings)
            }
            Tab("Profiles", systemImage: "cpu") {
                ProfilesSettingsTab()
            }
            Tab("Advanced", systemImage: "slider.horizontal.3") {
                AdvancedSettingsTab(settings: $store.settings)
            }
        }
        .frame(minWidth: 640, idealWidth: 700, minHeight: 480, idealHeight: 580)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @Binding var settings: AppSettings

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $settings.colorScheme) {
                    Text("Match System").tag(ColorSchemePreference.system)
                    Text("Light").tag(ColorSchemePreference.light)
                    Text("Dark").tag(ColorSchemePreference.dark)
                }
                .pickerStyle(.segmented)
            }
            Section("Sending") {
                Picker("Send with", selection: $settings.sendKey) {
                    Text("Return (⇧Return for a new line)").tag(SendKey.enter)
                    Text("⌘Return (Return for a new line)").tag(SendKey.commandEnter)
                }
            }
            titleSection
            Section {
                Toggle("Look for servers on this Mac when creating a workspace", isOn: $settings.localDiscoveryEnabled)
            } header: {
                Text("Connections")
            } footer: {
                Text("Checks the usual ports of llama.cpp, vLLM, mlx, LM Studio and Ollama on 127.0.0.1.")
                    .foregroundStyle(.secondary)
            }
            deletingSection
        }
        .formStyle(.grouped)
    }

    private var titleSection: some View {
        Section {
            Picker("Chat titles", selection: $settings.titleMode) {
                Text("First line of the first message").tag(TitleMode.firstLine)
                Text("Ask the model for a title").tag(TitleMode.llm)
            }
            if settings.titleMode == .llm {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Title prompt").font(.callout).foregroundStyle(.secondary)
                    CodeTextEditor(text: $settings.titlePrompt, minHeight: 100)
                    HStack {
                        Text("{{USER}} and {{ASSISTANT}} are replaced with the first exchange.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset") { settings.titlePrompt = ConversationTitle.defaultPrompt }
                            .controlSize(.small)
                            .disabled(settings.titlePrompt == ConversationTitle.defaultPrompt)
                    }
                }
            }
        } header: {
            Text("Titles")
        }
    }

    private var deletingSection: some View {
        Section {
            Toggle("Ask before deleting chats", isOn: $settings.confirmDelete)
            Stepper(value: $settings.keepDeletedDays, in: 1...365) {
                LabeledContent("Keep deleted chats for", value: "\(settings.keepDeletedDays) day\(settings.keepDeletedDays == 1 ? "" : "s")")
            }
        } header: {
            Text("Deleting")
        } footer: {
            Text("Deleted chats go to Recently Deleted in the sidebar, where you can restore them until they expire.")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Fonts & text

private struct FontsSettingsTab: View {
    @Binding var settings: AppSettings
    @State private var families: [String] = []

    var body: some View {
        Form {
            Section {
                ForEach(TextRole.allCases) { role in
                    FontRoleRow(role: role, spec: fontBinding(for: role), families: families, scale: settings.textScale)
                }
            } header: {
                Text("Fonts")
            } footer: {
                Text("Text size: ⌘+ and ⌘− scale every chat font together; ⌘0 resets.")
                    .foregroundStyle(.secondary)
            }
            textSection
            codeColorsSection
        }
        .formStyle(.grouped)
        .task {
            families = NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }.sorted()
        }
    }

    private func fontBinding(for role: TextRole) -> Binding<FontSpec> {
        Binding(
            get: { settings.fonts[role] ?? role.defaultFont },
            set: { settings.fonts[role] = $0 }
        )
    }

    private var textSection: some View {
        Section("Text") {
            LabeledContent("Text size") {
                HStack {
                    Slider(value: $settings.textScale, in: 0.6...2.5, step: 0.1)
                        .frame(width: 200)
                    Text(verbatim: "\(Int((settings.textScale * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }
            LabeledContent("Line spacing") {
                HStack {
                    Slider(value: $settings.lineSpacing, in: 1.0...2.0, step: 0.05)
                        .frame(width: 200)
                    Text(String(format: "%.2f", settings.lineSpacing))
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }
            LabeledContent("Message width") {
                HStack {
                    Slider(value: $settings.maxMessageWidth, in: 560...1600, step: 20)
                        .frame(width: 200)
                    Text("\(Int(settings.maxMessageWidth)) pt")
                        .monospacedDigit()
                        .frame(width: 60, alignment: .trailing)
                }
            }
        }
    }

    private var codeColorsSection: some View {
        Section {
            Picker("Light appearance", selection: $settings.codeThemeLight) {
                ForEach(CodeThemeNames.light, id: \.self) { Text($0).tag($0) }
                if !CodeThemeNames.light.contains(settings.codeThemeLight) {
                    Text(settings.codeThemeLight).tag(settings.codeThemeLight)
                }
            }
            Picker("Dark appearance", selection: $settings.codeThemeDark) {
                ForEach(CodeThemeNames.dark, id: \.self) { Text($0).tag($0) }
                if !CodeThemeNames.dark.contains(settings.codeThemeDark) {
                    Text(settings.codeThemeDark).tag(settings.codeThemeDark)
                }
            }
        } header: {
            Text("Code colors")
        }
    }
}

/// Theme names offered for code blocks. The transcript maps each name to its colors.
enum CodeThemeNames {
    static let light = ["xcode", "github", "atom-one-light", "solarized-light"]
    static let dark = ["atom-one-dark", "xcode-dark", "github-dark", "monokai", "solarized-dark"]
}

/// Family, size and a preview line for one text role.
private struct FontRoleRow: View {
    var role: TextRole
    @Binding var spec: FontSpec
    var families: [String]
    var scale: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(role.label)
                Spacer()
                familyPicker
                Stepper(value: $spec.size, in: 8...40, step: 0.5) {
                    Text(spec.size.formatted(.number.precision(.fractionLength(0...1))) + " pt")
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                }
                Button {
                    spec = role.defaultFont
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                }
                .buttonStyle(.borderless)
                .disabled(spec == role.defaultFont)
                .help("Use the default font")
            }
            Text(sample)
                .font(Font(previewFont as CTFont))
                .lineLimit(1)
                .foregroundStyle(role == .thinking || role == .metrics ? HierarchicalShapeStyle.secondary : HierarchicalShapeStyle.primary)
        }
        .padding(.vertical, 2)
    }

    private var familyPicker: some View {
        Picker("Font", selection: familyBinding) {
            Text(role == .code ? "System Monospaced" : "System").tag("")
            if role == .code {
                Text("SF Mono").tag("SF Mono")
            }
            if let family = spec.family, !family.isEmpty, family != "SF Mono", !families.contains(family) {
                Text(family).tag(family)
            }
            Divider()
            ForEach(families, id: \.self) { family in
                Text(family).tag(family)
            }
        }
        .labelsHidden()
        .frame(width: 190)
    }

    private var familyBinding: Binding<String> {
        Binding(
            get: { spec.family ?? "" },
            set: { spec.family = $0.isEmpty ? nil : $0 }
        )
    }

    private var previewFont: NSFont {
        SettingsStore.nsFont(FontSpec(family: spec.family, size: spec.size * scale), monospaced: role == .code)
    }

    private var sample: String {
        switch role {
        case .input: "Ask anything, or drop an image here…"
        case .userMessage: "Can you explain how attention works?"
        case .assistantMessage: "Attention lets each token weigh every other token."
        case .thinking: "The user wants a short explanation, so start with the intuition…"
        case .code: "func greet(_ name: String) -> String { \"Hi, \\(name)\" }"
        case .metrics: "1,234 tokens · 42.1 tok/s · prompt 512 tok/s"
        }
    }
}

// MARK: - Chat

private struct ChatSettingsTab: View {
    @Binding var settings: AppSettings

    var body: some View {
        Form {
            thinkingSection
            displaySection
            attachmentsSection
            Section("Generation") {
                Toggle("Offer Continue for stopped or cut-off replies", isOn: $settings.enableContinue)
            }
        }
        .formStyle(.grouped)
    }

    private var thinkingSection: some View {
        Section("Thinking") {
            Picker("Thinking blocks", selection: $settings.thinkingDisplay) {
                Text("Open while thinking, then collapse").tag(ThinkingDisplay.collapseWhenDone)
                Text("Always expanded").tag(ThinkingDisplay.alwaysExpanded)
                Text("Always collapsed").tag(ThinkingDisplay.alwaysCollapsed)
            }
            Toggle("Render thinking as Markdown", isOn: $settings.renderThinkingAsMarkdown)
        }
    }

    private var displaySection: some View {
        Section("Messages") {
            Toggle("Render your messages as Markdown", isOn: $settings.renderUserMessagesAsMarkdown)
            Toggle("Render math (LaTeX)", isOn: $settings.renderMath)
            Toggle("Show speed and token statistics", isOn: $settings.showMessageStats)
            Toggle("Show statistics for each agent turn", isOn: $settings.showAgenticTurnStats)
                .disabled(!settings.showMessageStats)
            Toggle("Expand tool calls", isOn: $settings.alwaysExpandToolCalls)
            Toggle("Show code blocks at full height", isOn: $settings.fullHeightCodeBlocks)
            Toggle("Don't scroll automatically while generating", isOn: $settings.disableAutoScroll)
        }
    }

    private var attachmentsSection: some View {
        Section {
            Picker("Resize images to", selection: $settings.maxImageMegapixels) {
                Text("1 megapixel").tag(1.0)
                Text("2 megapixels").tag(2.0)
                Text("4 megapixels").tag(4.0)
                Text("8 megapixels").tag(8.0)
                Text("16 megapixels").tag(16.0)
                Text("Original size").tag(0.0)
            }
            Toggle("Send PDFs as page images (for vision models)", isOn: $settings.pdfAsImages)
            Picker("Paste long text as a file", selection: $settings.pasteLongTextToFileLength) {
                Text("Over 1,000 characters").tag(1000)
                Text("Over 2,500 characters").tag(2500)
                Text("Over 5,000 characters").tag(5000)
                Text("Over 10,000 characters").tag(10_000)
                Text("Never").tag(0)
                if ![0, 1000, 2500, 5000, 10_000].contains(settings.pasteLongTextToFileLength) {
                    Text("Over \(settings.pasteLongTextToFileLength) characters").tag(settings.pasteLongTextToFileLength)
                }
            }
        } header: {
            Text("Attachments")
        } footer: {
            Text("Smaller images use fewer tokens and are processed faster.")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Tools & MCP

private struct ToolsSettingsTab: View {
    @Binding var settings: AppSettings
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Section {
                Stepper(value: $settings.maxAgenticTurns, in: 1...1000) {
                    LabeledContent("Turns before asking to continue", value: "\(settings.maxAgenticTurns)")
                }
            } header: {
                Text("Agent")
            } footer: {
                Text("A turn is one model reply that calls tools. When the limit is reached, goooeee asks before going on.")
                    .foregroundStyle(.secondary)
            }
            Section("MCP") {
                secondsField("Tool call timeout", value: $settings.mcpRequestTimeoutSeconds)
                secondsField("Connection timeout", value: $settings.mcpHandshakeTimeoutSeconds)
            }
            Section {
                Stepper(value: $settings.toolLogRetentionDays, in: 1...365) {
                    LabeledContent("Keep the tool call log for", value: "\(settings.toolLogRetentionDays) day\(settings.toolLogRetentionDays == 1 ? "" : "s")")
                }
            } header: {
                Text("Log")
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.mcpHandshakeTimeoutSeconds) { _, seconds in
            Task { await app.mcpHost.setHandshakeTimeout(seconds) }
        }
    }

    private func secondsField(_ title: String, value: Binding<Double>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField("", value: value, format: .number.precision(.fractionLength(0)))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                    .labelsHidden()
                Text("seconds").foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Terminal

private struct TerminalSettingsTab: View {
    @Binding var settings: AppSettings
    @State private var monospacedFamilies: [String] = []

    var body: some View {
        Form {
            Section {
                TextField("Shell", text: $settings.terminalShell.emptyAsNil(), prompt: Text(ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"))
                    .font(.system(.body, design: .monospaced))
            } header: {
                Text("Shell")
            } footer: {
                Text("Empty uses your login shell. Each workspace window has its own terminal (⌘`).")
                    .foregroundStyle(.secondary)
            }
            Section("Font") {
                Picker("Family", selection: familyBinding) {
                    Text("SF Mono").tag("SF Mono")
                    ForEach(monospacedFamilies, id: \.self) { Text($0).tag($0) }
                    if !monospacedFamilies.contains(familyBinding.wrappedValue), familyBinding.wrappedValue != "SF Mono" {
                        Text(familyBinding.wrappedValue).tag(familyBinding.wrappedValue)
                    }
                }
                Stepper(value: $settings.terminalFont.size, in: 8...32, step: 0.5) {
                    LabeledContent("Size", value: settings.terminalFont.size.formatted(.number.precision(.fractionLength(0...1))) + " pt")
                }
            }
            Section("Scrollback") {
                Picker("Lines kept", selection: $settings.terminalScrollback) {
                    Text("1,000").tag(1000)
                    Text("10,000").tag(10_000)
                    Text("50,000").tag(50_000)
                    Text("100,000").tag(100_000)
                    if ![1000, 10_000, 50_000, 100_000].contains(settings.terminalScrollback) {
                        Text("\(settings.terminalScrollback)").tag(settings.terminalScrollback)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { monospacedFamilies = Self.loadMonospacedFamilies() }
    }

    private var familyBinding: Binding<String> {
        Binding(
            get: { settings.terminalFont.family ?? "SF Mono" },
            set: { settings.terminalFont.family = $0 }
        )
    }

    private static func loadMonospacedFamilies() -> [String] {
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        let families = Set(names.compactMap { NSFont(name: $0, size: 12)?.familyName }.filter { !$0.hasPrefix(".") })
        return families.sorted()
    }
}

// MARK: - Advanced

private struct AdvancedSettingsTab: View {
    @Binding var settings: AppSettings
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section {
                Toggle("Offer a raw output view for replies", isOn: $settings.showRawOutputToggle)
                Toggle("Don't separate thinking from the reply", isOn: $settings.disableReasoningParsing)
                Toggle("Leave earlier thinking out of the context", isOn: $settings.excludeReasoningFromContext)
            } header: {
                Text("Model output")
            } footer: {
                Text("Some models (e.g. MiniMax M2) expect their earlier thinking back; their profiles keep it whatever this says.")
                    .foregroundStyle(.secondary)
            }
            Section("Data") {
                LabeledContent("Database") {
                    Text(AppDatabase.defaultURL.path)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppDatabase.defaultURL])
                }
                Button("All goooeee Files…") {
                    UserDefaults.standard.set(HelpTopic.filesAndData.id, forKey: HelpView.topicKey)
                    openWindow(id: WindowID.help)
                }
            }
            Section {
                Button("Reset All Settings…", role: .destructive) { confirmReset = true }
            } footer: {
                Text("Resets fonts and preferences. Connections, workspaces, chats and MCP servers are kept.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset all settings to their defaults?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { app.settingsStore.resetToDefaults() }
            Button("Cancel", role: .cancel) {}
        }
    }
}
