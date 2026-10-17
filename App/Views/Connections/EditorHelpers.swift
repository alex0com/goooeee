import AppKit
import GoooeeeCore
import SwiftUI
import UniformTypeIdentifiers

// Form helpers shared by the Connections, MCP Servers and Settings windows.

/// Edits a string dictionary as rows of name and value fields (headers, environment variables).
///
/// Rows are local state seeded once from the binding; give the view a new `.id` to reload it
/// after the binding changes from outside (e.g. Revert).
struct KeyValueListEditor: View {
    @Binding var pairs: [String: String]
    var keyPlaceholder = "Name"
    var valuePlaceholder = "Value"
    var addTitle = "Add"
    @State private var rows: [KeyValueRow] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($rows) { $row in
                HStack(spacing: 6) {
                    TextField(keyPlaceholder, text: $row.key)
                        .frame(maxWidth: 220)
                    TextField(valuePlaceholder, text: $row.value)
                    Button {
                        rows.removeAll { $0.id == row.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove")
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .labelsHidden()
            }
            Button {
                rows.append(KeyValueRow(key: "", value: ""))
            } label: {
                Label(addTitle, systemImage: "plus")
            }
            .buttonStyle(.borderless)
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            rows = pairs.sorted { $0.key < $1.key }.map { KeyValueRow(key: $0.key, value: $0.value) }
        }
        .onChange(of: rows) { _, newRows in
            let entries = newRows.compactMap { row -> (String, String)? in
                let key = row.key.trimmingCharacters(in: .whitespaces)
                return key.isEmpty ? nil : (key, row.value)
            }
            let dictionary = Dictionary(entries, uniquingKeysWith: { _, last in last })
            if dictionary != pairs { pairs = dictionary }
        }
    }
}

struct KeyValueRow: Identifiable, Hashable {
    let id = UUID()
    var key: String
    var value: String
}

/// Auto / Yes / No for optional capability overrides.
struct TriStatePicker: View {
    var title: String
    @Binding var value: Bool?
    var autoLabel = "Auto-detect"

    var body: some View {
        Picker(title, selection: $value) {
            Text(autoLabel).tag(Bool?.none)
            Text("Yes").tag(Bool?.some(true))
            Text("No").tag(Bool?.some(false))
        }
    }
}

/// A monospaced multi-line editor with a minimum height, for commands, JSON and templates.
struct CodeTextEditor: View {
    @Binding var text: String
    var minHeight: CGFloat = 90

    var body: some View {
        TextEditor(text: $text)
            .font(.system(.callout, design: .monospaced))
            .autocorrectionDisabled()
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
            .frame(minHeight: minHeight)
    }
}

/// Selectable monospaced text in a box, for commands, schemas and logs.
struct MonospacedBlock: View {
    var text: String
    var maxHeight: CGFloat? = nil

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: maxHeight)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
    }
}

extension Binding where Value == String? {
    /// A text binding where an empty string means `nil`.
    func emptyAsNil() -> Binding<String> {
        Binding<String>(
            get: { self.wrappedValue ?? "" },
            set: { self.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }
}

/// Open and save panels used by the editors.
@MainActor
enum EditorPanels {
    static func chooseDirectory(startingAt path: String?) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if let path, !path.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    static func chooseFile(types: [UTType], message: String? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = types
        if let message { panel.message = message }
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func saveFile(named name: String, type: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}
