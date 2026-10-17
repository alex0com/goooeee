import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Minimal HTTP abstraction so providers can be tested with stubs and work on macOS and Linux.
public protocol HTTPClient: Sendable {
    /// Performs a request and returns the whole body.
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// Performs a request and streams the body as it arrives.
    func stream(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>)
}

/// `URLSession`-based client using a data delegate, so streaming works on both platforms
/// (`URLSession.bytes(for:)` is not available in swift-corelibs-foundation).
public final class URLSessionHTTPClient: NSObject, HTTPClient, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [Int: TaskHandler] = [:]
    private var session: URLSession!

    public init(configuration: URLSessionConfiguration = .default) {
        super.init()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "goooeee.http"
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    public static let shared = URLSessionHTTPClient()

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (response, stream) = try await stream(for: request)
        var body = Data()
        for try await chunk in stream {
            body.append(chunk)
        }
        return (body, response)
    }

    public func stream(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .unbounded)
        let task = session.dataTask(with: request)
        let handler = TaskHandler(continuation: continuation)
        lock.withLock { handlers[task.taskIdentifier] = handler }
        continuation.onTermination = { @Sendable termination in
            if case .cancelled = termination { task.cancel() }
        }
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (responseContinuation: CheckedContinuation<HTTPURLResponse, Error>) in
                handler.setResponseContinuation(responseContinuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        return (response, stream)
    }

    private func handler(for task: URLSessionTask) -> TaskHandler? {
        lock.withLock { handlers[task.taskIdentifier] }
    }

    // MARK: URLSessionDataDelegate

    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        // Linux can report a proxy's CONNECT response before the real one, so the response is
        // only delivered to the caller with the first body bytes or on completion.
        handler(for: dataTask)?.setLatestResponse(response as? HTTPURLResponse)
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let handler = handler(for: dataTask) else { return }
        handler.deliverResponseIfNeeded()
        handler.yield(data)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let handler = lock.withLock { handlers.removeValue(forKey: task.taskIdentifier) }
        guard let handler else { return }
        if let error {
            handler.fail(InferenceError.from(error))
        } else {
            handler.deliverResponseIfNeeded()
            handler.finish()
        }
    }
}

private final class TaskHandler: @unchecked Sendable {
    private let lock = NSLock()
    private var responseContinuation: CheckedContinuation<HTTPURLResponse, Error>?
    private var latestResponse: HTTPURLResponse?
    private var responseDelivered = false
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    init(continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        self.continuation = continuation
    }

    func setResponseContinuation(_ continuation: CheckedContinuation<HTTPURLResponse, Error>) {
        lock.withLock { responseContinuation = continuation }
    }

    func setLatestResponse(_ response: HTTPURLResponse?) {
        lock.withLock { latestResponse = response }
    }

    func deliverResponseIfNeeded() {
        let pending: (CheckedContinuation<HTTPURLResponse, Error>, HTTPURLResponse?)? = lock.withLock {
            guard !responseDelivered, let responseContinuation else { return nil }
            responseDelivered = true
            self.responseContinuation = nil
            return (responseContinuation, latestResponse)
        }
        guard let (continuation, response) = pending else { return }
        if let response {
            continuation.resume(returning: response)
        } else {
            continuation.resume(throwing: InferenceError.invalidResponse("No HTTP response"))
        }
    }

    func yield(_ data: Data) {
        continuation.yield(data)
    }

    func finish() {
        continuation.finish()
    }

    func fail(_ error: Error) {
        let pending: CheckedContinuation<HTTPURLResponse, Error>? = lock.withLock {
            guard !responseDelivered else { return nil }
            responseDelivered = true
            defer { responseContinuation = nil }
            return responseContinuation
        }
        pending?.resume(throwing: error)
        continuation.finish(throwing: error)
    }
}

extension HTTPURLResponse {
    public var isSuccess: Bool { (200..<300).contains(statusCode) }
}
