import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import GoooeeeCore
import Logging
import MCP

/// The legacy MCP HTTP+SSE transport (protocol 2024-11-05): a long-lived `GET` stream that
/// first announces a POST endpoint (`event: endpoint`), then delivers messages (`event: message`).
public actor LegacySSETransport: Transport {
    public let logger: Logger

    private let url: URL
    private let headers: [String: String]
    private let http: HTTPClient
    private var endpoint: URL?
    private var streamTask: Task<Void, Never>?
    private let stream: AsyncThrowingStream<Data, Swift.Error>
    private let continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    private var endpointWaiters: [CheckedContinuation<URL, Swift.Error>] = []

    public init(url: URL, headers: [String: String] = [:], http: HTTPClient = URLSessionHTTPClient(configuration: .default)) {
        self.url = url
        self.headers = headers
        self.http = http
        self.logger = Logger(label: "goooeee.mcp.sse")
        (stream, continuation) = AsyncThrowingStream<Data, Swift.Error>.makeStream(bufferingPolicy: .unbounded)
    }

    public func connect() async throws {
        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 24 * 60 * 60
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let http = self.http
        let continuation = self.continuation
        streamTask = Task { [weak self] in
            do {
                let (response, bytes) = try await http.stream(for: request)
                guard response.isSuccess else {
                    throw MCPError.internalError("SSE endpoint answered HTTP \(response.statusCode)")
                }
                var parser = SSEParser()
                for try await chunk in bytes {
                    for event in parser.feed(chunk) {
                        await self?.handle(event)
                    }
                }
                continuation.finish(throwing: MCPError.connectionClosed)
            } catch {
                await self?.failWaiters(error)
                continuation.finish(throwing: error)
            }
        }
        _ = try await withTimeout(seconds: 15) { [weak self] in
            guard let self else { throw MCPError.connectionClosed }
            return try await self.waitForEndpoint()
        }
    }

    private func waitForEndpoint() async throws -> URL {
        if let endpoint { return endpoint }
        return try await withCheckedThrowingContinuation { waiter in
            endpointWaiters.append(waiter)
        }
    }

    private func handle(_ event: SSEEvent) {
        switch event.event {
        case "endpoint":
            let target = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let resolved = URL(string: target, relativeTo: url)?.absoluteURL else { return }
            endpoint = resolved
            let waiters = endpointWaiters
            endpointWaiters = []
            for waiter in waiters { waiter.resume(returning: resolved) }
        case "message", nil:
            if !event.data.isEmpty { continuation.yield(Data(event.data.utf8)) }
        default:
            break
        }
    }

    private func failWaiters(_ error: Swift.Error) {
        let waiters = endpointWaiters
        endpointWaiters = []
        for waiter in waiters { waiter.resume(throwing: error) }
    }

    public func disconnect() async {
        streamTask?.cancel()
        streamTask = nil
        failWaiters(MCPError.connectionClosed)
        continuation.finish()
    }

    public func send(_ data: Data) async throws {
        guard let endpoint else { throw MCPError.connectionClosed }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (body, response) = try await http.data(for: request)
        guard response.isSuccess else {
            throw MCPError.internalError("POST \(endpoint.path) answered HTTP \(response.statusCode): \(String(decoding: body.prefix(300), as: UTF8.self))")
        }
    }

    public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        stream
    }
}
