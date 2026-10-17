import Foundation

/// Reference to a secret stored outside the database (Keychain on macOS).
public struct SecretRef: Codable, Sendable, Hashable {
    public var account: String

    public init(account: String) {
        self.account = account
    }

    public static func apiKey(for connectionID: UUID) -> SecretRef {
        SecretRef(account: "connection.\(connectionID.uuidString).apiKey")
    }
}

/// How the server is started from the workspace terminal.
public struct LaunchConfig: Codable, Sendable, Hashable {
    public var command: String
    public var workingDirectory: String?
    public var environment: [String: String]
    /// Seconds to wait for the health check after starting.
    public var startupTimeout: TimeInterval

    public init(command: String = "", workingDirectory: String? = nil, environment: [String: String] = [:], startupTimeout: TimeInterval = 300) {
        self.command = command
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.startupTimeout = startupTimeout
    }
}

/// A user-loaded Jinja chat template (last resort, used with `APIStyle.openAICompletion`).
public struct ChatTemplate: Codable, Sendable, Hashable {
    public var source: String
    public var fileName: String?
    public var bosToken: String
    public var eosToken: String
    /// Extra stop strings sent with `/v1/completions`.
    public var stopTokens: [String]

    public init(source: String, fileName: String? = nil, bosToken: String = "", eosToken: String = "", stopTokens: [String] = []) {
        self.source = source
        self.fileName = fileName
        self.bosToken = bosToken
        self.eosToken = eosToken
        self.stopTokens = stopTokens
    }
}

/// Which default wins when the user hasn't set a value: the model profile or the server's reported default.
///
/// llama.cpp's `/props` reports its built-in defaults (e.g. temperature 0.8) even when the server
/// was started without sampling flags, so by default the curated profile wins and the server
/// value is shown for reference.
public enum DefaultsPolicy: String, Codable, Sendable, CaseIterable, Hashable {
    case profileFirst
    case serverFirst

    public var label: String {
        switch self {
        case .profileFirst: "Model profile, then server"
        case .serverFirst: "Server, then model profile"
        }
    }
}

public struct ConnectionTestSummary: Codable, Sendable, Hashable {
    public var date: Date
    public var passed: Bool
    public var message: String

    public init(date: Date, passed: Bool, message: String) {
        self.date = date
        self.passed = passed
        self.message = message
    }
}

/// A saved server connection. One connection can back several workspaces.
public struct ServerConnection: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var name: String
    public var engine: EngineKind
    public var apiStyle: APIStyle
    /// Server root, e.g. `http://127.0.0.1:8080`.
    public var baseURL: URL
    /// API prefix appended for OpenAI/Anthropic routes, normally `/v1`.
    public var apiPrefix: String
    public var apiKeyRef: SecretRef?
    public var extraHeaders: [String: String]
    public var defaultModelID: String?
    /// `nil` = detect from the model ID.
    public var profileID: String?
    public var defaultsPolicy: DefaultsPolicy
    public var sampling: SamplingSettings
    public var thinking: ThinkingSettings
    public var systemPrompt: String?
    public var extraBodyJSON: String?
    public var supportsImages: Bool?
    public var supportsTools: Bool?
    public var chatTemplate: ChatTemplate?
    public var requestTimeout: TimeInterval
    public var launch: LaunchConfig?
    public var lastTest: ConnectionTestSummary?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        engine: EngineKind,
        apiStyle: APIStyle? = nil,
        baseURL: URL? = nil,
        apiPrefix: String? = nil,
        apiKeyRef: SecretRef? = nil,
        extraHeaders: [String: String] = [:],
        defaultModelID: String? = nil,
        profileID: String? = nil,
        defaultsPolicy: DefaultsPolicy = .profileFirst,
        sampling: SamplingSettings = SamplingSettings(),
        thinking: ThinkingSettings = ThinkingSettings(),
        systemPrompt: String? = nil,
        extraBodyJSON: String? = nil,
        supportsImages: Bool? = nil,
        supportsTools: Bool? = nil,
        chatTemplate: ChatTemplate? = nil,
        requestTimeout: TimeInterval = 600,
        launch: LaunchConfig? = nil,
        lastTest: ConnectionTestSummary? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.engine = engine
        self.apiStyle = apiStyle ?? engine.defaultAPIStyle
        self.baseURL = baseURL ?? engine.defaultBaseURL
        self.apiPrefix = apiPrefix ?? engine.defaultAPIPrefix
        self.apiKeyRef = apiKeyRef
        self.extraHeaders = extraHeaders
        self.defaultModelID = defaultModelID
        self.profileID = profileID
        self.defaultsPolicy = defaultsPolicy
        self.sampling = sampling
        self.thinking = thinking
        self.systemPrompt = systemPrompt
        self.extraBodyJSON = extraBodyJSON
        self.supportsImages = supportsImages
        self.supportsTools = supportsTools
        self.chatTemplate = chatTemplate
        self.requestTimeout = requestTimeout
        self.launch = launch
        self.lastTest = lastTest
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// A new connection with the engine's defaults.
    public static func preset(_ engine: EngineKind, name: String? = nil, baseURL: URL? = nil) -> ServerConnection {
        var connection = ServerConnection(name: name ?? engine.displayName, engine: engine, baseURL: baseURL)
        if !engine.launchCommandExample.isEmpty {
            connection.launch = LaunchConfig(command: engine.launchCommandExample)
        }
        return connection
    }

    /// Full URL for an API route such as `/chat/completions`.
    public func apiURL(_ path: String) -> URL {
        URLBuilder.join(baseURL, apiPrefix, path)
    }

    /// Full URL for a route at the server root such as `/health` or `/props`.
    public func rootURL(_ path: String) -> URL {
        URLBuilder.join(baseURL, path)
    }

    /// Host and port for display, e.g. `127.0.0.1:8080`.
    public var hostDescription: String {
        let host = baseURL.host ?? baseURL.absoluteString
        if let port = baseURL.port { return "\(host):\(port)" }
        return host
    }

    public var portDescription: String {
        if let port = baseURL.port { return ":\(port)" }
        return baseURL.host ?? ""
    }
}

public enum URLBuilder {
    /// Joins URL path components without doubling or dropping slashes.
    public static func join(_ base: URL, _ components: String...) -> URL {
        var string = base.absoluteString
        while string.hasSuffix("/") { string.removeLast() }
        for component in components where !component.isEmpty {
            var part = component
            while part.hasPrefix("/") { part.removeFirst() }
            while part.hasSuffix("/") { part.removeLast() }
            guard !part.isEmpty else { continue }
            string += "/" + part
        }
        return URL(string: string) ?? base
    }

    /// Splits a user-entered URL like `http://host:8080/v1` into a server root and an API prefix.
    public static func normalize(_ input: String, defaultPrefix: String = "/v1") -> (base: URL, prefix: String)? {
        var trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") { trimmed = "http://" + trimmed }
        guard var components = URLComponents(string: trimmed), components.host != nil else { return nil }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        var prefix = defaultPrefix
        for known in ["/v1/chat/completions", "/v1/completions", "/v1/messages", "/v1"] where path.hasSuffix(known) {
            path.removeLast(known.count)
            prefix = "/v1"
            break
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { return nil }
        return (url, prefix)
    }
}
