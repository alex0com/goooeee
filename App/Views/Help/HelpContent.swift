import Foundation

/// One page of the Help window.
struct HelpTopic: Identifiable, Hashable {
    let id: String
    var title: String
    var symbol: String
    var summary: String
    var blocks: [HelpBlock]

    /// Everything a search can match.
    var searchText: String {
        ([title, summary] + blocks.flatMap(\.searchText)).joined(separator: "\n").lowercased()
    }
}

struct HelpShortcut: Hashable {
    var keys: String
    var action: String
}

/// Text uses inline Markdown: **bold**, *italic*, `code` and [links](https://…).
enum HelpBlock: Hashable {
    case heading(String)
    case text(String)
    case bullets([String])
    case steps([String])
    case note(String)
    case shortcuts([HelpShortcut])
    /// Live list of everything goooeee stores, with sizes and Show in Finder.
    case fileLocations
    /// Each workspace's working folder.
    case workspaceFolders
    case backupCommands
    case uninstallCommands

    var searchText: [String] {
        switch self {
        case .heading(let text), .text(let text), .note(let text): [text]
        case .bullets(let items), .steps(let items): items
        case .shortcuts(let shortcuts): shortcuts.map { "\($0.keys) \($0.action)" }
        case .fileLocations: AppFiles.locations.map { "\($0.title) \($0.contents) \($0.url.map(AppFiles.displayPath) ?? "keychain")" }
        case .workspaceFolders: ["working folder working directory"]
        case .backupCommands: ["backup copy database"]
        case .uninstallCommands: ["uninstall remove delete everything"]
        }
    }
}

extension HelpTopic {
    static let all: [HelpTopic] = [
        filesAndData, gettingStarted, connections, chatting, settings, codeBlocks, terminal, tools,
        shortcuts, troubleshooting, backupAndUninstall,
    ]

    static func topic(id: String) -> HelpTopic? { all.first { $0.id == id } }

    // MARK: Files & Data

    static let filesAndData = HelpTopic(
        id: "files",
        title: "Files & Data",
        symbol: "externaldrive",
        summary: "Where goooeee keeps your chats, settings and keys.",
        blocks: [
            .text("goooeee is a single app. It doesn't install helpers, login items, command-line tools or system extensions, and it doesn't run models itself: it talks to the servers you connect it to. Everything it stores is listed below, with the real paths on this Mac."),
            .fileLocations,
            .heading("Files you create"),
            .text("Code blocks you save with **Save As…** go where you choose. The save dialog and the terminal start in the workspace's working folder, which you set in the inspector's Workspace section:"),
            .workspaceFolders,
            .heading("Where your chats go"),
            .bullets([
                "Messages are sent only to the server of the workspace you're chatting in. Connections to OpenAI or Anthropic send your messages to that company.",
                "MCP servers receive the arguments of the tool calls you allow, and the local ones run as programs on this Mac with your permissions.",
                "goooeee has no analytics and sends nothing anywhere else.",
            ]),
            .note("API keys are never written to the database or settings file, so a database backup doesn't contain them."),
        ]
    )

    // MARK: Getting started

    static let gettingStarted = HelpTopic(
        id: "start",
        title: "Getting Started",
        symbol: "flag",
        summary: "Workspaces, servers and your first chat.",
        blocks: [
            .text("goooeee is a chat app for inference servers on this Mac or elsewhere: llama.cpp, vLLM, mlx_lm, mlx-vlm, DwarfStar 4, LM Studio, Ollama, OpenAI, Anthropic, and anything that speaks the OpenAI API."),
            .heading("Workspaces"),
            .text("Each window is a **workspace**: one server, one model, and its own chats, settings, tools and terminal. Open several windows to compare models side by side."),
            .steps([
                "Start your server, for example `llama-server -m model.gguf --jinja --port 8080`.",
                "Choose **File → New Workspace…** (⇧⌘N). goooeee looks for servers on the usual ports (8080, 8000, 1234, 11434, 8081, 8001, 8082 and 5001) and lists what it finds.",
                "Pick the server, or **Another server…** to enter its address, then pick a model.",
                "Click **Create Workspace**, then **New Chat** (⌘N) and type.",
            ]),
            .text("The dot next to the model name in the toolbar shows the server's state: green online, orange starting or loading a model, red offline. Click it to switch models, refresh or open the connection's settings."),
            .heading("The window"),
            .bullets([
                "**Left:** your chats, with search (⌘K), pinned chats and Recently Deleted.",
                "**Middle:** the chat and the message box. The terminal opens below it (⌘`).",
                "**Right:** the inspector (⌥⌘I): model, sampling, thinking, system prompt, tools, statistics and the workspace's settings.",
            ]),
            .note("Turn off server scanning in Settings → General if you don't want goooeee to probe local ports."),
        ]
    )

