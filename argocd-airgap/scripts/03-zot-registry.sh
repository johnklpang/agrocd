#!/usr/bin/env bash
# =============================================================================
# 03-zot-registry.sh
#
# Start, stop, and query a local Zot OCI registry for air-gapped image hosting.
#
# Modes:
#   docker|podman|nerdctl  — run Zot as a local container (default: docker/runtime)
#   helm                   — install/upgrade Zot into the Kubernetes cluster
#
# Typical air-gap flow:
#   1. Online:  ./scripts/01-online-prepare.sh --with-zot
#   2. Transfer artifacts/ + scripts/ + zot/ + helm/
#   3. Offline: ./scripts/03-zot-registry.sh start
#   4. Offline: ./scripts/02-airgap-deploy.sh --use-zot
#
# Usage:
#   ./scripts/03-zot-registry.sh <command> [options]
#
# Commands:
#   start     Start Zot (load image if needed) and print PRIVATE_REGISTRY
#   stop      Stop / uninstall Zot
#   status    Show whether Zot is running and the registry address
#   addr      Print registry host:port only (for scripting)
#   wait      Block until the registry /v2/ endpoint responds
#
# Options / environment:
#   --backend MODE        container (default) | binary | helm
#                           container = docker/podman/nerdctl
#                           binary    = run packaged zot binary (no container runtime)
#                           helm      = install into Kubernetes
#   --artifacts DIR       Artifacts from online phase (default: ./artifacts)
#   --name NAME           Container / Helm release name (default: zot)
#   --namespace NS        Helm namespace (default: zot)
#   --port PORT           Listen / host port (default: 5000)
#   --data-dir DIR        Persistent registry data directory
#                         (default: ./artifacts/zot-data)
#   --config FILE         Zot config.json (default: ./zot/config.json)
#   --binary PATH         Path to zot binary (default: artifacts/zot-bin/zot-linux-amd64)
#   --registry HOST:PORT  Override advertised registry address
#                         (default: 127.0.0.1:$PORT for container/binary,
#                          <node-ip>:<nodePort> or svc for helm)
#   --image REF           Zot image override (default: from artifacts/zot-images.txt
#                         or ghcr.io/project-zot/zot:latest)
#   --insecure            Use HTTP / skip TLS when probing (default for lab Zot)
#   --kube-context CTX    kubectl/helm context (helm backend)
#   --wait-timeout DUR    Ready wait timeout (default: 2m)
#   -h, --help
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

COMMAND=""
BACKEND="${ZOT_BACKEND:-container}"
ZOT_NAME="${ZOT_NAME:-zot}"
ZOT_NAMESPACE="${ZOT_NAMESPACE:-zot}"
ZOT_PORT="${ZOT_PORT:-5000}"
ZOT_DATA_DIR="${ZOT_DATA_DIR:-}"
ZOT_CONFIG="${ZOT_CONFIG:-}"
ZOT_IMAGE="${ZOT_IMAGE:-}"
ZOT_BINARY="${ZOT_BINARY:-}"
ZOT_REGISTRY_OVERRIDE="${PRIVATE_REGISTRY:-}"
INSECURE=1
RUNTIME="${CONTAINER_RUNTIME:-}"
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-2m}"

usage() {
  sed -n '2,56p' "$0" | sed 's/^# \?//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    start|stop|status|addr|wait)
      COMMAND="$1"; shift ;;
    --backend)       BACKEND="$2"; shift 2 ;;
    --artifacts)     ARTIFACTS_DIR="$2"; shift 2 ;;
    --name)          ZOT_NAME="$2"; shift 2 ;;
    --namespace)     ZOT_NAMESPACE="$2"; shift 2 ;;
    --port)          ZOT_PORT="$2"; shift 2 ;;
    --data-dir)      ZOT_DATA_DIR="$2"; shift 2 ;;
    --config)        ZOT_CONFIG="$2"; shift 2 ;;
    --binary)        ZOT_BINARY="$2"; shift 2 ;;
    --registry)      ZOT_REGISTRY_OVERRIDE="$2"; shift 2 ;;
    --image)         ZOT_IMAGE="$2"; shift 2 ;;
    --insecure)      INSECURE=1; shift ;;
    --secure)        INSECURE=0; shift ;;
    --runtime)       RUNTIME="$2"; shift 2 ;;
    --kube-context)  KUBE_CONTEXT="$2"; shift 2 ;;
    --wait-timeout)  WAIT_TIMEOUT="$2"; shift 2 ;;
    -h|--help)       usage ;;
    *) die "Unknown argument: $1 (use --help)" ;;
  esac
