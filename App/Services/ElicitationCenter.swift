import AppKit
import GoooeeeCore
import GoooeeeMCP
import Observation
import SwiftUI

/// Shows MCP elicitation forms: a server asks the user for structured input mid-task.
///
/// Requests are queued and shown one at a time in a floating panel built from the request's JSON
/// schema. Closing the panel cancels the request.
@MainActor
final class ElicitationCenter: NSObject, NSWindowDelegate {
    static let shared = ElicitationCenter()

    private struct Pending {
        var serverName: String
        var message: String
        var schema: JSONValue
        var continuation: CheckedContinuation<MCPElicitationResponse, Never>
    }

    private var queue: [Pending] = []
    private var current: Pending?
    private var panel: NSPanel?

    func request(serverName: String, message: String, schema: JSONValue) async -> MCPElicitationResponse {
        await withCheckedContinuation { continuation in
            queue.append(Pending(serverName: serverName, message: message, schema: schema, continuation: continuation))
            showNext()
        }
    }

    private func showNext() {
        guard current == nil, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        current = next
        let form = ElicitationForm(schema: next.schema)
        let view = ElicitationView(serverName: next.serverName, message: next.message, form: form) { [weak self] response in
            self?.finish(response)
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "\(next.serverName) needs information"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentViewController = NSHostingController(rootView: view)
        panel.delegate = self
        panel.center()
        self.panel = panel
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        if !NSApp.isActive { NSApp.requestUserAttention(.criticalRequest) }
    }

    private func finish(_ response: MCPElicitationResponse) {
        guard let request = current else { return }
        current = nil
        let closing = panel
        panel = nil
        closing?.delegate = nil
        closing?.close()
        request.continuation.resume(returning: response)
        showNext()
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSPanel) === panel else { return }
        finish(.cancel)
    }
}

// MARK: - Form model

/// One field of an elicitation form, read from a `properties` entry of the schema.
struct ElicitationField: Identifiable {
    enum Kind {
        case text(format: String?, minLength: Int?, maxLength: Int?)
        case number(minimum: Double?, maximum: Double?, isInteger: Bool)
        case boolean
        case choice([Option])
        case multiChoice([Option], minItems: Int?, maxItems: Int?)
    }

    struct Option: Hashable {
        var value: String
        var title: String
    }

    var id: String
    var title: String
    var description: String?
    var isRequired: Bool
    var kind: Kind
}

/// Field values and validation for one elicitation request.
@MainActor
@Observable
final class ElicitationForm {
    let fields: [ElicitationField]
    var text: [String: String] = [:]
    var flags: [String: Bool] = [:]
    var selections: [String: Set<String>] = [:]
    var dates: [String: Date] = [:]
    private(set) var errors: [String: String] = [:]

    init(schema: JSONValue) {
        let properties = schema["properties"]?.objectValue ?? [:]
        let required = schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        // Required fields first, in the schema's order, then the rest alphabetically.
        let names = required.filter { properties[$0] != nil } + properties.keys.filter { !required.contains($0) }.sorted()
        fields = names.compactMap { name in
            guard let property = properties[name] else { return nil }
            return Self.field(name: name, property: property, required: required.contains(name))
        }
        for field in fields {
            applyDefault(properties[field.id]?["default"], to: field)
        }
    }

    private static func field(name: String, property: JSONValue, required: Bool) -> ElicitationField {
        let title = property["title"]?.stringValue ?? name
        let description = property["description"]?.stringValue
        let type = property["type"]?.stringValue ?? "string"
        let kind: ElicitationField.Kind
        if let options = options(in: property) {
            kind = .choice(options)
        } else if type == "array", let items = property["items"], let options = options(in: items) {
            kind = .multiChoice(options, minItems: property["minItems"]?.intValue, maxItems: property["maxItems"]?.intValue)
        } else {
            switch type {
            case "boolean":
                kind = .boolean
            case "number", "integer":
                kind = .number(minimum: property["minimum"]?.doubleValue, maximum: property["maximum"]?.doubleValue, isInteger: type == "integer")
            default:
                kind = .text(format: property["format"]?.stringValue, minLength: property["minLength"]?.intValue, maxLength: property["maxLength"]?.intValue)
            }
        }
        return ElicitationField(id: name, title: title, description: description, isRequired: required, kind: kind)
    }

