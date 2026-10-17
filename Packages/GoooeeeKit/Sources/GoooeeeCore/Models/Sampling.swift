import Foundation

/// Every sampling parameter goooeee knows about.
///
/// Settings are stored as a sparse map keyed by `SamplingKey`; a missing key means
/// "not sent, the server decides". Engine presets decide which keys are sent and under which
/// wire name.
public enum SamplingKey: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
    case temperature
    case topK = "top_k"
    case topP = "top_p"
    case minP = "min_p"
    case maxTokens = "max_tokens"
    case repeatPenalty = "repeat_penalty"
    case presencePenalty = "presence_penalty"
    case frequencyPenalty = "frequency_penalty"
    case seed
    case stop
    // Advanced (llama.cpp parity)
    case typicalP = "typ_p"
    case repeatLastN = "repeat_last_n"
    case dynatempRange = "dynatemp_range"
    case dynatempExponent = "dynatemp_exponent"
    case xtcProbability = "xtc_probability"
    case xtcThreshold = "xtc_threshold"
    case dryMultiplier = "dry_multiplier"
    case dryBase = "dry_base"
    case dryAllowedLength = "dry_allowed_length"
    case dryPenaltyLastN = "dry_penalty_last_n"
    case samplers
    case backendSampling = "backend_sampling"

    public var id: String { rawValue }

    public enum Kind: Sendable {
        case double(range: ClosedRange<Double>, step: Double)
        case int(range: ClosedRange<Int>)
        case bool
        case strings
    }

    public var kind: Kind {
        switch self {
        case .temperature: .double(range: 0...2, step: 0.05)
        case .topK: .int(range: 0...500)
        case .topP, .minP, .typicalP, .xtcProbability, .xtcThreshold: .double(range: 0...1, step: 0.01)
        case .maxTokens: .int(range: -1...1_048_576)
        case .repeatPenalty: .double(range: 0...2, step: 0.01)
        case .presencePenalty, .frequencyPenalty: .double(range: -2...2, step: 0.05)
        case .seed: .int(range: -1...Int(Int32.max))
        case .stop, .samplers: .strings
        case .repeatLastN, .dryPenaltyLastN: .int(range: -1...65_536)
        case .dynatempRange, .dynatempExponent: .double(range: 0...5, step: 0.05)
        case .dryMultiplier, .dryBase: .double(range: 0...5, step: 0.05)
        case .dryAllowedLength: .int(range: 0...100)
        case .backendSampling: .bool
        }
    }

    public var label: String {
        switch self {
        case .temperature: "Temperature"
        case .topK: "Top K"
        case .topP: "Top P"
        case .minP: "Min P"
        case .maxTokens: "Max tokens"
        case .repeatPenalty: "Repeat penalty"
        case .presencePenalty: "Presence penalty"
        case .frequencyPenalty: "Frequency penalty"
        case .seed: "Seed"
        case .stop: "Stop sequences"
        case .typicalP: "Typical P"
        case .repeatLastN: "Repeat last N"
        case .dynatempRange: "Dynamic temperature range"
        case .dynatempExponent: "Dynamic temperature exponent"
        case .xtcProbability: "XTC probability"
        case .xtcThreshold: "XTC threshold"
        case .dryMultiplier: "DRY multiplier"
        case .dryBase: "DRY base"
        case .dryAllowedLength: "DRY allowed length"
        case .dryPenaltyLastN: "DRY penalty last N"
        case .samplers: "Sampler order"
        case .backendSampling: "Backend sampling"
        }
    }

    public var help: String {
        switch self {
        case .temperature: "Randomness of the output. Higher is more random, lower is more focused."
        case .topK: "Sample only from the K most likely tokens. 0 disables it."
        case .topP: "Sample from the smallest set of tokens whose probabilities add up to P."
        case .minP: "Drop tokens less likely than P times the most likely token."
        case .maxTokens: "Maximum number of tokens to generate. -1 means unlimited."
        case .repeatPenalty: "Penalize recently used tokens. 1.0 disables it."
        case .presencePenalty: "Penalize tokens that already appeared at all."
        case .frequencyPenalty: "Penalize tokens by how often they appeared."
        case .seed: "Random seed for reproducible output. -1 picks a random seed."
        case .stop: "Generation stops when one of these strings is produced."
        case .typicalP: "Locally typical sampling. 1.0 disables it."
        case .repeatLastN: "How many recent tokens the repeat penalty looks at."
        case .dynatempRange: "Temperature varies by up to this much based on entropy."
        case .dynatempExponent: "Shape of the dynamic temperature curve."
        case .xtcProbability: "Chance of removing the most likely tokens (XTC)."
        case .xtcThreshold: "Minimum probability for XTC to remove a token."
        case .dryMultiplier: "Strength of the DRY repetition penalty. 0 disables it."
        case .dryBase: "Base of the DRY penalty growth."
        case .dryAllowedLength: "Repeated sequences up to this length are not penalized by DRY."
        case .dryPenaltyLastN: "How many tokens DRY looks back. -1 means the whole context."
        case .samplers: "Order in which samplers run (llama.cpp)."
        case .backendSampling: "Run sampling on the GPU backend (llama.cpp)."
        }
    }

    /// Shown under the inspector's "Advanced" disclosure.
    public var isAdvanced: Bool {
        switch self {
        case .temperature, .topK, .topP, .minP, .maxTokens, .repeatPenalty, .presencePenalty,
            .frequencyPenalty, .seed, .stop:
            false
        default:
            true
        }
    }

    /// The order used in the inspector and in generated requests.
    public static let displayOrder: [SamplingKey] = [
        .temperature, .topK, .topP, .minP, .maxTokens, .repeatPenalty, .presencePenalty, .frequencyPenalty,
        .seed, .stop, .typicalP, .repeatLastN, .dynatempRange, .dynatempExponent, .xtcProbability,
        .xtcThreshold, .dryMultiplier, .dryBase, .dryAllowedLength, .dryPenaltyLastN, .samplers,
        .backendSampling,
    ]
}

