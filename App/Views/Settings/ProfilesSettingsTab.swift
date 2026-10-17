import AppKit
import GoooeeeCore
import SwiftUI
import UniformTypeIdentifiers

/// Model profiles: built-in ones are read-only; custom ones are edited as JSON and win over built-ins.
struct ProfilesSettingsTab: View {
    @Environment(AppModel.self) private var app
    @State private var selection: ProfileSelection?
    @State private var editorText = ""
    @State private var editorError: String?
    @State private var testModelID = ""
    @State private var notice: String?
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 220)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if selection == nil, let first = app.profiles.custom.first ?? app.profiles.builtIn.first {
                select(ProfileSelection(id: first.id, isCustom: first.isCustom))
            }
        }
        .alert("Profiles", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { selection }, set: { if let value = $0 { select(value) } })) {
                if !app.profiles.custom.isEmpty {
                    Section("Custom") {
                        ForEach(app.profiles.custom) { profile in
                            Text(profile.displayName).tag(ProfileSelection(id: profile.id, isCustom: true))
                        }
                    }
                }
                Section("Built-in") {
                    ForEach(app.profiles.builtIn) { profile in
                        Text(profile.displayName).tag(ProfileSelection(id: profile.id, isCustom: false))
                    }
                }
            }
            HStack(spacing: 4) {
                Button {
                    newProfile()
                } label: {
                    Image(systemName: "plus").frame(width: 20, height: 18)
                }
                .buttonStyle(.borderless)
                .help("New custom profile")
                Spacer()
                Menu {
                    Button("Import Profiles…") { importProfiles() }
                    Button("Export Custom Profiles…") { exportProfiles() }
                        .disabled(app.profiles.custom.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle").frame(width: 20, height: 18)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(8)
            .background(.bar)
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let selection, let profile = profile(for: selection) {
            VStack(alignment: .leading, spacing: 12) {
                header(profile)
                if selection.isCustom {
                    CodeTextEditor(text: $editorText, minHeight: 240)
                    if let editorError {
                        Label(editorError, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                    customActions(profile)
                } else {
                    MonospacedBlock(text: Self.json(for: profile))
                        .frame(maxHeight: .infinity)
                    HStack {
                        Text("Built-in profiles can't be edited. Duplicate one to change it; a custom profile with the same patterns wins.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Duplicate as Custom") { duplicate(profile) }
                    }
                }
                Divider()
                matchTester
            }
            .padding(16)
        } else {
            ContentUnavailableView("No Profile Selected", systemImage: "cpu")
        }
    }

    private func header(_ profile: ModelProfile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(profile.displayName).font(.title3.weight(.semibold))
                Text(profile.isCustom ? "Custom" : "Built-in")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }
            if !profile.match.isEmpty {
                Text("Matches model IDs like: " + profile.match.joined(separator: ", "))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let source = profile.source {
                Text("Source: \(source)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func customActions(_ profile: ModelProfile) -> some View {
        HStack {
            Button("Delete…", role: .destructive) { confirmDelete = true }
            Spacer()
            Button("Revert") { editorText = Self.json(for: profile); editorError = nil }
                .disabled(editorText == Self.json(for: profile))
            Button("Save") { saveEdited(originalID: profile.id) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(editorText == Self.json(for: profile))
        }
        .confirmationDialog("Delete the profile “\(profile.displayName)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { delete(profile) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var matchTester: some View {
        HStack {
            TextField("Test a model ID", text: $testModelID, prompt: Text("e.g. mlx-community/Qwen3-32B-4bit"))
                .textFieldStyle(.roundedBorder)
            if !testModelID.isEmpty {
                let matched = app.profiles.match(modelID: testModelID)
                Text("→ " + (matched?.displayName ?? "Generic (no match)"))
                    .foregroundStyle(matched == nil ? HierarchicalShapeStyle.secondary : HierarchicalShapeStyle.primary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: Model

    private func profile(for selection: ProfileSelection) -> ModelProfile? {
        (selection.isCustom ? app.profiles.custom : app.profiles.builtIn).first { $0.id == selection.id }
    }

    private func select(_ value: ProfileSelection) {
        selection = value
        editorError = nil
        if let profile = profile(for: value) { editorText = Self.json(for: profile) }
    }

    static func json(for profile: ModelProfile) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(profile) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private func uniqueID(_ base: String) -> String {
        let taken = Set(app.profiles.all.map(\.id))
        var id = base
        var counter = 2
        while taken.contains(id) {
            id = "\(base)-\(counter)"
            counter += 1
        }
        return id
    }

    private func newProfile() {
        let profile = ModelProfile(
            id: uniqueID("my-model"),
            displayName: "My model",
            match: ["my-model"],
            reasoning: .auto,
            sampling: ProfileSampling(standard: SamplingSettings([.temperature: .double(0.7), .topP: .double(0.95)])),
            isCustom: true
        )
        save(app.profiles.custom + [profile], select: profile.id)
    }

    private func duplicate(_ profile: ModelProfile) {
        var copy = profile
        copy.id = uniqueID(profile.id + "-custom")
        copy.displayName = profile.displayName + " (custom)"
        copy.isCustom = true
        save(app.profiles.custom + [copy], select: copy.id)
    }

    private func saveEdited(originalID: String) {
        let decoded: ModelProfile
        do {
            decoded = try JSONDecoder().decode(ModelProfile.self, from: Data(editorText.utf8))
        } catch {
            editorError = "Not a valid profile: \(error.localizedDescription)"
            return
        }
        if decoded.id != originalID, app.profiles.custom.contains(where: { $0.id == decoded.id }) {
            editorError = "Another custom profile already has the id “\(decoded.id)”."
            return
        }
        for pattern in decoded.match where (try? NSRegularExpression(pattern: pattern)) == nil {
            editorError = "“\(pattern)” isn't a valid regular expression."
            return
        }
        var custom = app.profiles.custom
        if let index = custom.firstIndex(where: { $0.id == originalID }) {
            custom[index] = decoded
        } else {
            custom.append(decoded)
        }
        editorError = nil
        save(custom, select: decoded.id)
    }

    private func delete(_ profile: ModelProfile) {
        let remaining = app.profiles.custom.filter { $0.id != profile.id }
        Task {
            await app.saveCustomProfiles(remaining)
            if let first = app.profiles.custom.first ?? app.profiles.builtIn.first {
                select(ProfileSelection(id: first.id, isCustom: first.isCustom))
            } else {
                selection = nil
            }
        }
    }

    private func save(_ custom: [ModelProfile], select id: String) {
        Task {
            await app.saveCustomProfiles(custom)
            select(ProfileSelection(id: id, isCustom: true))
        }
    }

    private func importProfiles() {
        guard let url = EditorPanels.chooseFile(types: [.json], message: "Choose a profiles JSON file") else { return }
        do {
            let data = try Data(contentsOf: url)
            let imported: [ModelProfile]
            if let file = try? ProfileRegistry.decodeProfiles(data) {
                imported = file
            } else if let list = try? JSONDecoder().decode([ModelProfile].self, from: data) {
                imported = list
            } else {
                imported = [try JSONDecoder().decode(ModelProfile.self, from: data)]
            }
            var custom = app.profiles.custom
            for profile in imported {
                if let index = custom.firstIndex(where: { $0.id == profile.id }) {
                    custom[index] = profile
                } else {
                    custom.append(profile)
                }
            }
            let firstID = imported.first?.id
            Task {
                await app.saveCustomProfiles(custom)
                if let firstID { select(ProfileSelection(id: firstID, isCustom: true)) }
                notice = "Imported \(imported.count) profile\(imported.count == 1 ? "" : "s")."
            }
        } catch {
            notice = "Couldn't import: \(error.localizedDescription)"
        }
    }

    private func exportProfiles() {
        guard let url = EditorPanels.saveFile(named: "goooeee-profiles.json", type: .json) else { return }
        do {
            try ProfileRegistry.encodeProfiles(app.profiles.custom).write(to: url, options: .atomic)
        } catch {
            notice = "Couldn't export: \(error.localizedDescription)"
        }
    }
}

/// A row in the profile list. Custom and built-in profiles may share an id.
struct ProfileSelection: Hashable {
    var id: String
    var isCustom: Bool
}
