#!/usr/bin/env bash
# =============================================================================
# 02-airgap-deploy.sh
#
# AIR-GAPPED PHASE — run on a machine WITHOUT internet access.
#
# Prerequisites (already transferred from the online phase):
#   artifacts/argo-cd-*.tgz
#   artifacts/argo-cd-images.tar
#   artifacts/images.txt
#   artifacts/image-map.tsv
#   artifacts/manifest.env
#
# What this script does:
#   1. Loads container images from the tar archive into the local runtime,
#      OR retags and pushes them to a private internal registry.
#   2. Generates Helm values that point image repositories at the private
#      registry (when configured).
#   3. Installs or upgrades Argo CD via Helm using the local chart package.
#   4. Waits for the deployment to become ready.
#   5. Prints the initial admin password retrieval command.
#
# Usage:
#   ./scripts/02-airgap-deploy.sh [options]
#
# Options / environment:
#   --artifacts DIR         Directory with online-phase artifacts (default: ./artifacts)
#   --namespace NS          Kubernetes namespace (default: argocd)
#   --release NAME          Helm release name (default: argocd)
#   --registry HOST[:PORT]  Private registry (env: PRIVATE_REGISTRY). If unset,
#                           images are loaded into the local runtime only.
#   --registry-user USER    Registry username (env: PRIVATE_REGISTRY_USER)
#   --registry-pass PASS    Registry password (env: PRIVATE_REGISTRY_PASSWORD)
#   --insecure-registry     Pass --insecure / skip TLS verify when pushing
#   --mode MODE             load | push | load-and-push  (default: auto)
#                             auto = push if --registry set, else load
#   --values FILE           Extra Helm values file(s); may be repeated
#   --runtime NAME          Container CLI: docker|podman|nerdctl|ctr
#   --ctr-namespace NS      containerd namespace for ctr (default: k8s.io)
#   --ctr-address PATH      containerd socket path
#   --kube-context CTX      kubectl/helm context
#   --wait-timeout DUR      Helm --timeout (default: 10m)
#   --dry-run               Render / plan only; do not install
#   --skip-helm             Only load/push images; skip Helm install
#   --rewrite-mode MODE     keep-path | flatten  (default: keep-path)
#   --use-zot               Use the local Zot registry started by
#                           03-zot-registry.sh (reads artifacts/zot.env).
#                           Sets PRIVATE_REGISTRY + insecure HTTP pushes.
#   -h, --help              Show help
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
NAMESPACE="${NAMESPACE:-argocd}"
RELEASE_NAME="${RELEASE_NAME:-argocd}"
PRIVATE_REGISTRY="${PRIVATE_REGISTRY:-}"
PRIVATE_REGISTRY_USER="${PRIVATE_REGISTRY_USER:-}"
PRIVATE_REGISTRY_PASSWORD="${PRIVATE_REGISTRY_PASSWORD:-}"
INSECURE_REGISTRY="${INSECURE_REGISTRY:-0}"
MODE="${MODE:-auto}"
RUNTIME="${CONTAINER_RUNTIME:-}"
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-10m}"
DRY_RUN=0
SKIP_HELM=0
USE_ZOT=0
REGISTRY_REWRITE_MODE="${REGISTRY_REWRITE_MODE:-keep-path}"
EXTRA_VALUES=()

usage() {
  sed -n '2,52p' "$0" | sed 's/^# \?//'
  exit 0
}

