#!/usr/bin/env python3
"""Tiny local web UI for auto-loop — dependency-free (Python stdlib only).

It does NOT run agents itself: it reads tasks.json / state.json / reports/ and shells
out to ./auto-loop.sh for validate / start / stop. The CLI is still the engine.

SECURITY: binds to 127.0.0.1 only. It can edit tasks and start the loop (which runs
agents with skipped permissions), so treat it like a local admin panel — do not port-
forward it or expose it to a network. See README "Safety".
"""
import json, os, re, subprocess, sys, signal
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

ROOT = os.path.dirname(os.path.abspath(__file__))
TASKS = os.path.join(ROOT, "tasks.json")
STATE = os.path.join(ROOT, "state.json")
LOCK = os.path.join(ROOT, ".auto-loop.lock")
REPORTS = os.path.join(ROOT, "reports")
LOGS = os.path.join(ROOT, "logs")
SH = os.path.join(ROOT, "auto-loop.sh")
NAME_RE = re.compile(r"^report-[0-9-]+\.md$")


def read_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return default


def loop_running():
    try:
        with open(LOCK) as f:
            pid = int(f.read().strip())
        os.kill(pid, 0)
        return pid
    except Exception:
        return 0


def sh(args, **kw):
    return subprocess.run([SH, *args], cwd=ROOT, capture_output=True, text=True,
                          timeout=kw.get("timeout", 60))


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):  # quiet
        pass

    def _send(self, code, body, ctype="application/json"):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        u = urlparse(self.path)
        if u.path in ("/", "/index.html"):
            try:
                with open(os.path.join(ROOT, "ui.html"), "rb") as f:
                    return self._send(200, f.read(), "text/html; charset=utf-8")
            except FileNotFoundError:
                return self._send(500, {"error": "ui.html missing"})
        if u.path == "/api/summary":
            tasks = read_json(TASKS, {"tasks": []}).get("tasks", [])
            state = read_json(STATE, {})
            reports = sorted([n for n in os.listdir(REPORTS) if NAME_RE.match(n)], reverse=True) \
                if os.path.isdir(REPORTS) else []
            return self._send(200, {"tasks": tasks, "state": state,
                                    "running": bool(loop_running()), "pid": loop_running(),
                                    "reports": reports})
        if u.path == "/api/report":
            name = parse_qs(u.query).get("name", [""])[0]
            if not NAME_RE.match(name):
                return self._send(400, {"error": "bad name"})
            try:
                with open(os.path.join(REPORTS, name)) as f:
                    return self._send(200, f.read(), "text/plain; charset=utf-8")
            except FileNotFoundError:
                return self._send(404, {"error": "not found"})
        return self._send(404, {"error": "not found"})

    def do_POST(self):
        u = urlparse(self.path)
        n = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(n) if n else b"{}"
        try:
            data = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            return self._send(400, {"error": "invalid JSON"})

        if u.path == "/api/tasks":
            tasks = data.get("tasks")
            if not isinstance(tasks, list) or not tasks:
                return self._send(400, {"error": "tasks must be a non-empty array"})
            # atomic write, then validate via the CLI (single source of truth)
            tmp = TASKS + ".tmp"
            with open(tmp, "w") as f:
                json.dump({"tasks": tasks}, f, indent=2, ensure_ascii=False)
            os.replace(tmp, TASKS)
            r = sh(["validate"])
            return self._send(200, {"ok": r.returncode == 0,
                                    "output": (r.stdout + r.stderr).strip()})

        if u.path == "/api/control":
            action = data.get("action")
            if action == "stop":
                r = sh(["stop"])
                return self._send(200, {"ok": True, "output": (r.stdout + r.stderr).strip(),
                                        "running": bool(loop_running())})
            if action == "start":
                if loop_running():
                    return self._send(409, {"error": "loop already running"})
                logf = open(os.path.join(LOGS, "nohup.log"), "a")
                subprocess.Popen(["/bin/bash", SH, "run"], cwd=ROOT,
                                 stdout=logf, stderr=logf, stdin=subprocess.DEVNULL,
                                 start_new_session=True)
                return self._send(200, {"ok": True, "output": "loop started"})
            return self._send(400, {"error": "action must be start|stop"})
        return self._send(404, {"error": "not found"})


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else int(os.environ.get("UI_PORT", "8787"))
    srv = ThreadingHTTPServer(("127.0.0.1", port), H)
    print(f"auto-loop UI: http://127.0.0.1:{port}  (Ctrl-C to stop)")
    signal.signal(signal.SIGINT, lambda *a: (srv.shutdown(), sys.exit(0)))
    srv.serve_forever()


if __name__ == "__main__":
    main()
