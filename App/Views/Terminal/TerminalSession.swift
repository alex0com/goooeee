import AppKit
import Darwin
import GoooeeeCore
import Observation
import SwiftTerm

/// The terminal of one workspace window: a login shell in a pseudo-terminal (SwiftTerm).
///
/// The shell starts the first time the terminal is shown or a command is sent to it. Launch
/// commands run in that shell, so their output stays visible and Ctrl-C stops them.
@MainActor
@Observable
final class TerminalSession: NSObject {
    private(set) var title = "Terminal"
    private(set) var currentDirectory: String?
    private(set) var isShellRunning = false
    private(set) var lastExitCode: Int32?
    /// A launch command was started and the server hasn't answered its health check yet.
    var isServerStarting = false

    @ObservationIgnored private(set) var workingDirectory: String?
    @ObservationIgnored private var terminalView: LocalProcessTerminalView?
    /// Set when `startServer` ran a command; cleared when the shell is back at its prompt.
    @ObservationIgnored private var launchedServer = false
    /// Input sent while a new shell is still starting; it's sent once the prompt is ready.
    @ObservationIgnored private var pendingInput: [@MainActor () -> Void] = []
    @ObservationIgnored private var promptWait: Task<Void, Never>?

    init(workingDirectory: String?) {
        self.workingDirectory = workingDirectory
        super.init()
    }