# ---------------------------------------------------------------------------
# Parse args
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --artifacts)         ARTIFACTS_DIR="$2"; shift 2 ;;
    --namespace)         NAMESPACE="$2"; shift 2 ;;
    --release)           RELEASE_NAME="$2"; shift 2 ;;
    --registry)          PRIVATE_REGISTRY="$2"; shift 2 ;;
    --registry-user)     PRIVATE_REGISTRY_USER="$2"; shift 2 ;;
    --registry-pass)     PRIVATE_REGISTRY_PASSWORD="$2"; shift 2 ;;
    --insecure-registry) INSECURE_REGISTRY=1; shift ;;
    --mode)              MODE="$2"; shift 2 ;;
    --values)            EXTRA_VALUES+=("$2"); shift 2 ;;
    --runtime)           RUNTIME="$2"; shift 2 ;;
    --ctr-namespace)     CTR_NAMESPACE="$2"; shift 2 ;;
    --ctr-address)       CTR_ADDRESS="$2"; shift 2 ;;
    --kube-context)      KUBE_CONTEXT="$2"; shift 2 ;;
    --wait-timeout)      WAIT_TIMEOUT="$2"; shift 2 ;;
    --dry-run)           DRY_RUN=1; shift ;;
    --skip-helm)         SKIP_HELM=1; shift ;;
    --rewrite-mode)      REGISTRY_REWRITE_MODE="$2"; shift 2 ;;
    --use-zot)           USE_ZOT=1; shift ;;
    -h|--help)           usage ;;
    *) die "Unknown argument: $1 (use --help)" ;;
  esac
done

resolve_roots
[[ -n "$RUNTIME" ]] && CONTAINER_RUNTIME="$RUNTIME"
export REGISTRY_REWRITE_MODE
export CTR_NAMESPACE="${CTR_NAMESPACE:-k8s.io}"
export CTR_ADDRESS="${CTR_ADDRESS:-}"

# ---------------------------------------------------------------------------
# Zot integration: load artifacts/zot.env produced by 03-zot-registry.sh
# ---------------------------------------------------------------------------
if [[ "$USE_ZOT" -eq 1 ]]; then
  ZOT_ENV="${ARTIFACTS_DIR}/zot.env"
  if [[ ! -f "$ZOT_ENV" ]]; then
    die "--use-zot requires ${ZOT_ENV}. Start Zot first: ./scripts/03-zot-registry.sh start"
  fi
  info "Loading Zot registry settings from ${ZOT_ENV}"
  load_manifest "$ZOT_ENV"
  PRIVATE_REGISTRY="${PRIVATE_REGISTRY:-${ZOT_REGISTRY:-}}"
  [[ -n "$PRIVATE_REGISTRY" ]] || die "zot.env did not define PRIVATE_REGISTRY"
  # Lab Zot speaks plain HTTP by default
  INSECURE_REGISTRY=1
  info "Using Zot registry: ${PRIVATE_REGISTRY} (insecure HTTP pushes enabled)"
fi

# Propagate insecure flag to pull helpers (after --use-zot may set it)
export PULL_INSECURE="$INSECURE_REGISTRY"

# Resolve mode
case "$MODE" in
  auto)
    if [[ -n "$PRIVATE_REGISTRY" ]]; then
      MODE="load-and-push"
    else
      MODE="load"
    fi
    ;;
  load|push|load-and-push) ;;
  *) die "Invalid --mode '${MODE}' (expected: auto|load|push|load-and-push)" ;;
esac

if [[ "$MODE" == "push" || "$MODE" == "load-and-push" ]]; then
  [[ -n "$PRIVATE_REGISTRY" ]] || die "--registry / PRIVATE_REGISTRY is required for mode=${MODE}"
fi

require_cmds awk sort
RUNTIME="$(detect_runtime)"
if [[ "$RUNTIME" == "ctr" ]]; then
  require_cmds ctr
fi

# helm/kubectl only required when we will talk to the cluster
if [[ "$SKIP_HELM" -eq 0 ]]; then
  require_cmds helm kubectl
fi

# ---------------------------------------------------------------------------
# Load online-phase manifest and locate artifacts
# ---------------------------------------------------------------------------
section "Argo CD air-gap OFFLINE deploy"
[[ -f "$MANIFEST_FILE" ]] || die "Missing ${MANIFEST_FILE} — did you copy artifacts from the online phase?"
load_manifest "$MANIFEST_FILE"

