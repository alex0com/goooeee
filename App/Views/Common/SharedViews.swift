import AppKit
import GoooeeeCore
import SwiftUI

// Small views shared by the workspace window, the inspector and the Connections window.

/// The connection status dot shown in the toolbar and in lists.
struct StatusDot: View {
    var status: ServerStatus
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay {
                if status == .starting || status == .loadingModel || status == .unknown {
                    Circle().stroke(color.opacity(0.5), lineWidth: 2).scaleEffect(1.8).opacity(0.6)
                }
            }
            .help(helpText)
            .accessibilityLabel(status.label)
    }

    private var color: Color {
        switch status {
        case .online: .green
        case .offline: .red
        case .starting, .loadingModel: .orange
        case .unknown: .gray
        }
    }

    private var helpText: String {
        if case .offline(let reason) = status, !reason.isEmpty { return "Offline: \(reason)" }
        return status.label
    }
}

/// Where a setting's value comes from ("you", "profile", "server").
struct SourceBadge: View {
    var source: SettingSource

    var body: some View {
        Text(source.isUser ? (source == .chat ? "chat" : source == .workspace ? "workspace" : "connection") : source.label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(background, in: Capsule())
            .foregroundStyle(source.isUser ? Color.accentColor : .secondary)
            .help(help)
    }

    private var background: Color {
        source.isUser ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.12)
    }

    private var help: String {
        switch source {
        case .chat: "Set for this chat"
        case .workspace: "Set for this workspace"
        case .connection: "Set on the connection"
        case .profile: "Recommended by the model profile"
        case .server: "The server's own default (not sent)"
        }
    }
}

/// A button that copies text and briefly shows a checkmark.
struct CopyButton: View {
    var text: () -> String
    var label: String = "Copy"
    var showsTitle = false
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text(), forType: .string)
            copied = true
            Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                copied = false
            }
        } label: {
            if showsTitle {
                Label(copied ? "Copied" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
            } else {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
        }
        .help(label)
    }
}

/// The thinking level menu used in the composer and the inspector.
struct ThinkingPicker: View {
    @Binding var level: ThinkingLevel?
    /// The level used when nothing is set here (shown as "Default (…)").
    var inherited: ThinkingLevel
    var compact = false

    var body: some View {
        Menu {
            Picker("Thinking", selection: $level) {
                Text("Default" + (inherited == .default ? "" : " (\(inherited.label))")).tag(ThinkingLevel?.none)
                Divider()
                ForEach(ThinkingLevel.allCases.filter { $0 != .default }) { level in
                    Text(level.label).tag(Optional(level))
                }
            }
            .pickerStyle(.inline)
        } label: {
            if compact {
                Label(title, systemImage: "brain")
            } else {
                Text(title)
            }
        }
        .menuIndicator(compact ? .hidden : .visible)
        .fixedSize()
        .help("Thinking (reasoning) level")
    }

    private var title: String {
        let effective = level ?? inherited
        return effective == .default ? "Thinking" : "Thinking: \(effective.label)"
    }
}

// MARK: - Sampling editor

/// Edits one settings layer (connection, workspace or chat). Unset values show what they inherit.
struct SamplingEditor: View {
    @Binding var values: SamplingSettings
    /// Effective settings for showing inherited values and their source.
    var effective: EffectiveSettings?
    /// Keys the engine accepts. Others are hidden unless they're set.
    var supportedKeys: Set<SamplingKey>
    @State private var showAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(basicKeys) { key in
                SamplingRow(key: key, value: binding(for: key), inherited: inherited(for: key))
            }
            if !advancedKeys.isEmpty {
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(advancedKeys) { key in
                            SamplingRow(key: key, value: binding(for: key), inherited: inherited(for: key))
                        }
                    }
                    .padding(.top, 6)
                }
            }
            if !values.isEmpty {
                Button("Reset All") { values = SamplingSettings() }
                    .controlSize(.small)
            }
        }
    }

    private var visibleKeys: [SamplingKey] {
        SamplingKey.displayOrder.filter { supportedKeys.contains($0) || values[$0] != nil }
    }

    private var basicKeys: [SamplingKey] { visibleKeys.filter { !$0.isAdvanced } }
    private var advancedKeys: [SamplingKey] { visibleKeys.filter(\.isAdvanced) }

    private func binding(for key: SamplingKey) -> Binding<SamplingValue?> {
        Binding(get: { values[key] }, set: { values[key] = $0 })
    }

    /// What applies when this layer leaves the key unset (only shown when it came from a lower layer).
    private func inherited(for key: SamplingKey) -> ResolvedValue? {
        guard let resolved = effective?[key] else { return nil }
        return resolved
    }
}

