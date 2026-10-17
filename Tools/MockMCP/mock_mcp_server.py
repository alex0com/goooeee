#!/usr/bin/env python3
"""Minimal stdio MCP server for goooeee tests. Standard library only.

Tools: echo(text), add(a, b), slow(seconds) with progress notifications, image() returning a
1x1 PNG, fail() returning an error result. Prompts: greet(name). Resources: mock://readme,
template mock://notes/{id}. Sends a log notification after initialization.

Edge-case modes:
  --crash-after N   exit after N requests (tests reconnect)
  --malformed       write a garbage line before each response
  --slow-init S     sleep S seconds before answering initialize
  --stderr          write noise to stderr
"""
import argparse
import json
import sys
import time

PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

TOOLS = [
    {"name": "echo", "description": "Echo the text back", "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]},
     "annotations": {"readOnlyHint": True}},
    {"name": "add", "description": "Add two numbers", "inputSchema": {"type": "object", "properties": {"a": {"type": "number"}, "b": {"type": "number"}}, "required": ["a", "b"]}},
    {"name": "slow", "description": "Wait and report progress", "inputSchema": {"type": "object", "properties": {"seconds": {"type": "number"}}}},
    {"name": "image", "description": "Return an image", "inputSchema": {"type": "object", "properties": {}}},
    {"name": "fail", "description": "Always fails", "inputSchema": {"type": "object", "properties": {}}},
]


def write(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def result(request_id, payload):
    write({"jsonrpc": "2.0", "id": request_id, "result": payload})


def error(request_id, code, message):
    write({"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}})


def call_tool(request_id, params, progress_token):
    name = params.get("name")
    args = params.get("arguments") or {}
    if name == "echo":
        result(request_id, {"content": [{"type": "text", "text": str(args.get("text", ""))}], "isError": False})
    elif name == "add":
        result(request_id, {"content": [{"type": "text", "text": str(float(args.get("a", 0)) + float(args.get("b", 0)))}], "isError": False})
    elif name == "slow":
        seconds = float(args.get("seconds", 0.3))
        steps = 3
        for step in range(1, steps + 1):
            time.sleep(seconds / steps)
            if progress_token is not None:
                write({"jsonrpc": "2.0", "method": "notifications/progress",
                       "params": {"progressToken": progress_token, "progress": step, "total": steps, "message": f"step {step}"}})
        result(request_id, {"content": [{"type": "text", "text": "done"}], "isError": False})
    elif name == "image":
        result(request_id, {"content": [{"type": "image", "data": PNG, "mimeType": "image/png"}], "isError": False})
    elif name == "fail":
        result(request_id, {"content": [{"type": "text", "text": "this tool always fails"}], "isError": True})
    else:
        error(request_id, -32602, f"Unknown tool: {name}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--crash-after", type=int, default=0)
    parser.add_argument("--malformed", action="store_true")
    parser.add_argument("--slow-init", type=float, default=0)
    parser.add_argument("--stderr", action="store_true")
    args = parser.parse_args()
    handled = 0

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            continue
        method = message.get("method")
        request_id = message.get("id")
        params = message.get("params") or {}
        if args.stderr:
            sys.stderr.write(f"mock-mcp: handling {method}\n")
            sys.stderr.flush()
        if request_id is None:
            continue  # notification
        if args.malformed:
            sys.stdout.write("this is not json\n")
            sys.stdout.flush()
        handled += 1

        if method == "initialize":
            if args.slow_init:
                time.sleep(args.slow_init)
            result(request_id, {
                "protocolVersion": params.get("protocolVersion", "2025-06-18"),
                "capabilities": {"tools": {"listChanged": True}, "prompts": {}, "resources": {"subscribe": False}, "logging": {}},
                "serverInfo": {"name": "mock-mcp", "version": "1.0.0"},
                "instructions": "Mock server for tests.",
            })
        elif method == "ping":
            result(request_id, {})
        elif method == "tools/list":
            result(request_id, {"tools": TOOLS})
        elif method == "tools/call":
            token = (params.get("_meta") or {}).get("progressToken")
            call_tool(request_id, params, token)
        elif method == "prompts/list":
            result(request_id, {"prompts": [{"name": "greet", "description": "Greet someone", "arguments": [{"name": "name", "required": True}]}]})
        elif method == "prompts/get":
            name = (params.get("arguments") or {}).get("name", "you")
            result(request_id, {"messages": [{"role": "user", "content": {"type": "text", "text": f"Please greet {name} warmly."}}]})
        elif method == "resources/list":
            result(request_id, {"resources": [{"uri": "mock://readme", "name": "readme", "mimeType": "text/markdown"}]})
        elif method == "resources/templates/list":
            result(request_id, {"resourceTemplates": [{"uriTemplate": "mock://notes/{id}", "name": "note"}]})
        elif method == "resources/read":
            uri = params.get("uri")
            result(request_id, {"contents": [{"uri": uri, "mimeType": "text/markdown", "text": f"# Contents of {uri}"}]})
        elif method == "logging/setLevel":
            result(request_id, {})
            write({"jsonrpc": "2.0", "method": "notifications/message", "params": {"level": "info", "logger": "mock", "data": "logging enabled"}})
        else:
            error(request_id, -32601, f"Method not found: {method}")

        if args.crash_after and handled >= args.crash_after:
            sys.exit(3)


if __name__ == "__main__":
    main()
