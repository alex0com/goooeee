# goooeee — Implementation Plan

A native macOS chat client for local and remote inference servers. goooeee **never runs a
model itself**. It talks to an inference server over HTTP using the **OpenAI-compatible API,
which is the default for every inference engine**. The Anthropic Messages API is supported as
a second option for Anthropic's own service. goooeee focuses on being the best possible front
end for the server: correct per-model settings, faithful rendering of model output (markdown,
code, thinking), accurate speed metrics, and a built-in terminal to launch the server from the
same window.

---

## 1. Goals and non-goals

### Goals
- Native SwiftUI macOS app, multi-window, three-pane layout:
  **conversations (left) · chat (middle) · settings inspector (right)**.
- Each window lists multiple conversations in its sidebar; **swipe left to delete**, as on iOS.
- Saved **server connections**, each with its own engine type, URL, key, model, sampling
  settings, thinking settings, system prompt and launch command.
- Per-connection **Test** button and generated **example `curl` commands**.
- Correct **default sampling settings per model**, with a visible source for every value
  (server / built-in profile / user). Chat templates are applied by the server; loading a
  Jinja template into a connection is a **last resort** (§7.5).
- Rendering of **markdown, code blocks with copy, and collapsible thinking blocks**.
- **Image attachments** when the model supports vision.
- **Speed metrics**: prompt processing tok/s, generation tok/s, overall average, TTFT.
- **Copy / edit / regenerate** for messages and code.
- **App settings** for fonts and sizes per output type (input, thinking, LLM output, code).
- An embedded **terminal per window** to start or watch the inference server.

### Non-goals (v1)
- Running models in-process (no MLX, no llama.cpp linking, no model downloads).
- Fetching anything from Hugging Face. All model information comes from the server, the
  built-in profiles, or the user.
- iOS / iPadOS targets.
- Tool calling / MCP / agent loops (the data model leaves room for them, see §16).
- Mac App Store distribution (see §11: the terminal needs a non-sandboxed app).

---

## 2. Starting point: MLXChatExample

