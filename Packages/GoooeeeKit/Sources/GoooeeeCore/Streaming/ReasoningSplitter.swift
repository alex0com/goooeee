import Foundation

/// Separates inline reasoning from visible content in streamed text.
///
/// Handles reasoning tags (`<think>`…`</think>`, `[THINK]`…`[/THINK]`, …) split across chunk
/// boundaries, templates that open the tag in the prompt (only `</think>` appears in the
/// output), and OpenAI Harmony channels. Reasoning that arrives in a separate field
/// (`reasoning_content`, `reasoning`) doesn't go through the splitter.
public struct ReasoningSplitter: Sendable {
    public enum Output: Sendable, Hashable {
        case content(String)
        case reasoning(String)
        /// Everything emitted as content so far was actually reasoning (start-inside templates).
        case reclassifyContentAsReasoning
    }

    struct TagPair: Sendable, Hashable {
        var open: String
        var close: String
    }

    static let autoPairs: [TagPair] = [
        TagPair(open: "<think>", close: "</think>"),
        TagPair(open: "<thinking>", close: "</thinking>"),
        TagPair(open: "[THINK]", close: "[/THINK]"),
        TagPair(open: "<|begin_of_thought|>", close: "<|end_of_thought|>"),
        TagPair(open: "<seed:think>", close: "</seed:think>"),
    ]

    static let harmonyMarkers = ["<|channel|>", "<|start|>", "<|end|>", "<|return|>", "<|call|>", "<|message|>"]

    private enum HarmonyMode: Sendable { case content, reasoning, skip, header }

    private let pairs: [TagPair]
    private let harmony: Bool
    private let mayStartInside: Bool
    private let enabled: Bool
    private var buffer = ""
    private var insidePair: TagPair?
    private var atSegmentStart = true
    private var sawTag = false
    private var harmonyMode: HarmonyMode = .content
    private var harmonyHeader = ""
    private var harmonyEngaged = false

    /// - Parameters:
    ///   - format: From the model profile.
    ///   - enabled: `false` passes everything through as content ("disable reasoning parsing").
    ///   - thinkingDisabled: The user turned thinking off, so a start-inside template won't open a tag.
    public init(format: ReasoningFormat, enabled: Bool = true, thinkingDisabled: Bool = false) {
        self.enabled = enabled
        switch format {
        case .none:
            pairs = []
            harmony = false
            mayStartInside = false
        case .auto:
            pairs = Self.autoPairs
            harmony = true
            mayStartInside = false
        case .harmony:
            pairs = []
            harmony = true
            mayStartInside = false
        case .tags(let open, let close, let startInside):
            pairs = [TagPair(open: open, close: close)]
            harmony = false
            mayStartInside = startInside && !thinkingDisabled
        }
    }

    public mutating func feed(_ text: String) -> [Output] {
        guard enabled, !text.isEmpty else { return text.isEmpty ? [] : [.content(text)] }
        buffer += text
        if harmony && (harmonyEngaged || buffer.contains("<|")) && pairsDoNotMatch() {
            return processHarmony(final: false)
        }
        return processTags(final: false)
    }

    /// Emits whatever is still buffered at the end of the stream.
    public mutating func flush() -> [Output] {
        guard enabled else { return [] }
        if harmonyEngaged { return processHarmony(final: true) }
        return processTags(final: true)
    }

    /// Harmony is used when the buffer looks like Harmony and not like a tag format.
    private mutating func pairsDoNotMatch() -> Bool {
        if harmonyEngaged { return true }
        if insidePair != nil { return false }
        if Self.harmonyMarkers.contains(where: { buffer.contains($0) }) {
            harmonyEngaged = true
            return true
        }
        return false
    }

    // MARK: Tags