CHART_TGZ="${ARTIFACTS_DIR}/${CHART_TGZ_BASENAME:?manifest missing CHART_TGZ_BASENAME}"
IMAGES_TAR="${ARTIFACTS_DIR}/${IMAGES_TAR_BASENAME:?manifest missing IMAGES_TAR_BASENAME}"
IMAGES_LIST="${ARTIFACTS_DIR}/${IMAGES_LIST_BASENAME:?manifest missing IMAGES_LIST_BASENAME}"
IMAGE_MAP="${ARTIFACTS_DIR}/${IMAGE_MAP_BASENAME:?manifest missing IMAGE_MAP_BASENAME}"

[[ -f "$CHART_TGZ" ]]    || die "Chart package not found: $CHART_TGZ"
[[ -f "$IMAGES_TAR" ]]   || die "Images archive not found: $IMAGES_TAR"
[[ -f "$IMAGES_LIST" ]]  || die "Images list not found: $IMAGES_LIST"

info "Chart package       : ${CHART_TGZ}"
info "Images archive      : ${IMAGES_TAR}"
info "Chart version       : ${CHART_VERSION:-unknown} (app ${APP_VERSION:-unknown})"
info "Namespace / release : ${NAMESPACE} / ${RELEASE_NAME}"
info "Mode                : ${MODE}"
info "Private registry    : ${PRIVATE_REGISTRY:-<none — local load only>}"
info "Container runtime   : ${RUNTIME}"
if [[ "$RUNTIME" == "ctr" ]]; then
  info "ctr namespace       : ${CTR_NAMESPACE}"
fi
info "Rewrite mode        : ${REGISTRY_REWRITE_MODE}"

HELM_CTX_ARGS=()
KUBECTL_CTX_ARGS=()
if [[ -n "$KUBE_CONTEXT" ]]; then
  HELM_CTX_ARGS+=(--kube-context "$KUBE_CONTEXT")
  KUBECTL_CTX_ARGS+=(--context "$KUBE_CONTEXT")
fi

# ---------------------------------------------------------------------------
# Helpers: registry login
# ---------------------------------------------------------------------------
registry_login() {
  [[ -n "$PRIVATE_REGISTRY" ]] || return 0
  if [[ -n "$PRIVATE_REGISTRY_USER" ]]; then
    info "Logging into registry ${PRIVATE_REGISTRY} as ${PRIVATE_REGISTRY_USER}"
    runtime_login "$RUNTIME" "$PRIVATE_REGISTRY" \
      "$PRIVATE_REGISTRY_USER" "$PRIVATE_REGISTRY_PASSWORD" "$INSECURE_REGISTRY"
  else
    warn "No registry credentials provided; assuming anonymous or pre-authenticated access"
  fi
}

# ---------------------------------------------------------------------------
# 1. Load images into local runtime
# ---------------------------------------------------------------------------
load_images() {
  section "1/4 Load images from tar archive"
  info "Loading ${IMAGES_TAR} into ${RUNTIME}..."
  runtime_load "$RUNTIME" "$IMAGES_TAR"
  info "Image load complete"
}

