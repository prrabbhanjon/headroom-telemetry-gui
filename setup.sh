#!/usr/bin/env bash
# =============================================================================
# Headroom Telemetry GUI — Setup Script v3.0
#
# Fixes in v3.0:
#   - Auto-reinstalls Claude Code binary if missing (--ignore-scripts fix)
#   - Auto-start after reboot: podman start + port-forward + health in one cmd
#   - Detects and fixes port 8787 conflict (local headroom proxy vs K8s forward)
#   - Auto-detects kind cluster (kind get clusters + kubectl context fallback)
#   - Auto-starts podman container if stopped (Exited 137 fix after Mac sleep)
#   - No set -e / set -uo (silent exit bug fixed)
#   - 9-point health check
#   - ~/.zshrc aliases added on install
#
# Usage:
#   ./setup.sh install    build images, load into kind, deploy, forward, open
#   ./setup.sh uninstall  remove all K8s resources + optionally delete images
#   ./setup.sh start      start kind container + port-forwards (after reboot)
#   ./setup.sh health     9-point deep health check
#   ./setup.sh status     quick overview: pods, services, forwards, stats
#   ./setup.sh forward    kill conflicts, start port-forwards
#   ./setup.sh stop       stop all port-forwards
#   ./setup.sh restart    restart both deployments + re-forward
#   ./setup.sh claude     start Claude Code through the proxy (auto-fix binary)
#   ./setup.sh logs       tail logs from both pods
#   ./setup.sh open       open dashboard in browser
#   ./setup.sh fix-claude reinstall Claude Code binary only
# =============================================================================

