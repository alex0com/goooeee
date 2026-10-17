import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Errors from talking to an inference server, with a hint about what to do.
public enum InferenceError: Error, LocalizedError, Sendable, Equatable {
    /// Nothing is listening on the host/port.
    case connectionRefused(String)
    case cannotFindHost(String)
    case timedOut
    case cancelled
    /// The server answered with a non-2xx status.
    case http(status: Int, message: String)
    /// The server reported an error inside the stream.
    case server(String)
    case invalidResponse(String)
    case invalidRequest(String)
    case network(String)

    public static func from(_ error: Error) -> InferenceError {
        if let error = error as? InferenceError { return error }
        if error is CancellationError { return .cancelled }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            let host = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.host
                ?? (nsError.userInfo["NSErrorFailingURLStringKey"] as? String)
                ?? "server"
            switch nsError.code {
            case NSURLErrorCancelled: return .cancelled
            case NSURLErrorTimedOut: return .timedOut
            case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost: return .connectionRefused(host)
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return .cannotFindHost(host)
            default: break
            }
        }
        return .network(nsError.localizedDescription)
    }

    /// Builds an error from a non-2xx response body, extracting `{"error": {"message": …}}` and similar shapes.
    public static func fromHTTP(status: Int, body: Data) -> InferenceError {
        .http(status: status, message: extractMessage(from: body) ?? HTTPURLResponse.localizedString(forStatusCode: status))
    }

    static func extractMessage(from body: Data) -> String? {
        if let json = try? JSONValue.parse(body) {
            if let message = json["error"]?["message"]?.stringValue { return message }
            if let message = json["error"]?.stringValue { return message }
            if let message = json["message"]?.stringValue { return message }
            if let message = json["detail"]?.stringValue { return message }
            if let detail = json["detail"]?.arrayValue?.first?["msg"]?.stringValue { return detail }
        }
        let text = String(decoding: body.prefix(2000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    public var errorDescription: String? {
        switch self {
        case .connectionRefused(let host): "Connection refused by \(host)."
        case .cannotFindHost(let host): "Can't find host \(host)."
        case .timedOut: "The request timed out."
        case .cancelled: "Cancelled."
        case .http(let status, let message): "HTTP \(status): \(message)"
        case .server(let message): message
        case .invalidResponse(let message): "Unexpected response: \(message)"
        case .invalidRequest(let message): message
        case .network(let message): message
        }
    }

    /// What the user can do about it.
    public var recoverySuggestion: String? {
        switch self {
        case .connectionRefused: "Is the server running? Start it from the terminal or check the connection's URL and port."
        case .cannotFindHost: "Check the host name in the connection settings."
        case .timedOut: "The server took too long to respond. Long prompts can take minutes on local machines; raise the request timeout in the connection settings."
        case .http(401, _), .http(403, _): "Check the API key in the connection settings."
        case .http(404, _): "The server doesn't have this endpoint. Check the API prefix (usually /v1) and the engine preset."
        case .http(503, _): "The server is busy or still loading the model. Try again in a moment."
        case .http(let status, let message) where status == 400 && message.lowercased().contains("tool"):
            "Tool calling may not be enabled on the server. llama.cpp needs --jinja; vLLM needs --enable-auto-tool-choice and a --tool-call-parser."
        default: nil
        }
    }

    public var isCancellation: Bool { self == .cancelled }
}
