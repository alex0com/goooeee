import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ConnectionTestStep: Identifiable, Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case reachability, auth, models, capabilities, chat, vision, toolCalling, template

        public var title: String {
            switch self {
            case .reachability: "Reachability"
            case .auth: "Authentication"
            case .models: "Models"
            case .capabilities: "Capabilities"
            case .chat: "Streaming chat"
            case .vision: "Vision"
            case .toolCalling: "Tool calling"
            case .template: "Chat template"
            }
        }
    }

    public enum Status: String, Sendable, Hashable {
        case pending, running, passed, warning, failed, skipped
    }

    public var id: Kind
    public var status: Status
    public var detail: String
    public var hint: String?
    public var durationMs: Double?
    /// The request as a curl command.
    public var request: String?
    /// A response excerpt.
    public var response: String?

    public var title: String { id.title }

    public init(id: Kind, status: Status = .pending, detail: String = "", hint: String? = nil, durationMs: Double? = nil, request: String? = nil, response: String? = nil) {
        self.id = id
        self.status = status
        self.detail = detail
        self.hint = hint
        self.durationMs = durationMs
        self.request = request
        self.response = response
    }
}

/// Runs the connection checks shown in the connection editor's **Test** tab.
public struct ConnectionTester: Sendable {
    public struct Options: Sendable {
        public var modelID: String?
        public var testVision: Bool
        public var testToolCalling: Bool

        public init(modelID: String? = nil, testVision: Bool = false, testToolCalling: Bool = false) {
            self.modelID = modelID
            self.testVision = testVision
            self.testToolCalling = testToolCalling
        }
    }

    public var connection: ServerConnection
    public var apiKey: String?
    public var profiles: ProfileRegistry
    public var http: HTTPClient

    public init(connection: ServerConnection, apiKey: String?, profiles: ProfileRegistry, http: HTTPClient = URLSessionHTTPClient.shared) {
        self.connection = connection
        self.apiKey = apiKey
        self.profiles = profiles
        self.http = http
    }

