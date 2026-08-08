#!/usr/bin/env python3
"""Tiny form-based login gate for the session viewer.

Sits behind nginx's `auth_request` directive (see
config/nginx/session-viewer.conf): nginx asks GET /auth-check "is this
visitor's cookie valid?" before serving anything from webui/, and
serves this server's /login page instead of a browser-native HTTP
Basic Auth popup when it isn't.

Deliberately stdlib-only (no Flask/etc) -- this is a small gate in
front of a private admin tool on a network already restricted to
ADMIN_CIDR (see docs/SECURITY.md), not a general-purpose auth system.
Sessions are a stateless signed cookie (expiry + HMAC), so there's no
session store to lose on a restart.
"""
import hmac
import hashlib
import html
import http.server
import os
import socketserver
import threading
import time
import urllib.parse

USER = os.environ["VIEWER_USER"]
PASSWORD = os.environ["VIEWER_PASSWORD"]
SECRET = os.environ["VIEWER_SESSION_SECRET"].encode()
TTL_SECONDS = int(float(os.environ.get("VIEWER_SESSION_TTL_HOURS", "12")) * 3600)
COOKIE_NAME = "viewer_session"
PORT = int(os.environ.get("PORT", "5000"))

# Naive per-IP brute-force throttle: 5 failed attempts locks that IP
# out for 60s. Defense in depth only -- the real control is that this
# service has no route to the internet at all (internal-only network)
# and sits behind ADMIN_CIDR at the network level.
_lock = threading.Lock()
_fails: dict[str, list[float]] = {}
MAX_FAILS = 5
FAIL_WINDOW = 60.0


def _throttled(ip: str) -> bool:
    with _lock:
        attempts = [t for t in _fails.get(ip, []) if time.time() - t < FAIL_WINDOW]
        _fails[ip] = attempts
        return len(attempts) >= MAX_FAILS


def _record_fail(ip: str) -> None:
    with _lock:
        _fails.setdefault(ip, []).append(time.time())


def _sign(expiry: int) -> str:
    mac = hmac.new(SECRET, str(expiry).encode(), hashlib.sha256).hexdigest()
    return f"{expiry}.{mac}"


def _valid(cookie_value: str) -> bool:
    try:
        expiry_s, mac = cookie_value.split(".", 1)
        expiry = int(expiry_s)
    except ValueError:
        return False
    if time.time() > expiry:
        return False
    expected = hmac.new(SECRET, expiry_s.encode(), hashlib.sha256).hexdigest()
    return hmac.compare_digest(mac, expected)


def _safe_next(raw: str | None) -> str:
    """Only allow same-site relative redirects, never //evil.com."""
    if not raw or not raw.startswith("/") or raw.startswith("//"):
        return "/"
    return raw


