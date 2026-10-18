# CI-Hub deploy: `core/lib/ci-hub.sh`

> **Private & Confidential. Property of Lifescope Inc. Do not distribute.**

`core/lib/ci-hub.sh` is the only way the CI Hub Service gets onto an appliance. It is a Docker Compose deploy of the `ci-os-hub` container
and its database, queue and reverse proxy, pulled from a private registry. It takes secrets, publishes ports on every interface and has no
other documentation, so this page is its runbook. Everything below was read from `core/lib/ci-hub.sh`, `core/lib/generate-tunnel-certs.sh`
and `pull-dev-manual.sh` (**[V]** for what the code does); none of it was run for this page, so what happens on a real registry is **[N]**.
The name is historical (the script was `pull-dev.sh`); the architecture note on the three things called "Hub" is in
[`multi-distro-design.md`](../architecture/multi-distro-design.md#8-naming-three-things-called-hub).

No credential value appears on this page, and none may be added to it.

## Who runs it

| Caller | When | Result without credentials |
|---|---|---|
| Ubuntu `deploy_ci_hub()` in `backends/ubuntu/provision/provision.sh` (tier `core`, so at first boot) | every provisioning run, if Docker is installed | the script prints "CI-Hub not deployed" and **exits 0**; provisioning continues and reports success |
| Arch `provision.sh` (the engine under CachyOS, `--step=ci-hub`), run by the CachyOS first-boot wrapper | first boot | the same message and exit 0. The ISO #4, #5 and #6 first boots skipped the deploy this way **[V]** (`cachyos-backend.md`) |
| `pull-dev-manual.sh` at the repository root | by hand | a thin wrapper that exports `DEVICE_ID`, `API_KEY` and `TUNNEL_TOKEN` and runs `core/lib/ci-hub.sh`; it refuses to run without `DEVICE_ID` and `API_KEY` |

So a machine can finish first boot "successfully" with no Hub on it. The check is whether the container exists (below).

## Inputs

| Variable | Needed | Meaning | Default |
|---|---|---|---|
| `REGISTRY_USERNAME`, `REGISTRY_PASSWORD` | yes | login for `portal.companionintelligence.com`; without both the script stops with exit 0 | none; no fallback exists on purpose (a shared default was a checked-in credential) |
| `DEVICE_ID` | no | the device's identity in the Hub | the DMI serial from `sudo dmidecode -s system-serial-number`, else `staging-<hostname>-<epoch>` |
| `API_KEY` | no | copied to `CI_CLOUD_API_KEY` unless that is already set | empty: the deploy proceeds without device pairing |
| `TUNNEL_TOKEN` | no | enables the Cloudflare tunnel profile | unset: the `tunnel` profile does not run |
| `CI_CLOUD_URL`, `CI_CLOUD_API_URL`, `CI_CLOUD_FRONTEND_URL` | no | the cloud endpoints written into the Hub's `.env` | `https://portal.companionintelligence.com` and its `/api` |
| `CI_OS_HUB_REPO_PATH` | no | a sibling checkout whose `.env.dev` supplies the registry login | `<workspace parent>/CI-OS-Hub` |

If `REGISTRY_USERNAME` or `REGISTRY_PASSWORD` is unset, the script looks, in this order, for `$CI_OS_HUB_REPO_PATH/.env.dev`,
`<workspace parent>/CI-Cloud/apps/hono-app/.env.dev` and `<workspace parent>/CI-Cloud/apps/hono-app/.env`, and **sources the first that exists**
(`set -a`). That is for a developer's workspace; on an appliance the variables must come from the environment.

### Supplying secrets without putting them in the process list

`pull-dev-manual.sh -d ID -k KEY -t TOKEN` works, but a value on the command line is visible to every user in `ps` and stays in shell history.
Read the secrets into the environment instead:

```bash
read -rsp 'Registry user: '     REGISTRY_USERNAME; echo; export REGISTRY_USERNAME
read -rsp 'Registry password: ' REGISTRY_PASSWORD; echo; export REGISTRY_PASSWORD
read -rsp 'API key: '           API_KEY;           echo; export API_KEY
read -rp  'Device id: '         DEVICE_ID;         export DEVICE_ID
./pull-dev-manual.sh                      # add: read -rsp 'Tunnel token: ' TUNNEL_TOKEN; export TUNNEL_TOKEN   to enable the tunnel
```

## What it creates

Everything is under `$HOME/ci-os-hub-staging` of the user who runs it (`INSTALL_DIR`; there is no flag to change it).

| Path | Content |
|---|---|
| `.env` | the Hub's configuration, including `JWT_SECRET`, `CI_CLOUD_API_KEY` and `DEVICE_ID`. The previous file is copied to `.env.bak` first, and `JWT_SECRET` is **reused** from it, so a re-run does not log everyone out; a first install gets `openssl rand -hex 32`. **The script never sets a mode on `.env`** (it is created with your umask) |
| `docker-compose.yml` | five services, below |
| `data/state/traefik/config/traefik.yml`, `dynamic/dynamic.yml`, `acme_storage.json` (mode 0600), `tls/` | the reverse proxy's configuration |
| `data/{media,repos,apps,logs,user-config,backups}`, `app-data/` | the Hub's data directories |
| `tunnel/token` (mode 0600), `tunnel/certs/custom-ca.pem`, `tunnel/config.yml` | only when `TUNNEL_TOKEN` is set |
| `~/.docker/config.json` | an `auths` entry for the registry with the credentials as base64, and **`credsStore` deleted** so that the plain entry is used (the script says it bypasses a registry 404). Needs `jq` |

| Service | Image | Published ports |
|---|---|---|
| `ci-hub-db` | `postgres:14` | 6543 |
| `ci-os-hub-queue` | `rabbitmq:4-alpine` | 5001 (to 5672) |
| `ci-os-hub` | `portal.companionintelligence.com/ci-os-hub:latest` | 5002 (to 3000) |
| `traefik` | `traefik:v3.6.7`, with `/var/run/docker.sock` mounted read-only | 18080 (80), 18443 (443), 18081 (8080, the dashboard; `api.insecure: true`) |
| `cloudflared` (profile `tunnel`) | `cloudflare/cloudflared:latest`, `tunnel run --token-file` | none |

The sequence is: check `docker` and `docker compose`; create the directories; write the tunnel token and certificate directory if there is a
token; log in to the registry; write the Traefik configuration, `.env` and `docker-compose.yml`; `docker compose pull` (a failed pull is exit 1);
`docker compose down --remove-orphans` and `up -d`. A re-run therefore **restarts the whole stack**; the database volume `ci_hub_pgdata`
survives.

## Confirm it worked

```bash
cd ~/ci-os-hub-staging && docker compose ps          # ci-os-hub, ci-hub-db, ci-os-hub-queue and traefik should be Up
docker ps --filter name=ci-os-hub --format '{{.Names}} {{.Status}}'
curl -fsS -o /dev/null -w '%{http_code}\n' http://localhost:5002/     # the Hub UI answers on 5002
```

The script ends by printing `Hub UI: http://localhost:5002`. On a machine where the deploy was skipped, none of these containers exists and
the first-boot log (`journalctl -u ci-os-first-boot-setup`) should hold the line "CI-Hub not deployed" **[I]**.

## Tear it down

```bash
cd ~/ci-os-hub-staging && docker compose --profile tunnel down          # stops and removes the containers, keeps the data
cd ~/ci-os-hub-staging && docker compose --profile tunnel down -v       # also deletes the database volume: the Hub's data is gone
docker logout portal.companionintelligence.com                           # removes the registry credential from ~/.docker/config.json
shred -u ~/ci-os-hub-staging/.env ~/ci-os-hub-staging/.env.bak          # the secrets (shred is best effort on journaling and copy-on-write filesystems)
```

## Security notes (read before running it on a machine that is on a network you do not control)

1. **Registry credentials are stored in `~/.docker/config.json` in base64** (not encrypted), and any process of that user can read them.
2. **`.env` has `JWT_SECRET`, the API key and fixed default credentials for the database and the queue, and is created with your umask.**
   Run `chmod 600 ~/ci-os-hub-staging/.env ~/ci-os-hub-staging/.env.bak` after the first deploy. The repository review of 2026-10-12 found a
   deployed Hub keeping a leaked `JWT_SECRET` in its `.env` (KI-05, finding M7).
3. **Five ports are published on all interfaces**: the database (6543), the queue (5001), the Hub (5002) and Traefik with its dashboard
   (18080, 18443, 18081). Neither edition installs a host firewall (`cachyos-backend.md`, risk R7b), so they are reachable from the LAN. The
   database and the queue use the script's fixed defaults, not secrets of the device.
4. **Traefik has the Docker socket.** A read-only mount of the socket still allows API calls that can start containers.
5. **Three images are not pinned by digest** (`postgres:14`, `rabbitmq:4-alpine`, `cloudflare/cloudflared:latest`), and the Hub image is `latest`.
6. `sudo dmidecode` runs when `DEVICE_ID` is not set, so a manual run may ask for your password.
7. `pull-dev-manual.sh -k` and `-t` put an API key and a tunnel token in the process list (see above).

## The tunnel certificate

When `TUNNEL_TOKEN` is set, `core/lib/generate-tunnel-certs.sh` writes one fixed, self-signed certificate into `tunnel/certs/custom-ca.pem` and
touches `tunnel/config.yml`. The certificate is embedded in the script and is the same on every deployment **[V]**: read with `openssl x509`,
subject `C=US, ST=State, L=City, O=CompanionIntelligence, OU=LocalDev, CN=CI-Local-Root-CA`, issued by itself, valid from 2026-01-13 to
2036-01-11, SHA-256 fingerprint `31:0E:04:F8:62:69:68:D3:A8:29:CF:7B:C1:5A:AB:38:09:B8:8E:3C:05:05:D8:62:D2:3C:81:12:9E:19:B8:38`.

What is **not** stated anywhere in this repository **[N]**: who holds the private key of that CA, what it is used to sign, and whether anything
trusts it. Nothing else in the tree reads `custom-ca.pem` (a search of `core/`, `backends/` and `pull-dev-manual.sh` finds only the writer), and
the compose file mounts the `tunnel/` directory read-only into the `cloudflared` container without naming the file. The name `LocalDev` and the
country/state/city placeholders suggest a development certificate, which is a guess **[I]**. Treat it as untrusted until the owner says what it
is, and do not add it to a system trust store. The open question is recorded as KI-22 in
[`known-issues-and-decisions.md`](../architecture/known-issues-and-decisions.md).

## Related

* [`multi-distro-design.md`](../architecture/multi-distro-design.md): why the script lives in `core/`.
* [`cachyos-backend.md`](../architecture/cachyos-backend.md): the endpoint table lists the registry and cloud hosts.
* [`headless-setup.md`](../architecture/headless-setup.md): the pairing flow of the setup portal.

© Companion Intelligence, Lifescope Inc
