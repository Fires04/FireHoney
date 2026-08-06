#!/usr/bin/env python3
"""
Bezi jako samostatny kontejner "session-generator" (viz docker-compose.yml).

Prochazi cowrie.json (read-only pripojeny svazek cowrie-var-log), najde
uzavrene session (cowrie.log.closed = ma ttylog), dohleda metadata
(src_ip, cas, spustene prikazy), zkonvertuje ttylog do asciinema .cast
(pokud jeste neni) a vygeneruje webui/index.html se seznamem.

Smycka bezi porad dokola, interval nastavis pres env GENERATE_INTERVAL
(vteriny, default 120) v .env souboru projektu.
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
    # cowrie.json obsahuje cesty relativni k cowrie cwd, napr.
    # "var/lib/cowrie/tty/<hash>". Nas mount odpovida jen "var/lib/",
    # zbytek za tim je stejny.
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
                print(f"WARN: konverze selhala pro {tty_path}: {e}", flush=True)
                continue

        if not cast_path.exists():
            continue

        cmds_preview = html.escape(" | ".join(s["commands"][:5])) or "(bez prikazu)"
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
      <td><a href="player.html?cast=casts/{cast_name}" class="play">&#9654; prehrat</a></td>
    </tr>""")

    generated_at = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")

    html_out = f"""<!doctype html>
<html lang="cs">
<head>
<meta charset="utf-8">
<title>Honeypot -- zaznamenane relace</title>
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
<h1>Honeypot -- zaznamenane relace</h1>
<div class="meta">Vygenerovano: {generated_at} - Celkem relaci: {len(rows)}</div>
<table>
<tr><th>Cas</th><th>Zdrojova IP</th><th>Protokol</th><th>Login</th><th>Prikazy (nahled)</th><th></th></tr>
{"".join(rows) if rows else '<tr><td colspan="6">Zatim zadne zaznamenane relace.</td></tr>'}
</table>
</body>
</html>
"""
    INDEX.write_text(html_out, encoding="utf-8")
    return len(rows)


if __name__ == "__main__":
    # `--once` -- spusti jeden pruchod a skonci (napr. pro rucni
    # `docker exec session-generator python3 generate-sessions.py --once`
    # bez cekani na dalsi tik smycky). Bez prepinace bezi porad dokola,
    # to je normalni chovani kontejneru z docker-compose.yml.
    if "--once" in sys.argv:
        n = run_once()
        print(f"OK: {n} relaci, index.html vygenerovan", flush=True)
        sys.exit(0)

    print(f"session-generator: interval={INTERVAL}s", flush=True)
    while True:
        try:
            n = run_once()
            print(f"OK: {n} relaci, index.html vygenerovan", flush=True)
        except Exception as e:
            print(f"CHYBA v behu generatoru: {e}", flush=True)
        time.sleep(INTERVAL)