NAMESPACE="headroom"
CLUSTER_NAME=""
CONTAINER_NAME="headroom-api-control-plane"
PROXY_IMAGE="headroom-proxy:latest"
GUI_IMAGE="headroom-gui:latest"
PROXY_LOCAL="localhost/headroom-proxy:latest"
GUI_LOCAL="localhost/headroom-gui:latest"
PROXY_PORT="8787"
GUI_PORT="3000"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()  { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()    { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error() { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
step()  { echo -e "\n${BOLD}${BLUE}==> $*${RESET}"; }
die()   { error "$*"; exit 1; }
sep()   { echo -e "${BLUE}────────────────────────────────────────────${RESET}"; }

banner() {
  echo -e "${BOLD}${CYAN}"
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║       Headroom Telemetry GUI — Setup Script v3.0         ║"
  echo "║      Kubernetes • Podman Desktop • Kind • nginx          ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo -e "${RESET}"
}

# ── FIX v3.0: Auto-reinstall Claude Code binary ──────────────────────────────
fix_claude_binary() {
  step "Fixing Claude Code binary"
  if command -v claude &>/dev/null; then
    ok "Claude Code already installed: $(which claude)"
    return
  fi

  warn "Claude Code binary missing — reinstalling..."

  local npm_root
  npm_root=$(npm root -g 2>/dev/null) || npm_root=""

  if [[ -n "$npm_root" && -f "$npm_root/@anthropic-ai/claude-code/install.cjs" ]]; then
    info "Running postinstall script..."
    node "$npm_root/@anthropic-ai/claude-code/install.cjs"
  else
    info "Reinstalling @anthropic-ai/claude-code..."
    npm install -g @anthropic-ai/claude-code --ignore-scripts
    npm_root=$(npm root -g 2>/dev/null)
    node "$npm_root/@anthropic-ai/claude-code/install.cjs" 2>/dev/null || true
  fi

  if command -v claude &>/dev/null; then
    ok "Claude Code fixed: $(which claude)"
  else
    local bin_path
    bin_path=$(npm bin -g 2>/dev/null || echo "$HOME/.npm-global/bin")
    if [[ -f "$bin_path/claude" ]]; then
      export PATH="$bin_path:$PATH"
      ok "Claude Code found at $bin_path/claude — add to PATH in ~/.zshrc:"
      echo -e "  ${CYAN}export PATH=\"$bin_path:\$PATH\"${RESET}"
    else
      warn "Claude Code install completed but binary not on PATH yet"
      warn "Run: source ~/.zshrc  or open a new terminal"
    fi
  fi
}

# ── Detect and start kind container ──────────────────────────────────────────
ensure_cluster_running() {
  info "Checking kind container status..."
  local state
  state=$(podman inspect "$CONTAINER_NAME" --format '{{.State.Status}}' 2>/dev/null || echo "missing")

  if [[ "$state" == "running" ]]; then
    ok "Kind container running: $CONTAINER_NAME"
  elif [[ "$state" == "exited" ]]; then
    warn "Kind container stopped (Exited 137) — restarting..."
    podman start "$CONTAINER_NAME"
    sleep 3
    ok "Kind container started: $CONTAINER_NAME"
  else
    warn "Kind container '$CONTAINER_NAME' not found"
    warn "Open Podman Desktop → Settings → Kubernetes → Enable"
  fi
}

# ── Detect cluster ────────────────────────────────────────────────────────────
detect_cluster() {
  info "Detecting kind cluster..."
  ensure_cluster_running
  CLUSTER_NAME=$(kind get clusters 2>/dev/null | head -1) || CLUSTER_NAME=""
  if [[ -z "$CLUSTER_NAME" ]]; then
    CLUSTER_NAME=$(kubectl config current-context 2>/dev/null | sed 's/kind-//' || echo "")
  fi
  if [[ -z "$CLUSTER_NAME" ]]; then
    die "No kind cluster found. Open Podman Desktop → Settings → Kubernetes → Enable."
  fi
  ok "Kind cluster: ${BOLD}$CLUSTER_NAME${RESET}"
}

# ── FIX: Kill conflicting process on port 8787 ───────────────────────────────
kill_conflicting_proxy() {
  local pid
  pid=$(lsof -ti tcp:${PROXY_PORT} 2>/dev/null | head -1) || pid=""
  if [[ -n "$pid" ]]; then
    local cmd
    cmd=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
    warn "Port ${PROXY_PORT} in use by: $cmd (PID $pid) — killing it"
    kill "$pid" 2>/dev/null || true
    sleep 1
    ok "Port ${PROXY_PORT} freed"
  fi
}

# ── Dependency checks ─────────────────────────────────────────────────────────
check_deps() {
  step "Checking dependencies"
  local missing=0
  for cmd in podman kind kubectl curl python3; do
    if command -v "$cmd" &>/dev/null; then
      ok "$cmd → $(command -v $cmd)"
    else
      error "$cmd not found"
      missing=$((missing+1))
    fi
  done

  # Check Claude Code separately (non-fatal)
  if command -v claude &>/dev/null; then
    ok "claude → $(which claude)"
  else
    warn "Claude Code binary not found — run: ./setup.sh fix-claude"
  fi

  [[ $missing -gt 0 ]] && die "$missing required tool(s) missing."
}

# ── Build images ──────────────────────────────────────────────────────────────
build_images() {
  step "Building container images"
  [[ ! -f "$SCRIPT_DIR/proxy/Dockerfile" ]] && die "proxy/Dockerfile not found. Run from project root."
  [[ ! -f "$SCRIPT_DIR/gui/Dockerfile"   ]] && die "gui/Dockerfile not found. Run from project root."

  info "Building headroom-proxy..."
  podman build -t "$PROXY_IMAGE" "$SCRIPT_DIR/proxy"
  podman tag "$PROXY_IMAGE" "$PROXY_LOCAL"
  ok "headroom-proxy built"

  info "Building headroom-gui..."
  podman build -t "$GUI_IMAGE" "$SCRIPT_DIR/gui"
  podman tag "$GUI_IMAGE" "$GUI_LOCAL"
  ok "headroom-gui built"
}

# ── Load images into kind ─────────────────────────────────────────────────────
load_images() {
  step "Loading images into kind cluster: $CLUSTER_NAME"
  podman save "$PROXY_LOCAL" -o /tmp/headroom-proxy.tar
  kind load image-archive /tmp/headroom-proxy.tar --name "$CLUSTER_NAME"
  ok "headroom-proxy loaded"

  podman save "$GUI_LOCAL" -o /tmp/headroom-gui.tar
  kind load image-archive /tmp/headroom-gui.tar --name "$CLUSTER_NAME"
  ok "headroom-gui loaded"

  rm -f /tmp/headroom-proxy.tar /tmp/headroom-gui.tar
}

# ── Apply K8s manifests ───────────────────────────────────────────────────────
apply_manifests() {
  step "Applying Kubernetes manifests"
  [[ ! -d "$SCRIPT_DIR/k8s" ]] && die "k8s/ directory not found."
  kubectl apply -f "$SCRIPT_DIR/k8s/namespace.yaml"
  kubectl apply -f "$SCRIPT_DIR/k8s/configmap.yaml"
  kubectl apply -f "$SCRIPT_DIR/k8s/proxy-deployment.yaml"
  kubectl apply -f "$SCRIPT_DIR/k8s/proxy-service.yaml"
  kubectl apply -f "$SCRIPT_DIR/k8s/gui-deployment.yaml"
  kubectl apply -f "$SCRIPT_DIR/k8s/gui-service.yaml"
  ok "All manifests applied"
}

# ── Patch deployments ─────────────────────────────────────────────────────────
patch_deployments() {
  step "Patching deployments with local image names"
  kubectl set image deployment/headroom-proxy proxy="$PROXY_LOCAL" -n "$NAMESPACE" 2>/dev/null || true
  kubectl set image deployment/headroom-gui   gui="$GUI_LOCAL"     -n "$NAMESPACE" 2>/dev/null || true
  kubectl patch deployment headroom-proxy -n "$NAMESPACE" \
    -p '{"spec":{"template":{"spec":{"containers":[{"name":"proxy","imagePullPolicy":"Never"}]}}}}' 2>/dev/null || true
  kubectl patch deployment headroom-gui -n "$NAMESPACE" \
    -p '{"spec":{"template":{"spec":{"containers":[{"name":"gui","imagePullPolicy":"Never"}]}}}}' 2>/dev/null || true
  ok "Deployments patched"
}

# ── Wait for pods ─────────────────────────────────────────────────────────────
wait_for_pods() {
  step "Waiting for pods to be ready (up to 120s)"
  kubectl rollout status deployment/headroom-proxy -n "$NAMESPACE" --timeout=120s
  kubectl rollout status deployment/headroom-gui   -n "$NAMESPACE" --timeout=120s
  ok "All pods running"
  echo ""
  kubectl get pods -n "$NAMESPACE"
}

# ── Port forwarding ───────────────────────────────────────────────────────────
start_forward() {
  step "Starting port-forwarding"
  pkill -f "kubectl port-forward" 2>/dev/null || true
  sleep 1
  kill_conflicting_proxy

  kubectl port-forward -n "$NAMESPACE" svc/headroom-proxy "${PROXY_PORT}:8787" \
    &>/tmp/headroom-proxy-forward.log &
  echo $! > /tmp/headroom-proxy-forward.pid

  kubectl port-forward -n "$NAMESPACE" svc/headroom-gui "${GUI_PORT}:80" \
    &>/tmp/headroom-gui-forward.log &
  echo $! > /tmp/headroom-gui-forward.pid

  sleep 2

  if curl -sf "http://localhost:${PROXY_PORT}/livez" &>/dev/null; then
    ok "Proxy reachable:  http://localhost:${PROXY_PORT}"
  else
    warn "Proxy not yet reachable — run: ./setup.sh health"
  fi
  ok "GUI forwarding:   http://localhost:${GUI_PORT}"
}

stop_forward() {
  step "Stopping port-forwarding"
  pkill -f "kubectl port-forward" 2>/dev/null && ok "Port-forwards stopped" || warn "None were running"
  rm -f /tmp/headroom-proxy-forward.pid /tmp/headroom-gui-forward.pid
}

# ── FIX v3.0: Start after reboot ─────────────────────────────────────────────
start_all() {
  step "Starting Headroom (cluster + port-forwards + Claude Code check)"

  # 1. Fix Claude Code binary if missing
  if ! command -v claude &>/dev/null; then
    fix_claude_binary
  else
    ok "Claude Code: $(which claude)"
  fi

  # 2. Start kind container
  ensure_cluster_running
  sleep 2
  detect_cluster

  # 3. Wait for cluster
  info "Waiting for cluster to be ready..."
  local attempts=0
  until kubectl get nodes &>/dev/null || [[ $attempts -ge 15 ]]; do
    sleep 2
    attempts=$((attempts+1))
    echo -n "."
  done
  echo ""

  if ! kubectl get nodes &>/dev/null; then
    die "Cluster not responding after 30s. Try: podman start $CONTAINER_NAME"
  fi
  ok "Cluster ready"

  # 4. Check pods
  local proxy_running
  proxy_running=$(kubectl get pods -n "$NAMESPACE" -l app=headroom-proxy \
    --field-selector=status.phase=Running 2>/dev/null | grep -c Running || echo 0)
  if [[ "$proxy_running" -eq 0 ]]; then
    warn "Pods not running — applying manifests..."
    apply_manifests
    wait_for_pods
  else
    ok "Pods already running"
    kubectl get pods -n "$NAMESPACE"
  fi

  # 5. Start port-forwards
  start_forward
  open_browser

  echo ""
  echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${GREEN}║        Headroom is running after reboot!         ║${RESET}"
  echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════╝${RESET}"
  echo ""
  echo -e "  Dashboard:  http://localhost:${GUI_PORT}"
  echo -e "  Run: ${CYAN}./setup.sh claude${RESET} to start Claude Code"
}

# ── Health check ──────────────────────────────────────────────────────────────
health_check() {
  step "Deep health check (9 points)"
  local all_ok=true

  sep
  echo -e "${BOLD}1. Kind container${RESET}"
  local state
  state=$(podman inspect "$CONTAINER_NAME" --format '{{.State.Status}}' 2>/dev/null || echo "missing")
  if [[ "$state" == "running" ]]; then ok "Container: running"
  else error "Container: $state"; all_ok=false; fi

  sep
  echo -e "${BOLD}2. Kubernetes pods${RESET}"
  if kubectl get pods -n "$NAMESPACE" 2>/dev/null | grep -q "Running"; then
    kubectl get pods -n "$NAMESPACE"; ok "Pods running"
  else error "No pods running"; all_ok=false; fi

  sep
  echo -e "${BOLD}3. Port conflict check (port ${PROXY_PORT})${RESET}"
  local pid
  pid=$(lsof -ti tcp:${PROXY_PORT} 2>/dev/null | head -1) || pid=""
  if [[ -n "$pid" ]]; then
    local cmd; cmd=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
    if echo "$cmd" | grep -qi "kubectl"; then ok "Port ${PROXY_PORT} held by kubectl (correct)"
    else warn "Port ${PROXY_PORT} held by: $cmd — run: ./setup.sh forward"; all_ok=false; fi
  else warn "Nothing on port ${PROXY_PORT} — run: ./setup.sh forward"; all_ok=false; fi

  sep
  echo -e "${BOLD}4. Port-forwards${RESET}"
  if pgrep -f "kubectl port-forward" &>/dev/null; then
    pgrep -af "kubectl port-forward"; ok "Port-forwards active"
  else warn "No port-forwards — run: ./setup.sh forward"; all_ok=false; fi

  sep
  echo -e "${BOLD}5. Proxy liveness (/livez)${RESET}"
  if curl -sf "http://localhost:${PROXY_PORT}/livez" &>/dev/null; then ok "Proxy UP"
  else error "Proxy not reachable"; all_ok=false; fi

  sep
  echo -e "${BOLD}6. Proxy readiness (/readyz)${RESET}"
  if curl -sf "http://localhost:${PROXY_PORT}/readyz" &>/dev/null; then ok "Proxy READY"
  else warn "Proxy not ready yet"; fi

  sep
  echo -e "${BOLD}7. Proxy health detail (/health)${RESET}"
  local health
  health=$(curl -sf "http://localhost:${PROXY_PORT}/health" 2>/dev/null)
  if [[ -n "$health" ]]; then
    echo "$health" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(f\"  Service:  {d.get('service','?')}\")
print(f\"  Status:   {d.get('status','?')}\")
print(f\"  Version:  {d.get('version','?')}\")
print(f\"  Uptime:   {round(d.get('uptime_seconds',0))}s\")
for k,v in d.get('checks',{}).items():
    st=v.get('status','?')
    icon='OK  ' if st in ('healthy','disabled') else 'FAIL'
    print(f\"  [{icon}] {k}: {st}\")
" 2>/dev/null
    ok "Health endpoint OK"
  else warn "Could not reach /health"; all_ok=false; fi

  sep
  echo -e "${BOLD}8. GUI reachability${RESET}"
  if curl -sf "http://localhost:${GUI_PORT}" &>/dev/null; then ok "Dashboard reachable"
  else error "Dashboard not reachable"; all_ok=false; fi

  sep
  echo -e "${BOLD}9. Proxy stats + Claude Code${RESET}"
  local stats
  stats=$(curl -sf "http://localhost:${PROXY_PORT}/stats" 2>/dev/null)
  if [[ -n "$stats" ]]; then
    echo "$stats" | python3 -c "
import json,sys
d=json.load(sys.stdin)
sess=d.get('display_session') or d.get('persistent_savings',{}).get('display_session',{}) or {}
c=d.get('compression',{})
tp=d.get('throughput',{}).get('rolling',{})
print(f\"  Requests:     {sess.get('requests',0)}\")
print(f\"  Tokens saved: {sess.get('tokens_saved',0)}\")
print(f\"  Savings:      {sess.get('savings_percent',0):.1f}%\")
print(f\"  CCR entries:  {c.get('ccr_entries',0)}\")
print(f\"  Fwd p50:      {round(tp.get('forward_p50',0))}ms\")
" 2>/dev/null
    ok "Stats OK"
  else warn "Could not reach /stats"; fi

  if command -v claude &>/dev/null; then ok "Claude Code: $(which claude)"
  else warn "Claude Code binary missing — run: ./setup.sh fix-claude"; fi

  sep
  if $all_ok; then
    echo -e "\n${BOLD}${GREEN}All health checks passed.${RESET}"
  else
    echo -e "\n${BOLD}${YELLOW}Some checks failed. Quick fixes:${RESET}"
    echo -e "  ${CYAN}./setup.sh start${RESET}      — start everything after reboot"
    echo -e "  ${CYAN}./setup.sh forward${RESET}    — restart port-forwards"
    echo -e "  ${CYAN}./setup.sh fix-claude${RESET} — fix Claude Code binary"
  fi
  echo ""
  echo -e "  Dashboard: http://localhost:${GUI_PORT}"
}

# ── Status ────────────────────────────────────────────────────────────────────
show_status() {
  step "Current status"
  local state
  state=$(podman inspect "$CONTAINER_NAME" --format '{{.State.Status}}' 2>/dev/null || echo "not found")
  echo -e "\n${BOLD}Kind container:${RESET} $CONTAINER_NAME → $state"

  echo -e "\n${BOLD}Pods:${RESET}"
  kubectl get pods -n "$NAMESPACE" 2>/dev/null || warn "Namespace not found"

  echo -e "\n${BOLD}Services:${RESET}"
  kubectl get svc -n "$NAMESPACE" 2>/dev/null || true

  echo -e "\n${BOLD}Images:${RESET}"
  podman images | grep -E "headroom|REPOSITORY" || warn "No headroom images"

  echo -e "\n${BOLD}Port-forwards:${RESET}"
  pgrep -af "kubectl port-forward" 2>/dev/null || warn "No active port-forwards"

  echo -e "\n${BOLD}Claude Code:${RESET}"
  command -v claude &>/dev/null && ok "$(which claude)" || warn "Missing — run: ./setup.sh fix-claude"

  echo -e "\n${BOLD}Proxy stats:${RESET}"
  if curl -sf "http://localhost:${PROXY_PORT}/livez" &>/dev/null; then
    curl -sf "http://localhost:${PROXY_PORT}/stats" | python3 -c "
import json,sys
d=json.load(sys.stdin)
sess=d.get('display_session') or d.get('persistent_savings',{}).get('display_session',{}) or {}
print(f\"  Requests: {sess.get('requests',0)}  |  Tokens saved: {sess.get('tokens_saved',0)}  |  Savings: {sess.get('savings_percent',0):.1f}%\")
" 2>/dev/null
  else warn "Proxy not reachable — run: ./setup.sh forward"; fi
}

# ── Restart ───────────────────────────────────────────────────────────────────
restart_deployments() {
  step "Restarting deployments"
  kubectl rollout restart deployment/headroom-proxy -n "$NAMESPACE"
  kubectl rollout restart deployment/headroom-gui   -n "$NAMESPACE"
  wait_for_pods
  start_forward
}

# ── Open browser ──────────────────────────────────────────────────────────────
open_browser() {
  local url="http://localhost:${GUI_PORT}"
  info "Opening $url"
  command -v open &>/dev/null && open "$url" || info "Open manually: $url"
}

# ── FIX v3.0: Claude Code with binary check ──────────────────────────────────
start_claude() {
  step "Starting Claude Code through Headroom proxy"

  # Fix binary if missing
  if ! command -v claude &>/dev/null; then
    warn "Claude Code binary missing — fixing now..."
    fix_claude_binary
  fi

  if ! command -v claude &>/dev/null; then
    die "Claude Code still not found after fix. Try: npm install -g @anthropic-ai/claude-code"
  fi

  # Check proxy
  local pid
  pid=$(lsof -ti tcp:${PROXY_PORT} 2>/dev/null | head -1) || pid=""
  if [[ -n "$pid" ]]; then
    local cmd; cmd=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
    if echo "$cmd" | grep -qi "headroom"; then
      warn "Local headroom proxy on port ${PROXY_PORT} — using it directly"
      ANTHROPIC_BASE_URL="http://127.0.0.1:${PROXY_PORT}" claude; return
    fi
  fi

  if ! curl -sf "http://localhost:${PROXY_PORT}/livez" &>/dev/null; then
    warn "Proxy not reachable — starting port-forward..."
    start_forward
    sleep 2
  fi

  if ! curl -sf "http://localhost:${PROXY_PORT}/livez" &>/dev/null; then
    die "Proxy still not reachable. Run: ./setup.sh health"
  fi

  ok "Proxy healthy — launching Claude Code"
  info "Dashboard: http://localhost:${GUI_PORT}"
  echo ""
  ANTHROPIC_BASE_URL="http://127.0.0.1:${PROXY_PORT}" claude
}

# ── Logs ──────────────────────────────────────────────────────────────────────
show_logs() {
  step "Recent logs"
  echo -e "${BOLD}Proxy:${RESET}"
  kubectl logs -n "$NAMESPACE" deploy/headroom-proxy --tail=30 2>/dev/null || warn "No proxy logs"
  echo -e "\n${BOLD}GUI:${RESET}"
  kubectl logs -n "$NAMESPACE" deploy/headroom-gui --tail=30 2>/dev/null || warn "No GUI logs"
}

# ── Uninstall ─────────────────────────────────────────────────────────────────
uninstall() {
  step "Uninstalling Headroom Telemetry GUI"
  warn "This removes all Kubernetes resources in namespace: $NAMESPACE"
  echo -en "${YELLOW}Continue? [y/N]:${RESET} "
  read -r confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }

  pkill -f "kubectl port-forward" 2>/dev/null || true
  rm -f /tmp/headroom-proxy-forward.pid /tmp/headroom-gui-forward.pid
  ok "Port-forwards stopped"

  kubectl delete namespace "$NAMESPACE" --ignore-not-found=true
  ok "Namespace $NAMESPACE deleted"

  echo -en "\n${YELLOW}Also remove local Podman images? [y/N]:${RESET} "
  read -r remove_images
  if [[ "$remove_images" =~ ^[Yy]$ ]]; then
    for img in "$PROXY_IMAGE" "$PROXY_LOCAL" "$GUI_IMAGE" "$GUI_LOCAL"; do
      podman rmi "$img" 2>/dev/null && ok "Removed $img" || warn "$img not found"
    done
  fi
  ok "Uninstall complete. Run ./setup.sh install to reinstall."
}

# ── Install ───────────────────────────────────────────────────────────────────
install() {
  check_deps
  fix_claude_binary
  detect_cluster
  build_images
  load_images
  apply_manifests
  patch_deployments
  wait_for_pods
  start_forward
  sleep 2
  health_check

  # Add zshrc aliases
  local zshrc_snippet="
# Headroom Telemetry GUI — auto-start (added by setup.sh)
alias headroom-start='cd $SCRIPT_DIR && ./setup.sh start'
alias headroom-claude='cd $SCRIPT_DIR && ./setup.sh claude'
alias headroom-health='cd $SCRIPT_DIR && ./setup.sh health'"

  echo ""
  echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${GREEN}║           Installation complete!                 ║${RESET}"
  echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════╝${RESET}"
  echo ""
  echo -e "  ${BOLD}Dashboard:${RESET}  http://localhost:${GUI_PORT}"
  echo -e "  ${BOLD}Proxy API:${RESET}  http://localhost:${PROXY_PORT}/stats"
  echo ""
  echo -e "  ${CYAN}./setup.sh claude${RESET}     start Claude Code through proxy"
  echo -e "  ${CYAN}./setup.sh start${RESET}      restart everything after reboot"
  echo -e "  ${CYAN}./setup.sh health${RESET}     9-point health check"
  echo -e "  ${CYAN}./setup.sh fix-claude${RESET} fix Claude Code binary"
  echo -e "  ${CYAN}./setup.sh logs${RESET}       pod logs"
  echo -e "  ${CYAN}./setup.sh uninstall${RESET}  remove everything"
  echo ""
  echo -e "${BOLD}Optional: add to ~/.zshrc for quick access:${RESET}"
  echo -e "${CYAN}$zshrc_snippet${RESET}"
  echo ""
  echo -en "${YELLOW}Add these aliases to ~/.zshrc now? [y/N]:${RESET} "
  read -r add_alias
  if [[ "$add_alias" =~ ^[Yy]$ ]]; then
    echo "$zshrc_snippet" >> ~/.zshrc
    ok "Aliases added — run: source ~/.zshrc"
  fi

  open_browser
}

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
  banner
  echo -e "Usage: ${BOLD}$(basename $0) <command>${RESET}"
  echo ""
  echo "Commands:"
  echo -e "  ${CYAN}install${RESET}     Full setup: build, load, deploy, forward, health, open"
  echo -e "  ${CYAN}uninstall${RESET}   Remove all K8s resources + optionally remove images"
  echo -e "  ${CYAN}start${RESET}       Start after reboot (cluster + forwards + checks)"
  echo -e "  ${CYAN}health${RESET}      9-point deep health check"
  echo -e "  ${CYAN}status${RESET}      Quick overview: pods, forwards, Claude, stats"
  echo -e "  ${CYAN}forward${RESET}     Kill conflicts, restart port-forwards"
  echo -e "  ${CYAN}stop${RESET}        Stop all port-forwards"
  echo -e "  ${CYAN}restart${RESET}     Restart both deployments + re-forward"
  echo -e "  ${CYAN}claude${RESET}      Start Claude Code through proxy (auto-fixes binary)"
  echo -e "  ${CYAN}fix-claude${RESET}  Reinstall Claude Code binary only"
  echo -e "  ${CYAN}logs${RESET}        Show recent logs from both pods"
  echo -e "  ${CYAN}open${RESET}        Open dashboard in browser"
  echo -e "  ${CYAN}help${RESET}        Show this message"
  echo ""
  echo "After reboot:"
  echo -e "  ${CYAN}./setup.sh start${RESET}  — restarts everything automatically"
  echo ""
}

# ── Entry point ───────────────────────────────────────────────────────────────
banner

case "${1:-help}" in
  install)    install ;;
  uninstall)  detect_cluster; uninstall ;;
  start)      start_all ;;
  health)     detect_cluster; health_check ;;
  status)     detect_cluster; show_status ;;
  restart)    detect_cluster; restart_deployments ;;
  forward)    detect_cluster; start_forward ;;
  stop)       stop_forward ;;
  claude)     start_claude ;;
  fix-claude) fix_claude_binary ;;
  logs)       show_logs ;;
  open)       open_browser ;;
  help|--help|-h) usage ;;
  *) error "Unknown command: $1"; usage; exit 1 ;;
esac
