#!/usr/bin/env python3
"""
Runs as its own container "session-generator" (see docker-compose.yml).

Scans cowrie.json (read-only mounted cowrie-var-log volume), finds
closed sessions (cowrie.log.closed = has a ttylog), looks up metadata
(src_ip, timestamp, commands run with their offsets), converts the
ttylog to an asciinema .cast (if not already done), writes a small
sidecar <hash>.commands.json with a timestamped command list, and
regenerates webui/index.html with the session list.

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

# Automated attackers/bots often paste a whole chain of commands with
# ~0s between them -- at real speed the terminal replay flashes by
# too fast to read. Floor every inter-frame gap in the .cast to at
# least this many seconds so a human eye can follow along. Doesn't
# meaningfully affect sessions that were already paced like a human
# typing. Configurable via SESSION_MIN_FRAME_DELAY in .env.
MIN_FRAME_DELAY = float(os.environ.get("SESSION_MIN_FRAME_DELAY", "0.05"))


def ttylog_to_container_path(ttylog_field: str) -> Path:
    # cowrie.json stores paths relative to cowrie's cwd, e.g.
    # "var/lib/cowrie/tty/<hash>". Our mount corresponds to just
    # "var/lib/", the rest of the path stays the same.
    rel = ttylog_field.split("var/lib/", 1)[-1]
    return VAR_LIB_DIR / rel


# NUL reliably crashes asciinema-player's terminal renderer (confirmed
# against a real captured session -- it showed the built-in error
# overlay instead of playing). It's genuine attacker-sent data, not a
# bug in our capture: some bot probes send raw control bytes, and
# Cowrie/the ttylog-to-cast conversion preserve them faithfully. We
# strip it rather than replace it -- a real terminal silently no-ops
# on a stray NUL too, so this doesn't change what the recording
# "shows", just what the player can survive rendering.
_UNSAFE_CHARS = "\x00"


def normalize_cast(cast_path: Path, min_delay: float) -> None:
    """Sanitize control characters the player can't handle (always),
    and floor every inter-frame delay in an asciicast v1 file to
    min_delay so bot-fast bursts stay visually followable (only if
    min_delay > 0). Rewrites the file in place; recomputes the
    top-level "duration" field only when delays were normalized.
    """
    try:
        data = json.loads(cast_path.read_text(encoding="utf-8", errors="replace"))
    except Exception:
        return

    stdout = data.get("stdout")
    if not isinstance(stdout, list):
        return

    changed = False
    total = 0.0
    for entry in stdout:
        if not isinstance(entry, list) or len(entry) != 2:
            continue
        delay, text = entry
        if isinstance(text, str):
            cleaned = "".join(c for c in text if c not in _UNSAFE_CHARS)
            if cleaned != text:
                entry[1] = cleaned
                changed = True
        if min_delay > 0 and isinstance(delay, (int, float)) and delay < min_delay:
            entry[0] = min_delay
            changed = True
        total += entry[0] if isinstance(entry[0], (int, float)) else 0

    if not changed:
        return

    if min_delay > 0:
        data["duration"] = total
    cast_path.write_text(json.dumps(data), encoding="utf-8")


def parse_timestamp(ts: str) -> datetime | None:
    if not ts:
        return None
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return None


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
                    s["commands"].append({
                        "time": ev.get("timestamp"),
                        "input": ev.get("input", ""),
                    })
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
        commands_path = CASTS_DIR / (tty_path.name + ".commands.json")

        if tty_path.exists() and not cast_path.exists():
            try:
                subprocess.run(
                    ["asciinema", "-o", str(cast_path), str(tty_path)],
                    check=True, capture_output=True, timeout=30,
                )
                normalize_cast(cast_path, MIN_FRAME_DELAY)
            except Exception as e:
                print(f"WARN: conversion failed for {tty_path}: {e}", flush=True)
                continue

        if not cast_path.exists():
            continue

        if s["commands"] and not commands_path.exists():
            session_start = parse_timestamp(s["start"])
            cmd_list = []
            for c in s["commands"]:
                cmd_ts = parse_timestamp(c["time"])
                offset = (cmd_ts - session_start).total_seconds() if (cmd_ts and session_start) else None
                cmd_list.append({"t": offset, "cmd": c["input"]})
            commands_path.write_text(json.dumps(cmd_list), encoding="utf-8")

        cmd_texts = [c["input"] for c in s["commands"]]
        cmds_preview = html.escape(" | ".join(cmd_texts[:5])) or "(no commands)"
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
  .topbar {{ display: flex; justify-content: space-between; align-items: baseline; }}
  .logout {{ color: #8b949e; font-size: 0.85em; text-decoration: none; }}
  .logout:hover {{ color: #c9d1d9; text-decoration: underline; }}
</style>
</head>
<body>
<div class="topbar"><h1>Honeypot -- captured sessions</h1><a class="logout" href="/logout">Sign out</a></div>
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