    // MARK: Connections

    static let connections = HelpTopic(
        id: "connections",
        title: "Connections",
        symbol: "server.rack",
        summary: "Server addresses, engine types, tests and curl commands.",
        blocks: [
            .text("A **connection** is a server: its address, its engine type, an API key if it needs one, and the default settings sent to it. Several workspaces can share one. Open them with **Window → Connections** (⇧⌘K)."),
            .heading("Choose the right engine type"),
            .text("The engine type decides which features goooeee uses. With **llama.cpp**, for example, it reads the server's sampling defaults, context size and vision support, offers Stop Thinking and the server's tools, and loads models on routers. **OpenAI-compatible** works with any server but only uses the standard API, so pick the server's own type when there is one."),
            .heading("Tabs"),
            .bullets([
                "**General:** name, engine type, address, API key, headers and timeout.",
                "**Model & Sampling:** default model and sampling values, whether the model profile or the server's defaults come first, and whether the model takes images and tool calls (Auto-detect, Yes or No).",
                "**Thinking:** the default thinking level and how it's requested.",
                "**Template:** a chat template, needed only for the completions API.",
                "**Launch:** a command that starts the server from the workspace's terminal (**Start Server**).",
                "**Test:** checks reachability, the API key, the model list, capabilities and a short streamed reply, optionally with an image (vision) and a tool call. It uses the settings as shown, even unsaved.",
                "**curl:** ready-to-run curl commands built from the same code as real requests.",
            ]),
            .text("Changes apply when you click **Save** (⌘S). **Revert** discards them."),
        ]
    )

    // MARK: Chatting

    static let chatting = HelpTopic(
        id: "chat",
        title: "Chatting",
        symbol: "bubble.left.and.bubble.right",
        summary: "Sending, attachments, branches, thinking and editing.",
        blocks: [
            .heading("Sending"),
            .bullets([
                "**Return** sends and **⇧Return** starts a new line. You can switch to **⌘Return** to send in Settings → General; ⌘Return always sends.",
                "**↑** in an empty message box edits your last message.",
                "Type **/** at the start to use a prompt from an MCP server, or **@** to attach one of its resources.",
                "**⌘.** stops a reply. While a model thinks, **Stop Thinking** ends the reasoning and moves on to the answer (llama.cpp).",
            ]),
            .heading("Attachments"),
            .text("Paste, drop or click the paper clip to attach files:"),
            .bullets([
                "**Images**, resized to the limit in Settings → Chat. They're sent only to models that can see images: the inspector shows ✓ Vision when the server or the model profile says so.",
                "**PDFs**, as text, or as page images for vision models (Settings → Chat).",
                "**Text and code files**, as text.",
                "**Long pastes** become a text attachment instead of filling the message box.",
            ]),
            .heading("Branches, editing and regenerating"),
            .bullets([
                "Editing a message or regenerating a reply (⌘R) keeps the old version as a branch. Switch with the arrows in the message's footer, or ⌘[ and ⌘].",
                "**Continue** asks the model to carry on from where a reply stopped.",
                "Deleting a message deletes the replies after it on that branch.",
                "Deleted chats go to **Recently Deleted** in the sidebar, where you can restore them for 30 days (Settings → General).",
            ]),
            .heading("Statistics"),
            .text("Under each reply: prompt-processing and generation speeds, token counts and time. The inspector shows the totals for the chat."),
        ]
    )

    // MARK: Settings

