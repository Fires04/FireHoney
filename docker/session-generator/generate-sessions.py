#!/usr/bin/env python3
"""
Runs as its own container "session-generator" (see docker-compose.yml).

Scans cowrie.json (read-only mounted cowrie-var-log volume), finds
closed sessions (cowrie.log.closed = has a ttylog), looks up metadata
(src_ip, timestamp, commands run), converts the ttylog to an asciinema
.cast (if not already done), and regenerates webui/index.html with the
list.

Runs in a loop forever; set the interval via the GENERATE_INTERVAL env
var (seconds, default 120) in the project's .env file. Pass --once to
run a single pass and exit (used by `make sessions`).
"""
import html
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

VAR_LOG_DIR = Path("/data/var/log")
VAR_LIB_DIR = Path("/data/var/lib")
WEBUI_DIR = Path("/data/webui")

LOGFILE = VAR_LOG_DIR / "cowrie" / "cowrie.json"
CASTS_DIR = WEBUI_DIR / "casts"
INDEX = WEBUI_DIR / "index.html"
INTERVAL = int(os.environ.get("GENERATE_INTERVAL", "120"))


def ttylog_to_container_path(ttylog_field: str) -> Path:
    # cowrie.json stores paths relative to cowrie's cwd, e.g.
    # "var/lib/cowrie/tty/<hash>". Our mount corresponds to just
    # "var/lib/", the rest of the path stays the same.
    rel = ttylog_field.split("var/lib/", 1)[-1]
    return VAR_LIB_DIR / rel


def run_once() -> int:
    CASTS_DIR.mkdir(parents=True, exist_ok=True)

    sessions: dict[str, dict] = {}

    if LOGFILE.exists():
        with open(LOGFILE, "r", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    ev = json.loads(line)
                except json.JSONDecodeError:
                    continue
                sid = ev.get("session")
                if not sid:
                    continue
                s = sessions.setdefault(sid, {
                    "session": sid, "src_ip": None, "start": None,
                    "commands": [], "login": None, "ttylog": None,
                    "protocol": ev.get("protocol", "?"),
                })
                eid = ev.get("eventid", "")
                if eid == "cowrie.session.connect":
                    s["src_ip"] = ev.get("src_ip")
                    s["start"] = ev.get("timestamp")
                elif eid == "cowrie.command.input":
                    s["commands"].append(ev.get("input", ""))
                elif eid in ("cowrie.login.success", "cowrie.login.failed"):
                    s["login"] = f'{ev.get("username")}/{ev.get("password")} ({"OK" if eid.endswith("success") else "FAIL"})'
                elif eid == "cowrie.log.closed":
                    s["ttylog"] = ev.get("ttylog")

    with_recording = [s for s in sessions.values() if s["ttylog"]]
    with_recording.sort(key=lambda s: s["start"] or "", reverse=True)

    rows = []
    for s in with_recording:
        tty_path = ttylog_to_container_path(s["ttylog"])
        cast_name = tty_path.name + ".cast"
        cast_path = CASTS_DIR / cast_name

        if tty_path.exists() and not cast_path.exists():
            try:
                subprocess.run(
                    ["asciinema", "-o", str(cast_path), str(tty_path)],
                    check=True, capture_output=True, timeout=30,
                )
            except Exception as e:
                print(f"WARN: conversion failed for {tty_path}: {e}", flush=True)
                continue

        if not cast_path.exists():
            continue

        cmds_preview = html.escape(" | ".join(s["commands"][:5])) or "(no commands)"
        login = html.escape(s["login"] or "?")
        src_ip = html.escape(s["src_ip"] or "?")
        start = html.escape(s["start"] or "?")

        rows.append(f"""
    <tr>
      <td>{start}</td>
      <td>{src_ip}</td>
      <td>{s["protocol"]}</td>
      <td>{login}</td>
      <td class="cmds">{cmds_preview}</td>
      <td><a href="player.html?cast=casts/{cast_name}" class="play">&#9654; play</a></td>
    </tr>""")

    generated_at = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")

    html_out = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Honeypot -- captured sessions</title>
<style>
  body {{ font-family: system-ui, sans-serif; background: #0d1117; color: #c9d1d9; margin: 2rem; }}
  h1 {{ color: #58a6ff; }}
  table {{ border-collapse: collapse; width: 100%; }}
  th, td {{ text-align: left; padding: 0.5rem 0.8rem; border-bottom: 1px solid #30363d; }}
  th {{ color: #8b949e; font-weight: 600; }}
  tr:hover {{ background: #161b22; }}
  .cmds {{ font-family: monospace; font-size: 0.85em; color: #f0883e; max-width: 400px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }}
  .play {{ color: #3fb950; text-decoration: none; font-weight: 600; }}
  .play:hover {{ text-decoration: underline; }}
  .meta {{ color: #8b949e; font-size: 0.85em; margin-bottom: 1.5rem; }}
</style>
</head>
<body>
<h1>Honeypot -- captured sessions</h1>
<div class="meta">Generated: {generated_at} - Total sessions: {len(rows)}</div>
<table>
<tr><th>Time</th><th>Source IP</th><th>Protocol</th><th>Login</th><th>Commands (preview)</th><th></th></tr>
{"".join(rows) if rows else '<tr><td colspan="6">No captured sessions yet.</td></tr>'}
</table>
</body>
</html>
"""
    INDEX.write_text(html_out, encoding="utf-8")
    return len(rows)


if __name__ == "__main__":
    # `--once` -- run a single pass and exit (e.g. for a manual
    # `docker exec session-generator python3 generate-sessions.py --once`
    # without waiting for the next loop tick). Without the flag it
    # loops forever, which is the normal behavior for the container
    # started from docker-compose.yml.
    if "--once" in sys.argv:
        n = run_once()
        print(f"OK: {n} session(s), index.html generated", flush=True)
        sys.exit(0)

    print(f"session-generator: interval={INTERVAL}s", flush=True)
    while True:
        try:
            n = run_once()
            print(f"OK: {n} session(s), index.html generated", flush=True)
        except Exception as e:
            print(f"ERROR in generator run: {e}", flush=True)
        time.sleep(INTERVAL)
