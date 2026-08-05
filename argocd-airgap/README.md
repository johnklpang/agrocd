# Argo CD Air-Gapped Helm Deployment

Bash + Helm workflow for installing Argo CD in a disconnected environment using an **existing private OCI registry**.

Default registry: **`zot-registry:30001`** (`http://zot-registry:30001/v2/`).

## Layout

```
argocd-airgap/
├── scripts/
│   ├── 01-online-prepare.sh                 # Connected: pull Argo CD chart/images
│   ├── 02-airgap-deploy.sh                  # Air-gapped: load/push images + Helm install
│   ├── 03-configure-containerd-registry.sh  # Allow kubelet HTTP pulls from the registry
│   └── lib/common.sh
├── helm/
│   └── values-airgap.yaml                   # Argo CD operator overrides
└── artifacts/                               # Generated transfer bundle (gitignored contents)
```

## Prerequisites

| Phase | Tools |
|-------|--------|
| Online | `helm` (≥ 3.8), `docker`/`podman`/`nerdctl`/`ctr`, optional `crane`/`skopeo` |
| Air-gapped | Same runtime, `curl`; `kubectl`+`helm` for cluster install. **`skopeo` recommended** for OCI pushes. Optional: `crane` |

Assumes an existing registry (this lab: NodePort Zot at `http://zot-registry:30001/v2/`) reachable from every Kubernetes node. These scripts do **not** install or start the registry.

## Recommended flow

### 1. Online — package Argo CD

```bash
cd argocd-airgap
chmod +x scripts/*.sh

./scripts/01-online-prepare.sh
# Prefer containerd ctr for pulls:
#   ./scripts/01-online-prepare.sh --runtime ctr --pull-tool ctr
#   ./scripts/01-online-prepare.sh --pull-tool ctr
```

### Using `ctr` (containerd) to download images

```bash
export CTR_NAMESPACE=k8s.io
./scripts/01-online-prepare.sh --runtime ctr --pull-tool ctr

# Air-gapped: import the tar into containerd (visible to kubelet)
./scripts/02-airgap-deploy.sh \
  --runtime ctr \
  --registry zot-registry:30001 \
  --insecure-registry \
  --artifacts ./artifacts
```

`ctr` notes:

| Item | Detail |
|------|--------|
| Pull | `ctr -n k8s.io images pull [--platform linux/amd64] <ref>` |
| Export | `ctr -n k8s.io images export argo-cd-images.tar <refs…>` |
| Import | `ctr -n k8s.io images import argo-cd-images.tar` |
| HTTP registry | `--plain-http` (set with `--insecure-registry`) |
| Namespace | Default `k8s.io` so kubelet can see imported images |
| Env | `CTR_NAMESPACE`, `CTR_ADDRESS`, `CTR_PLATFORM`, `CTR_NO_UNPACK=1` |

### 2. Transfer

```bash
tar -C .. -cvf argo-cd-airgap-bundle.tar argocd-airgap
# sneaker-net / USB → air-gapped host, then:
tar -xvf argo-cd-airgap-bundle.tar
cd argocd-airgap
```

### 3. Air-gapped — force plain HTTP (not HTTPS), then install

Zot at `http://zot-registry:30001/v2/` is **HTTP only**. Kubelet defaults to **HTTPS**, which fails with:

```text
Head "https://zot-registry:30001/v2/...": http: server gave HTTP response to HTTPS client
```

`--insecure-registry` makes the deploy script:
1. Push over plain HTTP (`ctr --plain-http` / skopeo)
2. Auto-configure **this node's** containerd for plain HTTP (not HTTPS)
3. You must still run the same config on **every worker**

```bash
# On EVERY worker (and master if not already done by 02):
sudo ./scripts/03-configure-containerd-registry.sh apply --registry zot-registry:30001

./scripts/02-airgap-deploy.sh \
  --runtime ctr \
  --registry zot-registry:30001 \
  --insecure-registry \
  --redis-secret-init manual \
  --artifacts ./artifacts

kubectl -n argocd delete pods --all
```

## Allowing Kubernetes to pull from an HTTP registry

**Every node** must treat the registry as insecure, or kubelet keeps trying HTTPS and pods stay in `ImagePullBackOff`:

```text
Failed to pull image "zot-registry:30001/argoproj/argocd:v3.5.0":
Head "https://zot-registry:30001/v2/...": http: server gave HTTP response to HTTPS client
```

```bash
sudo ./scripts/03-configure-containerd-registry.sh apply --registry zot-registry:30001
kubectl -n argocd delete pods --all
kubectl -n argocd get pods -w
```

