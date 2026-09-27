#!/usr/bin/env bash
#
# Asserts the HTTP behaviour a Proxmox installer depends on.
#
#   docker build -t pve-answer:smoke .
#   tests/smoke.sh [image-tag]

set -euo pipefail

IMAGE="${1:-pve-answer:smoke}"
# 0 lets Docker pick a free port. Override with PORT=... to pin it.
PUBLISH_PORT="${PORT:-0}"
CONTAINER="pve-answer-smoke-$$"
WORKDIR="$(mktemp -d)"
FAILURES=0

# Files may be owned by another uid, so remove them from inside a container.
cleanup() {
    docker rm -f "$CONTAINER" "${CONTAINER}-notoken" "${CONTAINER}-nohost" \
        "${CONTAINER}-root" "${CONTAINER}-user" "${CONTAINER}-insecure" \
        >/dev/null 2>&1 || true
    docker volume rm "pve-answer-smoke-root-$$" >/dev/null 2>&1 || true
    docker run --rm --platform "$IMAGE_PLATFORM" --entrypoint sh \
        -v "$WORKDIR:/w" "$IMAGE" \
        -c 'rm -rf /w/answers /w/certs /w/secrets' >/dev/null 2>&1 || true
    rm -rf "$WORKDIR" 2>/dev/null || true
}
trap cleanup EXIT

check() {
    local name="$1" expected="$2" actual="$3"

    if [ "$expected" = "$actual" ]; then
        printf 'ok   %-42s %s\n' "$name" "$actual"
    else
        printf 'FAIL %-42s expected %s, got %s\n' "$name" "$expected" "$actual"
        FAILURES=$((FAILURES + 1))
    fi
}

# Set explicitly, so a cross-architecture image starts without a warning.
IMAGE_PLATFORM="$(docker image inspect "$IMAGE" --format '{{.Os}}/{{.Architecture}}')"

# Host side of each mount, laid out as compose.yaml expects.
mkdir -p "$WORKDIR/answers" "$WORKDIR/certs" "$WORKDIR/secrets"
TOKEN_FILE="$WORKDIR/secrets/pve_answer_token"

MOUNT_TOKEN=(-v "$TOKEN_FILE:/run/secrets/pve_answer_token:ro")
MOUNT_CERTS=(-v "$WORKDIR/certs:/etc/pve-answer/certs")
MOUNT_ANSWERS=(-v "$WORKDIR/answers:/answers:ro")
MOUNT_DEFAULT=(-v "$WORKDIR/default.toml:/default.toml:ro")

# Wait for a container to serve, and echo its base URL. Never a fixed sleep:
# under emulation the first start generates a 4096-bit key and is slow.
wait_ready() {
    local container="$1" scheme="${2:-https}" port base

    # The mapping is not always registered when `docker run -d` returns.
    for _ in $(seq 1 60); do
        port="$(docker port "$container" 8443/tcp 2>/dev/null | head -1 | sed 's/.*://')"

        [ -n "$port" ] && break

        sleep 0.5
    done

    if [ -z "$port" ]; then
        echo "no published port for $container" >&2
        docker logs "$container" >&2
        return 1
    fi

    base="$scheme://127.0.0.1:$port"

    for _ in $(seq 1 240); do
        if curl -sk -o /dev/null "$base/health"; then
            echo "$base"
            return 0
        fi
        sleep 0.5
    done

    echo "$container never became ready. Container log:" >&2
    docker logs "$container" >&2
    return 1
}

# Start the image. Arguments (mounts, env) go to docker run.
start_container() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true

    docker run -d --name "$CONTAINER" --platform "$IMAGE_PLATFORM" \
        -p "$PUBLISH_PORT:8443" \
        "$@" "$IMAGE" >/dev/null

    PORT="$(docker port "$CONTAINER" 8443/tcp | head -1 | sed 's/.*://')"

    if [ -z "$PORT" ]; then
        echo "FAIL could not determine the published port" >&2
        docker logs "$CONTAINER" >&2
        exit 1
    fi

    BASE="$(wait_ready "$CONTAINER")" || exit 1
}

