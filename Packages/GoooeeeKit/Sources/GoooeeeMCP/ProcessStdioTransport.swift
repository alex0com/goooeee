import Foundation
import GoooeeeCore
import Logging
import MCP

/// MCP stdio transport for a server process that goooeee launches itself:
/// newline-delimited JSON-RPC on the child's stdin/stdout, stderr captured for the log.
public actor ProcessStdioTransport: Transport {
    public let logger: Logger

    private let command: String
    private let arguments: [String]
    private let environment: [String: String]
    private let workingDirectory: String?
    private let onStderr: @Sendable (String) -> Void
    private let onExit: @Sendable (Int32) -> Void

    private var process: Process?
    private var stdin: FileHandle?
    private let stream: AsyncThrowingStream<Data, Swift.Error>
    private let continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    private var stopping = false

    public init(
        command: String,
        arguments: [String],
        environment: [String: String] = [:],
        workingDirectory: String? = nil,
        onStderr: @escaping @Sendable (String) -> Void = { _ in },
        onExit: @escaping @Sendable (Int32) -> Void = { _ in }
    ) {
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.onStderr = onStderr
        self.onExit = onExit
        self.logger = Logger(label: "goooeee.mcp.stdio")
        (stream, continuation) = AsyncThrowingStream<Data, Swift.Error>.makeStream(bufferingPolicy: .unbounded)
    }

    public func connect() async throws {
        let path = ShellEnvironment.loginPATH()
        guard let executable = ShellEnvironment.resolveExecutable(command, path: path) else {
            throw MCPError.internalError("Command not found: \(command). Check that it's installed and on your PATH.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = ShellEnvironment.environment(adding: environment)
        env["PATH"] = path
        process.environment = env
        if let workingDirectory, !workingDirectory.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: (workingDirectory as NSString).expandingTildeInPath)
        }

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        let stdoutBuffer = LineBuffer()
        let continuation = self.continuation
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            for line in stdoutBuffer.append(data) where !line.isEmpty {
                continuation.yield(line)
            }
        }
        let stderrBuffer = LineBuffer()
        let onStderr = self.onStderr
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            for line in stderrBuffer.append(data) where !line.isEmpty {
                onStderr(String(decoding: line, as: UTF8.self))
            }
        }
        let onExit = self.onExit
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            Task { await self?.processExited(status: status) }
            onExit(status)
        }

        do {
            try process.run()
        } catch {
            throw MCPError.internalError("Couldn't start \(executable): \(error.localizedDescription)")
        }
        self.process = process
        self.stdin = input.fileHandleForWriting
    }

    private func processExited(status: Int32) {
        if stopping {
            continuation.finish()
        } else {
            continuation.finish(throwing: MCPError.connectionClosed)
        }
        process = nil
        stdin = nil
    }

    public func disconnect() async {
        stopping = true
        try? stdin?.close()
        stdin = nil
        if let process, process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < deadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            #if canImport(Darwin)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            #else
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            #endif
        }
        process = nil
        continuation.finish()
    }

    public func send(_ data: Data) async throws {
        guard let stdin else { throw MCPError.connectionClosed }
        var message = data
        if message.last != 0x0A { message.append(0x0A) }
        do {
            try stdin.write(contentsOf: message)
        } catch {
            throw MCPError.transportError(error)
        }
    }

    public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        stream
    }
}

/// Splits incoming bytes into lines.
final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ data: Data) -> [Data] {
        lock.withLock {
            buffer.append(data)
            var lines: [Data] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                var line = buffer[buffer.startIndex..<newline]
                if line.last == 0x0D { line = line.dropLast() }
                lines.append(Data(line))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            return lines
        }
    }
}
