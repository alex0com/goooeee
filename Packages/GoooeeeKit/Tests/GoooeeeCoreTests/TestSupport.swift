import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import GoooeeeCore

/// Serves canned responses, split into chunks, and records requests.
final class StubHTTPClient: HTTPClient, @unchecked Sendable {
    struct Route {
        var status: Int
        var body: Data
        var chunkSize: Int
    }

    private let lock = NSLock()
    private var routes: [String: Route] = [:]
    private(set) var requests: [URLRequest] = []

    func set(_ path: String, status: Int = 200, body: Data, chunkSize: Int = 7) {
        lock.withLock { routes[path] = Route(status: status, body: body, chunkSize: chunkSize) }
    }

    func set(_ path: String, status: Int = 200, json: String) {
        set(path, status: status, body: Data(json.utf8), chunkSize: 1 << 20)
    }

    var lastBody: JSONValue? {
        lock.withLock { requests.last?.httpBody }.flatMap { try? JSONValue.parse($0) }
    }

    private func route(for request: URLRequest) throws -> Route {
        try lock.withLock {
            requests.append(request)
            let path = request.url?.path ?? ""
            guard let route = routes[path] else { throw InferenceError.connectionRefused("stub") }
            return route
        }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let route = try route(for: request)
        return (route.body, HTTPURLResponse(url: request.url!, statusCode: route.status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }

    func stream(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        let route = try route(for: request)
        let response = HTTPURLResponse(url: request.url!, statusCode: route.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            var offset = 0
            while offset < route.body.count {
                let end = min(offset + route.chunkSize, route.body.count)
                continuation.yield(route.body.subdata(in: offset..<end))
                offset = end
            }
            continuation.finish()
        }
        return (response, stream)
    }
}

enum Fixtures {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "sse", subdirectory: "Fixtures") else {
            throw InferenceError.invalidRequest("Missing fixture \(name)")
        }
        return try Data(contentsOf: url)
    }
}

/// Feeds a fixture through the SSE parser and a decoder in chunks of `chunkSize` bytes.
func decodeFixture<D: StreamDecoding>(_ name: String, chunkSize: Int, decoder: D) throws -> [StreamEvent] {
    var decoder = decoder
    let data = try Fixtures.data(name)
    var parser = SSEParser()
    var events: [StreamEvent] = []
    var offset = 0
    while offset < data.count {
        let end = min(offset + chunkSize, data.count)
        for event in parser.feed(data.subdata(in: offset..<end)) {
            events += try decoder.decode(event)
        }
        offset = end
    }
    for event in parser.finish() { events += try decoder.decode(event) }
    events += decoder.finish()
    return events
}

func collect(_ stream: AsyncThrowingStream<StreamEvent, Error>) async throws -> [StreamEvent] {
    var events: [StreamEvent] = []
    for try await event in stream { events.append(event) }
    return events
}

extension Array where Element == StreamEvent {
    var content: String {
        compactMap { if case .contentDelta(let text) = $0 { return text } else { return nil } }.joined()
    }

    var reasoning: String {
        compactMap { if case .reasoningDelta(let text) = $0 { return text } else { return nil } }.joined()
    }
}

/// Feeds text to a splitter in pieces of `size` characters and joins the result.
func split(_ text: String, format: ReasoningFormat, size: Int, thinkingDisabled: Bool = false) -> (content: String, reasoning: String, reclassified: Bool) {
    var splitter = ReasoningSplitter(format: format, thinkingDisabled: thinkingDisabled)
    var outputs: [ReasoningSplitter.Output] = []
    let characters = Array(text)
    var index = 0
    while index < characters.count {
        let end = min(index + size, characters.count)
        outputs += splitter.feed(String(characters[index..<end]))
        index = end
    }
    outputs += splitter.flush()
    var content = ""
    var reasoning = ""
    var reclassified = false
    for output in outputs {
        switch output {
        case .content(let text): content += text
        case .reasoning(let text): reasoning += text
        case .reclassifyContentAsReasoning:
            reclassified = true
            reasoning = content + reasoning
            content = ""
        }
    }
    return (content, reasoning, reclassified)
}

/// Path to the repo's Tools directory (for the Python mocks).
enum RepoPaths {
    static var tools: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // GoooeeeCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // GoooeeeKit
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()  // repo
            .appendingPathComponent("Tools")
    }

    static var python: String? {
        ["/usr/bin/python3", "/usr/local/bin/python3", "/opt/homebrew/bin/python3"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// Starts the Python mock server on a free port for integration tests.
final class MockServerProcess: @unchecked Sendable {
    let process = Process()
    let port: Int

    init?(engine: String = "llamacpp", extra: [String] = []) {
        guard let python = RepoPaths.python else { return nil }
        port = Int.random(in: 20_000..<40_000)
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [RepoPaths.tools.appendingPathComponent("MockServer/mock_server.py").path,
                             "--port", String(port), "--engine", engine, "--tps", "0"] + extra
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        // Wait for the port to accept connections.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if Self.isListening(port: port) { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.terminate()
        return nil
    }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    func stop() {
        if process.isRunning { process.terminate() }
    }

    deinit { stop() }

    static func isListening(port: Int) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/models")!)
        request.timeoutInterval = 0.5
        URLSession.shared.dataTask(with: request) { _, response, _ in
            box.ok = (response as? HTTPURLResponse) != nil
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 1)
        return box.ok
    }

    final class ResultBox: @unchecked Sendable { var ok = false }
}