LOGIN_PAGE = """<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<title>Honeypot session viewer -- sign in</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  :root {{ color-scheme: dark; }}
  body {{
    background: #111217; color: #d4d6dd; font-family: system-ui, sans-serif;
    display: flex; align-items: center; justify-content: center;
    height: 100vh; margin: 0;
  }}
  form {{
    background: #1a1c23; padding: 2.5rem; border-radius: 10px;
    width: 20rem; box-shadow: 0 8px 30px rgba(0,0,0,.4);
  }}
  h1 {{ font-size: 1.1rem; margin: 0 0 1.5rem; color: #f2f2f3; }}
  label {{ display: block; font-size: .85rem; margin: 1rem 0 .3rem; color: #9a9ca5; }}
  input {{
    width: 100%; box-sizing: border-box; padding: .6rem .7rem;
    background: #111217; border: 1px solid #33353f; border-radius: 6px;
    color: #f2f2f3; font-size: 1rem;
  }}
  input:focus {{ outline: none; border-color: #ff6b35; }}
  button {{
    width: 100%; margin-top: 1.5rem; padding: .7rem; border: none;
    border-radius: 6px; background: #ff6b35; color: #111217;
    font-weight: 600; font-size: 1rem; cursor: pointer;
  }}
  button:hover {{ background: #ff8556; }}
  .error {{
    background: #3a1a1a; border: 1px solid #a33; color: #ff9b9b;
    padding: .6rem .8rem; border-radius: 6px; font-size: .85rem;
    margin-bottom: 1rem;
  }}
</style>
</head><body>
<form method="post" action="/login">
  <h1>&#128274; Honeypot session viewer</h1>
  {error_html}
  <label for="u">Username</label>
  <input id="u" name="username" autocomplete="username" autofocus required>
  <label for="p">Password</label>
  <input id="p" name="password" type="password" autocomplete="current-password" required>
  <input type="hidden" name="next" value="{next_}">
  <button type="submit">Sign in</button>
</form>
</body></html>
"""


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "viewer-auth/1.0"

    def log_message(self, fmt, *args):
        # Keep container logs readable -- default logs every request
        # verbosely to stderr, which is enough here.
        print(f"{self.client_address[0]} {fmt % args}", flush=True)

    def _client_ip(self) -> str:
        return self.headers.get("X-Real-IP", self.client_address[0])

    def _cookie(self) -> str | None:
        raw = self.headers.get("Cookie", "")
        for part in raw.split(";"):
            part = part.strip()
            if part.startswith(f"{COOKIE_NAME}="):
                return part[len(COOKIE_NAME) + 1:]
        return None

    def do_GET(self):
        parsed = urllib.parse.urlsplit(self.path)
        if parsed.path == "/auth-check":
            cookie = self._cookie()
            self.send_response(200 if cookie and _valid(cookie) else 401)
            self.end_headers()
            return

        if parsed.path == "/login":
            qs = urllib.parse.parse_qs(parsed.query)
            error_html = (
                '<div class="error">Wrong username or password.</div>'
                if qs.get("error") else ""
            )
            next_ = html.escape(_safe_next((qs.get("next") or [None])[0]))
            body = LOGIN_PAGE.format(error_html=error_html, next_=next_).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
            return

        if parsed.path == "/logout":
            self.send_response(302)
            self.send_header("Location", "/login")
            self.send_header(
                "Set-Cookie",
                f"{COOKIE_NAME}=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax",
            )
            self.end_headers()
            return

        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        if urllib.parse.urlsplit(self.path).path != "/login":
            self.send_response(404)
            self.end_headers()
            return

        ip = self._client_ip()
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length).decode("utf-8", errors="replace")
        form = urllib.parse.parse_qs(raw)
        username = (form.get("username") or [""])[0]
        password = (form.get("password") or [""])[0]
        next_ = _safe_next((form.get("next") or [None])[0])

        if _throttled(ip):
            self._redirect_to_login(next_, error=True)
            return

        user_ok = hmac.compare_digest(username, USER)
        pass_ok = hmac.compare_digest(password, PASSWORD)
        if user_ok and pass_ok:
            expiry = int(time.time()) + TTL_SECONDS
            self.send_response(302)
            self.send_header("Location", next_)
            self.send_header(
                "Set-Cookie",
                f"{COOKIE_NAME}={_sign(expiry)}; Path=/; Max-Age={TTL_SECONDS}; "
                "HttpOnly; SameSite=Lax",
            )
            self.end_headers()
            return

        _record_fail(ip)
        self._redirect_to_login(next_, error=True)

    def _redirect_to_login(self, next_: str, error: bool):
        qs = urllib.parse.urlencode({"next": next_, **({"error": "1"} if error else {})})
        self.send_response(302)
        self.send_header("Location", f"/login?{qs}")
        self.end_headers()


class ThreadingServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


if __name__ == "__main__":
    print(f"viewer-auth listening on :{PORT}", flush=True)
    ThreadingServer(("0.0.0.0", PORT), Handler).serve_forever()
