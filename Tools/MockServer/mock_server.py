#!/usr/bin/env python3
"""Scripted OpenAI-compatible inference server for goooeee tests and UI development.

Standard library only. Behaves like llama.cpp, vLLM, mlx-vlm or a generic server
(--engine), streams at a configurable speed (--tps), and picks a scenario from the last
user message:

  "think"        reasoning in a separate field (reasoning_content / reasoning)
  "tags"         reasoning inline as <think>...</think>
  "harmony"      gpt-oss Harmony channels in content
  "tool"         a tool call, then a final answer once the tool result is sent back
  "error"        an error in the middle of the stream
  "slow prompt"  llama.cpp prompt_progress events before the first token
  "long N"       N tokens of mixed markdown (tables, code, lists, math) for performance work
  anything else  a short markdown answer echoing the question

Endpoints: GET /v1/models, /health, /props, /version, /tools; POST /v1/chat/completions,
/v1/completions, /v1/messages (Anthropic), /tools, /apply-template,
/v1/chat/completions/control.

Usage: python3 mock_server.py --port 8080 --engine llamacpp --tps 80
"""
import argparse
import json
import random
import sys
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ARGS = None

SAMPLE_MARKDOWN = """## Answer

Here is a **short** answer with `inline code`, a list and a code block:

- first point
- second point with *emphasis*

```python
def greet(name):
    return f"Hello, {name}!"
```

| Model | Speed |
|-------|------:|
| mock  | fast  |

Euler's identity: $e^{i\\pi} + 1 = 0$.
"""

LONG_BLOCKS = [
    "### Section {n}\n\nThis paragraph discusses item {n} in some detail, with **bold** words, *italic* words and `code` spans so the renderer has work to do.\n\n",
    "- point {n}.1\n- point {n}.2\n- point {n}.3\n\n",
    "```swift\nfunc compute{n}(_ x: Int) -> Int {{\n    // step {n}\n    return x * {n} + 1\n}}\n```\n\n",
    "| key | value |\n|-----|-------|\n| a{n} | {n} |\n| b{n} | {m} |\n\n",
    "The formula $x_{n} = x_{{n-1}}^2 + c$ appears here.\n\n",
]


def tokenize(text):
    """Split text into small pieces that look like tokens."""
    pieces = []
    word = ""
    for char in text:
        word += char
        if char in " \n" or len(word) >= 4:
            pieces.append(word)
            word = ""
    if word:
        pieces.append(word)
    return pieces


def long_text(tokens):
    out = []
    n = 1
    count = 0
    while count < tokens:
        block = random.choice(LONG_BLOCKS).format(n=n, m=n * 7)
        out.append(block)
        count += len(tokenize(block))
        n += 1
    return "".join(out)


