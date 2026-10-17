# goooeee

A native macOS 26 chat app for local and remote inference servers: llama.cpp, vLLM, mlx_lm,
mlx-vlm, DwarfStar 4, LM Studio, Ollama, OpenAI, and anything else that speaks the OpenAI API
(the default for every engine, including custom ones such as ninfer). The Anthropic API is used
only for Anthropic's own service.

goooeee doesn't run models itself. Each window is a workspace for one server and one model, with
its own chats, settings, tools and terminal. The feature set follows the llama.cpp web UI as a
native Mac app:

- streaming chat with markdown, code highlighting, tables, math and thinking blocks
- prompt-processing, generation and average speeds
- branches, editing, regenerate and continue
- image, PDF and text attachments
- MCP tools, prompts and resources, with an agentic loop and permission prompts
- saved server connections with sampling settings, a connection test and ready-to-run curl
  commands
- a terminal in each window for launching the server

See [docs/PLAN.md](docs/PLAN.md) for the design and [docs/HANDOFF.md](docs/HANDOFF.md) for the
current state.

## Requirements

- macOS 26 or later
- Xcode 26 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), only if you
  change `project.yml`

## Build and run

```sh
git clone https://github.com/alex0com/goooeee.git
cd goooeee
xcodegen generate        # only needed if goooeee.xcodeproj is missing or project.yml changed
open goooeee.xcodeproj
```

Choose the **goooeee** scheme and press ⌘R. Xcode resolves the Swift packages (GRDB,
swift-markdown, the MCP Swift SDK, swift-jinja, SwiftTerm, SwiftMath) on first open.

From the command line:

```sh
xcodebuild -project goooeee.xcodeproj -scheme goooeee -configuration Release build
```

### Signing

The default build is signed ad hoc ("Sign to Run Locally") with the placeholder bundle ID
`local.goooeee.app`, so no Apple developer account is needed. To use your own bundle ID and team:

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig   # git-ignored
# edit PRODUCT_BUNDLE_IDENTIFIER, DEVELOPMENT_TEAM, CODE_SIGN_STYLE, CODE_SIGN_IDENTITY
```

With ad-hoc signing macOS may ask again for Keychain access to saved API keys after a rebuild.
Choose **Always Allow**.

The app isn't sandboxed: it starts MCP servers and inference servers as local processes and runs
a shell in its terminal.

## Tests

The app's logic lives in the `GoooeeeKit` Swift package, which builds and tests on macOS and
Linux:

```sh
cd Packages/GoooeeeKit
swift test
```

The tests start the mock inference server (`Tools/MockServer/mock_server.py`) and the mock MCP
server (`Tools/MockMCP/mock_mcp_server.py`), so they need `python3`.

## Trying it without a model

The mock server imitates llama.cpp, vLLM, mlx-vlm or a generic OpenAI server, including thinking,
tool calls, prompt progress and errors:

```sh
python3 Tools/MockServer/mock_server.py --engine llamacpp --port 8080 --vision --tps 60
```

Then create a workspace for `http://127.0.0.1:8080`. Keywords in a message pick a scenario:
`think`, `tags`, `harmony`, `tool`, `error`, `slow prompt`, `long 5000`.

## Layout

| Path | What |
|---|---|
| `App/` | The macOS app (SwiftUI windows, AppKit transcript, terminal) |
| `Packages/GoooeeeKit/` | Providers, streaming, settings, persistence, chat engine, MCP, markdown, transcript rows |
| `Config/` | Build settings and signing (`.xcconfig`) |
| `Tools/` | Mock inference and MCP servers for development and tests |
| `project.yml` | XcodeGen spec for `goooeee.xcodeproj` |
