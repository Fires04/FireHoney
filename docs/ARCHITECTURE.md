# Architecture

## Component overview

```
                          Internet / attackers
                                  │
                                  │ tcp/2222 (SSH), tcp/2223 (Telnet)
                                  ▼
   ┌──────────────────────────────────────────────────────────────┐
   │                         Host (VM)                             │
   │                                                                │
   │   ┌─────────────┐  honeypot-egress    ┌───────────────────┐   │
   │   │   Cowrie    │◄────172.30.0.0/24───┤  (the only network │   │
   │   │  (emulated) │                     │   with a route     │   │
   │   └──────┬──────┘                     │   out, filtered)   │   │
   │          │ internal (no route out)     └───────────────────┘  │
   │          ▼                                                    │
   │   ┌─────────────┐     ┌──────────┐     ┌──────────────────┐   │
   │   │  Promtail   │────▶│   Loki   │◄────│      Grafana      │   │
   │   └─────────────┘     └──────────┘     └─────────┬────────┘   │
   │                                                    │ mgmt-publish│
   │   ┌────────────────────┐   ┌────────────────┐     │ (port-publish,│
   │   │ session-generator   │──▶│ session-viewer  │◄────┘ no route out) │
   │   │ (.cast + index.html)│   │ (nginx+basicauth)│                    │
   │   └────────────────────┘   └────────┬─────────┘                    │
   │                                       │                             │
   └───────────────────────────────────────┼─────────────────────────────┘
                                            │ tcp/3000, tcp/8080
                                            ▼
                                   Your admin browser
                              (only from ADMIN_CIDR, see SECURITY.md)
```

## Three Docker networks, and why

| Network | Who's on it | Purpose |
|---|---|---|
| `honeypot-egress` | Cowrie (static IP) | The only network any container can use to initiate outbound connections -- and even then only on 80/443, thanks to the firewall |
| `internal` (Docker `internal: true`) | Cowrie, Promtail, Loki, Grafana, session-generator | Docker itself guarantees this network has no route out -- no extra firewall rule needed |
| `mgmt-publish` | Grafana, session-viewer, session-generator | Exists **only** because Docker can't publish ports for a container attached solely to an `internal: true` network. `scripts/firewall.sh` grants it no exception -- it effectively has no route out, verified by test |

## Why one VM, not two

The traditional recommendation is to keep the honeypot and the
logging/monitoring layer on two separate VMs (so that if an attacker
ever escapes the emulation, they can't delete the evidence of their
own intrusion). This project takes a single-VM compromise:

- Cowrie is an **emulation** (`backend = shell`), the attacker never
  gets a real shell on the host -- the risk of escape is low.
- Network isolation (VLAN recommended, see DEPLOYMENT.md) already
  prevents lateral movement into the rest of your network, which was
  the main reason for splitting things up.
- Residual risk: in the very unlikely event of an emulation escape,
  you could lose the data from that one incident. For a home lab
  that's an acceptable trade-off for simpler operations.

If you want a stricter model, feel free to move `loki`+`grafana` to a
separate host and point `promtail-config.yml` (`clients.url`) at its
IP -- the architecture supports it, it's just not the default.

## Why Docker Compose, not a custom build

Cowrie, Loki, Grafana, and nginx are actively developed and
maintained upstream projects -- rebuilding them with our own
Dockerfiles would mean losing automatic security updates for no
benefit. The custom `Dockerfile`s only cover what we actually built
ourselves:

- `docker/session-generator/` -- a small Python image that
  periodically converts captured sessions into a web-playable format
- `docker/fakefs-builder/` -- a one-shot source image for
  `scripts/build-fakefs.sh`, never runs as a service

## Data flow

1. An attacker connects to Cowrie (2222/2223)
2. Cowrie writes a JSON log (`cowrie.json`) + a TTY session recording (ttylog) to Docker volumes
3. Promtail tails `cowrie.json` and pushes it to Loki
4. Grafana queries Loki over LogQL -- the dashboard is ready right after startup (provisioning)
5. `session-generator` periodically scans `cowrie.json`, finds closed sessions, converts the ttylog to an asciinema `.cast`, and regenerates `webui/index.html`
6. `session-viewer` (nginx) serves `webui/` behind basic-auth
