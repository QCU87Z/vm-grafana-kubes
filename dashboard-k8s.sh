#!/usr/bin/env bash
# Install the Kubernetes Dashboard (live cluster object viewer) on the k3d cluster,
# create an admin viewer ServiceAccount, and print a login token + access instructions.
# NOTE: the chart's GitHub-Pages Helm repo has been returning 404, so we install straight
# from the pinned release tarball. Local test cluster only — the SA is bound to cluster-admin.
set -euo pipefail

CTX="${CTX:-k3d-vmtest}"
DS_NS="kubernetes-dashboard"
CHART_VER="7.14.0"
TGZ="https://github.com/kubernetes/dashboard/releases/download/kubernetes-dashboard-${CHART_VER}/kubernetes-dashboard-${CHART_VER}.tgz"

echo ">> Installing Kubernetes Dashboard $CHART_VER"
helm --kube-context "$CTX" upgrade --install kubernetes-dashboard "$TGZ" \
  --namespace "$DS_NS" --create-namespace --wait --timeout 6m >/dev/null

echo ">> Admin viewer ServiceAccount"
kubectl --context "$CTX" -n "$DS_NS" create serviceaccount admin-user \
  --dry-run=client -o yaml | kubectl --context "$CTX" apply -f - >/dev/null
kubectl --context "$CTX" create clusterrolebinding dashboard-admin-user \
  --clusterrole=cluster-admin --serviceaccount="$DS_NS":admin-user \
  --dry-run=client -o yaml | kubectl --context "$CTX" apply -f - >/dev/null

echo
echo ">> Access:"
echo "   kubectl --context $CTX -n $DS_NS port-forward svc/kubernetes-dashboard-kong-proxy 8443:443"
echo "   open https://localhost:8443   (accept the self-signed cert)"
echo
echo ">> Login token (valid 24h):"
kubectl --context "$CTX" -n "$DS_NS" create token admin-user --duration=24h
