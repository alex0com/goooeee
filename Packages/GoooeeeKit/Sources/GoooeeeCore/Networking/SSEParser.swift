import Foundation

/// One Server-Sent Events message.
public struct SSEEvent: Sendable, Hashable {
    /// Value of the most recent `event:` line (Anthropic uses these; OpenAI-style streams don't).
    public var event: String?
    public var data: String

    public init(event: String? = nil, data: String) {
        self.event = event
        self.data = data
    }

    public var isDone: Bool { data == "[DONE]" }
}

/// Incremental SSE parser.
///
/// Fed raw bytes as they arrive; returns complete events. Lines are split on bytes so a
/// multi-byte UTF-8 character split across chunks is never decoded early. Like the llama.cpp
/// UI, each `data:` line is dispatched on its own: OpenAI-compatible servers put one JSON
/// object per data line, and some don't send the blank separator line reliably.
public struct SSEParser: Sendable {
    private var buffer: [UInt8] = []
    private var currentEvent: String?
    /// Lines that weren't SSE fields (some servers stream bare JSON lines).
    public private(set) var unparsedLines = 0

    public init() {}

    public mutating func feed(_ data: Data) -> [SSEEvent] {
        buffer.append(contentsOf: data)
        var events: [SSEEvent] = []
        var lineStart = 0
        var index = 0
        while index < buffer.count {
            let byte = buffer[index]
            if byte == 0x0A || byte == 0x0D {
                let line = Array(buffer[lineStart..<index])
                // Treat \r\n as one line ending.
                if byte == 0x0D, index + 1 < buffer.count, buffer[index + 1] == 0x0A {
                    index += 1
                } else if byte == 0x0D, index + 1 == buffer.count {
                    // Can't tell yet whether \n follows; wait for more data.
                    break
                }
                if let event = process(line: line) { events.append(event) }
                lineStart = index + 1
            }
            index += 1
        }
        if lineStart > 0 { buffer.removeFirst(min(lineStart, buffer.count)) }
        return events
    }

    /// Flushes a final line that wasn't newline-terminated.
    public mutating func finish() -> [SSEEvent] {
        guard !buffer.isEmpty else { return [] }
        var line = buffer
        if line.last == 0x0D { line.removeLast() }
        buffer.removeAll()
        return process(line: line).map { [$0] } ?? []
    }

    private mutating func process(line bytes: [UInt8]) -> SSEEvent? {
        if bytes.isEmpty {
            currentEvent = nil
            return nil
        }
        let line = String(decoding: bytes, as: UTF8.self)
        if line.hasPrefix(":") { return nil }  // comment / keep-alive ping
        if line.hasPrefix("data:") {
            var value = line.dropFirst(5)
            if value.first == " " { value = value.dropFirst() }
            return SSEEvent(event: currentEvent, data: String(value))
        }
        if line.hasPrefix("event:") {
            var value = line.dropFirst(6)
            if value.first == " " { value = value.dropFirst() }
            currentEvent = String(value)
            return nil
        }
        if line.hasPrefix("id:") || line.hasPrefix("retry:") { return nil }
        // Bare JSON line (non-SSE streaming, e.g. some proxies): pass it through as data.
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("{") {
            return SSEEvent(event: currentEvent, data: trimmed)
        }
        unparsedLines += 1
        return nil
    }
}
