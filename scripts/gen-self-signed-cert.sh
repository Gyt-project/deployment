#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
#  gen-self-signed-cert.sh
#
#  Generates a self-signed TLS certificate for local / staging use and writes
#  the combined PEM file that HAProxy expects to haproxy/certs/gyt.pem.
#
#  Usage:
#    chmod +x scripts/gen-self-signed-cert.sh
#    ./scripts/gen-self-signed-cert.sh [domain]
#
#  Default domain: localhost
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

DOMAIN="${1:-localhost}"
OUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/haproxy/certs"
PEM_FILE="${OUT_DIR}/gyt.pem"
KEY_FILE="${OUT_DIR}/gyt.key"
CRT_FILE="${OUT_DIR}/gyt.crt"

mkdir -p "${OUT_DIR}"

echo "Generating self-signed certificate for: ${DOMAIN}"

openssl req -x509 \
  -newkey rsa:4096 \
  -keyout "${KEY_FILE}" \
  -out    "${CRT_FILE}" \
  -days   365 \
  -nodes \
  -subj   "/CN=${DOMAIN}/O=GYT Dev/C=US" \
  -addext "subjectAltName=DNS:${DOMAIN},DNS:localhost,IP:127.0.0.1"

# HAProxy needs cert + key in a single PEM file.
cat "${CRT_FILE}" "${KEY_FILE}" > "${PEM_FILE}"

# Remove the split files; gyt.pem is all HAProxy needs.
rm "${KEY_FILE}" "${CRT_FILE}"

echo ""
echo "Certificate written to: ${PEM_FILE}"
echo ""
echo "NOTE: This is a self-signed certificate. Browsers will show a security"
echo "      warning. For production, use a certificate from Let's Encrypt or"
echo "      another trusted CA.  See haproxy/certs/README.txt for instructions."
