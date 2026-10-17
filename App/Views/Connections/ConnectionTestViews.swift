import AppKit
import GoooeeeCore
import SwiftUI

// MARK: - Test

/// Runs the connection checks against the settings as shown (including unsaved edits).
struct ConnectionTestTab: View {
    var connection: ServerConnection
    var apiKey: String
    var onFinished: @MainActor (ConnectionTestSummary) -> Void
    @Environment(AppModel.self) private var app
    @State private var modelID = ""
    @State private var testVision = false
    @State private var testToolCalling = false
    @State private var steps: [ConnectionTestStep] = []
    @State private var runTask: Task<Void, Never>?
    @State private var summary: ConnectionTestSummary?

    var body: some View {
        Form {
            optionsSection
            if !steps.isEmpty {
                resultsSection
            } else if let last = connection.lastTest {
                Section("Last test") {
                    SummaryLabel(summary: last)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if modelID.isEmpty { modelID = connection.defaultModelID ?? "" }
        }
        .onDisappear { runTask?.cancel() }
    }

    private var isRunning: Bool { runTask != nil }

    private var optionsSection: some View {
        Section {
            TextField("Model", text: $modelID, prompt: Text("The server's first model"))
            Toggle("Send an image (vision)", isOn: $testVision)
            Toggle("Ask for a tool call", isOn: $testToolCalling)
            HStack {
                if isRunning {
                    ProgressView().controlSize(.small)
                    Text("Testing…").foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop") { stop() }
                } else {
                    Spacer()
                    Button("Run Test") { run() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
        } header: {
            Text("Test")
        } footer: {
            Text("Checks reachability, authentication, the model list, server capabilities and a short streamed reply, using the settings as they are now, even unsaved.")
                .foregroundStyle(.secondary)
        }
    }

    private var resultsSection: some View {
        Section {
            ForEach(steps) { step in
                TestStepRow(step: step)
            }
        } header: {
            HStack {
                Text("Results")
                Spacer()
                if let summary { SummaryLabel(summary: summary) }
            }
        }
    }

    private func run() {
        runTask?.cancel()
        summary = nil
        steps = []
        let tester = ConnectionTester(connection: connection, apiKey: apiKey.isEmpty ? nil : apiKey, profiles: app.profiles)
        let options = ConnectionTester.Options(
            modelID: modelID.isEmpty ? nil : modelID,
            testVision: testVision,
            testToolCalling: testToolCalling
        )
        runTask = Task {
            for await snapshot in tester.run(options) {
                guard !Task.isCancelled else { break }
                steps = snapshot
            }
            // A stopped or replaced run leaves `runTask` to whoever cancelled it.
            guard !Task.isCancelled else { return }
            runTask = nil
            guard !steps.isEmpty else { return }
            let result = ConnectionTester.summary(of: steps)
            summary = result
            onFinished(result)
        }
    }

    private func stop() {
        runTask?.cancel()
        runTask = nil
    }
}

private struct SummaryLabel: View {
    var summary: ConnectionTestSummary

    var body: some View {
        Label {
            Text(summary.message)
                .lineLimit(2)
                .help("\(summary.date.formatted(date: .abbreviated, time: .shortened)): \(summary.message)")
        } icon: {
            Image(systemName: summary.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(summary.passed ? Color.green : Color.red)
        }
    }
}

/// One check: status, detail, hint and the request/response behind it.
private struct TestStepRow: View {
    var step: ConnectionTestStep

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                statusIcon
                    .frame(width: 18)
                Text(step.title).fontWeight(.medium)
                Spacer()
                if let ms = step.durationMs {
                    Text(MetricsFormatter.duration(ms: ms))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if !step.detail.isEmpty {
                Text(step.detail)
                    .font(.callout)
                    .foregroundStyle(step.status == .failed ? Color.red : .secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 26)
            }
            if let hint = step.hint {
                Label(hint, systemImage: "lightbulb")
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(.leading, 26)
            }
            if step.request != nil || step.response != nil {
                DisclosureGroup("Request and response") {
                    exchange
                }
                .font(.callout)
                .padding(.leading, 26)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch step.status {
        case .pending:
            Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
        case .running:
            ProgressView().controlSize(.small)
        case .passed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .skipped:
            Image(systemName: "minus.circle").foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var exchange: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let request = step.request {
                HStack {
                    Text("Request").sectionHeader()
                    Spacer()
                    CopyButton(text: { request }, label: "Copy curl command")
                        .buttonStyle(.borderless)
                }
                MonospacedBlock(text: request, maxHeight: 160)
            }
            if let response = step.response {
                HStack {
                    Text("Response").sectionHeader()
                    Spacer()
                    CopyButton(text: { response }, label: "Copy response")
                        .buttonStyle(.borderless)
                }
                MonospacedBlock(text: response, maxHeight: 200)
            }
        }
        .padding(.top, 4)
    }
}

// MARK: - curl

/// Ready-to-run curl commands for this connection, built from the same code as real requests.
struct ConnectionCurlTab: View {
    var connection: ServerConnection
    var apiKey: String
    @Environment(AppModel.self) private var app
    @State private var revealKey = false

    var body: some View {
        Form {
            Section {
                if !apiKey.isEmpty {
                    Toggle("Show the API key in commands", isOn: $revealKey)
                }
                Text(keyNote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(examples) { example in
                CurlExampleSection(example: example)
            }
        }
        .formStyle(.grouped)
    }

    private var keyNote: String {
        if apiKey.isEmpty && !connection.engine.requiresAPIKey {
            return "Commands use the connection's model, sampling and thinking settings, as goooeee sends them."
        }
        return revealKey
            ? "Commands include your API key. Be careful where you paste them."
            : "Commands read the key from \(CurlRenderer.keyPlaceholder). Run export GOOOEEE_API_KEY=… in your shell first."
    }

    private var examples: [CurlExample] {
        let profile = app.profiles.resolve(modelID: connection.defaultModelID, explicitID: connection.profileID)
        let settings = (try? SettingsResolver(connection: connection, profile: profile).resolve()) ?? EffectiveSettings(profile: profile)
        return CurlRenderer.examples(
            connection: connection,
            apiKey: apiKey.isEmpty ? nil : apiKey,
            model: connection.defaultModelID,
            settings: settings,
            revealKey: revealKey
        )
    }
}

private struct CurlExampleSection: View {
    var example: CurlExample

    var body: some View {
        Section {
            MonospacedBlock(text: example.command, maxHeight: 240)
            if let note = example.note {
                Label(note, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text(example.title)
                Spacer()
                CopyButton(text: { example.command }, label: "Copy", showsTitle: true)
                    .buttonStyle(.borderless)
            }
        }
    }
}
