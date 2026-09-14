#!/usr/bin/env bash
# Deploy VictoriaMetrics cluster + Grafana on a local k3d cluster, simulating
# OpenShift's restricted-v2 (arbitrary UID + fsGroup) via the -ocp-sim overlays.
# Requires: docker (running), k3d, helm, kubectl.
set -euo pipefail

CLUSTER="${CLUSTER:-vmtest}"
NS="${NS:-vm-test}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ">> k3d cluster '$CLUSTER'"
if ! k3d cluster list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$CLUSTER"; then
  k3d cluster create "$CLUSTER" --wait
fi
kubectl config use-context "k3d-$CLUSTER" >/dev/null

echo ">> Helm repos"
helm repo add vm https://victoriametrics.github.io/helm-charts/ >/dev/null
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null
helm repo update >/dev/null

echo ">> Namespace $NS"
kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS" >/dev/null

echo ">> VictoriaMetrics cluster (base + OCP-sim overlay)"
helm upgrade --install vmcluster vm/victoria-metrics-cluster \
  --version 0.50.0 -n "$NS" \
  -f "$HERE/values-vmcluster.yaml" -f "$HERE/values-vmcluster-ocp-sim.yaml" \
  --wait --timeout 5m

echo ">> Grafana (base + OCP-sim overlay)"
helm upgrade --install grafana grafana/grafana \
  --version 10.5.15 -n "$NS" \
  -f "$HERE/values-grafana.yaml" -f "$HERE/values-grafana-ocp-sim.yaml" \
  --wait --timeout 5m

echo ">> vmagent (scrapes VM cluster components -> feeds the dashboard)"
helm upgrade --install vmagent vm/victoria-metrics-agent \
  --version 0.47.0 -n "$NS" \
  -f "$HERE/values-vmagent.yaml" -f "$HERE/values-vmagent-ocp-sim.yaml" \
  --wait --timeout 3m

echo ">> Pods:"
kubectl get pods -n "$NS"
echo
echo ">> Grafana admin password:"
kubectl get secret grafana -n "$NS" -o jsonpath="{.data.admin-password}" | base64 -d ; echo
echo ">> Port-forward:  kubectl port-forward svc/grafana 3000:80 -n $NS"