# ---------------------------------------------------------------------------
# 2. Retag + push to private registry; write rewritten image map
# ---------------------------------------------------------------------------
push_images() {
  section "2/4 Retag and push images to private registry"

  registry_login

  local rewritten_map
  rewritten_map="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$rewritten_map'" RETURN

  local original new_image
  while IFS= read -r original || [[ -n "$original" ]]; do
    [[ -z "$original" || "$original" =~ ^[[:space:]]*# ]] && continue
    new_image="$(rewrite_image "$original" "$PRIVATE_REGISTRY")"
    info "Tag  ${original}"
    info "  -> ${new_image}"
    runtime_tag "$RUNTIME" "$original" "$new_image"

    info "Push ${new_image}"
    push_image "$RUNTIME" "$new_image" "$INSECURE_REGISTRY"

    printf '%s\t%s\n' "$original" "$new_image" >>"$rewritten_map"
  done <"$IMAGES_LIST"

  cp -f "$rewritten_map" "$IMAGE_MAP"
  info "Updated image map: ${IMAGE_MAP}"
}

# ---------------------------------------------------------------------------
# Generate Helm --set / values overrides from the image map so every
# discovered image is pulled from the private registry (or local mirror).
#
# Strategy: set global.image.repository + per-component repositories based on
# image path heuristics. Also emit a generic values file that documents the
# full mapping for operators.
# ---------------------------------------------------------------------------
# Split an image reference into repository + tag (best-effort).
# Sets globals: _img_repo _img_tag  — provided by lib/common.sh as split_image_ref

generate_airgap_values() {
  local out_file="$1"
  local registry="${PRIVATE_REGISTRY:-}"

  info "Generating air-gap Helm values -> ${out_file}"

  # Sensible defaults matching recent argo-helm chart upstream repositories.
  # These are overwritten from the discovered image map whenever possible.
  local argocd_repo="quay.io/argoproj/argocd"
  local dex_repo="ghcr.io/dexidp/dex"
  # Upstream chart hosts have shifted over time (public.ecr.aws ↔ ecr-public.aws.com).
  # The image map from the online phase always wins; these are fallbacks only.
  local redis_repo="ecr-public.aws.com/docker/library/redis"
  local redis_exporter_repo="public.ecr.aws/bitnami/redis-exporter"
  local haproxy_repo="ecr-public.aws.com/docker/library/haproxy"
  local argocd_tag="${APP_VERSION:-}"
  local dex_tag=""
  local redis_tag=""

  local orig new
  if [[ -f "$IMAGE_MAP" ]]; then
    while IFS=$'\t' read -r orig new || [[ -n "$orig" ]]; do
      [[ -z "$orig" || "$orig" =~ ^[[:space:]]*# ]] && continue
      split_image_ref "$new"
      case "$orig" in
        *argoproj/argocd*|*argocd/argocd*)
          argocd_repo="$_img_repo"
          [[ -n "$_img_tag" ]] && argocd_tag="$_img_tag"
          ;;
        *dexidp/dex*)
          dex_repo="$_img_repo"
          [[ -n "$_img_tag" ]] && dex_tag="$_img_tag"
          ;;
        *redis-exporter*|*bitnami/redis-exporter*)
          redis_exporter_repo="$_img_repo"
          ;;
        *haproxy*)
          haproxy_repo="$_img_repo"
          ;;
        *redis*)
          redis_repo="$_img_repo"
          [[ -n "$_img_tag" ]] && redis_tag="$_img_tag"
          ;;
      esac
    done <"$IMAGE_MAP"
  fi

  {
    echo "# Auto-generated by 02-airgap-deploy.sh"
    echo "# Chart: ${CHART_NAME:-argo-cd} ${CHART_VERSION:-} (app ${APP_VERSION:-})"
    echo "# Registry: ${registry:-<local runtime / node-local images>}"
    echo
    echo "global:"
    echo "  image:"
    echo "    repository: ${argocd_repo}"
    [[ -n "$argocd_tag" ]] && echo "    tag: \"${argocd_tag}\""
    echo "    imagePullPolicy: IfNotPresent"
    if [[ -n "${PRIVATE_REGISTRY_USER:-}" ]]; then
      echo "  imagePullSecrets:"
      echo "    - name: argocd-registry-secret"
    fi
    echo
    echo "controller:"
    echo "  image:"
    echo "    repository: ${argocd_repo}"
    [[ -n "$argocd_tag" ]] && echo "    tag: \"${argocd_tag}\""
    echo
    echo "server:"
    echo "  image:"
    echo "    repository: ${argocd_repo}"
    [[ -n "$argocd_tag" ]] && echo "    tag: \"${argocd_tag}\""
    echo "  service:"
    echo "    type: ClusterIP"
    echo
    echo "repoServer:"
    echo "  image:"
    echo "    repository: ${argocd_repo}"
    [[ -n "$argocd_tag" ]] && echo "    tag: \"${argocd_tag}\""
    echo
    echo "applicationSet:"
    echo "  image:"
    echo "    repository: ${argocd_repo}"
    [[ -n "$argocd_tag" ]] && echo "    tag: \"${argocd_tag}\""
    echo
    echo "notifications:"
    echo "  image:"
    echo "    repository: ${argocd_repo}"
    [[ -n "$argocd_tag" ]] && echo "    tag: \"${argocd_tag}\""
    echo
    echo "dex:"
    echo "  image:"
    echo "    repository: ${dex_repo}"
    [[ -n "$dex_tag" ]] && echo "    tag: \"${dex_tag}\""
    echo
    echo "redis:"
    echo "  image:"
    echo "    repository: ${redis_repo}"
    [[ -n "$redis_tag" ]] && echo "    tag: \"${redis_tag}\""
    echo
    echo "redis-ha:"
    echo "  enabled: false"
    echo "  image:"
    echo "    repository: ${redis_repo}"
    [[ -n "$redis_tag" ]] && echo "    tag: \"${redis_tag}\""
    echo "  haproxy:"
    echo "    image:"
    echo "      repository: ${haproxy_repo}"
    echo "  exporter:"
    echo "    image:"
    echo "      repository: ${redis_exporter_repo}"
  } >"$out_file"
}