# Run the image to completion and echo its exit code.
run_to_exit() {
    local name="$1"
    shift

    docker run --name "$name" --platform "$IMAGE_PLATFORM" \
        "$@" "$IMAGE" >/dev/null 2>&1 || true
    docker inspect "$name" --format '{{.State.ExitCode}}'
}

status() { curl -sk -o /dev/null -w '%{http_code}' "$@"; }

# `docker logs | grep -q` would SIGPIPE docker logs and trip pipefail.
logs_contain() {
    local container="$1" needle="$2" logs
    logs="$(docker logs "$container" 2>&1)"

    case "$logs" in
        *"$needle"*) echo yes ;;
        *)           echo no ;;
    esac
}
header() {
    curl -sk -D - -o /dev/null "$@" | tr -d '\r' \
        | awk -F': ' 'tolower($1)=="x-answer-match" {print $2}'
}
fingerprint() {
    docker logs "$1" 2>&1 | grep -oE '([0-9A-F]{2}:){31}[0-9A-F]{2}' | tail -1
}

KNOWN='{"network_interfaces":[{"mac":"bc:24:11:7b:51:aa"}]}'
UNKNOWN='{"network_interfaces":[{"mac":"00:11:22:33:44:55"}]}'

cat > "$WORKDIR/answers/bc-24-11-7b-51-aa.toml" <<'TOML'
[global]
keyboard = "se"
country = "sv"
fqdn = "smoke-test.example.com"
mailto = "admin@example.com"
timezone = "Europe/Stockholm"
root-password-hashed = "$y$j9T$smoke$test"

[network]
source = "from-dhcp"

[disk-setup]
filesystem = "ext4"
disk-list = ["sda"]
TOML

echo '# smoke default: no settings, so an unregistered machine is not installed' \
    > "$WORKDIR/default.toml"

printf 'smoke:%s' "$(openssl rand -hex 16)" > "$TOKEN_FILE"
TOKEN="$(cat "$TOKEN_FILE")"

# Readable by whichever uid the container settles on.
chmod 644 "$TOKEN_FILE"

# Scenario 1: everything already provisioned

echo "== pre-provisioned =="

openssl req -x509 -newkey rsa:2048 -sha256 -days 1 -nodes \
    -keyout "$WORKDIR/certs/server.key" \
    -out "$WORKDIR/certs/server.crt" \
    -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" 2>/dev/null

chmod 644 "$WORKDIR/certs/server.key"

start_container "${MOUNT_TOKEN[@]}" "${MOUNT_CERTS[@]}" \
    "${MOUNT_ANSWERS[@]}" "${MOUNT_DEFAULT[@]}"
echo "Testing '$IMAGE' on port $PORT"

check "GET /health" 200 "$(status "$BASE/health")"
check "GET /answer (POST expected)" 405 "$(status "$BASE/answer")"
check "GET / (debug off)" 404 "$(status "$BASE/")"

check "POST /answer without a token" 401 \
    "$(status -X POST "$BASE/answer" -d "$KNOWN")"
check "POST /answer with a wrong token" 401 \
    "$(status -X POST -H "Authorization: Bearer smoke:wrong" "$BASE/answer" -d "$KNOWN")"
check "POST /answer with a wrong scheme" 401 \
    "$(status -X POST -H "Authorization: Basic $TOKEN" "$BASE/answer" -d "$KNOWN")"

AUTH=(-H "Authorization: Bearer $TOKEN")

check "POST /answer, known MAC" 200 \
    "$(status -X POST "${AUTH[@]}" "$BASE/answer" -d "$KNOWN")"
check "POST /answer, unknown MAC" 200 \
    "$(status -X POST "${AUTH[@]}" "$BASE/answer" -d "$UNKNOWN")"