This writes `/etc/containerd/certs.d/zot-registry:30001/hosts.toml` **and** sets
`config_path = "/etc/containerd/certs.d"` in `config.toml` (kubeadm often ships
`config_path = ''`, which makes `hosts.toml` ignored so kubelet keeps using HTTPS).

```toml
# /etc/containerd/certs.d/zot-registry:30001/hosts.toml
server = "http://zot-registry:30001"

[host."http://zot-registry:30001"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
```

Ensure `config.toml` has:

```toml
[plugins."io.containerd.grpc.v1.cri".registry]
  config_path = "/etc/containerd/certs.d"
```

**Docker** (if used on nodes), `/etc/docker/daemon.json`:

```json
{
  "insecure-registries": ["zot-registry:30001"]
}
```

```bash
curl -sS -o /dev/null -w '%{http_code}\n' http://zot-registry:30001/v2/
# expect 200 or 401
```

## What each script does

### `01-online-prepare.sh`
1. Adds the Argo Helm repo and pulls `argo-cd`
2. Extracts images with `helm template` (no hardcoded tags)
3. Pulls/saves images to `argo-cd-images.tar`

### `03-configure-containerd-registry.sh`
1. Writes containerd `hosts.toml` for plain-HTTP pulls
2. Restarts containerd so kubelet stops using HTTPS

### `02-airgap-deploy.sh`
1. Loads Argo CD images from the tar
2. Retags/pushes to `--registry`
3. Generates air-gap Helm values and runs `helm upgrade --install`
4. Waits for readiness and prints the admin password command

### Initial admin password

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
```

## Configuration reference

### `01-online-prepare.sh`

| Flag / env | Description |
|------------|-------------|
| `--chart-version VER` | Pin Argo CD Helm chart version |
| `--runtime NAME` | `docker` \| `podman` \| `nerdctl` \| `ctr` |
| `--pull-tool auto\|runtime\|crane\|ctr` | Image pull strategy |
| `--ctr-namespace NS` | containerd namespace (default `k8s.io`) |
| `--ctr-address PATH` | containerd socket path |
| `--skip-pull` | Re-package images already present locally |

### `02-airgap-deploy.sh`

| Flag / env | Description |
|------------|-------------|
| `--registry` / `PRIVATE_REGISTRY` | Private registry host[:port] (e.g. `zot-registry:30001`) |
| `--runtime NAME` | `docker` \| `podman` \| `nerdctl` \| `ctr` |
| `--ctr-namespace NS` | containerd namespace (default `k8s.io`) |
| `--mode` | `auto`, `load`, `push`, `load-and-push` |
| `--rewrite-mode` | `keep-path` (default) or `flatten` |
| `--insecure-registry` | Skip TLS verify / HTTP registry pushes (`ctr --plain-http`) |
| `--redis-secret-init manual\|helm` | `manual` (default): create `argocd-redis` Secret and disable the pre-upgrade hook Job; `helm`: use the chart Job |
| `--skip-helm` | Only load/push images |

### Helm pre-upgrade hook timeouts

If you see:

```text
Error: UPGRADE FAILED: pre-upgrade hooks failed: timed out waiting for the condition
```

that is almost always the `redis-secret-init` Job (ImagePullBackOff). Fix:

```bash
kubectl -n argocd delete job -l app.kubernetes.io/name=argocd-redis-secret-init --ignore-not-found

./scripts/02-airgap-deploy.sh \
  --runtime ctr \
  --registry zot-registry:30001 \
  --insecure-registry \
  --redis-secret-init manual \
  --artifacts ./artifacts
```

Also ensure every node can pull HTTP from the registry (`containerd` `hosts.toml` / Docker `insecure-registries`).

### Image rewrite modes

- **keep-path** (default): `quay.io/argoproj/argocd:v3.4.6` → `zot-registry:30001/argoproj/argocd:v3.4.6`
- **flatten**: `quay.io/argoproj/argocd:v3.4.6` → `zot-registry:30001/argocd:v3.4.6`

## Helm values layering

1. `artifacts/values-generated-airgap.yaml` — image repos/tags for the private registry
2. `helm/values-airgap.yaml` — operator defaults
3. Any `--values` files on the CLI

## Example: end-to-end

```bash
# --- Online ---
./scripts/01-online-prepare.sh --pull-tool crane
tar -C .. -cvf /media/usb/argo-cd-airgap-bundle.tar argocd-airgap

# --- Air-gapped ---
tar -xvf /media/usb/argo-cd-airgap-bundle.tar
cd argocd-airgap

sudo ./scripts/03-configure-containerd-registry.sh apply --registry zot-registry:30001

./scripts/02-airgap-deploy.sh \
  --runtime ctr \
  --registry zot-registry:30001 \
  --insecure-registry \
  --redis-secret-init manual \
  --artifacts ./artifacts \
  --namespace argocd
```
