#!/usr/bin/env bash
# Generates config/cowrie/fs.pickle -- a realistic-looking fake
# filesystem for Cowrie, instead of the generic default that every
# Cowrie install shares. Details and a security note (why this is
# NEVER run against a real production host) are in
# docs/ANTI-DETECTION.md.
#
# Run with: make fakefs   (or directly ./scripts/build-fakefs.sh)

set -euo pipefail
cd "$(dirname "$0")/.."

echo "[1/4] Building a one-shot 'realistic' Debian server (docker build)..."
docker build -t cowrie-honeypot/fakefs-src:latest ./docker/fakefs-builder

echo "[2/4] Exporting its filesystem to disk..."
rm -rf .fakefs-tmp
mkdir -p .fakefs-tmp
CID=$(docker create cowrie-honeypot/fakefs-src:latest)
docker export "$CID" | tar -x -C .fakefs-tmp
docker rm "$CID" > /dev/null

# Docker manages /etc/hostname outside the image layer, it tends to
# come out empty after export -- write it back manually. Same for
# /etc/os-release, which is a symlink on a real Debian system
# (createfs can't embed the content of a symlink).
echo webprod03 > .fakefs-tmp/etc/hostname
cp --remove-destination .fakefs-tmp/usr/lib/os-release .fakefs-tmp/etc/os-release 2>/dev/null || true

echo "[3/4] Generating fs.pickle (createfs from the cowrie package, one-shot container)..."
docker run --rm \
  -v "$(pwd)/.fakefs-tmp:/fakefs:ro" \
  -v "$(pwd)/config/cowrie:/out" \
  python:3.13-slim \
  bash -c "pip install --quiet cowrie && createfs -l /fakefs -d 100 -o /out/fs.pickle"

echo "[4/4] Cleaning up..."
rm -rf .fakefs-tmp

echo ""
echo "Done: config/cowrie/fs.pickle"
echo "Restart cowrie so it picks up the change:  docker compose restart cowrie"
