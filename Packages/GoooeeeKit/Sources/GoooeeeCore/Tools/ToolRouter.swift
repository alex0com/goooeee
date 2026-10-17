import Foundation

/// Context passed to a tool execution.
public struct ToolExecutionContext: Sendable {
    public var workspaceID: UUID
    public var conversationID: UUID
    public var workingDirectory: String?
    public var timeout: TimeInterval
    /// Progress updates (fraction 0…1 when known, message).
    public var onProgress: @Sendable (Double?, String?) -> Void

    public init(workspaceID: UUID, conversationID: UUID, workingDirectory: String?, timeout: TimeInterval, onProgress: @escaping @Sendable (Double?, String?) -> Void = { _, _ in }) {
        self.workspaceID = workspaceID
        self.conversationID = conversationID
        self.workingDirectory = workingDirectory
        self.timeout = timeout
        self.onProgress = onProgress
    }
}

/// A source of tools: the MCP host, llama.cpp server tools.
public protocol ToolProviding: Sendable {
    /// Tools offered for this selection, with `name == originalName` (the router assigns wire names).
    func tools(for selection: ToolSelection) async -> [ToolDefinition]
    func canExecute(_ tool: ToolDefinition) -> Bool
    func execute(_ tool: ToolDefinition, arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolResult
}

public enum ToolError: Error, LocalizedError, Equatable {
    case timedOut(TimeInterval)
    case unknownTool(String)
    case invalidArguments(String)
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .timedOut(let seconds): "The tool didn't finish within \(Int(seconds)) seconds."
        case .unknownTool(let name): "Unknown tool “\(name)”."
        case .invalidArguments(let message): "The arguments aren't valid JSON: \(message)"
        case .unavailable(let message): message
        }
    }
}

/// Aggregates tool sources and runs calls with a timeout.
public struct ToolRouter: Sendable {
    public var providers: [any ToolProviding]

    public init(providers: [any ToolProviding] = []) {
        self.providers = providers
    }

    public func tools(for selection: ToolSelection) async -> [ToolDefinition] {
        var all: [ToolDefinition] = []
        for provider in providers {
            all += await provider.tools(for: selection)
        }
        all = all.filter { !selection.disabledToolKeys.contains($0.key) }
        return ToolDefinition.assignWireNames(all)
    }

    public func execute(_ tool: ToolDefinition, call: ToolCall, context: ToolExecutionContext) async -> ToolResult {
        guard let arguments = call.parsedArguments else {
            return .text(ToolError.invalidArguments(call.arguments).localizedDescription, isError: true)
        }
        guard let provider = providers.first(where: { $0.canExecute(tool) }) else {
            return .text(ToolError.unknownTool(tool.name).localizedDescription, isError: true)
        }
        do {
            return try await withTimeout(seconds: context.timeout) {
                try await provider.execute(tool, arguments: arguments, context: context)
            }
        } catch is CancellationError {
            return .text("Cancelled.", isError: true)
        } catch {
            return .text((error as? LocalizedError)?.errorDescription ?? String(describing: error), isError: true)
        }
    }
}

/// Runs `operation`, throwing `ToolError.timedOut` if it takes longer than `seconds`.
///
/// Returns as soon as the deadline passes, even if `operation` ignores cancellation (a task
/// group would wait for it). The operation is cancelled and left to finish in the background.
public func withTimeout<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let gate = ResumeGate()
    let box = TaskBox()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let work = Task {
                do {
                    let value = try await operation()
                    if gate.claim() { continuation.resume(returning: value) }
                } catch {
                    if gate.claim() { continuation.resume(throwing: error) }
                }
            }
            let timer = Task {
                try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0.001) * 1_000_000_000))
                if gate.claim() {
                    work.cancel()
                    continuation.resume(throwing: ToolError.timedOut(seconds))
                }
            }
            box.set(work: work, timer: timer) {
                if gate.claim() { continuation.resume(throwing: CancellationError()) }
            }
        }
    } onCancel: {
        box.cancel()
    }
}

/// Ensures a continuation is resumed exactly once.
final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            if claimed { return false }
            claimed = true
            return true
        }
    }
}

/// Holds the tasks of `withTimeout` so outer cancellation can reach them.
final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var onCancel: (@Sendable () -> Void)?
    private var cancelled = false

    func set(work: Task<Void, Never>, timer: Task<Void, Never>, onCancel: @escaping @Sendable () -> Void) {
        let alreadyCancelled = lock.withLock {
            self.work = work
            self.timer = timer
            self.onCancel = onCancel
            return cancelled
        }
        if alreadyCancelled { cancel() }
    }

    func cancel() {
        let (work, timer, onCancel) = lock.withLock {
            cancelled = true
            return (self.work, self.timer, self.onCancel)
        }
        work?.cancel()
        timer?.cancel()
        onCancel?()
    }
}

/// llama.cpp server tools (`--tools`, `--mcp-servers-config`) exposed through `/tools`.
public final class LlamaServerToolSource: ToolProviding, @unchecked Sendable {
    private let client: LlamaCppClient
    private let lock = NSLock()
    private var cached: [ToolDefinition]?

    public init(client: LlamaCppClient) {
        self.client = client
    }

    public func tools(for selection: ToolSelection) async -> [ToolDefinition] {
        guard selection.serverToolsEnabled else { return [] }
        if let cached = lock.withLock({ cached }) { return cached }
        let tools = ((try? await client.tools()) ?? []).map(\.toolDefinition)
        lock.withLock { cached = tools }
        return tools
    }

    public func refresh() {
        lock.withLock { cached = nil }
    }

    public func canExecute(_ tool: ToolDefinition) -> Bool {
        tool.sourceKind == .serverTools
    }

    public func execute(_ tool: ToolDefinition, arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolResult {
        try await client.executeTool(name: tool.originalName, arguments: arguments, workingDirectory: context.workingDirectory, timeout: context.timeout)
    }
}