    static let settings = HelpTopic(
        id: "settings",
        title: "Settings & Precedence",
        symbol: "slider.horizontal.3",
        summary: "Which temperature wins, and where to change it.",
        blocks: [
            .text("Sampling settings (temperature, top-p and the rest) can be set in several places. For each one, the first place that sets it wins:"),
            .steps([
                "**This chat:** the inspector with **This Chat** selected.",
                "**The workspace:** the inspector with **Workspace** selected.",
                "**The connection:** its Model & Sampling tab.",
                "**The model profile:** recommended values for the model family, from the model card (Settings → Profiles).",
                "**The server's defaults:** shown, but not sent; the server applies them itself.",
            ]),
            .text("A connection can put the server's defaults before the model profile (**Server, then model profile**). Thinking uses the same order without the last two. Next to each value, a badge shows where it comes from: chat, workspace, connection, profile or server."),
            .heading("App settings"),
            .text("**goooeee → Settings** (⌘,) holds preferences that apply to every window: fonts and text size (⌘+, ⌘−, ⌘0), the send key, how thinking is shown, attachments, tools and MCP, the terminal, model profiles, and advanced options. **Advanced → Reset All Settings** restores the defaults and keeps your connections, workspaces, chats and MCP servers."),
        ]
    )

    // MARK: Code blocks

    static let codeBlocks = HelpTopic(
        id: "code",
        title: "Code Blocks",
        symbol: "chevron.left.forwardslash.chevron.right",
        summary: "Copy, save, paste into the terminal and preview.",
        blocks: [
            .text("The buttons at the top right of a code block:"),
            .bullets([
                "**Copy** copies the code.",
                "**Save As…** appears for scripts (they start with `#!`) and for code the reply names a file for, like “Save this as `hello.sh`”. The name is filled in and the dialog opens in the terminal's folder, so a following `bash hello.sh` finds the file. Scripts are saved as executable.",
                "**Paste into Terminal** (shell code) opens the terminal and puts the command at the prompt. Nothing runs until you press Return there, so you can check and edit it first.",
                "**Preview** shows HTML and SVG in a window.",
            ]),
            .note("Your shell treats `!` specially: in zsh and bash, `echo \"Hello!\"` fails with “event not found” or waits at `dquote>`. Use single quotes (`echo 'Hello!'`), or press Ctrl-C and edit the command."),
        ]
    )

    // MARK: Terminal

    static let terminal = HelpTopic(
        id: "terminal",
        title: "Terminal",
        symbol: "terminal",
        summary: "A shell in each workspace, and starting servers from it.",
        blocks: [
            .text("Each workspace window has its own terminal (⌘`), running your login shell in the workspace's working folder. Its output is kept while it's hidden. Choose another shell, font or scrollback in Settings → Terminal."),
            .heading("Starting the server"),
            .text("Give a connection a launch command in its **Launch** tab, and **Start Server** appears in the toolbar and the terminal. goooeee runs the command in the terminal, so you see its output, and waits for the server to answer. **Stop Server** sends Ctrl-C. If you quit goooeee while a server it started is running, it asks first."),
            .text("The terminal's menu (…) has Clear, Send Ctrl-C, Restart Shell and Copy Launch Command."),
        ]
    )

    // MARK: Tools

    static let tools = HelpTopic(
        id: "tools",
        title: "MCP & Tools",
        symbol: "wrench.and.screwdriver",
        summary: "MCP servers, tool permissions and the agentic loop.",
        blocks: [
            .text("Tools let a model read files, search, run commands and so on. They come from **MCP servers**, which you add in **Window → MCP Servers** (⌥⌘M), and from llama.cpp's own server tools."),
            .bullets([
                "**Local (stdio)** servers are programs goooeee starts, such as `npx -y @modelcontextprotocol/server-filesystem ~/Documents`. They run with your permissions.",
                "**Remote** servers are reached over HTTP or SSE, with optional headers.",
                "Header and environment values you mark as secret are kept in the Keychain, not the database.",
                "Import and export servers as the `mcpServers` JSON used by Cursor, Claude Desktop and llama-server.",
            ]),
            .text("Choose which servers and tools a workspace or chat can use in the inspector's Tools section."),
            .heading("Permissions"),
            .text("When a model calls a tool, goooeee asks first: **Allow Once**, **Always Allow Tool**, **Always Allow Server** or **Deny**. “Always” answers are kept per workspace."),
            .heading("The agentic loop"),
            .text("After a tool result, the model can call more tools before it answers. After 100 tool turns goooeee asks whether to keep going (Settings → Tools & MCP). Prompts (/) and resources (@) from MCP servers can be used in the message box."),
        ]
    )

    // MARK: Shortcuts

