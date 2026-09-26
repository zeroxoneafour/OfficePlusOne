#!/usr/bin/env python3
"""A fake OpenAI-compatible Chat Completions server for the AI fallback test.
Answers every POST /v1/chat/completions with a fixed reply, after checking the
request looks like a translated agent turn (system prompt, tools, messages).
Usage: fake_openai_server.py PORT  (exits after 60 s)"""
import json, sys, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

port = int(sys.argv[1])


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        msgs = body.get("messages", [])
        ok = (self.path.endswith("/chat/completions") and self.headers.get("Authorization") == "Bearer test-key"
              and msgs and msgs[0].get("role") == "system" and len(body.get("tools", [])) > 5)
        print("OPENAI %s path=%s tools=%d messages=%d" % ("OK" if ok else "BAD", self.path, len(body.get("tools", [])), len(msgs)), flush=True)
        reply = {"model": "fake", "choices": [{"finish_reason": "stop", "message": {"role": "assistant",
                 "content": "Hello from the fallback." if ok else "Bad request shape."}}]}
        data = json.dumps(reply).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


server = HTTPServer(("127.0.0.1", port), Handler)
threading.Timer(60, server.shutdown).start()
server.serve_forever()
