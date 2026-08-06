#!/usr/bin/env bash
# Jednorazova priprava pred prvnim "docker compose up":
#   - zkontroluje .env
#   - vygeneruje htpasswd pro session-viewer z VIEWER_USER/VIEWER_PASSWORD
#   - stahne self-hosted asciinema-player (zadne CDN za behu)
#   - stahne docker images
#
# Spousti se: make setup   (nebo primo ./scripts/setup.sh)

set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
  echo "Nemas .env, kopiruji z .env.example -- PROSIM UPRAV HESLA nez budes pokracovat:"
  cp .env.example .env
  echo "  \$EDITOR .env"
  exit 1
fi
set -a
# shellcheck disable=SC1091
source .env
set +a

if ! command -v docker &> /dev/null; then
  echo "Docker neni nainstalovany. Viz docs/DEPLOYMENT.md krok 1." >&2
  exit 1
fi

if [ "${GRAFANA_ADMIN_PASSWORD:-change-me-please}" = "change-me-please" ] || \
   [ "${VIEWER_PASSWORD:-change-me-too}" = "change-me-too" ]; then
  echo "!! V .env jsou porad defaultni hesla. Uprav GRAFANA_ADMIN_PASSWORD" >&2
  echo "!! a VIEWER_PASSWORD na neco vlastniho pred pokracovanim." >&2
  exit 1
fi

echo "[1/4] Adresarova struktura webui/..."
mkdir -p webui/casts webui/assets

echo "[2/4] htpasswd pro session-viewer (${VIEWER_USER})..."
docker run --rm httpd:alpine htpasswd -Bbn "${VIEWER_USER}" "${VIEWER_PASSWORD}" \
  > config/nginx/htpasswd

echo "[3/4] Self-hosted asciinema-player (jednorazove, dokud je internet)..."
if [ ! -f webui/assets/asciinema-player.min.js ]; then
  LATEST=$(curl -fsSL https://api.github.com/repos/asciinema/asciinema-player/releases/latest \
    | grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4)
  curl -fsSL -o webui/assets/asciinema-player.min.js \
    "https://github.com/asciinema/asciinema-player/releases/download/${LATEST}/asciinema-player.min.js"
  curl -fsSL -o webui/assets/asciinema-player.css \
    "https://github.com/asciinema/asciinema-player/releases/download/${LATEST}/asciinema-player.css"
  echo "    staženo ${LATEST}"
else
  echo "    uz existuje, preskakuji"
fi

echo "[4/4] Stahuji docker images a builduji session-generator..."
docker compose pull cowrie promtail loki grafana session-viewer
docker compose build session-generator

cat <<'EOF'

Hotovo. Dalsi kroky:
  1. (Volitelne, doporuceno) make fakefs   -- realisticky fake filesystem
  2. make up                                -- rozjede cely stack
  3. sudo make firewall                     -- egress lockdown
  4. Otevri http://SERVER_IP:${GRAFANA_PORT:-3000} a http://SERVER_IP:${SESSION_VIEWER_PORT:-8080}

Pred vystavenim do internetu si projdi docs/SECURITY.md checklist!
EOF