    /// The terminal view, created (and the shell started) on first use.
    var view: LocalProcessTerminalView {
        if let terminalView { return terminalView }
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 240))
        view.processDelegate = self
        view.optionAsMetaKey = true
        applyAppearance(to: view)
        terminalView = view
        startShell(in: view)
        return view
    }

    var hasView: Bool { terminalView != nil }

    /// A server started from this terminal is still running in the foreground.
    var hasRunningServer: Bool {
        guard launchedServer, isShellRunning else { return false }
        if foregroundIsShell {
            return false
        }
        return true
    }

    /// The shell is waiting at its prompt (nothing runs in the foreground).
    private var foregroundIsShell: Bool {
        guard let process = terminalView?.process, process.running, process.childfd >= 0 else { return true }
        let group = tcgetpgrp(process.childfd)
        return group <= 0 || group == process.shellPid
    }

    func setWorkingDirectory(_ path: String?) {
        workingDirectory = path
    }

    // MARK: Shell

    private func startShell(in view: LocalProcessTerminalView) {
        let settings = AppModel.shared.settings
        let shell = settings.terminalShell.flatMap { $0.isEmpty ? nil : $0 } ?? ShellEnvironment.userShell
        var environment = ShellEnvironment.environment(adding: [
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "TERM_PROGRAM": "goooeee",
        ])
        if environment["LANG"] == nil { environment["LANG"] = "en_US.UTF-8" }
        let directory = existingDirectory(workingDirectory) ?? FileManager.default.homeDirectoryForCurrentUser.path
        let shellName = "-" + (shell as NSString).lastPathComponent
        view.startProcess(
            executable: shell,
            args: [],
            environment: environment.map { "\($0.key)=\($0.value)" },
            execName: shellName,
            currentDirectory: directory
        )
        currentDirectory = directory
        isShellRunning = true
        lastExitCode = nil
        waitForPrompt()
    }

    /// Holds input back until the shell's line editor is running. Typed earlier, the pty echoes
    /// it before the prompt and the shell shows it a second time.
    private func waitForPrompt() {
        promptWait?.cancel()
        promptWait = Task { [weak self] in
            // zsh with a large rc file takes ~40 ms; give up after 3 s and send anyway.
            for _ in 0..<150 {
                guard let self, !Task.isCancelled else { return }
                if self.lineEditorIsActive { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard let self, !Task.isCancelled else { return }
            self.promptWait = nil
            let input = self.pendingInput
            self.pendingInput = []
            input.forEach { $0() }
        }
    }

    /// zsh, bash and sh turn off canonical mode on the pty while they read a command line.
    private var lineEditorIsActive: Bool {
        guard let process = terminalView?.process, process.running, process.childfd >= 0 else { return false }
        var attributes = termios()
        guard tcgetattr(process.childfd, &attributes) == 0 else { return false }
        return attributes.c_lflag & tcflag_t(ICANON) == 0
    }

    /// Starts a fresh shell after the previous one exited (or on request).
    func restartShell() {
        guard let view = terminalView else {
            _ = self.view
            return
        }
        if isShellRunning { view.terminate() }
        launchedServer = false
        isServerStarting = false
        view.getTerminal().resetToInitialState()
        startShell(in: view)
    }

    private func existingDirectory(_ path: String?) -> String? {
        guard let path else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory) && isDirectory.boolValue ? expanded : nil
    }

    // MARK: Commands

    /// Types a command into the shell and presses Return.
    func run(_ command: String) {
        let view = self.view
        if !isShellRunning { startShell(in: view) }
        whenPromptReady { [weak self] in self?.send(command + "\r") }
    }

    private func whenPromptReady(_ action: @escaping @MainActor () -> Void) {
        if promptWait != nil {
            pendingInput.append(action)
        } else {
            action()
        }
    }

    /// Puts text at the shell prompt as a paste, without pressing Return, so it can be checked
    /// and edited first. Used for code blocks from the chat.
    func paste(_ text: String) {
        let view = self.view
        if !isShellRunning { startShell(in: view) }
        let text = Self.pasteableText(text)
        whenPromptReady { [weak self] in
            guard let self, let terminalView = self.terminalView else { return }
            if terminalView.getTerminal().bracketedPasteMode {
                self.send("\u{1b}[200~" + text + "\u{1b}[201~")
            } else {
                // Shells without bracketed paste (macOS's bash 3.2) would run each line and
                // complete on tabs. Ctrl-V before them inserts them literally.
                self.send(text.replacingOccurrences(of: "\n", with: "\u{16}\n").replacingOccurrences(of: "\t", with: "\u{16}\t"))
            }
        }
        DispatchQueue.main.async { [weak view] in view?.window?.makeFirstResponder(view) }
    }

    /// Code from the model, made safe to paste: newlines normalized, trailing newlines dropped (they
    /// would press Return) and control characters removed. An escape sequence in the text could
    /// otherwise end the paste early and run the rest.
    static func pasteableText(_ text: String) -> String {
        var text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        text.unicodeScalars.removeAll { scalar in
            scalar != "\n" && scalar != "\t" && scalar.properties.generalCategory == .control
        }
        while text.hasSuffix("\n") { text.removeLast() }
        return text
    }

    /// Runs a server launch command in the shell (`cd` + environment + command).
    func startServer(command: String, workingDirectory: String?, environment: [String: String]) {
        var parts: [String] = []
        if let directory = existingDirectory(workingDirectory) {
            parts.append("cd \(Self.quote(directory)) &&")
        }
        let assignments = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\(Self.quote($0.value))" }
        if !assignments.isEmpty { parts.append("env " + assignments.joined(separator: " ")) }
        // Continuation lines in the saved command are joined so the shell sees one command.
        let joined = command
            .replacingOccurrences(of: "\\\n", with: " ")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        parts.append(joined)
        launchedServer = true
        isServerStarting = true
        run(parts.joined(separator: " "))
    }

    /// Ctrl-C to the foreground process.
    func interrupt() {
        guard terminalView != nil else { return }
        send("\u{03}")
        isServerStarting = false
    }

    func clear() {
        guard let view = terminalView else { return }
        // Clear the screen and scrollback the way ⌘K does in Terminal.app.
        view.feed(text: "\u{1b}[H\u{1b}[2J\u{1b}[3J")
        send("\u{0c}")
    }

    func send(_ text: String) {
        terminalView?.send(txt: text)
    }

    /// Ends the shell (window closing). Child processes get SIGHUP from the closed pty.
    func terminate() {
        promptWait?.cancel()
        promptWait = nil
        pendingInput = []
        guard let view = terminalView, isShellRunning else { return }
        view.terminate()
        isShellRunning = false
        launchedServer = false
    }

    // MARK: Appearance

    func applyAppearance() {
        guard let terminalView else { return }
        applyAppearance(to: terminalView)
    }

    private func applyAppearance(to view: LocalProcessTerminalView) {
        let settings = AppModel.shared.settings
        view.font = SettingsStore.nsFont(settings.terminalFont, monospaced: true)
        view.nativeForegroundColor = .textColor
        view.nativeBackgroundColor = .textBackgroundColor
        view.caretColor = .controlAccentColor
        view.changeScrollback(max(1000, settings.terminalScrollback))
    }

    private static func quote(_ value: String) -> String {
        if value.allSatisfy({ $0.isLetter || $0.isNumber || "-_./:=@%+,".contains($0) }) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - LocalProcessTerminalViewDelegate

extension TerminalSession: LocalProcessTerminalViewDelegate {
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        MainActor.assumeIsolated {
            self.title = title.isEmpty ? "Terminal" : title
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        MainActor.assumeIsolated {
            // OSC 7 reports file://host/path.
            if let directory, let url = URL(string: directory), url.isFileURL {
                self.currentDirectory = url.path
            } else if let directory {
                self.currentDirectory = directory
            }
        }
    }

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        MainActor.assumeIsolated {
            self.isShellRunning = false
            self.launchedServer = false
            self.isServerStarting = false
            self.lastExitCode = exitCode
        }
    }
}
