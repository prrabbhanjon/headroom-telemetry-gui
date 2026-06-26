#!/usr/bin/env bash
# =============================================================================
# Headroom Telemetry GUI — Setup Script v2.0
#
# Fixes included:
#   - No set -e / set -uo (silent exit bug fixed)
#   - Auto-detects kind cluster name (kind get clusters + kubectl context fallback)
#   - Auto-starts podman container if cluster is stopped (Exited 137 fix)
#   - Detects port 8787 conflict between local headroom proxy and K8s forward
#   - Kills conflicting local headroom proxy before starting K8s port-forward
#   - Health check with 9 checks including livez, readyz, GUI, stats
#   - ./setup.sh claude — checks proxy first, auto-forwards if needed
#   - ./setup.sh start  — start kind container + port-forwards in one command
#   - ~/.zshrc auto-start snippet generated on install
#
# Usage:
#   ./setup.sh install    build images, load into kind, deploy, forward, open
#   ./setup.sh uninstall  remove all K8s resources + optionally delete images
#   ./setup.sh start      start kind container + port-forwards (after reboot)
#   ./setup.sh health     9-point deep health check
#   ./setup.sh status     quick overview of pods, services, forwards, stats
#   ./setup.sh forward    kill conflicts, start port-forwards
#   ./setup.sh stop       stop all port-forwards
#   ./setup.sh restart    restart both deployments + re-forward
#   ./setup.sh claude     start Claude Code through the proxy
#   ./setup.sh logs       tail logs from both pods
#   ./setup.sh open       open dashboard in browser
# =============================================================================

# ── Config ────────────────────────────────────────────────────────────────────
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

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ── Helpers ───────────────────────────────────────────────────────────────────
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
  echo "║          Headroom Telemetry GUI — Setup Script v2.0      ║"
  echo "║      Kubernetes • Podman Desktop • Kind • nginx          ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo -e "${RESET}"
}

# ── FIX: Detect and start kind container if stopped ───────────────────────────
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
  elif [[ "$state" == "missing" ]]; then
    warn "Kind container '$CONTAINER_NAME' not found"
    warn "Open Podman Desktop → Settings → Kubernetes → Enable to create it"
  else
    warn "Kind container state: $state"
  fi
}

# ── FIX: Detect cluster with fallback ────────────────────────────────────────
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

# ── FIX: Kill local headroom proxy if running on same port ───────────────────
kill_conflicting_proxy() {
  local pid
  pid=$(lsof -ti tcp:${PROXY_PORT} 2>/dev/null | head -1) || pid=""
  if [[ -n "$pid" ]]; then
    local cmd
    cmd=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
    if echo "$cmd" | grep -qi "headroom"; then
      warn "Local headroom proxy running on port ${PROXY_PORT} (PID $pid) — stopping it"
      kill "$pid" 2>/dev/null || true
      sleep 1
      ok "Local headroom proxy stopped"
    else
      warn "Port ${PROXY_PORT} in use by: $cmd (PID $pid)"
      warn "Killing it to free the port..."
      kill "$pid" 2>/dev/null || true
      sleep 1
    fi
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
  ok "Temp tarballs cleaned up"
}

