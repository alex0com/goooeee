import AppKit
import GoooeeeMarkdown

/// Builds highlighted attributed strings for code blocks off the main thread and caches them.
///
/// A closed block is highlighted once. A block that is still streaming shows the most recent
/// highlighted prefix plus the plain rest, and is re-highlighted at most four times a second.
@MainActor
final class CodeHighlighter {
    struct Style: @unchecked Sendable {
        let font: NSFont
        let textColor: NSColor
        let colors: [SyntaxTokenKind: NSColor]
        let generation: Int
    }

    private struct Key: Hashable, Sendable {
        var language: String?
        var length: Int
        var hash: Int
        var generation: Int
    }

    private final class Box: @unchecked Sendable {
        let value: NSAttributedString
        init(_ value: NSAttributedString) { self.value = value }
    }

    private struct LiveEntry {
        var source: String
        var length: Int
        var string: NSAttributedString?
        var requestedAt: TimeInterval
        var inFlight: Bool
        var generation: Int
    }

    /// Called with a row ID when highlighting for that row finished (redraw it).
    var onHighlighted: ((String) -> Void)?

    private var cache = LRUCache<Key, NSAttributedString>(capacity: 300)
    private var inFlight = Set<Key>()
    private var waiting: [Key: Set<String>] = [:]
    private var live: [String: LiveEntry] = [:]
    private static let liveInterval: TimeInterval = 0.25

    /// Tabs are shown as four spaces so column widths are predictable.
    nonisolated static func displayCode(_ code: String) -> String {
        code.contains("\t") ? code.replacingOccurrences(of: "\t", with: "    ") : code
    }

    nonisolated static func build(code: String, language: String?, style: Style, highlight: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString(string: code, attributes: [.font: style.font, .foregroundColor: style.textColor])
        guard highlight, !code.isEmpty else { return result }
        let tokens = SyntaxHighlighter.tokens(for: code, language: language)
        let length = result.length
        result.beginEditing()
        for token in tokens where token.location >= 0 && token.length > 0 && token.location + token.length <= length {
            if let color = style.colors[token.kind] {
                result.addAttribute(.foregroundColor, value: color, range: NSRange(location: token.location, length: token.length))
            }
        }
        result.endEditing()
        return result
    }

    func plain(_ code: String, style: Style) -> NSAttributedString {
        Self.build(code: code, language: nil, style: style, highlight: false)
    }

    /// The highlighted string if it's ready; otherwise the best available stand-in, and highlighting starts.
    func attributedString(code: String, language: String?, style: Style, rowID: String) -> NSAttributedString {
        let key = Key(language: language, length: code.utf16.count, hash: code.hashValue, generation: style.generation)
        if let cached = cache.value(for: key) {
            live[rowID] = nil
            return cached
        }
        schedule(code: code, language: language, style: style, key: key, rowID: rowID)
        return composite(code: code, style: style, rowID: rowID) ?? plain(code, style: style)
    }

    /// For a block that is still being generated.
    func liveAttributedString(code: String, language: String?, style: Style, rowID: String) -> NSAttributedString {
        let now = ProcessInfo.processInfo.systemUptime
        let length = code.utf16.count
        var entry = live[rowID]
        if entry?.generation != style.generation || entry.map({ !code.hasPrefix($0.source) }) == true {
            entry = nil
        }
        let shouldRequest: Bool
        if let entry {
            shouldRequest = !entry.inFlight && entry.length < length && now - entry.requestedAt >= Self.liveInterval
        } else {
            shouldRequest = true
        }
        if shouldRequest {
            var updated = entry ?? LiveEntry(source: "", length: 0, string: nil, requestedAt: now, inFlight: true, generation: style.generation)
            updated.inFlight = true
            updated.requestedAt = now
            live[rowID] = updated
            let generation = style.generation
            Task.detached(priority: .userInitiated) { [weak self] in
                let built = Box(Self.build(code: code, language: language, style: style, highlight: true))
                await self?.finishLive(rowID: rowID, source: code, length: length, result: built, generation: generation)
            }
        } else if let entry {
            live[rowID] = entry
        }
        return composite(code: code, style: style, rowID: rowID) ?? plain(code, style: style)
    }

    func removeAll() {
        cache.removeAll()
        live.removeAll()
        waiting.removeAll()
    }

    // MARK: Private

    /// The latest highlighted prefix for the row plus the rest as plain text.
    private func composite(code: String, style: Style, rowID: String) -> NSAttributedString? {
        guard let entry = live[rowID], let string = entry.string, entry.generation == style.generation,
            entry.length <= code.utf16.count, code.hasPrefix(entry.source)
        else { return nil }
        guard entry.length < code.utf16.count else { return string }
        let result = NSMutableAttributedString(attributedString: string)
        let rest = (code as NSString).substring(from: entry.length)
        result.append(plain(rest, style: style))
        return result
    }

    private func schedule(code: String, language: String?, style: Style, key: Key, rowID: String) {
        waiting[key, default: []].insert(rowID)
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        Task.detached(priority: .userInitiated) { [weak self] in
            let built = Box(Self.build(code: code, language: language, style: style, highlight: true))
            await self?.finish(key: key, result: built)
        }
    }

    private func finish(key: Key, result: Box) {
        inFlight.remove(key)
        cache.set(result.value, for: key)
        let rows = waiting.removeValue(forKey: key) ?? []
        for row in rows {
            onHighlighted?(row)
        }
    }

    private func finishLive(rowID: String, source: String, length: Int, result: Box, generation: Int) {
        guard var entry = live[rowID], entry.generation == generation else { return }
        entry.inFlight = false
        if length >= entry.length {
            entry.source = source
            entry.length = length
            entry.string = result.value
        }
        live[rowID] = entry
        if live.count > 64 {
            for key in live.keys.prefix(live.count - 32) where key != rowID {
                live[key] = nil
            }
        }
        onHighlighted?(rowID)
    }
}
