import Foundation

/// The user's login-shell environment.
///
/// Apps launched from the Finder get a minimal `PATH`, so `npx`, `uvx`, Homebrew and pyenv
/// binaries wouldn't be found. The login shell's `PATH` is read once (without starting an
/// interactive shell, whose rc files could print to stdout) and reused for MCP servers and
/// launch commands.
public enum ShellEnvironment {
    private static let cache = Cache()

    public static let fallbackPATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    public static var userShell: String {
        ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
    }

    /// `PATH` from `$SHELL -l -c`, cached. Falls back to the common Homebrew/system paths.
    public static func loginPATH() -> String {
        if let cached = cache.path { return cached }
        let resolved = readLoginPATH() ?? fallbackPATH
        let merged = merge(resolved, ProcessInfo.processInfo.environment["PATH"] ?? "", fallbackPATH)
        cache.path = merged
        return merged
    }

    /// The current environment with the login `PATH` and `extra` on top.
    public static func environment(adding extra: [String: String] = [:]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = loginPATH()
        for (key, value) in extra { environment[key] = value }
        return environment
    }

    /// Resolves a command name against `PATH` (or expands `~` for paths).
    public static func resolveExecutable(_ command: String, path: String? = nil) -> String? {
        let expanded = (command as NSString).expandingTildeInPath
        if expanded.contains("/") {
            return FileManager.default.isExecutableFile(atPath: expanded) ? expanded : nil
        }
        for directory in (path ?? loginPATH()).split(separator: ":") {
            let candidate = "\(directory)/\(expanded)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    static func readLoginPATH() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: userShell)
        process.arguments = ["-l", "-c", "printf '__GOOOEEE_PATH__%s' \"$PATH\""]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        guard let range = text.range(of: "__GOOOEEE_PATH__") else { return nil }
        let path = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    static func merge(_ paths: String...) -> String {
        var seen = Set<String>()
        var result: [String] = []
        for path in paths {
            for entry in path.split(separator: ":").map(String.init) where !entry.isEmpty && seen.insert(entry).inserted {
                result.append(entry)
            }
        }
        return result.joined(separator: ":")
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var _path: String?
        var path: String? {
            get { lock.withLock { _path } }
            set { lock.withLock { _path = newValue } }
        }
    }
}
