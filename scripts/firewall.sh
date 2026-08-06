#!/usr/bin/env bash
# Host-level firewall pro honeypot VM -- viz docs/SECURITY.md pro
# vysvetleni modelu. Ve zkratce: zadne kontejnerem iniciovane odchozi
# spojeni neni povolene, JEDINA vyjimka je Cowrie na tcp/80,443
# (stahovani malware vzorku na povel utocnika), rate-limited a
# logovane. Vsechno ostatni (Grafana, session-viewer, Loki, Promtail,
# session-generator) nema do internetu zadnou cestu.
#
# Spousti se: sudo ./scripts/firewall.sh   (nebo `make firewall`)
# Vyzaduje: docker compose uz bezi (potrebuje znat COWRIE_IP z .env)

set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$(id -u)" -ne 0 ]; then
  echo "Spust jako root (sudo ./scripts/firewall.sh)" >&2
  exit 1
fi

if [ ! -f .env ]; then
  echo "Chybi .env -- zkopiruj z .env.example a uprav (WAN_IFACE, ADMIN_CIDR)." >&2
  exit 1
fi
set -a
# shellcheck disable=SC1091
source .env
set +a

: "${WAN_IFACE:?nastav WAN_IFACE v .env}"
: "${COWRIE_IP:?nastav COWRIE_IP v .env}"
: "${COWRIE_EGRESS_SUBNET:?nastav COWRIE_EGRESS_SUBNET v .env}"
: "${MGMT_PUBLISH_SUBNET:?nastav MGMT_PUBLISH_SUBNET v .env}"
: "${ADMIN_CIDR:?nastav ADMIN_CIDR v .env -- odkud smis na SSH/Grafanu}"

IFS=',' read -ra RESOLVERS <<< "${DNS_RESOLVERS:-1.1.1.1,9.9.9.9}"

echo "[*] Vytvarim/cistim DOCKER-USER retezec..."
iptables -N DOCKER-USER 2>/dev/null || iptables -F DOCKER-USER

# 1) Navratovy provoz vzdy projde.
iptables -A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# 2) Provoz prichazejici z WAN necháme na Dockerove vlastni DNAT logice.
iptables -A DOCKER-USER -i "$WAN_IFACE" -j RETURN

# 3) Cowrie smi novy odchozi provoz jen na tcp/80,443, rate-limited + logovano.
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

# 4) DNS pro Cowrie jen na vybrane resolvery.
for r in "${RESOLVERS[@]}"; do
  iptables -A DOCKER-USER -s "$COWRIE_IP" -o "$WAN_IFACE" -d "$r" -p udp --dport 53 \
    -m conntrack --ctstate NEW -j ACCEPT
  iptables -A DOCKER-USER -s "$COWRIE_IP" -o "$WAN_IFACE" -d "$r" -p tcp --dport 53 \
    -m conntrack --ctstate NEW -j ACCEPT
done

# 5) Cokoliv jineho z honeypot podsite ven = tripwire (log + drop).
iptables -A DOCKER-USER -s "$COWRIE_EGRESS_SUBNET" -o "$WAN_IFACE" \
  -m conntrack --ctstate NEW -j LOG --log-prefix "HONEYPOT-EGRESS-BLOCKED: " --log-level 4
iptables -A DOCKER-USER -s "$COWRIE_EGRESS_SUBNET" -o "$WAN_IFACE" \
  -m conntrack --ctstate NEW -j DROP

# 6) Grafana/session-viewer/session-generator podsit -- existuje jen
#    kvuli Docker port-publish mechanismu, nikdy nepotrebuje nic ven.
iptables -A DOCKER-USER -s "$MGMT_PUBLISH_SUBNET" -o "$WAN_IFACE" \
  -m conntrack --ctstate NEW -j LOG --log-prefix "MGMT-EGRESS-BLOCKED: " --log-level 4
iptables -A DOCKER-USER -s "$MGMT_PUBLISH_SUBNET" -o "$WAN_IFACE" \
  -m conntrack --ctstate NEW -j DROP

echo "[*] Hotovo. Aktualni DOCKER-USER pravidla:"
iptables -L DOCKER-USER -n -v --line-numbers

cat <<EOF

--- DULEZITE ---
1) Pravidla nejsou perzistentni pres reboot bez "iptables-persistent":
     apt install iptables-persistent && netfilter-persistent save
2) Spravu (SSH, Grafana port ${GRAFANA_PORT:-3000}, session-viewer port
   ${SESSION_VIEWER_PORT:-8080}) na urovni sve site/routeru omez jen na
   ADMIN_CIDR=${ADMIN_CIDR} -- tenhle skript resi jen odchozi provoz
   z kontejneru, ne kdo smi dovnitr na admin porty.
3) Sleduj log "HONEYPOT-EGRESS-BLOCKED" / "MGMT-EGRESS-BLOCKED"
   (journalctl -k) -- jakykoliv vyskyt = prosetrit jako podezreni na
   unik z emulace nebo chybu v konfiguraci.
4) Po kazdem "docker compose pull" (aktualizace images) tenhle skript
   znovu spust, aby pravidla sedela na aktualni docker sit.
EOF
