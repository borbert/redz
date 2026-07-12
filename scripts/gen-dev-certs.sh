#!/usr/bin/env bash
# Generate a self-signed cert for local TLS testing (not for production).
set -euo pipefail
OUT_DIR="${1:-./certs}"
mkdir -p "$OUT_DIR"
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$OUT_DIR/key.pem" \
  -out "$OUT_DIR/cert.pem" \
  -days 365 \
  -subj "/CN=localhost"
echo "Wrote $OUT_DIR/cert.pem and $OUT_DIR/key.pem"
