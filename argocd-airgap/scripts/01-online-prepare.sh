#!/usr/bin/env bash
# =============================================================================
# 01-online-prepare.sh
#
# ONLINE PHASE — run on a machine with internet access.
#
# What this script does:
#   1. Adds the official Argo CD Helm repository and updates it.
#   2. Pulls the Argo CD Helm chart (latest, or a pinned version).
#   3. Renders the chart with `helm template` and extracts every container
#      image reference automatically (no hardcoded tags).
#   4. Pulls those images with your local container runtime.
#   5. Packages all images into a single tar archive (argo-cd-images.tar).
#   6. Exports the chart .tgz plus a transfer manifest for the air-gapped side.
#
# Usage:
#   ./scripts/01-online-prepare.sh [options]
#
# Options / environment:
#   --chart-version VER   Pin chart version (default: latest from repo)
#   --values FILE         Extra Helm values used when rendering for image discovery
#   --artifacts DIR       Output directory (default: ./artifacts)
#   --runtime NAME        Container CLI: docker|podman|nerdctl|ctr (auto-detect)
#   --repo-url URL        Helm repo URL (default: https://argoproj.github.io/argo-helm)
#   --repo-name NAME      Helm repo name (default: argo)
#   --chart-name NAME     Chart name within the repo (default: argo-cd)
#   --skip-pull           Skip image pull (re-package from already-local images)
#   --pull-tool TOOL      auto (default) | runtime | crane | ctr
#                         auto: try selected runtime, fall back to crane/ctr
#                         ctr:  always download with containerd `ctr images pull`
#   --ctr-namespace NS    containerd namespace for ctr (default: k8s.io)
#   --ctr-address PATH    containerd socket (default: /run/containerd/containerd.sock)
#   -h, --help            Show help
#
# Transfer to the air-gapped network:
#   Copy the entire artifacts/ directory (or at minimum):
#     - artifacts/argo-cd-*.tgz          (Helm chart package)
#     - artifacts/argo-cd-images.tar     (container images)
#     - artifacts/images.txt             (image list)
#     - artifacts/manifest.env           (versions / filenames)
#     - artifacts/image-map.tsv          (original image references)
#     - helm/values-airgap.yaml          (optional starter values)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
HELM_REPO_URL="${HELM_REPO_URL:-https://argoproj.github.io/argo-helm}"
HELM_REPO_NAME="${HELM_REPO_NAME:-argo}"
CHART_NAME="${CHART_NAME:-argo-cd}"
CHART_VERSION="${CHART_VERSION:-}"
VALUES_FILE="${VALUES_FILE:-}"
SKIP_PULL=0
RUNTIME="${CONTAINER_RUNTIME:-}"
PULL_TOOL="${PULL_TOOL:-auto}"

usage() {
  sed -n '2,46p' "$0" | sed 's/^# \?//'
  exit 0
}

# ---------------------------------------------------------------------------
# Parse args
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --chart-version) CHART_VERSION="$2"; shift 2 ;;
    --values)        VALUES_FILE="$2"; shift 2 ;;
    --artifacts)     ARTIFACTS_DIR="$2"; shift 2 ;;
    --runtime)       RUNTIME="$2"; shift 2 ;;
    --repo-url)      HELM_REPO_URL="$2"; shift 2 ;;
    --repo-name)     HELM_REPO_NAME="$2"; shift 2 ;;
    --chart-name)    CHART_NAME="$2"; shift 2 ;;
    --skip-pull)     SKIP_PULL=1; shift ;;
    --pull-tool)     PULL_TOOL="$2"; shift 2 ;;
    --ctr-namespace) CTR_NAMESPACE="$2"; shift 2 ;;
    --ctr-address)   CTR_ADDRESS="$2"; shift 2 ;;
    --with-zot|--zot-image|--zot-chart-version)
      die "Zot packaging was removed. Use an existing private registry with 02-airgap-deploy.sh --registry HOST:PORT" ;;
    -h|--help)       usage ;;
    *) die "Unknown argument: $1 (use --help)" ;;
  esac
done

resolve_roots
[[ -n "$RUNTIME" ]] && CONTAINER_RUNTIME="$RUNTIME"
export PULL_TOOL
export CTR_NAMESPACE="${CTR_NAMESPACE:-k8s.io}"
export CTR_ADDRESS="${CTR_ADDRESS:-}"

require_cmds helm awk sort
RUNTIME="$(detect_runtime)"
if [[ "$PULL_TOOL" == "ctr" || "$RUNTIME" == "ctr" ]]; then
  require_cmds ctr