    /// `enum` (+ optional `enumNames`), or `oneOf`/`anyOf` with `const` and `title`.
    private static func options(in property: JSONValue) -> [ElicitationField.Option]? {
        if let values = property["enum"]?.arrayValue?.compactMap(\.stringValue), !values.isEmpty {
            let names = property["enumNames"]?.arrayValue?.compactMap(\.stringValue) ?? []
            return values.enumerated().map { index, value in
                ElicitationField.Option(value: value, title: index < names.count ? names[index] : value)
            }
        }
        if let list = (property["oneOf"] ?? property["anyOf"])?.arrayValue {
            let options = list.compactMap { entry -> ElicitationField.Option? in
                guard let value = entry["const"]?.stringValue else { return nil }
                return ElicitationField.Option(value: value, title: entry["title"]?.stringValue ?? value)
            }
            return options.isEmpty ? nil : options
        }
        return nil
    }

    private func applyDefault(_ value: JSONValue?, to field: ElicitationField) {
        switch field.kind {
        case .boolean:
            flags[field.id] = value?.boolValue ?? false
        case .multiChoice:
            selections[field.id] = Set(value?.arrayValue?.compactMap(\.stringValue) ?? [])
        case .number:
            if let number = value?.doubleValue { text[field.id] = Self.format(number) }
        case .choice:
            if let string = value?.stringValue { text[field.id] = string }
        case .text(let format, _, _):
            let isDate = format == "date" || format == "date-time"
            if let string = value?.stringValue {
                text[field.id] = string
                if isDate, let date = Self.parseDate(string) { dates[field.id] = date }
            }
            // The picker always shows a date, so a required one starts at today.
            if isDate, field.isRequired, dates[field.id] == nil { dates[field.id] = Date() }
        }
    }

    // MARK: Validation

    /// Validates every field; on success returns the content to send back.
    func validatedContent() -> [String: JSONValue]? {
        var content: [String: JSONValue] = [:]
        var problems: [String: String] = [:]
        for field in fields {
            switch validate(field) {
            case .success(let value?):
                content[field.id] = value
            case .success(nil):
                break
            case .failure(let problem):
                problems[field.id] = problem.message
            }
        }
        errors = problems
        return problems.isEmpty ? content : nil
    }

    private struct Problem: Error {
        var message: String
    }

    private func validate(_ field: ElicitationField) -> Result<JSONValue?, Problem> {
        switch field.kind {
        case .boolean:
            return .success(.bool(flags[field.id] ?? false))
        case .multiChoice(_, let minItems, let maxItems):
            let chosen = selections[field.id] ?? []
            if field.isRequired && chosen.isEmpty { return .failure(Problem(message: "Choose at least one.")) }
            if let minItems, !chosen.isEmpty, chosen.count < minItems { return .failure(Problem(message: "Choose at least \(minItems).")) }
            if let maxItems, chosen.count > maxItems { return .failure(Problem(message: "Choose at most \(maxItems).")) }
            return .success(chosen.isEmpty ? nil : .array(chosen.sorted().map(JSONValue.string)))
        case .choice:
            let value = text[field.id] ?? ""
            if value.isEmpty { return field.isRequired ? .failure(Problem(message: "Choose an option.")) : .success(nil) }
            return .success(.string(value))
        case .number(let minimum, let maximum, let isInteger):
            let raw = (text[field.id] ?? "").trimmingCharacters(in: .whitespaces)
            if raw.isEmpty { return field.isRequired ? .failure(Problem(message: "Required.")) : .success(nil) }
            guard let number = Double(raw.replacingOccurrences(of: ",", with: ".")) else { return .failure(Problem(message: "Enter a number.")) }
            if isInteger && number.rounded() != number { return .failure(Problem(message: "Enter a whole number.")) }
            if let minimum, number < minimum { return .failure(Problem(message: "Must be at least \(Self.format(minimum)).")) }
            if let maximum, number > maximum { return .failure(Problem(message: "Must be at most \(Self.format(maximum)).")) }
            return .success(isInteger ? .int(Int(number)) : .double(number))
        case .text(let format, let minLength, let maxLength):
            if format == "date" || format == "date-time" {
                guard let date = dates[field.id] else { return field.isRequired ? .failure(Problem(message: "Choose a date.")) : .success(nil) }
                return .success(.string(Self.formatDate(date, withTime: format == "date-time")))
            }
            let value = text[field.id] ?? ""
            if value.isEmpty { return field.isRequired ? .failure(Problem(message: "Required.")) : .success(nil) }
            if let minLength, value.count < minLength { return .failure(Problem(message: "At least \(minLength) characters.")) }
            if let maxLength, value.count > maxLength { return .failure(Problem(message: "At most \(maxLength) characters.")) }
            if format == "email", !Self.looksLikeEmail(value) { return .failure(Problem(message: "Enter an email address.")) }
            if format == "uri" || format == "url", URL(string: value)?.scheme == nil { return .failure(Problem(message: "Enter a full URL, like https://example.com.")) }
            return .success(.string(value))
        }
    }

