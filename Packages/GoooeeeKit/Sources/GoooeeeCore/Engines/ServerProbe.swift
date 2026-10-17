import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Asks a server what it can do: models, context length, vision, router mode, server tools, defaults.
public struct ServerProbe: Sendable {
    public var connection: ServerConnection
    public var apiKey: String?
    public var http: HTTPClient

    public init(connection: ServerConnection, apiKey: String?, http: HTTPClient = URLSessionHTTPClient.shared) {
        self.connection = connection
        self.apiKey = apiKey
        self.http = http
    }

    public struct Result: Sendable {
        public var capabilities: ServerCapabilities
        public var error: InferenceError?

        public var status: ServerStatus {
            if let error { return .offline(error.localizedDescription) }
            if capabilities.isLoading { return .loadingModel }
            return capabilities.reachable ? .online : .offline("Not reachable")
        }
    }

    public func probe(modelID: String? = nil) async -> Result {
        var capabilities = ServerCapabilities()
        let engine = connection.engine
        let llama = LlamaCppClient(connection: connection, apiKey: apiKey, http: http)

        if engine == .llamaCpp {
            do {
                let ready = try await llama.health()
                capabilities.reachable = true
                capabilities.isLoading = !ready
            } catch let error as InferenceError {
                if case .http = error {
                    capabilities.reachable = true
                } else {
                    return Result(capabilities: capabilities, error: error)
                }
            } catch {
                return Result(capabilities: capabilities, error: .from(error))
            }
        }

        do {
            let provider = ProviderFactory.make(connection: connection, apiKey: apiKey, http: http)
            capabilities.models = try await provider.listModels()
            capabilities.reachable = true
        } catch {
            let mapped = InferenceError.from(error)
            if !capabilities.reachable { return Result(capabilities: capabilities, error: mapped) }
        }

        if engine.capabilities.supportsProps {
            if let props = try? await llama.props() {
                capabilities.contextLength = props.contextLength
                capabilities.vision = props.vision
                capabilities.audio = props.audio
                capabilities.chatTemplate = props.chatTemplate
                capabilities.modelPath = props.modelPath
                capabilities.buildInfo = props.buildInfo
                capabilities.defaultSampling = props.defaultSampling
                capabilities.isRouter = props.isRouter
            }
            if capabilities.isRouter {
                if let models = try? await llama.routerModels(), !models.isEmpty {
                    capabilities.models = models
                }
                let selected = modelID ?? capabilities.models.first(where: { $0.loadState == .loaded })?.id
                if let selected, capabilities.model(id: selected)?.loadState == .loaded,
                    let props = try? await llama.props(model: selected)
                {
                    capabilities.contextLength = props.contextLength ?? capabilities.contextLength
                    capabilities.vision = props.vision ?? capabilities.vision
                    capabilities.defaultSampling = props.defaultSampling
                    capabilities.chatTemplate = props.chatTemplate ?? capabilities.chatTemplate
                }
                if let selected, let modalities = capabilities.model(id: selected)?.inputModalities {
                    capabilities.vision = modalities.contains("image")
                    capabilities.audio = modalities.contains("audio")
                }
            }
        } else if engine == .genericOpenAI {
            // llama.cpp (or a server built on it) saved as a plain OpenAI-compatible connection.
            // Only what the model accepts is taken: its sampling defaults and template would change
            // how this connection's settings resolve. Other servers answer 404, which changes nothing.
            if let props = try? await llama.props() {
                capabilities.vision = props.vision
                capabilities.audio = props.audio
            }
        }

        if engine.capabilities.supportsServerTools, let tools = try? await llama.tools() {
            capabilities.serverToolsAvailable = !tools.isEmpty
        }

        if capabilities.contextLength == nil {
            capabilities.contextLength = capabilities.model(id: modelID)?.contextLength
        }
        return Result(capabilities: capabilities, error: nil)
    }
}

/// A server found by scanning local ports.
public struct DiscoveredServer: Identifiable, Sendable, Hashable {
    public var engine: EngineKind
    public var baseURL: URL
    public var models: [String]

    public var id: String { baseURL.absoluteString }

    public var title: String {
        let port = baseURL.port.map { ":\($0)" } ?? ""
        return "\(engine.displayName) on \(port)"
    }

    public var subtitle: String {
        models.isEmpty ? "No models listed" : models.prefix(3).map(ModelNameFormatter.shortName).joined(separator: ", ")
    }

    public func makeConnection() -> ServerConnection {
        var connection = ServerConnection.preset(engine, name: engine.displayName, baseURL: baseURL)
        connection.defaultModelID = models.first
        return connection
    }
}

/// Finds inference servers on this Mac by probing the usual ports.
public enum LocalDiscovery {
    public static let defaultPorts = [8080, 8000, 1234, 11434, 8081, 8001, 8082, 5001]

    public static func scan(host: String = "127.0.0.1", ports: [Int] = defaultPorts, http: HTTPClient = URLSessionHTTPClient.shared) async -> [DiscoveredServer] {
        await withTaskGroup(of: DiscoveredServer?.self) { group in
            for port in ports {
                group.addTask { await probe(host: host, port: port, http: http) }
            }
            var found: [DiscoveredServer] = []
            for await server in group {
                if let server { found.append(server) }
            }
            return found.sorted { ($0.baseURL.port ?? 0) < ($1.baseURL.port ?? 0) }
        }
    }

    static func probe(host: String, port: Int, http: HTTPClient) async -> DiscoveredServer? {
        guard let base = URL(string: "http://\(host):\(port)") else { return nil }
        guard let modelsJSON = await getJSON(URLBuilder.join(base, "/v1/models"), http: http) else { return nil }
        let models = (try? ModelListParser.parse(modelsJSON.encoded())) ?? []
        let ids = models.map(\.id)
        let engine = await detectEngine(base: base, port: port, modelsJSON: modelsJSON, modelIDs: ids, http: http)
        return DiscoveredServer(engine: engine, baseURL: base, models: ids)
    }

    static func detectEngine(base: URL, port: Int, modelsJSON: JSONValue, modelIDs: [String], http: HTTPClient) async -> EngineKind {
        if let props = await getJSON(URLBuilder.join(base, "/props"), http: http), props["default_generation_settings"] != nil || props["build_info"] != nil {
            return .llamaCpp
        }
        if let tags = await getJSON(URLBuilder.join(base, "/api/tags"), http: http), tags["models"] != nil {
            return .ollama
        }
        if let version = await getJSON(URLBuilder.join(base, "/version"), http: http), version["version"] != nil {
            return .vllm
        }
        let firstEntry = modelsJSON["data"]?[0]
        if firstEntry?["loaded"] != nil { return .mlxVLM }
        if port == 1234 { return .lmStudio }
        if modelIDs.contains(where: { $0.lowercased().contains("deepseek") }) && port == 8000 { return .dwarfStar4 }
        if port == 8080 && modelIDs.contains(where: { $0.contains("mlx") }) { return .mlxLM }
        return .genericOpenAI
    }

    static func getJSON(_ url: URL, http: HTTPClient) async -> JSONValue? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        guard let (data, response) = try? await http.data(for: request), response.isSuccess else { return nil }
        return try? JSONValue.parse(data)
    }
}