fi
if [[ "$PULL_TOOL" == "crane" ]] || [[ "$PULL_TOOL" == "auto" ]]; then
  if ! command -v crane >/dev/null 2>&1; then
    if [[ "$PULL_TOOL" == "crane" ]]; then
      die "crane not found (install https://github.com/google/go-containerregistry)"
    fi
    warn "crane not found; PULL_TOOL=auto will not be able to fall back to crane"
  fi
fi

mkdir -p "$ARTIFACTS_DIR" "$CHART_DIR"
section "Argo CD air-gap ONLINE prepare"
info "Artifacts directory : ${ARTIFACTS_DIR}"
info "Helm repo           : ${HELM_REPO_NAME} -> ${HELM_REPO_URL}"
info "Chart               : ${CHART_NAME}${CHART_VERSION:+ (version ${CHART_VERSION})}"
info "Container runtime   : ${RUNTIME}"
info "Pull tool           : ${PULL_TOOL}"
if [[ "$RUNTIME" == "ctr" || "$PULL_TOOL" == "ctr" ]]; then
  info "ctr namespace       : ${CTR_NAMESPACE}"
  info "ctr address         : ${CTR_ADDRESS:-/run/containerd/containerd.sock (default)}"
fi

# ---------------------------------------------------------------------------
# 1. Add / update Helm repository and pull chart
# ---------------------------------------------------------------------------
section "1/5 Add Helm repository and pull chart"

info "Adding Helm repository '${HELM_REPO_NAME}'..."
helm repo add "$HELM_REPO_NAME" "$HELM_REPO_URL" --force-update
helm repo update "$HELM_REPO_NAME"

PULL_ARGS=(pull "${HELM_REPO_NAME}/${CHART_NAME}" --destination "$ARTIFACTS_DIR")
if [[ -n "$CHART_VERSION" ]]; then
  PULL_ARGS+=(--version "$CHART_VERSION")
fi

info "Pulling chart package..."
# Remove any previous chart packages for this name to avoid ambiguity
rm -f "${ARTIFACTS_DIR}/${CHART_NAME}"-*.tgz
helm "${PULL_ARGS[@]}"