/// One sampling parameter: set value with controls, or the inherited value with a "Set" action.
struct SamplingRow: View {
    var key: SamplingKey
    @Binding var value: SamplingValue?
    var inherited: ResolvedValue?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(key.label)
                    .help(key.help)
                Spacer(minLength: 4)
                if let value {
                    editor(for: value)
                    Button {
                        self.value = nil
                    } label: {
                        Image(systemName: "arrow.uturn.backward.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Use the inherited value")
                } else {
                    inheritedLabel
                }
            }
            if case .double(let range, let step) = key.kind, let current = value?.doubleValue {
                Slider(
                    value: Binding(get: { current }, set: { value = .double(($0 / step).rounded() * step) }),
                    in: range
                )
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var inheritedLabel: some View {
        HStack(spacing: 4) {
            if let inherited {
                Text(inherited.value.displayString)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                SourceBadge(source: inherited.source)
                if inherited.disagreesWithServer, let server = inherited.serverValue {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                        .help("The server's default is \(server.displayString)")
                }
            } else {
                Text("not sent").foregroundStyle(.tertiary)
            }
            Button("Set") {
                value = inherited?.value ?? defaultValue
            }
            .controlSize(.small)
        }
    }

    private var defaultValue: SamplingValue {
        switch key.kind {
        case .double(let range, _): .double(key == .temperature ? 0.7 : min(max(0.5, range.lowerBound), range.upperBound))
        case .int(let range): .int(max(0, range.lowerBound))
        case .bool: .bool(false)
        case .strings: .strings([])
        }
    }

    @ViewBuilder
    private func editor(for current: SamplingValue) -> some View {
        switch key.kind {
        case .double:
            TextField("", value: Binding(get: { current.doubleValue ?? 0 }, set: { value = .double($0) }), format: .number.precision(.fractionLength(0...3)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
                .monospacedDigit()
        case .int(let range):
            TextField("", value: Binding(
                get: { if case .int(let v) = current { v } else { Int(current.doubleValue ?? 0) } },
                set: { value = .int(min(max($0, range.lowerBound), range.upperBound)) }
            ), format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 72)
                .monospacedDigit()
        case .bool:
            Toggle("", isOn: Binding(get: { if case .bool(let v) = current { v } else { false } }, set: { value = .bool($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        case .strings:
            TextField(key == .samplers ? "e.g. top_k;top_p;temperature" : "one;per;stop", text: Binding(
                get: { if case .strings(let v) = current { v.joined(separator: ";") } else { "" } },
                set: { value = .strings($0.split(separator: ";", omittingEmptySubsequences: true).map(String.init)) }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 180)
        }
    }
}

// MARK: - Toast

struct ToastView: View {
    var toast: Toast
    var dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle")
                .foregroundStyle(toast.isError ? .orange : .secondary)
            Text(toast.message)
                .lineLimit(3)
                .textSelection(.enabled)
            if let title = toast.actionTitle, let action = toast.action {
                Button(title) {
                    action()
                    dismiss()
                }
                .buttonStyle(.borderless)
                .fontWeight(.semibold)
            }
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .task(id: toast.id) {
            // Errors stay longer; toasts with an action (Undo) stay long enough to use it.
            let seconds: UInt64 = toast.isError ? 8 : toast.action != nil ? 6 : 3
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            dismiss()
        }
    }
}

// MARK: - Helpers

extension View {
    /// A section header style used in inspectors and editors.
    func sectionHeader() -> some View {
        font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
    }

    /// Keeps a split view pane's min and max size constant, whatever its content. Use it on every
    /// pane of a `NavigationSplitView`, `.inspector`, `VSplitView` or `HSplitView`.
    ///
    /// The split view asks each pane for its min and max size during the window's constraint
    /// pass. If the answer changes there (a picker gains a longer model name, a badge appears
    /// after the server answers, the terminal title changes), AppKit re-runs the pass until it
    /// throws `_postWindowNeedsUpdateConstraints` and the app aborts. Pane sizes come from
    /// `navigationSplitViewColumnWidth`, `inspectorColumnWidth` or a `frame` applied after this.
    func splitColumnSizing() -> some View {
        frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }
}

extension NSPasteboard {
    static func copy(_ string: String) {
        general.clearContents()
        general.setString(string, forType: .string)
    }
}
