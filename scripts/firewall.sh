#!/usr/bin/env bash
# Host-level firewall for the honeypot VM -- see docs/SECURITY.md for
# an explanation of the model. In short: no container-initiated
# outbound connection is allowed, the ONLY exception is Cowrie on
# tcp/80,443 (downloading malware samples on the attacker's command),
# rate-limited and logged. Everything else (Grafana, session-viewer,
# Loki, Promtail, session-generator) has no route to the internet at
# all. Inbound new connections to Cowrie are also capped at 10/day per
# source IP (matched to cowrie.cfg's AuthRandom maxtry, see the
# comment at rule 3 below -- don't lower this without lowering maxtry
# too), to keep one scanning campaign from flooding you with hundreds
# of near-identical sessions, and IPs in the "cowrie-blocklist" ipset
# (populated by scripts/update-blocklist.sh from public known-scanner
# feeds) are dropped outright.
#
# Run with: sudo ./scripts/firewall.sh   (or `make firewall`)
# Requires: docker compose already running (needs COWRIE_IP from .env)

set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root (sudo ./scripts/firewall.sh)" >&2
  exit 1
fi

if [ ! -f .env ]; then
  echo "Missing .env -- copy it from .env.example and edit it (WAN_IFACE, ADMIN_CIDR)." >&2
  exit 1
fi
set -a
# shellcheck disable=SC1091
source .env
set +a

: "${WAN_IFACE:?set WAN_IFACE in .env}"
: "${COWRIE_IP:?set COWRIE_IP in .env}"
: "${COWRIE_EGRESS_SUBNET:?set COWRIE_EGRESS_SUBNET in .env}"
: "${MGMT_PUBLISH_SUBNET:?set MGMT_PUBLISH_SUBNET in .env}"
: "${ADMIN_CIDR:?set ADMIN_CIDR in .env -- where you are allowed to reach SSH/Grafana from}"

IFS=',' read -ra RESOLVERS <<< "${DNS_RESOLVERS:-1.1.1.1,9.9.9.9}"

# The blocklist ipset is populated separately (scripts/update-blocklist.sh);
# here we only make sure it exists so the iptables rule below doesn't
# fail to load on a box where update-blocklist.sh hasn't run yet.
if command -v ipset >/dev/null 2>&1; then
  ipset create cowrie-blocklist hash:ip hashsize 16384 maxelem 300000 -exist
else
  echo "[!] ipset not installed -- skipping the known-scanner blocklist rule." >&2
  echo "    Run: apt install ipset && sudo ./scripts/update-blocklist.sh" >&2
fi

echo "[*] Creating/flushing the DOCKER-USER chain..."
iptables -N DOCKER-USER 2>/dev/null || iptables -F DOCKER-USER

# 1) Return traffic always gets through.
iptables -A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# 2) Drop new connections from known-scanner IPs outright (see
#    scripts/update-blocklist.sh -- run it at least once, then on a
#    schedule, see docs/SECURITY.md). Skipped entirely if ipset isn't
#    installed.
if command -v ipset >/dev/null 2>&1; then
  iptables -A DOCKER-USER -i "$WAN_IFACE" -d "$COWRIE_IP" -p tcp -m multiport --dports 2222,2223 \
    -m set --match-set cowrie-blocklist src \
    -m conntrack --ctstate NEW \
    -j LOG --log-prefix "COWRIE-BLOCKLIST-DROP: "
  iptables -A DOCKER-USER -i "$WAN_IFACE" -d "$COWRIE_IP" -p tcp -m multiport --dports 2222,2223 \
    -m set --match-set cowrie-blocklist src \
    -m conntrack --ctstate NEW \
    -j DROP
fi

# 3) Rate-limit new inbound connections to Cowrie, per source IP --
#    max 10 sessions/day per IP, everything past that from the same IP
#    is logged and dropped before it ever reaches the container. Real
#    scanning campaigns (Mirai/Gafgyt-style bots) otherwise reconnect
#    every few seconds and flood the capture with hundreds of
#    identical sessions from one source -- this caps that without
#    reducing how many distinct attackers get through (every new IP
#    still gets its own 10).
#
#    IMPORTANT: this number must stay >= the maxtry value (2nd number)
#    in cowrie.cfg's auth_class_parameters. AuthRandom requires a
#    random number of attempts (up to maxtry) before it lets a source
#    IP in, and it counts those across separate connections, not just
#    within one -- many bots open a fresh connection per credential
#    tried. If this limit is lower than maxtry, most attackers get cut
#    off mid-brute-force and can never reach their own success
#    threshold at all (confirmed: with this at 4 and maxtry=10, ~75%
#    of source IPs would never complete a login). Default
#    auth_class_parameters is 3,10,10 -- keep this at 10 to match.
iptables -A DOCKER-USER -i "$WAN_IFACE" -d "$COWRIE_IP" -p tcp -m multiport --dports 2222,2223 \
  -m conntrack --ctstate NEW \
  -m hashlimit --hashlimit-name cowrie-inbound --hashlimit-mode srcip \
  --hashlimit-above 10/day --hashlimit-burst 10 --hashlimit-htable-expire 86400000 \
  -j LOG --log-prefix "COWRIE-INBOUND-RATELIMIT-DROP: "
