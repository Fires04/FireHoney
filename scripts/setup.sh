#!/usr/bin/env bash
# One-time preparation before the first "docker compose up":
#   - checks .env
#   - generates VIEWER_SESSION_SECRET if it's blank
#   - downloads the self-hosted asciinema-player (no CDN at runtime)
#   - pulls docker images
#
# Run with: make setup   (or directly ./scripts/setup.sh)

set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
  echo "No .env found, copying from .env.example -- PLEASE EDIT THE PASSWORDS before continuing:"
  cp .env.example .env
  echo "  \$EDITOR .env"
  exit 1
fi
set -a
# shellcheck disable=SC1091
source .env
set +a

if ! command -v docker &> /dev/null; then
  echo "Docker is not installed. See docs/DEPLOYMENT.md step 1." >&2
  exit 1
fi

if ! command -v openssl &> /dev/null; then
  echo "openssl is not installed (needed to generate VIEWER_SESSION_SECRET) -- run: apt install openssl" >&2
  exit 1
fi

if [ "${GRAFANA_ADMIN_PASSWORD:-change-me-please}" = "change-me-please" ] || \
   [ "${VIEWER_PASSWORD:-change-me-too}" = "change-me-too" ]; then
  echo "!! .env still has the default passwords. Set GRAFANA_ADMIN_PASSWORD" >&2
  echo "!! and VIEWER_PASSWORD to something of your own before continuing." >&2
  exit 1
fi

echo "[1/4] webui/ directory structure..."
mkdir -p webui/casts webui/assets

echo "[2/4] Session viewer login secret..."
if [ -z "${VIEWER_SESSION_SECRET:-}" ]; then
  GENERATED=$(openssl rand -hex 32)
  # Portable in-place append -- works whether or not the file ends
  # with a trailing newline.
  printf '\nVIEWER_SESSION_SECRET=%s\n' "${GENERATED}" >> .env
  echo "    generated a new one and saved it to .env"
else
  echo "    already set, skipping"
fi

echo "[3/4] Self-hosted asciinema-player (one-time, while there's internet access)..."
if [ ! -f webui/assets/asciinema-player.min.js ]; then
  LATEST=$(curl -fsSL https://api.github.com/repos/asciinema/asciinema-player/releases/latest \
    | grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4)
  curl -fsSL -o webui/assets/asciinema-player.min.js \
    "https://github.com/asciinema/asciinema-player/releases/download/${LATEST}/asciinema-player.min.js"
  curl -fsSL -o webui/assets/asciinema-player.css \
    "https://github.com/asciinema/asciinema-player/releases/download/${LATEST}/asciinema-player.css"
  echo "    downloaded ${LATEST}"
else
  echo "    already present, skipping"
fi

echo "[4/4] Pulling docker images (docker compose pull)..."
docker compose pull cowrie promtail loki grafana session-viewer
docker compose build session-generator viewer-auth

cat <<'EOF'

Done. Next steps:
  1. (Optional, recommended) make fakefs   -- realistic fake filesystem
  2. make up                                -- bring up the whole stack
  3. sudo make firewall                     -- egress lockdown
  4. Open http://SERVER_IP:${GRAFANA_PORT:-3000} and http://SERVER_IP:${SESSION_VIEWER_PORT:-8080}

Go through the docs/SECURITY.md checklist before exposing this to the internet!
EOF
