#!/usr/bin/env python3
"""A fake vault.sock: answers as the mode file says and records each path it is asked for."""
import json
import os
import socketserver
import sys
from http.server import BaseHTTPRequestHandler

SOCKET, MODE_FILE, LOG_FILE, CANARY = sys.argv[1:5]


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        with open(MODE_FILE, encoding="utf-8") as mode_file:
            mode = mode_file.read().strip()
        path = self.path.split("?")[0]
        with open(LOG_FILE, "a", encoding="utf-8") as log:
            log.write(path + "\n")
        status, body = 404, {"errors": []}
        if path == "/v1/auth/token/lookup-self":
            if mode == "no-token":
                status, body = 503, {"errors": [f"no token {CANARY}"]}
            else:
                status, body = 200, {"data": {"id": CANARY, "policies": ["default"]}}
        elif path.startswith("/v1/sys/internal/ui/mounts/"):
            status, body = 200, {"data": {"path": "kv/", "type": "kv", "options": {"version": "2"}}}
        elif path.startswith("/v1/kv/data/xolotl/keys/"):
            if mode == "ok" and path == "/v1/kv/data/xolotl/keys/host-sample/sample":
                status, body = 200, {"data": {"data": {"api_key": CANARY}, "metadata": {"version": 1}}}
            elif mode == "server-error":
                status, body = 500, {"errors": [f"internal {CANARY}"]}
        payload = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def address_string(self):
        return "fake-vault"

    def log_message(self, *_):
        pass


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


if os.path.exists(SOCKET):
    os.unlink(SOCKET)
with Server(SOCKET, Handler) as server:
    server.serve_forever()
