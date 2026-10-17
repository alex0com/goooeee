import Foundation
import Jinja

public enum TemplateError: Error, LocalizedError, Equatable {
    case parse(String)
    case render(String)

    public var errorDescription: String? {
        switch self {
        case .parse(let message): "The template couldn't be parsed: \(message)"
        case .render(let message): "The template couldn't be rendered: \(message)"
        }
    }
}

/// Renders a user-loaded Jinja chat template (last-resort mode, §10.5 of the plan).
public enum ChatTemplateRenderer {
    public static func render(
        template: ChatTemplate,
        messages: [ChatMessage],
        tools: [ToolDefinition] = [],
        addGenerationPrompt: Bool = true,
        enableThinking: Bool? = nil
    ) throws -> String {
        let parsed: Template
        do {
            parsed = try Template(template.source)
        } catch {
            throw TemplateError.parse(String(describing: error))
        }
        var context: [String: Value] = [
            "messages": .array(messages.map(messageValue)),
            "add_generation_prompt": .boolean(addGenerationPrompt),
            "bos_token": .string(template.bosToken),
            "eos_token": .string(template.eosToken),
        ]
        if !tools.isEmpty {
            context["tools"] = .array(tools.map { jinjaValue($0.openAIJSON) })
        }
        if let enableThinking {
            context["enable_thinking"] = .boolean(enableThinking)
        }
        do {
            return try parsed.render(context)
        } catch {
            throw TemplateError.render(String(describing: error))
        }
    }

    /// Renders a short sample conversation to check that a template works.
    public static func validate(_ template: ChatTemplate) throws -> String {
        try render(template: template, messages: [
            .text(.system, "You are a helpful assistant."),
            .text(.user, "Hello!"),
            .text(.assistant, "Hi! How can I help?"),
            .text(.user, "What is 2 + 2?"),
        ])
    }

    static func messageValue(_ message: ChatMessage) -> Value {
        var object: [String: Value] = [
            "role": .string(message.role.rawValue),
            "content": .string(message.text),
        ]
        if let reasoning = message.reasoning, !reasoning.isEmpty {
            object["reasoning_content"] = .string(reasoning)
        }
        if !message.toolCalls.isEmpty {
            object["tool_calls"] = .array(message.toolCalls.map { call in
                let arguments = call.parsedArguments.map(jinjaValue) ?? .string(call.arguments)
                return objectValue([
                    "id": .string(call.id),
                    "type": .string("function"),
                    "function": objectValue(["name": .string(call.name), "arguments": arguments]),
                ])
            })
        }
        if let id = message.toolCallID { object["tool_call_id"] = .string(id) }
        return objectValue(object)
    }

    static func objectValue(_ dictionary: [String: Value]) -> Value {
        var ordered = OrderedDictionary<ObjectKey, Value>(minimumCapacity: dictionary.count)
        for key in dictionary.keys.sorted() { ordered[.string(key)] = dictionary[key] }
        return .object(ordered)
    }

    static func jinjaValue(_ json: JSONValue) -> Value {
        switch json {
        case .null: return .null
        case .bool(let value): return .boolean(value)
        case .int(let value): return .int(value)
        case .double(let value): return .double(value)
        case .string(let value): return .string(value)
        case .array(let values): return .array(values.map(jinjaValue))
        case .object(let object): return objectValue(object.mapValues(jinjaValue))
        }
    }
}
