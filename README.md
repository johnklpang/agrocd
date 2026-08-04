# Argo CD air-gapped Helm deployment workflow
#
# Online (connected) host:
#   1. Run scripts/01-online-prepare.sh to pull the chart + images.
#   2. Transfer the artifacts/ directory (or argo-cd-airgap-bundle.tar) offline.
#
# Air-gapped host:
#   3. Run scripts/02-airgap-deploy.sh to load/push images and helm upgrade --install.
#
# See argocd-airgap/README.md for full instructions.
