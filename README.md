# proxmox-auto-install-assistant

Serves Proxmox VE installers an answer file over HTTPS, picked per machine by
MAC address.

Everything runs on **one machine, the answer server** — it serves the answer
files and prepares the ISO. No Proxmox host is involved until you boot it.

The installer POSTs its hardware info to `/answer`. The server returns
`answers/<mac>.toml` for a matching NIC, or `default.toml` if none matches.

The answer server must run **Debian or Ubuntu** — setup uses `apt`, and
`proxmox-auto-install-assistant` is published as a `.deb`.

Two ways to set it up, with the same result:

- **Ansible** — from your workstation against the answer server over SSH, or on
  the answer server itself with Ansible installed and `ansible_connection=local`
  in the inventory.
- **Manual** — the commands below, run on the answer server.

Two directories on the answer server, the same either way:

| Path | |
| --- | --- |
| `/opt/pve-answer` | `compose.yaml` and the files below |
| `/opt/iso-builder` | the source ISO and the prepared one |

Inside `/opt/pve-answer`, each mounted into the container:

| Host | Container | |
| --- | --- | --- |
| `certs/` | `/etc/pve-answer/certs/` | TLS certificate and key, generated on first run |
| `secrets/pve_answer_token` | `/run/secrets/pve_answer_token` | auth token, a compose secret |
| `answers/` | `/answers/` | per-MAC answer files, read-only |
| `default.toml` | `/default.toml` | served when no MAC matches, read-only |

Secrets never sit next to the answer files, and the container only writes to
`certs/`. Every host path can be moved; see `compose.yaml` or the Ansible
variables.

---

## Quickstart: Ansible

```bash
git clone https://github.com/PerVenT/pve-answer.git
cd pve-answer/ansible

cp hosts.example hosts
# Update `hosts` and `group_vars/answer_server.yml` with your values:

ansible-playbook site.yaml
```

That installs Docker and the assistant, starts the answer server, downloads the
ISO and prepares it. Re-running changes nothing.

The answer server needs your per-MAC files in `/opt/pve-answer/answers/` —
Ansible creates the directory but never writes into it. It also creates the
token and `default.toml` if missing, and never replaces them.

---

## Quickstart: manual

Same result, by hand. Everything below happens on the answer server.

### 1. Install Docker and the assistant

