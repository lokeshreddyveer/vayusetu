#!/usr/bin/env python3
"""Small self-hosted observer; place behind local Caddy HTTPS."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from ipaddress import ip_address
from threading import Lock
from time import monotonic
from urllib.parse import parse_qs, urlsplit
import json
import re

_NONCE = re.compile(r"^[0-9a-f]{48}$")
_lock = Lock()
_limits: dict[str, tuple[float, int]] = {}


class Handler(BaseHTTPRequestHandler):
    server_version = "VayuSetuObserver"
    sys_version = ""

    def log_message(self, _format: str, *_args: object) -> None:
        # Do not persist source addresses, query nonces, or request paths.
        return

    def do_GET(self) -> None:
        parsed = urlsplit(self.path)
        try:
            query = parse_qs(parsed.query, keep_blank_values=True, strict_parsing=True)
        except ValueError:
            self._reply(400, {"error": "invalid request"})
            return
        if parsed.path != "/v1/observe" or set(query) != {"nonce"} or len(query["nonce"]) != 1:
            self._reply(400, {"error": "invalid request"})
            return
        nonce = query["nonce"][0]
        if not _NONCE.fullmatch(nonce):
            self._reply(400, {"error": "invalid request"})
            return

        peer = self.client_address[0]
        try:
            if not ip_address(peer).is_loopback:
                self._reply(400, {"error": "observer address unavailable"})
                return
            forwarded = self.headers.get_all("X-Forwarded-For", [])
            if len(forwarded) != 1 or "," in forwarded[0]:
                self._reply(400, {"error": "observer address unavailable"})
                return
            address = ip_address(forwarded[0].strip())
        except ValueError:
            self._reply(400, {"error": "observer address unavailable"})
            return

        if not address.is_global or not self._allow(str(address)):
            self._reply(429 if address.is_global else 400, {"error": "request unavailable"})
            return
        self._reply(200, {"nonce": nonce, "address": str(address)})

    @staticmethod
    def _allow(address: str) -> bool:
        now = monotonic()
        with _lock:
            for key, (started, _) in list(_limits.items()):
                if now - started >= 60:
                    del _limits[key]
            started, count = _limits.get(address, (now, 0))
            if count >= 30 or (address not in _limits and len(_limits) >= 4096):
                return False
            _limits[address] = (started, count + 1)
            return True

    def _reply(self, status: int, payload: dict[str, str]) -> None:
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store, private")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 8787), Handler).serve_forever()