# Discover the downloaded .tgz (helm names it <chart>-<version>.tgz)
mapfile -t CHART_PACKAGES < <(ls -1t "${ARTIFACTS_DIR}/${CHART_NAME}"-*.tgz 2>/dev/null || true)
((${#CHART_PACKAGES[@]} > 0)) || die "No chart package found in ${ARTIFACTS_DIR} after helm pull"
CHART_TGZ="${CHART_PACKAGES[0]}"
info "Chart package: ${CHART_TGZ}"

# Untar into a clean directory for templating / inspection
rm -rf "${CHART_DIR:?}/"*
tar -xzf "$CHART_TGZ" -C "$CHART_DIR"
# Chart extracts as <chart-name>/...
UNTARRED_CHART="${CHART_DIR}/${CHART_NAME}"
[[ -d "$UNTARRED_CHART" ]] || die "Expected untarred chart at ${UNTARRED_CHART}"

# Read chart version / appVersion from Chart.yaml
CHART_VERSION_RESOLVED="$(awk '/^version:/{print $2; exit}' "${UNTARRED_CHART}/Chart.yaml")"
APP_VERSION="$(awk '/^appVersion:/{gsub(/"/,""); print $2; exit}' "${UNTARRED_CHART}/Chart.yaml")"
info "Resolved chart version=${CHART_VERSION_RESOLVED} appVersion=${APP_VERSION}"

# ---------------------------------------------------------------------------
# 2. Extract container images via helm template (no hardcoded tags)
# ---------------------------------------------------------------------------
section "2/5 Extract container images from chart"

TEMPLATE_ARGS=()
if [[ -n "$VALUES_FILE" ]]; then
  [[ -f "$VALUES_FILE" ]] || die "Values file not found: $VALUES_FILE"
  TEMPLATE_ARGS+=(-f "$VALUES_FILE")
  info "Using values file for image discovery: $VALUES_FILE"
fi

# Also include CRDs / hooks so hook Job images are not missed
info "Rendering chart with helm template..."
mapfile -t IMAGES < <(extract_images_from_chart "$UNTARRED_CHART" "${TEMPLATE_ARGS[@]}")

if ((${#IMAGES[@]} == 0)); then
  die "No images found in rendered manifests. Check chart path / values."
fi

info "Discovered ${#IMAGES[@]} unique image(s):"
printf '  - %s\n' "${IMAGES[@]}"

# Persist list + identity map (original -> original) for the offline phase
: >"$IMAGES_LIST"
: >"$IMAGE_MAP"
for img in "${IMAGES[@]}"; do
  printf '%s\n' "$img" >>"$IMAGES_LIST"
  # TSV: original<TAB>original  (offline phase rewrites the second column)
  printf '%s\t%s\n' "$img" "$img" >>"$IMAGE_MAP"
done

# ---------------------------------------------------------------------------
# 3. Pull images
# ---------------------------------------------------------------------------
section "3/5 Pull container images"

if [[ "$SKIP_PULL" -eq 1 ]]; then
  warn "Skipping image pull (--skip-pull). Images must already exist locally."
else
  info "Pull tool: ${PULL_TOOL}"
  for img in "${IMAGES[@]}"; do
    info "Pulling ${img}"
    pull_image "$RUNTIME" "$img"
  done
fi

# ---------------------------------------------------------------------------
# 4. Save images into a single tar archive
# ---------------------------------------------------------------------------
section "4/5 Package images into tar archive"

info "Saving ${#IMAGES[@]} image(s) -> ${IMAGES_TAR}"
runtime_save "$RUNTIME" "$IMAGES_TAR" "${IMAGES[@]}"
# Sanity check
[[ -s "$IMAGES_TAR" ]] || die "Image archive is empty: $IMAGES_TAR"
IMAGES_TAR_SIZE="$(du -h "$IMAGES_TAR" | awk '{print $1}')"
info "Image archive size: ${IMAGES_TAR_SIZE}"

# ---------------------------------------------------------------------------
# 5. Write transfer manifest
# ---------------------------------------------------------------------------
section "5/5 Write transfer manifest"

CHART_TGZ_BASENAME="$(basename "$CHART_TGZ")"
cat >"$MANIFEST_FILE" <<EOF
# Generated by 01-online-prepare.sh on $(date -u +'%Y-%m-%dT%H:%M:%SZ')
# Source this file on the air-gapped side (02-airgap-deploy.sh does so automatically).
CHART_NAME=${CHART_NAME}
CHART_VERSION=${CHART_VERSION_RESOLVED}
APP_VERSION=${APP_VERSION}
CHART_TGZ_BASENAME=${CHART_TGZ_BASENAME}
IMAGES_TAR_BASENAME=$(basename "$IMAGES_TAR")
IMAGES_LIST_BASENAME=$(basename "$IMAGES_LIST")
IMAGE_MAP_BASENAME=$(basename "$IMAGE_MAP")
IMAGE_COUNT=${#IMAGES[@]}
HELM_REPO_URL=${HELM_REPO_URL}
GENERATED_AT=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
EOF

info "Wrote ${MANIFEST_FILE}"

# Copy a starter air-gap values file next to artifacts for convenience
if [[ -f "${HELM_DIR}/values-airgap.yaml" ]]; then
  cp -f "${HELM_DIR}/values-airgap.yaml" "${ARTIFACTS_DIR}/values-airgap.yaml"
fi

section "ONLINE PHASE COMPLETE"
cat <<EOF

Artifacts ready for transfer (copy this entire directory to the air-gapped network):

  ${ARTIFACTS_DIR}/
    ├── ${CHART_TGZ_BASENAME}          # Argo CD Helm chart package
    ├── $(basename "$IMAGES_TAR")      # Argo CD container images
    ├── $(basename "$IMAGES_LIST")     # Image list (one per line)
    ├── $(basename "$IMAGE_MAP")       # Image map (TSV)
    └── $(basename "$MANIFEST_FILE")   # Versions / filenames

Suggested transfer:

  tar -C "$(dirname "$ROOT_DIR")" -cvf argo-cd-airgap-bundle.tar "$(basename "$ROOT_DIR")"

On the air-gapped host (registry already running, e.g. ${DEFAULT_PRIVATE_REGISTRY}):

  # Allow kubelet HTTP pulls (every node)
  sudo ./scripts/03-configure-containerd-registry.sh apply --registry ${DEFAULT_PRIVATE_REGISTRY}

  # Push images and install Argo CD
  ./scripts/02-airgap-deploy.sh \\
    --runtime ctr \\
    --registry ${DEFAULT_PRIVATE_REGISTRY} \\
    --insecure-registry \\
    --artifacts ${ARTIFACTS_DIR}

EOF