[MLXChatExample](https://github.com/ml-explore/mlx-swift-examples/tree/main/Applications/MLXChatExample)
is a small SwiftUI MVVM app (`Views/`, `Models/`, `ViewModels/`, `Services/`, `Support/`).
We keep its shape and UI ideas and replace everything that runs a model.

| MLXChatExample | goooeee | Action |
|---|---|---|
| `MLXChatExampleApp.swift` | `GoooeeeApp.swift` | Rewrite: `WindowGroup` + `Settings` + Connections `Window` scenes, menu commands |
| `ChatView.swift` | `Views/Chat/ChatView.swift` | Keep structure (conversation + prompt field + media previews), embed in 3-pane layout |
| — | `Views/Sidebar/ConversationListView.swift` | New: conversation list with swipe-to-delete (§5.1) |
| `Views/ConversationView.swift` | `Views/Chat/ConversationView.swift` | Keep; add lazy rendering, scroll anchoring during streaming |
| `Views/MessageView.swift` | `Views/Chat/MessageView.swift` | Rewrite: content blocks (thinking / markdown / code), action bar, metrics footer |
| `Views/PromptField.swift` | `Views/Chat/PromptField.swift` | Keep; add paste/drop images, send-key setting, stop button |
| `Views/MediaPreviewView.swift` | `Views/Chat/AttachmentStrip.swift` | Keep idea; images only in v1 |
| `Views/Toolbar/ChatToolbarView.swift` | `Views/Chat/ChatToolbar.swift` | Replace model picker with connection + model picker |
| `Views/Toolbar/GenerationInfoView.swift` | `Views/Chat/MetricsView.swift` | Extend to PP / TG / avg / TTFT |
| `Views/Toolbar/ErrorView.swift` | `Views/Common/ErrorBanner.swift` | Keep |
| `Views/Toolbar/DownloadProgressView.swift` | — | Delete (no downloads) |
| `ViewModels/ChatViewModel.swift` | `ViewModels/ChatViewModel.swift` | Keep responsibilities (history, lifecycle, cancel, media, metrics); back it with a provider instead of MLX |
| `Services/MLXService.swift` | `GoooeeeCore/Providers/*` | Replace with HTTP providers (§6) |
| `Models/LMModel.swift` | `GoooeeeCore/Models/ModelProfile.swift` | Replace with model profiles (§7) |
| `Models/Message.swift` | `GoooeeeCore/Models/Message.swift` | Extend: content blocks, attachments, metrics, state |
| `Support/HubApi+default.swift` | — | Delete (no Hugging Face access) |
| `Support/SampleData.swift` | `App/Preview/SampleData.swift` | Keep for SwiftUI previews |
| MLX / MLXLLM / MLXVLM / MLXLMCommon deps | — | Remove all |
| `increased-memory-limit` entitlement | — | Remove; add network-client entitlement and local-network usage string |

---

## 3. Tech stack and decisions

| Area | Choice | Why |
|---|---|---|
| Language / UI | Swift 6, SwiftUI, AppKit where needed | Native look, multi-window, inspector APIs |
| Minimum OS | macOS 15 (open question, §14) | `NavigationSplitView` + `.inspector`, `@Observable`, modern `WindowGroup(for:)` |
| Project | **XcodeGen** `project.yml` + local SwiftPM package `GoooeeeKit` | Reviewable project file; core logic testable with `swift test` on Linux CI |
| Networking | `URLSession.bytes(for:)` + own SSE parser | No dependency, full control over streaming and cancellation |
| Markdown | [Textual](https://github.com/gonzalezreal/textual) (successor to MarkdownUI, native text selection); MarkdownUI as fallback | GFM tables, task lists, selection, custom code-block styling |
| Code highlighting | HighlightSwift (highlight.js via JavaScriptCore) | Many languages, light/dark themes |
| Math (optional) | SwiftMath for `$…$` / `$$…$$` | Many models emit LaTeX |
| Templates | [swift-jinja](https://github.com/huggingface/swift-jinja) (a Swift Jinja engine; no Hugging Face network access) | Only used when the user loads a Jinja template into a connection (last resort, §7.5) |
| Terminal | [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) `LocalProcessTerminalView` | Full VT100/xterm emulation with a PTY, used by several shipping apps |
| Persistence | JSON files in Application Support behind a `Store` protocol | Simple, exportable, diff-able, testable on Linux; can move to SQLite/GRDB later |
| Secrets | Keychain | API keys never written to JSON |
| Distribution | Developer ID, hardened runtime, notarized DMG (later Homebrew cask + Sparkle) | Terminal needs a non-sandboxed app |

---

## 4. Repository layout

```
goooeee/
├── project.yml                      # XcodeGen spec (app target + test targets)
├── App/                             # macOS app target (SwiftUI, AppKit, Keychain, SwiftTerm)
│   ├── GoooeeeApp.swift
│   ├── Commands/                    # Menu bar commands, keyboard shortcuts
│   ├── Views/
│   │   ├── Sidebar/                 # Conversation list, swipe-to-delete, search, recently deleted
│   │   ├── Chat/                    # ConversationView, MessageView, PromptField, blocks
│   │   ├── Inspector/               # Right-hand settings panel
│   │   ├── Connections/             # Connection manager, editor, test runner, curl view
│   │   ├── Terminal/                # SwiftTerm wrapper, terminal drawer
│   │   ├── Settings/                # App settings (⌘,)
│   │   └── Common/
│   ├── ViewModels/                  # ChatViewModel, WindowState, ConnectionEditorModel, …
│   ├── Services/                    # KeychainStore, ImageEncoder, TerminalSession
│   ├── Preview/
│   └── Resources/                   # Assets, Info.plist, goooeee.entitlements
├── Packages/GoooeeeKit/             # Platform-independent core, no SwiftUI
│   ├── Package.swift
│   ├── Sources/GoooeeeCore/
│   │   ├── Models/                  # Conversation, Message, ContentBlock, ServerConnection, …
│   │   ├── Networking/              # SSEParser, HTTPClient, RequestBuilder, CurlRenderer
│   │   ├── Providers/               # OpenAIChat (default), OpenAICompletion, AnthropicMessages
│   │   ├── Engines/                 # EngineKind + adapters (llama.cpp, vLLM, mlx_lm, …)
│   │   ├── Parsing/                 # ReasoningSplitter, MarkdownBlockSplitter
│   │   ├── Metrics/                 # GenerationClock, MetricsCalculator
│   │   ├── Profiles/                # ModelProfile registry, SettingsResolver
│   │   ├── Templates/               # Jinja rendering of user-loaded templates (last resort)
│   │   ├── Diagnostics/             # ConnectionTester
│   │   └── Persistence/             # Store protocol + JSON file store
│   │   └── Resources/model-profiles.json
│   └── Tests/GoooeeeCoreTests/      # + Fixtures/ recorded SSE streams per engine
├── Tools/MockServer/                # Tiny scripted OpenAI-compatible SSE server for tests and UI dev
├── docs/PLAN.md
└── .github/workflows/ci.yml         # swift test (Linux) + xcodebuild build/test (macOS)
```

---

## 5. UI layout

````
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ ● ● ●  [⊞]  qwen3-32b @ llama.cpp (studio) ▾  ● online   [terminal] [inspector]          │
├──────────────────┬──────────────────────────────────────────────┬────────────────────────┤
│ Search chats     │                                              │ CONNECTION             │
│ + New chat  ⌘N   │  You                                         │  llama.cpp (studio) ▾  │
│                  │  Explain this diagram   [img]                │  Model: qwen3-32b ▾    │
│ Today            │                                              │  [Test] [curl]         │
│   Diagram Q      │  Assistant                                   │ SAMPLING      source   │
│   Rust bu[Delete]│  ▸ Thinking · 14.2 s                         │  temp   0.6   profile  │
│ Yesterday        │  Here is what the diagram shows…             │  top_p  0.95  profile  │
│   Plan trip      │  ```swift                       [Copy]       │  top_k  20    profile  │
│   Llama notes    │  let x = 1                                   │  min_p  0.05  server   │
│                  │  ```                                         │  max    8192  you      │
│                  │  PP 1,840 t/s · TG 42.1 t/s · avg 38.7 t/s   │ THINKING               │
│                  │  TTFT 0.31 s · 812 tok    [⧉] [✎] [↻]        │  [✓] enabled           │
│                  ├──────────────────────────────────────────────┤ SYSTEM PROMPT          │
│                  │  [+] Message…                       [■ / ↑]  │  …                     │
│                  ├──────────────────────────────────────────────┤ CHAT STATS             │
│                  │  $ llama-server -m qwen3-32b.gguf --jinja    │  avg TG 40.3 t/s       │
│                  │  (terminal drawer, one per window)           │                        │
└──────────────────┴──────────────────────────────────────────────┴────────────────────────┘
````

- `NavigationSplitView(sidebar:detail:)` + `.inspector(isPresented:)` for the right panel.
- Detail column is a `VSplitView`: conversation on top, collapsible terminal drawer below.
- Inspector shows **effective settings for this chat** (connection defaults + chat overrides).
  Each value shows where it came from (§7.4) and can be reset.

### 5.1 Conversation sidebar
- Every window has its own sidebar listing multiple conversations, grouped by date (Today,
  Yesterday, Previous 7 days, older by month), each row showing title, model badge and a
  streaming indicator. **+ New chat** (⌘N in the window) starts a conversation on the window's
  current connection and model.
- **Swipe to delete, as on iOS**: a two-finger swipe left on a row (trackpad, or Magic Mouse)
  reveals a red **Delete** button. A full swipe deletes immediately. Implemented with SwiftUI
  `List` + `.swipeActions(edge: .trailing, allowsFullSwipe: true)` and a `Button(role:
  .destructive)`. A swipe right reveals **Pin**.
- The same delete is available without a trackpad: right-click → Delete, ⌘⌫ on the selected
  row, and multi-select (⌘-click / ⇧-click) to delete several at once.
- **Undo**: deleting shows an "Undo" toast for a few seconds and registers with the window's
  `UndoManager` (⌘Z). Deleted chats go to **Recently Deleted** at the bottom of the sidebar and
  are purged after 30 days (configurable), so an accidental full swipe never loses a chat.
- Deleting a chat that is still generating cancels the stream first. If the chat is open in
  another window, that window moves to the next chat in its list.
- Rename (double-click or right-click → Rename), search field at the top, pinned chats first.

---

## 6. Inference connectivity

### 6.1 Provider abstraction (GoooeeeCore)

```swift
protocol InferenceProvider: Sendable {
    func listModels() async throws -> [RemoteModel]
    func probe() async throws -> ServerCapabilities          // health, ctx, vision, template…
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error>
}

enum StreamEvent: Sendable {
    case started(requestID: String?)
    case reasoningDelta(String)          // from a separate reasoning field / thinking block
    case contentDelta(String)            // visible text (may still contain inline <think> tags)
    case toolCallDelta(ToolCallDelta)    // parsed and stored, not executed in v1
    case usage(TokenUsage)               // prompt / completion / cached tokens
    case serverTimings(ServerTimings)    // e.g. llama.cpp `timings`
    case finished(FinishReason)
}
```

Implementations:
1. **`OpenAIChatProvider`, the default for every inference engine**: `POST /v1/chat/completions`
   with SSE streaming. Used by llama.cpp, vLLM, mlx_lm, mlx-vlm, DwarfStar 4, LM Studio, Ollama,
   OpenAI and any other OpenAI-compatible server. Every new connection starts with this API.
2. **`OpenAICompletionProvider`** (last resort, §7.5): `POST /v1/completions`, still the OpenAI
   API, with the prompt rendered **client-side** from a Jinja template the user loaded into the
   connection. Only used when the server's own template is wrong or missing and can't be fixed
   on the server.
3. **`AnthropicMessagesProvider`**: `POST /v1/messages`, SSE events (`message_start`,
   `content_block_start/delta/stop`, `message_delta`); thinking arrives as `thinking` content
   blocks. Used for Anthropic's API. Servers that also expose `/v1/messages` (DwarfStar 4) can
   be switched to it per connection, but they default to OpenAI too.

All providers share `RequestBuilder` → `URLRequest`. The same builder output feeds
`CurlRenderer`, so the curl examples always match what the app actually sends.

### 6.2 Engine adapters

All engines below use the OpenAI chat API by default. `EngineKind` only adds a preset and
small quirks on top of it: default base URL, health path, optional capability probe, sampling
key names, how thinking is toggled, where reasoning comes back, and where timings come from.

| Engine | Default URL | Optional capability probe | Reasoning comes back as | Speed source |
|---|---|---|---|---|
| llama.cpp `llama-server` | `http://127.0.0.1:8080` | `/health`, `/props` (`chat_template`, `modalities.vision`, `n_ctx`, default generation settings), `/apply-template` | `reasoning_content` (per `--reasoning-format`), else inline tags | `timings` in the final chunk (`prompt_per_second`, `predicted_per_second`) |
| vLLM | `http://127.0.0.1:8000` | `/health`, `/v1/models` (`max_model_len`) | `reasoning` (older builds: `reasoning_content`) when started with `--reasoning-parser` | `usage` via `stream_options.include_usage` + client clock |
| mlx_lm.server | `http://127.0.0.1:8080` | `/v1/models` | Inline `<think>` tags or a reasoning field, depending on version | `usage` + client clock |
| mlx_vlm.server | `http://127.0.0.1:8080` | `/health`, `/v1/models` (`loaded` flag) | Reasoning field or tags; `enable_thinking` request flag | `timings.predicted_per_second` in chunks + client clock |
| DwarfStar 4 `ds4-server` | `http://127.0.0.1:8000` | `/v1/models` | Reasoning field | `usage` + client clock |
| LM Studio | `http://127.0.0.1:1234` | `/v1/models` | `reasoning_content` or tags | `usage` + client clock |
| Ollama | `http://127.0.0.1:11434/v1` | `/v1/models` | `reasoning` or tags | `usage` + client clock |
| OpenAI API | `https://api.openai.com/v1` | `/v1/models` | — (chat completions don't return reasoning text) | `usage` + client clock |
| Generic OpenAI-compatible | user | `/v1/models` | Auto-detected (§8.2) | `usage` / `timings` if present + client clock |
| Anthropic API *(non-OpenAI)* | `https://api.anthropic.com` | `/v1/models` | `thinking` content blocks | `usage` + client clock |

New engines ("many other inference engines that are now being released") need no code to
work: pick **Generic OpenAI-compatible** and enter the URL. A named preset is a small data
addition when an engine needs a different default port or a quirk.

### 6.3 Sampling parameter mapping

Every sampling field is **optional**. `nil` means *don't send it, let the server decide*.
The adapter decides which keys are valid for the engine. This matters because strict APIs reject
unknown keys (OpenAI rejects `top_k`/`min_p`; some reasoning models reject `temperature`).

| Setting | OpenAI-compatible key (default) | Anthropic API key | Notes |
|---|---|---|---|
| Temperature | `temperature` | `temperature` | |
| Top-p | `top_p` | `top_p` | |
| Top-k | `top_k` | `top_k` | Not sent to OpenAI API |
| Min-p | `min_p` | — | llama.cpp, vLLM, mlx, ds4 |
| Repetition penalty | `repeat_penalty` (llama.cpp) / `repetition_penalty` (vLLM, mlx) | — | Key differs per engine |
| Presence / frequency penalty | `presence_penalty` / `frequency_penalty` | — | |
| Max tokens | `max_tokens` (or `max_completion_tokens`) | `max_tokens` (required) | |
| Seed | `seed` | — | |
| Stop | `stop` | `stop_sequences` | |
| Thinking on/off | `chat_template_kwargs.enable_thinking`, `reasoning_effort`, `think`, `enable_thinking`, or a `/no_think` prompt suffix (§7.3) | `thinking` object | Chosen by model profile + engine preset |
| Extra JSON | merged into body | merged into body | Escape hatch for anything else (e.g. `n_probs`, `cache_prompt`, `thinking_budget`) |

### 6.4 Streaming details
- SSE parser handles `data:` lines, multi-line events, `[DONE]`, keep-alive comments, error
  payloads sent mid-stream, and `event:` names (needed for the Anthropic API only).
- Request timeout is configurable per connection (default 10 min). Prompt processing for long
  contexts on local machines can take minutes before the first byte.
- Cancellation: cancelling the Swift `Task` closes the connection. llama.cpp, vLLM and mlx stop
  generating when the client disconnects. Partial output is kept and marked *stopped*.
- Generation runs in a `GenerationCoordinator` keyed by conversation ID, not in a view. Streams
  continue when the user switches chats or windows, and several windows can generate in parallel
  against different servers.
- UI updates are coalesced (≈30 Hz) so fast servers (200+ tok/s) don't flood SwiftUI.

---

## 7. Model profiles, chat templates and default settings

**The server applies the chat template.** llama.cpp (`--jinja`), vLLM, mlx_lm, mlx-vlm and
DwarfStar 4 all render the template from the model files when they receive a
`/v1/chat/completions` request. goooeee doesn't download or read anything from Hugging Face.
Its job is to: (a) **send the right parameters** for the model, (b) **parse the output** the
template produces, (c) **show what the server is doing** where the server exposes it, and
(d) as a **last resort**, use a Jinja template the user loads into the connection.

### 7.1 Model identification
For each connection + model, a model family is resolved from data the server already gives:
- Model ID from `/v1/models` (for example `Qwen/Qwen3-32B`, `mlx-community/Qwen3-32B-4bit`,
  `qwen3-32b-q4_k_m.gguf`).
- llama.cpp only: `/props` → model path/alias.
- Regex match of that ID against the built-in profiles: `qwen3`, `qwen3.5`, `deepseek-v4`,
  `glm-5`, `gemma-3`, `gpt-oss`, `llama-4`, `mistral`, `magistral`, `phi-4`, and others.
- The connection editor shows the match ("Detected: Qwen3, from model ID") and lets the user
  pick a different profile or **None** when the ID is ambiguous (renamed GGUF files, aliases).

### 7.2 Sources of settings, in order of precedence

| # | Source | Provides |
|---|---|---|
| 1 | **User override** (per chat, then per connection/model) | Anything |
| 2 | **Server-reported**, when the engine exposes it: llama.cpp `/props` (`default_generation_settings`, `n_ctx`, `modalities`, `chat_template`); vLLM `max_model_len` | What the running server actually uses |
| 3 | **Built-in profile registry** (`model-profiles.json`, shipped with the app, curated from the model cards) | Recommended sampling for thinking and non-thinking modes, reasoning tag format, thinking toggle method, vision flag |
| 4 | **Engine defaults** | Fallback: the field is not sent and the server uses its own default |

Example profile entry (values verified against the model cards during implementation):

```json
{
  "id": "qwen3",
  "match": ["(?i)qwen3(?!\\.5)", "(?i)qwen-3"],
  "reasoning": { "format": "tags", "open": "<think>", "close": "</think>", "mayStartInside": true },
  "thinkingToggle": { "chatTemplateKwarg": "enable_thinking", "softSwitch": ["/think", "/no_think"] },
  "sampling": {
    "thinking":    { "temperature": 0.6, "top_p": 0.95, "top_k": 20, "min_p": 0.0 },
    "nonThinking": { "temperature": 0.7, "top_p": 0.8,  "top_k": 20, "min_p": 0.0 }
  },
  "vision": false
}
```

Other formats the registry must describe: Harmony channels (`gpt-oss`: `analysis` / `final`),
`[THINK]…[/THINK]` (Magistral), templates that open `<think>` in the prompt so the output
contains only `</think>` (DeepSeek-R1-style, some Qwen/GLM templates), and models with no
thinking at all.

The registry ships inside the app and updates with app releases. Users can add or edit profiles
in Settings → Profiles (stored as JSON next to the built-in file), so a new model family doesn't
have to wait for a release.

### 7.3 Thinking control
The profile names one or more mechanisms and the engine preset picks a supported one:
`chat_template_kwargs.enable_thinking` (vLLM, llama.cpp `--jinja`, SGLang), top-level
`enable_thinking` (mlx-vlm), `reasoning_effort` (gpt-oss, OpenAI, DwarfStar 4), `think: false`
(DwarfStar 4, Ollama), Anthropic `thinking` config, or a system/user prompt soft switch
(`/no_think`). The inspector shows a single **Thinking** control (off / on / effort level when
supported). Switching it also switches the recommended sampling preset when the profile has one.

### 7.4 Settings resolver and provenance
`SettingsResolver` merges the four layers into `EffectiveSettings` and records, for each field,
which layer it came from. The inspector shows that as a small badge ("server", "profile",
"you") with a reset button. Mismatches are flagged, for example: "Server default temperature
0.8 differs from the profile's recommended 0.6".

### 7.5 Chat templates
In order of preference:
1. **Server template (default).** Nothing to configure. Where the engine exposes it (llama.cpp
   `/props`), the connection editor's **Template** tab shows the template read-only, and
   llama.cpp's `/apply-template` shows the exact prompt the server builds for the current chat.
2. **Fix it on the server.** If the server's template is wrong or missing (a common GGUF
   problem), the Template tab suggests the launch-command flag that loads a template file
   (`--chat-template-file` for llama.cpp, `--chat-template` for vLLM), and the server keeps
   using the OpenAI chat API.
3. **Last resort: load a Jinja template into the connection.** While creating or editing a
   connection the user can pick a `.jinja` file (or paste one). goooeee validates it by
   rendering a sample conversation, stores it with the connection, and switches that connection
   to `OpenAICompletionProvider`: the prompt is rendered client-side with swift-jinja and sent to
   `/v1/completions`. Stop tokens are taken from the template's special tokens or entered by
   hand. This mode is labelled in the toolbar so it's obvious it's active.

## 8. Chat rendering

### 8.1 Message model

```swift
struct Message: Identifiable, Codable {
    let id: UUID
    var role: Role                         // system | user | assistant
    var blocks: [ContentBlock]             // ordered; supports interleaved thinking
    var attachments: [Attachment]          // images (user messages)
    var metrics: GenerationMetrics?        // assistant messages
    var state: MessageState                // streaming | complete | stopped | failed(error)
    var modelID: String?
    var connectionID: UUID?
    var createdAt: Date
    var editedAt: Date?
}

enum ContentBlock: Codable {
    case text(String)                      // markdown
    case thinking(String, duration: TimeInterval?, signature: String?) // signature: Anthropic round-trip
    case toolCall(ToolCall)                // stored and displayed; not executed in v1
}
```

### 8.2 Reasoning extraction (`ReasoningSplitter`)
An incremental state machine fed by `reasoningDelta` and `contentDelta`:
- A separate reasoning field (`reasoning_content`, `reasoning`, Anthropic `thinking`) goes
  straight into a thinking block.
- Inline tags are split out of content using the profile's tag pair. Tags split across chunk
  boundaries (`"<thi"` + `"nk>"`) are buffered correctly.
- **Start-inside mode**: if a closing tag arrives without an opening tag, everything before it
  is reclassified as thinking.
- Harmony (`<|channel|>analysis<|message|>…<|end|>`) is handled by a dedicated parser when the
  server doesn't already split it.
- Unknown models: auto-detect `<think>`, `<thinking>`, `[THINK]`, `<|begin_of_thought|>`.
- Thinking is never re-sent to the server on later turns unless the profile or API requires it
  (Anthropic signed thinking blocks). This matches how most templates strip old reasoning.

### 8.3 Markdown and code
- Assistant text is rendered with Textual: GFM tables, task lists, block quotes, links, images
  by URL, and native text selection.
- During streaming, the markdown is split into top-level blocks. Finished blocks are cached
  and only the last, still-growing block is re-parsed on each update. This keeps long answers
  responsive.
- Unclosed code fences while streaming are rendered as an open code block (no flicker).
- Code blocks show a header with the language, a **Copy** button, a wrap toggle and
  "Open in terminal" for shell snippets. Highlighting uses the theme from app settings.
- Optional LaTeX rendering (`$…$`, `$$…$$`, `\(…\)`, `\[…\]`), off by default.
- A "View raw" toggle per message shows the exact text received, which is useful for template
  debugging.

### 8.4 Thinking block
- Collapsible `DisclosureGroup`. While streaming it shows "Thinking… 12.4 s" with a live
  token count and expands or collapses according to settings.
- Uses its own font and size from app settings (smaller, secondary color by default).
- Copy button for the reasoning text.

### 8.5 Message actions
| Action | User msg | Assistant msg |
|---|---|---|
| Copy (markdown) | ✓ | ✓ (option: include/exclude thinking) |
| Copy code block | — | ✓ per block |
| Edit | ✓ → **Save & resend** (drops the replies after it) or **Save only** | ✓ edit text in place; the edited text is used as context on later turns |
| Regenerate | — | ✓ (same or different model/connection) |
| Continue | — | ✓ continue a stopped/edited answer, where the engine supports assistant prefill |
| Delete | ✓ | ✓ |

Branching (keeping several versions of a reply with ‹ 1/3 › navigation) is planned for after v1.
The data model stores an optional `parentID`, so it can be added without migration.

---

## 9. Images / vision

- Add images by paperclip button, drag & drop, or paste (⌘V). Thumbnails appear in the
  attachment strip above the prompt field and can be removed before sending.
- **Capability gating**: the button is enabled only when the model supports vision, based on
  `/props` `modalities.vision` (llama.cpp), the model's profile flag, or a manual "Model
  supports images" switch on the connection. If none of these say yes, the button is hidden;
  dropping an image then offers to turn the switch on.
- Images are downscaled (configurable max edge, default 2048 px) and re-encoded (JPEG/PNG) to
  stay under server body limits (DwarfStar 4: 16 images, 64 MiB body).
- Encoding:
  - OpenAI-compatible (default): `{"type":"image_url","image_url":{"url":"data:image/jpeg;base64,…"}}`.
  - Anthropic API: `{"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":"…"}}`.
- Originals are stored with the conversation so a chat can be resent to another model.

---

## 10. Metrics

`GenerationClock` records request start, first byte, first reasoning/content token and last
token. `MetricsCalculator` combines the clock with server-reported numbers, preferring server
numbers when they exist.

| Metric | Server-reported (preferred) | Client-side fallback |
|---|---|---|
| **Prompt processing (PP) tok/s** | llama.cpp `timings.prompt_per_second` | `prompt_tokens / TTFT`, labelled "≈" because it includes network and queue time |
| **Generation (TG) tok/s** | llama.cpp / mlx-vlm `timings.predicted_per_second` | `completion_tokens / (t_last − t_first)` |
| **Average tok/s** | — | `completion_tokens / (t_last − t_request)`, end-to-end |
| TTFT | — | `t_first − t_request` |
| Tokens | `usage.prompt_tokens`, `completion_tokens`, cached tokens (`timings.cache_n`, `prompt_tokens_details.cached_tokens`) | Delta count (approximate) while streaming |
| Thinking time / tokens | Some servers report reasoning tokens in `usage` | Time between first and last reasoning delta |

- **Live** TG tok/s is shown while streaming from the delta count and corrected with
  `usage`/`timings` at the end. The app always sends `stream_options: {include_usage: true}` to
  engines that support it.
- Each assistant message has a compact footer (`PP · TG · avg · TTFT · tokens`). Hovering shows
  all raw numbers and their source.
- The inspector shows **chat averages** (mean TG / PP, total tokens) and **this session's**
  averages for the current connection.

---

## 11. Terminal integration

- Each window has a terminal drawer below the conversation (toggle ⌘` or toolbar button).
  It's a SwiftTerm `LocalProcessTerminalView` wrapped in `NSViewRepresentable`, running the
  user's login shell (`$SHELL -l`) so `PATH`, conda/uv/pyenv and Homebrew are available.
- One terminal session per window, kept alive when switching chats. Optional terminal tabs come
  after v1.
- Each connection can store a **launch command** and working directory, for example:
  - `llama-server -m ~/models/qwen3-32b-q4_k_m.gguf --jinja --port 8080 -c 32768`
  - `vllm serve Qwen/Qwen3-32B --reasoning-parser qwen3 --port 8000`
  - `mlx_lm.server --model mlx-community/Qwen3-32B-4bit --port 8080`
  - `mlx_vlm.server --model mlx-community/Qwen2.5-VL-7B-Instruct-4bit --port 8080`
  - `./ds4-server --ctx 32768`
- **Start server** types the command into the terminal, then polls the health endpoint and shows
  "starting… → online" in the toolbar. **Stop** sends Ctrl-C.
- The curl view has **Run in terminal**, so any example command can be executed and inspected.
- Closing a window whose terminal still has a running child process asks for confirmation.
- **Consequence:** the App Sandbox would confine the shell and everything it launches, so
  goooeee ships **non-sandboxed** with the hardened runtime and notarization (Developer ID).
  A Mac App Store build would have to drop or restrict the terminal.

---

## 12. Connections, testing and curl

### 12.1 `ServerConnection`

```swift
struct ServerConnection: Identifiable, Codable {
    let id: UUID
    var name: String                     // "llama.cpp (studio)"
    var engine: EngineKind               // .llamaCpp, .vllm, .mlxLM, .mlxVLM, .dwarfStar4, .lmStudio, .ollama, .openAI, .anthropic, .genericOpenAI
    var apiStyle: APIStyle = .openAIChat // .openAIChat (default) | .openAICompletion (with chatTemplate) | .anthropicMessages
    var baseURL: URL
    var apiKeyRef: KeychainRef?          // secret lives in Keychain
    var extraHeaders: [String: String]
    var defaultModelID: String?
    var profileID: ModelProfile.ID?      // nil = auto-detect from model ID (§7.1)
    var chatTemplate: ChatTemplate?      // last resort only (§7.5): Jinja source + stop tokens
    var sampling: SamplingSettings       // all-optional fields (§6.3)
    var thinking: ThinkingSettings
    var systemPrompt: String?
    var extraBodyJSON: String?
    var supportsImagesOverride: Bool?
    var requestTimeout: TimeInterval
    var launch: LaunchConfig?            // command, cwd, env, health path, auto-start
    var lastTest: ConnectionTestResult?
}
```

### 12.2 Connection manager (Window: "Connections", ⌘⇧K; also reachable from the inspector)
- List of saved connections + **New from preset** (one preset per engine, §6.2).
- Editor tabs: **General** (name, engine, URL, key, headers, timeout; API defaults to OpenAI) ·
  **Model & sampling** (model picker from `/v1/models`, detected profile, sampling fields with
  "server default" toggles, presets from the profile) · **Thinking** · **Template** (server
  template view; "Load Jinja template…" as last resort, §7.5) · **Launch** (command, cwd, env) ·
  **Test** · **curl**.
- Duplicate, import/export as JSON (keys excluded).

### 12.3 Test runner (`ConnectionTester`)
Runs the checks in order and streams results into a log:
1. **Reachability**: health endpoint or `/v1/models`. Reports latency, HTTP status and TLS errors.
2. **Auth**: detects 401/403 and points to the API key field.
3. **Models**: lists models and checks that the selected model exists or is loaded.
4. **Capabilities**: engine probe where available (`/props`, `max_model_len`, vision) and
   which profile matched.
5. **Chat**: a tiny streaming completion ("Reply with OK"). Reports TTFT, tok/s and whether
   reasoning was detected and how.
6. **Vision** (optional, when supported): sends a generated 64×64 test image.
7. **Template check** (only when a Jinja template is loaded): renders a sample conversation and,
   on llama.cpp, compares it with the server's `/apply-template` output.

Each step can show the **raw request/response**. The result summary is saved on the
connection ("✓ 2 min ago").

### 12.4 curl generator (`CurlRenderer`)
Generated from the real `URLRequest` produced by `RequestBuilder`, so it always reflects current
settings:
- OpenAI API examples: list models; non-streaming chat; streaming chat (`-N`); chat with an
  image; thinking on/off variants. Plus engine extras where they exist (llama.cpp `/health`,
  `/props`, `/apply-template`; vLLM `/health`). Anthropic connections get `/v1/messages`
  examples instead.
- The API key is masked by default (`$GOOOEEE_API_KEY` placeholder) with a "reveal" toggle.
- **Copy** and **Run in terminal** buttons.

---

## 13. App settings (⌘,) and multi-window

| Tab | Settings |
|---|---|
| **Appearance** | Font family + size for: **input field**, **user messages**, **LLM output**, **thinking**, **code**, **metrics**; line spacing; message width; code theme (light/dark); accent; compact vs. comfortable density |
| **Chat** | Send with ⏎ or ⌘⏎; thinking expanded / collapsed / collapse-when-done; show metrics footer; auto-title chats (via the active model, optional); render LaTeX; default image max size; ask before deleting a chat (off by default, undo is always available); keep deleted chats for N days |
| **Connections** | Default connection for new chats; request timeout default |
| **Profiles** | View built-in model profiles; add or edit custom ones |
| **Terminal** | Shell, font, size, scrollback, open drawer on launch |
| **Advanced** | Log level, export/import all data, reveal data folder, reset |

- Stored with `@AppStorage` / a `Codable` settings struct and applied through SwiftUI
  environment values, so all windows update live.
- ⌘+ / ⌘− / ⌘0 scale all chat fonts together, on top of the per-type sizes.

### Multi-window
- `WindowGroup(id: "chat", for: Conversation.ID.self)`: ⇧⌘N opens a new window (⌘N is a new
  chat in the current window), and "Open in New Window" opens a chat in its own window.
- Each window has its own `WindowState`: its active connection + model (shown in the toolbar),
  its sidebar selection, inspector/terminal visibility and terminal session. `@SceneStorage`
  restores it on relaunch.
- Each window's sidebar lists multiple conversations (§5.1). Each **conversation** also
  remembers the connection + model it uses, so two windows can talk to two different servers or
  models at once. A shared `ConversationStore`, `ConnectionRegistry` and `GenerationCoordinator`
  keep data consistent across windows.
- Standard macOS behavior: tabs (merge windows), full screen, window restoration.

---

## 14. Open questions

1. **"ninfer"**: I couldn't find an inference engine by this name. Is there a link? If it's
   OpenAI-compatible it already works through the generic preset.
2. **Sidebar scope**: the plan shows the same conversation library in every window's sidebar
   (like Mail or Notes), with each window selecting and running its own chat. The alternative
   is a separate conversation list per window (a window as a workspace for one server/model).
   Which one do you want?
3. **Minimum macOS version**: macOS 15 is proposed. Targeting macOS 26 would allow the newer
   SwiftUI text/rich-editor and WebView APIs and the current design language, but drops older Macs.
4. **Distribution**: Developer ID + notarized DMG is proposed (needed for an unrestricted
   terminal). Is the Mac App Store a requirement?
5. **Remote servers**: is plain HTTP over LAN/Tailscale expected? (The plan allows arbitrary
   loads and shows a warning for non-HTTPS remote hosts.)
6. **Bundle identifier / signing team** to use in `project.yml`.

---

## 15. Milestones

Each milestone ends with the app building, tests passing, and a short demo checklist.

| # | Milestone | Scope | Done when |
|---|---|---|---|
| **M0** | Scaffold | XcodeGen project, `GoooeeeKit` package, CI (Linux `swift test`, macOS `xcodebuild`), mock SSE server, entitlements/Info.plist (local network usage, ATS) | Empty 3-pane window launches; CI green |
| **M1** | Core networking (OpenAI API) | SSE parser, `OpenAIChatProvider`, request builder, curl renderer, engine presets, JSON store, Keychain | Unit tests against recorded OpenAI-API fixtures from llama.cpp, vLLM, mlx_lm, mlx-vlm, ds4 |
| **M2** | Connections UI | Connection manager, editor, model list, sampling fields with "server default", test runner, curl tab | Can create, test and save a connection to each engine; curl output runs as-is |
| **M3** | Chat MVP | Conversation sidebar with swipe-to-delete, undo and Recently Deleted; conversation view, prompt field, streaming, stop, markdown + code + copy, metrics footer, persistence | Multi-turn chat with a local llama.cpp server; metrics match server `timings`; full swipe deletes and ⌘Z restores |
| **M4** | Thinking & profiles | `ReasoningSplitter` (fields, tags, start-inside, Harmony), thinking block UI, profile registry + custom profiles, settings resolver with provenance, thinking toggle | Qwen3 / gpt-oss / DeepSeek-style / GLM outputs render correctly on ≥3 engines; inspector shows value sources |
| **M5** | Vision | Attachments (drop/paste/pick), capability gating, OpenAI image encoding | Image Q&A via llama.cpp (mmproj), mlx-vlm and vLLM |
| **M6** | Editing & actions | Edit/resend, edit assistant, regenerate (optionally with another model), continue, delete, copy variants | All actions in §8.5 work and persist |
| **M7** | Windows & settings | Multi-window, per-window state/restoration, app settings with per-type fonts, ⌘+/− scaling | Two windows stream from two servers at once; font changes apply live |
| **M8** | Terminal | SwiftTerm drawer, launch commands, start/stop + health wait, run curl in terminal | Start `llama-server` from the drawer and chat once healthy |
| **M9** | Anthropic API & template fallback | `AnthropicMessagesProvider` (thinking blocks, images); Template tab; "Load Jinja template…" with `OpenAICompletionProvider` | Chat with thinking on the Anthropic API; a GGUF with a broken template works after loading a `.jinja` file |
| **M10** | Polish & release | Performance pass (long chats, 200 tok/s streams), accessibility, keyboard shortcuts, icons, notarized DMG | Release candidate |

### Testing strategy
- **Unit (GoooeeeCore, runs on Linux)**: SSE parsing, chunk-boundary tag splitting, provider
  decoding from recorded streams per engine, settings resolution and provenance, curl rendering,
  metric math, Jinja rendering of sample templates (Qwen3, gpt-oss, Llama, Gemma).
- **Integration**: `Tools/MockServer` replays fixtures with realistic timing (slow prompt
  processing, fast generation, mid-stream errors, disconnects).
- **Manual matrix** before each release: llama.cpp, vLLM, mlx_lm, mlx-vlm, DwarfStar 4,
  LM Studio, Ollama, OpenAI (all via the OpenAI API) and the Anthropic API × {text, thinking,
  vision}.

### Risks
| Risk | Mitigation |
|---|---|
| Engines differ in reasoning fields and change them between releases | Accept all known field names; tag-parsing fallback; fixtures per engine version |
| Wrong or outdated templates inside GGUFs | Show the server template and rendered prompt (llama.cpp); suggest a template flag in the launch command; client-side Jinja as last resort |
| Profile regex picks the wrong family for a renamed model | Show the detected profile in the editor and let the user choose one or None |
| Accidental full-swipe deletes | Undo toast, ⌘Z, Recently Deleted for 30 days |
| Markdown rendering cost on long streamed answers | Block-level caching; coalesced updates; lazy stacks |
| Client-side PP speed is inaccurate (network, queueing) | Prefer server timings; label estimates "≈" |
| Strict APIs reject unknown sampling keys | Per-engine key allow-list; nil = not sent |
| Terminal under sandbox | Ship non-sandboxed (Developer ID) |

---

## 16. After v1

Branching, tool calls/MCP, chat search and folders, side-by-side "compare two models" view,
OpenAI Responses API (for reasoning summaries), SSH tunnel helper for remote servers, Sparkle updates,
Shortcuts/AppIntents, prompt library.
