#!/usr/bin/env bash
# Vygeneruje config/cowrie/fs.pickle -- realisticky vypadajici fake
# filesystem pro Cowrie, misto genericky stejneho defaultu, co ma
# kazda Cowrie instalace na svete. Detaily a bezpecnostni poznamka
# (proc se tohle NIKDY nespousti proti realnemu produkcnimu hostu)
# jsou v docs/ANTI-DETECTION.md.
#
# Spousti se: make fakefs   (nebo primo ./scripts/build-fakefs.sh)

set -euo pipefail
cd "$(dirname "$0")/.."

echo "[1/4] Stavim jednorazovy 'realny' Debian server (docker build)..."
docker build -t cowrie-honeypot/fakefs-src:latest ./docker/fakefs-builder

echo "[2/4] Exportuji jeho filesystem na disk..."
rm -rf .fakefs-tmp
mkdir -p .fakefs-tmp
CID=$(docker create cowrie-honeypot/fakefs-src:latest)
docker export "$CID" | tar -x -C .fakefs-tmp
docker rm "$CID" > /dev/null

# Docker spravuje /etc/hostname mimo image vrstvu, po exportu bývá
# prazdne -- dopiseme rucne. Totez /etc/os-release, ktery je na
# realnem Debianu symlink (createfs neumi embedovat obsah symlinku).
echo webprod03 > .fakefs-tmp/etc/hostname
cp --remove-destination .fakefs-tmp/usr/lib/os-release .fakefs-tmp/etc/os-release 2>/dev/null || true

echo "[3/4] Generuji fs.pickle (createfs z cowrie balicku, jednorazovy kontejner)..."
docker run --rm \
  -v "$(pwd)/.fakefs-tmp:/fakefs:ro" \
  -v "$(pwd)/config/cowrie:/out" \
  python:3.13-slim \
  bash -c "pip install --quiet cowrie && createfs -l /fakefs -d 100 -o /out/fs.pickle"

echo "[4/4] Uklizim..."
rm -rf .fakefs-tmp

echo ""
echo "Hotovo: config/cowrie/fs.pickle"
echo "Restartuj cowrie, at zmenu nacte:  docker compose restart cowrie"
