# Cowrie Honeypot Stack

A complete, reusable Docker Compose package for deploying an SSH/Telnet
honeypot ([Cowrie](https://github.com/cowrie/cowrie)) with live monitoring
and web-based session playback -- built as a modern replacement for the
now-unmaintained [HoneyDrive](https://sourceforge.net/projects/honeydrive/).

![status](https://img.shields.io/badge/status-home--lab-orange)

## What you get

- **Cowrie** -- an emulated SSH/Telnet honeypot (the attacker never gets
  a real shell, just a convincing imitation of one)
- **Three Grafana dashboards** -- ready on first boot (auto-provisioning):
  *Overview* (login attempts, top credentials/commands, attacker map),
  *Live Ops* (active sessions, connection rate, live feed), and
  *Human Hunt* (surfaces the rare real-person session buried in bot
  noise, by session duration and command diversity)
- **Web-based session playback** -- self-hosted (asciinema-player), no
  CDN, no SSH or terminal needed
- **Realistic fake filesystem** -- generated from an actual Debian
  server with packages installed (not the generic default every Cowrie
  install on earth shares)
- **Strict egress firewall** -- the honeypot container can't reach
  anywhere outbound except one precisely defined exception (malware
  sample downloads)
- **Noise reduction** -- inbound sessions capped at 10/day per source
  IP (matched to AuthRandom's max attempts, so brute-force sequences
  can still complete), plus an optional known-scanner IP blocklist
  (`blocklist.de`, `danger.rulez.sk`), so one scanning campaign
  doesn't drown out everything else in the capture
- Everything configurable from a single `.env` file

## Quick start

```bash
git clone https://github.com/Fires04/FireHoney.git cowrie-honeypot-stack
cd cowrie-honeypot-stack
cp .env.example .env
$EDITOR .env              # set passwords, WAN_IFACE, ADMIN_CIDR

make setup                # viewer login secret, asciinema-player, docker pull
make fakefs                # (recommended) realistic fake filesystem
make up                    # bring up the whole stack
sudo apt install ipset && sudo make update-blocklist  # (recommended) known-scanner blocklist
sudo make firewall         # egress lockdown

# Grafana:         http://SERVER_IP:3000
# Session viewer:  http://SERVER_IP:8080
```

**Before exposing this to the internet**, go through the
[docs/SECURITY.md](docs/SECURITY.md) checklist -- network isolation
(VLAN), port forwarding, and what to do before you let real attackers
at it.

## Documentation

| Document | What it covers |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | How it's put together, network diagram, why one VM |
| [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) | Step by step from a fresh VM to a running honeypot |
| [docs/CONFIGURATION.md](docs/CONFIGURATION.md) | What every `.env` variable does, how to tweak `cowrie.cfg`/`userdb.txt` |
| [docs/SECURITY.md](docs/SECURITY.md) | Firewall model, pre-launch checklist, GDPR |
| [docs/ANTI-DETECTION.md](docs/ANTI-DETECTION.md) | Why and how the honeypot looks less obvious |

## Requirements

- Linux server (tested on Debian 13), Docker Engine + Compose plugin
- Recommended: a dedicated VM (Proxmox or any other hypervisor) on an
  isolated network/VLAN -- see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- ~2 GB RAM, 20 GB disk

## Project structure

```
.
├── docker-compose.yml       # orchestration, reads .env
├── .env.example              # copy to .env and edit
├── Makefile                  # make setup/up/down/firewall/fakefs/...
├── config/
│   ├── cowrie/                 cowrie.cfg, userdb.txt, fs.pickle (generated)
│   ├── promtail/                promtail-config.yml
│   ├── loki/                    loki-config.yml
│   ├── nginx/                   session-viewer.conf
│   └── grafana/provisioning/    datasource + dashboard, loads itself
├── docker/
│   ├── session-generator/      custom image: turns sessions into .cast + index.html
│   ├── viewer-auth/             custom image: login-form gate for the session viewer
│   └── fakefs-builder/          custom image: source for the realistic filesystem
├── scripts/
│   ├── setup.sh                 one-time setup
│   ├── build-fakefs.sh           generates fs.pickle
│   └── firewall.sh               egress lockdown
├── webui/                     player.html + generated content
└── docs/                       see table above
```

## Why this architecture

Cowrie is an emulation (the attacker never gets a real shell), which
makes it substantially safer than a honeypot running a real OS. Even
so, the deployment is designed with defense in depth: an isolated
network (recommended), a strict egress firewall at the Docker level,
no admin interfaces exposed to the internet. Details in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and
[docs/SECURITY.md](docs/SECURITY.md).

## License

MIT (see LICENSE). Cowrie itself has its own license (BSD-3-Clause).