done

[[ -n "$COMMAND" ]] || die "Command required: start|stop|status|addr|wait (use --help)"

resolve_roots
[[ -n "$RUNTIME" ]] && CONTAINER_RUNTIME="$RUNTIME"

ZOT_DATA_DIR="${ZOT_DATA_DIR:-${ARTIFACTS_DIR}/zot-data}"
ZOT_CONFIG="${ZOT_CONFIG:-${ROOT_DIR}/zot/config.json}"
ZOT_VALUES="${ROOT_DIR}/zot/values-airgap.yaml"
ZOT_IMAGES_LIST="${ARTIFACTS_DIR}/zot-images.txt"
ZOT_IMAGES_TAR="${ARTIFACTS_DIR}/zot-images.tar"
ZOT_CHART_TGZ=""
ZOT_MANIFEST="${ARTIFACTS_DIR}/zot-manifest.env"
ZOT_BINARY="${ZOT_BINARY:-${ARTIFACTS_DIR}/zot-bin/zot-linux-amd64}"
ZOT_PID_FILE="${ARTIFACTS_DIR}/zot.pid"
ZOT_LOG_FILE="${ARTIFACTS_DIR}/zot.log"
ZOT_RUNTIME_CONFIG="${ARTIFACTS_DIR}/zot-runtime-config.json"

HELM_CTX_ARGS=()
KUBECTL_CTX_ARGS=()
if [[ -n "$KUBE_CONTEXT" ]]; then
  HELM_CTX_ARGS+=(--kube-context "$KUBE_CONTEXT")
  KUBECTL_CTX_ARGS+=(--context "$KUBE_CONTEXT")
fi

# ---------------------------------------------------------------------------
# Resolve which Zot image / chart to use from online-phase artifacts
# ---------------------------------------------------------------------------
load_zot_manifest_if_present() {
  if [[ -f "$ZOT_MANIFEST" ]]; then
    load_manifest "$ZOT_MANIFEST"
    if [[ -n "${ZOT_CHART_TGZ_BASENAME:-}" ]]; then
      ZOT_CHART_TGZ="${ARTIFACTS_DIR}/${ZOT_CHART_TGZ_BASENAME}"
    fi
    if [[ -z "$ZOT_IMAGE" && -n "${ZOT_IMAGE_REF:-}" ]]; then
      ZOT_IMAGE="$ZOT_IMAGE_REF"
    fi
  fi
}

resolve_zot_image() {
  if [[ -n "$ZOT_IMAGE" ]]; then
    echo "$ZOT_IMAGE"
    return
  fi
  if [[ -f "$ZOT_IMAGES_LIST" ]]; then
    local first
    first="$(awk 'NF && $0 !~ /^#/ {print; exit}' "$ZOT_IMAGES_LIST")"
    [[ -n "$first" ]] && { echo "$first"; return; }
  fi
  # Fallback — only useful if the host can still pull (not air-gapped)
  echo "ghcr.io/project-zot/zot:v2.1.18"
}

ensure_zot_image_loaded() {
  local runtime="$1"
  local image="$2"

  if "$runtime" image inspect "$image" >/dev/null 2>&1; then
    info "Zot image already present: ${image}"
    return
  fi

  if [[ -f "$ZOT_IMAGES_TAR" ]]; then
    info "Loading Zot image archive ${ZOT_IMAGES_TAR}"
    runtime_load "$runtime" "$ZOT_IMAGES_TAR"
    return
  fi

  # Last resort: try the combined Argo image tar (may include zot if --with-zot merged)
  if [[ -f "$IMAGES_TAR" ]] && grep -qxF "$image" "$IMAGES_LIST" 2>/dev/null; then
    info "Loading combined image archive ${IMAGES_TAR}"
    runtime_load "$runtime" "$IMAGES_TAR"
    return
  fi

  warn "Zot image ${image} not found locally; attempting runtime pull (needs network)"
  pull_image "$runtime" "$image"
}