# ---------------------------------------------------------------------------
# Optional: create an imagePullSecret when registry credentials are provided
# ---------------------------------------------------------------------------
ensure_pull_secret() {
  [[ -n "$PRIVATE_REGISTRY" && -n "$PRIVATE_REGISTRY_USER" ]] || return 0

  info "Ensuring namespace ${NAMESPACE} and imagePullSecret argocd-registry-secret"
  kubectl "${KUBECTL_CTX_ARGS[@]}" create namespace "$NAMESPACE" --dry-run=client -o yaml \
    | kubectl "${KUBECTL_CTX_ARGS[@]}" apply -f -

  local docker_server="$PRIVATE_REGISTRY"
  # kubectl create docker-registry expects the registry host
  kubectl "${KUBECTL_CTX_ARGS[@]}" -n "$NAMESPACE" create secret docker-registry argocd-registry-secret \
    --docker-server="$docker_server" \
    --docker-username="$PRIVATE_REGISTRY_USER" \
    --docker-password="$PRIVATE_REGISTRY_PASSWORD" \
    --dry-run=client -o yaml \
    | kubectl "${KUBECTL_CTX_ARGS[@]}" apply -f -
}

# ---------------------------------------------------------------------------
# 3. Helm install / upgrade
# ---------------------------------------------------------------------------
helm_install() {
  section "3/4 Install / upgrade Argo CD with local chart"

  local gen_values="${ARTIFACTS_DIR}/values-generated-airgap.yaml"
  generate_airgap_values "$gen_values"

  ensure_pull_secret

  local helm_args=(
    upgrade --install "$RELEASE_NAME" "$CHART_TGZ"
    --namespace "$NAMESPACE"
    --create-namespace
    --timeout "$WAIT_TIMEOUT"
    -f "$gen_values"
  )

  # Starter / operator values from the repo or artifacts
  if [[ -f "${ARTIFACTS_DIR}/values-airgap.yaml" ]]; then
    helm_args+=(-f "${ARTIFACTS_DIR}/values-airgap.yaml")
  elif [[ -f "${HELM_DIR}/values-airgap.yaml" ]]; then
    helm_args+=(-f "${HELM_DIR}/values-airgap.yaml")
  fi

  local vf
  for vf in "${EXTRA_VALUES[@]+"${EXTRA_VALUES[@]}"}"; do
    [[ -f "$vf" ]] || die "Values file not found: $vf"
    helm_args+=(-f "$vf")
  done

  helm_args+=("${HELM_CTX_ARGS[@]+"${HELM_CTX_ARGS[@]}"}")

  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "Dry-run: helm ${helm_args[*]} --dry-run"
    helm "${helm_args[@]}" --dry-run
    return
  fi

  info "Running: helm ${helm_args[*]}"
  helm "${helm_args[@]}"

  info "Waiting for Argo CD workloads to become Ready..."
  # Wait on the primary Deployments created by the chart
  local deploy
  for deploy in "${RELEASE_NAME}-server" "${RELEASE_NAME}-repo-server" "${RELEASE_NAME}-application-controller"; do
    # application-controller may be a StatefulSet depending on chart values
    if kubectl "${KUBECTL_CTX_ARGS[@]}" -n "$NAMESPACE" get deploy "$deploy" >/dev/null 2>&1; then
      kubectl "${KUBECTL_CTX_ARGS[@]}" -n "$NAMESPACE" rollout status "deploy/${deploy}" --timeout="$WAIT_TIMEOUT"
    elif kubectl "${KUBECTL_CTX_ARGS[@]}" -n "$NAMESPACE" get sts "$deploy" >/dev/null 2>&1; then
      kubectl "${KUBECTL_CTX_ARGS[@]}" -n "$NAMESPACE" rollout status "sts/${deploy}" --timeout="$WAIT_TIMEOUT"
    else
      # Chart names: argocd-server, argocd-repo-server, argocd-application-controller
      warn "Workload ${deploy} not found yet; will rely on aggregate wait"
    fi
  done

  # Broader readiness: all pods in namespace with app.kubernetes.io/part-of=argocd
  kubectl "${KUBECTL_CTX_ARGS[@]}" -n "$NAMESPACE" wait \
    --for=condition=Ready pods \
    -l app.kubernetes.io/part-of=argocd \
    --timeout="$WAIT_TIMEOUT" \
    || warn "Some pods not Ready within ${WAIT_TIMEOUT}; check: kubectl -n ${NAMESPACE} get pods"
}

