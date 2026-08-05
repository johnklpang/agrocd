#!/usr/bin/env bash
# Shared helpers for Argo CD air-gapped Helm workflows.
# shellcheck disable=SC2034

set -euo pipefail

# ---------------------------------------------------------------------------
# Default private registry (cluster-reachable LAN address)
# Override with --registry / PRIVATE_REGISTRY when needed.
# ---------------------------------------------------------------------------
# Existing in-cluster / NodePort Zot (HTTP): http://zot-registry:30001/v2/
DEFAULT_PRIVATE_REGISTRY="${DEFAULT_PRIVATE_REGISTRY:-zot-registry:30001}"

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
# Detect container runtime CLI (docker | podman | nerdctl | ctr)
# Prefer CONTAINER_RUNTIME override when set.
#
# For ctr (containerd):
#   CTR_NAMESPACE  — containerd namespace (default: k8s.io, what kubelet uses)
#   CTR_ADDRESS    — containerd socket (default: /run/containerd/containerd.sock)
# ---------------------------------------------------------------------------
detect_runtime() {
  if [[ -n "${CONTAINER_RUNTIME:-}" ]]; then
    command -v "$CONTAINER_RUNTIME" >/dev/null 2>&1 \
      || die "CONTAINER_RUNTIME='${CONTAINER_RUNTIME}' not found in PATH"
    echo "$CONTAINER_RUNTIME"
    return
  fi
  local rt
  for rt in docker podman nerdctl ctr; do
    if command -v "$rt" >/dev/null 2>&1; then
      echo "$rt"
      return
    fi
  done
  die "No container runtime found (docker, podman, nerdctl, or ctr). Install one or set CONTAINER_RUNTIME."
}

# Build the ctr base command with namespace / address.
# Uses sudo when the containerd socket is not writable by the current user.
# Usage: ctr_cmd images pull ...
ctr_cmd() {
  local args=()
  local ns="${CTR_NAMESPACE:-k8s.io}"
  local addr="${CTR_ADDRESS:-/run/containerd/containerd.sock}"
  local ctr_bin
  ctr_bin="$(command -v ctr)"

  # Elevate when needed (typical: /run/containerd/containerd.sock is root:root)
  if [[ ! -w "$addr" ]] && command -v sudo >/dev/null 2>&1; then
    args+=(sudo)
    # Preserve non-interactive environments
    args+=(-n)
  fi
  args+=("$ctr_bin")
  [[ -n "$ns" ]] && args+=(-n "$ns")
  [[ -n "$addr" ]] && args+=(--address "$addr")

  # If sudo -n fails (no passwordless sudo), retry without -n once when interactive
  if [[ "${args[0]}" == "sudo" ]]; then
    if ! sudo -n true 2>/dev/null; then
      args=(sudo "$ctr_bin")
      [[ -n "$ns" ]] && args+=(-n "$ns")
      [[ -n "$addr" ]] && args+=(--address "$addr")
    fi
  fi
  "${args[@]}" "$@"
}

# ---------------------------------------------------------------------------
# Runtime-agnostic image operations (docker/podman/nerdctl/ctr)
# ---------------------------------------------------------------------------
runtime_pull() {
  local runtime="$1"
  local image="$2"
  local insecure="${3:-0}"

  case "$runtime" in
    ctr)
      local args=(images pull)
      local platform="${CTR_PLATFORM:-}"
      if [[ -z "$platform" ]]; then
        case "$(uname -m)" in
          x86_64|amd64) platform=linux/amd64 ;;
          aarch64|arm64) platform=linux/arm64 ;;
        esac
      fi
      [[ -n "$platform" ]] && args+=(--platform "$platform")
      if [[ "$insecure" -eq 1 ]]; then
        args+=(--plain-http)
      fi
      if [[ -n "${PRIVATE_REGISTRY_USER:-}" ]]; then
        args+=(--user "${PRIVATE_REGISTRY_USER}:${PRIVATE_REGISTRY_PASSWORD:-}")
      fi
      info "ctr images pull ${image}${platform:+ (${platform})}"
      ctr_cmd "${args[@]}" "$image"
      ;;
    *)
      "$runtime" pull "$image"
      ;;
  esac
}

