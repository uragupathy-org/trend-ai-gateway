"""Tests for the streaming mode of the mock LLM. Run from the repo root:

    python3 -m unittest discover -s mock-llm-service/tests -v
"""
import importlib.util
import json
import os
import pathlib
import threading
import unittest
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent.parent
os.environ["MOCK_LLM_STREAM_DELAY_MS"] = "0"
os.environ["MOCK_LLM_STREAM_CHUNK_WORDS"] = "3"

spec = importlib.util.spec_from_file_location("mock_llm_server", HERE / "mock-llm-server.py")
LLM = importlib.util.module_from_spec(spec)
spec.loader.exec_module(LLM)


class MockLlmStreamTests(unittest.TestCase):
    def setUp(self):
        self.server = LLM.make_server(0)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}/v1/chat/completions"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()

    def post(self, payload):
        req = urllib.request.Request(self.url, data=json.dumps(payload).encode(),
                                     headers={"Content-Type": "application/json"}, method="POST")
        return urllib.request.urlopen(req, timeout=5)

    def test_non_stream_returns_single_json_completion(self):
        with self.post({"model": "mock-gpt-4o", "messages": [{"role": "user", "content": "hi"}]}) as resp:
            self.assertEqual(resp.headers["Content-Type"], "application/json")
            body = json.loads(resp.read())
        self.assertEqual(body["object"], "chat.completion")
        self.assertIn("hi", body["choices"][0]["message"]["content"])

    def test_stream_returns_sse_chunks_and_done(self):
        with self.post({"model": "mock-gpt-4o", "stream": True,
                        "messages": [{"role": "user", "content": "stream test"}]}) as resp:
            self.assertEqual(resp.headers["Content-Type"], "text/event-stream")
            raw = resp.read().decode()

        events = [line[len("data: "):] for line in raw.split("\n") if line.startswith("data: ")]
        self.assertEqual(events[-1], "[DONE]")

        chunks = [json.loads(e) for e in events[:-1]]
        self.assertTrue(all(c["object"] == "chat.completion.chunk" for c in chunks))
        self.assertEqual(chunks[0]["choices"][0]["delta"].get("role"), "assistant")
        self.assertEqual(chunks[-1]["choices"][0]["finish_reason"], "stop")

        text = "".join(c["choices"][0]["delta"].get("content", "") for c in chunks)
        self.assertEqual(text, "This is a canned response to your prompt: 'stream test'.")

    def test_stream_splits_into_word_chunks(self):
        with self.post({"model": "mock-gpt-4o", "stream": True,
                        "messages": [{"role": "user", "content": "one two three four five six seven"}]}) as resp:
            raw = resp.read().decode()
        content_chunks = [json.loads(line[6:])["choices"][0]["delta"].get("content")
                          for line in raw.split("\n")
                          if line.startswith("data: ") and line != "data: [DONE]"]
        content_chunks = [c for c in content_chunks if c]
        self.assertGreater(len(content_chunks), 1)


if __name__ == "__main__":
    unittest.main()