# ── Apply K8s manifests ───────────────────────────────────────────────────────
apply_manifests() {
  step "Applying Kubernetes manifests"
  [[ ! -d "$SCRIPT_DIR/k8s" ]] && die "k8s/ directory not found. Run from project root."
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

# ── FIX: Port forwarding with conflict detection ──────────────────────────────
start_forward() {
  step "Starting port-forwarding"

  # Kill existing kubectl port-forwards
  pkill -f "kubectl port-forward" 2>/dev/null || true
  sleep 1

  # FIX: Kill local headroom proxy or anything else on port 8787
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
    warn "Proxy not yet reachable — give it a moment and run: ./setup.sh health"
  fi
  ok "GUI forwarding:   http://localhost:${GUI_PORT}"
}

stop_forward() {
  step "Stopping port-forwarding"
  pkill -f "kubectl port-forward" 2>/dev/null && ok "Port-forwards stopped" || warn "None were running"
  rm -f /tmp/headroom-proxy-forward.pid /tmp/headroom-gui-forward.pid
}

# ── Start after reboot ────────────────────────────────────────────────────────
start_all() {
  step "Starting Headroom (cluster + port-forwards)"
  ensure_cluster_running
  sleep 2
  detect_cluster

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

  start_forward
  open_browser

  echo ""
  echo -e "${BOLD}${GREEN}Headroom is running!${RESET}"
  echo -e "  Dashboard: http://localhost:${GUI_PORT}"
  echo -e "  Run: ${CYAN}./setup.sh claude${RESET} to start Claude Code through proxy"
}

# ── Health check ──────────────────────────────────────────────────────────────
health_check() {
  step "Deep health check (9 points)"
  local all_ok=true

  sep
  echo -e "${BOLD}1. Kind container${RESET}"
  local state
  state=$(podman inspect "$CONTAINER_NAME" --format '{{.State.Status}}' 2>/dev/null || echo "missing")
  if [[ "$state" == "running" ]]; then
    ok "Container $CONTAINER_NAME: running"
  else
    error "Container $CONTAINER_NAME: $state"
    all_ok=false
  fi

  sep
  echo -e "${BOLD}2. Kubernetes pods${RESET}"
  if kubectl get pods -n "$NAMESPACE" 2>/dev/null | grep -q "Running"; then
    kubectl get pods -n "$NAMESPACE"
    ok "Pods running"
  else
    error "No pods running in namespace $NAMESPACE"
    all_ok=false
  fi

  sep
  echo -e "${BOLD}3. Port conflict check (port ${PROXY_PORT})${RESET}"
  local pid
  pid=$(lsof -ti tcp:${PROXY_PORT} 2>/dev/null | head -1) || pid=""
  if [[ -n "$pid" ]]; then
    local cmd
    cmd=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
    if echo "$cmd" | grep -qi "kubectl"; then
      ok "Port ${PROXY_PORT} held by kubectl port-forward (correct)"
    else
      warn "Port ${PROXY_PORT} held by: $cmd (PID $pid) — may conflict with K8s forward"
      warn "Run: ./setup.sh forward  to kill conflict and restart correctly"
      all_ok=false
    fi
  else
    warn "Nothing on port ${PROXY_PORT} — run: ./setup.sh forward"
    all_ok=false
  fi

  sep
  echo -e "${BOLD}4. Port-forwards${RESET}"
  if pgrep -f "kubectl port-forward" &>/dev/null; then
    pgrep -af "kubectl port-forward"
    ok "Port-forwards active"
  else
    warn "No port-forwards running → run: ./setup.sh forward"
    all_ok=false
  fi

  sep
  echo -e "${BOLD}5. Proxy liveness (/livez)${RESET}"
  if curl -sf "http://localhost:${PROXY_PORT}/livez" &>/dev/null; then
    ok "http://localhost:${PROXY_PORT}/livez → UP"
  else
    error "Proxy not reachable at localhost:${PROXY_PORT}"
    all_ok=false
  fi

  sep
  echo -e "${BOLD}6. Proxy readiness (/readyz)${RESET}"
  if curl -sf "http://localhost:${PROXY_PORT}/readyz" &>/dev/null; then
    ok "http://localhost:${PROXY_PORT}/readyz → READY"
  else
    warn "Proxy not ready yet"
  fi

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
    ok "Health endpoint responding"
  else
    warn "Could not reach /health"
    all_ok=false
  fi

  sep
  echo -e "${BOLD}8. GUI reachability (localhost:${GUI_PORT})${RESET}"
  if curl -sf "http://localhost:${GUI_PORT}" &>/dev/null; then
    ok "Dashboard reachable at http://localhost:${GUI_PORT}"
  else
    error "Dashboard not reachable at localhost:${GUI_PORT}"
    all_ok=false
  fi

  sep
  echo -e "${BOLD}9. Proxy stats (/stats)${RESET}"
  local stats
  stats=$(curl -sf "http://localhost:${PROXY_PORT}/stats" 2>/dev/null)
  if [[ -n "$stats" ]]; then
    echo "$stats" | python3 -c "
import json,sys
d=json.load(sys.stdin)
sess=d.get('display_session') or d.get('persistent_savings',{}).get('display_session',{}) or {}
life=d.get('persistent_savings',{}).get('lifetime',{}) or {}
c=d.get('compression',{})
tp=d.get('throughput',{}).get('rolling',{})
print(f\"  Session requests:     {sess.get('requests',0)}\")
print(f\"  Session tokens saved: {sess.get('tokens_saved',0)}\")
print(f\"  Session savings:      {sess.get('savings_percent',0):.1f}%\")
print(f\"  Lifetime requests:    {life.get('requests',0)}\")
print(f\"  Lifetime tokens saved:{life.get('tokens_saved',0)}\")
print(f\"  CCR entries:          {c.get('ccr_entries',0)}\")
print(f\"  Fwd latency p50:      {round(tp.get('forward_p50',0))}ms\")
print(f\"  Fwd latency p95:      {round(tp.get('forward_p95',0))}ms\")
" 2>/dev/null
    ok "Stats endpoint responding"
  else
    warn "Could not reach /stats"
  fi

  sep
  if $all_ok; then
    echo -e "\n${BOLD}${GREEN}All health checks passed.${RESET}"
  else
    echo -e "\n${BOLD}${YELLOW}Some checks failed. Quick fixes:${RESET}"
    echo -e "  ${CYAN}./setup.sh start${RESET}    — start cluster + forwards (after reboot)"
    echo -e "  ${CYAN}./setup.sh forward${RESET}  — restart port-forwards + fix conflicts"
    echo -e "  ${CYAN}./setup.sh restart${RESET}  — restart pods"
  fi
  echo ""
  echo -e "  Dashboard: http://localhost:${GUI_PORT}"
  echo -e "  Proxy API: http://localhost:${PROXY_PORT}/stats"
}

# ── Status ────────────────────────────────────────────────────────────────────
show_status() {
  step "Current status"

  echo -e "\n${BOLD}Kind container:${RESET}"
  local state
  state=$(podman inspect "$CONTAINER_NAME" --format '{{.State.Status}}' 2>/dev/null || echo "not found")
  echo "  $CONTAINER_NAME: $state"

  echo -e "\n${BOLD}Pods:${RESET}"
  kubectl get pods -n "$NAMESPACE" 2>/dev/null || warn "Namespace $NAMESPACE not found"

  echo -e "\n${BOLD}Services:${RESET}"
  kubectl get svc -n "$NAMESPACE" 2>/dev/null || true

  echo -e "\n${BOLD}Images in Podman:${RESET}"
  podman images | grep -E "headroom|REPOSITORY" || warn "No headroom images found"

  echo -e "\n${BOLD}Port-forwards:${RESET}"
  if pgrep -f "kubectl port-forward" &>/dev/null; then
    pgrep -af "kubectl port-forward"
  else
    warn "No active port-forwards — run: ./setup.sh forward"
  fi

  echo -e "\n${BOLD}Port conflict check:${RESET}"
  local pid
  pid=$(lsof -ti tcp:${PROXY_PORT} 2>/dev/null | head -1) || pid=""
  if [[ -n "$pid" ]]; then
    local cmd
    cmd=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
    echo "  Port ${PROXY_PORT} → $cmd (PID $pid)"
  else
    echo "  Port ${PROXY_PORT} → nothing listening"
  fi

  echo -e "\n${BOLD}Proxy stats:${RESET}"
  if curl -sf "http://localhost:${PROXY_PORT}/livez" &>/dev/null; then
    ok "Proxy UP"
    curl -sf "http://localhost:${PROXY_PORT}/stats" | python3 -c "
import json,sys
d=json.load(sys.stdin)
sess=d.get('display_session') or d.get('persistent_savings',{}).get('display_session',{}) or {}
print(f\"  Requests:     {sess.get('requests',0)}\")
print(f\"  Tokens saved: {sess.get('tokens_saved',0)}\")
print(f\"  Savings:      {sess.get('savings_percent',0):.1f}%\")
print(f\"  Input tokens: {sess.get('total_input_tokens',0)}\")
" 2>/dev/null
  else
    warn "Proxy not reachable — run: ./setup.sh forward"
  fi
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
  if command -v open &>/dev/null; then open "$url"
  elif command -v xdg-open &>/dev/null; then xdg-open "$url"
  else info "Open manually: $url"; fi
}

# ── FIX: Claude Code with proxy check ────────────────────────────────────────
start_claude() {
  step "Starting Claude Code through Headroom proxy"

  # Check if local headroom proxy is running (conflict scenario)
  local pid
  pid=$(lsof -ti tcp:${PROXY_PORT} 2>/dev/null | head -1) || pid=""
  if [[ -n "$pid" ]]; then
    local cmd
    cmd=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
    if echo "$cmd" | grep -qi "headroom"; then
      warn "Local headroom proxy detected on port ${PROXY_PORT}"
      warn "Using it directly (not K8s proxy)"
      ok "Proxy ready at http://127.0.0.1:${PROXY_PORT}"
      ANTHROPIC_BASE_URL="http://127.0.0.1:${PROXY_PORT}" claude
      return
    fi
  fi

  # Check K8s proxy via port-forward
  if ! curl -sf "http://localhost:${PROXY_PORT}/livez" &>/dev/null; then
    warn "Proxy not reachable — starting port-forward..."
    start_forward
    sleep 2
  fi

  if ! curl -sf "http://localhost:${PROXY_PORT}/livez" &>/dev/null; then
    die "Proxy still not reachable. Run ./setup.sh health to diagnose."
  fi

  ok "Proxy healthy — launching Claude Code"
  info "Dashboard: http://localhost:${GUI_PORT}"
  echo ""
  ANTHROPIC_BASE_URL="http://127.0.0.1:${PROXY_PORT}" claude
}

# ── Logs ──────────────────────────────────────────────────────────────────────
show_logs() {
  step "Recent logs"
  echo -e "${BOLD}Proxy logs:${RESET}"
  kubectl logs -n "$NAMESPACE" deploy/headroom-proxy --tail=30 2>/dev/null || warn "Could not get proxy logs"
  echo ""
  echo -e "${BOLD}GUI logs:${RESET}"
  kubectl logs -n "$NAMESPACE" deploy/headroom-gui --tail=30 2>/dev/null || warn "Could not get GUI logs"
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
    step "Removing Podman images"
    for img in "$PROXY_IMAGE" "$PROXY_LOCAL" "$GUI_IMAGE" "$GUI_LOCAL"; do
      podman rmi "$img" 2>/dev/null && ok "Removed $img" || warn "$img not found"
    done
  fi
  ok "Uninstall complete."
}

# ── Install ───────────────────────────────────────────────────────────────────
install() {
  check_deps
  detect_cluster
  build_images
  load_images
  apply_manifests
  patch_deployments
  wait_for_pods
  start_forward
  sleep 2
  health_check

  echo ""
  echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${GREEN}║           Installation complete!                 ║${RESET}"
  echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════╝${RESET}"
  echo ""
  echo -e "  ${BOLD}Dashboard:${RESET}  http://localhost:${GUI_PORT}"
  echo -e "  ${BOLD}Proxy API:${RESET}  http://localhost:${PROXY_PORT}/stats"
  echo ""
  echo -e "  ${CYAN}./setup.sh claude${RESET}    start Claude Code through proxy"
  echo -e "  ${CYAN}./setup.sh start${RESET}     start everything after reboot"
  echo -e "  ${CYAN}./setup.sh health${RESET}    9-point health check"
  echo -e "  ${CYAN}./setup.sh status${RESET}    quick overview"
  echo -e "  ${CYAN}./setup.sh forward${RESET}   restart port-forwards"
  echo -e "  ${CYAN}./setup.sh logs${RESET}      pod logs"
  echo -e "  ${CYAN}./setup.sh uninstall${RESET} remove everything"
  echo ""

  # Generate ~/.zshrc snippet
  local zshrc_snippet="
# Headroom Telemetry GUI — auto-start (added by setup.sh)
alias headroom-start='cd $SCRIPT_DIR && ./setup.sh start'
alias headroom-claude='cd $SCRIPT_DIR && ./setup.sh claude'
alias headroom-health='cd $SCRIPT_DIR && ./setup.sh health'"

  echo -e "${BOLD}Optional: add to ~/.zshrc for quick access:${RESET}"
  echo -e "${CYAN}$zshrc_snippet${RESET}"
  echo ""
  echo -en "${YELLOW}Add these aliases to ~/.zshrc now? [y/N]:${RESET} "
  read -r add_alias
  if [[ "$add_alias" =~ ^[Yy]$ ]]; then
    echo "$zshrc_snippet" >> ~/.zshrc
    ok "Aliases added to ~/.zshrc — run: source ~/.zshrc"
  fi

  open_browser
}

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
  banner
  echo -e "Usage: ${BOLD}$(basename $0) <command>${RESET}"
  echo ""
  echo "Commands:"
  echo -e "  ${CYAN}install${RESET}    Full setup: build, load, deploy, forward, health, open"
  echo -e "  ${CYAN}uninstall${RESET}  Remove all K8s resources, stop forwards, optionally remove images"
  echo -e "  ${CYAN}start${RESET}      Start kind container + port-forwards (use after reboot)"
  echo -e "  ${CYAN}health${RESET}     9-point deep health check"
  echo -e "  ${CYAN}status${RESET}     Quick overview: pods, services, forwards, conflict check, stats"
  echo -e "  ${CYAN}forward${RESET}    Kill conflicts, restart port-forwards"
  echo -e "  ${CYAN}stop${RESET}       Stop all port-forwards"
  echo -e "  ${CYAN}restart${RESET}    Restart both deployments + re-forward"
  echo -e "  ${CYAN}claude${RESET}     Start Claude Code through proxy (auto-fixes connection)"
  echo -e "  ${CYAN}logs${RESET}       Show recent logs from both pods"
  echo -e "  ${CYAN}open${RESET}       Open dashboard in browser"
  echo -e "  ${CYAN}help${RESET}       Show this message"
  echo ""
  echo "After reboot:"
  echo -e "  ${CYAN}./setup.sh start${RESET}   — restarts cluster + forwards automatically"
  echo ""
}

# ── Entry point ───────────────────────────────────────────────────────────────
banner

case "${1:-help}" in
  install)   install ;;
  uninstall) detect_cluster; uninstall ;;
  start)     start_all ;;
  health)    detect_cluster; health_check ;;
  status)    detect_cluster; show_status ;;
  restart)   detect_cluster; restart_deployments ;;
  forward)   detect_cluster; start_forward ;;
  stop)      stop_forward ;;
  claude)    start_claude ;;
  logs)      show_logs ;;
  open)      open_browser ;;
  help|--help|-h) usage ;;
  *) error "Unknown command: $1"; usage; exit 1 ;;
esac
