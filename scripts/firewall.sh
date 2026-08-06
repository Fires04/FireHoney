#!/usr/bin/env bash
# Host-level firewall for the honeypot VM -- see docs/SECURITY.md for
# an explanation of the model. In short: no container-initiated
# outbound connection is allowed, the ONLY exception is Cowrie on
# tcp/80,443 (downloading malware samples on the attacker's command),
# rate-limited and logged. Everything else (Grafana, session-viewer,
# Loki, Promtail, session-generator) has no route to the internet at
# all.
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
: "${ADMIN_CIDR:?set ADMIN_CIDR in .env -- where you're allowed to reach SSH/Grafana from}"

IFS=',' read -ra RESOLVERS <<< "${DNS_RESOLVERS:-1.1.1.1,9.9.9.9}"

echo "[*] Creating/flushing the DOCKER-USER chain..."
iptables -N DOCKER-USER 2>/dev/null || iptables -F DOCKER-USER

# 1) Return traffic always gets through.
iptables -A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# 2) Traffic arriving from WAN is left to Docker's own DNAT logic.
iptables -A DOCKER-USER -i "$WAN_IFACE" -j RETURN

# 3) Cowrie may open new outbound connections only on tcp/80,443,
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

# 4) DNS for Cowrie only to the configured resolvers.
for r in "${RESOLVERS[@]}"; do
  iptables -A DOCKER-USER -s "$COWRIE_IP" -o "$WAN_IFACE" -d "$r" -p udp --dport 53 \
    -m conntrack --ctstate NEW -j ACCEPT
  iptables -A DOCKER-USER -s "$COWRIE_IP" -o "$WAN_IFACE" -d "$r" -p tcp --dport 53 \
    -m conntrack --ctstate NEW -j ACCEPT
done

# 5) Anything else from the honeypot subnet outbound = tripwire (log + drop).
iptables -A DOCKER-USER -s "$COWRIE_EGRESS_SUBNET" -o "$WAN_IFACE" \
  -m conntrack --ctstate NEW -j LOG --log-prefix "HONEYPOT-EGRESS-BLOCKED: " --log-level 4
iptables -A DOCKER-USER -s "$COWRIE_EGRESS_SUBNET" -o "$WAN_IFACE" \
  -m conntrack --ctstate NEW -j DROP

# 6) Grafana/session-viewer/session-generator subnet -- exists only
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
2) Restrict admin access (SSH, Grafana port ${GRAFANA_PORT:-3000},
   session-viewer port ${SESSION_VIEWER_PORT:-8080}) at your
   network/router level to ADMIN_CIDR=${ADMIN_CIDR} only -- this
   script only handles outbound traffic from containers, not who's
   allowed in on the admin ports.
3) Watch for "HONEYPOT-EGRESS-BLOCKED" / "MGMT-EGRESS-BLOCKED" in the
   log (journalctl -k) -- any occurrence means investigate it as a
   suspected emulation escape or misconfiguration.
4) After every "docker compose pull" (image update), re-run this
   script so the rules match the current docker network.
EOF
