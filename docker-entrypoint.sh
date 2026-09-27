#!/bin/sh
#
# Checks the auth token, generates the TLS certificate if it is missing, then
# runs the server unprivileged. Existing files are never overwritten.
#
# Layout inside the container:
#
#   /etc/pve-answer/certs/server.{crt,key}   writable, generated on first run
#   /run/secrets/pve_answer_token            read-only compose secret
#   /answers/<mac>.toml                      read-only
#   /default.toml                            read-only, baked into the image

set -eu

# Used only if the certs directory's owner cannot be used.
FALLBACK_UID=10001
FALLBACK_GID=10001

CERTS_DIR=/etc/pve-answer/certs
CERT_FILE="$CERTS_DIR/server.crt"
KEY_FILE="$CERTS_DIR/server.key"
TOKEN_FILE="${PVE_ANSWER_TOKEN_FILE:-}"

log() { echo "entrypoint: $*"; }

# Development only: no token, no certificate, plain HTTP. Accepts the same
# values as the server's PVE_ANSWER_DEBUG (1/true/yes/on, any case).
INSECURE=""
case "$(echo "${PVE_ANSWER_INSECURE:-}" | tr -d ' ' | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) INSECURE=1 ;;
esac

# --- preflight -------------------------------------------------------------
# Checked first, so a doomed run leaves nothing behind.

if [ -z "$INSECURE" ]; then
    if [ -n "$TOKEN_FILE" ] && [ -e "$TOKEN_FILE" ]; then
        :
    elif [ -n "${PVE_ANSWER_TOKEN:-}" ]; then
        # The server prefers the file, so drop the (absent) file setting.
        unset PVE_ANSWER_TOKEN_FILE
        TOKEN_FILE=""
    else
        log "ERROR: no auth token at ${TOKEN_FILE:-<PVE_ANSWER_TOKEN_FILE unset>}."
        log ""
        log "The token is provided by the host, not generated here. Create it"
        log "next to compose.yaml, readable by the container user:"
        log "  mkdir -p secrets"
        log "  printf 'provisioning:%s' \"\$(openssl rand -hex 32)\" > secrets/pve_answer_token"
        log "  chown 10001:10001 secrets/pve_answer_token"
        log "  chmod 400 secrets/pve_answer_token"
        exit 1
    fi

    if [ ! -e "$CERT_FILE" ] || [ ! -e "$KEY_FILE" ]; then
        if [ -z "${PVE_ANSWER_HOSTNAMES:-}" ]; then
            log "ERROR: no certificate at $CERT_FILE and PVE_ANSWER_HOSTNAMES is"
            log "unset, so one cannot be generated."
            log ""
            log "The Proxmox installer validates the certificate's SAN entries, so"
            log "every address it may use to reach this server has to be named."
            log "Set it to a comma-separated list, for example:"
            log "  PVE_ANSWER_HOSTNAMES=10.100.9.50,pve-answer.example.com"
            exit 1
        fi
    fi
fi

# --- runtime identity ------------------------------------------------------
# Run as the owner of the certs directory, so generated files are usable on
# the host without sudo.

mkdir -p "$CERTS_DIR"

DIR_UID="$(stat -c '%u' "$CERTS_DIR" 2>/dev/null || true)"
DIR_GID="$(stat -c '%g' "$CERTS_DIR" 2>/dev/null || true)"

if [ -n "$DIR_UID" ] && [ "$DIR_UID" != "0" ]; then
    APP_UID="$DIR_UID"
    APP_GID="${DIR_GID:-$DIR_UID}"
else
    APP_UID="$FALLBACK_UID"
    APP_GID="$FALLBACK_GID"

    if [ -n "$INSECURE" ]; then
        :
    elif [ "$DIR_UID" = "0" ]; then
        log "WARNING: $CERTS_DIR is owned by root, so the server will run as"
        log "$APP_UID instead and generated files will need sudo to remove."
        log "To avoid that: chown -R \$(id -u):\$(id -g) on the host directory."
    else
        log "WARNING: could not determine the owner of $CERTS_DIR; running as"
        log "$APP_UID."
    fi
fi

log "running as uid $APP_UID, gid $APP_GID"

as_app() { setpriv --reuid="$APP_UID" --regid="$APP_GID" --clear-groups "$@"; }

# Compose ignores uid/gid/mode on file secrets, so the host file's own
# ownership decides whether the server can read it.
if [ -z "$INSECURE" ] && [ -n "$TOKEN_FILE" ] && ! as_app test -r "$TOKEN_FILE"; then
    log "ERROR: $TOKEN_FILE is not readable by uid $APP_UID."
    log "On the host: chown $APP_UID:$APP_GID <token file> && chmod 400 <token file>"
    exit 1
fi

# --- TLS certificate -------------------------------------------------------

if [ -z "$INSECURE" ] && { [ ! -e "$CERT_FILE" ] || [ ! -e "$KEY_FILE" ]; }; then
    san=""
    IFS=','
    for host in $PVE_ANSWER_HOSTNAMES; do
        host="$(echo "$host" | tr -d ' ')"

        [ -n "$host" ] || continue

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
    unset IFS

    if [ -z "$san" ]; then
        log "ERROR: PVE_ANSWER_HOSTNAMES contains no usable entries"
        exit 1
    fi

    log "generating a self-signed certificate for $san"

    openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
        -keyout "$KEY_FILE" \
        -out "$CERT_FILE" \
        -subj "/CN=$(echo "$PVE_ANSWER_HOSTNAMES" | cut -d ',' -f 1)" \
        -addext "subjectAltName=$san" 2>/dev/null

    chmod 600 "$KEY_FILE"
    chmod 644 "$CERT_FILE"

    # Only files this script created.
    chown "$APP_UID:$APP_GID" "$CERT_FILE" "$KEY_FILE" 2>/dev/null || true
fi

# Printed every start, so it is always in the log.
if [ -z "$INSECURE" ]; then
    log "certificate SHA-256 fingerprint (pass to prepare-iso --cert-fingerprint):"
    log "  $(openssl x509 -in "$CERT_FILE" -noout -fingerprint -sha256 \
        | cut -d '=' -f 2)"
fi

# --- insecure mode ---------------------------------------------------------
# Drop --cert/--key from the arguments (the image's CMD always passes them)
# and any token configuration, so the server runs open over plain HTTP.

if [ -n "$INSECURE" ]; then
    log "WARNING: PVE_ANSWER_INSECURE is set: no auth token, no TLS."
    log "Anyone who can reach this port can fetch every answer file."
    log "Use for local development only."

    unset PVE_ANSWER_TOKEN PVE_ANSWER_TOKEN_FILE

    skip=""
    for arg do
        shift
        if [ -n "$skip" ]; then
            skip=""
            continue
        fi
        case "$arg" in
            --cert|--key)     skip=1; continue ;;
            --cert=*|--key=*) continue ;;
        esac
        set -- "$@" "$arg"
    done
fi

# --- hand over -------------------------------------------------------------

exec setpriv --reuid="$APP_UID" --regid="$APP_GID" --clear-groups \
    python3 /app/server.py "$@"