    private static func looksLikeEmail(_ value: String) -> Bool {
        value.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil
    }

    static func format(_ number: Double) -> String {
        number.rounded() == number && abs(number) < 1e15 ? String(Int(number)) : String(number)
    }

    private static func parseDate(_ string: String) -> Date? {
        if let date = try? Date(string, strategy: .iso8601) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: string)
    }

    private static func formatDate(_ date: Date, withTime: Bool) -> String {
        if withTime { return date.formatted(.iso8601) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    func error(for field: ElicitationField) -> String? {
        errors[field.id]
    }
}

// MARK: - View

private struct ElicitationView: View {
    var serverName: String
    var message: String
    @Bindable var form: ElicitationForm
    var respond: @MainActor (MCPElicitationResponse) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Text(message)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Label("\(serverName) asks", systemImage: "puzzlepiece.extension")
                }
                if !form.fields.isEmpty {
                    Section {
                        ForEach(form.fields) { field in
                            ElicitationFieldView(field: field, form: form)
                        }
                    } footer: {
                        if form.fields.contains(where: \.isRequired) {
                            Text("* Required").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Text("Only share what you're comfortable sending to this server.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { respond(.cancel) }
                    .keyboardShortcut(.cancelAction)
                Button("Decline") { respond(.decline) }
                Button("Accept") {
                    if let content = form.validatedContent() { respond(.accept(content)) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 420, minHeight: 280)
    }
}

private struct ElicitationFieldView: View {
    var field: ElicitationField
    @Bindable var form: ElicitationForm

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            control
            if let description = field.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = form.error(for: field) {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var label: String {
        field.title + (field.isRequired ? " *" : "")
    }

    @ViewBuilder
    private var control: some View {
        switch field.kind {
        case .boolean:
            Toggle(label, isOn: flagBinding)
        case .choice(let options):
            Picker(label, selection: textBinding) {
                if !field.isRequired || textBinding.wrappedValue.isEmpty {
                    Text("—").tag("")
                }
                ForEach(options, id: \.value) { option in
                    Text(option.title).tag(option.value)
                }
            }
        case .multiChoice(let options, _, _):
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                ForEach(options, id: \.value) { option in
                    Toggle(option.title, isOn: selectionBinding(option.value))
                        .toggleStyle(.checkbox)
                        .padding(.leading, 8)
                }
            }
        case .number(let minimum, let maximum, _):
            TextField(label, text: textBinding, prompt: Text(rangePrompt(minimum, maximum)))
        case .text(let format, _, _):
            textControl(format: format)
        }
    }

    @ViewBuilder
    private func textControl(format: String?) -> some View {
        switch format {
        case "date":
            DatePicker(label, selection: dateBinding, displayedComponents: .date)
        case "date-time":
            DatePicker(label, selection: dateBinding)
        case "email":
            TextField(label, text: textBinding, prompt: Text("name@example.com"))
        case "uri", "url":
            TextField(label, text: textBinding, prompt: Text("https://"))
        default:
            TextField(label, text: textBinding, axis: .vertical)
                .lineLimit(1...6)
        }
    }

    private func rangePrompt(_ minimum: Double?, _ maximum: Double?) -> String {
        switch (minimum, maximum) {
        case (let low?, let high?): "\(ElicitationForm.format(low))–\(ElicitationForm.format(high))"
        case (let low?, nil): "at least \(ElicitationForm.format(low))"
        case (nil, let high?): "at most \(ElicitationForm.format(high))"
        case (nil, nil): ""
        }
    }

    private var textBinding: Binding<String> {
        Binding(get: { form.text[field.id] ?? "" }, set: { form.text[field.id] = $0 })
    }

    private var flagBinding: Binding<Bool> {
        Binding(get: { form.flags[field.id] ?? false }, set: { form.flags[field.id] = $0 })
    }

    private var dateBinding: Binding<Date> {
        Binding(get: { form.dates[field.id] ?? Date() }, set: { form.dates[field.id] = $0 })
    }

    private func selectionBinding(_ value: String) -> Binding<Bool> {
        Binding(
            get: { form.selections[field.id]?.contains(value) ?? false },
            set: { isOn in
                var set = form.selections[field.id] ?? []
                if isOn { set.insert(value) } else { set.remove(value) }
                form.selections[field.id] = set
            }
        )
    }
}
