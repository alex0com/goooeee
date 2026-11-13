import GoooeeeCore
import SwiftUI

/// How models are named in a list.
enum ModelNameStyle {
    /// The ID as the server lists it, e.g. `google/gemini-4-carbon`.
    case fullID
    /// The name after the last slash, with the full ID underneath.
    case shortName
}

/// A server's models with a search field: type to filter, ↑↓ to move, Return to choose.
struct ModelSearchList<Footer: View>: View {
    var models: [RemoteModel]
    var selectedID: String?
    var nameStyle: ModelNameStyle = .fullID
    var emptyMessage = "The server lists no models."
    var onPick: (String) -> Void
    @ViewBuilder var footer: () -> Footer

    @State private var query = ""
    @State private var highlighted: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        let results = self.results
        VStack(spacing: 0) {
            searchField(results)
            Divider()
            if models.isEmpty {
                message(emptyMessage)
            } else if results.isEmpty {
                message("No models match “\(query)”.")
            } else {
                list(results)
            }
            Divider()
            HStack(spacing: 8) {
                footer()
                Spacer(minLength: 8)
                if !models.isEmpty {
                    Text(results.count == models.count ? "\(models.count) models" : "\(results.count) of \(models.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .frame(width: 460, height: 400)
        .onAppear {
            highlighted = selectedID
            searchFocused = true
        }
        .onChange(of: query) { _, _ in highlighted = self.results.first?.id }
    }

    private func searchField(_ results: [RemoteModel]) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search models", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit {
                    if let id = highlighted.flatMap({ id in results.first { $0.id == id }?.id }) ?? results.first?.id { onPick(id) }
                }
                .onKeyPress(.downArrow) { move(1, in: results); return .handled }
                .onKeyPress(.upArrow) { move(-1, in: results); return .handled }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear the search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func list(_ results: [RemoteModel]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(results) { model in
                        row(model).id(model.id)
                    }
                }
                .padding(4)
            }
            .onAppear {
                if let selectedID { proxy.scrollTo(selectedID, anchor: .center) }
            }
            .onChange(of: highlighted) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private func row(_ model: RemoteModel) -> some View {
        Button {
            onPick(model.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .opacity(model.id == selectedID ? 1 : 0)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(nameStyle == .shortName ? model.displayName : model.id)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if nameStyle == .shortName, model.displayName != model.id {
                        Text(model.id)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                if let state = model.loadState, state != .unknown {
                    Text(state.rawValue)
                        .font(.caption)
                        .foregroundStyle(state == .loaded ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(model.id == highlighted ? Color.accentColor.opacity(0.22) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { highlighted = model.id }
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Sorted for the name style, then filtered: every word of the query must appear in the ID.
    private var results: [RemoteModel] {
        let sorted = nameStyle == .shortName
            ? ModelNameFormatter.sortedByShortName(models, id: \.id)
            : models.sorted { ModelNameFormatter.precedes($0.id, $1.id) }
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return sorted }
        return sorted.filter { model in
            let id = model.id.lowercased()
            return terms.allSatisfy { id.contains($0) }
        }
    }

    private func move(_ step: Int, in results: [RemoteModel]) {
        guard !results.isEmpty else { return }
        let current = highlighted.flatMap { id in results.firstIndex { $0.id == id } }
        let next = current.map { min(max($0 + step, 0), results.count - 1) } ?? (step > 0 ? 0 : results.count - 1)
        highlighted = results[next].id
    }
}

extension ModelSearchList where Footer == EmptyView {
    init(models: [RemoteModel], selectedID: String?, nameStyle: ModelNameStyle = .fullID, emptyMessage: String = "The server lists no models.", onPick: @escaping (String) -> Void) {
        self.init(models: models, selectedID: selectedID, nameStyle: nameStyle, emptyMessage: emptyMessage, onPick: onPick) { EmptyView() }
    }
}

/// A field-like button showing the chosen model; clicking it opens the searchable list.
struct ModelSearchPicker: View {
    var models: [RemoteModel]
    var selectedID: String?
    var nameStyle: ModelNameStyle = .fullID
    var placeholder = "Choose a model"
    var emptyMessage = "The server lists no models."
    var onPick: (String) -> Void
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Text(label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(selectedID == nil ? .secondary : .primary)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .help(selectedID ?? placeholder)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ModelSearchList(models: models, selectedID: selectedID, nameStyle: nameStyle, emptyMessage: emptyMessage) { id in
                isPresented = false
                onPick(id)
            }
        }
    }

    private var label: String {
        guard let selectedID else { return placeholder }
        return nameStyle == .shortName ? ModelNameFormatter.shortName(selectedID) : selectedID
    }
}
