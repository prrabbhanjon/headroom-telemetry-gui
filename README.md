# Headroom Telemetry GUI

> Live token savings dashboard for [Headroom AI](https://github.com/headroomlabs-ai/headroom) — deployed on Kubernetes via Podman Desktop.

[![Build and publish images](https://github.com/YOUR_USERNAME/headroom-telemetry-gui/actions/workflows/docker-publish.yml/badge.svg)](https://github.com/YOUR_USERNAME/headroom-telemetry-gui/actions/workflows/docker-publish.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![setup.sh version](https://img.shields.io/badge/setup.sh-v3.0-brightgreen)](setup.sh)
[![ghcr.io proxy](https://img.shields.io/badge/ghcr.io-headroom--proxy-teal)](https://ghcr.io/YOUR_USERNAME/headroom-proxy)
[![ghcr.io gui](https://img.shields.io/badge/ghcr.io-headroom--gui-orange)](https://ghcr.io/YOUR_USERNAME/headroom-gui)
[![Feedback welcome](https://img.shields.io/badge/feedback-welcome-blue)](https://github.com/YOUR_USERNAME/headroom-telemetry-gui/issues/new?labels=feedback&title=%5BFeedback%5D+)
[![Views](https://hits.sh/github.com/prrabbhanjon/headroom-telemetry-gui.svg?label=views&color=6f42c1)](https://hits.sh/github.com/prrabbhanjon/headroom-telemetry-gui/)

---

## 📸 Dashboard preview

> _Take a screenshot of your live dashboard at `http://localhost:3000` and save it as `docs/dashboard-preview.png` to show it here._

![Headroom Telemetry Dashboard](docs/dashboard-preview.png)

---

## 💬 Feedback & Comments

| | |
|---|---|
| 💡 **Feature idea** | [Open a feature request](https://github.com/YOUR_USERNAME/headroom-telemetry-gui/issues/new?labels=enhancement&title=%5BFeature%5D+) |
| 🐛 **Found a bug** | [Report a bug](https://github.com/YOUR_USERNAME/headroom-telemetry-gui/issues/new?labels=bug&title=%5BBug%5D+) |
| 💬 **General feedback** | [Leave feedback](https://github.com/YOUR_USERNAME/headroom-telemetry-gui/issues/new?labels=feedback&title=%5BFeedback%5D+) |
| ❓ **Question** | [Ask a question](https://github.com/YOUR_USERNAME/headroom-telemetry-gui/issues/new?labels=question&title=%5BQuestion%5D+) |
| ⭐ **Like it?** | Star the repo — it helps others find it! |

---

## What is this?

Every time you run an AI agent, it pulls in log files, searches code, grabs context — all of it goes into the LLM as a giant wall of text. You pay per token. Most of that text is boilerplate noise.

**Headroom** compresses everything before the model sees it — 60–95% fewer tokens, same answers. This project wraps Headroom in a full Kubernetes deployment with a live telemetry dashboard so you can see exactly how many tokens are being saved in real time.

---

## Architecture

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
│  ┌──────────────── namespace: headroom ───────────────┐  │
│  │                                                    │  │
│  │  ┌──────────────────────┐  ┌────────────────────┐  │  │
│  │  │   headroom-proxy     │  │   headroom-gui     │  │  │
│  │  │  headroom-ai[proxy]  │  │   nginx:alpine     │  │  │
│  │  │  port: 8787          │◄─│   port: 80         │  │  │
│  │  │  /livez /stats       │  │   polls /stats 1s  │  │  │
│  │  │  /health /metrics    │  │   Chart.js         │  │  │
│  │  └──────────┬───────────┘  └────────────────────┘  │  │
│  │             │  NodePort 30787     NodePort 30080    │  │
│  │  ┌──────────┴────────────────────────────────────┐  │  │
│  │  │  ConfigMap · namespace · services · deploys   │  │  │
│  │  └───────────────────────────────────────────────┘  │  │
│  └────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
                            │  compressed API calls
                            ▼
┌─────────────────────────────────────────────────────────┐
│                   ANTHROPIC CLOUD                        │
│         api.anthropic.com · /v1/messages                │
│   Input tokens → Headroom compresses → LLM responds     │
└─────────────────────────────────────────────────────────┘
```

### Telemetry data flow

```
Claude Code
    │  POST /v1/messages (ANTHROPIC_BASE_URL=http://127.0.0.1:8787)
    ▼
headroom-proxy pod
    ├── SmartCrusher (JSON) · CodeCompressor (AST) · Kompress-base (text)
    ├── CacheAligner → improves provider prefix cache hits
    ├── CCR cache → stores originals for retrieval
    ├── Records stats → proxy_savings.json
    │  compressed request
    ▼
Anthropic API → response → Claude Code

Every 1 second:
headroom-gui → GET http://headroom-proxy:8787/stats (pod-to-pod DNS)
    → tokens_saved · savings_percent · requests · ccr_entries · latency
    → Chart.js dashboard at localhost:3000
```

### CI/CD pipeline

```
git push origin main  OR  git tag v1.0.0
        │
        ▼
GitHub Actions (.github/workflows/docker-publish.yml)
        ├── Build proxy → ghcr.io/YOUR_USERNAME/headroom-proxy:latest
        └── Build GUI   → ghcr.io/YOUR_USERNAME/headroom-gui:latest
```

---

## Dashboard features

- Auto-refreshes every **1 second** — no manual refresh (like Zabbix)
- Adjustable rate: 0.5s / 1s / 2s / 5s / 10s
- Pulsing live indicator + poll counter
- **Metrics**: tokens saved · savings % · input tokens · requests · CCR entries · latency p50
- **Charts**: tokens saved over time · savings % over time (Chart.js)
- **Pipeline latency**: p50/p95 bars
- **CCR cache**: entries · retrievals · compression ratio
- **Live request log**: model · tokens in · tokens saved — flashes green on new entries
- Dark mode support

---

## Prerequisites

| Tool | Install |
|------|---------|
| [Podman Desktop](https://podman-desktop.io) | Download — includes Kind + kubectl |
| Git | `brew install git` |
| Node.js | `brew install node` |
| Claude Code | `npm install -g @anthropic-ai/claude-code --ignore-scripts` |
| headroom-ai | `pipx install "headroom-ai[all]"` |

> After installing Podman Desktop: **Settings → Kubernetes → Enable** → wait for green dot.

---

## Quick start

```bash
git clone https://github.com/YOUR_USERNAME/headroom-telemetry-gui.git
cd headroom-telemetry-gui
chmod +x setup.sh
./setup.sh install
```

---

## setup.sh v3.0 — all commands

```bash
./setup.sh install     # full setup: build, load, deploy, forward, health, open
./setup.sh uninstall   # remove all K8s resources + optionally delete images
./setup.sh start       # start after reboot (cluster + forwards + Claude check)
./setup.sh health      # 9-point deep health check
./setup.sh status      # quick overview: pods, forwards, Claude, stats
./setup.sh forward     # kill conflicts, restart port-forwards
./setup.sh stop        # stop all port-forwards
./setup.sh restart     # restart both deployments + re-forward
./setup.sh claude      # start Claude Code through proxy (auto-fixes binary)
./setup.sh fix-claude  # reinstall Claude Code binary only
./setup.sh logs        # show recent logs from both pods
./setup.sh open        # open dashboard in browser
./setup.sh help        # show all commands
```

### What's new in v3.0

| Fix | What was wrong | How fixed |
|-----|---------------|-----------|
| `fix-claude` command | Binary missing after `--ignore-scripts` | Auto-runs postinstall `install.cjs` |
| `start` command | Manual steps needed after reboot | Auto-starts container + pods + forwards + Claude check |
| Claude Code check | Started without binary present | `claude` command auto-fixed before launch |
| Port 8787 conflict | Local headroom proxy blocked K8s forward | `kill_conflicting_proxy()` runs before every forward |
| Health check | Didn't verify Claude binary | Check 9 now includes Claude Code binary status |
| Silent exit bug | `set -e` killed script after deps | Removed entirely |

---

## After every reboot

```bash
./setup.sh start
```

Auto-starts the Kind container, waits for cluster, checks pods, starts port-forwards, fixes Claude Code binary if needed, opens browser.

Add to `~/.zshrc`:

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
│   ├── workflows/docker-publish.yml     # CI/CD auto-build on push + tags
│   └── ISSUE_TEMPLATE/                  # feedback · bug · feature · question
├── docs/
│   └── dashboard-preview.png            # screenshot shown in README
├── proxy/
│   └── Dockerfile                       # python:3.12-slim + headroom-ai[proxy]
├── gui/
│   ├── Dockerfile                       # nginx:alpine
│   ├── index.html                       # auto-refresh dashboard (Chart.js)
│   └── nginx.conf                       # serves GUI + proxies /api/ internally
├── k8s/
│   ├── namespace.yaml
│   ├── configmap.yaml
│   ├── proxy-deployment.yaml
│   ├── proxy-service.yaml
│   ├── gui-deployment.yaml
│   └── gui-service.yaml
└── setup.sh                             # v3.0 — install · start · health · claude
```

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `ErrImageNeverPull` | Run `kind load image-archive` for both images |
| `ErrImagePull` | Set `imagePullPolicy: Never` + `localhost/` image name |
| Port 8787 conflict | `./setup.sh forward` kills conflicting process |
| Lost connection to pod | Pod restarted — `./setup.sh forward` |
| Tokens saved = 0 | Claude Code not routed — `./setup.sh claude` |
| Dashboard stale | Hard refresh: `Cmd+Shift+R` |
| Kind container stopped (Exited 137) | `./setup.sh start` auto-restarts |
| Claude Code binary missing | `./setup.sh fix-claude` |
| Port-forward drops after sleep | `./setup.sh forward` |

---

## Pull pre-built images

```bash
podman pull ghcr.io/YOUR_USERNAME/headroom-proxy:latest
podman pull ghcr.io/YOUR_USERNAME/headroom-gui:latest
podman tag ghcr.io/YOUR_USERNAME/headroom-proxy:latest localhost/headroom-proxy:latest
podman tag ghcr.io/YOUR_USERNAME/headroom-gui:latest   localhost/headroom-gui:latest
kubectl apply -f k8s/
./setup.sh forward
```

---

## License

Apache 2.0 — see [LICENSE](LICENSE).

---

## 💬 Share your feedback

**[👉 Click here to leave feedback](https://github.com/YOUR_USERNAME/headroom-telemetry-gui/issues/new?labels=feedback&title=%5BFeedback%5D+)**

---

<sub>Built with Podman Desktop · Kind · Python · nginx · Chart.js · GitHub Actions · Anthropic Claude · setup.sh v3.0</sub>
