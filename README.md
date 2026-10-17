# goooeee

A native macOS 26 chat app for local and remote inference servers: llama.cpp, vLLM, mlx_lm,
mlx-vlm, DwarfStar 4, LM Studio, Ollama, and anything else that speaks the OpenAI API (the
default for every engine). Each window is a workspace for one server and one model.

goooeee doesn't run models itself. It follows the llama.cpp web UI's feature set as a native
Mac app: streaming chat with thinking blocks, branching, attachments, speed statistics, MCP
tools/prompts/resources with an agentic loop, and a terminal in each window for launching the
server.

It's built from source with Xcode and distributed outside the App Store. Build instructions will
be added with the first scaffold.

Status: planning. See [docs/PLAN.md](docs/PLAN.md).