check "X-Answer-Match, known MAC" "bc-24-11-7b-51-aa" \
    "$(header -X POST "${AUTH[@]}" "$BASE/answer" -d "$KNOWN")"
check "X-Answer-Match, unknown MAC" "none" \
    "$(header -X POST "${AUTH[@]}" "$BASE/answer" -d "$UNKNOWN")"

check "known MAC serves its answer file" "yes" \
    "$(curl -sk -X POST "${AUTH[@]}" "$BASE/answer" -d "$KNOWN" \
        | grep -q 'smoke-test.example.com' && echo yes || echo no)"
check "unknown MAC serves the mounted default" "yes" \
    "$(curl -sk -X POST "${AUTH[@]}" "$BASE/answer" -d "$UNKNOWN" \
        | grep -q 'smoke default' && echo yes || echo no)"

check "TLS is enforced (plain HTTP is refused)" "yes" \
    "$(curl -s -o /dev/null "http://127.0.0.1:$PORT/health" && echo no || echo yes)"

check "existing certificate is not replaced" "no" \
    "$(logs_contain "$CONTAINER" 'generating a self-signed')"
RUNTIME_UID="$(docker exec "$CONTAINER" awk '/^Uid:/ {print $2}' /proc/1/status)"

check "server does not run as root" "yes" \
    "$([ "$RUNTIME_UID" != "0" ] && echo yes || echo no)"
DIR_OWNER="$(docker exec "$CONTAINER" stat -c '%u' /etc/pve-answer/certs)"

check "runs as the certs dir owner, or falls back when it is root" "yes" \
    "$([ "$RUNTIME_UID" = "$DIR_OWNER" ] \
        || { [ "$DIR_OWNER" = "0" ] && [ "$RUNTIME_UID" = "10001" ]; } \
        && echo yes || echo no)"

# Scenario 2: refusals, against an empty certs directory

echo
echo "== refusals =="

docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run --rm --platform "$IMAGE_PLATFORM" --entrypoint sh \
    -v "$WORKDIR:/w" "$IMAGE" -c 'rm -rf /w/certs/*' >/dev/null 2>&1 || true

check "refuses to start without a token" "1" \
    "$(run_to_exit "${CONTAINER}-notoken" -e PVE_ANSWER_HOSTNAMES=127.0.0.1 \
        "${MOUNT_CERTS[@]}")"
check "and says why" "yes" \
    "$(logs_contain "${CONTAINER}-notoken" 'no auth token')"
docker rm -f "${CONTAINER}-notoken" >/dev/null 2>&1 || true

# Must refuse to start with no address for the certificate's SAN.
check "refuses to start without PVE_ANSWER_HOSTNAMES" "1" \
    "$(run_to_exit "${CONTAINER}-nohost" "${MOUNT_TOKEN[@]}" "${MOUNT_CERTS[@]}")"
check "and says why" "yes" \
    "$(logs_contain "${CONTAINER}-nohost" 'PVE_ANSWER_HOSTNAMES')"
docker rm -f "${CONTAINER}-nohost" >/dev/null 2>&1 || true

check "and leaves no partial state behind" "yes" \
    "$([ -e "$WORKDIR/certs/server.key" ] && echo no || echo yes)"

# Scenario 3: first run, empty certs directory, the image's default answer

echo
echo "== first run, empty certs directory =="

start_container -e PVE_ANSWER_HOSTNAMES=127.0.0.1,localhost \
    "${MOUNT_TOKEN[@]}" "${MOUNT_CERTS[@]}" "${MOUNT_ANSWERS[@]}"

check "generated a certificate" "yes" \
    "$(docker exec "$CONTAINER" test -f /etc/pve-answer/certs/server.crt \
        && echo yes || echo no)"
check "generated a private key" "yes" \
    "$(docker exec "$CONTAINER" test -f /etc/pve-answer/certs/server.key \
        && echo yes || echo no)"
