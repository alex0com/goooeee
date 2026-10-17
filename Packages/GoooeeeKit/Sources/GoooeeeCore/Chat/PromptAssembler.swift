import Foundation

/// Turns a conversation path into API-neutral chat messages.
public enum PromptAssembler {
    public struct Options: Sendable {
        public var systemPrompt: String?
        /// Send earlier reasoning back (models whose templates expect it).
        public var includeReasoning: Bool
        public var supportsVision: Bool
        public var pdfAsImages: Bool

        public init(systemPrompt: String? = nil, includeReasoning: Bool = false, supportsVision: Bool = true, pdfAsImages: Bool = false) {
            self.systemPrompt = systemPrompt
            self.includeReasoning = includeReasoning
            self.supportsVision = supportsVision
            self.pdfAsImages = pdfAsImages
        }
    }

    public static func messages(path: [Message], options: Options) -> [ChatMessage] {
        var output: [ChatMessage] = []
        if let system = options.systemPrompt, !system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            output.append(.text(.system, system))
        }
        var pendingToolImages: [(name: String, data: Data, mimeType: String)] = []

        func flushToolImages() {
            guard !pendingToolImages.isEmpty else { return }
            var parts: [ChatContentPart] = [.text("Images returned by \(Set(pendingToolImages.map(\.name)).sorted().joined(separator: ", ")):")]
            parts += pendingToolImages.map { .image(data: $0.data, mimeType: $0.mimeType) }
            output.append(ChatMessage(role: .user, content: parts))
            pendingToolImages = []
        }

        for message in path {
            if message.role != .tool { flushToolImages() }
            switch message.role {
            case .system:
                output.append(.text(.system, message.text))
            case .user:
                output.append(ChatMessage(role: .user, content: userParts(message, options: options)))
            case .assistant:
                if case .failed = message.state, message.text.isEmpty, message.toolCalls.isEmpty { continue }
                let reasoning = options.includeReasoning && message.hasReasoning ? message.reasoning : nil
                let signature = message.blocks.compactMap { block -> String? in
                    if case .thinking(_, _, let signature) = block { return signature }
                    return nil
                }.last
                output.append(ChatMessage(
                    role: .assistant,
                    content: [.text(message.text)],
                    reasoning: reasoning ?? (signature != nil ? message.reasoning : nil),
                    reasoningSignature: signature,
                    toolCalls: message.toolCalls
                ))
            case .tool:
                let text = message.toolResult?.textForModel ?? message.text
                output.append(ChatMessage(role: .tool, content: [.text(text)], toolCallID: message.toolCallID))
                if options.supportsVision, let result = message.toolResult {
                    let name = message.toolCallID ?? "tool"
                    pendingToolImages += result.images.map { (name, $0.data, $0.mimeType) }
                }
            }
        }
        flushToolImages()
        return output
    }

    static func userParts(_ message: Message, options: Options) -> [ChatContentPart] {
        var parts: [ChatContentPart] = []
        for attachment in message.attachments {
            switch attachment.kind {
            case .image:
                if options.supportsVision, let data = attachment.data {
                    parts.append(.image(data: data, mimeType: attachment.mimeType))
                } else {
                    parts.append(.text("[Image “\(attachment.name)” omitted: the model can't see images.]"))
                }
            case .text:
                parts.append(.text(fileBlock(name: attachment.name, text: attachment.text ?? "")))
            case .pdf:
                if options.pdfAsImages, options.supportsVision, let pages = attachment.pageImages, !pages.isEmpty {
                    parts.append(.text("PDF “\(attachment.name)”, \(pages.count) page\(pages.count == 1 ? "" : "s"):"))
                    parts += pages.map { .image(data: $0, mimeType: "image/png") }
                } else {
                    parts.append(.text(fileBlock(name: attachment.name, text: attachment.text ?? "")))
                }
            case .mcpResource:
                if attachment.mimeType.hasPrefix("image/"), let data = attachment.data, options.supportsVision {
                    parts.append(.image(data: data, mimeType: attachment.mimeType))
                } else {
                    parts.append(.text(fileBlock(name: attachment.sourceURI ?? attachment.name, text: attachment.text ?? "")))
                }
            case .mcpPrompt:
                parts.append(.text(attachment.text ?? ""))
            }
        }
        let text = message.text
        if !text.isEmpty { parts.append(.text(text)) }
        if parts.isEmpty { parts.append(.text("")) }
        return parts
    }

    static func fileBlock(name: String, text: String) -> String {
        let fence = text.contains("```") ? "````" : "```"
        return "File: \(name)\n\(fence)\n\(text)\n\(fence)"
    }
}
