#!/bin/sh
#
# Generate a self-signed TLS certificate for the answer file server.
#
# Usage:
#
#   ./gen-cert.sh <ip-or-hostname> [<ip-or-hostname> ...]
#
# Example:
#
#   ./gen-cert.sh 10.100.9.50 pve-answer.example.com
#
# Every address the Proxmox installer may use to reach this server must be
# listed, because the installer validates the certificate's SAN entries.

set -eu

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <ip-or-hostname> [<ip-or-hostname> ...]" >&2
    exit 1
fi

CERT_DIR="${CERT_DIR:-./certs}"
DAYS="${DAYS:-3650}"

# Build the subjectAltName list, classifying each argument as IP or DNS.
san=""
for host in "$@"; do
    case "$host" in
        *[!0-9.]*) entry="DNS:$host" ;;
        *)         entry="IP:$host" ;;
    esac

    if [ -z "$san" ]; then
        san="$entry"
    else
        san="$san,$entry"
    fi
done

mkdir -p "$CERT_DIR"

openssl req -x509 -newkey rsa:4096 -sha256 -days "$DAYS" -nodes \
    -keyout "$CERT_DIR/server.key" \
    -out "$CERT_DIR/server.crt" \
    -subj "/CN=$1" \
    -addext "subjectAltName=$san"

chmod 600 "$CERT_DIR/server.key"
chmod 644 "$CERT_DIR/server.crt"

fingerprint=$(openssl x509 -in "$CERT_DIR/server.crt" -noout -fingerprint -sha256 \
    | cut -d '=' -f 2)

cat <<MSG

Certificate written to $CERT_DIR/server.crt
Private key written to $CERT_DIR/server.key

SHA-256 fingerprint:

$fingerprint

Pass this fingerprint to proxmox-auto-install-assistant, otherwise the
installer will refuse the self-signed certificate:

  proxmox-auto-install-assistant prepare-iso <iso> \\
      --fetch-from http \\
      --url "https://$1/answer" \\
      --cert-fingerprint "$fingerprint"
MSG
