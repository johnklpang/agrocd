# Argo CD Air-Gapped Helm Deployment

Robust Bash + Helm workflow for installing Argo CD in a disconnected (air-gapped) Kubernetes environment.

## Layout

```
argocd-airgap/
├── scripts/
│   ├── 01-online-prepare.sh   # Connected network: pull chart + images
│   ├── 02-airgap-deploy.sh    # Air-gapped: load/push images + Helm install
│   └── lib/common.sh          # Shared helpers (logging, image extract/rewrite)
├── helm/
│   └── values-airgap.yaml     # Operator overrides (layered at install time)
└── artifacts/                 # Generated transfer bundle (gitignored contents)
```

## Prerequisites

| Phase | Tools |
|-------|--------|
| Online | `helm` (≥ 3.8), `docker` **or** `podman` **or** `nerdctl`, network access to the Argo Helm repo and image registries |
| Air-gapped | `helm`, `kubectl`, same container runtime, access to the target cluster; optional private OCI registry |

## Quick start

### 1. Online phase (connected host)

```bash
cd argocd-airgap
chmod +x scripts/*.sh

# Latest chart
./scripts/01-online-prepare.sh

# Or pin a chart version
./scripts/01-online-prepare.sh --chart-version 7.7.16
```

This will:

1. Add `https://argoproj.github.io/argo-helm` and `helm pull argo/argo-cd`
2. Render the chart with `helm template` and extract every `image:` reference (no hardcoded tags)
3. Pull those images and save them to `artifacts/argo-cd-images.tar`
4. Export the chart `.tgz` plus `images.txt`, `image-map.tsv`, and `manifest.env`

### 2. Move artifacts into the air-gapped network

Copy the **entire** `artifacts/` directory (USB, sneaker-net, approved file transfer, etc.):

```bash
# On the online host — create a single transfer bundle
tar -C argocd-airgap -cvf argo-cd-airgap-bundle.tar artifacts scripts helm

# On the air-gapped host — extract
tar -xvf argo-cd-airgap-bundle.tar
cd argocd-airgap   # or whatever path you extracted to
```

Minimum required files inside `artifacts/`:

| File | Purpose |
|------|---------|
| `argo-cd-<version>.tgz` | Local Helm chart package |
| `argo-cd-images.tar` | All container images |
| `images.txt` | One image reference per line |
| `image-map.tsv` | Original → rewritten image mapping |
| `manifest.env` | Versions and filenames for the offline script |

Also transfer `scripts/` and `helm/` (or the whole `argocd-airgap/` tree).

### 3. Air-gapped phase

**Recommended: push images to an internal registry**

```bash
export PRIVATE_REGISTRY=registry.internal.example:5000
# Optional auth:
export PRIVATE_REGISTRY_USER=robot
export PRIVATE_REGISTRY_PASSWORD=secret

./scripts/02-airgap-deploy.sh \
  --artifacts ./artifacts \
  --registry "$PRIVATE_REGISTRY" \
  --namespace argocd \
  --release argocd
```

**Alternative: load images into the local runtime only** (kind / k3s / single-node where the kubelet shares that store):

```bash
./scripts/02-airgap-deploy.sh --mode load --artifacts ./artifacts
```

For containerd-based clusters, prefer `CONTAINER_RUNTIME=nerdctl` (or import with `ctr -n k8s.io images import` after a docker load on a bastion is not enough — images must be visible to the kubelet). A private registry is the portable approach for multi-node clusters.

## What the air-gap script does

1. Loads `argo-cd-images.tar` into Docker/Podman/nerdctl (unless `--mode push` only)
2. Retags and pushes each image to `PRIVATE_REGISTRY` using path-preserving rewrite:
   - `quay.io/argoproj/argocd:vX` → `registry.internal/argoproj/argocd:vX`
3. Generates `artifacts/values-generated-airgap.yaml` with per-component image repositories
4. `helm upgrade --install` using the local `.tgz`, generated values, and `helm/values-airgap.yaml`
5. Waits for Deployments/StatefulSets and `app.kubernetes.io/part-of=argocd` pods
6. Prints the initial admin password command

### Initial admin password

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
```

### Port-forward UI

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
# https://localhost:8080  (user: admin)
```

## Configuration reference

### `01-online-prepare.sh`

| Flag / env | Description |
|------------|-------------|
| `--chart-version VER` | Pin Helm chart version (default: latest) |
| `--values FILE` | Extra values used during image discovery |
| `--artifacts DIR` | Output directory (default: `./artifacts`) |
| `--runtime NAME` | `docker` \| `podman` \| `nerdctl` |
| `--repo-url` / `--repo-name` | Override Helm repository |
| `--skip-pull` | Re-package images already present locally |
| `--pull-tool TOOL` / `PULL_TOOL` | `auto` (default), `runtime`, or `crane`. `auto` falls back to [crane](https://github.com/google/go-containerregistry) when `docker pull` fails (useful in restricted overlayfs environments). |

### `02-airgap-deploy.sh`

| Flag / env | Description |
|------------|-------------|
| `--registry` / `PRIVATE_REGISTRY` | Internal registry host[:port] |
| `--registry-user` / `--registry-pass` | Registry credentials; also creates `argocd-registry-secret` |
| `--mode` | `auto` (default), `load`, `push`, `load-and-push` |
| `--rewrite-mode` | `keep-path` (default) or `flatten` |
| `--namespace` / `--release` | Kubernetes namespace and Helm release name |
| `--values FILE` | Extra Helm values (repeatable; highest precedence) |
| `--wait-timeout` | Helm / kubectl wait timeout (default: `10m`) |
| `--dry-run` | Plan only |
| `--skip-helm` | Only load/push images |
| `--insecure-registry` | Disable TLS verify on podman/nerdctl push |
| `--kube-context` | kubectl/helm context |

### Image rewrite modes

- **keep-path** (default): `quay.io/argoproj/argocd:v2.13.0` → `registry.example/argoproj/argocd:v2.13.0`
- **flatten**: `quay.io/argoproj/argocd:v2.13.0` → `registry.example/argocd:v2.13.0`

## Helm values layering

Install merges values in this order (later wins):

1. `artifacts/values-generated-airgap.yaml` — image repos/tags for the private registry
2. `artifacts/values-airgap.yaml` or `helm/values-airgap.yaml` — operator defaults
3. Any `--values` files passed on the CLI

Edit `helm/values-airgap.yaml` for durable cluster settings (replicas, ingress, resources). Do not hardcode image tags there; let the generated file own those.

## Error handling

Both scripts use `set -euo pipefail`, fail fast on missing tools/artifacts, and print UTC-timestamped logs. Re-run `02-airgap-deploy.sh` safely — it uses `helm upgrade --install`.

## Example: full offline bootstrap with auth registry

```bash
# Online
./scripts/01-online-prepare.sh --chart-version 7.7.16
tar -cvf /media/usb/argo-cd-airgap-bundle.tar artifacts scripts helm

# Air-gapped
tar -xvf /media/usb/argo-cd-airgap-bundle.tar
export PRIVATE_REGISTRY=harbor.corp.local/airgap
export PRIVATE_REGISTRY_USER=robot\$airgap
export PRIVATE_REGISTRY_PASSWORD='***'

./scripts/02-airgap-deploy.sh \
  --artifacts ./artifacts \
  --registry "$PRIVATE_REGISTRY" \
  --namespace argocd
```
