# Configuration

## `.env` -- infrastructure settings

| Variable | Default | What it does |
|---|---|---|
| `COWRIE_SSH_PORT` | 2222 | Host port for Cowrie SSH |
| `COWRIE_TELNET_PORT` | 2223 | Host port for Cowrie Telnet |
| `GRAFANA_PORT` | 3000 | Host port for the Grafana web UI |
| `SESSION_VIEWER_PORT` | 8080 | Host port for the session overview |
| `GRAFANA_ADMIN_USER` | admin | Grafana admin login |
| `GRAFANA_ADMIN_PASSWORD` | — | **Change this!** Grafana admin password |
| `VIEWER_USER` | viewer | Basic-auth login for the session viewer |
| `VIEWER_PASSWORD` | — | **Change this!** Basic-auth password, generated into `config/nginx/htpasswd` by `make setup` |
| `WAN_IFACE` | eth0 | The host's network interface -- find it with `ip route \| grep default` |
| `ADMIN_CIDR` | — | Where you're allowed to reach SSH/Grafana/viewer from. Never `0.0.0.0/0` |
| `DNS_RESOLVERS` | 1.1.1.1,9.9.9.9 | The only DNS servers Cowrie may reach (to resolve URLs during sample downloads) |
| `COWRIE_EGRESS_SUBNET` | 172.30.0.0/24 | Cowrie's internal Docker subnet -- only change on conflict |
| `COWRIE_IP` | 172.30.0.10 | Cowrie's static IP on that subnet (the firewall targets it precisely) |
| `MGMT_PUBLISH_SUBNET` | 172.31.0.0/24 | Internal subnet for Grafana/viewer/generator |
| `LOKI_RETENTION_HOURS` | 2160 (90 days) | How long Loki keeps logs |
| `SESSION_GENERATOR_INTERVAL` | 120 | How often (s) to look for newly captured sessions |

After any `.env` change: `docker compose up -d` (recreates only the
containers that need it), and if you changed network/port variables,
run `sudo make firewall` again.

## `config/cowrie/cowrie.cfg` -- honeypot behavior

A small file, just our overrides on top of Cowrie's built-in defaults
(Cowrie loads its own `cowrie.cfg.dist` internally from the package).
Key settings:

- `hostname` -- what the honeypot calls itself (`uname -a`, the
  prompt). If you change it, also update
  `docker/fakefs-builder/Dockerfile` (it hardcodes `webprod03` in
  `/etc/hostname`).
- `backend = shell` -- **never change this** to `proxy`/`llm`. The
  emulation is the security boundary of the whole project.
- `filesystem = etc/fs.pickle` (under `[shell]`) -- see `make fakefs`
  and [ANTI-DETECTION.md](ANTI-DETECTION.md)
- `download_limit_size` -- size limit for downloaded malware samples

**The file must stay pure ASCII** (comments included) -- Cowrie reads
it strictly as ASCII, otherwise loading breaks and *every* login
starts failing.

After editing: `docker compose restart cowrie` (or `make reset-cowrie`).

## `config/cowrie/userdb.txt` -- who can log in

Processed line by line, **first match wins**:
- `username:x:*` -- allow any password
- `username:x:!password` -- deny that specific password
- `username:x:!/regex/` -- deny anything matching the regex
  (`!/.*/ ` = deny everything for that user)

The default file has three layers (see the comments inside):
1. System accounts (`www-data`, `mysql`...) -- denied outright
2. A handful of "is this a honeypot?" canary passwords for root -- denied
3. Everything else -- allowed (the main source of data)

Want to see more "failed" logins in Grafana? Add more explicit
`!password` lines -- but note you're trading away captured data
volume from ordinary bots. See the discussion in
[ANTI-DETECTION.md](ANTI-DETECTION.md).

**This file must be pure ASCII too.**

## `config/promtail/promtail-config.yml` -- optional GeoIP

Download `GeoLite2-City.mmdb` for free (registration required) from
[maxmind.com](https://www.maxmind.com/), save it to
`config/promtail/GeoLite2-City.mmdb`, uncomment the `geoip` stage in
the file, `docker compose restart promtail`. Works entirely locally,
no extra outbound queries.

## `config/grafana/provisioning/dashboards/cowrie-overview.json`

The dashboard loads automatically when Grafana starts (file-based
provisioning). Edit the JSON directly, or edit it in the Grafana UI
and export it back (Dashboard settings → JSON Model) -- just watch
the `"datasource": {"uid": "loki"}` reference, it must stay `loki`
(matches `config/grafana/provisioning/datasources/loki.yaml`).

## `config/nginx/session-viewer.conf`

Basic-auth + static serving of `webui/`. For more users, add lines to
`config/nginx/htpasswd` (`htpasswd -B config/nginx/htpasswd new_user`).
