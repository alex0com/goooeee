import Foundation
import Testing
@testable import GoooeeeCore
@testable import GoooeeeMCP

private enum Mock {
    static var python: String? {
        ["/usr/bin/python3", "/usr/local/bin/python3", "/opt/homebrew/bin/python3"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var script: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tools/MockMCP/mock_mcp_server.py").path
    }

    static func config(_ extra: [String] = [], name: String = "mock") -> MCPServerConfig {
        MCPServerConfig(name: name, transport: .stdio(command: python ?? "python3", args: [script] + extra, env: [:], cwd: nil))
    }
}

final class TestMCPDelegate: MCPClientDelegate, @unchecked Sendable {
    func elicit(serverName: String, message: String, schema: JSONValue) async -> MCPElicitationResponse { .decline }
    func elicitURL(serverName: String, message: String, url: URL) async -> MCPElicitationResponse { .decline }
    func sample(serverName: String, request: MCPSamplingRequest) async throws -> String { "sampled" }
    func roots() async -> [URL] { [URL(fileURLWithPath: "/tmp")] }
}

@Suite("MCP host", .serialized, .enabled(if: Mock.python != nil))
struct MCPHostTests {
    func context() -> ToolExecutionContext {
        ToolExecutionContext(workspaceID: UUID(), conversationID: UUID(), workingDirectory: nil, timeout: 10)
    }

    @Test func connectsListsAndCallsTools() async throws {
        let host = MCPHost(secrets: InMemorySecretStore(), delegate: TestMCPDelegate())
        let config = Mock.config()
        await host.update(servers: [config])
        let tools = await host.tools(for: ToolSelection(mcpServerIDs: [config.id]))
        #expect(Set(tools.map(\.name)) == ["echo", "add", "slow", "image", "fail"])
        #expect(tools.first { $0.name == "echo" }?.readOnlyHint == true)

        let state = try #require(await host.state(for: config.id))
        #expect(state.phase == .connected)
        #expect(state.serverName == "mock-mcp")
        #expect(state.instructions == "Mock server for tests.")
        #expect(Set(state.capabilities).isSuperset(of: ["tools", "prompts", "resources", "logging"]))

        let echo = try #require(tools.first { $0.name == "echo" })
        let result = try await host.execute(echo, arguments: ["text": "hello"], context: context())
        #expect(result.textForModel == "hello")

        let add = try #require(tools.first { $0.name == "add" })
        #expect(try await host.execute(add, arguments: ["a": 2, "b": 3.5], context: context()).textForModel == "5.5")

        let image = try #require(tools.first { $0.name == "image" })
        #expect(try await host.execute(image, arguments: [:], context: context()).images.count == 1)

        let fail = try #require(tools.first { $0.name == "fail" })
        #expect(try await host.execute(fail, arguments: [:], context: context()).isError)

        await host.disconnectAll()
    }

    @Test func progressNotifications() async throws {
        let host = MCPHost(secrets: InMemorySecretStore())
        let config = Mock.config()
        await host.update(servers: [config])
        let tools = await host.tools(for: ToolSelection(mcpServerIDs: [config.id]))
        let slow = try #require(tools.first { $0.name == "slow" })
        let recorder = ProgressRecorder()
        var context = context()
        context.onProgress = { fraction, message in recorder.add(fraction, message) }
        let result = try await host.execute(slow, arguments: ["seconds": 0.3], context: context)
        #expect(result.textForModel == "done")
        #expect(recorder.values.count == 3)
        #expect(recorder.values.last?.0 == 1)
        await host.disconnectAll()
    }

    @Test func promptsAndResources() async throws {
        let host = MCPHost(secrets: InMemorySecretStore())
        let config = Mock.config()
        await host.update(servers: [config])
        let prompts = await host.prompts(serverIDs: [config.id])
        let greet = try #require(prompts.first)
        #expect(greet.arguments.first?.required == true)
        let attachments = try await host.getPrompt(greet, arguments: ["name": "Ada"])
        #expect(attachments.first?.kind == .mcpPrompt)
        #expect(attachments.first?.text == "Please greet Ada warmly.")

        let resources = await host.resources(serverIDs: [config.id])
        #expect(resources.first?.uri == "mock://readme")
        let readme = try await host.readResource(serverID: config.id, uri: "mock://readme")
        #expect(readme.text == "# Contents of mock://readme")

        let templates = await host.resourceTemplates(serverIDs: [config.id])
        let note = try #require(templates.first)
        #expect(note.variables == ["id"])
        #expect(note.expand(["id": "a b"]) == "mock://notes/a%20b")
        await host.disconnectAll()
    }

    @Test func toleratesMalformedLinesAndStderr() async throws {
        let host = MCPHost(secrets: InMemorySecretStore())
        let config = Mock.config(["--malformed", "--stderr"])
        await host.update(servers: [config])
        let tools = await host.tools(for: ToolSelection(mcpServerIDs: [config.id]))
        #expect(!tools.isEmpty)
        let state = await host.state(for: config.id)
        #expect(state?.logs.contains { $0.level == .stderr } == true)
        await host.disconnectAll()
    }

    @Test func handshakeTimeoutFails() async throws {
        let host = MCPHost(secrets: InMemorySecretStore())
        await host.setHandshakeTimeout(0.5)
        let config = Mock.config(["--slow-init", "5"])
        await host.update(servers: [config])
        await host.connect(config.id)
        let state = await host.state(for: config.id)
        #expect(state?.phase == .failed || state?.phase == .reconnecting)
        #expect(state?.error != nil)
        await host.disconnectAll()
    }

    @Test func reconnectsAfterCrash() async throws {
        let host = MCPHost(secrets: InMemorySecretStore())
        // Crashes after: initialize, tools/list, prompts/list, resources/list, templates, setLevel, then the next call.
        let config = Mock.config(["--crash-after", "7"])
        await host.update(servers: [config])
        let tools = await host.tools(for: ToolSelection(mcpServerIDs: [config.id]))
        let echo = try #require(tools.first { $0.name == "echo" })
        _ = try? await host.execute(echo, arguments: ["text": "x"], context: context())
        // Wait for the reconnect (1 s backoff).
        var reconnected = false
        for _ in 0..<60 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if let state = await host.state(for: config.id), state.phase == .connected,
                state.logs.contains(where: { $0.message.contains("exited") || $0.message.contains("Retrying") })
            {
                reconnected = true
                break
            }
        }
        #expect(reconnected)
        await host.disconnectAll()
    }

    @Test func missingCommandReportsError() async throws {
        let host = MCPHost(secrets: InMemorySecretStore())
        let config = MCPServerConfig(name: "missing", transport: .stdio(command: "definitely-not-a-command-xyz", args: [], env: [:], cwd: nil))
        await host.update(servers: [config])
        await host.connect(config.id)
        let state = await host.state(for: config.id)
        #expect(state?.error?.contains("Command not found") == true)
        await host.disconnectAll()
    }

    @Test func disabledServersAreSkipped() async throws {
        let host = MCPHost(secrets: InMemorySecretStore())
        var config = Mock.config()
        config.isEnabled = false
        await host.update(servers: [config])
        #expect(await host.tools(for: ToolSelection(mcpServerIDs: [config.id])).isEmpty)
    }
}

final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(Double?, String?)] = []

    func add(_ fraction: Double?, _ message: String?) {
        lock.withLock { storage.append((fraction, message)) }
    }

    var values: [(Double?, String?)] { lock.withLock { storage } }
}
