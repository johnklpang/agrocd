# Argo CD Air-Gapped Helm Deployment

Robust Bash + Helm workflow for installing Argo CD in a disconnected environment, using **[Zot](https://zotregistry.dev)** as the local OCI registry.

## Layout

```
argocd-airgap/
├── scripts/
│   ├── 01-online-prepare.sh   # Connected: pull Argo CD (+ optional Zot) chart/images
│   ├── 02-airgap-deploy.sh    # Air-gapped: load/push images + Helm install
│   ├── 03-zot-registry.sh     # Start/stop local Zot (container or Helm)
│   ├── 04-configure-containerd-registry.sh  # Allow kubelet HTTP pulls from Zot
│   └── lib/common.sh
├── helm/
│   └── values-airgap.yaml     # Argo CD operator overrides
├── zot/
│   ├── config.json            # Zot HTTP registry config (:5000)
│   └── values-airgap.yaml     # In-cluster Zot Helm overrides
└── artifacts/                 # Generated transfer bundle (gitignored contents)
```

## Prerequisites

| Phase | Tools |
|-------|--------|
| Online | `helm` (≥ 3.8), `docker`/`podman`/`nerdctl`/`ctr`, optional `crane`/`skopeo` |
| Air-gapped | Same runtime, `curl`; `kubectl`+`helm` for cluster install. **`skopeo` recommended** for OCI pushes to Zot. Optional: `crane` |

## Recommended flow (with Zot)

### 1. Online — package Argo CD **and** Zot

```bash
cd argocd-airgap
chmod +x scripts/*.sh

./scripts/01-online-prepare.sh --with-zot
# Prefer containerd ctr for pulls:
#   ./scripts/01-online-prepare.sh --with-zot --runtime ctr --pull-tool ctr
#   ./scripts/01-online-prepare.sh --with-zot --pull-tool ctr   # pull via ctr, save via docker/etc
# optional: --ctr-namespace k8s.io
```

This pulls the Argo CD chart/images **and**:

- Zot container image → `artifacts/zot-images.tar`
- Zot Helm chart → `artifacts/zot-*.tgz`
- Zot config/values → `artifacts/zot/`

### Using `ctr` (containerd) to download images

```bash
# Full ctr workflow (pull + export into the transfer tar)
export CTR_NAMESPACE=k8s.io   # kubelet namespace (default)
./scripts/01-online-prepare.sh --runtime ctr --pull-tool ctr

# Or only use ctr for downloads, keep docker/podman for packaging:
./scripts/01-online-prepare.sh --pull-tool ctr

# Air-gapped: import the tar into containerd (visible to kubelet)
./scripts/02-airgap-deploy.sh --runtime ctr --use-zot --artifacts ./artifacts
# Equivalent manual import:
#   ctr -n k8s.io images import artifacts/argo-cd-images.tar
```

`ctr` notes:

| Item | Detail |
|------|--------|
| Pull | `ctr -n k8s.io images pull [--platform linux/amd64] <ref>` |
| Export | `ctr -n k8s.io images export argo-cd-images.tar <refs…>` |
| Import | `ctr -n k8s.io images import argo-cd-images.tar` |
| HTTP registry | `--plain-http` (set automatically with `--use-zot` / `--insecure-registry`) |
| Namespace | Default `k8s.io` so kubelet can see imported images; override with `--ctr-namespace` |
| Unpack fallback | If overlay whiteouts fail on the bastion, import retries with `--no-unpack` (content still exportable/pushable; cluster nodes unpack normally) |
| Env | `CTR_NAMESPACE`, `CTR_ADDRESS`, `CTR_PLATFORM`, `CTR_NO_UNPACK=1` |

### 2. Transfer

```bash
tar -C .. -cvf argo-cd-airgap-bundle.tar argocd-airgap
# sneaker-net / USB → air-gapped host, then:
tar -xvf argo-cd-airgap-bundle.tar
cd argocd-airgap
```

### 3. Air-gapped — start Zot, then install Argo CD

```bash
# Start Zot as a local container on 127.0.0.1:5000 (default)
./scripts/03-zot-registry.sh start

# Load Argo CD images, push them into Zot, helm upgrade --install
./scripts/02-airgap-deploy.sh --use-zot --artifacts ./artifacts
```

`--use-zot` reads `artifacts/zot.env` (written by `03-zot-registry.sh`) and enables insecure HTTP pushes to Zot.

### Existing Zot registry (HTTP)

If Zot is already running (for example NodePort `zot-registry:30001`), do **not** start a new one. Push with plain HTTP:

```bash
./scripts/02-airgap-deploy.sh \
  --runtime ctr \
  --registry zot-registry:30001 \
  --insecure-registry \
  --artifacts ./artifacts
```

`--insecure-registry` is required for HTTP Zot. Without it, skopeo tries HTTPS and fails with:
`http: server gave HTTP response to HTTPS client`.

Equivalent:

```bash
export PRIVATE_REGISTRY=zot-registry:30001
./scripts/02-airgap-deploy.sh --runtime ctr --use-zot --insecure-registry --artifacts ./artifacts
# --use-zot forces insecure HTTP when PRIVATE_REGISTRY is already set
```

## Zot registry commands

```bash
./scripts/03-zot-registry.sh start              # container backend (default)
./scripts/03-zot-registry.sh status
./scripts/03-zot-registry.sh addr               # print host:port
./scripts/03-zot-registry.sh stop

./scripts/03-zot-registry.sh start --backend helm --namespace zot
./scripts/03-zot-registry.sh start --port 5000 --registry 192.168.1.10:5000
```

| Flag | Description |
|------|-------------|
| `--backend container\|binary\|helm` | Local container (default), native binary, or in-cluster Helm |
| `--port PORT` | Listen / host port (default `5000`) |
| `--registry HOST:PORT` | Advertised address written to `zot.env` |
| `--data-dir DIR` | Persistent storage directory |
| `--config FILE` | Zot `config.json` (default `zot/config.json`) |
| `--binary PATH` | Path to packaged `zot` binary (binary backend) |

## Allowing Kubernetes to pull from HTTP Zot

Lab Zot serves **plain HTTP**. **Every node** must treat it as an insecure registry, or kubelet keeps trying HTTPS and pods stay in `ImagePullBackOff`:

```text
Failed to pull image "zot-registry:30001/argoproj/argocd:v3.5.0":
Head "https://zot-registry:30001/v2/...": http: server gave HTTP response to HTTPS client
```

### Fix (run on every node)

```bash
# On k8s-master, k8s-worker1, k8s-worker2, ...
sudo ./scripts/04-configure-containerd-registry.sh apply --registry zot-registry:30001

# Then recreate pods so pulls retry over HTTP
kubectl -n argocd delete pods --all
kubectl -n argocd get pods -w
```

This writes `/etc/containerd/certs.d/zot-registry:30001/hosts.toml` and restarts containerd.

Manual equivalent:

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

Also confirm nodes can resolve and reach the registry:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' http://zot-registry:30001/v2/
# expect 200 or 401
```

## What each script does

### `01-online-prepare.sh`
1. Adds the Argo Helm repo and pulls `argo-cd`
2. Extracts images with `helm template` (no hardcoded tags)
3. Pulls/saves images to `argo-cd-images.tar`
4. With `--with-zot`: also packages the Zot image + chart

### `03-zot-registry.sh`
1. Loads `zot-images.tar` into the local runtime
2. Starts Zot (container or Helm)
3. Writes `artifacts/zot.env` with `PRIVATE_REGISTRY=...`

### `04-configure-containerd-registry.sh`
1. Writes containerd `hosts.toml` for plain-HTTP pulls from Zot
2. Restarts containerd so kubelet stops using HTTPS

### `02-airgap-deploy.sh`
1. Loads Argo CD images from the tar
2. Retags/pushes to Zot (`--use-zot`) or another `--registry`
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
| `--with-zot` | Also package Zot image + Helm chart |
| `--zot-image REF` | Override Zot image reference |
| `--zot-chart-version V` | Pin Zot Helm chart version |
| `--chart-version VER` | Pin Argo CD Helm chart version |
| `--runtime NAME` | `docker` \| `podman` \| `nerdctl` \| `ctr` |
| `--pull-tool auto\|runtime\|crane\|ctr` | Image pull strategy (`ctr` = `ctr images pull`) |
| `--ctr-namespace NS` | containerd namespace (default `k8s.io`) |
| `--ctr-address PATH` | containerd socket path |
| `--skip-pull` | Re-package images already present locally |

### `02-airgap-deploy.sh`

| Flag / env | Description |
|------------|-------------|
| `--use-zot` | Use Zot via `artifacts/zot.env` (sets registry + insecure HTTP) |
| `--registry` / `PRIVATE_REGISTRY` | Explicit registry host[:port] |
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

that is almost always the `redis-secret-init` Job (ImagePullBackOff from Zot). Fix:

```bash
# Clean stuck hook Job, then re-run (manual secret init is the default)
kubectl -n argocd delete job -l app.kubernetes.io/name=argocd-redis-secret-init --ignore-not-found

./scripts/02-airgap-deploy.sh \
  --runtime ctr \
  --registry zot-registry:30001 \
  --insecure-registry \
  --redis-secret-init manual \
  --artifacts ./artifacts
```

Also ensure every node can pull HTTP from Zot (`containerd` `hosts.toml` / Docker `insecure-registries` for `zot-registry:30001`).


### Image rewrite modes

- **keep-path** (default): `quay.io/argoproj/argocd:v3.4.6` → `127.0.0.1:5000/argoproj/argocd:v3.4.6`
- **flatten**: `quay.io/argoproj/argocd:v3.4.6` → `127.0.0.1:5000/argocd:v3.4.6`

## Helm values layering

1. `artifacts/values-generated-airgap.yaml` — image repos/tags for Zot
2. `helm/values-airgap.yaml` — operator defaults
3. Any `--values` files on the CLI

## Example: end-to-end with Zot

```bash
# --- Online ---
./scripts/01-online-prepare.sh --with-zot --pull-tool crane
tar -C .. -cvf /media/usb/argo-cd-airgap-bundle.tar argocd-airgap

# --- Air-gapped ---
tar -xvf /media/usb/argo-cd-airgap-bundle.tar
cd argocd-airgap

./scripts/03-zot-registry.sh start --port 5000
# Configure containerd/Docker insecure-registries for the printed address

./scripts/02-airgap-deploy.sh --use-zot --artifacts ./artifacts --namespace argocd
```