    static let shortcuts = HelpTopic(
        id: "shortcuts",
        title: "Keyboard Shortcuts",
        symbol: "keyboard",
        summary: "Every shortcut in one place.",
        blocks: [
            .heading("Chats"),
            .shortcuts([
                HelpShortcut(keys: "⌘N", action: "New chat"),
                HelpShortcut(keys: "⇧⌘N", action: "New workspace"),
                HelpShortcut(keys: "⌘K", action: "Search chats"),
                HelpShortcut(keys: "⌘⌫", action: "Delete chat"),
                HelpShortcut(keys: "Return", action: "Send (or ⌘Return, see Settings → General)"),
                HelpShortcut(keys: "⇧Return", action: "New line"),
                HelpShortcut(keys: "↑", action: "Edit your last message (empty message box)"),
                HelpShortcut(keys: "⌘.", action: "Stop the reply"),
                HelpShortcut(keys: "⌘R", action: "Regenerate the last reply"),
                HelpShortcut(keys: "⌘E", action: "Edit the last message"),
                HelpShortcut(keys: "⌘[  ⌘]", action: "Previous and next branch"),
            ]),
            .heading("Windows and view"),
            .shortcuts([
                HelpShortcut(keys: "⌘`", action: "Show or hide the terminal"),
                HelpShortcut(keys: "⌥⌘I", action: "Show or hide the inspector"),
                HelpShortcut(keys: "⌘+  ⌘−  ⌘0", action: "Bigger, smaller and actual text size"),
                HelpShortcut(keys: "⇧⌘K", action: "Connections"),
                HelpShortcut(keys: "⌥⌘M", action: "MCP Servers"),
                HelpShortcut(keys: "⌘,", action: "Settings"),
                HelpShortcut(keys: "⌘?", action: "This help"),
            ]),
            .heading("Connections window"),
            .shortcuts([
                HelpShortcut(keys: "⌘S", action: "Save the connection"),
                HelpShortcut(keys: "⌘Return", action: "Run the connection test"),
            ]),
        ]
    )

    // MARK: Troubleshooting

    static let troubleshooting = HelpTopic(
        id: "troubleshooting",
        title: "Troubleshooting",
        symbol: "stethoscope",
        summary: "Common problems and what to do.",
        blocks: [
            .heading("The server shows as offline"),
            .bullets([
                "Check that the server is running and the address in the connection matches its port (Connections → General).",
                "Run the connection's **Test** tab: each failed check says what went wrong and how to fix it.",
                "If the connection has a launch command, use **Start Server** and watch the terminal.",
            ]),
            .heading("Vision shows ✗ but the model can see images"),
            .text("goooeee goes by what the server reports. Set the connection's engine type to the server's own (for example llama.cpp instead of OpenAI-compatible), or set **Images** to Yes in the connection's Model & Sampling tab. The connection test's vision check tells you whether the model really sees them."),
            .heading("macOS keeps asking for the Keychain"),
            .text("Builds signed to run locally look new to macOS after each rebuild. Choose **Always Allow** when asked for the “\(AppFiles.keychainService)” item."),
            .heading("A pasted command fails with “event not found”"),
            .text("That's your shell's `!` history expansion. See Code Blocks."),
            .heading("goooeee crashed"),
            .text("macOS saves a report in the crash reports folder (see Files & Data). Include the newest goooeee-*.ips file when you report the problem."),
            .heading("Start over"),
            .text("Settings → Advanced → **Reset All Settings** keeps your data. To remove everything, see Backup & Uninstall."),
        ]
    )

    // MARK: Backup & uninstall

    static let backupAndUninstall = HelpTopic(
        id: "backup",
        title: "Backup & Uninstall",
        symbol: "archivebox",
        summary: "Copy your chats, or remove everything goooeee stored.",
        blocks: [
            .heading("Back up"),
            .text("Everything except API keys is in the database. Quit goooeee, then copy it, for example with these commands in Terminal:"),
            .backupCommands,
            .text("To restore, quit goooeee and copy the files back into the database folder. Then add the API keys again."),
            .heading("Uninstall"),
            .steps([
                "Quit goooeee.",
                "Move goooeee to the Trash.",
                "To also remove your data, run these commands in Terminal. They delete the database (all chats, workspaces and connections), settings, caches, crash reports and the Keychain items, and nothing else:",
            ]),
            .uninstallCommands,
            .note("Files you saved from code blocks, and anything your servers or MCP servers wrote, stay where they are."),
        ]
    )
}
