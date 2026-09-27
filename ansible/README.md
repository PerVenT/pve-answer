# Ansible

Everything runs on the answer server; the Proxmox host is not involved.

```bash
ansible-playbook site.yaml            # both of the below

ansible-playbook answer-server.yaml   # install, start, print token + fingerprint
ansible-playbook prepare-iso.yaml     # download the ISO and bake those in
```

All are idempotent.

| File | |
| --- | --- |
| `site.yaml` | both playbooks in order |
| `hosts` | the answer server |
| `group_vars/answer_server.yml` | image, paths, ISO URL, assistant version |
| `answer-server.yaml` | Docker, the assistant, the container |
| `prepare-iso.yaml` | ISO download and `prepare-iso` |

Host paths are variables in `group_vars/answer_server.yml`, all under
`pve_answer_dir` by default:

| Variable | Default | Mounted at |
| --- | --- | --- |
| `pve_answer_certs_dir` | `certs/` | `/etc/pve-answer/certs` |
| `pve_answer_token_file` | `secrets/pve_answer_token` | `/run/secrets/pve_answer_token` |
| `pve_answer_answers_dir` | `answers/` | `/answers` |
| `pve_answer_default_answer` | `default.toml` | `/default.toml` |

The token and `default.toml` are created only if missing. `answers/` is created
but never written to — per-MAC files are yours.

`websrv_health_check: false` prepares an ISO on a host not running the answer
server. The token and fingerprint are then used only if their files exist;
without them the ISO carries neither, and the installer must get them from
DHCP option 250/251 or a DNS TXT record.