    private mutating func processTags(final: Bool) -> [Output] {
        var outputs: [Output] = []
        func emit(_ output: Output) {
            switch output {
            case .content(let text) where text.isEmpty, .reasoning(let text) where text.isEmpty: return
            default: outputs.append(output)
            }
        }

        let harmonyTags = harmony ? Self.harmonyMarkers : []
        while true {
            if let pair = insidePair {
                if let range = buffer.range(of: pair.close) {
                    emit(.reasoning(String(buffer[..<range.lowerBound])))
                    buffer = String(buffer[range.upperBound...])
                    insidePair = nil
                    atSegmentStart = true
                    continue
                }
                let keep = final ? 0 : Self.partialSuffixLength(buffer, tags: [pair.close])
                emit(.reasoning(String(buffer.dropLast(keep))))
                buffer = String(buffer.suffix(keep))
                break
            }

            if atSegmentStart && !pairs.isEmpty {
                let leading = buffer.drop { $0.isWhitespace }
                if leading.isEmpty {
                    if final { emit(.content(buffer)); buffer = "" }
                    break
                }
                if let pair = pairs.first(where: { leading.hasPrefix($0.open) }) {
                    buffer = String(leading.dropFirst(pair.open.count))
                    insidePair = pair
                    sawTag = true
                    continue
                }
                if !final, pairs.contains(where: { $0.open.hasPrefix(leading) }) || harmonyTags.contains(where: { $0.hasPrefix(leading) }) {
                    break  // could still become an opening tag or a Harmony marker
                }
                atSegmentStart = false
            }

            if mayStartInside && !sawTag, let pair = pairs.first, let range = buffer.range(of: pair.close) {
                outputs.append(.reclassifyContentAsReasoning)
                emit(.reasoning(String(buffer[..<range.lowerBound])))
                buffer = String(buffer[range.upperBound...])
                sawTag = true
                atSegmentStart = true
                continue
            }

            var held = harmonyTags
            if mayStartInside && !sawTag { held += pairs.map(\.close) }
            let keep = final ? 0 : Self.partialSuffixLength(buffer, tags: held)
            emit(.content(String(buffer.dropLast(keep))))
            buffer = String(buffer.suffix(keep))
            break
        }
        return outputs
    }

    // MARK: Harmony

    private mutating func processHarmony(final: Bool) -> [Output] {
        var outputs: [Output] = []
        func emit(_ text: String) {
            guard !text.isEmpty else { return }
            switch harmonyMode {
            case .content: outputs.append(.content(text))
            case .reasoning: outputs.append(.reasoning(text))
            case .skip, .header: break
            }
        }

        while true {
            if harmonyMode == .header {
                if let range = buffer.range(of: "<|message|>") {
                    harmonyHeader += buffer[..<range.lowerBound]
                    buffer = String(buffer[range.upperBound...])
                    harmonyMode = Self.channelMode(header: harmonyHeader)
                    harmonyHeader = ""
                    continue
                }
                if final { buffer = ""; break }
                let keep = Self.partialSuffixLength(buffer, tags: ["<|message|>"])
                harmonyHeader += buffer.dropLast(keep)
                buffer = String(buffer.suffix(keep))
                break
            }

            let found = Self.harmonyMarkers.compactMap { marker in buffer.range(of: marker).map { (marker, $0) } }
                .min { $0.1.lowerBound < $1.1.lowerBound }
            guard let (marker, range) = found else {
                let keep = final ? 0 : Self.partialSuffixLength(buffer, tags: Self.harmonyMarkers)
                emit(String(buffer.dropLast(keep)))
                buffer = String(buffer.suffix(keep))
                break
            }
            emit(String(buffer[..<range.lowerBound]))
            buffer = String(buffer[range.upperBound...])
            switch marker {
            case "<|start|>":
                harmonyMode = .header
                harmonyHeader = ""
            case "<|channel|>":
                harmonyMode = .header
                harmonyHeader = "<|channel|>"
            case "<|end|>", "<|return|>", "<|call|>":
                harmonyMode = .skip
            default:
                break
            }
        }
        return outputs
    }

    private static func channelMode(header: String) -> HarmonyMode {
        guard let range = header.range(of: "<|channel|>") else { return .content }
        let channel = header[range.upperBound...].prefix { !$0.isWhitespace && $0 != "<" }
        return channel == "analysis" ? .reasoning : .content
    }

    /// Length of the longest suffix of `text` that is a proper prefix of one of `tags`.
    static func partialSuffixLength(_ text: String, tags: [String]) -> Int {
        var best = 0
        for tag in tags {
            let maxLength = min(tag.count - 1, text.count)
            guard maxLength > 0 else { continue }
            for length in stride(from: maxLength, through: 1, by: -1) where length > best {
                if tag.hasPrefix(text.suffix(length)) {
                    best = length
                    break
                }
            }
        }
        return best
    }
}
