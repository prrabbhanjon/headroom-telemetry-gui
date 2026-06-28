# Headroom Telemetry GUI

> Live token savings dashboard for [Headroom AI](https://github.com/chopratejas/headroom) — deployed on Kubernetes via Podman Desktop.

[![Build and publish images](https://github.com/prrabbhanjon/headroom-telemetry-gui/actions/workflows/docker-publish.yml/badge.svg)](https://github.com/prrabbhanjon/headroom-telemetry-gui/actions/workflows/docker-publish.yml)
![Repo views](https://komarev.com/ghpvc/?username=prrabbhanjon&color=brightgreen&style=flat&label=Repo+views)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![ghcr.io proxy](https://img.shields.io/badge/ghcr.io-headroom--proxy-teal)](https://ghcr.io/prrabbhanjon/headroom-proxy)
[![ghcr.io gui](https://img.shields.io/badge/ghcr.io-headroom--gui-orange)](https://ghcr.io/prrabbhanjon/headroom-gui)
[![Feedback welcome](https://img.shields.io/badge/feedback-welcome-brightgreen)](https://github.com/prrabbhanjon/headroom-telemetry-gui/issues/new?template=feedback.md&title=%5BFeedback%5D+)
[![Ask a question](https://img.shields.io/badge/questions-open%20an%20issue-blue)](https://github.com/prrabbhanjon/headroom-telemetry-gui/issues/new?template=question.md&title=%5BQuestion%5D+)

---

## 💬 Feedback & Comments

**Found this useful? Have ideas? Share your thoughts!**

| | |
|---|---|
| 💡 **Feature idea** | [Open a feature request](https://github.com/prrabbhanjon/headroom-telemetry-gui/issues/new?labels=enhancement&template=feature_request.md&title=%5BFeature%5D+) |
| 🐛 **Found a bug** | [Report a bug](https://github.com/prrabbhanjon/headroom-telemetry-gui/issues/new?labels=bug&template=bug_report.md&title=%5BBug%5D+) |
| 💬 **General feedback** | [Leave feedback](https://github.com/prrabbhanjon/headroom-telemetry-gui/issues/new?labels=feedback&title=%5BFeedback%5D+) |
| ❓ **Question** | [Ask a question](https://github.com/prrabbhanjon/headroom-telemetry-gui/issues/new?labels=question&title=%5BQuestion%5D+) |
| ⭐ **Like it?** | Star the repo — it helps others find it! |

---


## Dashboard preview

![Dashboard](docs/dashboard-preview.png)

## What is this?

Every time you run an AI agent, it pulls in log files, searches code, grabs context — all of it goes into the LLM as a giant wall of text. You pay per token. Most of that text is boilerplate noise.

**Headroom** compresses everything before the model sees it. This project wraps Headroom in a full Kubernetes deployment with a live telemetry dashboard so you can see exactly how many tokens are being saved in real time — automatically, every second.

---

## Architecture diagrams

### End-to-end flow

```
┌─────────────────────────────────────────────────────────┐
│                      HOST MACHINE                        │
│                                                         │
│  ┌──────────────┐  ┌──────────────────┐  ┌──────────┐  │
│  │   Browser    │  │   Claude Code    │  │  kubectl │  │
│  │ localhost:   │  │ ANTHROPIC_BASE_  │  │  apply   │  │
│  │    3000      │  │ URL=:8787        │  │  + logs  │  │
│  └──────┬───────┘  └────────┬─────────┘  └────┬─────┘  │
│         │                   │                  │        │
│         └──────────── kubectl port-forward ────┘        │
│                    :3000→80    :8787→8787                │
└─────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────┐
│              PODMAN DESKTOP                              │
│         Kind cluster: headroom-api                       │
│                                                         │
│  ┌─────────────────────── namespace: headroom ────────┐ │
│  │                                                    │ │
│  │  ┌─────────────────────┐  ┌──────────────────────┐ │ │
│  │  │   headroom-proxy    │  │    headroom-gui       │ │ │
│  │  │─────────────────────│  │──────────────────────│ │ │
│  │  │ headroom-ai[proxy]  │  │  nginx:alpine         │ │ │
│  │  │ port: 8787          │  │  port: 80             │ │ │
│  │  │                     │◄─│  polls /stats every 1s│ │ │
│  │  │ /livez  /readyz     │  │  Chart.js dashboard   │ │ │
│  │  │ /health /stats      │  │                       │ │ │
│  │  │ /metrics            │  │                       │ │ │
│  │  └──────────┬──────────┘  └──────────────────────┘ │ │
│  │             │ NodePort 30787      NodePort 30080    │ │
│  │             │                                       │ │
│  │  ┌──────────┴──────────────────────────────────┐   │ │
│  │  │  ConfigMap: CORS · telemetry · env vars     │   │ │
│  │  └─────────────────────────────────────────────┘   │ │
│  └────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
                            │
                            │  compressed API calls
                            ▼
┌─────────────────────────────────────────────────────────┐
│                   ANTHROPIC CLOUD                        │
│                                                         │
│         api.anthropic.com · /v1/messages                │
│         Claude Sonnet · Claude Opus                     │
│                                                         │
│   ┌──────────┐    ┌──────────┐    ┌──────────────────┐  │
│   │  Input   │───▶│ Compress │───▶│  LLM Response    │  │
│   │ tokens   │    │ by Headrm│    │  returned        │  │
│   │ (raw)    │    │ -60% avg │    │  to Claude Code  │  │
│   └──────────┘    └──────────┘    └──────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

---

### Kubernetes networking — how port-forward works

```
HOST MACHINE                    KIND CLUSTER (Podman container)
─────────────────               ──────────────────────────────

localhost:3000 ──┐              ┌─── Service: headroom-gui
                  │             │    ClusterIP 10.96.244.33
                  │  kubectl    │    NodePort  30080:80
                  ├─ port- ─────┤
                  │  forward    │    Pod: headroom-gui
                  │             │    container port 80
localhost:8787 ──┘              └─── Service: headroom-proxy
                                     ClusterIP 10.96.135.173
                                     NodePort  30787:8787

                                     Pod: headroom-proxy
                                     container port 8787

NOTE: NodePort exposes on the Kind container's internal IP,
NOT on host localhost directly. kubectl port-forward bridges
the gap by tunneling through the Kubernetes API server.
```

---

### Telemetry data flow

```
Claude Code
    │
    │  POST /v1/messages
    │  (with ANTHROPIC_BASE_URL=http://127.0.0.1:8787)
    ▼
headroom-proxy pod (port 8787)
    │
    ├── Compresses prompt tokens (SmartCrusher, CodeCompressor, Kompress-base)
    ├── Aligns prefix for provider cache hits (CacheAligner)
    ├── Stores original in CCR cache (Compress-Cache-Retrieve)
    ├── Records stats → proxy_savings.json
    │
    │  compressed request
    ▼
Anthropic API (api.anthropic.com)
    │
    │  response
    ▼
headroom-proxy (decompresses, returns to Claude Code)

Meanwhile, every 1 second:

headroom-gui pod (nginx)
    │
    │  GET http://headroom-proxy:8787/stats   ← pod-to-pod internal DNS
    ▼
headroom-proxy /stats endpoint
    │
    │  JSON: tokens_saved, savings_percent, requests,
    │        ccr_entries, latency p50/p95, recent_history[]
    ▼
headroom-gui dashboard (Chart.js)
    │
    │  rendered at localhost:3000
    ▼
Your browser — live auto-updating telemetry
```

---

### CI/CD pipeline — GitHub Actions

```
git push origin main          git tag v1.0.0
        │                           │
        ▼                           ▼
GitHub Actions (.github/workflows/docker-publish.yml)
        │
        ├── actions/checkout@v4
        ├── docker/setup-buildx-action@v3
        ├── docker/login-action@v3 (GITHUB_TOKEN → ghcr.io)
        │
        ├── Build proxy image
        │   context: ./proxy/Dockerfile
        │   tags: latest · v1.0.0 · sha-xxxxxxx
        │   push → ghcr.io/prrabbhanjon/headroom-proxy
        │
        └── Build GUI image
            context: ./gui/Dockerfile
            tags: latest · v1.0.0 · sha-xxxxxxx
            push → ghcr.io/prrabbhanjon/headroom-gui

Anyone can then pull:
  podman pull ghcr.io/prrabbhanjon/headroom-proxy:latest
  podman pull ghcr.io/prrabbhanjon/headroom-gui:latest
```

---

## Dashboard features

- Auto-refreshes every **1 second** — no manual refresh needed
- Adjustable refresh rate: 0.5s / 1s / 2s / 5s / 10s
- Pulsing live indicator and poll counter
- **Metrics**: tokens saved · savings rate · input tokens · requests · CCR entries · latency
- **Charts**: tokens saved over time · savings % over time
- **Pipeline latency**: p50/p95 bars for input, forward, generation
- **CCR cache**: entries, retrievals, compression ratio
- **Live request log**: model · tokens in · tokens saved · flash on new entries

---

## Prerequisites

| Tool | Install |
|------|---------|
| [Podman Desktop](https://podman-desktop.io) | Download — includes Kind + kubectl |
| Git | `brew install git` |
| Node.js | `brew install node` |
| Claude Code | `npm install -g @anthropic-ai/claude-code --ignore-scripts` |
| headroom-ai | `pipx install "headroom-ai[all]"` |

After installing Podman Desktop: **Settings → Kubernetes → Enable** → wait for green dot.

---

## Step 1 — Clone

```bash
git clone https://github.com/prrabbhanjon/headroom-telemetry-gui.git
cd headroom-telemetry-gui
chmod +x setup.sh
```

## Step 2 — Install

```bash
./setup.sh install
```

Builds images → loads into Kind → deploys to K8s → port-forwards → health check → opens browser.

## Step 3 — Start Claude Code through proxy

```bash
./setup.sh claude
```

## Step 4 — View dashboard

```
http://localhost:3000
```

## Step 5 — After every reboot

```bash
./setup.sh start
```

---

## All setup.sh commands

```bash
./setup.sh install    # full setup from scratch
./setup.sh uninstall  # remove everything
./setup.sh start      # restart after reboot
./setup.sh health     # 9-point health check
./setup.sh status     # quick overview
./setup.sh forward    # restart port-forwards
./setup.sh stop       # stop port-forwards
./setup.sh restart    # restart pods
./setup.sh claude     # start Claude Code through proxy
./setup.sh logs       # pod logs
./setup.sh open       # open browser
./setup.sh help       # show all commands
```

---

## Project structure

```
headroom-telemetry-gui/
├── .github/workflows/docker-publish.yml  # CI/CD auto-build
├── proxy/Dockerfile                      # python:3.12-slim + headroom-ai[proxy]
├── gui/
│   ├── Dockerfile                        # nginx:alpine
│   ├── index.html                        # auto-refresh dashboard
│   └── nginx.conf                        # proxy_pass to headroom-proxy
├── k8s/
│   ├── namespace.yaml
│   ├── configmap.yaml
│   ├── proxy-deployment.yaml
│   ├── proxy-service.yaml
│   ├── gui-deployment.yaml
│   └── gui-service.yaml
└── setup.sh                              # all-in-one management script
```

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `ErrImageNeverPull` | Run `kind load image-archive` for both images |
| `ErrImagePull` | Set `imagePullPolicy: Never` and use `localhost/` image name |
| Port 8787 conflict | Local headroom proxy running — `./setup.sh forward` kills it |
| Lost connection to pod | Pod restarted — `./setup.sh forward` |
| Tokens saved = 0 | Claude Code not routed through proxy — `./setup.sh claude` |
| Dashboard shows old content | Hard refresh: `Cmd+Shift+R` |
| Kind container stopped (Exited 137) | `./setup.sh start` auto-restarts it |
| Port-forward drops after sleep | `./setup.sh forward` |

---

## License

Apache 2.0 — see [LICENSE](LICENSE).

---

## 💬 Share your feedback

Have you tried this? Did it save you tokens? Ideas for improvement?

**[👉 Click here to leave feedback or ask a question](https://github.com/prrabbhanjon/headroom-telemetry-gui/issues/new?labels=feedback&title=%5BFeedback%5D+)**

I read every comment. Your feedback helps make this better for everyone.

---

<sub>Built with Podman Desktop · Kind · Python · nginx · Chart.js · GitHub Actions · Anthropic Claude</sub>
