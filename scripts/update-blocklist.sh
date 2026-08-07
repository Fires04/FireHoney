#!/usr/bin/env bash
# Refreshes the "cowrie-blocklist" ipset from public known-scanner
# feeds -- IPs already reported doing SSH/Telnet brute-forcing or
# generic login-attack bot behavior elsewhere on the internet. The
# firewall (scripts/firewall.sh) drops new connections from anything
# in this set before it ever reaches Cowrie, so repeat automated
# scanners stop showing up in the capture at all -- what's left is
# more likely to be someone hitting this box specifically.
#
# This is a lagging, best-effort signal, not a guarantee: a scanner
# has to have already been reported elsewhere to be on these lists,
# so brand-new bot IPs and any genuine human attacker still get
# through (which is correct -- we only want to cut confirmed
# automated noise, not filter the box's own data).
#
# Sources (free, no signup, plain-text IP-per-line):
#   - blocklist.de/lists/ssh.txt   -- reported SSH brute-forcers
#   - blocklist.de/lists/bots.txt  -- reported generic login-attack bots
#   - danger.rulez.sk bruteforceblocker -- reported SSH brute-forcers
#
# Run once manually, then on a schedule (see docs/SECURITY.md for a
# cron example) to keep it current.
#
# Run with: sudo ./scripts/update-blocklist.sh  (or `make update-blocklist`)

set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root (sudo ./scripts/update-blocklist.sh)" >&2
  exit 1
fi

if ! command -v ipset >/dev/null 2>&1; then
  echo "ipset not installed -- run: apt install ipset" >&2
  exit 1
fi

SET_NAME="cowrie-blocklist"
TMP_SET="cowrie-blocklist-tmp"
IP_FILE="$(mktemp)"
RESTORE_FILE="$(mktemp)"
trap 'rm -f "$IP_FILE" "$RESTORE_FILE"' EXIT

echo "[*] Downloading known-scanner IP feeds..."
{
  curl -fsSL --max-time 30 "https://lists.blocklist.de/lists/ssh.txt" || true
  curl -fsSL --max-time 30 "https://lists.blocklist.de/lists/bots.txt" || true
  curl -fsSL --max-time 30 "http://danger.rulez.sk/projects/bruteforceblocker/blist.php" || true
} | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -u > "$IP_FILE"

COUNT=$(wc -l < "$IP_FILE")
if [ "$COUNT" -lt 100 ]; then
  echo "[!] Only got $COUNT IPs -- feeds may be down or unreachable (remember: Loki/Promtail/etc have no internet route, but this script runs on the HOST, not in a container). Keeping the existing set unchanged." >&2
  exit 1
fi

echo "[*] Got $COUNT known-scanner IPs. Building the set..."
{
  echo "create $TMP_SET hash:ip hashsize 16384 maxelem 300000 -exist"
  echo "flush $TMP_SET"
  awk -v s="$TMP_SET" '{print "add " s " " $0}' "$IP_FILE"
} > "$RESTORE_FILE"
ipset restore -exist < "$RESTORE_FILE"

# Atomic swap -- no window where the set is empty/missing.
ipset create "$SET_NAME" hash:ip hashsize 16384 maxelem 300000 -exist
ipset swap "$TMP_SET" "$SET_NAME"
ipset destroy "$TMP_SET"

echo "[*] Done -- $SET_NAME now has $COUNT entries."
echo "    (scripts/firewall.sh must have been run at least once so the DOCKER-USER rule referencing this set exists)"