check "logged the certificate fingerprint" "yes" \
    "$([ -n "$(fingerprint "$CONTAINER")" ] && echo yes || echo no)"

RUNTIME_UID="$(docker exec "$CONTAINER" awk '/^Uid:/ {print $2}' /proc/1/status)"

check "generated key owned by the runtime uid" "$RUNTIME_UID" \
    "$(docker exec "$CONTAINER" stat -c '%u' /etc/pve-answer/certs/server.key)"
check "generated files are not root-owned" "yes" \
    "$([ "$(docker exec "$CONTAINER" stat -c '%u' /etc/pve-answer/certs/server.key)" != "0" ] \
        && echo yes || echo no)"

check "generated certificate carries the right SAN" "yes" \
    "$(echo | openssl s_client -connect "127.0.0.1:$PORT" 2>/dev/null \
        | openssl x509 -noout -text 2>/dev/null \
        | grep -q 'IP Address:127.0.0.1' && echo yes || echo no)"

check "serves with the mounted token" 200 \
    "$(status -X POST "${AUTH[@]}" "$BASE/answer" -d "$UNKNOWN")"
check "still rejects a request without it" 401 \
    "$(status -X POST "$BASE/answer" -d "$UNKNOWN")"
check "image default installs nothing" "yes" \
    "$(curl -sk -X POST "${AUTH[@]}" "$BASE/answer" -d "$UNKNOWN" \
        | grep -q '^\[' && echo no || echo yes)"
check "image default is the shipped one" "yes" \
    "$(curl -sk -X POST "${AUTH[@]}" "$BASE/answer" -d "$UNKNOWN" \
        | grep -q 'No answer file matched' && echo yes || echo no)"

# A restart must not invalidate what the first run generated.
FIRST_FINGERPRINT="$(fingerprint "$CONTAINER")"
LOG_LINES_BEFORE_RESTART="$(docker logs "$CONTAINER" 2>&1 | wc -l | tr -d ' ')"
docker restart "$CONTAINER" >/dev/null

# An ephemeral port is reassigned on restart.
PORT="$(docker port "$CONTAINER" 8443/tcp | head -1 | sed 's/.*://')"
BASE="https://127.0.0.1:$PORT"

for _ in $(seq 1 180); do
    curl -sk -o /dev/null "$BASE/health" && break
    sleep 0.5
done

check "serves again after restart" 200 "$(status "$BASE/health")"

check "restart keeps the same certificate" "$FIRST_FINGERPRINT" \
    "$(fingerprint "$CONTAINER")"
check "restart regenerates nothing" "0" \
    "$(docker logs "$CONTAINER" 2>&1 \
        | tail -n "+$((LOG_LINES_BEFORE_RESTART + 1))" \
        | grep -c 'generating a self-signed' || true)"

# Scenario 4: token from the environment instead of a secret

echo
echo "== token from PVE_ANSWER_TOKEN =="

start_container -e "PVE_ANSWER_TOKEN=$TOKEN" "${MOUNT_CERTS[@]}"

check "serves with the environment token" 200 \
    "$(status -X POST "${AUTH[@]}" "$BASE/answer" -d "$UNKNOWN")"
check "and rejects a request without it" 401 \
    "$(status -X POST "$BASE/answer" -d "$UNKNOWN")"

docker rm -f "$CONTAINER" >/dev/null 2>&1 || true

# Scenario 5: root-owned certs directory falls back to the image user

echo
echo "== root-owned certs directory =="

# A fresh named volume is root-owned: the case that must fall back.
ROOT_VOLUME="pve-answer-smoke-root-$$"
docker volume create "$ROOT_VOLUME" >/dev/null

docker run -d --name "${CONTAINER}-root" --platform "$IMAGE_PLATFORM" -p 0:8443 \
    -e PVE_ANSWER_HOSTNAMES=127.0.0.1 \
    "${MOUNT_TOKEN[@]}" \
    -v "$ROOT_VOLUME:/etc/pve-answer/certs" \
    "$IMAGE" >/dev/null

