"""Minimal Ollama API mock for benchmark script tests.

Usage: python3 mock_ollama.py PORT REQUEST_LOG

- GET  /api/tags      -> installed models (MODELS below)
- POST /api/generate  -> streams NDJSON (thinking, response, done)
                         and appends the request body to REQUEST_LOG
- POST /api/pull      -> streams pull progress NDJSON (status: success)
- model "error-model" -> HTTP 500
"""

import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODELS = ["mock-model:latest", "gemma4:12b", "error-model:latest"]

FINAL = {
    "done": True,
    "done_reason": "stop",
    "total_duration": 2_000_000_000,
    "load_duration": 100_000_000,
    "prompt_eval_count": 50,
    "prompt_eval_duration": 250_000_000,
    "eval_count": 40,
    "eval_duration": 800_000_000,
}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def log_message(self, *args):
        pass

    def _json(self, status, obj):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/api/tags":
            self._json(200, {"models": [{"name": m} for m in MODELS]})
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):
        if self.path == "/api/pull":
            self.send_response(200)
            self.send_header("Content-Type", "application/x-ndjson")
            self.end_headers()
            for chunk in [{"status": "pulling manifest"},
                          {"status": "downloading", "total": 100, "completed": 100},
                          {"status": "success"}]:
                self.wfile.write((json.dumps(chunk) + "\n").encode())
                self.wfile.flush()
            return
        if self.path != "/api/generate":
            self._json(404, {"error": "not found"})
            return
        length = int(self.headers.get("Content-Length", 0))
        req = json.loads(self.rfile.read(length).decode("utf-8"))
        with open(sys.argv[2], "a", encoding="utf-8") as log:
            log.write(json.dumps(req, ensure_ascii=False) + "\n")

        if req.get("model") == "error-model":
            self._json(500, {"error": "mock failure"})
            return

        think = req.get("think") not in (None, False)
        chunks = []
        if think:
            chunks += [{"thinking": "考え"}, {"thinking": "中..."}]
        chunks += [{"response": "こんにちは"}, {"response": "、世界"}]

        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.end_headers()
        for chunk in chunks:
            chunk.update({"model": req["model"], "done": False})
            self.wfile.write((json.dumps(chunk, ensure_ascii=False) + "\n").encode())
            self.wfile.flush()
            time.sleep(0.05)
        self.wfile.write((json.dumps(dict(FINAL, model=req["model"], response="")) + "\n").encode())
        self.wfile.flush()


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