iptables -A DOCKER-USER -i "$WAN_IFACE" -d "$COWRIE_IP" -p tcp -m multiport --dports 2222,2223 \
  -m conntrack --ctstate NEW \
  -m hashlimit --hashlimit-name cowrie-inbound --hashlimit-mode srcip \
  --hashlimit-above 10/day --hashlimit-burst 10 --hashlimit-htable-expire 86400000 \
  -j DROP

# 4) Traffic arriving from WAN is left to Docker's own DNAT logic.
iptables -A DOCKER-USER -i "$WAN_IFACE" -j RETURN

# 5) Cowrie may open new outbound connections only on tcp/80,443,
#    rate-limited and logged.
iptables -A DOCKER-USER -s "$COWRIE_IP" -o "$WAN_IFACE" -p tcp -m multiport --dports 80,443 \
  -m conntrack --ctstate NEW \
  -m hashlimit --hashlimit-name cowrie-egress --hashlimit-above 20/minute --hashlimit-burst 5 \
  -j LOG --log-prefix "COWRIE-EGRESS-RATELIMIT-DROP: "
iptables -A DOCKER-USER -s "$COWRIE_IP" -o "$WAN_IFACE" -p tcp -m multiport --dports 80,443 \
  -m conntrack --ctstate NEW \
  -m hashlimit --hashlimit-name cowrie-egress --hashlimit-above 20/minute --hashlimit-burst 5 \
  -j DROP
iptables -A DOCKER-USER -s "$COWRIE_IP" -o "$WAN_IFACE" -p tcp -m multiport --dports 80,443 \
  -m conntrack --ctstate NEW -j LOG --log-prefix "COWRIE-EGRESS-ALLOW: "
iptables -A DOCKER-USER -s "$COWRIE_IP" -o "$WAN_IFACE" -p tcp -m multiport --dports 80,443 \
  -m conntrack --ctstate NEW -j ACCEPT

# 6) DNS for Cowrie only to the configured resolvers.
for r in "${RESOLVERS[@]}"; do
  iptables -A DOCKER-USER -s "$COWRIE_IP" -o "$WAN_IFACE" -d "$r" -p udp --dport 53 \
    -m conntrack --ctstate NEW -j ACCEPT
  iptables -A DOCKER-USER -s "$COWRIE_IP" -o "$WAN_IFACE" -d "$r" -p tcp --dport 53 \
    -m conntrack --ctstate NEW -j ACCEPT
done

# 7) Anything else from the honeypot subnet outbound = tripwire (log + drop).
iptables -A DOCKER-USER -s "$COWRIE_EGRESS_SUBNET" -o "$WAN_IFACE" \
  -m conntrack --ctstate NEW -j LOG --log-prefix "HONEYPOT-EGRESS-BLOCKED: " --log-level 4
iptables -A DOCKER-USER -s "$COWRIE_EGRESS_SUBNET" -o "$WAN_IFACE" \
  -m conntrack --ctstate NEW -j DROP

# 8) Grafana/session-viewer/session-generator subnet -- exists only
#    because of the Docker port-publish mechanism, never needs
#    anything outbound.
iptables -A DOCKER-USER -s "$MGMT_PUBLISH_SUBNET" -o "$WAN_IFACE" \
  -m conntrack --ctstate NEW -j LOG --log-prefix "MGMT-EGRESS-BLOCKED: " --log-level 4
iptables -A DOCKER-USER -s "$MGMT_PUBLISH_SUBNET" -o "$WAN_IFACE" \
  -m conntrack --ctstate NEW -j DROP

echo "[*] Done. Current DOCKER-USER rules:"
iptables -L DOCKER-USER -n -v --line-numbers

cat <<EOF

--- IMPORTANT ---
1) These rules don't survive a reboot without "iptables-persistent":
     apt install iptables-persistent && netfilter-persistent save
   The "cowrie-blocklist" ipset needs the same treatment:
     apt install ipset-persistent && netfilter-persistent save
   (if ipset-persistent isn't packaged for your distro, a cron job
   running update-blocklist.sh at boot achieves the same thing)
2) Run scripts/update-blocklist.sh at least once (needs "ipset"
   installed), then schedule it (cron example in docs/SECURITY.md) --
   this script only ensures the ipset *exists*, it doesn't populate it.
3) Restrict admin access (SSH, Grafana port ${GRAFANA_PORT:-3000},
   session-viewer port ${SESSION_VIEWER_PORT:-8080}) at your
   network/router level to ADMIN_CIDR=${ADMIN_CIDR} only -- this
   script only handles outbound traffic from containers, not who's
   allowed in on the admin ports.
4) Watch for "HONEYPOT-EGRESS-BLOCKED" / "MGMT-EGRESS-BLOCKED" in the
   log (journalctl -k) -- any occurrence means investigate it as a
   suspected emulation escape or misconfiguration.
5) After every "docker compose pull" (image update), re-run this
   script so the rules match the current docker network.
EOF