runtime_save() {
  local runtime="$1"
  local outfile="$2"
  shift 2
  local images=("$@")
  ((${#images[@]} > 0)) || die "runtime_save: no images provided"

  case "$runtime" in
    ctr)
      # ctr export writes an OCI archive (compatible with ctr import / many tools)
      info "ctr images export ${outfile}"
      ctr_cmd images export "$outfile" "${images[@]}"
      ;;
    *)
      "$runtime" save -o "$outfile" "${images[@]}"
      ;;
  esac
}

runtime_load() {
  local runtime="$1"
  local infile="$2"

  case "$runtime" in
    ctr)
      info "ctr images import ${infile}"
      local platform="${CTR_PLATFORM:-}"
      if [[ -z "$platform" ]]; then
        case "$(uname -m)" in
          x86_64|amd64) platform=linux/amd64 ;;
          aarch64|arm64) platform=linux/arm64 ;;
        esac
      fi
      local import_args=(images import)
      [[ -n "$platform" ]] && import_args+=(--platform "$platform")
      # Prefer unpacking (needed for local runs). On restricted hosts where
      # overlay whiteouts fail, fall back to --no-unpack so content can still
      # be exported/pushed for air-gap transfer; target nodes unpack on import.
      if [[ "${CTR_NO_UNPACK:-0}" == "1" ]]; then
        import_args+=(--no-unpack)
        ctr_cmd "${import_args[@]}" "$infile"
      elif ! ctr_cmd "${import_args[@]}" "$infile"; then
        warn "ctr import unpack failed; retrying with --no-unpack"
        import_args+=(--no-unpack)
        ctr_cmd "${import_args[@]}" "$infile"
      fi
      ;;
    *)
      "$runtime" load -i "$infile"
      ;;
  esac
}

runtime_tag() {
  local runtime="$1"
  local source="$2"
  local target="$3"

  case "$runtime" in
    ctr)
      info "ctr images tag ${source} -> ${target}"
      ctr_cmd images tag "$source" "$target"
      ;;
    *)
      "$runtime" tag "$source" "$target"
      ;;
  esac
}

runtime_inspect() {
  local runtime="$1"
  local image="$2"

  case "$runtime" in
    ctr)
      # Match exact ref or a line containing the ref (ctr may normalize hosts)
      ctr_cmd images ls -q 2>/dev/null | grep -F "$image" | grep -q .
      ;;
    *)
      "$runtime" image inspect "$image" >/dev/null 2>&1
      ;;
  esac
}

runtime_login() {
  local runtime="$1"
  local registry="$2"
  local user="$3"
  local pass="$4"
  local insecure="${5:-0}"

  case "$runtime" in
    ctr)
      # ctr has no login; credentials are passed per-pull/push via --user
      warn "ctr has no persistent login; use --user on pull/push or configure registry auth"
      return 0
      ;;
    podman|nerdctl)
      local login_args=(login)
      [[ "$insecure" -eq 1 ]] && login_args+=(--tls-verify=false)
      login_args+=(-u "$user" --password-stdin "$registry")
      printf '%s' "$pass" | "$runtime" "${login_args[@]}"
      ;;
    *)
      printf '%s' "$pass" | "$runtime" login -u "$user" --password-stdin "$registry"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Pull a single image.
