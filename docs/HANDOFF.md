# Handoff: from the Linux container to the Mac

Everything so far was written in a Linux container. The `GoooeeeKit` package builds and its
tests pass there; the macOS app has never been compiled. This page lists what's verified, what
isn't, and where to start on the Mac.

## What's verified

`Packages/GoooeeeKit` builds and passes its tests on Linux (Swift 6.2, Swift 6 language mode,
complete concurrency checking):

| Module | Covered by tests |
|---|---|
| `GoooeeeCore` | Request building per engine, SSE parsing, reasoning splitting at every chunk boundary, metrics, settings resolution, curl rendering, connection tester, persistence with full-text search, chat engine and agentic loop, against fixtures and the live mock server |
| `GoooeeeMCP` | stdio transport against the mock MCP server: tools, progress, prompts, resources, reconnect after a crash, malformed output, timeouts |
| `GoooeeeMarkdown` | Incremental markdown (equal to a full parse at every chunk size from 1 to 64), math protection, syntax highlighter output and speed |
| `GoooeeeTranscript` | Row building, signatures, paging and diff steps |

Run them on the Mac with `cd Packages/GoooeeeKit && swift test`.

## What isn't verified

Everything under `App/`. It has only been parsed with `swiftc -parse`, never type-checked
against the macOS SDK. Expect a round of compile errors. Most should be small: a wrong argument
label, a missing `@MainActor`, an optional to unwrap.

| Area | Files | Risk |
|---|---|---|
| App shell, models | `App/GoooeeeApp.swift`, `App/AppModel.swift`, `App/Workspace/`, `App/Chat/ChatController.swift` | Low to medium |
| Workspace window, sidebar, search, composer, inspector | `App/Views/Workspace/`, `App/Views/Chat/`, `App/Views/Inspector/`, `App/Views/Common/` | Medium: SwiftUI type-checking, `NSTextView` composer behavior |
| Connections, MCP servers, settings, workspaces windows | `App/Views/Connections/`, `App/Views/MCP/`, `App/Views/Settings/`, `App/Views/Workspaces/`, `App/Services/ElicitationCenter.swift` | Medium |
| Transcript | `App/Transcript/` | High: the AppKit table, TextKit 2 measuring, the display link and scroll anchoring need tuning on real hardware |
| Terminal | `App/Views/Terminal/` | Medium: written against SwiftTerm 1.20.0's source |
| Keychain, attachments | `App/Services/` | Low |

## Known risks to check first

Places the code makes assumptions it couldn't verify without the macOS SDK:

- **SwiftMath** (`App/Transcript/MathRenderer.swift`): the `MathImage(latex:fontSize:textColor:labelMode:textAlignment:)`
  initializer and `asImage()`. Everything is behind `#if canImport(SwiftMath)`, so removing the
  package falls back to showing LaTeX source.
- **Transcript table** (`TranscriptViewController.swift`): several remove/insert steps applied in
  one `beginUpdates`/`endUpdates`, `rect(ofRow:)` used for scroll anchoring before the table
  re-tiles, and `view.displayLink(target:selector:)` pacing `flush()`.
- **TextKit 2**: `NSTextView(usingTextLayoutManager:)` on subclasses, and measured heights matching
  what the cells draw.
- **SwiftUI type-checking**: the optional-value `TextField` in the MCP server editor, `Table`
  columns in the Workspaces window, `ForEach` over bindings in the key/value editors, and
  `NSPanel` sizing in `ElicitationCenter`.
- **Font bridging**: `NSFont` → SwiftUI `Font` is written as `Font(nsFont as CTFont)`.

Transcript behavior that differs from the plan, on purpose:

- Branch arrows are in each message's footer, not in the assistant header.
- Editing an assistant message or showing its raw output happens in the footer row; the message's
  markdown rows collapse while the editor is open.
- Clicking an attachment opens it in its default app (not Quick Look yet).
- Table cells aren't selectable; Copy and Copy as Markdown are on hover and in the context menu.
- While thinking streams, only the last 6,000 characters show, as plain text; the full text is
  rendered as markdown once thinking ends.

## Suggested order on the Mac

1. `open goooeee.xcodeproj` (or `xcodegen generate` first if the project is missing). Let Xcode
   resolve packages.
2. Build. Fix compile errors file by file; the package is already correct, so errors are in `App/`.
3. Start the mock server and create a workspace for it:
   `python3 Tools/MockServer/mock_server.py --engine llamacpp --port 8080 --vision --tps 80`
4. Check, in this order: sending and streaming; thinking (`think`); long output and scrolling
   (`long 20000`); tool calls with the mock MCP server (`Tools/MockMCP/mock_mcp_server.py`,
   added in MCP Servers as a stdio server); prompt progress (`slow prompt`); errors (`error`).
5. Then a real server (llama.cpp with `--jinja`), the terminal's Start Server, and
   multiple windows.

## Decisions made while building

- **Settings precedence:** the model profile wins over llama.cpp's reported defaults unless a
  connection chooses "server, then model profile". See `docs/PLAN.md` §10.2.
- **Highlighting:** an own regex highlighter replaced HighlightSwift, whose HTML conversion is
  slow and main-thread-bound.
- **Swift modes:** the package uses Swift 6 with complete checking; the app target uses Swift 5
  mode with targeted checking (`Config/Shared.xcconfig`). Switch the app to Swift 6 once it
  compiles cleanly if you want.
- **Signing:** ad hoc with the placeholder bundle ID `local.goooeee.app`. Put the real bundle ID
  and team in `Config/Local.xcconfig` when you have them.
- **CI:** `.github/workflows/ci.yml` runs the package tests on Linux for every push. The macOS app
  build runs only when started by hand (Actions → CI → Run workflow), because macOS runner minutes
  cost ten times as much on a private repository.