def last_user_text(messages):
    for message in reversed(messages):
        if message.get("role") == "user":
            content = message.get("content")
            if isinstance(content, list):
                return " ".join(part.get("text", "") for part in content if isinstance(part, dict))
            return content or ""
    return ""


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        if ARGS.verbose:
            sys.stderr.write("mock: " + fmt % args + "\n")

    # ---- helpers ----
    def send_json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def read_json(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            return json.loads(raw or b"{}")
        except json.JSONDecodeError:
            return {}

    def start_sse(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True

    def sse(self, payload, event=None):
        chunk = ""
        if event:
            chunk += f"event: {event}\n"
        chunk += "data: " + (payload if isinstance(payload, str) else json.dumps(payload)) + "\n\n"
        self.wfile.write(chunk.encode())
        self.wfile.flush()

    def pause(self):
        if ARGS.tps > 0:
            time.sleep(1.0 / ARGS.tps)

    def check_auth(self):
        if ARGS.api_key and self.headers.get("Authorization") != f"Bearer {ARGS.api_key}" and self.headers.get("x-api-key") != ARGS.api_key:
            self.send_json(401, {"error": {"message": "Invalid API key", "type": "authentication_error"}})
            return False
        return True

    # ---- GET ----
    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/v1/models", "/models"):
            if not self.check_auth():
                return
            entry = {"id": ARGS.model, "object": "model", "owned_by": "mock", "created": 0}
            if ARGS.engine == "vllm":
                entry["max_model_len"] = 32768
            if ARGS.engine == "mlxvlm":
                entry["loaded"] = True
            if ARGS.engine == "llamacpp" and path == "/models":
                entry["status"] = {"value": "loaded"}
            self.send_json(200, {"object": "list", "data": [entry]})
        elif path == "/health" and ARGS.engine in ("llamacpp", "vllm", "mlxvlm"):
            self.send_json(200, {"status": "ok"})
        elif path == "/props" and ARGS.engine == "llamacpp":
            self.send_json(200, {
                "default_generation_settings": {"n_ctx": 32768, "params": {"temperature": 0.8, "top_k": 40, "top_p": 0.95, "min_p": 0.05, "repeat_penalty": 1.0}},
                "total_slots": 1,
                "model_path": f"/models/{ARGS.model}.gguf",
                "role": "model",
                "modalities": {"vision": ARGS.vision, "audio": False},
                "chat_template": "{% for m in messages %}<|im_start|>{{ m.role }}\n{{ m.content }}<|im_end|>\n{% endfor %}",
                "build_info": "mock",
            })
        elif path == "/version" and ARGS.engine == "vllm":
            self.send_json(200, {"version": "0.0.0-mock"})
        elif path == "/tools" and ARGS.engine == "llamacpp" and ARGS.server_tools:
            self.send_json(200, [{
                "display_name": "Read file", "tool": "read_file", "type": "builtin", "permissions": {"write": False}, "uses_cwd": True,
                "definition": {"type": "function", "function": {"name": "read_file", "description": "Read a file", "parameters": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}}},
            }])
        else:
            self.send_json(404, {"error": {"message": f"Not found: {path}"}})

    # ---- POST ----
    def do_POST(self):
        path = self.path.split("?")[0]
        body = self.read_json()
        if not self.check_auth():
            return
        if path == "/v1/chat/completions":
            self.chat(body)
        elif path == "/v1/completions":
            self.completion(body)
        elif path == "/v1/messages":
            self.anthropic(body)
        elif path == "/tools" and ARGS.engine == "llamacpp":
            self.send_json(200, {"plain_text_response": f"contents of {body.get('params', {}).get('path', '?')}"})
        elif path == "/apply-template" and ARGS.engine == "llamacpp":
            prompt = "".join(f"<|im_start|>{m.get('role')}\n{m.get('content')}<|im_end|>\n" for m in body.get("messages", []))
            self.send_json(200, {"prompt": prompt + "<|im_start|>assistant\n"})
        elif path == "/v1/chat/completions/control":
            self.send_json(200, {"success": True})
        else:
            self.send_json(404, {"error": {"message": f"Not found: {path}"}})

    def chunk(self, cid, delta=None, finish=None, extra=None):
        payload = {"id": cid, "object": "chat.completion.chunk", "created": int(time.time()), "model": ARGS.model,
                   "choices": [{"index": 0, "delta": delta or {}, "finish_reason": finish}]}
        if extra:
            payload.update(extra)
        return payload

    def reasoning_key(self):
        return "reasoning" if ARGS.engine == "vllm" else "reasoning_content"

    def chat(self, body):
        messages = body.get("messages", [])
        text = last_user_text(messages).lower()
        stream = body.get("stream", False)
        tools = body.get("tools") or []
        cid = "chatcmpl-" + uuid.uuid4().hex[:12]
        started = time.time()

        has_images = any(isinstance(m.get("content"), list) and any(p.get("type") == "image_url" for p in m["content"]) for m in messages)
        if has_images and not ARGS.vision:
            self.send_json(400, {"error": {"message": "image input is not supported - hint: if this is unexpected, you may need to provide the mmproj"}})
            return

        reasoning = ""
        content = ""
        tool_call = None
        if messages and messages[-1].get("role") == "tool":
            content = f"The tool returned: {messages[-1].get('content')}. That answers the question."
        elif "tool" in text and tools:
            fn = tools[0]["function"]
            props = list(fn.get("parameters", {}).get("properties", {}).keys())
            arguments = {props[0]: "Asia/Tokyo"} if props else {}
            tool_call = {"id": "call_" + uuid.uuid4().hex[:8], "name": fn["name"], "arguments": json.dumps(arguments)}
        elif "think" in text:
            reasoning = "The user wants a short answer. I will think briefly, then answer."
            content = "After thinking: **OK**."
        elif "tags" in text:
            content = "<think>Reasoning inside tags.</think>\n\nAnswer after tags."
        elif "harmony" in text:
            content = "<|channel|>analysis<|message|>Harmony reasoning.<|end|><|start|>assistant<|channel|>final<|message|>Harmony answer."
        elif text.startswith("long"):
            parts = text.split()
            count = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 2000
            content = long_text(count)
        elif "ok" in text and "single word" in text:
            content = "OK"
        else:
            content = SAMPLE_MARKDOWN

        prompt_tokens = sum(len(tokenize(json.dumps(m.get("content")))) for m in messages)
        if not stream:
            message = {"role": "assistant", "content": content or None}
            if reasoning:
                message[self.reasoning_key()] = reasoning
            if tool_call:
                message["tool_calls"] = [{"id": tool_call["id"], "type": "function", "function": {"name": tool_call["name"], "arguments": tool_call["arguments"]}}]
            completion_tokens = len(tokenize(content + reasoning))
            self.send_json(200, {"id": cid, "object": "chat.completion", "model": ARGS.model,
                                 "choices": [{"index": 0, "message": message, "finish_reason": "tool_calls" if tool_call else "stop"}],
                                 "usage": {"prompt_tokens": prompt_tokens, "completion_tokens": completion_tokens, "total_tokens": prompt_tokens + completion_tokens}})
            return

        self.start_sse()
        try:
            if ARGS.engine == "llamacpp" and body.get("return_progress"):
                total = max(prompt_tokens, 1)
                steps = 5 if "slow prompt" in text else 1
                for step in range(1, steps + 1):
                    if steps > 1:
                        time.sleep(0.2)
                    self.sse(self.chunk(cid, {}, None, {"prompt_progress": {"total": total, "cache": 0, "processed": total * step // steps, "time_ms": (time.time() - started) * 1000}}))
            self.sse(self.chunk(cid, {"role": "assistant", "content": None}))
            first_token = None
            count = 0
            for piece in tokenize(reasoning):
                self.pause()
                first_token = first_token or time.time()
                self.sse(self.chunk(cid, {self.reasoning_key(): piece}))
                count += 1
            if tool_call:
                self.pause()
                first_token = first_token or time.time()
                self.sse(self.chunk(cid, {"tool_calls": [{"index": 0, "id": tool_call["id"], "type": "function", "function": {"name": tool_call["name"], "arguments": ""}}]}))
                for piece in tokenize(tool_call["arguments"]):
                    self.pause()
                    self.sse(self.chunk(cid, {"tool_calls": [{"index": 0, "function": {"arguments": piece}}]}))
                    count += 1
            for index, piece in enumerate(tokenize(content)):
                if "error" in text and index == 3:
                    self.sse({"error": {"message": "Mock server error in the middle of the stream", "code": 500}})
                    return
                self.pause()
                first_token = first_token or time.time()
                self.sse(self.chunk(cid, {"content": piece}))
                count += 1
            finish = "tool_calls" if tool_call else "stop"
            done = time.time()
            extra = {}
            if ARGS.engine in ("llamacpp",):
                prompt_ms = ((first_token or done) - started) * 1000
                predicted_ms = (done - (first_token or done)) * 1000
                extra["timings"] = {"prompt_n": prompt_tokens, "prompt_ms": prompt_ms, "predicted_n": count, "predicted_ms": predicted_ms, "cache_n": 0,
                                    "prompt_per_second": prompt_tokens / max(prompt_ms / 1000, 1e-6), "predicted_per_second": count / max(predicted_ms / 1000, 1e-6)}
            if ARGS.engine == "mlxvlm":
                extra["timings"] = {"predicted_per_second": count / max(done - (first_token or done), 1e-6)}
            self.sse(self.chunk(cid, {}, finish, extra))
            if (body.get("stream_options") or {}).get("include_usage"):
                usage = {"id": cid, "object": "chat.completion.chunk", "model": ARGS.model, "choices": [],
                         "usage": {"prompt_tokens": prompt_tokens, "completion_tokens": count, "total_tokens": prompt_tokens + count}}
                self.sse(usage)
            self.sse("[DONE]")
        except (BrokenPipeError, ConnectionResetError):
            pass

    def completion(self, body):
        prompt = body.get("prompt", "")
        cid = "cmpl-" + uuid.uuid4().hex[:12]
        content = "Completion for a prompt of %d characters." % len(prompt)
        if not body.get("stream"):
            self.send_json(200, {"id": cid, "object": "text_completion", "choices": [{"index": 0, "text": content, "finish_reason": "stop"}]})
            return
        self.start_sse()
        for piece in tokenize(content):
            self.pause()
            self.sse({"id": cid, "object": "text_completion", "choices": [{"index": 0, "text": piece, "finish_reason": None}]})
        self.sse({"id": cid, "object": "text_completion", "choices": [{"index": 0, "text": "", "finish_reason": "stop"}]})
        self.sse("[DONE]")

    def anthropic(self, body):
        text = last_user_text(body.get("messages", [])).lower()
        mid = "msg_" + uuid.uuid4().hex[:12]
        thinking = "Thinking about it." if body.get("thinking") else ""
        answer = "Hello from the mock Anthropic API."
        self.start_sse()
        self.sse({"type": "message_start", "message": {"id": mid, "model": body.get("model"), "usage": {"input_tokens": 12, "output_tokens": 0}}}, "message_start")
        index = 0
        if thinking:
            self.sse({"type": "content_block_start", "index": index, "content_block": {"type": "thinking", "thinking": ""}}, "content_block_start")
            for piece in tokenize(thinking):
                self.pause()
                self.sse({"type": "content_block_delta", "index": index, "delta": {"type": "thinking_delta", "thinking": piece}}, "content_block_delta")
            self.sse({"type": "content_block_delta", "index": index, "delta": {"type": "signature_delta", "signature": "sig123"}}, "content_block_delta")
            self.sse({"type": "content_block_stop", "index": index}, "content_block_stop")
            index += 1
        if "tool" in text and body.get("tools"):
            tool = body["tools"][0]
            self.sse({"type": "content_block_start", "index": index, "content_block": {"type": "tool_use", "id": "toolu_1", "name": tool["name"], "input": {}}}, "content_block_start")
            self.sse({"type": "content_block_delta", "index": index, "delta": {"type": "input_json_delta", "partial_json": "{\"timezone\": \"Asia/Tokyo\"}"}}, "content_block_delta")
            self.sse({"type": "content_block_stop", "index": index}, "content_block_stop")
            stop = "tool_use"
        else:
            self.sse({"type": "content_block_start", "index": index, "content_block": {"type": "text", "text": ""}}, "content_block_start")
            for piece in tokenize(answer):
                self.pause()
                self.sse({"type": "content_block_delta", "index": index, "delta": {"type": "text_delta", "text": piece}}, "content_block_delta")
            self.sse({"type": "content_block_stop", "index": index}, "content_block_stop")
            stop = "end_turn"
        self.sse({"type": "message_delta", "delta": {"stop_reason": stop}, "usage": {"output_tokens": 9}}, "message_delta")
        self.sse({"type": "message_stop"}, "message_stop")


def main():
    global ARGS
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--engine", choices=["llamacpp", "vllm", "mlxvlm", "generic"], default="llamacpp")
    parser.add_argument("--model", default="mock-qwen3-8b")
    parser.add_argument("--tps", type=float, default=200, help="tokens per second (0 = as fast as possible)")
    parser.add_argument("--vision", action="store_true", help="accept image input")
    parser.add_argument("--server-tools", action="store_true", help="expose llama.cpp /tools")
    parser.add_argument("--api-key", default="", help="require this API key")
    parser.add_argument("--verbose", action="store_true")
    ARGS = parser.parse_args()
    server = ThreadingHTTPServer((ARGS.host, ARGS.port), Handler)
    server.daemon_threads = True
    print(f"mock server ({ARGS.engine}) on http://{ARGS.host}:{ARGS.port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