# PULL_TOOL: auto | runtime | crane | ctr
#   auto    — try the selected runtime, fall back to crane
#   runtime — only the selected runtime (docker/podman/nerdctl/ctr)
#   crane   — always crane, then import into the runtime
#   ctr     — always use containerd ctr (even if CONTAINER_RUNTIME is docker)
# ---------------------------------------------------------------------------
pull_image() {
  local runtime="$1"
  local image="$2"
  local tool="${PULL_TOOL:-auto}"
  local insecure="${PULL_INSECURE:-0}"

  case "$tool" in
    runtime)
      runtime_pull "$runtime" "$image" "$insecure"
      return
      ;;
    ctr)
      command -v ctr >/dev/null 2>&1 || die "PULL_TOOL=ctr but 'ctr' is not installed"
      if ! runtime_pull ctr "$image" "$insecure"; then
        warn "ctr images pull failed for ${image}; trying crane + ctr import"
        command -v crane >/dev/null 2>&1 || die "ctr pull failed and crane is not installed"
        local tmp
        tmp="$(mktemp)"
        info "crane pull ${image}"
        if ! crane pull "$image" "$tmp"; then
          rm -f "$tmp"
          die "crane pull failed for ${image}"
        fi
        # Force no-unpack path when overlay extract is broken on this host
        CTR_NO_UNPACK="${CTR_NO_UNPACK:-0}" runtime_load ctr "$tmp" || true
        if ! runtime_inspect ctr "$image"; then
          # Explicit no-unpack retry
          info "ctr images import --no-unpack (fallback)"
          local platform="${CTR_PLATFORM:-linux/amd64}"
          if ! ctr_cmd images import --no-unpack --platform "$platform" "$tmp"; then
            rm -f "$tmp"
            die "Failed to import ${image} into ctr after crane pull"
          fi
        fi
        if ! runtime_inspect ctr "$image"; then
          rm -f "$tmp"
          die "Image ${image} not listed in ctr after import"
        fi
        rm -f "$tmp"
      fi
      # If the packaging runtime is not ctr, also make the image visible there
      if [[ "$runtime" != "ctr" ]]; then
        local tmp2
        tmp2="$(mktemp)"
        if ctr_cmd images export "$tmp2" "$image"; then
          runtime_load "$runtime" "$tmp2" || warn "Imported via ctr but failed to load into ${runtime}"
        fi
        rm -f "$tmp2"
      fi
      return
      ;;
    crane)
      command -v crane >/dev/null 2>&1 || die "PULL_TOOL=crane but 'crane' is not installed"
      _pull_with_crane "$runtime" "$image"
      return
      ;;
    auto)
      if runtime_pull "$runtime" "$image" "$insecure"; then
        return 0
      fi
      warn "Runtime pull failed for ${image}; falling back to crane (if available)"
      if command -v crane >/dev/null 2>&1; then
        _pull_with_crane "$runtime" "$image"
        return
      fi
      # Last resort: try ctr directly
      if [[ "$runtime" != "ctr" ]] && command -v ctr >/dev/null 2>&1; then
        warn "Trying ctr images pull for ${image}"
        runtime_pull ctr "$image" "$insecure"
        local tmp
        tmp="$(mktemp)"
        ctr_cmd images export "$tmp" "$image"
        runtime_load "$runtime" "$tmp" || true
        rm -f "$tmp"
        return
      fi
      die "Failed to pull ${image} (runtime pull failed; crane/ctr unavailable or failed)"
      ;;
    *)
      die "Invalid PULL_TOOL='${tool}' (expected: auto|runtime|crane|ctr)"
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
  # Load into the local runtime so save can package a multi-image tar.
  if ! runtime_load "$runtime" "${tmp}/image.tar"; then
    if ! runtime_inspect "$runtime" "$image"; then
      rm -rf "$tmp"
      die "Failed to load ${image} into ${runtime} after crane pull"
    fi
    warn "runtime load reported an error but image ${image} is present; continuing"
  fi
  rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# Push a single image reference already present in the local runtime.
# Prefer skopeo with --format=oci — some registries reject Docker schema2 (HTTP 415).
# For plain-HTTP registries, skopeo needs registries.conf
# insecure=true — --dest-tls-verify=false alone still speaks HTTPS.
# Fall back to ctr --plain-http, then crane --insecure.
# ---------------------------------------------------------------------------

# Host[:port] from an image reference (zot-registry:30001/foo/bar:tag → zot-registry:30001)
image_registry_host() {
  local image="$1"
  echo "${image%%/*}"
}

# Write a registries.conf that marks a registry as HTTP/insecure for skopeo/c/image.
write_insecure_registries_conf() {
  local registry="$1"
  local conf_file="$2"
  cat >"$conf_file" <<EOF
# Generated for plain-HTTP push to ${registry}
[[registry]]
prefix = "${registry}"
location = "${registry}"
insecure = true

[[registry]]
location = "${registry}"
insecure = true
EOF
}

# skopeo copy → docker://dest with optional plain HTTP.
# Returns 0 on success. Sets _skopeo_http_hint=1 if failure looks like HTTPS-vs-HTTP.
skopeo_copy_oci() {
  local src="$1"
  local dest_image="$2"
  local insecure="${3:-0}"
  local conf="" errfile rc
  local -a args=(copy --format=oci)
  _skopeo_http_hint=0

  errfile="$(mktemp)"
  if [[ "$insecure" -eq 1 ]]; then
    conf="$(mktemp)"
    write_insecure_registries_conf "$(image_registry_host "$dest_image")" "$conf"
    args+=(--dest-tls-verify=false)
    # containers/image reads this for insecure/HTTP registry policy
    export CONTAINERS_REGISTRIES_CONF="$conf"
  fi

  if [[ "$insecure" -eq 1 ]]; then
    info "skopeo copy (oci, plain-http) ${dest_image}"
  else
    info "skopeo copy (oci) ${dest_image}"
  fi
  set +e
  skopeo "${args[@]}" "$src" "docker://${dest_image}" 2>"$errfile"
  rc=$?
  set -e

  if [[ "$rc" -ne 0 ]]; then
    cat "$errfile" >&2
    if grep -qiE 'HTTP response to HTTPS|server gave HTTP response|http: server gave' "$errfile"; then
      _skopeo_http_hint=1
    fi
  fi

  [[ -n "$conf" ]] && rm -f "$conf"
  unset CONTAINERS_REGISTRIES_CONF
  rm -f "$errfile"
  return "$rc"
}

