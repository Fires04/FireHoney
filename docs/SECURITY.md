# Security

## Egress (outbound) model

Default policy: **no container-initiated outbound connection is
allowed**. The one exception: the Cowrie container may open new
connections on tcp/80,443 (rate-limited, logged) -- because on the
attacker's command (`wget`/`curl` in the fake shell) it needs to be
able to actually download and store a real malware sample for
analysis. Cowrie only downloads the file, **it never executes it**.

Implemented in `scripts/firewall.sh` in the `DOCKER-USER` chain
(Docker never overwrites this chain, it's specifically meant for
custom rules over container traffic). Everything else -- Loki,
Grafana, Promtail, session-viewer, session-generator -- has no route
to the internet at all (either a Docker `internal: true` network, or
an explicit firewall rule with no exception).

Tripwire: any attempt at an outbound connection outside the allowed
scope gets logged as `HONEYPOT-EGRESS-BLOCKED` / `MGMT-EGRESS-BLOCKED`
(`journalctl -k`). Watch for it -- an occurrence means suspected
emulation escape or a misconfiguration.

## Ingress (inbound) access

- Cowrie ports (2222/2223 → typically 22/23 from outside) -- public,
  that's the point. `scripts/firewall.sh` caps new connections to
  Cowrie at 10/day per source IP so a single scanning campaign doesn't
  flood you with hundreds of near-identical sessions -- rejected
  attempts are logged as `COWRIE-INBOUND-RATELIMIT-DROP`. This
  doesn't reduce how many distinct attackers get captured, only how
  many times the same one reconnects.
  **This number must stay >= `cowrie.cfg`'s `auth_class_parameters`
  maxtry (default 10)** -- AuthRandom counts attempts across separate
  connections (many bots reconnect per credential tried instead of
  reusing one connection), so if the firewall cuts an IP off sooner
  than its own random attempt threshold, that IP can never actually
  complete a login. Change one, change the other.
- Grafana (3000) and session-viewer (8080) -- **never expose these to
  the internet**. Network/router-level firewalling must restrict
  access to `ADMIN_CIDR` only. The apps themselves also have a login
  (Grafana) / basic-auth (viewer), but that's not a substitute for
  network-level restriction.
- The real SSH for VM administration -- also `ADMIN_CIDR` only, never
  from WAN.

## Known-scanner blocklist

`scripts/update-blocklist.sh` pulls free, no-signup feeds of IPs
already reported doing SSH/Telnet brute-forcing or generic
login-attack bot behavior elsewhere on the internet
(`blocklist.de`, `danger.rulez.sk`) into an `ipset` called
`cowrie-blocklist`. `scripts/firewall.sh` drops any new connection
from that set before it reaches Cowrie (`COWRIE-BLOCKLIST-DROP` in
the log) -- repeat automated scanners stop showing up in the capture
at all, on top of the 10/day-per-IP cap.

This is a lagging signal (an IP has to be reported elsewhere first),
not a filter on your own data -- it never blocks an IP based on
anything it did *here*, only on its reputation elsewhere. A genuine
human attacker, or a brand-new bot IP nobody's reported yet, still
gets through untouched.

Setup:
```bash
sudo apt install ipset
sudo make update-blocklist   # populate it the first time
sudo make firewall           # (re-)apply the DOCKER-USER rule that uses it
```

Keep it current with a cron entry (`sudo crontab -e`):
```cron
0 4 * * * /path/to/cowrie-honeypot-stack/scripts/update-blocklist.sh >> /var/log/cowrie-blocklist.log 2>&1
```

The ipset itself needs `ipset-persistent` (or an `@reboot` cron entry
running `update-blocklist.sh`) to survive a reboot -- see the output
of `scripts/firewall.sh` for details.

## Checklist before exposing to the internet

- [ ] The VM is dedicated, isolated (VLAN recommended) -- no access to the rest of your network
- [ ] `make firewall` applied, verified by test (see DEPLOYMENT.md step 5)
- [ ] `.env` has your own passwords, not the defaults from `.env.example`
- [ ] Grafana/session-viewer aren't reachable from the internet (ADMIN_CIDR only)
- [ ] The real SSH admin port isn't reachable from WAN
- [ ] VM snapshot taken in a clean state
- [ ] You have a plan for periodic resets (see below)
- [ ] `cowrie.cfg` has `backend = shell` (not proxy/llm)
- [ ] You have a plan/retention policy for logs containing IP addresses (see GDPR below)

## Periodic reset

Recommended: periodically (weekly) restore the VM from a snapshot --
this clears any persistent contamination of the fake filesystem and
resets state after any failure. **Back up logs and downloaded samples
before resetting** (Docker volumes `cowrie-var-log`, `cowrie-var-lib`)
-- that's the data you want to keep.

## GDPR / legal

Attacker IP addresses are personal data (if you're in the EU).
Running a honeypot for network security purposes is usually covered
by legitimate interest (GDPR Art. 6(1)(f)), but:
- don't publish/expose raw logs with IPs
- have a defined retention period (`LOKI_RETENTION_HOURS` in `.env`)
- when sharing threat intel (blog, community), aggregate/anonymize

## What to do when you see `HONEYPOT-EGRESS-BLOCKED`

1. Check what the connection attempt was
   (`journalctl -k | grep EGRESS-BLOCKED`)
2. If it's a legitimate need (e.g. a different port for downloads),
   update `scripts/firewall.sh` deliberately -- don't widen it blindly
3. If it looks suspicious (a connection you didn't expect, to an
   unusual port/IP) -- isolate the VM immediately (disconnect the
   network), check the Grafana dashboard and raw logs, and treat it
   as a possible emulation escape attempt

## Anti-detection

See [ANTI-DETECTION.md](ANTI-DETECTION.md) -- how the honeypot looks
less obvious, and why that has its limits.