Docker from [its own repository](https://docs.docker.com/engine/install/), then
the assistant. It is published for Debian suites only, so on Ubuntu install the
`.deb` directly:

```bash
V=9.2.8
curl -fsSLO "http://download.proxmox.com/debian/pve/dists/trixie/pve-no-subscription/binary-amd64/proxmox-auto-install-assistant_${V}_amd64.deb"
apt install ./proxmox-auto-install-assistant_${V}_amd64.deb
```

On Debian, add the `pve-no-subscription` repository and `apt install proxmox-auto-install-assistant` as well, but the `.deb` is simpler and works on Ubuntu too.

### 2. Start the answer server

```bash
git clone https://github.com/PerVenT/pve-answer.git
cd pve-answer

mkdir -p /opt/pve-answer /opt/iso-builder
cp compose.yaml default.toml /opt/pve-answer/

cd /opt/pve-answer
mkdir -p answers certs secrets
chown 10001:10001 certs            # the container runs as this uid
chmod 700 certs secrets

# The token is created here, never by the container.
printf 'provisioning:%s' "$(openssl rand -hex 32)" > secrets/pve_answer_token
chown 10001:10001 secrets/pve_answer_token
chmod 400 secrets/pve_answer_token

export PVE_ANSWER_HOSTNAMES=10.100.9.150,pve-answer.example.com
docker compose up -d
docker compose logs
```

`PVE_ANSWER_HOSTNAMES` is every address the installer may use to reach this
server; they become the certificate's SAN entries, which the installer
validates. The first start generates the certificate, and the log prints its
fingerprint:

```text
entrypoint: certificate SHA-256 fingerprint (pass to prepare-iso --cert-fingerprint):
entrypoint:   AB:CD:EF:...
```

Nothing is overwritten, so `PVE_ANSWER_HOSTNAMES` is only needed the first
time. The container refuses to start without the token, or without a
certificate and that variable.

Docker Compose ignores `uid`, `gid` and `mode` on file secrets, so the token
file's own owner and mode on the host are what the container sees.

Check it:

```bash
curl --cacert /opt/pve-answer/certs/server.crt https://10.100.9.150/health
# should print "ok"

curl --cacert /opt/pve-answer/certs/server.crt -X POST https://10.100.9.150/answer \
    -H "Authorization: Bearer $(cat /opt/pve-answer/secrets/pve_answer_token)" \
    -d '{"network_interfaces":[{"mac":"bc:24:11:7b:51:aa"}]}'
```

### 3. Prepare the ISO

```bash
cd /opt/iso-builder
wget https://enterprise.proxmox.com/iso/proxmox-ve_9.2-1.iso

CERT_FINGERPRINT="$(cat /opt/pve-answer/certs/server.crt | openssl x509 -fingerprint -sha256 -noout | cut -d= -f2)"
AUTH_TOKEN="$(cat /opt/pve-answer/secrets/pve_answer_token)"
proxmox-auto-install-assistant prepare-iso proxmox-ve_9.2-1.iso \
    --fetch-from http \
    --url "https://10.100.9.150/answer" \
    --cert-fingerprint "${CERT_FINGERPRINT}" \
    --answer-auth-token "${AUTH_TOKEN}"
```

Both values come from step 2. Without the fingerprint the installer rejects the
certificate; without the token it gets `401`.

Boot a machine from the resulting `*-auto-from-http.iso`.

**The token sits in plain text inside the ISO**, so it identifies the ISO, not
a machine. If one leaks, regenerate `secrets/pve_answer_token`, restart,
rebuild the ISOs.

---

## Answer files

One file per machine in `/opt/pve-answer/answers/`, named after the MAC
it installs from. Separators don't matter: `bc-24-11-7b-51-aa.toml`,
`bc:24:11:7b:51:aa.toml` and `BC24117B51AA.toml` all match the same NIC.

```toml
# /opt/pve-answer/answers/bc-24-11-7b-51-aa.toml
[global]
keyboard = "se"
country = "sv"
fqdn = "test-pve.example.com"
mailto = "admin@example.com"
timezone = "Europe/Stockholm"
root-password-hashed = "$y$j9T$..."

[network]
source = "from-answer"
cidr = "10.100.9.71/24"
dns = "10.100.9.10"
gateway = "10.100.9.1"
filter.ID_NET_NAME_MAC = "*bc24117b51aa"

[disk-setup]
filesystem = "ext4"
lvm.swapsize = 8
disk-list = ['sda']
```

`default.toml` is served when no MAC matches. The one in this repository, also
baked into the image, has no install settings, so an unregistered machine is
not installed.

Field reference: [Answer File Format](https://pve.proxmox.com/wiki/Automated_Installation#Answer_File_Format).
Validate with `proxmox-auto-install-assistant validate-answer <file>`.

---

## Reference

### Notes

- `server.py` lives in the image: `docker compose pull && docker compose up -d`
  for a published build, `compose.dev.yaml` with `--build` for local edits.
  Answer files, certificates and the token are mounted and need no rebuild.
- The server runs as whoever owns `certs/`, so generated files need no `sudo`.
- Pulling needs the GHCR package public, or `docker login ghcr.io` on the host.

### Endpoints

| Method | Path | Response |
| --- | --- | --- |
| `POST` | `/answer` | the answer file, or `401` without a valid token |
| `GET` | `/health` | `ok` |
| `GET` | `/answer` | `405` — a POST is expected |
| `GET` | `/` | status page in debug mode, otherwise `404` |

`POST /answer` sets `X-Answer-Match` to the file that matched, or `none` on
fallback, and a no-match logs a `WARNING` naming the MACs.

### Debug mode

`GET /` shows whether TLS and auth are on and which MACs have answer files,
never file contents. **Off by default** — uncomment `PVE_ANSWER_DEBUG=1` in
[`compose.yaml`](compose.yaml).

### Flags

`compose.yaml` sets these through environment variables; `server.py` also takes
them directly.

| Flag | Env | Default |
| --- | --- | --- |
| `--host` | — | `0.0.0.0` |
| `--port` | — | `8443` |
| `--cert` / `--key` | — | none, serves plain HTTP |
| `--answers-dir` | — | `answers` |
| `--default-answer` | — | `default.toml` |
| `--auth-token-file` | `PVE_ANSWER_TOKEN_FILE`, `PVE_ANSWER_TOKEN` | none, endpoint open |
| `--debug` | `PVE_ANSWER_DEBUG` | off |

Run directly, without a certificate or token the server still starts, warning
that it serves plain HTTP or an open endpoint. The image sets
`PVE_ANSWER_TOKEN_FILE=/run/secrets/pve_answer_token`, and its entrypoint
refuses to start without a token unless insecure mode is on.

### Insecure mode (development)

`PVE_ANSWER_INSECURE=1` skips the token and certificate, drops `--cert`/`--key`
and any token configuration, and serves an open endpoint over plain HTTP.
`compose.dev.yaml` sets it, builds from the checkout and needs no `certs/` or
`secrets/`:

```sh
docker compose -f compose.dev.yaml up -d --build
curl http://localhost:444/health
```

Never set it on a server the installer can reach.

### CI

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs on push and PR to
`main`, weekly, and on demand. It tests, builds `amd64` and `arm64`, smoke
tests each, then publishes a multi-platform manifest as `latest` and
`sha-<short>` pointing at the exact images that passed. PRs do not publish.

```bash
pip install -r requirements_ci.txt
pytest

docker build -t pve-answer:smoke .
tests/smoke.sh pve-answer:smoke
```
