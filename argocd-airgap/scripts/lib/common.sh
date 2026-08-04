#!/usr/bin/env bash
# Shared helpers for Argo CD air-gapped Helm workflows.
# shellcheck disable=SC2034

set -euo pipefail

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log()  { printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"; }
info() { log "INFO  $*"; }
warn() { log "WARN  $*" >&2; }
err()  { log "ERROR $*" >&2; }
die()  { err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Require commands
# ---------------------------------------------------------------------------
require_cmds() {
  local missing=()
  local cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done
  if ((${#missing[@]} > 0)); then
    die "Missing required command(s): ${missing[*]}"
  fi
}

# ---------------------------------------------------------------------------
# Detect container runtime CLI (docker | podman | nerdctl)
# Prefer CONTAINER_RUNTIME override when set.
# ---------------------------------------------------------------------------
detect_runtime() {
  if [[ -n "${CONTAINER_RUNTIME:-}" ]]; then
    command -v "$CONTAINER_RUNTIME" >/dev/null 2>&1 \
      || die "CONTAINER_RUNTIME='${CONTAINER_RUNTIME}' not found in PATH"
    echo "$CONTAINER_RUNTIME"
    return
  fi
  local rt
  for rt in docker podman nerdctl; do
    if command -v "$rt" >/dev/null 2>&1; then
      echo "$rt"
      return
    fi
  done
  die "No container runtime found (docker, podman, or nerdctl). Install one or set CONTAINER_RUNTIME."
}

# ---------------------------------------------------------------------------
# Pull a single image. Uses crane when PULL_TOOL=crane or when the runtime
# pull fails (common in restricted/rootless overlayfs environments).
# ---------------------------------------------------------------------------
pull_image() {
  local runtime="$1"
  local image="$2"
  local tool="${PULL_TOOL:-auto}"

  case "$tool" in
    runtime)
      "$runtime" pull "$image"
      return
      ;;
    crane)
      command -v crane >/dev/null 2>&1 || die "PULL_TOOL=crane but 'crane' is not installed"
      _pull_with_crane "$runtime" "$image"
      return
      ;;
    auto)
      if "$runtime" pull "$image"; then
        return 0
      fi
      warn "Runtime pull failed for ${image}; falling back to crane (if available)"
      if command -v crane >/dev/null 2>&1; then
        _pull_with_crane "$runtime" "$image"
        return
      fi
      die "Failed to pull ${image} (runtime pull failed and crane not installed)"
      ;;
    *)
      die "Invalid PULL_TOOL='${tool}' (expected: auto|runtime|crane)"
      ;;
  esac
}

_pull_with_crane() {
  local runtime="$1"
  local image="$2"
  local tmp
  tmp="$(mktemp -d)"
  info "crane pull ${image}"
  if ! crane pull "$image" "${tmp}/image.tar"; then
    rm -rf "$tmp"
    die "crane pull failed for ${image}"
  fi
  # Load into the local runtime so docker/podman save can package a multi-image tar.
  # Ignore non-zero from whiteout warnings on some restricted hosts if the image appears.
  if ! "$runtime" load -i "${tmp}/image.tar"; then
    if ! "$runtime" image inspect "$image" >/dev/null 2>&1; then
      rm -rf "$tmp"
      die "Failed to load ${image} into ${runtime} after crane pull"
    fi
    warn "runtime load reported an error but image ${image} is present; continuing"
  fi
  rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# Push a single image reference already present in the local runtime.
# Prefer crane when available for registry push reliability.
# ---------------------------------------------------------------------------
push_image() {
  local runtime="$1"
  local image="$2"
  local insecure="${3:-0}"

  if command -v crane >/dev/null 2>&1; then
    local tmp crane_args=(push)
    tmp="$(mktemp)"
    if [[ "$insecure" -eq 1 ]]; then
      crane_args+=(--insecure)
    fi
    if ! "$runtime" save -o "$tmp" "$image"; then
      rm -f "$tmp"
      die "Failed to save ${image} for crane push"
    fi
    if ! crane "${crane_args[@]}" "$tmp" "$image"; then
      rm -f "$tmp"
      die "crane push failed for ${image}"
    fi
    rm -f "$tmp"
    return
  fi

  local push_args=(push)
  if [[ "$insecure" -eq 1 && ( "$runtime" == "podman" || "$runtime" == "nerdctl" ) ]]; then
    push_args+=(--tls-verify=false)
  fi
  push_args+=("$image")
  "$runtime" "${push_args[@]}"
}

# ---------------------------------------------------------------------------
# Resolve project paths relative to this library file.
# ---------------------------------------------------------------------------
script_dir() {
  # Resolve the directory of the calling script when sourced carefully.
  local source="${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}"
  cd "$(dirname "$source")" && pwd
}

# Default layout: <repo>/argocd-airgap/{scripts,helm,artifacts}
# Prefer ARGOCD_AIRGAP_ROOT if set.
resolve_roots() {
  if [[ -n "${ARGOCD_AIRGAP_ROOT:-}" ]]; then
    ROOT_DIR="$(cd "$ARGOCD_AIRGAP_ROOT" && pwd)"
  else
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    ROOT_DIR="$here"
  fi
  SCRIPTS_DIR="${ROOT_DIR}/scripts"
  HELM_DIR="${ROOT_DIR}/helm"
  ARTIFACTS_DIR="${ARTIFACTS_DIR:-${ROOT_DIR}/artifacts}"
  CHART_DIR="${ARTIFACTS_DIR}/chart"
  IMAGES_TAR="${IMAGES_TAR:-${ARTIFACTS_DIR}/argo-cd-images.tar}"
  IMAGES_LIST="${IMAGES_LIST:-${ARTIFACTS_DIR}/images.txt}"
  IMAGE_MAP="${IMAGE_MAP:-${ARTIFACTS_DIR}/image-map.tsv}"
  CHART_TGZ="${CHART_TGZ:-}"
  MANIFEST_FILE="${MANIFEST_FILE:-${ARTIFACTS_DIR}/manifest.env}"
}

# ---------------------------------------------------------------------------
# Extract unique container image references from rendered Helm manifests.
# Uses helm template output — no hardcoded tags.
# ---------------------------------------------------------------------------
extract_images_from_chart() {
  local chart_path="$1"
  shift
  # Remaining args are passed to helm template (e.g. -f values.yaml)
  local rendered
  rendered="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$rendered'" RETURN

  helm template airgap-extract "$chart_path" "$@" >"$rendered"

  # Match common Kubernetes image fields across containers / initContainers /
  # ephemeralContainers, including quoted and unquoted forms.
  # Also catch "image: " under helm hooks / Jobs / CronJobs.
  awk '
    BEGIN { IGNORECASE = 0 }
    /^[[:space:]]+image:[[:space:]]*/ {
      line = $0
      sub(/^[[:space:]]+image:[[:space:]]*/, "", line)
      gsub(/["'\'']/, "", line)
      gsub(/[[:space:]]+#.*$/, "", line)
      gsub(/[[:space:]]+$/, "", line)
      if (line != "" && line !~ /^</ && line !~ /\{\{/) {
        print line
      }
    }
  ' "$rendered" | sort -u
}

# ---------------------------------------------------------------------------
# Rewrite an image reference to a private registry.
#
# Strategies (REGISTRY_REWRITE_MODE):
#   keep-path (default): registry.example.com/argoproj/argocd:vX
#                        (strip original registry host, keep path+tag)
#   flatten:             registry.example.com/argocd:vX
#                        (last path segment only)
# ---------------------------------------------------------------------------
rewrite_image() {
  local image="$1"
  local registry="$2"
  local mode="${REGISTRY_REWRITE_MODE:-keep-path}"

  registry="${registry%/}"

  local name tag digest path last
  digest=""
  tag=""

  if [[ "$image" == *"@"* ]]; then
    name="${image%%@*}"
    digest="@${image#*@}"
  elif [[ "$image" == *":"* ]] && [[ "${image##*/}" == *":"* || "$image" =~ :[0-9a-zA-Z._-]+$ ]]; then
    # Has a tag (not just a port in the registry host). Heuristic:
    # if the last colon-separated segment has no slash, treat as tag.
    local maybe_tag="${image##*:}"
    if [[ "$maybe_tag" != */* ]]; then
      name="${image%:*}"
      tag=":${maybe_tag}"
    else
      name="$image"
    fi
  else
    name="$image"
  fi

  # Strip registry host if present (host has a '.' or ':' before first '/').
  if [[ "$name" =~ ^[^/]+[.:][^/]+/ ]]; then
    path="${name#*/}"
  else
    path="$name"
  fi

  case "$mode" in
    flatten)
      last="${path##*/}"
      echo "${registry}/${last}${tag}${digest}"
      ;;
    keep-path|*)
      echo "${registry}/${path}${tag}${digest}"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Parse key=value manifest.env written by the online phase.
# ---------------------------------------------------------------------------
load_manifest() {
  local file="$1"
  [[ -f "$file" ]] || die "Manifest not found: $file"
  # shellcheck disable=SC1090
  set -a
  # Only allow simple KEY=VALUE lines
  # shellcheck disable=SC2163
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
    export "$line"
  done <"$file"
  set +a
}

# ---------------------------------------------------------------------------
# Print a boxed section header
# ---------------------------------------------------------------------------
section() {
  local title="$1"
  echo
  echo "================================================================"
  echo " ${title}"
  echo "================================================================"
}
