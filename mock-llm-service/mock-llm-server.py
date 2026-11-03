#!/usr/bin/env python3
import argparse
import json
import os
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

DEFAULT_PORT = int(os.environ.get("MOCK_LLM_SERVER_PORT", 8001))
MOCK_MODEL = "mock-gpt-4o"
# Streaming: pause between SSE chunks, and words per chunk.
STREAM_DELAY_MS = int(os.environ.get("MOCK_LLM_STREAM_DELAY_MS", 50))
STREAM_CHUNK_WORDS = int(os.environ.get("MOCK_LLM_STREAM_CHUNK_WORDS", 3))

class MockLLMHandler(BaseHTTPRequestHandler):
    def _send_json(self, status_code, data):
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode("utf-8"))

    def _write_sse(self, data):
        self.wfile.write(f"data: {json.dumps(data)}\n\n".encode("utf-8"))
        self.wfile.flush()

    def _send_stream(self, model, content, timestamp, usage_block):
        # OpenAI-style server-sent events: word chunks, a final chunk with
        # finish_reason and usage, then "data: [DONE]".
        cid = f"chatcmpl-mock-{timestamp}"
        words = content.split(" ")
        pieces = [" ".join(words[i:i + STREAM_CHUNK_WORDS]) for i in range(0, len(words), STREAM_CHUNK_WORDS)]
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            for i, piece in enumerate(pieces):
                text = piece if i == len(pieces) - 1 else piece + " "
                delta = {"role": "assistant", "content": text} if i == 0 else {"content": text}
                self._write_sse({
                    "id": cid, "object": "chat.completion.chunk", "created": timestamp, "model": model,
                    "choices": [{"index": 0, "delta": delta, "finish_reason": None}],
                })
                time.sleep(STREAM_DELAY_MS / 1000)
            self._write_sse({
                "id": cid, "object": "chat.completion.chunk", "created": timestamp, "model": model,
                "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
                "usage": usage_block,
            })
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except BrokenPipeError:
            # The client went away mid-stream; nothing more to send.
            pass

    def do_GET(self):
        # 1. Health Endpoint
        if self.path == "/health":
            self._send_json(200, {"status": "healthy"})
            return

        # 2. Models Endpoint
        elif self.path == "/v1/models":
            response = {
                "object": "list",
                "data": [
                    {
                        "id": MOCK_MODEL,
                        "object": "model",
                        "created": int(time.time()),
                        "owned_by": "mock-server"
                    }
                ]
            }
            self._send_json(200, response)
            return

        self._send_json(404, {"error": "Not Found"})

    def do_POST(self):
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length).decode("utf-8") if content_length > 0 else "{}"
        
        try:
            req_data = json.loads(body)
        except json.JSONDecodeError:
            req_data = {}

        # Capture requested model or fallback
        requested_model = req_data.get("model", MOCK_MODEL)
        timestamp = int(time.time())

        # Fabricated token usage data
        usage_block = {
            "prompt_tokens": 15,
            "completion_tokens": 25,
            "total_tokens": 40
        }

        # 3. Chat Completions Endpoint
        if self.path == "/v1/chat/completions":
            # Extract last user message or use fallback message
            messages = req_data.get("messages", [])
            user_prompt = messages[-1]["content"] if messages else "Hello"
            reply = f"This is a canned response to your prompt: '{user_prompt}'."

            if req_data.get("stream"):
                self._send_stream(requested_model, reply, timestamp, usage_block)
                return

            response = {
                "id": f"chatcmpl-mock-{timestamp}",
                "object": "chat.completion",
                "created": timestamp,
                "model": requested_model,
                "choices": [
                    {
                        "index": 0,
                        "message": {
                            "role": "assistant",
                            "content": reply
                        },
                        "logprobs": None,
                        "finish_reason": "stop"
                    }
                ],
                "usage": usage_block
            }
            self._send_json(200, response)
            return

        # 4. Text Completions Endpoint
        elif self.path == "/v1/completions":
            prompt = req_data.get("prompt", "")
            
            response = {
                "id": f"cmpl-mock-{timestamp}",
                "object": "text_completion",
                "created": timestamp,
                "model": requested_model,
                "choices": [
                    {
                        "text": f"\n\nThis is a canned completion response following prompt: '{prompt}'.",
                        "index": 0,
                        "logprobs": None,
                        "finish_reason": "stop"
                    }
                ],
                "usage": usage_block
            }
            self._send_json(200, response)
            return

        self._send_json(404, {"error": "Not Found"})

def make_server(port):
    return HTTPServer(("", port), MockLLMHandler)

def run_server(port):
    httpd = make_server(port)
    print(f"Mock OpenAI Server running on http://localhost:{port}")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down mock server.")
        httpd.server_close()

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Mock OpenAI-compatible LLM server")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT,
                        help="port to listen on (default: $MOCK_LLM_PORT or 8001)")
    run_server(parser.parse_args().port)