ROOT_BASE="$(wait_ready "${CONTAINER}-root")" || exit 1

check "warns about the root-owned directory" "yes" \
    "$(logs_contain "${CONTAINER}-root" 'owned by root')"
check "falls back to the image user, not root" "10001" \
    "$(docker exec "${CONTAINER}-root" awk '/^Uid:/ {print $2}' /proc/1/status 2>/dev/null \
        || echo unavailable)"
check "and serves" 200 "$(status "$ROOT_BASE/health")"

docker rm -f "${CONTAINER}-root" >/dev/null 2>&1 || true

# Scenario 6: certs directory owned by a real user
# Docker Desktop reports bind mounts as root-owned, so a chowned volume is used
# to exercise the derivation that matters on Linux.

echo
echo "== certs directory owned by uid 4242 =="

docker run --rm --platform "$IMAGE_PLATFORM" --entrypoint sh \
    -v "$ROOT_VOLUME:/etc/pve-answer/certs" "$IMAGE" \
    -c 'rm -f /etc/pve-answer/certs/* && chown 4242:4242 /etc/pve-answer/certs' \
    >/dev/null

docker run -d --name "${CONTAINER}-user" --platform "$IMAGE_PLATFORM" -p 0:8443 \
    -e PVE_ANSWER_HOSTNAMES=127.0.0.1 \
    "${MOUNT_TOKEN[@]}" \
    -v "$ROOT_VOLUME:/etc/pve-answer/certs" \
    "$IMAGE" >/dev/null

USER_BASE="$(wait_ready "${CONTAINER}-user")" || exit 1

check "runs as the directory owner" "4242" \
    "$(docker exec "${CONTAINER}-user" awk '/^Uid:/ {print $2}' /proc/1/status \
        2>/dev/null || echo unavailable)"
check "no root-owned warning" "no" \
    "$(logs_contain "${CONTAINER}-user" 'owned by root')"
check "generated key owned by that uid" "4242" \
    "$(docker exec "${CONTAINER}-user" stat -c '%u' /etc/pve-answer/certs/server.key \
        2>/dev/null || echo unavailable)"

check "and still serves" 200 "$(status "$USER_BASE/health")"

docker rm -f "${CONTAINER}-user" >/dev/null 2>&1 || true
docker volume rm "$ROOT_VOLUME" >/dev/null 2>&1 || true

# Scenario 7: insecure mode, nothing mounted

echo
echo "== insecure mode =="

docker run -d --name "${CONTAINER}-insecure" --platform "$IMAGE_PLATFORM" -p 0:8443 \
    -e PVE_ANSWER_INSECURE=1 \
    "$IMAGE" >/dev/null

INSECURE_BASE="$(wait_ready "${CONTAINER}-insecure" http)" || exit 1

check "serves plain HTTP" 200 "$(status "$INSECURE_BASE/health")"
check "POST /answer needs no token" 200 \
    "$(status -X POST "$INSECURE_BASE/answer" -d "$UNKNOWN")"
check "warns that it is insecure" "yes" \
    "$(logs_contain "${CONTAINER}-insecure" 'PVE_ANSWER_INSECURE is set')"
check "passes no --cert to the server" "no" \
    "$(docker exec "${CONTAINER}-insecure" cat /proc/1/cmdline | tr '\0' ' ' \
        | grep -q -- '--cert' && echo yes || echo no)"
check "generates no certificate" "no" \
    "$(docker exec "${CONTAINER}-insecure" test -e /etc/pve-answer/certs/server.crt \
        && echo yes || echo no)"

docker rm -f "${CONTAINER}-insecure" >/dev/null 2>&1 || true


echo
if [ "$FAILURES" -gt 0 ]; then
    echo "$FAILURES check(s) failed. Container log:" >&2
    docker logs "$CONTAINER" >&2 || true
    exit 1
fi

echo "All smoke checks passed against '$IMAGE'."
