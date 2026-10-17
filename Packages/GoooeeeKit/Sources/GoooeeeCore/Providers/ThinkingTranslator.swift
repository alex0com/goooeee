import Foundation

/// Turns the single Thinking control into engine- and model-specific request fields.
public enum ThinkingTranslator {
    public struct Result: Sendable, Hashable {
        /// Fields merged into the request body.
        public var body: [String: JSONValue] = [:]
        /// Text appended to the system prompt (soft switch such as `/no_think`).
        public var systemPromptSuffix: String?
    }

    public static func translate(level: ThinkingLevel, profile: ModelProfile, engine: EngineKind) -> Result {
        var result = Result()
        guard let enabled = level.isEnabled else { return result }
        let control = profile.thinkingControl
        let capabilities = engine.capabilities
        var applied = false
        var kwargs: [String: JSONValue] = [:]

        for mechanism in capabilities.thinkingMechanisms {
            switch mechanism {
            case .chatTemplateKwarg:
                // llama.cpp's UI always sends enable_thinking when the user chose explicitly.
                let key = control.chatTemplateKwarg ?? (engine == .llamaCpp ? "enable_thinking" : nil)
                if let key, !control.alwaysThinks || enabled {
                    kwargs[key] = .bool(enabled)
                    applied = true
                }
            case .llamaCppBudget:
                if enabled, let budget = level.llamaCppBudgetTokens, budget >= 0, !control.reasoningEffort {
                    result.body["thinking_budget_tokens"] = .int(budget)
                }
            case .reasoningEffort:
                let modelUnderstandsEffort = control.reasoningEffort
                // Engines that map effort themselves, unless the model has its own switch (kwarg or soft switch).
                let modelHasOwnSwitch = control.chatTemplateKwarg != nil || control.softSwitch != nil
                let engineUsesEffort = engine == .openAI || ([.lmStudio, .ollama, .dwarfStar4].contains(engine) && !modelHasOwnSwitch)
                guard modelUnderstandsEffort || engineUsesEffort else { continue }
                if !enabled && engine == .dwarfStar4 { continue }  // ds4 turns thinking off with `think`
                if let effort = effort(for: level, profile: profile, engine: engine) {
                    result.body["reasoning_effort"] = .string(effort)
                    if engine == .llamaCpp { kwargs["reasoning_effort"] = .string(effort) }
                    applied = true
                }
            case .enableThinkingFlag:
                result.body["enable_thinking"] = .bool(enabled)
                if enabled, let budget = level.llamaCppBudgetTokens, budget > 0 {
                    result.body["thinking_budget"] = .int(budget)
                }
                applied = true
            case .thinkFlag:
                if engine == .ollama && enabled && result.body["reasoning_effort"] != nil { continue }
                result.body["think"] = .bool(enabled)
                applied = true
            case .anthropicThinking:
                // Built by the Anthropic provider.
                applied = true
            }
        }

        if !kwargs.isEmpty {
            result.body["chat_template_kwargs"] = .object(kwargs)
        }
        if !applied, let softSwitch = control.softSwitch, softSwitch.count == 2 {
            result.systemPromptSuffix = enabled ? softSwitch[0] : softSwitch[1]
        }
        return result
    }

    static func effort(for level: ThinkingLevel, profile: ModelProfile, engine: EngineKind) -> String? {
        switch level {
        case .default: return nil
        case .off: return profile.thinkingControl.alwaysThinks ? "low" : (engine == .openAI ? "minimal" : "none")
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        case .max: return engine == .dwarfStar4 ? "max" : "high"
        }
    }
}
