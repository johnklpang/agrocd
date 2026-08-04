# Argo CD air-gapped Helm deployment workflow (with local Zot OCI registry)
#
# Online (connected) host:
#   ./argocd-airgap/scripts/01-online-prepare.sh --with-zot
#
# Transfer the argocd-airgap/ tree (or artifacts + scripts + zot + helm).
#
# Air-gapped host:
#   ./argocd-airgap/scripts/03-zot-registry.sh start
#   ./argocd-airgap/scripts/02-airgap-deploy.sh --use-zot
#
# See argocd-airgap/README.md for full instructions.
