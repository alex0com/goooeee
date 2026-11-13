import Foundation

/// Load state of a model on a llama.cpp router (or any server that reports it).
public enum ModelLoadState: String, Codable, Sendable, Hashable {
    case loaded
    case loading
    case unloaded
    case sleeping
    case failed
    case unknown
}

/// A model as listed by `/v1/models` (and llama.cpp router `/models`).
public struct RemoteModel: Identifiable, Codable, Sendable, Hashable {
    public var id: String
    public var ownedBy: String?
    public var contextLength: Int?
    public var loadState: ModelLoadState?
    public var aliases: [String]
    public var inputModalities: [String]?

    public init(id: String, ownedBy: String? = nil, contextLength: Int? = nil, loadState: ModelLoadState? = nil, aliases: [String] = [], inputModalities: [String]? = nil) {
        self.id = id
        self.ownedBy = ownedBy
        self.contextLength = contextLength
        self.loadState = loadState
        self.aliases = aliases
        self.inputModalities = inputModalities
    }

    public var displayName: String { ModelNameFormatter.shortName(id) }

    public var supportsVision: Bool? {
        inputModalities.map { $0.contains("image") || $0.contains("vision") }
    }
}

/// What the server reported about itself.
public struct ServerCapabilities: Codable, Sendable, Hashable {
    public var reachable: Bool
    public var models: [RemoteModel]
    public var contextLength: Int?
    public var vision: Bool?
    public var audio: Bool?
    /// llama.cpp router mode (`/props` role = router).
    public var isRouter: Bool
    /// `/tools` is available (llama.cpp `--tools` or `--mcp-servers-config`).
    public var serverToolsAvailable: Bool
    public var chatTemplate: String?
    public var modelPath: String?
    public var buildInfo: String?
    /// Server default sampling values (llama.cpp `/props` default_generation_settings.params).
    public var defaultSampling: SamplingSettings
    /// Server is loading a model (llama.cpp `/health` 503).
    public var isLoading: Bool

    public init(
        reachable: Bool = false,
        models: [RemoteModel] = [],
        contextLength: Int? = nil,
        vision: Bool? = nil,
        audio: Bool? = nil,
        isRouter: Bool = false,
        serverToolsAvailable: Bool = false,
        chatTemplate: String? = nil,
        modelPath: String? = nil,
        buildInfo: String? = nil,
        defaultSampling: SamplingSettings = SamplingSettings(),
        isLoading: Bool = false
    ) {
        self.reachable = reachable
        self.models = models
        self.contextLength = contextLength
        self.vision = vision
        self.audio = audio
        self.isRouter = isRouter
        self.serverToolsAvailable = serverToolsAvailable
        self.chatTemplate = chatTemplate
        self.modelPath = modelPath
        self.buildInfo = buildInfo
        self.defaultSampling = defaultSampling
        self.isLoading = isLoading
    }

    public func model(id: String?) -> RemoteModel? {
        guard let id else { return nil }
        return models.first { $0.id == id || $0.aliases.contains(id) }
    }

    /// Context length for a model: per-model value (router, vLLM `max_model_len`) or the server-wide `n_ctx`.
    public func contextLength(for modelID: String?) -> Int? {
        model(id: modelID)?.contextLength ?? contextLength
    }
}

/// Connection status shown as the dot in the title bar.
public enum ServerStatus: Sendable, Hashable {
    case unknown
    case offline(String)
    case starting
    case loadingModel
    case online

    public var label: String {
        switch self {
        case .unknown: "Checking…"
        case .offline: "Offline"
        case .starting: "Starting…"
        case .loadingModel: "Loading model…"
        case .online: "Online"
        }
    }

    public var isOnline: Bool { self == .online }
}

/// When goooeee may choose a model without asking.
public enum AutomaticModelChoice {
    /// A model only when the choice is unambiguous: the preferred one (a connection's default) if the
    /// server lists it, the single model the server reports as loaded, or the server's only model.
    /// Never a model picked by its position in the list.
    public static func choose(from models: [RemoteModel], preferred: String? = nil) -> String? {
        if let preferred, models.contains(where: { $0.id == preferred }) { return preferred }
        let loaded = models.filter { $0.loadState == .loaded }
        if loaded.count == 1 { return loaded[0].id }
        if models.count == 1 { return models[0].id }
        return nil
    }
}
