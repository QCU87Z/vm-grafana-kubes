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
helm repo add grafana-community https://grafana-community.github.io/helm-charts/ >/dev/null
helm repo add codecentric https://codecentric.github.io/helm-charts >/dev/null
helm repo update >/dev/null

echo ">> Namespace $NS"
kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS" >/dev/null

echo ">> VictoriaMetrics cluster (base + OCP-sim overlay)"
helm upgrade --install vmcluster vm/victoria-metrics-cluster \
  --version 0.50.0 -n "$NS" \
  -f "$HERE/values-vmcluster.yaml" -f "$HERE/values-vmcluster-ocp-sim.yaml" \
  --wait --timeout 5m

echo ">> vmauth (tenant-enforcing auth proxy) + ingress"
helm upgrade --install vmauth vm/victoria-metrics-auth \
  --version 0.41.0 -n "$NS" \
  -f "$HERE/values-vmauth.yaml" -f "$HERE/values-vmauth-ocp-sim.yaml" \
  --wait --timeout 3m
kubectl apply -f "$HERE/ingress-vmauth.yaml"

echo ">> Keycloak realm ConfigMap + Keycloak (SSO / IdP)"
kubectl create configmap keycloak-realm -n "$NS" \
  --from-file=observability-realm.json="$HERE/keycloak-realm.json" \
  --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install keycloak codecentric/keycloakx \
  --version 7.3.1 -n "$NS" \
  -f "$HERE/values-keycloak.yaml" -f "$HERE/values-keycloak-ocp-sim.yaml" \
  --wait --timeout 5m

echo ">> vmui Ingress"
kubectl apply -f "$HERE/ingress-vmui.yaml"

echo ">> Grafana (base + OCP-sim overlay, with Keycloak SSO)"
helm upgrade --install grafana grafana-community/grafana \
  --version 13.2.4 -n "$NS" \
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
echo ">> Grafana local admin password (fallback login):"
kubectl get secret grafana -n "$NS" -o jsonpath="{.data.admin-password}" | base64 -d ; echo
echo
echo ">> ONE port-forward serves all UIs via Traefik + *.127.0.0.1.nip.io :"
echo "     kubectl port-forward -n kube-system svc/traefik 8080:80"
echo "   then open:"
echo "     Grafana   http://grafana.127.0.0.1.nip.io:8080     (Sign in with Keycloak)"
echo "     vmui      http://vmui.127.0.0.1.nip.io:8080/select/0/vmui/"
echo "     Keycloak  http://keycloak.127.0.0.1.nip.io:8080    (admin / admin)"
echo "     vmauth    http://vmauth.127.0.0.1.nip.io:8080      (tenant write/read entrypoint)"
echo "   SSO test user: ashley / changeme"
echo "   Tenants: team-a (acct 1) / team-b (acct 2). Grafana datasources: 'VM - team-a', 'VM - team-b'."
echo "   Write example: curl -u team-a-write:team-a-write-pass --data-binary 'm 1' \\"
echo "                    http://vmauth.127.0.0.1.nip.io:8080/api/v1/import/prometheus"