registry_probe_url() {
  local hostport="$1"
  if [[ "$INSECURE" -eq 1 ]]; then
    echo "http://${hostport}/v2/"
  else
    echo "https://${hostport}/v2/"
  fi
}

wait_for_registry() {
  local hostport="$1"
  local url
  url="$(registry_probe_url "$hostport")"
  info "Waiting for Zot at ${url}"
  local deadline=120
  if [[ "$WAIT_TIMEOUT" =~ ^([0-9]+)s$ ]]; then
    deadline="${BASH_REMATCH[1]}"
  elif [[ "$WAIT_TIMEOUT" =~ ^([0-9]+)m$ ]]; then
    deadline=$((BASH_REMATCH[1] * 60))
  elif [[ "$WAIT_TIMEOUT" =~ ^[0-9]+$ ]]; then
    deadline="$WAIT_TIMEOUT"
  fi
  local i=0
  while ((i < deadline)); do
    if curl -fsS ${INSECURE:+--insecure} -o /dev/null "$url" 2>/dev/null; then
      info "Zot is ready: ${hostport}"
      return 0
    fi
    # /v2/ may return 401 when auth is enabled — still means the registry is up
    local code
    code="$(curl -sS ${INSECURE:+--insecure} -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)"
    if [[ "$code" == "200" || "$code" == "401" ]]; then
      info "Zot is ready: ${hostport} (HTTP ${code})"
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  die "Timed out waiting for Zot at ${url}"
}

# ---------------------------------------------------------------------------
# Container backend (docker / podman / nerdctl)
# ---------------------------------------------------------------------------
container_addr() {
  if [[ -n "$ZOT_REGISTRY_OVERRIDE" ]]; then
    echo "$ZOT_REGISTRY_OVERRIDE"
  else
    echo "127.0.0.1:${ZOT_PORT}"
  fi
}

container_start() {
  require_cmds curl
  local runtime
  runtime="$(detect_runtime)"
  load_zot_manifest_if_present
  local image
  image="$(resolve_zot_image)"

  [[ -f "$ZOT_CONFIG" ]] || die "Zot config not found: ${ZOT_CONFIG}"
  mkdir -p "$ZOT_DATA_DIR"

  ensure_zot_image_loaded "$runtime" "$image"

  if "$runtime" inspect "$ZOT_NAME" >/dev/null 2>&1; then
    local state
    state="$("$runtime" inspect -f '{{.State.Running}}' "$ZOT_NAME" 2>/dev/null || echo false)"
    if [[ "$state" == "true" ]]; then
      info "Zot container '${ZOT_NAME}' already running"
    else
      info "Starting existing Zot container '${ZOT_NAME}'"
      "$runtime" start "$ZOT_NAME"
    fi
  else
    info "Creating Zot container '${ZOT_NAME}' on port ${ZOT_PORT}"
    if ! "$runtime" run -d \
      --name "$ZOT_NAME" \
      --restart unless-stopped \
      -p "${ZOT_PORT}:5000" \
      -v "${ZOT_CONFIG}:/etc/zot/config.json:ro" \
      -v "${ZOT_DATA_DIR}:/var/lib/registry" \
      "$image"; then
      warn "Failed to start Zot container; falling back to binary backend"
      BACKEND=binary
      binary_start
      return
    fi
  fi

  local addr
  addr="$(container_addr)"
  wait_for_registry "$addr"
  write_zot_env "$addr"
  print_zot_ready "$addr"
}

container_stop() {
  local runtime
  runtime="$(detect_runtime)"
  if "$runtime" inspect "$ZOT_NAME" >/dev/null 2>&1; then
    info "Stopping and removing Zot container '${ZOT_NAME}'"
    "$runtime" rm -f "$ZOT_NAME" >/dev/null
  else
    warn "Zot container '${ZOT_NAME}' not found"
  fi
}