    /// Streams snapshots of all steps as they progress.
    public func run(_ options: Options) -> AsyncStream<[ConnectionTestStep]> {
        AsyncStream { continuation in
            let task = Task {
                await execute(options) { continuation.yield($0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public static func summary(of steps: [ConnectionTestStep]) -> ConnectionTestSummary {
        let failed = steps.filter { $0.status == .failed }
        let warnings = steps.filter { $0.status == .warning }
        let message: String
        if let first = failed.first {
            message = "\(first.title): \(first.detail)"
        } else if !warnings.isEmpty {
            message = "Passed with \(warnings.count) warning\(warnings.count == 1 ? "" : "s")"
        } else {
            message = "All checks passed"
        }
        return ConnectionTestSummary(date: Date(), passed: failed.isEmpty, message: message)
    }

    private func execute(_ options: Options, publish: @Sendable ([ConnectionTestStep]) -> Void) async {
        var kinds: [ConnectionTestStep.Kind] = [.reachability, .auth, .models, .capabilities, .chat]
        if options.testVision { kinds.append(.vision) }
        if options.testToolCalling { kinds.append(.toolCalling) }
        if connection.chatTemplate != nil { kinds.append(.template) }
        var steps = kinds.map { ConnectionTestStep(id: $0) }

        func update(_ kind: ConnectionTestStep.Kind, _ change: (inout ConnectionTestStep) -> Void) {
            guard let index = steps.firstIndex(where: { $0.id == kind }) else { return }
            change(&steps[index])
            publish(steps)
        }
        func skipRemaining(after kind: ConnectionTestStep.Kind, reason: String) {
            var skipping = false
            for index in steps.indices {
                if skipping, steps[index].status == .pending {
                    steps[index].status = .skipped
                    steps[index].detail = reason
                }
                if steps[index].id == kind { skipping = true }
            }
            publish(steps)
        }
        publish(steps)

        // 1. Reachability
        update(.reachability) { $0.status = .running }
        let reachURL = connection.engine.healthPath.map { connection.rootURL($0) } ?? connection.apiURL("/models")
        var reachRequest = URLRequest(url: reachURL)
        reachRequest.timeoutInterval = 10
        RequestHeaders.apply(to: &reachRequest, connection: connection, apiKey: apiKey)
        let reachStart = MonotonicClock.now()
        var authStatus: Int?
        do {
            let (data, response) = try await http.data(for: reachRequest)
            let ms = (MonotonicClock.now() - reachStart) * 1000
            authStatus = response.statusCode
            update(.reachability) {
                $0.durationMs = ms
                $0.request = CurlRenderer.render(reachRequest)
                $0.response = "HTTP \(response.statusCode)\n" + String(decoding: data.prefix(1000), as: UTF8.self)
                if response.statusCode == 503 {
                    $0.status = .warning
                    $0.detail = "Server is up but still loading the model (HTTP 503)."
                } else {
                    $0.status = .passed
                    $0.detail = "\(connection.hostDescription) answered in \(MetricsFormatter.duration(ms: ms))."
                }
            }
        } catch {
            let mapped = InferenceError.from(error)
            update(.reachability) {
                $0.status = .failed
                $0.detail = mapped.localizedDescription
                $0.hint = mapped.recoverySuggestion
                $0.request = CurlRenderer.render(reachRequest)
            }
            skipRemaining(after: .reachability, reason: "Server not reachable")
            return
        }
        if Task.isCancelled { return }

        // 2–3. Auth + models
        update(.auth) { $0.status = .running }
        update(.models) { $0.status = .running }
        let provider = ProviderFactory.make(connection: connection, apiKey: apiKey, http: http)
        var models: [RemoteModel] = []
        do {
            models = try await provider.listModels()
            update(.auth) {
                $0.status = .passed
                $0.detail = (apiKey?.isEmpty ?? true) ? "No API key needed." : "API key accepted."
            }
            update(.models) {
                $0.status = models.isEmpty ? .warning : .passed
                $0.detail = models.isEmpty ? "The server listed no models." : "\(models.count) model\(models.count == 1 ? "" : "s"): " + models.prefix(4).map(\.displayName).joined(separator: ", ")
                if let wanted = options.modelID, !wanted.isEmpty, !models.contains(where: { $0.id == wanted || $0.aliases.contains(wanted) }) {
                    $0.status = .warning
                    $0.detail += ". The selected model “\(wanted)” isn't in the list."
                }
            }
        } catch {
            let mapped = InferenceError.from(error)
            if case .http(let status, _) = mapped, status == 401 || status == 403 {
                update(.auth) {
                    $0.status = .failed
                    $0.detail = mapped.localizedDescription
                    $0.hint = mapped.recoverySuggestion
                }
                skipRemaining(after: .auth, reason: "Authentication failed")
                return
            }
            update(.auth) { $0.status = authStatus == 401 || authStatus == 403 ? .failed : .passed }
            update(.models) {
                $0.status = .warning
                $0.detail = "Couldn't list models: \(mapped.localizedDescription)"
            }
        }
        if Task.isCancelled { return }

        let modelID = options.modelID ?? connection.defaultModelID ?? models.first?.id

        // 4. Capabilities
        update(.capabilities) { $0.status = .running }
        let probe = await ServerProbe(connection: connection, apiKey: apiKey, http: http).probe(modelID: modelID)
        let capabilities = probe.capabilities
        let profile = profiles.resolve(modelID: modelID, explicitID: connection.profileID)
        update(.capabilities) {
            var parts: [String] = []
            if let context = capabilities.contextLength(for: modelID) { parts.append("context \(MetricsFormatter.tokens(context))") }
            if let vision = capabilities.vision { parts.append(vision ? "vision" : "no vision") }
            if capabilities.isRouter { parts.append("router mode") }
            if capabilities.serverToolsAvailable { parts.append("server tools") }
            parts.append("profile: \(profile.displayName)")
            $0.status = .passed
            $0.detail = parts.joined(separator: " · ")
        }

        // 5. Chat
        update(.chat) { $0.status = .running }
        var settings = EffectiveSettings(profile: profile)
        settings.sampling[.maxTokens] = ResolvedValue(value: .int(profile.thinkingControl.alwaysThinks ? 1024 : 128), source: .connection)
        settings.thinking = profile.thinkingControl.alwaysThinks ? .low : .default
        let chatRequest = ChatRequest(model: modelID, messages: [.text(.user, "Reply with the single word OK.")], settings: settings)
        let chat = await runStream(provider: provider, request: chatRequest, profile: profile)
        update(.chat) {
            $0.request = (try? provider.makeURLRequest(chatRequest)).map { CurlRenderer.render($0) }
            switch chat {
            case .failure(let error):
                $0.status = .failed
                $0.detail = error.localizedDescription
                $0.hint = error.recoverySuggestion
            case .success(let outcome):
                $0.status = outcome.text.isEmpty && outcome.reasoning.isEmpty ? .warning : .passed
                var parts = ["“\(outcome.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))”"]
                if let ttft = outcome.metrics.ttftMs { parts.append("TTFT \(MetricsFormatter.duration(ms: ttft))") }
                if let speed = outcome.metrics.generationSpeed { parts.append("\(MetricsFormatter.speed(speed.value)) tok/s") }
                if !outcome.reasoning.isEmpty { parts.append("reasoning detected (\(outcome.reasoningViaField ? "separate field" : "tags in content"))") }
                $0.detail = parts.joined(separator: " · ")
                $0.response = outcome.text
            }
        }

        // 6. Vision
        if options.testVision {
            update(.vision) { $0.status = .running }
            if capabilities.vision == false {
                update(.vision) {
                    $0.status = .skipped
                    $0.detail = "The server reports no vision support for this model."
                }
            } else {
                let message = ChatMessage(role: .user, content: [.text("What color is this image? Answer in one word."), .image(data: CurlRenderer.tinyPNG, mimeType: "image/png")])
                let request = ChatRequest(model: modelID, messages: [message], settings: settings)
                let result = await runStream(provider: provider, request: request, profile: profile)
                update(.vision) {
                    switch result {
                    case .failure(let error):
                        $0.status = .failed
                        $0.detail = error.localizedDescription
                        $0.hint = "Vision needs a multimodal model (llama.cpp: --mmproj)."
                    case .success(let outcome):
                        $0.status = .passed
                        $0.detail = "Answered: “\(outcome.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))”"
                    }
                }
            }
        }

        // 7. Tool calling
        if options.testToolCalling {
            update(.toolCalling) { $0.status = .running }
            let request = ChatRequest(
                model: modelID,
                messages: [.text(.user, "What time is it in Tokyo right now? Use the get_current_time tool.")],
                settings: settings,
                tools: [CurlRenderer.exampleTool]
            )
            let result = await runStream(provider: provider, request: request, profile: profile)
            update(.toolCalling) {
                $0.request = (try? provider.makeURLRequest(request)).map { CurlRenderer.render($0) }
                switch result {
                case .failure(let error):
                    $0.status = .failed
                    $0.detail = error.localizedDescription
                    $0.hint = connection.engine == .llamaCpp
                        ? "Start llama-server with --jinja to enable tool calling."
                        : (connection.engine == .vllm ? "Start vLLM with --enable-auto-tool-choice --tool-call-parser <parser>." : error.recoverySuggestion)
                case .success(let outcome):
                    if let call = outcome.toolCalls.first {
                        $0.status = .passed
                        $0.detail = "Called \(call.name)(\(call.arguments))"
                    } else {
                        $0.status = .warning
                        $0.detail = "The model answered without calling the tool."
                        $0.hint = connection.engine == .llamaCpp ? "llama-server needs --jinja for tool calls." : "The server may not parse tool calls for this model."
                    }
                }
            }
        }

        // 8. Template
        if let template = connection.chatTemplate {
            update(.template) { $0.status = .running }
            do {
                let rendered = try ChatTemplateRenderer.validate(template)
                var detail = "Renders a sample conversation (\(rendered.count) characters)."
                if connection.engine == .llamaCpp {
                    let llama = LlamaCppClient(connection: connection, apiKey: apiKey, http: http)
                    if let serverPrompt = try? await llama.applyTemplate(messages: [.text(.system, "You are a helpful assistant."), .text(.user, "Hello!")]) {
                        detail += serverPrompt.isEmpty ? "" : " The server's own template is shown below for comparison."
                        update(.template) { $0.response = "Local:\n\(rendered)\n\nServer:\n\(serverPrompt)" }
                    }
                }
                update(.template) {
                    $0.status = .passed
                    $0.detail = detail
                    if $0.response == nil { $0.response = rendered }
                }
            } catch {
                update(.template) {
                    $0.status = .failed
                    $0.detail = error.localizedDescription
                }
            }
        }
    }

    struct StreamOutcome: Sendable {
        var text: String
        var reasoning: String
        var reasoningViaField: Bool
        var toolCalls: [ToolCall]
        var metrics: GenerationMetrics
    }

    private func runStream(provider: InferenceProvider, request: ChatRequest, profile: ModelProfile) async -> Result<StreamOutcome, InferenceError> {
        var accumulator = StreamAccumulator(splitter: ReasoningSplitter(format: profile.reasoning))
        var viaField = false
        do {
            for try await event in provider.stream(request) {
                if case .reasoningDelta = event { viaField = true }
                _ = accumulator.apply(event)
            }
            let blocks = accumulator.blocks
            let reasoning = blocks.filter(\.isThinking).map(\.text).joined()
            return .success(StreamOutcome(
                text: accumulator.currentText,
                reasoning: reasoning,
                reasoningViaField: viaField,
                toolCalls: accumulator.finalizeToolCalls(),
                metrics: accumulator.metrics
            ))
        } catch {
            return .failure(InferenceError.from(error))
        }
    }
}