/// A single sampling value.
public enum SamplingValue: Sendable, Hashable, Codable {
    case double(Double)
    case int(Int)
    case bool(Bool)
    case strings([String])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode([String].self) {
            self = .strings(value)
        } else if let value = try? container.decode(String.self) {
            self = .strings(value.split(separator: ";").map(String.init))
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported sampling value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .double(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .strings(let value): try container.encode(value)
        }
    }

    public var jsonValue: JSONValue {
        switch self {
        case .double(let value): .double(value)
        case .int(let value): .int(value)
        case .bool(let value): .bool(value)
        case .strings(let value): .array(value.map(JSONValue.string))
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let value): value
        case .int(let value): Double(value)
        default: nil
        }
    }

    /// Converts a server-reported JSON value into a sampling value of the right kind for `key`.
    public init?(json: JSONValue, for key: SamplingKey) {
        switch key.kind {
        case .double:
            guard let value = json.doubleValue else { return nil }
            self = .double(value)
        case .int:
            guard let value = json.intValue else { return nil }
            self = .int(value)
        case .bool:
            guard let value = json.boolValue else { return nil }
            self = .bool(value)
        case .strings:
            if let array = json.arrayValue {
                self = .strings(array.compactMap(\.stringValue))
            } else if let string = json.stringValue {
                self = .strings(string.split(separator: ";").map(String.init))
            } else {
                return nil
            }
        }
    }

    /// Normalizes a value to the representation expected for `key` (e.g. `0.0` → `.int(0)` for top-k).
    public func normalized(for key: SamplingKey) -> SamplingValue {
        switch (key.kind, self) {
        case (.int, .double(let value)): .int(Int(value.rounded()))
        case (.double, .int(let value)): .double(Double(value))
        default: self
        }
    }

    public var displayString: String {
        switch self {
        case .double(let value):
            let formatted = String(format: "%.3f", value)
            var trimmed = formatted
            while trimmed.hasSuffix("0") { trimmed.removeLast() }
            if trimmed.hasSuffix(".") { trimmed.removeLast() }
            return trimmed
        case .int(let value): return String(value)
        case .bool(let value): return value ? "on" : "off"
        case .strings(let value): return value.joined(separator: ", ")
        }
    }
}

/// A sparse set of sampling values. Missing keys are not sent.
public struct SamplingSettings: Sendable, Hashable, Codable {
    public var values: [SamplingKey: SamplingValue]

    public init(_ values: [SamplingKey: SamplingValue] = [:]) {
        self.values = values
    }

    public subscript(key: SamplingKey) -> SamplingValue? {
        get { values[key] }
        set { values[key] = newValue?.normalized(for: key) }
    }

    public var isEmpty: Bool { values.isEmpty }

    /// Values from `other` win.
    public func overlaid(with other: SamplingSettings) -> SamplingSettings {
        SamplingSettings(values.merging(other.values) { _, new in new })
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode([String: SamplingValue].self)
        var values: [SamplingKey: SamplingValue] = [:]
        for (name, value) in raw {
            if let key = SamplingKey(rawValue: name) { values[key] = value.normalized(for: key) }
        }
        self.values = values
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) }))
    }
}
