# goooeee — Implementation Plan

goooeee is a native **macOS 26** chat client for local and remote inference servers. It never
runs a model itself. Each window is a **workspace** bound to one server and one model, and talks
to that server through the **OpenAI-compatible API** (the default for every engine). The feature
set follows the llama.cpp web UI (`tools/ui` in llama.cpp), rebuilt as a fast, native Mac app:
streaming chat with thinking blocks, branching, attachments, speed statistics, **MCP tools,
prompts and resources** with an agentic tool loop, plus a terminal in every window to run the
server.

---

## 0. Decisions so far

| Topic | Decision |
|---|---|
| Platform | **macOS 26 minimum**, Swift 6.2, Xcode 26 |
| API | OpenAI-compatible `/v1/chat/completions` by default for every engine; Anthropic Messages only for Anthropic's own API |
| Engines | llama.cpp, vLLM, mlx_lm, mlx-vlm, DwarfStar 4, LM Studio, Ollama, OpenAI, and any OpenAI-compatible server (including **ninfer**, via the generic preset) |
| Windows | **Each window is a workspace for one server and one model**, with its own conversation list, settings, tools and terminal |
| Model info | No Hugging Face access. Settings come from the server, built-in profiles, or the user |
| Templates | Applied by the server. Loading a Jinja file into a connection is the last resort |
| Reference | The llama.cpp web UI, for features and behavior (ideas, not code) |
| MCP | Full MCP client: stdio, Streamable HTTP and SSE servers; tools, prompts, resources; agentic loop with permission prompts |
| Network | Plain HTTP on the LAN, no Tailscale; no warnings for `http://` |
| Distribution | Outside the App Store. Builds from source with ad-hoc signing now; Developer ID + notarization once a team exists |
| Bundle ID / team | Not decided yet; a placeholder is used until then (§4.1) |
| Performance | A hard requirement: fluid streaming and scrolling regardless of conversation size (§8) |

---

## 1. Goals and non-goals

### Goals
- Native, intuitive, fast. It should feel like a Mac app, not a web page in a window.
- **Workspaces**: each window = one server connection + one model + its own conversations.
- Three-pane window: **conversations (left) · chat (middle) · settings inspector (right)**.
- Swipe left on a conversation to delete it, as on iOS, with undo.
- Saved **server connections** with sampling settings, thinking settings, system prompt, launch
  command, **Test** button and generated **`curl` examples**.
- Correct default sampling settings per model, with the source of every value shown.
- Rendering of **markdown, code, math, thinking blocks and tool calls**, with copy everywhere.
- **Attachments**: images (vision models), text and code files, PDFs, long pastes.
- **Speed statistics**: prompt processing tok/s, generation tok/s, overall average, TTFT, live
  prompt-processing progress, context usage.
- **Edit, regenerate, continue and branch** conversations.
- **MCP**: connect MCP servers, let the model call their tools in an agentic loop, use their
  prompts and resources.
- **Terminal** in each window to start and watch the inference server.
- App settings including **font and size per text type** (input, thinking, LLM output, code).

### Non-goals (v1)
- Running models in-process (no MLX, no llama.cpp linking, no model downloads).
- Fetching model data from Hugging Face.
- iOS / iPadOS.
- Mac App Store (the terminal and stdio MCP servers need a non-sandboxed app).

---

## 2. What we take from the llama.cpp web UI

The llama.cpp UI (`tools/ui`, SvelteKit, ~73k lines) was reviewed at commit `f74e2fa`
(2026-10-16). Its layering (Routes → Components → Hooks → Stores → Services → Storage/API) maps
cleanly onto a SwiftUI app (Views → ViewModels/Stores → Services → Storage/API). Features we
adopt, and how they translate:

| llama.cpp web UI | goooeee (native) | § |
|---|---|---|
| `ChatService`: `/v1/chat/completions` streaming, `reasoning_content`, `tool_calls`, `timings` | `OpenAIChatProvider` + SSE parser on a background actor | 9 |
| `return_progress` → `prompt_progress {processed, total, cache, time_ms}` | Live "Reading prompt 12.4k / 32k (8k cached)" progress and PP speed | 13 |
| Stats with **Reading** and **Generation** views; agentic totals (turns, tool calls, tool time) | Metrics footer with the same two views + agentic summary | 13 |
| Reasoning effort → `thinking_budget_tokens` (Low 512, Medium 2048, High 8192, Max unlimited); `chat_template_kwargs.enable_thinking` | Thinking menu in the composer and inspector | 10.3 |
| **Stop reasoning**: `POST /v1/chat/completions/control {action: "reasoning_end", id}` | "Stop thinking" button on the live thinking block (llama.cpp preset) | 9.2 |
| Message **tree** (`parent`, `children`, `currentNode`), branch navigation | Same tree model, ‹ 2/3 › navigation | 11.1 |
| Continue (`continue_final_message`, `add_generation_prompt: false`) | Continue button where the engine supports it | 11.6 |
| Settings synced with server defaults from `/props` | "server" provenance in the settings resolver | 10.2 |
| Custom JSON parameters | Extra JSON per connection, workspace and chat | 9.3 |
| Exclude reasoning from context; disable reasoning parsing; raw output toggle | Same three options | 11.3 |
| Incremental markdown: stable blocks cached, only the unstable tail re-rendered; incomplete code block handling | Same idea, applied to a TextKit 2 transcript | 8 |
| Code highlighting (highlight.js), KaTeX math, HTML/SVG preview | Own regex highlighter (`SyntaxHighlighter`), SwiftMath, `WKWebView` preview | 11.4 |
| Attachments: images, text files, PDF (text or images), paste long text → file (2,500 chars) | Same, with PDFKit for PDFs | 12 |
| Title from first line or generated by the LLM | Same setting | 17 |
| Per-chat drafts; ⌘K search; import/export | Same; search uses SQLite FTS5 | 7, 18 |
| Context gauge (`n_ctx` from `/props`) | Context meter in the inspector | 13 |
| Router mode: `/models`, `/models/load`, `/models/unload`, `/props?model=` | The workspace's model picker loads/unloads models on llama.cpp routers | 9.2 |
| Server tools (`GET/POST /tools`, `--tools`, `--mcp-servers-config`) | "Server tools" source when the server exposes `/tools` | 14.6 |
| **MCP client** (`MCPService`, `mcpStore`, `agenticStore`): transports, health/logs, reconnect backoff, tools, prompts picker, resources browser, permission gates, turn limit, steering | Native MCP client with the same capabilities, **plus stdio servers** (a browser can't spawn processes, a Mac app can) | 14 |
| Modality validation (no images to non-vision models) | Same gating | 12 |
| Conversation tabs | Not adopted: workspace windows cover this | — |
| Stream resume after tab reload (`X-Conversation-Id`) | Later: a native app doesn't lose streams to page reloads | 22 |

---

## 3. Starting point: MLXChatExample

[MLXChatExample](https://github.com/ml-explore/mlx-swift-examples/tree/main/Applications/MLXChatExample)
contributes its MVVM folder layout (`Views/`, `Models/`, `ViewModels/`, `Services/`, `Support/`)
and the shape of its chat screen (`ChatView` → `ConversationView` + `PromptField` +
`MediaPreviewView`, toolbar with `GenerationInfoView` and `ErrorView`). Everything that runs a
model is removed: `MLXService`, `HubApi+default`, `DownloadProgressView`, the MLX package
dependencies and the increased-memory entitlement. `ChatViewModel` keeps its responsibilities
(history, generation lifecycle, cancellation, media, metrics) but is backed by HTTP providers.
`ConversationView`/`MessageView` are replaced by the AppKit transcript (§8), because rendering
streamed markdown through SwiftUI `Text`, as the example does, is the main performance limit for
long output.

---

## 4. Tech stack

| Area | Choice | Why |
|---|---|---|
| Language / UI | Swift 6.2, SwiftUI for app chrome, **AppKit + TextKit 2 for the transcript** | SwiftUI for sidebar, inspector, sheets, settings, toolbar (Liquid Glass comes for free on macOS 26); AppKit where text performance matters (§8) |
| OS | macOS 26+ | SwiftUI `WebView`, faster `List` on macOS, Liquid Glass, Swift 6.2 `Observations` |
| Project | XcodeGen `project.yml` + committed `goooeee.xcodeproj` + local SwiftPM package `GoooeeeKit` | Building needs only Xcode; core logic tested with `swift test` |
| Networking | `URLSession.bytes(for:)` + own SSE parser | Full control over streaming, back-pressure and cancellation |
| Markdown | [swift-markdown](https://github.com/swiftlang/swift-markdown) (cmark-gfm) → custom `NSAttributedString` renderer | Fast C parser, GFM tables/task lists, parsing off the main thread |
| Code highlighting | Own single-pass regex highlighter (`GoooeeeMarkdown.SyntaxHighlighter`), off main thread, cached | *Changed during implementation:* HighlightSwift's HTML-to-attributed-string step is slow and main-thread-bound, which breaks the streaming budget |
| Math | SwiftMath (LaTeX → image attachment), cached | KaTeX equivalent |
| HTML / SVG preview | SwiftUI `WebView` (macOS 26) in a sheet | Native preview of generated HTML/SVG |
| Persistence | SQLite via [GRDB](https://github.com/groue/GRDB.swift), WAL mode, FTS5 search | Small writes during streaming, paged loading of huge chats, fast search |
| MCP | [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) (protocol 2025-11-25) + own process-stdio and legacy-SSE transports | Official client with tools, prompts, resources, sampling, elicitation, roots, progress |
| Templates | swift-jinja (only for user-loaded templates, §10.5) | Last-resort client-side template rendering |
| Terminal | [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) `LocalProcessTerminalView` | Real PTY terminal |
| Secrets | Keychain | API keys, MCP headers and env secrets never stored in the database |

### 4.1 Building, signing and distribution
- Clone, open `goooeee.xcodeproj`, Run. No Apple developer account needed.
- `Config/Signing.xcconfig` (committed): ad-hoc signing (`CODE_SIGN_IDENTITY = -`), empty
  `DEVELOPMENT_TEAM`, placeholder bundle ID `local.goooeee.app`, then
  `#include? "Local.xcconfig"`. The real bundle ID and team go into the git-ignored
  `Config/Local.xcconfig` when you have them; no code changes needed.
- No App Sandbox (the terminal and stdio MCP servers launch processes). Hardened runtime on.
- Once a team exists: Developer ID signing, notarization and a DMG via a release script, for
  distribution outside the App Store (M12).
- With ad-hoc signing, macOS may ask again for Keychain access after a rebuild ("Always Allow").

---

## 5. Architecture

```
SwiftUI views / AppKit transcript          (main actor, no I/O)
        │  user intents            ▲ coarse state (@Observable, ≤ 10 Hz) + frame-paced text pushes
        ▼                          │
Workspace stores (@MainActor @Observable): WorkspaceStore, ChatStore, ConversationStore,
  ModelStore, ToolStore, MCPStore, AgenticStore, SettingsStore
        │ async calls              ▲ AsyncStreams of events
        ▼                          │
Services (actors, no UI state): InferenceService (providers), SSEParser, StreamParser
  (reasoning/markdown/tool-call assembly), MCPHost, ToolExecutor, Database (GRDB),
  ConnectionTester, CurlRenderer, ProcessLauncher
        │
        ▼
llama-server / vLLM / mlx / … (HTTP)   MCP servers (stdio / HTTP)   SQLite   Keychain
```

- One `WorkspaceContext` per window owns that window's stores. App-wide: database, connection
  registry, MCP server registry, settings.
- Streaming text never flows through SwiftUI state. The stream actor produces parsed chunks; a
  frame-paced pump (§8.2) hands them straight to the transcript view. SwiftUI only observes coarse
  state (is generating, metrics, errors).
- Swift 6.2 strict concurrency: UI stores are `@MainActor`; everything doing I/O or parsing is an
  `actor` or runs detached with `Sendable` values. *Implementation note:* the `GoooeeeKit` package
  builds in Swift 6 mode with complete checking; the app target builds in Swift 5 mode with
  targeted checking (its UI types are explicitly `@MainActor`), which avoids Swift 6 workarounds
  around AppKit and SwiftTerm delegate callbacks.

### Repository layout

```
goooeee/
├── project.yml                     # XcodeGen spec
├── goooeee.xcodeproj/              # generated, committed
├── Config/                         # Signing.xcconfig (committed), Local.xcconfig (ignored)
├── App/
│   ├── GoooeeeApp.swift            # scenes: workspace windows, Settings, Connections, MCP servers
│   ├── Workspace/                  # WorkspaceContext, window restoration, workspace picker
│   ├── Views/
│   │   ├── Sidebar/                # conversation list, swipe-to-delete, search, recently deleted
│   │   ├── Transcript/             # AppKit: TranscriptViewController, row views, TextKit 2 blocks
│   │   ├── Composer/               # prompt field, attachments, / and @ pickers, tools bar
│   │   ├── Inspector/              # model, sampling, thinking, tools, system prompt, context, stats
│   │   ├── Connections/            # editor, test runner, curl, template tab
│   │   ├── MCP/                    # server list, add/edit, logs, capabilities, resources browser
│   │   ├── Terminal/               # SwiftTerm drawer
│   │   └── Settings/               # app settings (⌘,)
│   ├── Stores/                     # @MainActor @Observable stores
│   └── Resources/
├── Packages/GoooeeeKit/
│   ├── Sources/
│   │   ├── GoooeeeCore/            # models, providers, SSE, stream parser, metrics, profiles,
│   │   │                           # settings resolver, curl, tester, persistence
│   │   ├── GoooeeeMarkdown/        # incremental markdown → attributed string, highlighting, math
│   │   └── GoooeeeMCP/             # MCP host, transports (process stdio, HTTP, SSE), tool bridge
│   └── Tests/                      # fixtures: recorded SSE streams per engine, MCP test servers
├── Tools/MockServer/               # scripted OpenAI-compatible server (speeds, sizes, tool calls)
├── Tools/MockMCP/                  # echo / slow / crashing / malformed MCP servers for tests
└── docs/PLAN.md
```

---

## 6. Workspaces and windows

A **workspace** is a window bound to one server connection and one model, with its own
conversations.

| Belongs to the workspace | Shared across workspaces |
|---|---|
| Server connection + selected model | Saved connections (one connection can back several workspaces) |
| Conversation list (left sidebar) | MCP server registry |
| Sampling/thinking overrides, system prompt | App settings and fonts |
| Enabled MCP servers and tools; tool permissions granted for this workspace | Model profiles |
| Terminal session and working directory | |
| Window frame, inspector/terminal visibility | |

- **New workspace** (⇧⌘N) opens a sheet: pick a saved connection (or create one, or pick a server
  found by local discovery, §7.5), then a model from `/v1/models`. The name defaults to
  "connection · model" and can be renamed.
- Relaunching restores every open workspace window. Closing a window keeps the workspace;
  **Window → Workspaces** lists all of them to reopen, rename, duplicate or delete.
- The title bar shows `Workspace · engine :port · model ▾` and a status dot
  (online / starting / offline). Changing the model applies to new messages; each message records
  the model that produced it.
- A conversation can be moved to another workspace (right-click → Move to…), e.g. to continue it
  on a different model.
- Several workspaces stream at the same time. A generation belongs to its conversation, not to the
  view, so switching chats never interrupts a stream.

---

## 7. UI and UX

````
┌──────────────────────────────────────────────────────────────────────────────────────────────┐
│ ● ● ●  Studio · llama.cpp :8080 · qwen3-32b ▾   ● online   [terminal] [inspector]            │
├──────────────────┬──────────────────────────────────────────────────┬────────────────────────┤
│ Search       ⌘K  │  You                                             │ MODEL                  │
│ + New chat   ⌘N  │  Explain this diagram   [img]                    │  qwen3-32b ▾           │
│                  │                                                  │  [Test] [curl]         │
│ Pinned           │  Assistant · qwen3-32b                           │ SAMPLING      source   │
│   Rust bug       │  ▸ Thought for 14.2 s                            │  temp   0.6   profile  │
│ Today            │  ▸ files.read_file   ✓ 0.2 s                     │  top_p  0.95  profile  │
│   Diagram Q      │  Here is what the diagram shows…                 │  top_k  20    profile  │
│   Plan tr[Delete]│  ```swift                          [Copy]        │  min_p  0.05  server   │
│ Yesterday        │  let x = 1                                       │  max    8192  you      │
│   Llama notes    │  ```                                             │ THINKING               │
│                  │  PP 1,840 t/s · TG 42.1 t/s · avg 38.7 t/s       │  effort  medium ▾      │
│                  │  TTFT 0.31 s · 812 tok  ‹2/2›  [⧉] [✎] [↻]       │ TOOLS                  │
│                  ├──────────────────────────────────────────────────┤  [✓] files  [✓] github │
│                  │  [+] [/] [@]  Message…               [■ / ↑]     │ SYSTEM PROMPT          │
│                  │  Tools: files, github · Thinking: medium ▾       │  …                     │
│                  ├──────────────────────────────────────────────────┤ CONTEXT                │
│                  │  $ llama-server -m qwen3-32b.gguf --jinja        │  12,410 / 32,768       │
│                  │  main: server is listening on 127.0.0.1:8080     │ CHAT STATS             │
│                  │  (terminal, one per workspace window)            │  avg TG 40.3 t/s       │
└──────────────────┴──────────────────────────────────────────────────┴────────────────────────┘
````

### 7.1 Layout
- `NavigationSplitView` (sidebar + detail) + `.inspector` on the right; Liquid Glass toolbar.
- Detail = transcript, composer, and a collapsible terminal drawer (⌘`).
- Inspector sections: Model · Sampling · Thinking · Tools · System prompt · Context · Chat stats.
  Advanced sampling (DRY, XTC, typical-p, dynamic temperature, sampler order) sits under a
  disclosure, so the default view stays simple.

### 7.2 Conversation sidebar (per workspace)
- Lists this workspace's conversations: Pinned, then Today / Yesterday / Previous 7 days / by
  month. Rows show title, last-message preview and a live dot while generating.
- **Swipe left to delete, as on iOS**: a two-finger swipe on a trackpad or Magic Mouse reveals a
  red **Delete** button; a full swipe deletes. Implemented with `List` +
  `.swipeActions(edge: .trailing, allowsFullSwipe: true)` and `Button(role: .destructive)`.
  Swipe right to **Pin**.
- Also: right-click → Delete, ⌘⌫, and multi-select (⌘/⇧-click) for bulk delete.
- **Undo** toast + ⌘Z; deleted chats go to **Recently Deleted** for 30 days (configurable).
- Deleting a generating chat stops its stream first.
- ⌘K searches titles and message text (FTS5) in this workspace, with a toggle for all workspaces.

### 7.3 Composer
- Multi-line input (Enter sends and ⇧Enter adds a newline, or ⌘Enter sends, per setting);
  per-chat drafts.
- **[+]** attachments, paste and drag & drop (§12). Pastes over 2,500 characters become a text
  attachment (configurable).
- **/** opens the MCP prompt picker (with an argument form); **@** attaches MCP resources.
- Tools bar: enabled tool sources at a glance, and the Thinking menu (Default / Off / Low /
  Medium / High / Max).
- While generating: Stop (■, also ⌘.). You can also type a **steering message**, injected between
  agentic turns as in llama.cpp.

### 7.4 Making it intuitive
- **First launch**: one sheet, "Connect to a server". goooeee probes the usual local ports
  (8080 llama.cpp/mlx, 8000 vLLM/ds4, 1234 LM Studio, 11434 Ollama) for `/v1/models` and lists
  what it finds ("llama.cpp on :8080 — qwen3-32b"). One click creates the connection and the first
  workspace. Manual entry is always available.
- **Errors say what to do**: "Connection refused on 127.0.0.1:8080. Is the server running?
  [Start server in terminal] [Edit connection]".
- **Empty states** offer the next action. An empty chat shows the model, context size, vision and
  tools badges, and a few starter prompts.
- Standard Mac behavior everywhere: undo, ⌘C/⌘V, services, full keyboard access, VoiceOver
  labels, light/dark/auto.
- Shortcuts: ⌘N new chat · ⇧⌘N new workspace · ⌘K search · ⌘⌫ delete chat · ⌘. stop ·
  ⌘R regenerate · ⌘E edit last message · ⌘` terminal · ⌥⌘I inspector · ⌘[ / ⌘] previous/next
  branch · ⌘+ / ⌘− font size.

### 7.5 Local server discovery
A quick async scan of `127.0.0.1` on the known ports (300 ms timeout each). The engine is guessed
from what answers (`/props` → llama.cpp, `/version` → vLLM, `/api/tags` → Ollama, otherwise
generic). Used by the first-launch and New Workspace sheets. LAN hosts are entered by hand.

---

## 8. Performance architecture

Requirement: text redraws fluidly while streaming, and the app doesn't slow down however much text
is generated or scrolled through.

### 8.1 Transcript view (AppKit + TextKit 2)
- The transcript is an `NSScrollView` + view-based `NSTableView` wrapped in
  `NSViewControllerRepresentable`. Rows are **reused**, so memory and layout cost depend on what's
  on screen, not on conversation length.
- One row per **block**, not per message: user message, thinking block, text segment, code block,
  tool call, metrics footer. A streaming answer only ever changes its **last** row.
- Text blocks are `NSTextView`s using **TextKit 2**, which lays out only the visible part
  (viewport layout), so very long answers stay cheap.
- **Row heights are cached** per (block, content version, width). Only the streaming row is
  re-measured (`noteHeightOfRows(withIndexesChanged:)`). After a window resize, visible rows are
  re-measured first and the rest lazily.
- Native text selection within each block; whole-message copy is a button.

### 8.2 Streaming pipeline
1. **Network actor** reads SSE bytes and decodes JSON chunks off the main thread.
2. **Stream parser actor** separates reasoning, content and tool calls (§11.3) and parses markdown
   incrementally: finished top-level blocks are **frozen** (parsed, styled and highlighted once);
   only the open tail block is re-parsed. This is the stable/unstable block idea from llama.cpp's
   UI.
3. **Frame-paced pump** on the main actor, driven by the window's display link
   (`NSView.displayLink`): at most once per frame it takes everything received since the previous
   frame and **appends** it to the tail row's `NSTextStorage` (never replacing the whole string).
   At 500 tok/s on a 120 Hz display that is about 4 tokens per frame.
4. **Code blocks** stream as plain monospaced text and are highlighted off the main thread when the
   fence closes (or every ~250 ms for long open blocks). Attributes are applied in one pass and
   cached by content hash.
5. **Math** renders when the closing delimiter arrives; rendered images are cached.
6. **Persistence** writes a streaming message at most once per second and once at the end, on the
   database actor.
7. SwiftUI state (generating flag, live tok/s, prompt progress) updates at most ~10 times a second.

### 8.3 Scrolling
- **Stick to bottom** only while you're at the bottom. Scrolling up during a stream stops
  auto-scroll and shows a "↓ Jump to latest" button. No animated scroll per token.
- Opening a long conversation loads and lays out the **last screen first**, then older messages in
  pages of ~50 as you scroll up.
- Collapsed thinking blocks and tool results don't lay out their hidden text.

### 8.4 Budgets (checked in CI and before each release)

| Scenario | Target |
|---|---|
| Streaming at 500 tok/s with mixed markdown, tables and code | No dropped frames at 120 Hz; main thread < 30% |
| Scrolling a 2,000-message / 2 M-character conversation | No dropped frames (Apple silicon, 120 Hz) |
| Opening that conversation | First screen in < 150 ms |
| Memory for that conversation | < 300 MB |
| Typing in the composer while another workspace streams | No added latency |
| Launch to usable window | < 1 s |

### 8.5 How it's verified
- `Tools/MockServer` streams scripted content at configurable speeds (up to 1,000 tok/s), sizes and
  shapes (huge code blocks, wide tables, long thinking, tool calls).
- XCTest performance tests with `XCTOSSignpostMetric` (scroll and animation hitches),
  `XCTClockMetric` and `XCTMemoryMetric`; signposts around parsing, layout and the pump.
- An Instruments pass (SwiftUI, Time Profiler, Hitches) per milestone.
- **M1 includes a spike** that runs the same stream through (a) this AppKit/TextKit 2 transcript
  and (b) a pure SwiftUI `List` + `Text` transcript on macOS 26, measured against the budgets. The
  plan assumes (a); if (b) meets every budget it can replace it for simpler code.

---

## 9. Inference connectivity

### 9.1 Providers
```swift
protocol InferenceProvider: Sendable {
    func listModels() async throws -> [RemoteModel]
    func probe() async throws -> ServerCapabilities        // health, n_ctx, vision, tools, router
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error>
}

enum StreamEvent: Sendable {
    case started(completionID: String?, model: String?)
    case promptProgress(processed: Int, total: Int, cached: Int, elapsedMs: Double)
    case reasoningDelta(String)
    case contentDelta(String)
    case toolCallDelta(index: Int, id: String?, name: String?, argumentsFragment: String)
    case usage(TokenUsage)
    case serverTimings(ServerTimings)                      // llama.cpp `timings`
    case finished(FinishReason)                            // stop | length | toolCalls | cancelled
}
```
1. **`OpenAIChatProvider`** (default for every engine): `POST /v1/chat/completions`, SSE.
2. **`OpenAICompletionProvider`** (last resort, §10.5): `POST /v1/completions` with the prompt
   rendered client-side from a user-loaded Jinja template.
3. **`AnthropicMessagesProvider`**: Anthropic's API only.

`RequestBuilder` produces every `URLRequest`, and `CurlRenderer` turns the same requests into curl
commands, so the examples always match what the app sends.

### 9.2 Engine presets
All engines use the OpenAI chat API. A preset adds a default URL and engine-specific extras.

| Engine | Default URL | Extras used when available | Reasoning field | Speed source |
|---|---|---|---|---|
| llama.cpp `llama-server` | `http://127.0.0.1:8080` | `/health`, `/props` (n_ctx, modalities, default generation settings, chat template), `return_progress`, `reasoning_format`, `thinking_budget_tokens`, stop-reasoning control endpoint, `continue_final_message`, router `/models` load/unload, `/tools`, `/apply-template`, `/slots` | `reasoning_content` | `timings` (+ live `prompt_progress`) |
| vLLM | `http://127.0.0.1:8000` | `/health`, `/v1/models` (`max_model_len`), `chat_template_kwargs`, `continue_final_message` | `reasoning` (older: `reasoning_content`) | `usage` + client clock |
| mlx_lm.server | `http://127.0.0.1:8080` | `/v1/models` | tags or reasoning field | `usage` + client clock |
| mlx_vlm.server | `http://127.0.0.1:8080` | `/health`, `/v1/models` (`loaded`), `enable_thinking`, `thinking_budget` | reasoning field or tags | `timings.predicted_per_second` + client clock |
| DwarfStar 4 `ds4-server` | `http://127.0.0.1:8000` | `/v1/models`, `reasoning_effort`, `think` | reasoning field | `usage` + client clock |
| LM Studio | `http://127.0.0.1:1234` | `/v1/models` | `reasoning_content` or tags | `usage` + client clock |
| Ollama | `http://127.0.0.1:11434/v1` | `/v1/models` | `reasoning` or tags | `usage` + client clock |
| OpenAI API | `https://api.openai.com/v1` | `/v1/models` | — | `usage` + client clock |
| Generic OpenAI-compatible (ninfer, others) | user | `/v1/models` | auto-detected | whatever is present + client clock |
| Anthropic API (non-OpenAI) | `https://api.anthropic.com` | `/v1/models` | `thinking` blocks | `usage` + client clock |

Unknown response fields are ignored and unknown engines work through the generic preset. Each
preset declares which request keys it accepts, so strict servers never receive keys they reject.

### 9.3 Sampling parameters
Every field is optional; empty means "not sent, the server decides". Basic: temperature, top-k,
top-p, min-p, max tokens, repeat penalty (`repeat_penalty` on llama.cpp, `repetition_penalty` on
vLLM/mlx), presence/frequency penalty, seed, stop. Advanced (llama.cpp parity, shown when the
engine accepts them): dynamic temperature range/exponent, XTC probability/threshold, typical-p,
repeat-last-n, DRY multiplier/base/allowed length/penalty-last-n, sampler order, backend sampling.
Plus **extra JSON** merged into the request body per connection, workspace or chat.

### 9.4 Streaming details
- The SSE parser handles `data:` lines, multi-line events, comments/pings, `[DONE]`, mid-stream
  errors, and `event:` names (Anthropic only).
- Request timeout per connection (default 10 min; local prompt processing can be slow).
- `stream_options: {include_usage: true}` for engines that accept it.
- Cancelling closes the connection and the server stops generating. Partial output is kept and
  marked as stopped.

---

## 10. Model profiles, templates and default settings

### 10.1 Model identification
From `/v1/models` IDs (and the llama.cpp `/props` model alias/path), matched by regex against the
built-in profiles (`qwen3`, `qwen3.5`, `deepseek-v4`, `glm-5`, `gemma-3`, `gpt-oss`, `llama-4`,
`mistral`, `magistral`, `phi-4`, …). The connection editor shows the match and lets you pick
another profile or None.

### 10.2 Sources of settings (highest first)
1. **You**: chat override, then workspace, then connection.
2. **Built-in profile** (`model-profiles.json`, curated from model cards, editable and extendable in
   Settings → Profiles): recommended sampling for thinking and non-thinking modes, reasoning
   format, thinking control method, vision and tool-call support.
3. **Server**: llama.cpp `/props` default generation settings, `n_ctx` and modalities; vLLM
   `max_model_len`. Server values are never sent back (the server applies them itself).
4. **Engine default**: nothing is sent.

*Implementation note:* the profile wins over the server by default because llama.cpp's `/props`
reports its built-in defaults (e.g. temperature 0.8) even when the server was started without
sampling flags. A connection can switch to "server, then model profile"
(`DefaultsPolicy.serverFirst`) when the server was started with deliberate sampling flags.

The inspector shows each value's source ("you", "server", "profile") with a reset button, and flags
disagreements ("server temperature 0.8 differs from the profile's 0.6").

Example profile:
```json
{
  "id": "qwen3",
  "match": ["(?i)qwen3(?!\\.5)", "(?i)qwen-3"],
  "reasoning": { "format": "tags", "open": "<think>", "close": "</think>", "mayStartInside": true },
  "thinkingControl": { "chatTemplateKwarg": "enable_thinking", "softSwitch": ["/think", "/no_think"] },
  "sampling": {
    "thinking":    { "temperature": 0.6, "top_p": 0.95, "top_k": 20, "min_p": 0.0 },
    "nonThinking": { "temperature": 0.7, "top_p": 0.8,  "top_k": 20, "min_p": 0.0 }
  },
  "vision": false,
  "tools": true
}
```
The registry also covers Harmony (`gpt-oss` analysis/final channels), `[THINK]…[/THINK]`
(Magistral), templates that open `<think>` in the prompt (so the output contains only `</think>`),
and models without thinking.

### 10.3 Thinking control
One menu: Default / Off / Low / Medium / High / Max. The preset translates it into
`chat_template_kwargs.enable_thinking` + `thinking_budget_tokens` (llama.cpp: Low 512, Medium 2048,
High 8192, Max unlimited, as in its UI), `enable_thinking` / `thinking_budget` (mlx-vlm),
`reasoning_effort` (gpt-oss, OpenAI, DwarfStar 4), `think` (Ollama, DwarfStar 4), Anthropic
`thinking`, or the `/no_think` soft switch. "Default" sends nothing. Changing it also switches to the
profile's matching sampling preset.

### 10.4 Server template visibility
The connection's **Template** tab shows the server's template where the engine exposes it
(llama.cpp `/props`) and, on llama.cpp, the exact prompt rendered for the current chat via
`/apply-template`.

### 10.5 Fixing a wrong template
1. Preferred: pass a template file to the server in the launch command (`--chat-template-file` for
   llama.cpp, `--chat-template` for vLLM). The Template tab suggests the flag.
2. Last resort: load a `.jinja` file into the connection. goooeee checks it on a sample chat, then
   renders prompts itself and uses `/v1/completions`. A toolbar badge shows this mode is on.

---

## 11. Chat rendering

### 11.1 Message tree
Conversations are trees, as in llama.cpp: each message has a `parentID`, and the conversation
stores `currentLeafID`. Editing a user message or regenerating an answer creates a sibling branch;
‹ 2/3 › arrows (⌘[ / ⌘]) switch branches. Only the active path is sent to the model.

### 11.2 Message model
```swift
struct Message: Identifiable, Codable, Sendable {
    let id: UUID
    var conversationID: UUID
    var parentID: UUID?
    var role: Role                    // system | user | assistant | tool
    var blocks: [ContentBlock]        // ordered; thinking and text can interleave
    var attachments: [Attachment]
    var toolCalls: [ToolCall]         // assistant messages that call tools
    var toolCallID: String?           // tool result messages
    var metrics: GenerationMetrics?
    var state: MessageState           // streaming | complete | stopped | failed
    var modelID: String?
    var createdAt: Date
}

enum ContentBlock: Codable, Sendable {
    case text(String)                 // markdown
    case thinking(String, duration: TimeInterval?, signature: String?)
}
```

### 11.3 Reasoning extraction
- Separate fields (`reasoning_content`, `reasoning`, Anthropic `thinking`) go straight into
  thinking blocks.
- Inline tags are split from content with buffering that is safe across chunk boundaries
  (`"<thi"` + `"nk>"`).
- Start-inside mode: a closing tag without an opening tag turns the earlier text into thinking.
- Harmony channels have their own parser. For unknown models, `<think>`, `<thinking>`, `[THINK]`
  and `<|begin_of_thought|>` are auto-detected.
- Options (llama.cpp parity): disable reasoning parsing, exclude reasoning from context (default:
  reasoning is not re-sent), raw output toggle per message.

### 11.4 Markdown, code, math
- GFM: headings, lists, task lists, tables (scroll horizontally), quotes, links, inline code, and
  images by URL (loaded lazily, cached).
- Code blocks: language label, **Copy**, wrap toggle, **Run in terminal** for shell code,
  **Preview** for HTML/SVG (native `WebView` sheet), optional height cap with expand.
- Math: `$…$`, `$$…$$`, `\(…\)`, `\[…\]`, with protection against false positives (prices, shell
  variables) like llama.cpp's latex-protection.
- User messages render as markdown by default (a setting shows them exactly as typed).

### 11.5 Thinking and tool-call blocks
- **Thinking**: collapsible. While streaming it shows "Thinking… 12.4 s" and, on llama.cpp, a
  **Stop thinking** button; when done it shows "Thought for 14.2 s". Own font and size, optional
  markdown rendering, copy button.
- **Tool calls**: one collapsible row per call with tool name and server, arguments (pretty JSON),
  status (waiting for permission / running with MCP progress / done / error), duration, and result
  (text, images, resource links). A setting keeps tool content expanded.

### 11.6 Actions
| Action | User msg | Assistant msg |
|---|---|---|
| Copy (markdown / plain) | ✓ | ✓ (with or without thinking) |
| Copy code block | — | ✓ |
| Edit | ✓ → new branch and resend, or save only | ✓ edit in place (used as context later) |
| Regenerate | — | ✓ new branch, optionally with another model on the workspace's server |
| Continue | — | ✓ where supported (`continue_final_message` on llama.cpp/vLLM) |
| Delete | ✓ (branch) | ✓ (branch) |

---

## 12. Attachments
- **Images** (JPEG, PNG, GIF, WebP, HEIC; SVG converted to PNG), downscaled to a configurable
  megapixel limit and sent as `image_url` data URIs. Only offered when the model supports vision
  (`/props` modalities, the profile, or a manual switch). Images in the history are dropped for
  non-vision models, as llama.cpp does.
- **Text and code files**: inlined as text parts with the file name.
- **PDF**: text extraction with PDFKit, or page images for vision models (setting).
- **Long paste** → text attachment (threshold setting, default 2,500 characters).
- **MCP resources** and **MCP prompts** (§14) appear as attachment chips.
- Add via [+], drag & drop or paste. Originals are stored in the database so chats can be resent.

---

## 13. Metrics

| Metric | Preferred source | Fallback |
|---|---|---|
| Prompt processing (PP) tok/s | llama.cpp `timings.prompt_n / prompt_ms` | `prompt_tokens / TTFT` (marked ≈) |
| Generation (TG) tok/s | `timings.predicted_n / predicted_ms` | `completion_tokens / (t_last − t_first)` |
| Average tok/s | — | `completion_tokens / total time` |
| TTFT | — | client clock |
| Cached prompt tokens | `timings.cache_n`, `prompt_tokens_details.cached_tokens` | — |
| Live prompt progress | llama.cpp `prompt_progress` (processed / total / cache / time) | spinner |
| Agentic totals | — | turns, tool calls, tool time, per-turn stats (setting) |
| Context used | `n_ctx` / `max_model_len` vs. prompt + output tokens | — |

- The footer under each answer has the same two views as llama.cpp: **Reading** (prompt) and
  **Generation**. It shows Reading while the prompt is processed and switches to Generation when
  tokens start arriving.
- Live TG while streaming, corrected with the server's numbers at the end.
- Inspector: context meter, chat averages, workspace session averages.

---

## 14. MCP and tools

goooeee is an MCP **host**. It connects to MCP servers, exposes their tools to the model through the
OpenAI `tools` parameter, and runs the agentic loop. Built on the MCP Swift SDK.

### 14.1 Server registry (app-wide; Settings → MCP Servers, or ⌥⌘M)
| Transport | Config | Notes |
|---|---|---|
| **stdio** | command, args, env, cwd, timeout | goooeee spawns and supervises the process (a browser can't; llama.cpp only offers this server-side) |
| **Streamable HTTP** | URL, headers | Current standard MCP transport |
| **SSE** (legacy) | URL, headers | For older servers |

- **Import and export the `mcpServers` JSON** used by Cursor and Claude Desktop. It's the same format
  as llama-server's `--mcp-servers-config`, so one file serves both.
- Secrets in env vars and headers are stored in the Keychain.
- Each server shows its status, connection phases and **logs** (like llama.cpp's connection log),
  server info and instructions, capability badges (tools, prompts, resources, logging,
  completions), the tool list with descriptions, and connect time.
- **Reconnect** with exponential backoff (1 s up to 30 s, ×2, 15 s per attempt, as in llama.cpp).
  Crashed stdio servers are restarted with the same backoff.
- Handshake timeout 10 s; tool call timeout 300 s (both settings).

### 14.2 Per-workspace enablement
The workspace's **Tools** inspector section lists the available sources (MCP servers, llama.cpp
server tools) with per-server and per-tool toggles. New conversations inherit the workspace's
selection. Tools are only sent when the model profile, or a manual switch, says the model supports
tool calls. Tool names are prefixed with the server name (`server_tool`) when needed, the same
scheme llama-server uses.

### 14.3 Agentic loop
1. Send the chat with `tools` (the enabled tool definitions).
2. Stream the answer and assemble `tool_calls` deltas.
3. If the turn ends with tool calls, show each call with a **permission prompt**:
   **Allow once · Always allow this tool · Always allow this server · Deny** (llama.cpp's four
   choices). Grants are stored per workspace and can be revoked in settings.
4. Run the call through MCP `tools/call` (or llama.cpp `POST /tools`), showing MCP progress
   notifications. Calls can be cancelled.
5. Append the `tool` result messages (text; images forwarded to vision models; resource links) and
   send the next turn.
6. Stop when the model answers without tool calls. After **max turns** (default 100, setting) ask
   "Continue?". A **steering message** typed during the loop is sent before the next turn.
7. Each turn is saved as separate messages; the footer shows agentic totals.

### 14.4 Prompts and resources
- **Prompts**: `/` in the composer lists prompts from all enabled servers. Prompts with arguments
  open a small form (with MCP argument completion when the server supports it). The result appears
  as a prompt chip and is sent as messages.
- **Resources**: `@` and a Resources browser (⌥⌘R) list resources and resource templates (template
  forms fill in URI variables). You can preview, attach to a message, and subscribe to updates.

### 14.5 Client capabilities offered to servers
- **Roots**: the workspace's working directory.
- **Elicitation** (forms): shown as a sheet you fill in or decline.
- **Sampling**: a server may ask the workspace's model to generate text; needs approval each time,
  or "always for this server".
- **Logging**: server log messages appear in that server's log view.

### 14.6 llama.cpp server tools
When the workspace's server is llama.cpp started with `--tools` or `--mcp-servers-config`,
`GET /tools` lists those tools. goooeee shows them as a "Server tools" source and runs them with
`POST /tools`, setting the `x-tool-cwd` header to the workspace's working directory. They run on the
server's machine, which the permission prompt says.

### 14.7 Safety
- Adding a stdio server shows the exact command it will run.
- Permission prompts are on by default; "always" grants are explicit and revocable.
- A per-workspace **tool call log** records every call, its arguments, result and decision.

---

## 15. Terminal
- One SwiftTerm terminal per workspace window, toggled with ⌘`, running the login shell
  (`$SHELL -l`) in the workspace's working directory. It stays alive while the window is open.
- Connections store a **launch command**, for example
  `llama-server -m ~/models/qwen3-32b-q4_k_m.gguf --jinja --port 8080 -c 32768`,
  `vllm serve Qwen/Qwen3-32B --reasoning-parser qwen3 --port 8000`,
  `mlx_lm.server --model mlx-community/Qwen3-32B-4bit --port 8080`, or `./ds4-server --ctx 32768`.
- **Start server** types the command into the terminal and waits for the health check; then the
  status dot turns green and the model list refreshes. **Stop** sends Ctrl-C. Closing a window with
  a running process asks first.
- curl examples and code blocks have **Run in terminal**.

---

## 16. Connections, testing and curl

### 16.1 Connection
```swift
struct ServerConnection: Identifiable, Codable, Sendable {
    let id: UUID
    var name: String
    var engine: EngineKind            // llamaCpp, vllm, mlxLM, mlxVLM, dwarfStar4, lmStudio, ollama, openAI, anthropic, genericOpenAI
    var apiStyle: APIStyle = .openAIChat
    var baseURL: URL
    var apiKeyRef: KeychainRef?
    var extraHeaders: [String: String]
    var defaultModelID: String?
    var profileID: ModelProfile.ID?   // nil = auto-detect
    var sampling: SamplingSettings    // all optional
    var thinking: ThinkingSettings
    var systemPrompt: String?
    var extraBodyJSON: String?
    var supportsImages: Bool?         // manual override
    var supportsTools: Bool?          // manual override
    var chatTemplate: ChatTemplate?   // last resort only
    var requestTimeout: TimeInterval
    var launch: LaunchConfig?         // command, cwd, env, health path
    var lastTest: ConnectionTestResult?
}
```

### 16.2 Editor (Connections window ⌘⇧K, or from the inspector)
Tabs: **General** (engine preset, URL, key, headers, timeout) · **Model & sampling** · **Thinking**
· **Template** · **Launch** · **Test** · **curl**. Duplicate, import/export JSON (keys excluded).

### 16.3 Test runner
1. Reachability (latency, status).
2. Auth (401/403 points to the key field).
3. Models.
4. Capabilities (`/props`, `max_model_len`, vision, router mode, server tools) and matched profile.
5. Streaming chat ("Reply with OK"): TTFT, tok/s, and whether and how reasoning was detected.
6. Vision (optional): sends a generated 64×64 image.
7. **Tool calling** (optional): sends a dummy tool to check that the server emits `tool_calls`.
   This catches a llama.cpp server started without `--jinja`, or vLLM without a tool parser.
8. Template check, when a Jinja file is loaded.

Each step can show the raw request and response. The summary is saved ("✓ 2 min ago").

### 16.4 curl
Generated from the real requests: list models, non-streaming and streaming chat, chat with an image,
thinking variants, chat with tools, plus engine extras (llama.cpp `/health`, `/props`,
`/apply-template`, `/tools`; vLLM `/health`). The key is masked as `$GOOOEEE_API_KEY` unless
revealed. **Copy** and **Run in terminal**.

---

## 17. App settings (⌘,)

| Tab | Settings |
|---|---|
| **Appearance** | Font family + size for **input**, **user messages**, **LLM output**, **thinking**, **code**, **metrics**; line spacing; message width; code theme; light/dark/auto |
| **Chat** | Send on Enter or ⌘Enter; show thinking while generating; collapse when done; render thinking as markdown; render user messages as markdown; show message stats; per-turn agentic stats; always expand tool calls; full-height code blocks; disable auto-scroll; title from first line or by the LLM (with prompt template); paste-to-file length; max image megapixels; PDF as images; enable Continue; render math; ask before deleting; keep deleted chats N days |
| **Tools & MCP** | MCP servers; max agentic turns; MCP request timeout; tool permission grants; tool call log retention |
| **Connections** | Defaults for new connections; local discovery on/off |
| **Profiles** | Built-in and custom model profiles |
| **Terminal** | Shell, font, size, scrollback |
| **Advanced** | Raw output toggle; disable reasoning parsing; exclude reasoning from context; extra JSON; import/export (including conversations); data folder; reset |

Font changes apply live in all windows. The transcript re-applies text attributes to visible rows
only. ⌘+ / ⌘− / ⌘0 scale all chat text together.

---

## 18. Persistence

SQLite (GRDB, WAL) at `~/Library/Application Support/goooeee/goooeee.sqlite`:

| Table | Key columns |
|---|---|
| `workspace` | id, name, connectionID, modelID, settings JSON, cwd, window state |
| `connection` | id, fields of §16.1 (secrets in Keychain) |
| `conversation` | id, workspaceID, title, pinned, currentLeafID, overrides JSON, createdAt, updatedAt, deletedAt |
| `message` | id, conversationID, parentID, role, blocks JSON, toolCalls JSON, toolCallID, metrics JSON, state, modelID, createdAt |
| `attachment` | id, messageID, kind, name, mime, data |
| `mcp_server` | id, name, transport, config JSON (secrets in Keychain), enabled |
| `tool_grant`, `tool_call_log` | permissions and audit log |
| `message_fts` | FTS5 index over message text and titles |

- Streaming writes are batched (at most one per second per message). Reads are paged from the
  active leaf upward.
- Export/import as goooeee JSON. Importing llama.cpp web UI exports is a stretch goal.

---

## 19. Open questions
Nothing blocking. Bundle ID and signing team will come later; placeholders are used until then.

---

## 20. Milestones

| # | Milestone | Scope | Done when |
|---|---|---|---|
| **M0** | Scaffold | XcodeGen + committed project, signing xcconfigs, GoooeeeKit targets, GRDB schema + migrations, CI (macOS build/test, project up-to-date check), MockServer, Info.plist (local network, arbitrary HTTP), no sandbox | A fresh clone builds and runs in Xcode with no account; CI green |
| **M1** | Core streaming + **transcript spike** | SSE parser, OpenAIChatProvider, stream parser (reasoning, markdown tail), AppKit/TextKit 2 transcript with frame-paced pump, perf harness, SwiftUI comparison | §8.4 budgets met for streaming and scrolling with MockServer; decision recorded |
| **M2** | Workspaces + connections | Workspace windows and restoration, New Workspace sheet, local discovery, connection editor, engine presets, Keychain, test runner, curl | Two workspaces on two servers; test and curl work for each engine |
| **M3** | Chat | Sidebar with swipe-to-delete, undo, Recently Deleted, ⌘K search; composer with drafts; markdown/code/math; copy; stop; metrics footer (Reading/Generation) with prompt progress; persistence | Usable daily against llama.cpp, with stats matching its `timings` |
| **M4** | Thinking & profiles | Reasoning splitter (fields, tags, start-inside, Harmony), thinking blocks + Stop thinking, Thinking menu, profiles + settings resolver with provenance, inspector | Qwen3, gpt-oss, DeepSeek-style and GLM output correct on at least 3 engines |
| **M5** | Branching & actions | Message tree, edit/regenerate as branches, branch navigation, continue, delete, edit assistant | All §11.6 actions work and persist |
| **M6** | Attachments | Images (with gating), text files, PDFs, long paste, drag/drop/paste | Vision chat on llama.cpp (mmproj), mlx-vlm and vLLM |
| **M7** | Tools & agentic loop | OpenAI tool calling, tool-call blocks, permission prompts, turn limit, steering, agentic stats, llama.cpp `/tools` source | A multi-step tool task completes with permissions and stats |
| **M8** | MCP | Registry, stdio/HTTP/SSE transports, health/logs/reconnect, `mcpServers` JSON import, per-workspace tools, prompt picker, resources browser, roots, elicitation, sampling | Works with the reference MCP servers (filesystem, fetch, everything) and the MockMCP edge cases |
| **M9** | Terminal | SwiftTerm drawer, launch commands, start/stop + health wait, Run in terminal | Start llama-server from the drawer and chat once it's healthy |
| **M10** | Settings & fonts | All §17 settings, per-type fonts, ⌘+/− | Font changes apply live without layout stalls |
| **M11** | Anthropic API & template fallback | AnthropicMessagesProvider; Template tab; Jinja fallback with `/v1/completions` | Thinking chat on Anthropic; a GGUF with a broken template works after loading a `.jinja` |
| **M12** | Polish & release | Performance regression pass against §8.4, accessibility, onboarding polish, docs; Developer ID + notarized DMG once a team exists | Release candidate |

### Testing
- **Unit (GoooeeeKit)**: SSE parsing, reasoning splitting at every chunk boundary, tool-call delta
  assembly, incremental markdown (re-parsing the tail gives the same result as a full parse),
  settings resolution, curl rendering, metric math, branch path selection, MCP message handling
  against MockMCP.
- **Recorded fixtures** from each engine (llama.cpp, vLLM, mlx_lm, mlx-vlm, ds4, LM Studio, Ollama,
  ninfer) for text, thinking, vision and tool calls.
- **Performance tests** (§8.5) in CI on Apple silicon runners.
- **UI tests** for the main flows: first launch, new workspace, chat, swipe-delete + undo, branch,
  tool permission.

### Risks
| Risk | Mitigation |
|---|---|
| Text performance with SwiftUI | AppKit/TextKit 2 transcript, measured in M1 against fixed budgets |
| Engines change reasoning or tool-call fields | Accept known variants, tag fallback, fixtures per engine version |
| Tool calling not enabled on the server | Test runner's tool-call check, with the fix ("start llama-server with --jinja") |
| MCP servers misbehave (hang, crash, malformed output) | Timeouts, backoff, process supervision, MockMCP tests (slow, crash, malformed, burst) |
| Untrusted tool execution | Permission prompts on by default, visible commands, revocable grants, audit log |
| Wrong templates inside GGUFs | Template tab, launch flag suggestion, Jinja last resort |
| Keychain prompts with ad-hoc signing | Documented; goes away with Developer ID signing |

---

## 21. Sources reviewed
- llama.cpp web UI, `tools/ui`: README (architecture), `services/chat.service.ts`,
  `services/mcp.service.ts`, `services/tools.service.ts`, `stores/agentic/*`, `stores/mcp/*`,
  `stores/tools.svelte.ts`, `constants/settings.constants.ts`, `constants/mcp.constants.ts`,
  `constants/reasoning-effort.constants.ts`, `constants/api-endpoints.constants.ts`,
  `MarkdownContent.svelte`, `ChatMessageStatistics.svelte`; and `tools/server/README.md` (server
  tools, MCP servers).
- MLXChatExample; mlx_lm, mlx-vlm, DwarfStar 4 and vLLM server docs; MCP Swift SDK README.

## 22. After v1
Stream resume after an app restart (llama.cpp replay buffer), Mermaid diagrams, audio input, OpenAI
Responses API, side-by-side model comparison, SSH tunnel helper, Shortcuts/App Intents, prompt
library, importing llama.cpp web UI exports.
