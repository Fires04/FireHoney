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
| `VIEWER_USER` | viewer | Login-form username for the session viewer |
| `VIEWER_PASSWORD` | — | **Change this!** Login-form password |
| `VIEWER_SESSION_SECRET` | — | Signs the viewer's login session cookie. `make setup` generates a random one if left blank -- see [SECURITY.md](SECURITY.md#session-viewer-login) |
| `VIEWER_SESSION_TTL_HOURS` | 12 | How long a viewer login stays signed in |
| `WAN_IFACE` | eth0 | The host's network interface -- find it with `ip route \| grep default` |
| `ADMIN_CIDR` | — | Where you're allowed to reach SSH/Grafana/viewer from. Never `0.0.0.0/0` |
| `DNS_RESOLVERS` | 1.1.1.1,9.9.9.9 | The only DNS servers Cowrie may reach (to resolve URLs during sample downloads) |
| `COWRIE_EGRESS_SUBNET` | 172.30.0.0/24 | Cowrie's internal Docker subnet -- only change on conflict |
| `COWRIE_IP` | 172.30.0.10 | Cowrie's static IP on that subnet (the firewall targets it precisely) |
| `MGMT_PUBLISH_SUBNET` | 172.31.0.0/24 | Internal subnet for Grafana/viewer/generator |
| `LOKI_RETENTION_HOURS` | 2160 (90 days) | How long Loki keeps logs |
| `SESSION_GENERATOR_INTERVAL` | 120 | How often (s) to look for newly captured sessions |
| `SESSION_MIN_FRAME_DELAY` | 0.05 | Minimum seconds between frames in the web player replay -- floors bot-fast bursts so they're watchable. `0` disables |

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
- `auth_class` / `auth_class_parameters` -- login timing model. Default
  `AuthRandom` (3-10 random attempts before success, see
  [ANTI-DETECTION.md](ANTI-DETECTION.md)) replaces the static
  `userdb.txt` model entirely -- set `auth_class = UserDB` to go back
  to it.

**The file must stay pure ASCII** (comments included) -- Cowrie reads
it strictly as ASCII, otherwise loading breaks and *every* login
starts failing.

After editing: `docker compose restart cowrie` (or `make reset-cowrie`).

## `config/cowrie/userdb.txt` -- who can log in (inactive by default)

Currently unused: `cowrie.cfg` defaults to `auth_class = AuthRandom`
(see above), which never consults this file. Kept here so you can
switch back to it (`auth_class = UserDB`) any time.


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

## `config/promtail/promtail-config.yml` -- optional GeoIP + attack map

The dashboard's "Attack origin map" panel needs GeoIP enabled to have
any data. Two database options, both free, in the same MaxMind DB
(`.mmdb`) format Promtail's `geoip` stage expects:

**Option A -- DB-IP City Lite (no account needed, recommended if you
don't want to register anywhere):**
```bash
curl -fsSL -o config/promtail/GeoLite2-City.mmdb.gz \
  "https://download.db-ip.com/free/dbip-city-lite-$(date +%Y-%m).mmdb.gz"
gunzip config/promtail/GeoLite2-City.mmdb.gz
```
Verified working: same field names as MaxMind
(`geoip_city_name`, `geoip_country_name`, `geoip_location_latitude`,
`geoip_location_longitude`, etc.) -- drop-in compatible with the
pipeline stages below, no config changes needed. Free tier is
CC BY 4.0 licensed -- if you publish anything derived from this data,
credit [DB-IP.com](https://db-ip.com/). Updated monthly; re-run the
command above periodically (the URL includes the year-month, e.g.
`dbip-city-lite-2026-08.mmdb.gz`) to refresh it.

**Option B -- MaxMind GeoLite2 (free, requires creating an account):**
Download `GeoLite2-City.mmdb` at [maxmind.com](https://www.maxmind.com/),
save it to the same path: `config/promtail/GeoLite2-City.mmdb`.

Either way, once the file is in place:

1. Uncomment **both** the `geoip` and `structured_metadata` stages in
   `promtail-config.yml` (they must be used together -- lat/lon are
   high-cardinality per-event values, so they go in as Loki
   structured metadata, not labels; see the comment in the file)
2. `docker compose restart promtail`

Works entirely locally against the downloaded DB file, no outbound
queries at lookup time.

**Status: verified end-to-end** against a live stack (DB-IP City Lite
database, real Loki + Grafana instance, a synthetic log line with a
real public IP injected into a running Cowrie's log):
- `geoip` stage extraction: confirmed correct (`geoip_city_name`,
  `geoip_country_name`, `geoip_location_latitude`,
  `geoip_location_longitude` all populated with correct values)
- `structured_metadata` ingestion into Loki: confirmed (non-zero
  `structuredMetadataBytesProcessed` in query stats, fields present
  on the returned stream)
- The dashboard's exact Geomap aggregation query
  (`sum by (src_ip, geoip_country_name, geoip_city_name,
  geoip_location_latitude, geoip_location_longitude) (...)`) returns
  correctly grouped rows with real coordinates

Not independently confirmed: that Grafana's Geomap panel visually
places the marker correctly (didn't have a browser screenshot in the
loop) -- but the panel gets fully populated, correctly-shaped data,
so this should render with `cowrie-overview.json`'s
`layers[0].location.latitudeField`/`longitudeField` config as-is on
any reasonably current Grafana version.

Note: private/RFC1918 source IPs (e.g. testing from your own LAN) have
no GeoIP entry, by design -- those rows just won't carry the
`geoip_*` fields. That's expected, not a bug; you'll see real markers
once actual internet traffic hits Cowrie.

## `webui/player.html` -- per-session command list

Next to the terminal replay, the player shows every command from that
session with its offset (`+12.3s`) -- click one to jump the player
there. Comes from `<hash>.commands.json`, written by
`generate-sessions.py` alongside the `.cast` file. No configuration
needed.

## `config/grafana/provisioning/dashboards/` -- three dashboards

All three load automatically when Grafana starts (file-based
provisioning, see `dashboards.yaml` in that folder -- any `.json`
dropped there is picked up, no extra config needed). Edit the JSON
directly, or edit it in the Grafana UI and export it back (Dashboard
settings → JSON Model) -- just watch the `"datasource": {"uid":
"loki"}` reference, it must stay `loki` (matches
`config/grafana/provisioning/datasources/loki.yaml`).

- **`cowrie-overview.json`** -- the default home dashboard: login
  attempts over time, top usernames/passwords, top commands,
  attacking IPs, the GeoIP map, live log streams. General-purpose
  stats.
- **`cowrie-live-ops.json`** -- a "NOC screen" view: approximate
  active-session count, connection/command rate, a live feed of new
  sessions. Refreshes every 5s. For watching the honeypot right now,
  not for historical analysis.
- **`cowrie-human-hunt.json`** -- built specifically to find real
  people, not scripted bots, in the capture. The vast majority of
  traffic on any public honeypot is Mirai/Gafgyt-style scanners that
  connect, run the same handful of fingerprinting commands in under a
  second, and disconnect -- this dashboard ranks sessions by duration
  and by *distinct* command count (bots repeat the same commands; a
  session with many different commands suggests someone actually
  exploring). These are heuristics, not proof -- the dashboard's own
  top panel explains the reasoning and tells you to confirm by
  watching the replay in the session viewer before concluding
  anything. Its "Session profiler" panel (duration + distinct commands
  joined into one table) relies on Grafana's outer-join transform and
  is marked experimental in its own description -- the two simple
  single-metric tables next to it are the reliable fallback if the
  join renders oddly on your Grafana version.

## `config/nginx/session-viewer.conf`

Static serving of `webui/`, gated by a login form (`viewer-auth`
checks every request via nginx's `auth_request` directive -- see
[SECURITY.md](SECURITY.md#session-viewer-login) for how it works).
There's a single shared login (`VIEWER_USER`/`VIEWER_PASSWORD`), not
per-user accounts -- this is meant for one admin, not a team.