container_status() {
  local runtime addr
  runtime="$(detect_runtime)"
  addr="$(container_addr)"
  if "$runtime" inspect "$ZOT_NAME" >/dev/null 2>&1; then
    local state
    state="$("$runtime" inspect -f 'running={{.State.Running}} status={{.State.Status}}' "$ZOT_NAME")"
    info "Container ${ZOT_NAME}: ${state}"
  else
    info "Container ${ZOT_NAME}: not found"
  fi
  info "Registry address: ${addr}"
  local url code
  url="$(registry_probe_url "$addr")"
  code="$(curl -sS ${INSECURE:+--insecure} -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo down)"
  info "Probe ${url} -> ${code}"
}

# ---------------------------------------------------------------------------
# Binary backend — run packaged zot binary (no container runtime required)
# ---------------------------------------------------------------------------
write_runtime_config() {
  [[ -f "$ZOT_CONFIG" ]] || die "Zot config not found: ${ZOT_CONFIG}"
  mkdir -p "$ZOT_DATA_DIR"
  # Rewrite listen port + storage root for this host without requiring jq
  awk -v port="$ZOT_PORT" -v root="$ZOT_DATA_DIR" '
    /"port":/ { sub(/"port":[[:space:]]*"[^"]*"/, "\"port\": \"" port "\"") }
    /"rootDirectory":/ { sub(/"rootDirectory":[[:space:]]*"[^"]*"/, "\"rootDirectory\": \"" root "\"") }
    { print }
  ' "$ZOT_CONFIG" >"$ZOT_RUNTIME_CONFIG"
}

binary_addr() { container_addr; }

binary_start() {
  require_cmds curl
  [[ -x "$ZOT_BINARY" ]] || die "Zot binary not found/executable: ${ZOT_BINARY} (re-run online prepare with --with-zot)"

  if [[ -f "$ZOT_PID_FILE" ]]; then
    local old_pid
    old_pid="$(cat "$ZOT_PID_FILE" 2>/dev/null || true)"
    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
      info "Zot binary already running (pid ${old_pid})"
      local addr
      addr="$(binary_addr)"
      wait_for_registry "$addr"
      write_zot_env "$addr"
      print_zot_ready "$addr"
      return
    fi
  fi

  write_runtime_config
  info "Starting Zot binary ${ZOT_BINARY} on port ${ZOT_PORT}"
  info "Config: ${ZOT_RUNTIME_CONFIG}  data: ${ZOT_DATA_DIR}"
  nohup "$ZOT_BINARY" serve "$ZOT_RUNTIME_CONFIG" >"$ZOT_LOG_FILE" 2>&1 &
  echo $! >"$ZOT_PID_FILE"
  info "Zot pid $(cat "$ZOT_PID_FILE") (logs: ${ZOT_LOG_FILE})"

  local addr
  addr="$(binary_addr)"
  wait_for_registry "$addr"
  write_zot_env "$addr"
  print_zot_ready "$addr"
}

binary_stop() {
  if [[ -f "$ZOT_PID_FILE" ]]; then
    local pid
    pid="$(cat "$ZOT_PID_FILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      info "Stopping Zot pid ${pid}"
      kill "$pid" 2>/dev/null || true
      sleep 1
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$ZOT_PID_FILE"
  else
    warn "No Zot pid file at ${ZOT_PID_FILE}"
  fi
  # Best-effort: stop anything listening on the port that looks like zot
  if command -v fuser >/dev/null 2>&1; then
    fuser -k "${ZOT_PORT}/tcp" 2>/dev/null || true
  fi
}

binary_status() {
  local addr pid="-"
  addr="$(binary_addr)"
  if [[ -f "$ZOT_PID_FILE" ]]; then
    pid="$(cat "$ZOT_PID_FILE" 2>/dev/null || echo -)"
    if [[ "$pid" != "-" ]] && kill -0 "$pid" 2>/dev/null; then
      info "Binary Zot: running (pid ${pid})"
    else
      info "Binary Zot: pid file present but process not running (pid ${pid})"
    fi
  else
    info "Binary Zot: not running"
  fi
  info "Registry address: ${addr}"
  local url code
  url="$(registry_probe_url "$addr")"
  code="$(curl -sS ${INSECURE:+--insecure} -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo down)"
  info "Probe ${url} -> ${code}"
}