# ---------------------------------------------------------------------------
# 4. Print admin password command
# ---------------------------------------------------------------------------
print_admin_password_help() {
  section "4/4 Initial admin password"

  cat <<EOF
Argo CD is installed (or image prep is complete).

Retrieve the initial admin password with:

  kubectl ${KUBECTL_CTX_ARGS[*]+"${KUBECTL_CTX_ARGS[*]}"} -n ${NAMESPACE} get secret argocd-initial-admin-secret \\
    -o jsonpath="{.data.password}" | base64 -d; echo

Port-forward the API server (example):

  kubectl ${KUBECTL_CTX_ARGS[*]+"${KUBECTL_CTX_ARGS[*]}"} -n ${NAMESPACE} port-forward svc/${RELEASE_NAME}-server 8080:443

Then open https://localhost:8080  (user: admin)

Useful status commands:

  helm ${HELM_CTX_ARGS[*]+"${HELM_CTX_ARGS[*]}"} -n ${NAMESPACE} status ${RELEASE_NAME}
  kubectl ${KUBECTL_CTX_ARGS[*]+"${KUBECTL_CTX_ARGS[*]}"} -n ${NAMESPACE} get pods

EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
case "$MODE" in
  load)
    load_images
    # Refresh identity map (original == local name)
    : >"$IMAGE_MAP"
    while IFS= read -r img || [[ -n "$img" ]]; do
      [[ -z "$img" || "$img" =~ ^# ]] && continue
      printf '%s\t%s\n' "$img" "$img" >>"$IMAGE_MAP"
    done <"$IMAGES_LIST"
    ;;
  push)
    # Assumes images already present locally (e.g. prior load)
    push_images
    ;;
  load-and-push)
    load_images
    push_images
    ;;
esac

if [[ "$SKIP_HELM" -eq 1 ]]; then
  warn "Skipping Helm install (--skip-helm)"
  print_admin_password_help
  exit 0
fi

helm_install
print_admin_password_help

section "AIR-GAPPED PHASE COMPLETE"
info "Done."
