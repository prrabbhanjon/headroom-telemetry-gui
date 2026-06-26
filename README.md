# Headroom Telemetry GUI

> Live token savings dashboard for [Headroom AI](https://github.com/chopratejas/headroom) — deployed on Kubernetes via Podman Desktop.

[![Build and publish images](https://github.com/prrabbhanjon/headroom-telemetry-gui/actions/workflows/docker-publish.yml/badge.svg)](https://github.com/prrabbhanjon/headroom-telemetry-gui/actions/workflows/docker-publish.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![ghcr.io proxy](https://img.shields.io/badge/ghcr.io-headroom--proxy-teal)](https://ghcr.io/prrabbhanjon/headroom-proxy)
[![ghcr.io gui](https://img.shields.io/badge/ghcr.io-headroom--gui-orange)](https://ghcr.io/prrabbhanjon/headroom-gui)

---

## What is this?

Every time you run an AI agent, it pulls in log files, searches code, grabs context — and all of it goes into the LLM as a giant wall of text. You pay per token. Most of that text is boilerplate noise.

**Headroom** compresses everything before the model sees it. This project wraps Headroom in a full Kubernetes deployment with a live telemetry dashboard so you can see exactly how many tokens are being saved in real time.

**Two container images. One command to deploy.**

| Image | Purpose | Port |
|-------|---------|------|
| `headroom-proxy` | Headroom AI proxy — compresses LLM prompts | 8787 |
| `headroom-gui` | nginx dashboard — auto-refreshes token savings data every second | 80 |

---

## Architecture

```
Host machine
├── Browser          → localhost:3000   (live telemetry dashboard)
├── Claude Code      → localhost:8787   (ANTHROPIC_BASE_URL)
└── kubectl          → port-forward bridge

Podman Desktop (Kind cluster: headroom-api)
└── namespace: headroom
    ├── Pod: headroom-proxy   (headroom-ai[proxy] · port 8787)
    │   ├── Service: NodePort 30787
    │   └── Endpoints: /livez /readyz /health /stats /metrics
    ├── Pod: headroom-gui     (nginx · dashboard · port 80)
    │   └── Service: NodePort 30080
    └── ConfigMap: CORS · telemetry settings

            ↓ compressed API calls

    Anthropic API (api.anthropic.com · /v1/messages)
```

### How port-forward works

NodePort services are exposed on the Kind container's internal IP — not directly on the host. `kubectl port-forward` opens a local socket, intercepts TCP connections, and tunnels them through the Kubernetes API server into the pod:

- `localhost:3000` → `svc/headroom-gui:80` → nginx → serves dashboard
- `localhost:8787` → `svc/headroom-proxy:8787` → headroom-ai → Anthropic API

The dashboard's `/stats` polling happens pod-to-pod via `headroom-proxy:8787` internally — no CORS issues.

---

## Dashboard features

- Auto-refreshes every **1 second** — no manual refresh needed (like Zabbix)
- Adjustable refresh rate: 0.5s / 1s / 2s / 5s / 10s
- Pulsing live indicator + poll counter
- **Metrics**: tokens saved, savings rate, input tokens, request count, CCR entries, proxy latency
- **Charts**: tokens saved over time, savings % over time (Chart.js)
- **Pipeline latency**: p50 / p95 bars for input, forward, generation
- **CCR cache**: entries, retrievals, original vs compressed tokens, space saved
- **Live request log**: model, input tokens, tokens saved per request — new entries flash green
- Proxy stats pulled from `http://127.0.0.1:8787/stats`

---

## Prerequisites

| Tool | Install |
|------|---------|
| [Podman Desktop](https://podman-desktop.io) | Download and install — includes Kind + kubectl |
| Git | `brew install git` |
| Node.js | `brew install node` |
| Claude Code | `npm install -g @anthropic-ai/claude-code --ignore-scripts` |
| headroom-ai | `pipx install "headroom-ai[all]"` |

After installing Podman Desktop: **Settings → Kubernetes → Enable** and wait for the green dot.

---

## Step 1 — Clone the repo

```bash
git clone https://github.com/prrabbhanjon/headroom-telemetry-gui.git
cd headroom-telemetry-gui
chmod +x setup.sh
```

---

## Step 2 — Install (full setup from scratch)

```bash
./setup.sh install
```

This single command does everything:

1. Checks all dependencies (podman, kind, kubectl, curl, python3)
2. Auto-detects the Kind cluster name
3. Starts the Kind container if stopped (after Mac sleep/reboot)
4. Builds both images with Podman
5. Saves images as tarballs and loads them into Kind's image store
6. Applies all Kubernetes manifests
7. Patches deployments with local image names and `imagePullPolicy: Never`
8. Waits for both pods to be `1/1 Running`
9. Starts port-forwarding in background
10. Runs a 9-point health check
11. Opens the dashboard in your browser

---

## Step 3 — Route Claude Code through the proxy

```bash
./setup.sh claude
# or manually:
ANTHROPIC_BASE_URL=http://127.0.0.1:8787 claude
```

Use Claude Code normally. Token savings appear in the dashboard within seconds.

---

## Step 4 — View the dashboard

Open your browser at:

```
http://localhost:3000
```

Check proxy stats directly:

```bash
curl http://127.0.0.1:8787/stats | python3 -m json.tool
```

---

## All setup.sh commands

```bash
./setup.sh install    # full setup: build, load, deploy, forward, health, open browser
./setup.sh uninstall  # remove all K8s resources, stop forwards, optionally delete images
./setup.sh start      # start Kind container + port-forwards (use after every reboot)
./setup.sh health     # 9-point deep health check
./setup.sh status     # quick overview: pods, services, forwards, conflict check, stats
./setup.sh forward    # kill port conflicts, restart port-forwarding
./setup.sh stop       # stop all port-forwards
./setup.sh restart    # restart both deployments + re-forward
./setup.sh claude     # start Claude Code through proxy (auto-fixes connection)
./setup.sh logs       # show recent logs from both pods
./setup.sh open       # open dashboard in browser
./setup.sh help       # show all commands
```

---

## After every reboot

```bash
./setup.sh start
```

This auto-starts the Kind container (which stops when Mac sleeps or reboots) and restarts port-forwarding.

Optional — add to `~/.zshrc` for quick access:

```bash
alias headroom-start='cd ~/headroom-telemetry-gui && ./setup.sh start'
alias headroom-claude='cd ~/headroom-telemetry-gui && ./setup.sh claude'
alias headroom-health='cd ~/headroom-telemetry-gui && ./setup.sh health'
```

---

## Project structure

```
headroom-telemetry-gui/
├── .github/
│   └── workflows/
│       └── docker-publish.yml   # CI/CD: auto-builds and pushes on push to main + tags
├── proxy/
│   └── Dockerfile               # python:3.12-slim + headroom-ai[proxy]
├── gui/
│   ├── Dockerfile               # nginx:alpine + dashboard
│   ├── index.html               # auto-refresh telemetry dashboard (Chart.js)
│   └── nginx.conf               # serves GUI + proxies /api/ to headroom-proxy
├── k8s/
│   ├── namespace.yaml           # namespace: headroom
│   ├── configmap.yaml           # CORS, telemetry env vars
│   ├── proxy-deployment.yaml    # headroom-proxy pod
│   ├── proxy-service.yaml       # NodePort 30787
│   ├── gui-deployment.yaml      # headroom-gui pod
│   └── gui-service.yaml         # NodePort 30080
├── setup.sh                     # install · uninstall · start · health · claude · logs
└── README.md
```

---

## Kubernetes manifests explained

### namespace.yaml
Creates the `headroom` namespace to isolate all resources.

### configmap.yaml
Sets `HEADROOM_CORS_ORIGINS=*` and `HEADROOM_TELEMETRY=off` so the proxy accepts requests from the GUI pod and doesn't send telemetry.

### proxy-deployment.yaml
Deploys `headroom-proxy` with `imagePullPolicy: Never` (uses locally loaded image), readiness probe on `/livez`, and resource limits (256Mi–512Mi RAM, 250m–500m CPU).

### proxy-service.yaml
NodePort service mapping container port 8787 → node port 30787. Accessible via `kubectl port-forward` from the host.

### gui-deployment.yaml
Deploys `headroom-gui` (nginx serving the dashboard). Lightweight: 64Mi–128Mi RAM, 50m–100m CPU.

### gui-service.yaml
NodePort service mapping container port 80 → node port 30080.

---

## Pull pre-built images (no build needed)

```bash
podman pull ghcr.io/prrabbhanjon/headroom-proxy:latest
podman pull ghcr.io/prrabbhanjon/headroom-gui:latest

podman tag ghcr.io/prrabbhanjon/headroom-proxy:latest localhost/headroom-proxy:latest
podman tag ghcr.io/prrabbhanjon/headroom-gui:latest   localhost/headroom-gui:latest

kind load image-archive <(podman save localhost/headroom-proxy:latest) --name headroom-api
kind load image-archive <(podman save localhost/headroom-gui:latest)   --name headroom-api

kubectl apply -f k8s/
./setup.sh forward
```

---

## CI/CD — GitHub Actions

On every push to `main` or version tag (`v*.*.*`), GitHub Actions automatically:

1. Builds `headroom-proxy` from `./proxy/Dockerfile`
2. Builds `headroom-gui` from `./gui/Dockerfile`
3. Pushes both to `ghcr.io/prrabbhanjon/` with tags: `latest`, semver (`v1.0.0`), commit SHA

To publish a release:

```bash
git tag -a v1.0.0 -m "first stable release"
git push origin v1.0.0
```

Images appear at:
- `ghcr.io/prrabbhanjon/headroom-proxy:v1.0.0`
- `ghcr.io/prrabbhanjon/headroom-gui:v1.0.0`

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `ErrImageNeverPull` | `kind load image-archive` not run — see Step 2 |
| `ErrImagePull` | Set `imagePullPolicy: Never` and use `localhost/` image name |
| Port already in use (8787) | Local headroom proxy conflict — run `./setup.sh forward` to auto-kill it |
| Lost connection to pod | Pod restarted — run `./setup.sh forward` |
| Tokens saved = 0 | Claude Code not routed through proxy — run `./setup.sh claude` |
| Dashboard shows old content | Hard refresh: `Cmd+Shift+R` |
| Kind container stopped (Exited 137) | `./setup.sh start` auto-restarts it |
| `kind get clusters` empty | Run `./setup.sh start` or open Podman Desktop → Settings → Kubernetes |
| Port-forward drops after sleep | Run `./setup.sh forward` or add aliases to `~/.zshrc` |

---

## Health check

```bash
./setup.sh health
```

Runs 9 checks:

1. Kind container running
2. Kubernetes pods in `Running` state
3. Port conflict check on port 8787
4. kubectl port-forwards active
5. Proxy liveness `/livez`
6. Proxy readiness `/readyz`
7. Proxy health detail `/health` (version, uptime, all checks)
8. GUI reachable at `localhost:3000`
9. Proxy stats `/stats` (requests, tokens saved, savings %, CCR entries, latency)

---

## License

Apache 2.0 — see [LICENSE](LICENSE).

---

<sub>Built with Podman Desktop · Kind · Python · nginx · Chart.js · GitHub Actions</sub>