push_image() {
  local runtime="$1"
  local image="$2"
  local insecure="${3:-0}"

  # Prefer ctr native push for HTTP registries when using --runtime ctr
  if [[ "$runtime" == "ctr" && "$insecure" -eq 1 ]]; then
    local args=(images push --plain-http)
    if [[ -n "${PRIVATE_REGISTRY_USER:-}" ]]; then
      args+=(--user "${PRIVATE_REGISTRY_USER}:${PRIVATE_REGISTRY_PASSWORD:-}")
    fi
    info "ctr images push --plain-http ${image}"
    if ctr_cmd "${args[@]}" "$image"; then
      return 0
    fi
    warn "ctr plain-http push failed (registry may require OCI manifests); trying skopeo"
  fi

  if command -v skopeo >/dev/null 2>&1; then
    local src tmp=""
    case "$runtime" in
      podman) src="containers-storage:${image}" ;;
      ctr)
        tmp="$(mktemp)"
        runtime_save ctr "$tmp" "$image"
        src="oci-archive:${tmp}"
        ;;
      *) src="docker-daemon:${image}" ;;
    esac

    if skopeo_copy_oci "$src" "$image" "$insecure"; then
      [[ -n "$tmp" ]] && rm -f "$tmp"
      return 0
    fi

    # Auto-retry once with plain HTTP if the registry spoke HTTP to an HTTPS client
    if [[ "$insecure" -ne 1 && "${_skopeo_http_hint:-0}" -eq 1 ]]; then
      warn "Registry appears to be plain HTTP (not HTTPS)."
      warn "Retrying with insecure/HTTP mode. Pass --insecure-registry next time."
      if skopeo_copy_oci "$src" "$image" 1; then
        [[ -n "$tmp" ]] && rm -f "$tmp"
        return 0
      fi
    fi

    [[ -n "$tmp" ]] && rm -f "$tmp"
    die "skopeo push failed for ${image}. For HTTP registries use: --registry HOST:PORT --insecure-registry"
  fi

  if command -v crane >/dev/null 2>&1; then
    local tmp crane_args=(push)
    tmp="$(mktemp)"
    if [[ "$insecure" -eq 1 ]]; then
      crane_args+=(--insecure)
    fi
    if ! runtime_save "$runtime" "$tmp" "$image"; then
      rm -f "$tmp"
      die "Failed to save ${image} for crane push"
    fi
    warn "skopeo not found; crane may fail on registries that reject Docker schema2 (HTTP 415). Install skopeo for OCI pushes."
    if ! crane "${crane_args[@]}" "$tmp" "$image"; then
      if [[ "$insecure" -ne 1 ]]; then
        warn "Retrying crane push with --insecure (plain HTTP)"
        if crane push --insecure "$tmp" "$image"; then
          rm -f "$tmp"
          return 0
        fi
      fi
      rm -f "$tmp"
      die "crane push failed for ${image}"
    fi
    rm -f "$tmp"
    return
  fi

  case "$runtime" in
    ctr)
      local args=(images push)
      [[ "$insecure" -eq 1 ]] && args+=(--plain-http)
      if [[ -n "${PRIVATE_REGISTRY_USER:-}" ]]; then
        args+=(--user "${PRIVATE_REGISTRY_USER}:${PRIVATE_REGISTRY_PASSWORD:-}")
      fi
      info "ctr images push ${image}"
      ctr_cmd "${args[@]}" "$image"
      return
      ;;
  esac

  if [[ "$insecure" -eq 1 ]]; then
    warn "Pushing to an HTTP/insecure registry without skopeo/crane."
    warn "Ensure the runtime allows insecure registries (e.g. Docker insecure-registries)."
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
# Split an image reference into repository + tag (best-effort).
# Sets globals: _img_repo _img_tag
# ---------------------------------------------------------------------------
split_image_ref() {
  local ref="$1"
  _img_tag=""
  if [[ "$ref" == *"@"* ]]; then
    _img_repo="${ref%%@*}"
    return
  fi
  local last="${ref##*/}"
  if [[ "$last" == *":"* ]]; then
    _img_tag="${ref##*:}"
    _img_repo="${ref%:*}"
  else
    _img_repo="$ref"
  fi
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