# ---------------------------------------------------------------------------
# Helm backend (in-cluster Zot)
# ---------------------------------------------------------------------------
helm_addr() {
  if [[ -n "$ZOT_REGISTRY_OVERRIDE" ]]; then
    echo "$ZOT_REGISTRY_OVERRIDE"
    return
  fi

  # Prefer NodePort on the first schedulable node when service type is NodePort
  local svc_type node_port cluster_ip
  svc_type="$(kubectl "${KUBECTL_CTX_ARGS[@]}" -n "$ZOT_NAMESPACE" get svc "$ZOT_NAME" -o jsonpath='{.spec.type}' 2>/dev/null || true)"
  if [[ "$svc_type" == "NodePort" ]]; then
    node_port="$(kubectl "${KUBECTL_CTX_ARGS[@]}" -n "$ZOT_NAMESPACE" get svc "$ZOT_NAME" -o jsonpath='{.spec.ports[0].nodePort}')"
    local node_ip
    node_ip="$(kubectl "${KUBECTL_CTX_ARGS[@]}" get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
    if [[ -n "$node_ip" && -n "$node_port" ]]; then
      echo "${node_ip}:${node_port}"
      return
    fi
  fi

  cluster_ip="$(kubectl "${KUBECTL_CTX_ARGS[@]}" -n "$ZOT_NAMESPACE" get svc "$ZOT_NAME" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
  if [[ -n "$cluster_ip" && "$cluster_ip" != "None" ]]; then
    echo "${cluster_ip}:5000"
    return
  fi

  # In-cluster DNS name (useful from pods; not from the bastion)
  echo "${ZOT_NAME}.${ZOT_NAMESPACE}.svc.cluster.local:5000"
}

helm_start() {
  require_cmds helm kubectl curl
  load_zot_manifest_if_present

  local image chart_ref
  image="$(resolve_zot_image)"
  split_image_ref "$image"
  local repo="$_img_repo" tag="$_img_tag"

  # Ensure the Zot image is available to the cluster: load on single-node or
  # require the operator to have mirrored it. For multi-node, push to an
  # already-running registry first — chicken/egg is solved by container backend
  # bootstrap, then helm can pull from that, OR use node-local load.
  local runtime=""
  if command -v docker >/dev/null 2>&1 || command -v podman >/dev/null 2>&1 || command -v nerdctl >/dev/null 2>&1; then
    runtime="$(detect_runtime)"
    ensure_zot_image_loaded "$runtime" "$image"
  fi

  if [[ -n "$ZOT_CHART_TGZ" && -f "$ZOT_CHART_TGZ" ]]; then
    chart_ref="$ZOT_CHART_TGZ"
    info "Using local Zot chart package: ${chart_ref}"
  else
    # Online fallback
    chart_ref="oci://ghcr.io/project-zot/helm-charts/zot"
    warn "No local Zot chart in artifacts; using ${chart_ref} (needs network)"
  fi

  local set_args=(
    --set "image.repository=${repo}"
    --set "service.type=NodePort"
    --set "service.port=5000"
  )
  [[ -n "$tag" ]] && set_args+=(--set "image.tag=${tag}")

  local values_args=()
  [[ -f "$ZOT_VALUES" ]] && values_args+=(-f "$ZOT_VALUES")

  info "Installing / upgrading Zot release '${ZOT_NAME}' in namespace '${ZOT_NAMESPACE}'"
  helm "${HELM_CTX_ARGS[@]}" upgrade --install "$ZOT_NAME" "$chart_ref" \
    --namespace "$ZOT_NAMESPACE" \
    --create-namespace \
    --timeout "$WAIT_TIMEOUT" \
    "${values_args[@]+"${values_args[@]}"}" \
    "${set_args[@]}"

  kubectl "${KUBECTL_CTX_ARGS[@]}" -n "$ZOT_NAMESPACE" rollout status "deploy/${ZOT_NAME}" --timeout="$WAIT_TIMEOUT" \
    || kubectl "${KUBECTL_CTX_ARGS[@]}" -n "$ZOT_NAMESPACE" wait --for=condition=Available "deploy/${ZOT_NAME}" --timeout="$WAIT_TIMEOUT" \
    || warn "Could not confirm Deployment ready; probing registry endpoint next"

  local addr
  addr="$(helm_addr)"
  # NodePort may take a moment
  sleep 2
  wait_for_registry "$addr" || warn "Direct probe of ${addr} failed — nodes may still reach ClusterIP/NodePort"
  write_zot_env "$addr"
  print_zot_ready "$addr"
}

