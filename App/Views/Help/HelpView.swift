import AppKit
import GoooeeeCore
import SwiftUI

/// Help → goooeee Help (⌘?): topics on the left, the selected one on the right.
struct HelpView: View {
    /// Shared with the places that open Help at a topic (Settings → Advanced → All goooeee Files).
    @AppStorage(HelpView.topicKey) private var selection: String = HelpTopic.filesAndData.id
    @State private var query = ""

    static let topicKey = "goooeee.help.topic"

    var body: some View {
        NavigationSplitView {
            List(filteredTopics, selection: Binding(get: { selection }, set: { if let id = $0 { selection = id } })) { topic in
                Label(topic.title, systemImage: topic.symbol)
                    .tag(topic.id)
            }
            .searchable(text: $query, placement: .sidebar, prompt: "Search Help")
            .overlay {
                if filteredTopics.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .splitColumnSizing()
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
        } detail: {
            Group {
                if let topic = HelpTopic.topic(id: selection) {
                    HelpTopicView(topic: topic) { selection = $0 }
                        .id(topic.id)
                } else {
                    ContentUnavailableView("Choose a topic", systemImage: "questionmark.circle")
                }
            }
            .splitColumnSizing()
            .frame(minWidth: 480)
        }
        .navigationTitle("goooeee Help")
    }

    private var filteredTopics: [HelpTopic] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return HelpTopic.all }
        return HelpTopic.all.filter { topic in
            let text = topic.searchText
            return words.allSatisfy { text.contains($0) }
        }
    }
}

/// One topic, scrolled as a page.
private struct HelpTopicView: View {
    var topic: HelpTopic
    var open: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label(topic.title, systemImage: topic.symbol)
                    .font(.largeTitle.weight(.semibold))
                    .labelStyle(.titleAndIcon)
                Text(topic.summary)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)
                ForEach(Array(topic.blocks.enumerated()), id: \.offset) { _, block in
                    HelpBlockView(block: block)
                }
                if topic.id != HelpTopic.filesAndData.id {
                    Divider().padding(.top, 10)
                    Button("Where goooeee keeps its files →") { open(HelpTopic.filesAndData.id) }
                        .buttonStyle(.link)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct HelpBlockView: View {
    var block: HelpBlock

    var body: some View {
        switch block {
        case .heading(let text):
            Text(text)
                .font(.title2.weight(.semibold))
                .padding(.top, 10)
        case .text(let text):
            HelpText(text)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        HelpText(item)
                    }
                }
            }
        case .steps(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 18, alignment: .trailing)
                        HelpText(item)
                    }
                }
            }
        case .note(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                HelpText(text)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        case .shortcuts(let shortcuts):
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 6) {
                ForEach(shortcuts, id: \.self) { shortcut in
                    GridRow {
                        Text(shortcut.keys)
                            .font(.body.monospaced())
                            .gridColumnAlignment(.trailing)
                        Text(shortcut.action)
                    }
                }
            }
        case .fileLocations:
            FileLocationsView()
        case .workspaceFolders:
            WorkspaceFoldersView()
        case .backupCommands:
            CommandsBox(text: AppFiles.backupCommands)
        case .uninstallCommands:
            CommandsBox(text: AppFiles.uninstallCommands)
        }
    }
}

/// Inline Markdown (bold, code, links), wrapping.
private struct HelpText: View {
    var markdown: String

    init(_ markdown: String) {
        self.markdown = markdown
    }

    var body: some View {
        Text(attributed)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var attributed: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }
}

// MARK: - Files

private struct FileLocationsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(AppFiles.locations) { location in
                FileLocationRow(location: location)
            }
        }
    }
}

private struct FileLocationRow: View {
    var location: AppFiles.Location
    /// `nil` while measuring; `.some(nil)` when nothing exists there yet.
    @State private var size: Int64??

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(location.title).font(.headline)
                Spacer()
                sizeLabel
            }
            if let url = location.url {
                Text(AppFiles.displayPath(url) + (location.kind == .database ? " (+ -wal, -shm)" : ""))
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .padding(.leading, 26)
            } else {
                Text("Login keychain, name “\(AppFiles.keychainService)”")
                    .font(.system(.callout, design: .monospaced))
                    .padding(.leading, 26)
            }
            HelpText(location.contents)
                .padding(.leading, 26)
            HelpText(location.removal)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.leading, 26)
            HStack(spacing: 8) {
                if let url = location.url {
                    Button("Show in Finder") { AppFiles.reveal(location) }
                    CopyButton(text: { url.path }, label: "Copy Path", showsTitle: true)
                } else if let keychainAccess = AppFiles.keychainAccess {
                    Button("Open Keychain Access") {
                        NSWorkspace.shared.openApplication(at: keychainAccess, configuration: NSWorkspace.OpenConfiguration())
                    }
                }
            }
            .controlSize(.small)
            .padding(.leading, 26)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .task {
            let files = AppFiles.files(of: location)
            let measured = await Task.detached(priority: .utility) { AppFiles.size(of: files) }.value
            size = .some(measured)
        }
    }

    private var symbol: String {
        switch location.kind {
        case .folder: "folder"
        case .file: "doc"
        case .database: "cylinder.split.1x2"
        case .keychain: "key"
        }
    }

    @ViewBuilder
    private var sizeLabel: some View {
        switch location.kind {
        case .keychain:
            EmptyView()
        default:
            switch size {
            case .none:
                ProgressView().controlSize(.mini)
            case .some(.none):
                Text("Not created yet").font(.caption).foregroundStyle(.secondary)
            case .some(.some(let bytes)):
                Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct WorkspaceFoldersView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if app.workspaces.isEmpty {
            HelpText("No workspaces yet. New workspaces use your home folder.")
                .foregroundStyle(.secondary)
        } else {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(app.workspaces) { workspace in
                    let path = ((workspace.workingDirectory ?? NSHomeDirectory()) as NSString).expandingTildeInPath
                    GridRow {
                        Text(workspace.name)
                            .lineLimit(1)
                        Text((path as NSString).abbreviatingWithTildeInPath)
                            .font(.system(.callout, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Show") { NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true)) }
                            .controlSize(.small)
                    }
                }
            }
        }
    }
}

/// Shell commands with a Copy button.
private struct CommandsBox: View {
    var text: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            MonospacedBlock(text: text, maxHeight: 220)
            CopyButton(text: { text }, label: "Copy Commands", showsTitle: true)
                .controlSize(.small)
        }
    }
}
