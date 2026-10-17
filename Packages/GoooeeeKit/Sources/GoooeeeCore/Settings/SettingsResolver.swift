import Foundation

/// Where an effective value came from. Shown as a badge in the inspector.
public enum SettingSource: String, Codable, Sendable, Hashable, Comparable {
    case chat
    case workspace
    case connection
    case profile
    case server

    public var label: String {
        switch self {
        case .chat: "this chat"
        case .workspace: "workspace"
        case .connection: "connection"
        case .profile: "profile"
        case .server: "server"
        }
    }

    /// Values set by the user ("you" in the inspector).
    public var isUser: Bool {
        switch self {
        case .chat, .workspace, .connection: true
        default: false
        }
    }

    private var rank: Int {
        switch self {
        case .chat: 0
        case .workspace: 1
        case .connection: 2
        case .profile: 3
        case .server: 4
        }
    }

    public static func < (lhs: SettingSource, rhs: SettingSource) -> Bool { lhs.rank < rhs.rank }
}

public struct ResolvedValue: Sendable, Hashable {
    public var value: SamplingValue
    public var source: SettingSource
    /// The server's own default, when it reported one and it differs from `value`.
    public var serverValue: SamplingValue?
    /// Whether the value is included in requests. Server-sourced values are not sent (the server applies them itself).
    public var isSent: Bool { source != .server }

    public init(value: SamplingValue, source: SettingSource, serverValue: SamplingValue? = nil) {
        self.value = value
        self.source = source
        self.serverValue = serverValue
    }

    /// The profile's value differs from what the server would use on its own.
    public var disagreesWithServer: Bool {
        guard let serverValue else { return false }
        return serverValue != value
    }
}

/// Everything needed to build a request, with the source of each value.
public struct EffectiveSettings: Sendable, Hashable {
    public var sampling: [SamplingKey: ResolvedValue]
    public var thinking: ThinkingLevel
    public var thinkingSource: SettingSource?
    public var systemPrompt: String?
    public var systemPromptSource: SettingSource?
    public var extraBody: JSONValue?
    public var profile: ModelProfile

    public init(
        sampling: [SamplingKey: ResolvedValue] = [:],
        thinking: ThinkingLevel = .default,
        thinkingSource: SettingSource? = nil,
        systemPrompt: String? = nil,
        systemPromptSource: SettingSource? = nil,
        extraBody: JSONValue? = nil,
        profile: ModelProfile = .generic
    ) {
        self.sampling = sampling
        self.thinking = thinking
        self.thinkingSource = thinkingSource
        self.systemPrompt = systemPrompt
        self.systemPromptSource = systemPromptSource
        self.extraBody = extraBody
        self.profile = profile
    }

    /// Values that go into the request.
    public var sentSampling: SamplingSettings {
        SamplingSettings(sampling.filter { $0.value.isSent }.mapValues(\.value))
    }

    public subscript(key: SamplingKey) -> ResolvedValue? { sampling[key] }
}

public enum SettingsError: Error, LocalizedError, Equatable {
    case invalidExtraJSON(SettingSource, String)

    public var errorDescription: String? {
        switch self {
        case .invalidExtraJSON(let source, let message): "Extra JSON (\(source.label)) is not valid JSON: \(message)"
        }
    }
}

/// Merges connection, workspace and chat settings with the model profile and server defaults.
public struct SettingsResolver: Sendable {
    public var connection: ServerConnection
    public var workspace: SettingsOverrides
    public var chat: SettingsOverrides
    public var profile: ModelProfile
    public var serverDefaults: SamplingSettings

    public init(
        connection: ServerConnection,
        workspace: SettingsOverrides = SettingsOverrides(),
        chat: SettingsOverrides = SettingsOverrides(),
        profile: ModelProfile,
        serverDefaults: SamplingSettings = SamplingSettings()
    ) {
        self.connection = connection
        self.workspace = workspace
        self.chat = chat
        self.profile = profile
        self.serverDefaults = serverDefaults
    }

    public func resolve() throws -> EffectiveSettings {
        var result = EffectiveSettings(profile: profile)

        // Thinking: chat → workspace → connection.
        if let level = chat.thinking, level != .default {
            result.thinking = level
            result.thinkingSource = .chat
        } else if let level = workspace.thinking, level != .default {
            result.thinking = level
            result.thinkingSource = .workspace
        } else if connection.thinking.level != .default {
            result.thinking = connection.thinking.level
            result.thinkingSource = .connection
        }

        // Sampling.
        let profileValues = profile.sampling.settings(thinking: result.thinking)
        let userLayers: [(SettingSource, SamplingSettings)] = [
            (.chat, chat.sampling),
            (.workspace, workspace.sampling),
            (.connection, connection.sampling),
        ]
        let fallbackLayers: [(SettingSource, SamplingSettings)] =
            connection.defaultsPolicy == .profileFirst
            ? [(.profile, profileValues), (.server, serverDefaults)]
            : [(.server, serverDefaults), (.profile, profileValues)]

        for key in SamplingKey.allCases {
            let serverValue = serverDefaults[key]
            for (source, layer) in userLayers + fallbackLayers {
                if let value = layer[key] {
                    result.sampling[key] = ResolvedValue(
                        value: value,
                        source: source,
                        serverValue: source == .server ? nil : serverValue
                    )
                    break
                }
            }
        }

        // System prompt: chat → workspace → connection. An empty string at a level clears it.
        for (source, prompt) in [(SettingSource.chat, chat.systemPrompt), (.workspace, workspace.systemPrompt), (.connection, connection.systemPrompt)] {
            if let prompt {
                let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                result.systemPrompt = trimmed.isEmpty ? nil : prompt
                result.systemPromptSource = source
                break
            }
        }

        // Extra JSON: connection, then workspace, then chat merged on top.
        var extra: JSONValue?
        for (source, json) in [(SettingSource.connection, connection.extraBodyJSON), (.workspace, workspace.extraBodyJSON), (.chat, chat.extraBodyJSON)] {
            guard let json, !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            do {
                let parsed = try JSONValue.parse(json)
                extra = extra.map { $0.merging(parsed) } ?? parsed
            } catch {
                throw SettingsError.invalidExtraJSON(source, String(describing: error))
            }
        }
        result.extraBody = extra
        return result
    }
}
