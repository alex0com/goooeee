SSE fixtures for provider and accumulator tests.

These are synthesized from each engine's documented stream format (llama.cpp
`reasoning_content` + `timings` + `prompt_progress`, vLLM `reasoning` + trailing `usage`,
mlx-vlm `timings.predicted_per_second`, OpenAI tool call deltas, Anthropic message events).
Replace or extend them with real recordings (`curl -N ... > file.sse`) when an engine changes
its output.
