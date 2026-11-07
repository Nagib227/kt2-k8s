import json
import os
import signal
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "8080"))
VERSION = os.environ.get("APP_VERSION", "1.0.0")

ITEMS = [
    {"id": 1, "title": "Пары", "text": "Облачные технологии: практика по Kubernetes"},
    {"id": 2, "title": "Библиотека", "text": "Читальный зал работает до 21:00"},
]


def database_mode():
    return "external" if os.environ.get("DATABASE_URL") else "not-configured"


def announcements():
    payload = {
        "version": VERSION,
        "message": os.environ.get("MESSAGE", "CampusBoard"),
        "database": database_mode(),
        "token_set": bool(os.environ.get("API_TOKEN")),
        "items": ITEMS,
    }
    if os.environ.get("API_TOKEN") and os.environ["API_TOKEN"] in json.dumps(payload):
        raise RuntimeError("secret leaked into response")
    return payload


def ready_body():
    if os.environ.get("READY", "true") != "true":
        return 503, {"status": "not-ready", "version": VERSION}
    return 200, {"status": "ready", "version": VERSION, "database": database_mode()}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/live":
            return self._send(200, {"status": "alive", "version": VERSION})
        if path == "/ready":
            code, body = ready_body()
            return self._send(code, body)
        if path == "/api/announcements":
            return self._send(200, announcements())
        self._send(404, {"error": "not found"})

    def _send(self, code, payload):
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        # Request line only. Headers and the API token are never written.
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)


def serve():
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.daemon_threads = True

    def handle_sigterm(signum, frame):
        print("SIGTERM received, finishing in-flight requests", flush=True)
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, handle_sigterm)
    print("listening on %s version %s" % (PORT, VERSION), flush=True)
    server.serve_forever()
    server.server_close()
    print("stopped", flush=True)


if __name__ == "__main__":
    serve()
