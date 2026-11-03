#!/usr/bin/env python3
"""Loopback-only fake Responses endpoint for the native integration test."""
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
import json
import sys
import threading


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if self.headers.get("Authorization") == "Bearer fake-cam-test-key":
            Path(sys.argv[2]).write_text("matched", encoding="utf-8")
        response = {"id": "resp_fake", "object": "response", "created_at": 0,
                    "status": "completed", "model": "test-model", "output": [],
                    "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2}}
        event = "data: " + json.dumps({"type": "response.completed", "response": response}) + "\n\n"
        data = event.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        threading.Thread(target=self.server.shutdown, daemon=True).start()


server = HTTPServer(("127.0.0.1", 0), Handler)
Path(sys.argv[1]).write_text(str(server.server_port), encoding="utf-8")
server.serve_forever()