helm_stop() {
  require_cmds helm
  info "Uninstalling Helm release '${ZOT_NAME}' from namespace '${ZOT_NAMESPACE}'"
  helm "${HELM_CTX_ARGS[@]}" uninstall "$ZOT_NAME" --namespace "$ZOT_NAMESPACE" || warn "Uninstall failed or release missing"
}

helm_status() {
  require_cmds kubectl
  local addr
  addr="$(helm_addr)"
  kubectl "${KUBECTL_CTX_ARGS[@]}" -n "$ZOT_NAMESPACE" get deploy,svc,pods -l "app.kubernetes.io/name=zot" 2>/dev/null \
    || kubectl "${KUBECTL_CTX_ARGS[@]}" -n "$ZOT_NAMESPACE" get deploy,svc,pods 2>/dev/null \
    || warn "Unable to list Zot resources"
  info "Registry address: ${addr}"
}

# ---------------------------------------------------------------------------
# Persist env for 02-airgap-deploy.sh --use-zot
# ---------------------------------------------------------------------------
write_zot_env() {
  local addr="$1"
  local env_file="${ARTIFACTS_DIR}/zot.env"
  cat >"$env_file" <<EOF
# Generated by 03-zot-registry.sh on $(date -u +'%Y-%m-%dT%H:%M:%SZ')
PRIVATE_REGISTRY=${addr}
ZOT_REGISTRY=${addr}
# Lab Zot defaults to HTTP — keep insecure pushes / pulls enabled
INSECURE_REGISTRY=1
REGISTRY_REWRITE_MODE=${REGISTRY_REWRITE_MODE:-keep-path}
EOF
  info "Wrote ${env_file}"
}

print_zot_ready() {
  local addr="$1"
  section "Zot registry ready"
  cat <<EOF

PRIVATE_REGISTRY=${addr}

Next steps:

  # Export for this shell, or rely on --use-zot (reads artifacts/zot.env)
  export PRIVATE_REGISTRY=${addr}

  # Push Argo CD images into Zot and install:
  ./scripts/02-airgap-deploy.sh --use-zot --artifacts ${ARTIFACTS_DIR}

Kubernetes nodes must be allowed to pull from this HTTP registry.
For containerd, add a hosts.toml entry for ${addr} with skip_verify / plain HTTP.
For Docker, add the host to insecure-registries.

EOF
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "$BACKEND" in
  container|docker|podman|nerdctl)
    BACKEND=container
    ;;
  binary|bin|native)
    BACKEND=binary
    ;;
  helm|k8s|kubernetes)
    BACKEND=helm
    ;;
  *)
    die "Invalid --backend '${BACKEND}' (expected: container|binary|helm)"
    ;;
esac

case "$COMMAND-$BACKEND" in
  start-container)  container_start ;;
  stop-container)   container_stop ;;
  status-container) container_status ;;
  addr-container)   container_addr; exit 0 ;;
  wait-container)   wait_for_registry "$(container_addr)" ;;
  start-binary)     binary_start ;;
  stop-binary)      binary_stop ;;
  status-binary)    binary_status ;;
  addr-binary)      binary_addr; exit 0 ;;
  wait-binary)      wait_for_registry "$(binary_addr)" ;;
  start-helm)       helm_start ;;
  stop-helm)        helm_stop ;;
  status-helm)      helm_status ;;
  addr-helm)        helm_addr; exit 0 ;;
  wait-helm)        wait_for_registry "$(helm_addr)" ;;
  *) die "Unhandled command/backend: ${COMMAND}/${BACKEND}" ;;
esac
